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
#   sudo timeshift-backup.sh                create a snapshot + prune
#   sudo timeshift-backup.sh --prune-only   apply retention only, no new snapshot
#   sudo timeshift-backup.sh --dry-run      detect + log intentions, change nothing
#
# Retention knobs (KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB) come from the config
# and can be overridden in the environment: KEEP=5 timeshift-backup.sh --prune-only
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
PRUNE_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --prune-only) PRUNE_ONLY=1 ;;
        -h|--help) sed -n '27,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

LOG="${TIMESHIFT_BACKUP_LOG:-/var/log/timeshift-backup.log}"   # overridable for sandbox tests
# Timeshift stores rsync snapshots at <device-root>/timeshift/snapshots/<name>,
# and the backup drive is mounted at $BACKUP_MOUNT, so that is where they land.
TS_DIR="$BACKUP_MOUNT/timeshift/snapshots"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]${DRY:+ [DRY]} $*" | tee -a "$LOG"; }

log "========== TIMESHIFT BACKUP SESSION START$([ "$PRUNE_ONLY" = 1 ] && echo ' (PRUNE ONLY)')${DRY:+ (DRY RUN — no changes)} =========="

# One lock for every layer (backup-common.sh): a borg or Back In Time run at
# the same time would prune against the space this snapshot is taking.
if (( ! DRY )); then
    if ! bx_lock 2>>"$LOG"; then
        log "Another backup layer is still running (lock ${BX_LOCK_FILE:-/var/lock/backup-system.lock} held); exiting."
        exit 0
    fi
fi

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

log "suite=${BX_VERSION:-?} host=${BACKUP_HOST_ID} root_fs=$(bx_root_fstype) config=$BX_CONFIG mount=$BACKUP_MOUNT schedule=$SCHEDULE_MODE"
log "retention KEEP=$KEEP MIN_KEEP=$MIN_KEEP MIN_FREE_PCT=$MIN_FREE_PCT MIN_FREE_GIB=$MIN_FREE_GIB"

# Backup drive mounted, and the RIGHT drive (fs-UUID guard from config).
if ! guard_msg=$(bx_check_backup_drive); then
    log "ERROR: $guard_msg — aborting."
    while IFS= read -r _h; do [ -n "$_h" ] && log "  hint: $_h"; done < <(bx_drive_gone_hint)
    exit 1
fi

# Capacity: the drive must hold one full copy of the sources plus spare room.
if cap_msg=$(bx_check_backup_capacity); then log "$cap_msg"; else
    log "ERROR: $cap_msg — aborting."
    exit 1
fi
log "free space now: $(bx_free_gib)G / $(bx_free_pct)% on $BACKUP_MOUNT"

# Pin every Timeshift call to THIS drive, never to whatever device Timeshift's
# own config last remembered: by fs-UUID from the config, else by the device
# actually mounted at $BACKUP_MOUNT.
if [ -n "$BACKUP_FS_UUID" ]; then
    TS_DEV=(--snapshot-device "$BACKUP_FS_UUID")
else
    _src=$(findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null | sed 's/\[.*//')
    TS_DEV=(--snapshot-device "$_src")
fi

# --- snapshot helpers ---------------------------------------------------------
# Snapshot dirs are named by timestamp, so a plain sort is oldest-first.
ts_list()     { ls -1d "$TS_DIR"/*/ 2>/dev/null | sed 's#/$##' | sort; }
# Timeshift writes info.json last; a dir without it is in progress or aborted.
ts_complete() { [ -f "$1/info.json" ]; }
# Only complete snapshots count towards KEEP / MIN_KEEP.
# while-read, not for-in: a snapshot path with a space (/run/media/u/My Passport)
# split into fragments that were never directories, and nothing was pruned.
ts_kept()     { local d; while IFS= read -r d; do [ -n "$d" ] && ts_complete "$d" && echo "$d"; done < <(ts_list); return 0; }
ts_running()  { pgrep -x timeshift >/dev/null 2>&1; }

# ts_delete <name>: ask Timeshift (so its index/symlinks stay coherent), then
# make sure the directory is really gone — Timeshift refuses dirs it does not
# recognise (aborted snapshots), and those we remove directly. Returns non-zero
# if the directory survives, so callers never loop on an undeletable snapshot.
ts_delete() {
    local name="$1" dir="$TS_DIR/$1"
    timeshift --delete --snapshot "$name" --scripted "${TS_DEV[@]}" >>"$LOG" 2>&1
    if [ -d "$dir" ]; then
        log "  timeshift --delete did not remove $name — removing the directory directly"
        rm -rf --one-file-system "$dir"
    fi
    [ ! -d "$dir" ]
}

# ---------------------------------------------------------------------------
# Create the snapshot on the backup drive.
# ---------------------------------------------------------------------------
if [ "$PRUNE_ONLY" = 1 ]; then
    log "prune-only: not creating a snapshot"
else
    COMMENT="${BACKUP_HOST_ID} $(date '+%Y-%m-%d %H:%M:%S') (linux-backup-system)"
    # No --tags: Timeshift files it as "ondemand", which its own scheduler never
    # touches — retention is ours alone (deploy.sh disables Timeshift's schedule).
    TS_ARGS=(--create --scripted --comments "$COMMENT" "${TS_DEV[@]}")

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
fi

# ---------------------------------------------------------------------------
# Retention. Timeshift rsync snapshots are self-contained dirs named by
# timestamp under $TS_DIR, so they sort lexically oldest-first. Prune by
# directory (predictable and consistent with the borg/BIT layers):
#   0. drop aborted snapshots (no info.json) — they hold space and would restore
#      nothing, and Timeshift never counts or cleans them;
#   1. keep the newest $KEEP;
#   2. drop the oldest beyond $MIN_KEEP until MIN_FREE is met.
# NEVER time-based.
# ---------------------------------------------------------------------------
if [ ! -d "$TS_DIR" ]; then
    log "no snapshot directory at $TS_DIR yet (first run?) — skipping prune"
else
    # 0. aborted snapshots. Timeshift is single-instance, so once our --create
    #    has returned (or in prune-only mode, if none is running) any dir without
    #    info.json is a leftover from an interrupted run, not work in progress.
    if ts_running; then
        log "another timeshift instance is running — leaving incomplete snapshots alone"
    else
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            ts_complete "$d" && continue
            name=$(basename "$d")
            if (( DRY )); then
                log "would remove incomplete snapshot (no info.json): $name"
            else
                log "Removing incomplete snapshot (no info.json): $name"
                ts_delete "$name" || log "  WARNING: could not remove $name"
            fi
        done < <(ts_list)
    fi

    total=$(ts_kept | wc -l)
    # 1. count-based
    if (( total > KEEP )); then
        if (( DRY )); then
            log "would prune $(( total - KEEP )) oldest snapshot(s) beyond newest $KEEP (of $total): $(ts_kept | head -n -"$KEEP" | xargs -rn1 basename | tr '\n' ' ')"
        else
            log "Pruning old snapshots ($total total, keeping newest $KEEP)..."
            while IFS= read -r old; do
                [ -n "$old" ] || continue
                name=$(basename "$old")
                log "  Removing: $name"
                ts_delete "$name" || log "  WARNING: could not remove $name"
            done < <(ts_kept | head -n -"$KEEP")
        fi
    else
        log "count prune: $total snapshot(s) <= KEEP=$KEEP, nothing to remove"
    fi
    # 2. free-space based
    if (( DRY )); then
        if bx_space_low; then
            log "would free-space prune (free $(bx_free_gib)G / $(bx_free_pct)% is below MIN_FREE_PCT=$MIN_FREE_PCT / MIN_FREE_GIB=$MIN_FREE_GIB), oldest first, floor MIN_KEEP=$MIN_KEEP"
        else
            log "free space OK (free $(bx_free_gib)G / $(bx_free_pct)% vs MIN_FREE_PCT=$MIN_FREE_PCT / MIN_FREE_GIB=$MIN_FREE_GIB) — no space prune needed"
        fi
    else
        while bx_space_low; do
            n=$(ts_kept | wc -l)
            if (( n <= MIN_KEEP )); then
                log "Space still low (free $(bx_free_gib)G / $(bx_free_pct)%) but at floor MIN_KEEP=$MIN_KEEP; stopping"
                break
            fi
            oldest=$(ts_kept | head -1)
            [ -d "$oldest" ] || break
            name=$(basename "$oldest")
            log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%, want ${MIN_FREE_PCT}%/${MIN_FREE_GIB}G): deleting oldest snapshot $name"
            ts_delete "$name" || { log "ERROR: could not delete $name — stopping space prune"; break; }
        done
    fi
fi

log "--- Final State ---"
log "Snapshots: $(ts_kept | wc -l) complete   Free: $(bx_free_gib)G / $(bx_free_pct)% on $BACKUP_MOUNT"
(( ! DRY )) && df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
log "========== TIMESHIFT BACKUP SESSION END${DRY:+ (DRY RUN — nothing changed)} =========="
