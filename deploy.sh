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
# deploy.sh — policy-aware installer for linux-backup-system.
#
# Usage:
#   sudo ./deploy.sh --dry-run     detect + print the plan, change nothing
#   sudo ./deploy.sh               install packages, scripts, config, units
#
# Auto-detects the distro family and package manager (Debian/Ubuntu/Mint,
# Fedora/Asahi, Arch/Manjaro, openSUSE), the root filesystem (btrfs -> snapper
# and send/receive replicas; anything else -> Timeshift), the backup drive and
# whether it is removable (ad-hoc: timers masked) or installed (scheduled),
# an existing borg setup (never overwritten), and the architecture.
#
# Environment overrides:
#   BACKUP_MOUNT=/path/to/backup  — force a specific backup mount path
#   FORCE_BORG=1                  — overwrite existing borg scripts even if present
#   SCHEDULE_MODE=adhoc|scheduled — override the drive-type detection
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DEPLOY]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# This suite drives Linux-only tooling (snapper, borg units, systemd timers,
# udev rules). Bail out early and clearly if we are not on Linux at all —
# otherwise the first symptom is a confusing "/etc/os-release not found".
if [ "$(uname -s)" != "Linux" ]; then
    err "This deploy script must run on the Linux machine being backed up."
    err "Detected host OS: $(uname -s) $(uname -m) — not Linux."
    err "Copy this directory to the target box and run it there, e.g.:"
    err "  rsync -a ./ user@asahi-host:~/linux-backup-system/"
    err "  ssh user@asahi-host 'cd ~/linux-backup-system && sudo ./deploy.sh'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared library: one package map and one installer for the deploy and for
# every script it deploys, so what deploy.sh installs is what the scripts check.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/backup-common.sh" || { echo "FATAL: backup-common.sh missing next to deploy.sh" >&2; exit 1; }
SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME=$(eval echo "~$SUDO_USER")

DRY=0
for _a in "$@"; do
    case "$_a" in
        --dry-run|-n) DRY=1 ;;
        -h|--help) sed -n '27,42p' "$0"; exit 0 ;;
        *) echo "unknown argument: $_a" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { err "Must run as root: sudo ./deploy.sh"; exit 1; }


###############################################################################
# Detect distro family
###############################################################################
detect_distro() {
    if [ ! -r /etc/os-release ]; then
        err "Cannot detect distro (/etc/os-release not found or unreadable)"
        err "Every systemd Linux ships this file; are you on the right machine?"
        exit 1
    fi

    . /etc/os-release

    # Match on ID first, then on each word of ID_LIKE, so derivatives resolve
    # to their parent family (Fedora Asahi Remix, Nobara, CachyOS, Zorin, ...).
    DISTRO_FAMILY=""
    for _id in "${ID:-}" ${ID_LIKE:-}; do
        case "$_id" in
            ubuntu|linuxmint|debian|pop)
                DISTRO_FAMILY="debian"
                ;;
            fedora|fedora-asahi-remix|rhel|centos|asahi)
                DISTRO_FAMILY="fedora"
                ;;
            manjaro|arch|endeavouros)
                DISTRO_FAMILY="arch"
                ;;
            opensuse*|suse|sles)
                DISTRO_FAMILY="suse"
                ;;
            *)
                continue
                ;;
        esac
        break
    done

    if [ -z "$DISTRO_FAMILY" ]; then
        err "Unknown distro: ID=${ID:-unknown} ID_LIKE=${ID_LIKE:-none}"
        err "Supported families: debian/ubuntu/mint, fedora/asahi, arch/manjaro, opensuse"
        err "To add yours, see README.md 'Hand-rolling a fix for your setup', then run"
        err "  sudo ./backup-diag.sh -o backup-diag.md"
        err "and attach that file to the issue — it is the report the fix is built from."
        exit 1
    fi

    DISTRO_NAME="${PRETTY_NAME:-${ID:-unknown}}"
}

###############################################################################
# Detect if ecryptfs is in use
###############################################################################
detect_ecryptfs() {
    HAS_ECRYPTFS=false
    if mount | grep -q ecryptfs 2>/dev/null; then
        HAS_ECRYPTFS=true
    elif [ -d "/home/.ecryptfs" ]; then
        HAS_ECRYPTFS=true
    fi
}

###############################################################################
# Detect filesystem type (btrfs vs ext4 etc)
###############################################################################
detect_filesystem() {
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
    HAS_BTRFS=false
    HAS_SNAPPER=false
    if [ "$ROOT_FSTYPE" = "btrfs" ]; then
        HAS_BTRFS=true
        if command -v snapper &>/dev/null && snapper list-configs &>/dev/null 2>&1; then
            HAS_SNAPPER=true
        fi
    fi
}

###############################################################################
# Dependencies — installed as soon as the box is detected, before anything
# that needs them (the drive set-up needs mkfs.btrfs and cryptsetup; the layers
# need borg, rsync, snapper or timeshift; the tray needs GTK + AppIndicator).
#
# Required tools are installed together and verified by `command -v` after
# the install; missing any of them aborts the deploy with the package list.
# Optional layers are installed one at a time so a package the distro does not
# carry (backintime on Arch is AUR-only) costs a warning, not the deploy.
# A dry run only reports what it would install.
###############################################################################
install_dependencies() {
    local required=(borg rsync cryptsetup btrfs mkfs.btrfs findmnt lsblk sfdisk wipefs blkid udevadm)
    local optional=(backintime)
    [ "$HAS_BTRFS" = true ]     && optional+=(snapper)
    [ "$HAS_BTRFS" = false ]    && optional+=(timeshift)
    [ "$HAS_ECRYPTFS" = true ]  && optional+=(mount.ecryptfs)

    export BX_DEP_DRYRUN="$DRY"
    log "Dependencies for $DISTRO_NAME ($DISTRO_FAMILY): required ${required[*]}"
    if ! bx_ensure_deps "${required[@]}" 2>&1 | sed 's/^/  /'; then :; fi
    if [ "${PIPESTATUS[0]}" -ne 0 ] && (( ! DRY )); then
        err "Required tools could not be installed — cannot continue."
        [ "$DISTRO_FAMILY" = arch ] && err "On Arch/Manjaro a stale package database is the usual cause: run  pacman -Syu  first, then re-run deploy.sh."
        exit 1
    fi

    local tool
    for tool in "${optional[@]}"; do
        if ! bx_ensure_deps "$tool" 2>&1 | sed 's/^/  /'; then :; fi
        if [ "${PIPESTATUS[0]}" -ne 0 ] && (( ! DRY )); then
            case "$tool" in
                backintime) warn "Back In Time is not installable here (Arch: AUR — yay -S backintime). The BIT layer is deployed but will not run until it is." ;;
                timeshift)  warn "Timeshift is not installable here (Arch: AUR — yay -S timeshift). Non-btrfs local snapshots are off until it is." ;;
                snapper)    warn "snapper could not be installed; btrfs replicas still run, snapper timeline snapshots are off." ;;
                *)          warn "$tool could not be installed." ;;
            esac
        fi
    done

    # snapper may have just arrived: re-detect, and say how to configure it.
    if [ "$HAS_BTRFS" = true ] && [ "$HAS_SNAPPER" = false ] && command -v snapper >/dev/null 2>&1; then
        if snapper list-configs >/dev/null 2>&1; then HAS_SNAPPER=true
        else warn "snapper is installed but has no config — create one with:  sudo snapper -c root create-config /"; fi
    fi

    install_tray_dependencies
}

# The tray is Python + GTK3 + AppIndicator3 via GObject introspection; those
# are not commands, so they are probed by importing them.
tray_deps_present() {
    python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("AppIndicator3", "0.1"); from gi.repository import Gtk, AppIndicator3' >/dev/null 2>&1
}
install_tray_dependencies() {
    if tray_deps_present; then log "  tray dependencies present (python3, GTK3, AppIndicator3)"; return; fi
    local pkgs
    case "$DISTRO_FAMILY" in
        debian) pkgs="python3 python3-gi gir1.2-gtk-3.0 gir1.2-appindicator3-0.1" ;;
        fedora) pkgs="python3 python3-gobject gtk3 libappindicator-gtk3" ;;
        arch)   pkgs="python python-gobject gtk3 libappindicator-gtk3" ;;
        suse)   pkgs="python3 python3-gobject python3-gobject-Gdk typelib-1_0-Gtk-3_0 typelib-1_0-AppIndicator3-0_1" ;;
        *)      warn "no tray packages known for family '$DISTRO_FAMILY' — the tray needs python3 + GTK3 + AppIndicator3 typelibs"; return ;;
    esac
    if (( DRY )); then log "  (dry-run) would install tray dependencies: $pkgs"; return; fi
    log "  installing tray dependencies: $pkgs"
    # shellcheck disable=SC2086
    if ! eval "$(bx_pkg_install_cmd) $pkgs" >/dev/null 2>&1 || ! tray_deps_present; then
        warn "tray dependencies did not install — the tray will not start until they do: $pkgs"
    fi
}

###############################################################################
# Detect backup mount path
###############################################################################
detect_backup_mount() {
    # Priority 1: Environment variable override
    if [ -n "${BACKUP_MOUNT:-}" ]; then
        log "Using BACKUP_MOUNT from environment: $BACKUP_MOUNT"
        return
    fi

    # Priority 2: an existing /etc/backup-system.conf. Mounted: use it. Not
    # mounted: this host already has a drive, it is just not connected — keep
    # the configured path so units and config are not rewritten to a default,
    # and only offer the set-up flow as an alternative.
    if [ -r /etc/backup-system.conf ]; then
        local existing_mount
        existing_mount=$(. /etc/backup-system.conf 2>/dev/null; echo "${BACKUP_MOUNT:-}")
        if [ -n "$existing_mount" ] && mountpoint -q "$existing_mount" 2>/dev/null && ! bx_mount_is_live "$existing_mount"; then
            # The drive was yanked while mounted: the mount answers "yes" but
            # its device is gone. Writes into it vanish, and treating it as
            # mounted would make the drive-type detection guess. Clear it.
            warn "$existing_mount is a dead mount — its drive was unplugged while mounted. Clearing it."
            if (( DRY )); then
                log "  (dry run: a real run lazily unmounts it and closes the LUKS mapping)"
            elif [ -x "$SCRIPT_DIR/borg-backup-drive-detach.sh" ]; then
                BX_CONFIG=/etc/backup-system.conf bash "$SCRIPT_DIR/borg-backup-drive-detach.sh" | sed 's/^/  /'
            fi
        fi
        if [ -n "$existing_mount" ] && bx_mount_is_live "$existing_mount"; then
            BACKUP_MOUNT="$existing_mount"
            log "Detected backup mount from /etc/backup-system.conf: $BACKUP_MOUNT"
            offer_blank_drive
            return
        fi
        if [ -n "$existing_mount" ]; then
            BACKUP_MOUNT="$existing_mount"
            WAITING_FOR_DRIVE=1
            warn "Configured backup drive is not connected (nothing mounted at $BACKUP_MOUNT)."
            local blanks; blanks=$(blank_hotplug_disks | tr '\n' ' ')
            [ -n "$blanks" ] && log "New blank drive connected: ${blanks% }"
            if (( DRY )) || [ ! -t 0 ]; then
                log "Continuing with the configured drive; connect it and re-run to finish (recovery scripts, first backup)."
                return
            fi
            echo ""
            echo "  1) Continue — install/update everything; connect the drive later  (default)"
            echo "  2) Set up a different drive now${blanks:+ (blank drive seen: ${blanks% })}"
            ask "Choice [1/2]: "
            if [ "$REPLY" = 2 ]; then WAITING_FOR_DRIVE=0; BACKUP_MOUNT=/mnt/backup; prepare_backup_drive "${blanks%% *}"; fi
            return
        fi
    fi

    # Priority 3: Look for mounted volumes labeled Borg-backup
    local label_dev
    label_dev=$(blkid -L "Borg-backup" 2>/dev/null || true)
    if [ -n "$label_dev" ]; then
        local label_mount
        label_mount=$(findmnt -n -o TARGET "$label_dev" 2>/dev/null || true)
        if [ -n "$label_mount" ]; then
            BACKUP_MOUNT="$label_mount"
            log "Detected backup mount from volume label: $BACKUP_MOUNT"
            return
        fi
        # Try the LUKS mapper device
        for mapper in /dev/mapper/luks-*; do
            [ -b "$mapper" ] || continue
            label_mount=$(findmnt -n -o TARGET "$mapper" 2>/dev/null || true)
            if [ -n "$label_mount" ]; then
                local check_label
                check_label=$(lsblk -n -o LABEL "$mapper" 2>/dev/null || true)
                if [ "$check_label" = "Borg-backup" ]; then
                    BACKUP_MOUNT="$label_mount"
                    log "Detected backup mount from LUKS label: $BACKUP_MOUNT"
                    return
                fi
            fi
        done
    fi

    # Priority 4: Check /mnt/backup
    if mountpoint -q /mnt/backup 2>/dev/null; then
        BACKUP_MOUNT="/mnt/backup"
        log "Using default backup mount: $BACKUP_MOUNT"
        return
    fi

    # Priority 5: no drive is mounted anywhere. Set one up now, or install
    # first and set it up later (the dry run and a non-interactive session
    # always take the second path).
    BACKUP_MOUNT="/mnt/backup"
    if (( DRY )); then
        log "No backup drive mounted — a real run would offer to set one up; planning with $BACKUP_MOUNT"
        WAITING_FOR_DRIVE=1
        return
    fi
    if [ ! -t 0 ]; then
        warn "No backup drive mounted and no terminal to ask on — installing now; re-run deploy.sh with the drive connected."
        WAITING_FOR_DRIVE=1
        return
    fi
    prepare_backup_drive
}

###############################################################################
# Backup drive set-up: connect, identify, (optionally) encrypt, format, mount.
#
# Every step here is interactive. The one destructive step — formatting — is
# gated behind the device path typed back and the word ERASE, and is refused
# outright on a disk that holds a mounted filesystem, active swap, or an fstab
# or crypttab entry. Encryption is never done here: a drive that should be
# encrypted is encrypted by the user with GNOME Disks or GParted first, or in
# place afterwards with LinuxLocker; this script only adopts the result.
###############################################################################
WAITING_FOR_DRIVE=0
DRIVE_SETUP_DONE=0
DRIVE_KEYFILE=""
FORMATTED_PART=""
PLAIN_DRIVE_ACCEPTED=0

# A plain backup drive holds a readable copy of every file on the machine.
# Say so, and go ahead only on an explicit acceptance.
accept_plain_risk() {
    echo ""
    echo -e "${YELLOW}An unencrypted backup drive is a readable copy of everything on this machine${NC}"
    echo "— every file, every password store, every key in /etc — for anyone who picks"
    echo "the drive up. The machine's own encryption does not extend to the backup."
    echo ""
    echo "You can encrypt it in place later, keeping the backups on it, with LinuxLocker:"
    echo "  https://github.com/doug445/LinuxLocker"
    echo ""
    ask "Type PLAIN to accept that risk and format without encryption, anything else to go back: "
    if [ "$REPLY" = "PLAIN" ]; then PLAIN_DRIVE_ACCEPTED=1; return 0; fi
    warn "Not accepted — nothing was written."
    return 1
}

ask() { # ask PROMPT -> REPLY (trimmed)
    echo -en "$1"
    read -r REPLY
    REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"; REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}

wait_for_drive() {
    WAITING_FOR_DRIVE=1
    BACKUP_MOUNT="/mnt/backup"
    echo ""
    log "Installing the backup system now without a drive."
    log "When the backup drive is connected, run:  sudo ./deploy.sh"
    log "It will find the drive (or walk you through setting it up) and finish the configuration."
    echo ""
}

# A blank disk: no partition table, no filesystem, nothing on it in use. The
# thing a user has just unboxed and plugged in.
disk_is_blank() {
    local dev="$1" pt fs
    pt=$(lsblk -dno PTTYPE "$dev" 2>/dev/null || true); fs=$(lsblk -dno FSTYPE "$dev" 2>/dev/null || true)
    [ -z "$pt" ] && [ -z "$fs" ] && [ "$(lsblk -rno NAME "$dev" 2>/dev/null | wc -l)" -le 1 ] && ! disk_in_use "$dev"
}

# Whole disks that are not in use: NAME SIZE TRAN HOTPLUG MODEL, one per line.
# Blank ones are marked; the first blank hotplug/USB disk is remembered in
# BLANK_DISK as the suggested default.
BLANK_DISK=""
list_candidate_disks() {
    local line NAME SIZE TRAN HOTPLUG MODEL TYPE busy mark
    BLANK_DISK=""
    while IFS= read -r line; do
        NAME=""; SIZE=""; TRAN=""; HOTPLUG=""; MODEL=""; TYPE=""
        eval "$line"   # lsblk -P emits NAME="..." pairs, quoted and escaped by lsblk itself
        [ "$TYPE" = disk ] || continue
        case "$NAME" in loop*|zram*|sr*|ram*|nbd*) continue ;;
        esac
        busy=""; mark=""
        if disk_in_use "/dev/$NAME"; then busy="   <- in use, not eligible"
        elif disk_is_blank "/dev/$NAME"; then
            mark="   <- blank, ready to set up"
            if [ -z "$BLANK_DISK" ] && { [ "$HOTPLUG" = 1 ] || [ "$TRAN" = usb ]; }; then BLANK_DISK="/dev/$NAME"; fi
        fi
        printf '  %-14s %8s  %-6s %-8s %s%s%s\n' "/dev/$NAME" "$SIZE" "${TRAN:--}" "$([ "$HOTPLUG" = 1 ] && echo hotplug || echo fixed)" "${MODEL:-}" "$busy" "$mark"
    done < <(lsblk -dPo NAME,SIZE,TRAN,HOTPLUG,MODEL,TYPE 2>/dev/null)
}

# Blank hotplug/USB disks present right now, one path per line (no prompt).
blank_hotplug_disks() {
    local line NAME TRAN HOTPLUG TYPE
    while IFS= read -r line; do
        NAME=""; TRAN=""; HOTPLUG=""; TYPE=""
        eval "$line"
        [ "$TYPE" = disk ] || continue
        case "$NAME" in loop*|zram*|sr*|ram*|nbd*) continue ;; esac
        { [ "$HOTPLUG" = 1 ] || [ "$TRAN" = usb ]; } || continue
        disk_is_blank "/dev/$NAME" && echo "/dev/$NAME"
    done < <(lsblk -dPo NAME,TRAN,HOTPLUG,TYPE 2>/dev/null)
}

# On a host that already has a drive configured: a blank drive that has just
# been connected is worth mentioning, and on a terminal worth offering.
offer_blank_drive() {
    local blanks
    blanks=$(blank_hotplug_disks | tr '\n' ' ')
    [ -n "$blanks" ] || return 0
    log "New blank drive connected: ${blanks% }"
    if (( DRY )) || [ ! -t 0 ]; then
        log "  (a real run on a terminal offers to set it up as the backup drive)"
        return 0
    fi
    echo ""
    echo "A blank drive is connected: ${blanks% }"
    echo "Set it up as THIS host's backup drive? The current configuration ($BACKUP_MOUNT)"
    echo "is replaced; the old config is kept beside the new one as .old-<date>."
    ask "Set up the blank drive now? [y/N]: "
    case "$REPLY" in y|Y|yes|YES)
        if mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
            log "unmounting the current drive at $BACKUP_MOUNT first"
            umount "$BACKUP_MOUNT" 2>/dev/null || { err "could not unmount $BACKUP_MOUNT (busy?) — leaving the current drive in place"; return 0; }
        fi
        WAITING_FOR_DRIVE=0
        BACKUP_MOUNT=/mnt/backup
        prepare_backup_drive "${blanks%% *}"
        ;;
    esac
}

# A disk is in use if anything on it (partition, LUKS mapping, LV) is mounted
# or swapped, or if any of its UUIDs appear in fstab or crypttab.
disk_in_use() {
    local dev="$1" u
    lsblk -rno MOUNTPOINTS "$dev" 2>/dev/null | grep -q . && return 0
    while read -r u; do
        [ -n "$u" ] || continue
        grep -qsF "$u" /etc/fstab /etc/crypttab && return 0
    done < <(lsblk -rno UUID,PARTUUID "$dev" 2>/dev/null | tr ' ' '\n')
    return 1
}

# The single typed confirmation before anything is written to a device.
confirm_erase() { # confirm_erase DEV DESCRIPTION
    local dev="$1"
    echo ""
    echo -e "${RED}This will ERASE $dev${NC} ($2). Everything on it will be gone."
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$dev" 2>/dev/null | sed 's/^/    /'
    ask "Type the device path ($dev) to continue, anything else to abort: "
    [ "$REPLY" = "$dev" ] || { warn "Aborted — nothing was written."; return 1; }
    ask "Type ERASE to confirm: "
    [ "$REPLY" = "ERASE" ] || { warn "Aborted — nothing was written."; return 1; }
    return 0
}

# Partition a whole disk (GPT, one partition) and make btrfs on it. btrfs is
# used for the backup drive on every host: the send/receive replicas of a btrfs
# root need a btrfs destination, and compression is free space on the others.
drive_still_there() { # drive_still_there DEV — false (with a message) if it was unplugged
    [ -b "$1" ] && return 0
    err "$1 is gone — drive disconnected? Nothing further was written."
    return 1
}

format_plain() { # format_plain DEV -> sets FORMATTED_PART
    local dev="$1"
    confirm_erase "$dev" "plain btrfs, label Borg-backup" || return 1
    drive_still_there "$dev" || return 1
    log "Wiping signatures and writing a GPT with one partition on $dev ..."
    wipefs -a "$dev" >/dev/null
    printf 'label: gpt\n,,L\n' | sfdisk --quiet --wipe always "$dev"
    udevadm settle 2>/dev/null || sleep 2
    drive_still_there "$dev" || return 1
    FORMATTED_PART=$(lsblk -rnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}' || true)
    [ -n "$FORMATTED_PART" ] && [ -b "$FORMATTED_PART" ] || { err "partition did not appear on $dev"; return 1; }
    log "mkfs.btrfs -L Borg-backup $FORMATTED_PART ..."
    mkfs.btrfs -f -q -L Borg-backup "$FORMATTED_PART" || { err "mkfs.btrfs failed"; return 1; }
    udevadm settle 2>/dev/null || sleep 1
    return 0
}

# Enroll a keyfile in the LUKS drive so the attach unit can unlock it on
# connect. Needs the drive's passphrase once. Never touches the existing slots
# and never lowers the AF hash — luksAddKey without --hash silently writes
# sha256 into the new slot on some cryptsetup builds.
enroll_keyfile() { # enroll_keyfile LUKS_DEV
    local ldev="$1" kdir=/etc/luks-keys kf=/etc/luks-keys/backup-drive.key
    echo ""
    echo "Unlock-on-connect: with a keyfile enrolled, plugging the drive in unlocks and"
    echo "mounts it (never starts a backup). The keyfile lives at $kf, mode 0400, root only."
    echo "Without it you will unlock the drive by hand before each backup."
    ask "Enroll a keyfile now? [Y/n]: "
    case "$REPLY" in n|N|no|NO) log "No keyfile enrolled — unlock by hand before backing up."; return 0 ;; esac
    mkdir -p "$kdir"; chmod 700 "$kdir"
    if [ ! -s "$kf" ]; then
        ( umask 077; head -c 64 /dev/urandom > "$kf" ) || { err "could not write $kf"; return 1; }
    else
        log "keyfile $kf already exists — enrolling it"
    fi
    chmod 400 "$kf"
    echo "cryptsetup will ask for the drive's passphrase:"
    if cryptsetup luksAddKey --pbkdf argon2id --hash sha512 "$ldev" "$kf"; then
        DRIVE_KEYFILE="$kf"
        log "keyfile enrolled in $ldev"
    else
        warn "luksAddKey failed — no keyfile enrolled; you can retry with:"
        warn "  sudo cryptsetup luksAddKey --pbkdf argon2id --hash sha512 $ldev $kf"
    fi
    return 0
}

mount_backup_fs() { # mount_backup_fs FS_DEV
    local fsdev="$1" fstype
    drive_still_there "$fsdev" || return 1
    fstype=$(lsblk -no FSTYPE "$fsdev" 2>/dev/null | head -1 || true)
    mkdir -p "$BACKUP_MOUNT"
    if [ "$fstype" = btrfs ]; then
        mount -o compress=zstd:1 "$fsdev" "$BACKUP_MOUNT" || { err "mount failed"; return 1; }
    else
        mount "$fsdev" "$BACKUP_MOUNT" || { err "mount failed"; return 1; }
    fi
    chown "$SUDO_USER:$SUDO_USER" "$BACKUP_MOUNT" 2>/dev/null || true
    log "mounted $fsdev ($fstype) at $BACKUP_MOUNT"
    DRIVE_SETUP_DONE=1
    return 0
}

prepare_backup_drive() { # prepare_backup_drive [PRESELECTED_DEV]
    local preselect="${1:-}"
    if [ -z "$preselect" ]; then
        echo ""
        echo "============================================"
        echo "  No backup drive is mounted"
        echo "============================================"
        echo ""
        echo "  1) I have a drive connected — set it up now"
        echo "  2) Wait — install the backup system now, set the drive up later"
        echo ""
        ask "Choice [1/2]: "
        case "$REPLY" in 1) ;; *) wait_for_drive; return ;; esac
    fi

    local dev="" luks_part="" fs_part="" mapper="" inner_fs="" luks_uuid="" suggested=""
    while :; do
        echo ""
        echo "Connect the backup drive now if it is not already. Whole disks seen:"
        echo ""
        list_candidate_disks
        suggested="${preselect:-$BLANK_DISK}"
        [ -n "$suggested" ] && [ -b "$suggested" ] || suggested=""
        echo ""
        echo "  (r) rescan    (w) wait — install now, set the drive up later"
        ask "Device to use for backups${suggested:+ [$suggested]}: "
        case "$REPLY" in
            r|R) continue ;;
            w|W) wait_for_drive; return ;;
            "")  [ -n "$suggested" ] && REPLY="$suggested" || { wait_for_drive; return; } ;;
        esac
        dev="$REPLY"
        [ -b "$dev" ] || { warn "$dev is not a block device"; continue; }
        if disk_in_use "$dev"; then
            warn "$dev holds a mounted filesystem, active swap, or an fstab/crypttab entry — refusing to touch it."
            continue
        fi
        break
    done

    luks_part=$(lsblk -rnpo NAME,FSTYPE "$dev" | awk '$2=="crypto_LUKS"{print $1; exit}' || true)
    fs_part=$(lsblk -rnpo NAME,FSTYPE,TYPE "$dev" | awk '$2!="" && $2!="crypto_LUKS" && $2!="swap"{print $1; exit}' || true)

    # ----- A) already LUKS-encrypted: unlock and adopt -----------------------
    if [ -n "$luks_part" ]; then
        luks_uuid=$(cryptsetup luksUUID "$luks_part" 2>/dev/null || true)
        mapper="luks-$luks_uuid"
        log "$luks_part is LUKS-encrypted (UUID ${luks_uuid:-?})."
        if [ ! -e "/dev/mapper/$mapper" ]; then
            echo "cryptsetup will ask for its passphrase:"
            cryptsetup open "$luks_part" "$mapper" || { err "could not unlock $luks_part"; wait_for_drive; return; }
        fi
        udevadm settle 2>/dev/null || sleep 1
        inner_fs=$(lsblk -no FSTYPE "/dev/mapper/$mapper" 2>/dev/null | head -1 || true)
        if [ -n "$inner_fs" ]; then
            echo ""
            echo "Inside it: a $inner_fs filesystem (label: $(lsblk -no LABEL "/dev/mapper/$mapper" 2>/dev/null | head -1))."
            echo "  1) Use it as-is — keep whatever is on it, add backups alongside"
            echo "  2) Reformat the inside as btrfs (label Borg-backup) — erases it"
            ask "Choice [1/2]: "
            if [ "$REPLY" = 2 ]; then
                confirm_erase "/dev/mapper/$mapper" "inside of the LUKS container, btrfs" || { wait_for_drive; return; }
                drive_still_there "$luks_part" || { wait_for_drive; return; }
                mkfs.btrfs -f -q -L Borg-backup "/dev/mapper/$mapper" || { err "mkfs.btrfs failed"; wait_for_drive; return; }
                udevadm settle 2>/dev/null || sleep 1
            fi
        else
            echo "The container is empty inside."
            confirm_erase "/dev/mapper/$mapper" "inside of the LUKS container, btrfs" || { wait_for_drive; return; }
            mkfs.btrfs -f -q -L Borg-backup "/dev/mapper/$mapper" || { err "mkfs.btrfs failed"; wait_for_drive; return; }
            udevadm settle 2>/dev/null || sleep 1
        fi
        enroll_keyfile "$luks_part"
        mount_backup_fs "/dev/mapper/$mapper" || { wait_for_drive; return; }
        return
    fi

    # ----- B) plain filesystem present: adopt or reformat ---------------------
    if [ -n "$fs_part" ]; then
        echo ""
        echo "$fs_part already has a $(lsblk -no FSTYPE "$fs_part" | head -1) filesystem (label: $(lsblk -no LABEL "$fs_part" | head -1))."
        echo "  1) Use it as-is — keep whatever is on it, add backups alongside"
        echo "  2) Erase and format the whole drive for backups (plain btrfs)"
        echo "  3) Encrypt it first — I will do that myself, then re-run deploy.sh"
        echo "  4) Wait — install now, set the drive up later"
        ask "Choice [1-4]: "
        case "$REPLY" in
            1) accept_plain_risk || { explain_encrypt_first "$dev"; wait_for_drive; return; }
               mount_backup_fs "$fs_part" || wait_for_drive; return ;;
            2) ;;
            3) explain_encrypt_first "$dev"; wait_for_drive; return ;;
            *) wait_for_drive; return ;;
        esac
    else
        # ----- C) empty drive --------------------------------------------------
        echo ""
        echo "$dev has no filesystem."
        echo "  1) Encrypt it first — I will do that myself, then re-run deploy.sh   (recommended)"
        echo "  2) Format it plain now (btrfs, label Borg-backup); encrypt in place later if wanted"
        echo "  3) Wait — install now, set the drive up later"
        ask "Choice [1-3]: "
        case "$REPLY" in
            1) explain_encrypt_first "$dev"; wait_for_drive; return ;;
            2) ;;
            *) wait_for_drive; return ;;
        esac
    fi

    accept_plain_risk || { explain_encrypt_first "$dev"; wait_for_drive; return; }
    format_plain "$dev" || { wait_for_drive; return; }
    echo ""
    echo "Formatted, unencrypted. To encrypt this drive in place later, keeping the backups on it:"
    echo "  LinuxLocker — https://github.com/doug445/LinuxLocker  (in-place LUKS2, data partitions included)"
    echo "then re-run deploy.sh so the config picks up the LUKS UUID and unlock-on-connect."
    mount_backup_fs "$FORMATTED_PART" || wait_for_drive
}

explain_encrypt_first() {
    local dev="$1"
    echo ""
    echo "Encrypt $dev yourself, then come back — deploy.sh will find the LUKS drive,"
    echo "ask for its passphrase once, offer to enroll a keyfile for unlock-on-connect,"
    echo "and adopt it. Any of these does the job:"
    echo ""
    echo "  GNOME Disks   Format Disk (GPT) -> + partition -> type: Internal disk (ext4/btrfs),"
    echo "                tick 'Password protect volume (LUKS)', filesystem btrfs, label Borg-backup"
    echo "  GParted       Device > Create Partition Table (gpt); Partition > New, btrfs, tick 'Encrypt with LUKS'"
    echo "  Command line  sudo cryptsetup luksFormat --type luks2 --pbkdf argon2id ${dev}1"
    echo "                sudo cryptsetup open ${dev}1 backup && sudo mkfs.btrfs -L Borg-backup /dev/mapper/backup"
    echo ""
    echo "Prefer to keep a plain drive for now? Format it here instead, and encrypt it in place"
    echo "later with LinuxLocker: https://github.com/doug445/LinuxLocker"
    echo ""
    echo "When the drive is ready and connected:  sudo ./deploy.sh"
}

###############################################################################
# Check if borg is already deployed and working
###############################################################################
detect_existing_borg() {
    BORG_ALREADY_DEPLOYED=false
    if [ -f /usr/local/sbin/borg-backup.sh ] && \
       [ -f /etc/systemd/system/borg-backup.service ] && \
       [ -f /etc/systemd/system/borg-backup.timer ] && \
       systemctl is-active borg-backup.timer &>/dev/null; then
        BORG_ALREADY_DEPLOYED=true
    fi
}

###############################################################################
# Convert mount path to systemd unit name (for RequiresMountsFor)
###############################################################################
systemd_escape_path() {
    # systemd-escape handles this properly
    systemd-escape --path "$1" 2>/dev/null || echo "$1" | sed 's|^/||;s|/|-|g'
}

###############################################################################
# Generate BIT config for this system
###############################################################################
generate_bit_config() {
    local user_to_exclude="$SUDO_USER"
    local exclude_idx=19
    local exclude_size=18  # base excludes (1-18)
    local cfg=/root/.config/backintime/config

    # An existing config is the user's — it may carry hand-tuned exclusions or
    # rsync options — and is never regenerated over, except when a new drive
    # was set up this run (the destination path changed); then the old one is
    # kept beside it.
    if [ -f "$cfg" ] && [ "$DRIVE_SETUP_DONE" != 1 ]; then
        log "  $cfg exists — left as-is"
        return
    fi
    if [ -f "$cfg" ]; then
        /usr/bin/cp -a "$cfg" "$cfg.old-$(date +%Y%m%d-%H%M%S)"
        log "  new drive this run — previous BIT config kept as $cfg.old-*"
    fi

    # SELinux hosts: rsync must not carry security.selinux xattrs into the
    # snapshot tree, or every file restores with the label it had at backup
    # time and the target relabels on first boot (or refuses to).
    local rsync_en=false rsync_val=""
    if [ -d /sys/fs/selinux ]; then
        rsync_en=true; rsync_val="--filter='-x security.selinux'"
    fi

    # Start with base config
    cat > "$cfg" << EOF
config.version=6
profile1.name=Full System Backup

# Snapshot destination
profile1.snapshots.path=$BACKUP_MOUNT/backintime
profile1.snapshots.mode=local

# Sources: / and /boot
profile1.snapshots.include.size=2
profile1.snapshots.include.1.type=0
profile1.snapshots.include.1.value=/
profile1.snapshots.include.2.type=0
profile1.snapshots.include.2.value=/boot

# Base exclusions
profile1.snapshots.exclude.1.type=0
profile1.snapshots.exclude.1.value=/dev/*
profile1.snapshots.exclude.2.type=0
profile1.snapshots.exclude.2.value=/proc/*
profile1.snapshots.exclude.3.type=0
profile1.snapshots.exclude.3.value=/sys/*
profile1.snapshots.exclude.4.type=0
profile1.snapshots.exclude.4.value=/tmp/*
profile1.snapshots.exclude.5.type=0
profile1.snapshots.exclude.5.value=/run/*
profile1.snapshots.exclude.6.type=0
profile1.snapshots.exclude.6.value=/mnt/*
profile1.snapshots.exclude.7.type=0
profile1.snapshots.exclude.7.value=/media/*
profile1.snapshots.exclude.8.type=0
profile1.snapshots.exclude.8.value=/snap/*
profile1.snapshots.exclude.9.type=0
profile1.snapshots.exclude.9.value=/swapfile
profile1.snapshots.exclude.10.type=0
profile1.snapshots.exclude.10.value=/var/tmp/*
profile1.snapshots.exclude.11.type=0
profile1.snapshots.exclude.11.value=/var/cache/*
profile1.snapshots.exclude.12.type=0
profile1.snapshots.exclude.12.value=/var/log/journal/*
profile1.snapshots.exclude.13.type=0
profile1.snapshots.exclude.13.value=/home/*/.cache/*
profile1.snapshots.exclude.14.type=0
profile1.snapshots.exclude.14.value=/home/*/.local/share/Trash/*
profile1.snapshots.exclude.15.type=0
profile1.snapshots.exclude.15.value=/home/*/.npm/_cacache/*
profile1.snapshots.exclude.16.type=0
profile1.snapshots.exclude.16.value=/home/*/.cargo/registry/*
profile1.snapshots.exclude.17.type=0
profile1.snapshots.exclude.17.value=/root/.cache/*
profile1.snapshots.exclude.18.type=0
profile1.snapshots.exclude.18.value=/root/.local/share/Trash/*
EOF

    # Add ecryptfs-specific excludes if applicable
    if [ "$HAS_ECRYPTFS" = true ] && [ "$user_to_exclude" != "root" ]; then
        cat >> /root/.config/backintime/config << ECRYPT
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/home/${user_to_exclude}
ECRYPT
        ((exclude_idx++))
        cat >> /root/.config/backintime/config << ECRYPT
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/home/${user_to_exclude}/**
ECRYPT
        exclude_size=$exclude_idx
    fi

    # Add btrfs-specific excludes
    if [ "$HAS_BTRFS" = true ]; then
        # Exclude btrfs snapshot directories (snapper and manual)
        cat >> /root/.config/backintime/config << BTRFS
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/.snapshots/*
BTRFS
        ((exclude_idx++))
        cat >> /root/.config/backintime/config << BTRFS
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/home/.snapshots/*
BTRFS
        ((exclude_idx++))
        cat >> /root/.config/backintime/config << BTRFS
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/.backup-snapshots/*
BTRFS
        ((exclude_idx++))
        cat >> /root/.config/backintime/config << BTRFS
profile1.snapshots.exclude.${exclude_idx}.type=0
profile1.snapshots.exclude.${exclude_idx}.value=/var/lib/flatpak/*
BTRFS
        exclude_size=$exclude_idx
    fi

    # Write the exclude size and remaining config
    cat >> /root/.config/backintime/config << EOF
profile1.snapshots.exclude.size=${exclude_size}

# Scheduling disabled (systemd timer handles it)
profile1.schedule.mode=0
profile1.schedule.time=0
profile1.schedule.day=1

# Retention: 10 daily, 2 weekly, 2 monthly
profile1.snapshots.remove_old_snapshots.enabled=true
profile1.snapshots.remove_old_snapshots.unit=80
profile1.snapshots.remove_old_snapshots.value=10
profile1.snapshots.keep_named_snapshots=true
profile1.snapshots.smart_remove=true
profile1.snapshots.smart_remove.keep_all=2
profile1.snapshots.smart_remove.keep_one_per_day=10
profile1.snapshots.smart_remove.keep_one_per_week=2
profile1.snapshots.smart_remove.keep_one_per_month=2
profile1.snapshots.smart_remove.run_remote_in_background=false

# rsync options
profile1.snapshots.rsync_options.enabled=$rsync_en
profile1.snapshots.rsync_options.value=$rsync_val
profile1.snapshots.one_file_system=false

# Preservation
profile1.snapshots.preserve_acl=true
profile1.snapshots.preserve_xattr=true
profile1.snapshots.copy_unsafe_links=false
profile1.snapshots.copy_links=false

# Logging and behavior
profile1.snapshots.log_level=1
profile1.snapshots.no_on_battery=false
profile1.snapshots.notify.enabled=true
profile1.snapshots.bwlimit.enabled=false
profile1.snapshots.continue_on_errors=true
profile1.snapshots.use_checksum=false
profile1.snapshots.backup_on_restore.enabled=true
profile1.snapshots.full_rsync=false
profile1.snapshots.take_snapshot_regardless_of_changes=false
EOF
}

###############################################################################
# Deploy systemd units with correct paths
###############################################################################
deploy_systemd_units() {
    local mount_unit
    mount_unit=$(systemd_escape_path "$BACKUP_MOUNT")

    # BIT service — always deploy
    sed -e "s|RequiresMountsFor=.*|RequiresMountsFor=$BACKUP_MOUNT|" \
        -e "s|After=.*mount|After=${mount_unit}.mount|" \
        -e "/^\[Unit\]/a ConditionPathIsMountPoint=$BACKUP_MOUNT" \
        "$SCRIPT_DIR/backintime-backup.service" > /etc/systemd/system/backintime-backup.service

    install -m 644 "$SCRIPT_DIR/backintime-backup.timer" /etc/systemd/system/backintime-backup.timer

    # Borg units — only if not already deployed (or FORCE_BORG=1)
    if [ "$BORG_ALREADY_DEPLOYED" = false ] || [ "${FORCE_BORG:-0}" = "1" ]; then
        sed -e "s|RequiresMountsFor=.*|RequiresMountsFor=$BACKUP_MOUNT|" \
            -e "s|After=.*mount|After=${mount_unit}.mount|" \
            -e "/^\[Unit\]/a ConditionPathIsMountPoint=$BACKUP_MOUNT" \
            "$SCRIPT_DIR/borg-backup.service" > /etc/systemd/system/borg-backup.service

        install -m 644 "$SCRIPT_DIR/borg-backup.timer" /etc/systemd/system/borg-backup.timer
        log "  Borg units deployed."
    else
        log "  Borg units: existing setup preserved (use FORCE_BORG=1 to overwrite)."
    fi

    systemctl daemon-reload
}

###############################################################################
# Add shell function to rc file if not present
###############################################################################
add_shell_function() {
    local rc_file="$1"
    local func_name="$2"
    local func_body="$3"

    if [ -f "$rc_file" ] && grep -q "^${func_name}()" "$rc_file" 2>/dev/null; then
        log "  $func_name() already in $(basename "$rc_file") — skipping"
        return
    fi

    [ -f "$rc_file" ] || return

    cat >> "$rc_file" << EOF

# $func_name — added by backup-system deploy
$func_body
EOF
    log "  Added $func_name() to $(basename "$rc_file")"
}

###############################################################################
# Detect schedule mode: external/removable/USB drive -> ad-hoc (no timers),
# an internal installed drive -> schedulable. Override with SCHEDULE_MODE env.
###############################################################################
detect_schedule_mode() {
    if [ -n "${SCHEDULE_MODE:-}" ]; then
        log "Schedule mode from environment: $SCHEDULE_MODE"; return
    fi
    local src base rm hp tran
    # Every pipeline here ends in "|| true": under set -e -o pipefail a failing
    # findmnt/lsblk inside $(...) would otherwise kill the script silently.
    src=$(findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null | sed "s/\[.*//" || true)
    if [ -z "$src" ] || ! bx_mount_is_live "$BACKUP_MOUNT"; then
        # No live drive mounted: nothing may run on its own until one is set up.
        SCHEDULE_MODE=adhoc
        log "Schedule mode (no live backup drive at $BACKUP_MOUNT): $SCHEDULE_MODE"
        return
    fi
    if [[ "$src" == /dev/mapper/* ]]; then
        src=$(cryptsetup status "${src#/dev/mapper/}" 2>/dev/null | awk "/device:/{print \$2}" || true)
    fi
    base=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)
    [ -n "$base" ] || base=$(basename "${src:-none}")
    rm=$(cat "/sys/block/$base/removable" 2>/dev/null || echo 0)
    hp=$(lsblk -no HOTPLUG "/dev/$base" 2>/dev/null | head -1 || true)
    tran=$(lsblk -no TRAN "/dev/$base" 2>/dev/null | head -1 || true)
    # "scheduled" enables timers that run backups unattended, so it needs
    # positive evidence of a fixed internal disk: a resolvable disk that is
    # neither removable nor hotplug nor on USB. Anything unresolved is ad-hoc.
    if [ ! -d "/sys/block/$base" ]; then
        SCHEDULE_MODE=adhoc
        warn "Could not resolve the backup drive's disk (source ${src:-?}) — assuming ad-hoc; set SCHEDULE_MODE=scheduled yourself if it is an installed drive."
        return
    fi
    if [ "$rm" = 1 ] || [ "$hp" = 1 ] || [ "$tran" = usb ] || [ -z "$tran" ]; then
        SCHEDULE_MODE=adhoc
    else
        SCHEDULE_MODE=scheduled
    fi
    log "Schedule mode (drive $base: removable=$rm hotplug=$hp tran=${tran:-?}): $SCHEDULE_MODE"
}

###############################################################################
# Generate /etc/backup-system.conf from detection (never clobber an existing one)
###############################################################################
write_system_conf() {
    local fs_uuid dev luks_uuid=""
    fs_uuid=$(findmnt -n -o UUID --target "$BACKUP_MOUNT" 2>/dev/null || true)
    dev=$(findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null | sed "s/\[.*//" || true)
    if [[ "$dev" == /dev/mapper/* ]]; then
        local backing; backing=$(cryptsetup status "${dev#/dev/mapper/}" 2>/dev/null | awk "/device:/{print \$2}" || true)
        luks_uuid=$(cryptsetup luksUUID "$backing" 2>/dev/null || true)
    fi
    if [ -f /etc/backup-system.conf ] && [ "$DRIVE_SETUP_DONE" = 1 ]; then
        local old
        old="/etc/backup-system.conf.old-$(date +%Y%m%d-%H%M%S)"
        mv /etc/backup-system.conf "$old"
        log "  a new drive was set up this run — previous config kept at $old"
    elif [ -f /etc/backup-system.conf ]; then
        log "  /etc/backup-system.conf exists — left as-is (detected fs_uuid=$fs_uuid luks_uuid=${luks_uuid:-none})"
        return
    fi
    local keyfile="$DRIVE_KEYFILE"
    if [ -z "$keyfile" ] && [ -n "$luks_uuid" ] && [ -r /etc/luks-keys/backup-drive.key ]; then
        keyfile=/etc/luks-keys/backup-drive.key
    fi
    cat > /etc/backup-system.conf <<EOF
# /etc/backup-system.conf — generated by deploy.sh on $(date +%F). Safe to edit.
BACKUP_MOUNT="$BACKUP_MOUNT"
BACKUP_FS_UUID="$fs_uuid"
BACKUP_LUKS_UUID="${luks_uuid:-}"
BACKUP_KEYFILE="$keyfile"
BACKUP_MOUNT_OPTS="$([ "$(findmnt -no FSTYPE --target "$BACKUP_MOUNT" 2>/dev/null)" = btrfs ] && echo compress=zstd:1)"
SCHEDULE_MODE="$SCHEDULE_MODE"
KEEP=10
MIN_KEEP=3
MIN_FREE_PCT=10
MIN_FREE_GIB=0
EOF
    log "  wrote /etc/backup-system.conf (mount=$BACKUP_MOUNT fs_uuid=$fs_uuid schedule=$SCHEDULE_MODE)"
}

###############################################################################
# Timeshift (non-btrfs roots): make it a pure engine for timeshift-backup.sh.
# Timeshift's own scheduler is time-based (hourly/daily/weekly/monthly/boot
# with per-tag counts): left on, it would create snapshots behind the wrapper's
# back and prune them by AGE — the one thing fleet retention must never do —
# onto whatever device its config last remembered. Turn every built-in schedule
# off, drop its cron entries, force rsync mode and pin it to the backup drive.
# The wrapper's snapshots are tagged "ondemand", which Timeshift never
# auto-prunes. Idempotent; the exclude list and everything else are untouched.
###############################################################################
configure_timeshift() {
    local cfg=/etc/timeshift/timeshift.json fs_uuid dev luks_uuid="" out
    fs_uuid=$(findmnt -n -o UUID --target "$BACKUP_MOUNT" 2>/dev/null || true)
    dev=$(findmnt -no SOURCE --target "$BACKUP_MOUNT" 2>/dev/null | sed "s/\[.*//")
    if [[ "$dev" == /dev/mapper/* ]]; then
        local backing; backing=$(cryptsetup status "${dev#/dev/mapper/}" 2>/dev/null | awk "/device:/{print \$2}")
        luks_uuid=$(cryptsetup luksUUID "$backing" 2>/dev/null || true)
    fi
    mkdir -p /etc/timeshift
    out=$(python3 - "$cfg" "$fs_uuid" "$luks_uuid" <<'PY'
import json, os, sys
path, fs_uuid, luks_uuid = sys.argv[1:4]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except ValueError:
        cfg = {}
# Timeshift stores every scalar as a string ("true"/"false"), so match that.
want = {"btrfs_mode": "false", "do_first_run": "false", "stop_cron_emails": "true"}
for k in ("schedule_boot", "schedule_hourly", "schedule_daily", "schedule_weekly", "schedule_monthly"):
    want[k] = "false"
if fs_uuid:
    want["backup_device_uuid"] = fs_uuid
    want["parent_device_uuid"] = luks_uuid
changed = sorted(k for k, v in want.items() if cfg.get(k) != v)
if changed:
    cfg.update(want)
    cfg.setdefault("exclude", [])
    cfg.setdefault("exclude-apps", [])
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    print("set " + " ".join(changed))
else:
    print("already configured")
PY
    ) || { warn "could not update $cfg — Timeshift's own schedule may still be active"; return; }
    # Timeshift (re)writes these from its schedule flags; with every flag off it
    # removes them itself on its next run, but do not wait for that.
    rm -f /etc/cron.d/timeshift-hourly /etc/cron.d/timeshift-boot
    log "  Timeshift: built-in schedule off, rsync mode, pinned to ${fs_uuid:-$dev} ($out)"
}

###############################################################################
# Deploy the verify/header units, the drive-attach unit and the udev rule.
###############################################################################
deploy_extra_units() {
    local u
    for u in backup-verify luks-header-backup; do
        [ -f "$SCRIPT_DIR/$u.service" ] || continue
        sed -e "s#/mnt/backup#$BACKUP_MOUNT#g" \
            -e "s#^Environment=BORG_REPO=.*#Environment=BORG_REPO=$BACKUP_MOUNT/borg-backup#" \
            "$SCRIPT_DIR/$u.service" > "/etc/systemd/system/$u.service"
        [ -f "$SCRIPT_DIR/$u.timer" ] && install -m 644 "$SCRIPT_DIR/$u.timer" "/etc/systemd/system/$u.timer"
    done
    if [ "$HAS_BTRFS" = false ]; then
        for u in timeshift-backup.service timeshift-backup.timer; do
            [ -f "$SCRIPT_DIR/$u" ] || continue
            sed "s#/mnt/backup#$BACKUP_MOUNT#g" "$SCRIPT_DIR/$u" > "/etc/systemd/system/$u"
        done
    fi
    for u in borg-backup-drive-attach.service borg-backup-drive-detach.service; do
        [ -f "$SCRIPT_DIR/$u" ] && install -m 644 "$SCRIPT_DIR/$u" /etc/systemd/system/
    done
    # The udev rule is a template: it fires on the backup drive's LUKS UUID from
    # /etc/backup-system.conf. No UUID known (plain drive, or unconfigured) means
    # no rule — never a rule pinned to some other machine's disk.
    local dev_uuid
    dev_uuid=$(. /etc/backup-system.conf 2>/dev/null; echo "${BACKUP_LUKS_UUID:-${BACKUP_FS_UUID:-}}")
    if [ -f "$SCRIPT_DIR/99-borg-backup.rules" ] && [ -n "$dev_uuid" ]; then
        sed "s#@BACKUP_DEV_UUID@#$dev_uuid#g" "$SCRIPT_DIR/99-borg-backup.rules" \
            > /etc/udev/rules.d/99-borg-backup.rules
        chmod 644 /etc/udev/rules.d/99-borg-backup.rules
    else
        log "  no drive UUID in /etc/backup-system.conf — udev attach/detach rule not installed"
    fi
    systemctl daemon-reload
    udevadm control --reload 2>/dev/null || true
}

###############################################################################
# Main
###############################################################################
echo ""
echo "============================================"
echo "  3-Layer Backup System Deployment"
echo "  Snapper + Borg + Back in Time"
echo "============================================"
echo ""

detect_distro
detect_ecryptfs
detect_filesystem
install_dependencies
detect_backup_mount
detect_existing_borg
detect_schedule_mode

log "Suite:     linux-backup-system ${BX_VERSION:-?}"
log "Distro:    $DISTRO_NAME ($DISTRO_FAMILY)"
log "User:      $SUDO_USER"
log "Home:      $USER_HOME"
log "Arch:      $(uname -m)"
log "Root FS:   $ROOT_FSTYPE"
log "btrfs:     $HAS_BTRFS"
log "snapper:   $HAS_SNAPPER"
log "ecryptfs:  $HAS_ECRYPTFS"
log "Backup:    $BACKUP_MOUNT"
log "Borg exists: $BORG_ALREADY_DEPLOYED"
log "Schedule:  $SCHEDULE_MODE"
echo ""

if (( DRY )); then
    echo -e "${CYAN}[DRY RUN]${NC} planned actions (nothing will change):"
    log "  packages: see the [deps] lines above — installed and verified before anything else"
    log "  scripts -> /usr/local/sbin: borg-backup.sh backintime-backup.sh backup-verify.sh"
    log "             luks-header-backup.sh timeshift-backup.sh backup-diag.sh backup-common.sh lib-cmdline.sh"
    log "             borg-backup-drive-attach.sh borg-backup-drive-detach.sh + restore scripts"
    log "  config  -> /etc/backup-system.conf (mount=$BACKUP_MOUNT, schedule=$SCHEDULE_MODE)$([ -f /etc/backup-system.conf ] && echo ' [exists, kept]')"
    [ "$HAS_BTRFS" = false ] && log "  timeshift -> /etc/timeshift/timeshift.json: built-in schedule OFF (fleet retention is never time-based), rsync mode, pinned to $BACKUP_MOUNT; cron.d/timeshift-* removed"
    log "  units   -> borg/BIT/backup-verify/luks-header$([ "$HAS_BTRFS" = false ] && echo '/timeshift') + drive-attach/detach + udev rule"
    if [ "$SCHEDULE_MODE" = scheduled ]; then
        log "  timers  -> borg + BIT$([ "$HAS_BTRFS" = false ] && echo ' + Timeshift') ENABLED (internal drive)"
    else
        log "  timers  -> borg + BIT$([ "$HAS_BTRFS" = false ] && echo ' + Timeshift') MASKED (ad-hoc); drive-attach enabled for unlock-on-connect"
    fi
    log "  verify + luks-header timers ENABLED regardless (read-only maintenance)"
    [ "$HAS_SNAPPER" = true ] && log "  snapper-replicate.sh (if present) patched idempotently"
    echo ""
    echo -e "${GREEN}Dry run complete — nothing was changed.${NC}"
    exit 0
fi

# Step 1: packages were installed by install_dependencies() straight after
# detection (the drive set-up needed them); nothing left to do here.
log "Packages verified."

# Step 2: Deploy scripts
log "Deploying scripts..."

# BIT scripts — always deploy
cp "$SCRIPT_DIR/backintime-backup.sh" /usr/local/sbin/backintime-backup.sh
chmod +x /usr/local/sbin/backintime-backup.sh

# Restore scripts — always deploy (bug-fixed versions)
for script in backintime-restore.sh borg-restore.sh restore.sh; do
    cp "$SCRIPT_DIR/$script" "/usr/local/sbin/$script"
    chmod +x "/usr/local/sbin/$script"
done

# Borg backup script — only if not already deployed
if [ "$BORG_ALREADY_DEPLOYED" = false ] || [ "${FORCE_BORG:-0}" = "1" ]; then
    cp "$SCRIPT_DIR/borg-backup.sh" /usr/local/sbin/borg-backup.sh
    chmod +x /usr/local/sbin/borg-backup.sh
    log "  Borg script deployed."
else
    log "  Borg script: existing /usr/local/sbin/borg-backup.sh preserved."
fi
# Universal library + verifier + header backup + drive-attach + snapper patch
cp "$SCRIPT_DIR/backup-common.sh" /usr/local/sbin/backup-common.sh
chmod 644 /usr/local/sbin/backup-common.sh
[ -f "$SCRIPT_DIR/lib-cmdline.sh" ] && install -m 644 "$SCRIPT_DIR/lib-cmdline.sh" /usr/local/sbin/lib-cmdline.sh
for s in backup-verify.sh luks-header-backup.sh; do
    [ -f "$SCRIPT_DIR/$s" ] && { cp "$SCRIPT_DIR/$s" "/usr/local/sbin/$s"; chmod 700 "/usr/local/sbin/$s"; }
done
# restore helper must sit next to the restore scripts (they find it via their own dir)
[ -f "$SCRIPT_DIR/restore-rebuild-boot.sh" ] && install -m 755 "$SCRIPT_DIR/restore-rebuild-boot.sh" /usr/local/sbin/restore-rebuild-boot.sh
[ -f "$SCRIPT_DIR/timeshift-backup.sh" ] && install -m 755 "$SCRIPT_DIR/timeshift-backup.sh" /usr/local/sbin/timeshift-backup.sh
[ -f "$SCRIPT_DIR/backup-diag.sh" ] && install -m 755 "$SCRIPT_DIR/backup-diag.sh" /usr/local/sbin/backup-diag.sh
for s in borg-backup-drive-attach.sh borg-backup-drive-detach.sh; do
    [ -f "$SCRIPT_DIR/$s" ] && install -m 755 "$SCRIPT_DIR/$s" "/usr/local/sbin/$s"
done
write_system_conf
[ "$HAS_BTRFS" = false ] && configure_timeshift
if [ -f /usr/local/sbin/snapper-replicate.sh ] && [ -f "$SCRIPT_DIR/patch-snapper-replicate.py" ]; then
    python3 "$SCRIPT_DIR/patch-snapper-replicate.py" || warn "snapper-replicate patch needs manual attention"
fi
log "Scripts deployed."

# Step 3: Deploy backup tray
log "Deploying backup tray indicator..."
cp "$SCRIPT_DIR/backup-tray.py" /usr/local/bin/backup-tray
chmod +x /usr/local/bin/backup-tray
mkdir -p "$USER_HOME/.config/autostart"
cp "$SCRIPT_DIR/backup-tray.desktop" "$USER_HOME/.config/autostart/"
chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.config/autostart/backup-tray.desktop"
log "Tray indicator deployed."

# Step 4: Generate BIT config
log "Generating Back in Time config..."
mkdir -p /root/.config/backintime
generate_bit_config
if [ "$HAS_ECRYPTFS" = true ]; then
    log "  ecryptfs detected — excluding /home/$SUDO_USER (encrypted view)"
fi
if [ "$HAS_BTRFS" = true ]; then
    log "  btrfs detected — excluding /.snapshots, /home/.snapshots, /.backup-snapshots"
fi
log "  Config written to /root/.config/backintime/config"

# Step 5: Create snapshot directory
mkdir -p "$BACKUP_MOUNT/backintime" 2>/dev/null || true
log "Snapshot directory: $BACKUP_MOUNT/backintime"

# Step 6: Deploy systemd units
log "Deploying systemd timers..."
deploy_systemd_units
deploy_extra_units
TS_TIMER=""
[ "$HAS_BTRFS" = false ] && TS_TIMER="timeshift-backup.timer"
if [ "$SCHEDULE_MODE" = scheduled ]; then
    # shellcheck disable=SC2086
    systemctl unmask backintime-backup.timer borg-backup.timer $TS_TIMER 2>/dev/null || true
    # unmask removes a previous ad-hoc mask symlink; put the real timers back.
    for _t in backintime-backup.timer borg-backup.timer $TS_TIMER; do
        install -m 644 "$SCRIPT_DIR/$_t" "/etc/systemd/system/$_t"
    done
    systemctl daemon-reload
    # shellcheck disable=SC2086
    systemctl enable --now backintime-backup.timer borg-backup.timer $TS_TIMER 2>/dev/null || true
    log "  scheduled mode: borg + BIT${TS_TIMER:+ + Timeshift} timers enabled (internal drive)"
else
    # ad-hoc: backups run by hand / on drive-attach; never on a timer
    # shellcheck disable=SC2086
    systemctl disable --now backintime-backup.timer borg-backup.timer $TS_TIMER 2>/dev/null || true
    # A mask is a /dev/null symlink at /etc/systemd/system/<unit>; a real unit
    # file there defeats it ("File exists"). Remove the timers first — the
    # services stay, the tray and the shell functions run the scripts directly.
    rm -f /etc/systemd/system/backintime-backup.timer /etc/systemd/system/borg-backup.timer \
          ${TS_TIMER:+/etc/systemd/system/$TS_TIMER}
    systemctl daemon-reload
    # shellcheck disable=SC2086
    systemctl mask backintime-backup.timer borg-backup.timer $TS_TIMER 2>/dev/null || true
    systemctl enable --now borg-backup-drive-attach.service 2>/dev/null || true
    log "  ad-hoc mode: borg + BIT${TS_TIMER:+ + Timeshift} timers masked; drive-attach enabled for unlock-on-connect"
fi
# verify + header are read-only maintenance; safe to schedule on every box
systemctl enable --now backup-verify.timer luks-header-backup.timer 2>/dev/null || true
log "  Borg timer:  $(systemctl is-enabled borg-backup.timer 2>/dev/null || true) / $(systemctl is-active borg-backup.timer 2>/dev/null || true)"
log "  BIT timer:   $(systemctl is-enabled backintime-backup.timer 2>/dev/null || true) / $(systemctl is-active backintime-backup.timer 2>/dev/null || true)"
if [ "$HAS_SNAPPER" = true ]; then
    log "  Snapper:     $(systemctl is-active snapper-timeline.timer 2>/dev/null || echo 'check manually')"
fi

# Step 7: Deploy recovery scripts to backup drive
if bx_mount_is_live "$BACKUP_MOUNT"; then
    log "Deploying recovery scripts to backup drive..."
    mkdir -p "$BACKUP_MOUNT/recovery-scripts"
    for f in borg-backup.sh borg-restore.sh backintime-backup.sh backintime-restore.sh restore.sh restore-rebuild-boot.sh backup-common.sh lib-cmdline.sh backup-verify.sh luks-header-backup.sh timeshift-backup.sh backup-diag.sh README.md; do
        cp "$SCRIPT_DIR/$f" "$BACKUP_MOUNT/recovery-scripts/"
    done
    chmod +x "$BACKUP_MOUNT/recovery-scripts/"*.sh
    log "  Recovery scripts at $BACKUP_MOUNT/recovery-scripts/"
else
    warn "$BACKUP_MOUNT not mounted — skipping recovery scripts to backup drive"
fi

# Step 8: Add shell functions
log "Adding shell functions..."

BITBACK_FUNC="bitback() {
    if ! mountpoint -q $BACKUP_MOUNT 2>/dev/null; then echo \"ERROR: $BACKUP_MOUNT not mounted\"; return 1; fi
    case \"\${1:-}\" in
        list) pkexec backintime --config /root/.config/backintime/config show ;;
        log)  sudo tail -50 /var/log/backintime-backup.log ;;
        *)    sudo /usr/local/sbin/backintime-backup.sh ;;
    esac
}"

TIMEBACK_FUNC="timeback() {
    local BORG_REPO=\"$BACKUP_MOUNT/borg-backup\"
    if ! mountpoint -q $BACKUP_MOUNT 2>/dev/null; then echo \"ERROR: $BACKUP_MOUNT not mounted\"; return 1; fi
    case \"\${1:-}\" in
        list) sudo borg list \"\$BORG_REPO\" ;; info) sudo borg info \"\$BORG_REPO\" ;;
        log) sudo tail -50 /var/log/borg-backup.log ;; *) sudo /usr/local/sbin/borg-backup.sh ;;
    esac
}"

SNAPBACK_FUNC='snapback() {
    case "${1:-}" in
        list)     sudo snapper -c root list; echo; sudo snapper -c home list ;;
        create)   sudo snapper -c root create -d "manual"; sudo snapper -c home create -d "manual"; echo "Snapshots created." ;;
        rollback) sudo snapper -c root undochange "${2:?Usage: snapback rollback <snapshot#>}..0" ;;
        diff)     sudo snapper -c root diff "${2:?Usage: snapback diff <snapshot#>}..0" ;;
        *)        echo "Usage: snapback [list|create|rollback N|diff N]" ;;
    esac
}'

for rc in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
    add_shell_function "$rc" "timeback" "$TIMEBACK_FUNC"
    add_shell_function "$rc" "bitback" "$BITBACK_FUNC"
    if [ "$HAS_SNAPPER" = true ]; then
        add_shell_function "$rc" "snapback" "$SNAPBACK_FUNC"
    fi
done

# Step 9: Verify BIT config
log "Verifying BIT config..."
backintime --config /root/.config/backintime/config check-config 2>&1 | grep -iE 'done|fine|error' || true

# Step 10: Summary
echo ""
echo "============================================"
echo -e "  ${GREEN}DEPLOYMENT COMPLETE${NC}"
echo -e "  $DISTRO_NAME ($(uname -m))"
echo "============================================"
echo ""
echo "Backup layers:"
if [ "$HAS_SNAPPER" = true ]; then
    echo -e "  ${GREEN}✓${NC} Snapper (btrfs)  — hourly timeline snapshots (local)"
fi
echo -e "  ${GREEN}✓${NC} Borg             — daily deduplicated archives (external)"
echo -e "  ${GREEN}✓${NC} Back in Time      — daily rsync+hardlink snapshots (external)"
echo ""
echo "Next steps:"
if [ "$WAITING_FOR_DRIVE" = 1 ]; then
    echo -e "  ${YELLOW}0. No backup drive yet.${NC} Connect one and run  sudo ./deploy.sh  again —"
    echo "     it will find the drive (or walk you through formatting it) and finish the config."
fi
if [ "$PLAIN_DRIVE_ACCEPTED" = 1 ]; then
    echo -e "  ${YELLOW}Reminder:${NC} the backup drive is unencrypted. Protect the backups on it when you"
    echo "     can: LinuxLocker encrypts it in place — https://github.com/doug445/LinuxLocker"
fi
echo "  1. Verify backup drive: mountpoint $BACKUP_MOUNT"
if [ "$BORG_ALREADY_DEPLOYED" = false ]; then
    echo "  2. Init Borg repo (if new): sudo borg init --encryption=none $BACKUP_MOUNT/borg-backup"
    echo "  3. First Borg backup:       sudo /usr/local/sbin/borg-backup.sh"
fi
echo "  4. First BIT backup:        sudo /usr/local/sbin/backintime-backup.sh"
echo "  5. Log out/in for tray icon (or run: /usr/local/bin/backup-tray &)"
echo ""
echo "Shell commands:"
echo "  timeback [list|info|log]     — Borg operations"
echo "  bitback [list|log]           — Back in Time operations"
echo "  sudo backup-diag.sh -o backup-diag.md — troubleshooting report for a bug/setup report"
if [ "$HAS_SNAPPER" = true ]; then
    echo "  snapback [list|create|rollback N|diff N] — Snapper operations"
fi
echo ""

if [ "$HAS_ECRYPTFS" = true ]; then
    echo "  NOTE: ecryptfs detected. /home/$SUDO_USER is excluded from BIT."
    echo "  Encrypted blobs at /home/.ecryptfs/$SUDO_USER are backed up instead."
    echo ""
fi

if [ "$DISTRO_FAMILY" = "arch" ]; then
    echo "  NOTE: On Arch/Manjaro, install backintime from AUR if not done:"
    echo "    yay -S backintime"
    echo ""
fi
