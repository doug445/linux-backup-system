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
# Back up the LUKS2 header of every crypto_LUKS device on this machine.
#
# A LUKS header is ~16 MiB and changes only when keyslots change, but a STALE
# header backup is worse than none: restoring one silently reinstates an old
# keyslot set and revokes the current ones. So the active keyslots are encoded
# in each filename, and the run warns when a stored header no longer matches
# the live device.
#
# Headers are stored in two locations so no device's header depends on that
# same device being readable:
#   /root/luks-headers          (on the root filesystem)
#   $BACKUP_MOUNT/luks-headers  (on the backup drive)
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

# Per-host config: source the shared library and /etc/backup-system.conf so a
# run by hand (or from the tray) sees the same drive the units do. Values set
# in the environment — the units' Environment= lines — still win.
_env_mount="${BACKUP_MOUNT:-}"; _env_repo="${BORG_REPO:-}"; _env_keep="${KEEP:-}"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_self_dir/backup-common.sh" /usr/local/sbin/backup-common.sh /usr/local/lib/backup-common.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
declare -f bx_load_config >/dev/null && bx_load_config
[ -n "$_env_mount" ] && BACKUP_MOUNT="$_env_mount"
[ -n "$_env_repo" ] && BORG_REPO="$_env_repo"
BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
LOCAL_DIR="/root/luks-headers"
BACKUP_DIR="$BACKUP_MOUNT/luks-headers"
LOG="/var/log/luks-header-backup.log"
KEEP=${_env_keep:-6}   # headers kept per device: its own knob, not the fleet KEEP
STAMP="$(date +%Y-%m-%d)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

slot_manifest() {
    # Slot numbers only. Do NOT grep all digits out of "1: luks2" -- that also
    # captures the 2 from "luks2" and produces nonsense like "1,2,2,2".
    # LUKS2 lists slots as "  0: luks2", LUKS1 as "Key Slot 0: ENABLED".
    cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^[[:space:]]+[0-9]+: luks2/     { sub(/:/, "", $1); print $1 }
        /^Key Slot [0-9]+: ENABLED/      { sub(/:/, "", $3); print $3 }' | paste -sd, -
}

log "========== LUKS HEADER BACKUP START =========="

mkdir -p "$LOCAL_DIR"
dests=("$LOCAL_DIR")
if mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
    mkdir -p "$BACKUP_DIR"
    dests+=("$BACKUP_DIR")
else
    log "WARNING: $BACKUP_MOUNT not mounted; storing headers in $LOCAL_DIR only"
fi

rc=0
while read -r dev uuid; do
    [[ -n "$dev" ]] || continue
    label="$(basename "$dev")_${uuid:0:8}"
    # Kernel names drift between boots (sdb1 today, sda1 tomorrow), so the
    # superseded scan and the prune are keyed on the uuid fragment alone.
    byuuid="*_${uuid:0:8}_slots-"
    slots="$(slot_manifest "$dev")"
    log "$dev (uuid ${uuid:0:8}) active keyslots: ${slots:-NONE}"

    if [[ -z "$slots" ]]; then
        log "ERROR: $dev reports no keyslots; refusing to back up a broken header"
        rc=1
        continue
    fi

    tmp="$(mktemp /tmp/luks-header.XXXXXX)"
    rm -f "$tmp"
    if ! cryptsetup luksHeaderBackup "$dev" --header-backup-file "$tmp" 2>>"$LOG"; then
        log "ERROR: header backup failed for $dev"
        rm -f "$tmp"
        rc=1
        continue
    fi
    chmod 600 "$tmp"

    for d in "${dests[@]}"; do
        out="$d/${label}_slots-${slots//,/-}_${STAMP}.header"
        cp -f "$tmp" "$out" && chmod 600 "$out"
        sha256sum "$out" | awk '{print $1"  "B}' B="$(basename "$out")" >> "$d/SHA256SUMS.new"
        log "  stored $out"
    done
    rm -f "$tmp"

    for d in "${dests[@]}"; do
        while IFS= read -r old; do
            [[ -n "$old" ]] || continue
            case "$(basename "$old")" in
                *"_slots-${slots//,/-}_"*) ;;
                *) log "  NOTE: superseded header present (keyslots differ from live): $(basename "$old")" ;;
            esac
        done < <(find "$d" -maxdepth 1 -name "${byuuid}*.header" 2>/dev/null)

        # Retain the most recent $KEEP headers per device.
        while IFS= read -r o; do
            [[ -n "$o" ]] || continue
            rm -f "$o" && log "  pruned old header $(basename "$o")"
        done < <(ls -1t "$d"/${byuuid}*.header 2>/dev/null | tail -n +$((KEEP + 1)))
    done
done < <(lsblk -rno PATH,FSTYPE,UUID | awk '$2=="crypto_LUKS"{print $1, $3}')

for d in "${dests[@]}"; do
    if [[ -f "$d/SHA256SUMS.new" ]]; then
        mv -f "$d/SHA256SUMS.new" "$d/SHA256SUMS"
        chmod 600 "$d/SHA256SUMS"
    fi
done

log "========== LUKS HEADER BACKUP END (rc=$rc) =========="
exit $rc
