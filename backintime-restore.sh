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
mountpoint -q "$TARGET" || fatal "$TARGET is not a mountpoint"

# Restoring from an INSTALLED system (a second disk, a test bed) rather than a
# live USB: nothing may be written to the running system's own disk. The boot
# rebuild must not touch firmware boot entries — bootctl/grub-install would
# put the new disk first in THIS machine's boot order — and borg keeps its
# security/cache state in a temporary directory, not under /root.
if [ -z "${RESTORE_NO_NVRAM:-}" ]; then
    case "$(findmnt -no FSTYPE / 2>/dev/null)" in
        overlay|squashfs|tmpfs|iso9660|aufs|zram) RESTORE_NO_NVRAM=0 ;;
        *) if grep -qE '(^| )(boot=casper|rd\.live\.image|archisobasedir=|archisolabel=|boot=live|root=live:)' /proc/cmdline 2>/dev/null; then RESTORE_NO_NVRAM=0; else RESTORE_NO_NVRAM=1; fi ;;
    esac
fi
export RESTORE_NO_NVRAM
if [ "$RESTORE_NO_NVRAM" = 1 ]; then
    log "Running from an installed system ($(findmnt -no SOURCE / 2>/dev/null)): firmware boot entries will NOT be written (removable-media fallback loaders only) — pick the restored disk from the firmware boot menu. RESTORE_NO_NVRAM=0 overrides."
fi
# Never onto the system this is running from: "/" is a mountpoint too, and so
# is a bind mount of it.
[ "$TARGET" != / ] || fatal "refusing to restore onto / — the running system. Boot a live USB and mount the new disk at a target path."
[ "$(findmnt -no SOURCE --target "$TARGET" 2>/dev/null)" != "$(findmnt -no SOURCE / 2>/dev/null)" ] \
    || fatal "$TARGET is the running root filesystem ($(findmnt -no SOURCE / 2>/dev/null)) — refusing to restore over the live system"

###############################################################################
# Step 1: Find and select snapshot
###############################################################################
log "========== BIT RESTORE SESSION START =========="
log "Date: $(date)"
log "Live system kernel: $(uname -r)"

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

# Log system state
log "--- Block devices ---"
lsblk -f 2>&1 || true
log "--- All UUIDs ---"
blkid 2>&1 || true
log "--- Current mounts ---"
mount 2>&1 || true

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
# Step 3: Verify ecryptfs data integrity
###############################################################################
log "Checking ecryptfs data..."
if [ -d "$TARGET/home/.ecryptfs" ]; then
    ECRYPTFS_ERRORS=0

    for ecryptfs_dir in "$TARGET"/home/.ecryptfs/*/; do
        [ -d "$ecryptfs_dir" ] || continue
        username=$(basename "$ecryptfs_dir")
        log "  Found ecryptfs home for user: $username"

        for f in .ecryptfs/wrapped-passphrase .ecryptfs/Private.sig .ecryptfs/Private.mnt .ecryptfs/auto-mount; do
            if [ -f "$ecryptfs_dir/$f" ]; then
                log "    OK: $f"
            else
                error "    MISSING: $f"
                ECRYPTFS_ERRORS=$((ECRYPTFS_ERRORS + 1))
            fi
        done

        private_count=$(find "$ecryptfs_dir/.Private" -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [ "$private_count" -gt 0 ]; then
            log "    OK: .Private/ has $private_count top-level encrypted files"
        else
            error "    EMPTY: .Private/ directory has no files!"
            ECRYPTFS_ERRORS=$((ECRYPTFS_ERRORS + 1))
        fi

        wp_size=$(stat -c%s "$ecryptfs_dir/.ecryptfs/wrapped-passphrase" 2>/dev/null || echo 0)
        if [ "$wp_size" -ge 50 ] && [ "$wp_size" -le 70 ]; then
            log "    OK: wrapped-passphrase size=$wp_size bytes (expected ~58)"
        else
            error "    BAD: wrapped-passphrase size=$wp_size bytes (expected ~58)"
            ECRYPTFS_ERRORS=$((ECRYPTFS_ERRORS + 1))
        fi

        sig_count=$(wc -l < "$ecryptfs_dir/.ecryptfs/Private.sig" 2>/dev/null || echo 0)
        if [ "$sig_count" -eq 2 ]; then
            log "    OK: Private.sig has 2 signature lines"
        else
            error "    BAD: Private.sig has $sig_count lines (expected 2)"
            ECRYPTFS_ERRORS=$((ECRYPTFS_ERRORS + 1))
        fi

        mnt_path=$(cat "$ecryptfs_dir/.ecryptfs/Private.mnt" 2>/dev/null || true)
        if [ "$mnt_path" = "/home/$username" ]; then
            log "    OK: Private.mnt points to /home/$username"
        else
            warn "    Private.mnt points to '$mnt_path' — may need updating if username changed"
        fi
    done

    if [ "$ECRYPTFS_ERRORS" -gt 0 ]; then
        error "ecryptfs integrity check found $ECRYPTFS_ERRORS error(s)!"
        echo "  WARNING: ecryptfs data may be incomplete. Home directory may not decrypt."
        echo "  Press Enter to continue anyway, or Ctrl+C to abort."
        read -r
    fi

    if [ ! -f "$TARGET/usr/bin/ecryptfs-mount-private" ]; then
        warn "ecryptfs-utils not found in target — ecryptfs auto-mount on login may fail"
        warn "Install ecryptfs-utils after booting (via your distro's package manager)"
    fi
else
    log "No ecryptfs detected — skipping ecryptfs verification"
fi

###############################################################################
# Step 4: Detect new UUIDs from currently mounted devices
###############################################################################
log "Detecting UUIDs for mounted devices..."

echo ""
echo "============================================================"
echo "  UUID DETECTION — CURRENT MOUNTED DEVICES"
echo "============================================================"

# Detect root filesystem type
TARGET_ROOT_DEV=$(findmnt -n -o SOURCE "$TARGET")
TARGET_ROOT_FSTYPE=$(findmnt -n -o FSTYPE "$TARGET" 2>/dev/null || echo "unknown")
ROOT_UUID=$(blkid -s UUID -o value "$TARGET_ROOT_DEV" 2>/dev/null) || true
log "Root device: $TARGET_ROOT_DEV (fstype=$TARGET_ROOT_FSTYPE) → UUID=$ROOT_UUID"

# For btrfs: detect the raw device (strip [/subvol] from source)
BTRFS_RAW_DEV=""
ROOT_SUBVOL=""   # set -u: every ext4/xfs/LVM restore died here as "unbound variable" after extraction
if [ "$TARGET_ROOT_FSTYPE" = "btrfs" ]; then
    BTRFS_RAW_DEV=$(echo "$TARGET_ROOT_DEV" | sed 's/\[.*\]//')
    ROOT_UUID=$(blkid -s UUID -o value "$BTRFS_RAW_DEV" 2>/dev/null) || true
    log "btrfs raw device: $BTRFS_RAW_DEV → UUID=$ROOT_UUID"
    # Detect subvolume names from mount options
    ROOT_SUBVOL=$(findmnt -n -o OPTIONS "$TARGET" | grep -oP 'subvol=/\K[^,]+' || true)
    log "btrfs root subvol: ${ROOT_SUBVOL:-not detected}"
fi

# Detect /home (may be separate partition or btrfs subvol)
HOME_UUID=""
HOME_SUBVOL=""
if mountpoint -q "$TARGET/home" 2>/dev/null; then
    HOME_DEV=$(findmnt -n -o SOURCE "$TARGET/home")
    HOME_FSTYPE=$(findmnt -n -o FSTYPE "$TARGET/home" 2>/dev/null || true)
    if [ "$HOME_FSTYPE" = "btrfs" ]; then
        HOME_RAW_DEV=$(echo "$HOME_DEV" | sed 's/\[.*\]//')
        HOME_UUID=$(blkid -s UUID -o value "$HOME_RAW_DEV" 2>/dev/null) || true
        HOME_SUBVOL=$(findmnt -n -o OPTIONS "$TARGET/home" | grep -oP 'subvol=/\K[^,]+' || true)
        log "Home device: $HOME_RAW_DEV (btrfs subvol=$HOME_SUBVOL) → UUID=$HOME_UUID"
    else
        HOME_UUID=$(blkid -s UUID -o value "$HOME_DEV" 2>/dev/null) || true
        log "Home device: $HOME_DEV → UUID=$HOME_UUID"
    fi
fi

# Detect /boot
BOOT_UUID=""
if mountpoint -q "$TARGET/boot" 2>/dev/null; then
    BOOT_DEV=$(findmnt -n -o SOURCE "$TARGET/boot")
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV" 2>/dev/null) || true
    log "Boot device: $BOOT_DEV → UUID=$BOOT_UUID"
fi

# Detect the ESP: /boot/efi (GRUB) or /efi (systemd-boot with XBOOTLDR at
# /boot, the kernel-install layout). Checking /boot/efi alone left an /efi
# host's fstab naming the old ESP, and the restored system hung at boot.
EFI_UUID=""; EFI_MNT=""
for _e in /boot/efi /efi; do
    mountpoint -q "$TARGET$_e" 2>/dev/null || continue
    EFI_MNT="$_e"
    EFI_DEV=$(findmnt -n -o SOURCE "$TARGET$_e")
    EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV" 2>/dev/null) || true
    log "EFI device:  $EFI_DEV ($_e) → UUID=$EFI_UUID"
    break
done
# No dedicated ESP: /boot itself may be the ESP (systemd-boot on Arch mounts it
# there). Its fstab entry is then the /boot one, rewritten below as /boot.
_pt() { lsblk -dno PARTTYPE "$1" 2>/dev/null | head -1 | tr -d ' ' | tr '[:upper:]' '[:lower:]'; }
_ESP_T=c12a7328-f81f-11d2-ba4b-00a0c93ec93b; _XBL_T=bc13c2ff-59e6-4262-a352-b275fd6f7172
if [ -z "$EFI_MNT" ] && [ -n "${BOOT_DEV:-}" ] && [ "$(findmnt -n -o FSTYPE "$TARGET/boot" 2>/dev/null)" = vfat ]; then
    case "$(_pt "$BOOT_DEV")" in
        "$_ESP_T"|0xef) EFI_MNT=/boot; EFI_DEV="$BOOT_DEV"; EFI_UUID="$BOOT_UUID"
                        log "ESP is /boot itself ($BOOT_DEV, typed EFI System)" ;;
        "")             [ -d "$TARGET/boot/EFI" ] && { EFI_MNT=/boot; EFI_DEV="$BOOT_DEV"; EFI_UUID="$BOOT_UUID"
                        warn "ESP appears to be /boot itself ($BOOT_DEV holds EFI/) — its partition type could not be read"; } ;;
    esac
fi
# Awareness: the NEW disk's partition types. The firmware boots only a
# partition typed EFI System; systemd-boot reads entries only from the ESP or
# a partition typed XBOOTLDR. Wrong types restore every file and still do not
# boot. Checked here, before anything is rewritten, so they can be fixed now.
if [ -n "${EFI_DEV:-}" ]; then
    case "$(_pt "$EFI_DEV")" in
        "$_ESP_T"|0xef) log "  ESP partition type: EFI System — OK" ;;
        "") warn "  ESP $EFI_DEV: partition type unreadable — make sure it is 'EFI System' (sgdisk -t N:ef00)" ;;
        *)  warn "  ESP $EFI_DEV is NOT typed 'EFI System' — the firmware will not boot it. Fix now: sgdisk -t N:ef00 <disk>" ;;
    esac
fi
if [ -n "$EFI_MNT" ] && [ "$EFI_MNT" != /boot ] && [ -n "${BOOT_DEV:-}" ] \
   && [ "$(findmnt -n -o FSTYPE "$TARGET/boot" 2>/dev/null)" = vfat ] \
   && [ ! -d "$TARGET/boot/grub" ] && [ ! -d "$TARGET/boot/grub2" ]; then
    case "$(_pt "$BOOT_DEV")" in
        "$_XBL_T"|0xea) log "  /boot partition type: XBOOTLDR — OK" ;;
        *) warn "  /boot ($BOOT_DEV) is a vfat partition next to the ESP but NOT typed XBOOTLDR — systemd-boot will not see its entries. Fix now: sgdisk -t N:ea00 <disk>" ;;
    esac
fi

# Detect swap — only on the disk(s) the target itself lives on. The first
# swap-typed device on ANY disk used to win: the live USB's, another OS's,
# another drive's, and resume= then pointed at a device the restored system
# never has (a 30-90 s "gave up waiting for suspend/resume device" per boot).
# Every device type: LVM/dm swap, partitions on sd*/nvme*/mmcblk*/vd*.
_disk_of() {
    local d kn pk sl
    d=$(readlink -f "$1" 2>/dev/null) || return 1; kn=$(basename "$d")
    while :; do
        sl=$(ls "/sys/block/$kn/slaves" 2>/dev/null | head -1 || true)
        if [ -n "$sl" ]; then kn="$sl"; continue; fi
        pk=$(lsblk -dno PKNAME "/dev/$kn" 2>/dev/null | head -1 || true)
        if [ -n "$pk" ]; then kn="$pk"; continue; fi
        break
    done
    echo "/dev/$kn"
}
# The dm-crypt mapper under a device — itself, or below LVM — or nothing.
_crypt_under() {
    local kn sl
    kn=$(basename "$(readlink -f "$1" 2>/dev/null)") || return 0
    while [ -n "$kn" ]; do
        case "$(cat "/sys/block/$kn/dm/uuid" 2>/dev/null)" in CRYPT-*) cat "/sys/block/$kn/dm/name"; return 0 ;; esac
        sl=$(ls "/sys/block/$kn/slaves" 2>/dev/null | head -1 || true)
        kn=$sl
    done
    return 0
}
# An LVM mapper name's volume group: mint--vg-root → mint-vg ("--" is an escaped "-").
_dm_vg() { awk '{gsub(/--/, "\001"); split($0, a, "-"); gsub(/\001/, "-", a[1]); print a[1]}' <<<"$1"; }
TARGET_DISKS=" "
for _d in "${BTRFS_RAW_DEV:-$TARGET_ROOT_DEV}" "${BOOT_DEV:-}" "${EFI_DEV:-}"; do
    [ -n "$_d" ] || continue
    TARGET_DISKS="$TARGET_DISKS$(_disk_of "$_d" 2>/dev/null || true) "
done
SWAP_UUID=""; SWAP_DEV=""
while read -r dev; do
    [ -b "$dev" ] || continue
    case "$TARGET_DISKS" in *" $(_disk_of "$dev" 2>/dev/null || true) "*) ;; *) continue ;; esac
    SWAP_DEV="$dev"
    SWAP_UUID=$(blkid -s UUID -o value "$dev" 2>/dev/null) || true
    log "Swap device: $dev → UUID=$SWAP_UUID"
    break
done < <(lsblk -rno PATH,FSTYPE 2>/dev/null | awk '$2=="swap"{print $1}')
[ -n "$SWAP_DEV" ] || log "No swap device on the target disk(s) (${TARGET_DISKS# }) — resume= references, if any, are left for the check below"

# Detect LUKS UUIDs (for crypttab)
HAS_LUKS=false
log "Detecting LUKS devices..."
declare -A LUKS_MAP LUKS_DEV

if command -v dmsetup &>/dev/null; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        mapper_name=$(echo "$line" | awk '{print $1}' | tr -d ':')
        [ -z "$mapper_name" ] && continue
        [ "$mapper_name" = "control" ] && continue
        [ "$mapper_name" = "No" ] && continue

        # Find underlying device
        slave=""
        # Method 1: dmsetup deps
        slave=$(dmsetup deps -o devname "$mapper_name" 2>/dev/null | grep -oP '\(\w+\)' | tr -d '()' | head -1) || true
        # Method 2: /sys/block/dm-*/slaves
        if [ -z "$slave" ]; then
            for dm in /sys/block/dm-*/dm/name; do
                [ -f "$dm" ] || continue
                if [ "$(cat "$dm")" = "$mapper_name" ]; then
                    dm_dir=$(dirname "$(dirname "$dm")")
                    slave=$(ls "$dm_dir/slaves/" 2>/dev/null | head -1) || true
                    break
                fi
            done
        fi

        if [ -n "$slave" ]; then
            underlying="/dev/$slave"
            # Only containers on the restore target: on an installed system the
            # running root's container and the backup drive are open too, and
            # pairing either with the restored system's entries is wrong.
            case "$TARGET_DISKS" in
                *" $(_disk_of "$underlying" 2>/dev/null || true) "*) ;;
                *) log "LUKS: $mapper_name ($underlying) is not on the target disk(s) — ignored"; continue ;;
            esac
            if command -v cryptsetup &>/dev/null && cryptsetup isLuks "$underlying" 2>/dev/null; then
                luks_uuid=$(cryptsetup luksUUID "$underlying" 2>/dev/null) || true
                if [ -n "$luks_uuid" ]; then
                    LUKS_MAP["$mapper_name"]="$luks_uuid"
                    LUKS_DEV["$mapper_name"]="$underlying"
                    HAS_LUKS=true
                    log "LUKS: $mapper_name ← $underlying → UUID=$luks_uuid"
                fi
            fi
        fi
    done < <(dmsetup ls 2>/dev/null)
fi

echo ""
echo "============================================================"
echo "  SUMMARY OF NEW UUIDs"
echo "============================================================"
echo "  Root filesystem:  ${ROOT_UUID:-NOT DETECTED} ($TARGET_ROOT_FSTYPE)"
[ -n "$ROOT_SUBVOL" ] && echo "  Root subvol:      $ROOT_SUBVOL"
echo "  /home:            ${HOME_UUID:-same as root or not separate}"
[ -n "$HOME_SUBVOL" ] && echo "  Home subvol:      $HOME_SUBVOL"
echo "  /boot:            ${BOOT_UUID:-NOT DETECTED}"
echo "  ESP ${EFI_MNT:-/boot/efi or /efi}: ${EFI_UUID:-NOT DETECTED}"
echo "  Swap:             ${SWAP_UUID:-NOT DETECTED (zram or none)}"
echo "  LUKS in use:      $HAS_LUKS"
for name in "${!LUKS_MAP[@]}"; do
    echo "  LUKS ($name): ${LUKS_MAP[$name]}"
done
echo "============================================================"
echo ""

###############################################################################
# Step 5: Read OLD UUIDs from restored files and update fstab
###############################################################################
log "Reading old UUIDs from restored fstab..."

# lib-cmdline.sh: fstab/crypttab parsing and the kernel command-line rewrite.
for _c in "$SCRIPT_DIR/lib-cmdline.sh" /usr/local/sbin/lib-cmdline.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
declare -f cl_rewrite_ids >/dev/null || fatal "lib-cmdline.sh not found next to this script or in /usr/local/sbin — cannot rewrite kernel command lines; the restored system would not boot"
FSTAB="$TARGET/etc/fstab"
CRYPTTAB="$TARGET/etc/crypttab"

[ -f "$FSTAB" ] || fatal "Restored fstab not found at $FSTAB"

log "--- OLD fstab ---"
cat "$FSTAB"
echo ""

FSTAB_ORIG="$FSTAB.bak.$(date +%s)"   # the ids as the source had them (the crypttab pairing reads them)
cp "$FSTAB" "$FSTAB_ORIG"

# Extract old ids from fstab and point each at its new device — by field, in
# the form the entry already uses (UUID=, PARTUUID=, LABEL=, PARTLABEL=). A
# substring match on "UUID=" also matched inside "PARTUUID=" and wrote a
# filesystem UUID where a partition UUID belongs.
# fix_fstab_ref WHAT MOUNT|swap NEWDEV — sets FIX_OLD/FIX_NEW to the swapped
# ids when they are UUIDs or PARTUUIDs (the kernel command-line map needs them).
fix_fstab_ref() {
    local what="$1" mnt="$2" dev="$3" kind="" old="" new=""
    FIX_OLD=""; FIX_NEW=""
    IFS=$'\t' read -r kind old < <(cl_fstab_ref "$FSTAB" "$mnt") || true
    [ -n "$old" ] || return 0
    if [ "$kind" = PATH ]; then
        case "$old" in
            /dev/mapper/*|/dev/[a-z]*-*/*) log "  $what: fstab names $old (a mapper/LVM path, stable across disks) — left as-is" ;;
            /dev/*) warn "  $what: fstab names $old for $mnt — a kernel device name, not an id; check it is right on the new disk" ;;
            *)      log "  $what: fstab names $old (a file, no id to update)" ;;
        esac
        return 0
    fi
    if [ -z "$dev" ]; then
        warn "  $what: fstab has $kind=$old for $mnt but no new device is mounted there — left as-is"
        return 0
    fi
    new=$(blkid -s "$kind" -o value "$dev" 2>/dev/null || true)
    if [ -z "$new" ]; then
        warn "  $what: $dev has no $kind — fstab entry $kind=$old for $mnt left as-is; fix it by hand before rebooting"
        return 0
    fi
    [ "$new" = "$old" ] && { log "  $what: $kind=$old already correct"; return 0; }
    cl_table_set_ref "$FSTAB" 1 "$kind" "$old" "$new"
    log "  Updated $what ($mnt) $kind: $old → $new"
    case "$kind" in UUID|PARTUUID) FIX_OLD="$old"; FIX_NEW="$new" ;; esac
}

log "Old fstab references: root=$(cl_fstab_ref "$FSTAB" / | tr '\t' '=') home=$(cl_fstab_ref "$FSTAB" /home | tr '\t' '=') boot=$(cl_fstab_ref "$FSTAB" /boot | tr '\t' '=') esp=$(cl_fstab_ref "$FSTAB" "${EFI_MNT:-/boot/efi}" | tr '\t' '=') swap=$(cl_fstab_ref "$FSTAB" swap | tr '\t' '=')"

log "Updating fstab..."
# Root first: on btrfs the same UUID also names /home and every other
# subvolume, and cl_table_set_ref rewrites all of those lines at once.
fix_fstab_ref root / "${BTRFS_RAW_DEV:-$TARGET_ROOT_DEV}";   OLD_ROOT_UUID="$FIX_OLD"; ROOT_UUID="${FIX_NEW:-$ROOT_UUID}"
fix_fstab_ref /home /home "${HOME_RAW_DEV:-${HOME_DEV:-}}";   OLD_HOME_UUID="$FIX_OLD"; HOME_UUID="${FIX_NEW:-$HOME_UUID}"
fix_fstab_ref /boot /boot "${BOOT_DEV:-}";                    OLD_BOOT_UUID="$FIX_OLD"; BOOT_UUID="${FIX_NEW:-$BOOT_UUID}"
if [ -n "$EFI_MNT" ] && [ "$EFI_MNT" != /boot ]; then
    fix_fstab_ref ESP "$EFI_MNT" "${EFI_DEV:-}";              OLD_EFI_UUID="$FIX_OLD";  EFI_UUID="${FIX_NEW:-$EFI_UUID}"
else
    OLD_EFI_UUID=""
fi
fix_fstab_ref swap swap "${SWAP_DEV:-}";                      OLD_SWAP_UUID="$FIX_OLD"; SWAP_UUID="${FIX_NEW:-$SWAP_UUID}"

# Comment out backup partition entry (if uncommented)
if grep -v '^\s*#' "$FSTAB" | grep -q 'backup-crypt'; then
    sed -i '/backup-crypt/s/^/#RESTORED# /' "$FSTAB"
    log "  Commented out backup partition entry"
fi

log "--- NEW fstab ---"
cat "$FSTAB"

###############################################################################
# Step 6: Update crypttab with new LUKS UUIDs
###############################################################################
declare -A OPEN_AS=()   # crypttab name → the other name its new container is open under here
if [ -f "$CRYPTTAB" ] && [ "$HAS_LUKS" = true ]; then
    log "Updating crypttab..."
    log "--- OLD crypttab ---"
    cat "$CRYPTTAB"
    cp "$CRYPTTAB" "$CRYPTTAB.bak.$(date +%s)"

    LUKS_ID_MAP="$(mktemp /tmp/restore-luksmap.XXXXXX)"
    for mapper_name in "${!LUKS_MAP[@]}"; do
        new_luks_uuid="${LUKS_MAP[$mapper_name]}"
        c_kind=""; c_old=""; c_new=""
        IFS=$'\t' read -r c_kind c_old < <(cl_crypttab_ref "$CRYPTTAB" "$mapper_name") || true
        [ -n "$c_old" ] || continue
        case "$c_kind" in
            UUID) c_new="$new_luks_uuid" ;;
            PARTUUID|LABEL|PARTLABEL) c_new=$(blkid -s "$c_kind" -o value "${LUKS_DEV[$mapper_name]:-}" 2>/dev/null || true) ;;
            *) warn "  $mapper_name: crypttab names $c_old (a path, not an id) — left as-is; check it is right on the new disk"; continue ;;
        esac
        if [ -z "$c_new" ]; then
            warn "  $mapper_name: no new $c_kind found for ${LUKS_DEV[$mapper_name]:-its device} — crypttab left as-is; fix it by hand"
            continue
        fi
        if [ "$c_old" != "$c_new" ]; then
            case "$c_kind" in UUID|PARTUUID) echo "$c_old $c_new" >> "$LUKS_ID_MAP" ;; esac   # for the command-line rewrite below
            cl_table_set_ref "$CRYPTTAB" 2 "$c_kind" "$c_old" "$c_new"
            log "  Updated $mapper_name $c_kind: $c_old → $c_new"
        fi
    done

    # Containers opened under a name the restored crypttab does not use, while the
    # old ids still exist. On an installed system (a second disk, a test bed) the
    # running system holds the crypttab names (sdb3_crypt, boot_crypt), the new
    # disk's containers get other names, and the old disk is still installed —
    # neither the name match above nor the pairing below reached them, and
    # crypttab kept unlocking the OLD disk. Pair each by what it carries: the
    # restored mount above it, and the crypttab entry that carried that mount on
    # the source (by mapper path, the LVM metadata backup, or the old id's device).
    _entry_for_mount() {
        local k v n vg kn pv
        IFS=$'\t' read -r k v < <(cl_fstab_ref "$FSTAB_ORIG" "$1") || true
        [ -n "$v" ] || return 0
        case "$k" in
            PATH)
                case "$v" in /dev/mapper/*) n=${v#/dev/mapper/} ;; /dev/*/*) n="" ; vg=$(basename "$(dirname "$v")") ;; *) return 0 ;; esac
                if [ -n "$n" ] && [ -n "$(cl_crypttab_ref "$CRYPTTAB" "$n")" ]; then echo "$n"; return 0; fi
                [ -n "$n" ] && vg=$(_dm_vg "$n")
                # the volume group's physical volume, as its restored metadata backup names it
                pv=$(sed -n 's/^[[:space:]]*device = "\([^"]*\)".*/\1/p' "$TARGET/etc/lvm/backup/$vg" 2>/dev/null | head -1)
                n=${pv#/dev/mapper/}
                if [ "$pv" != "$n" ] && [ -n "$(cl_crypttab_ref "$CRYPTTAB" "$n")" ]; then echo "$n"; return 0; fi
                # The backup's device is only a hint, and it can be stale: one
                # written while another disk's group of this name was open named
                # that disk's container. The source's own entry: the one whose
                # container, open on this system, holds a group of this name.
                [ -n "$vg" ] || return 0
                local e ek ev ed em
                while read -r e; do
                    IFS=$'\t' read -r ek ev < <(cl_crypttab_ref "$CRYPTTAB" "$e") || true
                    case "$ek" in UUID|PARTUUID|LABEL|PARTLABEL) ;; *) continue ;; esac
                    ed=$(blkid -t "$ek=$ev" -o device 2>/dev/null | head -1); [ -n "$ed" ] || continue
                    for em in $(lsblk -rno NAME,TYPE "$ed" 2>/dev/null | awk '$2=="crypt"{print $1}'); do
                        [ "$(pvs --config 'backup { backup = 0 archive = 0 }' --noheadings -o vg_name "/dev/mapper/$em" 2>/dev/null | tr -d ' ')" = "$vg" ] && { echo "$e"; return 0; }
                    done
                done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1}' "$CRYPTTAB")
                ;;
            UUID|PARTUUID|LABEL|PARTLABEL)
                kn=$(blkid -t "$k=$v" -o device 2>/dev/null | head -1)
                [ -n "$kn" ] || return 0
                n=$(_crypt_under "$kn")
                [ -n "$n" ] && [ -n "$(cl_crypttab_ref "$CRYPTTAB" "$n")" ] && echo "$n"
                ;;
        esac
        return 0
    }
    for mapper_name in "${!LUKS_MAP[@]}"; do
        [ -n "$(cl_crypttab_ref "$CRYPTTAB" "$mapper_name")" ] && continue
        while read -r _m; do
            _m=$(printf '%b' "$_m")
            case "$_m" in "$TARGET"|"$TARGET"/*) ;; *) continue ;; esac
            _m=${_m#"$TARGET"}; _m=${_m:-/}
            _name=$(_entry_for_mount "$_m")
            [ -n "$_name" ] && [ -z "${OPEN_AS[$_name]:-}" ] || continue
            c_kind=""; c_old=""; c_new=""
            IFS=$'\t' read -r c_kind c_old < <(cl_crypttab_ref "$CRYPTTAB" "$_name") || true
            case "$c_kind" in
                UUID) c_new="${LUKS_MAP[$mapper_name]}" ;;
                PARTUUID|LABEL|PARTLABEL) c_new=$(blkid -s "$c_kind" -o value "${LUKS_DEV[$mapper_name]:-}" 2>/dev/null || true) ;;
                *) continue ;;
            esac
            [ -n "$c_new" ] || continue
            OPEN_AS[$_name]=$mapper_name
            if [ "$(tr '[:upper:]' '[:lower:]' <<<"$c_old")" != "$(tr '[:upper:]' '[:lower:]' <<<"$c_new")" ]; then
                case "$c_kind" in UUID|PARTUUID) echo "$c_old $c_new" >> "$LUKS_ID_MAP" ;; esac
                cl_table_set_ref "$CRYPTTAB" 2 "$c_kind" "$c_old" "$c_new"
                log "  Updated $_name $c_kind: $c_old → $c_new (carries $_m; its new container is open here as '$mapper_name')"
            fi
            break
        done < <(lsblk -rno MOUNTPOINTS "/dev/mapper/$mapper_name" 2>/dev/null | grep .)
    done

    # Entries no open mapper matched BY NAME. Fedora names its mapper
    # luks-<OLD-UUID>; on the new disk the container is opened as
    # luks-<NEW-UUID> or cryptroot, nothing matched, crypttab kept the old
    # id and the initramfs was rebuilt against it. With exactly one unmatched
    # entry whose device is gone and exactly one open container no entry
    # names, they are each other's.
    _matched=" "
    for mapper_name in "${!LUKS_MAP[@]}"; do
        [ -n "$(cl_crypttab_ref "$CRYPTTAB" "$mapper_name")" ] && _matched="$_matched$mapper_name "
    done
    for _name in "${!OPEN_AS[@]}"; do _matched="$_matched${OPEN_AS[$_name]} "; done
    _unmatched_maps=()
    for mapper_name in "${!LUKS_MAP[@]}"; do
        case "$_matched" in *" $mapper_name "*) ;; *) _unmatched_maps+=("$mapper_name") ;; esac
    done
    _unmatched_entries=()
    while read -r _name; do
        [ -n "$_name" ] || continue
        [ -n "${LUKS_MAP[$_name]:-}" ] && continue
        c_kind=""; c_old=""
        IFS=$'\t' read -r c_kind c_old < <(cl_crypttab_ref "$CRYPTTAB" "$_name") || true
        case "$c_kind" in UUID|PARTUUID) ;; *) continue ;; esac
        cl_ref_exists "$c_kind" "$c_old" && continue      # still present: a second drive carried over
        if cl_crypttab_optional "$CRYPTTAB" "$_name"; then  # noauto/nofail: a data drive, not the boot
            log "  $_name: optional data drive (noauto/nofail), not connected here — left as-is"
            continue
        fi
        _unmatched_entries+=("$_name")
    done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1}' "$CRYPTTAB")
    if [ ${#_unmatched_entries[@]} -eq 1 ] && [ ${#_unmatched_maps[@]} -eq 1 ]; then
        _name="${_unmatched_entries[0]}"; mapper_name="${_unmatched_maps[0]}"
        c_kind=""; c_old=""; c_new=""
        IFS=$'\t' read -r c_kind c_old < <(cl_crypttab_ref "$CRYPTTAB" "$_name") || true
        if [ "$c_kind" = UUID ]; then c_new="${LUKS_MAP[$mapper_name]}"
        else c_new=$(blkid -s "$c_kind" -o value "${LUKS_DEV[$mapper_name]:-}" 2>/dev/null || true); fi
        if [ -n "$c_new" ]; then
            warn "crypttab entry '$_name' ($c_kind=$c_old, no such device here) is the only unmatched entry and '$mapper_name' (${LUKS_DEV[$mapper_name]:-?}) the only open container no entry names — pairing them"
            case "$c_kind" in UUID|PARTUUID) echo "$c_old $c_new" >> "$LUKS_ID_MAP" ;; esac
            cl_table_set_ref "$CRYPTTAB" 2 "$c_kind" "$c_old" "$c_new"
            log "  Updated $_name $c_kind: $c_old → $c_new (the mapper keeps the name '$_name'; the initramfs creates it from crypttab)"
        fi
    elif [ ${#_unmatched_entries[@]} -gt 0 ]; then
        for _name in "${_unmatched_entries[@]}"; do
            warn "crypttab entry '$_name' names a device that does not exist here and no open mapper is called '$_name' — open the new container under that name (cryptsetup open <dev> $_name) and re-run, or fix crypttab by hand; the check below will flag it"
        done
    fi

    # Comment out backup-crypt entry
    if grep -q '^backup-crypt' "$CRYPTTAB"; then
        sed -i '/^backup-crypt/s/^/#RESTORED# /' "$CRYPTTAB"
        log "  Commented out backup-crypt entry"
    fi

    log "--- NEW crypttab ---"
    cat "$CRYPTTAB"

    # Which entries now name a target container that is open under ANOTHER name
    # (also when crypttab was already right).
    OPEN_AS=()
    while read -r _name; do
        IFS=$'\t' read -r c_kind c_old < <(cl_crypttab_ref "$CRYPTTAB" "$_name") || true
        [ "$c_kind" = UUID ] || continue
        for mapper_name in "${!LUKS_MAP[@]}"; do
            [ "$(tr '[:upper:]' '[:lower:]' <<<"${LUKS_MAP[$mapper_name]}")" = "$(tr '[:upper:]' '[:lower:]' <<<"$c_old")" ] || continue
            [ "$mapper_name" != "$_name" ] && OPEN_AS[$_name]=$mapper_name
        done
    done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1}' "$CRYPTTAB")
    for _name in "${!OPEN_AS[@]}"; do
        warn "crypttab entry '$_name' is this disk's container, open here as '${OPEN_AS[$_name]}' (the running system holds '$_name') — the boot rebuild is told explicitly"
    done
elif [ -f "$CRYPTTAB" ]; then
    log "crypttab exists but no LUKS devices detected — leaving unchanged"
else
    log "No crypttab found — skipping (no LUKS)"
fi

###############################################################################
# Step 5b: Rewrite every kernel command-line carrier to the new ids.
#
# The kernel finds the root, and the initramfs the LUKS container, from the
# command line — which lives in BLS / systemd-boot entries, /etc/kernel/cmdline
# and cmdline.d, GRUB_CMDLINE_LINUX and its drop-ins, extlinux.conf,
# cmdline.txt, refind_linux.conf, limine.conf. fstab and crypttab alone are
# not enough: a carrier still naming the old disk stops in the initramfs.
# lib-cmdline.sh rewrites reference positions only and never a mapper name.
###############################################################################
ID_MAP="$(mktemp /tmp/restore-idmap.XXXXXX)"
{
    [ -n "$OLD_ROOT_UUID" ] && [ -n "$ROOT_UUID" ] && echo "$OLD_ROOT_UUID $ROOT_UUID"
    [ -n "$OLD_HOME_UUID" ] && [ -n "$HOME_UUID" ] && echo "$OLD_HOME_UUID $HOME_UUID"
    [ -n "$OLD_BOOT_UUID" ] && [ -n "$BOOT_UUID" ] && echo "$OLD_BOOT_UUID $BOOT_UUID"
    [ -n "$OLD_EFI_UUID" ]  && [ -n "$EFI_UUID" ]  && echo "$OLD_EFI_UUID $EFI_UUID"
    [ -n "$OLD_SWAP_UUID" ] && [ -n "$SWAP_UUID" ] && echo "$OLD_SWAP_UUID $SWAP_UUID"
    [ -n "${LUKS_ID_MAP:-}" ] && [ -s "$LUKS_ID_MAP" ] && cat "$LUKS_ID_MAP"
} > "$ID_MAP"

# The ROOT container. With the old disk still installed its old id exists on
# this machine and the running system holds its mapper name, so neither the
# crypttab pairing nor the mapper-name bridge above reaches it — and the
# restored disk would boot by unlocking the OLD disk. The container under the
# target's root filesystem is the new root container, whatever it is called.
OLD_ROOT_LUKS=$(cl_root_luks_id "$TARGET")
NEW_ROOT_LUKS=""
_rsrc=$(findmnt -no SOURCE "$TARGET" 2>/dev/null | sed 's/\[.*//')
if [[ "$_rsrc" == /dev/mapper/* ]]; then
    _rb=$(cryptsetup status "${_rsrc#/dev/mapper/}" 2>/dev/null | awk '/device:/{print $2}')
    [ -n "$_rb" ] && NEW_ROOT_LUKS=$(cryptsetup luksUUID "$_rb" 2>/dev/null || true)
fi
if [ -n "$OLD_ROOT_LUKS" ] && [ -n "$NEW_ROOT_LUKS" ]; then
    if [ "$OLD_ROOT_LUKS" != "$(tr '[:upper:]' '[:lower:]' <<<"$NEW_ROOT_LUKS")" ] && ! grep -qi "^$OLD_ROOT_LUKS " "$ID_MAP"; then
        echo "$OLD_ROOT_LUKS $NEW_ROOT_LUKS" >> "$ID_MAP"
        log "Root LUKS container: $OLD_ROOT_LUKS → $NEW_ROOT_LUKS (the container under $TARGET; its mapper name stays as the restored system declares it)"
    fi
elif [ -n "$OLD_ROOT_LUKS" ]; then
    warn "the restored system unlocks its root from LUKS container $OLD_ROOT_LUKS, but $TARGET is not on a LUKS container — its boot will ask for a container that is not there; restore onto an encrypted root, or remove rd.luks/cryptdevice from the command line"
fi

# Hibernation into a swapfile on the root filesystem: resume=UUID= names that
# filesystem. fstab names the root by mapper path here, so the root filesystem
# mapping above never saw the old id; the resume id is it.
RESUME_ID=""; RESUME_OFF=""
IFS=$'\t' read -r RESUME_ID RESUME_OFF < <(cl_resume_file_ref "$TARGET") || true
if [ -n "$RESUME_ID" ] && awk '$1 !~ /^#/ && $3=="swap" && $1 ~ /^\// && $1 !~ /^\/dev\// {f=1} END{exit !f}' "$FSTAB"; then
    if [ -n "$ROOT_UUID" ] && ! grep -qi "^$RESUME_ID " "$ID_MAP"; then
        echo "$RESUME_ID $ROOT_UUID" >> "$ID_MAP"
        log "resume= (swapfile on the root filesystem): $RESUME_ID → $ROOT_UUID"
    fi
fi

# crypttab and crypttab.initramfs, by id, for every container mapping — the
# name-based loop above does not see crypttab.initramfs (mkinitcpio sd-encrypt
# bakes it into the initramfs; left stale, the restored disk's initramfs asks
# for the OLD disk's container at every boot).
for _ct in "$CRYPTTAB" "$TARGET/etc/crypttab.initramfs"; do
    [ -f "$_ct" ] || continue
    _changed=0
    while read -r _o _n _; do
        [ -n "$_o" ] && [ -n "$_n" ] || continue
        if awk -v o="$(tr '[:upper:]' '[:lower:]' <<<"$_o")" '$1 !~ /^#/ {d=tolower($2); gsub(/"/,"",d); if (d=="uuid=" o) f=1} END{exit !f}' "$_ct"; then
            [ "$_changed" = 1 ] || cp "$_ct" "$_ct.bak.$(date +%s)"
            _changed=1
            _cur=$(awk -v o="$(tr '[:upper:]' '[:lower:]' <<<"$_o")" '$1 !~ /^#/ {d=$2; gsub(/"/,"",d); if (tolower(d)=="uuid=" o) {sub(/^UUID=/,"",d); print d; exit}}' "$_ct")
            cl_table_set_ref "$_ct" 2 UUID "$_cur" "$_n"
            log "  ${_ct#"$TARGET"}: UUID=$_cur → $_n"
        fi
    done < "$ID_MAP"
done
# Command lines that bind a container id to a mapper NAME — cryptdevice=
# UUID=<id>:<name> (Arch encrypt hook), rd.luks.name=<id>=<name> (dracut,
# sd-encrypt) — declare the root container themselves, not in crypttab, so
# crypttab alone never yields their new id. The name is the bridge to the
# container opened under it.
if [ "$HAS_LUKS" = true ]; then
    while IFS=$'\t' read -r _oid _mname; do
        [ -n "$_oid" ] && [ -n "${LUKS_MAP[$_mname]:-}" ] || continue
        _nid=$(tr '[:upper:]' '[:lower:]' <<<"${LUKS_MAP[$_mname]}")
        [ "$_oid" != "$_nid" ] || continue
        grep -qi "^$_oid " "$ID_MAP" && continue
        echo "$_oid ${LUKS_MAP[$_mname]}" >> "$ID_MAP"
        log "  mapped LUKS $_oid → ${LUKS_MAP[$_mname]} through mapper name '$_mname' (declared on the command line, not in crypttab)"
    done < <(cl_find_carriers "$TARGET" | while IFS=$'\t' read -r _k _f; do cl_luks_name_pairs "$_f"; done | sort -u)
    # A single rd.luks.uuid=/luks.uuid= id that is stale and still unmapped,
    # and a single open container nothing maps to yet: that is it.
    _mapped_new=" $(awk '{print tolower($2)}' "$ID_MAP" | tr '\n' ' ') "
    _unmapped=()
    for mapper_name in "${!LUKS_MAP[@]}"; do
        case "$_mapped_new" in *" $(tr '[:upper:]' '[:lower:]' <<<"${LUKS_MAP[$mapper_name]}") "*) ;; *) _unmapped+=("$mapper_name") ;; esac
    done
    _stale_luks=$(cl_find_carriers "$TARGET" | while IFS=$'\t' read -r _k _f; do cl_ids_in_file "$_f"; done \
                  | awk '$1=="luks"{print $2}' | sort -u \
                  | while read -r _id; do cl_id_exists luks "$_id" || grep -qi "^$_id " "$ID_MAP" || echo "$_id"; done)
    if [ "$(wc -w <<<"$_stale_luks")" -eq 1 ] && [ ${#_unmapped[@]} -eq 1 ]; then
        echo "$_stale_luks ${LUKS_MAP[${_unmapped[0]}]}" >> "$ID_MAP"
        warn "command line names LUKS container $_stale_luks, which does not exist here; '${_unmapped[0]}' (${LUKS_DEV[${_unmapped[0]}]:-?}) is the only open container nothing else maps to — mapping them"
    fi
fi
log "Rewriting kernel command-line carriers ($(grep -c . "$ID_MAP") id mappings)..."
n_carriers=$(cl_find_carriers "$TARGET" | wc -l)
log "  carriers found under $TARGET: $n_carriers"
cl_find_carriers "$TARGET" | while IFS=$'\t' read -r k f; do log "    $k: ${f#"$TARGET"}"; done
while IFS=$'\t' read -r k f; do log "  rewrote $k: ${f#"$TARGET"}"; done < <(cl_rewrite_ids "$TARGET" "$ID_MAP")
# Every full GRUB config too. The boot rebuild regenerates the one the distro's
# generator owns; a GRUB built from source reads another (/boot/grub/ on Fedora)
# that nothing regenerates, and restored verbatim it booted the OLD disk.
mapfile -t _grub_cfgs < <(cl_grub_cfgs "$TARGET")
if [ ${#_grub_cfgs[@]} -gt 0 ]; then
    while IFS=$'\t' read -r k f; do log "  rewrote $k: ${f#"$TARGET"}"; done < <(cl_rewrite_files "$ID_MAP" grubcfg "${_grub_cfgs[@]}")
fi
# The new root/home/boot/ESP filesystem ids are declared by the mounts
# themselves even where fstab names a mapper path (and a swapfile's resume=
# names the root filesystem): not "undeclared".
left=$(CL_EXTRA_EXPECTED="${ROOT_UUID:-} ${HOME_UUID:-} ${BOOT_UUID:-} ${EFI_UUID:-}" cl_carrier_mismatches "$TARGET")
if [ -n "$left" ]; then
    warn "command-line ids not declared by the restored fstab/crypttab (check before rebooting):"
    while IFS=$'\t' read -r k f rk id; do warn "    $k ${f#"$TARGET"}: $rk $id"; done <<<"$left"
fi

###############################################################################
# Step 7: Chroot and update initramfs + GRUB
###############################################################################
# SELinux: files restored without their labels make an enforcing system refuse
# logins and services. The Back In Time layer strips security.* xattrs by
# design, and a live USB without SELinux may not write them back on a borg
# extract either. /.autorelabel has the restored system relabel every file on
# its first boot — one slow boot and one extra reboot, on every SELinux target.
# Swapfiles: an active swapfile is in no file-level backup, so fstab names a
# file the restored disk does not have. Re-create it (RAM-sized, so
# hibernation still fits) and point resume_offset= at its new blocks.
while read -r _swf; do
    _tgt="$TARGET$_swf"
    [ -e "$_tgt" ] && { log "swapfile $_swf present in the restore"; continue; }
    _dir=$(dirname "$_tgt")
    _p="$_dir"; while [ ! -d "$_p" ]; do _p=$(dirname "$_p"); done
    _fs=$(findmnt -no FSTYPE --target "$_p" 2>/dev/null)
    _gib=$(( ( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) + 1048575 ) / 1048576 ))
    log "re-creating swapfile $_swf (${_gib} GiB, $_fs) — swapfiles are never in a file-level backup"
    if [ "$_fs" = btrfs ]; then
        [ -d "$_dir" ] || btrfs subvolume create "$_dir" >/dev/null || mkdir -p "$_dir"
        if ! btrfs filesystem mkswapfile --size "${_gib}g" "$_tgt" >/dev/null 2>&1; then
            touch "$_tgt"; chattr +C "$_tgt" 2>/dev/null || true
            fallocate -l "${_gib}G" "$_tgt" && chmod 600 "$_tgt" && mkswap "$_tgt" >/dev/null || warn "could not create $_swf — fstab's swap line will fail at boot (non-fatal); create it by hand"
        fi
        _off=$(btrfs inspect-internal map-swapfile -r "$_tgt" 2>/dev/null || true)
    else
        mkdir -p "$_dir"
        { fallocate -l "${_gib}G" "$_tgt" 2>/dev/null || dd if=/dev/zero of="$_tgt" bs=1M count=$(( _gib * 1024 )) status=none; } \
            && chmod 600 "$_tgt" && mkswap "$_tgt" >/dev/null || warn "could not create $_swf"
        _off=$(filefrag -v "$_tgt" 2>/dev/null | awk '$1=="0:" {sub(/\.\./,"",$4); print $4; exit}')
    fi
    if [ -n "$RESUME_OFF" ]; then
        if [ -n "$_off" ]; then
            while IFS=$'\t' read -r _k _f; do log "  resume_offset=$RESUME_OFF → $_off in $_k ${_f#"$TARGET"}"; done < <(cl_set_resume_offset "$TARGET" "$_off")
        else
            warn "could not read the new swapfile's physical offset — resume_offset=$RESUME_OFF is stale; hibernation must not be used until it is fixed"
        fi
    fi
done < <(awk '$1 !~ /^#/ && $3=="swap" && $1 ~ /^\// && $1 !~ /^\/dev\// {print $1}' "$FSTAB")

SELINUX_MODE=$(awk -F= '/^[[:space:]]*SELINUX=/{gsub(/[[:space:]"]/, "", $2); print $2; exit}' "$TARGET/etc/selinux/config" 2>/dev/null || true)
case "$SELINUX_MODE" in
    enforcing|permissive)
        touch "$TARGET/.autorelabel"
        log "SELinux ($SELINUX_MODE) in the restored system: created /.autorelabel — the first boot relabels every file, then reboots once" ;;
    *)  log "SELinux not enabled in the restored system (${SELINUX_MODE:-no /etc/selinux/config}) — no relabel needed" ;;
esac

log "Preparing chroot environment..."

# Undo the binds on ANY exit: a set -e abort between here and the cleanup
# below used to leave $TARGET/dev, /proc, /sys mounted, and the next attempt
# (or an umount of the target) failed on them.
cleanup_chroot() {
    local m
    for m in sys/firmware/efi/efivars run dev/pts dev proc sys; do umount "$TARGET/$m" 2>/dev/null || true; done
    release_crypttab
}
# Debian's initramfs hook (cryptsetup-initramfs) finds the root container's
# crypttab entry by the name the container is OPEN under. Open here under another
# name (see OPEN_AS), it finds none, and the initramfs cannot unlock the root — the
# restored disk stops at "waiting for encrypted source device". For the rebuild
# only, such entries carry the 'initramfs' option (included whatever they are open
# as); the restored crypttab is put back right after.
CRYPTTAB_HELD=""
release_crypttab() {
    [ -n "$CRYPTTAB_HELD" ] && [ -f "$CRYPTTAB_HELD" ] || return 0
    cat "$CRYPTTAB_HELD" > "$CRYPTTAB"; rm -f "$CRYPTTAB_HELD"; CRYPTTAB_HELD=""
    log "crypttab put back as restored (the rebuild-only 'initramfs' option removed)"
}
if [ ${#OPEN_AS[@]} -gt 0 ] && [ -f "$TARGET/usr/share/initramfs-tools/hooks/cryptroot" ]; then
    _early=" $(_crypt_under "${BTRFS_RAW_DEV:-$TARGET_ROOT_DEV}") "
    mountpoint -q "$TARGET/usr" && _early="$_early$(_crypt_under "$(findmnt -no SOURCE "$TARGET/usr" | sed 's/\[.*//')") "
    for _name in "${!OPEN_AS[@]}"; do
        case "$_early" in *" ${OPEN_AS[$_name]} "*) ;; *) continue ;; esac
        if [ -z "$CRYPTTAB_HELD" ]; then CRYPTTAB_HELD=$(mktemp /tmp/restore-crypttab.XXXXXX); cp "$CRYPTTAB" "$CRYPTTAB_HELD"; fi
        awk -v n="$_name" 'BEGIN{OFS="\t"} $1 !~ /^#/ && $1==n { if (NF < 4 || $4 == "") $4 = "initramfs"; else if (("," $4 ",") !~ /,initramfs,/) $4 = $4 ",initramfs" } {print}' "$CRYPTTAB_HELD" > "$CRYPTTAB"
        log "crypttab '$_name': 'initramfs' for the rebuild only — the initramfs hook looks the root container up by its open name, and here it is open as '${OPEN_AS[$_name]}'"
    done
fi
trap cleanup_chroot EXIT

mkdir -p "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run"
mount --bind /dev  "$TARGET/dev"
mount --bind /dev/pts "$TARGET/dev/pts"
mount -t proc proc "$TARGET/proc"
mount -t sysfs sys "$TARGET/sys"
# /run too: dracut, lvm and bootctl look for udev's and systemd's state there
# (arch-chroot and Fedora's chroot recipe both bind it).
mount --bind /run "$TARGET/run" 2>/dev/null || true
if [ -d /sys/firmware/efi/efivars ]; then
    mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
    # Read-only when nothing may reach this machine's firmware: a tool that
    # ignores --no-variables still cannot write a boot entry.
    [ "$RESTORE_NO_NVRAM" = 1 ] && mount -o remount,bind,ro "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
fi
# --remove-destination: the restored resolv.conf is usually a dangling symlink
# into ../run/systemd/resolve/, and a plain cp wrote through it and failed.
cp --remove-destination /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

# ecryptfs-utils in the target (only if the restored system uses ecryptfs)
if [ -d "$TARGET/home/.ecryptfs" ] && [ ! -x "$TARGET/usr/bin/ecryptfs-mount-private" ]; then
    log "Installing ecryptfs-utils in chroot..."
    chroot "$TARGET" /bin/bash -c '
        if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y ecryptfs-utils
        elif command -v dnf >/dev/null 2>&1; then dnf install -y ecryptfs-utils
        elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm ecryptfs-utils; fi' 2>&1 \
        || warn "could not install ecryptfs-utils - install after boot"
fi

# Universal boot-chain rebuild inside the target: initramfs (or UKI) + bootloader
# (GRUB or systemd-boot), encrypted-/boot aware. One script, every layout.
if [ -f "$SCRIPT_DIR/restore-rebuild-boot.sh" ]; then
    log "Rebuilding boot chain in chroot (universal: GRUB / systemd-boot / UKI)..."
    install -m 755 "$SCRIPT_DIR/restore-rebuild-boot.sh" "$TARGET/root/.restore-rebuild-boot.sh"
    chroot "$TARGET" /usr/bin/env RESTORE_NO_NVRAM="$RESTORE_NO_NVRAM" /root/.restore-rebuild-boot.sh || warn "boot rebuild reported errors - review the log above"
    rm -f "$TARGET/root/.restore-rebuild-boot.sh"
else
    error "restore-rebuild-boot.sh not found next to this script ($SCRIPT_DIR) - boot NOT rebuilt!"
    warn  "copy restore-rebuild-boot.sh alongside backintime-restore.sh and re-run, or rebuild boot manually."
fi

log "Cleaning up chroot mounts..."
cleanup_chroot
trap - EXIT

###############################################################################
# Step 8: Comprehensive verification
###############################################################################
echo ""
echo "============================================================"
echo "  POST-RESTORE VERIFICATION"
echo "============================================================"

ERRORS=0
WARNINGS=0

# Verify fstab and crypttab references, by field and kind (a PARTUUID is
# looked up as a PARTUUID, a LABEL as a LABEL; paths are not checked here)
log "Verifying fstab references..."
while IFS=$'\t' read -r kind val; do
    [ "$kind" = PATH ] && continue
    if cl_ref_exists "$kind" "$val"; then
        log "  OK: $kind=$val found"
    else
        error "  FAIL: $kind=$val NOT FOUND on any device!"
        ERRORS=$((ERRORS + 1))
    fi
done < <(cl_table_refs "$FSTAB" 1)

# Verify crypttab references
if [ -f "$CRYPTTAB" ] && [ "$HAS_LUKS" = true ]; then
    log "Verifying crypttab references..."
    while read -r _cname; do
        IFS=$'\t' read -r kind val < <(cl_crypttab_ref "$CRYPTTAB" "$_cname") || continue
        [ "$kind" = PATH ] && continue
        if cl_ref_exists "$kind" "$val"; then
            log "  OK: LUKS $_cname $kind=$val found"
        elif cl_crypttab_optional "$CRYPTTAB" "$_cname"; then
            # A data drive the boot does not wait for (noauto/nofail): not
            # connected to this machine is normal after a restore.
            warn "  $_cname $kind=$val not connected — optional (noauto/nofail), the boot does not need it"
            WARNINGS=$((WARNINGS + 1))
        else
            error "  FAIL: LUKS $_cname $kind=$val NOT FOUND — the boot waits for it"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1}' "$CRYPTTAB")
fi

# Verify every kernel command-line carrier names a device that exists NOW
log "Verifying kernel command-line carriers against the new disk..."
stale=$(cl_stale_ids "$TARGET")
if [ -n "$stale" ]; then
    while IFS=$'\t' read -r k f rk id; do
        error "  FAIL: $k ${f#"$TARGET"} references $rk $id which does not exist — the restored system would not boot"
        ERRORS=$((ERRORS + 1))
    done <<<"$stale"
else
    log "  OK: every carrier ($(cl_find_carriers "$TARGET" | wc -l)) references ids present on this disk"
fi
# ...and on the TARGET disk. An id that exists on another disk of this machine
# (the old disk, still installed) passes the check above and boots the wrong
# system: the restored disk unlocking and mounting the old root.
log "Verifying the boot chain references only the target disk(s):${TARGET_DISKS% }"
offt=$(cl_refs_off_target "$TARGET" "$TARGET_DISKS")
if [ -n "$offt" ]; then
    while IFS=$'\t' read -r f rk id d; do
        error "  FAIL: $f references $rk $id on $d — NOT the restore target; the restored system would boot, unlock or mount the other disk"
        ERRORS=$((ERRORS + 1))
    done <<<"$offt"
else
    log "  OK: root, /boot, ESP, /home, crypttab.initramfs and every command line resolve onto the target disk(s)"
fi
# Unified kernel images carry their command line inside a signed binary; no
# file rewrite reaches it. The generator's images were rebuilt above; one it
# does not know (a hand-built rescue image, a leftover preset) still names the
# old disk — and with that disk installed, boots it.
log "Verifying the command line embedded in every unified kernel image..."
_uki_n=0
while read -r _uki; do
    [ -n "$_uki" ] || continue
    _uki_n=$((_uki_n + 1))
    _ucl=$(cl_uki_cmdline "$_uki")
    if [ -z "$_ucl" ]; then log "  ${_uki#"$TARGET"}: no embedded command line (it takes the loader's)"; continue; fi
    _utmp=$(mktemp); printf '%s\n' "$_ucl" > "$_utmp"
    _ubad=""
    while IFS=$'\t' read -r rk id; do
        [ -n "$id" ] || continue
        if ! cl_id_exists "$rk" "$id"; then _ubad="$_ubad $rk $id (not present)"
        else
            _ud=$(cl_ref_disk "$rk" "$id")
            case " $TARGET_DISKS " in *" $_ud "*) ;; *) [ -n "$_ud" ] && _ubad="$_ubad $rk $id (on $_ud)" ;; esac
        fi
    done < <(cl_ids_in_file "$_utmp")
    rm -f "$_utmp"
    if [ -n "$_ubad" ]; then
        error "  FAIL: ${_uki#"$TARGET"} embeds a command line naming:$_ubad — rebuild it for this disk or remove it; the boot menu offers it"
        ERRORS=$((ERRORS + 1))
    else
        log "  OK: ${_uki#"$TARGET"}"
    fi
done < <(cl_ukis "$TARGET")
[ "$_uki_n" -gt 0 ] || log "  no unified kernel images"

# Verify GRUB's own files: every grub.cfg, and the early config inside every
# loader image on the ESP
while IFS=$'\t' read -r _lvl _msg; do
    case "$_lvl" in
        INFO) log "$_msg" ;;
        OK)   log "  OK: $_msg" ;;
        WARN) warn "  $_msg"; WARNINGS=$((WARNINGS + 1)) ;;
        FAIL) error "  FAIL: $_msg"; ERRORS=$((ERRORS + 1)) ;;
    esac
done < <(cl_grub_boot_findings "$TARGET" "$ID_MAP")

# Verify initramfs — both naming conventions
log "Verifying initramfs..."
# Every layout: /boot/initrd.img-* (Debian), /boot/initramfs-*.img (Fedora,
# mkinitcpio), the kernel-install Type #1 layout <boot|esp>/<machine-id>/<ver>/
# {linux,initrd} (systemd-boot on Arch/Fedora/Debian), and UKIs, which carry
# kernel and initramfs in one file. Checking the first two alone reported "no
# kernels" on every kernel-install host.
INITRD_COUNT=0; VMLINUZ_COUNT=0; UKI_COUNT=0
for f in "$TARGET"/boot/initrd.img-* "$TARGET"/boot/initramfs-*.img "$TARGET"/boot/*/*/initrd "$TARGET"/efi/*/*/initrd "$TARGET"/boot/efi/*/*/initrd; do
    [ -f "$f" ] || continue
    echo "$f" | grep -q 'fallback' && continue
    INITRD_COUNT=$((INITRD_COUNT + 1))
done
for f in "$TARGET"/boot/vmlinuz-* "$TARGET"/boot/*/*/linux "$TARGET"/efi/*/*/linux "$TARGET"/boot/efi/*/*/linux; do
    [ -f "$f" ] && VMLINUZ_COUNT=$((VMLINUZ_COUNT + 1))
done
for f in "$TARGET"/boot/EFI/Linux/*.efi "$TARGET"/efi/EFI/Linux/*.efi "$TARGET"/boot/efi/EFI/Linux/*.efi; do
    [ -f "$f" ] && UKI_COUNT=$((UKI_COUNT + 1))
done
if [ "$INITRD_COUNT" -gt 0 ] || [ "$UKI_COUNT" -gt 0 ]; then
    log "  OK: Found $INITRD_COUNT initramfs image(s), $UKI_COUNT UKI(s)"
else
    error "  FAIL: No initramfs images or UKIs found!"
    ERRORS=$((ERRORS + 1))
fi

# Verify kernels
if [ "$VMLINUZ_COUNT" -gt 0 ] || [ "$UKI_COUNT" -gt 0 ]; then
    log "  OK: Found $VMLINUZ_COUNT kernel(s), $UKI_COUNT UKI(s)"
else
    error "  FAIL: No kernels in /boot or the ESP!"
    ERRORS=$((ERRORS + 1))
fi

# Verify ecryptfs (if applicable)
if [ -d "$TARGET/home/.ecryptfs" ]; then
    log "Verifying ecryptfs..."
    for ecryptfs_dir in "$TARGET"/home/.ecryptfs/*/; do
        [ -d "$ecryptfs_dir" ] || continue
        username=$(basename "$ecryptfs_dir")
        for f in .ecryptfs/wrapped-passphrase .ecryptfs/Private.sig .Private; do
            if [ -e "$ecryptfs_dir/$f" ]; then
                log "  OK: $username/$f"
            else
                error "  FAIL: $username/$f missing!"
                ERRORS=$((ERRORS + 1))
            fi
        done
    done
fi

# Verify essential config files
# /etc/default/grub only matters on a GRUB system.
_cfgs=("$TARGET/etc/fstab")
{ [ -d "$TARGET/boot/grub" ] || [ -d "$TARGET/boot/grub2" ]; } && _cfgs+=("$TARGET/etc/default/grub")
for f in "${_cfgs[@]}"; do
    if [ -f "$f" ]; then
        log "  OK: $(basename "$f") exists"
    else
        warn "  $(basename "$f") not found"
        WARNINGS=$((WARNINGS + 1))
    fi
done

echo ""
echo "============================================================"
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "  ${GREEN}ALL CHECKS PASSED${NC} — system should boot correctly"
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "  ${YELLOW}$WARNINGS WARNING(S)${NC} — review above, but should be OK"
else
    echo -e "  ${RED}$ERRORS ERROR(S), $WARNINGS WARNING(S)${NC} — fix before rebooting!"
fi
echo "============================================================"
echo ""
echo "Post-boot checklist:"
echo "  1. Log in normally"
echo "  2. If ecryptfs: ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase"
echo "  3. Check dmesg: dmesg | grep -i error"
echo "  4. Verify timers: systemctl status borg-backup.timer backintime-backup.timer"
echo ""
log "========== BIT RESTORE SESSION END =========="

cp "$RESTORE_LOG" "$TARGET/var/log/backintime-restore-latest.log" 2>/dev/null || true
log "Full log: $RESTORE_LOG"
log "Copied to: /var/log/backintime-restore-latest.log"
# Failed checks are the exit status, as in borg-restore.sh.
if [ "$ERRORS" -gt 0 ]; then
    error "Restore finished with $ERRORS verification error(s) — the restored disk is NOT ready to boot; fix them first (see above)"
    exit 2
fi
log "Restore complete. Unmount all partitions and reboot."
