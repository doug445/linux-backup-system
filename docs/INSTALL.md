# Install, configure, schedule

`deploy.sh` end to end: what it detects and installs, how the backup drive is set up and sized, the scheduling policy, retention, the tray, and what every file is. Back to the [README](../README.md).

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
lib-restore.sh                the restore pipeline both method scripts share: new-disk ids, fstab/crypttab/command-line rewrite, chroot boot rebuild, verification
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
