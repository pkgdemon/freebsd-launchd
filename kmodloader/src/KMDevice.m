/*
 * KMDevice.m — parsed sysctl dev. entry (Phase 1).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMDevice.h"

static NSString *
NormalizeHex(NSString *raw)
{
    if (!raw) return nil;
    NSString *lower = raw.lowercaseString;
    if ([lower hasPrefix:@"0x"]) {
        lower = [lower substringFromIndex:2];
    }
    return [lower stringByPaddingToLength:4
                              withString:@"0"
                         startingAtIndex:0].uppercaseString;
}

@implementation KMDevice

- (NSString *)pciVendorID    { return NormalizeHex(self.pnpInfo[@"vendor"]); }
- (NSString *)pciDeviceID    { return NormalizeHex(self.pnpInfo[@"device"]); }
- (NSString *)pciSubvendorID { return NormalizeHex(self.pnpInfo[@"subvendor"]); }
- (NSString *)pciSubdeviceID { return NormalizeHex(self.pnpInfo[@"subdevice"]); }

@end
