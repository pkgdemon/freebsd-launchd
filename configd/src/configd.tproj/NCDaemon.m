/*
 * NCDaemon.m — netconfigd top-level coordinator (Phase 1 minimal).
 *
 * Mirrors the rc.conf "auto network" preset:
 *   network_interfaces="auto"          -> enumerate via getifaddrs(3)
 *   ifconfig_DEFAULT="DHCP"            -> default to dhclient
 *   synchronous_dhclient="NO" / -b     -> dhclient -b (background)
 *   ipv6_activate_all_interfaces="YES" -> ifconfig $iface inet6 accept_rtadv
 *   rtsold_enable="YES"                -> rtsold -a
 *
 * Per-interface user overrides (Phase 2+): when /Local/Library/
 * LaunchDaemons/org.freebsd.netif.<iface>.plist or org.freebsd.dhclient.
 * <iface>.plist exists, defer the iface to that plist and skip here.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 freebsd-launchd contributors.
 */

#import "NCDaemon.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_media.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <syslog.h>
#import <unistd.h>

static NSString *const kLocalLaunchDaemons = @"/Local/Library/LaunchDaemons";

@implementation NCDaemon

- (void)start {
    NSLog(@"netconfigd: starting (pid=%d)", getpid());
    [self bringUpInterfaces];
    [self startRtsold];
    NSLog(@"netconfigd: ready");
}

- (void)bringUpInterfaces {
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0) {
        NSLog(@"netconfigd: getifaddrs failed: %s", strerror(errno));
        return;
    }

    /* getifaddrs returns one entry per (iface, address-family); dedup. */
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_name == NULL) continue;
        NSString *ifname = [NSString stringWithUTF8String:ifa->ifa_name];
        if ([seen containsObject:ifname]) continue;
        [seen addObject:ifname];

        if (![self shouldHandleInterface:ifname flags:ifa->ifa_flags]) {
            continue;
        }

        if ([self interfaceHasUserOverride:ifname]) {
            NSLog(@"netconfigd: %@ has user override in /Local/Library/LaunchDaemons/, skipping", ifname);
            continue;
        }

        [self bringUpInterface:ifname];
    }
    freeifaddrs(ifaddr);
}

- (BOOL)shouldHandleInterface:(NSString *)name flags:(int)flags {
    /* Filter out interface families we don't auto-handle:
     *     lo       (loopback)
     *     tap, tun (virtual point-to-point)
     *     gif, stf (IPv6 tunnels)
     *     wlan     (needs explicit wpa_supplicant + dhclient pair)
     *     wg       (WireGuard)
     *     epair, bridge, enc, pflog, pfsync (pseudo / firewall)
     */
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[ @"lo", @"tap", @"tun", @"gif", @"stf",
                      @"wlan", @"wg", @"epair", @"bridge",
                      @"enc", @"pflog", @"pfsync" ];
    });
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return NO;
    }
    return YES;
}

- (BOOL)interfaceHasUserOverride:(NSString *)ifname {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *netifPlist = [NSString stringWithFormat:@"%@/org.freebsd.netif.%@.plist",
                            kLocalLaunchDaemons, ifname];
    NSString *dhclientPlist = [NSString stringWithFormat:@"%@/org.freebsd.dhclient.%@.plist",
                               kLocalLaunchDaemons, ifname];
    return [fm fileExistsAtPath:netifPlist] || [fm fileExistsAtPath:dhclientPlist];
}

- (void)bringUpInterface:(NSString *)ifname {
    NSLog(@"netconfigd: bringing up %@", ifname);

    /* ifconfig <iface> up */
    [self runTool:@"/sbin/ifconfig"
             args:@[ifname, @"up"]
             wait:YES];

    /* ifconfig <iface> inet6 accept_rtadv auto_linklocal */
    [self runTool:@"/sbin/ifconfig"
             args:@[ifname, @"inet6", @"accept_rtadv", @"auto_linklocal"]
             wait:YES];

    /* Skip dhclient if there's no carrier on the interface. With -b
     * dhclient is supposed to fork into the background after its first
     * DHCPDISCOVER attempt, but on a link-down interface it never sends
     * that first DISCOVER — it sits in the foreground waiting for media
     * to come up — which holds back boot. Phase 2's PF_ROUTE source
     * will start dhclient on demand when a cable is plugged in later. */
    if (![self interfaceHasLink:ifname]) {
        NSLog(@"netconfigd: %@: no carrier, skipping dhclient (Phase 2 will retry on link-up)",
              ifname);
        return;
    }

    /* dhclient -b <iface>: background after first DISCOVER attempt. */
    [self runTool:@"/sbin/dhclient"
             args:@[@"-b", ifname]
             wait:NO];
}

- (BOOL)interfaceHasLink:(NSString *)ifname {
    /* SIOCGIFMEDIA + IFM_AVALID/IFM_ACTIVE is what ifconfig(8) itself
     * uses to print "status: active" / "status: no carrier". Drivers
     * without media support (some pseudo / virtio cases) return ENOTTY;
     * we conservatively treat that as "link present" so dhclient gets
     * a chance to run. */
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) {
        NSLog(@"netconfigd: %@: socket() for media query failed: %s; assuming link",
              ifname, strerror(errno));
        return YES;
    }

    struct ifmediareq ifmr;
    memset(&ifmr, 0, sizeof(ifmr));
    strncpy(ifmr.ifm_name, ifname.UTF8String, sizeof(ifmr.ifm_name) - 1);

    int rv = ioctl(s, SIOCGIFMEDIA, &ifmr);
    close(s);

    if (rv < 0) {
        /* No media support on this iface — usually means a virtio_net or
         * pseudo device. Don't gate dhclient on this. */
        return YES;
    }
    if (!(ifmr.ifm_status & IFM_AVALID)) {
        /* Driver hasn't decided yet; let dhclient try. */
        return YES;
    }
    return (ifmr.ifm_status & IFM_ACTIVE) != 0;
}

- (void)startRtsold {
    NSLog(@"netconfigd: starting rtsold -a (IPv6 RA solicitation)");
    [self runTool:@"/usr/sbin/rtsold"
             args:@[@"-a"]
             wait:NO];
}

- (void)runTool:(NSString *)path args:(NSArray<NSString *> *)args wait:(BOOL)wait {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args;
    @try {
        [task launch];
    } @catch (NSException *exc) {
        NSLog(@"netconfigd: failed to launch %@ %@: %@",
              path, [args componentsJoinedByString:@" "], exc.reason);
        return;
    }
    if (wait) {
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            NSLog(@"netconfigd: %@ %@ exited %d",
                  path, [args componentsJoinedByString:@" "],
                  task.terminationStatus);
        }
    }
}

@end
