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
# Back in Time Restore + UUID Fixup + ecryptfs Recovery Script
# Restores a BIT snapshot and updates UUIDs in fstab, crypttab, GRUB, and initramfs
# to match the NEW drive's partitions. Handles ecryptfs home directories.
#
# Usage: boot from live USB, mount partitions, then run:
#   sudo ./backintime-restore.sh /mnt/target /mnt/backup/backintime [snapshot-name]
#   sudo ./backintime-restore.sh --files-only /mnt/target /mnt/backup/backintime [snapshot-name]
#
# --files-only: Restore files only, skip UUID fixup/chroot/verification
#               (used by restore.sh launcher in combined mode)
#
# Prerequisites:
#   - Target partitions already created, formatted, and mounted at /mnt/target
#   - /mnt/target/boot and the ESP (/mnt/target/boot/efi or /mnt/target/efi) mounted
#   - LUKS already opened if applicable
#   - Backup drive mounted (unlock LUKS first if needed)
#   - Live USB must have: rsync, cryptsetup, ecryptfs-utils
#     Install if missing (package manager varies by distro)
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

# Full logging
RESTORE_LOG="/tmp/backintime-restore-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$RESTORE_LOG") 2>&1
echo "Full restore log: $RESTORE_LOG"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[RESTORE]${NC} $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$@"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _l in "$SCRIPT_DIR/lib-restore.sh" /usr/local/sbin/lib-restore.sh; do
    # shellcheck disable=SC1090
    [ -r "$_l" ] && { . "$_l"; break; }
done
declare -f rx_detect_ids >/dev/null || fatal "lib-restore.sh not found next to this script or in /usr/local/sbin — it holds the restore pipeline"

# Parse flags: --files-only (restore files, skip fixup/chroot) and --dry-run
FILES_ONLY=false
DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
POS=()
for a in "$@"; do
    case "$a" in
        --files-only) FILES_ONLY=true ;;
        --dry-run|-n) DRY=1 ;;
        *) POS+=("$a") ;;
    esac
done

TARGET="${POS[0]:-}"
BIT_BASE="${POS[1]:-}"
SNAPSHOT_NAME="${POS[2]:-}"

if [ -z "$TARGET" ] || [ -z "$BIT_BASE" ]; then
    cat <<'USAGE'
Usage: backintime-restore.sh [--files-only] <target-mountpoint> <backintime-base-path> [snapshot-name]

Examples:
  # Restore latest snapshot with full UUID fixup:
  backintime-restore.sh /mnt/target /mnt/backup/backintime

  # Restore specific snapshot:
  backintime-restore.sh /mnt/target /mnt/backup/backintime 20260404-030000

  # Files only (skip UUID fixup, used by restore.sh launcher):
  backintime-restore.sh --files-only /mnt/target /mnt/backup/backintime

Steps before running this script:
  1. Boot from a live USB
  2. Install deps: rsync ecryptfs-utils (via your distro's package manager)
  3. Open LUKS:    cryptsetup open /dev/sdX3 <crypt_name>
  4. Activate LVM: vgchange -ay
  5. Mount root:   mount /dev/mapper/<vg_name>-root /mnt/target
  6. Mount boot:   mount /dev/sdX2 /mnt/target/boot
  7. Mount EFI:    mount /dev/sdX1 /mnt/target/boot/efi   (or /mnt/target/efi — where the source had it)
  8. Open backup:  cryptsetup open /dev/sdY1 backup-crypt
  9. Mount backup: mount /dev/mapper/backup-crypt /mnt/backup
  10. Run restore: ./backintime-restore.sh /mnt/target /mnt/backup/backintime

After restore:
  - Reboot, log in, enter your login password to unlock ecryptfs
  - Run: ecryptfs-unwrap-passphrase /home/.ecryptfs/USER/.ecryptfs/wrapped-passphrase
    to verify your ecryptfs passphrase is intact
USAGE
    exit 1
fi

[ -d "$TARGET" ] || fatal "Target $TARGET does not exist"
[ -d "$BIT_BASE" ] || fatal "BIT base $BIT_BASE does not exist"
rx_check_target

###############################################################################
# Step 1: Find and select snapshot
###############################################################################
log "========== BIT RESTORE SESSION START =========="

# Which host's chain: one drive can hold several. The first directory
# alphabetically used to win, with no choice offered.
mapfile -t _HOSTS < <(for d in "$BIT_BASE"/backintime/*/; do [ -d "$d" ] && basename "$d"; done)
[ ${#_HOSTS[@]} -gt 0 ] || fatal "No hostname directory found under $BIT_BASE/backintime/"
BIT_HOST="${RESTORE_HOST:-}"
if [ -z "$BIT_HOST" ] && [ ${#_HOSTS[@]} -eq 1 ]; then BIT_HOST="${_HOSTS[0]}"; fi
if [ -z "$BIT_HOST" ]; then
    if [ -t 0 ]; then
        echo "Back In Time chains from ${#_HOSTS[@]} hosts:"
        select BIT_HOST in "${_HOSTS[@]}"; do [ -n "$BIT_HOST" ] && break; done
    else
        fatal "chains from several hosts (${_HOSTS[*]}) — set RESTORE_HOST=<name>"
    fi
fi
[ -d "$BIT_BASE/backintime/$BIT_HOST" ] || fatal "no chain for host '$BIT_HOST' under $BIT_BASE/backintime/"
log "Backup host: $BIT_HOST"

SNAPSHOT_BASE="$BIT_BASE/backintime/$BIT_HOST/root/1"
[ -d "$SNAPSHOT_BASE" ] || fatal "Snapshot base not found: $SNAPSHOT_BASE"

# List available snapshots
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  AVAILABLE BACK IN TIME SNAPSHOTS${NC}"
echo -e "${BOLD}============================================================${NC}"

SNAPSHOTS=()
while IFS= read -r snap_dir; do
    snap_name=$(basename "$snap_dir")
    if [ -d "$snap_dir/backup" ] && [ ! -e "$snap_dir/failed" ]; then
        SNAPSHOTS+=("$snap_name")
        # Parse date from snapshot name (YYYYMMDD-HHMMSS)
        snap_date="${snap_name:0:4}-${snap_name:4:2}-${snap_name:6:2} ${snap_name:9:2}:${snap_name:11:2}:${snap_name:13:2}"
        snap_size=$(du -sh "$snap_dir/backup" 2>/dev/null | cut -f1)
        echo "  ${snap_name}  (${snap_date})  ${snap_size:-unknown size}"
    fi
done < <(ls -d "$SNAPSHOT_BASE"/*/ 2>/dev/null | sort)

echo -e "${BOLD}============================================================${NC}"
echo ""

[ ${#SNAPSHOTS[@]} -gt 0 ] || fatal "No valid snapshots found in $SNAPSHOT_BASE"

# Select snapshot
if [ -n "$SNAPSHOT_NAME" ]; then
    # Fuzzy match: allow partial name
    MATCHED=""
    for s in "${SNAPSHOTS[@]}"; do
        if [[ "$s" == *"$SNAPSHOT_NAME"* ]]; then
            MATCHED="$s"
            break
        fi
    done
    [ -n "$MATCHED" ] || fatal "No snapshot matching '$SNAPSHOT_NAME' found"
    SNAPSHOT_NAME="$MATCHED"
else
    SNAPSHOT_NAME="${SNAPSHOTS[-1]}"  # Latest
fi

SNAPSHOT_PATH="$SNAPSHOT_BASE/$SNAPSHOT_NAME/backup"
log "Selected snapshot: $SNAPSHOT_NAME"
log "Snapshot path: $SNAPSHOT_PATH"

[ -d "$SNAPSHOT_PATH" ] || fatal "Snapshot backup directory not found: $SNAPSHOT_PATH"

rx_log_state

###############################################################################
# Step 2: Restore the backup via rsync
###############################################################################
log "Restoring snapshot '$SNAPSHOT_NAME' to $TARGET ..."
echo ""
echo -e "${CYAN}Restoring files via rsync... this may take a while.${NC}"
echo ""

if (( ! DRY )) && [ -t 0 ]; then
    echo ""
    echo "  Snapshot: $SNAPSHOT_NAME  (host $BIT_HOST)"
    echo "  Target:   $TARGET  ($(findmnt -no SOURCE,FSTYPE --target "$TARGET" 2>/dev/null))"
    echo ""
    read -rp "Copy this snapshot onto $TARGET? [y/N] " _ans
    [[ "$_ans" =~ ^[yY] ]] || fatal "cancelled"
fi
# rc 23/24 are partial-transfer warnings; under set -e a bare rsync aborted the
# script on them, after the copy and before any fixup.
rsync_rc=0
rsync -aAXH --numeric-ids --info=progress2 ${DRY:+--dry-run} \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/tmp/*' \
    --exclude='/run/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    "$SNAPSHOT_PATH/" "$TARGET/" || rsync_rc=$?

if [ "$rsync_rc" -eq 0 ]; then
    log "Restore completed successfully (rc=0)"
elif [ "$rsync_rc" -eq 24 ]; then
    log "Restore completed with partial transfer warnings (rc=24) — some source files vanished (normal)"
else
    log "WARNING: rsync finished with rc=$rsync_rc"
fi

# Ensure essential directories exist (not in a dry run: it writes nothing)
if (( ! DRY )); then
    for d in dev proc sys tmp run mnt media; do
        mkdir -p "$TARGET/$d"
    done
    chmod 1777 "$TARGET/tmp"
fi

log "File restoration complete."

# If --files-only (or --dry-run), stop before any fixup/chroot changes.
if [ "$FILES_ONLY" = true ] || (( DRY )); then
    if (( DRY )); then
        log "[DRY] file stage was a dry-run; would next update fstab/crypttab UUIDs,"
        log "[DRY] chroot in and rebuild boot via restore-rebuild-boot.sh (GRUB/systemd-boot/UKI)."
        log "========== DRY RUN complete - nothing was changed =========="
    else
        log "Files-only mode — skipping UUID fixup, chroot, and verification."
    fi
    log "Full debug log: $RESTORE_LOG"
    exit 0
fi

###############################################################################
# Steps 3–8: the shared pipeline (lib-restore.sh) — ecryptfs check, the new
# disk's ids, fstab / crypttab / command lines, swapfiles + SELinux, the boot
# rebuild in a chroot, verification. Failed checks are the exit status.
###############################################################################
rx_check_ecryptfs
rx_detect_ids
rx_fix_fstab
rx_fix_crypttab
rx_rewrite_cmdlines
rx_swapfiles_selinux
rx_chroot_rebuild
rx_verify
rx_finish backintime-restore-latest.log
