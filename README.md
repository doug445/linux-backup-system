[![CI](https://github.com/doug445/linux-backup-system/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/linux-backup-system/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: x86_64 | aarch64](https://img.shields.io/badge/platform-x86__64%20%7C%20aarch64-lightgrey.svg)](#tested--untested)
[![Layers: Borg | Back In Time | btrfs/Timeshift](https://img.shields.io/badge/layers-Borg%20%7C%20Back%20In%20Time%20%7C%20btrfs%2FTimeshift-blue.svg)](#layers)
[![Boot: GRUB | systemd-boot | UKI](https://img.shields.io/badge/boot-GRUB%20%7C%20systemd--boot%20%7C%20UKI-informational.svg)](#restore)

# linux-backup-system — universal, restore-verified backup and bare-metal restore for any Linux

**A universal Linux backup system: one codebase meant to run unchanged on
any Linux system — every distro, every root filesystem, every boot layout —
that answers the only question that matters once a disk is gone: could I
actually restore this machine?** Nothing is keyed to a distro name; every
decision is made from what the machine shows at run time, so a setup this
suite has never seen is a detection gap to close, not a port to write — and
closing those gaps is what the [call for contributions](#contributing) is
for. It layers
**Borg** deduplicated archives, **Back In Time**-format rsync snapshots, a
local snapshot layer chosen by the root filesystem (**btrfs send/receive**
replicas of your snapper snapshots on btrfs, **Timeshift** on ext4 and
everything else), keyslot-tagged **LUKS header backups**, and a
**restore-readiness check** that asserts from what is actually on the backup
drive that a bare-metal restore would boot. On restore it rebuilds the boot
chain for whatever it finds: **GRUB** (EFI or legacy BIOS), **systemd-boot**,
**Unified Kernel Images**, an encrypted argon2id `/boot`. Fedora, Fedora Asahi
Remix on Apple Silicon, Debian, Ubuntu, Linux Mint, Arch, Manjaro, openSUSE;
x86_64 and aarch64.

Nothing here is pinned to a machine: the backup drive, its guard UUID, the
unlock keyfile, the schedule policy and the retention live in
`/etc/backup-system.conf`, and every path that depends on the disk or boot
layout is derived at run time. It replaces the older `BIT_deploy` and
`borg-backup` projects, which were Back-In-Time-centric and carried one host's
paths hardcoded.

> ### Status: ✅ verified on metal, ❌ written but not yet verified
>
> "Universal" is the goal and the design; the proof is per setup. The
> [Tested / untested](#tested--untested) tables say which distros, root
> filesystems and boot layouts have been confirmed with a real backup and a
> passing `backup-verify.sh` on real hardware. **Each ❌ row turns ✅ as that
> setup is tested and verified** — by the author where the hardware exists,
> and by a [setup report](CONTRIBUTING.md#most-wanted-setup-reports) from
> anyone running one of those setups, or any Linux this suite has never seen.
> A patch that passes the tests puts the contributor's name on the license.

> **A backup never starts because a drive appeared.** Plugging the backup
> drive in unlocks and mounts it; a backup runs when a timer fires (installed
> second drive) or when you start one (external drive) — from the tray or the
> command line. Every script takes `--dry-run`. Retention never deletes by age.

---

## Quick start

```bash
git clone https://github.com/doug445/linux-backup-system.git
cd linux-backup-system
sudo ./deploy.sh --dry-run     # 1. detect distro, fs, boot layout, drive; print the plan; change nothing
sudo ./deploy.sh               # 2. install packages, scripts, config, units — and set the drive up if none is mounted
sudo borg-backup.sh --dry-run  # 3. see exactly what the first backup would do
sudo borg-backup.sh            # 4. the first backup
sudo backup-verify.sh          # 5. would a bare-metal restore boot? exit 0 = yes
```

If no backup drive is mounted, step 2 asks you to connect one, lets you pick
it, offers to have you encrypt it first (GNOME Disks, GParted, or in place
later with [LinuxLocker](https://github.com/doug445/LinuxLocker)), formats it
for backup on a typed confirmation — or installs now and tells you to re-run
when the drive is connected. See [Install](#install).

## Layers

| Layer | Tool | Scope | Notes |
|---|---|---|---|
| Deduplicated archive | Borg | every distro | the universal layer; always present |
| File snapshots | Back In Time format (direct rsync) | every distro | GUI-compatible, hardlinked; bypasses BIT's Qt/DBus internals, which deadlock headless |
| Local/replica snapshots | btrfs send/receive **or** Timeshift | fs-dependent | btrfs root → snapper snapshots replicated by send/receive (in `borg-backup.sh`); any other root → `timeshift-backup.sh` |
| LUKS header backup | `luks-header-backup.sh` | encrypted hosts | active keyslots encoded in every filename, stored on two disks |
| Restore-readiness check | `backup-verify.sh` | every distro | asserts a restore would boot — kernel, bootloader config, and every kernel command line agreeing with `fstab`/`crypttab`; exit 0 / 1 (warnings) / 2 (a restore would fail) |
| Troubleshooting report | `backup-diag.sh` | every distro | read-only, redacted; the file a bug or setup report is built from |

## Tested / untested

Green ✅ means a real backup **and** a `backup-verify` pass have been confirmed
on that setup. A red ❌ means the code paths exist and dry-run clean but that
exact combination has **not** been verified yet — run it there and confirm
before trusting it. The tooling was developed and dry-run-verified on Fedora
Asahi Remix (aarch64), and fully verified end-to-end on Linux Mint 22.3
(x86_64, ext4 root on LVM-on-LUKS, encrypted argon2id `/boot`, GRUB EFI) on
2026-09-11.

**Distros**

| Distro | Status |
|---|:--:|
| Fedora | ✅ |
| Fedora Asahi Remix (Apple Silicon, aarch64) | ✅ |
| Debian / Ubuntu / Linux Mint | ✅ |
| Arch / Manjaro / EndeavourOS | ❌ |
| openSUSE (Leap / Tumbleweed) | ❌ |

**Root filesystems** (this picks the local-snapshot engine — see Layers)

| Root fs | Local-snapshot engine | Status |
|---|---|:--:|
| btrfs | btrfs send/receive (`borg-backup.sh`) | ✅ |
| ext4 | Timeshift (`timeshift-backup.sh`) | ✅ create · ❌ prune (never fired on a real drive) |
| xfs / f2fs / anything else | Timeshift | ❌ |

**Boot layouts**

| Setup | Status |
|---|:--:|
| systemd-boot (Type #1 entries, no UKI) | ✅ |
| UKI (unified kernel image) | ✅ |
| GRUB (EFI) | ✅ |
| GRUB (legacy BIOS) | ❌ |
| Standard `vmlinuz` + `initramfs` (non-UKI) | ✅ |
| Encrypted argon2id `/boot` (needs GRUB ≥ 2.12) | ✅ |
| Encrypted pbkdf2 `/boot` — LUKS1 (GRUB ≥ 2.02) or LUKS2 with pbkdf2 (GRUB ≥ 2.06), the form stock GRUB opens | ❌ |
| Plain `/boot` (unencrypted /boot) | ❌ |
| Raspberry Pi firmware boot (`/boot/firmware`: `config.txt`, `cmdline.txt`, `kernel*.img`; no bootloader) | ❌ |
| Bare-metal restore **executing** the boot rebuild (not just its dry run) | ❌ |

A ❌ row turns ✅ when that setup has been deployed, has produced one real
backup on each layer, and has passed `backup-verify.sh` — with the
[troubleshooting report](#troubleshooting-logs-dry-runs-and-the-report) from
that machine kept as the evidence. Every backup and the installer take
`--dry-run` first, so the plan can be inspected without touching anything.

## Scheduling policy

Set per host, and auto-detected by `deploy.sh` from the backup drive:

- **Ad-hoc** (default; external / removable / USB / hotplug drive) — backups run
  by hand or from the tray. The borg and BIT timers are **masked**; the
  udev-triggered `borg-backup-drive-attach.service` unlocks and mounts the drive
  on connect but never starts a backup.
- **Scheduled** (a second **installed** internal drive) — the daily borg and BIT
  timers are enabled.

Override detection with `SCHEDULE_MODE=adhoc|scheduled` in the config or the
environment. The read-only `backup-verify` and `luks-header-backup` timers are
enabled on every host regardless — they never write a backup.

## Retention

Count-based **and** free-space based, **never** time-based — an ad-hoc drive can
sit unplugged for months and age must never delete a backup. Applied by every
layer (borg archives, btrfs/Timeshift replicas, BIT snapshots):

| Knob | Default | Meaning |
|---|---|---|
| `KEEP` | 10 | normal: keep the newest N of each set, any age |
| `MIN_KEEP` | 3 | hard floor: never prune below this, even when full |
| `MIN_FREE_PCT` | 10 | keep at least this % of the drive free |
| `MIN_FREE_GIB` | 0 | and at least this many GiB free (0 = ignore) |

Normal runs keep `KEEP`. Only when the drive is genuinely tight does it drop the
oldest, one at a time, down to `MIN_KEEP`.

## Install

```bash
sudo ./deploy.sh --dry-run     # detect + print the plan, change nothing
sudo ./deploy.sh               # install packages, scripts, config, units
```

`deploy.sh` detects distro family, root filesystem, boot layout and drive type;
**installs and verifies every dependency the detected setup needs** before
touching anything else; deploys every script plus `backup-common.sh`; generates
`/etc/backup-system.conf` (never clobbering an existing one); deploys the
units and the udev rule; enables timers only in scheduled mode; installs the
tray; and adds `timeback` / `bitback` / `snapback` shell functions. On
non-btrfs roots it installs Timeshift as the local-snapshot layer.

**Setting the drive up.** When no backup drive is mounted, a real run (never
the dry run, never a non-interactive session) offers:

1. **Set it up now.** Connect the drive; `deploy.sh` lists whole disks with
   size, bus and model, refuses any disk that holds a mounted filesystem, swap
   or an fstab/crypttab entry, and asks which one to use. Then, depending on
   what is on it:
   - **already LUKS-encrypted** — asks for its passphrase once, uses the
     filesystem inside as-is or reformats it as btrfs on your say-so, and
     offers to enroll a keyfile (`/etc/luks-keys/backup-drive.key`, root-only
     0400, added with `--pbkdf argon2id --hash sha512`) so the drive unlocks
     and mounts itself on connect;
   - **a plain filesystem** — use it as-is, erase and format it, encrypt it
     first yourself, or wait;
   - **empty** — encrypt it first yourself (recommended), format it plain, or
     wait.
2. **Wait.** Install everything now; re-run `deploy.sh` when the drive is
   connected and it finishes the configuration.

**Blank drives, connected and disconnected.** A brand-new drive — no partition
table, no filesystem — is marked *blank, ready to set up* in the disk list and
offered as the default. On a host that already has a backup drive configured,
a blank hotplug drive that has just been plugged in is reported on every run
and, on a terminal, offered as a replacement (the previous config is kept
beside the new one). A configured drive that is simply not connected is
recognised as such: the run continues with the configured path and the
summary says to reconnect and re-run — nothing is rewritten to a default. If
a drive is unplugged in the middle of set-up, every write step re-checks the
device first and aborts with *drive disconnected?* rather than formatting
whatever appeared in its place. At run time, yanking the backup drive fires a
udev *remove* rule that starts `borg-backup-drive-detach.service` (a unit,
because `systemd-udevd` runs with a private mount namespace and an `umount`
from a udev `RUN` program never reaches the host): the dead mount is lazily
unmounted and the orphaned LUKS mapping closed, so the next plug-in attaches
cleanly instead of failing on "already mounted" or "device already exists". The attach script also clears a stale mount or mapping it finds on
the way in. Neither ever starts a backup.

Encryption is never done by `deploy.sh`. Choose *encrypt first* and it prints
the exact GNOME Disks, GParted and `cryptsetup` steps, then adopts the result
on the next run. Choose *plain* and it states the risk in one paragraph — an
unencrypted backup drive is a readable copy of every file on the machine —
and formats only after you type `PLAIN`; the summary then reminds you that
[LinuxLocker](https://github.com/doug445/LinuxLocker) encrypts it in place
later, keeping the backups on it. Formatting itself is gated behind typing the
device path back and the word `ERASE`. The drive is always btrfs (GPT, one
partition, label `Borg-backup`): the send/receive replicas of a btrfs root need
a btrfs destination, and compression is free space on the others.

## Dependencies

**`deploy.sh` installs what the detected box needs, automatically, as its
first act after detection** — before the drive set-up, which needs
`mkfs.btrfs` and `cryptsetup`, and before any layer is deployed. One package
map in `backup-common.sh` serves the installer and every script it deploys, so
what gets installed is exactly what the scripts later check for.

| Set | Tools | On failure |
|---|---|---|
| **Required**, every host | borg, rsync, cryptsetup, btrfs-progs (the backup drive is always btrfs), util-linux (`findmnt`, `lsblk`, `sfdisk`, `wipefs`, `blkid`), `udevadm` | verified by `command -v` after the install; any still missing **aborts the deploy** with the package list (on Arch/Manjaro: run `pacman -Syu` first) |
| **By layer** | Back In Time; `snapper` on a btrfs root; `timeshift` on any other root; `ecryptfs-utils` when an ecryptfs home is found | each installed on its own, so one the distro does not carry (Back In Time and Timeshift are AUR-only on Arch) costs a **warning naming the manual command**, not the deploy |
| **Tray** | python3, GTK 3 and AppIndicator3 through GObject introspection, probed by importing them | warning; the tray does not start until they are present |

Package names are resolved per family — Debian/Ubuntu/Mint, Fedora/RHEL,
Arch/Manjaro, openSUSE — and installed with that family's package manager,
non-interactively. A `--dry-run` reports every package it *would* install and
installs nothing. Every backup script re-checks its own tools at run time and
installs any that went missing since, rather than failing partway through.

## Troubleshooting: logs, dry-runs and the report

Every backup script logs a detection dump as its first lines — suite version,
host, root fs, snapshot engine, ESP, sources, retention — then does its work.
`--dry-run` performs all detection and logs every action it *would* take
without changing anything:

```bash
sudo /usr/local/sbin/borg-backup.sh --dry-run        # borg runs with --dry-run
sudo /usr/local/sbin/backintime-backup.sh --dry-run  # rsync runs with --dry-run
sudo /usr/local/sbin/timeshift-backup.sh --dry-run   # non-btrfs roots
sudo /usr/local/sbin/backup-verify.sh                # read-only by nature
sudo /usr/local/sbin/restore-rebuild-boot.sh --dry-run   # the boot-chain plan a restore would execute here
```

Logs: `/var/log/borg-backup.log`, `/var/log/backintime-backup.log`,
`/var/log/timeshift-backup.log`, `/var/log/luks-header-backup.log`. The verify
and drive-attach units log to the journal only (`journalctl -u backup-verify.service`).
Restore sessions log to `/tmp/borg-restore-*.log` / `/tmp/backintime-restore-*.log`.

**The troubleshooting report** collects all of that and more into one Markdown
file — the file every bug report and setup report is built from, and the one
thing to send me when something is wrong on a setup I cannot reach:

```bash
sudo ./backup-diag.sh -o backup-diag.md        # or: tray → Troubleshooting → Generate troubleshooting report
```

It is **read-only**: it mounts nothing, starts no backup, and never touches
key material — keyfiles by path and mode only, LUKS headers by public metadata
only, every UUID truncated to 8 characters (`--no-redact` keeps them whole for
a private report; `--full` gives longer log tails). It records `os-release`,
kernel, firmware and Secure Boot state, a tool inventory with versions,
`lsblk` / `findmnt` / `fstab` / `crypttab`, every ESP candidate and its
contents, loader entries, UKIs, GRUB and initramfs configuration, installed
kernels, the config file, the deployed scripts with hashes, **what the suite's
own detection reports for every decision it makes**, the
`restore-rebuild-boot.sh --dry-run` plan, unit and timer state, the udev rule,
every log and journal tail, and — as root — the full `backup-verify.sh` run.
Read it before you post it; then attach it to an issue.

## Hand-rolling a fix for your setup and distro

The suite makes a small number of decisions from what it detects, and a setup
it has never seen shows up as one of them being wrong. Every decision lives in
one place. This is where, what to change, and how to prove it.

**Step 1 — find the wrong decision.** Run the report and compare the section
*"What the suite's own detection reports"* with the raw `lsblk` / `findmnt` /
boot-layout sections above it:

```bash
sudo ./backup-diag.sh -o backup-diag.md
```

The line that disagrees with reality is the bug. Then:

| Decision | Where it is made | What to change | How to prove it |
|---|---|---|---|
| **Distro family → package manager** | `backup-common.sh` → `bx_distro_family` (matches `ID` and each word of `ID_LIKE` from `os-release`) and `bx_pkg_install_cmd`; `deploy.sh` → `detect_distro` (the same families, plus per-family package names) | Add your `ID` / `ID_LIKE` token to the family it belongs to, or add a family with its install command. Both places, or the library will accept a distro the installer refuses. | Add a synthetic `os-release` case to `tests/lib-fixture-test.sh`; `sudo ./deploy.sh --dry-run` prints `Distro:` with the right family |
| **Package names** (borg, Back In Time, AppIndicator, Timeshift) | `backup-common.sh` → `bx_pkg_for`; `deploy.sh` → `detect_distro` (`BIT_PKGS`, `BORG_PKG`) and the two `case "$DISTRO_FAMILY"` blocks in *Step 1: Install packages* | Map the command to your distro's package name. | `sudo borg-backup.sh --dry-run` — its `[deps]` lines name what it would install |
| **Root filesystem → snapshot engine** | `backup-common.sh` → `bx_snapshot_engine` (btrfs → send/receive, else Timeshift); consumed by `borg-backup.sh` (replica block), `timeshift-backup.sh` (early exit on btrfs), `backup-verify.sh` (section 4) | A new engine means a new branch in all four. A filesystem that should simply use Timeshift needs nothing — it already does. | `--dry-run` of both backup scripts; one real run; `backup-verify.sh` section 4 |
| **Where the boot-firmware partition is** | `backup-common.sh` → `BX_ESP_PATHS` (used by `bx_esp_mount` and `backup-verify.sh`), `bx_backup_sources`, and the ESP block in `restore-rebuild-boot.sh` — **the accepted paths are `/boot/efi`, `/efi` and `/boot/firmware`** | Add your mountpoint to `BX_ESP_PATHS`, the sources list, and the rebuild script's loop. Stopgap until then: `BACKUP_EXTRA_SOURCES="/your/esp"` in the config gets it into the backup set. | The report's *ESP candidates*; `borg-backup.sh --dry-run` lists it under `backup sources` |
| **Which bootloader, and how to rebuild it** | `restore-rebuild-boot.sh` — the detection block (`IS_UKI`, `USES_GRUB`, `USES_SDBOOT`, `IS_PI_FW`) and the per-bootloader steps; an unknown bootloader **warns and continues** | Add a detection test and a rebuild step for rEFInd, Limine, syslinux/extlinux, U-Boot… The Raspberry Pi case (no bootloader, fix `root=PARTUUID` in `cmdline.txt`) is the template for a firmware-reads-the-partition board. | `restore-rebuild-boot.sh --dry-run` on the live system shows the plan; `tests/cli-test.sh` proves the dry run executes nothing |
| **Whether the archive is bootable** | `backup-common.sh` → `bx_boot_listing_counts`, used by `backup-verify.sh` section 3: patterns over the archive listing for a UKI, a `vmlinuz`/`Image`/`kernel*.img` or a kernel-install `<machine-id>/<version>/linux`, a `grub.cfg`, systemd-boot entries, and Pi `config.txt`+`cmdline.txt`. A bootloader they do not know produces a **false FAIL**: *"archive has NO bootloader config"* | Add a pattern for your bootloader's config file (or kernel name, e.g. `zImage`) and a synthetic listing to `tests/lib-fixture-test.sh`. | The fixture test; then `backup-verify.sh` after one real archive — section 3 must PASS |
| **Which initramfs tool** | `restore-rebuild-boot.sh` — `update-initramfs` / `dracut` / `mkinitcpio` by `command -v`; otherwise a warning | Add your generator. | `restore-rebuild-boot.sh --dry-run` shows the `would:` line |
| **Kernel command-line carriers on restore** | `lib-cmdline.sh` → `cl_find_carriers` (BLS/systemd-boot entries, `/etc/kernel/cmdline` + `cmdline.d`, `GRUB_CMDLINE_LINUX` + `grub.d`, `extlinux.conf`, `syslinux.cfg`, `cmdline.txt`, `refind_linux.conf`, `limine.conf`, `/etc/default/limine`) and `cl_rewrite_ids`; called by both restore scripts after the `fstab`/`crypttab` fix-up, checked by `cl_stale_ids` before reboot and by `backup-verify.sh` against the archive | Add your carrier's path to `cl_find_carriers` and, if it uses a new reference syntax, to `CL_REF_PREFIX`. | Add it to `tests/cmdline-fixture-test.sh`; `backup-verify.sh` section 3 reports "carriers agree with fstab/crypttab" |
| **Encrypted `/boot`, and which GRUB can open it** | `restore-rebuild-boot.sh` — `BOOT_ON_LUKS` from `/boot` (or `/`) being on `/dev/mapper/*`, then the container's LUKS version and KDF decide the GRUB floor (LUKS1 → 2.02, LUKS2/pbkdf2 → 2.06, argon2 → 2.12); `backup-verify.sh` section 6 says the same | A LUKS `/boot` opened under another path, or LVM-on-plain-disk, needs a `cryptsetup status` check instead of the prefix test; a new KDF needs a floor. | The report's boot-layout line `boot_on_luks=` and the rebuild's dry-run `encrypted /boot:` line |
| **Ad-hoc vs scheduled** | `deploy.sh` → `detect_schedule_mode` (removable, hotplug, or USB transport → ad-hoc) | Thunderbolt NVMe, SD readers and LVM stacks can misclassify. Override first: `SCHEDULE_MODE=` in the config or environment. | `sudo ./deploy.sh --dry-run` prints `Schedule mode (…): ` with the evidence |

**Step 2 — prove it, then send it.** Run what CI runs, then a real backup and
a verify on the machine, then send me both the patch and the report:

```bash
bash tests/run-all.sh                 # shellcheck, ruff, headers, all tests — must be green
sudo ./deploy.sh --dry-run && sudo ./deploy.sh
sudo borg-backup.sh && sudo backintime-backup.sh      # + timeshift-backup.sh on non-btrfs
sudo backup-verify.sh; echo "exit $?"                 # 0 = restore-ready
sudo ./backup-diag.sh -o backup-diag.md               # collected AFTER the above
```

Open an issue with the **New Linux setup** template, attach `backup-diag.md`
and the patch (or a pull request). **Please always send the report, even
without a patch** — it is auto-generated for exactly this, and it is what I
build the fix from for a setup I cannot reach. A working patch that passes the
tests gets your name on the copyright line of `LICENSE` next to mine, credit in
the release notes, and a row in [Contributors](#contributors) —
[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-linux-setup--and-getting-onto-the-license)
has the terms.

## Restore

Restore is universal across boot layouts. Boot from a live USB, unlock and mount
the backup drive and the target partitions, then run the launcher or a method
script directly:

```bash
sudo ./restore.sh                                   # interactive: snapper / btrfs / borg / BIT / combined
sudo ./borg-restore.sh /mnt/target /mnt/backup/borg-backup            # borg archive
sudo ./borg-restore.sh --dry-run /mnt/target /mnt/backup/borg-backup  # preview: no writes
sudo ./backintime-restore.sh /mnt/target /mnt/backup/backintime       # BIT snapshot
```

After extracting files, both method scripts fix up the new disk's ids in
`fstab` and `crypttab` **and in every kernel command-line carrier** — BLS and
systemd-boot entries, `/etc/kernel/cmdline` and `cmdline.d`,
`GRUB_CMDLINE_LINUX` and its drop-ins, `extlinux.conf`, `syslinux.cfg`, a Pi
`cmdline.txt`, `refind_linux.conf`, `limine.conf` — rewriting `root=`,
`resume=`, `rd.luks.uuid=`, `cryptdevice=` and friends while leaving mapper
*names* alone, then refuse to call the restore complete while any carrier
still names an id that does not exist on the new disk. Then they chroot in
and run **`restore-rebuild-boot.sh`**, which rebuilds the boot chain for
whatever the restored system uses — detected, not configured:

- initramfs via dracut, `update-initramfs`, or mkinitcpio; or a **UKI** rebuilt
  via `kernel-install` / `dracut --uefi`;
- **GRUB** (EFI or legacy BIOS, x86_64 or aarch64) reinstalled and its config
  regenerated, with `GRUB_ENABLE_CRYPTODISK=y` set and a warning when GRUB is
  older than 2.12 on an argon2id `/boot`;
- **systemd-boot** reinstalled with `bootctl` and entries recreated.

`restore-rebuild-boot.sh` is standalone and takes `--dry-run`, so you can preview
the exact boot steps inside an `arch-chroot` (or even on a live system) before
committing. It warns and continues on a bootloader or initramfs tool it does
not know — **read its warnings, not its exit code**. `--dry-run` on
`borg-restore.sh` / `backintime-restore.sh` previews the file extraction and
target-UUID detection and stops before any write.

## The tray

`backup-tray.py` (installed as `/usr/local/bin/backup-tray`, autostarted) shows
a "B" in the system tray — yellow while any layer is running, charcoal when it
is safe to unmount — and a menu with one section per layer this host actually
has: Snapper (btrfs roots), Borg (list, log, run, dry run, verify), Back In
Time (list, log, run, GUI), Timeshift (non-btrfs roots: list, log, run, GUI),
LUKS headers (run, log), Restore readiness (run the check, last scheduled
result), Troubleshooting (generate the report), and the drive's free space. It
reads `/etc/backup-system.conf`; nothing in it is per-host.

## Files

```
deploy.sh                     universal, policy-aware installer + drive set-up (--dry-run)
backup-common.sh              shared library: version, config load, layout/fs detection, package map, retention helpers
lib-cmdline.sh                every kernel command-line carrier: find, rewrite ids on restore, check against fstab/crypttab
backup-system.conf.example    per-host config template (installed to /etc/backup-system.conf)
borg-backup.sh                borg archive + btrfs replicas (btrfs roots)   --dry-run
backintime-backup.sh          BIT-format rsync snapshots                    --dry-run
timeshift-backup.sh           Timeshift snapshots + count/space retention (non-btrfs local layer)  --dry-run
backup-verify.sh              restore-readiness assertion (exit 0/1/2)
luks-header-backup.sh         LUKS header backup, keyslot-tagged
backup-diag.sh                troubleshooting report: read-only, redacted   (-o FILE, --no-redact, --full)
borg-backup-drive-attach.sh   unlock (if LUKS) + mount on connect, clears a stale mount/mapping; never backs up
borg-backup-drive-detach.sh   detach unit (started by the udev remove rule): lazy-unmount + close the mapping after a yank
patch-snapper-replicate.py    idempotent fixes for snapper-replicate.sh (btrfs snapper hosts)
restore.sh                    interactive restore launcher (snapper/btrfs/borg/BIT/combined)
borg-restore.sh               borg restore + UUID fixup + universal boot rebuild   --dry-run
backintime-restore.sh         BIT restore + UUID fixup + universal boot rebuild    --dry-run [--files-only]
restore-rebuild-boot.sh       universal boot-chain rebuild (GRUB/systemd-boot/UKI/encrypted-boot)  --dry-run
backup-tray.py backup-tray.desktop                 tray: every layer, run/log/verify/report by hand
*.service *.timer 99-borg-backup.rules             systemd units + udev attach/detach rule template
tests/                        lib fixtures, command lines, report redaction, deploy dry-run — what CI runs
docs/ABOUT.md                 the long-form description
```

## Frequently asked questions

### Which Linux distributions does this back up?

Any with `systemd` and one of `apt`, `dnf`, `pacman` or `zypper`: Fedora and
RHEL-family, Debian, Ubuntu, Linux Mint, Pop!\_OS, Arch, Manjaro, EndeavourOS,
CachyOS, openSUSE Leap and Tumbleweed, and Fedora Asahi Remix on Apple
Silicon. Derivatives resolve to their family through `ID_LIKE`, so they need
not be named anywhere. Which of those have been *confirmed* is in
[Tested / untested](#tested--untested).

### Does it work with an encrypted backup drive?

Yes, and that is the intended case. The drive is a LUKS volume; with a keyfile
enrolled (`deploy.sh` offers to), plugging it in unlocks and mounts it. The
borg repository is initialised with `--encryption=none` because the drive
provides the encryption at rest, and a LUKS header backup of every encrypted
device on the machine is kept on two disks.

### Can I use it with an unencrypted backup drive?

Yes, after typing `PLAIN` to accept, in one paragraph, what that means: the
drive is a readable copy of every file on the machine. Encrypt it in place
later — keeping the backups on it — with
[LinuxLocker](https://github.com/doug445/LinuxLocker), then re-run `deploy.sh`.

### Why is retention never based on age?

Because an external drive can sit in a drawer for six months, and the first
run after that must not delete anything for being "old". Retention keeps the
newest `KEEP` of each set, never fewer than `MIN_KEEP`, and only when the drive
is genuinely below `MIN_FREE_PCT` / `MIN_FREE_GIB` does it drop the oldest, one
at a time.

### Why does plugging the drive in not start a backup?

By policy. A backup that starts the moment a drive appears is a backup that
gets yanked mid-write. The attach unit unlocks and mounts; you start the
backup, or a timer does on an installed second drive.

### Does it back up a separate `/boot` and the ESP?

Yes — the source set is derived from the live mount table: `/`, a separate
`/home`, a separate `/boot`, and the ESP at `/efi` or `/boot/efi`. The Back
In Time layer rsyncs all of `/` crossing into those mounts; borg lists them
explicitly. `backup-verify.sh` then checks the newest archive actually contains
a kernel and a bootloader configuration.

### Does it handle btrfs snapshots, snapper and send/receive?

On a btrfs root, `borg-backup.sh` sends read-only snapshot replicas of every
btrfs source to the drive with `btrfs send/receive`, and
`patch-snapper-replicate.py` fixes the three known correctness bugs in a
`snapper-replicate.sh` if the host has one. On any other root, Timeshift is
the equivalent layer.

### What does "restore-verified" mean, exactly?

`backup-verify.sh` does not check that backups ran. It checks that what they
produced could rebuild the machine: the newest archive lists a kernel and a
bootloader configuration, every kernel command line in it names the same
devices its own `fstab` and `crypttab` do (a stale `rd.luks.uuid=` restores
to a machine that stops in the initramfs with every file present), the
stored LUKS headers match the live devices' keyslots, the keyfile opens the backup volume, the replica layer is intact, the
drive has room, and the boot chain has no known caveat. Exit 0 means a restore
would boot; 2 means it would not. A check that does not apply is SKIP, never a
pass.

### Will a restore boot on a UKI / systemd-boot / GRUB / BIOS machine?

`restore-rebuild-boot.sh` detects which one the restored system uses and
rebuilds it — initramfs or UKI, GRUB EFI or BIOS, systemd-boot — inside the
chroot. Its `--dry-run` plan has been checked on the encrypted-`/boot` GRUB
host; the plan has not yet been *executed* by a real bare-metal restore, which
is why that row is ❌.

### How is this different from just running borg on a timer?

Borg on a timer answers "did it run". This answers "would it restore", from
the same drive, on every layout, with the boot chain rebuilt for you — and it
keeps the ad-hoc drive, the count-based retention and the no-backup-on-plug-in
policy that a bare timer gets wrong.

### Does it work on a Raspberry Pi?

In design, yes — Raspberry Pi OS is the Debian family on aarch64, the backup
layers need nothing special, and a USB drive is ad-hoc like anywhere else. The
Pi boots without a bootloader: its firmware reads `config.txt`, `cmdline.txt`
and `kernel*.img` from a vfat partition at `/boot/firmware`. 3.3.0 recognises
that partition as the boot source, counts those files as a bootable archive in
the verify pass, and on restore rewrites `root=PARTUUID=` in `cmdline.txt` for
the new card instead of trying to install GRUB. **None of it has run on a
Pi** — it is a ❌ row, and a setup report from one is what turns it green.

### Can I run it on Apple Silicon?

Yes — Fedora Asahi Remix (aarch64) is the development platform. GRUB on
`arm64-efi`, m1n1/U-Boot in front of it, and a 16k-page kernel are all
handled; the verify pass notes the Asahi-specific caveats.

### Something is wrong on my distro — what do you need from me?

The troubleshooting report: `sudo ./backup-diag.sh -o backup-diag.md`. It is
read-only and redacted. Attach it to an issue, and if you have hand-rolled a
fix, the patch too — [Hand-rolling a fix](#hand-rolling-a-fix-for-your-setup-and-distro)
says where each decision lives.

## Not yet universal / TODO

- **Restore boot rebuild needs real-hardware verification.**
  `restore-rebuild-boot.sh` handles GRUB, systemd-boot, UKI and encrypted `/boot`
  and dry-runs correctly. On the encrypted-argon2id-`/boot` host it correctly
  detected `boot_on_luks=true`, `grub=true`, `uki=false`, resolved the locally
  built GRUB 2.14 (not the stock 2.12 in `/usr/sbin`) and planned
  `update-initramfs -k all -c` + `grub-install` + `update-grub` — but that plan
  has not yet been *executed* by a real bare-metal restore. Run the real restore
  path on hardware before trusting it, using `--dry-run` first.
- **Timeshift wrapper: create verified on ext4, prune still untested.**
  `timeshift-backup.sh` created a real snapshot on an ext4 root (Mint 22.3,
  2026-09-11) and `backup-verify.sh` confirmed its rsync payload. The count and
  free-space prune paths have still not fired on a real drive — that needs more
  snapshots than `KEEP`, or a drive tight enough to trip `MIN_FREE_*`.
- **The boot-firmware partition is only recognised at `/boot/efi`, `/efi` or
  `/boot/firmware`** (`BX_ESP_PATHS`). `BACKUP_EXTRA_SOURCES` is the stopgap.
- **The command-line rewrite on restore is exercised only against synthetic
  trees** (`tests/cmdline-fixture-test.sh`, every carrier kind). A real
  restore onto a fresh disk is the ❌ "bare-metal restore" row.
- **`backup-verify.sh` knows GRUB, systemd-boot, UKIs and Raspberry Pi firmware
  files.** rEFInd, Limine and syslinux archives produce a false "no bootloader
  config" FAIL until a pattern is added.
- **Raspberry Pi: written, never run.** The firmware-boot recogniser, the
  verify patterns and the `cmdline.txt` `root=PARTUUID` rewrite in
  `restore-rebuild-boot.sh` are exercised only against synthetic listings in
  the fixture test. The author has Pis in storage and no plan to run one; that
  row will stay ❌ until someone with a Pi sends a setup report.
- Every ❌ row above stays red until that setup has been run and verified on
  real hardware; each turns ✅ as that happens.

## Documentation

| Doc | Covers |
|---|---|
| [`docs/ABOUT.md`](docs/ABOUT.md) | The long-form description: the problem, who it is for, what makes it different, what it deliberately does not do |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Scope, the setup-report table, the troubleshooting report, adding a Linux setup and getting onto the license |
| [`SECURITY.md`](SECURITY.md) | Supported versions, reporting, what is in and out of scope, what never to send |
| [`backup-system.conf.example`](backup-system.conf.example) | Every per-host knob, with its default |
| [`.github/rulesets/`](.github/rulesets/README.md) | Branch and tag protection as JSON, applied to this repository |

## Contributing

The goal is one backup system that runs on **any Linux** — universal in fact,
not just in design — and one person cannot own every distro, filesystem and
boot layout. That is what contributions are for. This project takes **setup
reports**, **new Linux setups** (a report, or a patch that passes the tests)
and **serious bugs**, and any design change ideas. Any contribution from an 
author that is added to a version release with be added to the license.
[CONTRIBUTING.md](CONTRIBUTING.md) has the table of what is still unconfirmed;
a report that a setup *worked* is the only way a row gets ticked. Run what CI
runs before opening a pull request:

```bash
bash tests/run-all.sh
```

A working patch for a new setup that passes the tests puts **your name on the
copyright line of `LICENSE`** next to mine, in the release notes, and in the
table below.

## Contributors

| Contributor | Setup added | Release |
|---|---|---|
| *(none yet — the first working patch for a ❌ row goes here)* | | |

## Audit

Reviewed in full on 2026-09-12 by **Claude Fable 5.1** (Anthropic) ahead of
the 3.0.0 release: every script, the units, the tray and the documentation,
with each finding reproduced before it was fixed. Found and fixed in 3.0.0:
the `timeback` shell function was defined but never installed; the drive-attach
unit pointed at `/usr/local/bin` while the installer put the script in
`/usr/local/sbin`, so it failed on every host; the udev rule carried the
author's own drive UUID; the tray hardcoded the author's mount path, parsed
values out of a script that no longer held them, and had no Timeshift, LUKS
header, verify or troubleshooting sections; openSUSE was accepted by the
library and refused by the installer. Nothing in this suite has changed hands:
the design decisions are the author's, the audit checked that the code keeps
them.

## License and contact

MIT — see [LICENSE](LICENSE).

- **Version:** 3.4.2
- **Author:** William MacKinnon ([doug445](https://github.com/doug445))
- **Email:** spilled-bowline0j@icloud.com
- **Repository:** https://github.com/doug445/linux-backup-system

Copyright (c) 2026 William MacKinnon &lt;spilled-bowline0j&#64;icloud.com&gt;
