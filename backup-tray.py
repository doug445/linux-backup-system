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
"""
Backup Status Tray Indicator — one icon for every layer of linux-backup-system.

Sections appear only for the layers this host actually runs, detected the same
way the scripts detect them: Snapper and btrfs replicas on a btrfs root,
Timeshift on any other root, plus Borg, Back In Time, the LUKS header backup,
the restore-readiness check and the troubleshooting report.

Shows a rounded square with "B" in the system tray:
  - Bright yellow: a backup is running
  - Charcoal: idle / safe to unmount

Every path comes from /etc/backup-system.conf (BX_CONFIG overrides), never from
this file: the tray is deployed unchanged to every host.
"""

import contextlib
import os
import sys

# Daemonize BEFORE any GTK/GLib imports — fork must happen before D-Bus
# connections are established, otherwise the child inherits broken state.
# Skip if running under systemd (INVOCATION_ID set) — systemd manages lifecycle.
if "INVOCATION_ID" not in os.environ:
    if os.fork() > 0:
        sys.exit(0)
    os.setsid()

import re
import shutil
import signal
import subprocess
import tempfile
import time

import gi

gi.require_version("Gtk", "3.0")
# Debian/Ubuntu/Mint ship the maintained Ayatana fork of AppIndicator; the
# legacy namespace is gone from newer releases and the tray died at import on
# every login there. Same API, so either one serves.
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3
from gi.repository import GLib, Gtk

POLL_INTERVAL_MS = 2000
COOLDOWN_SECONDS = 15  # keep the icon lit through sub-second stages so a run is visible

CONFIG_PATH = os.environ.get("BX_CONFIG", "/etc/backup-system.conf")
SBIN = "/usr/local/sbin"

BIT_CONFIG = "/root/.config/backintime/config"
BIT_LOCK_PATH = "/root/.local/share/backintime/worker.lock"

BORG_LOG = "/var/log/borg-backup.log"
BIT_LOG = "/var/log/backintime-backup.log"
TIMESHIFT_LOG = "/var/log/timeshift-backup.log"
LUKS_LOG = "/var/log/luks-header-backup.log"

# ── Icon rendering (SVG → tempdir) ───────────────────────────────────────────

ICON_SIZE = 22

SVG_TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
  <rect x="1" y="1" width="{inner}" height="{inner}" rx="4" ry="4"
        fill="{bg}" stroke="{stroke}" stroke-width="1"/>
  <text x="{cx}" y="{cy}" text-anchor="middle"
        font-family="sans-serif" font-weight="bold" font-size="{font_size}"
        fill="{fg}">B</text>
</svg>"""


def make_icon(name, bg, fg, stroke):
    """Create an SVG icon file and return its path."""
    svg = SVG_TEMPLATE.format(
        size=ICON_SIZE, inner=ICON_SIZE - 2,
        bg=bg, fg=fg, stroke=stroke,
        font_size=int(ICON_SIZE * 0.65),
        cx=ICON_SIZE / 2, cy=ICON_SIZE * 0.72,
    )
    icon_dir = os.path.join(tempfile.gettempdir(), "backup-tray-icons")
    os.makedirs(icon_dir, exist_ok=True)
    path = os.path.join(icon_dir, f"{name}.svg")
    with open(path, "w") as f:
        f.write(svg)
    return path


# ── Runtime detection ─────────────────────────────────────────────────────────

# Terminal emulators in preference order, with the argument form each one
# takes to run a shell command. Fedora Workstation ships Ptyxis (no
# gnome-terminal, no xterm), GNOME Console is kgx, Sway/Hyprland users have
# foot or wezterm; xfce4-terminal's -e takes ONE string (its -x takes argv).
TERMINALS = [
    ("x-terminal-emulator", ["-e"]),          # Debian alternatives: whatever the user picked
    ("ptyxis", ["--"]),
    ("kgx", ["-e"]),
    ("konsole", ["-e"]),
    ("gnome-terminal", ["--"]),
    ("xfce4-terminal", ["-x"]),
    ("tilix", ["-e"]),
    ("mate-terminal", ["-x"]),
    ("lxterminal", ["-e"]),
    ("qterminal", ["-e"]),
    ("foot", []),
    ("wezterm", ["start", "--"]),
    ("alacritty", ["-e"]),
    ("kitty", []),
    ("xterm", ["-e"]),
]


def find_terminal():
    for term, _ in TERMINALS:
        if shutil.which(term):
            return term
    return ""


def load_config():
    """Read KEY="value" lines from /etc/backup-system.conf.

    The file is a shell fragment the scripts source; the tray only needs the
    plain assignments, so it is parsed rather than executed. Missing file or
    missing keys fall back to the same defaults backup-common.sh uses.
    """
    conf = {}
    with contextlib.suppress(OSError), open(CONFIG_PATH) as f:
        for line in f:
            m = re.match(r'^\s*([A-Z_]+)=["\']?([^"\'#\n]*)["\']?', line)
            if m:
                conf[m.group(1)] = m.group(2).strip()
    mount = conf.get("BACKUP_MOUNT") or "/mnt/backup"
    conf["BACKUP_MOUNT"] = mount
    conf["BORG_REPO"] = conf.get("BORG_REPO") or f"{mount}/borg-backup"
    return conf


def root_fstype():
    r = run_quiet(["findmnt", "-no", "FSTYPE", "/"])
    return r.strip() if r else ""


def run_quiet(cmd, timeout=3):
    """Run a command and return its stdout, or None on any failure."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


# A shell running a -c string only MENTIONS what it names: a terminal wrapper,
# an agent's tool shell or a one-liner that tails a log. The process it starts
# shows up on its own and is matched there.
SHELL_C = re.compile(r"^(\S*/)?(ba|da|z|k|fi)?sh\s+(-\S+\s+)*-c\s")


def pgrep(pattern, full=True):
    """Matching `pgrep -a` lines, minus this process and shell -c wrappers."""
    flags = "-fa" if full else "-a"
    out = run_quiet(["pgrep", flags, pattern])
    if not out:
        return []
    me = str(os.getpid())
    lines = []
    for line in out.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] != me and not SHELL_C.match(parts[1]):
            lines.append(parts[1])
    return lines


def script_running(name):
    """A suite script actually executing, not a command line that names it.

    The kernel shows a script started through its shebang as
    "<interpreter> <path/to/script>", so require exactly that: an editor, a
    pager or `grep borg-backup.sh` never counts. Matching the name anywhere
    showed "backup running" while nothing ran.
    """
    rx = re.compile(r"^(\S*/)?(env\s+)?(ba|da)?sh\s+(-\S+\s+)*\S*" + re.escape(name) + r"(\s|$)")
    return any(rx.match(cmd) for cmd in pgrep(re.escape(name)))


def process_running(rx):
    """A process whose own executable (argv0, or the script a python/perl
    interpreter runs) matches rx — anchored, so a mention elsewhere never counts."""
    anchored = re.compile(r"^(\S*/)?((python|perl)[\d.]*\s+(-\S+\s+)*\S*/)?" + rx)
    return next((cmd for cmd in pgrep(rx) if anchored.match(cmd)), None)


CONF = load_config()
TERMINAL = find_terminal()
BACKUP_MOUNT = CONF["BACKUP_MOUNT"]
BORG_REPO = CONF["BORG_REPO"]
ROOT_FS = root_fstype()


def run_in_terminal(cmd_str):
    full_cmd = f'{cmd_str}; echo; read -p "Press Enter to close..."'
    if not TERMINAL:
        # Say so on screen: a FileNotFoundError inside a menu handler only
        # reached stderr, and every menu action looked dead.
        dlg = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR,
                                buttons=Gtk.ButtonsType.CLOSE,
                                text="No terminal emulator found")
        dlg.format_secondary_text("Install one of: " + ", ".join(t for t, _ in TERMINALS)
                                  + "\n\nThe command was:\n" + cmd_str)
        dlg.run()
        dlg.destroy()
        return
    pre = next(args for term, args in TERMINALS if term == TERMINAL)
    argv = [TERMINAL, *pre, "bash", "-c", full_cmd]
    try:
        subprocess.Popen(argv)
    except OSError as e:
        dlg = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR,
                                buttons=Gtk.ButtonsType.CLOSE,
                                text=f"Could not start {TERMINAL}")
        dlg.format_secondary_text(str(e))
        dlg.run()
        dlg.destroy()


def mount_is_live(path):
    """True when path is a mount point whose source device still exists.

    A drive yanked while mounted leaves the mount behind until the detach unit
    clears it; its source node is what disappears (or, for a LUKS mapping, the
    disk under it — then the detach unit closes the mapping within seconds).
    """
    if not os.path.ismount(path):
        return False
    with contextlib.suppress(OSError), open("/proc/self/mounts") as f:
        for line in f:
            fields = line.split()
            if len(fields) > 1 and fields[1] == path:
                src = fields[0]
                return not src.startswith("/dev/") or os.path.exists(src)
    return True


# ── Backup detection ──────────────────────────────────────────────────────────

def is_snapper_running():
    for svc in ["snapper-timeline.service", "snapper-cleanup.service"]:
        out = run_quiet(["systemctl", "is-active", svc])
        if out and out.strip() == "active":
            return True, f"{svc} active"
    if pgrep("snapper", full=False):
        return True, "snapper process running"
    return False, ""


def unit_active(unit):
    """True while a suite oneshot unit is running (the timers' and tray's runs)."""
    out = run_quiet(["systemctl", "is-active", unit])
    return bool(out) and out.strip() in ("active", "activating")


def is_borg_running():
    """Borg, the borg-backup.sh wrapper, or a btrfs send/receive replica."""
    if unit_active("borg-backup.service"):
        return True, "borg-backup.service running"
    if os.path.exists(os.path.join(BORG_REPO, "lock.exclusive")):
        return True, "Borg repo locked"

    if script_running("borg-backup.sh"):
        return True, "borg-backup.sh running"
    cmd = process_running(r"borgmatic(\s|$)") or process_running(r"borg\s+(create|prune|compact|check|extract)\b")
    if cmd:
        return True, cmd.strip()[:60]
    if process_running(r"btrfs\s+(send|receive)\b"):
        return True, "btrfs send/receive"
    return False, ""


def bit_lock_alive():
    """True when the BIT worker lock names a live pid.

    The tray runs as the desktop user and the lock lives under /root, which it
    usually cannot traverse; that is not evidence of a running job (treating it
    as held showed "Back in Time running" forever), so an unreadable lock is
    ignored and is_bit_running falls back to the unit and process checks.
    """
    try:
        with open(BIT_LOCK_PATH) as f:
            content = f.read().strip()
    except OSError:
        return False
    pid_str = content.splitlines()[0] if content else ""
    if not pid_str.isdigit():
        return True
    try:
        os.kill(int(pid_str), 0)
    except ProcessLookupError:
        return False  # stale lock
    except PermissionError:
        return True
    return True


def is_bit_running():
    """Back in Time: the unit, the worker lock, our rsync wrapper, or the GUI's own jobs."""
    if unit_active("backintime-backup.service"):
        return True, "backintime-backup.service running"
    if bit_lock_alive():
        return True, "Back in Time running"

    if script_running("backintime-backup.sh"):
        return True, "backintime-backup.sh running"
    # The GUI's own jobs: backintime (a python script) with a job verb.
    cmd = process_running(r"backintime(-qt)?(\.py)?\s+(.*\s)?(backup|backup-job|restore|smart-remove)(\s|$)")
    if cmd:
        return True, cmd.strip()[:60]
    return False, ""


def is_timeshift_running():
    if unit_active("timeshift-backup.service"):
        return True, "timeshift-backup.service running"
    if script_running("timeshift-backup.sh"):
        return True, "timeshift-backup.sh running"
    cmd = process_running(r"timeshift(-launcher)?\s+(.*\s)?--(create|delete|check)(\s|$)")
    if cmd:
        return True, cmd.strip()[:60]
    return False, ""


def is_verify_running():
    if unit_active("backup-verify.service"):
        return True, "backup-verify.service running"
    if script_running("backup-verify.sh"):
        return True, "backup-verify.sh running"
    return False, ""


def is_luks_header_running():
    if unit_active("luks-header-backup.service"):
        return True, "luks-header-backup.service running"
    if script_running("luks-header-backup.sh"):
        return True, "luks-header-backup.sh running"
    return False, ""


# ── Tray indicator ────────────────────────────────────────────────────────────

class BackupIndicator:
    def __init__(self):
        self.icon_active = make_icon("active", "#FFD700", "#000000", "#DAA520")
        self.icon_idle = make_icon("idle", "#3C3C3C", "#6C6C6C", "#2A2A2A")
        icon_dir = os.path.dirname(self.icon_active)

        self.indicator = AppIndicator3.Indicator.new(
            "backup-tray",
            os.path.splitext(os.path.basename(self.icon_idle))[0],
            AppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
        )
        self.indicator.set_icon_theme_path(icon_dir)
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Backup Status")

        self.is_active = False
        self.last_seen_active = 0
        self.active_start_time = 0
        self.active_sources = set()

        # Which layers exist on THIS host — the same rule the scripts use:
        # btrfs root -> snapper + btrfs replicas; anything else -> Timeshift.
        self.is_btrfs = ROOT_FS == "btrfs"
        self.has_snapper = self.is_btrfs and shutil.which("snapper") is not None
        self.has_timeshift = (not self.is_btrfs) and (
            shutil.which("timeshift") is not None
            or os.path.exists(f"{SBIN}/timeshift-backup.sh"))
        self.has_verify = os.path.exists(f"{SBIN}/backup-verify.sh")
        self.has_luks = os.path.exists(f"{SBIN}/luks-header-backup.sh")
        self.has_diag = os.path.exists(f"{SBIN}/backup-diag.sh")

        # Snapper detection: track .snapshots dir mtime so we can flash the
        # tray for sub-second snapshot operations that polling would miss.
        self._snapper_mtimes = {}
        for snap_dir in ("/.snapshots", "/home/.snapshots"):
            with contextlib.suppress(OSError):
                self._snapper_mtimes[snap_dir] = os.stat(snap_dir).st_mtime

        self._build_menu()
        self.update_status()
        GLib.timeout_add(POLL_INTERVAL_MS, self.update_status)

    # -- menu ---------------------------------------------------------------

    def _section(self, title, items):
        header = Gtk.MenuItem(label=f"── {title} ──")
        header.set_sensitive(False)
        self.menu.append(header)
        for label, handler in items:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", handler)
            self.menu.append(item)
        self.menu.append(Gtk.SeparatorMenuItem())

    def _build_menu(self):
        self.menu = Gtk.Menu()

        self.status_item = Gtk.MenuItem(label="✅ Idle — safe to unmount")
        self.menu.append(self.status_item)
        self.menu.append(Gtk.SeparatorMenuItem())

        if self.has_snapper:
            self._section("Snapper (btrfs snapshots)", [
                ("Snapper: List snapshots (root)", self.on_snapper_list_root),
                ("Snapper: List snapshots (home)", self.on_snapper_list_home),
                ("Snapper: Create snapshot now", self.on_snapper_create),
                ("Snapper: Rollback root…", self.on_snapper_rollback),
                ("Snapper: Rollback home…", self.on_snapper_rollback_home),
            ])

        borg_title = "Borg (deduplicated archives" + (
            " + btrfs replicas)" if self.is_btrfs else ")")
        self._section(borg_title, [
            ("Borg: List archives", self.on_borg_list),
            ("Borg: View backup log", self.on_borg_log),
            ("Borg: Run backup now", self.on_borg_run),
            ("Borg: Dry run (plan only, no changes)", self.on_borg_dry_run),
            ("Borg: Verify integrity", self.on_borg_verify),
        ])

        self._section("Back in Time (rsync snapshots)", [
            ("BIT: List snapshots", self.on_bit_list),
            ("BIT: View backup log", self.on_bit_log),
            ("BIT: Run backup now", self.on_bit_run),
            ("BIT: Open GUI", self.on_bit_gui),
        ])

        if self.has_timeshift:
            self._section("Timeshift (local snapshots)", [
                ("Timeshift: List snapshots", self.on_timeshift_list),
                ("Timeshift: View backup log", self.on_timeshift_log),
                ("Timeshift: Run snapshot now", self.on_timeshift_run),
                ("Timeshift: Open GUI", self.on_timeshift_gui),
            ])

        if self.has_luks:
            self._section("LUKS headers", [
                ("LUKS: Back up headers now", self.on_luks_run),
                ("LUKS: View header backup log", self.on_luks_log),
            ])

        if self.has_verify:
            self._section("Restore readiness", [
                ("Verify: Would a restore boot? (run check)", self.on_verify_run),
                ("Verify: Last scheduled result", self.on_verify_last),
            ])

        if self.has_diag:
            self._section("Troubleshooting", [
                ("Generate troubleshooting report…", self.on_diag),
            ])

        self.disk_item = Gtk.MenuItem(label="\U0001f4be Drive: checking...")
        self.disk_item.set_sensitive(False)
        self.menu.append(self.disk_item)

        item = Gtk.MenuItem(label="Quit")
        item.connect("activate", self.on_quit)
        self.menu.append(item)

        self.menu.show_all()
        self.indicator.set_menu(self.menu)

    # -- polling ------------------------------------------------------------

    def update_status(self):
        now = time.monotonic()
        sources_running = set()
        details = []

        if self.has_snapper:
            running, detail = is_snapper_running()
            if running:
                sources_running.add("Snapper")
                details.append(detail)
            # Detect sub-second snapshot operations via .snapshots dir mtime
            for snap_dir in ("/.snapshots", "/home/.snapshots"):
                try:
                    mtime = os.stat(snap_dir).st_mtime
                except OSError:
                    continue
                prev = self._snapper_mtimes.get(snap_dir)
                self._snapper_mtimes[snap_dir] = mtime
                if prev is not None and mtime != prev:
                    sources_running.add("Snapper")
                    details.append(f"snapshot {os.path.basename(snap_dir)}")

        probes = [("Borg", is_borg_running), ("BIT", is_bit_running)]
        if self.has_timeshift:
            probes.append(("Timeshift", is_timeshift_running))
        if self.has_luks:
            probes.append(("LUKS headers", is_luks_header_running))
        if self.has_verify:
            probes.append(("Verify", is_verify_running))
        for name, probe in probes:
            running, detail = probe()
            if running:
                sources_running.add(name)
                details.append(detail)

        any_running = len(sources_running) > 0

        if any_running:
            self.last_seen_active = now
            self.active_sources = sources_running

        in_cooldown = (now - self.last_seen_active) < COOLDOWN_SECONDS
        effectively_active = any_running or (self.is_active and in_cooldown)

        if effectively_active and not self.is_active:
            self.is_active = True
            self.active_start_time = now
            self.indicator.set_icon_full("active", "Backup running")

        if effectively_active:
            elapsed = int(now - self.active_start_time)
            elapsed_str = f"{elapsed // 60}m {elapsed % 60}s" if elapsed >= 60 else f"{elapsed}s"
            src_str = " + ".join(sorted(self.active_sources)) if self.active_sources else "Backup"
            detail_short = details[0][:40] if details else "running"
            self.status_item.set_label(f"❌ {src_str}: {detail_short} ({elapsed_str})")
        elif not effectively_active and self.is_active:
            self.is_active = False
            self.active_sources = set()
            self.indicator.set_icon_full("idle", "Idle")
            self.status_item.set_label("✅ Idle — safe to unmount")
        else:
            self.indicator.set_icon_full("idle", "Idle")

        # Update disk usage label. Only a live mount: statvfs on the empty
        # mountpoint directory reports the ROOT filesystem, so an unplugged
        # drive showed the system disk's size as the backup drive's.
        if not mount_is_live(BACKUP_MOUNT):
            self.disk_item.set_label("\U0001f4be Drive: not connected")
            return True
        try:
            stat = os.statvfs(BACKUP_MOUNT)
            total_gb = stat.f_blocks * stat.f_frsize / 1024**3
            used_gb = (stat.f_blocks - stat.f_bfree) * stat.f_frsize / 1024**3
            pct = int(used_gb / total_gb * 100) if total_gb else 0
            self.disk_item.set_label(
                f"\U0001f4be Drive: {used_gb:.0f} GB / {total_gb:.0f} GB ({pct}%)")
        except (OSError, ZeroDivisionError):
            self.disk_item.set_label("\U0001f4be Drive: not mounted")

        return True

    # -- Snapper handlers ---------------------------------------------------
    def on_snapper_list_root(self, _):
        run_in_terminal("sudo snapper -c root list")

    def on_snapper_list_home(self, _):
        run_in_terminal("sudo snapper -c home list")

    def on_snapper_create(self, _):
        run_in_terminal(
            'sudo snapper -c root create -d "manual snapshot" && '
            'sudo snapper -c home create -d "manual snapshot" && '
            'echo "Snapshots created for root and home."'
        )

    def on_snapper_rollback(self, _):
        run_in_terminal(
            'echo "=== Current root snapshots ===" && '
            'sudo snapper -c root list && echo && '
            'read -p "Enter snapshot # to undo changes back to (or Ctrl+C to cancel): " SNAP && '
            'echo "Rolling back root to snapshot $SNAP..." && '
            'sudo snapper -c root undochange "$SNAP..0" && '
            'echo "Rollback complete. Reboot recommended."'
        )

    def on_snapper_rollback_home(self, _):
        run_in_terminal(
            'echo "=== Current home snapshots ===" && '
            'sudo snapper -c home list && echo && '
            'read -p "Enter snapshot # to undo changes back to (or Ctrl+C to cancel): " SNAP && '
            'echo "Rolling back home to snapshot $SNAP..." && '
            'sudo snapper -c home undochange "$SNAP..0" && '
            'echo "Rollback complete."'
        )

    # -- Borg handlers ------------------------------------------------------
    def on_borg_list(self, _):
        run_in_terminal(f"sudo borg list {BORG_REPO}")

    def on_borg_log(self, _):
        run_in_terminal(f"sudo tail -80 {BORG_LOG}")

    def on_borg_run(self, _):
        run_in_terminal(f"sudo {SBIN}/borg-backup.sh")

    def on_borg_dry_run(self, _):
        run_in_terminal(f"sudo {SBIN}/borg-backup.sh --dry-run")

    def on_borg_verify(self, _):
        run_in_terminal(
            f"echo 'Verifying Borg repo integrity...' && "
            f"sudo borg check --show-rc {BORG_REPO} && "
            f"echo && sudo borg info {BORG_REPO}"
        )

    # -- BIT handlers -------------------------------------------------------
    def on_bit_list(self, _):
        run_in_terminal(f"sudo backintime --config {BIT_CONFIG} show")

    def on_bit_log(self, _):
        run_in_terminal(f"sudo tail -80 {BIT_LOG}")

    def on_bit_run(self, _):
        run_in_terminal(f"sudo {SBIN}/backintime-backup.sh")

    def on_bit_gui(self, _):
        subprocess.Popen(["backintime-qt"])

    # -- Timeshift handlers -------------------------------------------------
    def on_timeshift_list(self, _):
        run_in_terminal("sudo timeshift --list")

    def on_timeshift_log(self, _):
        run_in_terminal(f"sudo tail -80 {TIMESHIFT_LOG}")

    def on_timeshift_run(self, _):
        run_in_terminal(f"sudo {SBIN}/timeshift-backup.sh")

    def on_timeshift_gui(self, _):
        subprocess.Popen(["timeshift-launcher"])

    # -- LUKS header handlers -----------------------------------------------
    def on_luks_run(self, _):
        run_in_terminal(f"sudo {SBIN}/luks-header-backup.sh")

    def on_luks_log(self, _):
        run_in_terminal(f"sudo tail -80 {LUKS_LOG}")

    # -- Restore-readiness handlers -----------------------------------------
    def on_verify_run(self, _):
        run_in_terminal(f"sudo {SBIN}/backup-verify.sh")

    def on_verify_last(self, _):
        # The verify unit logs only to the journal; show its most recent run.
        run_in_terminal("sudo journalctl -u backup-verify.service -o cat --no-pager -n 120")

    # -- Troubleshooting ----------------------------------------------------
    def on_diag(self, _):
        out = os.path.expanduser(f"~/backup-diag-{time.strftime('%Y%m%d-%H%M%S')}.md")
        run_in_terminal(
            f"sudo {SBIN}/backup-diag.sh -o {out} && "
            f"sudo chown $(id -u):$(id -g) {out} && "
            f"echo && echo 'Report written to {out}' && "
            f"echo 'Read it, then attach it to a GitHub issue (see CONTRIBUTING.md).'"
        )

    def on_quit(self, _):
        Gtk.main_quit()


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

    for attempt in range(5):
        try:
            BackupIndicator()
            break
        except Exception as e:  # noqa: BLE001 — GTK/D-Bus init can raise anything at login
            wait = 2 * (attempt + 1)
            print(f"backup-tray: GTK init failed (attempt {attempt+1}/5): {e}",
                  file=sys.stderr)
            time.sleep(wait)
    else:
        print("backup-tray: giving up after 5 GTK init failures", file=sys.stderr)
        sys.exit(1)

    Gtk.main()


if __name__ == "__main__":
    main()
