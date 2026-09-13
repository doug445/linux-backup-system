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
# Borg Backup Script — universal across distros and boot layouts.
#
# Backs up the running system to a borg repo on the backup drive, plus (when the
# root filesystem is btrfs) sends read-only btrfs snapshot replicas of every
# btrfs source. Nothing is hardcoded to one host: the backup drive, its UUID
# guard and every source path are taken from /etc/backup-system.conf and from
# the live mount table via backup-common.sh, so UKI/GRUB/systemd-boot, an ESP at
# /efi or /boot/efi, and a separate or in-root /boot all work unchanged.
#
# Usage:
#   sudo borg-backup.sh              run the backup
#   sudo borg-backup.sh --dry-run    detect + log every action, change nothing
#                                    (borg runs with --dry-run; no snapshot,
#                                     send, prune, compact or delete happens)
set -uo pipefail

# --- shared library + per-host config ---------------------------------------
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_self_dir/backup-common.sh" /usr/local/sbin/backup-common.sh /usr/local/lib/backup-common.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
if ! declare -f bx_load_config >/dev/null; then
    echo "FATAL: backup-common.sh not found (looked next to this script and in /usr/local/sbin)" >&2
    exit 3
fi
bx_load_config

DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        -h|--help) sed -n '27,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

ARCHIVE_NAME="$(hostname)-$(date +%Y-%m-%d_%H-%M-%S)"
LOG="/var/log/borg-backup.log"
SNAP_DIR="$BACKUP_MOUNT/snapshots"
LOCAL_SNAP_DIR="/.backup-snapshots"
STAMP="$(date +%Y%m%d_%H%M%S)"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Re-exec under systemd-inhibit so screen-lock / idle / lid-close cannot put the
# machine to sleep and power-gate the USB controller mid-backup. On 2026-06-16
# the screen blanked during borg check and the whole xHCI bus was deregistered,
# killing the verify with an I/O error. --mode=block holds the inhibitor lock
# (respected by systemd-logind and KDE PowerDevil) for the script's lifetime.
# A dry run touches nothing, so it does not need the inhibitor.
if (( ! DRY )) && [ -z "${BORG_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1; then
    export BORG_INHIBITED=1
    exec systemd-inhibit \
        --what=sleep:idle:handle-lid-switch:handle-suspend-key \
        --who="borg-backup.sh" \
        --why="USB backup drive must stay powered during backup" \
        --mode=block \
        "$0" "$@"
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]${DRY:+ [DRY]} $*" | tee -a "$LOG"; }

# Dependencies first — identify anything missing and install it (a dry run only
# reports). btrfs-progs is required only when the root filesystem is btrfs.
export BX_DEP_DRYRUN="$DRY"
_deps=(borg cryptsetup findmnt lsblk)
bx_is_btrfs && _deps+=(btrfs)
bx_ensure_deps "${_deps[@]}" 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ] && (( ! DRY )); then
    log "FATAL: required dependencies missing and could not be installed — aborting."
    exit 4
fi

# Prevent concurrent runs. The orphan-cleanup block below will delete an
# in-flight receive's destination subvolume (ro=false), killing the other
# instance's btrfs receive and SIGPIPE'ing its send. flock makes the
# systemd timer skip cleanly when a manual run is already in progress.
LOCKFILE="/var/lock/borg-backup.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "Another borg-backup.sh is already running (lock $LOCKFILE held); exiting."
    exit 0
fi

log "========== BACKUP SESSION START${DRY:+ (DRY RUN — no changes)} =========="

# Rotate log if over 10MB (not in dry mode)
if (( ! DRY )) && [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv "$LOG" "${LOG}.1"
    log "Rotated previous log (>10MB)"
fi

# Detection dump — the first thing to read when troubleshooting on a new box.
mapfile -t SOURCES < <(bx_backup_sources)
log "suite=${BX_VERSION:-?} host=$(hostname) arch=$(uname -m) root_fs=$(bx_root_fstype) snapshot_engine=$(bx_snapshot_engine)"
log "config=$BX_CONFIG mount=$BACKUP_MOUNT repo=$BORG_REPO schedule=$SCHEDULE_MODE"
log "esp=$(bx_esp_mount || echo none) boot_is_mount=$(bx_boot_is_mount && echo yes || echo no)"
log "retention KEEP=$KEEP MIN_KEEP=$MIN_KEEP MIN_FREE_PCT=$MIN_FREE_PCT MIN_FREE_GIB=$MIN_FREE_GIB"
log "backup sources: ${SOURCES[*]}"

# Backup drive mounted, and the RIGHT drive (fs-UUID guard from config).
if ! guard_msg=$(bx_check_backup_drive); then
    log "ERROR: $guard_msg — aborting."
    exit 1
fi
log "free space now: $(bx_free_gib)G / $(bx_free_pct)% on $BACKUP_MOUNT"
# Capacity: the drive must hold one full copy of the sources plus spare room.
if cap_msg=$(bx_check_backup_capacity); then log "$cap_msg"; else
    log "ERROR: $cap_msg — aborting."
    exit 1
fi


# Initialize repo if it doesn't exist
if [ ! -d "$BORG_REPO/data" ]; then
    if (( DRY )); then
        log "would initialize new borg repo at $BORG_REPO (encryption=none)"
    else
        log "Initializing new Borg repo at $BORG_REPO (encryption=none, LUKS handles it)..."
        borg init --encryption=none "$BORG_REPO" 2>&1 | tee -a "$LOG"
    fi
fi

## --- btrfs send/receive replicas (only when root is btrfs) -------------------
# Emits "label:mountpoint" for each btrfs source; "/" -> root, "/home" -> home,
# "/srv/data" -> srv_data. Labels drive the on-disk replica naming and pruning.
btrfs_sources() {
    local m
    for m in "${SOURCES[@]}"; do
        [ "$(findmnt -no FSTYPE "$m" 2>/dev/null)" = btrfs ] || continue
        if [ "$m" = / ]; then echo "root:/"; else echo "$(echo "${m#/}" | tr / _):$m"; fi
    done
}

btrfs_ok=true
if bx_is_btrfs; then
    mapfile -t BTRFS_SRC < <(btrfs_sources)
    mapfile -t LABELS    < <(printf '%s\n' "${BTRFS_SRC[@]}" | cut -d: -f1)
    log "btrfs replicas for: ${BTRFS_SRC[*]}"
    (( DRY )) || mkdir -p "$SNAP_DIR" "$LOCAL_SNAP_DIR"

    # NOTE: btrfs mirror pruning deliberately does NOT happen at the START of a
    # run, and is NOT time-based. This drive is plugged in ad-hoc — months can
    # pass between runs — so a time sweep up front would delete every existing
    # mirror before the replacement was written. Pruning is count+space based
    # and happens AFTER a verified-good send; see the block further down.

    if (( ! DRY )); then
        # Clean up any incomplete (ro=false) remote snapshots from prior failures
        for label in "${LABELS[@]}"; do
            for snap in "$SNAP_DIR/${label}_"*; do
                [ -d "$snap" ] || continue
                ro=$(btrfs property get "$snap" ro 2>/dev/null | grep -oP 'ro=\K.*')
                if [ "$ro" = "false" ]; then
                    log "Removing incomplete snapshot: $(basename "$snap")"
                    btrfs subvolume delete "$snap" >>"$LOG" 2>&1 || true
                fi
            done
        done
        # Clean up any orphaned local snapshots
        for snap in "$LOCAL_SNAP_DIR"/*; do
            [ -d "$snap" ] || continue
            log "Removing orphaned local snapshot: $(basename "$snap")"
            btrfs subvolume delete "$snap" >>"$LOG" 2>&1 || true
        done
    fi

    # Create local read-only snapshot, send/receive to backup drive, then clean.
    # NOTE: btrfs send/receive MUST NOT pipe through tee — the 3-way pipe causes
    # receive to fail with SIGPIPE cascading through the pipeline.
    for entry in "${BTRFS_SRC[@]}"; do
        label="${entry%%:*}"
        src="${entry#*:}"
        local_snap="$LOCAL_SNAP_DIR/${label}_$STAMP"
        if (( DRY )); then
            log "would snapshot $src -> $local_snap, send to $SNAP_DIR/${label}_$STAMP"
            continue
        fi

        log "Creating local snapshot: $local_snap"
        if ! btrfs subvolume snapshot -r "$src" "$local_snap" >>"$LOG" 2>&1; then
            log "ERROR: Failed to create local snapshot for $label ($src)"
            btrfs_ok=false
            continue
        fi

        log "Sending snapshot to backup drive: ${label}_$STAMP"
        if btrfs send "$local_snap" 2>>"$LOG" | btrfs receive "$SNAP_DIR/" >>"$LOG" 2>&1; then
            ro=$(btrfs property get "$SNAP_DIR/${label}_$STAMP" ro 2>/dev/null | grep -oP 'ro=\K.*')
            if [ "$ro" = "true" ]; then
                log "Snapshot ${label}_$STAMP sent and verified"
            else
                log "WARNING: Snapshot ${label}_$STAMP appears incomplete (ro=$ro), removing"
                btrfs subvolume delete "$SNAP_DIR/${label}_$STAMP" >>"$LOG" 2>&1 || true
                btrfs_ok=false
            fi
        else
            log "ERROR: btrfs send/receive failed for $label (pipe rc: ${PIPESTATUS[*]})"
            [ -d "$SNAP_DIR/${label}_$STAMP" ] && btrfs subvolume delete "$SNAP_DIR/${label}_$STAMP" >>"$LOG" 2>&1 || true
            btrfs_ok=false
        fi

        log "Cleaning up local snapshot: $local_snap"
        btrfs subvolume delete "$local_snap" >>"$LOG" 2>&1 || true
    done

    if [ "$btrfs_ok" = "true" ]; then
        log "All btrfs snapshots sent successfully"
    else
        log "WARNING: Some btrfs snapshots failed — continuing with borg backup"
    fi

    # Prune replicas: count-based (keep newest $KEEP per label), then free-space
    # based (drop oldest beyond $MIN_KEEP until MIN_FREE is met). Only after a
    # fully successful send, so a failed run never costs existing history.
    if (( DRY )); then
        for label in "${LABELS[@]}"; do
            excess=$(( $(ls -1d "$SNAP_DIR/${label}_"* 2>/dev/null | wc -l) - KEEP ))
            (( excess > 0 )) && log "would prune $excess old '$label' mirror(s) beyond newest $KEEP"
        done
    elif [ "$btrfs_ok" = "true" ]; then
        for label in "${LABELS[@]}"; do
            ls -1d "$SNAP_DIR/${label}_"* 2>/dev/null | sort | head -n -"$KEEP" \
            | while read -r d; do
                [ -d "$d" ] || continue
                log "Pruning old btrfs mirror: $(basename "$d") (keeping newest $KEEP)"
                btrfs subvolume delete "$d" >>"$LOG" 2>&1 || true
            done
        done
        while bx_space_low; do
            pruned=0
            for label in "${LABELS[@]}"; do
                bx_space_low || break
                n=$(ls -1d "$SNAP_DIR/${label}_"* 2>/dev/null | wc -l)
                [ "$n" -le "$MIN_KEEP" ] && continue
                oldest=$(ls -1d "$SNAP_DIR/${label}_"* 2>/dev/null | sort | head -1)
                [ -d "$oldest" ] || continue
                log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%): deleting oldest $label mirror $(basename "$oldest")"
                btrfs subvolume delete "$oldest" >>"$LOG" 2>&1 || true
                btrfs subvolume sync "$SNAP_DIR" >>"$LOG" 2>&1 || sync
                pruned=1
            done
            [ "$pruned" = 0 ] && { log "Space still low but every btrfs label is at floor MIN_KEEP=$MIN_KEEP; stopping"; break; }
        done
    else
        log "Skipping btrfs mirror pruning — this run's send did not fully succeed"
    fi
else
    log "Root filesystem is $(bx_root_fstype); skipping btrfs replicas (Timeshift covers the snapshot layer on non-btrfs hosts)."
fi

## --- Borg archive ------------------------------------------------------------
log "Starting Borg backup: $ARCHIVE_NAME"

BORG_OPTS=(--verbose --filter AME --list --show-rc --compression lz4
           --one-file-system --exclude-caches
           --exclude '/dev/*' --exclude '/proc/*' --exclude '/sys/*'
           --exclude '/tmp/*' --exclude '/run/*' --exclude '/mnt/*'
           --exclude '/media/*' --exclude '/var/tmp/*' --exclude '/var/cache/*'
           --exclude '/var/log/journal/*' --exclude '/home/*/.cache/*'
           --exclude '/home/*/.local/share/Trash/*' --exclude '/home/*/.npm/_cacache/*'
           --exclude '/home/*/.cargo/registry/*' --exclude '/home/*/.lichess/*'
           --exclude '/home/*/build/*' --exclude '/root/.cache/*'
           --exclude '/root/.local/share/Trash/*' --exclude '/var/lib/flatpak/*'
           --exclude '/.snapshots/*' --exclude '/.backup-snapshots/*')
# --stats is incompatible with --dry-run in borg; use one or the other.
if (( DRY )); then BORG_OPTS+=(--dry-run); else BORG_OPTS+=(--stats); fi

borg create "${BORG_OPTS[@]}" "$BORG_REPO::$ARCHIVE_NAME" "${SOURCES[@]}" 2>&1 | tee -a "$LOG"
backup_rc=${PIPESTATUS[0]}

if [ "$backup_rc" -eq 0 ]; then
    log "Backup completed successfully (rc=0)"
elif [ "$backup_rc" -eq 1 ]; then
    log "Backup completed with warnings (rc=1)"
else
    log "ERROR: Backup failed with rc=$backup_rc"
    exit 2
fi

if (( DRY )); then
    log "would prune to newest $KEEP archives, then free-space prune to MIN_FREE_PCT=$MIN_FREE_PCT / MIN_FREE_GIB=$MIN_FREE_GIB (floor MIN_KEEP=$MIN_KEEP), then compact and check --last 1"
    log "========== BACKUP SESSION END (DRY RUN — nothing changed) =========="
    exit 0
fi

# Retention: count-based, then free-space based. NEVER time-based — this drive
# can sit unplugged for months and age must not delete history.
#   1. keep the newest $KEEP archives (any age)
#   2. if the drive is still tight, drop the oldest one at a time until MIN_FREE
#      is met, but never below $MIN_KEEP archives.
log "Pruning old backups (keep newest $KEEP)..."
borg prune --list --show-rc --keep-last "$KEEP" "$BORG_REPO" 2>&1 | tee -a "$LOG"

log "Compacting repository..."
borg compact --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"

while bx_space_low; do
    n=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l)
    if [ "$n" -le "$MIN_KEEP" ]; then
        log "Space still low (free $(bx_free_gib)G / $(bx_free_pct)%) but at floor MIN_KEEP=$MIN_KEEP; stopping"
        break
    fi
    oldest=$(borg list --short "$BORG_REPO" 2>/dev/null | head -1)
    [ -n "$oldest" ] || break
    log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%, want ${MIN_FREE_PCT}%/${MIN_FREE_GIB}G): deleting oldest archive $oldest"
    borg delete --stats "$BORG_REPO::$oldest" 2>&1 | tee -a "$LOG"
    borg compact --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"
done

log "Verifying latest archive..."
borg check --last 1 --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"

log "--- Final State ---"
df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
borg list --last 3 "$BORG_REPO" 2>&1 | tee -a "$LOG"

log "========== BACKUP SESSION END =========="
