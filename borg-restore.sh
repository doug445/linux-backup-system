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
# Borg Restore + UUID Fixup + Initramfs Rebuild Script
# Multi-distro: Debian/Ubuntu/Mint, Fedora/Asahi, Arch/Manjaro
# Multi-arch: x86_64, aarch64
# Multi-fs: ext4, btrfs (subvols), LVM, LUKS, ecryptfs
#
# Usage: boot from live USB, mount partitions, then run:
#   sudo ./borg-restore.sh /mnt/target /mnt/backup/borg-backup [archive-name]
#
# Prerequisites:
#   - Target partitions already created, formatted, and mounted at /mnt/target
#   - /mnt/target/boot and /mnt/target/boot/efi mounted
#   - LUKS already opened if applicable
#   - Borg backup drive mounted (unlock LUKS first if needed)
#   - Live USB must have: borgbackup, cryptsetup
set -euo pipefail

# Full logging — capture everything for debugging
RESTORE_LOG="/tmp/borg-restore-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$RESTORE_LOG") 2>&1
echo "Full restore log: $RESTORE_LOG"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[RESTORE]${NC} $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }
fatal() { error "$@"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
POS=()
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        *) POS+=("$a") ;;
    esac
done
TARGET="${POS[0]:-}"
BORG_REPO="${POS[1]:-}"
ARCHIVE="${POS[2]:-}"

if [ -z "$TARGET" ] || [ -z "$BORG_REPO" ]; then
    cat <<'USAGE'
Usage: borg-restore.sh <target-mountpoint> <borg-repo-path> [archive-name]

Examples:
  # Restore latest archive with full UUID fixup:
  borg-restore.sh /mnt/target /mnt/backup/borg-backup

  # Restore specific archive:
  borg-restore.sh /mnt/target /mnt/backup/borg-backup mbp2012-2026-04-04_00-30-00

Steps before running this script:
  1. Boot from a live USB
  2. Install deps: borgbackup (via your distro's package manager)
  3. Open LUKS (if applicable):
       cryptsetup open /dev/sdX3 <crypt_name>
  4. Activate LVM (if applicable):
       vgchange -ay
  5. Mount root:
       ext4/LVM:  mount /dev/mapper/<vg>-root /mnt/target
       btrfs:     mount -o subvol=root /dev/sdXN /mnt/target
                  mkdir -p /mnt/target/home
                  mount -o subvol=home /dev/sdXN /mnt/target/home
  6. Mount boot:   mount /dev/sdX2 /mnt/target/boot
  7. Mount EFI:    mount /dev/sdX1 /mnt/target/boot/efi
  8. Open backup:  cryptsetup open /dev/sdY1 backup-crypt
  9. Mount backup: mount /dev/mapper/backup-crypt /mnt/backup
  10. Run restore: ./borg-restore.sh /mnt/target /mnt/backup/borg-backup

After restore:
  - Reboot, log in
  - If ecryptfs: ecryptfs-unwrap-passphrase /home/.ecryptfs/USER/.ecryptfs/wrapped-passphrase
USAGE
    exit 1
fi

[ -d "$TARGET" ] || fatal "Target $TARGET does not exist"
[ -d "$BORG_REPO" ] || fatal "Borg repo $BORG_REPO does not exist"
mountpoint -q "$TARGET" || fatal "$TARGET is not a mountpoint"

# If no archive specified, use the latest
if [ -z "$ARCHIVE" ]; then
    ARCHIVE=$(borg list --last 1 --short "$BORG_REPO" 2>/dev/null) \
        || fatal "Could not list archives in $BORG_REPO"
    [ -n "$ARCHIVE" ] || fatal "No archives found in $BORG_REPO"
    log "Using latest archive: $ARCHIVE"
fi

# Verify archive exists
borg info "$BORG_REPO"::"$ARCHIVE" >/dev/null 2>&1 \
    || fatal "Archive '$ARCHIVE' not found in repo"

###############################################################################
# Log system state for debugging
###############################################################################
log "========== RESTORE SESSION START =========="
log "Date: $(date)"
log "Architecture: $(uname -m)"
log "Live system kernel: $(uname -r)"
log "--- Block devices ---"
lsblk -f 2>&1 || true
log "--- All UUIDs ---"
blkid 2>&1 || true
log "--- Current mounts ---"
mount 2>&1 || true
log "--- Borg archive info ---"
borg info "$BORG_REPO"::"$ARCHIVE" 2>&1 || true

###############################################################################
# Step 1: Restore the backup
###############################################################################
log "Restoring archive '$ARCHIVE' to $TARGET ..."
cd "$TARGET"
if (( DRY )); then
    log "[DRY] listing what would be extracted (no files written):"
    borg extract --dry-run --list "$BORG_REPO"::"$ARCHIVE" | tail -40
else
    borg extract --verbose --list "$BORG_REPO"::"$ARCHIVE"
fi
log "Extraction ${DRY:+(dry-run) }complete."

###############################################################################
# Step 2: Verify ecryptfs data integrity (only if ecryptfs exists)
###############################################################################
if [ -d "$TARGET/home/.ecryptfs" ]; then
    log "Checking ecryptfs data..."
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
                ((ECRYPTFS_ERRORS++))
            fi
        done

        private_count=$(find "$ecryptfs_dir/.Private" -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [ "$private_count" -gt 0 ]; then
            log "    OK: .Private/ has $private_count top-level encrypted files"
        else
            error "    EMPTY: .Private/ directory has no files!"
            ((ECRYPTFS_ERRORS++))
        fi

        wp_size=$(stat -c%s "$ecryptfs_dir/.ecryptfs/wrapped-passphrase" 2>/dev/null || echo 0)
        if [ "$wp_size" -ge 50 ] && [ "$wp_size" -le 70 ]; then
            log "    OK: wrapped-passphrase size=$wp_size bytes (expected ~58)"
        else
            error "    BAD: wrapped-passphrase size=$wp_size bytes (expected ~58)"
            ((ECRYPTFS_ERRORS++))
        fi

        sig_count=$(wc -l < "$ecryptfs_dir/.ecryptfs/Private.sig" 2>/dev/null || echo 0)
        if [ "$sig_count" -eq 2 ]; then
            log "    OK: Private.sig has 2 signature lines"
        else
            error "    BAD: Private.sig has $sig_count lines (expected 2)"
            ((ECRYPTFS_ERRORS++))
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
        echo "  Press Enter to continue anyway, or Ctrl+C to abort."
        read -r
    fi

    if [ ! -f "$TARGET/usr/bin/ecryptfs-mount-private" ]; then
        warn "ecryptfs-utils not found in target — install after boot"
    fi
else
    log "No ecryptfs detected — skipping ecryptfs verification"
fi

###############################################################################
# Step 3: Detect new UUIDs from currently mounted devices
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

# Detect /boot/efi
EFI_UUID=""
if mountpoint -q "$TARGET/boot/efi" 2>/dev/null; then
    EFI_DEV=$(findmnt -n -o SOURCE "$TARGET/boot/efi")
    EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV" 2>/dev/null) || true
    log "EFI device:  $EFI_DEV → UUID=$EFI_UUID"
fi

# Detect swap (LVM swap, partition swap, or zram)
SWAP_UUID=""
for dev in /dev/mapper/vg*-swap* /dev/mapper/*-swap* /dev/sd*[0-9] /dev/nvme*p[0-9]; do
    [ -b "$dev" ] || continue
    dev_type=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
    if [ "$dev_type" = "swap" ]; then
        SWAP_UUID=$(blkid -s UUID -o value "$dev" 2>/dev/null) || true
        log "Swap device: $dev → UUID=$SWAP_UUID"
        break
    fi
done

# Detect LUKS UUIDs (for crypttab)
HAS_LUKS=false
log "Detecting LUKS devices..."
declare -A LUKS_MAP

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
            if command -v cryptsetup &>/dev/null && cryptsetup isLuks "$underlying" 2>/dev/null; then
                luks_uuid=$(cryptsetup luksUUID "$underlying" 2>/dev/null) || true
                if [ -n "$luks_uuid" ]; then
                    LUKS_MAP["$mapper_name"]="$luks_uuid"
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
echo "  /boot/efi:        ${EFI_UUID:-NOT DETECTED}"
echo "  Swap:             ${SWAP_UUID:-NOT DETECTED (zram or none)}"
echo "  LUKS in use:      $HAS_LUKS"
for name in "${!LUKS_MAP[@]}"; do
    echo "  LUKS ($name): ${LUKS_MAP[$name]}"
done
echo "============================================================"
echo ""

if (( DRY )); then
    log "[DRY] would now update $TARGET/etc/fstab + crypttab to the new UUIDs above,"
    log "[DRY] then chroot in and rebuild the boot chain via restore-rebuild-boot.sh"
    log "[DRY] (universal: initramfs/UKI + GRUB/systemd-boot)."
    log "========== DRY RUN complete - nothing was changed =========="
    exit 0
fi

###############################################################################
# Step 4: Read OLD UUIDs from restored files and update fstab
###############################################################################
log "Reading old UUIDs from restored fstab..."

FSTAB="$TARGET/etc/fstab"
CRYPTTAB="$TARGET/etc/crypttab"

[ -f "$FSTAB" ] || fatal "Restored fstab not found at $FSTAB"

log "--- OLD fstab ---"
cat "$FSTAB"
echo ""

cp "$FSTAB" "$FSTAB.bak.$(date +%s)"

# Extract old UUIDs from fstab
OLD_ROOT_UUID=$(grep -oP 'UUID=\K[0-9a-fA-F-]+(?=\s+/\s)' "$FSTAB" || true)
OLD_HOME_UUID=$(grep -oP 'UUID=\K[0-9a-fA-F-]+(?=\s+/home\s)' "$FSTAB" || true)
OLD_BOOT_UUID=$(grep -oP 'UUID=\K[0-9a-fA-F-]+(?=\s+/boot\s)' "$FSTAB" || true)
OLD_EFI_UUID=$(grep -oP 'UUID=\K[0-9a-fA-F-]+(?=\s+/boot/efi\s)' "$FSTAB" || true)
OLD_SWAP_UUID=$(grep -oP 'UUID=\K[0-9a-fA-F-]+(?=\s+\S*swap)' "$FSTAB" || true)

log "Old UUIDs: root=${OLD_ROOT_UUID:-?} home=${OLD_HOME_UUID:-?} boot=${OLD_BOOT_UUID:-?} efi=${OLD_EFI_UUID:-?} swap=${OLD_SWAP_UUID:-?}"

log "Updating fstab..."

# Update root UUID
if [ -n "$ROOT_UUID" ] && [ -n "$OLD_ROOT_UUID" ] && [ "$ROOT_UUID" != "$OLD_ROOT_UUID" ]; then
    # For btrfs, root and home may share the same UUID — update all occurrences
    sed -i "s|UUID=$OLD_ROOT_UUID|UUID=$ROOT_UUID|g" "$FSTAB"
    log "  Updated root UUID: $OLD_ROOT_UUID → $ROOT_UUID"
elif [ -n "$ROOT_UUID" ] && [ -z "$OLD_ROOT_UUID" ]; then
    log "  Root uses /dev/mapper path (no UUID in fstab) — no UUID update needed"
fi

# Update /home UUID (if it's a separate partition with different UUID)
if [ -n "$HOME_UUID" ] && [ -n "$OLD_HOME_UUID" ] && [ "$HOME_UUID" != "$OLD_HOME_UUID" ] && [ "$HOME_UUID" != "$ROOT_UUID" ]; then
    sed -i "s|UUID=$OLD_HOME_UUID|UUID=$HOME_UUID|g" "$FSTAB"
    log "  Updated /home UUID: $OLD_HOME_UUID → $HOME_UUID"
fi

# Update /boot UUID
if [ -n "$BOOT_UUID" ] && [ -n "$OLD_BOOT_UUID" ] && [ "$BOOT_UUID" != "$OLD_BOOT_UUID" ]; then
    sed -i "s|UUID=$OLD_BOOT_UUID|UUID=$BOOT_UUID|g" "$FSTAB"
    log "  Updated /boot UUID: $OLD_BOOT_UUID → $BOOT_UUID"
fi

# Update /boot/efi UUID
if [ -n "$EFI_UUID" ] && [ -n "$OLD_EFI_UUID" ] && [ "$EFI_UUID" != "$OLD_EFI_UUID" ]; then
    sed -i "s|UUID=$OLD_EFI_UUID|UUID=$EFI_UUID|g" "$FSTAB"
    log "  Updated /boot/efi UUID: $OLD_EFI_UUID → $EFI_UUID"
fi

# Update swap UUID
if [ -n "$SWAP_UUID" ] && [ -n "$OLD_SWAP_UUID" ] && [ "$SWAP_UUID" != "$OLD_SWAP_UUID" ]; then
    sed -i "s|UUID=$OLD_SWAP_UUID|UUID=$SWAP_UUID|g" "$FSTAB"
    log "  Updated swap UUID: $OLD_SWAP_UUID → $SWAP_UUID"
fi

# Comment out backup partition entry (if uncommented)
if grep -v '^\s*#' "$FSTAB" | grep -q 'backup-crypt'; then
    sed -i '/backup-crypt/s/^/#RESTORED# /' "$FSTAB"
    log "  Commented out backup partition entry"
fi

log "--- NEW fstab ---"
cat "$FSTAB"

###############################################################################
# Step 5: Update crypttab with new LUKS UUIDs
###############################################################################
if [ -f "$CRYPTTAB" ] && [ "$HAS_LUKS" = true ]; then
    log "Updating crypttab..."
    log "--- OLD crypttab ---"
    cat "$CRYPTTAB"
    cp "$CRYPTTAB" "$CRYPTTAB.bak.$(date +%s)"

    LUKS_ID_MAP="$(mktemp /tmp/restore-luksmap.XXXXXX)"
    for mapper_name in "${!LUKS_MAP[@]}"; do
        new_luks_uuid="${LUKS_MAP[$mapper_name]}"
        old_luks_uuid=$(grep -oP "^${mapper_name}\s+UUID=\K[0-9a-fA-F-]+" "$CRYPTTAB" || true)
        if [ -n "$old_luks_uuid" ] && [ "$old_luks_uuid" != "$new_luks_uuid" ]; then
            echo "$old_luks_uuid $new_luks_uuid" >> "$LUKS_ID_MAP"   # for the command-line rewrite below
            sed -i "s|UUID=$old_luks_uuid|UUID=$new_luks_uuid|g" "$CRYPTTAB"
            log "  Updated $mapper_name LUKS UUID: $old_luks_uuid → $new_luks_uuid"
        fi
    done

    # Comment out backup-crypt entry
    if grep -q '^backup-crypt' "$CRYPTTAB"; then
        sed -i '/^backup-crypt/s/^/#RESTORED# /' "$CRYPTTAB"
        log "  Commented out backup-crypt entry"
    fi

    log "--- NEW crypttab ---"
    cat "$CRYPTTAB"
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
for _c in "$SCRIPT_DIR/lib-cmdline.sh" /usr/local/sbin/lib-cmdline.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
declare -f cl_rewrite_ids >/dev/null || fatal "lib-cmdline.sh not found next to this script or in /usr/local/sbin — cannot rewrite kernel command lines; the restored system would not boot"
ID_MAP="$(mktemp /tmp/restore-idmap.XXXXXX)"
{
    [ -n "$OLD_ROOT_UUID" ] && [ -n "$ROOT_UUID" ] && echo "$OLD_ROOT_UUID $ROOT_UUID"
    [ -n "$OLD_HOME_UUID" ] && [ -n "$HOME_UUID" ] && echo "$OLD_HOME_UUID $HOME_UUID"
    [ -n "$OLD_BOOT_UUID" ] && [ -n "$BOOT_UUID" ] && echo "$OLD_BOOT_UUID $BOOT_UUID"
    [ -n "$OLD_EFI_UUID" ]  && [ -n "$EFI_UUID" ]  && echo "$OLD_EFI_UUID $EFI_UUID"
    [ -n "$OLD_SWAP_UUID" ] && [ -n "$SWAP_UUID" ] && echo "$OLD_SWAP_UUID $SWAP_UUID"
    [ -n "${LUKS_ID_MAP:-}" ] && [ -s "$LUKS_ID_MAP" ] && cat "$LUKS_ID_MAP"
} > "$ID_MAP"
log "Rewriting kernel command-line carriers ($(grep -c . "$ID_MAP") id mappings)..."
n_carriers=$(cl_find_carriers "$TARGET" | wc -l)
log "  carriers found under $TARGET: $n_carriers"
cl_find_carriers "$TARGET" | while IFS=$'\t' read -r k f; do log "    $k: ${f#"$TARGET"}"; done
while IFS=$'\t' read -r k f; do log "  rewrote $k: ${f#"$TARGET"}"; done < <(cl_rewrite_ids "$TARGET" "$ID_MAP")
left=$(cl_carrier_mismatches "$TARGET")
if [ -n "$left" ]; then
    warn "command-line ids not declared by the restored fstab/crypttab (check before rebooting):"
    while IFS=$'\t' read -r k f rk id; do warn "    $k ${f#"$TARGET"}: $rk $id"; done <<<"$left"
fi

###############################################################################
# Step 6: Chroot and update initramfs + GRUB
###############################################################################
log "Preparing chroot environment..."

mount --bind /dev  "$TARGET/dev"
mount --bind /dev/pts "$TARGET/dev/pts"
mount -t proc proc "$TARGET/proc"
mount -t sysfs sys "$TARGET/sys"
[ -d /sys/firmware/efi/efivars ] && mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
cp /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

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
    chroot "$TARGET" /root/.restore-rebuild-boot.sh || warn "boot rebuild reported errors - review the log above"
    rm -f "$TARGET/root/.restore-rebuild-boot.sh"
else
    error "restore-rebuild-boot.sh not found next to this script ($SCRIPT_DIR) - boot NOT rebuilt!"
    warn  "copy restore-rebuild-boot.sh alongside borg-restore.sh and re-run, or rebuild boot manually."
fi

log "Cleaning up chroot mounts..."
umount "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
umount "$TARGET/dev/pts" 2>/dev/null || true
umount "$TARGET/dev" 2>/dev/null || true
umount "$TARGET/proc" 2>/dev/null || true
umount "$TARGET/sys" 2>/dev/null || true

###############################################################################
# Step 7: Comprehensive verification
###############################################################################
echo ""
echo "============================================================"
echo "  POST-RESTORE VERIFICATION"
echo "============================================================"

ERRORS=0
WARNINGS=0

# Verify fstab UUIDs
log "Verifying fstab UUIDs..."
while IFS= read -r line; do
    uuid=$(echo "$line" | grep -oP 'UUID=\K[0-9a-fA-F-]+' || true)
    if [ -n "$uuid" ]; then
        if blkid -U "$uuid" >/dev/null 2>&1; then
            log "  OK: UUID=$uuid found"
        else
            error "  FAIL: UUID=$uuid NOT FOUND on any device!"
            ((ERRORS++))
        fi
    fi
done < <(grep -v '^\s*#' "$FSTAB" | grep -v '^\s*$')

# Verify crypttab UUIDs
if [ -f "$CRYPTTAB" ] && [ "$HAS_LUKS" = true ]; then
    log "Verifying crypttab UUIDs..."
    while IFS= read -r line; do
        uuid=$(echo "$line" | grep -oP 'UUID=\K[0-9a-fA-F-]+' || true)
        if [ -n "$uuid" ]; then
            if blkid -U "$uuid" >/dev/null 2>&1; then
                log "  OK: LUKS UUID=$uuid found"
            else
                error "  FAIL: LUKS UUID=$uuid NOT FOUND!"
                ((ERRORS++))
            fi
        fi
    done < <(grep -v '^\s*#' "$CRYPTTAB" | grep -v '^\s*$')
fi

# Verify every kernel command-line carrier names a device that exists NOW
log "Verifying kernel command-line carriers against the new disk..."
stale=$(cl_stale_ids "$TARGET")
if [ -n "$stale" ]; then
    while IFS=$'\t' read -r k f rk id; do
        error "  FAIL: $k ${f#"$TARGET"} references $rk $id which does not exist — the restored system would not boot"
        ((ERRORS++))
    done <<<"$stale"
else
    log "  OK: every carrier ($(cl_find_carriers "$TARGET" | wc -l)) references ids present on this disk"
fi

# Verify GRUB config UUIDs
for grub_cfg in "$TARGET/boot/grub/grub.cfg" "$TARGET/boot/grub2/grub.cfg"; do
    if [ -f "$grub_cfg" ]; then
        log "Verifying GRUB config ($grub_cfg)..."
        for uuid in $(grep -oP '(?:root=UUID=|resume=UUID=|search.*--fs-uuid.*?)\K[0-9a-fA-F-]+' "$grub_cfg" 2>/dev/null | sort -u); do
            if blkid -U "$uuid" >/dev/null 2>&1; then
                log "  OK: GRUB UUID=$uuid found"
            else
                error "  FAIL: GRUB UUID=$uuid NOT FOUND!"
                ((ERRORS++))
            fi
        done
        break
    fi
done

# Verify initramfs — both naming conventions
log "Verifying initramfs..."
INITRD_COUNT=0
for f in "$TARGET"/boot/initrd.img-* "$TARGET"/boot/initramfs-*.img; do
    [ -f "$f" ] || continue
    echo "$f" | grep -q 'fallback' && continue
    ((INITRD_COUNT++))
done
if [ "$INITRD_COUNT" -gt 0 ]; then
    log "  OK: Found $INITRD_COUNT initramfs image(s)"
else
    error "  FAIL: No initramfs images found!"
    ((ERRORS++))
fi

# Verify kernels
VMLINUZ_COUNT=$(ls "$TARGET"/boot/vmlinuz-* 2>/dev/null | wc -l)
if [ "$VMLINUZ_COUNT" -gt 0 ]; then
    log "  OK: Found $VMLINUZ_COUNT kernel(s)"
else
    error "  FAIL: No kernels in /boot!"
    ((ERRORS++))
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
                ((ERRORS++))
            fi
        done
    done
fi

# Verify essential config files
for f in "$TARGET/etc/default/grub" "$TARGET/etc/fstab"; do
    if [ -f "$f" ]; then
        log "  OK: $(basename "$f") exists"
    else
        warn "  $(basename "$f") not found"
        ((WARNINGS++))
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
log "========== RESTORE SESSION END =========="

cp "$RESTORE_LOG" "$TARGET/var/log/borg-restore-latest.log" 2>/dev/null || true
log "Full log: $RESTORE_LOG"
log "Copied to: /var/log/borg-restore-latest.log"
log "Restore complete. Unmount all partitions and reboot."
