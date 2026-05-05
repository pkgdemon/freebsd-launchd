#!/bin/sh
# build.sh — assemble a FreeBSD live ISO using the init_chroot architecture
# with an in-kernel unionfs + tmpfs writable overlay:
#   cd9660 = kernel root; vnode-mounted rootfs.uzip is the read-only lower;
#   tmpfs is the writable upper; in-kernel unionfs combines them; pivot
#   via init_chroot kenv (no preload, no mfsroot, no reboot -r).
# Runs on FreeBSD (host or vmactions VM). Produces out/livecd.iso.

set -eu

: "${FREEBSD_VERSION:=15.0}"
: "${COMPRESS:=zstd}"
: "${LABEL:=LIVECD}"
ARCH=${ARCH:-amd64}

# Note: no LIVE_HEADROOM in this variant. The lower UFS is sized exactly
# to content; writable headroom comes from the tmpfs upper at boot, which
# is page-allocated on demand and bounded by host RAM + swap rather than
# by a build-time constant.

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$ROOT/work
OUT=$ROOT/out
DIST=$ROOT/distfiles

MIRROR="https://download.freebsd.org/ftp/releases/${ARCH}/${FREEBSD_VERSION}-RELEASE"

mkdir -p "$WORK" "$OUT" "$DIST"

# Clean any prior partial build (but keep distfiles cached)
rm -rf "$WORK"/* "$OUT"/*

echo "==> build: FreeBSD $FREEBSD_VERSION ($ARCH), compress=$COMPRESS"

#
# 1. fetch base.txz + kernel.txz
#
for f in base.txz kernel.txz; do
    if [ ! -f "$DIST/$f" ]; then
        echo "==> downloading $f"
        fetch -o "$DIST/$f" "$MIRROR/$f"
    fi
done

#
# 2. extract into rootfs staging dir
#
echo "==> extracting base+kernel"
mkdir -p "$WORK/rootfs"
tar -xJf "$DIST/base.txz"   -C "$WORK/rootfs"
tar -xJf "$DIST/kernel.txz" -C "$WORK/rootfs"

# base.txz ships /etc/login.conf but not the compiled /etc/login.conf.db.
# Without the .db, login_getclass() can't find any class and logs a noisy
# warning at boot ("login_getclass: unknown class 'daemon'"). The FreeBSD
# installer rebuilds it via cap_mkdb during install; we have to do the
# same since we skip bsdinstall.
cap_mkdb "$WORK/rootfs/etc/login.conf"

# Same idea for the password databases. base.txz may or may not ship the
# *.db files depending on version; rebuild them to be safe so getpwnam()
# and friends work without warnings.
pwd_mkdb -p -d "$WORK/rootfs/etc" "$WORK/rootfs/etc/master.passwd"

#
# 3. install packages from pkglist.txt (skipped if empty/comments-only)
#
PKGS=$(grep -v '^[[:space:]]*#' "$ROOT/pkglist.txt" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
if [ -n "$PKGS" ]; then
    echo "==> installing packages:"
    echo "$PKGS" | sed 's/^/    /'
    cp /etc/resolv.conf "$WORK/rootfs/etc/resolv.conf"
    mount -t devfs devfs "$WORK/rootfs/dev"
    cleanup_chroot() {
        umount -f "$WORK/rootfs/dev" 2>/dev/null || true
        rm -f "$WORK/rootfs/etc/resolv.conf"
    }
    trap cleanup_chroot EXIT INT TERM
    chroot "$WORK/rootfs" env ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes pkg bootstrap -f
    # shellcheck disable=SC2086
    chroot "$WORK/rootfs" env ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes pkg install -y $PKGS
    cleanup_chroot
    trap - EXIT INT TERM
else
    echo "==> pkglist.txt empty; skipping pkg install"
fi

#
# 4. trim rootfs of things not needed at runtime
#
echo "==> slimming rootfs"
rm -rf \
    "$WORK/rootfs/usr/share/man" \
    "$WORK/rootfs/usr/share/doc" \
    "$WORK/rootfs/usr/share/info" \
    "$WORK/rootfs/usr/share/locale" \
    "$WORK/rootfs/usr/share/games" \
    "$WORK/rootfs/usr/share/examples" \
    "$WORK/rootfs/usr/share/openssl" \
    "$WORK/rootfs/usr/share/dict" \
    "$WORK/rootfs/usr/share/calendar" \
    "$WORK/rootfs/usr/include" \
    "$WORK/rootfs/usr/tests" \
    "$WORK/rootfs/usr/lib/debug" \
    "$WORK/rootfs/usr/libdata/lint" \
    "$WORK/rootfs/var/db/etcupdate"
find "$WORK/rootfs/boot/kernel" -name '*.symbols' -delete 2>/dev/null || true

#
# 5. apply local overlays (etc/rc.conf, etc/rc.local, ...)
#
if [ -d "$ROOT/overlays" ]; then
    echo "==> applying overlays"
    cp -aR "$ROOT/overlays/." "$WORK/rootfs/"
fi

# rc.local needs to be executable
[ -f "$WORK/rootfs/etc/rc.local" ] && chmod +x "$WORK/rootfs/etc/rc.local"

#
# 6. minimal /etc/fstab; root mounted by unionfs at boot, no entries needed
#
cat > "$WORK/rootfs/etc/fstab" <<'EOF'
# Live system: root is the unionfs merged view (read-only UFS lower +
# tmpfs upper, layered in the ramdisk-style init phase and then exposed
# as / via init_chroot).
EOF

#
# 7. makefs UFS without an explicit -s. The writable upper is tmpfs at
#    boot, so the lower UFS doesn't need user-visible headroom -- only
#    enough room for UFS internal overhead (cylinder groups, inode
#    tables, default ~8% minfree). makefs auto-computes that when -s
#    is omitted; passing a tight -s trips its bsize rounding logic.
#    mkuzip then compresses; output goes into the cdroot.
#
CONTENT_BYTES=$(du -sk "$WORK/rootfs" | awk '{print $1*1024}')
echo "==> rootfs content = $CONTENT_BYTES bytes ($((CONTENT_BYTES / 1024 / 1024)) MiB)"

echo "==> makefs ffs (auto-sized)"
makefs -t ffs -o version=2,label=ROOTFS \
    "$WORK/rootfs.ufs" "$WORK/rootfs"
ls -lh "$WORK/rootfs.ufs"

mkdir -p "$WORK/cdroot"
case "$COMPRESS" in
    zstd) MKUZIP_FLAGS="-A zstd -C 19 -d -s 262144" ;;
    zlib) MKUZIP_FLAGS="-d -s 65536" ;;
    *)    echo "ERROR: unknown COMPRESS=$COMPRESS"; exit 1 ;;
esac
echo "==> mkuzip $MKUZIP_FLAGS"
mkuzip $MKUZIP_FLAGS -j "$(sysctl -n hw.ncpu)" \
    -o "$WORK/cdroot/rootfs.uzip" "$WORK/rootfs.ufs"

# Stage the init environment on the cd9660 root. The kernel mounts cd9660
# as / and runs /sbin/init from there, which then runs /init.sh which uses
# tools from /rescue. unionfs is in-kernel and rescue's mount_unionfs is
# statically linked — no dynamic /sbin/geom + libs needed (unlike the
# gunion variant).
echo "==> staging init environment on cd9660"
mkdir -p "$WORK/cdroot/sbin" "$WORK/cdroot/rescue" "$WORK/cdroot/sysroot" \
         "$WORK/cdroot/upper" "$WORK/cdroot/dev" "$WORK/cdroot/etc"

# /rescue: statically-linked busybox-equivalent. Provides sh, mdconfig,
# mount, mount_unionfs, kldload, kenv, sleep, echo, cat, halt, etc.
# Self-contained.
#
# CRITICAL: /rescue uses hardlinks aggressively -- every tool name is a
# hardlink to the same crunchgen binary, so the real disk footprint is
# ~14 MB even though there are ~200 entries. FreeBSD's `cp -a` does NOT
# preserve hardlinks (unlike GNU cp), so a naive cp turns every hardlink
# into a full file copy -> 2.8 GB explosion. Use a tar pipe which does
# preserve hardlinks.
( cd "$WORK/rootfs" && tar cf - rescue ) | ( cd "$WORK/cdroot" && tar xf - )

# /sbin/init -> /rescue/init. /rescue/init is statically linked.
ln -sf /rescue/init "$WORK/cdroot/sbin/init"

# Ship /etc/login.conf (+ compiled .db) on the cd9660 root.
# Without this, login_getclass() called early in boot -- before the
# init_chroot pivot fully takes effect for the calling process -- sees
# cd9660's empty /etc and logs a noisy warning:
#   init - - login_getclass: unknown class 'daemon'
# GhostBSD's livecd hits the same issue and ships login.conf in their
# ramdisk for the same reason. lib/libutil/login_cap.c:349 emits the
# warning; it goes away as soon as login.conf is reachable.
cp "$WORK/rootfs/etc/login.conf" "$WORK/cdroot/etc/login.conf"
[ -f "$WORK/rootfs/etc/login.conf.db" ] && \
    cp "$WORK/rootfs/etc/login.conf.db" "$WORK/cdroot/etc/login.conf.db"

# pivot script
cp "$ROOT/ramdisk/init.sh" "$WORK/cdroot/init.sh"
chmod +x "$WORK/cdroot/init.sh"

ls -lh "$WORK/cdroot/rootfs.uzip"

#
# 8. stage /boot on the cd9660 carrier — but ONLY the loader-needed bits.
#    Linux livecds ship just the kernel + initramfs on iso9660 (~60 MB
#    total) and put all kernel modules inside the squashfs. We do the
#    same: copy the kernel binary (gzipped) plus the few modules the
#    loader will preload + a handful of likely-auto-loaded ones. The
#    other ~80 modules stay only in rootfs.uzip; the running system
#    kldloads them from there post-chroot.
#
echo "==> staging minimal /boot on cd9660"
mkdir -p "$WORK/cdroot/boot/kernel"

# Bootloader pieces (whichever exist; vary by FreeBSD release/arch)
for f in cdboot loader loader.efi loader_lua loader_lua.efi \
         loader_simp loader_simp.efi pmbr isoboot boot1.efi \
         gptboot defaults device.hints lua fonts; do
    if [ -e "$WORK/rootfs/boot/$f" ]; then
        cp -aR "$WORK/rootfs/boot/$f" "$WORK/cdroot/boot/"
    fi
done

# Kernel binary, gzipped so the loader unpacks it on read. Save as
# kernel.gz (with .gz extension) -- the loader's gzipfs layer detects
# the extension and decompresses transparently. Same pattern mfsBSD uses.
gzip -9c "$WORK/rootfs/boot/kernel/kernel" > "$WORK/cdroot/boot/kernel/kernel.gz"
ls -lh "$WORK/cdroot/boot/kernel/kernel.gz" \
       "$WORK/rootfs/boot/kernel/kernel"

# Modules: only what we need at boot.
#   * geom_uzip / unionfs — explicitly loaded via loader.conf for the pivot
#   * acpi, ahci, virtio_blk, virtio_pci, ahci/scsi_da/cd — typically
#     auto-loaded by the kernel for storage in qemu/real hardware. Some
#     are built into GENERIC, but ship them anyway in case the user
#     boots a kernel without them.
BOOT_MODULES="geom_uzip.ko unionfs.ko \
              acpi.ko \
              virtio.ko virtio_pci.ko virtio_blk.ko virtio_scsi.ko \
              ahci.ko mfi.ko"
for m in $BOOT_MODULES; do
    if [ -f "$WORK/rootfs/boot/kernel/$m" ]; then
        cp "$WORK/rootfs/boot/kernel/$m" "$WORK/cdroot/boot/kernel/"
    fi
done

cp "$ROOT/boot/loader.conf" "$WORK/cdroot/boot/loader.conf"

echo "==> /boot on cd9660:"
du -sh "$WORK/cdroot/boot" "$WORK/cdroot/boot/kernel" || true
ls -la "$WORK/cdroot/boot/kernel/" || true

#
# 9. EFI System Partition (FAT16, /EFI/BOOT/BOOTX64.EFI inside) and a copy
#    of the EFI loader at the cd9660 root for OVMF's ISO9660 discovery.
#
echo "==> building EFI System Partition"
ESP="$WORK/efi.img"
ESPROOT="$WORK/efi-staging"
mkdir -p "$ESPROOT/EFI/BOOT"
if [ -f "$WORK/rootfs/boot/loader_lua.efi" ]; then
    EFI_LOADER="$WORK/rootfs/boot/loader_lua.efi"
elif [ -f "$WORK/rootfs/boot/loader.efi" ]; then
    EFI_LOADER="$WORK/rootfs/boot/loader.efi"
else
    echo "ERROR: no loader.efi found in base.txz boot/"
    exit 1
fi
echo "==> EFI loader: $EFI_LOADER"
cp "$EFI_LOADER" "$ESPROOT/EFI/BOOT/BOOTX64.EFI"
makefs -t msdos -s 32m -o fat_type=16,sectors_per_cluster=1 \
    "$ESP" "$ESPROOT"
mkdir -p "$WORK/cdroot/EFI/BOOT"
cp "$EFI_LOADER" "$WORK/cdroot/EFI/BOOT/BOOTX64.EFI"

#
# 10. final cd9660 (hybrid BIOS + UEFI El Torito)
#
echo "==> building ISO"
BOOTABLE_ARGS=""
if [ -f "$WORK/cdroot/boot/cdboot" ]; then
    BOOTABLE_ARGS="-o bootimage=i386;$WORK/cdroot/boot/cdboot -o no-emul-boot"
fi
BOOTABLE_ARGS="$BOOTABLE_ARGS -o bootimage=i386;$ESP -o no-emul-boot -o platformid=efi"

# shellcheck disable=SC2086
makefs -D -N "$WORK/rootfs/etc" -t cd9660 \
    -o rockridge -o label="$LABEL" \
    $BOOTABLE_ARGS \
    "$OUT/livecd.iso" "$WORK/cdroot"

ls -lh "$OUT/livecd.iso"
sha256 "$OUT/livecd.iso" 2>/dev/null || sha256sum "$OUT/livecd.iso"

echo
echo "==> cdroot size breakdown:"
du -sh "$WORK/cdroot"/* 2>/dev/null | sort -h
echo
echo "==> ISO total: $(ls -lh "$OUT/livecd.iso" | awk '{print $5}')"
echo "==> DONE"
