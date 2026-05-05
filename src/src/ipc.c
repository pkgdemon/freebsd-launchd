/*
 * ipc.c — server-side AF_UNIX request handler (Phase 2 increment 2).
 *
 * Listens on an AF_UNIX SOCK_STREAM socket. Each accepted connection
 * gets its own DISPATCH_SOURCE_TYPE_READ source. The handler reads one
 * framed message, dispatches by cmd, sends one reply, and closes.
 *
 * One-message-per-connection keeps the protocol stateless and the
 * implementation small. launchctl opens a fresh connection per
 * subcommand, which matches Apple's launchctl behavior.
 *
 * Apple's original 537-line src/ipc.c (Mach RPC server) is preserved
 * at git 0d37c19 (the launchd-842.1.4 import) for reference.
 */

#include "ipc.h"
#include "core.h"
#include "log.h"
#include "runtime.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static int                  listen_fd      = -1;
static dispatch_source_t    listen_src     = NULL;
static char                *sock_path      = NULL;
static bool                 created_canonical = false; /* did we create the
                                                        * /var/run/launchd/sock
                                                        * symlink? */

const char *
ipc_server_path(void)
{
    return sock_path;
}

/* (ipc_send / ipc_recv live in ipc_proto.c — shared with launchctl
 * client which links just that file + ipc.h, no libdispatch deps.) */

/* ---- command handlers ---- */

static int
send_reply(int fd, int err, const char *msg)
{
    /* Reply payload format: "errno: msg\n", where errno is decimal. */
    char buf[1024];
    int n = snprintf(buf, sizeof(buf), "%d %s\n", err, msg ? msg : "");
    if (n < 0) n = 0;
    if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
    return ipc_send(fd, IPC_CMD_REPLY, buf, (size_t)n);
}

static void
handle_load(int fd, const char *path)
{
    if (!path || path[0] == '\0') {
        send_reply(fd, EINVAL, "missing plist path");
        return;
    }
    Job *j = jobmgr_load_plist_file(path);
    if (!j) {
        send_reply(fd, EINVAL, "plist load failed (see launchd log)");
        return;
    }
    if (jobmgr_insert(j) != 0) {
        char msg[256];
        snprintf(msg, sizeof(msg), "%s already loaded", j->label);
        jobmgr_free(j);
        send_reply(fd, EEXIST, msg);
        return;
    }
    if (j->run_at_load && !j->disabled) {
        if (job_spawn(j) != 0) {
            send_reply(fd, EIO, "spawn failed");
            return;
        }
    }
    send_reply(fd, 0, j->label);
}

static void
handle_unload(int fd, const char *label)
{
    if (!label || label[0] == '\0') {
        send_reply(fd, EINVAL, "missing label");
        return;
    }
    int err = jobmgr_unload(label);
    if (err == ENOENT) {
        send_reply(fd, ENOENT, "no such job");
        return;
    }
    if (err != 0) {
        send_reply(fd, err, strerror(err));
        return;
    }
    send_reply(fd, 0, label);
}

/* Build a "<label>\t<pid>\t<last-exit-status>\n" line per loaded job. */
struct list_ctx {
    char  *buf;
    size_t cap;
    size_t len;
};

static void
list_append(Job *j, void *vctx)
{
    struct list_ctx *c = vctx;
    char line[512];
    int n = snprintf(line, sizeof(line),
        "%s\t%d\t%d\n",
        j->label,
        (int)j->p,
        WIFEXITED(j->last_exit_status) ? WEXITSTATUS(j->last_exit_status) : -1);
    if (n <= 0) return;
    if (c->len + (size_t)n + 1 > c->cap) {
        size_t newcap = (c->cap ? c->cap * 2 : 1024);
        while (newcap < c->len + (size_t)n + 1) newcap *= 2;
        char *nb = realloc(c->buf, newcap);
        if (!nb) return;
        c->buf = nb;
        c->cap = newcap;
    }
    memcpy(c->buf + c->len, line, (size_t)n);
    c->len += (size_t)n;
    c->buf[c->len] = '\0';
}

static void
list_count(Job *j, void *vctx)
{
    (void)j;
    (*(size_t *)vctx)++;
}

static void
handle_list(int fd)
{
    /* Reply format: a leading "0 <count> jobs\n" status line, then
     * one tab-separated row per job: "<label>\t<pid>\t<last-exit>\n".
     * launchctl prints the whole reply verbatim, so the status header
     * is just the first line and the rows follow. */
    struct list_ctx c = { 0 };
    /* Count + reserve. */
    size_t count = 0;
    jobmgr_foreach(list_count, &count);

    char header[64];
    snprintf(header, sizeof(header), "0 %zu jobs\n", count);
    size_t hlen = strlen(header);

    jobmgr_foreach(list_append, &c);

    /* Concatenate header + body into one payload. */
    size_t total = hlen + c.len;
    char  *out   = malloc(total + 1);
    if (!out) {
        free(c.buf);
        send_reply(fd, ENOMEM, "out of memory");
        return;
    }
    memcpy(out, header, hlen);
    if (c.buf) memcpy(out + hlen, c.buf, c.len);
    out[total] = '\0';

    /* Sent as a raw payload (already errno-prefixed); skip send_reply
     * which would double-prefix. */
    ipc_send(fd, IPC_CMD_REPLY, out, total);

    free(out);
    free(c.buf);
}

static void
handle_start(int fd, const char *label)
{
    if (!label || label[0] == '\0') {
        send_reply(fd, EINVAL, "missing label");
        return;
    }
    Job *j = jobmgr_find_by_label(label);
    if (!j) {
        send_reply(fd, ENOENT, "no such job");
        return;
    }
    if (j->state == JOB_STATE_RUNNING) {
        send_reply(fd, EALREADY, "already running");
        return;
    }
    if (job_spawn(j) != 0) {
        send_reply(fd, EIO, "spawn failed");
        return;
    }
    send_reply(fd, 0, label);
}

static void
handle_stop(int fd, const char *label)
{
    if (!label || label[0] == '\0') {
        send_reply(fd, EINVAL, "missing label");
        return;
    }
    Job *j = jobmgr_find_by_label(label);
    if (!j) {
        send_reply(fd, ENOENT, "no such job");
        return;
    }
    if (j->state != JOB_STATE_RUNNING || j->p <= 0) {
        send_reply(fd, ESRCH, "not running");
        return;
    }
    /* SIGTERM only — KeepAlive will respawn if configured (subject to
     * the 10s throttle). For "stop and don't respawn" use unload. */
    if (kill(j->p, SIGTERM) != 0) {
        send_reply(fd, errno, strerror(errno));
        return;
    }
    j->state = JOB_STATE_STOPPING;
    send_reply(fd, 0, label);
}

static void
handle_shutdown(int fd)
{
    send_reply(fd, 0, "shutting down");
    launchd_shutdown();
}

static void
dispatch_msg(int fd, struct ipc_msg_hdr *hdr, void *payload)
{
    switch (hdr->cmd) {
    case IPC_CMD_LOAD:
        handle_load(fd, (const char *)payload);
        break;
    case IPC_CMD_UNLOAD:
        handle_unload(fd, (const char *)payload);
        break;
    case IPC_CMD_LIST:
        handle_list(fd);
        break;
    case IPC_CMD_START:
        handle_start(fd, (const char *)payload);
        break;
    case IPC_CMD_STOP:
        handle_stop(fd, (const char *)payload);
        break;
    case IPC_CMD_SHUTDOWN:
        handle_shutdown(fd);
        break;
    default:
        send_reply(fd, EINVAL, "unknown command");
        break;
    }
}

/* Per-connection: read one message, dispatch, close. */
static void
handle_connection(int fd)
{
    struct ipc_msg_hdr hdr;
    void *payload = NULL;

    int r = ipc_recv(fd, &hdr, &payload);
    if (r == -2) {
        /* clean EOF — client connected and immediately closed */
    } else if (r < 0) {
        launchd_syslog(LOG_ERR, "ipc_recv: %s", strerror(errno));
        send_reply(fd, errno ? errno : EPROTO, "protocol error");
    } else {
        dispatch_msg(fd, &hdr, payload);
    }
    free(payload);
    close(fd);
}

/* ---- accept loop ---- */

static void
accept_one(void)
{
    for (;;) {
        struct sockaddr_un sun;
        socklen_t sl = sizeof(sun);
        int cfd = accept(listen_fd, (struct sockaddr *)&sun, &sl);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            launchd_syslog(LOG_ERR, "accept: %s", strerror(errno));
            return;
        }
        handle_connection(cfd);
    }
}

/* ---- init/teardown ---- */

int
ipc_server_init(const char *sockpath_or_null)
{
    if (sockpath_or_null) {
        sock_path = strdup(sockpath_or_null);
    } else {
        /* Path resolution order:
         *   1. $LAUNCHD_SOCKET if the caller (e.g., the CI test harness)
         *      already exported one, so daemon and client agree without
         *      having to scrape the daemon's stderr.
         *   2. /var/run/launchd/sock when PID 1 (canonical path).
         *   3. /tmp/launchd-<pid>.sock otherwise — lets multiple non-PID-1
         *      test daemons coexist without colliding. */
        const char *env = getenv("LAUNCHD_SOCKET");
        if (env && env[0]) {
            sock_path = strdup(env);
        } else if (getpid() == 1) {
            mkdir(IPC_DEFAULT_PID1_DIR, 0755);
            sock_path = strdup(IPC_DEFAULT_PID1_SOCK);
        } else {
            char buf[256];
            snprintf(buf, sizeof(buf),
                "/tmp/launchd-%u.sock", (unsigned)getpid());
            sock_path = strdup(buf);
        }
    }
    if (!sock_path) return -1;

    unlink(sock_path);

    listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        launchd_syslog(LOG_CRIT, "socket: %s", strerror(errno));
        return -1;
    }
    fcntl(listen_fd, F_SETFD, FD_CLOEXEC);
    fcntl(listen_fd, F_SETFL, O_NONBLOCK);

    struct sockaddr_un sun = { .sun_family = AF_UNIX };
    strncpy(sun.sun_path, sock_path, sizeof(sun.sun_path) - 1);

    mode_t old = umask(077);
    if (bind(listen_fd, (struct sockaddr *)&sun, sizeof(sun)) < 0) {
        launchd_syslog(LOG_CRIT, "bind %s: %s", sock_path, strerror(errno));
        umask(old);
        close(listen_fd);
        listen_fd = -1;
        return -1;
    }
    umask(old);

    if (listen(listen_fd, 16) < 0) {
        launchd_syslog(LOG_CRIT, "listen: %s", strerror(errno));
        close(listen_fd);
        listen_fd = -1;
        return -1;
    }

    setenv("LAUNCHD_SOCKET", sock_path, 1);

    /* Create the canonical /var/run/launchd/sock symlink so that
     * `launchctl list` (and any other client without LAUNCHD_SOCKET
     * exported) can find us without the user having to scrape the
     * daemon's stderr. Best-effort: if we don't have permission
     * (non-root, or path immutable), log and continue. Skip when we
     * already are the canonical path (PID 1, or explicit override). */
    if (strcmp(sock_path, IPC_DEFAULT_PID1_SOCK) != 0) {
        if (mkdir(IPC_DEFAULT_PID1_DIR, 0755) != 0 && errno != EEXIST) {
            launchd_syslog(LOG_INFO,
                "ipc: cannot create %s: %s — `launchctl` will need "
                "LAUNCHD_SOCKET=%s",
                IPC_DEFAULT_PID1_DIR, strerror(errno), sock_path);
        } else {
            unlink(IPC_DEFAULT_PID1_SOCK);  /* may be a stale symlink */
            if (symlink(sock_path, IPC_DEFAULT_PID1_SOCK) == 0) {
                created_canonical = true;
                launchd_syslog(LOG_NOTICE,
                    "ipc: %s -> %s",
                    IPC_DEFAULT_PID1_SOCK, sock_path);
            } else {
                launchd_syslog(LOG_INFO,
                    "ipc: cannot symlink %s -> %s: %s — "
                    "`launchctl` will need LAUNCHD_SOCKET=%s",
                    IPC_DEFAULT_PID1_SOCK, sock_path, strerror(errno),
                    sock_path);
            }
        }
    }

    listen_src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)listen_fd, 0,
        launchd_main_queue());
    if (!listen_src) {
        launchd_syslog(LOG_CRIT, "dispatch_source_create(listen) failed");
        close(listen_fd);
        listen_fd = -1;
        return -1;
    }
    dispatch_source_set_event_handler(listen_src, ^{ accept_one(); });
    dispatch_activate(listen_src);

    launchd_syslog(LOG_NOTICE, "ipc: listening on %s", sock_path);
    return 0;
}

void
ipc_server_close(void)
{
    if (listen_src) {
        dispatch_source_cancel(listen_src);
        listen_src = NULL;
    }
    if (listen_fd >= 0) {
        close(listen_fd);
        listen_fd = -1;
    }
    if (created_canonical) {
        unlink(IPC_DEFAULT_PID1_SOCK);
        created_canonical = false;
    }
    if (sock_path) {
        unlink(sock_path);
        free(sock_path);
        sock_path = NULL;
    }
}
