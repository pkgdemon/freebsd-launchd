/*
 * KMDaemon.h — top-level coordinator for kmodloader.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>

@interface KMDaemon : NSObject

/* Phase 1 entry: load personality registry, enumerate currently-attached
 * devices, match each, kldload any unmatched-but-personality-claims. Logs
 * progress via NSLog. Returns when work is done. */
- (void)runOneShot;

@end
