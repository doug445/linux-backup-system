# Security Policy

**linux-backup-system 3.4.0**

## Supported Versions

linux-backup-system is maintained by one person and carries no backport
branches. Fixes land on `main` and go out in the next tagged release. Only the
newest release is supported; there is no long-term-support line and older tags
do not receive patches.

| Version | Supported |
| ------- | --------- |
| `main` | :white_check_mark: fixes land here first |
| Newest tagged release | :white_check_mark: |
| Any earlier tag | :x: upgrade to the newest release |

The [releases page](https://github.com/doug445/linux-backup-system/releases)
lists every tag, newest first, and each release's notes record what changed in
it. This project keeps that history in the release notes rather than in a
`CHANGELOG.md`.

If you are running a checkout you pulled weeks ago, `git pull` and retry before
reporting — the issue may already be fixed. Include what you are running: the
`suite=` value on the first line of any backup log, the first row of the
troubleshooting report, or

```bash
git -C /path/to/linux-backup-system describe --tags --always --dirty
```

A `-dirty` suffix means the working tree has local modifications, and a hash
with no tag means the checkout is somewhere between releases. Say so in the
report either way — it changes what I can reproduce.

Say which distro, which root filesystem and which boot layout. This suite keys
its behaviour off what it detects on the machine, not off a distro name, so
"Fedora on btrfs with GRUB" and "Fedora on ext4 with systemd-boot" are
different code paths through the same scripts.

## Reporting a Vulnerability

I take the security of linux-backup-system seriously. If you discover a
security vulnerability, please do not open a public issue.

Instead, please report it privately by emailing the report to: spilled-bowline0j@icloud.com

**What to expect:**
* **Acknowledgment:** You will receive an initial response to your report within 72 hours.
* **Updates:** I will keep you informed of my progress as I investigate the issue and develop a fix.
* **Resolution:** If the vulnerability is accepted, I will address it promptly in a new release and notify you. If declined, I will provide a clear explanation of my reasoning.

Please include as much detail as possible in your email, including steps to
reproduce. Read [Before you send diagnostics](#before-you-send-diagnostics)
first — a backup system's artefacts include the keys to the drive they live on.

## What is in scope

These scripts run as root on a timer or on a udev event, read every file on
the machine, write to an external drive they unlock with a keyfile, store LUKS
header backups, and — on restore — rewrite `fstab`, `crypttab`, the initramfs
and the bootloader of the target. A mistake here does not degrade a feature:
it loses the only copy of something, restores a machine that will not boot, or
hands a volume over. That is the interesting surface:

* **Key material going somewhere it should not.** The backup drive's keyfile
  (`BACKUP_KEYFILE`), the LUKS header backups under `luks-headers/`, and any
  borg passphrase. A secret written world-readable, copied onto a drive the
  user did not choose, echoed into a log, the journal or the troubleshooting
  report, or passed on a command line where `ps` can see it is a real finding.
* **A restore-readiness check that passes when it should not.**
  `backup-verify.sh` exists to say whether a bare-metal restore would boot. It
  reporting "restore-ready" on a repository with no kernel, no bootloader
  config, or a stale LUKS header is a vulnerability, not a cosmetic bug. **A
  SKIP counted as a PASS is the same bug**: a check that does not apply must be
  reported as SKIP, and a check that applies and did not run must never be
  reported as either.
* **Writing to the wrong drive.** `bx_check_backup_drive` refuses to write
  unless the filesystem mounted at `BACKUP_MOUNT` carries the UUID pinned in
  the config. That guard failing to fire — or a script writing to
  `BACKUP_MOUNT` without calling it — is in scope. So is the udev rule or the
  attach unit unlocking a drive other than the one in `BACKUP_LUKS_UUID`.
* **A backup that starts when policy says it must not.** Auto-backup-on-connect
  is deliberately absent: the attach unit unlocks and mounts and never starts a
  backup, and on an ad-hoc drive the borg and BIT timers are masked. Any path
  by which plugging a drive in starts a backup is a finding, because the policy
  exists to keep a half-written backup off a drive that is about to be yanked.
* **Retention deleting what it must not.** Retention is count-based and
  free-space based, never time-based, and never prunes below `MIN_KEEP`. A
  prune that deletes by age, drops below the floor, or deletes the newest set
  instead of the oldest is a data-loss bug.
* **A stale LUKS header restored as current.** `luks-header-backup.sh` encodes
  the active keyslots in every filename so a stale header cannot be mistaken
  for the live one. That encoding being wrong, or the warning on a mismatch not
  firing, is in scope: restoring a stale header silently revokes the current
  keyslots.
* **The restore rewriting the wrong system.** `borg-restore.sh` and
  `backintime-restore.sh` fix up UUIDs and chroot into the target to rebuild
  its boot chain. Anything that touches a filesystem other than the mounted
  target — the live medium, another install's ESP — is in scope.
* **`restore-rebuild-boot.sh` reporting complete on a boot chain it did not
  rebuild.** It warns and continues on an unknown bootloader or initramfs tool.
  A missing warning — a target left unbootable with no line saying so — is the
  silent-pass class this project treats as a vulnerability.
* **The dependency installer trusting the wrong thing.** `bx_ensure_deps` runs
  apt, dnf, pacman or zypper as root. A repository added without signature
  checking or a package pulled from an unverified source is in scope.
* **The troubleshooting report leaking key material.** `backup-diag.sh` is
  read-only and is meant to be pasted into a public issue. A keyfile's
  contents, LUKS header material, a passphrase, or a UUID left whole when
  `--no-redact` was not given, is a finding.
* **A read-only tool that writes.** `backup-verify.sh`, `backup-diag.sh`, every
  `--dry-run`, and `restore-rebuild-boot.sh --dry-run` must reach no point of
  no return; `tests/` must touch no real disk.

## What is out of scope

* **Bugs in the software this suite drives** — borg, rsync, Back In Time,
  Timeshift, btrfs-progs, snapper, cryptsetup, GRUB, systemd-boot, dracut,
  mkinitcpio, initramfs-tools. Report those upstream.
* **An unencrypted backup drive.** The suite encrypts nothing itself; it
  unlocks a LUKS drive you made and writes to it. A plain drive is your choice,
  and the borg repository is initialised with `--encryption=none` by design
  because LUKS provides the encryption at rest.
* **A lost keyfile, or a forgotten drive passphrase.** There is no backdoor.
  That is the drive working.
* **A setup this suite does not handle.** A distro, filesystem or boot layout
  outside the status tables is a setup request, and the README says how to
  hand-roll it. It becomes a finding only if `backup-verify.sh` calls that
  setup restore-ready when it is not.
* **Backups not running because the drive was never plugged in.** Ad-hoc is a
  policy, not a bug.

## Before you send diagnostics

**Read this one.** A backup system's artefacts include the keys to the drive
they live on.

**Use the troubleshooting report rather than assembling one by hand.** It is
built to be safe to paste in public: it never reads a keyfile's contents,
never dumps a LUKS header, never prints a passphrase, and truncates every UUID
to eight characters unless you pass `--no-redact`.

```bash
sudo ./backup-diag.sh -o backup-diag.md
```

Read the file before you post it. The script is careful, but you are the last
check on what leaves your machine — and for a **security** report, send it to
the email address above rather than attaching it to an issue.

* **Never send a keyfile.** Not `BACKUP_KEYFILE`, not anything under
  `/etc/luks-keys/`. It opens the drive.
* **Never send a LUKS header backup.** Not one from `/root/luks-headers`, not
  one from the drive's `luks-headers/`. It carries every keyslot, offline-
  attackable. There is no bug report that needs it. The **filename** is fine —
  it encodes only the slot numbers.
* **Never send a borg passphrase**, if you set one.
* **`cryptsetup luksDump` output is safe to share** — it prints parameters,
  not key material. The report includes that subset already.
* **The backup logs are usually fine to send** — `/var/log/borg-backup.log`,
  `/var/log/backintime-backup.log`, `/var/log/timeshift-backup.log`,
  `/var/log/luks-header-backup.log` carry paths and UUIDs, occasionally more
  than you meant to. The report already tails them, redacted.

Send the smallest thing that demonstrates the problem.
