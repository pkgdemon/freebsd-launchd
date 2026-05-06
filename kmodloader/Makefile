# kmodloader build (FreeBSD).
#
# Phase 1 minimal scope: ObjC daemon that walks the sysctl dev. tree,
# matches devices against personality plists in /System/Library/Extensions
# and /Local/Library/Extensions, and kldloads any matching kmods.
# Boot-time matching only; hot-plug via devctl(4) is Phase 2.
#
# Plan: https://pkgdemon.github.io/freebsd-kmodloader-plan.html

TOPDIR := $(abspath $(CURDIR)/..)
COMPAT := $(CURDIR)/compat
BUILD  := $(TOPDIR)/build/kmodloader

CC := clang

SYSINC := /System/Library/Headers
SYSLIB := /System/Library/Libraries

OBJCFLAGS := -fobjc-runtime=gnustep-2.2 -fobjc-arc -fblocks \
             -I$(SYSINC)/gnustep -I$(SYSINC) -I$(COMPAT) \
             -I$(CURDIR)/src \
             -O2 -Wall -Wextra -Wno-unused-parameter

LDFLAGS := -fuse-ld=lld \
           -L$(SYSLIB) \
           -ldispatch \
           -lBlocksRuntime \
           -lgnustep-base \
           -lobjc \
           -Wl,-rpath,$(SYSLIB)

SRCS_M := \
    src/main.m \
    src/KMDaemon.m \
    src/KMRegistry.m \
    src/KMDevice.m \
    src/KMBusEnumerate.m \
    src/KMMatch.m

OBJS := $(SRCS_M:%.m=$(BUILD)/%.o)
DEPS := $(OBJS:.o=.d)

PERSONALITIES_SRC := personalities
PERSONALITIES     := $(shell find $(PERSONALITIES_SRC) -name '*.plist' 2>/dev/null)

.PHONY: all
all: $(BUILD)/kmodloader
	@echo "==> kmodloader: built in $(BUILD)"

$(BUILD)/kmodloader: $(OBJS)
	@mkdir -p $(@D)
	@echo "  LD  kmodloader"
	@$(CC) -o $@ $(OBJS) $(LDFLAGS)

$(BUILD)/%.o: %.m
	@mkdir -p $(@D)
	@echo "  OBJC $(notdir $<)"
	@$(CC) $(OBJCFLAGS) -MMD -MP -c -o $@ $<

-include $(DEPS)

.PHONY: clean
clean:
	rm -rf $(BUILD)

# Daemon: /usr/libexec/kmodloader (per plan §6 install paths).
# Personality bundles: /System/Library/Extensions/<name>.kext/Contents/Info.plist
PREFIX     ?= /usr/libexec
EXT_PREFIX ?= /System/Library/Extensions
DESTDIR    ?=

.PHONY: install
install: all
	@mkdir -p $(DESTDIR)$(PREFIX)
	@install -m 755 $(BUILD)/kmodloader $(DESTDIR)$(PREFIX)/kmodloader
	@echo "==> kmodloader installed: $(DESTDIR)$(PREFIX)/kmodloader"
	@mkdir -p $(DESTDIR)$(EXT_PREFIX)
	@for plist in $(PERSONALITIES); do \
	    rel=$${plist#$(PERSONALITIES_SRC)/}; \
	    dst=$(DESTDIR)$(EXT_PREFIX)/$$rel; \
	    mkdir -p `dirname $$dst`; \
	    install -m 644 $$plist $$dst; \
	    echo "==> personality installed: $$dst"; \
	done
