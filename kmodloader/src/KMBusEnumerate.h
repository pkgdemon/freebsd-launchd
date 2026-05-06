/*
 * KMBusEnumerate.h — walks the sysctl dev. tree, returns KMDevice list.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>
@class KMDevice;

@interface KMBusEnumerate : NSObject

/* Returns one KMDevice per entry in the kernel's dev tree that has
 * a parsable %pnpinfo. Phase 2 will switch this to a libdevinfo walk
 * (more complete; reports unattached devices too); Phase 1 uses the
 * simpler sysctl shell-out which sees only attached devices. */
+ (NSArray<KMDevice *> *)enumerateAttachedDevices;

@end
