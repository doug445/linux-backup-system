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
#   prepare       WIPE the test drive, partition it like this host      (TB_WIPE=<serial>)
#   format        LUKS (passphrase "test") + filesystems + btrfs subvolumes
#   mount         the target tree at $TB_MNT, laid out like this host's fstab
#   backup [functional|minimal]
#                 a TEST archive in its own repository on the backup drive
#                 functional (default): configs, keys, Claude Code and shell setup of
#                 every home are kept, bulk data is not; minimal: no /home contents
#   restore       dry run, then the real restore, from a frozen copy of the suite
#   finish        byte manifest, home skeletons, boot logger, checks; unmount + close
#   collect       after booting the test drive and back: report, fingerprint diff,
#                 hard-link-aware byte comparison, verdict
#   revert [--keep-repo]
#                 undo every TEST-ONLY change: mounts, mappings, transfer sizes,
#                 the report left on this host, the test repository
#   all           fingerprint before → prepare → format → mount → backup → restore → finish
#
# Test drives only ever get the passphrase "test": they hold a copy of this machine
# and are wiped again on the next run. The suite's real restore scripts never carry
# a passphrase.
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
for _c in "${TESTBED_CONF:-}" "$BACKUP_MOUNT/testbed/testbed.conf" \
          "$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.config/linux-backup-system/testbed.conf" "$TB_DIR/testbed.conf"; do
    if [ -n "$_c" ] && [ -r "$_c" ]; then TB_CONF="$_c"; # shellcheck disable=SC1090
        . "$_c"; break; fi
done
TB_PASSPHRASE="test"                       # test drives only — see the header
TB_MNT="${TB_MNT:-/mnt/tb-target}"
TB_HOST="$BACKUP_HOST_ID"
TB_REPO="${TB_REPO:-$BACKUP_MOUNT/borg-testbed-$TB_HOST}"
TB_BIG_EXCLUDES="${TB_BIG_EXCLUDES:-/var/lib/ollama/* /usr/lib/ollama/* /var/lib/docker/* /var/lib/containers/* /var/lib/libvirt/images/* /var/lib/plocate/* /var/lib/mlocate/* /var/lib/chrootbuild/* /opt/cuda/* /usr/share/doc/* /usr/lib/jvm/*}"
TB_EXTRA_EXCLUDES="${TB_EXTRA_EXCLUDES:-}"
TB_HOME_KEEP="${TB_HOME_KEEP:-.config .local/bin .local/share/keyrings .local/share/applications .local/share/fonts .ssh .gnupg .pki .claude .claude.json .bashrc .bash_profile .bash_logout .profile .zshrc .zprofile .zshenv .zlogin .oh-my-zsh .xinitrc .xprofile .xsession .Xresources .tmux.conf .tmux .gitconfig .dotfiles .vimrc .nanorc}"
TB_SECTORS_KB="${TB_SECTORS_KB:-128}"     # smaller USB transfers for bridges that reset under load; 0 = leave alone

# --- state + ledger ---------------------------------------------------------------
if [ -z "${TB_STATE:-}" ]; then
    TB_STATE=$(ls -1d "/var/lib/linux-backup-testbed/$TB_HOST"-* 2>/dev/null | sort | tail -1)
    [ -n "$TB_STATE" ] && [ -f "$TB_STATE/finished-collect" ] && [ "${1:-}" != collect ] && [ "${1:-}" != status ] && [ "${1:-}" != revert ] && TB_STATE=""
    [ -n "$TB_STATE" ] || TB_STATE="/var/lib/linux-backup-testbed/$TB_HOST-$(date +%Y%m%d-%H%M)"
fi
LEDGER="$TB_STATE/LEDGER.md"
st_get() { cat "$TB_STATE/$1" 2>/dev/null; }
st_set() { mkdir -p "$TB_STATE"; printf '%s\n' "$2" > "$TB_STATE/$1"; }
ledger() { # ledger test|permanent WHAT REVERT
    mkdir -p "$TB_STATE"
    [ -f "$LEDGER" ] || printf '# Restore test bed — %s\n\nTest vs real: the suite has no test mode. Rows marked **test** are undone by `testbed.sh revert`.\n\n| when | kind | change | revert |\n|---|---|---|---|\n' "$TB_HOST" > "$LEDGER"
    printf '| %s | %s | %s | %s |\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$LEDGER"
}

# --- drives -------------------------------------------------------------------------
disk_by_serial() { [ -n "$1" ] && lsblk -dnpo NAME,SERIAL 2>/dev/null | awk -v s="$1" '$2==s {print $1; exit}'; }
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
    [ -f "$TB_STATE/sectors.$kn" ] || cat "$f" > "$TB_STATE/sectors.$kn"
    echo "$TB_SECTORS_KB" > "$f" && ledger test "max_sectors_kb $(cat "$TB_STATE/sectors.$kn") → $TB_SECTORS_KB on $d (runtime)" "restored by revert (also lost at re-plug)"
}

# --- this host's layout ---------------------------------------------------------------
# Every fact the target layout mirrors, as KEY=VALUE lines in $TB_STATE/host-layout.
detect_layout() {
    local root_src root_fs esp boot_fs boot_dev boot_is_esp=0 crypt="" luks_dev="" luks_ver="" luks_kdf=""
    local home_src home_fs swap_dev sv
    root_src=$(findmnt -no SOURCE / | sed 's/\[.*//'); root_fs=$(findmnt -no FSTYPE /)
    if [ "$(lsblk -dno TYPE "$root_src" 2>/dev/null)" = crypt ]; then
        crypt=1; luks_dev=$(cryptsetup status "$(basename "$root_src")" 2>/dev/null | awk '/device:/{print $2}')
        luks_ver=$(cryptsetup luksDump "$luks_dev" 2>/dev/null | awk '/^Version:/{print $2; exit}')
        luks_kdf=$(cryptsetup luksDump "$luks_dev" 2>/dev/null | awk '/PBKDF:/{print $2; exit}')
        [ "$luks_ver" = 1 ] && luks_kdf=pbkdf2
    fi
    case "$(lsblk -dno TYPE "$root_src" 2>/dev/null)" in lvm) echo "UNSUPPORTED=root on LVM ($root_src): not mirrored yet — restore by hand onto an LV" ;; esac
    lsblk -rno TYPE "$(bx_disk_of "$root_src")" 2>/dev/null | grep -qE '^raid' && echo "UNSUPPORTED=root on mdadm RAID: not mirrored yet"
    case "$root_fs" in btrfs|ext4|xfs|f2fs) ;; *) echo "UNSUPPORTED=root filesystem $root_fs: not mirrored yet" ;; esac
    esp=$(bx_esp_mount 2>/dev/null || true)
    echo "ROOT_FS=$root_fs"; echo "ROOT_CRYPT=${crypt:-0}"
    [ -n "$crypt" ] && { echo "LUKS_VERSION=${luks_ver:-2}"; echo "LUKS_PBKDF=${luks_kdf:-argon2id}"; echo "MAPPER_NAME=$(basename "$root_src")"; }
    [ -d /sys/firmware/efi ] && echo "FIRMWARE=uefi" || echo "FIRMWARE=bios"
    if [ -n "$esp" ]; then
        echo "ESP_MOUNT=$esp"; echo "ESP_MIB=$(( $(lsblk -bdno SIZE "$(findmnt -no SOURCE "$esp")") / 1048576 ))"
        [ "$esp" = /boot ] && boot_is_esp=1
    fi
    if mountpoint -q /boot && [ "$boot_is_esp" = 0 ]; then
        boot_dev=$(findmnt -no SOURCE /boot | sed 's/\[.*//'); boot_fs=$(findmnt -no FSTYPE /boot)
        if [ "$(lsblk -dno TYPE "$boot_dev")" = crypt ]; then echo "UNSUPPORTED=separate encrypted /boot partition: not mirrored yet"; fi
        echo "BOOT_FS=$boot_fs"; echo "BOOT_MIB=$(( $(lsblk -bdno SIZE "$boot_dev") / 1048576 ))"
        echo "BOOT_PARTTYPE=$( [ "$boot_fs" = vfat ] && echo ea00 || echo 8300 )"
    fi
    if [ "$root_fs" = btrfs ]; then
        # subvolumes the host's fstab mounts from the root filesystem: MOUNT=SUBVOL
        while read -r _t sv; do echo "SUBVOL=$_t=$sv"; done < <(findmnt -rno TARGET,SOURCE,FSTYPE -t btrfs | awk -v d="$root_src" '$3=="btrfs" && index($2, d"[")==1 {s=$2; sub(/^[^[]*\[/, "", s); sub(/\]$/, "", s); print $1, s}')
    fi
    home_src=$(findmnt -no SOURCE /home 2>/dev/null | sed 's/\[.*//'); home_fs=$(findmnt -no FSTYPE /home 2>/dev/null)
    if [ -n "$home_src" ] && [ "$home_src" != "$root_src" ]; then
        echo "HOME_FS=$home_fs"; echo "HOME_CRYPT=$( [ "$(lsblk -dno TYPE "$home_src")" = crypt ] && echo 1 || echo 0)"
    fi
    swap_dev=$(awk 'NR>1 && $2=="partition"{print $1; exit}' /proc/swaps)
    [ -n "$swap_dev" ] && echo "SWAP_MIB=$(( $(lsblk -bdno SIZE "$swap_dev") / 1048576 ))"
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

# --- fingerprint: this machine's own disks ----------------------------------------------
cmd_fingerprint() {
    local tag="${1:-}" out d p
    case "$tag" in
        diff)
            [ -f "$TB_STATE/fingerprint-before.txt" ] && [ -f "$TB_STATE/fingerprint-after.txt" ] || die "need fingerprint before and after first"
            # Expected on any boot of this machine: systemd-boot refreshes its random seed;
            # firmware boot menus reorder BootOrder; the test report directory.
            if diff <(grep -vE 'restore-test|loader/random-seed|^BootOrder:' "$TB_STATE/fingerprint-before.txt") \
                    <(grep -vE 'restore-test|loader/random-seed|^BootOrder:' "$TB_STATE/fingerprint-after.txt") > "$TB_STATE/fingerprint.diff"; then
                say "this machine's disks: IDENTICAL (partition tables, LUKS headers, boot files, boot entries)"
                grep -h '^BootOrder:' "$TB_STATE/fingerprint-before.txt" "$TB_STATE/fingerprint-after.txt" | uniq | sed -n '2p' | grep -q . && say "  note: BootOrder changed — firmware boot menus do that; no entry was added or removed"
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
        done
        [ -d /sys/firmware/efi ] && { echo "## NVRAM"; efibootmgr 2>/dev/null | grep -v '^BootCurrent'; }
        echo "## boot configs"; sha256sum /etc/fstab /etc/crypttab /etc/crypttab.initramfs /etc/kernel/cmdline /etc/default/grub 2>/dev/null
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
    uns=$(layout_all UNSUPPORTED); [ -n "$uns" ] && { printf '%s\n' "$uns" | sed 's/^/[testbed] UNSUPPORTED: /' >&2; return 1; }
    t=$(target_disk); size_mib=$(( $(lsblk -bdno SIZE "$t") / 1048576 ))
    esp=$(layout ESP_MIB); boot=$(layout BOOT_MIB); swap=$(layout SWAP_MIB); home_fs=$(layout HOME_FS)
    : > "$TB_STATE/plan"
    say "test drive: $t ($(lsblk -dno MODEL,SERIAL "$t" | xargs), ${size_mib} MiB) — laid out like this host:"
    if [ "$(layout FIRMWARE)" = bios ]; then echo "PART=$n:bios_grub:1:ef02:-" >> "$TB_STATE/plan"; n=$((n+1)); fi
    [ -n "$esp" ] && { echo "PART=$n:esp:$(( esp < 300 ? 300 : esp )):ef00:$(layout ESP_MOUNT)" >> "$TB_STATE/plan"; n=$((n+1)); }
    [ -n "$boot" ] && { echo "PART=$n:boot:$boot:$(layout BOOT_PARTTYPE):/boot" >> "$TB_STATE/plan"; n=$((n+1)); }
    [ -n "$swap" ] && { echo "PART=$n:swap:$swap:8200:swap" >> "$TB_STATE/plan"; n=$((n+1)); }
    local used=0 v; while IFS=: read -r _ _ v _ _; do used=$((used + v)); done < <(sed -n 's/^PART=//p' "$TB_STATE/plan")
    local rest=$(( size_mib - used - 16 ))
    if [ -n "$home_fs" ]; then
        echo "PART=$n:root:$(( rest * 7 / 10 )):$( [ "$(layout ROOT_CRYPT)" = 1 ] && echo 8309 || echo 8304 ):/" >> "$TB_STATE/plan"; n=$((n+1))
        echo "PART=$n:home:0:$( [ "$(layout HOME_CRYPT)" = 1 ] && echo 8309 || echo 8302 ):/home" >> "$TB_STATE/plan"
    else
        echo "PART=$n:root:0:$( [ "$(layout ROOT_CRYPT)" = 1 ] && echo 8309 || echo 8304 ):/" >> "$TB_STATE/plan"
    fi
    while IFS=: read -r num role mib type mnt; do
        printf '    p%-2s %-9s %8s  type %s  %s\n' "$num" "$role" "$( [ "$mib" = 0 ] && echo rest || echo "${mib}M")" "$type" "$mnt"
    done < <(sed -n 's/^PART=//p' "$TB_STATE/plan")
    [ "$(layout ROOT_CRYPT)" = 1 ] && say "    root: LUKS$(layout LUKS_VERSION) $(layout LUKS_PBKDF) (the host's own KDF, so its bootloader can open it), passphrase \"test\""
    [ "$(layout ROOT_FS)" = btrfs ] && say "    btrfs subvolumes: $(layout_all SUBVOL | tr '\n' ' ')"
    say "    report partition on THIS host for the booted test drive: $(layout REPORT_MOUNT) (PARTUUID $(layout REPORT_PARTUUID))"
    return 0
}

# --- prepare: wipe + partition ------------------------------------------------------------------
cmd_prepare() {
    local t; t=$(target_disk)
    cmd_plan >/dev/null || die "plan failed — run: testbed.sh plan"
    [ "${TB_WIPE:-}" = "$TB_TARGET_SERIAL" ] || die "this ERASES $t ($(lsblk -dno MODEL,SIZE "$t" | xargs)). Confirm with TB_WIPE=$TB_TARGET_SERIAL"
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

# --- format -----------------------------------------------------------------------------------------
cmd_format() {
    [ -f "$TB_STATE/plan" ] || die "no plan — run prepare first"
    local p root_blk ver kdf sv mnt name
    has_role esp  && { mkfs.vfat -F 32 -n TB-ESP "$(partdev esp)" >/dev/null || die "mkfs ESP"; }
    if has_role boot; then
        case "$(layout BOOT_FS)" in vfat) mkfs.vfat -F 32 -n TB-BOOT "$(partdev boot)" >/dev/null ;; *) "mkfs.$(layout BOOT_FS)" -q -F -L tb-boot "$(partdev boot)" >/dev/null 2>&1 || "mkfs.$(layout BOOT_FS)" -f -L tb-boot "$(partdev boot)" >/dev/null ;; esac || die "mkfs /boot"
    fi
    has_role swap && { mkswap -L tb-swap "$(partdev swap)" >/dev/null || die "mkswap"; }
    p=$(partdev root); root_blk=$p
    if [ "$(layout ROOT_CRYPT)" = 1 ]; then
        ver=$(layout LUKS_VERSION); kdf=$(layout LUKS_PBKDF)
        local kdfargs=(); [ "${ver:-2}" = 2 ] && kdfargs=(--pbkdf "${kdf:-argon2id}")
        printf '%s' "$TB_PASSPHRASE" | cryptsetup luksFormat --batch-mode --type "luks${ver:-2}" "${kdfargs[@]}" --key-file=- "$p" || die "luksFormat"
        printf '%s' "$TB_PASSPHRASE" | cryptsetup open --key-file=- "$p" tb-root || die "open tb-root"
        root_blk=/dev/mapper/tb-root
        ledger test "LUKS${ver:-2} ($kdf) on $p opened as tb-root, passphrase \"test\"" "revert closes it"
    fi
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
    root_blk=$(partdev root); [ "$(layout ROOT_CRYPT)" = 1 ] && root_blk=/dev/mapper/tb-root
    [ -b "$root_blk" ] || die "$root_blk is not there (open it: testbed.sh format, or cryptsetup open)"
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
    if has_role boot; then mkdir -p "$TB_MNT/boot"; mountpoint -q "$TB_MNT/boot" || mount "$(partdev boot)" "$TB_MNT/boot" || die "mount /boot"; fi
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
    local mode="${1:-functional}" inc="" k ex
    mountpoint -q "$BACKUP_MOUNT" || die "backup drive not mounted at $BACKUP_MOUNT"
    case "$mode" in functional|minimal) ;; *) die "backup functional|minimal" ;; esac
    freeze_suite
    ex="/home/*/* $TB_BIG_EXCLUDES $TB_EXTRA_EXCLUDES"
    if [ "$mode" = functional ]; then for k in $TB_HOME_KEEP; do inc="$inc /home/*/$k"; done; fi
    set_sectors "$(bx_disk_of "$(findmnt -no SOURCE "$BACKUP_MOUNT" | sed 's/\[.*//')")"
    st_set backup-mode "$mode"
    say "TEST archive ($mode) → $TB_REPO"
    ledger test "TEST archive ($mode) in $TB_REPO; excludes on the command line only, /etc/backup-system.conf untouched" "revert deletes $TB_REPO (revert --keep-repo keeps it)"
    env BORG_REPO="$TB_REPO" BACKUP_EXTRA_EXCLUDES="$ex" BACKUP_EXTRA_INCLUDES="${inc# }" \
        "$TB_STATE/suite/borg-backup.sh" > "$TB_STATE/backup.log" 2>&1
    local rc=$?
    tail -3 "$TB_STATE/backup.log"
    # rc 3 = the btrfs replica layer did not fully succeed; the archive is complete
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || die "test backup failed (rc=$rc) — $TB_STATE/backup.log"
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
    local rc=$?
    sed 's/\x1b\[[0-9;]*m//g' "$TB_STATE/restore.log" | grep -E 'FAIL|ERROR\(S\)|ALL CHECKS|WARNING\(S\)' | tail -12
    st_set restore-rc "$rc"
    [ "$rc" -eq 0 ] || warn "restore exited $rc — $TB_STATE/restore.log"
}

# --- finish: manifest, homes, logger ----------------------------------------------------------------------
cmd_finish() {
    local a uid gid hd
    a=$(st_get archive); mountpoint -q "$TB_MNT" || die "target not mounted"
    mkdir -p "$TB_MNT/root/restore-test"
    BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes borg list --format '{type}{TAB}{size}{TAB}{path}{NL}' "$TB_REPO::$a" | gzip -1 > "$TB_MNT/root/restore-test/manifest.tsv.gz" || die "manifest"
    cp "$TB_MNT/root/restore-test/manifest.tsv.gz" "$TB_STATE/manifest.tsv.gz"
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
    sync
    say "unmounting and closing the test drive ..."
    unmount_target
    cmd_fingerprint after >/dev/null
    cmd_fingerprint diff || warn "this machine changed during the test — see $TB_STATE/fingerprint.diff"
    cp "$TB_STATE/fingerprint-after.txt" "$TB_STATE/fingerprint-preboot.txt"
    cat <<MSG

[testbed] Ready to boot the test drive.
  1. Leave only the test drive connected (serial $TB_TARGET_SERIAL).
  2. Reboot, pick it from the firmware boot menu; the passphrase is: test
  3. Wait ~2 minutes after the login screen appears (the logger writes its report to
     this machine's $(layout REPORT_MOUNT) — PARTUUID $(layout REPORT_PARTUUID)).
  4. Boot back into this machine and run:  sudo $0 collect
MSG
}
unmount_target() {
    local m
    for m in $(findmnt -rno TARGET 2>/dev/null | grep -E "^$TB_MNT(/|$)" | sort -r); do umount "$m" 2>/dev/null || umount -l "$m"; done
    for m in tb-home tb-root tb-verify; do [ -e "/dev/mapper/$m" ] && cryptsetup close "$m"; done
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
    # This machine, after booting it again.
    cmd_fingerprint after >/dev/null
    cp "$TB_STATE/fingerprint-before.txt" "$TB_STATE/fingerprint-before.keep" 2>/dev/null
    cmd_fingerprint diff || verdict=FAIL
    # Byte comparison against the archive, hard-link aware, on the test drive read-only.
    local t; t=$(target_disk)
    p=$(partdev root); if [ "$(layout ROOT_CRYPT)" = 1 ]; then printf '%s' "$TB_PASSPHRASE" | cryptsetup open --readonly --key-file=- "$p" tb-verify || die "open test drive"; p=/dev/mapper/tb-verify; fi
    tmp=/run/tb-verify; mkdir -p "$tmp"
    local o=ro; [ "$(layout ROOT_FS)" = btrfs ] && o="ro,rescue=nologreplay,subvol=$(layout_all SUBVOL | awk -F= '$1=="/"{print $2}')"
    mount -o "$o" "$p" "$tmp" || die "mount test root"
    has_role boot && mount -o ro "$(partdev boot)" "$tmp/boot"
    has_role esp && mount -o ro "$(partdev esp)" "$tmp$(layout ESP_MOUNT)"
    python3 "$TB_DIR/compare-manifest.py" "$TB_STATE/manifest.tsv.gz" "$tmp" > "$TB_STATE/byte-comparison.md"
    for m in $(findmnt -rno TARGET | grep -E "^$tmp(/|$)" | sort -r); do umount "$m"; done
    [ -e /dev/mapper/tb-verify ] && cryptsetup close tb-verify
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
    if [ "$keep" = 0 ] && [ -d "$TB_REPO" ]; then
        case "$TB_REPO" in "$BACKUP_MOUNT"/borg-testbed-*) rm -rf "$TB_REPO" && say "deleted the test repository $TB_REPO" ;; *) warn "TB_REPO=$TB_REPO is not a borg-testbed-* path — not deleting it" ;; esac
    fi
    ledger test "reverted: mounts, mappings, transfer sizes, report$( [ "$keep" = 0 ] && echo ', test repository')" "-"
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
    collect)     cmd_collect ;;
    revert)      cmd_revert "$@" ;;
    all)         cmd_fingerprint before && cmd_prepare && cmd_format && cmd_mount && cmd_backup "${1:-functional}" && cmd_restore && cmd_finish ;;
    *)           echo "unknown command: $cmd (see --help)" >&2; exit 2 ;;
esac
