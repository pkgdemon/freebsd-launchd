/*
 * runtime.c — libdispatch-based event loop for the new launchd.
 *
 * Phase 2 increment 1: SIGCHLD reaping + SIGTERM/SIGINT shutdown.
 * Apple's original ~1450-line src/runtime.c (kqueue + Mach port set
 * dispatcher) is preserved at git 0d37c19 (the launchd-842.1.4 import)
 * for reference.
 */

#include "runtime.h"
#include "core.h"
#include "ipc.h"
#include "log.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static dispatch_queue_t main_q;
static dispatch_source_t sigchld_src;
static dispatch_source_t sigterm_src;
static dispatch_source_t sigint_src;
static dispatch_source_t sighup_src;

static bool shutting_down = false;

dispatch_queue_t
launchd_main_queue(void)
{
    return main_q;
}

void
launchd_shutdown(void)
{
    if (shutting_down) {
        return;
    }
    shutting_down = true;
    launchd_syslog(LOG_NOTICE, "shutting down");
    /* Tear down the IPC listener so the canonical /var/run/launchd/sock
     * symlink doesn't outlive us and point at a dead per-pid socket. */
    ipc_server_close();
    launchd_log_close();
    exit(0);
}

/* SIGCHLD handler — drain all pending children. SIGCHLD coalesces in
 * the kernel, so one delivery may correspond to multiple exits. */
static void
sigchld_handler(void)
{
    for (;;) {
        int status;
        pid_t p = waitpid(-1, &status, WNOHANG);
        if (p == 0) {
            /* No more terminated children right now. */
            return;
        }
        if (p < 0) {
            if (errno != ECHILD) {
                launchd_syslog(LOG_ERR, "waitpid: %s", strerror(errno));
            }
            return;
        }

        Job *j = job_find_by_pid(p);
        if (!j) {
            /* Reparented orphan we don't supervise. PID 1 still needs
             * to reap it so the kernel doesn't accumulate zombies, which
             * is exactly what the waitpid call above did. Nothing else. */
            launchd_syslog(LOG_DEBUG,
                "reaped orphan pid %d status=0x%x", (int)p, status);
            continue;
        }

        job_reap(j, status);

        /* Single-plist mode (increment 1, or `-p` without `-d`): exit
         * once the supervised singleton finishes. Daemon mode (`-d`)
         * disables this so the daemon keeps listening on the AF_UNIX
         * socket for further launchctl commands. */
        if (jobmgr_singleton_done() && jobmgr_exit_when_singleton_done()) {
            launchd_shutdown();
        }
    }
}

/* No-op handler installed for signals that drive a libdispatch source.
 * We need a non-default, non-SIG_IGN disposition so that:
 *   (a) the default action (terminate, etc.) does not fire, and
 *   (b) for SIGCHLD specifically, the kernel does NOT trigger its
 *       SIG_IGN auto-reap optimization. With SIG_IGN, FreeBSD reaps
 *       the child synchronously and never delivers SIGCHLD — which
 *       means EVFILT_SIGNAL never fires and our dispatch source
 *       waits forever. A real handler keeps the kernel queueing
 *       the signal so the dispatch source can observe it. */
static void
launchd_sig_noop(int signo)
{
    (void)signo;
}

static void
install_signal_source(int signo, dispatch_block_t handler,
    dispatch_source_t *out)
{
    /* Install no-op disposition (NOT SIG_IGN — see comment on
     * launchd_sig_noop above). EVFILT_SIGNAL / signalfd then observe
     * the queued signal and fire the dispatch source. */
    struct sigaction sa = { 0 };
    sa.sa_handler = launchd_sig_noop;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(signo, &sa, NULL);

    dispatch_source_t s = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        (uintptr_t)signo,
        0,
        main_q);
    if (!s) {
        launchd_syslog(LOG_CRIT,
            "dispatch_source_create(SIGNAL, %d) failed", signo);
        exit(1);
    }
    dispatch_source_set_event_handler(s, handler);
    dispatch_activate(s);
    *out = s;
}

void
launchd_runtime_init(void)
{
    main_q = dispatch_get_main_queue();

    /* Ignore the signals Apple's launchd ignored. None of them carry
     * meaningful semantics for the supervisor itself; they're only for
     * children, which see SIG_DFL via posix_spawnattr_setsigdefault. */
    static const int ignore[] = {
        SIGPIPE, SIGALRM, SIGURG, SIGTSTP, SIGCONT,
        SIGTTIN, SIGTTOU, SIGIO, SIGXCPU, SIGXFSZ, SIGVTALRM,
        SIGPROF, SIGWINCH, SIGUSR1, SIGUSR2,
    };
    for (size_t i = 0; i < sizeof(ignore)/sizeof(ignore[0]); i++) {
        signal(ignore[i], SIG_IGN);
    }

    install_signal_source(SIGCHLD, ^{ sigchld_handler(); },  &sigchld_src);
    install_signal_source(SIGTERM, ^{ launchd_shutdown(); }, &sigterm_src);
    install_signal_source(SIGINT,  ^{ launchd_shutdown(); }, &sigint_src);
    /* SIGHUP normally re-reads config; for increment 1 it just shuts
     * down (we have no on-disk config to re-read past the CLI plist). */
    install_signal_source(SIGHUP,  ^{ launchd_shutdown(); }, &sighup_src);
}

void
launchd_runtime(void)
{
    dispatch_main();
    /* unreachable; dispatch_main() does not return */
}
