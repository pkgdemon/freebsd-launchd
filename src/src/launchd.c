/*
 * launchd.c — daemon main (Phase 2 increments 1 + 2 + 3 + 5).
 *
 * CLI:
 *   launchd                          PID 1 mode: scan default dirs,
 *                                    start IPC server, never exit.
 *                                    (Same as `-d -S /System/Library/LaunchDaemons
 *                                    -S /Library/LaunchDaemons` plus
 *                                    PID-1-specific behaviors.)
 *   launchd -f -p <plist>            foreground; load + spawn one job;
 *                                    exit when reaped (legacy increment-1)
 *   launchd -f -d                    foreground daemon; AF_UNIX socket;
 *                                    never self-exits (increment 2)
 *   launchd -f -d -p <plist>         daemon + preload one plist
 *   launchd -f -d -S <dir> [-S ...]  daemon + scan directory(ies) at start
 *   launchd -h                       help
 *
 * Default IPC socket: /tmp/launchd-<pid>.sock for non-PID-1, and
 * /var/run/launchd/sock when PID 1. Set LAUNCHD_SOCKET to override.
 *
 * Apple's original ~660-line src/launchd.c is preserved at git
 * 0d37c19 (the launchd-842.1.4 import) for reference.
 */

#include "core.h"
#include "ipc.h"
#include "log.h"
#include "runtime.h"

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_SCAN_DIRS 8

static const char *default_scan_dirs[] = {
    "/System/Library/LaunchDaemons",
    "/Library/LaunchDaemons",
    NULL,
};

static void
usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s                                       (PID 1 mode)\n"
        "       %s -f -p <plist-path>\n"
        "       %s -f -d [-p <plist>] [-S <dir>] ...\n"
        "       %s -h\n"
        "\n"
        "  -f             run in foreground; log to stderr\n"
        "  -d             daemon mode: AF_UNIX socket for launchctl\n"
        "  -p <path>      load and spawn this plist at startup\n"
        "  -S <dir>       scan dir for *.plist at startup (repeatable)\n"
        "  -h             show this help\n"
        "\n"
        "With no flags, runs as PID 1: scans /System/Library/LaunchDaemons\n"
        "and /Library/LaunchDaemons, opens the IPC socket, never exits.\n",
        argv0, argv0, argv0, argv0);
}

int
main(int argc, char *argv[])
{
    int foreground = 0;
    int daemon_mode = 0;
    const char *plist = NULL;
    const char *scan_dirs[MAX_SCAN_DIRS] = { 0 };
    size_t      n_scan_dirs = 0;

    int ch;
    while ((ch = getopt(argc, argv, "fdp:S:h")) != -1) {
        switch (ch) {
        case 'f': foreground = 1; break;
        case 'd': daemon_mode = 1; break;
        case 'p': plist = optarg; break;
        case 'S':
            if (n_scan_dirs >= MAX_SCAN_DIRS) {
                fprintf(stderr, "%s: too many -S dirs (max %d)\n",
                    argv[0], MAX_SCAN_DIRS);
                return 2;
            }
            scan_dirs[n_scan_dirs++] = optarg;
            break;
        case 'h':
        default:
            usage(argv[0]);
            return ch == 'h' ? 0 : 2;
        }
    }

    /* No arguments at all: PID 1 mode. */
    bool pid1_mode = (argc == 1);
    if (pid1_mode) {
        foreground = 1;       /* no daemonize() — we ARE init */
        daemon_mode = 1;      /* always run the IPC server */
        for (size_t i = 0; default_scan_dirs[i] && n_scan_dirs < MAX_SCAN_DIRS; i++) {
            scan_dirs[n_scan_dirs++] = default_scan_dirs[i];
        }
    }

    if (!foreground) {
        fprintf(stderr, "%s: -f is required (or run with no args for PID 1)\n",
            argv[0]);
        usage(argv[0]);
        return 2;
    }
    if (!daemon_mode && !plist) {
        fprintf(stderr,
            "%s: must specify either -d (daemon mode) or -p <plist>\n",
            argv[0]);
        usage(argv[0]);
        return 2;
    }

    launchd_log_init(foreground);
    launchd_syslog(LOG_NOTICE,
        "starting (pid=%d pid1_mode=%d daemon=%d plist=%s scan_dirs=%zu)",
        (int)getpid(), pid1_mode, daemon_mode,
        plist ? plist : "(none)", n_scan_dirs);

    /* Set up dispatch sources first so SIGCHLD-during-load gets caught. */
    launchd_runtime_init();

    /* `-p plist`: legacy single-plist mode. Marked as the singleton so
     * the daemon exits when it's reaped (in non-daemon-mode only). */
    if (plist) {
        Job *j = jobmgr_load_plist_file(plist);
        if (!j) {
            launchd_syslog(LOG_CRIT, "failed to load plist: %s", plist);
            return 1;
        }
        if (jobmgr_insert(j) != 0) {
            launchd_syslog(LOG_CRIT, "%s: insert into job table failed",
                j->label);
            jobmgr_free(j);
            return 1;
        }
        jobmgr_set_singleton(j);
        if (j->run_at_load && !j->disabled) {
            if (job_spawn(j) != 0) {
                launchd_syslog(LOG_CRIT, "%s: spawn failed", j->label);
                return 1;
            }
        }
    }

    /* `-S dir`: scan dirs for plists. Failure to load any one plist is
     * non-fatal — under PID 1 we can't let one bad plist prevent boot. */
    size_t total_loaded = 0;
    for (size_t i = 0; i < n_scan_dirs; i++) {
        total_loaded += jobmgr_load_plist_dir(scan_dirs[i]);
    }
    if (n_scan_dirs > 0) {
        launchd_syslog(LOG_NOTICE, "scan complete: %zu plists loaded across %zu dirs",
            total_loaded, n_scan_dirs);
    }

    if (daemon_mode) {
        jobmgr_set_exit_when_singleton_done(false);
        if (ipc_server_init(NULL) != 0) {
            launchd_syslog(LOG_CRIT, "ipc_server_init failed");
            return 1;
        }
        launchd_syslog(LOG_NOTICE,
            "listening on %s (set LAUNCHD_SOCKET=this-path for launchctl)",
            ipc_server_path());
    }

    /* Hand off to dispatch_main(); does not return. */
    launchd_runtime();
    return 0;  /* unreachable */
}
