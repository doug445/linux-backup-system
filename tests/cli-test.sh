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

echo "== timeshift-backup.sh --prune-only: accepted, no snapshot planned, drive guard first"
out=$(BX_CONFIG=/dev/null BACKUP_MOUNT="$T/no-such-mount" TIMESHIFT_BACKUP_LOG="$T/ts.log" \
      bash "$ROOT/timeshift-backup.sh" --prune-only --dry-run 2>&1); rc=$?
if grep -q 'btrfs' <<<"$out" && [ "$rc" -eq 0 ]; then
    ok "btrfs root: layer skipped (exit 0)"
else
    [ "$rc" -eq 1 ] && grep -q 'is not mounted' <<<"$out" && ok "unmounted drive refused (exit 1) before any action" || bad "expected the drive guard to abort with 1: rc=$rc: $out"
fi
if grep -q 'would run: timeshift' <<<"$out"; then bad "--prune-only planned a snapshot"; else ok "no snapshot planned"; fi

echo "== borg --pattern values that start with '-' use the = form (argparse reads a bare '-x' as a flag)"
if grep -nE "\-\-pattern ['\"]-" "$ROOT"/*.sh >/dev/null 2>&1; then
    bad "bare --pattern '-…' found: $(grep -nE "\-\-pattern ['\"]-" "$ROOT"/*.sh | cut -d: -f1,2 | tr '\n' ' ')"
else
    ok "no bare --pattern '-…' in any script"
fi

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
grep -q 'ACTION=="remove".*systemctl --no-block start borg-backup-drive-detach.service' "$ROOT/99-borg-backup.rules" && ok "remove rule starts the detach UNIT (udevd PrivateMounts)" || bad "remove rule must start the detach unit, not run the script"
grep -q 'RUN+="/usr/local/sbin/' "$ROOT/99-borg-backup.rules" && bad "a RUN+= script in the udev rule would umount inside udevd's namespace" || ok "no direct RUN+= script in the udev rule"

echo "== every unit's ExecStart names a script this repo installs to that path"
for u in "$ROOT"/*.service; do
    exe=$(sed -n 's/^ExecStart=//p' "$u" | awk '{print $1}')
    case "$exe" in
        /usr/local/sbin/*.sh) [ -f "$ROOT/$(basename "$exe")" ] && ok "$(basename "$u") -> $exe" || bad "$(basename "$u") ExecStart names $exe which is not in the repo" ;;
        /usr/local/bin/*)     bad "$(basename "$u") ExecStart in /usr/local/bin — deploy installs scripts to /usr/local/sbin" ;;
        *)                    bad "$(basename "$u") unexpected ExecStart: $exe" ;;
    esac
done
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

echo "== tray: a backup counts as running only when one runs (not when a command line names it)"
# The tray's detection helpers, loaded with GTK stubbed out and pgrep fed
# synthetic process lists. Each case prints PASS/FAIL itself.
while IFS= read -r line; do
    case "$line" in PASS*) ok "tray: ${line#PASS }" ;; FAIL*) bad "tray: ${line#FAIL }" ;; *) [ -n "$line" ] && bad "tray probe: $line" ;; esac
done < <(INVOCATION_ID=cli-test BX_CONFIG="$T/none.conf" python3 - "$ROOT/backup-tray.py" 2>&1 <<'PY'
import re, sys, types
gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository")
for n in ("AppIndicator3", "GLib", "Gtk"):
    setattr(repo, n, types.SimpleNamespace())
sys.modules.update({"gi": gi, "gi.repository": repo})
ns = {"__name__": "tray"}
exec(open(sys.argv[1]).read().split("# ── Tray indicator")[0], ns)
fake = []
ns["pgrep"] = lambda pattern, full=True: [c for c in fake if re.search(pattern, c) and not ns["SHELL_C"].match(c)]
ns["unit_active"] = lambda unit: False
def case(desc, cmds, probe, want):
    fake[:] = cmds
    got = bool(ns[probe]()[0])
    print(("PASS " if got == want else "FAIL ") + f"{desc} (got {got})")
case("borg-backup.sh running",            ["/bin/bash /usr/local/sbin/borg-backup.sh"], "is_borg_running", True)
case("borg create under python",          ["/usr/bin/python /usr/bin/borg create --stats r::a /"], "is_borg_running", True)
case("btrfs send",                        ["btrfs send /.backup-snapshots/root_1"], "is_borg_running", True)
case("shell -c naming borg-backup.sh",    ["/usr/bin/zsh -c sudo /usr/local/sbin/borg-backup.sh"], "is_borg_running", False)
case("editor/pager on borg-backup.sh",    ["vim borg-backup.sh", "less /usr/local/sbin/borg-backup.sh"], "is_borg_running", False)
case("grep for 'borg create'",            ["grep borg create /var/log/borg-backup.log"], "is_borg_running", False)
case("backintime-backup.sh running",      ["bash /usr/local/sbin/backintime-backup.sh"], "is_bit_running", True)
case("Back In Time GUI job",              ["/usr/bin/python3 -Es /usr/share/backintime/common/backintime.py backup-job"], "is_bit_running", True)
case("idle Back In Time serviceHelper",   ["/usr/bin/python -Es /usr/share/backintime/qt/serviceHelper.py"], "is_bit_running", False)
case("tail of the BIT log",               ["tail -f /var/log/backintime-backup.log"], "is_bit_running", False)
case("timeshift --create",                ["timeshift --create --scripted --comments x"], "is_timeshift_running", True)
case("idle timeshift-gtk",                ["timeshift-gtk"], "is_timeshift_running", False)
case("backup-verify.sh running",          ["bash /usr/local/sbin/backup-verify.sh"], "is_verify_running", True)
case("sudo line alone is not the run",    ["sudo /usr/local/sbin/backup-verify.sh"], "is_verify_running", False)
print(("PASS " if ns["mount_is_live"]("/nonexistent-lbs-mount") is False else "FAIL ") + "a directory that is not a mount is not the drive")
print(("PASS " if ns["mount_is_live"]("/") is True else "FAIL ") + "a live mount is the drive")
PY
)

echo "== deploy: rc functions and an existing Back In Time config are updated in place, never clobbered"
# The two helpers, lifted out of deploy.sh and run against scratch files.
sed -n '/^add_shell_function()/,/^}/p;/^generate_bit_config()/,/^}/p' "$ROOT/deploy.sh" > "$T/deploy-fns.sh"
printf 'log(){ echo "LOG: $*"; }\nwarn(){ echo "WARN: $*"; }\n' >> "$T/deploy-fns.sh"
printf '# mine\nalias ll="ls -l"\ntimeback() { sudo borgmatic create; }\n\n# bitback — added by backup-system deploy\nbitback() {\n    old body\n}\n' > "$T/rc"
out=$(bash -c "source '$T/deploy-fns.sh'
add_shell_function '$T/rc' timeback 'timeback() {
    new
}'
add_shell_function '$T/rc' bitback 'bitback() {
    new body
}'
add_shell_function '$T/rc' bitback 'bitback() {
    new body
}'
add_shell_function '$T/rc' snapback 'snapback() {
    s
}'" 2>&1)
grep -q 'WARN:.*timeback() is already defined' <<<"$out" && grep -q 'sudo borgmatic create' "$T/rc" && ok "a foreign timeback() is left alone and named" || bad "foreign timeback(): $out"
grep -q 'Updated bitback()' <<<"$out" && grep -q '    new body' "$T/rc" && ! grep -q 'old body' "$T/rc" && ok "the deploy's own bitback() block is rewritten when its body changed" || bad "bitback update: $out"
grep -q 'bitback() in rc is current' <<<"$out" && [ "$(grep -c '^bitback()' "$T/rc")" = 1 ] && ok "an unchanged block is left as one copy" || bad "bitback idempotency: $(grep -c '^bitback()' "$T/rc") copies"
grep -q 'Added snapback()' <<<"$out" && grep -q '^snapback()' "$T/rc" && grep -q '^alias ll=' "$T/rc" && ok "a new function is appended; the rest of the file survives" || bad "snapback add: $out"

printf 'config.version=6\nprofile1.name=Full System Backup\nprofile1.snapshots.path=/mnt/borg-backup/backintime\nprofile1.snapshots.exclude.99.value=/my/custom\nprofile1.schedule.mode=1\n' > "$T/bit.cfg"
out=$(BX_BIT_CONFIG="$T/bit.cfg" BACKUP_MOUNT=/mnt/backup DRIVE_SETUP_DONE=0 HAS_ECRYPTFS=false HAS_BTRFS=true SUDO_USER=u \
      bash -c "source '$T/deploy-fns.sh'; generate_bit_config; echo rc=\$?" 2>&1)
grep -q '^profile1.snapshots.path=/mnt/backup/backintime$' "$T/bit.cfg" && ok "existing BIT config: snapshots.path re-pointed at the backup drive" || bad "BIT path not updated: $(grep snapshots.path "$T/bit.cfg")"
grep -q '^profile1.schedule.mode=0$' "$T/bit.cfg" && ok "existing BIT config: BIT's own scheduler turned off" || bad "schedule.mode not zeroed"
grep -q '^profile1.snapshots.exclude.99.value=/my/custom$' "$T/bit.cfg" && [ "$(grep -c '^profile1.name=' "$T/bit.cfg")" = 1 ] && ok "existing BIT config: hand-tuned lines kept, nothing regenerated" || bad "BIT config was regenerated"
grep -q 'rc=1' <<<"$out" && grep -q 'kept; updated' <<<"$out" && ok "kept config reports rc=1 (caller does not claim to have written it)" || bad "kept-config rc/log: $out"
out=$(BX_BIT_CONFIG="$T/bit.cfg" BACKUP_MOUNT=/mnt/backup DRIVE_SETUP_DONE=0 HAS_ECRYPTFS=false HAS_BTRFS=true SUDO_USER=u \
      bash -c "source '$T/deploy-fns.sh'; generate_bit_config; echo rc=\$?" 2>&1)
grep -q 'left as-is' <<<"$out" && ok "second run: config already current, left as-is" || bad "second run: $out"
rm -f "$T/bit.cfg"
out=$(BX_BIT_CONFIG="$T/bit.cfg" BACKUP_MOUNT=/mnt/backup DRIVE_SETUP_DONE=0 HAS_ECRYPTFS=false HAS_BTRFS=true SUDO_USER=u \
      bash -c "source '$T/deploy-fns.sh'; generate_bit_config; echo rc=\$?" 2>&1)
grep -q 'rc=0' <<<"$out" && grep -q '^profile1.snapshots.path=/mnt/backup/backintime$' "$T/bit.cfg" && grep -q '/.backup-snapshots/' "$T/bit.cfg" && ok "no config: a fresh one is generated (rc=0) with the btrfs excludes" || bad "fresh BIT config: $out"

echo "== deploy: the verify unit carries the configured BORG_REPO, not the default"
if grep -q 'Environment=\(BORG_REPO\|BACKUP_MOUNT\)=' "$ROOT"/*.service; then bad "a unit still carries Environment=BORG_REPO/BACKUP_MOUNT (outranks the config): $(grep -l 'Environment=\(BORG_REPO\|BACKUP_MOUNT\)=' "$ROOT"/*.service | tr '\n' ' ')"; else ok "no unit pins BORG_REPO/BACKUP_MOUNT over the config"; fi
grep -q 'Environment=BORG_REPO' "$ROOT/deploy.sh" && bad "deploy.sh still templates Environment=BORG_REPO" || ok "deploy.sh does not template Environment=BORG_REPO"
grep -q '^RequiresMountsFor' "$ROOT/luks-header-backup.service" && bad "luks-header-backup.service requires the drive (it must run without it)" || ok "luks-header-backup.service runs with the drive absent"
grep -q '^MemoryMax=' "$ROOT/borg-backup.service" && bad "borg-backup.service still uses MemoryMax (kills borg on big trees)" || ok "borg-backup.service throttles (MemoryHigh) instead of killing"
grep -v '^#' "$ROOT/99-borg-backup.rules" | grep -q 'UDISKS_AUTO_CLEAR' && bad "udev rule uses UDISKS_AUTO_CLEAR (not a udisks property)" || ok "udev rule uses real udisks properties"
grep -q '@BACKUP_FS_UUID@' "$ROOT/99-borg-backup.rules" && ok "udev rule covers the filesystem UUID too" || bad "udev rule ignores the inner filesystem UUID"
grep -q 'BORG_REPO=\\\$(. /etc/backup-system.conf' "$ROOT/deploy.sh" && ok "timeback() resolves BORG_REPO from the config at call time" || bad "timeback() hardcodes the repo path"

echo "== version stamp"
v=$(sed -n 's/^BX_VERSION="\(.*\)"/\1/p' "$ROOT/backup-common.sh")
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "BX_VERSION=$v is semver" || bad "BX_VERSION '$v'"
grep -q "linux-backup-system $v\|Version:\*\* $v" "$ROOT/README.md" && ok "README carries $v" || bad "README does not carry version $v"
grep -q "linux-backup-system $v" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md" && ok "SECURITY/CONTRIBUTING carry $v" || bad "SECURITY/CONTRIBUTING version stamp mismatch"

echo
echo "cli-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
