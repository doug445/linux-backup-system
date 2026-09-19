# Troubleshooting, and hand-rolling a fix

Logs, dry runs, the troubleshooting report, the USB-bridge failure everyone hits once — and, for a setup the suite has never seen, where each decision lives and how to prove a fix. Back to the [README](../README.md).

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
a private report; `--full` gives longer log tails). It opens with a **setup
fingerprint** — one screen of the facts every decision is made from, gathered
without assuming any of them: `ID`/`ID_LIKE`, which package managers exist,
the root filesystem and the whole device stack under it, every real
filesystem mounted, what the kernel supports, page and sector sizes,
encryption and volume management in use, the ESP's vendor directories (and
U-Boot's variable file where there is one), every loader config found, the
initramfs tools, what could take snapshots — followed by the tooling each
filesystem has for a backup and a restore. That section plus *What the
suite's own detection reports* is what a new distro, filesystem or boot layout
is added from, with nothing else needed from the machine. It then records
`os-release`, kernel, firmware and Secure Boot state, a tool inventory with versions,
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
dry run: the [restore test bed](STATUS.md#the-restore-test-bed) on a spare drive
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
the release notes, and a row in [Contributors](../README.md#contributors) —
[CONTRIBUTING.md](../CONTRIBUTING.md#adding-a-linux-setup--and-getting-onto-the-license)
has the terms.
