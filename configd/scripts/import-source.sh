#!/bin/sh
# One-shot importer for Apple's configd source.
#
# Clones apple-oss-distributions/configd at the configd-963.270.3 tag,
# strips the .git directory, and lands the tree under configd/src/ at
# the configd subdir. The Mach/IOKit/AirPort/sim files listed in plan
# §6.1 (freebsd-configd-plan.html) are NOT removed here — that is a
# separate follow-up commit so the verbatim Apple import is preserved
# as a clean baseline in the git history.
#
# Re-running is refused if configd/src/ already exists and is
# non-empty; remove it explicitly first if you really want to redo
# the import.
#
# Mirrors the pattern of scripts/import-source.sh (which handles
# launchd's import).

set -eu

UPSTREAM_URL="https://github.com/apple-oss-distributions/configd.git"
UPSTREAM_TAG="configd-963.270.3"

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
configd_root=$(cd -- "$script_dir/.." && pwd)
dest="$configd_root/src"

if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
	echo "configd/import-source: $dest already exists and is non-empty; refusing to clobber." >&2
	echo "configd/import-source: remove it first if you really mean to re-import." >&2
	exit 1
fi

if ! command -v git >/dev/null 2>&1; then
	echo "configd/import-source: git not found in PATH." >&2
	exit 1
fi

echo "configd/import-source: cloning $UPSTREAM_URL @ $UPSTREAM_TAG into $dest"
rm -rf "$dest"
git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$dest"

upstream_sha=$(git -C "$dest" rev-parse HEAD)

rm -rf "$dest/.git"

echo "configd/import-source: imported $UPSTREAM_TAG ($upstream_sha)"
echo "configd/import-source: tree is at $dest"
echo "configd/import-source: next step — commit the verbatim import, then run the §6.1 amputation as a separate commit."
