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
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
# Defined here: without it `expect` is the Tcl program of that name, which
# silently checks nothing.
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
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

echo "== deploy: an unlabeled backup drive is found by what is on it, a borg-lookalike directory is not"
mkdir -p "$T/fbc/media/My Drive/borg-backup" "$T/fbc/data/borg-backup"; : > "$T/fbc/media/My Drive/borg-backup/config"
eval "$(sed -n '/^find_backup_by_contents() {/,/^}/p' "$ROOT/deploy.sh")"
findmnt() { printf '%s %s\n' "$T/fbc/data" /dev/sdz1 "$T/fbc/media/My\\x20Drive" '/dev/mapper/luks-x[/]'; }
r=$(find_backup_by_contents); expect "found: the mount holding a borg repository (escaped space decoded)" "$T/fbc/media/My Drive" "${r#*$'\t'}"
expect "found: its source, subvolume suffix dropped" /dev/mapper/luks-x "${r%%$'\t'*}"
findmnt() { printf '%s %s\n' "$T/fbc/data" /dev/sdz1 / /dev/nvme0n1p3; }
find_backup_by_contents >/dev/null && bad "a borg-backup directory without a repository config was taken for a drive" || ok "no repository config, no drive"
eval "$(sed -n '/^adopt_label_mount() {/,/^}/p' "$ROOT/deploy.sh")"
findmnt() { case "$*" in *--mountpoint*/mnt/backup*) echo '/dev/mapper/luks-x[/]' ;; esac; }
out=$(DRY=1 WAITING_FOR_DRIVE=0; : "$DRY"; log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }
      adopt_label_mount /dev/mapper/luks-x "/media/u/My Drive"; echo "M=$BACKUP_MOUNT W=$WAITING_FOR_DRIVE")
grep -q 'M=/mnt/backup W=0' <<<"$out" && ! grep -q WARN <<<"$out" && ok "a drive also mounted at /mnt/backup is used there, not waited for" || bad "desktop automount beside /mnt/backup: $out"
unset -f findmnt find_backup_by_contents adopt_label_mount

echo "== deploy: a running backup is judged by its lock, never by a command line that names the script"
sed -n '/^backup_lock_held()/,/^}/p' "$ROOT/deploy.sh" > "$T/lockfn.sh"
out=$(BX_LOCK_FILE="$T/lbs.lock" bash -c "source '$T/lockfn.sh'; : /usr/local/sbin/borg-backup.sh; backup_lock_held && echo held || echo free")
expect_free=$out
[ "$expect_free" = free ] && ok "no lock held: free (even though this shell's command line names borg-backup.sh)" || bad "lock guard: $out"
( exec 9>"$T/lbs.lock"; flock -n 9; sleep 3 ) & lpid=$!; sleep 1
out=$(BX_LOCK_FILE="$T/lbs.lock" bash -c "source '$T/lockfn.sh'; backup_lock_held && echo held || echo free")
wait "$lpid"
[ "$out" = held ] && ok "a held lock: running" || bad "held lock not seen: $out"

echo "== restore-rebuild-boot.sh: RESTORE_NO_NVRAM=1 writes no firmware boot entry"
grep -q -- '--no-variables install' "$ROOT/restore-rebuild-boot.sh" && ok "systemd-boot path has a --no-variables install" || bad "no --no-variables bootctl path"
grep -q -- '--no-nvram --removable' "$ROOT/restore-rebuild-boot.sh" && ok "GRUB path installs --no-nvram --removable" || bad "no --no-nvram GRUB path"
sed -n '/^efi_boot_entry()/,/^}/p' "$ROOT/restore-rebuild-boot.sh" | grep -q 'NO_NVRAM" = 1' && ok "efibootmgr entry creation is skipped" || bad "efi_boot_entry ignores NO_NVRAM"
echo "== restore-rebuild-boot.sh: a grub.cfg beside systemd-boot is GRUB only if the ESP holds a GRUB image"
blk=$(awk '/^# Both found on a UEFI host/{f=1} f; f && /^fi$/{exit}' "$ROOT/restore-rebuild-boot.sh")
mkdir -p "$T/gesp/EFI/systemd" "$T/gesp/EFI/BOOT"
printf 'MZ shim MokListRT' > "$T/gesp/EFI/systemd/systemd-bootx64.efi"; printf 'MZ #### LoaderInfo: systemd-boot 255' > "$T/gesp/EFI/systemd/grubx64.efi"
cp "$T/gesp/EFI/systemd/grubx64.efi" "$T/gesp/EFI/BOOT/BOOTX64.EFI"
r=$(USES_GRUB=true USES_SDBOOT=true IS_EFI=true ESP="$T/gesp"; say() { :; }; : "$USES_SDBOOT$IS_EFI$ESP"; eval "$blk"; echo "$USES_GRUB")
expect "systemd-boot behind shim, no GRUB image: GRUB left alone (Mint with grub packages)" false "$r"
printf 'MZ grub rescue> ' > "$T/gesp/EFI/BOOT/core.efi"
r=$(USES_GRUB=true USES_SDBOOT=true IS_EFI=true ESP="$T/gesp"; say() { :; }; : "$USES_SDBOOT$IS_EFI$ESP"; eval "$blk"; echo "$USES_GRUB")
expect "a bare grub-install core on the ESP: GRUB is in use" true "$r"
r=$(USES_GRUB=true USES_SDBOOT=false IS_EFI=true ESP="$T/gesp/none"; say() { :; }; : "$USES_SDBOOT$IS_EFI$ESP"; eval "$blk"; echo "$USES_GRUB")
expect "no systemd-boot: a grub.cfg still means GRUB" true "$r"
grep -q "grep -qsE 'ukify" "$ROOT/restore-rebuild-boot.sh" && grep -q 'update-initramfs) debian_initramfs_all' "$ROOT/restore-rebuild-boot.sh" \
    && ok "UKIs built by a Debian initramfs/postinst hook are rebuilt through update-initramfs" || bad "hook-built UKIs are not rebuilt"
sb=$(awk '/sign-all fails as a whole/{f=1} f; f && /^    fi$/{exit}' "$ROOT/restore-rebuild-boot.sh")
r=$(DRY=""; say() { echo "SAY $*"; }; warn() { echo "WARN $*"; }; sbctl() { printf 'failed signing /boot/EFI/Linux/a.efi: /boot/EFI/Linux/a.efi does not exist\n✓ Signed /efi/EFI/BOOT/BOOTX64.EFI\n'; return 1; }; eval "$sb")
grep -q '^SAY .*no longer there.*a.efi' <<<"$r" && ! grep -q '^WARN' <<<"$r" && ok "sbctl: entries for deleted files are named, not a signing failure" || bad "sbctl gone-files: $r"
r=$(DRY=""; say() { echo "SAY $*"; }; warn() { echo "WARN $*"; }; sbctl() { printf 'failed signing /boot/EFI/Linux/a.efi: /boot/EFI/Linux/a.efi does not exist\nfailed signing /efi/x.efi: permission denied\n'; return 1; }; eval "$sb")
grep -q '^WARN sbctl sign-all reported errors' <<<"$r" && ok "sbctl: a real signing failure still warns" || bad "sbctl real failure: $r"

for r in '/_entry_for_mount() {/,/^    }/p' '/^_crypt_under() {/,/^}/p' '/^release_crypttab() {/,/^fi$/p'; do
    a=$(sed -n "$r" "$ROOT/borg-restore.sh"); b=$(sed -n "$r" "$ROOT/backintime-restore.sh")
    [ -n "$a" ] && [ "$a" = "$b" ] && ok "restore scripts share the crypttab pairing code: ${r%%/,*}/" || bad "borg and Back In Time restores differ in ${r%%/,*}/"
done
for f in borg-restore.sh backintime-restore.sh; do
    grep -q 'mount -o remount,bind,ro "$TARGET/sys/firmware/efi/efivars"' "$ROOT/$f" && grep -q 'env RESTORE_NO_NVRAM="$RESTORE_NO_NVRAM"' "$ROOT/$f" \
        && ok "$f: efivars read-only in the chroot and the mode passed in when run from an installed system" || bad "$f: NVRAM guard missing"
done

echo "== any shell: bash shebang via env, re-exec guard, library guard, helpers that parse in bash, zsh and fish"
bad_sb=$(for f in $(cd "$ROOT" && git ls-files '*.sh' 2>/dev/null || ls ./*.sh tests/*.sh); do head -1 "$ROOT/$f" | grep -qx '#!/usr/bin/env bash' || echo "$f"; done)
[ -z "$bad_sb" ] && ok "every script starts #!/usr/bin/env bash (no /bin/bash: NixOS, Guix)" || bad "shebangs: $bad_sb"
noguard=$(for f in $(cd "$ROOT" && git ls-files '*.sh' 2>/dev/null); do
    first_set=$(grep -n '^set -' "$ROOT/$f" | head -1 | cut -d: -f1); g=$(grep -n 'BASH_VERSION:-}" \] ||' "$ROOT/$f" | head -1 | cut -d: -f1)
    { [ -n "$g" ] && { [ -z "$first_set" ] || [ "$g" -lt "$first_set" ]; }; } || echo "$f"; done)
[ -z "$noguard" ] && ok "every script checks for bash before its first set -o (dash dies on pipefail)" || bad "no guard before set: $noguard"
if command -v zsh >/dev/null; then
    out=$(cd "$ROOT" && zsh ./deploy.sh --help 2>&1); grep -q Usage <<<"$out" && ok "zsh ./deploy.sh --help re-execs under bash" || bad "zsh deploy.sh: $out"
    (cd "$ROOT" && zsh ./borg-backup.sh --bogus-flag >/dev/null 2>&1); expect "zsh ./borg-backup.sh --bogus-flag -> 2 (ran as bash)" 2 "$?"
    out=$(cd "$ROOT" && zsh -c '. ./backup-common.sh; echo sourced-rc=$?' 2>&1)
    grep -q 'needs bash' <<<"$out" && grep -q 'sourced-rc=1' <<<"$out" && ok "sourcing the library from zsh refuses with a message" || bad "zsh source: $out"
fi
for sh_ in dash "busybox sh"; do
    command -v ${sh_%% *} >/dev/null || continue
    out=$(cd "$ROOT" && $sh_ ./deploy.sh --help 2>&1); grep -q Usage <<<"$out" && ok "$sh_ ./deploy.sh --help re-execs under bash" || bad "$sh_ deploy.sh: $out"
done
# helper_sh's heredocs contain lines that are just "}", so extract whole
# function ranges by their neighbours, not by the first closing brace.
awk '/^helper_sh\(\)/{f=1} /^add_fish_function\(\)/{f=0} f' "$ROOT/deploy.sh" > "$T/helpers.sh"
for n in timeback bitback snapback; do
    bash -c ". '$T/helpers.sh'; helper_sh $n '/mnt/my backup'" > "$T/h-$n.sh"
    bash -n "$T/h-$n.sh" && ok "$n: bash parses it" || bad "$n: bash -n failed"
    if command -v zsh >/dev/null; then zsh -n "$T/h-$n.sh" && ok "$n: zsh parses it" || bad "$n: zsh -n failed"; fi
    grep -q "mountpoint -q '/mnt/my backup'" "$T/h-$n.sh" || [ "$n" = snapback ] && ok "$n: a mount path with a space stays one argument" || bad "$n: unquoted mount"
    if command -v fish >/dev/null; then
        bash -c ". '$T/helpers.sh'; helper_fish $n '/mnt/my backup'" > "$T/h-$n.fish"
        fish --no-execute "$T/h-$n.fish" 2>"$T/fish.err" && ok "$n: fish parses its .fish file" || bad "$n: fish: $(cat "$T/fish.err")"
    fi
done

echo "== restore test bed: help, root refusal, hard-link-aware byte comparison"
out=$(bash "$ROOT/testbed/testbed.sh" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'Usage: sudo testbed/testbed.sh' <<<"$out" && ! grep -qE '^(set -|TB_DIR=)' <<<"$out" && ok "testbed.sh --help prints the usage block only" || bad "testbed --help: rc=$rc"
grep -q 'passphrase "test"' <<<"$out" && ok "the help states the fixed test-drive passphrase" || bad "help does not state the test passphrase"
if [ "$(id -u)" -ne 0 ]; then
    bash "$ROOT/testbed/testbed.sh" status >/dev/null 2>&1; expect "testbed.sh as a normal user refuses (exit 1)" 1 "$?"
fi
grep -q 'TB_PASSPHRASE' "$ROOT/borg-restore.sh" "$ROOT/backintime-restore.sh" "$ROOT/restore.sh" "$ROOT/deploy.sh" && bad "a real restore/deploy script references the test passphrase" || ok "no real restore or deploy script carries a passphrase"
# The Mac firmware menu showed the test drive exactly like the host's disk (the
# restored volume icon and label): finish labels it TEST and parks the icon.
tb_fn() { awk -v n="$1() {" '$0==n {p=1} p {print} p && /^}$/ {exit}' "$ROOT/testbed/testbed.sh"; }
grep -qx '    mark_test_drive_picker' <<<"$(awk '/^cmd_finish\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")" && ok "finish labels the test drive in the firmware boot menu" || bad "cmd_finish does not call mark_test_drive_picker"
grep -qx '    preflight_grub_unlock' <<<"$(awk '/^cmd_finish\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")" && ok "finish checks GRUB opens the test drive with the passphrase before the boot" || bad "cmd_finish does not call preflight_grub_unlock"
# vmboot: the test drive boots in QEMU before a real reboot, never writing to it
vmb=$(awk '/^cmd_vmboot\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")
grep -q 'snapshot=on' <<<"$vmb" && ok "vmboot attaches the test drive with snapshot=on (nothing written to it)" || bad "vmboot does not use snapshot=on"
grep -q -- '-nic none' <<<"$vmb" && ok "vmboot gives the VM no network (restored homes hold real logins)" || bad "vmboot VM has a network"
grep -q 'serial=\$TB_TARGET_SERIAL' <<<"$vmb" && ok "vmboot's virtual disk carries the test drive's serial (logger PASS check)" || bad "vmboot disk has no serial"
grep -q 'REPORT_PARTUUID' <<<"$vmb" && ok "vmboot gives the logger a report disk with the report PARTUUID" || bad "vmboot has no report disk"
grep -qx '    vmboot)      cmd_vmboot ;;' "$ROOT/testbed/testbed.sh" && ok "testbed.sh vmboot is a command" || bad "vmboot not dispatched"
grep -q 'cmd_vmboot' <<<"$(awk '/^cmd_finish\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")" && ok "finish runs the VM boot before saying the drive is ready" || bad "finish does not run vmboot"
grep -q 'vmboot=' "$ROOT/backup-diag.sh" && grep -q 'VM boot of the test drive' "$ROOT/backup-diag.sh" && ok "the troubleshooting report carries the VM boot verdict" || bad "backup-diag.sh has no VM boot section"
# The report disk is read through mtools, from the image file: a loop device every
# poll popped the desktop's device notifier up every 30 s.
if command -v sgdisk >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 && command -v mkfs.vfat >/dev/null 2>&1; then
    ri="$T/report.img"; truncate -s 64M "$ri"; sgdisk -n 1:0:0 -t 1:0700 "$ri" >/dev/null
    rf=$(sgdisk -i 1 "$ri" | awk '/^First sector/{print $3}'); rl=$(sgdisk -i 1 "$ri" | awk '/^Last sector/{print $3}')
    mkfs.vfat --offset "$rf" "$ri" $(( (rl - rf + 1) / 2 )) >/dev/null 2>&1
    printf 'x\n_report complete_\n' > "$T/br.md"
    MTOOLS_SKIP_CHECK=1 mmd -i "$ri@@$((rf * 512))" ::/restore-test-h-1 && MTOOLS_SKIP_CHECK=1 mcopy -i "$ri@@$((rf * 512))" "$T/br.md" ::/restore-test-h-1/boot-report-1.md
    ( losetup() { echo "losetup called" >&2; return 1; }; eval "$(awk '/^vm_report_read\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")"; vm_report_read "$ri" "$T/rr" ) 2>"$T/rr.err"
    grep -q '_report complete_' "$T/rr/boot-report-1.md" 2>/dev/null && ! grep -q 'losetup called' "$T/rr.err" \
        && ok "vmboot reads the report disk from the image file (mtools), no loop device" || bad "report disk read: $(cat "$T/rr.err")"
fi
# GRUB runs a built-in config through its rescue parser: plain commands only. An
# `if … fi` there unlocked nothing and the test boot stopped at grub>.
# shellcheck disable=SC2034  # read by the eval'd testbed function
ecfg=$( TB_TARGET_SERIAL=SERIAL1; TB_PASSPHRASE="test"; eval "$(tb_fn grub_early_cfg)"; grub_early_cfg bbbb-boot bbbb-boot rrrr-root )
grep -q 'TEST DRIVE' <<<"$ecfg" && ok "the auto-unlock loader announces itself as the TEST DRIVE" || bad "early config has no TEST DRIVE banner: $ecfg"
expect "early config: /boot first, then the other container, each once, with -p" "cryptomount -u bbbb-boot -p test|cryptomount -u rrrr-root -p test" "$(grep '^cryptomount' <<<"$ecfg" | paste -sd'|')"
grep -vE '^(echo|cryptomount|set|insmod|search|sleep) ' <<<"$ecfg" | grep -q . && bad "early config has a line GRUB's rescue parser cannot run: $(grep -vE '^(echo|cryptomount|set|insmod|search|sleep) ' <<<"$ecfg")" || ok "early config: plain commands only (rescue parser — no if/then/fi, &&, ||, braces)"
grep -qE '(^|[; ])(if|then|else|fi|for|while|do|done)([; ]|$)|&&|\|\||[{}]' <<<"$ecfg" && bad "early config uses shell control flow" || ok "early config: no shell control flow"
P="$T/picker"; mkdir -p "$P/boot/efi/EFI/BOOT"; printf 'icon' > "$P/boot/efi/.VolumeIcon.icns"; printf 'main-nvme' > "$P/boot/efi/EFI/BOOT/.disk_label.contentDetails"
# shellcheck disable=SC2034  # read by the eval'd testbed function
out=$( TB_MNT="$P"; TB_STATE="$T/pstate"
       layout() { case "$1" in FIRMWARE) echo uefi ;; ESP_MOUNT) echo /boot/efi ;; esac; }
       say() { echo "say: $*"; }; warn() { echo "warn: $*"; }; ledger() { :; }
       eval "$(tb_fn mark_test_drive_picker)"; mark_test_drive_picker 2>&1 )
[ ! -e "$P/boot/efi/.VolumeIcon.icns" ] && [ -f "$P/root/restore-test/VolumeIcon.icns.parked" ] && ok "picker: the restored volume icon is parked on the test drive" || bad "picker: volume icon not parked: $out"
expect "picker: .disk_label.contentDetails says TEST" "TEST" "$(cat "$P/boot/efi/EFI/BOOT/.disk_label.contentDetails")"
if command -v grub-render-label >/dev/null 2>&1 || command -v grub2-render-label >/dev/null 2>&1; then
    [ -s "$P/boot/efi/EFI/BOOT/.disk_label" ] && [ -s "$P/boot/efi/EFI/BOOT/.disk_label_2x" ] && [ "$(head -c1 "$P/boot/efi/EFI/BOOT/.disk_label" | od -An -tx1 | tr -d ' ')" = 01 ] \
        && ok "picker: a rendered Apple .disk_label (and _2x) for TEST" || bad "picker: no rendered label: $out"
fi
mkdir -p "$T/cm/usr/bin" "$T/cm/etc"
printf 'data-one\n' > "$T/cm/usr/bin/a"; ln "$T/cm/usr/bin/a" "$T/cm/usr/bin/a-link"
printf 'changed-longer\n' > "$T/cm/etc/state"; printf 'x\n' > "$T/cm/etc/same"
{ printf -- '-\t9\tusr/bin/a\n-\t0\tusr/bin/a-link\n-\t6\tetc/state\n-\t2\tetc/same\n-\t5\tetc/gone\nd\t0\tetc\n'; } | gzip > "$T/cm.tsv.gz"
out=$(python3 "$ROOT/testbed/compare-manifest.py" "$T/cm.tsv.gz" "$T/cm")
grep -q '| byte-identical size, same name | 2 |' <<<"$out" && ok "compare: same-size files counted" || bad "compare identical: $out"
grep -q '| hard-link names of a restored inode (borg lists them as 0 bytes) | 1 |' <<<"$out" && ok "compare: a hard link listed as 0 bytes is not a difference" || bad "compare hardlink: $out"
grep -q '| size differs | 1 |' <<<"$out" && grep -q '/etc/state' <<<"$out" && ok "compare: a changed file is named" || bad "compare differ: $out"
grep -q '| missing | 1 |' <<<"$out" && grep -q '^/etc/gone$' <<<"$out" && ok "compare: a missing file is named" || bad "compare missing: $out"

echo "== test bed fingerprint: a loader re-signed by the machine's own boot is the same code"
eval "$(sed -n "/^EFI_CODE_HASH='/,/^'\$/p" "$ROOT/testbed/testbed.sh")"
python3 - "$T/pe" <<'PY'
import struct, sys
d = sys.argv[1]
def image(sig):
    b = bytearray(512)
    b[0:2] = b"MZ"; struct.pack_into("<I", b, 0x3C, 64); b[64:68] = b"PE\0\0"
    opt = 64 + 24; struct.pack_into("<H", b, opt, 0x20B); b[300:320] = b"loader code here...."
    if sig:
        struct.pack_into("<I", b, opt + 64, len(sig))            # checksum changes too
        struct.pack_into("<II", b, opt + 112 + 32, len(b), len(sig))
        b += sig
    return bytes(b)
import os; os.makedirs(d, exist_ok=True)
open(d + "/u.efi", "wb").write(image(b""))
open(d + "/a.efi", "wb").write(image(b"SIGNATURE-ONE-xx"))
open(d + "/b.efi", "wb").write(image(b"SIGNATURE-TWO-yyyy"))
c = bytearray(image(b"SIGNATURE-ONE-xx")); c[305] ^= 1; open(d + "/c.efi", "wb").write(bytes(c))
PY
h=$(cd "$T/pe" && python3 -c "$EFI_CODE_HASH" a.efi b.efi u.efi c.efi | cut -d' ' -f1)
expect "two signatures of one image hash the same" "$(sed -n 1p <<<"$h")" "$(sed -n 2p <<<"$h")"
expect "the signed image hashes like the unsigned one" "$(sed -n 1p <<<"$h")" "$(sed -n 3p <<<"$h")"
[ "$(sed -n 1p <<<"$h")" != "$(sed -n 4p <<<"$h")" ] && ok "a changed code byte is a different hash" || bad "a code change was hidden by the signature-insensitive hash"
aw=$(sed -n "/fl=\$(efibootmgr -v/,/exit}')/p" "$ROOT/testbed/testbed.sh" | sed "1s/.*awk -v b=\"Boot\$cur\" -v u=\"\$espuuid\" '//; \$s/')\$//")
u=3332ce4a-8003-4816-b5c4-1fe9c0fc53dd
expect "firmware loader from efibootmgr 18's File(…) form" /EFI/systemd/systemd-bootx64.efi \
    "$(printf 'Boot0000* Linux Boot Manager\tHD(1,GPT,%s,0x800,0x90000)/File(\\EFI\\systemd\\systemd-bootx64.efi)\n' "$u" | awk -v b=Boot0000 -v u="$u" "$aw")"
expect "firmware loader from the bare …)/\\EFI\\… form" /EFI/fedora/shimx64.efi \
    "$(printf 'Boot0000* Fedora\tHD(1,GPT,%s,0x800,0x90000)/\\EFI\\fedora\\shimx64.efi\n' "$u" | awk -v b=Boot0000 -v u="$u" "$aw")"
py=$(sed -n "/python3 -c 'import re,sys/,/serial.log/p" "$ROOT/testbed/testbed.sh" | sed "1s/.*python3 -c 'import re,sys/import re,sys/; \$s/' \"\$vm.*//")
printf '\033[2J\033[01;01HBoot in 1s.\033[2J\033[01;01H' > "$T/ser-handoff"; printf '\033[2J\033[08;06H   Linux Mint (linuxmint.efi)   ' > "$T/ser-menu"
python3 -c "$py" "$T/ser-handoff" && ok "VM askpass: the loader has handed off — typing allowed" || bad "VM askpass: handoff not recognised"
python3 -c "$py" "$T/ser-menu" && bad "VM askpass: would type into the loader menu (edits an entry)" || ok "VM askpass: never types while the loader menu is on the console"
grep -q 'ROOT_UNLOCK=initramfs-tools' "$ROOT/testbed/testbed.sh" && ok "VM askpass: only for initramfs-tools unlocks (systemd reads the credential)" || bad "VM askpass gate missing"
nob=$(grep -nE '(^|[;&|(]|then|do)[[:space:]]*(echo y \| )?(vgchange|vgcreate|pvcreate|lvcreate|vgs|pvs|lvs|vgcfgbackup|vgcfgrestore|vgrename) ' "$ROOT/testbed/testbed.sh" \
      | grep -v 'TB_LVM' | grep -v 'root_src\|-S "vg_name=\$vg"' || true)
[ -z "$nob" ] && ok "test bed: every LVM command on the test drive writes no metadata backup to this host" || bad "LVM commands that write this host's /etc/lvm: $nob"
grep -q "sys_vendor" <<<"$(awk '/^mirror_firmware_entry\(\) \{/,/^}$/' "$ROOT/testbed/testbed.sh")" && ok "Acer firmware: no grubx64.efi on the test drive's fallback path (Linpus lite entry)" || bad "mirror_firmware_entry ignores Acer's Linpus lite entries"

echo "== version stamp"
v=$(sed -n 's/^BX_VERSION="\(.*\)"/\1/p' "$ROOT/backup-common.sh")
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "BX_VERSION=$v is semver" || bad "BX_VERSION '$v'"
grep -q "linux-backup-system $v\|Version:\*\* $v" "$ROOT/README.md" && ok "README carries $v" || bad "README does not carry version $v"
grep -q "linux-backup-system $v" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md" && ok "SECURITY/CONTRIBUTING carry $v" || bad "SECURITY/CONTRIBUTING version stamp mismatch"

echo
echo "cli-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
