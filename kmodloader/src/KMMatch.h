/*
 * KMMatch.h — match a KMDevice against a KMRegistry's personalities.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import <Foundation/Foundation.h>

@class KMDevice;
@class KMRegistry;

@interface KMMatch : NSObject

/* Returns the kld name (CFBundleExecutable) of the highest-scoring
 * matching personality, or nil if no personality matches. */
+ (NSString *)bestMatchForDevice:(KMDevice *)device
                      inRegistry:(KMRegistry *)registry;

@end
