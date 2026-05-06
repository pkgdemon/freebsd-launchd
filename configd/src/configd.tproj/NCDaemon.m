/*
 * NCDaemon.m — netconfigd top-level coordinator (placeholder).
 *
 * Phase 1's auto-network role (DHCPv4/v6 + RA/SLAAC + link-state +
 * hot-plug) moved to dhcpcd, run directly by launchd via
 * org.freebsd.dhcpcd.plist. dhcpcd in master mode handles everything
 * NCDaemon was attempting (and more — DHCPv6, RDNSS/DNSSL, IPv4LL,
 * link-up recovery, lagg/vlan/bridge layering recognition).
 *
 * netconfigd's role going forward (Phase 2+) is higher-level: a
 * SystemConfiguration-like dynamic store and DO IPC server that other
 * components query for current network state, plus a watcher on
 * /Local/Library/Preferences/Network.plist for declarative overrides
 * to dhcpcd.conf. None of that is built yet; this binary is currently
 * a stub that logs and exits.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "NCDaemon.h"

#import <unistd.h>

@implementation NCDaemon

- (void)start {
    NSLog(@"netconfigd: Phase 1 placeholder (pid=%d)", getpid());
    NSLog(@"netconfigd: network auto-config is dhcpcd's job; "
          @"this stub exits cleanly until Phase 2");
}

@end
