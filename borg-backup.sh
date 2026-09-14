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

ARCHIVE_NAME="${BACKUP_HOST_ID}-$(date +%Y-%m-%d_%H-%M-%S)"
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

# One lock for every layer (backup-common.sh): a second borg run would delete
# this one's in-flight receive as "incomplete", and a Back In Time or
# Timeshift run at the same time would watch the drive fill and prune this
# layer's history to make room. Wait up to BX_LOCK_WAIT, then give up cleanly.
if ! bx_lock 2>>"$LOG"; then
    log "Another backup layer is still running (lock ${BX_LOCK_FILE:-/var/lock/backup-system.lock} held); exiting."
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
log "suite=${BX_VERSION:-?} host=${BACKUP_HOST_ID} arch=$(uname -m) root_fs=$(bx_root_fstype) snapshot_engine=$(bx_snapshot_engine)"
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
        if bx_source_fully_excluded "$m"; then
            log "no replica for $m — its whole tree is on the exclude list" >&2
            continue
        fi
        if [ "$m" = / ]; then echo "root:/"; else echo "$(echo "${m#/}" | tr / _):$m"; fi
    done
}

btrfs_ok=true
declare -A LABEL_OK=()
if bx_is_btrfs && [ "$(findmnt -no FSTYPE --target "$BACKUP_MOUNT" 2>/dev/null)" != btrfs ]; then
    # `btrfs receive` needs a btrfs destination. On an ext4/xfs/exfat backup
    # drive every send failed, every run, and the session still ended rc=0
    # with no snapshot layer at all.
    log "ERROR: root is btrfs but the backup drive at $BACKUP_MOUNT is $(findmnt -no FSTYPE --target "$BACKUP_MOUNT" 2>/dev/null || echo '?'), not btrfs — send/receive replicas need a btrfs drive; skipping the replica layer (borg + Back In Time still run)"
    btrfs_ok=false
elif bx_is_btrfs; then
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
            for snap in "$SNAP_DIR/${label}_"[0-9]*; do
                [ -d "$snap" ] || continue
                ro=$(btrfs property get "$snap" ro 2>/dev/null | sed -n 's/^ro=//p')
                if [ "$ro" = "false" ]; then
                    log "Removing incomplete snapshot: $(basename "$snap")"
                    btrfs subvolume delete "$snap" >>"$LOG" 2>&1 || true
                fi
            done
        done
        # Local snapshots: keep exactly one per label — the parent the next
        # incremental send needs (its replica is complete on this drive).
        # Anything else is a leftover from an interrupted run, a label that
        # is no longer a source, or a parent whose replica is gone.
        keep=" "
        for label in "${LABELS[@]}"; do
            p=$(bx_replica_parent "$label" "$LOCAL_SNAP_DIR" "$SNAP_DIR")
            [ -n "$p" ] && keep="$keep$p "
        done
        for snap in "$LOCAL_SNAP_DIR"/*; do
            [ -d "$snap" ] || continue
            case "$keep" in *" $(basename "$snap") "*) continue ;; esac
            log "Removing local snapshot that is no usable parent: $(basename "$snap")"
            btrfs subvolume delete "$snap" >>"$LOG" 2>&1 || true
        done
    fi

    # Snapshot, send (incremental when the last replica and its local parent
    # are both there), verify; the library keeps the new snapshot as the next
    # run's parent.
    for entry in "${BTRFS_SRC[@]}"; do
        label="${entry%%:*}"
        src="${entry#*:}"
        if (( DRY )); then
            p=$(bx_replica_parent "$label" "$LOCAL_SNAP_DIR" "$SNAP_DIR")
            log "would snapshot $src and send ${label}_$STAMP to $SNAP_DIR — ${p:+incremental from $p}${p:-FULL send (no usable parent: first run, new drive, or pruned replica)}"
            continue
        fi
        log "Sending $label ($src) to the backup drive: ${label}_$STAMP ..."
        if msg=$(bx_replica_send "$label" "$src" "$LOCAL_SNAP_DIR" "$SNAP_DIR" "$STAMP" "$LOG"); then
            log "Replica ${label}_$STAMP sent and verified ($msg)"
            LABEL_OK[$label]=1
        else
            log "ERROR: replica of $label failed: $msg"
            btrfs_ok=false
        fi
    done

    if [ "$btrfs_ok" = "true" ]; then
        log "All btrfs snapshots sent successfully"
    else
        log "WARNING: Some btrfs snapshots failed — continuing with borg backup"
    fi

    # Prune replicas: count-based (keep newest $KEEP per label), then free-space
    # based (drop oldest beyond $MIN_KEEP until MIN_FREE is met). Count prune
    # only for a label whose send succeeded this run, so a failed run never
    # costs that label's history — but per LABEL: one label that can never be
    # snapshotted (a swapfile in @) used to switch pruning off for every label
    # forever, the drive filled with the others' replicas, and borg then ate
    # its own archives to make room. The glob ends in a digit so a label that
    # is a prefix of another (var, var_lib) never prunes the other's replicas.
    if (( DRY )); then
        for label in "${LABELS[@]}"; do
            excess=$(( $(ls -1d "$SNAP_DIR/${label}_"[0-9]* 2>/dev/null | wc -l) - KEEP ))
            (( excess > 0 )) && log "would prune $excess old '$label' mirror(s) beyond newest $KEEP"
        done
    else
        for label in "${LABELS[@]}"; do
            if [ -z "${LABEL_OK[$label]:-}" ]; then
                log "Skipping count prune for '$label' — this run's send did not succeed"
                continue
            fi
            ls -1d "$SNAP_DIR/${label}_"[0-9]* 2>/dev/null | sort | head -n -"$KEEP" \
            | while read -r d; do
                [ -d "$d" ] || continue
                log "Pruning old btrfs mirror: $(basename "$d") (keeping newest $KEEP)"
                btrfs subvolume delete "$d" >>"$LOG" 2>&1 || log "  WARNING: could not delete $(basename "$d")"
            done
        done
        while bx_space_low; do
            pruned=0
            for label in "${LABELS[@]}"; do
                bx_space_low || break
                n=$(ls -1d "$SNAP_DIR/${label}_"[0-9]* 2>/dev/null | wc -l)
                [ "$n" -le "$MIN_KEEP" ] && continue
                oldest=$(ls -1d "$SNAP_DIR/${label}_"[0-9]* 2>/dev/null | sort | head -1)
                [ -d "$oldest" ] || continue
                log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%): deleting oldest $label mirror $(basename "$oldest")"
                btrfs subvolume delete "$oldest" >>"$LOG" 2>&1 || true
                btrfs subvolume sync "$SNAP_DIR" >>"$LOG" 2>&1 || sync
                if [ -d "$oldest" ]; then
                    log "ERROR: could not delete $(basename "$oldest") (read-only drive?) — stopping the space prune"
                    pruned=0; break 2
                fi
                pruned=1
            done
            [ "$pruned" = 0 ] && { log "Space still low but every btrfs label is at floor MIN_KEEP=$MIN_KEEP; stopping"; break; }
        done
    fi
else
    log "Root filesystem is $(bx_root_fstype); skipping btrfs replicas (Timeshift covers the snapshot layer on non-btrfs hosts)."
fi

## --- Borg archive ------------------------------------------------------------
log "Starting Borg backup: $ARCHIVE_NAME"

BORG_OPTS=(--verbose --filter AME --list --show-rc --compression lz4
           --one-file-system --exclude-caches)
# The exclude list is the shared one in backup-common.sh (bx_excludes), so
# borg and Back In Time agree on what "everything" is; per-host additions go
# in BACKUP_EXTRA_EXCLUDES. Patterns, not --exclude, because order matters: a
# source that lives under a blanket-excluded tree (BACKUP_EXTRA_SOURCES=
# /mnt/data under /mnt/*) is re-included FIRST — borg takes the first match —
# where --exclude '/mnt/*' used to archive it as an empty directory.
for _src in "${SOURCES[@]}"; do
    case "$_src" in /mnt/*|/media/*|/run/*|/tmp/*) BORG_OPTS+=("--pattern=+$_src") ;; esac
done
while IFS= read -r _ex; do [ -n "$_ex" ] && BORG_OPTS+=("--pattern=-$_ex"); done < <(bx_excludes)
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
# Scoped to THIS host's archives: two machines sharing one repo must not
# prune each other (--glob-archives), and every borg exit code is read —
# a failed prune or a corrupt repo used to end the session rc=0.
HOST_GLOB="${BACKUP_HOST_ID}-*"
log "Pruning old backups (keep newest $KEEP of $HOST_GLOB)..."
borg prune --list --show-rc --glob-archives "$HOST_GLOB" --keep-last "$KEEP" "$BORG_REPO" 2>&1 | tee -a "$LOG"
prune_rc=${PIPESTATUS[0]}
[ "$prune_rc" -le 1 ] || log "ERROR: borg prune failed (rc=$prune_rc) — nothing pruned this run"

log "Compacting repository..."
borg compact --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"

while bx_space_low; do
    n=$(borg list --short --glob-archives "$HOST_GLOB" "$BORG_REPO" 2>/dev/null | wc -l)
    if [ "$n" -le "$MIN_KEEP" ]; then
        log "Space still low (free $(bx_free_gib)G / $(bx_free_pct)%) but at floor MIN_KEEP=$MIN_KEEP; stopping"
        break
    fi
    oldest=$(borg list --short --glob-archives "$HOST_GLOB" "$BORG_REPO" 2>/dev/null | head -1)
    [ -n "$oldest" ] || break
    log "Space low (free $(bx_free_gib)G / $(bx_free_pct)%, want ${MIN_FREE_PCT}%/${MIN_FREE_GIB}G): deleting oldest archive $oldest"
    borg delete --stats "$BORG_REPO::$oldest" 2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" -gt 1 ]; then
        log "ERROR: could not delete $oldest (repo locked? read-only drive?) — stopping the space prune"
        break
    fi
    borg compact --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"
done

log "Verifying latest archive..."
borg check --last 1 --show-rc "$BORG_REPO" 2>&1 | tee -a "$LOG"
check_rc=${PIPESTATUS[0]}

log "--- Final State ---"
df -h "$BACKUP_MOUNT" 2>&1 | tee -a "$LOG"
borg list --last 3 --glob-archives "$HOST_GLOB" "$BORG_REPO" 2>&1 | tee -a "$LOG"

if [ "$check_rc" -gt 1 ]; then
    log "ERROR: borg check found problems in the repository (rc=$check_rc) — this backup is NOT verified"
    log "========== BACKUP SESSION END (WITH ERRORS) =========="
    exit 5
fi
if [ "$btrfs_ok" != true ]; then
    log "WARNING: the btrfs replica layer did not fully succeed this run (see above); borg archive is complete"
    log "========== BACKUP SESSION END (REPLICAS INCOMPLETE) =========="
    exit 3
fi
log "========== BACKUP SESSION END =========="
