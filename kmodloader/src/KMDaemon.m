/*
 * KMDaemon.m — top-level coordinator (Phase 1e).
 *
 * Two parallel match paths feed one kldload loop:
 *
 * 1. devmatch(8) — covers any in-tree FreeBSD driver that declares
 *    PNP_INFO. Reads /boot/kernel/linker.hints (and the per-pkg
 *    /boot/modules/linker.hints), walks the live device tree, emits
 *    kld names for unattached devices that have a registered driver.
 *    No flag — bare `devmatch` outputs basename per line.
 *
 * 2. GPU vendor scan — covers drm-kmod GPU drivers (i915kms, amdgpu,
 *    radeonkms) and the nvidia binary blob, none of which declare
 *    PNP_INFO. Reads pciconf -l for class=0x0300xx (display
 *    controllers), extracts vendor field, maps three stable PCI-SIG
 *    vendor IDs to the appropriate kld set:
 *      0x8086 → i915kms
 *      0x1002 → amdgpu, radeonkms (drivers self-select by device)
 *      0x10de → nvidia-drm
 *    No device-ID curation needed; the drivers themselves know which
 *    devices they support and skip non-matching ones.
 *
 * Loaded klds are deduped and the GPU drivers run first so the
 * framebuffer / drmn0 is up before peripheral drivers attach.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "KMDaemon.h"

#import <unistd.h>

@interface KMDaemon ()
- (NSArray<NSString *> *)kldsFromDevmatch;
- (NSSet<NSString *> *)gpuVendorIDs;
- (NSArray<NSString *> *)gpuKldsForVendors:(NSSet<NSString *> *)vendors;
- (NSSet<NSString *> *)loadedKlds;
- (BOOL)kldload:(NSString *)kld;
@end

@implementation KMDaemon

- (void)runOneShot
{
    NSLog(@"kmodloader: starting (pid=%d)", getpid());

    NSSet<NSString *> *gpuVendors = [self gpuVendorIDs];
    NSArray<NSString *> *gpuKlds = [self gpuKldsForVendors:gpuVendors];
    NSLog(@"kmodloader: GPU vendors %@ → %lu kld(s)",
          gpuVendors.allObjects, (unsigned long)gpuKlds.count);

    NSArray<NSString *> *devmatchKlds = [self kldsFromDevmatch];
    NSLog(@"kmodloader: devmatch suggests %lu kld(s)",
          (unsigned long)devmatchKlds.count);

    /* GPU first — once the framebuffer is owned by a DRM driver, peripheral
     * driver loads can't visibly disrupt it. Then the devmatch set. */
    NSMutableOrderedSet<NSString *> *plan = [NSMutableOrderedSet orderedSet];
    [plan addObjectsFromArray:gpuKlds];
    [plan addObjectsFromArray:devmatchKlds];

    NSSet<NSString *> *loaded = [self loadedKlds];
    NSUInteger loadedNow = 0;
    for (NSString *kld in plan) {
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

/* Bare `devmatch` (no flag): output is one kld basename per line for
 * every enabled-but-unattached device that has a registered driver
 * in linker.hints. Strip a .ko suffix defensively (recent versions
 * don't include it but we shouldn't break if a future one does).
 *
 * NOT `devmatch -a`: that flag prints "devname: kld" for every
 * enabled device including already-attached — wrong shape entirely. */
- (NSArray<NSString *> *)kldsFromDevmatch
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/devmatch";
    task.arguments = @[];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: devmatch failed to launch: %@", exc.reason);
        return @[];
    }
    if (task.terminationStatus != 0) {
        NSLog(@"kmodloader: devmatch exited %d", task.terminationStatus);
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

/* Walk pciconf -l for display-controller PCI devices (class 0x0300xx)
 * and return the unique set of vendor IDs as lowercase "0xNNNN"
 * strings. Multi-GPU systems (Intel iGPU + Nvidia dGPU is common on
 * laptops) yield multiple vendors; non-GPU systems return empty. */
- (NSSet<NSString *> *)gpuVendorIDs
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/sbin/pciconf";
    task.arguments = @[@"-l"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exc) {
        NSLog(@"kmodloader: pciconf failed to launch: %@", exc.reason);
        return [NSSet set];
    }
    if (task.terminationStatus != 0) {
        NSLog(@"kmodloader: pciconf exited %d", task.terminationStatus);
        return [NSSet set];
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];

    NSMutableSet<NSString *> *vendors = [NSMutableSet set];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        /* Only display-class devices: PCI class 0x0300xx covers VGA
         * controllers (0x030000), 8514 (0x030001), XGA (0x030010),
         * and 3D controllers (0x030200). Match the 0x0300 prefix. */
        if ([line rangeOfString:@"class=0x0300"].location == NSNotFound) {
            continue;
        }
        NSRange r = [line rangeOfString:@"vendor=0x"];
        if (r.location == NSNotFound) continue;
        NSUInteger start = NSMaxRange(r);
        if (start + 4 > line.length) continue;
        NSString *hex = [[line substringWithRange:NSMakeRange(start, 4)]
                         lowercaseString];
        [vendors addObject:[NSString stringWithFormat:@"0x%@", hex]];
    }
    return vendors;
}

- (NSArray<NSString *> *)gpuKldsForVendors:(NSSet<NSString *> *)vendors
{
    NSMutableArray<NSString *> *r = [NSMutableArray array];
    if ([vendors containsObject:@"0x8086"]) {
        /* Intel: i915kms covers Broadwell onward; older Intel iGPUs
         * are unsupported by drm-kmod and fall back to vgapci/efifb. */
        [r addObject:@"i915kms"];
    }
    if ([vendors containsObject:@"0x1002"]) {
        /* AMD: load both. amdgpu claims GCN 1.1+ (HD 7790, R7 260+,
         * Polaris, Vega, Navi); radeonkms claims pre-GCN-1.1
         * (TeraScale through HD 7000). Only one will attach for any
         * given device; the other sits idle. */
        [r addObject:@"amdgpu"];
        [r addObject:@"radeonkms"];
    }
    if ([vendors containsObject:@"0x10de"]) {
        /* NVIDIA: nvidia-drm depends on nvidia-modeset which depends
         * on nvidia, so kldload of nvidia-drm pulls the chain via
         * MODULE_DEPEND. Note: requires hw.nvidiadrm.modeset=1 set
         * in /boot/loader.conf before this loads (kenv-time tunable). */
        [r addObject:@"nvidia-drm"];
    }
    return r;
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
