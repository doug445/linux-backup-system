#!/usr/bin/env bash
#
# linux-backup-system — restore-verified multi-layer Linux backups for every distro and boot layout
# https://github.com/doug445/linux-backup-system
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Restore-readiness check: assert that a bare-metal restore would actually work.
#
# This does NOT check that backups ran. It checks that what they produced could
# be used to rebuild the machine. Those are different questions, and only the
# second one matters when the disk is gone.
#
# Portable across the fleet (x86_64 and aarch64/Asahi): every path is derived
# from crypttab/fstab/findmnt at run time, nothing is hardcoded to one host.
#
# Exit: 0 = restore-ready, 1 = ready with warnings, 2 = a restore would fail.
set -uo pipefail

# Per-host config: source the shared library and /etc/backup-system.conf so a
# run by hand (or from the tray) sees the same drive the units do. Values set
# in the environment — the units' Environment= lines — still win.
_env_mount="${BACKUP_MOUNT:-}"; _env_repo="${BORG_REPO:-}"; _env_keep="${KEEP:-}"
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _c in "$_self_dir/backup-common.sh" /usr/local/sbin/backup-common.sh /usr/local/lib/backup-common.sh; do
    # shellcheck disable=SC1090
    [ -r "$_c" ] && { . "$_c"; break; }
done
declare -f bx_load_config >/dev/null && bx_load_config
[ -n "$_env_mount" ] && BACKUP_MOUNT="$_env_mount"
[ -n "$_env_repo" ] && BORG_REPO="$_env_repo"
BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
HEADER_DIRS=("/root/luks-headers" "$BACKUP_MOUNT/luks-headers")
MAX_ARCHIVE_AGE_H=${MAX_ARCHIVE_AGE_H:-48}
# Extra keyfiles to test against the backup volume, space-separated. The usual
# locations are scanned automatically (see keyfile_candidates).
EXTRA_KEYFILES="${EXTRA_KEYFILES:-}"

# borg must never block on a prompt inside a timer unit. A moved repo or an
# unencrypted one are both normal here (LUKS provides the encryption).
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

fail=0; warn=0
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else R=""; G=""; Y=""; B=""; N=""; fi
ok()   { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; fail=1; }
note() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; warn=1; }
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }

# Active keyslot numbers of a LUKS device, one per line. LUKS2 dumps them as
# "  0: luks2", LUKS1 as "Key Slot 0: ENABLED".
slots_of() {
    cryptsetup luksDump "$1" 2>/dev/null | awk '
        /^[[:space:]]+[0-9]+: luks2/     { sub(/:/, "", $1); print $1 }
        /^Key Slot [0-9]+: ENABLED/      { sub(/:/, "", $3); print $3 }'
}

# The borg repo: $BORG_REPO if set, else the first directory directly under the
# backup mount that looks like one (a borg "config" file next to "data/").
# The fleet's borg-backup.sh names it borg-backup; older docs said borg-repo.
find_borg_repo() {
    local d
    if [[ -n "${BORG_REPO:-}" ]]; then printf '%s\n' "$BORG_REPO"; return 0; fi
    for d in "$BACKUP_MOUNT/borg-backup" "$BACKUP_MOUNT/borg-repo"; do
        [[ -f "$d/config" && -d "$d/data" ]] && { printf '%s\n' "$d"; return 0; }
    done
    for d in "$BACKUP_MOUNT"/*/; do
        d=${d%/}
        [[ -f "$d/config" && -d "$d/data" ]] || continue
        grep -qs '^\[repository\]' "$d/config" && { printf '%s\n' "$d"; return 0; }
    done
    printf '%s\n' "$BACKUP_MOUNT/borg-backup"
}

# Paths this machine needs to boot, as archive-relative paths. Layout differs:
# UKI + systemd-boot uses /efi + /boot, GRUB-EFI and Asahi use /boot/efi +
# /boot, legacy-BIOS GRUB has only /boot -- and /boot may be its own filesystem
# or just a directory on root.
#
# Do NOT gate /boot on findmnt: `findmnt /boot` returns nothing when /boot is a
# plain directory, which would silently skip the check on every GRUB box that
# has no separate boot partition, and report restore-ready without ever having
# looked at a boot file.
boot_paths() {
    [[ -d /boot ]] && printf 'boot\n'
    # The ESP, wherever it lives -- asserted separately from /boot, because a
    # bare "boot" match is satisfied by /boot/vmlinuz alone and would pass even
    # with the ESP missing (no grubx64.efi / no BOOTX64.EFI means no boot).
    # Read fstab as well as findmnt: an ESP declared but not mounted means the
    # backup captured an empty directory, which must fail rather than go unseen.
    { findmnt -rno TARGET,FSTYPE 2>/dev/null | awk '$2=="vfat" {print $1}'
      awk '$1 !~ /^#/ && $3 == "vfat" {print $2}' /etc/fstab 2>/dev/null
    } | grep -xE '/efi|/boot/efi' | sort -u | sed 's#^/##'
    return 0
}

# Legacy BIOS GRUB keeps stage1/core.img in the MBR gap or a bios_grub
# partition. Neither is a filesystem, so no file-level backup contains them.
is_bios_boot() { [[ ! -d /sys/firmware/efi ]]; }

# Fedora ships grub2-*, Arch/Debian ship grub-*. Both layouts appear fleet-wide
# (Fedora, Manjaro, EndeavourOS, Linux Mint, Asahi).
uses_grub() { [[ -f /boot/grub2/grub.cfg || -f /boot/grub/grub.cfg ]]; }

grub_version() {
    local g
    for g in grub2-install grub-install grub2-mkconfig grub-mkconfig; do
        command -v "$g" &>/dev/null || continue
        "$g" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
        return 0
    done
}

# true when $1 >= $2
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# GRUB gained LUKS2 argon2 support in 2.12. Below that it can only derive
# PBKDF2 and an argon2id /boot is genuinely unopenable; at or above it,
# argon2id /boot is fine and is the intended configuration here.
GRUB_ARGON2_MIN="2.12"

# Underlying block device of an active dm-crypt mapping ("" if not one).
luks_dev_of_mapper() {
    cryptsetup status "$1" 2>/dev/null | awk '/device:/ {print $2}'
}

# Backing LUKS device of /boot, if /boot is encrypted. Empty otherwise.
boot_luks_dev() {
    local src
    src=$(findmnt -no SOURCE /boot 2>/dev/null) || return 0
    src=${src%%\[*}          # btrfs: "/dev/mapper/x[/subvol]"
    [[ "$src" == /dev/mapper/* ]] || return 0
    luks_dev_of_mapper "${src#/dev/mapper/}"
}

is_asahi() {
    grep -qi apple /proc/device-tree/compatible 2>/dev/null
}

# Every keyfile on this machine that might open the backup volume. crypttab is
# only one source: fleet hosts unlock the backup drive from a udev-triggered
# attach script with its own KEYFILE=, which crypttab never sees. Missing one
# is the false PASS this check exists to prevent, so cast wide: crypttab,
# the standard key directories, and any --key-file / KEYFILE= path mentioned
# by a local script or unit.
keyfile_candidates() {
    {
        awk '$1 !~ /^#/ && NF >= 3 && $3 != "none" && $3 != "-" {print $3}' \
            /etc/crypttab 2>/dev/null
        find /etc/luks-keys /etc/cryptsetup-keys.d -maxdepth 1 -type f 2>/dev/null
        find /root -maxdepth 1 -type f \( -name '.luks*' -o -name '*.key' -o -name '*keyfile*' \) 2>/dev/null
        grep -rhoE -- '(--key-file[= ]+|KEYFILE=)"?/[^" ]+' \
            /usr/local/sbin /usr/local/bin /etc/systemd/system /etc/udev/rules.d 2>/dev/null \
            | sed -E 's/^(--key-file[= ]+|KEYFILE=)"?//'
        tr ' ' '\n' <<< "$EXTRA_KEYFILES"
    } | grep -E '^/' | sort -u | while IFS= read -r f; do
        [[ -f "$f" && -r "$f" ]] || continue
        # a real keyfile is small; skip anything that is obviously not one
        (( $(stat -c %s "$f" 2>/dev/null || echo 0) <= 8388608 )) || continue
        printf '%s\n' "$f"
    done
}

printf '%shost:%s %s   %sarch:%s %s' "$B" "$N" "$(hostname)" "$B" "$N" "$(uname -m)"
is_asahi && printf '   (Asahi / Apple Silicon)'
printf '\n'

hdr "1. Backup volume is independently unlockable"
# The failure this exists to catch: the only key to the backup volume living on
# the very filesystem the backup is meant to replace. If the root disk dies, a
# keyfile-only backup volume is unrecoverable ciphertext.
backup_src=$(findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null)
backup_src=${backup_src%%\[*}
backup_dev=""
if [[ "$backup_src" == /dev/mapper/* ]]; then
    backup_dev=$(luks_dev_of_mapper "${backup_src#/dev/mapper/}")
fi

if [[ -z "$backup_dev" ]]; then
    note "could not resolve a LUKS device behind $BACKUP_MOUNT (not mounted? not encrypted?)"
else
    mapfile -t all_slots < <(slots_of "$backup_dev")
    echo "  backup device: $backup_dev   keyslots: ${all_slots[*]:-none}"
    mapfile -t keyfiles < <(keyfile_candidates)
    echo "  keyfiles tested: ${#keyfiles[@]}${keyfiles[0]:+ (${keyfiles[*]})}"

    # Slots a stored keyfile can open are NOT independent secrets. A slot whose
    # test could not be completed (e.g. argon2 memory the host cannot allocate)
    # is not counted as independent either: an unlock that fails here fails in
    # a rescue environment too.
    declare -A keyfile_slot=() untestable=()
    for kf in "${keyfiles[@]}"; do
        for s in "${all_slots[@]}"; do
            [[ -n "${keyfile_slot[$s]:-}" ]] && continue
            cryptsetup luksOpen --test-passphrase --key-file "$kf" \
                --key-slot "$s" "$backup_dev" &>/dev/null
            rc=$?
            case $rc in
                0) keyfile_slot[$s]="$kf" ;;
                2) ;;                         # wrong key for this slot: fine
                *) untestable[$s]="rc=$rc with $kf" ;;
            esac
        done
    done

    independent=0
    for s in "${all_slots[@]}"; do
        if [[ -n "${keyfile_slot[$s]:-}" ]]; then
            echo "    slot $s: opened by keyfile ${keyfile_slot[$s]}"
        elif [[ -n "${untestable[$s]:-}" ]]; then
            note "slot $s: could not be tested (cryptsetup ${untestable[$s]}); not counted"
        else
            echo "    slot $s: not opened by any known keyfile (independent secret)"
            independent=$((independent + 1))
        fi
    done

    if (( independent > 0 )); then
        ok "$independent independent keyslot(s) — backup survives loss of the root disk"
        (( ${#keyfiles[@]} == 0 )) && note "no keyfile candidates found to test; if one exists, pass EXTRA_KEYFILES="
    else
        bad "EVERY keyslot on the backup volume is a keyfile stored on another disk."
        echo "        If that disk dies, this backup is permanently unreadable."
        echo "        Fix (see README, mind the memory cost on small-RAM machines):"
        echo "          sudo cryptsetup luksAddKey $backup_dev --key-file <existing-keyfile> \\"
        echo "            --pbkdf argon2id --hash sha512 --pbkdf-memory 4194304 \\"
        echo "            --pbkdf-force-iterations 8 --pbkdf-parallel 4"
    fi
fi

hdr "2. LUKS header backups current and stored off-device"
# Match on the keyslot set encoded in the filename. Sorting filenames and taking
# the last is wrong: "slots-0-1" sorts before "slots-1", so a lexical sort
# happily picks a stale header over the current one.
while read -r dev uuid; do
    [[ -n "$dev" ]] || continue
    live=$(slots_of "$dev" | paste -sd- -)
    short=${uuid:0:8}
    if [[ -z "$live" ]]; then
        bad "$(basename "$dev") (uuid $short): could not read its keyslots"
        continue
    fi
    for d in "${HEADER_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        cur=$(find "$d" -maxdepth 1 -name "*_${short}_slots-${live}_*.header" 2>/dev/null | head -1)
        any=$(find "$d" -maxdepth 1 -name "*_${short}_slots-*.header" 2>/dev/null | wc -l)
        if [[ -n "$cur" ]]; then
            ok "$(basename "$dev"): current header in $d ($(basename "$cur"))"
            stale=$(find "$d" -maxdepth 1 -name "*_${short}_slots-*.header" \
                    ! -name "*_slots-${live}_*.header" 2>/dev/null | wc -l)
            (( stale > 0 )) && note "$(basename "$dev"): $stale superseded header(s) also in $d"
        elif (( any > 0 )); then
            bad "$(basename "$dev"): no header in $d matches live keyslots ($live)"
        else
            bad "$(basename "$dev") (uuid $short): NO header backup in $d"
        fi
    done
done < <(lsblk -rno PATH,FSTYPE,UUID | awk '$2=="crypto_LUKS"{print $1, $3}')

hdr "3. Borg archive exists, is fresh, and is bootable-complete"
BORG_REPO=$(find_borg_repo)
if [[ -d "$BORG_REPO" ]]; then
    echo "  repo: $BORG_REPO"
    # A backup in progress holds the repo lock; that is not a broken repo.
    berr=$(mktemp /tmp/backup-verify.XXXXXX)
    arch=$(borg list --lock-wait 30 --last 1 --format '{archive}{NL}' "$BORG_REPO" 2>"$berr")
    rc=$?
    if (( rc != 0 )); then
        if grep -qi 'lock' "$berr"; then
            note "repo is locked (backup running?); archive checks skipped this run"
        else
            bad "borg cannot read $BORG_REPO (rc=$rc): $(tail -1 "$berr")"
        fi
    elif [[ -z "$arch" ]]; then
        bad "no archives in $BORG_REPO"
    else
        echo "  latest archive: $arch"
        # borg has no {start} placeholder; {time} is "Fri, 2026-09-11 11:19:18"
        # and date(1) needs the weekday stripped.
        atime=$(borg list --lock-wait 30 --last 1 --format '{time}{NL}' "$BORG_REPO" 2>/dev/null \
                | sed 's/^[A-Za-z]*, //')
        aepoch=$(date -d "$atime" +%s 2>/dev/null)
        if [[ -z "${aepoch:-}" ]]; then
            note "could not parse archive timestamp: '$atime'"
        else
            age_h=$(( ( $(date +%s) - aepoch ) / 3600 ))
            if (( age_h > MAX_ARCHIVE_AGE_H )); then
                note "latest archive is ${age_h}h old (threshold ${MAX_ARCHIVE_AGE_H}h)"
            else
                ok "latest archive is ${age_h}h old"
            fi
        fi
        # Enumerate the archive ONCE; every check below reads this listing.
        # Walking it per-path costs minutes on a large repo.
        listing=$(mktemp /tmp/backup-verify.XXXXXX)
        if borg list --lock-wait 30 --format '{path}{NL}' "$BORG_REPO::$arch" 2>/dev/null > "$listing"; then
            mapfile -t need < <(printf 'etc/fstab\netc/crypttab\n'; boot_paths)
            for p in "${need[@]}"; do
                n=$(grep -cE "^${p}(/|$)" "$listing")
                if (( n > 0 )); then ok "archive contains /$p ($n entries)"
                else bad "archive is MISSING /$p — restore would not boot"; fi
            done

            # A non-empty /boot is not the same as a bootable one. Assert an
            # actual kernel and a bootloader config, in whatever form this host
            # uses: UKI, plain vmlinuz+initramfs, GRUB, or systemd-boot.
            # Only look under boot/ and efi/: /usr/lib/modules keeps a vmlinuz
            # copy on Fedora and would satisfy a root-only archive.
            uki=$(grep -icE '^(boot|efi)/.*/EFI/Linux/.*\.efi$' "$listing")
            kern=$(grep -cE '^(boot|efi)/(.*/)?(vmlinuz|vmlinux|Image|kernel)(-|$)' "$listing")
            gcfg=$(grep -icE '^(boot|efi)/.*/grub\.cfg$' "$listing")
            sdb=$(grep -icE '^(boot|efi)/.*/loader/(loader\.conf|entries/.+\.conf)$' "$listing")

            if (( uki > 0 || kern > 0 )); then
                ok "archive has a kernel ($uki UKI, $kern vmlinuz/Image)"
            else
                bad "archive contains NO kernel image — restore would not boot"
            fi
            if (( gcfg > 0 || sdb > 0 || uki > 0 )); then
                ok "archive has a bootloader config ($gcfg grub.cfg, $sdb sd-boot, $uki UKI)"
            else
                bad "archive has NO bootloader config (no grub.cfg, loader entries, or UKI)"
            fi
        else
            bad "could not read archive $arch"
        fi
        rm -f "$listing"
    fi
    rm -f "$berr"
else
    note "no borg repo at $BORG_REPO"
fi

hdr "4. Local/replica snapshot layer is intact"
# Which engine is correct here depends on the root filesystem: btrfs roots get
# send/receive replicas (borg-backup.sh / snapper-replicate), everything else
# gets Timeshift. Checking for btrfs replicas on an ext4/xfs box would warn
# forever about a layer that host is not supposed to have, so branch on the fs.
if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == btrfs ]]; then
    # Two layouts exist on the fleet: snapper-replicate's <config>/<num>/snapshot
    # and borg-backup.sh's flat <label>_<stamp>. Enumerate subvolumes rather than
    # a fixed depth: a btrfs subvolume root is always inode 256.
    inc=0; tot=0
    if [[ -d "$BACKUP_MOUNT/snapshots" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            show=$(btrfs subvolume show "$s" 2>/dev/null) || continue
            tot=$((tot + 1))
            ro=$(btrfs property get "$s" ro 2>/dev/null | cut -d= -f2)
            ru=$(grep -oE 'Received UUID:[[:space:]]+[0-9a-f]{8}-' <<< "$show")
            if [[ "$ro" != "true" || -z "$ru" ]]; then
                bad "incomplete receive: $s"
                inc=$((inc + 1))
            fi
        done < <(find "$BACKUP_MOUNT/snapshots" -mindepth 1 -maxdepth 3 -type d -inum 256 2>/dev/null | sort)
        if (( tot == 0 )); then
            note "no btrfs subvolumes found under $BACKUP_MOUNT/snapshots"
        elif (( inc == 0 )); then
            ok "$tot replicated subvolumes, all complete (ro + received_uuid)"
        fi
    else
        note "no btrfs replicas at $BACKUP_MOUNT/snapshots"
    fi
else
    # Non-btrfs root: Timeshift is this layer. A snapshot dir is complete when it
    # carries the rsync payload (localhost/) that a restore actually reads back.
    ts_dir="$BACKUP_MOUNT/timeshift/snapshots"
    if [[ -d "$ts_dir" ]]; then
        tot=0; inc=0
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            tot=$((tot + 1))
            if [[ ! -d "$s/localhost" ]]; then
                bad "incomplete Timeshift snapshot (no localhost/ payload): $s"
                inc=$((inc + 1))
            fi
        done < <(find "$ts_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if (( tot == 0 )); then
            note "no Timeshift snapshots yet under $ts_dir"
        elif (( inc == 0 )); then
            ok "$tot Timeshift snapshot(s), all complete (rsync payload present)"
        fi
    else
        note "no Timeshift snapshots at $ts_dir (non-btrfs local layer not in use)"
    fi
fi

hdr "5. Capacity"
if mountpoint -q "$BACKUP_MOUNT"; then
    use=$(df --output=pcent "$BACKUP_MOUNT" | tail -1 | tr -dc '0-9')
    avail=$(df -h --output=avail "$BACKUP_MOUNT" | tail -1 | tr -d ' ')
    if   (( use > 90 )); then bad  "backup volume ${use}% full (${avail} free)"
    elif (( use > 80 )); then note "backup volume ${use}% full (${avail} free)"
    else ok "backup volume ${use}% full (${avail} free)"; fi
else
    bad "$BACKUP_MOUNT is not mounted"
fi

boot_dev="$(boot_luks_dev)"
if [[ -n "$boot_dev" ]] || is_asahi || is_bios_boot; then
    hdr "6. Boot chain notes for this layout (informational)"
    if [[ -n "$boot_dev" ]]; then
        boot_kdf=$(cryptsetup luksDump "$boot_dev" 2>/dev/null | awk '/PBKDF:/ {print $2; exit}')
        boot_ver=$(cryptsetup luksDump "$boot_dev" 2>/dev/null | awk '/^Version:/ {print $2; exit}')
        say_kdf="LUKS${boot_ver:-?}/${boot_kdf:-unknown}"
        if uses_grub && [[ "$boot_kdf" == argon2* ]]; then
            gv="$(grub_version)"
            if [[ -z "$gv" ]]; then
                note "/boot is encrypted ($boot_dev, $say_kdf), GRUB in use, version unknown."
                echo "        argon2 needs GRUB >= $GRUB_ARGON2_MIN. Keep that in mind when"
                echo "        restoring onto a distro whose stock GRUB is older."
            elif ver_ge "$gv" "$GRUB_ARGON2_MIN"; then
                ok "/boot encrypted ($say_kdf), GRUB $gv derives argon2 — supported"
                echo "        Restore onto GRUB >= $GRUB_ARGON2_MIN. A distro's stock GRUB may be"
                echo "        older than the one built here; check before rebuilding /boot."
            else
                bad "/boot is argon2-encrypted but GRUB $gv predates argon2 support (>= $GRUB_ARGON2_MIN)."
                echo "        This host should not be able to unlock /boot at boot. Either"
                echo "        GRUB was replaced out of band, or a restore onto this GRUB"
                echo "        version would leave /boot unreachable."
            fi
        elif uses_grub; then
            note "/boot is encrypted ($boot_dev, $say_kdf), GRUB in use."
            echo "        Fleet contract is Argon2id; this volume reports ${boot_kdf:-unknown}."
        else
            note "/boot is encrypted ($boot_dev, $say_kdf)."
            echo "        Its header is covered by check 2. The initramfs/bootloader must"
            echo "        still be able to unlock it after a restore."
        fi
    fi
    if is_asahi; then
        note "m1n1/U-Boot live in Apple-managed partitions that Linux cannot back up."
        echo "        A bare-metal restore needs the Asahi installer to rebuild the boot"
        echo "        chain first; only then can this backup be restored onto it."
    fi
    if is_bios_boot; then
        note "Legacy BIOS boot: GRUB stage1/core.img sit in the MBR gap or a"
        echo "        bios_grub partition -- raw sectors, in no file-level backup."
        echo "        After restoring, reinstall them:  grub2-install /dev/sdX"
        echo "        (grub-install on Debian/Ubuntu), then regenerate grub.cfg."
    fi
fi

echo
if   (( fail )); then printf '%sRESTORE WOULD FAIL — fix the FAIL items above.%s\n' "$R" "$N"; exit 2
elif (( warn )); then printf '%sReady, with warnings.%s\n' "$Y" "$N"; exit 1
else printf '%sRestore-ready.%s\n' "$G" "$N"; exit 0; fi
