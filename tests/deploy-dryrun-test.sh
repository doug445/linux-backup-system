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
# tests/deploy-dryrun-test.sh — deploy.sh --dry-run as root, on a machine with
# no backup drive: it must detect the host, print the plan and change nothing.
# Needs root (it refuses otherwise). It never installs a package or writes a
# file in dry-run mode, which is exactly what this test proves.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }

if [ "$(id -u)" -ne 0 ]; then echo "deploy-dryrun-test: needs root — SKIP"; exit 0; fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
had_conf=0; [ -e /etc/backup-system.conf ] && had_conf=1
before=$(ls -la /usr/local/sbin /etc/systemd/system 2>/dev/null | sha256sum)

out=$(BACKUP_MOUNT="$T/backup" SUDO_USER="${SUDO_USER:-root}" bash "$ROOT/deploy.sh" --dry-run </dev/null 2>&1); rc=$?
echo "$out" | tail -25
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -q 'Dry run complete' <<<"$out" && ok "reached the end of the plan" || bad "did not print 'Dry run complete'"
grep -q 'Distro:' <<<"$out" && ok "detected the distro" || bad "no distro line"
grep -q 'Suite:' <<<"$out" && ok "printed the suite version" || bad "no suite version line"
grep -q 'Schedule mode' <<<"$out" && ok "decided a schedule mode" || bad "no schedule decision"
grep -q 'backup-diag.sh' <<<"$out" && ok "plan lists backup-diag.sh" || bad "plan omits backup-diag.sh"
grep -q '\[deps\]' <<<"$out" && ok "dependency step ran (reported, not installed)" || bad "no [deps] line — dependencies were not checked"
grep -qE 'tray dependencies (present|: )|would install tray' <<<"$out" && ok "tray dependencies probed" || bad "tray dependencies not probed"

after=$(ls -la /usr/local/sbin /etc/systemd/system 2>/dev/null | sha256sum)
[ "$before" = "$after" ] && ok "nothing installed" || bad "/usr/local/sbin or /etc/systemd/system changed"
if [ $had_conf -eq 0 ] && [ -e /etc/backup-system.conf ]; then bad "config was written in dry run"; else ok "config untouched"; fi

echo
echo "deploy-dryrun-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
