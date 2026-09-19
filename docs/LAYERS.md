# The layers, and why three of them

What each backup layer is for, why one tool is never enough, and how the set maps onto the 3-2-1 rule. Back to the [README](../README.md).

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
