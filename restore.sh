#!/bin/bash
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
# Master Restore Launcher — 4-Method System Recovery
# Interactive recovery using Snapper, btrfs receive, Borg, and/or Back in Time.
# Run from a live USB after mounting the backup drive, or locally for snapper rollback.
#
# Usage: sudo ./restore.sh
#   (interactive — guides through everything)
#
# Or with pre-mounted target:
#   sudo ./restore.sh /mnt/target
set -uo pipefail

# The borg repo is encryption=none (the LUKS drive encrypts it); without these
# a fresh live USB's borg asks "unknown unencrypted repository — continue?" on
# a stderr that is discarded below, and hangs.
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-/mnt/target}"

# Full logging
RESTORE_LOG="/tmp/restore-launcher-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$RESTORE_LOG") 2>&1
echo "Full restore log: $RESTORE_LOG"

log()   { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[RESTORE]${NC} $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$@"; exit 1; }

confirm() {
    local prompt="$1"
    local response
    echo -en "${YELLOW}$prompt [y/N]: ${NC}"
    read -r response
    [[ "$response" =~ ^[yY]$ ]]
}

banner() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║        4-Method System Recovery Launcher                ║${NC}"
    echo -e "${BOLD}║   Snapper · btrfs · Borg · Back in Time                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

###############################################################################
# Log system state
###############################################################################
log_system_state() {
    log "========== SYSTEM STATE =========="
    log "Date: $(date)"
    log "Kernel: $(uname -r)"
    log "Architecture: $(uname -m)"
    log "Hostname: $(hostname)"
    log "--- Block devices ---"
    lsblk -f 2>&1 || true
    log "--- All UUIDs ---"
    blkid 2>&1 || true
    log "--- Current mounts ---"
    mount 2>&1 || true
    log "--- Root filesystem ---"
    findmnt -n -o SOURCE,FSTYPE,OPTIONS / 2>&1 || true
    log "=================================="
}

###############################################################################
# Step 1: Check dependencies
###############################################################################
check_deps() {
    log "Checking dependencies..."
    local missing=()

    for cmd in rsync blkid findmnt; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    command -v borg &>/dev/null || missing+=("borgbackup")

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing tools: ${missing[*]}"
        echo ""
        echo "Required packages: borgbackup rsync cryptsetup"
        if confirm "Try to install now?"; then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq 2>/dev/null
                apt-get install -y borgbackup rsync cryptsetup lvm2 2>&1
            elif command -v dnf &>/dev/null; then
                dnf install -y borgbackup rsync cryptsetup 2>&1
            elif command -v pacman &>/dev/null; then
                # -Sy: a live ISO's package database is stale by weeks
                pacman -Sy --noconfirm --needed borg rsync cryptsetup lvm2 2>&1
            else
                fatal "No supported package manager found. Install manually."
            fi || fatal "Failed to install some packages."
        else
            fatal "Cannot proceed without required tools."
        fi
    fi
    log "All dependencies present."
}

###############################################################################
# Detect what's available
###############################################################################
detect_capabilities() {
    HAS_SNAPPER=false
    HAS_BTRFS=false
    HAS_BTRFS_SNAPS=false
    HAS_BORG=false
    HAS_BIT=false
    BACKUP_MOUNT=""

    # btrfs root?
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
    if [ "$ROOT_FSTYPE" = "btrfs" ]; then
        HAS_BTRFS=true
    fi

    # snapper available?
    if command -v snapper &>/dev/null && snapper list-configs &>/dev/null 2>&1; then
        HAS_SNAPPER=true
    fi

    # Find backup drive: the host's config (when run on the installed system),
    # then the usual places.
    if [ -r /etc/backup-system.conf ]; then
        BACKUP_MOUNT=$(. /etc/backup-system.conf 2>/dev/null; echo "${BACKUP_MOUNT:-}")
    fi

    # Try common locations
    for mount in "$BACKUP_MOUNT" "/run/media/"*/Borg-backup /mnt/backup; do
        [ -z "$mount" ] && continue
        if mountpoint -q "$mount" 2>/dev/null; then
            BACKUP_MOUNT="$mount"
            break
        fi
    done

    BORG_REPO="$BACKUP_MOUNT/borg-backup"
    BIT_BASE="$BACKUP_MOUNT/backintime"
    BTRFS_SNAP_DIR="$BACKUP_MOUNT/snapshots"

    # Check what backups exist on the drive
    if [ -n "$BACKUP_MOUNT" ] && mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
        [ -d "$BORG_REPO/data" ] && HAS_BORG=true
        [ -d "$BIT_BASE/backintime" ] && HAS_BIT=true
        [ -d "$BTRFS_SNAP_DIR" ] && ls "$BTRFS_SNAP_DIR"/ &>/dev/null 2>&1 && HAS_BTRFS_SNAPS=true
    fi
}

###############################################################################
# Setup backup drive (if not mounted)
###############################################################################
setup_backup_drive() {
    if [ -n "$BACKUP_MOUNT" ] && mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
        log "Backup drive already mounted at $BACKUP_MOUNT"
        return 0
    fi

    echo ""
    echo -e "${CYAN}Backup drive is not mounted. Let's set it up.${NC}"
    echo ""
    echo "Current block devices:"
    lsblk -f 2>&1
    echo ""

    echo "Enter the backup partition device. Default: /dev/sdb1"
    echo -en "Backup device [/dev/sdb1]: "
    read -r backup_dev
    backup_dev="${backup_dev:-/dev/sdb1}"

    [ -b "$backup_dev" ] || fatal "$backup_dev is not a valid block device"

    # Open LUKS if needed
    if command -v cryptsetup &>/dev/null && cryptsetup isLuks "$backup_dev" 2>/dev/null; then
        if ! [ -b /dev/mapper/backup-crypt ]; then
            log "Opening LUKS on $backup_dev..."
            cryptsetup open "$backup_dev" backup-crypt || fatal "Failed to open LUKS."
        fi
        BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
        mkdir -p "$BACKUP_MOUNT"
        mount /dev/mapper/backup-crypt "$BACKUP_MOUNT" || fatal "Failed to mount backup drive"
    else
        BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
        mkdir -p "$BACKUP_MOUNT"
        mount "$backup_dev" "$BACKUP_MOUNT" || fatal "Failed to mount backup drive"
    fi

    log "Backup drive mounted at $BACKUP_MOUNT"
    # Re-detect after mounting
    BORG_REPO="$BACKUP_MOUNT/borg-backup"
    BIT_BASE="$BACKUP_MOUNT/backintime"
    BTRFS_SNAP_DIR="$BACKUP_MOUNT/snapshots"
    [ -d "$BORG_REPO/data" ] && HAS_BORG=true
    [ -d "$BIT_BASE/backintime" ] && HAS_BIT=true
    [ -d "$BTRFS_SNAP_DIR" ] && HAS_BTRFS_SNAPS=true
}

###############################################################################
# Setup target (for non-snapper restores)
###############################################################################
setup_target() {
    echo ""
    echo -e "${BOLD}=== TARGET DRIVE SETUP ===${NC}"
    echo ""

    if mountpoint -q "$TARGET" 2>/dev/null; then
        log "Target already mounted at $TARGET"
        if mountpoint -q "$TARGET/boot" 2>/dev/null; then
            log "  /boot mounted"
        else
            warn "  /boot NOT mounted"
        fi
        if mountpoint -q "$TARGET/boot/efi" 2>/dev/null; then
            log "  /boot/efi mounted"
        elif mountpoint -q "$TARGET/efi" 2>/dev/null; then
            log "  /efi mounted"
        else
            warn "  ESP NOT mounted (neither /boot/efi nor /efi)"
        fi

        if confirm "Use existing mounts at $TARGET?"; then
            return 0
        fi
    fi

    echo ""
    echo "Current block devices:"
    lsblk -f 2>&1
    echo ""
    echo -e "${CYAN}Prepare the target drive before restoring.${NC}"
    echo ""
    echo "For btrfs systems:"
    echo "  1. Mount root subvol: mount -o subvol=root /dev/nvmeXnYpZ $TARGET"
    echo "  2. Mount home subvol: mount -o subvol=home /dev/nvmeXnYpZ $TARGET/home"
    echo "  3. Mount boot:        mount /dev/sdX2 $TARGET/boot"
    echo "  4. Mount EFI:         mount /dev/sdX1 $TARGET/boot/efi   (or $TARGET/efi)"
    echo ""
    echo "For ext4/LUKS/LVM systems:"
    echo "  1. Open LUKS:     cryptsetup open /dev/sdX3 <crypt_name>"
    echo "  2. Activate LVM:  vgchange -ay"
    echo "  3. Mount root:    mount /dev/mapper/<vg_name>-root $TARGET"
    echo "  4. Mount boot:    mount /dev/sdX2 $TARGET/boot"
    echo "  5. Mount EFI:     mount /dev/sdX1 $TARGET/boot/efi   (or $TARGET/efi)"
    echo ""

    echo -e "${YELLOW}Prepare the target now, then press Enter to continue...${NC}"
    read -r

    mkdir -p "$TARGET"
    mountpoint -q "$TARGET" || fatal "$TARGET is not mounted."
    log "Target drive ready at $TARGET"
}

###############################################################################
# Method 1: Snapper rollback (local, fastest)
###############################################################################
do_snapper_rollback() {
    log "=== SNAPPER ROLLBACK ==="

    if ! command -v snapper &>/dev/null; then
        fatal "snapper is not installed"
    fi

    echo ""
    echo -e "${BOLD}Available root snapshots:${NC}"
    snapper -c root list
    echo ""
    echo -e "${BOLD}Available home snapshots:${NC}"
    snapper -c home list
    echo ""

    echo -en "Root snapshot # to rollback to: "
    read -r root_snap
    [ -n "$root_snap" ] || fatal "No snapshot selected"

    echo ""
    echo -e "${BOLD}Rollback plan:${NC}"
    echo "  Root: undo all changes since snapshot #$root_snap"
    echo ""
    echo -e "${CYAN}Changes that will be undone (root):${NC}"
    snapper -c root diff "$root_snap..0" 2>&1 | head -30
    echo "  ... (showing first 30 changes)"
    echo ""

    if ! confirm "Proceed with snapper rollback?"; then
        log "Rollback cancelled."
        return
    fi

    log "Rolling back root to snapshot #$root_snap..."
    snapper -c root undochange "$root_snap..0" 2>&1 | tee -a "$RESTORE_LOG"
    root_rc=$?

    echo ""
    echo -en "Also rollback home? Enter home snapshot # (or Enter to skip): "
    read -r home_snap

    if [ -n "$home_snap" ]; then
        log "Rolling back home to snapshot #$home_snap..."
        snapper -c home undochange "$home_snap..0" 2>&1 | tee -a "$RESTORE_LOG"
    fi

    echo ""
    if [ "$root_rc" -eq 0 ]; then
        echo -e "${GREEN}Snapper rollback complete.${NC}"
        echo "Reboot recommended: sudo reboot"
    else
        echo -e "${RED}Rollback had issues (rc=$root_rc). Check output above.${NC}"
    fi
}

###############################################################################
# Method 2: btrfs receive from backup drive
###############################################################################
do_btrfs_receive() {
    log "=== BTRFS RECEIVE FROM BACKUP DRIVE ==="

    [ -d "$BTRFS_SNAP_DIR" ] || fatal "No btrfs snapshots at $BTRFS_SNAP_DIR"

    echo ""
    echo -e "${BOLD}Available btrfs snapshots on backup drive:${NC}"
    ls -la "$BTRFS_SNAP_DIR/" 2>&1
    echo ""

    # List root snapshots
    echo -e "${CYAN}Root snapshots:${NC}"
    ls -d "$BTRFS_SNAP_DIR"/root_* 2>/dev/null || echo "  (none)"
    echo ""
    echo -e "${CYAN}Home snapshots:${NC}"
    ls -d "$BTRFS_SNAP_DIR"/home_* 2>/dev/null || echo "  (none)"
    echo ""

    echo "Enter the root snapshot to restore (e.g., root_20260404_141542):"
    echo -en "Root snapshot [latest]: "
    read -r root_snap
    if [ -z "$root_snap" ]; then
        root_snap=$(ls -d "$BTRFS_SNAP_DIR"/root_* 2>/dev/null | sort | tail -1)
        root_snap=$(basename "$root_snap")
    fi
    [ -d "$BTRFS_SNAP_DIR/$root_snap" ] || fatal "Snapshot not found: $BTRFS_SNAP_DIR/$root_snap"

    echo -en "Home snapshot [latest]: "
    read -r home_snap
    if [ -z "$home_snap" ]; then
        home_snap=$(ls -d "$BTRFS_SNAP_DIR"/home_* 2>/dev/null | sort | tail -1)
        home_snap=$(basename "$home_snap")
    fi

    echo ""
    echo -e "${BOLD}Restore plan:${NC}"
    echo "  Root: $root_snap"
    echo "  Home: $home_snap"
    echo "  Target: btrfs on $(findmnt -n -o SOURCE / 2>/dev/null || echo '?')"
    echo ""
    echo -e "${YELLOW}WARNING: This will replace the current root and home subvolumes${NC}"
    echo -e "${YELLOW}with the backed-up snapshots. Current data will be in the old subvolume.${NC}"
    echo ""

    if ! confirm "Proceed with btrfs receive restore?"; then
        log "Restore cancelled."
        return
    fi

    # Get the btrfs device
    local btrfs_dev
    btrfs_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//')

    # Mount the top-level subvolid=5 to a temp location
    local toplevel="/tmp/btrfs-toplevel-$$"
    mkdir -p "$toplevel"
    mount -o subvolid=5 "$btrfs_dev" "$toplevel" || fatal "Could not mount btrfs top-level"

    STAMP="$(date +%Y%m%d_%H%M%S)"

    # receive_into SNAP SUBVOL — receive the replica, and only when that
    # succeeded move the live subvolume aside and put a writable snapshot of the
    # replica in its place. The old order (rename first, receive second, exit
    # status never read, a tee in the pipe) left a system with NO root
    # subvolume when the receive failed, and still said "restore complete".
    receive_into() {
        local snap="$1" subvol="$2" rc
        if [ -d "$toplevel/$snap" ]; then
            log "Removing a leftover received copy: $snap"
            btrfs subvolume delete "$toplevel/$snap" >>"$RESTORE_LOG" 2>&1 || true
        fi
        log "Receiving $snap ..."
        btrfs send "$BTRFS_SNAP_DIR/$snap" 2>>"$RESTORE_LOG" | btrfs receive "$toplevel/" >>"$RESTORE_LOG" 2>&1
        rc=("${PIPESTATUS[@]}")
        if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ] || [ "$(btrfs property get "$toplevel/$snap" ro 2>/dev/null | sed -n 's/^ro=//p')" != true ]; then
            error "receive of $snap failed (send rc=${rc[0]}, receive rc=${rc[1]}) — '$subvol' left untouched; see $RESTORE_LOG"
            [ -d "$toplevel/$snap" ] && btrfs subvolume delete "$toplevel/$snap" >>"$RESTORE_LOG" 2>&1 || true
            return 1
        fi
        if [ -d "$toplevel/$subvol" ]; then
            log "Moving current $subvol aside: $subvol → ${subvol}.pre_restore_$STAMP"
            mv "$toplevel/$subvol" "$toplevel/${subvol}.pre_restore_$STAMP" || { error "could not move $subvol aside"; return 1; }
        fi
        if ! btrfs subvolume snapshot "$toplevel/$snap" "$toplevel/$subvol" >>"$RESTORE_LOG" 2>&1; then
            error "could not create writable $subvol from $snap — putting the old one back"
            [ -d "$toplevel/${subvol}.pre_restore_$STAMP" ] && mv "$toplevel/${subvol}.pre_restore_$STAMP" "$toplevel/$subvol"
            return 1
        fi
        btrfs subvolume delete "$toplevel/$snap" >>"$RESTORE_LOG" 2>&1 || true
        log "$subvol restored from $snap"
    }

    local current_root current_home ok=1
    current_root=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=/\K[^,]+')
    [ -n "$current_root" ] || { umount "$toplevel"; fatal "could not tell which subvolume / is mounted from"; }
    receive_into "$root_snap" "$current_root" || ok=0

    # home: the subvolume /home is actually mounted from (@home, home, …), not
    # a hard-coded name — with "home" hard-coded, an @home system got a new,
    # unused toplevel "home" and its real home was never restored.
    if [ "$ok" = 1 ] && [ -n "$home_snap" ] && [ -d "$BTRFS_SNAP_DIR/$home_snap" ]; then
        current_home=$(findmnt -n -o OPTIONS /home 2>/dev/null | grep -oP 'subvol=/\K[^,]+' || true)
        if [ -n "$current_home" ] && [ "$current_home" != "$current_root" ]; then
            receive_into "$home_snap" "$current_home" || ok=0
        else
            warn "/home is not its own subvolume here (it lives inside $current_root) — the home replica is not applied separately"
        fi
    fi
    umount "$toplevel" 2>/dev/null || true
    rmdir "$toplevel" 2>/dev/null || true

    echo ""
    if [ "$ok" = 1 ]; then
        echo -e "${GREEN}btrfs restore complete.${NC}"
        echo "Old subvolumes preserved as *.pre_restore_$STAMP"
        echo "Nested subvolumes (/.snapshots, /var/lib/machines, …) are not carried by send/receive:"
        echo "if fstab mounts one, recreate it (btrfs subvolume create) before rebooting."
        echo "Reboot to use the restored system."
    else
        echo -e "${RED}btrfs restore did NOT complete — see the errors above and $RESTORE_LOG.${NC}"
        echo "Nothing that failed was swapped in; the running subvolumes are as they were."
    fi
}

###############################################################################
# Method 3: Borg extract
###############################################################################
do_borg_restore() {
    local restore_script="$SCRIPT_DIR/borg-restore.sh"
    [ -x "$restore_script" ] || restore_script="/usr/local/sbin/borg-restore.sh"
    [ -x "$restore_script" ] || fatal "borg-restore.sh not found"

    echo ""
    echo -e "${BOLD}Borg Archives:${NC}"
    borg list "$BORG_REPO" 2>/dev/null | tail -10
    echo ""
    echo -en "Archive to restore (Enter for latest): "
    read -r archive

    if [ -n "$archive" ]; then
        "$restore_script" "$TARGET" "$BORG_REPO" "$archive"
    else
        "$restore_script" "$TARGET" "$BORG_REPO"
    fi
}

###############################################################################
# Method 4: Back in Time restore
###############################################################################
do_bit_restore() {
    local restore_script="$SCRIPT_DIR/backintime-restore.sh"
    [ -x "$restore_script" ] || restore_script="/usr/local/sbin/backintime-restore.sh"
    [ -x "$restore_script" ] || fatal "backintime-restore.sh not found"

    echo ""
    echo -en "BIT snapshot to restore (Enter for latest): "
    read -r snapshot

    if [ -n "$snapshot" ]; then
        "$restore_script" "$TARGET" "$BIT_BASE" "$snapshot"
    else
        "$restore_script" "$TARGET" "$BIT_BASE"
    fi
}

###############################################################################
# Method 5: Combined (Borg base + BIT overlay)
###############################################################################
do_combined_restore() {
    log "=== COMBINED RESTORE: Borg base + BIT overlay ==="

    local borg_script="$SCRIPT_DIR/borg-restore.sh"
    [ -x "$borg_script" ] || borg_script="/usr/local/sbin/borg-restore.sh"
    [ -x "$borg_script" ] || fatal "borg-restore.sh not found"

    local bit_script="$SCRIPT_DIR/backintime-restore.sh"
    [ -x "$bit_script" ] || bit_script="/usr/local/sbin/backintime-restore.sh"
    [ -x "$bit_script" ] || fatal "backintime-restore.sh not found"

    # Order matters: the Back In Time overlay copies the snapshot's OLD fstab,
    # crypttab, loader entries and initramfs, so it must land BEFORE the id
    # rewrite and the boot rebuild — the old order undid the fixup it had just
    # done. Files from both layers first, one fixup pass last.
    log "Phase 1/3: extracting the Borg archive (files only)..."
    echo -en "Borg archive (Enter for latest): "
    read -r borg_archive

    if [ -n "$borg_archive" ]; then
        "$borg_script" --files-only "$TARGET" "$BORG_REPO" "$borg_archive"
    else
        "$borg_script" --files-only "$TARGET" "$BORG_REPO"
    fi
    borg_rc=$?
    if [ "$borg_rc" -ne 0 ]; then
        error "Borg extraction finished with errors (rc=$borg_rc)"
        confirm "Continue with the BIT overlay anyway?" || exit "$borg_rc"
    fi

    log "Phase 2/3: overlaying the newest files from Back In Time (files only)..."
    echo -en "BIT snapshot for overlay (Enter for latest): "
    read -r bit_snapshot

    if [ -n "$bit_snapshot" ]; then
        "$bit_script" --files-only "$TARGET" "$BIT_BASE" "$bit_snapshot"
    else
        "$bit_script" --files-only "$TARGET" "$BIT_BASE"
    fi
    bit_rc=$?
    [ "$bit_rc" -eq 0 ] || warn "BIT overlay finished with rc=$bit_rc — continuing to the fixup"

    log "Phase 3/3: fstab/crypttab/command-line rewrite + boot rebuild (one pass, on the combined tree)..."
    "$borg_script" --fixup-only "$TARGET" "$BORG_REPO"

    log "=== COMBINED RESTORE COMPLETE ==="
}

###############################################################################
# Main
###############################################################################
main() {
    banner

    [ "$(id -u)" -eq 0 ] || fatal "Must run as root (sudo)"

    log_system_state
    check_deps
    detect_capabilities

    echo ""
    echo -e "${BOLD}=== DETECTED CAPABILITIES ===${NC}"
    echo "  Root filesystem: $ROOT_FSTYPE"
    echo "  btrfs:           $HAS_BTRFS"
    echo "  Snapper:         $HAS_SNAPPER"
    echo ""

    # For methods requiring backup drive
    if ! $HAS_SNAPPER || $HAS_BORG || $HAS_BIT || $HAS_BTRFS_SNAPS; then
        setup_backup_drive
        # Re-detect after mount
        [ -d "$BORG_REPO/data" ] && HAS_BORG=true
        [ -d "$BIT_BASE/backintime" ] && HAS_BIT=true
        [ -d "$BTRFS_SNAP_DIR" ] && ls "$BTRFS_SNAP_DIR"/ &>/dev/null 2>&1 && HAS_BTRFS_SNAPS=true
    fi

    echo "  Backup drive:    ${BACKUP_MOUNT:-not mounted}"
    echo "  Borg repo:       $HAS_BORG"
    echo "  BIT snapshots:   $HAS_BIT"
    echo "  btrfs snapshots: $HAS_BTRFS_SNAPS"
    echo ""

    # Build options
    echo -e "${BOLD}=== RESTORE OPTIONS ===${NC}"
    echo ""
    local options=()
    local opt_num=0

    if [ "$HAS_SNAPPER" = true ]; then
        ((opt_num++))
        options+=("snapper")
        echo -e "  ${GREEN}$opt_num)${NC} Snapper rollback ${CYAN}(fastest — seconds, local only)${NC}"
        echo "     Undo changes since a specific snapshot. No external drive needed."
    fi

    if [ "$HAS_BTRFS_SNAPS" = true ]; then
        ((opt_num++))
        options+=("btrfs")
        echo -e "  ${GREEN}$opt_num)${NC} btrfs receive from backup drive ${CYAN}(minutes, subvolume replace)${NC}"
        echo "     Restore root/home subvolumes from btrfs send/receive snapshots."
    fi

    if [ "$HAS_BORG" = true ]; then
        ((opt_num++))
        options+=("borg")
        echo -e "  ${GREEN}$opt_num)${NC} Borg extract ${CYAN}(full system, deduplicated archive)${NC}"
        echo "     Restore from a Borg archive. Includes UUID fixup and initramfs rebuild."
    fi

    if [ "$HAS_BIT" = true ]; then
        ((opt_num++))
        options+=("bit")
        echo -e "  ${GREEN}$opt_num)${NC} Back in Time restore ${CYAN}(full system, rsync snapshots)${NC}"
        echo "     Restore from BIT. Plain files — browsable without special tools."
    fi

    if [ "$HAS_BORG" = true ] && [ "$HAS_BIT" = true ]; then
        ((opt_num++))
        options+=("combined")
        echo -e "  ${GREEN}$opt_num)${NC} Combined: Borg base + BIT overlay ${CYAN}(recommended for full rebuild)${NC}"
        echo "     Borg as primary, BIT fills in latest changes. Single UUID fixup pass."
    fi

    [ "$opt_num" -gt 0 ] || fatal "No backup sources found! Check backup drive."

    echo ""
    echo -en "Select restore method [1]: "
    read -r choice
    choice="${choice:-1}"

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$opt_num" ]; then
        fatal "Invalid choice: $choice"
    fi

    RESTORE_MODE="${options[$((choice - 1))]}"
    log "Selected restore mode: $RESTORE_MODE"

    # Snapper and btrfs-receive work on the running system
    # Borg/BIT/combined need a target mount
    case "$RESTORE_MODE" in
        snapper)
            echo ""
            echo -e "${BOLD}=== SNAPPER ROLLBACK ===${NC}"
            echo "  This works on the running system — no target mount needed."
            echo ""
            if confirm "Proceed?"; then
                do_snapper_rollback
            fi
            ;;
        btrfs)
            echo ""
            echo -e "${BOLD}=== BTRFS RECEIVE ===${NC}"
            echo "  This replaces root/home subvolumes on the running system."
            echo "  Current subvolumes will be renamed (preserved)."
            echo ""
            if confirm "Proceed?"; then
                do_btrfs_receive
            fi
            ;;
        borg)
            setup_target
            echo ""
            echo -e "${BOLD}=== BORG RESTORE ===${NC}"
            echo "  Target: $TARGET"
            echo ""
            if confirm "Proceed?"; then
                do_borg_restore
            fi
            ;;
        bit)
            setup_target
            echo ""
            echo -e "${BOLD}=== BACK IN TIME RESTORE ===${NC}"
            echo "  Target: $TARGET"
            echo ""
            if confirm "Proceed?"; then
                do_bit_restore
            fi
            ;;
        combined)
            setup_target
            echo ""
            echo -e "${BOLD}=== COMBINED RESTORE (Borg + BIT) ===${NC}"
            echo "  Target: $TARGET"
            echo ""
            if confirm "Proceed?"; then
                do_combined_restore
            fi
            ;;
    esac

    echo ""
    log "Restore log saved to: $RESTORE_LOG"
}

main "$@"
