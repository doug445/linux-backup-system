#!/bin/bash
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
set -uo pipefail

DRY=          # empty, not 0: ${DRY:+...} treats the string "0" as set
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

# Kernel form: UKI if the ESP holds unified images, or kernel-install is set to uki.
IS_UKI=false
if [ -n "$ESP" ] && compgen -G "$ESP/EFI/Linux/*.efi" >/dev/null 2>&1; then IS_UKI=true; fi
grep -qs 'layout[[:space:]]*=[[:space:]]*uki' /etc/kernel/install.conf 2>/dev/null && IS_UKI=true

# Bootloader: GRUB if a grub.cfg exists; systemd-boot if its EFI binary is on the
# ESP (or bootctl reports installed) — checked independently, a host can have one
# or the other. loader/entries alone does NOT mean systemd-boot: Fedora GRUB uses
# BLS entries in /boot/loader/entries too.
USES_GRUB=false
{ [ -f /boot/grub2/grub.cfg ] || [ -f /boot/grub/grub.cfg ] \
  || command -v grub2-mkconfig >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1; } && USES_GRUB=true
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

say "distro=$DISTRO_FAMILY arch=$ARCH efi=$IS_EFI esp=${ESP:-none}"
say "kernels: ${KVERS[*]:-none}"
say "has_luks=$HAS_LUKS boot_on_luks=$BOOT_ON_LUKS uki=$IS_UKI grub=$USES_GRUB systemd-boot=$USES_SDBOOT limine=$USES_LIMINE refind=$USES_REFIND pi_firmware=$IS_PI_FW"
[ ${#KVERS[@]} -eq 0 ] && warn "no kernels found under /lib/modules — cannot rebuild"

# ---------------------------------------------------------------------------
# 1. Rebuild kernels: UKI or plain initramfs, distro-appropriate.
# ---------------------------------------------------------------------------
say "===== kernel / initramfs rebuild ====="
if [ "$IS_UKI" = true ]; then
    say "UKI layout — regenerating unified images"
    if command -v kernel-install >/dev/null 2>&1; then
        for kv in "${KVERS[@]}"; do
            img="/lib/modules/$kv/vmlinuz"; [ -f "$img" ] || img="/boot/vmlinuz-$kv"
            run kernel-install add "$kv" "$img"
        done
    elif command -v dracut >/dev/null 2>&1; then
        for kv in "${KVERS[@]}"; do run dracut --force --uefi --kver "$kv"; done
    else
        warn "no kernel-install or dracut — cannot regenerate UKI"
    fi
else
    if command -v update-initramfs >/dev/null 2>&1; then
        say "Debian family — update-initramfs -k all -c"
        run update-initramfs -k all -c
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
        if command -v grub2-install >/dev/null 2>&1; then
            run grub2-install --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck
        elif command -v grub-install >/dev/null 2>&1; then
            run grub-install --target="$gt" --efi-directory="$edir" --bootloader-id="$bid" --recheck
        fi
    else
        disk=$(lsblk -npo PKNAME "$boot_src" 2>/dev/null | head -1)
        if [ -n "$disk" ]; then
            command -v grub2-install >/dev/null 2>&1 && run grub2-install "$disk" --recheck \
                || { command -v grub-install >/dev/null 2>&1 && run grub-install "$disk" --recheck; }
        else
            warn "could not determine BIOS boot disk for grub-install"
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
        run bootctl ${ESP:+--esp-path="$ESP"} install
        # kernel-install writes Type#1 entries (or UKIs) per the install layout
        if command -v kernel-install >/dev/null 2>&1; then
            for kv in "${KVERS[@]}"; do
                img="/lib/modules/$kv/vmlinuz"; [ -f "$img" ] || img="/boot/vmlinuz-$kv"
                run kernel-install add "$kv" "$img"
            done
        else
            warn "bootctl present but kernel-install missing — loader entries may be incomplete"
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

say "===== boot rebuild ${DRY:+(dry run) }complete ====="
