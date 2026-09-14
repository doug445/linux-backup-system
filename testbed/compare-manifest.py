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
"""compare-manifest.py MANIFEST ROOT — every regular file in a borg archive listing
("type<TAB>size<TAB>path") against a restored tree, hard-link aware: borg lists the
data under the first name and size 0 under every other name of the same inode."""
import gzip
import os
import sys
from collections import defaultdict

man, root = sys.argv[1], sys.argv[2].rstrip("/")
entries = []
with gzip.open(man, "rt", errors="surrogateescape") as f:
    for line in f:
        t, size, path = line.rstrip("\n").split("\t", 2)
        if t == "-":
            entries.append((int(size), path))
files = len(entries); exp_bytes = sum(s for s, _ in entries)
by_inode = defaultdict(list); stats = {}; missing = []
for size, path in entries:
    try:
        st = os.lstat(f"{root}/{path}")
    except OSError:
        missing.append(path); continue
    stats[path] = st; by_inode[(st.st_dev, st.st_ino)].append((size, path))
identical = hardlink_ok = 0; differ = []; restored_bytes = 0
for group in by_inode.values():
    actual = stats[group[0][1]].st_size
    restored_bytes += actual
    listed = [s for s, _ in group if s > 0]
    for size, path in group:
        if size == actual:
            identical += 1
        elif size == 0 and actual > 0 and len(group) > 1 and actual in listed:
            hardlink_ok += 1          # another name of this inode carries the data in the archive
        elif size == 0 and actual > 0 and stats[path].st_nlink > 1 and not listed:
            differ.append((path, size, actual, "hard link whose data-carrying name is outside the archive"))
        else:
            differ.append((path, size, actual, ""))
print(f"| regular files in the archive | {files:,} |\n|---|---|")
print(f"| byte-identical size, same name | {identical:,} |")
print(f"| hard-link names of a restored inode (borg lists them as 0 bytes) | {hardlink_ok:,} |")
print(f"| size differs | {len(differ):,} |")
print(f"| missing | {len(missing):,} |")
print(f"| bytes in the archive listing (hard links counted once) | {exp_bytes:,} |")
print(f"| bytes on the restored drive (each inode once) | {restored_bytes:,} |")
ok = identical + hardlink_ok
print(f"\n**{100.0*ok/files:.4f}% of files restored with the archived size ({ok:,} of {files:,})**\n")
print("Every size difference:\n```")
for p, a, b, why in differ: print(f"{a:>12,} -> {b:>12,}  /{p}  {why}")
print("```\nEvery missing file:\n```")
for p in missing: print("/" + p)
print("```")
