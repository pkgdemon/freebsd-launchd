/*
 * KMBusEnumerate.m — sysctl dev. tree walker (Phase 1).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMBusEnumerate.h"
#import "KMDevice.h"

@implementation KMBusEnumerate

+ (NSArray<KMDevice *> *)enumerateAttachedDevices
{
    /* Run `sysctl -aN dev` to list every dev.* sysctl name. We're after
     * names ending in `.%pnpinfo` — those identify attached devices
     * with parsable PnP metadata. */
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/sysctl";
    task.arguments = @[@"-aN", @"dev"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: bus enum: sysctl -aN dev failed to launch: %@",
              exc.reason);
        return @[];
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];

    NSMutableArray<KMDevice *> *devices = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *name = [line stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (![name hasSuffix:@".%pnpinfo"]) {
            continue;
        }
        /* name format: dev.<driver>.<unit>.%pnpinfo */
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
        if (parts.count < 4) continue;
        NSString *driver = parts[1];
        NSString *unit   = parts[2];
        NSString *devName = [NSString stringWithFormat:@"%@%@", driver, unit];

        NSString *pnpRaw = [self sysctlValue:name];
        if (!pnpRaw || pnpRaw.length == 0) continue;

        NSDictionary<NSString *, NSString *> *pnp = [self parsePnpInfo:pnpRaw];
        if (pnp.count == 0) continue;

        KMDevice *dev = [[KMDevice alloc] init];
        dev.name    = devName;
        dev.driver  = driver;
        dev.pnpInfo = pnp;
        [devices addObject:dev];
    }
    return [devices copy];
}

+ (NSString *)sysctlValue:(NSString *)name
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/sysctl";
    task.arguments = @[@"-n", name];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        return nil;
    }
    if (task.terminationStatus != 0) return nil;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *raw = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
    return [raw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/* pnpinfo strings look like: "vendor=0x8086 device=0x10d3 subvendor=0x1234 ..."
 * Parse into a dict. */
+ (NSDictionary<NSString *, NSString *> *)parsePnpInfo:(NSString *)raw
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *token in [raw componentsSeparatedByCharactersInSet:ws]) {
        if (token.length == 0) continue;
        NSRange eq = [token rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [token substringToIndex:eq.location];
        NSString *val = [token substringFromIndex:eq.location + 1];
        result[key] = val;
    }
    return [result copy];
}

@end
