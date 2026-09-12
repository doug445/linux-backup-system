#!/usr/bin/env python3
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
"""Idempotently apply the three correctness fixes to snapper-replicate.sh.

Fix 1 -- the replication treadmill.
    The send loop walks every source snapshot and sends any not on the backup;
    the prune then keeps only the N highest-numbered. When the source retains
    more snapshots than the backup keeps, the difference is re-sent and
    re-deleted on EVERY run, forever. Guard: skip snapshots older than the
    newest already on the backup, since the prune would drop them anyway.

Fix 2 -- truncated receives adopted as incremental parents.
    The "already replicated" test was `[[ -d .../snapshot ]]`. An interrupted
    `btrfs receive` leaves a read-write subvolume with no received_uuid, which
    that test happily accepts -- and the next run uses it as the parent for
    everything after, silently corrupting the chain. Guard: require a
    received_uuid, else delete and re-send.

Fix 3 -- retention. KEEP must be >= the source snapshot count or the oldest
    source snapshots are never covered by the backup.

Safe to re-run: each fix is applied only if absent. If the host's script does
not match the expected shape, that fix is reported as SKIPPED and nothing is
written, rather than guessing.

Exit: 0 = script is fully patched (now or already), 1 = something needed
manual attention.
"""
import os
import re
import shutil
import sys
import time

PATH = os.environ.get("SNAPPER_REPLICATE", "/usr/local/sbin/snapper-replicate.sh")
KEEP_DEFAULT = os.environ.get("SNAPPER_KEEP", "30")

SKIP_GUARD = '''        # Older than the newest snapshot already on the backup: the prune
        # step below keeps only the highest-numbered ones, so sending this
        # would only get it deleted again at the end of the run. Skipping
        # also keeps every send a forward diff.
        if [[ -n "$latest_remote" ]] && (( num < latest_remote )); then
            continue
        fi

'''

RO_ANCHOR = "        # Ensure source is read-only (snapper snapshots should be)\n"

OLD_SKIP = (
    "        # Skip if already replicated\n"
    '        if [[ -d "$dest_snap_dir/snapshot" ]]; then\n'
    '            latest_remote="$num"\n'
    "            continue\n"
    "        fi\n"
)

NEW_SKIP = (
    "        # Skip if already replicated. An interrupted receive leaves the\n"
    "        # subvolume read-write with no received_uuid; that is not a usable\n"
    "        # incremental parent, so drop it and send this snapshot again.\n"
    '        if [[ -d "$dest_snap_dir/snapshot" ]]; then\n'
    '            if btrfs subvolume show "$dest_snap_dir/snapshot" 2>/dev/null'
    " | grep -qE 'Received UUID:[[:space:]]+[0-9a-f]{8}-'; then\n"
    '                latest_remote="$num"\n'
    "                continue\n"
    "            fi\n"
    '            log "$config/$num: incomplete receive on backup, re-sending"\n'
    '            btrfs subvolume delete "$dest_snap_dir/snapshot" 2>>"$LOG"\n'
    "        fi\n"
)

results = []


def report(name, status, detail=""):
    results.append((name, status, detail))
    suffix = f" -- {detail}" if detail else ""
    print(f"  {name:<28} {status}{suffix}")


def main():
    if not os.path.exists(PATH):
        print(f"  {PATH} not present; nothing to patch")
        return 0

    with open(PATH) as f:
        src = f.read()
    original = src

    # --- Fix 2: completed-receive check -------------------------------------
    if "Received UUID:[[:space:]]" in src:
        report("incomplete-receive guard", "ALREADY PRESENT")
    elif src.count(OLD_SKIP) == 1:
        src = src.replace(OLD_SKIP, NEW_SKIP)
        report("incomplete-receive guard", "APPLIED")
    else:
        report("incomplete-receive guard", "SKIPPED", "expected block not found")

    # --- Fix 1: skip-older guard --------------------------------------------
    if "num < latest_remote" in src:
        report("treadmill skip guard", "ALREADY PRESENT")
    elif src.count(RO_ANCHOR) == 1:
        src = src.replace(RO_ANCHOR, SKIP_GUARD + RO_ANCHOR)
        report("treadmill skip guard", "APPLIED")
    else:
        report("treadmill skip guard", "SKIPPED", "anchor not found")

    # --- Fix 3: retention ----------------------------------------------------
    if re.search(r"^KEEP=", src, re.MULTILINE):
        cur = re.search(r"^KEEP=(\d+)", src, re.MULTILINE)
        current = cur.group(1) if cur else "?"
        report("KEEP retention", "ALREADY PRESENT", f"KEEP={current}")
    else:
        m = re.search(r'^LOG="[^"]*"\n', src, re.MULTILINE)
        if m and re.search(r"\(\( count > 10 \)\)", src):
            src = src[: m.end()] + (
                "\n# Snapshots to retain on the backup drive, per config. Keep this >= the\n"
                "# source retention (snapper NUMBER_LIMIT) or the oldest source snapshots\n"
                "# are never covered by the backup.\n"
                f"KEEP={KEEP_DEFAULT}\n"
            ) + src[m.end():]
            src = src.replace("(( count > 10 ))", "(( count > KEEP ))")
            src = src.replace("head -n $((count - 10))", "head -n $((count - KEEP))")
            src = src.replace(
                "# Prune: keep only last 10 on backup drive",
                "# Prune: keep only last $KEEP on backup drive",
            )
            src = src.replace(
                "# Keeps last 10 snapshots on backup drive",
                "# Keeps last $KEEP snapshots on backup drive",
            )
            report("KEEP retention", "APPLIED", f"KEEP={KEEP_DEFAULT}")
        else:
            report("KEEP retention", "SKIPPED", "prune block not in expected form")

    if src == original:
        print("  no changes needed")
    else:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        bak = f"{PATH}.bak-{stamp}"
        shutil.copy2(PATH, bak)
        with open(PATH, "w") as f:
            f.write(src)
        print(f"  wrote {PATH} (backup: {bak})")

    return 1 if any(s == "SKIPPED" for _, s, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
