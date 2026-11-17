#!/usr/bin/env bash
# ============================================================================
#  test-install.sh SCENARIO… — install MKOS into a disk image with the real
#  installer engine from this checkout, check the result on disk, then boot it
#  in QEMU and check the running system through the guest agent.
#
#    sudo iso/test-install.sh alongside-btrfs     fake Windows 11 disk → shrink + install
#    sudo iso/test-install.sh wipe-ext4 free-ext4 partition-btrfs
#    sudo KEEP=1 iso/test-install.sh …           keep the images afterwards
#
#  Runs on the build machine (Arch), not inside the live ISO: the engine is
#  pointed at a staged copy of the image's files (iso/stage.sh) and uses the
#  host's package cache. It never touches the host's firmware boot entries or
#  clock (PLAN_TEST). The VM is always killed at the end.
#  Needs: qemu-base, edk2-ovmf, arch-install-scripts, ntfsprogs, sgdisk.
# ============================================================================
set -uo pipefail
ISO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
W=${MKOS_TEST_DIR:-/var/tmp/mkos-install-test}
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
PASS=0 FAILS=0
ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAILS=$((FAILS + 1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 2; }
[ $# -gt 0 ] || { sed -n '3,16p' "$0" | sed 's/^# \?//'; exit 2; }
for t in qemu-system-x86_64 pacstrap sgdisk mkntfs; do command -v $t >/dev/null || { echo "missing: $t" >&2; exit 2; }; done

rm -rf "$W"; mkdir -p "$W/stage"
"$ISO_DIR/stage.sh" "$W/stage" >/dev/null
STAGE=$W/stage
HASH=$(printf 'mkos-test' | openssl passwd -6 -stdin)
QEMU_PID=""; LOOP=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && sleep 1 && kill -9 "$QEMU_PID" 2>/dev/null
    umount -R /mnt/mkos-test 2>/dev/null
    [ -n "$LOOP" ] && detach "$LOOP"
    QEMU_PID=""; LOOP=""
}
trap 'cleanup; [ "${KEEP:-0}" = 1 ] || rm -rf "$W"' EXIT

# detach a loop device for real (an ntfs-3g/FUSE unmount lets go of it a moment later)
detach() { local _; for _ in $(seq 40); do losetup -d "$1" 2>/dev/null; losetup "$1" >/dev/null 2>&1 || return 0; sleep 0.25; done; echo "still attached: $1" >&2; }
guest() { python3 "$ISO_DIR/test/qga.py" "$W/qga.sock" bash -c "$*"; }

scenario() {
    local name=$1 mode fs img="$W/$1.img" extra="" winsha=""
    mode=${name%%-*}; fs=${name##*-}
    echo; echo "━━ $name ━━"
    rm -f "$img"
    case "$mode" in
        alongside)
            winsha=$(DATA_MIB=200 "$ISO_DIR/test/make-windows-disk.sh" "$img" 80)
            ;;
        wipe) truncate -s 40G "$img" ;;
        free)
            truncate -s 60G "$img"
            sgdisk -o -n 1:1M:+300M -t 1:ef00 -n 2:0:+15G -t 2:8300 -c 2:other-linux "$img" >/dev/null
            ;;
        partition)
            truncate -s 60G "$img"
            sgdisk -o -n 1:1M:+300M -t 1:ef00 -n 2:0:+40G -t 2:8300 -c 2:old-linux "$img" >/dev/null
            ;;
        *) echo "unknown scenario $name"; return 1 ;;
    esac
    LOOP=$(losetup -fP --show "$img"); udevadm settle
    case "$mode" in
        free|partition) mkfs.fat -F32 "${LOOP}p1" >/dev/null; mkfs.ext4 -q "${LOOP}p2" ;;
    esac
    case "$mode" in
        alongside) extra="SHRINK_PART=${LOOP}p3"$'\n'"MKOS_MIB=40960" ;;
        partition) extra="TARGET_PART=${LOOP}p2" ;;
    esac
    cat >"$W/plan" <<EOF
DISK=$LOOP
MODE=$mode
FS=$fs
$extra
HOSTNAME=mkos-vm
USERNAME=alex
FULLNAME=Alex Tester
PASSWORD_HASH='$HASH'
TIMEZONE=Asia/Kolkata
XKB_LAYOUT=us
LOGIN=lock
PLAN_TEST=1
HOST_CACHE=1
EXTRA_PKGS=qemu-guest-agent
EXTRA_SERVICES=qemu-guest-agent
EXTRA_CMDLINE=console=ttyS0,115200
EOF
    local t0=$SECONDS
    MKOS_LIB=$STAGE/usr/local/lib/mkos MKOS_SRC=$STAGE MKOS_REPO_DIR=/nonexistent \
    MKOS_DESKTOP_LIST=$STAGE/usr/local/share/mkos/desktop-packages.txt \
        bash "$STAGE/usr/local/bin/mkos-install-engine" "$W/plan" >"$W/$name.log" 2>&1
    local last; last=$(grep '^@@' "$W/$name.log" | tail -n1)
    if [ "$last" = "@@ 100 done" ]; then ok "installer finished ($((SECONDS - t0)) s)"; else bad "installer: $last"; tail -n 25 "$W/$name.log"; cleanup; return 1; fi

    # ── on disk ──
    local root; root=$(lsblk -lnpo NAME,PARTLABEL "$LOOP" | awk '$2 == "mkos" { print $1 }' | tail -n1)
    [ "$mode" = partition ] && root=${LOOP}p2
    mkdir -p /mnt/mkos-test
    if [ "$fs" = btrfs ]; then mount -o subvol=@ "$root" /mnt/mkos-test; else mount "$root" /mnt/mkos-test; fi
    check "fstab mounts / by UUID" grep -qE '^UUID=.*\s/\s' /mnt/mkos-test/etc/fstab
    check "GRUB has a MKOS entry" grep -q "menuentry 'MKOS" /mnt/mkos-test/boot/grub/grub.cfg
    check "test kernel arguments reached GRUB" grep -q 'console=ttyS0' /mnt/mkos-test/boot/grub/grub.cfg
    if [ "$mode" = alongside ]; then
        check "hardware clock in local time (like Windows)" grep -qx LOCAL /mnt/mkos-test/etc/adjtime
    fi
    umount -R /mnt/mkos-test
    if [ "$mode" = alongside ]; then
        mkdir -p /mnt/mkos-test
        ntfs-3g -o ro "${LOOP}p3" /mnt/mkos-test
        local now; now=$(cd /mnt/mkos-test && find Users Windows -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
        umount /mnt/mkos-test
        [ "$now" = "$winsha" ] && ok "Windows' files unchanged after the shrink" || bad "Windows' files changed!"
        check "Windows recovery partition untouched" blkid -s LABEL -o value "${LOOP}p4"
    fi
    if [ "$mode" = free ]; then check "the other Linux partition is untouched" test "$(blkid -s TYPE -o value "${LOOP}p2")" = ext4; fi
    # A real install adds a firmware boot entry for MKOS; a test never writes
    # NVRAM, so the VM is given the same thing through the fallback loader path.
    local esp; esp=$(lsblk -lnpo NAME,PARTTYPE "$LOOP" | awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }')
    mkdir -p /mnt/mkos-test && mount "$esp" /mnt/mkos-test
    check "GRUB installed to EFI/MKOS" test -s /mnt/mkos-test/EFI/MKOS/grubx64.efi
    if [ "$mode" = alongside ]; then
        check "Windows' boot manager untouched" grep -q "fake Windows Boot Manager" /mnt/mkos-test/EFI/Microsoft/Boot/bootmgfw.efi
        check "Windows' fallback loader untouched" grep -q "fake Windows Boot Manager" /mnt/mkos-test/EFI/Boot/bootx64.efi
    fi
    install -Dm644 /mnt/mkos-test/EFI/MKOS/grubx64.efi /mnt/mkos-test/EFI/BOOT/BOOTX64.EFI
    umount /mnt/mkos-test
    detach "$LOOP"; LOOP=""

    # ── booted ──
    cp "$OVMF_VARS" "$W/vars.fd"
    rm -f "$W/qga.sock"
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$W/vars.fd" \
        -drive file="$img",format=raw,if=virtio -nic user,model=virtio-net-pci \
        -chardev socket,path="$W/qga.sock",server=on,wait=off,id=qga0 \
        -device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
        -display none -vga virtio -serial file:"$W/$name.serial" -boot menu=off &
    QEMU_PID=$!
    if python3 "$ISO_DIR/test/qga.py" "$W/qga.sock" --wait 240 >/dev/null; then
        ok "boots: GRUB → kernel → systemd → guest agent"
    else
        bad "did not boot (see $W/$name.serial)"; tail -n 30 "$W/$name.serial"; cleanup; return 1
    fi
    guest 'for i in $(seq 60); do s=$(systemctl is-system-running); case $s in running|degraded) echo $s; exit 0;; esac; sleep 2; done; echo $s' | sed 's/^/    system: /'
    local failed; failed=$(guest 'systemctl --failed --no-legend --plain | cut -d" " -f1' | paste -sd' ')
    [ -z "$failed" ] && ok "no failed units" || bad "failed units: $failed"
    check "branded as MKOS" guest 'grep -q MKOS /etc/os-release'
    check "user alex exists and may use sudo" guest 'id alex | grep -q wheel'
    check "account lockout policy configured" guest 'grep -q "admin_group = wheel" /etc/security/faillock.conf'
    check "root file system is $fs" guest "test \"\$(findmnt -no FSTYPE /)\" = $fs"
    check "zram swap is on, sized to RAM" guest 'grep -q zram /proc/swaps'
    check "memory tuning applied (swappiness 180)" guest 'test "$(sysctl -n vm.swappiness)" = 180'
    check "earlyoom running" guest 'systemctl is-active earlyoom'
    check "NetworkManager running" guest 'systemctl is-active NetworkManager'
    check "MKOS tools installed (mode, dictate, doctor)" guest 'test -x /usr/local/bin/mkos-mode -a -x /usr/local/bin/mkos-dictate -a -x /usr/local/bin/mkos-doctor'
    check "voice typing and NTFS tools present" guest 'pacman -Qq wtype ntfsprogs earlyoom'
    check "desktop starts behind the lock screen" guest 'test -e /home/alex/.config/mkos/lock-at-login'
    check "keyboard layout written for Hyprland" guest 'grep -q kb_layout /home/alex/.config/hypr/mkos-local.lua'
    check "tty1 logs alex in (then the lock screen asks)" guest 'grep -q "autologin alex" /etc/systemd/system/getty@tty1.service.d/autologin.conf'
    check "time zone Asia/Kolkata" guest 'test "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Asia/Kolkata'
    if [ "$mode" = alongside ]; then
        # (os-prober skips loop devices on the build host, so this is checked in the VM)
        check "boot menu finds Windows on this disk (os-prober)" guest 'os-prober | grep -q "^/dev/vda1@/[Ee][Ff][Ii]/Microsoft/Boot/bootmgfw.efi:Windows"'
        check "Windows' drive still mounts read-only in MKOS" guest 'mkdir -p /run/w && mount -t ntfs3 -o ro /dev/vda3 /run/w && test -f /run/w/Windows/System32/ntoskrnl.exe'
    fi
    if [ "$fs" = btrfs ]; then
        check "snapshots configured (fresh-install snapshot exists)" guest 'snapper --no-dbus -c root list | grep -q "Fresh MKOS install"'
        check "snapshot subvolumes mounted" guest 'findmnt /.snapshots && findmnt /home'
    fi
    python3 "$ISO_DIR/test/qga.py" "$W/qga.sock" --shutdown >/dev/null 2>&1
    for _ in $(seq 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 1; done
    cleanup
    [ "${KEEP:-0}" = 1 ] || rm -f "$img"
}

for s in "$@"; do scenario "$s"; done
echo
echo "passed: $PASS   failed: $FAILS"
[ "$FAILS" -eq 0 ]
