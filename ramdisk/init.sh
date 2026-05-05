#!/rescue/sh
# /init.sh — boot pivot script. Runs in one of two modes:
#
# (a) PID 1 mode (Option D, plan §9.2 revised):
#     loader.conf init_path=/init.sh causes the kernel to exec us
#     directly via the shebang above. /rescue/sh becomes PID 1 with
#     this script as argv[1]. After the unionfs pivot we hand PID 1
#     to launchd via `exec /rescue/chroot /sysroot /sbin/launchd`,
#     preserving PID across the exec chain.
#
# (b) Fallback mode (kernel rejected /init.sh, tried /rescue/init next):
#     /rescue/init runs as PID 1 and reads init_script=/init.sh kenv
#     to invoke us as its child. After the unionfs pivot we set
#     init_chroot=/sysroot kenv and exit; /rescue/init does the chroot
#     and continues normal multi-user boot (FreeBSD init's runcom +
#     /etc/rc, no launchd).
#
# Detection: $$ == 1 iff PID 1 mode.
#
# Memory cost: ~50 MB at idle (decompressed pages of accessed uzip data
# only). Writable upper is tmpfs, page-allocated on demand, no fixed
# size — apparent free space scales with host RAM.

set -eu
PATH=/rescue
export PATH

# Phase 3d debug — print PID + mode so the CI boot log shows which
# branch fired. Remove these once Option D is empirically settled.
echo ">>> /init.sh: starting (pid=$$, mode=$([ "$$" = "1" ] && echo PID1 || echo CHILD))"

# Phase 3d debug — leave stdout/stderr connected to console so CI's
# boot.log captures every step. Re-silence once Option D is green.
# (Original line: exec 1>/dev/null 2>&1)

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

# Branch on whether we're PID 1 or init's child.
if [ "$$" = "1" ]; then
    # Option D: we're PID 1. Hand off to launchd by chroot+exec. exec
    # replaces this shell with /rescue/chroot (preserving PID 1), which
    # chroots and execs /sbin/launchd (still PID 1). launchd inherits.
    echo ">>> /init.sh: handing PID 1 to /sbin/launchd via /rescue/chroot"
    exec /rescue/chroot /sysroot /sbin/launchd
fi
echo ">>> /init.sh: child mode, setting init_chroot kenv and exiting"

# Fallback path: we're a child of /rescue/init via init_script. Set
# kenv for /rescue/init's chroot, then exit. init.c reads init_chroot
# at line 333, AFTER the script runs (lines 326-331), so a kenv set
# here is honored.
kenv init_chroot=/sysroot

# Unset init_script so init doesn't try to re-run us after the chroot.
# (init only reads init_script once at startup, but unset for cleanliness.)
kenv -u init_script 2>/dev/null || true
kenv -u init_shell  2>/dev/null || true

exit 0
