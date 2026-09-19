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
#   - /mnt/target/boot and the ESP (/mnt/target/boot/efi or /mnt/target/efi) mounted
#   - LUKS already opened if applicable
#   - Borg backup drive mounted (unlock LUKS first if needed)
#   - Live USB must have: borgbackup, cryptsetup
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

# The repo is encryption=none (the LUKS drive encrypts it). On a fresh live
# USB borg's security dir is empty and its first access asks "previously
# unknown unencrypted repository — continue? [yN]" on stderr — which every
# call below discards: a silent hang, then "Could not list archives".
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
# borg's security and cache directories go to a temporary directory: on a live
# USB /root is tmpfs anyway, on an installed system they would be written to
# the running system's own disk.
[ -n "${BORG_BASE_DIR:-}" ] || { BORG_BASE_DIR=$(mktemp -d /tmp/borg-restore-base.XXXXXX); export BORG_BASE_DIR; }

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
for _l in "$SCRIPT_DIR/lib-restore.sh" /usr/local/sbin/lib-restore.sh; do
    # shellcheck disable=SC1090
    [ -r "$_l" ] && { . "$_l"; break; }
done
declare -f rx_detect_ids >/dev/null || fatal "lib-restore.sh not found next to this script or in /usr/local/sbin — it holds the restore pipeline"
DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
FILES_ONLY=false   # extract and stop (the launcher's combined mode overlays Back In Time next)
FIXUP_ONLY=false   # skip extraction: fstab/crypttab/command lines + boot rebuild on what is at TARGET
POS=()
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --files-only) FILES_ONLY=true ;;
        --fixup-only) FIXUP_ONLY=true ;;
        *) POS+=("$a") ;;
    esac
done
TARGET="${POS[0]:-}"
BORG_REPO="${POS[1]:-}"
ARCHIVE="${POS[2]:-}"

if [ -z "$TARGET" ] || [ -z "$BORG_REPO" ]; then
    cat <<'USAGE'
Usage: borg-restore.sh [--dry-run] [--files-only | --fixup-only] <target-mountpoint> <borg-repo-path> [archive-name]

  --files-only   extract the archive and stop (no fstab/crypttab/boot work)
  --fixup-only   no extraction: rewrite ids and rebuild boot for what is at the target
  RESTORE_HOST=<name> picks the host when the repo holds several hosts' archives

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
  7. Mount EFI:    mount /dev/sdX1 /mnt/target/boot/efi   (or /mnt/target/efi — where the source had it)
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
rx_check_target

# If no archive specified, use the latest — of THIS host's. One repo can hold
# several machines' archives (name prefix <host>-<date>); "latest" used to be
# whichever machine backed up last.
if [ "$FIXUP_ONLY" = true ]; then
    log "fixup-only: no extraction; working on what is at $TARGET"
elif [ -z "$ARCHIVE" ]; then
    mapfile -t _HOSTS < <(borg list --short "$BORG_REPO" 2>/dev/null | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$//' | sort -u)
    [ ${#_HOSTS[@]} -gt 0 ] || fatal "No archives found in $BORG_REPO"
    HOST_PREFIX="${RESTORE_HOST:-}"
    if [ -z "$HOST_PREFIX" ] && [ ${#_HOSTS[@]} -eq 1 ]; then HOST_PREFIX="${_HOSTS[0]}"; fi
    if [ -z "$HOST_PREFIX" ]; then
        if [ -t 0 ]; then
            echo "The repo holds archives from ${#_HOSTS[@]} hosts:"
            select HOST_PREFIX in "${_HOSTS[@]}"; do [ -n "$HOST_PREFIX" ] && break; done
        else
            fatal "archives from several hosts (${_HOSTS[*]}) — set RESTORE_HOST=<name> or name the archive"
        fi
    fi
    ARCHIVE=$(borg list --last 1 --short --glob-archives "$HOST_PREFIX-*" "$BORG_REPO" 2>/dev/null) \
        || fatal "Could not list archives in $BORG_REPO"
    [ -n "$ARCHIVE" ] || fatal "No archives for host '$HOST_PREFIX' in $BORG_REPO"
    log "Using latest archive of host '$HOST_PREFIX': $ARCHIVE"
fi

# Verify archive exists, and have the operator confirm what is about to be
# written where — once, before a full extraction.
if [ "$FIXUP_ONLY" != true ]; then
    borg info "$BORG_REPO"::"$ARCHIVE" >/dev/null 2>&1 \
        || fatal "Archive '$ARCHIVE' not found in repo"
    if (( ! DRY )) && [ -t 0 ]; then
        _when=$(borg list --format '{time}{NL}' --glob-archives "$ARCHIVE" "$BORG_REPO" 2>/dev/null | head -1)
        echo ""
        echo "  Archive:  $ARCHIVE  (${_when:-time unknown})"
        echo "  Target:   $TARGET  ($(findmnt -no SOURCE,FSTYPE --target "$TARGET" 2>/dev/null))"
        echo ""
        read -rp "Extract this archive onto $TARGET? [y/N] " _ans
        [[ "$_ans" =~ ^[yY] ]] || fatal "cancelled"
    fi
fi

###############################################################################
# Log system state for debugging
###############################################################################
rx_log_state
if [ "$FIXUP_ONLY" != true ]; then
    log "--- Borg archive info ---"
    borg info "$BORG_REPO"::"$ARCHIVE" 2>&1 || true
fi

###############################################################################
# Step 1: Restore the backup
###############################################################################
if [ "$FIXUP_ONLY" = true ]; then
    log "Skipping extraction (--fixup-only)."
else
    log "Restoring archive '$ARCHIVE' to $TARGET ..."
    cd "$TARGET"
    extract_rc=0
    if (( DRY )); then
        log "[DRY] listing what would be extracted (no files written):"
        borg extract --dry-run --list "$BORG_REPO"::"$ARCHIVE" | tail -40
    else
        # --numeric-ids: owners by uid/gid, not by NAME through the live USB's
        # passwd — restoring Fedora from a Manjaro stick remapped every system
        # account the two distros number differently. rc 1 is a warning
        # (xattrs/ACLs the target fs cannot take); under set -e it used to
        # abort here, after a full extraction and before any fixup.
        borg extract --verbose --list --numeric-ids "$BORG_REPO"::"$ARCHIVE" || extract_rc=$?
        [ "$extract_rc" -le 1 ] || fatal "borg extract failed (rc=$extract_rc) — see the output above"
        [ "$extract_rc" -eq 1 ] && warn "borg extract finished with warnings (rc=1) — review the list above"
        # Directories the archive does not hold but its files need (the parents
        # of an include inside an excluded tree, in archives made before 4.0.2)
        # are created by borg extract as root, mode 700. A home's .local and
        # .local/share came back that way (found by inspecting a restored
        # drive), where nothing the user runs can write its state. Give
        # each such directory the owner, group and mode of its nearest archived
        # ancestor; a directory the archive does hold keeps what it recorded.
        log "Checking directories the extract created without an archive entry ..."
        borg list --format '{path}{NL}' "$BORG_REPO"::"$ARCHIVE" 2>/dev/null | python3 -c '
import os, stat, sys
target = sys.argv[1]
paths = set(l.rstrip("\n") for l in sys.stdin if l.strip())
made = set()
for p in paths:
    d = os.path.dirname(p)
    while d and d not in paths and d not in made:
        made.add(d); d = os.path.dirname(d)
n = 0
for d in sorted(made, key=lambda x: x.count("/")):
    t = os.path.join(target, d)
    try:
        st = os.lstat(t)
    except OSError:
        continue
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0:
        continue
    a = os.path.dirname(d)
    while a and a not in paths:
        a = os.path.dirname(a)
    if not a:
        continue
    ast = os.stat(os.path.join(target, a))
    if ast.st_uid == 0:
        continue
    os.chown(t, ast.st_uid, ast.st_gid)
    os.chmod(t, stat.S_IMODE(ast.st_mode))
    n += 1
    print("  /%s: root 0%o -> %d:%d 0%o (from /%s)" % (d, stat.S_IMODE(st.st_mode), ast.st_uid, ast.st_gid, stat.S_IMODE(ast.st_mode), a))
print("  %d director%s repaired" % (n, "y" if n == 1 else "ies"))
' "$TARGET" || warn "could not check the directories the extract created — look for root-owned directories in the restored homes"
    fi
    log "Extraction ${DRY:+(dry-run) }complete."
    if [ "$FILES_ONLY" = true ]; then
        log "Files-only mode — stopping before fstab/crypttab/command-line rewrite and boot rebuild."
        log "Full log: $RESTORE_LOG"
        exit 0
    fi
fi

###############################################################################
# Steps 2–7: the shared pipeline (lib-restore.sh) — ecryptfs check, the new
# disk's ids, fstab / crypttab / command lines, swapfiles + SELinux, the boot
# rebuild in a chroot, verification. Failed checks are the exit status.
###############################################################################
rx_check_ecryptfs
rx_detect_ids
if (( DRY )); then
    log "[DRY] would now update $TARGET/etc/fstab + crypttab to the new UUIDs above,"
    log "[DRY] then chroot in and rebuild the boot chain via restore-rebuild-boot.sh"
    log "[DRY] (universal: initramfs/UKI + GRUB/systemd-boot)."
    log "========== DRY RUN complete - nothing was changed =========="
    exit 0
fi
rx_fix_fstab
rx_fix_crypttab
rx_rewrite_cmdlines
rx_swapfiles_selinux
rx_chroot_rebuild
rx_verify
rx_finish borg-restore-latest.log
