/*
 * KMDaemon.m — top-level coordinator (Phase 1).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMDaemon.h"
#import "KMRegistry.h"
#import "KMDevice.h"
#import "KMBusEnumerate.h"
#import "KMMatch.h"

#import <unistd.h>

static NSString *const kSystemExtensions = @"/System/Library/Extensions";
static NSString *const kLocalExtensions  = @"/Local/Library/Extensions";

@implementation KMDaemon

- (void)runOneShot
{
    NSLog(@"kmodloader: starting (pid=%d)", getpid());

    KMRegistry *registry = [[KMRegistry alloc] init];
    [registry loadFromExtensionsDir:kSystemExtensions];
    [registry loadFromExtensionsDir:kLocalExtensions];
    NSLog(@"kmodloader: loaded %lu personalities",
          (unsigned long)registry.personalities.count);

    NSArray<KMDevice *> *devices = [KMBusEnumerate enumerateAttachedDevices];
    NSLog(@"kmodloader: enumerated %lu devices via sysctl dev.",
          (unsigned long)devices.count);

    NSSet<NSString *> *loaded = [self loadedKlds];
    NSUInteger matched = 0;
    NSUInteger loadedNow = 0;

    for (KMDevice *device in devices) {
        NSString *kld = [KMMatch bestMatchForDevice:device inRegistry:registry];
        if (!kld) {
            continue;
        }
        matched++;
        if ([loaded containsObject:kld]) {
            NSLog(@"kmodloader: %@: matched %@ but already loaded; skip",
                  device.name, kld);
            continue;
        }
        NSLog(@"kmodloader: %@ (vendor=%@ device=%@): matched %@, loading",
              device.name,
              device.pciVendorID ?: @"-",
              device.pciDeviceID ?: @"-",
              kld);
        if ([self kldload:kld]) {
            loadedNow++;
        }
    }

    NSLog(@"kmodloader: done (matched=%lu, loaded-now=%lu)",
          (unsigned long)matched, (unsigned long)loadedNow);
}

/* Returns the set of currently-loaded kld names (without .ko extension).
 * Parses kldstat -v output. */
- (NSSet<NSString *> *)loadedKlds
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/kldstat";
    task.arguments = @[@"-v"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: kldstat failed: %@", exc.reason);
        return [NSSet set];
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    /* kldstat -v lines look like:
     *  Id Refs Address                Size Name
     *   1  ...                            kernel
     *  ...
     *  10    1 ...                  1234 if_em.ko
     * Plus indented "Contains modules:" subsections with one module
     * per line. We grab the .ko filenames, strip extension. */
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        NSArray<NSString *> *fields = [trimmed componentsSeparatedByCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
        for (NSString *field in fields) {
            if ([field hasSuffix:@".ko"]) {
                NSString *base = [field stringByDeletingPathExtension];
                [names addObject:base];
            }
        }
    }
    return names;
}

- (BOOL)kldload:(NSString *)kld
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/kldload";
    /* -n: don't error if already loaded (defensive — we already
     *     filtered, but races are possible). */
    task.arguments = @[@"-n", kld];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: kldload %@ failed to launch: %@", kld, exc.reason);
        return NO;
    }
    if (task.terminationStatus != 0) {
        NSLog(@"kmodloader: kldload %@ exited %d", kld, task.terminationStatus);
        return NO;
    }
    NSLog(@"kmodloader: %@: loaded successfully", kld);
    return YES;
}

@end
