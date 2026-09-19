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
# backup-diag.sh — the troubleshooting report for linux-backup-system.
#
# Collects everything needed to add a distro, filesystem or boot layout this
# suite does not yet handle, or to reproduce a bug, formatted as Markdown to
# attach to a GitHub issue. It ONLY READS. It mounts nothing, writes nothing
# outside the file you name, runs no backup, and never touches key material:
# keyfiles are reported by path and mode only, LUKS headers are never dumped,
# and every UUID is truncated to 8 characters unless you pass --no-redact.
#
# Usage:
#   sudo backup-diag.sh -o backup-diag.md     write the report to a file
#   sudo backup-diag.sh                       write it to stdout
#   sudo backup-diag.sh --no-redact -o f.md   keep UUIDs whole (private reports)
#   sudo backup-diag.sh --full -o f.md        longer log tails, full journal
#
# Runs without root too: the sections that need it are marked SKIP, not failed.
# Exit 0 whenever the report was written; the findings are in the report.
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

OUT=""; REDACT=1; FULL=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT="${2:?-o needs a file}"; shift ;;
        --no-redact) REDACT=0 ;;
        --full)      FULL=1 ;;
        -h|--help)   sed -n '/^# backup-diag.sh — /,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
TAIL_N=$(( FULL ? 400 : 60 ))
JOURNAL_N=$(( FULL ? 500 : 120 ))

# Find the library the deployed scripts use, or the one next to this file when
# run from a checkout. Its detection functions are what "the suite thinks".
LIB=""
for c in /usr/local/sbin/backup-common.sh "$SELF_DIR/backup-common.sh" /usr/local/lib/backup-common.sh; do
    [ -r "$c" ] && { LIB="$c"; break; }
done

# Where the sibling scripts live: the deployed copies first, else this checkout.
sibling() { # sibling NAME -> path or ""
    local n="$1"
    if [ -x "/usr/local/sbin/$n" ]; then echo "/usr/local/sbin/$n"
    elif [ -f "$SELF_DIR/$n" ]; then echo "$SELF_DIR/$n"
    else echo ""; fi
}

TMP="$(mktemp -t backup-diag.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
exec 3>"$TMP"

out()     { printf '%s\n' "$*" >&3; }
section() { out ""; out "## $*"; out ""; }
sub()     { out ""; out "### $*"; out ""; }
skip()    { out "_SKIP: $*_"; out ""; }

# run LABEL CMD... — a fenced block with the command, its merged output and its
# exit status. Everything runs with a timeout so a hung tool cannot hang the
# report. stdin is /dev/null so nothing can prompt.
run() {
    local label="$1"; shift
    local rc
    out "**\`$label\`**"; out ""; out '```'
    if command -v timeout >/dev/null 2>&1; then
        # RUN_TIMEOUT: backup-verify.sh lists a whole archive; 120 s cut it off
        # on any large repo and the readiness section ended in "exit 124".
        timeout "${RUN_TIMEOUT:-120}" "$@" </dev/null >&3 2>&1; rc=$?
    else
        "$@" </dev/null >&3 2>&1; rc=$?
    fi
    out '```'
    [ "$rc" -eq 0 ] || out "_exit status ${rc}_"
    out ""
}
# runsh LABEL 'shell snippet' — same, for pipelines.
runsh() { run "$1" bash -c "$2"; }

# file LABEL PATH — the file's contents, comments stripped, in a fenced block.
file() {
    local label="$1" f="$2"
    if [ -r "$f" ]; then
        out "**\`$label\`**"; out ""; out '```'
        grep -vE '^\s*(#|$)' "$f" >&3 2>&1 || true
        out '```'; out ""
    else
        out "**\`$label\`**: not present or not readable"; out ""
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }
ver()  { # ver CMD [ARGS...] — one line, or "not installed"
    local c="$1"; shift
    if have "$c"; then
        printf '%s' "$c: " >&3
        timeout 10 "$c" "$@" </dev/null 2>&1 | head -1 >&3 || out "(no version output)"
    else
        out "$c: not installed"
    fi
}

# ---------------------------------------------------------------------------
BX_VERSION=""
if [ -n "$LIB" ]; then
    # shellcheck disable=SC1090
    . "$LIB"
    bx_load_config
fi
CONF="${BX_CONFIG:-/etc/backup-system.conf}"

out "# linux-backup-system troubleshooting report"
out ""
out "| | |"
out "|---|---|"
out "| **Suite version** | ${BX_VERSION:-unknown (no library, or a pre-3.0.0 deployment)} |"
out "| **Library used** | ${LIB:-none} |"
out "| **Generated** | $(date -u '+%Y-%m-%d %H:%M:%S UTC') |"
out "| **Run as root** | $([ $IS_ROOT = 1 ] && echo yes || echo 'no — root-only sections are SKIP') |"
out "| **UUIDs** | $([ $REDACT = 1 ] && echo 'truncated to 8 characters (--no-redact keeps them whole)' || echo 'NOT redacted') |"
out ""
out "> Read this file before you post it. It is built to be safe to paste in"
out "> public — no keyfile contents, no LUKS header material, no passphrases —"
out "> but you are the last check on what leaves your machine."

# ---------------------------------------------------------------------------
section "Host"
file "/etc/os-release" /etc/os-release
run "uname -rm" uname -rm
runsh "hostname / init / firmware" 'echo "hostname=$(hostname)"; echo "init=$(ps -o comm= -p 1 2>/dev/null)"; [ -d /sys/firmware/efi ] && echo firmware=UEFI || echo firmware=BIOS; [ -r /proc/device-tree/compatible ] && printf "device-tree=%s\n" "$(tr "\0" " " </proc/device-tree/compatible)"; true'
if have mokutil; then run "mokutil --sb-state" mokutil --sb-state; else out "mokutil: not installed (Secure Boot state unknown)"; out ""; fi
runsh "virtualisation" 'systemd-detect-virt 2>/dev/null || echo "systemd-detect-virt unavailable"'
# SELinux decides whether a restore relabels, and a type left by a removed policy
# module breaks btrfs replicas ("lsetxattr ... Invalid argument").
runsh "SELinux" 'if command -v getenforce >/dev/null 2>&1; then getenforce; sestatus 2>/dev/null | grep -E "policy name|Current mode|Mode from config"; else echo "not installed"; fi'

# ---------------------------------------------------------------------------
# One screen that says what is NEW about this machine. Every fact the package
# map, the snapshot-engine choice, the source list and the boot rebuild key on,
# gathered without assuming any of them — so a distro, filesystem or boot
# layout the suite has never met is described well enough to be added from
# this file alone. Read-only, like everything else here.
section "Setup fingerprint — for a distro, filesystem or boot layout the suite does not know"
out "The decisions the suite makes, and the raw facts each one is made from. For a"
out "new setup, this section plus *What the suite's own detection reports* below is"
out "what a fix is written from; the maintainer needs nothing else from the machine."
out ""
runsh "fingerprint" '
    . /etc/os-release 2>/dev/null
    echo "os-release:       ID=${ID:-?} ID_LIKE=${ID_LIKE:-} VERSION_ID=${VERSION_ID:-} VARIANT_ID=${VARIANT_ID:-}"
    echo "arch / kernel:    $(uname -m) $(uname -r)   page size $(getconf PAGESIZE 2>/dev/null || echo ?) bytes"
    if [ -d /sys/firmware/efi ]; then fw=UEFI; else fw=BIOS; fi
    [ -r /proc/device-tree/chosen/u-boot,version ] && fw="$fw via U-Boot $(tr -d "\0" < /proc/device-tree/chosen/u-boot,version 2>/dev/null)"
    [ -r /proc/device-tree/chosen/asahi,efi-system-partition ] && fw="$fw (Asahi: stub names ESP PARTUUID $(tr -d "\0" < /proc/device-tree/chosen/asahi,efi-system-partition | cut -c1-8)…)"
    echo "firmware:         $fw$( [ -r /sys/class/dmi/id/sys_vendor ] && printf ";  %s %s" "$(cat /sys/class/dmi/id/sys_vendor)" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"; [ -r /proc/device-tree/model ] && printf ";  %s" "$(tr -d "\0" < /proc/device-tree/model)")"
    pm=""; for p in apt-get dnf yum zypper pacman apk xbps-install emerge slackpkg sbopkg nix-env eopkg rpm-ostree transactional-update pkg urpmi swupd; do command -v "$p" >/dev/null 2>&1 && pm="$pm $p"; done
    echo "package managers: ${pm:- none of the known ones found}"
    rs=$(findmnt -no SOURCE / | sed "s/\[.*//"); echo "root:             $(findmnt -no FSTYPE /) on $rs  options=$(findmnt -no OPTIONS / | cut -c1-80)"
    echo "root stack:       $(lsblk -sno TYPE "$rs" 2>/dev/null | tr "\n" ">" | sed "s/>$//")   (each layer under the root, top down)"
    echo "real filesystems: $(findmnt -rno FSTYPE --real | sort | uniq -c | awk "{printf \"%s x%s  \", \$2, \$1}")"
    echo "kernel supports:  $(grep -vE "nodev" /proc/filesystems | awk "{print \$1}" | tr "\n" " ")"
    echo "encryption:       $(lsblk -rno TYPE | grep -c "^crypt$") open dm-crypt device(s), $(lsblk -rno FSTYPE | grep -c crypto_LUKS) LUKS container(s)"
    echo "volume mgmt:      lvm=$(lsblk -rno TYPE | grep -c "^lvm$") md-raid=$(lsblk -rno TYPE | grep -c "^raid") zfs=$(command -v zpool >/dev/null 2>&1 && zpool list -H 2>/dev/null | wc -l || echo 0) bcachefs=$(findmnt -rno FSTYPE --real | grep -c bcachefs)"
    echo "sector sizes:     $(lsblk -dno NAME,LOG-SEC,PHY-SEC 2>/dev/null | awk "{printf \"%s=%s/%s  \", \$1, \$2, \$3}")   (logical/physical bytes per disk)"
    for e in /boot/efi /efi /boot; do [ -d "$e/EFI" ] || continue; echo "ESP:              $e  vendor dirs: $(ls "$e/EFI" 2>/dev/null | tr "\n" " ")$( [ -f "$e/ubootefi.var" ] && echo " — ubootefi.var present (U-Boot keeps its EFI variables in this file)")"; break; done
    ld=""; for f in /boot/grub2/grub.cfg:GRUB /boot/grub/grub.cfg:GRUB /boot/loader/loader.conf:systemd-boot /efi/loader/loader.conf:systemd-boot /boot/efi/loader/loader.conf:systemd-boot /boot/extlinux/extlinux.conf:extlinux /boot/syslinux/syslinux.cfg:syslinux /boot/refind_linux.conf:rEFInd /boot/limine.conf:Limine /boot/efi/limine.conf:Limine /boot/firmware/config.txt:raspberry-pi-firmware /boot/config.txt:raspberry-pi-firmware; do [ -f "${f%%:*}" ] && ld="$ld ${f##*:}(${f%%:*})"; done
    echo "loader configs:  ${ld:- none of the known ones found}"
    uk=0; for d in /boot/EFI/Linux /efi/EFI/Linux /boot/efi/EFI/Linux; do [ -d "$d" ] && uk=$((uk + $(ls "$d" 2>/dev/null | grep -ci "\.efi$"))); done
    ig=""; for t in dracut mkinitcpio update-initramfs booster kernel-install ukify; do command -v "$t" >/dev/null 2>&1 && ig="$ig $t"; done
    echo "initramfs tools: ${ig:- none found}   unified kernel images: $uk   kernel-install layout: $(grep -hs "^layout=" /etc/kernel/install.conf /usr/lib/kernel/install.conf 2>/dev/null | tail -1 | cut -d= -f2)"
    sn=""; command -v snapper >/dev/null 2>&1 && sn="$sn snapper($(ls /etc/snapper/configs 2>/dev/null | tr "\n" "," | sed "s/,$//"))"; command -v timeshift >/dev/null 2>&1 && sn="$sn timeshift"; [ "$(findmnt -no FSTYPE /)" = btrfs ] && sn="$sn btrfs-subvolumes($(btrfs subvolume list / 2>/dev/null | wc -l))"; command -v zfs >/dev/null 2>&1 && sn="$sn zfs-datasets($(zfs list -H 2>/dev/null | wc -l))"
    echo "snapshot means:  ${sn:- none found (no snapper, timeshift, btrfs root or zfs)}"
    echo "init:             $(ps -o comm= -p 1 2>/dev/null)   SELinux: $(getenforce 2>/dev/null || echo n/a)   AppArmor: $( [ -d /sys/kernel/security/apparmor ] && echo present || echo no)"
'
# The tools each filesystem needs for a backup layer and a restore — present
# or not, with versions. A filesystem with no mkfs/fsck here cannot be laid out
# by the restore test bed, and a snapshot layer for it has to come from
# somewhere else.
runsh "filesystem tooling (present / version)" '
    for fs in $(findmnt -rno FSTYPE --real | sort -u); do
        printf "%-10s" "$fs:"
        for t in "mkfs.$fs" "fsck.$fs"; do command -v "$t" >/dev/null 2>&1 && printf " %s" "$t" || printf " (no %s)" "$t"; done
        case "$fs" in
            btrfs) command -v btrfs >/dev/null 2>&1 && printf "  btrfs-progs %s" "$(btrfs --version 2>/dev/null | head -1 | awk "{print \$NF}")" ;;
            xfs)   command -v xfs_info >/dev/null 2>&1 && printf "  xfsprogs %s" "$(xfs_info -V 2>/dev/null | head -1 | awk "{print \$NF}")" ;;
            ext[234]) command -v tune2fs >/dev/null 2>&1 && printf "  e2fsprogs %s" "$(tune2fs 2>&1 | head -1 | awk "{print \$2}")" ;;
            f2fs)  command -v dump.f2fs >/dev/null 2>&1 && printf "  f2fs-tools" ;;
            zfs)   command -v zfs >/dev/null 2>&1 && printf "  zfs %s" "$(zfs version 2>/dev/null | head -1)" ;;
            bcachefs) command -v bcachefs >/dev/null 2>&1 && printf "  bcachefs-tools %s" "$(bcachefs version 2>/dev/null | head -1)" ;;
            nilfs2) command -v nilfs-tune >/dev/null 2>&1 && printf "  nilfs-utils" ;;
            jfs)   command -v jfs_tune >/dev/null 2>&1 && printf "  jfsutils" ;;
        esac
        echo
    done
    for t in lvm mdadm dmsetup cryptsetup; do command -v "$t" >/dev/null 2>&1 && printf "%s %s\n" "$t" "$("$t" --version 2>/dev/null | head -1)" || echo "$t: not installed"; done
    true'
runsh "block devices with geometry and partition types" 'lsblk -o NAME,TYPE,FSTYPE,FSVER,PARTTYPENAME,SIZE,LOG-SEC,PHY-SEC,ROTA,TRAN,MOUNTPOINTS 2>/dev/null || lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS'
runsh "device-mapper tables (target types only)" 'command -v dmsetup >/dev/null 2>&1 && dmsetup table 2>/dev/null | awk "{print \$1, \$4}" || echo "dmsetup not installed"; true'

section "Tool inventory"
out '```'
ver borg --version
ver rsync --version
ver btrfs --version
ver timeshift --version
ver backintime --version
ver snapper --version
ver cryptsetup --version
ver bootctl --version
ver grub-install --version
ver grub2-install --version
ver grub-mkconfig --version
ver grub2-mkconfig --version
ver dracut --version
ver mkinitcpio --version
ver update-initramfs -h
ver kernel-install --version
ver systemctl --version
ver python3 --version
ver findmnt --version
out '```'

# ---------------------------------------------------------------------------
section "Storage layout"
run "lsblk" lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS,LABEL,UUID,TRAN,HOTPLUG,RM
# --real, not a fixed list of types: a filesystem this suite has never seen is
# exactly the one the report exists for, and a type filter left it out.
run "findmnt (every real filesystem)" findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS --real
# Serial values are not printed; what matters is whether lsblk and udev agree.
# Behind some USB bridges lsblk reports the bridge's SCSI serial (all zeros)
# while the drive's own serial is only in udev's ID_SERIAL_SHORT — the restore
# test bed identifies drives by serial.
runsh "disk serials (agreement only, values not shown)" 'lsblk -dnpo NAME,TRAN,SERIAL | while read -r d t sr; do u=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n "s/^ID_SERIAL_SHORT=//p"); case "$sr" in ""|$t) sr="";; esac; ph=no; [ -z "$sr" ] || [ -z "$(printf %s "$sr" | tr -d 0)" ] && ph=yes; printf "%-14s tran=%-5s lsblk-serial-placeholder=%-3s udev-serial=%-7s agree=%s
" "$d" "${t:--}" "$ph" "$([ -n "$u" ] && echo present || echo absent)" "$([ "$sr" = "$u" ] && echo yes || echo NO)"; done; true'
file "/etc/fstab" /etc/fstab
file "/etc/crypttab" /etc/crypttab
if [ $IS_ROOT = 1 ] && have cryptsetup; then
    sub "LUKS devices (metadata only — never the header, never a key)"
    runsh "cryptsetup luksDump summary per crypto_LUKS device" '
        lsblk -rno PATH,FSTYPE | awk '"'"'$2=="crypto_LUKS"{print $1}'"'"' | while read -r d; do
            echo "== $d"; cryptsetup luksDump "$d" 2>&1 | grep -E "^(Version|Epoch|UUID|.*: luks2|Key Slot [0-9]+:|\s+(Cipher|PBKDF|Memory|Iterations|Time cost|AF hash))" | sed "s/^[[:space:]]*/  /"
        done; true'
else
    skip "LUKS metadata needs root and cryptsetup"
fi

# ---------------------------------------------------------------------------
section "Boot layout"
runsh "ESP candidates" 'for e in /boot/efi /efi /boot /esp; do [ -d "$e/EFI" ] && { echo "$e: has EFI/ (mounted: $(mountpoint -q "$e" && echo yes || echo no), fstype: $(findmnt -no FSTYPE "$e" 2>/dev/null || echo -))"; ls "$e/EFI" 2>/dev/null | sed "s/^/    EFI\//"; }; done; true'
runsh "systemd-boot entries / UKIs" 'for e in /boot/efi /efi /boot; do [ -d "$e/loader/entries" ] && { echo "$e/loader/entries:"; ls "$e/loader/entries" | sed "s/^/    /"; }; [ -d "$e/EFI/Linux" ] && { echo "$e/EFI/Linux:"; ls "$e/EFI/Linux" | sed "s/^/    /"; }; done; true'
runsh "GRUB" 'for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/grub2/grub.cfg.new /boot/grub/grub.cfg.new /etc/default/grub; do [ -f "$f" ] && echo "present: $f"; done; grep -hE "^GRUB_(ENABLE_CRYPTODISK|CMDLINE_LINUX|CMDLINE_LINUX_DEFAULT|FONT|THEME)=" /etc/default/grub 2>/dev/null; true'
# Which loader the firmware really starts. A shim entry can chain to a
# grubx64.efi that was replaced by another loader (systemd-boot) — then GRUB's
# files are not the boot path, and removing shim or its entry breaks booting.
if have efibootmgr; then run "efibootmgr" efibootmgr; else out "efibootmgr: not installed"; out ""; fi
if [ $IS_ROOT = 1 ]; then
    runsh "what each shim on the ESP chains to" 'for e in /boot/efi /efi /boot; do for sh in "$e"/EFI/*/shim*.efi; do [ -f "$sh" ] || continue; d=$(dirname "$sh"); for g in "$d"/grub*.efi; do [ -f "$g" ] || continue; k=unknown; grep -qa "systemd-boot" "$g" && k=systemd-boot; grep -qa "GNU GRUB" "$g" && k=GRUB; echo "$sh -> $(basename "$g"): $k"; done; done; done 2>/dev/null | sort -u; true'
fi
runsh "kernel-install / dracut / mkinitcpio config" 'for f in /etc/kernel/install.conf /etc/kernel/cmdline /etc/dracut.conf /etc/mkinitcpio.conf /etc/initramfs-tools/initramfs.conf; do [ -f "$f" ] && { echo "== $f"; grep -vE "^\s*(#|$)" "$f" | head -20; }; done; ls /etc/dracut.conf.d /etc/mkinitcpio.d /etc/mkinitcpio.conf.d 2>/dev/null; true'
runsh "/boot contents (names only)" 'ls -la /boot 2>/dev/null | awk "{print \$1, \$5, \$NF}"; true'
runsh "installed kernels" 'ls /lib/modules 2>/dev/null; true'
if [ $IS_ROOT = 1 ] && have bootctl; then run "bootctl status" bootctl status --no-pager; fi
runsh "kernel command line" 'cat /proc/cmdline'

# ---------------------------------------------------------------------------
section "Suite configuration"
if [ -r "$CONF" ]; then
    out "**\`$CONF\`** (keyfile shown as path only)"; out ""; out '```'
    grep -vE '^\s*(#|$)' "$CONF" >&3
    out '```'; out ""
    # shellcheck disable=SC1090
    kf=$(. "$CONF" 2>/dev/null; echo "${BACKUP_KEYFILE:-}")
    if [ -n "$kf" ]; then
        if [ -e "$kf" ]; then out "BACKUP_KEYFILE: exists, mode $(stat -c %a "$kf" 2>/dev/null), owner $(stat -c %U "$kf" 2>/dev/null) — contents never included"
        elif [ $IS_ROOT = 0 ]; then out "BACKUP_KEYFILE: \`$kf\` — cannot check without root"
        else out "BACKUP_KEYFILE: \`$kf\` does NOT exist"; fi
        out ""
    fi
else
    out "**\`$CONF\`**: not present — every value is at its built-in default"; out ""
fi
if [ $IS_ROOT = 1 ] && mountpoint -q "${BACKUP_MOUNT:-/mnt/backup}" 2>/dev/null; then
    # A drive another machine also backs up to: btrfs replicas share one
    # directory and are pruned by label, so two hosts on one drive collide.
    runsh "other machines' data on the backup drive (names only)" 'm="${BACKUP_MOUNT:-/mnt/backup}"; echo "Back In Time hosts: $(ls "$m/backintime/backintime" 2>/dev/null | tr "\n" " ")"; echo "btrfs replicas per label: $(ls "$m/snapshots" 2>/dev/null | sed -E "s/_[0-9]{8}_[0-9]{6}$//" | sort | uniq -c | awk "{printf \"%s=%s \", \$2, \$1}")"; echo "test bed repositories: $(ls -d "$m"/borg-testbed-* 2>/dev/null | xargs -r -n1 basename | tr "\n" " ")"; echo "this host: $(hostname)"; true'
fi
runsh "deployed scripts" 'for f in /usr/local/sbin/{backup-common,lib-cmdline,lib-restore,borg-backup,backintime-backup,timeshift-backup,backup-verify,luks-header-backup,restore-rebuild-boot,borg-backup-drive-attach,borg-backup-drive-detach,backup-diag}.sh /usr/local/bin/backup-tray; do [ -e "$f" ] && printf "%s  %s  %s\n" "$(stat -c "%a %U" "$f")" "$(sha256sum "$f" 2>/dev/null | cut -c1-12)" "$f"; done; true'

# ---------------------------------------------------------------------------
section "What the suite's own detection reports"
out "If this disagrees with the raw output above, **that disagreement is the bug**"
out "and the most useful thing in this file."
out ""
if [ -n "$LIB" ]; then
    out '```'
    {
        echo "library:          $LIB (BX_VERSION=${BX_VERSION:-unset, pre-3.0.0})"
        echo "distro family:    $(bx_distro_family)"
        echo "install command:  $(bx_pkg_install_cmd)"
        echo "root fstype:      $(bx_root_fstype)"
        echo "snapshot engine:  $(bx_snapshot_engine)"
        echo "esp mount:        $(bx_esp_mount || echo none)"
        echo "/boot own mount:  $(bx_boot_is_mount && echo yes || echo no)"
        echo "backup sources:   $(bx_backup_sources | tr '\n' ' ')"
        echo "backup mount:     $BACKUP_MOUNT"
        echo "borg repo:        $BORG_REPO"
        echo "schedule mode:    $SCHEDULE_MODE"
        echo "retention:        KEEP=$KEEP MIN_KEEP=$MIN_KEEP MIN_FREE_PCT=$MIN_FREE_PCT MIN_FREE_GIB=$MIN_FREE_GIB"
        if msg=$(bx_check_backup_drive 2>&1); then
            echo "drive guard:      OK (free ${MIN_FREE_PCT}% floor: $(bx_free_pct)% free, $(bx_free_gib) GiB)"
        else
            echo "drive guard:      $msg"
        fi
        echo "linux filesystems: $(bx_human_bytes "$(bx_sources_total_bytes)")  (whole disk $(bx_human_bytes "$(bx_system_disk_bytes)"))   data in sources: $(bx_human_bytes "$(bx_sources_used_bytes)")"
        echo "$(bx_check_backup_capacity 2>&1 || true)"
    } >&3 2>&1
    out '```'; out ""
else
    skip "backup-common.sh not found in /usr/local/sbin or next to this script"
fi

rb=$(sibling restore-rebuild-boot.sh)
if [ -n "$rb" ]; then
    sub "restore-rebuild-boot.sh --dry-run (read-only plan for THIS system's boot chain)"
    run "restore-rebuild-boot.sh --dry-run" bash "$rb" --dry-run
else
    skip "restore-rebuild-boot.sh not found"
fi

dp="$SELF_DIR/deploy.sh"
if [ $IS_ROOT = 1 ] && [ -f "$dp" ]; then
    sub "deploy.sh --dry-run (detection + plan, changes nothing)"
    run "deploy.sh --dry-run" env BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}" bash "$dp" --dry-run
elif [ ! -f "$dp" ]; then
    skip "deploy.sh is not next to this script (run from the checkout to include its dry run)"
else
    skip "deploy.sh --dry-run needs root"
fi

# ---------------------------------------------------------------------------
section "Units, timers and udev"
runsh "unit state" 'for u in borg-backup.timer borg-backup.service backintime-backup.timer backintime-backup.service timeshift-backup.timer timeshift-backup.service backup-verify.timer backup-verify.service luks-header-backup.timer luks-header-backup.service borg-backup-drive-attach.service; do e=$(systemctl is-enabled "$u" 2>/dev/null); a=$(systemctl is-active "$u" 2>/dev/null); printf "%-34s enabled=%-10s active=%s\n" "$u" "${e:-absent}" "${a:-unknown}"; done'
run "list-timers" systemctl list-timers --all --no-pager
runsh "udev rule" 'f=/etc/udev/rules.d/99-borg-backup.rules; [ -f "$f" ] && grep -vE "^\s*(#|$)" "$f" || echo "not installed"'
runsh "masked backup units" 'ls -la /etc/systemd/disabled-backup-units 2>/dev/null || echo none'

# ---------------------------------------------------------------------------
section "USB: drops, bridge resets and authorization"
# A drive that vanished mid-backup and "every USB port died" are usually a
# bridge that reset its UAS link plus USB authorization (USBGuard's lock hook)
# keeping the re-enumerated device out. Both leave traces here.
runsh "unauthorized USB devices (authorized=0)" 'b=$(for d in /sys/bus/usb/devices/*; do [ -f "$d/authorized" ] && [ -f "$d/idVendor" ] && [ "$(cat "$d/authorized")" = 0 ] && echo "$(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"; done); echo "${b:-none}"'
runsh "USB storage drivers (uas vs usb-storage) and quirks" 'lsusb -t 2>/dev/null | grep -iE "mass storage|uas|usb-storage" || echo "no USB storage attached"; echo "usb-storage quirks: $(cat /sys/module/usb_storage/parameters/quirks 2>/dev/null || echo "module not loaded")"'
if have usbguard; then
    runsh "USBGuard policy" 'for p in InsertedDevicePolicy ImplicitPolicyTarget; do printf "%s=%s\n" "$p" "$(usbguard get-parameter "$p" 2>/dev/null || echo "(no IPC access)")"; done; usbguard list-devices 2>/dev/null | grep -E "08:06:(50|62)" | sed -E "s/ hash \"[^\"]*\"//; s/ parent-hash \"[^\"]*\"//; s/ serial \"[^\"]*\"/ serial …/" || true'
else
    out "_USBGuard not installed._"; out ""
fi
if [ $IS_ROOT = 1 ] && have journalctl; then
    runsh "kernel: USB disconnects/resets, this boot and the previous one" 'for b in -1 0; do echo "--- boot $b"; journalctl -k -b "$b" --no-pager -o short-iso 2>/dev/null | grep -E "USB disconnect|uas_zap_pending|reset (Super|high)Speed USB|not authorized for usage|I/O error, dev sd|forced readonly" | tail -n 25; done'
fi

# ---------------------------------------------------------------------------
section "Logs (last $TAIL_N lines each)"
for lg in /var/log/borg-backup.log /var/log/backintime-backup.log /var/log/timeshift-backup.log /var/log/luks-header-backup.log; do
    if [ -r "$lg" ]; then runsh "$lg" "tail -n $TAIL_N '$lg'"
    elif [ -e "$lg" ]; then out "**\`$lg\`**: exists but not readable (run as root)"; out ""
    else out "**\`$lg\`**: absent"; out ""; fi
done
if have journalctl; then
    for u in backup-verify.service borg-backup-drive-attach.service timeshift-backup.service borg-backup.service backintime-backup.service luks-header-backup.service; do
        runsh "journal: $u" "journalctl -u $u --no-pager -o short-iso -n $JOURNAL_N 2>&1 | tail -n $JOURNAL_N"
    done
fi
runsh "restore session logs in /tmp" 'ls -la /tmp/borg-restore-*.log /tmp/backintime-restore-*.log 2>/dev/null || echo none'

# ---------------------------------------------------------------------------
section "Restore test bed runs"
# The evidence a Bare-metal restore row turns green on: attach the state
# directory's LEDGER.md, boot-report/ and byte-comparison.md with the issue.
if [ $IS_ROOT = 1 ]; then
    runsh "/var/lib/linux-backup-testbed" 'n=0; for d in /var/lib/linux-backup-testbed/*/; do [ -d "$d" ] || continue; n=1; g() { cat "$d/$1" 2>/dev/null | head -1; }; printf "%s  verdict=%s vmboot=%s suite=%s backup=%s restore-rc=%s preflight-grub=%s collected=%s\n" "$(basename "$d")" "$(g verdict || true)" "$(g vmboot || true)" "$(g suite-version)" "$(g backup-mode)" "$(g restore-rc)" "$(g preflight-grub-unlock || true)" "$([ -f "$d/finished-collect" ] && echo yes || echo no)"; grep -h "restored with the archived size" "$d/byte-comparison.md" 2>/dev/null | sed "s/^/    /"; done; [ "$n" = 1 ] || echo "no test bed runs on this machine"'
    # The newest run's VM boot (testbed.sh vmboot, run by finish): what the test
    # drive did before anyone booted it for real — its loader on the serial
    # console, and the verdict lines of the boot logger that ran inside the VM.
    runsh "newest test bed run: VM boot of the test drive" 'd=$(ls -1d /var/lib/linux-backup-testbed/*/ 2>/dev/null | sort | tail -1); [ -n "$d" ] || { echo "no test bed runs"; exit 0; }; v="$d/vm"
        echo "run: $(basename "$d")  vmboot=$(cat "$d/vmboot" 2>/dev/null || echo never-ran)"
        [ -s "$d/vmboot-why" ] && echo "why: $(cat "$d/vmboot-why")"
        [ -d "$v" ] || exit 0
        echo "qemu: $(qemu-system-$(uname -m) --version 2>/dev/null | head -1)"
        echo "--- loader on the serial console"; tr -d "\r" < "$v/serial.log" 2>/dev/null | sed "s/\x1b\[[0-9;?]*[a-zA-Z]//g" | grep -aoE "linux-backup-system TEST DRIVE [^:]*|Slot \"[0-9]+\" opened|No key available[^.]{0,80}|error: .{0,100}|Booting .{0,90}|GNU GRUB +version [0-9.]+" | sort | uniq -c | head -20
        r=$(ls -1 "$v"/boot-report/boot-report-*.md 2>/dev/null | sort | tail -1)
        if [ -n "$r" ]; then echo "--- boot logger inside the VM ($(basename "$r"))"; grep -hE "\*\*|system state|_report complete_" "$r"; else echo "--- no boot report from the VM"; fi
        echo "--- screenshots: $(ls "$v"/screen-* 2>/dev/null | wc -l) in $v (attach screen-last.png with a failure)"'
else
    skip "the test bed state needs root"
fi

# ---------------------------------------------------------------------------
section "Restore readiness (backup-verify.sh, read-only)"
bv=$(sibling backup-verify.sh)
if [ $IS_ROOT = 1 ] && [ -n "$bv" ]; then
    RUN_TIMEOUT=900 run "backup-verify.sh" env BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}" BORG_REPO="${BORG_REPO:-}" bash "$bv"
elif [ -z "$bv" ]; then
    skip "backup-verify.sh not found"
else
    skip "backup-verify.sh needs root"
fi

out ""
out "---"
out "_Generated by backup-diag.sh — https://github.com/doug445/linux-backup-system — attach to an issue there; see CONTRIBUTING.md._"

# ---------------------------------------------------------------------------
exec 3>&-
if [ $REDACT = 1 ]; then
    # Keep 8 characters: enough to correlate lines within one report, not
    # enough to fingerprint the disks.
    # UUIDs truncated; and the hostname, user names in home/media paths, disk
    # serials in by-id paths — a report is pasted into a public issue.
    _host=$(hostname 2>/dev/null || uname -n)
    redact() { sed -E 's/([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/\1-…/g; s/([0-9a-fA-F]{4})-([0-9a-fA-F]{4})\b/\1-…/g' \
               | sed -E "s/(^|[^A-Za-z0-9_.-])${_host//./\\.}([^A-Za-z0-9_.-]|$)/\1HOST\2/g; s#/home/[^/ ]+#/home/USER#g; s#/run/media/[^/ ]+#/run/media/USER#g; s#/media/[^/ ]+#/media/USER#g; s#(by-id/[a-z]+-)[^ /]+#\1…#g"; }
else
    redact() { cat; }
fi
if [ -n "$OUT" ]; then
    redact <"$TMP" >"$OUT" || { echo "could not write $OUT" >&2; exit 1; }
    chmod 600 "$OUT" 2>/dev/null || true
    echo "report written: $OUT ($(wc -l <"$OUT") lines)" >&2
else
    redact <"$TMP"
fi
exit 0
