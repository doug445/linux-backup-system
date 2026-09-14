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
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
# Debian upgraded in place from before usrmerge, Gentoo split-usr: cryptsetup
# lives in /sbin and mount in /bin. Never hard-code /usr/bin.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}

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

# Physically present (by the LUKS partition's own UUID link, or the fs UUID on
# a plain drive)? Then this is a spurious event: touch nothing. The mapper
# node and the fs UUID link inside it are NOT evidence — they outlive a yank.
present=1
if [ -n "$BACKUP_LUKS_UUID" ]; then [ -e "/dev/disk/by-uuid/$BACKUP_LUKS_UUID" ] || present=0
else [ -e "/dev/disk/by-uuid/$BACKUP_FS_UUID" ] || present=0; fi
if [ "$present" = 1 ]; then
    log "drive is still present — leaving it."
    exit 0
fi

# 1. The mount: lazily unmount so nothing can write into a dead filesystem.
if mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
    log "drive gone — lazily unmounting $BACKUP_MOUNT"
    umount -l "$BACKUP_MOUNT" 2>/dev/null || true
fi

# 2. The LUKS mapping: close it (force the dm table away if it is still busy).
if [ -n "$BACKUP_LUKS_UUID" ]; then
    MAPPER="luks-$BACKUP_LUKS_UUID"
    if [ -e "/dev/mapper/$MAPPER" ]; then
        log "drive gone — closing /dev/mapper/$MAPPER"
        cryptsetup close "$MAPPER" 2>/dev/null \
            || dmsetup remove --force "$MAPPER" 2>/dev/null \
            || log "could not close $MAPPER — it will be cleared on the next attach"
    fi
fi
log "done."
exit 0
