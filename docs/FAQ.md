# Frequently asked questions

Back to the [README](../README.md).

## Frequently asked questions

### Which Linux distributions does this back up?

Any with `systemd` and one of `apt`, `dnf`, `pacman` or `zypper`: Fedora and
RHEL-family, Debian, Ubuntu, Linux Mint, Pop!\_OS, Arch, Manjaro, EndeavourOS,
CachyOS, openSUSE Leap and Tumbleweed, and Fedora Asahi Remix on Apple
Silicon. Derivatives resolve to their family through `ID_LIKE`, so they need
not be named anywhere. Which of those have been *confirmed* is in
[Tested / untested](STATUS.md#tested--untested).

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

That route has a dependency this suite cannot remove, and it matters most on
the machines Asahi is for — the ones that outlive their macOS support. "Run
the Asahi installer from macOS" is not a local operation: the installer runs
from a macOS that still boots and finishes with one step in recoveryOS (which
stays on the disk), but it **downloads the stub macOS image for your model
from Apple's servers** to build the boot chain. The macOS install itself may be years out of support
and it still serves; the day Apple stops serving that image, a Mac whose stub
partitions are gone has no way to get a Linux boot chain back — and no backup
of yours can put it there: the stub is a small APFS container holding a
minimal macOS with m1n1 in its kernel slot, under a boot policy the machine's
own Secure Enclave signs when the installer sets it. So on an Asahi Mac,
protect the part only that process can make:

- never delete the stub container (the 2–3 GB APFS partition beside your
  Linux partitions) to reclaim its space, and keep macOS bootable — the
  installer runs from it, and recoveryOS finishes it;
- the recovery you should actually count on is a restore **over the existing
  boot chain**: keep the stub, the ESP and `/boot` where they are, reformat
  or replace only the root, and restore this backup over it. That is what the
  test bed proves on a Mac, and it needs nothing from Apple;
- a second stub (the installer's "UEFI environment only" install, ~3 GB,
  alongside the first) is cheap insurance while Apple still serves the image:
  a spare, machine-signed boot chain that a restore can be pointed at.

### Something is wrong on my distro — what do you need from me?

The troubleshooting report: `sudo ./backup-diag.sh -o backup-diag.md`. It is
read-only and redacted. Attach it to an issue, and if you have hand-rolled a
fix, the patch too — [Hand-rolling a fix](TROUBLESHOOTING.md#hand-rolling-a-fix-for-your-setup-and-distro)
says where each decision lives.
