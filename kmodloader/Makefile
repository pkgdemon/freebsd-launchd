# kmodloader build (FreeBSD).
#
# Phase 0 placeholder — no source files yet. Phase 1 fills in
# kmodloader/src/{main.m, KMDaemon.{h,m}, KMRegistry.{h,m},
# KMBusEnumerate.{h,m}, KMMatch.{h,m}, KMDevctlSource.{h,m}} and
# wires up the build against /System/Library/Libraries/{libdispatch,
# libgnustep-base,libobjc,libBlocksRuntime}.so — same shape as
# the launchd and netconfigd Makefiles.
#
# Phase plan: https://pkgdemon.github.io/freebsd-kmodloader-plan.html

TOPDIR := $(abspath $(CURDIR)/..)
COMPAT := $(CURDIR)/compat
BUILD  := $(TOPDIR)/build/kmodloader

.PHONY: all clean install
all:
	@echo "==> kmodloader: Phase 0 — no sources to build yet."
	@echo "    Phase 1 implementation pending; see"
	@echo "    https://pkgdemon.github.io/freebsd-kmodloader-plan.html"

clean:
	rm -rf $(BUILD)

PREFIX  ?= /usr/libexec
DESTDIR ?=

install: all
	@echo "==> kmodloader: nothing to install in Phase 0."
