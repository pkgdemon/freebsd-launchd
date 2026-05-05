#!/bin/sh
# make-configd.sh — build + install netconfigd from configd/ on a system
# that already has the GNUstep system domain at /System/Library/.
#
# Standalone per plan §8.8: build.sh calls this at livecd-build time,
# and downstream consumers can clone the repo and call this directly
# to drop netconfigd onto an existing /System/Library/ tree.
#
# Usage:
#   make-configd.sh [--prefix=/path]

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
		*)          echo "make-configd: unknown arg: $arg" >&2; usage ;;
	esac
done

# Hard-check the system domain. Failing the link with "library not
# found" several minutes into the build is no fun; bail early.
need_lib() {
	if [ ! -e "${DESTDIR}/System/Library/Libraries/$1" ]; then
		echo "make-configd: missing ${DESTDIR}/System/Library/Libraries/$1" >&2
		echo "make-configd: run the GNUstep system-domain build first." >&2
		exit 1
	fi
}

need_lib libdispatch.so
need_lib libobjc.so
need_lib libgnustep-base.so

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
configd_dir="$script_dir/configd"

[ -d "$configd_dir/src" ] || {
	echo "make-configd: $configd_dir/src/ not found" >&2
	exit 1
}

if ! command -v gmake >/dev/null 2>&1; then
	echo "make-configd: gmake not in PATH (install the gmake pkg)" >&2
	exit 1
fi

gmake -C "$configd_dir" install \
	DESTDIR="$DESTDIR" \
	PREFIX=/usr/libexec

echo "==> make-configd: netconfigd installed under ${DESTDIR}/usr/libexec/"
