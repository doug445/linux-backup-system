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
# Unlock + mount the backup drive on plug-in / boot coldplug.
#
# POLICY: this script ONLY unlocks and mounts. It NEVER starts a backup.
# Auto-backup-on-connect is deliberately disabled — on an ad-hoc (external) box
# the backup timers are masked and backups are run by hand or from the tray.
# Triggered by /etc/udev/rules.d/99-backup-drive.rules.
#
# Universal: the drive's LUKS UUID, filesystem UUID, keyfile, mountpoint and any
# mount options come from /etc/backup-system.conf (BACKUP_LUKS_UUID /
# BACKUP_FS_UUID / BACKUP_KEYFILE / BACKUP_MOUNT / BACKUP_MOUNT_OPTS). With none
# set it is a clean no-op, so the same unit ships to every host.
set -uo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_self_dir/backup-common.sh" /usr/local/sbin/backup-common.sh /usr/local/lib/backup-common.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
if declare -f bx_load_config >/dev/null; then bx_load_config; else
    BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"; BACKUP_LUKS_UUID="${BACKUP_LUKS_UUID:-}"
    BACKUP_FS_UUID="${BACKUP_FS_UUID:-}"; BACKUP_KEYFILE="${BACKUP_KEYFILE:-}"
fi

LUKS_UUID="$BACKUP_LUKS_UUID"
FS_UUID="$BACKUP_FS_UUID"
MAPPER="luks-${LUKS_UUID}"
MOUNTPOINT="$BACKUP_MOUNT"
KEYFILE="$BACKUP_KEYFILE"
MOUNT_OPTS="${BACKUP_MOUNT_OPTS:-}"
OWNER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

log() { echo "[backup-drive-attach] $*"; }

# Nothing configured for this host → nothing to do.
if [ -z "$FS_UUID" ]; then
    log "no backup drive configured in /etc/backup-system.conf (BACKUP_FS_UUID) — nothing to do."
    exit 0
fi

# A plain (unencrypted) drive has no LUKS UUID: skip straight to the mount.
if [ -z "$LUKS_UUID" ]; then
    if [ ! -e "/dev/disk/by-uuid/${FS_UUID}" ]; then
        log "backup filesystem ${FS_UUID} not present — nothing to do."
        exit 0
    fi
# Drive present?
elif [ ! -e "/dev/disk/by-uuid/${LUKS_UUID}" ]; then
    log "LUKS partition ${LUKS_UUID} not present — nothing to do."
    exit 0
fi

# Unlock
if [ -z "$LUKS_UUID" ]; then
    :
elif [ -e "/dev/mapper/${MAPPER}" ]; then
    log "already unlocked: /dev/mapper/${MAPPER}"
else
    if [ -z "$KEYFILE" ] || [ ! -r "$KEYFILE" ]; then
        log "ERROR: keyfile '${KEYFILE:-<unset>}' missing/unreadable — cannot auto-unlock."
        exit 1
    fi
    log "unlocking ${LUKS_UUID} with $KEYFILE"
    if ! /usr/sbin/cryptsetup luksOpen --key-file "$KEYFILE" \
            "/dev/disk/by-uuid/${LUKS_UUID}" "$MAPPER"; then
        log "ERROR: luksOpen failed (is the keyfile enrolled in a keyslot?)"
        exit 1
    fi
fi

# Wait briefly for the decrypted filesystem node to settle
for _ in $(/usr/bin/seq 1 20); do
    [ -e "/dev/disk/by-uuid/${FS_UUID}" ] && break
    /usr/bin/sleep 0.25
done

# Mount (mount options optional, per-fs, from config)
if /usr/bin/mountpoint -q "$MOUNTPOINT"; then
    log "already mounted: $MOUNTPOINT"
else
    /usr/bin/mkdir -p "$MOUNTPOINT"
    log "mounting $FS_UUID -> $MOUNTPOINT ${MOUNT_OPTS:+(opts: $MOUNT_OPTS)}"
    if ! /usr/bin/mount ${MOUNT_OPTS:+-o "$MOUNT_OPTS"} "UUID=${FS_UUID}" "$MOUNTPOINT"; then
        log "ERROR: mount failed"
        exit 1
    fi
    /usr/bin/chown "${OWNER}:${OWNER}" "$MOUNTPOINT" 2>/dev/null || true
fi

log "ready: $MOUNTPOINT ($(/usr/bin/df -h --output=avail "$MOUNTPOINT" | /usr/bin/tail -1 | /usr/bin/tr -d ' ') free)"
exit 0
