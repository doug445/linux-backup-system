# Restore

How a restore runs — from a live USB or from an installed system onto a second disk — and what the boot rebuild does for each layout. Back to the [README](../README.md).

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
first and restore over the fresh install; [CONTRIBUTING.md](../CONTRIBUTING.md#not-possible--please-do-not-spend-time-on-these)
lists them, and the setups that *are* possible but not handled yet.

`restore-rebuild-boot.sh` is standalone and takes `--dry-run`, so you can preview
the exact boot steps inside an `arch-chroot` (or even on a live system) before
committing. It warns and continues on a bootloader or initramfs tool it does
not know — **read its warnings, not its exit code**. `--dry-run` on
`borg-restore.sh` / `backintime-restore.sh` previews the file extraction and
target-UUID detection and stops before any write.
