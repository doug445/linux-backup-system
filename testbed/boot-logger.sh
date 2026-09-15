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
# testbed/boot-logger.sh — runs ONCE when a restored TEST drive boots
# (testbed-boot-logger.service, installed by `testbed.sh finish`). Proves what the
# system is running from and how it came up, compares every archived file, and
# leaves the report on the source machine's unencrypted boot partition
# (REPORT_PARTUUID in /root/restore-test/testbed.env) — the only thing it writes
# there. Read-only everywhere else.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
ENVF=/root/restore-test/testbed.env
# shellcheck disable=SC1090
. "$ENVF" 2>/dev/null || { echo "no $ENVF" >&2; exit 1; }
R=/run/testbed-boot-report.md
exec 3>"$R"
out() { printf '%s\n' "$*" >&3; }
sec() { out ""; out "## $*"; out ""; }
cmd() { out '```'; out "\$ $*"; timeout 180 bash -c "$*" >&3 2>&1; out '```'; }
disk_of() { local kn sl pk; kn=$(basename "$(readlink -f "$1")"); while :; do sl=$(ls "/sys/block/$kn/slaves" 2>/dev/null | head -1); [ -n "$sl" ] && { kn=$sl; continue; }; pk=$(lsblk -dno PKNAME "/dev/$kn" 2>/dev/null | head -1); [ -n "$pk" ] && { kn=$pk; continue; }; break; done; echo "/dev/$kn"; }

# publish — the report so far, and this boot's journal, onto the source machine's
# boot partition, where `testbed.sh collect` (root) reads them. Called as soon as
# the verdict and health sections exist, and again at the end: the byte
# comparison takes minutes, and a test drive powered off early still leaves
# its report behind.
TS=$(date +%Y%m%d-%H%M%S)
publish() {
    local dev m d
    dev=$(blkid -t "PARTUUID=$REPORT_PARTUUID" -o device 2>/dev/null | head -1)
    [ -n "$dev" ] || { echo "report partition PARTUUID=$REPORT_PARTUUID not found" >&2; return 1; }
    m=/run/testbed-report; mkdir -p "$m"
    mount -o rw,nosuid,nodev,noexec "$dev" "$m" || return 1
    d="$m/restore-test-$STAMP"; mkdir -p "$d"
    cp "$R" "$d/boot-report-$TS.md"
    journalctl -b --no-pager -o short-iso > "$d/journal-$TS.txt" 2>&1
    sync; umount "$m"
}

timeout 600 systemctl is-system-running --wait >/dev/null 2>&1 || true   # never block on a boot that does not settle
out "# Restore test bed — boot report ($HOST, $STAMP)"
out ""; out "generated $(date -Is), kernel $(uname -r)"

sec "Verdict"
root_src=$(findmnt -no SOURCE / | sed 's/\[.*//'); root_disk=$(disk_of "$root_src"); serial=$(lsblk -dno SERIAL "$root_disk" | tr -d ' ')
out "- root: \`$root_src\` on \`$root_disk\` serial \`$serial\` ($(lsblk -dno TRAN "$root_disk"))"
if [ "$serial" = "$TEST_SERIAL" ] || udevadm info -q property -n "$root_disk" 2>/dev/null | grep -qxF "ID_SERIAL_SHORT=$TEST_SERIAL"; then out "- **PASS: running from the restored test drive**"; else out "- **FAIL: not running from the test drive (serial $TEST_SERIAL)**"; fi
host_open=""; host_mounted=""
for s in $HOST_DISK_SERIALS; do
    d=$(lsblk -dnpo NAME,SERIAL | awk -v s="$s" '$2==s{print $1}')
    [ -n "$d" ] || d=$(for x in $(lsblk -dnpo NAME); do udevadm info -q property -n "$x" 2>/dev/null | grep -qxF "ID_SERIAL_SHORT=$s" && echo "$x"; done)
    [ -n "$d" ] || continue
    host_open="$host_open$(lsblk -rnpo NAME,TYPE "$d" | awk '$2=="crypt"{printf "%s ", $1}')"
    host_mounted="$host_mounted$(findmnt -rno TARGET,SOURCE | awk -v d="$d" 'index($2, d)==1{printf "%s ", $1}')"
done
[ -z "$host_open" ] && out "- **PASS: no container on the source machine's disks is open**" || out "- **FAIL: source-machine containers open: $host_open**"
[ -z "$host_mounted" ] && out "- **PASS: nothing from the source machine's disks is mounted**" || out "- **FAIL: source-machine mounts: $host_mounted**"
state=$(systemctl is-system-running 2>/dev/null)
out "- system state: \`$state\`$( [ "$state" = running ] && echo ' — **PASS**' || echo " — failed units: $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{printf "%s ", $1}')")"

sec "Boot chain"
cmd "cat /proc/cmdline"
cmd "bootctl status 2>/dev/null | grep -E 'Secure Boot|Firmware:|Product|Partition|Loader:|Stub:' | head -20; mokutil --sb-state 2>/dev/null"
cmd "lsblk -o NAME,SIZE,TRAN,SERIAL,FSTYPE,LABEL,MOUNTPOINTS"
cmd "grep -vh '^#' /etc/crypttab.initramfs /etc/crypttab 2>/dev/null; grep -v '^#' /etc/fstab | grep ."
cmd "swapon --show"

sec "Health"
cmd "systemctl --failed --no-legend"
cmd "journalctl -b -p err --no-pager -o short-iso | tail -60"
# Directories inside a home that root owns: the user's desktop cannot write its
# state there. A restore once left ~/.local and ~/.local/share root:root 700 while
# every other check PASSed; inspecting the restored drive found it.
while IFS=: read -r u _ uid _ _ hd _; do
    [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 60000 ] && [ -d "$hd" ] || continue
    ro=$(find "$hd" -xdev -maxdepth 4 -type d -uid 0 ! -name __pycache__ 2>/dev/null | head -20 | tr '\n' ' ')
    if [ -n "$ro" ]; then out "- **WARN: root-owned directories in $u's home** (the desktop cannot write there): \`$ro\`"
    else out "- PASS: no root-owned directories in $u's home"; fi
done < /etc/passwd

publish || true

sec "Network, Wi-Fi, Bluetooth"
cmd "nm-online -t 60 -q && echo 'online' || echo 'NOT online after 60 s'"
cmd "nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null"
cmd "rfkill list 2>/dev/null; bluetoothctl devices Paired 2>/dev/null | head"
cmd "getent hosts example.org || echo 'DNS failed'"

sec "Byte comparison against the test archive"
if [ -r /root/restore-test/manifest.tsv.gz ]; then
    python3 /root/restore-test/compare-manifest.py /root/restore-test/manifest.tsv.gz / >&3 2>&1
else out "(no manifest)"; fi

out ""; out "_report complete_"
publish || true
cp "$R" /root/restore-test/
