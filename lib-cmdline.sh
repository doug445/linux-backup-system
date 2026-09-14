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
# lib-cmdline.sh — every place a kernel command line lives, and the block-device
# ids it carries.
#
# A restore onto a new disk gives every filesystem and LUKS container a new
# UUID. fstab and crypttab are rewritten for that by the restore scripts, but
# the kernel finds the root — and the initramfs finds the LUKS container — from
# the command line, and the command line lives in many places: BLS / systemd-
# boot entries, /etc/kernel/cmdline and cmdline.d, GRUB_CMDLINE_LINUX and its
# drop-ins, extlinux.conf, cmdline.txt, refind_linux.conf, limine.conf. A
# carrier left naming the old disk means a machine that stops in the initramfs
# after a restore the suite reported as complete.
#
# This library finds every carrier under a root, rewrites old ids to new ones
# in reference positions only (UUID=, PARTUUID=, rd.luks.uuid=, luks.uuid=,
# rd.luks.name=<uuid>=, cryptdevice=UUID=, resume=UUID=, search --fs-uuid) —
# never inside a mapper NAME, which crypttab keeps — and reports references
# that do not match the system's fstab/crypttab or do not exist on this box.
#
# The carrier list is carried over from the author's LinuxLocker
# (bin/lib-boot.sh, MIT), where it is exercised on the in-place-encryption
# side of the same problem. Sourced, never executed; touches nothing unless
# cl_rewrite_ids is called. Works unprivileged on synthetic trees (tests).

# ---------------------------------------------------------------------------
# cl_find_carriers ROOT — "kind<TAB>path" for every command-line carrier found
# under ROOT ("" or "/" for the live system).
# ---------------------------------------------------------------------------
cl_find_carriers() {
    local root="${1%/}" f d
    [ -f "$root/etc/kernel/cmdline" ] && printf 'cmdline\t%s\n' "$root/etc/kernel/cmdline"
    for f in "$root"/etc/cmdline.d/*.conf "$root"/etc/kernel/cmdline.d/*.conf; do
        [ -f "$f" ] && printf 'dropin\t%s\n' "$f"
    done
    for d in /boot /efi /boot/efi; do
        for f in "$root$d"/loader/entries/*.conf; do
            [ -f "$f" ] && printf 'bls\t%s\n' "$f"
        done
    done
    [ -f "$root/etc/default/grub" ] && printf 'grubdefault\t%s\n' "$root/etc/default/grub"
    for f in "$root"/etc/default/grub.d/*.cfg; do
        [ -f "$f" ] && printf 'grubd\t%s\n' "$f"
    done
    for f in "$root/boot/extlinux/extlinux.conf" "$root/extlinux/extlinux.conf"; do
        [ -f "$f" ] && { printf 'extlinux\t%s\n' "$f"; break; }
    done
    for f in "$root/boot/syslinux/syslinux.cfg" "$root/boot/syslinux.cfg"; do
        [ -f "$f" ] && { printf 'syslinux\t%s\n' "$f"; break; }
    done
    for f in "$root/boot/firmware/cmdline.txt" "$root/boot/cmdline.txt"; do
        [ -f "$f" ] && { printf 'cmdlinetxt\t%s\n' "$f"; break; }
    done
    # rEFInd reads refind_linux.conf from the directory the kernel is in.
    for f in "$root/boot/refind_linux.conf" \
             "$root"/boot/efi/EFI/*/refind_linux.conf \
             "$root"/efi/EFI/*/refind_linux.conf \
             "$root"/boot/EFI/*/refind_linux.conf; do
        [ -f "$f" ] && printf 'refind\t%s\n' "$f"
    done
    # Limine looks beside its EFI app, then /boot/limine/, /boot/, /limine/, /.
    for f in "$root"/boot/limine.conf "$root"/boot/limine.cfg \
             "$root"/boot/limine/limine.conf "$root"/boot/limine/limine.cfg \
             "$root"/boot/efi/EFI/BOOT/limine.conf "$root"/boot/efi/EFI/BOOT/limine.cfg \
             "$root"/efi/EFI/BOOT/limine.conf "$root"/efi/EFI/BOOT/limine.cfg \
             "$root"/boot/EFI/BOOT/limine.conf "$root"/boot/EFI/BOOT/limine.cfg \
             "$root"/boot/efi/limine.conf "$root"/efi/limine.conf \
             "$root"/boot/efi/limine/limine.conf "$root"/efi/limine/limine.conf; do
        [ -f "$f" ] && printf 'limine\t%s\n' "$f"
    done
    # CachyOS / limine-entry-tool regenerate limine.conf from this file.
    [ -f "$root/etc/default/limine" ] && printf 'limine-default\t%s\n' "$root/etc/default/limine"
    return 0
}

# The id reference forms this library understands, as one ERE prefix group.
# Group 1 is the prefix; the id follows. Case-insensitive at the call sites.
CL_REF_PREFIX='(UUID=|(rd\.)?luks\.uuid=(luks-)?|(rd\.)?luks\.name=|--fs-uuid[= ]+)'
CL_ID='[0-9a-fA-F]{4,}(-[0-9a-fA-F]{2,}){0,4}'

# ---------------------------------------------------------------------------
# cl_ids_in_file FILE — "kind<TAB>id" for every id referenced in the file:
# kind is partuuid (PARTUUID=), luks (rd.luks.uuid= / luks.uuid= / rd.luks.name=)
# or uuid (UUID=, --fs-uuid). Comment lines are skipped. Ids print lowercase.
# ---------------------------------------------------------------------------
cl_ids_in_file() {
    local f="$1" m
    [ -r "$f" ] || return 0
    grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
    | grep -oiE "(PART)?${CL_REF_PREFIX}${CL_ID}" 2>/dev/null \
    | while IFS= read -r m; do
        local low; low=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
        case "$low" in
            partuuid=*)               printf 'partuuid\t%s\n' "${low#partuuid=}" ;;
            rd.luks.uuid=luks-*)      printf 'luks\t%s\n' "${low#rd.luks.uuid=luks-}" ;;
            rd.luks.uuid=*)           printf 'luks\t%s\n' "${low#rd.luks.uuid=}" ;;
            luks.uuid=luks-*)         printf 'luks\t%s\n' "${low#luks.uuid=luks-}" ;;
            luks.uuid=*)              printf 'luks\t%s\n' "${low#luks.uuid=}" ;;
            rd.luks.name=*)           printf 'luks\t%s\n' "${low#rd.luks.name=}" ;;
            luks.name=*)              printf 'luks\t%s\n' "${low#luks.name=}" ;;
            uuid=*)                   printf 'uuid\t%s\n' "${low#uuid=}" ;;
            --fs-uuid*)               printf 'uuid\t%s\n' "${low##--fs-uuid[= ]}" ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# cl_rewrite_ids ROOT MAPFILE — rewrite every carrier under ROOT. MAPFILE holds
# "OLD NEW" pairs, one per line (any id kind; comments and blanks ignored).
# Only reference positions change; a mapper name such as /dev/mapper/luks-OLD
# or the name half of rd.luks.name=OLD=luks-OLD is left alone because crypttab
# keeps that name. Files are rewritten through `cat >` so the inode, mode,
# owner and SELinux label survive (matters on /etc and on a FAT ESP). Prints
# "kind<TAB>path" for each file changed. CL_DRY=1 prints what would change and
# writes nothing.
# ---------------------------------------------------------------------------
cl_rewrite_ids() { # cl_rewrite_ids ROOT MAPFILE
    local root="${1%/}" map="$2" kind path old new tmp expr
    [ -r "$map" ] || return 1
    expr=""
    while read -r old new _; do
        [ -n "$old" ] && [ -n "$new" ] || continue
        case "$old" in \#*) continue ;; esac
        [ "$old" != "$new" ] || continue
        # ERE, GNU sed, case-insensitive: prefix kept (\1), id replaced.
        expr="${expr}/^[[:space:]]*#/!s/(${CL_REF_PREFIX})${old}($|[^0-9a-fA-F-])/\\1${new}\\6/gI;"
    done < "$map"
    [ -n "$expr" ] || return 0
    while IFS=$'\t' read -r kind path; do
        [ -f "$path" ] || continue
        tmp="$(mktemp "$(dirname "$path")/.lbs-cl.XXXXXX")" || return 1
        sed -E "$expr" "$path" > "$tmp"
        if cmp -s "$path" "$tmp"; then rm -f "$tmp"; continue; fi
        if [ "${CL_DRY:-0}" = 1 ]; then
            printf '%s\t%s\n' "$kind" "$path"; rm -f "$tmp"; continue
        fi
        cat "$tmp" > "$path" && rm -f "$tmp"
        printf '%s\t%s\n' "$kind" "$path"
    done < <(cl_find_carriers "$root")
    return 0
}

# ---------------------------------------------------------------------------
# cl_expected_ids ROOT — the ids ROOT's own fstab and crypttab declare, one per
# line, lowercase: every UUID=/PARTUUID= in fstab's device column, every UUID=
# in crypttab's device column. The set a carrier must agree with.
# ---------------------------------------------------------------------------
cl_expected_ids() {
    local root="${1%/}"
    { [ -r "$root/etc/fstab" ] && awk '$1 !~ /^#/ && $1 ~ /^(PART)?UUID=/ {sub(/^(PART)?UUID=/, "", $1); print $1}' "$root/etc/fstab"
      [ -r "$root/etc/crypttab" ] && awk '$1 !~ /^#/ && $2 ~ /^UUID=/ {sub(/^UUID=/, "", $2); print $2}' "$root/etc/crypttab"
    } 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u
    return 0
}

# ---------------------------------------------------------------------------
# cl_carrier_mismatches ROOT — "kind<TAB>path<TAB>refkind<TAB>id" for every id a
# carrier references that fstab/crypttab under the same ROOT do not declare.
# Empty output means every command line agrees with the system's own tables.
# Used by backup-verify.sh on files extracted from an archive, and by the
# restore scripts before the reboot.
# ---------------------------------------------------------------------------
cl_carrier_mismatches() {
    local root="${1%/}" expected kind path rk id
    expected=" $(cl_expected_ids "$root" | tr '\n' ' ') "
    while IFS=$'\t' read -r kind path; do
        while IFS=$'\t' read -r rk id; do
            [ -n "$id" ] || continue
            case "$expected" in *" $id "*) ;; *) printf '%s\t%s\t%s\t%s\n' "$kind" "$path" "$rk" "$id" ;; esac
        done < <(cl_ids_in_file "$path")
    done < <(cl_find_carriers "$root")
    return 0
}

# ---------------------------------------------------------------------------
# fstab / crypttab device references, parsed BY FIELD. A device column is
# KIND=VALUE — UUID, PARTUUID, LABEL or PARTLABEL, optionally quoted — or
# anything else (a path such as /dev/mapper/x or /swapfile), reported as kind
# PATH. The restore scripts once matched "UUID=" as a substring: that also hit
# the tail of "PARTUUID=", and a filesystem UUID was written where a partition
# UUID belongs.
# ---------------------------------------------------------------------------
_CL_REF_AWK='function ref(d,  k) {
    gsub(/"/, "", d)
    if (match(d, /^(UUID|PARTUUID|LABEL|PARTLABEL)=/)) { k = substr(d, 1, RLENGTH - 1); return k "\t" substr(d, RLENGTH + 1) }
    return "PATH\t" d
}'

# cl_table_refs FILE COL — "KIND<TAB>VALUE" of device column COL (fstab 1,
# crypttab 2) on every active line.
cl_table_refs() {
    [ -r "$1" ] || return 0
    awk -v c="$2" "$_CL_REF_AWK"' $1 !~ /^#/ && NF >= c { print ref($c) }' "$1"
}

# cl_fstab_ref FSTAB MOUNT — "KIND<TAB>VALUE" of the entry mounted at MOUNT;
# MOUNT "swap" means the first swap entry. Empty when there is none.
cl_fstab_ref() {
    [ -r "$1" ] || return 0
    awk -v m="$2" "$_CL_REF_AWK"' $1 !~ /^#/ && NF >= 3 && ($2 == m || (m == "swap" && $3 == "swap")) { print ref($1); exit }' "$1"
}

# cl_crypttab_ref CRYPTTAB NAME — "KIND<TAB>VALUE" of mapping NAME's device.
cl_crypttab_ref() {
    [ -r "$1" ] || return 0
    awk -v n="$2" "$_CL_REF_AWK"' $1 == n && NF >= 2 { print ref($2); exit }' "$1"
}

# cl_table_set_ref FILE COL KIND OLD NEW — on every active line whose column
# COL is exactly KIND=OLD (quoted or not), write KIND=NEW. Every line, as btrfs
# subvolumes share one UUID. Nothing else changes: other columns, whitespace
# and comments are kept byte for byte, and the file through `cat >` keeps its
# inode, mode and label.
cl_table_set_ref() {
    local f="$1" tmp
    [ -f "$f" ] || return 1
    tmp="$(mktemp "$(dirname "$f")/.lbs-tab.XXXXXX")" || return 1
    awk -v c="$2" -v k="$3" -v o="$4" -v n="$5" '
        $1 !~ /^#/ && NF >= c {
            d = $c; gsub(/"/, "", d)
            if (d == k "=" o) {
                line = $0; out = ""; i = 0
                while (match(line, /[^ \t]+/)) {
                    i++
                    out = out substr(line, 1, RSTART - 1) (i == c ? k "=" n : substr(line, RSTART, RLENGTH))
                    line = substr(line, RSTART + RLENGTH)
                }
                $0 = out line
            }
        }
        { print }' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# cl_ref_exists KIND VALUE — does a device with this reference exist now?
# PATH is not checked (always true). CL_ID_EXISTS_CMD overrides it (tests).
cl_ref_exists() {
    local kind="$1" val="$2"
    [ "$kind" = PATH ] && return 0
    if [ -n "${CL_ID_EXISTS_CMD:-}" ]; then "$CL_ID_EXISTS_CMD" "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" "$val"; return; fi
    [ -n "$(blkid -t "$kind=$val" -o device 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# cl_id_exists KIND ID — does this id exist on the running system? Uses blkid;
# CL_ID_EXISTS_CMD overrides it (tests): a command given KIND ID.
# ---------------------------------------------------------------------------
cl_id_exists() {
    local kind="$1" id="$2"
    if [ -n "${CL_ID_EXISTS_CMD:-}" ]; then "$CL_ID_EXISTS_CMD" "$kind" "$id"; return; fi
    case "$kind" in
        partuuid) [ -n "$(blkid -t "PARTUUID=$id" -o device 2>/dev/null)" ] ;;
        *)        blkid -U "$id" >/dev/null 2>&1 ;;
    esac
}

# cl_stale_ids ROOT — "kind<TAB>path<TAB>refkind<TAB>id" for every referenced id
# that does not exist on this system. Run from a live system against the
# restored target, after the rewrite: anything printed will not boot.
cl_stale_ids() {
    local root="${1%/}" kind path rk id
    while IFS=$'\t' read -r kind path; do
        while IFS=$'\t' read -r rk id; do
            [ -n "$id" ] || continue
            cl_id_exists "$rk" "$id" || printf '%s\t%s\t%s\t%s\n' "$kind" "$path" "$rk" "$id"
        done < <(cl_ids_in_file "$path")
    done < <(cl_find_carriers "$root")
    return 0
}
