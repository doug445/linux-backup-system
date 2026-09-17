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
# testbed/testbed.sh — the bare-metal restore test bed. Back this machine up to a
# TEST archive, restore it onto a dedicated TEST drive, boot the drive, and prove
# what came back — while writing nothing to this machine's own disks.
#
# Usage: sudo testbed/testbed.sh <command>
#   status        drives, this host's layout, the test state and its ledger
#   plan          the target layout mirrored from this host (writes nothing)
#   fingerprint before|after|diff
#                 this machine's own disks: partition tables, exact LUKS headers,
#                 every file on /boot and the ESP, firmware boot entries
#   prepare       WIPE the test drive, partition its first TB_TARGET_GIB (100) like this host
#                 (TB_WIPE=<serial>); the rest of the drive stays unpartitioned
#   format        LUKS (passphrase "test") + filesystems + btrfs subvolumes
#   mount         the target tree at $TB_MNT, laid out like this host's fstab
#   backup [functional|minimal]
#                 a TEST archive in its own repository on the backup drive
#                 functional (default): configs, keys, Claude Code and shell setup of
#                 every home are kept, bulk data is not; minimal: no /home contents
#   restore       dry run, then the real restore, from a frozen copy of the suite
#   finish        byte manifest, home skeletons, boot logger, checks; unmount + close;
#                 then vmboot (TB_VMBOOT=0 skips it)
#   vmboot        boot the closed test drive in QEMU (snapshot: nothing written to it,
#                 no network) with a report disk for its boot logger → VM verdict
#   collect       after booting the test drive and back: report, fingerprint diff,
#                 hard-link-aware byte comparison, verdict
#   revert [--keep-repo]
#                 undo every TEST-ONLY change: mounts, mappings, transfer sizes,
#                 the report left on this host, the test repository
#   all           fingerprint before → prepare → format → mount → backup → restore → finish
#
# Test drives only ever get the passphrase "test": they hold a copy of this machine
# and are wiped again on the next run. What the host opens without a prompt, the
# test drive does too: the host's crypttab keyfile is a second key on each container
# that crypttab opens with it, and an encrypted /boot is opened by a test-only GRUB
# fallback loader with "test" built in. A root unlocked by passphrase asks for "test".
# The suite's real restore scripts never carry a passphrase.
#
# Configuration (testbed.conf, see testbed.conf.example): $TESTBED_CONF, then
# <backup drive>/testbed/testbed.conf, then ~/.config/linux-backup-system/testbed.conf,
# then next to this script. State + ledger: /var/lib/linux-backup-testbed/<host>-<stamp>/.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

TB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$(cd "$TB_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SUITE/backup-common.sh" || { echo "backup-common.sh not found next to testbed/" >&2; exit 3; }
# shellcheck disable=SC1091
. "$SUITE/lib-cmdline.sh" || { echo "lib-cmdline.sh not found next to testbed/" >&2; exit 3; }
bx_load_config

say()  { echo "[testbed] $*"; }
warn() { echo "[testbed] WARNING: $*" >&2; }
die()  { echo "[testbed] ERROR: $*" >&2; exit 1; }

case "${1:-}" in -h|--help|"") sed -n '/^# testbed\/testbed.sh/,/^\[ -n "\${BASH_VERSION/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

# --- configuration -------------------------------------------------------------
TB_TARGET_SERIAL="${TB_TARGET_SERIAL:-}"; TB_BACKUP_SERIAL="${TB_BACKUP_SERIAL:-}"
TB_CONF=none
# Last: the copy the newest test run of this host kept in its state directory —
# collect runs after a reboot with the backup drive (and its copy) unplugged.
for _c in "${TESTBED_CONF:-}" "$BACKUP_MOUNT/testbed/testbed.conf" \
          "$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.config/linux-backup-system/testbed.conf" "$TB_DIR/testbed.conf" \
          "$(ls -1d "/var/lib/linux-backup-testbed/$BACKUP_HOST_ID"-* 2>/dev/null | sort | tail -1)/testbed.conf"; do
    if [ -n "$_c" ] && [ -r "$_c" ]; then TB_CONF="$_c"; # shellcheck disable=SC1090
        . "$_c"; break; fi
done
TB_PASSPHRASE="test"                       # test drives only — see the header
export LVM_SUPPRESS_FD_WARNINGS=1          # lvm run inside read loops: no "file descriptor leaked" noise
TB_MNT="${TB_MNT:-/mnt/tb-target}"
TB_HOST="$BACKUP_HOST_ID"
TB_REPO="${TB_REPO:-$BACKUP_MOUNT/borg-testbed-$TB_HOST}"
TB_BIG_EXCLUDES="${TB_BIG_EXCLUDES:-/var/lib/ollama/* /usr/lib/ollama/* /var/lib/docker/* /var/lib/containers/* /var/lib/libvirt/images/* /var/lib/plocate/* /var/lib/mlocate/* /var/lib/chrootbuild/* /opt/cuda/* /usr/share/doc/* /usr/lib/jvm/*}"
TB_EXTRA_EXCLUDES="${TB_EXTRA_EXCLUDES:-}"
# A functional home is one the desktop comes up in: ~/.config alone is not. Plasma's
# panel theme, plasmoids, wallpapers and activities, color schemes, icons and
# terminal profiles live in ~/.local/share — without them a restored EndeavourOS
# KDE drive logged in to no panel, no launcher and no way to open a terminal. The
# programs ~/.local/bin links into (Claude Code, pipx) and a shell's plug-ins
# (ble.sh) are kept for the same reason: the rc files and links kept above need them.
TB_HOME_KEEP="${TB_HOME_KEEP:-.config .local/bin .local/state .local/share/keyrings .local/share/applications .local/share/fonts .local/share/plasma .local/share/plasmashell .local/share/kactivitymanagerd .local/share/color-schemes .local/share/icons .local/share/themes .local/share/wallpapers .local/share/aurorae .local/share/kwin .local/share/kxmlgui5 .local/share/konsole .local/share/knewstuff3 .local/share/mime .local/share/user-places.xbel .local/share/gnome-shell .local/share/cinnamon .local/share/nemo .local/share/xfce4 .local/share/claude .local/share/pipx .local/share/blesh .themes .icons .fonts .ssh .gnupg .pki .claude .claude.json .bashrc .bash_profile .bash_logout .profile .zshrc .zprofile .zshenv .zlogin .oh-my-zsh .xinitrc .xprofile .xsession .Xresources .tmux.conf .tmux .gitconfig .dotfiles .vimrc .nanorc}"
TB_TARGET_GIB="${TB_TARGET_GIB:-100}"     # the test bed's part of the test drive, from its start; the rest stays unpartitioned (0 = whole drive)
TB_SECTORS_KB="${TB_SECTORS_KB:-128}"     # smaller USB transfers for bridges that reset under load; 0 = leave alone

# LVM writes a metadata backup and archive to THIS host's /etc/lvm for every
# volume group a command touches — even vgs, when the backup looks stale. The
# test drive's group carries this host's name after finish: its metadata
# replaced this host's /etc/lvm/backup/<vg> (a vgcfgrestore from it would write
# the test drive's layout onto this machine), and the next test backup restored
# that file, so the restore paired the root container with nothing. Every LVM
# command on the test drive writes neither.
TB_LVM=(--config 'backup { backup = 0 archive = 0 }')

# --- state + ledger ---------------------------------------------------------------
if [ -z "${TB_STATE:-}" ]; then
    TB_STATE=$(ls -1d "/var/lib/linux-backup-testbed/$TB_HOST"-* 2>/dev/null | sort | tail -1)
    [ -n "$TB_STATE" ] && [ -f "$TB_STATE/finished-collect" ] && [ "${1:-}" != collect ] && [ "${1:-}" != status ] && [ "${1:-}" != revert ] && TB_STATE=""
    [ -n "$TB_STATE" ] || TB_STATE="/var/lib/linux-backup-testbed/$TB_HOST-$(date +%Y%m%d-%H%M)"
fi
LEDGER="$TB_STATE/LEDGER.md"
case "$TB_CONF" in none|"$TB_STATE/testbed.conf") ;; *) mkdir -p "$TB_STATE" && cp -f "$TB_CONF" "$TB_STATE/testbed.conf" 2>/dev/null ;; esac
st_get() { cat "$TB_STATE/$1" 2>/dev/null; }
st_set() { mkdir -p "$TB_STATE"; printf '%s\n' "$2" > "$TB_STATE/$1"; }
ledger() { # ledger test|permanent WHAT REVERT
    mkdir -p "$TB_STATE"
    [ -f "$LEDGER" ] || printf '# Restore test bed — %s\n\nTest vs real: the suite has no test mode. Rows marked **test** are undone by `testbed.sh revert`.\n\n| when | kind | change | revert |\n|---|---|---|---|\n' "$TB_HOST" > "$LEDGER"
    printf '| %s | %s | %s | %s |\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$LEDGER"
}

# --- drives -------------------------------------------------------------------------
# A disk answers to lsblk's serial or udev's ID_SERIAL_SHORT: behind some USB
# bridges lsblk reports the SCSI serial (0000000000000000 on a Realtek bridge,
# Fedora 44) while the drive's own serial is only in ID_SERIAL_SHORT.
disk_has_serial() { # disk_has_serial DISK SERIAL
    [ -n "$2" ] || return 1
    [ "$(lsblk -dno SERIAL "$1" 2>/dev/null | tr -d ' ')" = "$2" ] && return 0
    udevadm info -q property -n "$1" 2>/dev/null | grep -qxF "ID_SERIAL_SHORT=$2"
}
disk_by_serial() {
    local d
    [ -n "$1" ] || return 1
    for d in $(lsblk -dnpo NAME 2>/dev/null); do disk_has_serial "$d" "$1" && { echo "$d"; return 0; }; done
    return 1
}
# This machine's own disks: every disk under a mounted filesystem, an active swap
# partition or an open container — minus the backup and test drives.
host_disks() {
    local t b s d
    t=$(disk_by_serial "$TB_TARGET_SERIAL"); b=$(disk_by_serial "$TB_BACKUP_SERIAL")
    { findmnt -rno SOURCE 2>/dev/null | sed 's/\[.*//' | grep '^/dev/'
      awk 'NR>1 && $2=="partition" {print $1}' /proc/swaps
      lsblk -rnpo NAME,TYPE 2>/dev/null | awk '$2=="crypt"{print $1}'
    } | sort -u | while read -r s; do d=$(bx_disk_of "$s" 2>/dev/null) && [ -n "$d" ] && echo "$d"; done \
      | sort -u | grep -vxF -e "${t:-/nonexistent}" -e "${b:-/nonexistent}" -e "$(bx_disk_of "$(findmnt -no SOURCE "$BACKUP_MOUNT" 2>/dev/null | sed 's/\[.*//')" 2>/dev/null || echo /nonexistent)"
    return 0
}
target_disk() {
    [ -n "$TB_TARGET_SERIAL" ] || die "TB_TARGET_SERIAL is not set (config: $TB_CONF) — which drive is the test target?"
    local t; t=$(disk_by_serial "$TB_TARGET_SERIAL")
    [ -n "$t" ] || die "test drive (serial $TB_TARGET_SERIAL) is not connected"
    host_disks | grep -qxF "$t" && die "test drive $t holds a mounted filesystem, swap or open container of THIS machine — refusing"
    [ "$(bx_disk_of "$(findmnt -no SOURCE / | sed 's/\[.*//')")" = "$t" ] && die "test drive $t is the running root — refusing"
    echo "$t"
}
part() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "$1$2" ;; esac; }
set_sectors() { # set_sectors DISK — remember the kernel's value, lower it
    local d kn f; d="$1"; kn=$(basename "$d"); f="/sys/block/$kn/queue/max_sectors_kb"
    [ "$TB_SECTORS_KB" -gt 0 ] 2>/dev/null && [ -w "$f" ] || return 0
    # lower only: a bridge already below the test value keeps its own (raising 120 → 128 is not "smaller")
    [ "$(cat "$f")" -gt "$TB_SECTORS_KB" ] 2>/dev/null || return 0
    [ -f "$TB_STATE/sectors.$kn" ] || cat "$f" > "$TB_STATE/sectors.$kn"
    echo "$TB_SECTORS_KB" > "$f" && ledger test "max_sectors_kb $(cat "$TB_STATE/sectors.$kn") → $TB_SECTORS_KB on $d (runtime)" "restored by revert (also lost at re-plug)"
}

# --- this host's layout ---------------------------------------------------------------
# Every fact the target layout mirrors, as KEY=VALUE lines in $TB_STATE/host-layout.
# luks_facts PREFIX MAPPER — the container behind an open mapper, as the KEY=VALUE
# lines format needs to make the test container open the same way: LUKS version,
# and the KDF of the host's cheapest keyslot (the one its bootloader or initramfs
# demonstrably opens), plus the keyfile crypttab gives that mapper, if any.
luks_facts() {
    local pre="$1" name="$2" dev dump ver kf
    dev=$(cryptsetup status "$name" 2>/dev/null | awk '/device:/{print $2}')
    dump=$(cryptsetup luksDump "$dev" 2>/dev/null); ver=$(awk '/^Version:/{print $2; exit}' <<<"$dump")
    echo "${pre}_MAPPER=$name"; echo "${pre}_LUKS_VERSION=${ver:-2}"
    if [ "$ver" = 1 ]; then echo "${pre}_LUKS_PBKDF=pbkdf2"
    else
        # keyslot blocks: PBKDF, Time cost, Memory, Threads — the lowest time cost wins
        awk '$1=="PBKDF:"{k=$2; t=m=p=""} $1=="Time"{t=$3} $1=="Memory:"{m=$2} $1=="Threads:"{p=$2; print t+0, k, m, p}' <<<"$dump" \
            | sort -n | head -1 | while read -r t k m p; do
                echo "${pre}_LUKS_PBKDF=${k:-argon2id}"; [ -n "$m" ] && echo "${pre}_LUKS_MEMORY=$m"
                [ -n "$p" ] && echo "${pre}_LUKS_THREADS=$p"; echo "${pre}_LUKS_TIME=$t"
            done
    fi
    kf=$(awk -v n="$name" '$1 !~ /^#/ && $1==n && $3!="none" && $3!="-" {print $3; exit}' /etc/crypttab 2>/dev/null)
    [ -n "$kf" ] && [ -f "$kf" ] && echo "${pre}_KEYFILE=$kf"
    return 0
}
detect_layout() {
    local root_src root_fs esp boot_fs boot_dev boot_is_esp=0 crypt=""
    local home_src home_fs swap_dev sv pv vg="" lv size dmp role n
    root_src=$(findmnt -no SOURCE / | sed 's/\[.*//'); root_fs=$(findmnt -no FSTYPE /)
    # Root on LVM: what the volume group sits on (a partition or a LUKS container)
    # is what gets mirrored; the logical volumes are laid out again inside it.
    pv=$root_src
    if [ "$(lsblk -dno TYPE "$root_src" 2>/dev/null)" = lvm ]; then
        vg=$(lvs --noheadings -o vg_name "$root_src" 2>/dev/null | tr -d ' ')
        pv=$(pvs --noheadings -o pv_name -S "vg_name=$vg" 2>/dev/null | tr -d ' ')
        n=$(printf '%s\n' "$pv" | grep -c .)
        if [ -z "$vg" ] || [ "$n" != 1 ]; then
            echo "NOT_MIRRORED=root on LVM volume group ${vg:-?} over $n physical volumes (the test bed lays out one)"; pv=$root_src; vg=""
        else
            echo "ROOT_VG=$vg"
            while read -r lv size dmp; do
                role=other
                [ "$(readlink -f "$dmp")" = "$(readlink -f "$root_src")" ] && role=root
                awk 'NR>1{print $1}' /proc/swaps | while read -r s; do [ "$(readlink -f "$s")" = "$(readlink -f "$dmp")" ] && echo x; done | grep -q x && role=swap
                [ "$role" = other ] && echo "NOT_MIRRORED=logical volume $vg/$lv is neither the root nor swap (the test bed lays out those two)"
                echo "LV=$lv:${size%%.*}:$role"
            done < <(lvs --noheadings --units m --nosuffix -o lv_name,lv_size,lv_dm_path -S "vg_name=$vg" 2>/dev/null)
        fi
    fi
    if [ "$(lsblk -dno TYPE "$pv" 2>/dev/null)" = crypt ]; then
        crypt=1
        luks_facts ROOT "$(basename "$pv")"
    fi
    lsblk -rno TYPE "$(bx_disk_of "$root_src")" 2>/dev/null | grep -qE '^raid' && echo "NOT_MIRRORED=root on mdadm RAID (the test bed cannot lay it out yet)"
    case "$root_fs" in btrfs|ext4|xfs|f2fs) ;; *) echo "NOT_MIRRORED=root filesystem $root_fs (the test bed cannot format it yet)" ;; esac
    esp=$(bx_esp_mount 2>/dev/null || true)
    echo "ROOT_FS=$root_fs"; echo "ROOT_CRYPT=${crypt:-0}"
    # Debian's initramfs-tools unlocks the root with its own askpass (plymouth or
    # the console): no systemd credential reaches it — the VM boot types.
    [ "${crypt:-0}" = 1 ] && [ "$(dpkg-query -W -f='${db:Status-Status}' initramfs-tools 2>/dev/null)" = installed ] && echo "ROOT_UNLOCK=initramfs-tools"
    [ -d /sys/firmware/efi ] && echo "FIRMWARE=uefi" || echo "FIRMWARE=bios"
    if [ -n "$esp" ]; then
        echo "ESP_MOUNT=$esp"; echo "ESP_MIB=$(( $(lsblk -bdno SIZE "$(findmnt -no SOURCE "$esp")") / 1048576 ))"
        [ "$esp" = /boot ] && boot_is_esp=1
        # the loader this machine's firmware entry starts (read only): the test
        # drive gets no entry, so finish points its fallback path at the same chain
        if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null 2>&1; then
            local cur espuuid fl
            cur=$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: *//p')
            espuuid=$(lsblk -dno PARTUUID "$(findmnt -no SOURCE "$esp")" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            fl=$(efibootmgr -v 2>/dev/null | awk -v b="Boot$cur" -v u="$espuuid" '
                u != "" && index($0, b) == 1 && index(tolower($0), u) {
                    p = $0   # efibootmgr 18 on Ubuntu: …)/File(\EFI\…); elsewhere …)/\EFI\…
                    if (match(p, /File\([^)]*\)/)) p = substr(p, RSTART + 5, RLENGTH - 6)
                    else { sub(/.*\)\//, "", p); sub(/[[:space:]].*/, "", p) }
                    gsub(/\\/, "/", p); print p; exit}')
            case "$fl" in /EFI/*) echo "FW_LOADER=$fl" ;; esac
        fi
    fi
    if mountpoint -q /boot && [ "$boot_is_esp" = 0 ]; then
        boot_dev=$(findmnt -no SOURCE /boot | sed 's/\[.*//'); boot_fs=$(findmnt -no FSTYPE /boot)
        echo "BOOT_FS=$boot_fs"
        if [ "$(lsblk -dno TYPE "$boot_dev")" = crypt ]; then
            # an encrypted /boot, opened by GRUB: the partition is the container
            echo "BOOT_CRYPT=1"; luks_facts BOOT "$(basename "$boot_dev")"
            echo "BOOT_MIB=$(( $(lsblk -bdno SIZE "$(cryptsetup status "$(basename "$boot_dev")" | awk '/device:/{print $2}')") / 1048576 ))"
            echo "BOOT_PARTTYPE=8309"
        else
            echo "BOOT_CRYPT=0"; echo "BOOT_MIB=$(( $(lsblk -bdno SIZE "$boot_dev") / 1048576 ))"
            echo "BOOT_PARTTYPE=$( [ "$boot_fs" = vfat ] && echo ea00 || echo 8300 )"
        fi
    fi
    if [ "$root_fs" = btrfs ]; then
        # subvolumes the host's fstab mounts from the root filesystem: MOUNT=SUBVOL
        while read -r _t sv; do echo "SUBVOL=$_t=$sv"; done < <(findmnt -rno TARGET,SOURCE,FSTYPE -t btrfs | awk -v d="$root_src" '$3=="btrfs" && index($2, d"[")==1 {s=$2; sub(/^[^[]*\[/, "", s); sub(/\]$/, "", s); print $1, s}')
    fi
    home_src=$(findmnt -no SOURCE /home 2>/dev/null | sed 's/\[.*//'); home_fs=$(findmnt -no FSTYPE /home 2>/dev/null)
    if [ -n "$home_src" ] && [ "$home_src" != "$root_src" ]; then
        echo "HOME_FS=$home_fs"; echo "HOME_CRYPT=$( [ "$(lsblk -dno TYPE "$home_src")" = crypt ] && echo 1 || echo 0)"
    fi
    # a swap partition of its own; swap on a logical volume is an LV line above
    swap_dev=$(awk 'NR>1 && $2=="partition"{print $1; exit}' /proc/swaps)
    [ -n "$swap_dev" ] && [ "$(lsblk -dno TYPE "$swap_dev" 2>/dev/null)" = part ] && echo "SWAP_MIB=$(( $(lsblk -bdno SIZE "$swap_dev") / 1048576 ))"
    # Where the booted test drive leaves its report: an UNENCRYPTED boot
    # partition of this machine (it cannot unlock the others).
    local rp=""; for m in /boot /efi /boot/efi; do
        mountpoint -q "$m" || continue
        [ "$(lsblk -dno TYPE "$(findmnt -no SOURCE "$m" | sed 's/\[.*//')")" = part ] || continue
        rp=$m; break
    done
    [ -n "$rp" ] && { echo "REPORT_MOUNT=$rp"; echo "REPORT_PARTUUID=$(lsblk -dno PARTUUID "$(findmnt -no SOURCE "$rp")")"; }
    return 0
}
layout() { [ -f "$TB_STATE/host-layout" ] || { mkdir -p "$TB_STATE"; detect_layout > "$TB_STATE/host-layout"; }; grep "^$1=" "$TB_STATE/host-layout" | head -1 | cut -d= -f2-; }
layout_all() { [ -f "$TB_STATE/host-layout" ] || { mkdir -p "$TB_STATE"; detect_layout > "$TB_STATE/host-layout"; }; grep "^$1=" "$TB_STATE/host-layout" | cut -d= -f2-; }

# EFI_CODE_HASH — sha256 of a PE image without its signature (checksum field,
# certificate-table entry and table): a loader re-signed by the machine's own
# boot (an sbctl drop-in on systemd-boot-update) is the same code. The files
# section keeps the whole-file hashes; the diff compares .efi files by code.
EFI_CODE_HASH='
import hashlib, struct, sys
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    try:
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        assert b[pe:pe + 4] == b"PE\0\0"
        opt = pe + 24
        ck = opt + 64
        sec = opt + (96 if struct.unpack_from("<H", b, opt)[0] == 0x10B else 112) + 4 * 8
        off, size = struct.unpack_from("<II", b, sec)
        end = off if off and size else len(b)
        body = b[:ck] + b[ck + 4:sec] + b[sec + 8:end] + (b[off + size:] if off and size else b"")
    except (AssertionError, struct.error):
        body = b
    print(hashlib.sha256(body).hexdigest() + "  " + p)
'
# --- fingerprint: this machine's own disks ----------------------------------------------
cmd_fingerprint() {
    local tag="${1:-}" out d p
    case "$tag" in
        diff)
            [ -f "$TB_STATE/fingerprint-before.txt" ] && [ -f "$TB_STATE/fingerprint-after.txt" ] || die "need fingerprint before and after first"
            # Expected on any boot of this machine: systemd-boot refreshes its random seed;
            # firmware boot menus reorder BootOrder and keep their own entries for the
            # removable media present at power-on (legacy "BBS(" entries, "UEFI: <drive>"
            # entries on a /USB( path) — firmware-made, the suite never writes NVRAM; the
            # test report directory. Disks are compared when present in both: a disk
            # plugged in or pulled out between the two (a USB stick) is a note, not a change.
            local both
            both=$(comm -12 <(sed -n 's/^## disk [^ ]* serial //p' "$TB_STATE/fingerprint-before.txt" | sort -u) \
                            <(sed -n 's/^## disk [^ ]* serial //p' "$TB_STATE/fingerprint-after.txt" | sort -u))
            local bycode=0
            grep -q '^## efi code ' "$TB_STATE/fingerprint-before.txt" && grep -q '^## efi code ' "$TB_STATE/fingerprint-after.txt" && bycode=1
            # Firmware entries for a partition no disk here has: stale, and the firmware
            # drops them at power-on (Acer removed its "Linpus lite" entry for a wiped
            # test drive) — not compared.
            local parts
            parts=$(lsblk -rno PARTUUID 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep . | tr '\n' ' ')
            fp_norm() { # the fingerprint without the expected noise and without disks absent from the other side
                awk -v both="$both" -v bycode="$bycode" -v parts="$parts" 'BEGIN{n=split(both, a, "\n"); for (i=1;i<=n;i++) keep[a[i]]=1
                        n=split(parts, b, " "); for (i=1;i<=n;i++) exists[b[i]]=1}
                    /^## files / {infiles=1; skip=0; dev=""; print; next}
                    /^## / {infiles=0}
                    bycode && infiles && tolower($0) ~ /\.efi$/ {next}
                    /^## disk / {dev=$3; sub(/^## disk [^ ]* serial /, "", $0); skip = !($0 in keep); if (!skip) print "## disk serial " $0; next}
                    /^## / && !/^## LUKS header / {skip=0; dev=""}
                    skip {next}
                    # the kernel may number the same disk differently after a reboot (nvme1n1 → nvme0n1):
                    # the serial identifies it, its device name is not compared
                    dev != "" {gsub(dev, "DISK")}
                    /restore-test|loader\/random-seed|^BootOrder:/ {next}
                    /^Boot[0-9A-Fa-f]{4}/ && /BBS\(|\/USB\(/ {next}
                    /^Boot[0-9A-Fa-f]{4}/ && match($0, /HD\([0-9]+,GPT,[0-9A-Fa-f-]+,/) {
                        u = tolower(substr($0, RSTART, RLENGTH)); sub(/^hd\([0-9]+,gpt,/, "", u); sub(/,$/, "", u)
                        if (!(u in exists)) next
                    }
                    {print}' "$1"
            }
            if diff <(fp_norm "$TB_STATE/fingerprint-before.txt") <(fp_norm "$TB_STATE/fingerprint-after.txt") > "$TB_STATE/fingerprint.diff"; then
                say "this machine's disks: IDENTICAL (partition tables, LUKS headers, boot files, boot entries)"
                grep -h '^BootOrder:' "$TB_STATE/fingerprint-before.txt" "$TB_STATE/fingerprint-after.txt" | uniq | sed -n '2p' | grep -q . && say "  note: BootOrder changed — firmware boot menus do that"
                diff <(grep -E '^Boot[0-9A-Fa-f]{4}' "$TB_STATE/fingerprint-before.txt" | grep -E 'BBS\(|/USB\(') \
                     <(grep -E '^Boot[0-9A-Fa-f]{4}' "$TB_STATE/fingerprint-after.txt" | grep -E 'BBS\(|/USB\(') >/dev/null \
                    || say "  note: the firmware's own removable-media boot entries changed (BBS / USB device paths) — made by the firmware at power-on"
                local gone
                gone=$(comm -3 <(sed -n 's/^## disk [^ ]* serial //p' "$TB_STATE/fingerprint-before.txt" | sort -u) \
                               <(sed -n 's/^## disk [^ ]* serial //p' "$TB_STATE/fingerprint-after.txt" | sort -u) | sed 's/^\t/after only: /; s/^\([^a]\)/before only: \1/' | tr '\n' ';')
                [ -n "$gone" ] && say "  note: disks present in only one fingerprint (plugged in or pulled out, not compared): $gone"
                local stale
                stale=$(grep -hE '^Boot[0-9A-Fa-f]{4}' "$TB_STATE/fingerprint-before.txt" "$TB_STATE/fingerprint-after.txt" | sort | uniq -u \
                    | while read -r l; do u=$(grep -oiE 'HD\([0-9]+,GPT,[0-9a-f-]+,' <<<"$l" | cut -d, -f3 | tr '[:upper:]' '[:lower:]'); [ -n "$u" ] && [[ " $parts " != *" $u "* ]] && printf '%s; ' "${l%%$'\t'*}"; done)
                [ -n "$stale" ] && say "  note: firmware entries for partitions no disk here has (stale — the firmware adds and drops those): $stale"
                if [ "$bycode" = 1 ]; then
                    local resigned
                    resigned=$(diff <(awk '/^## files /{f=1; next} /^## /{f=0} f && tolower($0) ~ /\.efi$/' "$TB_STATE/fingerprint-before.txt") \
                                    <(awk '/^## files /{f=1; next} /^## /{f=0} f && tolower($0) ~ /\.efi$/' "$TB_STATE/fingerprint-after.txt") | sed -n 's/^> [0-9a-f]*  //p' | sort -u | tr '\n' ' ')
                    [ -n "$resigned" ] && say "  note: re-signed, same code (this machine's own boot signs its loaders): $resigned"
                fi
                return 0
            fi
            warn "this machine's disks CHANGED:"; cat "$TB_STATE/fingerprint.diff" >&2; return 1 ;;
        before|after) ;;
        *) die "fingerprint before|after|diff" ;;
    esac
    out="$TB_STATE/fingerprint-$tag.txt"; mkdir -p "$TB_STATE"
    {
        for d in $(host_disks); do
            echo "## disk $d serial $(lsblk -dno SERIAL "$d")"
            sfdisk -d "$d" 2>/dev/null | grep -vE '^(last-lba|first-lba):'
            for p in $(lsblk -rnpo NAME,FSTYPE "$d" | awk '$2=="crypto_LUKS"{print $1}'); do
                t=$(mktemp -u /run/tb-hdr.XXXXXX)
                cryptsetup luksHeaderBackup "$p" --header-backup-file "$t" >/dev/null 2>&1 && echo "## LUKS header $p $(sha256sum < "$t" | cut -c1-64)"
                rm -f "$t"
            done
        done
        for m in /boot /efi /boot/efi; do
            mountpoint -q "$m" || continue
            echo "## files $m"; (cd "$m" && find . -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum)
            echo "## efi code $m"; (cd "$m" && find . -xdev -type f -iname '*.efi' -print0 | sort -z | xargs -0 -r python3 -c "$EFI_CODE_HASH")
        done
        [ -d /sys/firmware/efi ] && { echo "## NVRAM"; efibootmgr 2>/dev/null | grep -v '^BootCurrent'; }
        echo "## boot configs"; sha256sum /etc/fstab /etc/crypttab /etc/crypttab.initramfs /etc/kernel/cmdline /etc/default/grub 2>/dev/null
        # this host's volume group metadata backup: the test drive's group once replaced it
        if [ -n "$(layout ROOT_VG)" ]; then
            echo "## LVM metadata backup"
            sed '/^description\|^creation_\|^#/d' "/etc/lvm/backup/$(layout ROOT_VG)" 2>/dev/null | sha256sum | sed "s|-\$|/etc/lvm/backup/$(layout ROOT_VG)|"
        fi
    } > "$out"
    say "fingerprint $tag: $out ($(grep -c . "$out") lines, disks: $(host_disks | tr '\n' ' '))"
    [ "$tag" = before ] && st_set fingerprint-before-at "$(date -Is)"
    return 0
}

# --- plan ---------------------------------------------------------------------------------
cmd_plan() {
    local t size_mib esp boot swap home_fs n=1 uns
    rm -f "$TB_STATE/host-layout"; layout ROOT_FS >/dev/null
    say "this host ($TB_HOST):"; sed 's/^/    /' "$TB_STATE/host-layout"
    # The suite restores these; the test bed cannot lay them out on a test drive yet.
    uns=$(layout_all NOT_MIRRORED); [ -n "$uns" ] && { printf '%s\n' "$uns" | sed 's/^/[testbed] test bed cannot mirror this host yet: /' >&2; return 1; }
    t=$(target_disk); size_mib=$(( $(lsblk -bdno SIZE "$t") / 1048576 ))
    local disk_mib=$size_mib
    [ "$TB_TARGET_GIB" -gt 0 ] 2>/dev/null && [ $(( TB_TARGET_GIB * 1024 )) -lt "$size_mib" ] && size_mib=$(( TB_TARGET_GIB * 1024 ))
    esp=$(layout ESP_MIB); boot=$(layout BOOT_MIB); swap=$(layout SWAP_MIB); home_fs=$(layout HOME_FS)
    : > "$TB_STATE/plan"
    say "test drive: $t ($(lsblk -dno MODEL,SERIAL "$t" | xargs), ${disk_mib} MiB) — the test bed's part: the first ${size_mib} MiB$( [ "$size_mib" -lt "$disk_mib" ] && echo ", the rest left unpartitioned (TB_TARGET_GIB=$TB_TARGET_GIB)"), laid out like this host:"
    if [ "$(layout FIRMWARE)" = bios ]; then echo "PART=$n:bios_grub:1:ef02:-" >> "$TB_STATE/plan"; n=$((n+1)); fi
    [ -n "$esp" ] && { echo "PART=$n:esp:$(( esp < 300 ? 300 : esp )):ef00:$(layout ESP_MOUNT)" >> "$TB_STATE/plan"; n=$((n+1)); }
    [ -n "$boot" ] && { echo "PART=$n:boot:$boot:$(layout BOOT_PARTTYPE):/boot" >> "$TB_STATE/plan"; n=$((n+1)); }
    [ -n "$swap" ] && { echo "PART=$n:swap:$swap:8200:swap" >> "$TB_STATE/plan"; n=$((n+1)); }
    local used=0 v; while IFS=: read -r _ _ v _ _; do used=$((used + v)); done < <(sed -n 's/^PART=//p' "$TB_STATE/plan")
    local rest=$(( size_mib - used - 16 ))
    [ "$rest" -ge 20480 ] || die "only $rest MiB left for the root in the test bed's ${size_mib} MiB — raise TB_TARGET_GIB"
    local rtype=8304; [ -n "$(layout ROOT_VG)" ] && rtype=8e00; [ "$(layout ROOT_CRYPT)" = 1 ] && rtype=8309
    if [ -n "$home_fs" ]; then
        echo "PART=$n:root:$(( rest * 7 / 10 )):$rtype:/" >> "$TB_STATE/plan"; n=$((n+1))
        echo "PART=$n:home:$(( rest - rest * 7 / 10 )):$( [ "$(layout HOME_CRYPT)" = 1 ] && echo 8309 || echo 8302 ):/home" >> "$TB_STATE/plan"
    else
        echo "PART=$n:root:$rest:$rtype:/" >> "$TB_STATE/plan"
    fi
    while IFS=: read -r num role mib type mnt; do
        printf '    p%-2s %-9s %8s  type %s  %s\n' "$num" "$role" "$( [ "$mib" = 0 ] && echo rest || echo "${mib}M")" "$type" "$mnt"
    done < <(sed -n 's/^PART=//p' "$TB_STATE/plan")
    [ "$(layout ROOT_CRYPT)" = 1 ] && say "    root: LUKS$(layout ROOT_LUKS_VERSION) $(layout ROOT_LUKS_PBKDF) (the host's own KDF parameters), passphrase \"test\"$( [ -n "$(layout ROOT_KEYFILE)" ] && echo " + the keyfile $(layout ROOT_KEYFILE) (its crypttab opens it with that)")"
    [ "$(layout BOOT_CRYPT)" = 1 ] && say "    /boot: LUKS$(layout BOOT_LUKS_VERSION) $(layout BOOT_LUKS_PBKDF) (the host's own KDF parameters, so its GRUB can open it), passphrase \"test\"$( [ -n "$(layout BOOT_KEYFILE)" ] && echo " + the keyfile $(layout BOOT_KEYFILE)")"
    if [ -n "$(layout ROOT_VG)" ]; then
        say "    LVM: volume group $(tb_vg) (renamed $(layout ROOT_VG) by finish — this host holds that name while the test runs):"
        layout_all LV | while IFS=: read -r lv mib role; do say "      $lv  $( [ "$role" = root ] && echo rest || echo "${mib}M")  $role"; done
    fi
    [ "$(layout ROOT_FS)" = btrfs ] && say "    btrfs subvolumes: $(layout_all SUBVOL | tr '\n' ' ')"
    say "    report partition on THIS host for the booted test drive: $(layout REPORT_MOUNT) (PARTUUID $(layout REPORT_PARTUUID))"
    return 0
}

# --- prepare: wipe + partition ------------------------------------------------------------------
cmd_prepare() {
    local t; t=$(target_disk)
    cmd_plan >/dev/null || die "plan failed — run: testbed.sh plan"
    [ "${TB_WIPE:-}" = "$TB_TARGET_SERIAL" ] || die "this ERASES $t ($(lsblk -dno MODEL,SIZE "$t" | xargs)). Confirm with TB_WIPE=$TB_TARGET_SERIAL"
    # every tool prepare + format run, checked (and installed) BEFORE the drive is touched
    bx_ensure_deps sgdisk wipefs cryptsetup mkfs.vfat "mkfs.$(layout ROOT_FS)" | sed 's/^/[testbed] /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "missing tools — install them and re-run prepare"
    unmount_target    # a previous run's mounts, volume group and containers on the test drive
    local m; for m in $(lsblk -rnpo MOUNTPOINTS "$t" 2>/dev/null | grep .); do umount "$m" || die "cannot unmount $m on the test drive (a shell inside it?)"; done
    for m in $(lsblk -rnpo NAME,TYPE "$t" | awk '$2=="crypt"{print $1}'); do cryptsetup close "$(basename "$m")" 2>/dev/null; done
    set_sectors "$t"
    wipefs -a "$t"* >/dev/null 2>&1; sgdisk --zap-all "$t" >/dev/null || die "sgdisk --zap-all failed"
    local args=() num role mib type mnt
    while IFS=: read -r num role mib type mnt; do
        if [ "$mib" = 0 ]; then args+=(-n "$num:0:0"); else args+=(-n "$num:0:+${mib}M"); fi
        args+=(-t "$num:$type" -c "$num:tb-$role")
    done < <(sed -n 's/^PART=//p' "$TB_STATE/plan")
    sgdisk "${args[@]}" "$t" >/dev/null || die "sgdisk partitioning failed"
    udevadm settle; sleep 1
    ledger test "test drive $t (serial $TB_TARGET_SERIAL) wiped and partitioned like $TB_HOST" "none — the test drive is wiped again on the next run"
    say "partitioned $t:"; lsblk -o NAME,SIZE,PARTTYPENAME "$t" | sed 's/^/    /'
    st_set target "$t"
}

partdev() { # partdev ROLE — the test drive's partition for a plan role
    local t; t=$(target_disk)
    part "$t" "$(sed -n 's/^PART=//p' "$TB_STATE/plan" | awk -F: -v r="$1" '$2==r{print $1}')"
}
has_role() { sed -n 's/^PART=//p' "$TB_STATE/plan" 2>/dev/null | awk -F: -v r="$1" '$2==r{f=1} END{exit !f}'; }
# The test drive's LVM volume group while the test runs: this host holds its real
# name (and the device-mapper names of its volumes), so it is created as tb-<name>
# and renamed by finish, once it is inactive.
tb_vg() { echo "tb-$(layout ROOT_VG)"; }
root_lv() { layout_all LV | awk -F: '$3=="root"{print $1; exit}'; }
root_pv() { if [ "$(layout ROOT_CRYPT)" = 1 ]; then echo /dev/mapper/tb-root; else partdev root; fi; }
root_blk() { if [ -n "$(layout ROOT_VG)" ]; then echo "/dev/$(tb_vg)/$(root_lv)"; else root_pv; fi; }
boot_blk() { if [ "$(layout BOOT_CRYPT)" = 1 ]; then echo /dev/mapper/tb-boot; else partdev boot; fi; }
# luks_format PREFIX PARTITION MAPPER — a container made the way the host's is
# (version, KDF, memory, threads, time cost), passphrase "test", plus the host's
# keyfile when its crypttab opens the container with one: the restored crypttab
# and initramfs use that keyfile, and the test drive is a copy of this host anyway.
luks_format() {
    local pre="$1" p="$2" name="$3" ver kdf kf args=()
    ver=$(layout "${pre}_LUKS_VERSION"); kdf=$(layout "${pre}_LUKS_PBKDF"); kf=$(layout "${pre}_KEYFILE")
    if [ "${ver:-2}" = 2 ]; then
        args=(--pbkdf "${kdf:-argon2id}")
        if [ "${kdf:-argon2id}" != pbkdf2 ]; then
            [ -n "$(layout "${pre}_LUKS_MEMORY")" ] && args+=(--pbkdf-memory "$(layout "${pre}_LUKS_MEMORY")")
            [ -n "$(layout "${pre}_LUKS_THREADS")" ] && args+=(--pbkdf-parallel "$(layout "${pre}_LUKS_THREADS")")
            [ "$(layout "${pre}_LUKS_TIME")" -gt 0 ] 2>/dev/null && args+=(--pbkdf-force-iterations "$(layout "${pre}_LUKS_TIME")")
        fi
    fi
    printf '%s' "$TB_PASSPHRASE" | cryptsetup luksFormat --batch-mode --type "luks${ver:-2}" "${args[@]}" --key-file=- "$p" || die "luksFormat $p"
    if [ -n "$kf" ]; then
        printf '%s' "$TB_PASSPHRASE" | cryptsetup luksAddKey --batch-mode "${args[@]}" --key-file=- "$p" "$kf" || die "luksAddKey $kf → $p"
    fi
    printf '%s' "$TB_PASSPHRASE" | cryptsetup open --key-file=- "$p" "$name" || die "open $name"
    ledger test "LUKS${ver:-2} (${kdf:-argon2id}) on $p opened as $name, passphrase \"test\"${kf:+ + the keyfile of this host, $kf}" "revert closes it"
}
# open_target — the test drive's containers and volume group, before finish renames it
open_target() {
    if [ "$(layout ROOT_CRYPT)" = 1 ] && [ ! -e /dev/mapper/tb-root ]; then
        printf '%s' "$TB_PASSPHRASE" | cryptsetup open --key-file=- "$(partdev root)" tb-root || die "open $(partdev root)"
    fi
    if has_role boot && [ "$(layout BOOT_CRYPT)" = 1 ] && [ ! -e /dev/mapper/tb-boot ]; then
        printf '%s' "$TB_PASSPHRASE" | cryptsetup open --key-file=- "$(partdev boot)" tb-boot || die "open $(partdev boot)"
    fi
    if [ -n "$(layout ROOT_VG)" ] && [ ! -e "$(root_blk)" ]; then
        vgchange "${TB_LVM[@]}" -ay --devices "$(root_pv)" "$(tb_vg)" >/dev/null || die "volume group $(tb_vg) not found on $(root_pv) — after finish it is called $(layout ROOT_VG); collect reads it without activating it"
    fi
    return 0
}

# --- format -----------------------------------------------------------------------------------------
cmd_format() {
    [ -f "$TB_STATE/plan" ] || die "no plan — run prepare first"
    local p root_blk sv mnt name lv mib role
    has_role esp  && { mkfs.vfat -F 32 -n TB-ESP "$(partdev esp)" >/dev/null || die "mkfs ESP"; }
    if has_role boot; then
        p=$(partdev boot)
        [ "$(layout BOOT_CRYPT)" = 1 ] && { luks_format BOOT "$p" tb-boot; p=/dev/mapper/tb-boot; }
        case "$(layout BOOT_FS)" in vfat) mkfs.vfat -F 32 -n TB-BOOT "$p" >/dev/null ;; *) "mkfs.$(layout BOOT_FS)" -q -F -L tb-boot "$p" >/dev/null 2>&1 || "mkfs.$(layout BOOT_FS)" -f -L tb-boot "$p" >/dev/null ;; esac || die "mkfs /boot"
    fi
    has_role swap && { mkswap -L tb-swap "$(partdev swap)" >/dev/null || die "mkswap"; }
    p=$(partdev root)
    [ "$(layout ROOT_CRYPT)" = 1 ] && luks_format ROOT "$p" tb-root
    if [ -n "$(layout ROOT_VG)" ]; then
        pvcreate "${TB_LVM[@]}" -ff -y "$(root_pv)" >/dev/null && vgcreate "${TB_LVM[@]}" "$(tb_vg)" "$(root_pv)" >/dev/null || die "LVM volume group $(tb_vg) on $(root_pv)"
        while IFS=: read -r lv mib role; do    # fixed-size volumes first, the root takes the rest
            [ "$role" = root ] && continue
            lvcreate "${TB_LVM[@]}" -y -W y -n "$lv" -L "${mib}m" "$(tb_vg)" >/dev/null || die "lvcreate $lv"
            [ "$role" = swap ] && { mkswap "/dev/$(tb_vg)/$lv" >/dev/null || die "mkswap $lv"; }
        done < <(layout_all LV)
        lvcreate "${TB_LVM[@]}" -y -W y -n "$(root_lv)" -l 100%FREE "$(tb_vg)" >/dev/null || die "lvcreate $(root_lv)"
        ledger test "LVM volume group $(tb_vg) on $(root_pv): $(layout_all LV | cut -d: -f1 | tr '\n' ' ')" "renamed $(layout ROOT_VG) by finish; wiped with the drive on the next run"
    fi
    root_blk=$(root_blk)
    case "$(layout ROOT_FS)" in
        btrfs) mkfs.btrfs -q -f -L tb-root "$root_blk" >/dev/null ;;
        xfs)   mkfs.xfs -q -f -L tb-root "$root_blk" ;;
        *)     "mkfs.$(layout ROOT_FS)" -q -F -L tb-root "$root_blk" ;;
    esac || die "mkfs root"
    if [ "$(layout ROOT_FS)" = btrfs ]; then
        mkdir -p /run/tb-top; mount "$root_blk" /run/tb-top || die "mount top level"
        while IFS='=' read -r mnt sv; do
            name=${sv#/}; [ -n "$name" ] || continue
            mkdir -p "/run/tb-top/$(dirname "$name")"
            btrfs subvolume create "/run/tb-top/$name" >/dev/null || die "subvolume $name"
        done < <(layout_all SUBVOL)
        umount /run/tb-top
    fi
    if has_role home; then
        p=$(partdev home)
        if [ "$(layout HOME_CRYPT)" = 1 ]; then
            printf '%s' "$TB_PASSPHRASE" | cryptsetup luksFormat --batch-mode --type luks2 --key-file=- "$p" && printf '%s' "$TB_PASSPHRASE" | cryptsetup open --key-file=- "$p" tb-home || die "LUKS /home"
            p=/dev/mapper/tb-home
        fi
        "mkfs.$(layout HOME_FS)" -q -F -L tb-home "$p" >/dev/null 2>&1 || "mkfs.$(layout HOME_FS)" -q -f -L tb-home "$p" || die "mkfs /home"
    fi
    say "formatted:"; lsblk -o NAME,SIZE,FSTYPE,LABEL "$(target_disk)" | sed 's/^/    /'
}

# --- mount -------------------------------------------------------------------------------------------
cmd_mount() {
    [ -f "$TB_STATE/plan" ] || die "no plan"
    local root_blk mnt sv
    open_target; root_blk=$(root_blk)
    [ -b "$root_blk" ] || die "$root_blk is not there (run: testbed.sh format)"
    mkdir -p "$TB_MNT"
    if [ "$(layout ROOT_FS)" = btrfs ]; then
        sv=$(layout_all SUBVOL | awk -F= '$1=="/"{print $2}')
        mountpoint -q "$TB_MNT" || mount -o "subvol=${sv:-/}" "$root_blk" "$TB_MNT" || die "mount root"
        while IFS='=' read -r mnt sv; do
            [ "$mnt" = / ] && continue
            mkdir -p "$TB_MNT$mnt"; mountpoint -q "$TB_MNT$mnt" || mount -o "subvol=$sv" "$root_blk" "$TB_MNT$mnt" || die "mount $mnt"
        done < <(layout_all SUBVOL | sort -t= -k1,1)
    else
        mountpoint -q "$TB_MNT" || mount "$root_blk" "$TB_MNT" || die "mount root"
    fi
    if has_role home; then local h; h=$(partdev home); [ "$(layout HOME_CRYPT)" = 1 ] && h=/dev/mapper/tb-home; mkdir -p "$TB_MNT/home"; mountpoint -q "$TB_MNT/home" || mount "$h" "$TB_MNT/home" || die "mount /home"; fi
    if has_role boot; then mkdir -p "$TB_MNT/boot"; mountpoint -q "$TB_MNT/boot" || mount "$(boot_blk)" "$TB_MNT/boot" || die "mount /boot"; fi
    if has_role esp; then local e; e=$(layout ESP_MOUNT); mkdir -p "$TB_MNT$e"; mountpoint -q "$TB_MNT$e" || mount "$(partdev esp)" "$TB_MNT$e" || die "mount ESP"; fi
    ledger test "target tree mounted at $TB_MNT" "revert unmounts it"
    say "mounted:"; findmnt -R -o TARGET,SOURCE,FSTYPE "$TB_MNT" | sed 's/^/    /'
}

# --- backup: the TEST archive ---------------------------------------------------------------------------
freeze_suite() { # a copy of the suite the test runs from — editing the checkout mid-run cannot reach it
    [ -d "$TB_STATE/suite" ] && return 0
    mkdir -p "$TB_STATE/suite"
    if git -C "$SUITE" rev-parse --git-dir >/dev/null 2>&1 && [ -z "$(git -C "$SUITE" status --porcelain -- '*.sh' 2>/dev/null)" ]; then
        git -C "$SUITE" archive HEAD | tar -x -C "$TB_STATE/suite"
        st_set suite-version "$(git -C "$SUITE" describe --tags --always 2>/dev/null) ($(git -C "$SUITE" rev-parse --short HEAD))"
    else
        cp -a "$SUITE"/. "$TB_STATE/suite/"; rm -rf "$TB_STATE/suite/.git"
        st_set suite-version "$BX_VERSION (working tree copy, uncommitted changes)"
    fi
    say "suite frozen for this test: $(st_get suite-version)"
}
cmd_backup() {
    local mode="${1:-functional}" keep_inc="" k ex
    mountpoint -q "$BACKUP_MOUNT" || die "backup drive not mounted at $BACKUP_MOUNT"
    case "$mode" in functional|minimal) ;; *) die "backup functional|minimal" ;; esac
    freeze_suite
    ex="/home/*/* $TB_BIG_EXCLUDES $TB_EXTRA_EXCLUDES"
    if [ "$mode" = functional ]; then for k in $TB_HOME_KEEP; do keep_inc="$keep_inc /home/*/$k"; done; fi
    set_sectors "$(bx_disk_of "$(findmnt -no SOURCE "$BACKUP_MOUNT" | sed 's/\[.*//')")"
    st_set backup-mode "$mode"
    say "TEST archive ($mode) → $TB_REPO"
    ledger test "TEST archive ($mode) in $TB_REPO; excludes on the command line only, /etc/backup-system.conf untouched; no btrfs replicas (BX_NO_REPLICAS=1: the drive's shared replica directory is neither written nor pruned)" "revert deletes $TB_REPO (revert --keep-repo keeps it)"
    # The backup drive may be another machine's production drive: the test run
    # writes only to its own repository. Replicas live in one directory shared by
    # every host and are pruned by label — skipped.
    env BX_NO_REPLICAS=1 BORG_REPO="$TB_REPO" BACKUP_EXTRA_EXCLUDES="$ex" BACKUP_EXTRA_INCLUDES="${keep_inc# }" \
        "$TB_STATE/suite/borg-backup.sh" > "$TB_STATE/backup.log" 2>&1
    local brc=$?
    tail -3 "$TB_STATE/backup.log"
    # rc 3 = the btrfs replica layer did not fully succeed; the archive is complete
    [ "$brc" -eq 0 ] || [ "$brc" -eq 3 ] || die "test backup failed (rc=$brc) — $TB_STATE/backup.log"
    st_set archive "$(BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes borg list --last 1 --short "$TB_REPO")"
    say "archive: $(st_get archive)"
}

# --- restore ----------------------------------------------------------------------------------------------
cmd_restore() {
    local a; a=$(st_get archive); [ -n "$a" ] || die "no test archive — run backup first"
    mountpoint -q "$TB_MNT" || die "target not mounted — run mount first"
    freeze_suite
    say "dry run ..."
    "$TB_STATE/suite/borg-restore.sh" --dry-run "$TB_MNT" "$TB_REPO" "$a" < /dev/null > "$TB_STATE/restore-dry.log" 2>&1 || die "restore dry run failed — $TB_STATE/restore-dry.log"
    say "restore ($a) ..."
    "$TB_STATE/suite/borg-restore.sh" "$TB_MNT" "$TB_REPO" "$a" < /dev/null > "$TB_STATE/restore.log" 2>&1
    local rrc=$?
    # the verification's own lines only: borg's file list names MEMORY_FAILURE, CURLOPT_FAILONERROR.3 …
    sed 's/\x1b\[[0-9;]*m//g' "$TB_STATE/restore.log" | grep -E '^[[:space:]]+FAIL:|ERROR\(S\)|ALL CHECKS|WARNING\(S\)' | tail -12
    st_set restore-rc "$rrc"
    [ "$rrc" -eq 0 ] || warn "restore exited $rrc — $TB_STATE/restore.log"
}

# --- finish: manifest, homes, logger ----------------------------------------------------------------------
cmd_finish() {
    local a uid gid hd
    rm -f "$TB_STATE/auto-unlock"
    # A restore whose verification failed boots nothing worth a verdict.
    [ "$(st_get restore-rc)" = 0 ] || [ "${TB_FORCE:-}" = 1 ] || die "the restore exited $(st_get restore-rc || echo '(never ran)') — its checks failed ($TB_STATE/restore.log); fix and run restore again (TB_FORCE=1 finishes anyway)"
    a=$(st_get archive); mountpoint -q "$TB_MNT" || die "target not mounted"
    mkdir -p "$TB_MNT/root/restore-test"
    # finish again (a fix to the test drive after a failed test boot) runs with the
    # backup drive already unplugged for that boot: the manifest of this archive
    # is in the state directory from the first finish.
    if [ ! -d "$TB_REPO" ] && [ -s "$TB_STATE/manifest.tsv.gz" ]; then
        cp "$TB_STATE/manifest.tsv.gz" "$TB_MNT/root/restore-test/manifest.tsv.gz" || die "manifest"
        say "backup drive not connected — the manifest of $a from the first finish is used"
    else
        BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes borg list --format '{type}{TAB}{size}{TAB}{path}{NL}' "$TB_REPO::$a" | gzip -1 > "$TB_MNT/root/restore-test/manifest.tsv.gz" || die "manifest"
        cp "$TB_MNT/root/restore-test/manifest.tsv.gz" "$TB_STATE/manifest.tsv.gz"
    fi
    # Homes whose contents were not in the archive: from /etc/skel, so logins work.
    while IFS=: read -r _ _ uid gid _ hd _; do
        [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [ "${hd#/home/}" != "$hd" ] || continue
        [ -d "$TB_MNT$hd" ] || { cp -a "$TB_MNT/etc/skel" "$TB_MNT$hd" 2>/dev/null || mkdir -p "$TB_MNT$hd"; }
        chown "$uid:$gid" "$TB_MNT$hd"; chmod 700 "$TB_MNT$hd"
    done < "$TB_MNT/etc/passwd"
    # The logger and what it needs to know.
    install -m 755 "$TB_DIR/boot-logger.sh" "$TB_MNT/usr/local/sbin/testbed-boot-logger.sh"
    install -m 644 "$TB_DIR/compare-manifest.py" "$TB_MNT/root/restore-test/compare-manifest.py"
    install -m 644 "$TB_DIR/testbed-boot-logger.service" "$TB_MNT/etc/systemd/system/testbed-boot-logger.service"
    mkdir -p "$TB_MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/testbed-boot-logger.service "$TB_MNT/etc/systemd/system/multi-user.target.wants/testbed-boot-logger.service"
    {
        echo "TEST_SERIAL=$TB_TARGET_SERIAL"
        echo "HOST=$TB_HOST"
        echo "HOST_DISK_SERIALS=\"$(for d in $(host_disks); do lsblk -dno SERIAL "$d"; done | tr '\n' ' ')\""
        echo "REPORT_PARTUUID=$(layout REPORT_PARTUUID)"
        echo "STAMP=$(basename "$TB_STATE")"
    } > "$TB_MNT/root/restore-test/testbed.env"
    ledger test "test drive: boot logger enabled, manifest + testbed.env in /root/restore-test" "lives on the test drive only"
    # A UKI no generator rebuilt keeps the host disk's ids (restore verification
    # names it); it would boot THIS machine's disk from the test drive's menu. Park it.
    local f
    while read -r f; do
        grep -q "FAIL: ${f#"$TB_MNT"} embeds" <(sed 's/\x1b\[[0-9;]*m//g' "$TB_STATE/restore.log" 2>/dev/null) || continue
        mv "$f" "$TB_MNT/root/restore-test/$(basename "$f").parked"
        ledger test "test drive: stale UKI ${f#"$TB_MNT"} parked in /root/restore-test (it names this machine's disk)" "test drive only"
        say "parked stale UKI ${f#"$TB_MNT"}"
    done < <(cl_ukis "$TB_MNT")
    auto_unlock_grub
    preflight_grub_unlock
    mirror_firmware_entry
    park_shim_fallback
    mark_test_drive_picker
    isolate_other_disks
    # The restored boot configuration must name the volume group by its real name:
    # the temporary one exists only while this test bed runs.
    if [ -n "$(layout ROOT_VG)" ] && grep -rlsF "/dev/mapper/$(tb_vg | sed 's/-/--/g')-" "$TB_MNT/boot/grub" "$TB_MNT/boot/grub2" "$TB_MNT/etc/fstab" "$TB_MNT/etc/default/grub" "$TB_MNT/etc/initramfs-tools/conf.d" 2>/dev/null | grep -q .; then
        warn "the restored boot configuration names the test bed's temporary volume group $(tb_vg): $(grep -rlsF "/dev/mapper/$(tb_vg | sed 's/-/--/g')-" "$TB_MNT/boot/grub" "$TB_MNT/boot/grub2" "$TB_MNT/etc" 2>/dev/null | sed "s#^$TB_MNT##" | tr '\n' ' ')— it will not boot"
    fi
    sync
    say "unmounting and closing the test drive ..."
    unmount_mounts
    if [ -n "$(layout ROOT_VG)" ] && vgs "${TB_LVM[@]}" --devices "$(root_pv)" "$(tb_vg)" >/dev/null 2>&1; then
        vgchange "${TB_LVM[@]}" -an --devices "$(root_pv)" "$(tb_vg)" >/dev/null || die "cannot deactivate $(tb_vg) (still in use?)"
        # vgrename refuses a name /dev already has (this host's group), and
        # vgcfgrestore's "active volumes" question counts this host's volumes by
        # name. The metadata goes only to the test drive's physical volume
        # (--devices): back it up, rename it in the file, write it back there.
        local vgf; vgf=$(mktemp /run/tb-vg.XXXXXX)
        vgcfgbackup "${TB_LVM[@]}" --devices "$(root_pv)" -f "$vgf" "$(tb_vg)" >/dev/null || die "cannot back up the metadata of $(tb_vg)"
        sed -i "s/^$(tb_vg) {\$/$(layout ROOT_VG) {/" "$vgf"
        grep -q "^$(layout ROOT_VG) {\$" "$vgf" || die "renaming $(tb_vg) in its metadata backup failed ($vgf)"
        echo y | vgcfgrestore "${TB_LVM[@]}" --devices "$(root_pv)" -f "$vgf" "$(layout ROOT_VG)" >/dev/null 2>&1 \
            && vgs "${TB_LVM[@]}" --devices "$(root_pv)" "$(layout ROOT_VG)" >/dev/null 2>&1 || die "cannot rename $(tb_vg) → $(layout ROOT_VG) on $(root_pv) (metadata: $vgf)"
        rm -f "$vgf"
        ledger test "test drive: volume group $(tb_vg) renamed $(layout ROOT_VG), the name the restored system mounts" "test drive only"
        say "volume group $(tb_vg) renamed $(layout ROOT_VG) (inactive; this host never activates it)"
    fi
    unmount_target
    cmd_fingerprint after >/dev/null
    cmd_fingerprint diff || warn "this machine changed during the test — see $TB_STATE/fingerprint.diff"
    cp "$TB_STATE/fingerprint-after.txt" "$TB_STATE/fingerprint-preboot.txt"
    # The test drive booted in a VM first: a drive that cannot boot is found here,
    # not by someone at the firmware menu of this machine.
    if [ "${TB_VMBOOT:-1}" != 0 ]; then
        cmd_vmboot
        case "$(st_get vmboot)" in
            PASS) ;;
            SKIPPED) warn "the VM boot was skipped ($(st_get vmboot-why)) — the real boot is the first boot of this drive" ;;
            *) die "the test drive did not boot in the VM — do not boot it for real yet; evidence: $TB_STATE/vm (TB_VMBOOT=0 skips this check)" ;;
        esac
    fi
    local pick='on a UEFI host the entry that starts with
     "UEFI:" (the plain one is the legacy BIOS entry and does not boot a UEFI test drive)'
    grep -qi apple /sys/class/dmi/id/sys_vendor 2>/dev/null && pick='hold Option (⌥) at power-on and pick the drive labelled TEST'
    # The VM boot ran the relabel on a throwaway overlay: /.autorelabel is still
    # on the drive, and the real first boot relabels and reboots — into this
    # machine's own disk unless the test drive is picked again.
    sed 's/\x1b\[[0-9;]*m//g' "$TB_STATE/restore.log" 2>/dev/null | grep -q 'created /.autorelabel' && pick="$pick
     (SELinux relabel boot: it relabels every file and reboots once — pick the test drive again)"
    cat <<MSG

[testbed] Ready to boot the test drive.
  1. Leave only the test drive connected (serial $TB_TARGET_SERIAL).
  2. Reboot, pick it from the firmware boot menu — $pick; $( [ "$(st_get auto-unlock)" = grub ] && echo "it unlocks itself (built-in passphrase: test) and its GRUB first prints \"TEST DRIVE\"" || echo "the passphrase is: test")
  3. Wait ~2 minutes after the login screen appears (the logger writes its report to
     this machine's $(layout REPORT_MOUNT) — PARTUUID $(layout REPORT_PARTUUID)).
  4. Boot back into this machine and run:  sudo $0 collect
MSG
}
# auto_unlock_grub — TEST DRIVES ONLY: the test drive boots unattended. GRUB
# asks for a passphrase for every container it opens: the encrypted /boot, and
# the root too where grub.cfg names it (grub-mkconfig adds `cryptomount -u` for
# a root on LUKS). The initramfs and systemd then open theirs with the keyfile
# the restored crypttab names.
# The core image the restore installed at the firmware's fallback path
# (EFI/BOOT/BOOTX64.EFI) is rebuilt, inside the restored system with its own
# GRUB, with the same prefix and early config plus the built-in passphrase
# "test" (cryptomount -p, GRUB >= 2.12). The restore's own image is kept in
# /root/restore-test and at EFI/<id>/grubx64.efi, untouched.
auto_unlock_grub() {
    local esp u loader mods moddir kv
    [ "$(layout BOOT_CRYPT)" = 1 ] && [ "$(layout FIRMWARE)" = uefi ] || return 0
    esp="$TB_MNT$(layout ESP_MOUNT)"; loader="$esp/EFI/BOOT/BOOTX64.EFI"
    [ -f "$loader" ] && [ -d "$TB_MNT/boot/grub" ] || { warn "auto-unlock: no GRUB fallback loader at ${loader#"$TB_MNT"} — the test boot asks for the passphrase (test)"; return 0; }
    u=$(cryptsetup luksUUID "$(partdev boot)" 2>/dev/null) || return 0
    local p all=""
    for p in $(lsblk -rnpo NAME,FSTYPE "$(target_disk)" | awk '$2=="crypto_LUKS"{print $1}'); do all="$all $(cryptsetup luksUUID "$p")"; done
    # The modules and the grub-mkimage of ONE install: /usr/local's modules
    # packed by the distro's grub2-mkimage (or the reverse) is a mismatched image.
    local mkimage=""
    for moddir in /usr/local/lib/grub/x86_64-efi /usr/lib/grub/x86_64-efi; do
        [ -f "$TB_MNT$moddir/cryptodisk.mod" ] || continue
        for mkimage in "${moddir%/lib/grub/x86_64-efi}"/bin/grub-mkimage "${moddir%/lib/grub/x86_64-efi}"/bin/grub2-mkimage; do
            [ -x "$TB_MNT$mkimage" ] && break; mkimage=""
        done
        [ -n "$mkimage" ] && break
    done
    [ -n "$mkimage" ] || { warn "auto-unlock: no x86_64-efi GRUB modules with their grub-mkimage in the restored system"; return 0; }
    kv=$(chroot "$TB_MNT" "$mkimage" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -z "$kv" ] || [ "$(printf '2.12\n%s\n' "$kv" | sort -V | head -1)" != 2.12 ]; then
        warn "auto-unlock: GRUB ${kv:-?} in the restored system has no cryptomount -p (needs 2.12) — the test boot asks for the passphrase (test)"; return 0
    fi
    mods="part_gpt part_msdos cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha512 pbkdf2 ext2 fat lvm search search_fs_uuid normal configfile echo sleep"
    [ -f "$TB_MNT$moddir/argon2.mod" ] && mods="$mods argon2"
    mkdir -p "$TB_MNT/root/restore-test"
    [ -f "$TB_MNT/root/restore-test/BOOTX64.EFI.restored" ] || cp "$loader" "$TB_MNT/root/restore-test/BOOTX64.EFI.restored"
    # shellcheck disable=SC2086
    grub_early_cfg "$u" $all > "$TB_MNT/root/restore-test/grub-early.cfg"
    # shellcheck disable=SC2086
    if chroot "$TB_MNT" "$mkimage" -d "$moddir" -O x86_64-efi -c /root/restore-test/grub-early.cfg \
            -p "(cryptouuid/${u//-/})/grub" -o "$(layout ESP_MOUNT)/EFI/BOOT/BOOTX64.EFI" $mods; then
        ledger test "test drive: EFI/BOOT/BOOTX64.EFI rebuilt with the built-in passphrase \"test\" for its LUKS containers ($(echo $all)) — the drive boots unattended" "test drive only; the restore's image is /root/restore-test/BOOTX64.EFI.restored"
        say "auto-unlock: the test drive's fallback loader opens /boot with the built-in passphrase — no prompt at boot"
        st_set auto-unlock grub
    else
        cp "$TB_MNT/root/restore-test/BOOTX64.EFI.restored" "$loader"
        warn "auto-unlock: grub-mkimage failed — the restore's loader is back in place; the test boot asks for the passphrase (test)"
    fi
    return 0
}
# grub_early_cfg BOOT_UUID [UUID...] — the config built into the test loader:
# /boot's container first (the prefix lives there), then every other one. GRUB
# runs a built-in config through its RESCUE parser (kern/parser.c,
# grub_rescue_parse_line), before normal.mod exists: one plain command per line.
# `if cryptomount …; then … fi` there is not a command — nothing was unlocked
# and the test boot stopped at the grub> prompt. The banner says which loader
# is running; cryptomount prints its own error if a container does not open.
grub_early_cfg() {
    local u="$1" p
    shift
    printf 'echo "linux-backup-system TEST DRIVE %s: opening its LUKS containers with the built-in passphrase"\n' "$TB_TARGET_SERIAL"
    printf 'cryptomount -u %s -p %s\n' "$u" "$TB_PASSPHRASE"
    for p in "$@"; do [ "$p" = "$u" ] || printf 'cryptomount -u %s -p %s\n' "$p" "$TB_PASSPHRASE"; done
}
# preflight_grub_unlock — before anyone reboots: GRUB's own crypto code (the
# grub-fstest of the install the test loader was built from) opens each LUKS
# container of the test drive with the passphrase "test" — and /boot's files are
# readable through it. A failure here is a test boot that stops at a prompt.
preflight_grub_unlock() {
    local fstest="" d p u out bad=0
    [ "$(layout BOOT_CRYPT)" = 1 ] || [ "$(layout ROOT_CRYPT)" = 1 ] || return 0
    # An encrypted root beside a plain /boot (or /boot on the ESP) is opened by
    # the initramfs, not by GRUB: nothing for GRUB to open — and a distro GRUB
    # without argon2 "failed" on a root it never reads.
    if [ "$(layout BOOT_CRYPT)" != 1 ] && { [ -n "$(layout BOOT_FS)" ] || [ "$(layout ESP_MOUNT)" = /boot ]; }; then
        return 0
    fi
    for d in /usr/local/bin /usr/bin; do
        for p in grub-fstest grub2-fstest; do [ -x "$d/$p" ] && { fstest="$d/$p"; break 2; }; done
    done
    [ -n "$fstest" ] || { warn "preflight: no grub-fstest on this machine — GRUB's unlock of the test drive is not checked before the boot"; return 0; }
    for p in $(lsblk -rnpo NAME,FSTYPE "$(target_disk)" | awk '$2=="crypto_LUKS"{print $1}'); do
        u=$(cryptsetup luksUUID "$p" 2>/dev/null) || continue
        out=$(printf '%s\n' "$TB_PASSPHRASE" | timeout 600 "$fstest" -C "$p" ls "(cryptouuid/${u//-/})/" 2>&1)
        if grep -q 'opened' <<<"$out"; then
            say "preflight: GRUB ($fstest) opens $p ($u) with the passphrase \"test\""
        else
            warn "preflight: GRUB ($fstest) could NOT open $p ($u) with the passphrase \"test\": $(tail -2 <<<"$out" | tr '\n' ' ')"; bad=1
        fi
    done
    st_set preflight-grub-unlock "$([ "$bad" = 0 ] && echo ok || echo FAILED)"
    return 0
}
# mark_test_drive_picker — TEST DRIVES ONLY: the restore copies the ESP's
# decorations too, so on a Mac the firmware boot menu (Option key) showed the
# test drive exactly like this machine's own disk — same volume icon, same
# label — and the wrong one got picked. The test drive's loader directory gets
# the label TEST (.disk_label rendered by grub-render-label, .disk_label_2x,
# .disk_label.contentDetails) and the restored volume icon is parked, so the
# menu shows a plain drive icon named TEST. Harmless on other firmware.
mark_test_drive_picker() {
    local esp dir render="" font="" f
    [ "$(layout FIRMWARE)" = uefi ] || return 0
    esp="$TB_MNT$(layout ESP_MOUNT)"; dir="$esp/EFI/BOOT"
    [ -d "$dir" ] || return 0
    mkdir -p "$TB_MNT/root/restore-test"
    if [ -f "$esp/.VolumeIcon.icns" ]; then
        mv -f "$esp/.VolumeIcon.icns" "$TB_MNT/root/restore-test/VolumeIcon.icns.parked"
        ledger test "test drive: ESP volume icon parked in /root/restore-test (the firmware menu showed it like this machine's disk)" "test drive only"
    fi
    for f in grub-render-label grub2-render-label; do command -v "$f" >/dev/null 2>&1 && { render=$(command -v "$f"); break; }; done
    for f in /usr/share/grub/unicode.pf2 /usr/share/grub2/unicode.pf2 /usr/local/share/grub/unicode.pf2 /boot/grub/fonts/unicode.pf2 /boot/grub2/fonts/unicode.pf2; do
        [ -r "$f" ] && { font=$f; break; }
    done
    printf 'TEST' > "$dir/.disk_label.contentDetails"
    if [ -n "$render" ] && [ -n "$font" ] && "$render" -f "$font" -t TEST -b '#cccccc' -c black -o "$dir/.disk_label" 2>/dev/null; then
        cp -f "$dir/.disk_label" "$dir/.disk_label_2x"
        say "firmware boot menu: the test drive is labelled TEST (plain drive icon)"
    else
        rm -f "$dir/.disk_label" "$dir/.disk_label_2x"
        warn "no grub-render-label or unicode.pf2 — the test drive's firmware menu entry is not labelled TEST (its volume icon is parked, so it still differs)"
    fi
    ledger test "test drive: firmware boot menu label TEST in EFI/BOOT" "test drive only"
    return 0
}
# mirror_firmware_entry — TEST DRIVES ONLY: this machine boots through its
# firmware entry (FW_LOADER); the test drive, which gets no entry, is picked by
# its fallback path EFI/BOOT/BOOT<arch>.EFI. Where the entry starts shim and the
# fallback does not, the test boot skipped shim: no MOK keys in the kernel, and
# the modules signed with them (nvidia, zfs) were rejected — a failure of the
# test path, not of the restore. The fallback is made to start the same chain:
# the entry's shim, with its chain target (grub<arch>.efi) beside it; a
# systemd-boot-update drop-in on the test drive keeps it so across boots, after
# the restored system's own drop-ins rewrite the fallback. Originals are kept
# in /root/restore-test.
mirror_firmware_entry() {
    local espm esp fl src tgt a fb
    [ "$(layout FIRMWARE)" = uefi ] || return 0
    fl=$(layout FW_LOADER); [ -n "$fl" ] || return 0
    case "$(uname -m)" in x86_64) a=x64 ;; aarch64) a=aa64 ;; *) return 0 ;; esac
    espm=$(layout ESP_MOUNT); esp="$TB_MNT$espm"
    src="$esp$fl"; tgt="$(dirname "$src")/grub$a.efi"; fb="$esp/EFI/BOOT/BOOT${a^^}.EFI"
    [ -f "$src" ] && [ -f "$fb" ] || return 0
    grep -aq MokListRT "$src" && ! grep -aq MokListRT "$fb" || return 0
    # the boot logger tells a restore fault from a test path without shim
    grep -qx 'SOURCE_SHIM=1' "$TB_MNT/root/restore-test/testbed.env" 2>/dev/null || echo 'SOURCE_SHIM=1' >> "$TB_MNT/root/restore-test/testbed.env"
    # Acer's Insyde firmware turns any \EFI\Boot\grubx64.efi it sees into a
    # "Linpus lite" boot entry of its own, first in BootOrder — an NVRAM write on
    # this machine, and that entry starts systemd-boot without shim anyway.
    if grep -qi '^acer' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        warn "Acer firmware: shim cannot be put on the test drive's fallback path (the firmware makes a boot entry for EFI/BOOT/grub$a.efi) — the test boot has no MOK keys; modules signed with them (nvidia, zfs) are reported as not verifiable by this test"
        return 0
    fi
    [ -f "$tgt" ] || { warn "firmware entry $fl is shim, but its chain target ${tgt#"$esp"} is not on the test drive — the fallback path stays as restored (no MOK keys on the test boot)"; return 0; }
    mkdir -p "$TB_MNT/root/restore-test"
    [ -f "$TB_MNT/root/restore-test/BOOT${a^^}.EFI.fallback" ] || cp "$fb" "$TB_MNT/root/restore-test/BOOT${a^^}.EFI.fallback"
    cp -f "$src" "$fb" && cp -f "$tgt" "$esp/EFI/BOOT/grub$a.efi" || { warn "could not put the shim chain on the fallback path"; return 0; }
    if [ -f "$TB_MNT/usr/lib/systemd/system/systemd-boot-update.service" ]; then
        mkdir -p "$TB_MNT/etc/systemd/system/systemd-boot-update.service.d"
        cat > "$TB_MNT/etc/systemd/system/systemd-boot-update.service.d/zz-testbed-fallback-shim.conf" <<EOF
# linux-backup-system TEST DRIVE only (testbed.sh finish): the fallback path starts
# the chain the source machine's firmware entry starts ($fl).
[Service]
ExecStartPost=-/usr/bin/cp -f $espm$fl $espm/EFI/BOOT/BOOT${a^^}.EFI
ExecStartPost=-/usr/bin/cp -f ${tgt#"$TB_MNT"} $espm/EFI/BOOT/grub$a.efi
EOF
    fi
    ledger test "test drive: fallback EFI/BOOT/BOOT${a^^}.EFI starts shim like this machine's firmware entry ($fl), chain target grub$a.efi beside it; drop-in zz-testbed-fallback-shim.conf keeps it" "test drive only; the restored fallback is /root/restore-test/BOOT${a^^}.EFI.fallback"
    say "test drive: fallback path starts shim, as this machine's firmware entry $fl does (MOK keys for nvidia/zfs)"
    return 0
}
# park_shim_fallback — TEST DRIVES ONLY: shim started as EFI/BOOT/BOOT<arch>.EFI
# runs fb<arch>.efi first when it sits beside it, and fallback CREATES a firmware
# boot entry (from EFI/<id>/BOOT<arch>.CSV) before booting — a write to THIS
# machine's NVRAM, which the verdict forbids. A real restore keeps it: on the
# machine the disk goes into, that entry is what it should get. The file is
# kept in /root/restore-test.
park_shim_fallback() {
    local esp f
    [ "$(layout FIRMWARE)" = uefi ] || return 0
    esp="$TB_MNT$(layout ESP_MOUNT)"
    for f in "$esp"/EFI/BOOT/fb*.efi "$esp"/EFI/BOOT/FB*.EFI; do
        [ -f "$f" ] || continue
        mkdir -p "$TB_MNT/root/restore-test"
        mv -f "$f" "$TB_MNT/root/restore-test/$(basename "$f").parked"
        ledger test "test drive: shim fallback ${f#"$TB_MNT"} parked in /root/restore-test — it would write a firmware boot entry on this machine" "test drive only"
        say "parked shim fallback ${f#"$TB_MNT"} (the test boot writes no firmware entry)"
    done
    return 0
}
# isolate_other_disks — TEST DRIVES ONLY: the restored crypttab and fstab still
# name this machine's other disks — a data drive, an SD card — and the restore
# brought their keyfiles along, so the booted test drive unlocked them
# (EndeavourOS: a nofail crypttab entry opened the host's SD card, and the boot
# report FAILed "source-machine containers open"). Every entry whose device
# resolves, here, to a disk other than the test drive gets noauto on the test
# drive; so does an fstab entry on one of those containers. A real restore keeps
# them: the restore itself is right to leave them alone. The restored files are
# kept in /root/restore-test.
isolate_other_disks() {
    local t f line dev name opts disk names=" " n=0 a=()
    t=$(target_disk)
    for f in crypttab fstab; do
        [ -f "$TB_MNT/etc/$f" ] || continue
        [ -f "$TB_MNT/root/restore-test/$f.restored" ] || cp -p "$TB_MNT/etc/$f" "$TB_MNT/root/restore-test/$f.restored"
        : > "$TB_MNT/etc/$f.tb"
        while IFS= read -r line || [ -n "$line" ]; do
            read -ra a <<<"$line"
            if [ "${#a[@]}" -lt 2 ] || [ "${a[0]#\#}" != "${a[0]}" ]; then printf '%s\n' "$line" >> "$TB_MNT/etc/$f.tb"; continue; fi
            if [ "$f" = crypttab ]; then name=${a[0]}; dev=${a[1]}; else name=""; dev=${a[0]}; fi
            opts=${a[3]:-}
            disk=""
            case "$dev" in
                UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*) disk=$(bx_disk_of "$(blkid -t "$dev" -o device 2>/dev/null | head -1)" 2>/dev/null) ;;
                /dev/mapper/*) case "$names" in *" ${dev#/dev/mapper/} "*) disk="a container of another disk" ;; esac ;;
                /dev/*) [ -b "$dev" ] && disk=$(bx_disk_of "$dev" 2>/dev/null) ;;
            esac
            if [ -z "$disk" ] || [ "$disk" = "$t" ] || [[ ",$opts," == *,noauto,* ]]; then
                printf '%s\n' "$line" >> "$TB_MNT/etc/$f.tb"; continue
            fi
            # The boot chain naming another disk is a restore failure, never isolated away.
            if { [ "$f" = crypttab ] && { [ "$name" = "$(layout ROOT_MAPPER)" ] || [ "$name" = "$(layout BOOT_MAPPER)" ]; }; } \
               || { [ "$f" = fstab ] && case "${a[1]}" in /|/boot|/efi|/boot/efi|/usr|/var|/home) true ;; *) false ;; esac; }; then
                warn "the restored /etc/$f still names $dev (on $disk) for ${name:-${a[1]}} — the restore did not move it to the test drive; left as-is"
                printf '%s\n' "$line" >> "$TB_MNT/etc/$f.tb"; continue
            fi
            [ -n "$name" ] && names="$names$name "
            if [ "$f" = crypttab ]; then [ -n "${a[2]:-}" ] || a[2]=none; else [ -n "${a[2]:-}" ] || a[2]=auto; fi
            a[3]="${opts:+$opts,}noauto"
            printf '%s\n' "${a[*]}" >> "$TB_MNT/etc/$f.tb"; n=$((n+1))
            say "test drive: /etc/$f entry for $dev (on $disk, not the test drive) → noauto"
        done < "$TB_MNT/etc/$f"
        cat "$TB_MNT/etc/$f.tb" > "$TB_MNT/etc/$f"; rm -f "$TB_MNT/etc/$f.tb"
    done
    [ "$n" -gt 0 ] && ledger test "test drive: $n crypttab/fstab entries for disks other than the test drive set noauto — the booted test drive unlocks and mounts nothing of this machine's (originals: /root/restore-test/*.restored)" "test drive only"
    return 0
}
unmount_mounts() {
    local m
    for m in $(findmnt -rno TARGET 2>/dev/null | grep -E "^($TB_MNT|/run/tb-verify)(/|$)" | sort -r); do umount "$m" 2>/dev/null || umount -l "$m"; done
    return 0
}
unmount_target() {
    local m
    unmount_mounts
    [ -e /dev/mapper/tb-verify-root ] && dmsetup remove tb-verify-root
    if [ -n "$(layout ROOT_VG 2>/dev/null)" ] && [ -e /dev/mapper/tb-root ]; then
        vgchange "${TB_LVM[@]}" -an --devices /dev/mapper/tb-root "$(tb_vg)" >/dev/null 2>&1 || true
    fi
    for m in tb-home tb-boot tb-root tb-verify-home tb-verify-boot tb-verify; do [ -e "/dev/mapper/$m" ] && cryptsetup close "$m"; done
    return 0
}

# --- vmboot: the test drive booted in a virtual machine ------------------------------------------------------
# Before anyone reboots this machine: QEMU boots the TEST drive — its own
# firmware path, loader, built-in passphrase, initramfs, SELinux relabel, the
# boot logger — and the verdict comes from that logger's own report.
#   - the test drive is attached with snapshot=on: every write of the VM goes to
#     a throwaway overlay, the drive stays exactly as finish left it (its relabel
#     is still to come on the real boot);
#   - it carries its real serial, so the logger's "running from the test drive"
#     check holds;
#   - a small report disk carries this machine's REPORT_PARTUUID: the logger
#     writes its report there, as it will onto this machine's partition later;
#   - no network: the restored homes hold real logins and keys, and nothing in
#     them may sync from a VM; nothing of this machine's disks is attached.
# UEFI hosts need OVMF (x86_64) or AAVMF (aarch64); a BIOS host boots SeaBIOS.
# TB_VM_SECONDS (1800) bounds the run; TB_VM_MEM_MIB the memory (4096, or the
# largest argon2 memory cost of the test drive's containers + 2048).
vm_firmware() { # "code" or "code<TAB>vars"; nothing when none is installed
    local c v
    case "$(uname -m)" in
        x86_64)
            for c in /usr/share/edk2/ovmf/OVMF.stateless.fd /usr/share/OVMF/OVMF.stateless.fd; do [ -r "$c" ] && { echo "$c"; return 0; }; done
            for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/qemu/ovmf-x86_64-code.bin; do
                [ -r "$c" ] || continue
                for v in "${c/CODE/VARS}" "${c/code/vars}"; do [ "$v" != "$c" ] && [ -r "$v" ] && { printf '%s\t%s\n' "$c" "$v"; return 0; }; done
            done ;;
        aarch64)
            for c in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw /usr/share/edk2/aarch64/AAVMF_CODE.fd; do
                [ -r "$c" ] || continue
                for v in "${c/CODE/VARS}" /usr/share/edk2/aarch64/vars-template-pflash.raw; do [ "$v" != "$c" ] && [ -r "$v" ] && { printf '%s\t%s\n' "$c" "$v"; return 0; }; done
            done ;;
    esac
    return 1
}
vm_skip() { st_set vmboot SKIPPED; st_set vmboot-why "$1"; say "VM boot skipped: $1"; return 0; }
vm_report_read() { # vm_report_read IMG DEST — copy the report directory out of the report disk, read-only
    # mtools reads the image file itself: a loop device every poll made the
    # desktop's device notifier (Plasma's Disks & Devices) pop up every 30 s.
    local img="$1" dest="$2" off loop d rmnt=/run/tb-vmreport got=1
    off=$(( $(sgdisk -i 1 "$img" 2>/dev/null | awk '/^First sector/{print $3}') * 512 ))
    if command -v mcopy >/dev/null 2>&1 && [ "$off" -gt 0 ]; then
        for d in $(MTOOLS_SKIP_CHECK=1 mdir -b -i "$img@@$off" ::/ 2>/dev/null | sed -n 's#^::/\(restore-test-[^/]*\)/*$#\1#p'); do
            mkdir -p "$dest" && MTOOLS_SKIP_CHECK=1 mcopy -s -n -o -i "$img@@$off" "::/$d/*" "$dest/" 2>/dev/null
            compgen -G "$dest/boot-report-*.md" >/dev/null && got=0
        done
        return "$got"
    fi
    loop=$(losetup --find --show --read-only --partscan "$img") || return 1
    udevadm settle; mkdir -p "$rmnt"
    if mount -o ro "${loop}p1" "$rmnt" 2>/dev/null; then
        if compgen -G "$rmnt/restore-test-*/boot-report-*.md" >/dev/null; then mkdir -p "$dest" && cp -a "$rmnt"/restore-test-*/. "$dest/" && got=0; fi
        umount "$rmnt"
    fi
    losetup -d "$loop"
    return "$got"
}
cmd_vmboot() {
    local t arch qemu fw code vars img loop vm="$TB_STATE/vm" secs mem accel=() firmware=() n=0 sock
    [ -f "$TB_STATE/plan" ] && [ -s "$TB_STATE/manifest.tsv.gz" ] || die "vmboot runs after finish (no plan or manifest in $TB_STATE)"
    t=$(target_disk)
    lsblk -rno MOUNTPOINTS "$t" | grep -q . && die "the test drive has mounted partitions — vmboot needs it closed (finish closes it)"
    lsblk -rno TYPE "$t" | grep -qE 'crypt|lvm' && die "the test drive has open containers or volumes — close them first"
    arch=$(uname -m); qemu=$(command -v "qemu-system-$arch" 2>/dev/null)
    [ -n "$qemu" ] || { vm_skip "no qemu-system-$arch (Fedora: dnf install qemu-system-x86-core edk2-ovmf; Debian/Ubuntu: apt install qemu-system-x86 ovmf; Arch: pacman -S qemu-base edk2-ovmf)"; return 0; }
    if [ "$(layout FIRMWARE)" = uefi ]; then
        fw=$(vm_firmware) || { vm_skip "no UEFI firmware for QEMU (OVMF/AAVMF package)"; return 0; }
        IFS=$'\t' read -r code vars <<<"$fw"
    fi
    # argon2 allocates its whole memory cost to open a keyslot: a 4 GiB-cost
    # container cannot be opened inside a 4096 MiB guest.
    local kdf_kib=0 k v
    for k in ROOT_LUKS_MEMORY BOOT_LUKS_MEMORY; do v=$(layout "$k"); [ "${v:-0}" -gt "$kdf_kib" ] 2>/dev/null && kdf_kib=$v; done
    secs="${TB_VM_SECONDS:-1800}"; mem="${TB_VM_MEM_MIB:-$(( kdf_kib / 1024 + 2048 > 4096 ? kdf_kib / 1024 + 2048 : 4096 ))}"
    # A root the initramfs unlocks by passphrase: the VM has no one at the prompt.
    # systemd-cryptsetup takes it from the cryptsetup.passphrase credential, which
    # a VM's systemd imports from SMBIOS type 11 — no keystrokes (a key pressed at
    # the systemd-boot menu edits the entry). The real test boot still asks.
    local cred=() askpass=0
    [ "$(layout ROOT_CRYPT)" = 1 ] && [ -z "$(layout ROOT_KEYFILE)" ] && cred=(-smbios "type=11,value=io.systemd.credential:cryptsetup.passphrase=$TB_PASSPHRASE")
    # initramfs-tools reads no credential: the passphrase is typed, at its prompt only
    [ ${#cred[@]} -gt 0 ] && [ "$(layout ROOT_UNLOCK)" = initramfs-tools ] && askpass=1
    rm -rf "$vm"; mkdir -p "$vm"
    if [ -n "${code:-}" ]; then
        if [ -n "${vars:-}" ]; then cp "$vars" "$vm/vars.fd"; firmware=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$vm/vars.fd")
        else firmware=(-bios "$code"); fi
    fi
    [ -w /dev/kvm ] && accel=(-enable-kvm -cpu host)
    # the report disk: GPT, one vfat partition with this machine's report PARTUUID
    img="$vm/report.img"
    truncate -s 64M "$img" && sgdisk -n "1:0:0" -t 1:0700 -u "1:$(layout REPORT_PARTUUID)" "$img" >/dev/null || die "report disk"
    # formatted in the image file itself (no loop device for the desktop to announce)
    local first last
    first=$(sgdisk -i 1 "$img" | awk '/^First sector/{print $3}'); last=$(sgdisk -i 1 "$img" | awk '/^Last sector/{print $3}')
    mkfs.vfat -n TB-VMREPORT --offset "$first" "$img" $(( (last - first + 1) / 2 )) >/dev/null 2>&1 || die "mkfs report disk"
    sock="$vm/monitor.sock"
    say "VM boot of the test drive ($t, snapshot — nothing is written to it; no network; report disk PARTUUID $(layout REPORT_PARTUUID); up to $((secs / 60)) min) ..."
    local machine=(); [ "$arch" = x86_64 ] && machine=(-machine q35); [ "$arch" = aarch64 ] && machine=(-machine virt)
    "$qemu" "${accel[@]}" "${machine[@]}" -m "$mem" -smp 2 "${firmware[@]}" "${cred[@]}" \
        -drive "file=$t,format=raw,if=none,id=tb,snapshot=on,cache=none" -device "virtio-blk-pci,drive=tb,serial=$TB_TARGET_SERIAL,bootindex=1" \
        -drive "file=$img,format=raw,if=virtio" \
        -nic none -display none -vga std -serial "file:$vm/serial.log" -monitor "unix:$sock,server,nowait" \
        > "$vm/qemu.log" 2>&1 &
    local qpid=$!
    ledger test "VM boot of the test drive (snapshot=on: its writes discarded), evidence in $vm" "nothing to revert — the drive is not written"
    vm_monitor() { python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(65536)
s.sendall((sys.argv[2]+"\n").encode()); time.sleep(1); s.close()' "$sock" "$1" 2>/dev/null; }
    # vm_idle — the screen and the serial console both unchanged since the last
    # call, and no loader menu on the console: the boot waits for input. The
    # loader mirrors its menu to the serial console and clears it when it starts
    # an entry; the kernel writes nothing there (no console=ttyS0). A key sent to
    # the menu would edit an entry — never then.
    local idle_prev="" typed=0 typed_shot="" typed_at=0
    vm_idle() {
        local shot cur
        vm_monitor "screendump $vm/probe.ppm"
        shot=$(sha256sum "$vm/probe.ppm" 2>/dev/null | cut -d' ' -f1)
        cur="$shot $(stat -c %s "$vm/serial.log" 2>/dev/null)"
        [ -n "$shot" ] && [ "$cur" = "$idle_prev" ] || { idle_prev=$cur; return 1; }
        python3 -c 'import re,sys
t = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
tail = t.rsplit("\x1b[2J", 1)[-1]
sys.exit(1 if re.sub(r"\x1b\[[0-9;=?]*[A-Za-z]", "", tail).strip() else 0)' "$vm/serial.log" 2>/dev/null
    }
    vm_type() { # the passphrase and Enter, one key at a time
        local i c
        for ((i = 0; i < ${#1}; i++)); do
            c=${1:i:1}
            case "$c" in [a-z0-9]) vm_monitor "sendkey $c" ;; [A-Z]) vm_monitor "sendkey shift-${c,}" ;; *) warn "VM boot: cannot type '$c' — the passphrase prompt is left unanswered"; return 1 ;; esac
        done
        vm_monitor "sendkey ret"
    }
    while [ "$n" -lt "$secs" ] && kill -0 "$qpid" 2>/dev/null; do
        sleep 30; n=$((n + 30))
        [ $((n % 120)) -eq 0 ] && vm_monitor "screendump $vm/screen-$(printf '%04d' "$n").ppm"
        # typed once at the first idle screen; again (up to 3) only while the same screen waits on
        if [ "$askpass" = 1 ] && [ "$typed" -lt 3 ] && [ $((n - typed_at)) -ge 120 ] && vm_idle \
           && { [ "$typed" = 0 ] || [ "${idle_prev%% *}" = "$typed_shot" ]; }; then
            cp -f "$vm/probe.ppm" "$vm/askpass-$typed.ppm"
            vm_type "$TB_PASSPHRASE" && { typed=$((typed + 1)); typed_shot=${idle_prev%% *}; typed_at=$n; say "VM boot: the initramfs waits at its passphrase prompt — typed the test passphrase ($typed)"; }
        fi
        if vm_report_read "$img" "$vm/boot-report" && grep -qh '_report complete_' "$vm"/boot-report/boot-report-*.md 2>/dev/null; then break; fi
    done
    vm_monitor "screendump $vm/screen-last.ppm"; sleep 2
    vm_monitor system_powerdown
    for _ in $(seq 1 12); do kill -0 "$qpid" 2>/dev/null || break; sleep 5; done
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
    vm_report_read "$img" "$vm/boot-report" || true
    command -v magick >/dev/null 2>&1 && for f in "$vm"/screen-*.ppm; do [ -f "$f" ] && magick "$f" "${f%.ppm}.png" && rm -f "$f"; done
    # the verdict
    local verdict=PASS why=""
    if [ "$(layout BOOT_CRYPT)" = 1 ] && [ "$(st_get auto-unlock)" = grub ]; then
        grep -q 'TEST DRIVE' "$vm/serial.log" || { verdict=FAIL; why="$why the test loader never ran (no TEST DRIVE banner on the serial console);"; }
    fi
    if ! compgen -G "$vm/boot-report/boot-report-*.md" >/dev/null; then
        verdict=FAIL; why="$why no boot report — the system never came up far enough for its logger (see $vm/screen-last.png, $vm/serial.log);"
    else
        grep -qh '_report complete_' "$vm"/boot-report/boot-report-*.md || { verdict=FAIL; why="$why the boot report is partial (the logger did not finish within $((secs / 60)) min);"; }
        grep -h '\*\*' "$(ls -1 "$vm"/boot-report/boot-report-*.md | sort | tail -1)" | sed 's/^/    /'
        grep -qh 'FAIL' "$(ls -1 "$vm"/boot-report/boot-report-*.md | sort | tail -1)" && { verdict=FAIL; why="$why the boot report has FAIL lines;"; }
    fi
    st_set vmboot "$verdict"; st_set vmboot-why "${why:-}"
    if [ "$verdict" = PASS ]; then say "VM boot: PASS — the test drive booted, unlocked itself and its logger reported (evidence: $vm)"
    else warn "VM boot: FAIL —$why"; fi
    return 0
}

# --- collect: after the test boot ------------------------------------------------------------------------------
cmd_collect() {
    local rp dev mnt tmp p verdict=PASS
    rp=$(layout REPORT_PARTUUID); dev=$(blkid -t "PARTUUID=$rp" -o device 2>/dev/null | head -1)
    [ -n "$dev" ] || die "report partition PARTUUID $rp not found on this machine"
    mnt=$(findmnt -no TARGET "$dev" | head -1)
    [ -n "$mnt" ] || { mnt=/run/tb-report; mkdir -p "$mnt"; mount -o ro "$dev" "$mnt" || die "mount report partition"; }
    local rdir; rdir="$mnt/restore-test-$(basename "$TB_STATE")"
    [ -d "$rdir" ] || die "no report in $rdir — did the test drive boot and wait two minutes?"
    cp -a "$rdir"/. "$TB_STATE/boot-report/" 2>/dev/null || { mkdir -p "$TB_STATE/boot-report"; cp -a "$rdir"/. "$TB_STATE/boot-report/"; }
    say "boot report copied to $TB_STATE/boot-report/"
    [ "$mnt" = /run/tb-report ] && umount "$mnt"
    grep -h '\*\*' "$TB_STATE"/boot-report/boot-report-*.md | sed 's/^/    /'
    grep -qh 'FAIL' "$TB_STATE"/boot-report/boot-report-*.md && verdict=FAIL
    grep -qh '_report complete_' "$TB_STATE"/boot-report/boot-report-*.md \
        || { warn "the boot report is partial — the test drive was switched off before its logger finished (the byte comparison on the booted drive is missing)"; verdict=FAIL; }
    # This machine, after booting it again.
    cmd_fingerprint after >/dev/null
    cp "$TB_STATE/fingerprint-before.txt" "$TB_STATE/fingerprint-before.keep" 2>/dev/null
    cmd_fingerprint diff || verdict=FAIL
    # Byte comparison against the archive, hard-link aware, on the test drive read-only.
    local t; t=$(target_disk)
    p=$(partdev root); if [ "$(layout ROOT_CRYPT)" = 1 ]; then printf '%s' "$TB_PASSPHRASE" | cryptsetup open --readonly --key-file=- "$p" tb-verify || die "open test drive"; p=/dev/mapper/tb-verify; fi
    if [ -n "$(layout ROOT_VG)" ]; then
        # The test drive's volume group carries this host's name now: never activate
        # it here. Map its root volume read-only by hand, from its own metadata only.
        local ps ext
        ps=$(pvs "${TB_LVM[@]}" --devices "$p" --noheadings --units s --nosuffix -o pe_start "$p" 2>/dev/null | tr -d ' ')
        ext=$(vgs "${TB_LVM[@]}" --devices "$p" --noheadings --units s --nosuffix -o vg_extent_size "$(layout ROOT_VG)" 2>/dev/null | tr -d ' ')
        lvs "${TB_LVM[@]}" --devices "$p" --noheadings --units s --nosuffix -o seg_start,seg_size,seg_pe_ranges "$(layout ROOT_VG)/$(root_lv)" 2>/dev/null \
            | awk -v ps="${ps%%.*}" -v ex="${ext%%.*}" -v d="$p" '{r=$3; sub(/^.*:/, "", r); split(r, a, "-"); printf "%d %d linear %s %d\n", $1, $2, d, ps + a[1] * ex}' \
            | dmsetup create --readonly tb-verify-root || die "map the root volume $(layout ROOT_VG)/$(root_lv) of the test drive"
        p=/dev/mapper/tb-verify-root
    fi
    tmp=/run/tb-verify; mkdir -p "$tmp"
    local o=ro; [ "$(layout ROOT_FS)" = btrfs ] && o="ro,rescue=nologreplay,subvol=$(layout_all SUBVOL | awk -F= '$1=="/"{print $2}')"
    [ "$(layout ROOT_FS)" = ext4 ] && o="ro,noload"
    mount -o "$o" "$p" "$tmp" || die "mount test root"
    # Everything else the archive has files under: the other btrfs subvolumes of
    # the root filesystem (/home) and a /home partition. Unmounted, every file in
    # them counted as missing.
    local sv svp
    if [ "$(layout ROOT_FS)" = btrfs ]; then
        while IFS='=' read -r svp sv; do
            [ -n "$svp" ] && [ "$svp" != / ] && [ -d "$tmp$svp" ] || continue
            mount -o "ro,rescue=nologreplay,subvol=$sv" "$p" "$tmp$svp" || warn "could not mount subvolume $sv at $svp — its files count as missing"
        done < <(layout_all SUBVOL)
    fi
    if has_role home; then
        local h; h=$(partdev home)
        if [ "$(layout HOME_CRYPT)" = 1 ]; then printf '%s' "$TB_PASSPHRASE" | cryptsetup open --readonly --key-file=- "$h" tb-verify-home && h=/dev/mapper/tb-verify-home; fi
        mount -o ro "$h" "$tmp/home" 2>/dev/null || mount -o ro,noload "$h" "$tmp/home" || warn "could not mount the test drive's /home — its files count as missing"
    fi
    if has_role boot; then
        local b; b=$(partdev boot)
        if [ "$(layout BOOT_CRYPT)" = 1 ]; then printf '%s' "$TB_PASSPHRASE" | cryptsetup open --readonly --key-file=- "$b" tb-verify-boot && b=/dev/mapper/tb-verify-boot; fi
        mount -o ro "$b" "$tmp/boot" 2>/dev/null || mount -o ro,noload "$b" "$tmp/boot"
    fi
    has_role esp && mount -o ro "$(partdev esp)" "$tmp$(layout ESP_MOUNT)"
    python3 "$TB_DIR/compare-manifest.py" "$TB_STATE/manifest.tsv.gz" "$tmp" > "$TB_STATE/byte-comparison.md"
    unmount_target
    sed -n '1,9p' "$TB_STATE/byte-comparison.md" | sed 's/^/    /'
    st_set verdict "$verdict"; touch "$TB_STATE/finished-collect"
    say "VERDICT: $verdict — state and evidence: $TB_STATE"
    say "then: sudo $0 revert   (removes the report from this machine and the test repository)"
}

# --- revert ----------------------------------------------------------------------------------------------------------
cmd_revert() {
    local keep=0 f kn rp dev mnt
    [ "${1:-}" = --keep-repo ] && keep=1
    unmount_target; say "test drive unmounted and closed"
    for f in "$TB_STATE"/sectors.*; do
        [ -f "$f" ] || continue; kn=${f##*.}
        [ -w "/sys/block/$kn/queue/max_sectors_kb" ] && cat "$f" > "/sys/block/$kn/queue/max_sectors_kb" && say "$kn max_sectors_kb → $(cat "$f")"
    done
    rp=$(layout REPORT_PARTUUID 2>/dev/null); dev=$([ -n "$rp" ] && blkid -t "PARTUUID=$rp" -o device 2>/dev/null | head -1)
    if [ -n "$dev" ]; then
        mnt=$(findmnt -no TARGET "$dev" | head -1)
        if [ -n "$mnt" ] && [ -d "$mnt/restore-test-$(basename "$TB_STATE")" ]; then
            if [ -d "$TB_STATE/boot-report" ]; then rm -rf "$mnt/restore-test-$(basename "$TB_STATE")" && say "removed the report from $mnt"
            else warn "report in $mnt not collected yet — run collect first (left in place)"; fi
        fi
    fi
    local repo_gone=0
    if [ "$keep" = 0 ] && ! mountpoint -q "$BACKUP_MOUNT"; then
        # Locked or unplugged: the repository is not reachable, so it is not gone.
        warn "backup drive not mounted at $BACKUP_MOUNT — the test repository $TB_REPO is still on it; mount the drive and run revert again"
    elif [ "$keep" = 0 ] && [ -d "$TB_REPO" ]; then
        case "$TB_REPO" in "$BACKUP_MOUNT"/borg-testbed-*) rm -rf "$TB_REPO" && say "deleted the test repository $TB_REPO" && repo_gone=1 ;; *) warn "TB_REPO=$TB_REPO is not a borg-testbed-* path — not deleting it" ;; esac
    fi
    ledger test "reverted: mounts, mappings, transfer sizes, report$( [ "$repo_gone" = 1 ] && echo ', test repository')" "-"
    say "reverted. Evidence stays in $TB_STATE"
}

# --- status ---------------------------------------------------------------------------------------------------------
cmd_status() {
    say "suite $BX_VERSION  host $TB_HOST  config $TB_CONF"
    say "backup drive: ${TB_BACKUP_SERIAL:-?} → $(disk_by_serial "$TB_BACKUP_SERIAL" || true)   mounted at $BACKUP_MOUNT: $(mountpoint -q "$BACKUP_MOUNT" && echo yes || echo no)"
    say "test drive:   ${TB_TARGET_SERIAL:-?} → $(disk_by_serial "$TB_TARGET_SERIAL" || echo 'not connected')"
    say "this machine's disks: $(host_disks | while read -r d; do printf '%s(%s) ' "$d" "$(lsblk -dno SERIAL "$d")"; done)"
    say "state: $TB_STATE $( [ -d "$TB_STATE" ] || echo '(new)')"
    [ -f "$LEDGER" ] && sed 's/^/    /' "$LEDGER"
    return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
    status)      cmd_status ;;
    plan)        cmd_plan ;;
    fingerprint) cmd_fingerprint "$@" ;;
    prepare)     cmd_prepare ;;
    format)      cmd_format ;;
    mount)       cmd_mount ;;
    backup)      cmd_backup "$@" ;;
    restore)     cmd_restore ;;
    finish)      cmd_finish ;;
    vmboot)      cmd_vmboot ;;
    collect)     cmd_collect ;;
    revert)      cmd_revert "$@" ;;
    all)         cmd_fingerprint before && cmd_prepare && cmd_format && cmd_mount && cmd_backup "${1:-functional}" && cmd_restore && cmd_finish ;;
    *)           echo "unknown command: $cmd (see --help)" >&2; exit 2 ;;
esac
