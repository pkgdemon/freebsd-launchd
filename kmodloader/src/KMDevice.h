/*
 * KMDevice.h — represents one entry in the sysctl dev. tree.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>

@interface KMDevice : NSObject

/* Logical device name, e.g. "em0", "ahci0", "uhci0". */
@property (copy) NSString *name;

/* Driver basename, e.g. "em" from "em0". */
@property (copy) NSString *driver;

/* Parsed pnpinfo dict. Common keys (from sysctl dev.X.Y.%pnpinfo):
 *   "vendor"      -> "0xNNNN"   PCI vendor
 *   "device"      -> "0xNNNN"   PCI device
 *   "subvendor"   -> "0xNNNN"
 *   "subdevice"   -> "0xNNNN"
 *   "class"       -> "0xNNNNNN" PCI class:subclass:progif
 * For USB devices similar fields with idVendor / idProduct keys. */
@property (copy) NSDictionary<NSString *, NSString *> *pnpInfo;

/* Convenience accessors that strip the "0x" prefix and zero-pad to 4
 * uppercase hex chars; nil if absent. Match expected format in
 * IOPCIMatch personality strings ("0x8086:0x10D3"). */
- (NSString *)pciVendorID;
- (NSString *)pciDeviceID;
- (NSString *)pciSubvendorID;
- (NSString *)pciSubdeviceID;

@end
