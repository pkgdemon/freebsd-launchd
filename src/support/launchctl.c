/*
 * launchctl.c — minimal AF_UNIX client for the new launchd
 * (Phase 2 increment 2).
 *
 * Connects to the path in $LAUNCHD_SOCKET (or the per-pid default
 * /tmp/launchd-<pid>.sock if unset and there's exactly one launchd in
 * /tmp/launchd-*.sock; falls back to /var/run/launchd/sock for PID 1).
 * Sends one framed binary message via the protocol defined in
 * src/launchd/src/ipc.h, prints the reply, exits with 0 on success or
 * the daemon-reported errno on failure.
 *
 * Subcommands implemented in this increment:
 *   launchctl load <plist-path>         IPC_CMD_LOAD
 *   launchctl unload <label>            IPC_CMD_UNLOAD   (stub on server)
 *   launchctl list                      IPC_CMD_LIST     (stub on server)
 *   launchctl start <label>             IPC_CMD_START    (stub on server)
 *   launchctl stop <label>              IPC_CMD_STOP     (stub on server)
 *   launchctl shutdown                  IPC_CMD_SHUTDOWN
 *   launchctl help                      print usage
 *
 * Apple's original ~4549-line support/launchctl.c is preserved at git
 * 0d37c19 (the launchd-842.1.4 import) for reference.
 */

#include "../src/ipc.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static void
usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s <subcommand> [args...]\n"
        "\n"
        "  load <plist-path>     load a plist into a running launchd\n"
        "  unload <label>        unload a job by label  (stub)\n"
        "  list                  list loaded jobs       (stub)\n"
        "  start <label>         manually start a job   (stub)\n"
        "  stop <label>          manually stop a job    (stub)\n"
        "  shutdown              tell launchd to exit\n"
        "  help                  show this help\n"
        "\n"
        "Connects to $LAUNCHD_SOCKET, falling back to\n"
        "  /var/run/launchd/sock (pid 1) or\n"
        "  /tmp/launchd-<pid>.sock (any other pid)\n",
        argv0);
}

/* Pick a socket path: $LAUNCHD_SOCKET first, then default. */
static const char *
pick_sockpath(char *buf, size_t bufsz)
{
    const char *env = getenv("LAUNCHD_SOCKET");
    if (env && env[0]) {
        return env;
    }
    /* Fallback path. We don't try to enumerate /tmp/launchd-*.sock —
     * that's ambiguous if multiple test daemons are running. The user
     * should set LAUNCHD_SOCKET explicitly in that case. */
    snprintf(buf, bufsz, "%s", IPC_DEFAULT_PID1_SOCK);
    return buf;
}

static int
client_connect(void)
{
    char buf[256];
    const char *path = pick_sockpath(buf, sizeof(buf));

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "launchctl: socket: %s\n", strerror(errno));
        return -1;
    }
    struct sockaddr_un sun = { .sun_family = AF_UNIX };
    strncpy(sun.sun_path, path, sizeof(sun.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) < 0) {
        fprintf(stderr, "launchctl: connect %s: %s\n", path, strerror(errno));
        fprintf(stderr, "  (set LAUNCHD_SOCKET if launchd is at a different path)\n");
        close(fd);
        return -1;
    }
    return fd;
}

/* Send one command, read one reply, print it, return errno-style status. */
static int
do_cmd(uint32_t cmd, const char *payload)
{
    int fd = client_connect();
    if (fd < 0) return 1;

    size_t plen = payload ? strlen(payload) : 0;
    if (ipc_send(fd, cmd, payload, plen) != 0) {
        fprintf(stderr, "launchctl: send: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    struct ipc_msg_hdr hdr;
    void *reply = NULL;
    int r = ipc_recv(fd, &hdr, &reply);
    close(fd);
    if (r != 0) {
        fprintf(stderr, "launchctl: recv: %s\n",
            r == -2 ? "server closed without reply" : strerror(errno));
        return 1;
    }

    if (hdr.cmd != IPC_CMD_REPLY) {
        fprintf(stderr, "launchctl: unexpected reply cmd=%u\n", hdr.cmd);
        free(reply);
        return 1;
    }

    /* Reply payload format from ipc.c: "<errno> <message>\n". Print as-is. */
    if (reply) {
        fputs((char *)reply, stdout);
    }

    /* Parse the leading integer to set our exit code. */
    int rc = 0;
    if (reply) {
        rc = (int)strtol((char *)reply, NULL, 10);
    }
    free(reply);
    return rc == 0 ? 0 : 1;
}

int
main(int argc, char *argv[])
{
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }
    const char *sub = argv[1];

    if (!strcmp(sub, "help") || !strcmp(sub, "-h") || !strcmp(sub, "--help")) {
        usage(argv[0]);
        return 0;
    }

    if (!strcmp(sub, "load")) {
        if (argc != 3) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_LOAD, argv[2]);
    }
    if (!strcmp(sub, "unload")) {
        if (argc != 3) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_UNLOAD, argv[2]);
    }
    if (!strcmp(sub, "list")) {
        if (argc != 2) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_LIST, NULL);
    }
    if (!strcmp(sub, "start")) {
        if (argc != 3) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_START, argv[2]);
    }
    if (!strcmp(sub, "stop")) {
        if (argc != 3) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_STOP, argv[2]);
    }
    if (!strcmp(sub, "shutdown")) {
        if (argc != 2) { usage(argv[0]); return 2; }
        return do_cmd(IPC_CMD_SHUTDOWN, NULL);
    }

    fprintf(stderr, "launchctl: unknown subcommand: %s\n", sub);
    usage(argv[0]);
    return 2;
}
