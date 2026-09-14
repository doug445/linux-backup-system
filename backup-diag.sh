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
run "findmnt (real filesystems)" findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS -t ext4,ext3,ext2,btrfs,xfs,f2fs,vfat,exfat,ntfs,zfs,bcachefs
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
runsh "GRUB" 'for f in /boot/grub2/grub.cfg /boot/grub/grub.cfg /etc/default/grub; do [ -f "$f" ] && echo "present: $f"; done; grep -hE "^GRUB_(ENABLE_CRYPTODISK|CMDLINE_LINUX|CMDLINE_LINUX_DEFAULT)=" /etc/default/grub 2>/dev/null; true'
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
runsh "deployed scripts" 'for f in /usr/local/sbin/{backup-common,lib-cmdline,borg-backup,backintime-backup,timeshift-backup,backup-verify,luks-header-backup,restore-rebuild-boot,borg-backup-drive-attach,borg-backup-drive-detach,backup-diag}.sh /usr/local/bin/backup-tray; do [ -e "$f" ] && printf "%s  %s  %s\n" "$(stat -c "%a %U" "$f")" "$(sha256sum "$f" 2>/dev/null | cut -c1-12)" "$f"; done; true'

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
