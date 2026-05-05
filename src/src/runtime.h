/*
 * runtime.h — libdispatch-based event loop for the new launchd.
 *
 * Phase 2 increment 1: signal sources only (SIGCHLD, SIGTERM, SIGINT).
 * Subsequent increments add the AF_UNIX listening source (increment 2),
 * KeepAlive throttle timers (increment 3), Sockets activation READ
 * sources (increment 4), and the WatchPaths VNODE sources (increment 4
 * BSD-only).
 */
#ifndef LAUNCHD_RUNTIME_H
#define LAUNCHD_RUNTIME_H

#include <dispatch/dispatch.h>
#include <stdbool.h>

/* Initialize the dispatch sources (SIGCHLD reaping, SIGTERM shutdown).
 * Call once before launchd_runtime(). */
void launchd_runtime_init(void);

/* Hand off to dispatch_main(). Does not return. */
void launchd_runtime(void);

/* Mark the daemon as shutting down. Triggers exit from dispatch_main()
 * after the next event drain. */
void launchd_shutdown(void);

/* Return the main dispatch queue. */
dispatch_queue_t launchd_main_queue(void);

#endif /* LAUNCHD_RUNTIME_H */
