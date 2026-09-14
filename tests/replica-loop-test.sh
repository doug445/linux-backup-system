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
# tests/replica-loop-test.sh — btrfs replicas on real filesystems: two small
# btrfs images on loop devices stand in for the system disk and the backup
# drive. Proves the first send is full, the next is incremental from the kept
# parent (and costs the drive only the change), a pruned parent replica falls
# back to a full send, a failed send keeps the previous parent, and a
# fully-excluded tree gets no replica. Needs root (loop devices, mounts);
# skipped otherwise. Touches nothing outside its own temp directory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }

if [ "$(id -u)" -ne 0 ]; then echo "replica-loop-test: needs root — SKIP"; exit 0; fi
for c in mkfs.btrfs losetup btrfs; do command -v "$c" >/dev/null || { echo "replica-loop-test: $c missing — SKIP"; exit 0; }; done

T="$(mktemp -d /var/tmp/lbs-replica.XXXXXX)"
L1=""; L2=""
cleanup() {
    umount "$T/sys" 2>/dev/null; umount "$T/drive" 2>/dev/null
    [ -n "$L1" ] && losetup -d "$L1" 2>/dev/null; [ -n "$L2" ] && losetup -d "$L2" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
truncate -s 300M "$T/sys.img" "$T/drive.img"
L1=$(losetup -f --show "$T/sys.img") && L2=$(losetup -f --show "$T/drive.img") || { echo "replica-loop-test: no loop devices — SKIP"; exit 0; }
mkfs.btrfs -q -f "$L1" >/dev/null && mkfs.btrfs -q -f "$L2" >/dev/null || { bad "mkfs.btrfs"; exit 1; }
mkdir -p "$T/sys" "$T/drive"
mount "$L1" "$T/sys" && mount "$L2" "$T/drive" || { bad "mount"; exit 1; }

# shellcheck disable=SC1091
. "$ROOT/backup-common.sh"
btrfs subvolume create "$T/sys/@home" >/dev/null
mkdir -p "$T/sys/.backup-snapshots" "$T/drive/snapshots"
head -c 40M /dev/urandom > "$T/sys/@home/big"
LOC="$T/sys/.backup-snapshots"; DST="$T/drive/snapshots"; LOGF="$T/log"
used() { btrfs filesystem sync "$T/drive" >/dev/null 2>&1; df -B1M --output=used "$T/drive" | tail -1 | tr -dc '0-9'; }
nlocal() { ls -1d "$LOC"/home_* 2>/dev/null | wc -l; }

echo "== first send: full"
m=$(bx_replica_send home "$T/sys/@home" "$LOC" "$DST" 20260101_000001 "$LOGF"); rc=$?
expect "rc 0" 0 "$rc"; expect "says full" full "$m"
expect "replica is read-only" true "$(btrfs property get "$DST/home_20260101_000001" ro | sed -n 's/^ro=//p')"
expect "one local snapshot kept as the parent" 1 "$(nlocal)"
u1=$(used)

echo "== second send: incremental from the kept parent"
head -c 2M /dev/urandom > "$T/sys/@home/small"
m=$(bx_replica_send home "$T/sys/@home" "$LOC" "$DST" 20260101_000002 "$LOGF"); rc=$?
expect "rc 0" 0 "$rc"; expect "says incremental" "incremental from home_20260101_000001" "$m"
expect "still one local snapshot (the new parent)" "$LOC/home_20260101_000002" "$(ls -1d "$LOC"/home_*)"
u2=$(used); grow=$(( u2 - u1 ))
[ "$grow" -lt 20 ] && ok "the drive grew by the change only (${grow} MiB, a full send would be ~40)" || bad "the drive grew ${grow} MiB — not incremental"
cmp -s "$T/sys/@home/small" "$DST/home_20260101_000002/small" && cmp -s "$T/sys/@home/big" "$DST/home_20260101_000002/big" \
    && ok "incremental replica holds both the old and the new file, byte for byte" || bad "incremental replica content differs"

echo "== parent replica pruned on the drive: full send, not a broken incremental"
btrfs subvolume delete "$DST/home_20260101_000002" >/dev/null
expect "no usable parent" "" "$(bx_replica_parent home "$LOC" "$DST")"
m=$(bx_replica_send home "$T/sys/@home" "$LOC" "$DST" 20260101_000003 "$LOGF"); rc=$?
expect "rc 0" 0 "$rc"; expect "falls back to full" full "$m"

echo "== a failed send keeps the previous parent"
mount -o remount,ro "$T/drive"
m=$(bx_replica_send home "$T/sys/@home" "$LOC" "$DST" 20260101_000004 "$LOGF"); rc=$?
mount -o remount,rw "$T/drive"
expect "rc 1" 1 "$rc"
grep -q 'receive rc=' <<<"$m" && ok "says why ($m)" || bad "no reason given: $m"
expect "previous parent still there, no half snapshot" "$LOC/home_20260101_000003" "$(ls -1d "$LOC"/home_*)"
expect "next run is incremental again" home_20260101_000003 "$(bx_replica_parent home "$LOC" "$DST")"

echo "== label prefix: 'var' never picks up 'var_lib' as its parent"
btrfs subvolume create "$T/sys/@varlib" >/dev/null
bx_replica_send var_lib "$T/sys/@varlib" "$LOC" "$DST" 20260101_000005 "$LOGF" >/dev/null
expect "no parent for var" "" "$(bx_replica_parent var "$LOC" "$DST")"

echo "== a tree that is wholly excluded gets no replica"
BACKUP_MOUNT="$T/drive" bx_source_fully_excluded /var/cache && ok "/var/cache is fully excluded" || bad "/var/cache not seen as excluded"
BACKUP_MOUNT="$T/drive" bx_source_fully_excluded /var/log && bad "/var/log wrongly seen as fully excluded" || ok "/var/log is replicated (only its journal is excluded)"
BACKUP_MOUNT="$T/drive" bx_source_fully_excluded /home && bad "/home wrongly excluded" || ok "/home is replicated"

echo
echo "replica-loop-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
