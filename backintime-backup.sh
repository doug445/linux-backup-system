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
# Back in Time Backup Script — direct rsync into a BIT-format snapshot tree.
#
# Bypasses BIT's Python/Qt/DBus internals (which deadlock headless) while keeping
# the on-disk snapshot format, so the BIT GUI still reads them. Universal: the
# backup drive, its UUID guard and retention come from /etc/backup-system.conf
# via backup-common.sh; rsync copies all of "/" (crossing into a separate /boot,
# ESP and /home), so every boot layout is captured without configuration.
#
# Usage:
#   sudo backintime-backup.sh              run the backup
#   sudo backintime-backup.sh --dry-run    rsync --dry-run + log intentions, change nothing
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
        -h|--help) sed -n '27,37p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

LOG="/var/log/backintime-backup.log"
# The chain is filed under BACKUP_HOST_ID (pinned in the config by deploy.sh),
# not the live hostname: a renamed host used to start a second full copy under
# the new name — no --link-dest, no hardlinks — that nothing ever pruned.
SNAP_BASE="$BACKUP_MOUNT/backintime/backintime/${BACKUP_HOST_ID}/root/1"
BIT_CONFIG="/root/.config/backintime/config"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]${DRY:+ [DRY]} $*" | tee -a "$LOG"; }

# One lock for every layer (backup-common.sh). A second Back In Time run used
# to rm -rf the first one's in-progress snapshot; a borg run alongside watched
# the drive fill and pruned its own archives to make room.
if (( ! DRY )); then
    if ! bx_lock 2>>"$LOG"; then
        log "Another backup layer is still running (lock ${BX_LOCK_FILE:-/var/lock/backup-system.lock} held); exiting."
        exit 0
    fi
fi

# Dependencies first — identify anything missing and install it (a dry run only
# reports) rather than failing silently mid-rsync.
export BX_DEP_DRYRUN="$DRY"
bx_ensure_deps rsync findmnt 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ] && (( ! DRY )); then
    log "FATAL: required dependencies missing and could not be installed — aborting."
    exit 4
fi

###############################################################################
# Pre-flight
###############################################################################
log "========== BIT BACKUP SESSION START${DRY:+ (DRY RUN — no changes)} =========="
log "suite=${BX_VERSION:-?} host=${BACKUP_HOST_ID} kernel=$(uname -r) arch=$(uname -m) root_fs=$(bx_root_fstype)"
log "config=$BX_CONFIG mount=$BACKUP_MOUNT schedule=$SCHEDULE_MODE"
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

AVAIL_KB=$(df --output=avail "$BACKUP_MOUNT" 2>/dev/null | tail -1 | tr -dc '0-9')
log "Backup drive: $(df -h "$BACKUP_MOUNT" | tail -1)"
[ "${AVAIL_KB:-0}" -lt 5242880 ] && log "WARNING: less than 5GB available!"

###############################################################################
# Prepare snapshot directory
###############################################################################
# Find previous snapshot for --link-dest (incremental hardlinks)
PREV_SNAP=""
[ -L "$SNAP_BASE/last_snapshot" ] && PREV_SNAP=$(readlink "$SNAP_BASE/last_snapshot")

DEST="$SNAP_BASE/new_snapshot/backup"
if (( ! DRY )); then
    mkdir -p "$SNAP_BASE"
    # Clean up stale incomplete snapshot from a prior failed run
    if [ -d "$SNAP_BASE/new_snapshot" ]; then
        log "Removing stale incomplete snapshot from prior failed run"
        rm -rf "$SNAP_BASE/new_snapshot"
    fi
    mkdir -p "$DEST"
    touch "$SNAP_BASE/new_snapshot/save_to_continue"   # in-progress marker
fi

###############################################################################
# Build rsync command
###############################################################################
RSYNC_ARGS=(
    --recursive --times --devices --specials --hard-links --links
    --acls --xattrs --perms --executability --group --owner
    --delete --delete-excluded --human-readable --no-inc-recursive -s
    "--filter=-x security.*"
    "--filter=-xr security.*"
    --chmod=Du+wx
)
# What to copy: "/" and, because rsync crosses filesystems here, every separate
# local filesystem the machine is made of comes along (a separate /home, /boot,
# the ESP, an openSUSE /var) — but NOTHING else that happens to be mounted:
# the backup drive itself (a drive mounted anywhere but /mnt used to copy its
# own borg repo and replicas into the snapshot until it was full), NAS shares,
# docker overlays, snap images, other people's USB sticks. Every mount that is
# not a backup source is excluded by name, from the live mount table.
mapfile -t SOURCES < <(bx_backup_sources)
# A source that lives under a blanket-excluded tree (BACKUP_EXTRA_SOURCES=
# /mnt/data under /mnt/*) is included first — rsync takes the first match.
for _src in "${SOURCES[@]}"; do
    case "$_src" in /mnt/*|/media/*|/run/*|/tmp/*) RSYNC_ARGS+=("--include=$_src") ;; esac
done
while IFS= read -r _t; do
    [ -n "$_t" ] && [ "$_t" != / ] || continue
    case " ${SOURCES[*]} " in *" $_t "*) continue ;; esac
    RSYNC_ARGS+=("--exclude=$_t/*")
done < <(findmnt -lno TARGET 2>/dev/null)
# The shared exclude list (backup-common.sh): the same one borg uses, plus
# BACKUP_EXTRA_EXCLUDES from the config.
while IFS= read -r _ex; do [ -n "$_ex" ] && RSYNC_ARGS+=("--exclude=$_ex"); done < <(bx_excludes)
RSYNC_ARGS+=(--exclude="$BACKUP_MOUNT/backintime")
log "backup sources: ${SOURCES[*]}"
if [ -n "$PREV_SNAP" ] && [ -d "$SNAP_BASE/$PREV_SNAP/backup" ]; then
    RSYNC_ARGS+=(--link-dest="../../${PREV_SNAP}/backup")
    log "Incremental from: $PREV_SNAP"
else
    log "Full backup (no previous snapshot)"
fi
(( DRY )) && RSYNC_ARGS+=(--dry-run --itemize-changes)

###############################################################################
# Run rsync — stdout/stderr to log, no pipe to Python
###############################################################################
log "Starting rsync${DRY:+ (dry-run)}..."
START_TIME=$(date +%s)
rsync "${RSYNC_ARGS[@]}" / "$DEST" >>"$LOG" 2>&1
rsync_rc=$?
END_TIME=$(date +%s)
DURATION_MIN=$(( (END_TIME - START_TIME) / 60 )); DURATION_SEC=$(( (END_TIME - START_TIME) % 60 ))

# rsync exit codes: 0=ok, 24=vanished files (normal), 23=partial
PARTIAL=0
case "$rsync_rc" in
    0)  log "rsync completed successfully (rc=0) in ${DURATION_MIN}m ${DURATION_SEC}s" ;;
    24) log "rsync completed with vanished files (rc=24) in ${DURATION_MIN}m ${DURATION_SEC}s — normal" ;;
    23) log "WARNING: rsync partial transfer (rc=23) in ${DURATION_MIN}m ${DURATION_SEC}s — kept as a FAILED snapshot (Back In Time's marker), not as the chain head"
        PARTIAL=1 ;;
    *)  log "ERROR: rsync failed with rc=$rsync_rc after ${DURATION_MIN}m ${DURATION_SEC}s"
        df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
        (( ! DRY )) && rm -rf "$SNAP_BASE/new_snapshot"
        exit 2 ;;
esac

if (( DRY )); then
    log "would finalize snapshot $(date +%Y%m%d-%H%M%S)-000, update last_snapshot symlink"
    log "would prune to newest $KEEP snapshots, then free-space prune to MIN_FREE_PCT=$MIN_FREE_PCT / MIN_FREE_GIB=$MIN_FREE_GIB (floor MIN_KEEP=$MIN_KEEP)"
    log "========== BIT BACKUP SESSION END (DRY RUN — nothing changed) =========="
    exit 0
fi

###############################################################################
# Finalize snapshot (BIT-compatible format)
###############################################################################
SNAP_NAME="$(date +%Y%m%d-%H%M%S)-000"
rm -f "$SNAP_BASE/new_snapshot/save_to_continue"
cat > "$SNAP_BASE/new_snapshot/info" << EOF
[0]
snapshot_version=2
snapshot_date=$(date +%Y%m%d-%H%M%S)
host=$(hostname)
user=root
profile_id=1
tag=
type=1
EOF
[ -f "$BIT_CONFIG" ] && cp "$BIT_CONFIG" "$SNAP_BASE/new_snapshot/config"
mv "$SNAP_BASE/new_snapshot" "$SNAP_BASE/$SNAP_NAME"
if (( PARTIAL )); then
    # A partial copy (drive went read-only, I/O errors, a destination that
    # rejects ACLs/xattrs) must never become last_snapshot: it would be the
    # next run's --link-dest and, ten runs later, the count prune would have
    # replaced every complete snapshot with partial ones.
    touch "$SNAP_BASE/$SNAP_NAME/failed"
    log "Snapshot kept as FAILED: $SNAP_NAME (last_snapshot unchanged${PREV_SNAP:+: $PREV_SNAP})"
else
    rm -f "$SNAP_BASE/last_snapshot"
    ln -s "$SNAP_NAME" "$SNAP_BASE/last_snapshot"
    log "Snapshot finalized: $SNAP_NAME"
fi

###############################################################################
# Prune: count-based (keep newest $KEEP), then free-space based (drop oldest
# beyond $MIN_KEEP until MIN_FREE is met). NEVER time-based — an ad-hoc drive
# may sit unplugged for months. The newest is always kept, so last_snapshot
# stays valid.
###############################################################################
# Failed (partial) snapshots first: they hold space and restore a partial
# system. Any older than the newest complete snapshot goes; a failed one newer
# than every complete one is kept until a complete one supersedes it.
bit_complete() { ls -1d "$SNAP_BASE"/[0-9]* 2>/dev/null | sort | while read -r d; do [ -e "$d/failed" ] || echo "$d"; done; }
newest_ok=$(bit_complete | tail -1)
if [ -n "$newest_ok" ]; then
    ls -1d "$SNAP_BASE"/[0-9]* 2>/dev/null | sort | while read -r d; do
        [ -e "$d/failed" ] || continue
        [ "$d" \< "$newest_ok" ] || continue
        log "Removing failed snapshot: $(basename "$d") (superseded by $(basename "$newest_ok"))"
        rm -rf "$d"
    done
fi
# rm -rf on btrfs frees space only at the next commit; without a sync the
# free-space loop below re-read df too early and deleted one snapshot too many.
bit_sync() { sync; btrfs filesystem sync "$BACKUP_MOUNT" >/dev/null 2>&1 || true; }
SNAP_COUNT=$(bit_complete | wc -l)
if [ "$SNAP_COUNT" -gt "$KEEP" ]; then
    log "Pruning old snapshots ($SNAP_COUNT complete, keeping newest $KEEP)..."
    bit_complete | head -n -"$KEEP" | while read -r old; do
        log "  Removing: $(basename "$old")"
        rm -rf "$old"
    done
    bit_sync
fi
while bx_space_low; do
    n=$(bit_complete | wc -l)
    if [ "$n" -le "$MIN_KEEP" ]; then
        log "Space still low (free $(bx_free_gib)G / $(bx_free_pct)%) but at floor MIN_KEEP=$MIN_KEEP; stopping"
        break
    fi
    oldest=$(bit_complete | head -1)
    [ -d "$oldest" ] || break
    log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%): deleting oldest snapshot $(basename "$oldest")"
    rm -rf "$oldest"
    bit_sync
    if [ -e "$oldest" ]; then
        log "ERROR: could not delete $(basename "$oldest") (read-only drive?) — stopping the space prune"
        break
    fi
done

###############################################################################
# Post-backup
###############################################################################
FINAL_AVAIL_KB=$(df --output=avail "$BACKUP_MOUNT" 2>/dev/null | tail -1 | tr -dc '0-9')
log "--- Final State ---"
log "Snapshots: $(bit_complete | wc -l) complete$( n=$(ls -1d "$SNAP_BASE"/[0-9]*/failed 2>/dev/null | wc -l); [ "$n" -gt 0 ] && echo ", $n failed")"
log "Space used by this backup: ~$(( (${AVAIL_KB:-0} - ${FINAL_AVAIL_KB:-0}) / 1024 ))MB"
log "Remaining: $(( ${FINAL_AVAIL_KB:-0} / 1024 / 1024 ))GB"
df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
if (( PARTIAL )); then
    log "========== BIT BACKUP SESSION END (PARTIAL — see rsync rc=23 above) =========="
    exit 3
fi
log "========== BIT BACKUP SESSION END =========="
