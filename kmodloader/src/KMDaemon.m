/*
 * KMDaemon.m — top-level coordinator (Phase 1d, devmatch-driven).
 *
 * Strategy: delegate (device, kld) matching entirely to devmatch(8).
 * devmatch reads /boot/kernel/linker.hints (and the per-pkg hints in
 * /boot/modules/linker.hints), which kldxref(8) generated from each
 * driver's PNP_INFO macros. With -a it walks the live device tree and
 * emits one kld name per unattached device that has a matching driver.
 * Output is just a list of kld names — we kldload each.
 *
 * Why not Apple-shaped IOPCIMatch personality plists? They require
 * hand-maintaining (vendor:device) lists per driver — Apple ships
 * finite hardware, FreeBSD's PNP database is the size of the entire
 * driver ecosystem. Hand-curated personality plists were a Phase 1
 * stopgap; linker.hints is the authoritative source.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMDaemon.h"

#import <unistd.h>

@interface KMDaemon ()
- (NSArray<NSString *> *)kldsFromDevmatch;
- (NSSet<NSString *> *)loadedKlds;
- (BOOL)kldload:(NSString *)kld;
@end

@implementation KMDaemon

- (void)runOneShot
{
    NSLog(@"kmodloader: starting (pid=%d)", getpid());

    NSArray<NSString *> *needed = [self kldsFromDevmatch];
    NSLog(@"kmodloader: devmatch suggests %lu kld(s)", (unsigned long)needed.count);

    NSSet<NSString *> *loaded = [self loadedKlds];
    NSUInteger loadedNow = 0;

    for (NSString *kld in needed) {
        if ([loaded containsObject:kld]) {
            NSLog(@"kmodloader: %@ already loaded; skip", kld);
            continue;
        }
        if ([self kldload:kld]) {
            loadedNow++;
        }
    }

    NSLog(@"kmodloader: done (loaded-now=%lu)", (unsigned long)loadedNow);
}

/* Run `devmatch -a` and parse one-kld-per-line output. .ko suffix is
 * stripped so the names align with kldstat -v's "Contains modules:"
 * basenames and so kldload -n accepts them. */
- (NSArray<NSString *> *)kldsFromDevmatch
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/sbin/devmatch";
    task.arguments = @[@"-a"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: devmatch -a failed to launch: %@", exc.reason);
        return @[];
    }
    if (task.terminationStatus != 0) {
        NSLog(@"kmodloader: devmatch -a exited %d", task.terminationStatus);
        return @[];
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];

    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (NSString *raw in [output componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0) continue;
        if ([line hasSuffix:@".ko"]) {
            line = [line stringByDeletingPathExtension];
        }
        [result addObject:line];
    }
    return result.array;
}

/* Parse kldstat -v for the set of currently-loaded kld basenames. */
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
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
        for (NSString *field in [line componentsSeparatedByCharactersInSet:ws]) {
            if ([field hasSuffix:@".ko"]) {
                [names addObject:[field stringByDeletingPathExtension]];
            }
        }
    }
    return names;
}

- (BOOL)kldload:(NSString *)kld
{
    NSLog(@"kmodloader: loading %@", kld);
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/kldload";
    /* -n: silently succeed if already loaded (defensive against races
     *     between our pre-check and the actual load call). */
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
    NSLog(@"kmodloader: %@: loaded", kld);
    return YES;
}

@end
