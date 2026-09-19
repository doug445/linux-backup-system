# About linux-backup-system

**linux-backup-system is a universal Linux backup and bare-metal restore
suite: one multi-layer codebase meant to run unchanged on any Linux system —
every distro, every root filesystem, every boot layout — that answers the only
question that matters once a disk is gone: could I actually restore this
machine?** It combines **Borg** deduplicated archives, **Back In
Time**-format rsync snapshots, a local snapshot layer chosen by the root
filesystem — **btrfs send/receive** replicas on btrfs, **Timeshift** on ext4
and everything else — keyslot-tagged **LUKS header backups**, and a
**restore-readiness check** that asserts, from what is actually on the backup
drive, that a rebuilt machine would boot. On restore, one script rebuilds the
boot chain for whatever the restored system uses: GRUB (EFI or legacy BIOS),
systemd-boot, Unified Kernel Images, an encrypted argon2id `/boot`.

Nothing in it is pinned to a machine. The backup drive, its guard UUID, the
unlock keyfile, the schedule policy and the retention live in one config file,
and every path that depends on the disk or the boot layout is derived at run
time.

This page is the long-form description of what the project is, who it is for,
and where its boundaries are. For how to run it, start with the
[README](../README.md).

---

## The problem it solves

Most Linux backup setups answer "did the backup run?" Almost none answer "would
the restore boot?" — and the second question is the one that is asked exactly
once, with the original disk gone. A borg archive with no kernel in it, a
snapshot tree that never crossed into the separate `/boot`, an ESP that was
mounted at `/efi` where the exclude list expected `/boot/efi`, a LUKS header
backup from before the last passphrase change: every one of those is a backup
that ran green for a year and restores to a machine that does not start.

The work is not the copying. **The work is knowing what this machine's boot
chain needs, proving the backup contains it, and being able to rebuild it on
a new disk** — and that is what linux-backup-system automates:

- deriving the source set from the live mount table — `/`, a separate `/home`,
  a separate `/boot`, the ESP wherever it is — so a bootable restore has
  everything, on every layout;
- choosing the local-snapshot engine from the root filesystem, not from a
  distro name;
- refusing to write to any drive but the one whose filesystem UUID the config
  pins;
- retention that is count-based and free-space based and **never** time-based,
  because an external drive can sit unplugged for months and age must never
  delete a backup;
- LUKS header backups whose filenames encode the active keyslots, so a stale
  header can never be mistaken for the live one;
- a verify pass that lists the newest archive and checks it for a kernel and a
  bootloader config, tests the stored headers against the live devices, and
  tests the keyfile against the backup volume — and exits non-zero when a
  restore would fail, whether or not the backup "ran";
- a restore that fixes up `fstab`, `crypttab` **and every kernel command-line
  carrier** — BLS and systemd-boot entries, `/etc/kernel/cmdline`, GRUB
  defaults and drop-ins, `extlinux.conf`, `cmdline.txt`, rEFInd, Limine — for
  the new disk's ids, refuses to finish while any of them names a device that
  does not exist, then chroots in and rebuilds the initramfs, the UKI, GRUB or
  systemd-boot for whatever it finds there.

## Universal, and why that is a call for contributions

"Universal" here is a design rule before it is a claim. Nothing in the suite
is keyed to a distro name: the package manager, the root filesystem, the
snapshot engine, where the ESP is, whether `/boot` is its own filesystem,
which bootloader and initramfs generator the machine uses, whether the backup
drive is removable — all of it is read from the machine at run time, and
derivatives inherit support from their family through `ID_LIKE`. A Linux
system this suite has never seen is therefore not a port to write but a
detection gap to close: one wrong line in the troubleshooting report, one
function to fix, one fixture to add.

One maintainer cannot own every distro, filesystem and boot layout, which is
why the status tables in [STATUS.md](STATUS.md) are honest about what has been confirmed on
metal and why the project asks for setup reports and patches. The gap that
most needs other hands is the package map: the suite knows `apt`, `dnf`,
`pacman` and `zypper`, and a Slackware, Gentoo, Turbolinux, Alpine, Void,
NixOS or Solus system needs someone who runs one to add its package manager
and package names — a small patch, and the one the project asks for first. A working patch
for a setup that passes the tests puts the contributor's name on the license.
That is the mechanism by which "universal" becomes true.

## Who it is for

- **Anyone with more than one Linux machine** who wants one backup codebase
  across a Fedora box, a Mint laptop and an Apple Silicon Asahi machine, rather
  than three half-remembered setups.
- **People who plug a drive in when they think of it.** Ad-hoc is the default
  policy: an external drive unlocks and mounts on connect and a backup runs
  when a human starts it — from the tray, or the command line — and never
  because the drive appeared.
- **People with a second internal drive** who want the daily timers instead.
  The installer detects which case it is.
- **Anyone who has been burned by a restore.** The verify pass and the
  boot-chain rebuild exist because the author has.
- **btrfs users** who want snapper snapshots replicated off-machine by
  send/receive, and **ext4 users** who get Timeshift as the equivalent layer
  without configuring anything.

## What makes it different

**It is keyed off the machine, not off a distro name.** Which package
manager, which root filesystem, where the ESP is, whether `/boot` is its own
filesystem, whether the backup drive is removable — every decision is made
from what the machine shows at run time. Derivatives inherit support from
their family through `ID_LIKE`, so Fedora Asahi Remix, Nobara, Pop!\_OS,
EndeavourOS and CachyOS are covered by the same rule as their parents.

**Retention never deletes by age.** `KEEP` newest of each set, never below
`MIN_KEEP`, and only when the drive is genuinely below `MIN_FREE_PCT` or
`MIN_FREE_GIB` does it drop the oldest, one at a time. A drive that was in a
drawer for six months comes back with everything it had.

**Auto-backup-on-connect does not exist here.** The udev rule and the attach
unit unlock and mount; nothing starts a backup. That is a policy, enforced in
the units, because a backup that starts the moment a drive appears is a backup
that gets yanked mid-write.

**The verify pass is not "did it run".** It is "could this be used to rebuild
the machine" — a different question, and the only one that matters when the
disk is gone. A check that does not apply is reported as SKIP, never quietly
counted as a pass.

**`--dry-run` is real, everywhere.** The installer, both backup scripts, the
Timeshift wrapper, both restore scripts and the boot-chain rebuild all take
it, and each runs its entire detection and logs every action it would take
before stopping short of the first write.

**It tells you what it thinks.** Every backup log opens with a detection dump
— version, host, root filesystem, snapshot engine, ESP, sources, retention —
and the troubleshooting report puts the suite's detection next to the raw
`lsblk` / `findmnt` / `fstab` it was derived from, so a wrong decision is
visible as a disagreement between two sections of one file.

## What it deliberately does not do

- **It does not encrypt.** The backup drive is a LUKS volume you made; the
  suite unlocks it with a keyfile you enrolled and writes to it. The borg
  repository is initialised without its own encryption because the drive
  provides it.
- **It does not back up on a schedule unless the drive is installed.** A
  removable drive means ad-hoc, and ad-hoc means a human starts it.
- **It does not delete by age.** Ever.
- **It does not configure the boot layout.** Nothing about the machine goes in
  the config file. If detection is wrong for your setup, the fix is a detection
  fix, and the README says how to hand-roll one.
- **It cannot make a Mac boot from nothing.** On Apple Silicon the firmware's
  own partitions, m1n1 and U-Boot are Apple-managed; a dead Mac is reinstalled
  with the Asahi installer from macOS, and this backup is restored over the
  fresh install. Bare metal, on that hardware, means "after the installer".
- **It has no backdoor.** A lost keyfile and a forgotten drive passphrase mean
  the drive is gone. That is the drive working.

## Safety posture

This tooling runs as root, unlocks a drive with a keyfile, and on restore
rewrites the boot chain of a machine. The project's answer to that is not
reassurance but machinery: the fs-UUID wrong-drive guard, the masked timers on
ad-hoc drives, the attach unit that cannot start a backup, the retention floor,
the keyslot-tagged header filenames, the verify pass that exits non-zero, the
detection dump at the top of every log, and `--dry-run` on every script.

The library and every command line are exercised in CI on x86_64 and aarch64
for every push, including `deploy.sh --dry-run` as root with proof that it
installed nothing and the troubleshooting report with proof that it redacted.
What CI cannot prove is that a real machine of *your* kind backs up and
verifies — the status tables in [STATUS.md](STATUS.md) say which ones have.

Read [`SECURITY.md`](../SECURITY.md) before filing anything, and especially
before attaching diagnostics: a backup system's artefacts include the keys to
the drive they live on.

## Project facts

| | |
|---|---|
| **License** | MIT |
| **Language** | Bash for every backup, verify and restore path, `shellcheck -S warning` clean; Python 3 (GTK/AppIndicator) for the tray only |
| **Architectures** | x86_64, aarch64 (Apple Silicon under Fedora Asahi Remix included) |
| **Distro families** | Fedora / RHEL, Debian / Ubuntu / Mint, Arch / Manjaro, openSUSE — derivatives via `ID_LIKE` |
| **Root filesystems** | btrfs (snapper + send/receive), ext4 (Timeshift); any other root takes the Timeshift layer, unverified |
| **Boot layouts** | GRUB EFI, GRUB legacy BIOS, systemd-boot, Unified Kernel Images, encrypted argon2id `/boot`, plain `/boot`, Raspberry Pi firmware boot, Limine, rEFInd (untested) |
| **Layers** | Borg, Back In Time format (direct rsync), btrfs send/receive or Timeshift, LUKS header backup, restore-readiness verify |
| **Requires** | borg, rsync, cryptsetup; `btrfs-progs` + snapper on btrfs; timeshift elsewhere — each script installs what it is missing |
| **Author** | William MacKinnon &lt;spilled-bowline0j@icloud.com&gt; |
| **Source** | https://github.com/doug445/linux-backup-system |
