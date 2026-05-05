# launchd build (FreeBSD).
#
# Compiles src/{launchd,runtime,ipc,ipc_proto,log}.c + core.m against
# the system domain at /System/Library/ (libdispatch + libobjc2 +
# libgnustep-base + libgnustep-corebase). Produces two binaries:
# launchd (the daemon) + launchctl (the tiny client).
#
# Driven by ../make-launchd.sh; can also be run directly with `gmake`
# on a host that already has /System/Library/ populated.

TOPDIR := $(abspath $(CURDIR)/..)
COMPAT := $(TOPDIR)/compat
BUILD  := $(TOPDIR)/build/launchd

CC := clang

# /System/Library/Headers carries libdispatch (dispatch/, os/, Block.h),
# libobjc2 (objc/), and the GNUstep CoreFoundation + Foundation headers.
SYSINC := /System/Library/Headers
SYSLIB := /System/Library/Libraries

CFLAGS := -O2 -std=gnu11 \
          -Wall -Wextra \
          -Wno-unused-parameter \
          -fblocks \
          -I$(COMPAT) \
          -I$(SYSINC)

# core.m uses NSPropertyListSerialization (Foundation / Obj-C). ARC for
# autoreleasepool / object lifecycle; -fblocks for libdispatch APIs and
# ARC; -fobjc-runtime=gnustep-2.2 to match the runtime libobjc2 advertises.
OBJCFLAGS := -fobjc-runtime=gnustep-2.2 -fobjc-arc -fblocks \
             -I$(SYSINC)/gnustep -I$(SYSINC) -I$(COMPAT) \
             -O2 -Wall -Wextra -Wno-unused-parameter

# -lBlocksRuntime resolves _Block_object_assign / _Block_object_dispose
# emitted by the compiler for ^{} block literals. -Wl,-rpath embeds the
# system-domain path so binaries find their libs without env help.
LDFLAGS := -fuse-ld=lld \
           -L$(SYSLIB) \
           -ldispatch \
           -lBlocksRuntime \
           -lgnustep-corebase \
           -lgnustep-base \
           -lobjc \
           -Wl,-rpath,$(SYSLIB)

SRCS_C := \
    src/launchd.c \
    src/runtime.c \
    src/ipc.c \
    src/ipc_proto.c \
    src/log.c
SRCS_M := \
    src/core.m

OBJS := $(SRCS_C:%.c=$(BUILD)/%.o) $(SRCS_M:%.m=$(BUILD)/%.o)
DEPS := $(OBJS:.o=.d)

# launchctl is a separate, much smaller binary linking just the
# framed-message I/O helpers from ipc_proto.c. No libdispatch or
# Foundation deps — launchctl stays a tiny portable client.
LAUNCHCTL_SRCS := support/launchctl.c src/ipc_proto.c
LAUNCHCTL_OBJS := $(LAUNCHCTL_SRCS:%.c=$(BUILD)/%.o)

LAUNCHCTL_LDFLAGS := -fuse-ld=lld

.PHONY: all
all: $(BUILD)/launchd $(BUILD)/launchctl
	@echo "==> launchd: 2 binaries built in $(BUILD) (launchd, launchctl)"

$(BUILD)/launchd: $(OBJS)
	@mkdir -p $(@D)
	@echo "  LD  launchd"
	@$(CC) -o $@ $(OBJS) $(LDFLAGS)

$(BUILD)/launchctl: $(LAUNCHCTL_OBJS)
	@mkdir -p $(@D)
	@echo "  LD  launchctl"
	@$(CC) -o $@ $(LAUNCHCTL_OBJS) $(LAUNCHCTL_LDFLAGS)

$(BUILD)/%.o: %.c
	@mkdir -p $(@D)
	@echo "  CC  $(notdir $<)"
	@$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

$(BUILD)/%.o: %.m
	@mkdir -p $(@D)
	@echo "  OBJC $(notdir $<)"
	@$(CC) $(OBJCFLAGS) -MMD -MP -c -o $@ $<

-include $(DEPS)

.PHONY: clean
clean:
	rm -rf $(BUILD)

# Plan §4 places launchd + launchctl in /sbin: PID 1 must live on the
# root partition, and launchctl needs to work in single-user before
# /usr/local mounts.
PREFIX  ?= /sbin
DESTDIR ?=

.PHONY: install
install: all
	@mkdir -p $(DESTDIR)$(PREFIX)
	@install -m 755 $(BUILD)/launchd   $(DESTDIR)$(PREFIX)/launchd
	@install -m 755 $(BUILD)/launchctl $(DESTDIR)$(PREFIX)/launchctl
	@echo "==> launchd installed: $(DESTDIR)$(PREFIX)/{launchd,launchctl}"
