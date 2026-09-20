[![CI](https://github.com/doug445/linux-backup-system/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/linux-backup-system/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: aarch64 | x86_64](https://img.shields.io/badge/platform-aarch64%20%7C%20x86__64-lightgrey.svg)](docs/STATUS.md#tested--untested)
[![Layers: Borg | Back In Time | btrfs/Timeshift](https://img.shields.io/badge/layers-Borg%20%7C%20Back%20In%20Time%20%7C%20btrfs%2FTimeshift-blue.svg)](docs/LAYERS.md)
[![Boot: GRUB | systemd-boot | UKI](https://img.shields.io/badge/boot-GRUB%20%7C%20systemd--boot%20%7C%20UKI-informational.svg)](docs/RESTORE.md)

# linux-backup-system — restore-verified backup for any Linux, built on Apple Silicon first

**Built and proven on Fedora Asahi Remix — Linux on Apple Silicon, the
hardest boot chain there is to support, and the one place where
"reinstall, then restore over it" is the only way back — and run unchanged
on x86_64.** One codebase for every distro, root filesystem and boot layout,
that answers the only question that matters once a disk is gone: *could I
actually restore this machine?* It layers **Borg** archives, **Back In
Time**-format rsync snapshots, a local snapshot layer chosen by the root
filesystem (**btrfs send/receive** or **Timeshift**), keyslot-tagged **LUKS
header backups**, and a daily **restore-readiness check** that asserts, from
what is on the backup drive, that a restore would boot. On restore it
rebuilds the boot chain for whatever it finds — **GRUB**, **systemd-boot**,
**Unified Kernel Images**, an encrypted argon2id `/boot` — and a **restore
test bed** turns "it should work" into a verdict by restoring onto a spare
drive, a disk image or free space on the running disk and booting the result.

Nothing is keyed to a distro name and nothing is pinned to a machine: every
decision is made from what the machine shows at run time, and the drive, its
guard UUID, the keyfile, the schedule and the retention live in one config
file. A setup this suite has never seen is a detection gap to close, not a
port to write — [Contributing](#contributing) says how.

> **Testing only unless your setup is all green.** Unless your distro, root
> filesystem and boot layout are all ✅ in the *Bare-metal restore* column of
> [Status](docs/STATUS.md#tested--untested), use this for testing, not
> production. A backup you have never restored is a hope, not a backup.
> **A backup never starts because a drive appeared**: plugging the drive in
> unlocks and mounts it; a backup runs when you start one or a timer fires.
> Every script takes `--dry-run`. Retention never deletes by age.

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

No backup drive mounted? Step 2 asks you to connect one, lets you pick it,
offers to have you encrypt it first, and formats it on a typed confirmation —
or installs now and finishes when the drive is there. The drive set-up, sizing,
scheduling and retention are in [docs/INSTALL.md](docs/INSTALL.md).

## Apple Silicon: a Mac running Linux can be rebuilt from this backup

**This is the headline feature, and it is tested.** A dead disk, a wiped
machine, an upgrade that will not boot: run the Asahi installer from macOS
(it finishes with one step in recoveryOS) to get a fresh Fedora Asahi Remix
stub booting — the only part of the machine that is Apple's to make — then
point this suite's restore at it. Every file comes back; `fstab`,
`crypttab` and every kernel command line are rewritten to the new partitions'
ids; the initramfs and the GRUB configuration are rebuilt inside the restored
system; a verification refuses to call it done while anything would boot,
unlock or mount the wrong disk. Reboot, and it is your machine again — users,
keys, Wi-Fi, desktop, the lot. **Verified on a MacBook Pro (M1 Pro) in
September 2026: Asahi installer from macOS, restore over the fresh install,
and it boots.** No other backup tool documents, let alone tests, this path;
most do not know a Mac cannot be restored bare-metal at all.

Apple Silicon is a first-class target here, not a port. The author's own
machines are an M1 Pro and an M2 Max, and the suite is keyed to the Asahi
boot chain — stub → m1n1 → U-Boot → shim → GRUB on `arm64-efi`, 16k pages —
which is the same on every M-series generation Asahi runs on. An
Asahi-specific fault on any of them is a bug in this suite and gets fixed:
send the [troubleshooting report](docs/TROUBLESHOOTING.md) and it is worked
from there. For the day Apple stops serving the installer's stub image for
your model, the [FAQ](docs/FAQ.md#can-i-run-it-on-apple-silicon) says what to
protect now.

Two truths, then, and both are in the tables. **On a Mac the recovery is the
simple one**: reinstall from macOS, restore over it, done — proven. **On
x86-64 it is the hard one**: bare metal means recreating the boot chain from
files alone, with nothing to reinstall from — GRUB or systemd-boot, UKIs and
their embedded command lines, Secure Boot with shim or your own keys,
LVM-on-LUKS, an encrypted `/boot` — and that is what the rest of this suite
exists for, seven such restores deep.

### Why aarch64 is still the test bed that counts

An x86 machine boots a file from a FAT partition. A Mac running Linux boots
a stub macOS the Asahi installer made, whose boot policy the machine's own
Secure Enclave signed; its kernel slot holds m1n1, which loads its second
stage and U-Boot from the ESP, which loads shim, which loads GRUB, under a
16k-page kernel, on a 4Kn disk whose first partitions can never be recreated
from Linux. Every one of these cost the suite a fix that x86 never needed —
which is why it is developed here first:

- **Nothing external booted.** On the M2 Max, U-Boot enumerated none of the
  USB drives tried (two bridges, direct and through a hub), so "restore onto
  a spare drive and boot it" — the whole test-bed method — was impossible
  there. The test bed grew a **disk-image target** (a file on the
  backup drive, booted in a VM) and a **same-disk mode** (test partitions in
  free space behind a second Asahi stub, picked at power-on) for this machine.
- **4096-byte sectors.** Apple NVMe is 4Kn; a VM that presents the same drive
  with 512-byte sectors reads its GPT at the wrong offsets. The VM boot now
  passes the target's logical sector size through.
- **`ID=fedora-asahi-remix`, `EFI/fedora`.** The boot rebuild trusted
  os-release's `ID` for the ESP's vendor directory, so on Asahi it never took
  the Fedora-shim branch and left shim on the removable path with no GRUB
  beside it. The test bed caught it before any reboot; the rebuild now finds
  the directory that actually holds the loaders. Seven x86 bare-metal restores
  — Fedora, Mint, Manjaro, EndeavourOS — had passed without ever exercising it.
- **Boot entries that live in a file.** U-Boot keeps its EFI variables in
  `ubootefi.var` on the ESP the stub names (`/chosen/asahi,efi-system-partition`;
  `arch/arm/mach-apple/board.c`). Entries shim's fallback writes at boot time
  persist there; entries `efibootmgr` writes from Linux do not survive a
  reboot. A restored ESP therefore carries the *source* machine's `BootOrder`,
  whose first entry is the source machine's own shim — booted from a second
  stub, it would start the wrong system. The same-disk mode parks that file:
  with no entries, U-Boot's boot manager tries the default loader on the
  stub's own ESP before any other partition (`efi_bootmgr.c`, *try EFI system
  partition*), which is the test ESP.
- **No argon2 in GRUB 2.12 on aarch64.** An encrypted `/boot` there needs a
  GRUB ≥ 2.14 built from source; the verify pass and the rebuild name the
  floor for whatever KDF the container uses.

A restore that survives that chain leaves the x86 UEFI cases — seven
bare-metal restores in the table: GRUB, systemd-boot, UKIs, Secure Boot with
shim and with sbctl keys, encrypted argon2id `/boot`, LVM-on-LUKS — as the
easy ones.

## Status

**Verified on 10 systems, restored and VM-booted on an eleventh** — every ✅
below is a real backup, a passing `backup-verify.sh` and, in the *Bare-metal
restore* column, a restore onto a blank disk by the suite's own scripts that
booted, logged in and came up on the network, byte-compared against the
archive. The eleventh is the M2 Max: restored onto a disk image and booted in
a VM (`PASS-VM`, 99.991 % of files identical), the real boot behind a second
Asahi stub still to come. The full tables, row by row,
are [docs/STATUS.md](docs/STATUS.md); the machines are
[docs/TESTED-SYSTEMS.md](docs/TESTED-SYSTEMS.md).

| | ✅ verified | ❌ wanted |
|---|---|---|
| **Distros** | Fedora, **Fedora Asahi Remix (aarch64)**, Debian / Ubuntu / Linux Mint, Arch / Manjaro / EndeavourOS | openSUSE; Slackware, Gentoo, Alpine, Void, NixOS, Solus (package managers the map does not know) |
| **Root filesystems** | btrfs (subvolumes, swapfile), ext4, root on LUKS2 (sd-encrypt), LVM-on-LUKS | xfs, f2fs |
| **Boot layouts** | GRUB (EFI), systemd-boot (Type #1 and UKI), UKIs from dracut / kernel-install / mkinitcpio, Secure Boot with sbctl keys, encrypted argon2id `/boot`, plain `/boot`, ESP at `/efi` + XBOOTLDR, SELinux relabel (enforcing and permissive), Apple Silicon over a fresh Asahi install | GRUB legacy BIOS, encrypted pbkdf2 `/boot`, Raspberry Pi firmware boot, Limine, rEFInd; ⚠️ Secure Boot through shim, restore from a live USB |

A ❌ row turns ⚠️ when it is under test on real hardware and ✅ when
`testbed.sh collect` has returned `VERDICT: PASS` for it — a `PASS-VM` (a
disk image booted in a VM, never by the machine) is evidence for the restore
and keeps the row at ⚠️.

## Restore

```bash
sudo ./restore.sh                                            # interactive: snapper / btrfs / borg / BIT / combined
sudo ./borg-restore.sh --dry-run /mnt/target /mnt/backup/borg-backup   # preview; drop --dry-run to restore
```

From a live USB, or from an installed system onto a second disk — nothing is
written to the disk you are running from. The files come back, then `fstab`,
`crypttab` and every kernel command-line carrier are rewritten to the new
disk's ids, then `restore-rebuild-boot.sh` rebuilds the boot chain inside the
restored system, and a verification refuses to call it done while anything
would boot, unlock or mount the wrong disk. All of it: [docs/RESTORE.md](docs/RESTORE.md).

## Documentation

| Doc | Covers |
|---|---|
| [`docs/STATUS.md`](docs/STATUS.md) | The tested / untested tables, the restore test bed, what is not yet universal |
| [`docs/TESTED-SYSTEMS.md`](docs/TESTED-SYSTEMS.md) | Every tested machine: hardware, layout, what was verified on it and what was found |
| [`docs/INSTALL.md`](docs/INSTALL.md) | `deploy.sh`, drive set-up and sizing, dependencies, scheduling, retention, the tray, every file |
| [`docs/RESTORE.md`](docs/RESTORE.md) | Restoring from a live USB or an installed system; the boot rebuild per layout |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Logs, dry runs, the troubleshooting report, USB bridge drops; hand-rolling a fix for a new setup |
| [`docs/LAYERS.md`](docs/LAYERS.md) | The layers, why three of them, the 3-2-1 mapping |
| [`docs/FAQ.md`](docs/FAQ.md) | Distros, encryption, drive size, retention, snapshots, Raspberry Pi, Apple Silicon |
| [`docs/ABOUT.md`](docs/ABOUT.md) | The long-form description: the problem, who it is for, what it deliberately does not do |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Scope, the setup-report table, adding a Linux setup and getting onto the license |
| [`SECURITY.md`](SECURITY.md) | Supported versions, reporting, what never to send |
| [`backup-system.conf.example`](backup-system.conf.example) | Every per-host knob, with its default |
| [`.github/rulesets/`](.github/rulesets/README.md) | Branch and tag protection as JSON, applied to this repository |

## Contributing

The goal is one backup system that runs on **any Linux** — universal in fact,
not just in design — and one person cannot own every distro, filesystem and
boot layout. The project takes **setup reports**, **new Linux setups** (a
report, or a patch that passes `bash tests/run-all.sh`) and **serious bugs**.
Most wanted: the distro families the package map does not know (Slackware,
Gentoo, Alpine, Void, NixOS, Solus), and a Raspberry Pi. A working patch for
a ❌ row puts **your name on the copyright line of `LICENSE`**, in the release
notes, and in the table below; a report alone is still what the fix gets built
from. [CONTRIBUTING.md](CONTRIBUTING.md) has the terms and the table of what
is still unconfirmed.

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

- **Version:** 4.1.1
- **Author:** William MacKinnon ([doug445](https://github.com/doug445))
- **Email:** spilled-bowline0j@icloud.com
- **Repository:** https://github.com/doug445/linux-backup-system

Copyright (c) 2026 William MacKinnon &lt;spilled-bowline0j&#64;icloud.com&gt;
