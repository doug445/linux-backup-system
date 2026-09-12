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
# Clean up after the backup drive is unplugged (udev "remove" on its partition).
#
# A drive yanked while mounted leaves a dead mount at BACKUP_MOUNT and, on a
# LUKS drive, a dm mapping whose backing device is gone. Left alone, the next
# plug-in fails: "already mounted" on a mount nothing can read, and
# "device already exists" from cryptsetup. This lazily unmounts and closes
# the mapping — only when the backing device is really gone — so the attach
# unit can bring the drive back cleanly.
#
# Never touches a drive that is still present, and never starts anything.
set -uo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_self_dir/backup-common.sh" /usr/local/sbin/backup-common.sh /usr/local/lib/backup-common.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
if declare -f bx_load_config >/dev/null; then bx_load_config; else
    BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"; BACKUP_LUKS_UUID="${BACKUP_LUKS_UUID:-}"; BACKUP_FS_UUID="${BACKUP_FS_UUID:-}"
fi

log() { echo "[backup-drive-detach] $*"; }

if [ -z "$BACKUP_FS_UUID" ] && [ -z "$BACKUP_LUKS_UUID" ]; then
    log "no backup drive configured — nothing to do."
    exit 0
fi

# 1. The mount: gone backing device -> lazy unmount.
if /usr/bin/mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
    src=$(/usr/bin/findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null | sed 's/\[.*//' || true)
    if [ -n "$src" ] && [ ! -e "$src" ] || { [ -n "$BACKUP_FS_UUID" ] && [ ! -e "/dev/disk/by-uuid/$BACKUP_FS_UUID" ]; }; then
        log "backing device gone — lazily unmounting $BACKUP_MOUNT"
        /usr/bin/umount -l "$BACKUP_MOUNT" 2>/dev/null || true
    else
        log "$BACKUP_MOUNT still backed by a present device — leaving it."
        exit 0
    fi
fi

# 2. The LUKS mapping: backing partition gone -> close it.
if [ -n "$BACKUP_LUKS_UUID" ]; then
    MAPPER="luks-$BACKUP_LUKS_UUID"
    if [ -e "/dev/mapper/$MAPPER" ] && [ ! -e "/dev/disk/by-uuid/$BACKUP_LUKS_UUID" ]; then
        log "LUKS partition gone — closing /dev/mapper/$MAPPER"
        /usr/sbin/cryptsetup close "$MAPPER" 2>/dev/null \
            || /usr/sbin/dmsetup remove --force "$MAPPER" 2>/dev/null \
            || log "could not close $MAPPER (still busy?) — it will be closed on the next attach"
    fi
fi
log "done."
exit 0
