# Contributing to linux-backup-system

**linux-backup-system 4.0.5**

This suite runs as root on every machine it is deployed to and is the last
line between a dead disk and a rebuilt one. Every added code path is a path
that can lose someone's only copy or restore a machine that will not boot, and
there is one maintainer to be sure it does not. Scope is therefore narrow on
purpose.

| | |
|---|---|
| **Wanted** | Setup reports from distros, filesystems and boot layouts I cannot reach — see below |
| **Wanted** | New Linux setups: a report, or a patch that passes the tests |
| **Wanted** | Serious bugs, with a troubleshooting report |
| **Qualifed** | Refactors, new options, general feature requests — high quality |

---

## Most wanted: setup reports

The library, the command lines and the read-only tools are exercised in CI on
every push, on x86_64 and aarch64. What CI cannot prove is that on **your**
distro, root filesystem and boot layout the suite detects the right things,
writes a real backup, and that `backup-verify.sh` then agrees a restore would
boot.

**Unless a setup is ✅ in the README's *Bare-metal restore* column, the suite is
for testing only on it — not production.** The restore test bed
(`testbed/testbed.sh`, see the README) is how a row turns green.

Every ❌ row in the README's status tables is a setup the code claims to handle
and that has not been confirmed on metal by me; a ⚠️ row is one undergoing
testing now. **Each row turns ⚠️ while it is being tested and ✅ once it is
verified on real hardware.** A report that it worked is
as valuable as a bug report — it is how a row turns ✅ on hardware I do not
have.

| Setup | Status | What to confirm |
|---|---|---|
| Fedora, Fedora Asahi Remix (aarch64), Debian / Ubuntu / Mint, Arch / Manjaro / EndeavourOS | ✅ | still worth a report on a different boot layout — the machines are listed in [docs/TESTED-SYSTEMS.md](docs/TESTED-SYSTEMS.md) |
| **openSUSE** | ❌ — **contributions wanted** | `zypper` package names; a real backup + verify pass |
| **Slackware, Gentoo, Turbolinux, Alpine, Void, NixOS, Solus** — a package manager the map does not know | ❌ **most wanted** | the family token, its non-interactive install command, the package names for borg / Back In Time / Timeshift / the tray, a synthetic `os-release` fixture, and a real backup + verify pass |
| btrfs root → snapper + send/receive replicas | ✅ | |
| ext4 root → Timeshift layer | ✅ | |
| **xfs / f2fs / any other root** | ❌ | that the Timeshift layer engages and verifies |
| systemd-boot, UKI, GRUB EFI, encrypted argon2id `/boot` | ✅ | |
| **GRUB legacy BIOS** | ❌ | `restore-rebuild-boot.sh` finds the boot disk; a restored machine boots |
| Plain (unencrypted) `/boot` | ✅ | a restored machine booting is the bare-metal row below |
| **Encrypted pbkdf2 `/boot`** (LUKS1, or LUKS2 with pbkdf2 — stock GRUB) | ❌ not under test | verify section 6 names the KDF and GRUB floor; `restore-rebuild-boot.sh --dry-run` prints `encrypted /boot: LUKS…/pbkdf2 — needs GRUB >= 2.02/2.06`; a restored machine unlocks `/boot` |
| **Raspberry Pi firmware boot** (Raspberry Pi OS, `/boot/firmware`) | ❌ — written against synthetic listings only | `bx_esp_mount` finds `/boot/firmware`; borg lists it as a source; verify section 3 PASSes on a real archive; `restore-rebuild-boot.sh --dry-run` shows the `cmdline.txt` rewrite; a restored card boots |
| **Limine** (CachyOS's default) | ⚠️ under test | verify section 3 counts `limine.conf`; `restore-rebuild-boot.sh --dry-run` shows `limine=true` and the `limine-install` (CachyOS) or binary copy + `efibootmgr` plan; a restored machine boots |
| **rEFInd** | ⚠️ under test | verify section 3 counts `refind.conf`; the dry run shows `refind=true` and `refind-install --yes`; a restored machine boots |
| **SELinux restore relabel** — ✅ on Linux Mint (permissive) and Fedora (enforcing); RHEL not yet | ✅ | a report from RHEL or another SELinux distro: the restore log says it created `/.autorelabel`; the first boot relabels, reboots once, and logins and services work |
| Bare-metal restore — Manjaro, btrfs on LUKS2 (sd-encrypt), systemd-boot + mkinitcpio UKIs, Secure Boot with sbctl keys | ✅ total system restore, booted fully working | a report on another distro or boot layout |
| Bare-metal restore — Fedora 44, btrfs on LUKS2 (dracut), systemd-boot + kernel-install UKIs, SELinux enforcing | ✅ total system restore, booted fully working | a report on RHEL or another dracut distro |
| Bare-metal restore — EndeavourOS, ext4 on LUKS2 (dracut), systemd-boot Type #1 entries, KDE Plasma | ✅ total system restore, booted fully working | a report on another Type #1 setup (Arch with mkinitcpio, a separate `/home`) |
| Bare-metal restore — Fedora 44 on a 2014 MacBook Pro, btrfs on LUKS2 (dracut, keyfile), encrypted argon2id `/boot` opened by GRUB 2.14 built from source behind shim, SELinux enforcing | ✅ total system restore, booted working (VM boot and real boot) | a report from another machine running a from-source GRUB, or an Intel Mac on another distro |
| Bare-metal restore — shim Secure Boot, Limine, rEFInd; restore from a live USB | ⚠️ under test | `sudo testbed/testbed.sh all`, boot the test drive, `testbed.sh collect` → `VERDICT: PASS`; attach the state directory's `LEDGER.md`, boot report and byte comparison |
| **Bare-metal restore — Raspberry Pi, GRUB legacy BIOS, encrypted pbkdf2 `/boot`, openSUSE, and the distros the package map does not know** | ❌ not under test — **most wanted** | the same test bed run on that hardware |
| Apple Silicon restore over a fresh Asahi install — never bare metal: Asahi installer from macOS first, then this backup restored over it | ✅ | a report from an M2 or later, or with the current release, is still welcome |

### Wanted: setups the restore does not handle yet

These can be restored bare-metal in principle — the boot code lives in files
— but the suite does not know how yet, and a restore today would leave the
machine unbootable or broken. Each is a good first patch for someone who runs
one. The README's *Hand-rolling a fix* section says where each decision lives.

| Setup | Why a restore fails today | What a patch needs |
|---|---|---|
| **Image-based "immutable" distros** — Fedora Silverblue / Kinoite / Bazzite / CoreOS (rpm-ostree), openSUSE MicroOS / Aeon (transactional-update) | the rebuild runs dracut and grub-mkconfig; an ostree system's boot entries belong to `ostree admin`, a transactional one's to its snapshot tooling | detection of the deployment model, and a rebuild step that redeploys through it instead |
| **NixOS** | disk UUIDs live in `/etc/nixos/hardware-configuration.nix`; `fstab` is generated from it and the suite's rewrite is overwritten on the next build | the UUID rewrite in `hardware-configuration.nix`, and a rebuild through `nixos-install --root` / `nixos-enter` |
| **ZFS or bcachefs root** | no id rewrite for `root=ZFS=` / pool names or bcachefs's multi-device syntax; the target pool must be created first | pool/filesystem recreation steps in the restore checklist, the id forms in `lib-cmdline.sh`, the initramfs hooks |
| **mdadm RAID, multi-device btrfs** | array UUIDs in `mdadm.conf` and the initramfs are not rewritten; the arrays must exist before the files go back | the `mdadm.conf` rewrite, an initramfs regeneration that picks it up |
| **syslinux / extlinux, LILO / elilo** (Slackware) | command lines are rewritten, but the loader itself is never reinstalled | an `extlinux --install` / `lilo` step in `restore-rebuild-boot.sh` |
| **LUKS unlocked by TPM2, FIDO2 or Clevis** | the new container carries no token enrollment; the restored system asks for the passphrase (not a failure, but not documented) | a post-restore note or a re-enrollment step (`systemd-cryptenroll`, `clevis luks bind`) |
| **Secure Boot with your own keys** (sbctl) | files the rebuild regenerates are unsigned until re-signed | an `sbctl sign-all` step when sbctl is in use |
| **Non-systemd distros** — Void (runit), Alpine / Gentoo (OpenRC), Slackware | `kernel-install` and `bootctl` are absent; only the GRUB path applies, and the backup side's units need a cron or service equivalent | the family (see below), and a scheduler for ad-hoc/scheduled mode without systemd |

### Not possible — please do not spend time on these

A bare-metal restore needs everything the firmware reads before Linux starts
to be *files* in the backup. On these systems it is not: the boot chain sits
in raw sectors, signed partitions or firmware-managed storage that no
file-level backup can hold or recreate. The supported path is the same for
all of them — **reinstall the system with its own installer or image, then
restore this backup over the fresh install** — and that already works; a
patch that tries to make them bare-metal cannot.

| System | Why |
|---|---|
| **Apple Silicon** (Fedora Asahi Remix) | m1n1, U-Boot and the partitions the Mac's firmware boots from are Apple-managed; reinstall with the Asahi installer from macOS first (✅ verified that way) |
| **ARM boards with U-Boot at raw offsets** — most Rockchip and Allwinner boards, many others | the bootloader is written to fixed sectors of the boot medium (or SPI flash), outside any partition; flash the vendor or distro image first. A **Raspberry Pi is not in this group**: its firmware is ordinary files on a vfat partition |
| **Chromebooks** (depthcharge) | the firmware boots signed kernel partitions, not a bootloader from a filesystem |
| **A/B verified-image systems** — SteamOS, ChromeOS, Ubuntu Core | the OS is a signed, dm-verity-protected image; it is reinstalled, never restored file by file |

### How to file a setup report

Open an issue with the **New Linux setup** template, titled
`Setup report: <distro> / <root fs> / <boot layout>`, with:

1. the troubleshooting report (below), collected **after** `deploy.sh` ran;
2. which of these you actually ran, and what each said:
   ```bash
   sudo ./deploy.sh --dry-run
   sudo borg-backup.sh --dry-run
   sudo backintime-backup.sh --dry-run
   sudo timeshift-backup.sh --dry-run        # non-btrfs roots
   sudo borg-backup.sh                       # a real archive
   sudo backup-verify.sh; echo "exit $?"     # 0 = restore-ready; section 7 names leftovers
   ```
3. anything you had to fix by hand — **that is the actual finding.**
4. for a **Bare-metal restore** row: a restore test bed run on a spare drive —
   `sudo TB_WIPE=<serial> testbed/testbed.sh all` (its `finish` boots the test
   drive in a VM first — install QEMU and OVMF/AAVMF for that), boot the test drive,
   `sudo testbed/testbed.sh collect` — and from its state directory
   (`/var/lib/linux-backup-testbed/<host>-<stamp>/`) attach `LEDGER.md`,
   `verdict`, `vmboot`, `byte-comparison.md`, `boot-report/boot-report-*.md` and
   `vm/boot-report/boot-report-*.md`; when the VM boot failed, `vm/serial.log` and
   `vm/screen-last.png` too. The troubleshooting report summarises all of it in
   its *Restore test bed runs* section. Identify
   drives by the serial udev reports (`udevadm info -q property -n /dev/sdX |
   grep ID_SERIAL_SHORT`): behind some USB bridges `lsblk` shows only zeros. If
   the backup drive is shared with another machine, say so — the test bed writes
   only its own `borg-testbed-<host>` repository there.

A dry-run-only report is useful too, and costs nothing: it exercises all of
detection without touching the drive. Say so in the title if that is what it
is.

---

## The troubleshooting report

Almost every bug here is a detection bug — the suite decided your machine
looks one way when it looks another — and a description is rarely enough to
act on. There is a script that collects everything needed, as Markdown to
attach straight to an issue:

```bash
sudo ./backup-diag.sh -o backup-diag.md
```

It collects: `os-release`, kernel and firmware, a tool inventory with versions,
`lsblk` / `findmnt` / `fstab` / `crypttab`, every ESP candidate and what is in
it, loader entries, UKIs, GRUB and initramfs configuration, the installed
kernels, `/etc/backup-system.conf`, the deployed scripts with their hashes,
**what the suite's own detection reports** for every decision it makes, the
read-only plan `restore-rebuild-boot.sh --dry-run` would execute, unit and
timer state, the udev rule, the tail of every log and journal, and — as root —
the full `backup-verify.sh` run.

**It only reads.** It mounts nothing, starts no backup, and never touches key
material: keyfiles are reported by path and mode, LUKS headers by public
metadata only, and every UUID is truncated to 8 characters unless you pass
`--no-redact`.

| Flag | Effect |
|---|---|
| *(default)* | UUIDs truncated to 8 characters — enough to correlate lines in one report, not enough to fingerprint your disks |
| `--no-redact` | keep UUIDs whole; only for a private report |
| `--full` | longer log tails and journals |
| `-o FILE` | write to a file (mode 600) instead of stdout |

The tray has it too: *Troubleshooting → Generate troubleshooting report*.

If the section headed *"What the suite's own detection reports"* disagrees
with the raw output above it in the same file, **that disagreement is the
bug**, and it is the single most useful thing you can send. The README section
*Hand-rolling a fix for your setup and distro* maps every line of that section
to the function that produced it.

### What never to attach

The report already excludes these, and you should not add them by hand:

- the backup drive's keyfile (`BACKUP_KEYFILE`, anything in `/etc/luks-keys/`)
- LUKS header backups (`luks-headers/*.img`) — every keyslot, offline-attackable
- a borg passphrase

[SECURITY.md](SECURITY.md) has the full list and the reasoning.

---

## Adding a Linux setup — and getting onto the license

A new distro family, root filesystem or boot layout is the one kind of code
change this project wants — and **a distro family with a package manager the
map does not know is the one most wanted**: Slackware (`slackpkg`), Gentoo
(`emerge`), Turbolinux and other RPM distros outside the Fedora and SUSE
families, Alpine (`apk`), Void (`xbps`), NixOS (`nix`), Solus (`eopkg`). Every
layer of this suite is generic; the package map is the only thing standing
between one of those systems and a working deploy. A family patch touches
four places — `bx_distro_family`, `bx_pkg_install_cmd` and `bx_pkg_for` in
`backup-common.sh`, and `detect_distro` plus the tray packages in `deploy.sh`
— and one fixture leg. The README's *Hand-rolling a fix* section says
where each decision lives and how to change it. A pull request that adds one
has to:

1. **Change detection, not add configuration.** The design rule is that
   nothing about the machine goes in the config file; the scripts work it out.
   A patch that adds a knob the user must set to make their setup work will be
   declined in favour of one that detects it.
2. **Fail loudly where it does not apply.** A check that cannot run reports
   SKIP; an unknown bootloader produces a warning line; nothing is ever
   silently counted as a pass. That invariant is the whole safety model.
3. **Carry a fixture leg.** Add the new family or layout to
   `tests/lib-fixture-test.sh` (a synthetic `os-release` for a distro; a
   synthetic mount or tree for a layout) in the same pull request. A path
   without a test is a path nobody can regression-test.
4. **Come with the troubleshooting report** from the machine it was written
   on, collected after a real backup and a `backup-verify.sh` pass.

**Credit.** A working patch that passes `tests/run-all.sh` — green in CI on
x86_64 and aarch64 — and that I can confirm from its report gets:

- **your name on the copyright line of [`LICENSE`](LICENSE), next to mine**,
  in the form `Copyright (c) <year> William MacKinnon, <your name>`;
- credit by name in the release notes of the release that ships it;
- a row in the README's *Contributors* table naming the setup you added.

That is the deal: you did the work I could not do without your hardware, and
the license says so.

---

## What counts as a serious bug

- Data loss, or a plausible path to it — including retention deleting what it
  must not.
- `backup-verify.sh` reporting restore-ready on a repository that would not
  restore, or a SKIP counted as a pass.
- A backup started by a udev event, or by anything other than a timer in
  scheduled mode or a human.
- A write to a drive other than the one pinned in the config.
- A restore that leaves the target unbootable **without a warning line saying
  so** — the silent class.
- Detection reporting one thing while the report's raw sections show another.

Not serious: cosmetic output, a wish for a flag, a preference about defaults.

## Reporting one

Use the **Bug report** template. Say which distro, root filesystem and boot
layout — those are the four things every code path branches on, and half of
all reports omit one. Include:

1. the troubleshooting report;
2. `--dry-run` output if you still can (it is read-only, so usually possible
   even after a failure);
3. the exact command line and any `BACKUP_*` / `SCHEDULE_MODE` variables you
   set;
4. what you expected, and what happened.

## Before opening a pull request

Run what CI runs:

```bash
bash tests/run-all.sh          # bash -n, shellcheck, ruff, SPDX headers, all tests
```

or the pieces:

```bash
shellcheck -S warning $(git ls-files '*.sh')
ruff check --isolated $(git ls-files '*.py')     # ruff 0.16.4, the version CI pins
bash tests/lib-fixture-test.sh                   # expect 0 failed
bash tests/cmdline-fixture-test.sh               # expect 0 failed
bash tests/cli-test.sh                           # expect 0 failed
sudo bash tests/deploy-dryrun-test.sh            # expect 0 failed; changes nothing
```

Requirements for any patch:

- `bash -n` clean and `shellcheck -S warning` clean; Python clean under ruff's
  default ruleset. All three are enforced in CI.
- No new runtime dependency beyond what the layer already needs. The restore
  scripts run from a live USB; a restore tool that needs something installed
  first is a restore tool you cannot use when you need it.
- Every script carries the SPDX header. CI checks.
- Comments explain **why**, not what. The existing code is dense with reasons
  for non-obvious choices; match that.
- Anything that can fail must fail loudly. A check that does not apply reports
  SKIP; it is never silently counted as a pass.

## Testing

`tests/lib-fixture-test.sh` exercises `backup-common.sh` against synthetic
inputs: distro-family mapping from `os-release` files (including derivatives
resolved through `ID_LIKE`), the command→package map, the per-family install
command, config loading and defaults, the free-space predicates and the
wrong-drive guard. No disk, no root.

`tests/cli-test.sh` exercises every script's command line without root or a
backup drive: `--help` prints exactly the usage block, unknown flags are
refused, `restore-rebuild-boot.sh --dry-run` executes nothing, and
`backup-diag.sh` produces every section with UUIDs redacted (and whole under
`--no-redact`).

`tests/cmdline-fixture-test.sh` exercises `lib-cmdline.sh` against a synthetic
restored system: every kernel command-line carrier kind, the restore-time id
rewrite (mapper names left alone, comments left alone, CRLF and uppercase ids),
consistency against `fstab`/`crypttab`, stale-id detection with a stubbed
`blkid`, dry mode and idempotence. No disk, no root.

`tests/deploy-dryrun-test.sh` runs `deploy.sh --dry-run` as root on a machine
with no backup drive and proves nothing was installed by hashing the install
directories before and after.

All four run in CI on x86_64 and aarch64 for every push.

## Security issues

**Do not open an issue.** Read [SECURITY.md](SECURITY.md) first — the keyfile
and the header backups are key material, not diagnostics.

## Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
