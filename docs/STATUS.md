# Status: tested and untested setups

The proof behind "universal": which distros, root filesystems and boot layouts have had a real backup, a passing `backup-verify.sh`, and a bare-metal restore that booted — and how the restore test bed produces that verdict. The machines themselves are in [TESTED-SYSTEMS.md](TESTED-SYSTEMS.md). Back to the [README](../README.md).

## Tested / untested

Two columns, two different claims:

- **Backup + verify** — ✅ a real backup **and** a `backup-verify` pass have been
  confirmed on that setup; ⚠️ it is deployed on real hardware and being run,
  but that pass is not recorded yet; ❌ the code paths exist and dry-run clean,
  and that exact combination has **not** been verified.
- **Bare-metal restore** — ✅ a backup of that setup has been restored onto a
  **different, blank disk** by the suite's own restore scripts, the disk has
  **booted** (unlocked, logged in, network up), and the restored files were
  compared against the archive — with [`testbed/testbed.sh`](STATUS.md#the-restore-test-bed),
  which proves the source machine's disks were not written; ⚠️ that restore is
  under test now; ❌ not yet restored and booted.

**Unless every row that describes your machine is ✅ in the Bare-metal restore
column, use the suite for testing only — not in production.**

**Verified on 10 tested systems**, restored and VM-booted on an eleventh (the M2 Max, `PASS-VM`) — the machines behind the rows: [TESTED-SYSTEMS.md](TESTED-SYSTEMS.md).

**Distros**

| Distro | Backup + verify | Bare-metal restore |
|---|:--:|:--:|
| Fedora | ✅ | ✅ |
| Fedora Asahi Remix (Apple Silicon, aarch64) | ✅ | ✅ over a fresh Asahi install (never bare metal — see the FAQ); M2 Max: restored onto a disk image and booted in a VM, `PASS-VM` (2026-09-18) |
| Debian / Ubuntu / Linux Mint | ✅ | ✅ |
| Arch / Manjaro / EndeavourOS | ✅ | ✅ |
| openSUSE (Leap / Tumbleweed) | ❌ — **contributions wanted**, see [Contributing](../README.md#contributing) | ❌ not under test |
| **Slackware, Gentoo, Turbolinux, Alpine, Void, NixOS, Solus** — package managers the map does not know yet (`slackpkg`, `emerge`, `apk`, `xbps`, `nix`, `eopkg`) | ❌ — **contributions wanted**, see [Contributing](../README.md#contributing) | ❌ not under test |

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
| Apple Silicon (Asahi) restore — **never bare metal**: reinstall with the Asahi installer from macOS, then restore over the fresh install (see [FAQ](FAQ.md#can-i-run-it-on-apple-silicon)) | ✅ | ✅ |

A ❌ row turns ⚠️ when that setup is deployed and being run on real hardware.
In the Backup + verify column it turns ✅ when it has produced one real backup on
each layer and has passed `backup-verify.sh`, with the
[troubleshooting report](TROUBLESHOOTING.md#troubleshooting-logs-dry-runs-and-the-report) from
that machine kept as the evidence. In the Bare-metal restore column it turns ✅
when [`testbed.sh collect`](#the-restore-test-bed) has returned `VERDICT: PASS`
for it, and its state directory is kept as the evidence. A `PASS-VM` — the
test bed's verdict for a restore onto a disk image, booted in a VM and never
by the machine's own firmware — is evidence for the restore, not for this
column: it keeps a row at ⚠️. Every backup, the installer and the restore
take `--dry-run` first.

### The restore test bed

`testbed/testbed.sh` turns "the restore should work" into a verdict, on any
machine, with two spare drives: the backup drive and a **test drive** that is
wiped on every run. With no spare drive, `TB_TARGET_IMAGE=<file>` makes a
sparse disk image on the backup drive the test drive instead — the whole run
is the same, except that the only boot a file can get is the VM boot, so its
verdict is `PASS-VM` (`collect --vm`): proof of the restore, not of the
machine's firmware booting it.
On a machine whose firmware boots nothing external (Apple Silicon: U-Boot sees
no USB drive), `TB_TARGET_ESP=<PARTUUID>` names a *spare* EFI System partition
on the running disk with free space after it — on a Mac, the ESP of a second
"UEFI environment only" Asahi install — and the test bed lays its partitions
out in that free space instead, keeps the ESP and its stub files, and the
restored system is picked at power-on like any other install. That is the
road to a real boot, and a ✅, on a Mac. This machine's own partitions,
containers, boot files and entries are fingerprinted as always; the added
partitions are what `TB_DELETE_TARGET=1 testbed.sh revert` removes.

```bash
cp testbed/testbed.conf.example /mnt/backup/testbed/testbed.conf   # the two drives' serials, once
sudo testbed/testbed.sh plan                                # the test drive laid out like THIS machine
sudo TB_WIPE=<test-drive-serial> testbed/testbed.sh all     # fingerprint, wipe, partition, LUKS, backup, restore, logger, VM boot
sudo testbed/testbed.sh vmboot                              # (run by finish) boot the test drive in QEMU first — snapshot, no network → VM verdict
# reboot, pick the test drive's "UEFI:" entry in the firmware menu (a Mac: Option key, the drive labelled TEST; passphrase: test, unless finish says it unlocks itself), wait five minutes, boot back
sudo testbed/testbed.sh collect                             # boot report, fingerprint diff, byte comparison → VERDICT
sudo testbed/testbed.sh revert                              # undo every test-only change
# no spare drive: TB_TARGET_IMAGE=/mnt/backup/testbed/<host>-test.img in testbed.conf — same run, no TB_WIPE,
# then `sudo testbed/testbed.sh collect --vm` → VERDICT: PASS-VM (the VM boot is the only boot a file gets)
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
  handled by the restore yet — see [CONTRIBUTING.md](../CONTRIBUTING.md#wanted-setups-the-restore-does-not-handle-yet).
- **Raspberry Pi: written, never run.** The firmware-boot recogniser, the
  verify patterns and the `cmdline.txt` `root=PARTUUID` rewrite in
  `restore-rebuild-boot.sh` are exercised only against synthetic listings in
  the fixture test. The author has Pis in storage and no plan to run one; that
  row will stay ❌ until someone with a Pi sends a setup report.
- Every ❌ row above stays red until that setup has been run and verified on
  real hardware; a row under test now is ⚠️, and each turns ✅ as that happens.
