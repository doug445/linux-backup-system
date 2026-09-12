# Contributing to linux-backup-system

**linux-backup-system 3.4.0**

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
| **Declined** | Refactors, new options, general feature requests — regardless of quality |

---

## Most wanted: setup reports

The library, the command lines and the read-only tools are exercised in CI on
every push, on x86_64 and aarch64. What CI cannot prove is that on **your**
distro, root filesystem and boot layout the suite detects the right things,
writes a real backup, and that `backup-verify.sh` then agrees a restore would
boot.

Every ❌ row in the README's status tables is a setup the code claims to handle
and that has not been confirmed on metal by me. **This repository stays
private until every row is green.** A report that it worked is as valuable as
a bug report — it is the only way a row ever turns ✅.

| Setup | Status | What to confirm |
|---|---|---|
| Fedora, Fedora Asahi Remix (aarch64), Debian / Ubuntu / Mint | ✅ | still worth a report on a different boot layout |
| **Arch / Manjaro / EndeavourOS** | ❌ | packages resolve; `backintime` from AUR; a real backup + verify pass |
| **openSUSE** | ❌ | `zypper` package names; a real backup + verify pass |
| btrfs root → snapper + send/receive replicas | ✅ | |
| ext4 root → Timeshift layer | ✅ create | **count and free-space prune never fired on a real drive** |
| **xfs / f2fs / any other root** | ❌ | that the Timeshift layer engages and verifies |
| systemd-boot, UKI, GRUB EFI, encrypted argon2id `/boot` | ✅ | |
| **GRUB legacy BIOS** | ❌ | `restore-rebuild-boot.sh` finds the boot disk; a restored machine boots |
| **Plain (unencrypted) `/boot`** | ❌ | verify's boot-chain section; a restored machine boots |
| **Raspberry Pi firmware boot** (Raspberry Pi OS, `/boot/firmware`) | ❌ — written against synthetic listings only | `bx_esp_mount` finds `/boot/firmware`; borg lists it as a source; verify section 3 PASSes on a real archive; `restore-rebuild-boot.sh --dry-run` shows the `cmdline.txt` rewrite; a restored card boots |
| **Bare-metal restore executing the boot rebuild** | ❌ | the `--dry-run` plan has been checked; the real plan has never been *executed* on hardware |

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
   sudo backup-verify.sh; echo "exit $?"     # 0 = restore-ready
   ```
3. anything you had to fix by hand — **that is the actual finding.**

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
change this project wants. The README's *Hand-rolling a fix* section says
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
