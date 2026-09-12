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
# tests/cli-test.sh — every script's command line, without root and without a
# backup drive: --help prints the usage block (guards the sed line ranges that
# print it, which shift whenever a header grows), unknown arguments are refused
# with exit 2, and the read-only tools produce their reports.
#
# Also proves backup-diag.sh redacts: a synthetic config carries a full UUID,
# which must appear truncated by default and whole under --no-redact. And that
# restore-rebuild-boot.sh --dry-run executes nothing (every action line is a
# "would:" line). No disk is touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== --help prints the usage block, and only that"
for s in deploy.sh borg-backup.sh backintime-backup.sh timeshift-backup.sh backup-diag.sh; do
    out=$(bash "$ROOT/$s" --help 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then bad "$s --help exit $rc"; continue; fi
    if ! grep -q 'Usage' <<<"$out"; then bad "$s --help lacks a Usage line"; continue; fi
    if grep -qE '^(set -|[A-Z_]+=)' <<<"$out"; then bad "$s --help leaks code past the header"; continue; fi
    if grep -q 'SPDX-License' <<<"$out"; then bad "$s --help prints the license block"; continue; fi
    ok "$s --help"
done

echo "== unknown arguments are refused with exit 2"
for s in deploy.sh borg-backup.sh backintime-backup.sh timeshift-backup.sh backup-diag.sh; do
    bash "$ROOT/$s" --bogus-flag >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 2 ]; then ok "$s --bogus-flag -> 2"; else bad "$s --bogus-flag -> $rc"; fi
done

echo "== restore-rebuild-boot.sh --dry-run executes nothing"
out=$(bash "$ROOT/restore-rebuild-boot.sh" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -q 'distro=' <<<"$out" && ok "prints the detection line" || bad "no detection line: $out"
grep -q 'boot_on_luks=' <<<"$out" && ok "prints the boot-layout line" || bad "no boot-layout line"
if grep -qE '^\[rebuild-boot\] \+ ' <<<"$out"; then bad "an action was EXECUTED in dry run"; else ok "no executed actions"; fi

echo "== backup-diag.sh: read-only report with redaction"
cat > "$T/conf" <<'CONF'
BACKUP_MOUNT="/mnt/backup"
BACKUP_FS_UUID="deadbeef-1111-2222-3333-444455556666"
BACKUP_KEYFILE="/etc/luks-keys/test.key"
CONF
BX_CONFIG="$T/conf" bash "$ROOT/backup-diag.sh" -o "$T/r.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
for h in '# linux-backup-system troubleshooting report' '## Host' '## Tool inventory' '## Storage layout' '## Boot layout' \
         '## Suite configuration' "## What the suite's own detection reports" '## Units, timers and udev' '## Logs' '## Restore readiness'; do
    grep -qF "$h" "$T/r.md" && ok "section: $h" || bad "missing section: $h"
done
grep -q 'deadbeef-…' "$T/r.md" && ok "UUID truncated to 8 chars" || bad "UUID not truncated"
grep -q 'deadbeef-1111-2222' "$T/r.md" && bad "full UUID leaked" || ok "full UUID absent"
grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$T/r.md" && bad "some full UUID leaked" || ok "no full UUID anywhere"
grep -q 'contents never included\|cannot check without root\|does NOT exist' "$T/r.md" && ok "keyfile reported by path only" || bad "keyfile line missing"
grep -q 'distro family:' "$T/r.md" && ok "library detection block present" || bad "library detection block missing"
grep -q 'restore-rebuild-boot.sh --dry-run' "$T/r.md" && ok "boot-chain dry run embedded" || bad "boot-chain dry run missing"
BX_CONFIG="$T/conf" bash "$ROOT/backup-diag.sh" --no-redact -o "$T/n.md" >/dev/null 2>&1
grep -q 'deadbeef-1111-2222-3333-444455556666' "$T/n.md" && ok "--no-redact keeps the UUID whole" || bad "--no-redact still redacted"
out=$(BX_CONFIG="$T/conf" bash "$ROOT/backup-diag.sh" 2>/dev/null | head -1)
[ "$out" = '# linux-backup-system troubleshooting report' ] && ok "stdout mode" || bad "stdout mode: '$out'"

echo "== borg-backup-drive-detach.sh: safe when nothing is configured or present"
printf 'BACKUP_MOUNT="%s/mnt"\n' "$T" > "$T/empty.conf"
out=$(BX_CONFIG="$T/empty.conf" bash "$ROOT/borg-backup-drive-detach.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "no UUIDs configured -> exit 0" || bad "exit $rc: $out"
grep -q 'nothing to do' <<<"$out" && ok "says nothing to do" || bad "unexpected: $out"
printf 'BACKUP_MOUNT="%s/mnt"\nBACKUP_FS_UUID="deadbeef-1111-2222-3333-444455556666"\nBACKUP_LUKS_UUID="deadbeef-aaaa-bbbb-cccc-ddddeeeeffff"\n' "$T" > "$T/absent.conf"
out=$(BX_CONFIG="$T/absent.conf" bash "$ROOT/borg-backup-drive-detach.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "configured drive absent, nothing mounted -> exit 0" || bad "exit $rc: $out"
grep -q 'done' <<<"$out" && ok "completes without touching anything" || bad "unexpected: $out"
out=$(BX_CONFIG="$T/absent.conf" bash "$ROOT/borg-backup-drive-attach.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "attach with drive absent -> exit 0" || bad "attach exit $rc: $out"
grep -q 'not present' <<<"$out" && ok "attach says not present" || bad "unexpected: $out"

echo "== udev rule template"
grep -q 'ACTION=="remove".*borg-backup-drive-detach.sh' "$ROOT/99-borg-backup.rules" && ok "remove rule runs the detach script" || bad "no remove rule"
grep -q 'ACTION=="add|change".*borg-backup-drive-attach.service' "$ROOT/99-borg-backup.rules" && ok "add rule wants the attach unit" || bad "no add rule"
n=$(grep -c '@BACKUP_DEV_UUID@' "$ROOT/99-borg-backup.rules"); [ "$n" -ge 3 ] && ok "every rule line is templated ($n)" || bad "template placeholder count $n"
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
    sed 's/@BACKUP_DEV_UUID@/deadbeef-1111-2222-3333-444455556666/g' "$ROOT/99-borg-backup.rules" > "$T/99-test.rules"
    if udevadm verify --no-style "$T/99-test.rules" >/dev/null 2>&1; then ok "udevadm verify accepts the rule"; else bad "udevadm verify rejects the rule: $(udevadm verify --no-style "$T/99-test.rules" 2>&1 | head -3)"; fi
fi

echo "== backup-verify.sh and luks-header-backup.sh read /etc/backup-system.conf (BX_CONFIG) by themselves"
printf 'BACKUP_MOUNT="%s/cfgmount"\n' "$T" > "$T/verify.conf"
out=$(BX_CONFIG="$T/verify.conf" bash "$ROOT/backup-verify.sh" 2>&1 || true)
grep -q "$T/cfgmount" <<<"$out" && ok "verify uses the configured mount" || bad "verify ignored the config: $(grep -m1 'not mounted' <<<"$out")"
grep -q '/mnt/backup' <<<"$out" && bad "verify still mentions the /mnt/backup default" || ok "no /mnt/backup fallback leaked"
out=$(BX_CONFIG="$T/verify.conf" BACKUP_MOUNT="$T/envmount" bash "$ROOT/backup-verify.sh" 2>&1 || true)
grep -q "$T/envmount" <<<"$out" && ok "environment still overrides the config" || bad "environment did not override the config"
grep -q 'KEEP=${_env_keep:-6}' "$ROOT/luks-header-backup.sh" && ok "luks-header-backup keeps its own KEEP default" || bad "luks-header-backup KEEP default lost"

echo "== version stamp"
v=$(sed -n 's/^BX_VERSION="\(.*\)"/\1/p' "$ROOT/backup-common.sh")
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "BX_VERSION=$v is semver" || bad "BX_VERSION '$v'"
grep -q "linux-backup-system $v\|Version:\*\* $v" "$ROOT/README.md" && ok "README carries $v" || bad "README does not carry version $v"
grep -q "linux-backup-system $v" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md" && ok "SECURITY/CONTRIBUTING carry $v" || bad "SECURITY/CONTRIBUTING version stamp mismatch"

echo
echo "cli-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
