/*
 * KMMatch.m — Apple-style probe-score matching (Phase 1).
 *
 * Scores:
 *   exact PCI vendor:device         100 + IOProbeScore
 *   PCI class match (e.g. all USB)   50 + IOProbeScore
 *   USB VID:PID                     100 + IOProbeScore
 *   USB class:subclass:protocol      50 + IOProbeScore
 *
 * Ties broken by registry insertion order (first wins).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMMatch.h"
#import "KMDevice.h"
#import "KMRegistry.h"

@implementation KMMatch

+ (NSString *)bestMatchForDevice:(KMDevice *)device
                      inRegistry:(KMRegistry *)registry
{
    NSInteger bestScore = -1;
    NSString *bestKld = nil;

    for (NSDictionary *pers in registry.personalities) {
        NSInteger score = [self scorePersonality:pers forDevice:device];
        if (score < 0) continue;
        if (score > bestScore) {
            bestScore = score;
            bestKld = pers[@"CFBundleExecutable"];
        }
        /* Equal score: first wins (registry insertion order). */
    }
    return bestKld;
}

+ (NSInteger)scorePersonality:(NSDictionary *)pers forDevice:(KMDevice *)device
{
    NSInteger probe = [pers[@"IOProbeScore"] integerValue];
    NSString *category = pers[@"IOMatchCategory"];

    /* PCI exact-match: IOPCIMatch is array of "vendor:device" hex strings,
     * optionally with subvendor:subdevice trailing. */
    NSArray *pciMatch = pers[@"IOPCIMatch"];
    if ([pciMatch isKindOfClass:[NSArray class]]) {
        if ([self pciDevice:device matchesAny:pciMatch]) {
            return 100 + probe;
        }
    }

    /* PCI class match: array of "class:subclass:progif" hex strings. */
    NSArray *pciClass = pers[@"IOPCIClassMatch"];
    if ([pciClass isKindOfClass:[NSArray class]]) {
        if ([self pciDevice:device matchesClass:pciClass]) {
            return 50 + probe;
        }
    }

    (void)category;  /* USB / ACPI matchers are Phase 1c work. */
    return -1;
}

+ (BOOL)pciDevice:(KMDevice *)dev matchesAny:(NSArray *)patterns
{
    NSString *vendor = dev.pciVendorID;
    NSString *device = dev.pciDeviceID;
    if (!vendor || !device) return NO;
    NSString *needleShort = [NSString stringWithFormat:@"0x%@:0x%@", vendor, device];
    /* Long form with subvendor:subdevice is less common; users may write
     * either. Compare uppercase to be tolerant. */
    NSString *up = needleShort.uppercaseString;
    for (id pat in patterns) {
        if (![pat isKindOfClass:[NSString class]]) continue;
        NSString *p = ((NSString *)pat).uppercaseString;
        /* Patterns may be "0xVVVV:0xDDDD" or
         * "0xVVVV:0xDDDD:0xSVSV:0xSDSD". For Phase 1, only check
         * the leading vendor:device pair. */
        if ([p hasPrefix:up]) return YES;
    }
    return NO;
}

+ (BOOL)pciDevice:(KMDevice *)dev matchesClass:(NSArray *)patterns
{
    NSString *cls = dev.pnpInfo[@"class"];
    if (!cls) return NO;
    NSString *up = cls.uppercaseString;
    for (id pat in patterns) {
        if (![pat isKindOfClass:[NSString class]]) continue;
        NSString *p = ((NSString *)pat).uppercaseString;
        if ([up containsString:p]) return YES;
    }
    return NO;
}

@end
