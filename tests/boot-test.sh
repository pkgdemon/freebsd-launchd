#!/bin/sh
# boot-test.sh — boot the live ISO in qemu and confirm the system reaches
# multi-user mode by watching for /etc/rc's "Starting local daemons:"
# marker on the serial console. That single marker proves the entire
# pipeline worked: loader → kernel → cd9660 root mount → init →
# init.sh's gunion + init_chroot pivot → multi-user boot in the chroot.

set -eu

ISO=${1:?usage: boot-test.sh path/to/livecd.iso}

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found"
    exit 1
fi

mkdir -p tests
LOG=tests/boot.log
EXP=tests/boot.exp

echo "==> boot test: $ISO"
ls -lh "$ISO"

# Pick acceleration. KVM if available; TCG fallback.
if [ -e /dev/kvm ]; then
    sudo chmod 666 /dev/kvm 2>/dev/null || true
fi
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_FLAGS="-accel kvm -cpu host"
    echo "==> using KVM acceleration"
else
    ACCEL_FLAGS="-accel tcg,thread=single -cpu qemu64"
    echo "==> using TCG (single-thread)"
fi

# Find OVMF firmware
OVMF=""
for f in /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF.fd \
         /usr/share/qemu/OVMF.fd; do
    if [ -f "$f" ]; then
        OVMF="$f"
        break
    fi
done
if [ -z "$OVMF" ]; then
    echo "ERROR: no OVMF firmware found"
    exit 1
fi
echo "==> using UEFI firmware: $OVMF"

export ACCEL_FLAGS OVMF

cat > "$EXP" <<'EOF'
set timeout 480
log_file -a tests/boot.log
log_user 1

set iso [lindex $argv 0]
set accel_flags [split $env(ACCEL_FLAGS) " "]

eval spawn qemu-system-x86_64 \
    -m 4G \
    -machine q35 \
    -bios $env(OVMF) \
    $accel_flags \
    -cdrom $iso -boot d \
    -display none -serial stdio \
    -no-reboot

# Single test: wait for the getty "login:" prompt on the serial console.
# This is the strongest boot-success marker FreeBSD emits -- by the time
# getty prints "login:", every prior stage has succeeded: loader, kernel,
# cd9660 mount, init.sh, gunion overlay, init_chroot pivot, all of /etc/rc,
# all rc.d services, and getty has come up and is accepting users.
#
# (Earlier we tried "Starting local daemons:" but that banner only prints
# if /etc/rc.local exists; we removed rc.local for a clean live-system
# experience, so the banner is gone too.)
expect {
    timeout {
        puts "\nFAIL: 'login:' prompt not seen within 8 minutes"
        exit 1
    }
    "login:" { puts "\nOK: boot reached the login prompt" }
}

close
wait
exit 0
EOF

expect "$EXP" "$ISO"
echo "==> boot-test PASSED"
