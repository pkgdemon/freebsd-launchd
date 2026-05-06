/*
 * KMRegistry.h — personality database.
 *
 * Loads .kext-style bundles from one or more directories. Each bundle's
 * Contents/Info.plist contributes its IOKitPersonalities to the registry.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>

/* Each entry in `personalities` is a flattened dict combining:
 *   "Name"             -> NSString    (the personality name within IOKitPersonalities)
 *   "Bundle"           -> NSString    (the bundle directory's basename)
 *   "CFBundleExecutable" -> NSString  (the kld name to kldload, no .ko extension)
 *   "IOMatchCategory"  -> NSString    ("PCI" / "USB" / "USBClass" / etc.)
 *   "IOPCIMatch"       -> NSArray     ("0xVENDOR:0xDEVICE" hex strings)
 *   "IOPCIClassMatch"  -> NSArray     ("class:subclass:progif")
 *   "IOUSBProductMatch"-> NSArray     ("vid:pid")
 *   "IOUSBClassMatch"  -> NSArray     ("class:subclass:protocol")
 *   "IOACPIMatch"      -> NSArray     (HID strings)
 *   "IOProbeScore"     -> NSNumber    (higher = preferred on tie)
 */
@interface KMRegistry : NSObject

@property (readonly) NSArray<NSDictionary *> *personalities;

/* Walk `dir` for *.kext subdirectories; for each, parse
 * Contents/Info.plist; flatten the IOKitPersonalities dict into the
 * registry. Logs failures via NSLog but is otherwise tolerant. */
- (void)loadFromExtensionsDir:(NSString *)dir;

@end
