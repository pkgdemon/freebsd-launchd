# netconfigd build (FreeBSD).
#
# Phase 1 minimal scope: compile main.m + NCDaemon.m into a netconfigd
# binary linking against /System/Library/Libraries/{libdispatch,
# libgnustep-base,libobjc,libBlocksRuntime}.so. No DO server yet (Phase 3),
# no PF_ROUTE source yet (Phase 2). Just a daemon that reads
# /Local/Library/Preferences/Network.plist (or auto-everything if absent),
# spawns dhclient on every link-up ethernet, exec's rtsold for IPv6 RA,
# and sits in dispatch_main().
#
# Apple's existing configd.tproj source files (configd.m, _config*.c,
# _notify*.c, _SCD.c, etc.) sit in the tree alongside our new files but
# are not compiled in this phase. They get pruned + ported in Phase 2+.

TOPDIR := $(abspath $(CURDIR)/..)
COMPAT := $(CURDIR)/compat
BUILD  := $(TOPDIR)/build/configd

CC := clang

SYSINC := /System/Library/Headers
SYSLIB := /System/Library/Libraries

# core.m-style ObjC build; same flags pattern as the launchd Makefile.
OBJCFLAGS := -fobjc-runtime=gnustep-2.2 -fobjc-arc -fblocks \
             -I$(SYSINC)/gnustep -I$(SYSINC) -I$(COMPAT) \
             -O2 -Wall -Wextra -Wno-unused-parameter

LDFLAGS := -fuse-ld=lld \
           -L$(SYSLIB) \
           -ldispatch \
           -lBlocksRuntime \
           -lgnustep-base \
           -lobjc \
           -Wl,-rpath,$(SYSLIB)

SRCS_M := \
    src/configd.tproj/main.m \
    src/configd.tproj/NCDaemon.m

OBJS := $(SRCS_M:%.m=$(BUILD)/%.o)
DEPS := $(OBJS:.o=.d)

.PHONY: all
all: $(BUILD)/netconfigd
	@echo "==> netconfigd: built in $(BUILD)"

$(BUILD)/netconfigd: $(OBJS)
	@mkdir -p $(@D)
	@echo "  LD  netconfigd"
	@$(CC) -o $@ $(OBJS) $(LDFLAGS)

$(BUILD)/%.o: %.m
	@mkdir -p $(@D)
	@echo "  OBJC $(notdir $<)"
	@$(CC) $(OBJCFLAGS) -MMD -MP -c -o $@ $<

-include $(DEPS)

.PHONY: clean
clean:
	rm -rf $(BUILD)

# Plan §4 places netconfigd in /usr/libexec — daemon not invoked
# directly by users.
PREFIX  ?= /usr/libexec
DESTDIR ?=

.PHONY: install
install: all
	@mkdir -p $(DESTDIR)$(PREFIX)
	@install -m 755 $(BUILD)/netconfigd $(DESTDIR)$(PREFIX)/netconfigd
	@echo "==> netconfigd installed: $(DESTDIR)$(PREFIX)/netconfigd"
