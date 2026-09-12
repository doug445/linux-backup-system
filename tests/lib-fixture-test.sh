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
# tests/lib-fixture-test.sh — backup-common.sh against synthetic inputs.
#
# Exercises the shared library's detection and policy functions: distro-family
# mapping from synthetic os-release files (including derivatives that resolve
# through ID_LIKE), the command->package map, the per-family install command,
# config loading and defaults, the free-space predicates and the wrong-drive
# guard. No disk, no root, no network — pure logic, so it runs everywhere.
# shellcheck disable=SC2034  # variables set here are read by the sourced library functions
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../backup-common.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
expect() { # expect DESC EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== distro family from os-release"
osrel() { printf 'ID=%s\nID_LIKE="%s"\n' "$1" "$2" > "$T/os-release"; BX_OS_RELEASE="$T/os-release" bx_distro_family; }
expect "fedora"                         fedora  "$(osrel fedora '')"
expect "fedora-asahi-remix via ID_LIKE" fedora  "$(osrel fedora-asahi-remix 'fedora')"
expect "nobara via ID_LIKE"             fedora  "$(osrel nobara 'fedora')"
expect "rhel"                           fedora  "$(osrel rhel 'fedora')"
expect "debian"                         debian  "$(osrel debian '')"
expect "ubuntu"                         debian  "$(osrel ubuntu 'debian')"
expect "linuxmint via ID_LIKE"          debian  "$(osrel linuxmint 'ubuntu debian')"
expect "pop"                            debian  "$(osrel pop 'ubuntu debian')"
expect "arch"                           arch    "$(osrel arch '')"
expect "manjaro"                        arch    "$(osrel manjaro 'arch')"
expect "endeavouros"                    arch    "$(osrel endeavouros 'arch')"
expect "cachyos via ID_LIKE"            arch    "$(osrel cachyos 'arch')"
expect "opensuse-tumbleweed via ID_LIKE" suse   "$(osrel opensuse-tumbleweed 'opensuse suse')"
expect "sles"                           suse    "$(osrel sles '')"
expect "alpine is unknown"              unknown "$(osrel alpine '')"
expect "void is unknown"                unknown "$(osrel void '')"
expect "missing os-release is unknown"  unknown "$(BX_OS_RELEASE=$T/nope bx_distro_family)"
# A family name must never match as a substring of another token.
expect "'archlinux-ish' token does not match arch" unknown "$(osrel notarch '')"

echo "== command -> package"
expect "borg on debian"   borgbackup  "$(bx_pkg_for borg debian)"
expect "borg on fedora"   borgbackup  "$(bx_pkg_for borg fedora)"
expect "borg on arch"     borg        "$(bx_pkg_for borg arch)"
expect "btrfs"            btrfs-progs "$(bx_pkg_for btrfs debian)"
expect "mkfs.btrfs"       btrfs-progs "$(bx_pkg_for mkfs.btrfs arch)"
expect "bootctl"          systemd     "$(bx_pkg_for bootctl fedora)"
expect "findmnt"          util-linux  "$(bx_pkg_for findmnt debian)"
expect "awk"              gawk        "$(bx_pkg_for awk fedora)"
expect "timeshift"        timeshift   "$(bx_pkg_for timeshift debian)"
expect "rsync passthrough" rsync      "$(bx_pkg_for rsync debian)"
expect "sfdisk"           util-linux  "$(bx_pkg_for sfdisk debian)"
expect "udevadm"          systemd     "$(bx_pkg_for udevadm arch)"
expect "snapper"          snapper     "$(bx_pkg_for snapper fedora)"
expect "mount.ecryptfs"   ecryptfs-utils "$(bx_pkg_for mount.ecryptfs debian)"
expect "backintime debian" "backintime-common backintime-qt" "$(bx_pkg_for backintime debian)"
expect "backintime fedora" backintime-qt "$(bx_pkg_for backintime fedora)"
expect "backintime suse"   backintime-qt "$(bx_pkg_for backintime suse)"
expect "backintime arch"   backintime   "$(bx_pkg_for backintime arch)"

echo "== install command per family"
icmd() { printf 'ID=%s\n' "$1" > "$T/os-release"; BX_OS_RELEASE="$T/os-release" bx_pkg_install_cmd; }
expect "debian"  "apt-get update -qq && apt-get install -y" "$(icmd debian)"
expect "fedora"  "dnf install -y"                           "$(icmd fedora)"
expect "arch"    "pacman -S --noconfirm --needed"           "$(icmd arch)"
expect "suse"    "zypper --non-interactive install"         "$(icmd opensuse-leap)"
expect "unknown family gives empty command" ""             "$(icmd alpine)"

echo "== bx_ensure_deps"
out=$(bx_ensure_deps bash sh 2>&1); expect "all present short-circuits" 0 "$?"
case "$out" in *"all present"*) ok "reports all present" ;; *) bad "unexpected: $out" ;; esac
printf 'ID=alpine\n' > "$T/os-release"
out=$(BX_OS_RELEASE="$T/os-release" BX_DEP_DRYRUN=1 bx_ensure_deps definitely-not-a-command-xyz 2>&1); rc=$?
expect "missing tool on unknown family returns 1" 1 "$rc"
case "$out" in *"nstall manually"*) ok "tells the user to install manually" ;; *) bad "unexpected: $out" ;; esac
printf 'ID=debian\n' > "$T/os-release"
out=$(BX_OS_RELEASE="$T/os-release" BX_DEP_DRYRUN=1 bx_ensure_deps definitely-not-a-command-xyz 2>&1); rc=$?
if [ "$(id -u)" -eq 0 ]; then
    expect "dry-run on known family returns 0 (root)" 0 "$rc"
    case "$out" in *"(dry-run) would install: definitely-not-a-command-xyz"*"apt-get"*) ok "dry-run names package and installer" ;; *) bad "unexpected: $out" ;; esac
else
    expect "not root cannot install -> 1" 1 "$rc"
    case "$out" in *"not running as root"*) ok "explains it is not root" ;; *) bad "unexpected: $out" ;; esac
fi

echo "== config loading"
unset BACKUP_MOUNT BORG_REPO BACKUP_FS_UUID SCHEDULE_MODE KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB BACKUP_EXTRA_SOURCES
BX_CONFIG="$T/none.conf"; bx_load_config
expect "default mount"     /mnt/backup             "$BACKUP_MOUNT"
expect "default repo"      /mnt/backup/borg-backup "$BORG_REPO"
expect "default schedule"  adhoc                   "$SCHEDULE_MODE"
expect "default KEEP"      10 "$KEEP"; expect "default MIN_KEEP" 3 "$MIN_KEEP"
expect "default MIN_FREE_PCT" 10 "$MIN_FREE_PCT"; expect "default MIN_FREE_GIB" 0 "$MIN_FREE_GIB"
unset BACKUP_MOUNT BORG_REPO BACKUP_FS_UUID SCHEDULE_MODE KEEP MIN_KEEP MIN_FREE_PCT MIN_FREE_GIB
cat > "$T/host.conf" <<'CONF'
BACKUP_MOUNT="/media/x"
SCHEDULE_MODE="scheduled"
KEEP=4
BACKUP_FS_UUID="12345678-1234-1234-1234-123456789abc"
CONF
BX_CONFIG="$T/host.conf"; bx_load_config
expect "mount from config"     /media/x             "$BACKUP_MOUNT"
expect "repo derived from mount" /media/x/borg-backup "$BORG_REPO"
expect "schedule from config"  scheduled            "$SCHEDULE_MODE"
expect "KEEP from config"      4 "$KEEP"; expect "MIN_KEEP still default" 3 "$MIN_KEEP"

echo "== wrong-drive guard"
BACKUP_MOUNT="$T/not-a-mount"; BACKUP_FS_UUID=""
out=$(bx_check_backup_drive); rc=$?
expect "unmounted path refused" 1 "$rc"
case "$out" in *"is not mounted"*) ok "says not mounted" ;; *) bad "unexpected: $out" ;; esac
BACKUP_MOUNT=/; BACKUP_FS_UUID=""
bx_check_backup_drive >/dev/null; expect "empty UUID skips the guard" 0 "$?"
BACKUP_FS_UUID="00000000-0000-0000-0000-000000000000"
out=$(bx_check_backup_drive); rc=$?
expect "mismatched UUID refused" 1 "$rc"
case "$out" in *"wrong drive"*) ok "says wrong drive" ;; *) bad "unexpected: $out" ;; esac
real=$(findmnt -n -o UUID --target / 2>/dev/null)
if [ -n "$real" ]; then
    BACKUP_FS_UUID="$real"; bx_check_backup_drive >/dev/null; expect "matching UUID accepted" 0 "$?"
fi

echo "== free-space predicates"
BACKUP_MOUNT=/
pct=$(bx_free_pct); gib=$(bx_free_gib)
case "$pct" in ''|*[!0-9]*) bad "free pct not numeric: '$pct'" ;; *) ok "free pct numeric ($pct)" ;; esac
case "$gib" in ''|*[!0-9]*) bad "free gib not numeric: '$gib'" ;; *) ok "free gib numeric ($gib)" ;; esac
MIN_FREE_PCT=0; MIN_FREE_GIB=0
bx_space_low; expect "0/0 floors: never low" 1 "$?"
MIN_FREE_PCT=101; MIN_FREE_GIB=0
bx_space_low; expect "101% floor: always low" 0 "$?"
MIN_FREE_PCT=0; MIN_FREE_GIB=999999999
bx_space_low; expect "absurd GiB floor: low" 0 "$?"
BACKUP_MOUNT="$T/absent"
expect "absent mount reports 0% free" 0 "$(bx_free_pct)"

echo "== backup sources"
BACKUP_EXTRA_SOURCES=""
first=$(bx_backup_sources | head -1); expect "root first" / "$first"
m=$(findmnt -rno TARGET -t tmpfs 2>/dev/null | grep -v '^/$' | head -1)
if [ -n "$m" ]; then
    BACKUP_EXTRA_SOURCES="$m"
    if bx_backup_sources | grep -qx "$m"; then ok "extra mounted source included ($m)"; else bad "extra source $m missing"; fi
fi
BACKUP_EXTRA_SOURCES="$T/not-mounted"
if bx_backup_sources | grep -qx "$T/not-mounted"; then bad "unmounted extra source must be dropped"; else ok "unmounted extra source dropped"; fi

echo "== snapshot engine"
e=$(bx_snapshot_engine)
case "$e" in btrfs|timeshift|none) ok "engine is one of btrfs/timeshift/none ($e)" ;; *) bad "engine '$e'" ;; esac
if bx_is_btrfs; then expect "btrfs root -> btrfs engine" btrfs "$e"; fi

echo
echo "lib-fixture-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
