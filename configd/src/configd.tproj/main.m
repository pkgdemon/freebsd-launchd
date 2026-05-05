/*
 * main.m — netconfigd daemon entry point (Phase 1 minimal).
 *
 * Sets up the autorelease pool, instantiates NCDaemon, starts it, then
 * hands control to dispatch_main() which never returns. SIGTERM /
 * SIGHUP handling is Phase 2 work via DISPATCH_SOURCE_TYPE_SIGNAL;
 * for now the daemon relies on launchd to deliver SIGTERM and reap
 * the process on shutdown.
 *
 * Apple's existing configd.tproj/configd.m (Mach-rooted server loop)
 * is in the tree alongside this file but not compiled — it gets pruned
 * + ported in Phase 2+.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import "NCDaemon.h"

int
main(int argc, const char *argv[])
{
    (void)argc; (void)argv;

    @autoreleasepool {
        NCDaemon *daemon = [[NCDaemon alloc] init];
        [daemon start];
    }

    /* Hands off to libdispatch's main queue. Future event sources
     * (PF_ROUTE, vnode on Network.plist, signals, child PROC_EXIT)
     * will fire from here; Phase 1 has no event sources installed,
     * so this just keeps the daemon alive after spawning the children.
     */
    dispatch_main();
    return 0; /* unreachable */
}
