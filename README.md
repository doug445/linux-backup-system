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
Remix on Apple Silicon, Debian, Ubuntu, Linux Mint, Arch, Manjaro, EndeavourOS, openSUSE;
x86_64 and aarch64.

Nothing here is pinned to a machine: the backup drive, its guard UUID, the
unlock keyfile, the schedule policy and the retention live in
`/etc/backup-system.conf`, and every path that depends on the disk or boot
layout is derived at run time. It replaces the older `BIT_deploy` and
`borg-backup` projects, which were Back-In-Time-centric and carried one host's
paths hardcoded.

> ### ⚠️ Testing only unless your setup is all green
>
> **Unless your distro, root filesystem and boot layout are all ✅ in the
> *Bare-metal restore* column of [Tested / untested](#tested--untested), this
> suite is for testing only. Do not use it in production until all are green.**
> A backup you have never restored is a hope, not a backup; a ⚠️ or ❌ restore
> row means nobody has yet booted that setup from a restored disk.

> ### Status: ✅ verified on metal, ⚠️ undergoing testing now, ❌ not written or not yet verified
>
> "Universal" is the goal and the design; the proof is per setup. The
> [Tested / untested](#tested--untested) tables say which distros, root
> filesystems and boot layouts have been confirmed with a real backup and a
> passing `backup-verify.sh` on real hardware. **Each ❌ row turns ⚠️ while it
> is being tested and ✅ once it is verified** — by the author where the hardware exists,
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

## Why three backup layers instead of one

A single backup tool is a single point of failure. Every backup program has a
format, a code path and a retention policy, and each of those can fail
silently: a deduplicated repository with one corrupt chunk, an rsync run that
quietly stopped copying a directory, a snapshot engine that pruned the wrong
thing. If that one tool is your only copy, its bug is your data loss. Three
independent layers on Linux — a deduplicated **Borg archive**, plain **rsync
file snapshots** (Back In Time format) and a **filesystem-level snapshot**
(btrfs send/receive or Timeshift) — fail in different ways, are read back by
different code, and give you three different ways to get a machine back:

| Need | Layer that answers it | Why the others don't |
|---|---|---|
| Roll the whole OS back after a bad update, in minutes | btrfs / Timeshift snapshot | borg and rsync restores rebuild file by file |
| Get one file, one directory, or one config from last month | BIT rsync snapshot | plain files, browsable with `ls`, `cp`, any file manager, no tool required |
| Long history in little space, encrypted, integrity-checked | Borg archive | dedup + compression; `borg check` proves the bits are intact |
| Restore onto a fresh disk and have it **boot** | any layer + `restore-rebuild-boot.sh` | that is what `backup-verify.sh` asserts every day |

The point is not redundancy for its own sake. Each layer covers a failure the
other two cannot, and a restore-readiness check runs against all of them so a
broken layer is found on a normal day, not on the day the disk dies. That is
what makes this a **restorable** Linux backup strategy rather than a backup
that merely exists.

### The recommended 3-2-1 storage strategy

The widely recommended **3-2-1 backup strategy** is: keep **3** copies of your
data, on **2** different kinds of storage media, with **1** copy off-site.
Modern variants add **1** copy offline or immutable (against ransomware and
accidental deletion) and **0** errors on verification (3-2-1-1-0). How the
layers here map onto it:

- **3 copies** — the live system plus the three independent backup layers.
- **2 media** — the internal disk and a separate backup drive; a second drive
  of a different type (SSD vs spinning disk, or a NAS) covers the "different
  media" clause fully.
- **1 off-site** — the Borg repo is the natural candidate: it is encrypted and
  deduplicated, so pushing it to a remote host over SSH, to a storage provider,
  or to a drive kept at another address costs little bandwidth and exposes no
  plaintext. `borg` can target a second repository directly, or the repository
  directory can be mirrored with `rsync`.
- **1 offline** — in ad-hoc mode the backup drive is unplugged between runs, so
  it is unreachable by ransomware or a stray `rm -rf` on the live system.
- **0 errors** — `backup-verify.sh` runs daily and fails loudly when a restore
  would not boot, the verification step most setups skip. A real restore onto
  spare hardware after deploying, and after any change to the boot layout,
  proves the rest.

Apply the full rule to the machines whose data you cannot recreate; a
disposable box gets the on-site layers and nothing more.

## Tested / untested

Two columns, two different claims:

- **Backup + verify** — ✅ a real backup **and** a `backup-verify` pass have been
  confirmed on that setup; ⚠️ it is deployed on real hardware and being run,
  but that pass is not recorded yet; ❌ the code paths exist and dry-run clean,
  and that exact combination has **not** been verified.
- **Bare-metal restore** — ✅ a backup of that setup has been restored onto a
  **different, blank disk** by the suite's own restore scripts, the disk has
  **booted** (unlocked, logged in, network up), and the restored files were
  compared against the archive — with [`testbed/testbed.sh`](#the-restore-test-bed),
  which proves the source machine's disks were not written; ⚠️ that restore is
  under test now; ❌ not yet restored and booted.

**Unless every row that describes your machine is ✅ in the Bare-metal restore
column, use the suite for testing only — not in production.**

**Verified on 9 tested systems** — the machines behind the ✅ rows: [docs/TESTED-SYSTEMS.md](docs/TESTED-SYSTEMS.md).

**Distros**

| Distro | Backup + verify | Bare-metal restore |
|---|:--:|:--:|
| Fedora | ✅ | ✅ |
| Fedora Asahi Remix (Apple Silicon, aarch64) | ✅ | ✅ over a fresh Asahi install (never bare metal — see the FAQ) |
| Debian / Ubuntu / Linux Mint | ✅ | ✅ |
| Arch / Manjaro / EndeavourOS | ✅ | ✅ |
| openSUSE (Leap / Tumbleweed) | ❌ — **contributions wanted**, see [Contributing](#contributing) | ❌ not under test |
| **Slackware, Gentoo, Turbolinux, Alpine, Void, NixOS, Solus** — package managers the map does not know yet (`slackpkg`, `emerge`, `apk`, `xbps`, `nix`, `eopkg`) | ❌ — **contributions wanted**, see [Contributing](#contributing) | ❌ not under test |

**Root filesystems** (this picks the local-snapshot engine — see Layers)

| Root fs | Local-snapshot engine | Backup + verify | Bare-metal restore |
|---|---|:--:|:--:|
| btrfs (subvolumes, swapfile) | btrfs send/receive (`borg-backup.sh`) | ✅ | ✅ |
| ext4 | Timeshift (`timeshift-backup.sh`) | ✅ | ✅ |
| xfs / f2fs / anything else | Timeshift | ❌ — **contributions wanted** | ❌ not under test |
| root on LUKS2, unlocked by sd-encrypt (`rd.luks.name=` + `crypttab.initramfs`) | — | ✅ | ✅ |
| root on LVM-on-LUKS | — | ✅ | ✅ |

**Boot layouts**

| Setup | Backup + verify | Bare-metal restore |
|---|:--:|:--:|
| systemd-boot (Type #1 entries, no UKI) | ✅ | ✅ |
| systemd-boot + UKI (unified kernel image), rebuilt by mkinitcpio presets | ✅ | ✅ |
| UKI rebuilt by dracut or kernel-install | ✅ | ✅ |
| **Secure Boot with your own keys** (sbctl) — the rebuilt loader and UKIs re-signed | ✅ | ✅ |
| Secure Boot through shim (Fedora, Ubuntu) | ✅ | ⚠️ |
| GRUB (EFI) | ✅ | ✅ |
| GRUB (legacy BIOS) | ❌ — **contributions wanted** | ❌ not under test |
| Standard `vmlinuz` + `initramfs` (non-UKI) | ✅ | ✅ |
| ESP at `/efi` + vfat XBOOTLDR `/boot` | ✅ | ✅ |
| Encrypted argon2id `/boot` (needs GRUB 2.14 or later — 2.12 has no argon2) — incl. GRUB built from source into `/usr/local` behind the distro's shim | ✅ | ✅ |
| Encrypted pbkdf2 `/boot` — LUKS1 (GRUB ≥ 2.02) or LUKS2 with pbkdf2 (GRUB ≥ 2.06), the form stock GRUB opens | ❌ — **contributions wanted** | ❌ not under test |
| Plain `/boot` (unencrypted /boot) | ✅ | ✅ |
| Raspberry Pi firmware boot (`/boot/firmware`: `config.txt`, `cmdline.txt`, `kernel*.img`; no bootloader) | ❌ — **contributions wanted** | ❌ not under test |
| Limine (CachyOS's default) — loader reinstalled, firmware boot entry created | ❌ — **contributions wanted** | ❌ not under test |
| rEFInd — `refind-install`, or binary + firmware boot entry | ❌ — **contributions wanted** | ❌ not under test |
| SELinux restore relabel on Linux Mint (SELinux permissive) — `/.autorelabel` on the restored system: the first boot relabeled every file and rebooted once, then booted clean | ✅ | ✅ |
| SELinux restore relabel on Fedora (SELinux enforcing) — `/.autorelabel` on the restored system: the first boot relabeled every file and rebooted once, then booted clean and enforcing | ✅ | ✅ |
| Restore from an **installed system** onto a second disk, the original disk still installed — no NVRAM writes, nothing written to the original disk | — | ✅ |
| Restore from a live USB | — | ⚠️ |
| Apple Silicon (Asahi) restore — **never bare metal**: reinstall with the Asahi installer from macOS, then restore over the fresh install (see [FAQ](#can-i-run-it-on-apple-silicon)) | ✅ | ✅ |

A ❌ row turns ⚠️ when that setup is deployed and being run on real hardware.
In the Backup + verify column it turns ✅ when it has produced one real backup on
each layer and has passed `backup-verify.sh`, with the
[troubleshooting report](#troubleshooting-logs-dry-runs-and-the-report) from
that machine kept as the evidence. In the Bare-metal restore column it turns ✅
when [`testbed.sh collect`](#the-restore-test-bed) has returned `VERDICT: PASS`
for it, and its state directory is kept as the evidence. Every backup, the
installer and the restore take `--dry-run` first.

### The restore test bed

`testbed/testbed.sh` turns "the restore should work" into a verdict, on any
machine, with two spare drives: the backup drive and a **test drive** that is
wiped on every run.

```bash
cp testbed/testbed.conf.example /mnt/backup/testbed/testbed.conf   # the two drives' serials, once
sudo testbed/testbed.sh plan                                # the test drive laid out like THIS machine
sudo TB_WIPE=<test-drive-serial> testbed/testbed.sh all     # fingerprint, wipe, partition, LUKS, backup, restore, logger, VM boot
sudo testbed/testbed.sh vmboot                              # (run by finish) boot the test drive in QEMU first — snapshot, no network → VM verdict
# reboot, pick the test drive's "UEFI:" entry in the firmware menu (a Mac: Option key, the drive labelled TEST; passphrase: test, unless finish says it unlocks itself), wait five minutes, boot back
sudo testbed/testbed.sh collect                             # boot report, fingerprint diff, byte comparison → VERDICT
sudo testbed/testbed.sh revert                              # undo every test-only change
```

It lays out the first 100 GiB of the test drive (`TB_TARGET_GIB`, 0 = all of
it; the rest stays unpartitioned) and mirrors the host: ESP location, a separate vfat or ext4 `/boot` — encrypted
too, opened by GRUB — swap and `/home` partitions, LUKS with the host's own
version and KDF parameters (so its GRUB can still open it) plus the keyfile its
crypttab names, root on LVM (the volume group is created under a temporary name,
since the host holds the real one, and renamed by `finish`), the btrfs
subvolumes fstab mounts. The test archive goes to
its own repository (`borg-testbed-<host>`), keeping every home's configuration,
keys, shell setup, desktop state (`~/.local/share`'s panel themes, plasmoids,
color schemes, icons, terminal profiles) and Claude Code but no bulk data; the host config is not
touched, and no btrfs replica is written or pruned — the backup drive can be
another machine's production drive, and replicas share one directory pruned by
label. `testbed.conf` is copied into the run's state directory, so `collect`
finds it with the backup drive unplugged. The restore runs from a frozen copy of the suite. `fingerprint`
records the machine's own disks — partition tables, exact LUKS headers, every
file on `/boot` and the ESP, firmware boot entries — before and after, and the
verdict fails if anything but the expected (systemd-boot's random seed, a
firmware reordering its boot menu) changed. The booted test drive leaves its
report and journal on the host's unencrypted boot partition, the one place it
writes — as soon as the verdict and health sections exist, and again when the
byte comparison is done (`collect` fails a partial report); every
step is recorded in a ledger with its revert. `finish` sets `noauto` on the
restored crypttab and fstab entries for the host's other disks (a data drive,
an SD card — their keyfiles come back with the restore), never on the boot
chain's own, so the test boot unlocks and mounts none of them. Test drives always get the
passphrase `test`. Where the host's own boot chain opens them without a prompt,
so does the test drive: containers the restored crypttab opens by keyfile get the
host's keyfile as a second key, and an encrypted `/boot` is opened by a test-only
rebuild of the GRUB fallback loader carrying `test` built in (`cryptomount -p`,
GRUB ≥ 2.12; the restore's own loader is kept beside it). A root the host unlocks
by passphrase in the initramfs asks for `test` at boot — `finish` says which. The
suite's real restore scripts never carry a passphrase. Not
mirrored yet (the suite restores them; the test bed cannot lay them out): root
on mdadm RAID, a volume group over several physical volumes.

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

On non-btrfs hosts `deploy.sh` also switches **Timeshift's own scheduler off**
(every `schedule_*` flag in `/etc/timeshift/timeshift.json`, plus its
`cron.d/timeshift-hourly` and `timeshift-boot` entries), forces rsync mode and
pins it to the backup drive. Timeshift's built-in schedule is time-based and
prunes by age, which is exactly what fleet retention must never do; the
`timeshift-backup` timer is the only thing that creates Timeshift snapshots.

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
| `CAPACITY_HEADROOM_PCT` | 20 | the drive must hold the sources' used bytes plus this much, or it is **refused** |
| `CAPACITY_RECOMMEND_X` | 2 | the drive should be this many times the Linux filesystems it backs up; below it, a warning |
| `CAPACITY_CHECK` | refuse | `refuse` / `warn` / `off` — the floor is measured on the whole filesystem of each source, so a btrfs system disk that also holds 1.5 TiB of VM images beside a 100 GiB system needs `warn` to use a 1 TiB drive |
| `BACKUP_HOST_ID` | the hostname at deploy | what this host's backups are filed under (borg archive prefix, Back In Time chain, replica names); pinned so a hostname change never orphans the chain |
| `BACKUP_EXTRA_EXCLUDES` | empty | extra exclude patterns for the file-level layers, anchored at `/`; borg and Back In Time share one list |
| `BACKUP_EXTRA_INCLUDES` | empty | paths re-included inside an excluded tree — they win over every exclude (`/home/*/*` excluded, `/home/*/.config` kept); a directory carries its subtree |
| `BX_LOCK_WAIT` | 7200 | seconds a layer waits for another layer's run to finish (all three take one lock; 0 = skip) |

Normal runs keep `KEEP`. Only when the drive is genuinely tight does it drop the
oldest, one at a time, down to `MIN_KEEP`. `KEEP` can never be set below
`MIN_KEEP` (it is raised), a non-number falls back to the default, and every
count prune is per set: one btrfs source that can never be snapshotted (a
swapfile in `@`) no longer switches pruning off for every other set. A delete
that fails (read-only drive, a locked repo) stops the free-space prune instead
of looping on it. Two layers never prune at once — borg, Back In Time and
Timeshift take one lock, and the second one queues.

**What is backed up.** `/` and every separately mounted local filesystem the
machine is made of — a separate `/home`, `/boot`, the ESP, openSUSE's `/var`,
`/opt`, `/srv`, `/root` and `/usr/local` subvolumes, a classic separate `/var`
partition, every ZFS dataset — found from the live mount table, not a list.
The backup drive itself, removable media, network shares, docker overlays,
snap images and bind mounts of a directory already inside a source are left
out, as are active swapfiles. `BACKUP_EXTRA_SOURCES` adds a mount the rule
would skip (`/mnt/data`), and it is then included even though `/mnt/*` is on
the exclude list.

Precedence is environment > `/etc/backup-system.conf` > built-in default, so a
one-off override needs no config edit:

```bash
sudo env KEEP=5 /usr/local/sbin/timeshift-backup.sh --prune-only   # apply retention, no new snapshot
```

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
non-btrfs roots it installs Timeshift as the local-snapshot layer and
configures it as a pure engine for `timeshift-backup.sh`: built-in schedule
off, rsync mode, pinned to the backup drive (idempotent; the exclude list is
left alone).

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

**How big the drive must be.** Before a drive is formatted or adopted — and
before every backup — the suite sizes it against this machine. The **floor**
is one full copy of everything in the backup sources plus 20% spare room,
measured against actual filesystem usage, not disk size: a drive below it
cannot hold even one backup and is **refused**, by `deploy.sh` in the picker
and by every backup script before it writes. The **recommendation** is twice
the total size of the Linux filesystems in the backup sources — root, `/home`,
`/boot`, the ESP, each counted once — so there is room for many generations of
every layer; below that the drive is accepted and the recommendation is
stated. It is deliberately not the whole disk: on a dual-boot or Apple Silicon
machine most of the disk belongs to another OS and is never backed up. `deploy.sh`
prints the numbers for this machine on every run, and `backup-verify.sh`
section 5 checks the mounted drive the same way. Knobs: `CAPACITY_HEADROOM_PCT`
(20) and `CAPACITY_RECOMMEND_X` (2) in the config.

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
sudo /usr/local/sbin/backup-verify.sh                # read-only (the timer never passes --fix)
sudo /usr/local/sbin/restore-rebuild-boot.sh --dry-run   # the boot-chain plan a restore would execute here
```

`backup-verify.sh` section 7 names the leftovers of a long-lived system that a
restore carries over: unified kernel images of kernels removed since (the menu
still offers them; nothing can rebuild them), an ESP GRUB stub searching for a
filesystem that no longer exists, a `GRUB_FONT`/`GRUB_THEME` that does not
exist (`grub-mkconfig` aborts on it and leaves only `grub.cfg.new`), and files
whose SELinux label the loaded policy does not know — a removed policy module
leaves its type behind, and `btrfs receive` then refuses the whole replica.
`sudo backup-verify.sh --fix` repairs them in place: the images move to
`/var/lib/linux-backup-system/stale-ukis/`, the stub is pointed at the
filesystem holding `grub.cfg`, the font is built from the installed TTF, the
files are relabeled with `restorecon -R`. The restore handles the same cases on
the restored disk by itself.

`timeshift-backup.sh` also takes `--prune-only` (retention without a new
snapshot). Its prune treats a snapshot directory without `info.json` — which
Timeshift writes last — as aborted and removes it, then keeps the newest `KEEP`
complete snapshots, then frees space oldest-first down to `MIN_KEEP`. Every
`timeshift` call is pinned to the backup drive with `--snapshot-device`, never
to whatever device Timeshift's own config remembers. `backup-verify.sh` applies
the same completeness rule.

**The drive dropped in the middle of a backup — and every USB port seems
dead.** Usually neither the drive nor the ports. Two things combine:

1. Some USB bridges (Realtek RTL9201/RTL9210, some JMicron and ASMedia) reset
   their UAS link under a long sustained write — an hour-long `btrfs send` is
   the classic trigger. The kernel log shows `uas_zap_pending … inflight`,
   `USB disconnect`, and the drive re-enumerating a second later. The backup
   in progress fails; the btrfs drive goes read-only for that mount and is
   consistent on the next one (copy-on-write, the transaction is aborted).
2. USB authorization then keeps it out. With USBGuard and a lock hook that
   blocks inserted devices while the session is locked, the re-enumerated
   drive — and anything re-plugged to "test the port", a mouse receiver
   included — stays blocked. It looks like dead hardware; **unlocking the
   session brings the ports back, no reboot needed** (or `usbguard list-devices
   | grep block` then `usbguard allow-device <id>`).

The backup scripts now say this in their log when the drive is missing, and the
troubleshooting report has a *USB: drops, bridge resets and authorization*
section. To make the bridge itself stable: smaller UAS transfers for this run
(`echo 128 | sudo tee /sys/block/sdX/queue/max_sectors_kb`, lost at the next
plug-in), or, permanently, force the slower BOT transport for that bridge
(`options usb-storage quirks=<vid>:<pid>:u` in `/etc/modprobe.d/`) — which on
most bridges also loses TRIM. Keep the session unlocked for a long first
backup either way.

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

The line that disagrees with reality is the bug. The report also shows what
detection alone cannot: whether `lsblk` and udev agree on each disk's serial,
the firmware boot entries and what each shim on the ESP really chains to, the
SELinux mode, other machines' data on the backup drive, and every restore test
bed run with its verdict. Then:

| Decision | Where it is made | What to change | How to prove it |
|---|---|---|---|
| **Distro family → package manager** | `backup-common.sh` → `bx_distro_family` (matches `ID` and each word of `ID_LIKE` from `os-release`) and `bx_pkg_install_cmd`; `deploy.sh` → `detect_distro` (the same families, plus per-family package names) | Add your `ID` / `ID_LIKE` token to the family it belongs to, or add a family with its install command. Both places, or the library will accept a distro the installer refuses. | Add a synthetic `os-release` case to `tests/lib-fixture-test.sh`; `sudo ./deploy.sh --dry-run` prints `Distro:` with the right family |
| **Package names** (borg, Back In Time, AppIndicator, Timeshift) | `backup-common.sh` → `bx_pkg_for`; `deploy.sh` → `detect_distro` (`BIT_PKGS`, `BORG_PKG`) and the two `case "$DISTRO_FAMILY"` blocks in *Step 1: Install packages* | Map the command to your distro's package name. | `sudo borg-backup.sh --dry-run` — its `[deps]` lines name what it would install |
| **Root filesystem → snapshot engine** | `backup-common.sh` → `bx_snapshot_engine` (btrfs → send/receive, else Timeshift); consumed by `borg-backup.sh` (replica block), `timeshift-backup.sh` (early exit on btrfs), `backup-verify.sh` (section 4) | A new engine means a new branch in all four. A filesystem that should simply use Timeshift needs nothing — it already does. | `--dry-run` of both backup scripts; one real run; `backup-verify.sh` section 4 |
| **Where the boot-firmware partition is** | `backup-common.sh` → `BX_ESP_PATHS` (used by `bx_esp_mount` and `backup-verify.sh`), `bx_backup_sources`, and the ESP block in `restore-rebuild-boot.sh` — **the accepted paths are `/boot/efi`, `/efi` and `/boot/firmware`** | Add your mountpoint to `BX_ESP_PATHS`, the sources list, the rebuild script's loop, and the ESP loop in both restore scripts. Stopgap until then: `BACKUP_EXTRA_SOURCES="/your/esp"` in the config gets it into the backup set. | The report's *ESP candidates*; `borg-backup.sh --dry-run` lists it under `backup sources` |
| **Which bootloader, and how to rebuild it** | `restore-rebuild-boot.sh` — the detection block (`IS_UKI`, `USES_GRUB`, `USES_SDBOOT`, `USES_LIMINE`, `USES_REFIND`, `IS_PI_FW`) and the per-bootloader steps; `efi_boot_entry` creates the firmware boot entry; an unknown bootloader **warns and continues**. On the Fedora family with shim on the ESP the signed `grubx64.efi` is kept, not reinstalled — and it may not be GRUB at all (a hand-made setup can put systemd-boot there): the report's *what each shim on the ESP chains to* says which | Add a detection test and a rebuild step for syslinux/extlinux, LILO, U-Boot… (Limine and rEFInd are the templates for a loader that makes no boot entry of its own) The Raspberry Pi case (no bootloader, fix `root=PARTUUID` in `cmdline.txt`) is the template for a firmware-reads-the-partition board. | `restore-rebuild-boot.sh --dry-run` on the live system shows the plan; `tests/cli-test.sh` proves the dry run executes nothing |
| **Whether the archive is bootable** | `backup-common.sh` → `bx_boot_listing_counts`, used by `backup-verify.sh` section 3: patterns over the archive listing for a UKI, a `vmlinuz`/`Image`/`kernel*.img` or a kernel-install `<machine-id>/<version>/linux`, a `grub.cfg`, systemd-boot entries, and Pi `config.txt`+`cmdline.txt`. A bootloader they do not know produces a **false FAIL**: *"archive has NO bootloader config"* | Add a pattern for your bootloader's config file (or kernel name, e.g. `zImage`) and a synthetic listing to `tests/lib-fixture-test.sh`. | The fixture test; then `backup-verify.sh` after one real archive — section 3 must PASS |
| **Which initramfs or UKI generator** | `restore-rebuild-boot.sh` — for unified kernel images `UKI_TOOL` comes from configuration, not from what is installed: mkinitcpio `default_uki=`/`fallback_uki=` presets, dracut `uefi=yes`, `layout=uki` in `/etc/kernel/install.conf` for kernel-install (every systemd host has kernel-install; picking it on a mkinitcpio box left the old command line embedded). Plain initramfs: `update-initramfs` / `dracut` / `mkinitcpio` by `command -v`, one kernel at a time. After the rebuild a rescue UKI is rebuilt with dracut and images of kernels no longer in `/lib/modules` move to `/var/lib/linux-backup-system/stale-ukis/` | Add your generator, and the configuration that says it is the one in use. Images it names differently from `<token>-<version>.efi` need their own orphan rule. | `restore-rebuild-boot.sh --dry-run` shows the `would:` lines; the restore's verification lists every UKI's embedded command line as OK or FAIL |
| **What goes into the archive** | `backup-common.sh` → `bx_backup_sources`, `bx_excludes`, `bx_includes`, `bx_borg_patterns`. An include inside an excluded tree (`BACKUP_EXTRA_INCLUDES="/home/*/.config"` under `/home/*/*`) gets every directory above it as an exact `re:` match: the directory entry is archived, its other contents are not. Without those, a restore recreated the parents root-owned (`~/.local` and `~/.local/share` as `root:root 700`, found by inspecting a restored drive); `borg-restore.sh` now gives any directory the extract had to create the owner and mode of its nearest archived ancestor | A new kind of include or exclude goes through `bx_borg_patterns`; keep the parent rule for it. Exclude the contents of a system directory, not its first level, where packages create directories with their own owners: `/var/cache/*/*`, not `/var/cache/*` (a restore came back with `/var/cache/lightdm` missing and `akmods` root-owned). `bx_source_fully_excluded` counts both forms, so such a tree still gets no btrfs replica. | `borg list <repo>::<archive> <parent dirs>` shows them with the right owner; `tests/lib-fixture-test.sh` checks the pattern order and the parent lines |
| **Leftovers a restore carries over** | `backup-common.sh` → `bx_orphan_ukis`, `bx_dead_grub_stubs`, `bx_grub_missing_files` (only where a `grub.cfg` exists), `bx_unlabeled_paths`; reported by `backup-verify.sh` section 7 and repaired by `--fix`; the restore handles the same cases on the new disk | A new class of leftover (something harmless on the running system that breaks a backup layer or a restore) is a detector there, a repair behind `--fix`, and a line in section 7. Never repair a loader that is not the boot path. | A synthetic tree in `tests/lib-fixture-test.sh` (`BX_ROOT=`); `backup-verify.sh` section 7 before and after `--fix` |
| **SELinux relabel** | `borg-restore.sh` — `SELINUX=` in the restored `/etc/selinux/config`: enforcing or permissive → `/.autorelabel`, so the first boot relabels every file and reboots once. A file carrying a type no loaded policy module defines makes `btrfs receive` refuse the whole replica; `borg-backup.sh` names the path to relabel | Another MAC system (AppArmor needs nothing; Smack does) is a branch there. | The restore log's `created /.autorelabel` line; on the booted drive `/.autorelabel` is gone and `getenforce` answers |
| **Where btrfs replicas live** | `borg-backup.sh` → `SNAP_DIR="$BACKUP_MOUNT/snapshots"`, pruned per label (`root`, `home`, …) — one directory for every machine that uses the drive | Two btrfs machines on one drive share labels and prune each other's replicas: give each its own drive, or keep the replica layer on one of them. The restore test bed sets `BX_NO_REPLICAS=1` for exactly this reason. | `backup-diag.sh` → *other machines' data on the backup drive* |
| **Kernel command-line carriers on restore** | `lib-cmdline.sh` → `cl_find_carriers` (BLS/systemd-boot entries, `/etc/kernel/cmdline` + `cmdline.d`, `GRUB_CMDLINE_LINUX` + `grub.d`, `extlinux.conf`, `syslinux.cfg`, `cmdline.txt`, `refind_linux.conf`, `limine.conf`, `/etc/default/limine`) and `cl_rewrite_ids`; called by both restore scripts after the `fstab`/`crypttab` fix-up, checked by `cl_stale_ids` before reboot and by `backup-verify.sh` against the archive | Add your carrier's path to `cl_find_carriers` and, if it uses a new reference syntax, to `CL_REF_PREFIX`. | Add it to `tests/cmdline-fixture-test.sh`; `backup-verify.sh` section 3 reports "carriers agree with fstab/crypttab" |
| **Encrypted `/boot`, and which GRUB can open it** | `restore-rebuild-boot.sh` — `BOOT_ON_LUKS` from `/boot` (or `/`) being on `/dev/mapper/*`, then the container's LUKS version and KDF decide the GRUB floor (LUKS1 → 2.02, LUKS2/pbkdf2 → 2.06, argon2 → 2.14 — the rebuild picks the `grub-install` whose modules include `argon2.mod`); `backup-verify.sh` section 6 says the same | A LUKS `/boot` opened under another path, or LVM-on-plain-disk, needs a `cryptsetup status` check instead of the prefix test; a new KDF needs a floor. | The report's boot-layout line `boot_on_luks=` and the rebuild's dry-run `encrypted /boot:` line |
| **Ad-hoc vs scheduled** | `deploy.sh` → `detect_schedule_mode` (removable, hotplug, or USB transport → ad-hoc); in ad-hoc mode the backup timers are stopped **before** any unit file is written (an old `Persistent=` timer otherwise fires its missed run on the daemon-reload) | Thunderbolt NVMe, SD readers and LVM stacks can misclassify. Override first: `SCHEDULE_MODE=` in the config or environment. | `sudo ./deploy.sh --dry-run` prints `Schedule mode (…): ` with the evidence |
| **Which drive is which (restore test bed)** | `testbed/testbed.sh` → `disk_by_serial`: `lsblk`'s serial or udev's `ID_SERIAL_SHORT`; the drive holding this machine's mounts, swap or open containers is refused | A bridge that reports neither needs another stable id. Take serials for `testbed.conf` from `udevadm info -q property -n /dev/sdX \| grep ID_SERIAL_SHORT` — behind some USB bridges `lsblk` shows zeros. | `sudo testbed/testbed.sh status` resolves both serials to devices |

**Step 2 — prove it, then send it.** Run what CI runs, then a real backup and
a verify on the machine, then send me both the patch and the report:

```bash
bash tests/run-all.sh                 # shellcheck, ruff, headers, all tests — must be green
sudo ./deploy.sh --dry-run && sudo ./deploy.sh
sudo borg-backup.sh && sudo backintime-backup.sh      # + timeshift-backup.sh on non-btrfs
sudo backup-verify.sh; echo "exit $?"                 # 0 = restore-ready; section 7 names leftovers
sudo ./backup-diag.sh -o backup-diag.md               # collected AFTER the above
```

A change to the restore or the boot rebuild is proven by a restore, not by a
dry run: the [restore test bed](#the-restore-test-bed) on a spare drive
(`sudo TB_WIPE=<serial> testbed/testbed.sh all`, boot the test drive,
`sudo testbed/testbed.sh collect` → `VERDICT: PASS`), then inspect the restored
drive itself — ownership and modes in the homes, `/.autorelabel` consumed, the
boot report's warnings — before calling it working. `testbed.sh` runs from the
checkout and bash reads a script as it goes: do not edit it while a run is in
progress. In tests, capture output before matching it — `cmd | grep -q` under
`set -o pipefail` fails whenever `grep` exits early and `cmd` still writes.

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
script directly. **Apple Silicon is the exception to "bare metal":** m1n1,
U-Boot and the partitions the firmware boots from are Apple-managed and cannot
be recreated from Linux, so a dead Mac is first reinstalled with the Asahi
installer from macOS, and the backup is then restored *over* that fresh
install — the boot rebuild adapts an existing chain there, it never creates
one.

```bash
sudo ./restore.sh                                   # interactive: snapper / btrfs / borg / BIT / combined
sudo ./borg-restore.sh /mnt/target /mnt/backup/borg-backup            # borg archive
sudo ./borg-restore.sh --dry-run /mnt/target /mnt/backup/borg-backup  # preview: no writes
sudo ./backintime-restore.sh /mnt/target /mnt/backup/backintime       # BIT snapshot
```

**Restoring from an installed system instead of a live USB** — onto a second
disk, a new internal drive fitted beside the old one, or a test disk — is
detected (the running root is not a live image) and made safe for the disk
you are running from. Nothing is written to it:

- no firmware boot entry: `bootctl --no-variables`, `grub-install --no-nvram
  --removable`, no `efibootmgr`, and the chroot sees `efivars` read-only — the
  machine's boot order is left alone; pick the restored disk from the firmware
  boot menu (`RESTORE_NO_NVRAM=0` to write an entry anyway);
- borg's cache and security state go to a temporary directory, not `/root`;
- only LUKS containers on the target disk are paired with the restored
  system's entries — the running root's container and the backup drive are
  open too;
- the **root container** is mapped from the container actually under the
  target's root. With the old disk still installed its old id still exists
  and its mapper name is taken, so no other rule reaches it — and without
  this the restored disk boots by unlocking, and running from, the OLD disk;
- `crypttab.initramfs` (mkinitcpio sd-encrypt) is rewritten with `crypttab`;
- a swapfile named in `fstab` is re-created (swapfiles are never in a
  file-level backup) and `resume_offset=` rewritten to its new blocks, with
  `resume=UUID=` moved to the new root filesystem;
- the final check fails any boot-chain reference — command line,
  `crypttab.initramfs`, `fstab` for `/`, `/boot`, the ESP, `/home` — that
  resolves to a disk other than the target, not merely one that is missing.

A live-USB restore takes none of these branches except the last three, which
are simply correct there too.

Before anything is rewritten, both method scripts check the new disk's
partition types — the ESP (at `/boot/efi`, `/efi`, or `/boot` itself) must be
typed *EFI System*, and a separate vfat `/boot` next to it *XBOOTLDR* — and
print the `sgdisk` fix, because a wrong type restores every file and still
does not boot. After extracting files, they fix up the new disk's ids in
`fstab` and `crypttab` — field by field, in the form each entry already uses
(`UUID=`, `PARTUUID=`, `LABEL=`) — **and in every kernel command-line carrier** — BLS and
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
  without argon2 (older than 2.14) on an argon2id `/boot`;
- **systemd-boot** reinstalled with `bootctl` and entries recreated;
- **Limine** and **rEFInd** reinstalled (`limine-install` on CachyOS, or the
  loader binary copied to the ESP; `refind-install`) with a firmware boot
  entry from `efibootmgr` — NVRAM entries are in no backup (untested on metal).

On a restored system with SELinux enabled, the restore also creates
`/.autorelabel`, so the first boot relabels every file (one extra reboot):
the Back In Time layer does not carry SELinux labels, and an enforcing system
with unlabeled files refuses logins.

Some systems cannot be restored bare-metal by *any* file-level backup — Apple
Silicon, ARM boards with U-Boot at raw offsets, Chromebooks, A/B image systems
such as SteamOS — because their boot chain is not files. For those, reinstall
first and restore over the fresh install; [CONTRIBUTING.md](CONTRIBUTING.md#not-possible--please-do-not-spend-time-on-these)
lists them, and the setups that *are* possible but not handled yet.

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
reads `/etc/backup-system.conf`; nothing in it is per-host. `deploy.sh`
restarts a running tray with the build it just installed, reusing the old
process's desktop session, so a redeploy never leaves a stale tray on screen.

## Files

```
deploy.sh                     universal, policy-aware installer + drive set-up (--dry-run)
backup-common.sh              shared library: version, config load, layout/fs detection, package map, retention helpers
lib-cmdline.sh                every kernel command-line carrier: find, rewrite ids on restore, check against fstab/crypttab
backup-system.conf.example    per-host config template (installed to /etc/backup-system.conf)
borg-backup.sh                borg archive + btrfs replicas (btrfs roots)   --dry-run
backintime-backup.sh          BIT-format rsync snapshots                    --dry-run
timeshift-backup.sh           Timeshift snapshots + count/space retention (non-btrfs local layer)  --dry-run --prune-only
backup-verify.sh              restore-readiness assertion (exit 0/1/2)
luks-header-backup.sh         LUKS header backup, keyslot-tagged
backup-diag.sh                troubleshooting report: read-only, redacted   (-o FILE, --no-redact, --full)
borg-backup-drive-attach.sh   unlock (if LUKS) + mount on connect, clears a stale mount/mapping; never backs up
borg-backup-drive-detach.sh   detach unit (started by the udev remove rule): lazy-unmount + close the mapping after a yank
patch-snapper-replicate.py    idempotent fixes for snapper-replicate.sh (btrfs snapper hosts)
restore.sh                    interactive restore launcher (snapper/btrfs/borg/BIT/combined)
borg-restore.sh               borg restore + UUID fixup + universal boot rebuild   --dry-run [--files-only | --fixup-only]
backintime-restore.sh         BIT restore + UUID fixup + universal boot rebuild    --dry-run [--files-only]
                              (both: RESTORE_HOST=<name> picks the host when a drive holds several)
restore-rebuild-boot.sh       universal boot-chain rebuild (GRUB/systemd-boot/UKI/encrypted-boot)  --dry-run
backup-tray.py backup-tray.desktop                 tray: every layer, run/log/verify/report by hand
*.service *.timer 99-borg-backup.rules             systemd units + udev attach/detach rule template
testbed/                      bare-metal restore test bed: plan, wipe, restore, boot report, byte comparison, verdict, revert
tests/                        lib fixtures, command lines, report redaction, deploy dry-run, loop-device replicas — what CI runs
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

### How big does the backup drive have to be?

At least one full copy of what is on the machine plus 20% — measured
against what the backup sources actually use, not the size of any disk — or
the suite refuses to format, adopt or write to it. Recommended: twice the
total size of the Linux filesystems being backed up (not the whole disk; a
Windows or macOS partition on the same disk is never copied), so borg
archives, Back In Time snapshots and btrfs/Timeshift replicas each have room
for many generations. `deploy.sh` prints both numbers for your machine; both
are knobs in the config.

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

Replicas are **incremental**. After a good send the newest read-only snapshot
of each source stays in `/.backup-snapshots` as the next run's parent, so a
second run costs the drive only what changed; the log says `incremental from
<parent>` or `full`. A full send happens on the first run, on a new drive, or
when the parent's replica was pruned, and the dry run says which it will be.
The kept parent holds the system disk's changed blocks until the next backup,
the same cost as one snapper snapshot. A source whose whole tree is on the
exclude list — Manjaro's `@cache` at `/var/cache` — gets no replica, since
send/receive cannot apply excludes.

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

Yes, on confirmed systems. `restore-rebuild-boot.sh` detects which one the
restored system uses and rebuilds it — initramfs or UKI, GRUB EFI or BIOS,
systemd-boot — inside the chroot. Successful restore is confirmed by the 
bare-metal restore status with a ✅. Make sure your system matches all 
confirmed ✅ restore parameters listed.

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

With one boundary: **a restore on Apple Silicon is never bare metal.** m1n1,
U-Boot and the partitions the Mac's firmware boots from live outside Linux
and cannot be backed up or recreated by it. If the disk or the Linux install
is gone, the order is: run the Asahi installer from macOS to get a fresh
Fedora Asahi Remix booting, then restore this backup over it (the files, the
`fstab`/`crypttab` and command-line fix-ups, the initramfs). The verify pass
says so on every Asahi host, and the status table carries it as its own row —
verified in September 2026 on a MacBook Pro (M1 Pro): Asahi installer from
macOS, then this suite's restore over the fresh install, and it boots.

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
- **Timeshift free-space prune has fired only in the sandbox.** On the ext4
  host the count prune, the `MIN_KEEP` floor and the aborted-snapshot cleanup
  ran for real; the free-space branch deleted real directories only on the
  loop-device drive (the production drive is 87% free). Same code path.
- **The boot-firmware partition is only recognised at `/boot/efi`, `/efi`,
  `/boot/firmware`, or `/boot` itself when `/boot` is a vfat partition typed EFI
  System** (`BX_ESP_PATHS`, `bx_boot_is_esp`). The ESP-at-`/boot` case is
  detected and checked by the restore scripts and the boot rebuild but has
  not been restored on metal. `BACKUP_EXTRA_SOURCES` is the stopgap for
  anything else.
- **The command-line rewrite on restore is exercised only against synthetic
  trees** (`tests/cmdline-fixture-test.sh`, every carrier kind). A real
  restore onto a fresh disk is the "bare-metal restore" column — ✅ where a
  test-bed run has passed, ⚠️ where it is under test now.
- **Limine and rEFInd are written and fixture-tested, never run on metal**;
  the SELinux relabel has run on metal on Linux Mint (permissive) and Fedora
  (enforcing), not yet on RHEL; syslinux/extlinux configs are recognised by the verify
  pass, but the restore does not reinstall that loader. Image-based distros
  (ostree, transactional), NixOS, ZFS/bcachefs roots and mdadm RAID are not
  handled by the restore yet — see [CONTRIBUTING.md](CONTRIBUTING.md#wanted-setups-the-restore-does-not-handle-yet).
- **Raspberry Pi: written, never run.** The firmware-boot recogniser, the
  verify patterns and the `cmdline.txt` `root=PARTUUID` rewrite in
  `restore-rebuild-boot.sh` are exercised only against synthetic listings in
  the fixture test. The author has Pis in storage and no plan to run one; that
  row will stay ❌ until someone with a Pi sends a setup report.
- Every ❌ row above stays red until that setup has been run and verified on
  real hardware; a row under test now is ⚠️, and each turns ✅ as that happens.

## Documentation

| Doc | Covers |
|---|---|
| [`docs/TESTED-SYSTEMS.md`](docs/TESTED-SYSTEMS.md) | Every tested machine: hardware, layout, and what was verified on it |
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
and **serious bugs** and qualified unique patches.

**Most wanted: the distro families the package map does not know.** The
detection and the layers are generic, but a family is only usable once its
package manager is in `backup-common.sh` (`bx_distro_family`,
`bx_pkg_install_cmd`, `bx_pkg_for`) and `deploy.sh` (`detect_distro`, the
tray packages). Today that is `apt`, `dnf`, `pacman` and `zypper`. Not yet:

| Family | Package manager | What a patch needs |
|---|---|---|
| **Slackware** | `slackpkg` / `sbopkg` | install command; where `borgbackup`, `backintime`, `timeshift` come from (SlackBuilds) |
| **Gentoo** | `emerge` (Portage) | non-interactive install command; atom names (`app-backup/borgbackup`, …) |
| **Turbolinux** and other RPM distros outside the Fedora/SUSE families | `rpm` + their own front end | the front end's install command and package names |
| **Alpine** | `apk` | musl caveats for borg; package names |
| **Void** | `xbps-install` | package names |
| **NixOS** | `nix` | whether package installation is even the right model there, or the scripts should assume a declared environment |
| **Solus** | `eopkg` | package names |

A working patch for any of these — a family token, an install command, the
package names, a synthetic `os-release` case in `tests/lib-fixture-test.sh`,
and the troubleshooting report from a real machine — puts your name on the
copyright line of `LICENSE` and a row in [Contributors](#contributors). A setup
report alone, without a patch, is still the thing the fix gets built from.
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

- **Version:** 4.0.4
- **Author:** William MacKinnon ([doug445](https://github.com/doug445))
- **Email:** spilled-bowline0j@icloud.com
- **Repository:** https://github.com/doug445/linux-backup-system

Copyright (c) 2026 William MacKinnon &lt;spilled-bowline0j&#64;icloud.com&gt;
