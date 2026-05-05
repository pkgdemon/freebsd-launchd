#!/rescue/sh
# /init.sh — runs as a child of /sbin/init via init_script kenv.
#
# This script lives at the root of the cd9660 ISO. The kernel mounts
# cd9660 as /, init runs from /sbin/init (FreeBSD's real init binary from
# base.txz), reads init_script=/init.sh kenv, forks, and execs us.
#
# We set up an in-kernel unionfs overlay (read-only uzip lower + tmpfs
# writable upper) at /sysroot, then write init_chroot=/sysroot kenv and
# exit. After we exit, init proceeds to read init_chroot at init.c:333
# and chroots into /sysroot before continuing normal multi-user boot.
# cd9660 stays mounted as the kernel's actual root; userland sees
# /sysroot as /.
#
# Memory cost: ~50 MB at idle (decompressed pages of accessed uzip data
# only). Writable upper is tmpfs, page-allocated on demand, no fixed
# size — apparent free space scales with host RAM.

set -eu
PATH=/rescue
export PATH

# Silence diagnostic output. End users shouldn't see init.sh's internals
# during boot. If something fails, set -e bubbles up and init drops to
# single-user where the user can investigate.
exec 1>/dev/null 2>&1

# Defensive module loads (also requested in /boot/loader.conf, but be safe
# in case someone built a kernel without the loader.conf entries).
kldload geom_uzip 2>/dev/null || true
kldload unionfs 2>/dev/null || true

# Vnode-mount the compressed rootfs from the cd9660. /rootfs.uzip is at
# the root of the cd9660 (placed there by build.sh). geom_uzip auto-tastes
# /dev/md0 and produces /dev/md0.uzip.
mdconfig -a -t vnode -o readonly -f /rootfs.uzip -u 0

# Wait for the uzip taste to complete
i=0
while [ ! -e /dev/md0.uzip ]; do
    sleep 1
    i=$((i+1))
    if [ "$i" -gt 30 ]; then
        ls -la /dev/md* 2>/dev/null || true
        halt -p
    fi
done

# Mount the read-only lower at /sysroot (the merge target). /sysroot
# exists as an empty directory on the cd9660 — we can't mkdir it here
# because cd9660 is read-only at runtime.
mount -t ufs -o ro /dev/md0.uzip /sysroot

# Mount tmpfs as the writable upper. tmpfs has no fixed size — pages
# allocate on demand from the VM subsystem and spill to swap under
# memory pressure (semantically identical to Linux tmpfs). The /upper
# mountpoint is also pre-created on the cd9660 by build.sh.
mount -t tmpfs tmpfs /upper

# Layer the tmpfs upper on top of the read-only lower via in-kernel
# unionfs. After this mount, /sysroot is the merged writable view:
# reads fall through to the lower, writes are captured in the upper.
mount -t unionfs /upper /sysroot

# devfs in the chroot
mount -t devfs devfs /sysroot/dev

# Tell init to chroot into /sysroot after we exit. init.c reads
# init_chroot kenv at line 333, which is AFTER the script runs
# (line 326-331), so a kenv set here will be honored.
kenv init_chroot=/sysroot

# Unset init_script so init doesn't try to re-run us after the chroot.
# (init only reads init_script once at startup, but unset for cleanliness.)
kenv -u init_script 2>/dev/null || true
kenv -u init_shell  2>/dev/null || true

exit 0
