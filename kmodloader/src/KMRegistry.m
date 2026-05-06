/*
 * KMRegistry.m — personality database (Phase 1).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMRegistry.h"

@interface KMRegistry ()
@property (strong) NSMutableArray<NSDictionary *> *mutablePersonalities;
@end

@implementation KMRegistry

- (instancetype)init
{
    if ((self = [super init])) {
        _mutablePersonalities = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSDictionary *> *)personalities
{
    return [self.mutablePersonalities copy];
}

- (void)loadFromExtensionsDir:(NSString *)dir
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir)) {
        NSLog(@"kmodloader: registry: %@ does not exist, skipping", dir);
        return;
    }

    NSError *err = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:&err];
    if (!entries) {
        NSLog(@"kmodloader: registry: %@: %@",
              dir, err.localizedDescription ?: @"unknown error");
        return;
    }

    for (NSString *entry in entries) {
        if (![entry hasSuffix:@".kext"]) {
            continue;
        }
        NSString *bundle = [dir stringByAppendingPathComponent:entry];
        NSString *plistPath = [bundle stringByAppendingPathComponent:@"Contents/Info.plist"];
        if (![fm fileExistsAtPath:plistPath]) {
            NSLog(@"kmodloader: registry: %@ has no Contents/Info.plist; skipping",
                  bundle);
            continue;
        }

        NSData *data = [NSData dataWithContentsOfFile:plistPath];
        if (!data) {
            NSLog(@"kmodloader: registry: failed to read %@", plistPath);
            continue;
        }

        NSError *plistErr = nil;
        id parsed = [NSPropertyListSerialization
                     propertyListWithData:data
                                  options:NSPropertyListImmutable
                                   format:NULL
                                    error:&plistErr];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            NSLog(@"kmodloader: registry: %@: %@",
                  plistPath,
                  plistErr.localizedDescription ?: @"not a plist dict");
            continue;
        }

        NSDictionary *info = (NSDictionary *)parsed;
        NSString *kldName = info[@"CFBundleExecutable"];
        NSDictionary *iokitPers = info[@"IOKitPersonalities"];
        if (![iokitPers isKindOfClass:[NSDictionary class]] || !kldName) {
            NSLog(@"kmodloader: registry: %@ missing CFBundleExecutable or IOKitPersonalities; skipping",
                  bundle);
            continue;
        }

        for (NSString *persName in iokitPers) {
            id pers = iokitPers[persName];
            if (![pers isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSMutableDictionary *flat = [(NSDictionary *)pers mutableCopy];
            flat[@"Name"]               = persName;
            flat[@"Bundle"]              = entry;
            flat[@"CFBundleExecutable"]  = kldName;
            [self.mutablePersonalities addObject:[flat copy]];
        }
    }

    NSLog(@"kmodloader: registry: loaded %@ (%lu personalities total)",
          dir, (unsigned long)self.mutablePersonalities.count);
}

@end
