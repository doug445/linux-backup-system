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
# tests/run-all.sh — what CI runs. Run it before opening a pull request.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 1
rc=0
mapfile -t SH < <(git ls-files '*.sh' 2>/dev/null); [ ${#SH[@]} -gt 0 ] || SH=(./*.sh tests/*.sh)
echo "### bash -n";            for f in "${SH[@]}"; do bash -n "$f" || rc=1; done
echo "### shellcheck";         shellcheck -S warning "${SH[@]}" || rc=1
echo "### python";             python3 -B -m py_compile ./*.py || rc=1
if command -v ruff >/dev/null; then ruff check --isolated --no-cache ./*.py || rc=1; else echo "ruff not installed — skipped"; fi
echo "### license headers";    for f in ./*.sh ./*.py tests/*.sh; do grep -q 'SPDX-License-Identifier: MIT' "$f" || { echo "missing SPDX: $f"; rc=1; }; done
echo "### lib-fixture-test";   bash tests/lib-fixture-test.sh || rc=1
echo "### cmdline-fixture-test"; bash tests/cmdline-fixture-test.sh || rc=1
echo "### cli-test";           bash tests/cli-test.sh || rc=1
echo "### deploy-dryrun-test"; bash tests/deploy-dryrun-test.sh || rc=1
echo; [ $rc -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $rc
