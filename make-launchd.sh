#!/bin/sh
# make-launchd.sh — build + install launchd from src/ on a system that
# already has the GNUstep system domain at /System/Library/.
#
# Standalone per plan §8.8: build.sh calls this at livecd-build time,
# and downstream consumers (e.g. gershwin-on-freebsd's chroot) can
# clone the repo and call this directly to drop launchd onto an
# existing /System/Library/ tree.
#
# Usage:
#   make-launchd.sh [--prefix=/path]
#
# --prefix targets a chroot install (DESTDIR). Default empty (host).

set -eu

DESTDIR=""

usage() {
	echo "usage: $0 [--prefix=PATH]" >&2
	exit 64
}

for arg in "$@"; do
	case "$arg" in
		--prefix=*) DESTDIR="${arg#--prefix=}" ;;
		--help|-h)  usage ;;
		*)          echo "make-launchd: unknown arg: $arg" >&2; usage ;;
	esac
done

# Hard-check the system domain. Failing the link with "library not
# found" several minutes into a compile is no fun; bail early with a
# message that names the missing thing and how to fix it.
need_lib() {
	if [ ! -e "${DESTDIR}/System/Library/Libraries/$1" ]; then
		echo "make-launchd: missing ${DESTDIR}/System/Library/Libraries/$1" >&2
		echo "make-launchd: run the GNUstep system-domain build first." >&2
		exit 1
	fi
}

need_lib libdispatch.so
need_lib libobjc.so
need_lib libgnustep-base.so
need_lib libgnustep-corebase.so

# Locate the launchd source relative to this script. The repo layout
# puts src/ as a sibling of make-launchd.sh, so a clone of the repo
# Just Works regardless of where it lives on disk.
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
src_dir="$script_dir/src"

[ -d "$src_dir/src" ] || {
	echo "make-launchd: $src_dir/src/ not found — wrong script location?" >&2
	exit 1
}

# Prefer the buildpkgs-installed gmake; FreeBSD's base make doesn't
# understand the GNU-make-isms in src/Makefile.
if ! command -v gmake >/dev/null 2>&1; then
	echo "make-launchd: gmake not in PATH (install the gmake pkg)" >&2
	exit 1
fi

gmake -C "$src_dir" install \
	DESTDIR="$DESTDIR" \
	PREFIX=/sbin

echo "==> make-launchd: launchd + launchctl installed under ${DESTDIR}/sbin/"
