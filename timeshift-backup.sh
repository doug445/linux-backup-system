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
# Timeshift snapshot to the backup drive — the local-snapshot layer for NON-btrfs
# roots (btrfs roots use borg-backup.sh's send/receive replicas instead).
#
# Creates one Timeshift rsync snapshot on the backup drive, then applies the
# fleet retention: count-based plus free-space based, NEVER time-based. Universal
# and config-driven via /etc/backup-system.conf + backup-common.sh.
#
# Usage:
#   sudo timeshift-backup.sh              create a snapshot + prune
#   sudo timeshift-backup.sh --dry-run    detect + log intentions, change nothing
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
        -h|--help) sed -n '27,36p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

LOG="/var/log/timeshift-backup.log"
# Timeshift stores rsync snapshots at <device-root>/timeshift/snapshots/<name>,
# and the backup drive is mounted at $BACKUP_MOUNT, so that is where they land.
TS_DIR="$BACKUP_MOUNT/timeshift/snapshots"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]${DRY:+ [DRY]} $*" | tee -a "$LOG"; }

log "========== TIMESHIFT BACKUP SESSION START${DRY:+ (DRY RUN — no changes)} =========="

# This layer is for non-btrfs roots only.
if bx_is_btrfs; then
    log "Root filesystem is btrfs — Timeshift layer not used here (borg-backup.sh does btrfs replicas). Nothing to do."
    exit 0
fi

# Dependencies first — identify anything missing and install it.
export BX_DEP_DRYRUN="$DRY"
bx_ensure_deps timeshift rsync findmnt 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ] && (( ! DRY )); then
    log "FATAL: required dependencies missing and could not be installed — aborting."
    exit 4
fi

log "suite=${BX_VERSION:-?} host=$(hostname) root_fs=$(bx_root_fstype) config=$BX_CONFIG mount=$BACKUP_MOUNT schedule=$SCHEDULE_MODE"
log "retention KEEP=$KEEP MIN_KEEP=$MIN_KEEP MIN_FREE_PCT=$MIN_FREE_PCT MIN_FREE_GIB=$MIN_FREE_GIB"

# Backup drive mounted, and the RIGHT drive (fs-UUID guard from config).
if ! guard_msg=$(bx_check_backup_drive); then
    log "ERROR: $guard_msg — aborting."
    exit 1
fi
log "free space now: $(bx_free_gib)G / $(bx_free_pct)% on $BACKUP_MOUNT"

# ---------------------------------------------------------------------------
# Create the snapshot on the backup drive.
# ---------------------------------------------------------------------------
COMMENT="$(hostname) $(date '+%Y-%m-%d %H:%M:%S') (linux-backup-system)"
TS_ARGS=(--create --scripted --comments "$COMMENT")
# Pin the snapshot to the backup drive by fs-UUID when we know it.
[ -n "$BACKUP_FS_UUID" ] && TS_ARGS+=(--snapshot-device "$BACKUP_FS_UUID")

if (( DRY )); then
    log "would run: timeshift ${TS_ARGS[*]}"
else
    log "Creating Timeshift snapshot..."
    timeshift "${TS_ARGS[@]}" 2>&1 | tee -a "$LOG"
    ts_rc=${PIPESTATUS[0]}
    if [ "$ts_rc" -ne 0 ]; then
        log "ERROR: timeshift --create failed (rc=$ts_rc)"
        exit 2
    fi
fi

# ---------------------------------------------------------------------------
# Retention. Timeshift rsync snapshots are self-contained dirs named by
# timestamp under $TS_DIR, so they sort lexically oldest-first. Prune by
# directory (predictable and consistent with the borg/BIT layers): keep the
# newest $KEEP, then drop the oldest beyond $MIN_KEEP until MIN_FREE is met.
# NEVER time-based.
# ---------------------------------------------------------------------------
ts_list() { ls -1d "$TS_DIR"/*/ 2>/dev/null | sed 's#/$##' | sort; }

if [ ! -d "$TS_DIR" ]; then
    log "no snapshot directory at $TS_DIR yet (first run?) — skipping prune"
else
    total=$(ts_list | wc -l)
    if (( DRY )); then
        excess=$(( total - KEEP ))
        (( excess > 0 )) && log "would prune $excess oldest snapshot(s) beyond newest $KEEP (of $total)"
        log "would then free-space prune to MIN_FREE_PCT=$MIN_FREE_PCT / MIN_FREE_GIB=$MIN_FREE_GIB (floor MIN_KEEP=$MIN_KEEP)"
    else
        # 1. count-based
        if (( total > KEEP )); then
            log "Pruning old snapshots ($total total, keeping newest $KEEP)..."
            ts_list | head -n -"$KEEP" | while read -r old; do
                name=$(basename "$old")
                log "  Removing: $name"
                timeshift --delete --snapshot "$name" --scripted >>"$LOG" 2>&1 || rm -rf "$old"
            done
        fi
        # 2. free-space based
        while bx_space_low; do
            n=$(ts_list | wc -l)
            if (( n <= MIN_KEEP )); then
                log "Space still low (free $(bx_free_gib)G / $(bx_free_pct)%) but at floor MIN_KEEP=$MIN_KEEP; stopping"
                break
            fi
            oldest=$(ts_list | head -1)
            [ -d "$oldest" ] || break
            name=$(basename "$oldest")
            log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%): deleting oldest snapshot $name"
            timeshift --delete --snapshot "$name" --scripted >>"$LOG" 2>&1 || rm -rf "$oldest"
        done
    fi
fi

log "--- Final State ---"
log "Snapshots: $(ts_list | wc -l)   Free: $(bx_free_gib)G / $(bx_free_pct)% on $BACKUP_MOUNT"
(( ! DRY )) && df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
log "========== TIMESHIFT BACKUP SESSION END${DRY:+ (DRY RUN — nothing changed)} =========="
