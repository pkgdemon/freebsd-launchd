/*
 * NCDaemon.h — netconfigd top-level coordinator.
 *
 * Phase 1 scope per freebsd-configd-plan.html §13: enumerate ethernet
 * interfaces at startup, bring each up, kick off dhclient -b -n in the
 * background per-iface, exec rtsold -a for IPv6 RA. No event sources,
 * no DO IPC, no live config reload — Phases 2+.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>

@interface NCDaemon : NSObject

/* Brings up every link-up non-virtual ethernet interface and starts
 * rtsold. Returns immediately; dispatch_main() in main.m keeps the
 * daemon alive and reaps spawned children via SIGCHLD. */
- (void)start;

@end
