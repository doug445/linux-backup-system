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
# restore-rebuild-boot.sh — rebuild the boot chain after a file restore.
#
# Universal across bootloaders and kernel forms. Run INSIDE the restored system
# (the restore scripts copy it into $TARGET and execute it under chroot; it can
# also be run standalone inside an arch-chroot, or with --dry-run on a live
# system to see what it WOULD do). It detects everything from the system it runs
# in — distro, arch, kernels, LUKS, ESP, bootloader and kernel form — so it needs
# no arguments beyond the optional --dry-run.
#
# Handles:
#   - initramfs: dracut / update-initramfs / mkinitcpio
#   - UKI (unified kernel image): kernel-install / dracut --uefi
#   - bootloader: GRUB (EFI + BIOS, x86_64/aarch64), systemd-boot (bootctl),
#     Limine and rEFInd (untested on metal), with a firmware boot entry
#   - encrypted /boot: enables GRUB cryptodisk; warns if GRUB < 2.12 with argon2
#
# Usage:  restore-rebuild-boot.sh [--dry-run]
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
# RESTORE_NO_NVRAM=1 (set by the restore scripts when they run from an
# installed system): write no firmware boot entry — install the loaders at the
# removable-media fallback path the firmware boots from its boot menu, and
# leave this machine's boot order alone.
NO_NVRAM="${RESTORE_NO_NVRAM:-0}"
[ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ] && DRY=1

say()  { echo "[rebuild-boot]${DRY:+ [DRY]} $*"; }
warn() { echo "[rebuild-boot]${DRY:+ [DRY]} WARNING: $*"; }
# run: log the command; execute it unless --dry-run.
run()  { if (( DRY )); then echo "[rebuild-boot] [DRY] would: $*"; else echo "[rebuild-boot] + $*"; "$@"; fi; }
# runsh: same, for a shell snippet (redirections/pipes).
runsh(){ if (( DRY )); then echo "[rebuild-boot] [DRY] would: $1"; else echo "[rebuild-boot] + $1"; bash -c "$1"; fi; }

# ---------------------------------------------------------------------------
# Detect the system we are rebuilding.
# ---------------------------------------------------------------------------
DISTRO_FAMILY=unknown
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*|*mint*) DISTRO_FAMILY=debian ;;
        *fedora*|*rhel*|*centos*) DISTRO_FAMILY=fedora ;;
        *arch*)                   DISTRO_FAMILY=arch ;;
    esac
fi
ARCH=$(uname -m)

# Kernel versions = the module directories present in the restored system.
mapfile -t KVERS < <(ls -1 /lib/modules 2>/dev/null)

# LUKS in use? (any active crypttab entry in the restored system)
HAS_LUKS=false
grep -qsvE '^\s*#|^\s*$' /etc/crypttab 2>/dev/null && HAS_LUKS=true

# ESP mountpoint.
ESP=""
for e in /boot/efi /efi /boot/firmware; do mountpoint -q "$e" 2>/dev/null && { ESP="$e"; break; }; done
[ -z "$ESP" ] && { for e in /boot/efi /efi; do [ -d "$e/EFI" ] && { ESP="$e"; break; }; done; }
IS_EFI=false; [ -d /sys/firmware/efi ] && IS_EFI=true

# Partition type as firmware and systemd-boot see it: esp | xbootldr | other | unknown.
ptkind() {
    local pt; pt=$(lsblk -dno PARTTYPE "$1" 2>/dev/null | head -1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    case "$pt" in
        c12a7328-f81f-11d2-ba4b-00a0c93ec93b|0xef) echo esp ;;
        bc13c2ff-59e6-4262-a352-b275fd6f7172|0xea) echo xbootldr ;;
        "") echo unknown ;;
        *) echo other ;;
    esac
}
# /boot itself may be the ESP (systemd-boot on Arch mounts it there): vfat,
# typed EFI System — or, untyped, holding EFI/ — and no dedicated ESP found.
BOOT_KIND=""
# A GRUB system reads its own /boot (any type); the XBOOTLDR check is for systemd-boot.
USES_GRUB_HINT=false
{ [ -f /boot/grub2/grub.cfg ] || [ -f /boot/grub/grub.cfg ]; } && USES_GRUB_HINT=true
if [ "$(findmnt -no FSTYPE /boot 2>/dev/null)" = vfat ]; then
    BOOT_KIND=$(ptkind "$(findmnt -no SOURCE /boot 2>/dev/null)")
    if [ -z "$ESP" ] && { [ "$BOOT_KIND" = esp ] || { [ "$BOOT_KIND" = unknown ] && [ -d /boot/EFI ]; }; }; then
        ESP=/boot
    fi
fi
# Awareness checks for the NEW disk: the firmware only boots an ESP it can
# recognise, and systemd-boot only reads entries from a /boot typed XBOOTLDR.
if [ "$IS_EFI" = true ] && [ -n "$ESP" ] && mountpoint -q "$ESP" 2>/dev/null; then
    esp_kind=$(ptkind "$(findmnt -no SOURCE "$ESP" 2>/dev/null)")
    case "$esp_kind" in
        esp)     say "ESP $ESP: partition type EFI System — OK" ;;
        unknown) warn "ESP $ESP: partition type unreadable — make sure it is 'EFI System' (GPT C12A7328-…, sgdisk -t N:ef00) or the firmware will not boot it" ;;
        *)       warn "ESP $ESP is NOT typed 'EFI System' ($esp_kind) — the firmware will not find the bootloader. Fix: sgdisk -t N:ef00 <disk>" ;;
    esac
fi
if [ -n "$ESP" ] && [ "$ESP" != /boot ] && [ -n "$BOOT_KIND" ] && mountpoint -q /boot 2>/dev/null; then
    case "$BOOT_KIND" in
        xbootldr) say "/boot: separate vfat, partition type XBOOTLDR — OK" ;;
        # kernel-install may still write there (BOOT_ROOT=/boot), but the
        # loader only reads entries from an ESP or a partition typed XBOOTLDR.
        *) [ "$USES_GRUB_HINT" = true ] || warn "/boot is a separate vfat partition next to ESP $ESP but not typed XBOOTLDR ($BOOT_KIND) — systemd-boot will not see the entries on it. Fix: sgdisk -t N:ea00 <disk>" ;;
    esac
fi
# Raspberry Pi firmware boot: the SoC firmware reads config.txt / cmdline.txt /
# kernel*.img straight from the vfat partition; there is no bootloader to
# install. UNTESTED ON METAL — see the README status table.
IS_PI_FW=false; PI_FW_DIR=""
if [ "$IS_EFI" = false ]; then
    for d in /boot/firmware /boot; do [ -f "$d/config.txt" ] && { IS_PI_FW=true; PI_FW_DIR="$d"; break; }; done
fi

# Kernel form: UKI if the ESP — or an XBOOTLDR /boot — holds unified images,
# or kernel-install is set to uki. And WHICH tool built them: the one whose
# config says so. Preferring kernel-install because it exists (it exists on
# every systemd host) on an Arch box whose UKIs come from mkinitcpio presets
# left the restored UKIs with the OLD command line embedded.
IS_UKI=false; UKI_TOOL=""
for _d in ${ESP:+"$ESP/EFI/Linux"} /boot/EFI/Linux /boot/efi/EFI/Linux /efi/EFI/Linux; do
    compgen -G "$_d/*.efi" >/dev/null 2>&1 && { IS_UKI=true; break; }
done
grep -qs 'layout[[:space:]]*=[[:space:]]*uki' /etc/kernel/install.conf /etc/kernel/install.conf.d/*.conf 2>/dev/null && IS_UKI=true
if [ "$IS_UKI" = true ]; then
    if grep -qsE '^[[:space:]]*default_uki=|^[[:space:]]*fallback_uki=' /etc/mkinitcpio.d/*.preset 2>/dev/null && command -v mkinitcpio >/dev/null 2>&1; then
        UKI_TOOL=mkinitcpio
    elif grep -qsE '^[[:space:]]*uefi=["'"'"']?yes' /etc/dracut.conf /etc/dracut.conf.d/*.conf 2>/dev/null && command -v dracut >/dev/null 2>&1; then
        UKI_TOOL=dracut
    elif grep -qs 'layout[[:space:]]*=[[:space:]]*uki' /etc/kernel/install.conf /etc/kernel/install.conf.d/*.conf 2>/dev/null && command -v kernel-install >/dev/null 2>&1; then
        UKI_TOOL=kernel-install
    elif command -v kernel-install >/dev/null 2>&1; then UKI_TOOL=kernel-install
    elif command -v dracut >/dev/null 2>&1; then UKI_TOOL=dracut
    elif command -v mkinitcpio >/dev/null 2>&1; then UKI_TOOL=mkinitcpio
    fi
fi

# Bootloader: GRUB if a grub.cfg exists; systemd-boot if its EFI binary is on the
# ESP (or bootctl reports installed) — checked independently, a host can have one
# or the other. loader/entries alone does NOT mean systemd-boot: Fedora GRUB uses
# BLS entries in /boot/loader/entries too.
# GRUB is in use when its config exists (or /etc/default/grub next to a
# /boot/grub{,2} directory). NOT merely because the grub package is installed:
# a systemd-boot host with grub still on disk (Manjaro after a migration) got
# grub-install onto its ESP and a new default NVRAM entry pointing at a GRUB
# with no config.
USES_GRUB=false
{ [ -f /boot/grub2/grub.cfg ] || [ -f /boot/grub/grub.cfg ] \
  || { [ -f /etc/default/grub ] && { [ -d /boot/grub2 ] || [ -d /boot/grub ]; }; }; } && USES_GRUB=true
USES_SDBOOT=false
if [ -n "$ESP" ] && compgen -G "$ESP/EFI/systemd/systemd-boot*.efi" >/dev/null 2>&1; then
    USES_SDBOOT=true
elif [ -n "$ESP" ] && [ -d "$ESP/loader/entries" ] && [ ! -f /boot/grub2/grub.cfg ] && [ ! -f /boot/grub/grub.cfg ] \
     && { [ -f "$ESP/EFI/BOOT/BOOTX64.EFI" ] || [ -f "$ESP/EFI/BOOT/BOOTAA64.EFI" ]; }; then
    USES_SDBOOT=true
fi
command -v bootctl >/dev/null 2>&1 && bootctl --quiet is-installed 2>/dev/null && [ "$USES_GRUB" = false ] && USES_SDBOOT=true

# Limine (CachyOS's default): limine.conf wherever Limine reads it, or its EFI
# binary under EFI/limine. rEFInd: its binary or refind.conf under EFI/refind.
# UNTESTED ON METAL — see the README status table.
USES_LIMINE=false; LIMINE_EFI=""
for f in /boot/limine.conf /boot/limine/limine.conf ${ESP:+"$ESP/limine.conf" "$ESP/limine/limine.conf" "$ESP/EFI/limine/limine.conf" "$ESP/EFI/BOOT/limine.conf"}; do
    [ -f "$f" ] && { USES_LIMINE=true; break; }
done
if [ -n "$ESP" ]; then
    for f in "$ESP"/EFI/limine/BOOT*.EFI "$ESP"/EFI/limine/*.efi; do [ -f "$f" ] && { USES_LIMINE=true; LIMINE_EFI="$f"; break; }; done
    [ -z "$LIMINE_EFI" ] && [ -f "$ESP/EFI/BOOT/limine.conf" ] && for f in "$ESP"/EFI/BOOT/BOOT*.EFI; do [ -f "$f" ] && { LIMINE_EFI="$f"; break; }; done
fi
USES_REFIND=false
if [ -n "$ESP" ] && { compgen -G "$ESP/EFI/refind/refind_*.efi" >/dev/null 2>&1 || [ -f "$ESP/EFI/refind/refind.conf" ]; }; then
    USES_REFIND=true
fi

# efi_boot_entry LABEL LOADER — create a firmware boot entry for LOADER (a file
# on the ESP) unless one already points at it on this ESP. NVRAM entries are in
# no backup: a new disk has none, and without one the firmware only tries
# EFI/BOOT/BOOT<arch>.EFI. grub-install and bootctl make their own; Limine
# and a hand-copied rEFInd do not.
efi_boot_entry() {
    local label="$1" loader="$2" src kn disk part puuid rel
    [ "$IS_EFI" = true ] || return 0
    if [ "$NO_NVRAM" = 1 ]; then say "no firmware boot entry for $label (RESTORE_NO_NVRAM=1) — boot it from the firmware boot menu"; return 0; fi
    if ! command -v efibootmgr >/dev/null 2>&1; then
        warn "efibootmgr not installed — no firmware boot entry for $label; install efibootmgr, or pick the disk from the firmware boot menu"
        return 0
    fi
    src=$(findmnt -no SOURCE "$ESP" 2>/dev/null); kn=$(basename "$(readlink -f "$src" 2>/dev/null)")
    disk=$(lsblk -npo PKNAME "$src" 2>/dev/null | head -1)
    part=$(cat "/sys/class/block/$kn/partition" 2>/dev/null || true)
    puuid=$(lsblk -no PARTUUID "$src" 2>/dev/null | head -1)
    rel="\\${loader#"$ESP"/}"; rel="${rel//\//\\}"
    if [ -z "$disk" ] || [ -z "$part" ]; then
        warn "could not resolve the ESP's disk and partition — create the entry by hand: efibootmgr --create --disk <disk> --part <n> --label $label --loader '$rel'"
        return 0
    fi
    if [ -n "$puuid" ] && efibootmgr -v 2>/dev/null | grep -iF "$puuid" | grep -qiF "$(basename "$loader")"; then
        say "firmware boot entry for $label on this ESP already present"
        return 0
    fi
    run efibootmgr --create --disk "$disk" --part "$part" --label "$label" --loader "$rel"
}

# Is /boot on LUKS, and if GRUB, is it new enough for argon2?
BOOT_ON_LUKS=false
boot_src=$(findmnt -no SOURCE /boot 2>/dev/null | sed 's/\[.*//')
[ -z "$boot_src" ] && boot_src=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
[[ "$boot_src" == /dev/mapper/* ]] && BOOT_ON_LUKS=true

# The WHOLE DISK a device sits on, through LUKS/LVM/RAID and partitions. A
# BIOS grub-install wants the disk; `lsblk PKNAME` of /dev/mapper/cryptboot
# gave the partition, and grub-install refused it ("will not proceed with
# blocklists") — no MBR written.
disk_of() {
    local d kn pk sl
    d=$(readlink -f "$1" 2>/dev/null) || return 1; kn=$(basename "$d")
    while :; do
        sl=$(ls "/sys/block/$kn/slaves" 2>/dev/null | head -1 || true)
        if [ -n "$sl" ]; then kn="$sl"; continue; fi
        pk=$(lsblk -dno PKNAME "/dev/$kn" 2>/dev/null | head -1 || true)
        if [ -n "$pk" ]; then kn="$pk"; continue; fi
        break
    done
    [ -b "/dev/$kn" ] && echo "/dev/$kn"
}

# kernel-install takes the command line from /etc/kernel/cmdline, else
# /usr/lib/kernel/cmdline, else /proc/cmdline — which, in this chroot, is the
# LIVE USB's (root=live:CDLABEL=… rd.live.image). Baked into a UKI or a Type #1
# entry that is the only bootable image. Make sure a real one exists first,
# from the restored (already id-rewritten) loader entries if need be.
ensure_kernel_cmdline() {
    [ -s /etc/kernel/cmdline ] && return 0
    [ -s /usr/lib/kernel/cmdline ] && return 0
    local e opts=""
    for e in ${ESP:+"$ESP"/loader/entries/*.conf} /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
        [ -f "$e" ] || continue
        opts=$(awk '$1=="options"{ $1=""; sub(/^ /,""); printf "%s ", $0 }' "$e" | sed 's/ $//')
        [ -n "$opts" ] && break
    done
    if [ -z "$opts" ] && [ -f /etc/default/grub ]; then
        opts=$( . /etc/default/grub 2>/dev/null; echo "${GRUB_CMDLINE_LINUX:-} ${GRUB_CMDLINE_LINUX_DEFAULT:-}" | sed 's/^ //; s/ $//')
    fi
    if [ -z "$opts" ]; then
        warn "no /etc/kernel/cmdline and no restored loader entry to take one from — kernel-install would embed the LIVE system's command line; skipped. Write /etc/kernel/cmdline (root=… etc.) and run kernel-install add by hand."
        return 1
    fi
    say "writing /etc/kernel/cmdline from the restored loader entry: $opts"
    runsh "mkdir -p /etc/kernel && printf '%s\\n' '$opts' > /etc/kernel/cmdline"
}

say "distro=$DISTRO_FAMILY arch=$ARCH efi=$IS_EFI esp=${ESP:-none} no_nvram=$NO_NVRAM"
say "kernels: ${KVERS[*]:-none}"
say "has_luks=$HAS_LUKS boot_on_luks=$BOOT_ON_LUKS uki=$IS_UKI grub=$USES_GRUB systemd-boot=$USES_SDBOOT limine=$USES_LIMINE refind=$USES_REFIND pi_firmware=$IS_PI_FW"
[ ${#KVERS[@]} -eq 0 ] && warn "no kernels found under /lib/modules — cannot rebuild"

# ---------------------------------------------------------------------------
# 1. Rebuild kernels: UKI or plain initramfs, distro-appropriate.
# ---------------------------------------------------------------------------
say "===== kernel / initramfs rebuild ====="
if [ "$IS_UKI" = true ]; then
    say "UKI layout — regenerating unified images with ${UKI_TOOL:-?}"
    case "$UKI_TOOL" in
        mkinitcpio) run mkinitcpio -P ;;
        dracut)     for kv in "${KVERS[@]}"; do run dracut --force --uefi --kver "$kv"; done ;;
        kernel-install)
            if ensure_kernel_cmdline; then
                for kv in "${KVERS[@]}"; do
                    img="/lib/modules/$kv/vmlinuz"; [ -f "$img" ] || img="/boot/vmlinuz-$kv"
                    run kernel-install add "$kv" "$img"
                done
            fi ;;
        *) warn "no mkinitcpio, dracut or kernel-install — cannot regenerate UKIs" ;;
    esac
    # kernel-install and dracut name each image after its kernel version and
    # rebuild only the installed kernels. Anything else on the boot partitions
    # still embeds the SOURCE disk's command line, and the loader menu offers
    # it: a rescue image (Fedora's <token>-0-rescue.efi — its plugin writes
    # Type #1 rescue entries only, so it is rebuilt here with dracut), and the
    # images of kernels removed since (a package removal that left its UKI;
    # no modules, nothing to rebuild from — moved off the boot partitions).
    case "$UKI_TOOL" in kernel-install|dracut)
        _newest=$(printf '%s\n' "${KVERS[@]}" | sort -V | tail -1)
        _stale=/var/lib/linux-backup-system/stale-ukis
        for _u in /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi /boot/efi/EFI/Linux/*.efi; do
            [ -f "$_u" ] || continue
            _b=$(basename "$_u"); _known=false
            for kv in "${KVERS[@]}"; do case "$_b" in *"$kv"*) _known=true; break ;; esac; done
            [ "$_known" = true ] && continue
            case "$_b" in
                *rescue*)
                    if [ -n "$_newest" ] && command -v dracut >/dev/null 2>&1 && ensure_kernel_cmdline; then
                        say "rescue image $_u: rebuilt for this disk (kernel $_newest, no-hostonly)"
                        _cl=$(tr '\n' ' ' < /etc/kernel/cmdline 2>/dev/null || tr '\n' ' ' < /usr/lib/kernel/cmdline)
                        run rm -f "$_u"
                        run dracut --force --uefi --no-hostonly --kver "$_newest" --kernel-cmdline "$_cl" "$_u" \
                            || warn "rescue image rebuild failed — $_u is gone from the menu; rebuild it by hand: dracut --uefi --no-hostonly --kver $_newest $_u"
                        continue
                    fi ;;
            esac
            warn "$_u belongs to no installed kernel (${KVERS[*]}) and cannot be rebuilt — moved to $_stale/ (it names the source disk)"
            run mkdir -p "$_stale"; run mv -f "$_u" "$_stale/"
        done ;;
    esac
else
    if command -v update-initramfs >/dev/null 2>&1; then
        # One kernel at a time, newest first, and every one of them: `-k all -c`
        # writes each new image beside the old one and STOPS at the first
        # failure. On a small /boot (a 732 MiB encrypted one holding four
        # kernels) the first write hit ENOSPC and every initramfs stayed the
        # source disk's — whose crypttab unlocks the OLD root. The old image
        # moves aside to the root filesystem while its replacement is written,
        # and comes back if the new one fails.
        say "Debian family — update-initramfs, one kernel at a time (newest first)"
        aside=/var/tmp/restore-initrd-aside; (( DRY )) || mkdir -p "$aside"
        # Installed kernels only: /lib/modules keeps directories of kernels
        # long removed (module leftovers, DKMS builds), and an initramfs for
        # each of those filled /boot again.
        while read -r kv; do
            [ -n "$kv" ] || continue
            [ -f "/boot/vmlinuz-$kv" ] || { say "skipping $kv — /lib/modules only, no /boot/vmlinuz-$kv"; continue; }
            img="/boot/initrd.img-$kv"
            if [ -f "$img" ] && (( ! DRY )); then mv "$img" "$aside/"; fi
            if run update-initramfs -c -k "$kv"; then
                (( DRY )) || rm -f "$aside/initrd.img-$kv"
            else
                warn "update-initramfs failed for $kv — its previous initramfs is put back (it still describes the SOURCE disk: do not boot this kernel)"
                (( DRY )) || { rm -f "$img"; [ -f "$aside/initrd.img-$kv" ] && mv "$aside/initrd.img-$kv" "$img"; }
            fi
        done < <(printf '%s\n' "${KVERS[@]}" | sort -rV)
        (( DRY )) || rmdir "$aside" 2>/dev/null || true
    elif command -v dracut >/dev/null 2>&1; then
        say "Fedora family — dracut --regenerate-all --force"
        if ! run dracut --regenerate-all --force; then
            for kv in "${KVERS[@]}"; do run dracut --force "/boot/initramfs-$kv.img" "$kv"; done
        fi
    elif command -v mkinitcpio >/dev/null 2>&1; then
        say "Arch family — mkinitcpio -P"
        run mkinitcpio -P
    else
        warn "no initramfs tool found (update-initramfs/dracut/mkinitcpio)"
    fi
fi

# ---------------------------------------------------------------------------
# 2. GRUB: enable cryptodisk when /boot is encrypted, reinstall, regenerate.
# ---------------------------------------------------------------------------
if [ "$USES_GRUB" = true ]; then
    say "===== GRUB ====="
    if [ "$BOOT_ON_LUKS" = true ]; then
        if ! grep -qs '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub 2>/dev/null; then
            say "enabling GRUB_ENABLE_CRYPTODISK=y (encrypted /boot)"
            runsh "sed -i '/^GRUB_ENABLE_CRYPTODISK=/d' /etc/default/grub 2>/dev/null; echo GRUB_ENABLE_CRYPTODISK=y >> /etc/default/grub"
        fi
        gv=$({ grub2-install --version 2>/dev/null || grub-install --version 2>/dev/null; } | grep -oE '[0-9]+\.[0-9]+' | head -1)
        # What GRUB must be able to open depends on the /boot container: LUKS1
        # needs cryptodisk (GRUB >= 2.02), LUKS2 with pbkdf2 needs >= 2.06,
        # argon2 needs >= 2.12. Read the container, not an assumption.
        boot_mapper=$(findmnt -no SOURCE /boot 2>/dev/null | sed 's/\[.*//'); boot_mapper=${boot_mapper#/dev/mapper/}
        boot_luks=$(cryptsetup status "$boot_mapper" 2>/dev/null | awk '/device:/{print $2}')
        boot_kdf=$(cryptsetup luksDump "$boot_luks" 2>/dev/null | awk '/PBKDF:/{print $2; exit}')
        boot_lv=$(cryptsetup luksDump "$boot_luks" 2>/dev/null | awk '/^Version:/{print $2; exit}')
        case "${boot_lv:-?}/${boot_kdf:-?}" in
            */argon2*) need=2.12 ;;
            2/*)       need=2.06 ;;
            1/*)       need=2.02 ;;
            *)         need=2.12 ;;   # unknown: assume the strictest
        esac
        say "encrypted /boot: LUKS${boot_lv:-?}/${boot_kdf:-?} — needs GRUB >= $need (found ${gv:-unknown})"
        if [ -n "$gv" ] && [ "$(printf '%s\n%s\n' "$need" "$gv" | sort -V | head -1)" != "$need" ]; then
            warn "GRUB $gv is older than $need and cannot unlock this /boot (LUKS${boot_lv:-?}/${boot_kdf:-?}) — restore may leave /boot unopenable"
        fi
    fi
    # Reinstall the bootloader
    if [ "$IS_EFI" = true ]; then
        case "$ARCH" in x86_64) gt=x86_64-efi;; aarch64) gt=arm64-efi;; *) gt="$ARCH-efi";; esac
        bid="${ID:-linux}"; edir="${ESP:-/boot/efi}"
        gi=""; command -v grub2-install >/dev/null 2>&1 && gi=grub2-install
        [ -z "$gi" ] && command -v grub-install >/dev/null 2>&1 && gi=grub-install
        if [ "$DISTRO_FAMILY" = fedora ] && compgen -G "$edir/EFI/$bid/shim*.efi" >/dev/null 2>&1; then
            # Fedora/RHEL boot shim -> the SIGNED grubx64.efi from the grub2-efi
            # package. grub2-install would replace it with an unsigned image
            # (Secure Boot then refuses it) or fail for lack of the modules
            # package; the binaries were restored with the files and need no
            # reinstall. The ESP stub EFI/<id>/grub.cfg was id-rewritten by
            # the restore script.
            say "Fedora family with shim on the ESP — keeping the signed GRUB image, not running $gi"
            say "(if the ESP was empty or damaged: dnf reinstall shim-x64 grub2-efi-x64 restores it)"
            # The stub's one job is to find the filesystem holding grub2/grub.cfg.
            # The id rewrite maps only ids the source disk had: a stub that was
            # already dead on the source (left from an earlier /boot) stays dead.
            # Point it at the restored filesystem that holds grub2/ instead.
            _stub="$edir/EFI/$bid/grub.cfg"
            if [ -f "$_stub" ] && [ -f /boot/grub2/grub.cfg ]; then
                if mountpoint -q /boot; then _want=$(findmnt -no UUID /boot); _pfx='($dev)/grub2'
                else _want=$(findmnt -no UUID /); _pfx='($dev)/boot/grub2'; fi
                _have=$(sed -nE 's/.*search .*--fs-uuid --set=dev ([^ ]+).*/\1/p' "$_stub" | head -1)
                if [ -n "$_want" ] && [ -n "$_have" ] && [ "$_have" != "$_want" ]; then
                    say "ESP GRUB stub named fs uuid $_have (not this disk's) — pointed at $_want, the filesystem holding grub2/"
                    runsh "sed -i -E 's/(search .*--fs-uuid --set=dev )$_have/\\1$_want/; s|^set prefix=.*|set prefix=$_pfx|' '$_stub'"
                fi
            fi
        elif [ -n "$gi" ] && [ "$NO_NVRAM" = 1 ]; then
            say "RESTORE_NO_NVRAM=1: GRUB installed without a firmware entry, at the removable-media path"
            run "$gi" --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck --no-nvram
            run "$gi" --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck --no-nvram --removable
        elif [ -n "$gi" ]; then
            if ! run "$gi" --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck; then
                # A firmware that refuses NVRAM writes (efivars read-only, some
                # VMs, Apple): install the files anyway, and as the removable-
                # media fallback path the firmware tries without any entry.
                warn "$gi failed — retrying without touching NVRAM, plus the removable-media fallback (EFI/BOOT/BOOT*.EFI)"
                run "$gi" --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck --no-nvram || true
                run "$gi" --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck --no-nvram --removable || true
            fi
        fi
    else
        disk=$(disk_of "$boot_src" 2>/dev/null || true)
        if [ -n "$disk" ]; then
            command -v grub2-install >/dev/null 2>&1 && run grub2-install "$disk" --recheck \
                || { command -v grub-install >/dev/null 2>&1 && run grub-install "$disk" --recheck; }
        else
            warn "could not determine BIOS boot disk for grub-install (from $boot_src)"
        fi
    fi
    # Regenerate config
    if command -v update-grub >/dev/null 2>&1; then run update-grub
    elif [ -f /boot/grub2/grub.cfg ] && command -v grub2-mkconfig >/dev/null 2>&1; then run grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v grub-mkconfig >/dev/null 2>&1; then run grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v grub2-mkconfig >/dev/null 2>&1; then run grub2-mkconfig -o /boot/grub2/grub.cfg
    else warn "no grub config generator found"; fi
fi

# ---------------------------------------------------------------------------
# 3. systemd-boot: reinstall the loader and (re)create entries.
# ---------------------------------------------------------------------------
if [ "$USES_SDBOOT" = true ]; then
    say "===== systemd-boot ====="
    if command -v bootctl >/dev/null 2>&1; then
        if [ "$NO_NVRAM" = 1 ]; then
            say "RESTORE_NO_NVRAM=1: systemd-boot installed without touching EFI variables (EFI/BOOT/BOOT*.EFI is the entry point)"
            run bootctl ${ESP:+--esp-path="$ESP"} --no-variables install
        elif ! run bootctl ${ESP:+--esp-path="$ESP"} install; then
            warn "bootctl install failed — retrying without NVRAM variables (the firmware boots EFI/BOOT/BOOT*.EFI, which bootctl also writes)"
            run bootctl ${ESP:+--esp-path="$ESP"} --no-variables install || true
        fi
        # kernel-install writes Type#1 entries (or UKIs) per the install layout.
        # Only where kernel-install owns the entries: on a mkinitcpio host the
        # restored entries are already right (their ids were rewritten) and
        # kernel-install would add a second set with the live USB's cmdline.
        if [ "$IS_UKI" = true ] && [ "$UKI_TOOL" != kernel-install ]; then
            say "entries/UKIs are managed by $UKI_TOOL (rebuilt above) — not running kernel-install"
        elif command -v kernel-install >/dev/null 2>&1 && compgen -G "${ESP:-/boot}/$(cat /etc/machine-id 2>/dev/null)/*" >/dev/null 2>&1; then
            if ensure_kernel_cmdline; then
                for kv in "${KVERS[@]}"; do
                    img="/lib/modules/$kv/vmlinuz"; [ -f "$img" ] || img="/boot/vmlinuz-$kv"
                    run kernel-install add "$kv" "$img"
                done
            fi
        elif command -v kernel-install >/dev/null 2>&1 && ! compgen -G "${ESP:-/boot}/loader/entries/*.conf" >/dev/null 2>&1 && ! compgen -G "/boot/loader/entries/*.conf" >/dev/null 2>&1; then
            # no entries at all were restored: let kernel-install create them
            if ensure_kernel_cmdline; then
                for kv in "${KVERS[@]}"; do
                    img="/lib/modules/$kv/vmlinuz"; [ -f "$img" ] || img="/boot/vmlinuz-$kv"
                    run kernel-install add "$kv" "$img"
                done
            fi
        else
            say "loader entries restored with the files (ids rewritten) — kept as they are"
        fi
    else
        warn "systemd-boot detected but bootctl not available"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Limine: reinstall the loader binary (UEFI) or its boot sector (BIOS) and
#    create the firmware boot entry. limine.conf itself was restored with the
#    files and its kernel command lines rewritten by the restore script.
#    UNTESTED ON METAL.
# ---------------------------------------------------------------------------
if [ "$USES_LIMINE" = true ]; then
    say "===== Limine ====="
    if command -v limine-install >/dev/null 2>&1; then
        # CachyOS's limine-mkinitcpio-hook: installs the binary, the entries
        # and the firmware boot entry for this system's own layout.
        run limine-install || warn "limine-install reported errors — review above"
        command -v limine-update >/dev/null 2>&1 && { run limine-update || warn "limine-update reported errors — review above"; }
    elif [ "$IS_EFI" = true ]; then
        case "$ARCH" in x86_64) lb=BOOTX64.EFI ;; aarch64) lb=BOOTAA64.EFI ;; *) lb="" ;; esac
        if [ -z "$ESP" ]; then
            warn "Limine on UEFI but no ESP mounted — cannot reinstall it"
        elif [ -z "$lb" ] || [ ! -f "/usr/share/limine/$lb" ]; then
            warn "Limine EFI binary /usr/share/limine/${lb:-BOOT<arch>.EFI} not found — is the limine package installed in the restored system?"
        else
            dest="${LIMINE_EFI:-$ESP/EFI/limine/$lb}"
            runsh "mkdir -p '$(dirname "$dest")' && cp /usr/share/limine/$lb '$dest'"
            efi_boot_entry Limine "$dest"
        fi
    else
        disk=$(lsblk -npo PKNAME "$boot_src" 2>/dev/null | head -1)
        if [ -n "$disk" ] && command -v limine >/dev/null 2>&1; then
            run limine bios-install "$disk"
        else
            warn "Limine BIOS install needs the boot disk and the limine tool (disk: ${disk:-unknown}) — run: limine bios-install <disk>"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. rEFInd: refind-install finds the ESP, reinstalls the binary and drivers,
#    and creates the firmware boot entry. refind.conf and refind_linux.conf
#    were restored with the files. UNTESTED ON METAL.
# ---------------------------------------------------------------------------
if [ "$USES_REFIND" = true ]; then
    say "===== rEFInd ====="
    if command -v refind-install >/dev/null 2>&1; then
        run refind-install --yes || warn "refind-install reported errors — review above"
    else
        case "$ARCH" in x86_64) rb=refind_x64.efi ;; aarch64) rb=refind_aa64.efi ;; *) rb="" ;; esac
        if [ -n "$rb" ] && [ -f "/usr/share/refind/$rb" ]; then
            runsh "mkdir -p '$ESP/EFI/refind' && cp /usr/share/refind/$rb '$ESP/EFI/refind/$rb'"
            efi_boot_entry rEFInd "$ESP/EFI/refind/$rb"
        else
            warn "rEFInd detected but neither refind-install nor /usr/share/refind/${rb:-refind_<arch>.efi} is present — reinstall rEFInd before rebooting"
        fi
    fi
fi

if [ "$IS_PI_FW" = true ]; then
    say "===== Raspberry Pi firmware boot ($PI_FW_DIR) — nothing to install ====="
    # The firmware finds the root by PARTUUID in cmdline.txt; a restore onto a
    # new card has a new PARTUUID. Rewrite root= to the device / is on now.
    root_src=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
    root_puuid=$(lsblk -no PARTUUID "$root_src" 2>/dev/null | head -1)
    if [ -f "$PI_FW_DIR/cmdline.txt" ] && [ -n "$root_puuid" ]; then
        if grep -q "root=PARTUUID=$root_puuid" "$PI_FW_DIR/cmdline.txt"; then
            say "cmdline.txt already points root= at PARTUUID=$root_puuid"
        else
            runsh "sed -i 's#root=[^ ]*#root=PARTUUID=$root_puuid#' $PI_FW_DIR/cmdline.txt"
        fi
    else
        warn "could not rewrite root= in $PI_FW_DIR/cmdline.txt (file or PARTUUID missing) — check it by hand before rebooting"
    fi
    [ -f "$PI_FW_DIR/config.txt" ] && grep -q '^initramfs' "$PI_FW_DIR/config.txt" \
        && say "config.txt loads an initramfs; update-initramfs (rpi hooks) refreshed it above" \
        || say "config.txt loads no initramfs — kernel*.img boots the root directly"
elif [ "$USES_GRUB" = false ] && [ "$USES_SDBOOT" = false ] && [ "$USES_LIMINE" = false ] && [ "$USES_REFIND" = false ]; then
    warn "no bootloader detected (neither GRUB, systemd-boot, Limine, rEFInd nor Pi firmware) — boot install skipped"
fi

# ---------------------------------------------------------------------------
# 6. Secure Boot: everything regenerated above is unsigned. A host enrolled
#    with its own keys (sbctl) refuses them at the firmware until re-signed;
#    the sbctl pacman hook does not fire here. Sign what sbctl knows about.
# ---------------------------------------------------------------------------
if command -v sbctl >/dev/null 2>&1 && { [ -d /var/lib/sbctl ] || [ -d /usr/share/secureboot/keys ]; }; then
    say "===== Secure Boot (sbctl keys present) ====="
    run sbctl sign-all || warn "sbctl sign-all reported errors — sign the loader and kernels by hand before rebooting"
    if (( ! DRY )); then sbctl verify 2>&1 | sed 's/^/[rebuild-boot]   /' || true; fi
elif [ "$IS_EFI" = true ] && command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q enabled; then
    if ! compgen -G "${ESP:-/boot/efi}/EFI/*/shim*.efi" >/dev/null 2>&1; then
        warn "Secure Boot is enabled, no shim on the ESP and no sbctl keys — the firmware may refuse the (unsigned) loader/kernels rebuilt above; disable Secure Boot for the first boot or sign them"
    fi
fi

say "===== boot rebuild ${DRY:+(dry run) }complete ====="
