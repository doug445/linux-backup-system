#!/usr/bin/env bash
#
# linux-backup-system — restore-verified multi-layer Linux backups for every distro and boot layout
# https://github.com/doug445/linux-backup-system
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# tests/lib-fixture-test.sh — backup-common.sh against synthetic inputs.
#
# Exercises the shared library's detection and policy functions: distro-family
# mapping from synthetic os-release files (including derivatives that resolve
# through ID_LIKE), the command->package map, the per-family install command,
# config loading and defaults, the free-space predicates and the wrong-drive
# guard. No disk, no root, no network — pure logic, so it runs everywhere.
# shellcheck disable=SC2034  # variables set here are read by the sourced library functions
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../backup-common.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
expect() { # expect DESC EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== distro family from os-release"
osrel() { printf 'ID=%s\nID_LIKE="%s"\n' "$1" "$2" > "$T/os-release"; BX_OS_RELEASE="$T/os-release" bx_distro_family; }
expect "fedora"                         fedora  "$(osrel fedora '')"
expect "fedora-asahi-remix via ID_LIKE" fedora  "$(osrel fedora-asahi-remix 'fedora')"
expect "nobara via ID_LIKE"             fedora  "$(osrel nobara 'fedora')"
expect "rhel"                           fedora  "$(osrel rhel 'fedora')"
expect "debian"                         debian  "$(osrel debian '')"
expect "ubuntu"                         debian  "$(osrel ubuntu 'debian')"
expect "linuxmint via ID_LIKE"          debian  "$(osrel linuxmint 'ubuntu debian')"
expect "pop"                            debian  "$(osrel pop 'ubuntu debian')"
expect "arch"                           arch    "$(osrel arch '')"
expect "manjaro"                        arch    "$(osrel manjaro 'arch')"
expect "endeavouros"                    arch    "$(osrel endeavouros 'arch')"
expect "cachyos via ID_LIKE"            arch    "$(osrel cachyos 'arch')"
expect "opensuse-tumbleweed via ID_LIKE" suse   "$(osrel opensuse-tumbleweed 'opensuse suse')"
expect "sles"                           suse    "$(osrel sles '')"
expect "alpine is unknown"              unknown "$(osrel alpine '')"
expect "void is unknown"                unknown "$(osrel void '')"
expect "missing os-release is unknown"  unknown "$(BX_OS_RELEASE=$T/nope bx_distro_family)"
# A family name must never match as a substring of another token.
expect "'archlinux-ish' token does not match arch" unknown "$(osrel notarch '')"

echo "== command -> package"
expect "borg on debian"   borgbackup  "$(bx_pkg_for borg debian)"
expect "borg on fedora"   borgbackup  "$(bx_pkg_for borg fedora)"
expect "borg on arch"     borg        "$(bx_pkg_for borg arch)"
expect "btrfs"            btrfs-progs "$(bx_pkg_for btrfs debian)"
expect "mkfs.btrfs"       btrfs-progs "$(bx_pkg_for mkfs.btrfs arch)"
expect "bootctl"          systemd     "$(bx_pkg_for bootctl fedora)"
expect "findmnt"          util-linux  "$(bx_pkg_for findmnt debian)"
expect "awk"              gawk        "$(bx_pkg_for awk fedora)"
expect "timeshift"        timeshift   "$(bx_pkg_for timeshift debian)"
expect "rsync passthrough" rsync      "$(bx_pkg_for rsync debian)"
expect "sfdisk"           util-linux  "$(bx_pkg_for sfdisk debian)"
expect "udevadm"          systemd     "$(bx_pkg_for udevadm arch)"
expect "snapper"          snapper     "$(bx_pkg_for snapper fedora)"
expect "mount.ecryptfs"   ecryptfs-utils "$(bx_pkg_for mount.ecryptfs debian)"
expect "backintime debian" "backintime-common backintime-qt" "$(bx_pkg_for backintime debian)"
expect "backintime fedora" backintime-qt "$(bx_pkg_for backintime fedora)"
expect "backintime suse"   backintime-qt "$(bx_pkg_for backintime suse)"
expect "backintime arch"   backintime   "$(bx_pkg_for backintime arch)"

echo "== install command per family"
icmd() { printf 'ID=%s\n' "$1" > "$T/os-release"; BX_OS_RELEASE="$T/os-release" bx_pkg_install_cmd; }
expect "debian"  "apt-get update -qq && apt-get install -y" "$(icmd debian)"
expect "fedora"  "dnf install -y"                           "$(icmd fedora)"
expect "arch"    "pacman -S --noconfirm --needed"           "$(icmd arch)"
expect "suse"    "zypper --non-interactive install"         "$(icmd opensuse-leap)"
expect "unknown family gives empty command" ""             "$(icmd alpine)"

echo "== bx_ensure_deps"
out=$(bx_ensure_deps bash sh 2>&1); expect "all present short-circuits" 0 "$?"
case "$out" in *"all present"*) ok "reports all present" ;; *) bad "unexpected: $out" ;; esac
printf 'ID=alpine\n' > "$T/os-release"
out=$(BX_OS_RELEASE="$T/os-release" BX_DEP_DRYRUN=1 bx_ensure_deps definitely-not-a-command-xyz 2>&1); rc=$?
expect "missing tool on unknown family returns 1" 1 "$rc"
case "$out" in *"nstall manually"*) ok "tells the user to install manually" ;; *) bad "unexpected: $out" ;; esac
printf 'ID=debian\n' > "$T/os-release"
out=$(BX_OS_RELEASE="$T/os-release" BX_DEP_DRYRUN=1 bx_ensure_deps definitely-not-a-command-xyz 2>&1); rc=$?
if [ "$(id -u)" -eq 0 ]; then
    expect "dry-run on known family returns 0 (root)" 0 "$rc"
    case "$out" in *"(dry-run) would install: definitely-not-a-command-xyz"*"apt-get"*) ok "dry-run names package and installer" ;; *) bad "unexpected: $out" ;; esac
else
    expect "not root cannot install -> 1" 1 "$rc"
    case "$out" in *"not running as root"*) ok "explains it is not root" ;; *) bad "unexpected: $out" ;; esac
fi

echo "== config loading"
unset BACKUP_MOUNT BORG_REPO BACKUP_FS_UUID SCHEDULE_MODE KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB BACKUP_EXTRA_SOURCES
BX_CONFIG="$T/none.conf"; bx_load_config
expect "default mount"     /mnt/backup             "$BACKUP_MOUNT"
expect "default repo"      /mnt/backup/borg-backup "$BORG_REPO"
expect "default schedule"  adhoc                   "$SCHEDULE_MODE"
expect "default KEEP"      10 "$KEEP"; expect "default MIN_KEEP" 3 "$MIN_KEEP"
expect "default MIN_FREE_PCT" 10 "$MIN_FREE_PCT"; expect "default MIN_FREE_GIB" 0 "$MIN_FREE_GIB"
unset BACKUP_MOUNT BORG_REPO BACKUP_FS_UUID SCHEDULE_MODE KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB
cat > "$T/host.conf" <<'CONF'
BACKUP_MOUNT="/media/x"
SCHEDULE_MODE="scheduled"
KEEP=4
BACKUP_FS_UUID="12345678-1234-1234-1234-123456789abc"
CONF
BX_CONFIG="$T/host.conf"; bx_load_config
expect "mount from config"     /media/x             "$BACKUP_MOUNT"
expect "repo derived from mount" /media/x/borg-backup "$BORG_REPO"
expect "schedule from config"  scheduled            "$SCHEDULE_MODE"
expect "KEEP from config"      4 "$KEEP"; expect "MIN_KEEP still default" 3 "$MIN_KEEP"

echo "== wrong-drive guard"
BACKUP_MOUNT="$T/not-a-mount"; BACKUP_FS_UUID=""
out=$(bx_check_backup_drive); rc=$?
expect "unmounted path refused" 1 "$rc"
case "$out" in *"is not mounted"*) ok "says not mounted" ;; *) bad "unexpected: $out" ;; esac
BACKUP_MOUNT=/; BACKUP_FS_UUID=""
bx_check_backup_drive >/dev/null; expect "empty UUID skips the guard" 0 "$?"
BACKUP_FS_UUID="00000000-0000-0000-0000-000000000000"
out=$(bx_check_backup_drive); rc=$?
expect "mismatched UUID refused" 1 "$rc"
case "$out" in *"wrong drive"*) ok "says wrong drive" ;; *) bad "unexpected: $out" ;; esac
real=$(findmnt -n -o UUID --target / 2>/dev/null)
if [ -n "$real" ]; then
    BACKUP_FS_UUID="$real"; bx_check_backup_drive >/dev/null; expect "matching UUID accepted" 0 "$?"
fi

echo "== live-mount and presence helpers"
bx_mount_is_live /; expect "/ is a live mount" 0 "$?"
bx_mount_is_live "$T/nope"; expect "non-mount is not live" 1 "$?"
rootsrc=$(findmnt -no SOURCE --target / 2>/dev/null | sed 's/\[.*//')
bx_dev_is_live "$rootsrc"; expect "root device is live ($rootsrc)" 0 "$?"
bx_dev_is_live /dev/null; expect "/dev/null is not a live block device" 1 "$?"
bx_dev_is_live "$T/absent"; expect "absent path is not live" 1 "$?"
BACKUP_LUKS_UUID=""; BACKUP_FS_UUID=""; bx_backup_drive_present; expect "nothing configured -> not present" 1 "$?"
BACKUP_LUKS_UUID="00000000-0000-0000-0000-000000000000"; bx_backup_drive_present; expect "absent LUKS uuid -> not present" 1 "$?"
BACKUP_LUKS_UUID=""; BACKUP_FS_UUID="$(findmnt -n -o UUID --target / 2>/dev/null)"
if [ -n "$BACKUP_FS_UUID" ] && [ -e "/dev/disk/by-uuid/$BACKUP_FS_UUID" ]; then bx_backup_drive_present; expect "root fs uuid -> present" 0 "$?"; fi
BACKUP_FS_UUID=""

echo "== free-space predicates"
BACKUP_MOUNT=/
pct=$(bx_free_pct); gib=$(bx_free_gib)
case "$pct" in ''|*[!0-9]*) bad "free pct not numeric: '$pct'" ;; *) ok "free pct numeric ($pct)" ;; esac
case "$gib" in ''|*[!0-9]*) bad "free gib not numeric: '$gib'" ;; *) ok "free gib numeric ($gib)" ;; esac
MIN_FREE_PCT=0; MIN_FREE_GIB=0
bx_space_low; expect "0/0 floors: never low" 1 "$?"
MIN_FREE_PCT=101; MIN_FREE_GIB=0
bx_space_low; expect "101% floor: always low" 0 "$?"
MIN_FREE_PCT=0; MIN_FREE_GIB=999999999
bx_space_low; expect "absurd GiB floor: low" 0 "$?"
BACKUP_MOUNT="$T/absent"
expect "absent mount reports 0% free" 0 "$(bx_free_pct)"

echo "== backup sources"
BACKUP_EXTRA_SOURCES=""
first=$(bx_backup_sources | head -1); expect "root first" / "$first"
m=$(findmnt -rno TARGET -t tmpfs 2>/dev/null | grep -v '^/$' | head -1)
if [ -n "$m" ]; then
    BACKUP_EXTRA_SOURCES="$m"
    if bx_backup_sources | grep -qx "$m"; then ok "extra mounted source included ($m)"; else bad "extra source $m missing"; fi
fi
BACKUP_EXTRA_SOURCES="$T/not-mounted"
if bx_backup_sources | grep -qx "$T/not-mounted"; then bad "unmounted extra source must be dropped"; else ok "unmounted extra source dropped"; fi

echo "== boot-listing classifier (uki kern gcfg sdb pifw oth)"
printf 'etc/fstab\nboot/vmlinuz-6.1.0\nboot/initramfs-6.1.0.img\nboot/grub2/grub.cfg\nboot/efi/EFI/fedora/grubx64.efi\nusr/lib/modules/6.1.0/vmlinuz\n' > "$T/l-grub"
expect "GRUB + vmlinuz"        "0 1 1 0 0 0" "$(bx_boot_listing_counts "$T/l-grub")"
printf 'efi/EFI/Linux/arch-linux.efi\nefi/loader/loader.conf\nefi/loader/entries/arch.conf\n' > "$T/l-uki"
expect "systemd-boot + UKI"     "1 0 0 2 0 0" "$(bx_boot_listing_counts "$T/l-uki")"
printf 'boot/efi/EFI/Linux/fedora.efi\nboot/efi/loader/entries/f.conf\nboot/efi/EFI/fedora/grub.cfg\n' > "$T/l-uki2"
expect "ESP at /boot/efi: UKI + entry + grub.cfg" "1 0 1 1 0 0" "$(bx_boot_listing_counts "$T/l-uki2")"
printf 'boot/vmlinuz-linux\nboot/initramfs-linux.img\nboot/loader/loader.conf\nboot/loader/entries/arch.conf\nboot/EFI/systemd/systemd-bootx64.efi\n' > "$T/l-sdb-boot"
expect "systemd-boot, no UKI, ESP at /boot (Arch)" "0 1 0 2 0 0" "$(bx_boot_listing_counts "$T/l-sdb-boot")"
printf 'efi/0123456789abcdef0123456789abcdef/6.10.0-1/linux\nefi/0123456789abcdef0123456789abcdef/6.10.0-1/initrd\nefi/loader/entries/0123456789abcdef0123456789abcdef-6.10.0-1.conf\n' > "$T/l-sdb-efi"
expect "systemd-boot, no UKI, kernel-install Type #1 at /efi" "0 1 0 1 0 0" "$(bx_boot_listing_counts "$T/l-sdb-efi")"
printf 'boot/0123456789abcdef0123456789abcdef/6.10.0-1/linux\nboot/loader/entries/x.conf\n' > "$T/l-sdb-xboot"
expect "systemd-boot, no UKI, XBOOTLDR at /boot" "0 1 0 1 0 0" "$(bx_boot_listing_counts "$T/l-sdb-xboot")"
printf 'home/x/0123456789abcdef0123456789abcdef/6.10.0-1/linux\n' > "$T/l-sdb-fake"
expect "Type #1 layout outside boot/efi does not count" "0 0 0 0 0 0" "$(bx_boot_listing_counts "$T/l-sdb-fake")"
printf 'boot/firmware/config.txt\nboot/firmware/cmdline.txt\nboot/firmware/kernel8.img\nboot/firmware/kernel_2712.img\nboot/firmware/initramfs8\nboot/firmware/bcm2712-rpi-5-b.dtb\n' > "$T/l-pi"
expect "Raspberry Pi firmware"  "0 2 0 0 2 0" "$(bx_boot_listing_counts "$T/l-pi")"
printf 'boot/config.txt\nboot/cmdline.txt\nboot/kernel8.img\n' > "$T/l-pi-old"
expect "Pi, old /boot layout"   "0 1 0 0 2 0" "$(bx_boot_listing_counts "$T/l-pi-old")"
printf 'etc/fstab\nusr/lib/modules/6.1.0/vmlinuz\nhome/x/kernel.txt\n' > "$T/l-none"
expect "root-only archive"      "0 0 0 0 0 0" "$(bx_boot_listing_counts "$T/l-none")"
printf 'boot/vmlinuz-linux-cachyos\nboot/initramfs-linux-cachyos.img\nboot/limine.conf\nboot/EFI/limine/BOOTX64.EFI\n' > "$T/l-limine"
expect "Limine (CachyOS, ESP at /boot)" "0 1 0 0 0 1" "$(bx_boot_listing_counts "$T/l-limine")"
printf 'boot/vmlinuz-linux\nboot/refind_linux.conf\nefi/EFI/refind/refind.conf\nefi/EFI/refind/refind_x64.efi\n' > "$T/l-refind"
expect "rEFInd (config on the ESP)"   "0 1 0 0 0 1" "$(bx_boot_listing_counts "$T/l-refind")"
printf 'boot/vmlinuz-lts\nboot/extlinux/extlinux.conf\n' > "$T/l-extlinux"
expect "extlinux"                     "0 1 0 0 0 1" "$(bx_boot_listing_counts "$T/l-extlinux")"
printf 'home/x/limine.conf\netc/refind.conf\n' > "$T/l-oth-fake"
expect "loader configs outside boot/efi do not count" "0 0 0 0 0 0" "$(bx_boot_listing_counts "$T/l-oth-fake")"
mkdir -p "$T/pifw"; printf 'arm_64bit=1\n' > "$T/pifw/config.txt"
if [ ! -d /sys/firmware/efi ]; then BX_PI_FW="$T/pifw" bx_pi_firmware_boot; expect "config.txt without EFI -> Pi firmware boot" 0 "$?"
else BX_PI_FW="$T/pifw" bx_pi_firmware_boot; expect "EFI machine is never Pi firmware boot" 1 "$?"; fi
BX_PI_FW="$T/nope" bx_pi_firmware_boot; r=$?; [ -f /boot/config.txt ] || expect "no config.txt -> not Pi" 1 "$r"
expect "parttype: GPT EFI System -> esp"        esp      "$(bx_parttype_kind c12a7328-f81f-11d2-ba4b-00a0c93ec93b)"
expect "parttype: uppercase GUID -> esp"         esp      "$(bx_parttype_kind C12A7328-F81F-11D2-BA4B-00A0C93EC93B)"
expect "parttype: MBR 0xef -> esp"               esp      "$(bx_parttype_kind 0xef)"
expect "parttype: XBOOTLDR -> xbootldr"          xbootldr "$(bx_parttype_kind bc13c2ff-59e6-4262-a352-b275fd6f7172)"
expect "parttype: Linux filesystem -> other"     other    "$(bx_parttype_kind 0fc63daf-8483-4772-8e79-3d69d8477de4)"
expect "parttype: empty -> other"                other    "$(bx_parttype_kind '')"
for f in borg-restore.sh backintime-restore.sh restore-rebuild-boot.sh; do
    grep -q 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' "$HERE/../$f" && grep -q 'bc13c2ff-59e6-4262-a352-b275fd6f7172' "$HERE/../$f" \
        && ok "$f checks the ESP and XBOOTLDR partition types" || bad "$f lacks the ESP/XBOOTLDR partition-type check"
done
grep -q 'EFI_MNT=/boot' "$HERE/../borg-restore.sh" && grep -q 'EFI_MNT=/boot' "$HERE/../backintime-restore.sh" \
    && ok "restore scripts recognise /boot as the ESP" || bad "a restore script does not recognise /boot as the ESP"
grep -q 'ESP=/boot' "$HERE/../restore-rebuild-boot.sh" && ok "boot rebuild recognises /boot as the ESP" || bad "boot rebuild does not recognise /boot as the ESP"
expect "esp path list carries /boot/firmware" 0 "$(grep -qx '/boot/firmware' <<<"$(tr '|' '\n' <<<"$BX_ESP_PATHS")"; echo $?)"

echo "== capacity policy (pure arithmetic)"
CAPACITY_HEADROOM_PCT=20; CAPACITY_RECOMMEND_X=2
expect "below floor -> refuse"        "refuse 120 400" "$(bx_capacity_verdict 119 100 200)"
expect "exactly floor -> not refused" "warn 120 400"   "$(bx_capacity_verdict 120 100 200)"
expect "below 2x system disk -> warn" "warn 120 400"   "$(bx_capacity_verdict 399 100 200)"
expect "at 2x system disk -> ok"      "ok 120 400"     "$(bx_capacity_verdict 400 100 200)"
expect "unknown Linux total: floor only" "ok 120 0"    "$(bx_capacity_verdict 121 100 0)"
CAPACITY_HEADROOM_PCT=50; CAPACITY_RECOMMEND_X=3
expect "knobs honoured"               "refuse 150 600" "$(bx_capacity_verdict 149 100 200)"
CAPACITY_HEADROOM_PCT=20; CAPACITY_RECOMMEND_X=2
expect "human 0"        "0 B"      "$(bx_human_bytes 0)"
expect "human 1536"     "1.5 KiB"  "$(bx_human_bytes 1536)"
expect "human 4 TB"     "3.6 TiB"  "$(bx_human_bytes 4000000000000)"
u=$(bx_sources_used_bytes); [ "$u" -gt 0 ] 2>/dev/null && ok "sources used bytes > 0 ($(bx_human_bytes "$u"))" || bad "sources used bytes: '$u'"
d=$(bx_system_disk_bytes); case "$d" in ''|*[!0-9]*) bad "system disk bytes not numeric: '$d'" ;; *) ok "system disk bytes numeric ($(bx_human_bytes "$d"))" ;; esac
t=$(bx_sources_total_bytes); [ "$t" -ge "$u" ] 2>/dev/null && ok "Linux filesystems total >= used ($(bx_human_bytes "$t"))" || bad "sources total '$t' < used '$u'"
if [ "$d" -eq 0 ] || [ "$t" -le "$d" ]; then ok "Linux filesystems total <= whole disk"; else bad "sources total $t exceeds disk $d"; fi
rootsrc=$(findmnt -no SOURCE --target / 2>/dev/null | sed 's/\[.*//')
disk=$(bx_disk_of "$rootsrc" 2>/dev/null); if [ -n "$disk" ]; then
    [ "$(lsblk -dno TYPE "$disk" 2>/dev/null)" = disk ] && ok "bx_disk_of resolves / to a whole disk ($disk)" || bad "bx_disk_of gave $disk"
else ok "bx_disk_of: / not on a resolvable disk here (container?) — skipped"; fi
BACKUP_MOUNT="$T/absent"; out=$(bx_check_backup_capacity); rc=$?
expect "unmounted drive cannot be sized -> 1" 1 "$rc"
out=$(bx_check_backup_capacity 1); rc=$?
expect "1-byte drive -> refuse" 1 "$rc"
case "$out" in "capacity: REFUSED"*) ok "refusal message" ;; *) bad "unexpected: $out" ;; esac
out=$(bx_check_backup_capacity 99999999999999999); rc=$?
expect "absurdly large drive -> 0" 0 "$rc"
case "$out" in "capacity: OK — "*) ok "ok message" ;; *) bad "unexpected: $out" ;; esac

echo "== backup sources from a mount table: every local filesystem, nothing else"
cat > "$T/mt" <<'MT'
/ btrfs /dev/mapper/root[/@] rw,subvol=/@
/home btrfs /dev/mapper/root[/@home] rw,subvol=/@home
/var btrfs /dev/mapper/root[/@/var] rw,subvol=/@/var
/srv/data btrfs /dev/mapper/root[/@/srv/data] rw,subvol=/@
/.snapshots btrfs /dev/mapper/root[/@/.snapshots] rw,subvol=/@/.snapshots
/boot vfat /dev/nvme0n1p3 rw
/efi vfat /dev/nvme0n1p1 rw
/mnt/backup btrfs /dev/mapper/luks-x rw
/mnt/backup/snapshots btrfs /dev/mapper/luks-x[/snapshots] rw
/run/media/u/stick vfat /dev/sdb1 rw
/opt ext4 /dev/sda5 rw
/opt/bind ext4 /dev/sda5[/x] rw
/opt2 ext4 /dev/sda5 rw
/home/u/nas nfs4 nas:/export rw
/var/lib/docker/overlay2/x/merged overlay overlay rw
/snap/core/1 squashfs /dev/loop0 ro
/proc proc proc rw
/tmp tmpfs tmpfs rw
/mnt/data xfs /dev/sdc1 rw
/tank/home zfs tank/home rw
MT
got=$(BACKUP_MOUNT=/mnt/backup BX_MOUNT_TABLE="$T/mt" BACKUP_EXTRA_SOURCES="/mnt/data /nope" bx_backup_sources | tr '\n' ' ')
expect "openSUSE-style /var, a data disk, a ZFS dataset in; bind/snapper/NAS/overlay/snap/backup drive out" "/ /boot /efi /home /mnt/data /opt /tank/home /var " "$got"
unset BX_MOUNT_TABLE BACKUP_EXTRA_SOURCES

echo "== kernels without an initramfs beside them"
printf 'boot/vmlinuz-6.1.0-18-amd64\nboot/initrd.img-6.1.0-18-amd64\nboot/vmlinuz-6.2.0-1-amd64\nboot/vmlinuz-linux\nboot/initramfs-linux.img\nefi/0123456789abcdef0123456789abcdef/6.10/linux\nefi/0123456789abcdef0123456789abcdef/6.11/linux\nefi/0123456789abcdef0123456789abcdef/6.11/initrd\nboot/vmlinuz-6.4.0-default\nboot/initrd-6.4.0-default\nboot/vmlinuz-lts\nboot/initramfs-lts\nboot/firmware/kernel8.img\nboot/vmlinuz-0-rescue-0123456789abcdef0123456789abcdef\nboot/initramfs-0-rescue-0123456789abcdef0123456789abcdef.img\n' > "$T/l-initrd"
expect "Debian/Fedora/Arch/openSUSE/Alpine/kernel-install/rescue pairs; two unpaired" "boot/vmlinuz-6.2.0-1-amd64 efi/0123456789abcdef0123456789abcdef/6.10/linux " "$(bx_kernels_without_initrd "$T/l-initrd" | tr '\n' ' ')"
expect "UKI-only listing: nothing to pair" "" "$(bx_kernels_without_initrd "$T/l-uki" | tr '\n' ' ')"

echo "== retention counts are validated: KEEP never undercuts MIN_KEEP, garbage falls back"
unset BACKUP_MOUNT BORG_REPO BACKUP_FS_UUID SCHEDULE_MODE KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB BACKUP_EXTRA_SOURCES
printf 'KEEP=0\nMIN_KEEP=3\n' > "$T/keep.conf"; BX_CONFIG="$T/keep.conf" bx_load_config 2>/dev/null
expect "KEEP=0 (head -n -0 deletes everything) raised to MIN_KEEP" 3 "$KEEP"
unset KEEP MIN_KEEP
printf 'KEEP=abc\nMIN_KEEP=0\n' > "$T/keep.conf"; BX_CONFIG="$T/keep.conf" bx_load_config 2>/dev/null
expect "KEEP=abc falls back to 10" 10 "$KEEP"; expect "MIN_KEEP=0 raised to 1" 1 "$MIN_KEEP"
unset KEEP MIN_KEEP BACKUP_HOST_ID
printf 'BACKUP_HOST_ID=pinned\n' > "$T/host.conf"; BX_CONFIG="$T/host.conf" bx_load_config 2>/dev/null
expect "BACKUP_HOST_ID from the config" pinned "$BACKUP_HOST_ID"
unset BACKUP_HOST_ID; BX_CONFIG=/dev/null bx_load_config 2>/dev/null
[ -n "$BACKUP_HOST_ID" ] && ok "BACKUP_HOST_ID defaults to the hostname ($BACKUP_HOST_ID)" || bad "BACKUP_HOST_ID empty"

echo "== the shared exclude list"
ex=$(BACKUP_MOUNT=/mnt/backup BACKUP_EXTRA_EXCLUDES="/x/y /z/*" bx_excludes)
grep -qx '/mnt/backup/\*' <<<"$ex" && ok "excludes the backup drive itself" || bad "backup drive not excluded"
grep -qx '/x/y' <<<"$ex" && grep -qx '/z/\*' <<<"$ex" && ok "BACKUP_EXTRA_EXCLUDES appended" || bad "extra excludes missing"
grep -qx '/home/\*/build/\*' <<<"$ex" && bad "a personal exclude (~/build) is still in the universal list" || ok "no personal excludes in the universal list"
grep -qx '/.snapshots/\*' <<<"$ex" && grep -qx '/var/lib/snapd/snap/\*' <<<"$ex" && ok "snapper dirs and snap images excluded" || bad "snapper/snap excludes missing"

echo "== extra excludes keep their globs; the fully-excluded check survives pipefail"
got=$(cd / && BACKUP_MOUNT=/mnt/backup BACKUP_EXTRA_EXCLUDES="/home/* /usr/*" bx_excludes | tail -2 | tr '\n' ' ')
expect "patterns printed literally, not expanded against the filesystem" "/home/* /usr/* " "$got"
many=$(for i in $(seq 1 5000); do printf '/x/%s/* ' "$i"; done)
( set -o pipefail; BACKUP_MOUNT=/mnt/backup BACKUP_EXTRA_EXCLUDES="$many /home/*" bx_source_fully_excluded /home ) && ok "a long exclude list under pipefail: /home still fully excluded" || bad "SIGPIPE under pipefail turned a match into 'not excluded'"
( set -o pipefail; BACKUP_MOUNT=/mnt/backup BACKUP_EXTRA_EXCLUDES="$many" bx_source_fully_excluded /var/cache ) && ok "…and the base list's /var/cache too" || bad "/var/cache lost under pipefail"

echo "== extra includes: literal, one per line, trailing slash dropped"
expect "includes printed as given" "/home/*/.config /home/*/.ssh " "$(cd / && BACKUP_EXTRA_INCLUDES="/home/*/.config /home/*/.ssh/" bx_includes | tr '\n' ' ')"
expect "no includes: nothing" "" "$(BACKUP_EXTRA_INCLUDES="" bx_includes)"

echo "== borg pattern order: extra source, includes, excludes"
pat=$(BACKUP_MOUNT=/mnt/backup BACKUP_EXTRA_INCLUDES="/home/*/.config" BACKUP_EXTRA_EXCLUDES="/home/*/*" bx_borg_patterns / /home /mnt/data | tr '\n' ' ')
case "$pat" in "--pattern=+/mnt/data --pattern=+/home/*/.config --pattern=-/dev/*"*) ok "source re-include, then includes, then the first exclude" ;; *) bad "pattern order: $pat" ;; esac
grep -q -- '--pattern=-/home/\*/\* ' <<<"$pat " && ok "the extra exclude is in the list" || bad "extra exclude missing"

echo "== capacity check knob"
BACKUP_MOUNT="$T/absent"; CAPACITY_CHECK=off
m=$(bx_check_backup_capacity); rc=$?; expect "CAPACITY_CHECK=off passes" 0 "$rc"; grep -q disabled <<<"$m" && ok "…and says so" || bad "no 'disabled' message: $m"
CAPACITY_CHECK=refuse

echo "== USB authorization: blocked devices are named"
mkdir -p "$T/usb/2-1" "$T/usb/1-3" "$T/usb/usb1"
printf 0 > "$T/usb/2-1/authorized"; printf 0bda > "$T/usb/2-1/idVendor"; printf 9201 > "$T/usb/2-1/idProduct"; printf RTL9201 > "$T/usb/2-1/product"
printf 1 > "$T/usb/1-3/authorized"; printf 046d > "$T/usb/1-3/idVendor"; printf c52b > "$T/usb/1-3/idProduct"
printf 1 > "$T/usb/usb1/authorized"
expect "only the unauthorized device, with port, id and name" "2-1 0bda:9201 RTL9201" "$(BX_SYSFS_USB="$T/usb" bx_usb_blocked_devices)"
BX_SYSFS_USB="$T/usb" bx_drive_gone_hint | grep -q 'NOT AUTHORIZED.*0bda:9201' && ok "the drive-gone hint names it" || bad "hint does not name the blocked device"
printf 1 > "$T/usb/2-1/authorized"
expect "nothing blocked: no hint about authorization" "" "$(BX_SYSFS_USB="$T/usb" bx_drive_gone_hint | grep AUTHORIZED)"

echo "== snapshot engine"
e=$(bx_snapshot_engine)
case "$e" in btrfs|timeshift|none) ok "engine is one of btrfs/timeshift/none ($e)" ;; *) bad "engine '$e'" ;; esac
if bx_is_btrfs; then expect "btrfs root -> btrfs engine" btrfs "$e"; fi

echo
echo "lib-fixture-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
