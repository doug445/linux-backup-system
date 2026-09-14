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
# tests/cmdline-fixture-test.sh — lib-cmdline.sh against a synthetic restored
# system: every carrier kind, the restore-time id rewrite, mapper names left
# alone, consistency against fstab/crypttab, stale-id detection with a stubbed
# blkid, dry mode, idempotence, CRLF and uppercase ids. No disk, no root.
# Run by sh (dash), zsh or `bash`-less invocation: re-exec under bash — the
# shebang is ignored when a script is handed to another shell by name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib-cmdline.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $*"; }
bad() { fail=$((fail+1)); echo "  FAIL  $*"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/root"

OR=11111111-aaaa-bbbb-cccc-000000000001   # old root fs
NR=22222222-aaaa-bbbb-cccc-000000000001   # new root fs
OL=33333333-dddd-eeee-ffff-000000000002   # old LUKS container
NL=44444444-dddd-eeee-ffff-000000000002   # new LUKS container
OS=55555555-1111-2222-3333-000000000003   # old swap
NS=66666666-1111-2222-3333-000000000003   # new swap
OP=a1b2c3d4-02                            # old Pi PARTUUID
NP=e5f6a7b8-02                            # new Pi PARTUUID
OB=77777777-abcd-abcd-abcd-000000000004   # old /boot fs (kept: not in map)

mk() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; }
mk "$R/etc/fstab"              "UUID=$NR / btrfs subvol=root 0 0\nUUID=$OB /boot ext4 defaults 0 0\n/dev/mapper/luks-$OL none swap sw 0 0\n#UUID=$OR old\n"
mk "$R/etc/crypttab"           "luks-$OL UUID=$NL none discard\n"
mk "$R/etc/kernel/cmdline"     "root=UUID=$OR rootflags=subvol=root rd.luks.uuid=luks-$OL rd.luks.name=$OL=luks-$OL resume=UUID=$OS quiet\n"
mk "$R/etc/cmdline.d/10-x.conf" "rd.luks.uuid=$OL\n"
mk "$R/boot/loader/entries/a.conf" "title A\nlinux /vmlinuz\noptions root=UUID=$OR rd.luks.uuid=luks-$OL rhgb\n"
mk "$R/efi/loader/entries/b.conf" "options root=UUID=${OR^^} luks.uuid=$OL\n"
mk "$R/etc/default/grub"       "GRUB_CMDLINE_LINUX=\"rd.luks.uuid=luks-$OL resume=UUID=$OS\"\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n# search --fs-uuid $OR\n"
mk "$R/etc/default/grub.d/99.cfg" "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$OL:cryptroot\"\n"
mk "$R/boot/extlinux/extlinux.conf" "LABEL x\n  APPEND root=UUID=$OR rw\n"
mk "$R/boot/efi/EFI/refind/refind_linux.conf" "\"Boot\" \"root=UUID=$OR ro\"\n"
mk "$R/boot/limine.conf"       "cmdline: root=UUID=$OR rd.luks.uuid=$OL\n"
mk "$R/etc/default/limine"     "KERNEL_CMDLINE[default]=\"root=UUID=$OR\"\n"
mk "$R/boot/syslinux/syslinux.cfg" "APPEND root=UUID=$OR\n"
mk "$R/home/x/notes.txt"       "root=UUID=$OR must not be touched\n"

echo "== carriers found"
kinds=$(cl_find_carriers "$R" | cut -f1 | sort | tr '\n' ' ')
for k in cmdline dropin bls grubdefault grubd extlinux syslinux refind limine limine-default; do
    case " $kinds " in *" $k "*) ok "finds $k" ;; *) bad "missing carrier kind $k (have: $kinds)" ;; esac
done
expect "two BLS entries (boot + efi)" 2 "$(cl_find_carriers "$R" | grep -c '^bls')"
expect "notes.txt is not a carrier" 0 "$(cl_find_carriers "$R" | grep -c notes)"

echo "== ids referenced"
expect "kernel/cmdline ids" "uuid $OR
luks $OL
luks $OL
uuid $OS" "$(cl_ids_in_file "$R/etc/kernel/cmdline" | tr '\t' ' ')"
expect "uppercase id lowercased" "uuid $OR
luks $OL" "$(cl_ids_in_file "$R/efi/loader/entries/b.conf" | tr '\t' ' ')"
expect "cryptdevice=UUID= is a uuid ref" "uuid $OL" "$(cl_ids_in_file "$R/etc/default/grub.d/99.cfg" | tr '\t' ' ')"

echo "== expected ids and mismatches BEFORE the rewrite"
expect "fstab+crypttab ids (sorted)" "$NR
$NL
$OB" "$(cl_expected_ids "$R")"
mm=$(cl_carrier_mismatches "$R"); n=$(grep -c . <<<"$mm")
[ "$n" -ge 12 ] && ok "mismatches reported before rewrite ($n)" || bad "expected many mismatches, got $n"
grep -q "$OR" <<<"$mm" && ok "old root id is a mismatch" || bad "old root id not flagged"

echo "== dry rewrite changes nothing"
printf '%s %s\n%s %s\n%s %s\n%s %s\n' "$OR" "$NR" "$OL" "$NL" "$OS" "$NS" "$OP" "$NP" > "$T/map"
before=$(find "$R" -type f -exec cat {} + | md5sum)
n=$(CL_DRY=1 cl_rewrite_ids "$R" "$T/map" | wc -l)
after=$(find "$R" -type f -exec cat {} + | md5sum)
[ "$before" = "$after" ] && ok "dry run wrote nothing" || bad "dry run modified files"
expect "dry run lists the 11 files it would change" 11 "$n"

echo "== real rewrite"
ino_before=$(stat -c %i "$R/etc/kernel/cmdline")
changed=$(cl_rewrite_ids "$R" "$T/map")
expect "inode preserved" "$ino_before" "$(stat -c %i "$R/etc/kernel/cmdline")"
expect "kernel/cmdline" "root=UUID=$NR rootflags=subvol=root rd.luks.uuid=luks-$NL rd.luks.name=$NL=luks-$OL resume=UUID=$NS quiet" "$(cat "$R/etc/kernel/cmdline")"
expect "drop-in" "rd.luks.uuid=$NL" "$(cat "$R/etc/cmdline.d/10-x.conf")"
expect "BLS entry" "options root=UUID=$NR rd.luks.uuid=luks-$NL rhgb" "$(sed -n 3p "$R/boot/loader/entries/a.conf")"
expect "uppercase id rewritten" "options root=UUID=$NR luks.uuid=$NL" "$(cat "$R/efi/loader/entries/b.conf")"
expect "GRUB default" "GRUB_CMDLINE_LINUX=\"rd.luks.uuid=luks-$NL resume=UUID=$NS\"" "$(sed -n 1p "$R/etc/default/grub")"
expect "GRUB comment line untouched" "# search --fs-uuid $OR" "$(sed -n 3p "$R/etc/default/grub")"
expect "GRUB drop-in cryptdevice" "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$NL:cryptroot\"" "$(cat "$R/etc/default/grub.d/99.cfg")"
expect "extlinux" "  APPEND root=UUID=$NR rw" "$(sed -n 2p "$R/boot/extlinux/extlinux.conf")"
expect "rEFInd" "\"Boot\" \"root=UUID=$NR ro\"" "$(cat "$R/boot/efi/EFI/refind/refind_linux.conf")"
expect "limine" "cmdline: root=UUID=$NR rd.luks.uuid=$NL" "$(cat "$R/boot/limine.conf")"
expect "limine default" "KERNEL_CMDLINE[default]=\"root=UUID=$NR\"" "$(cat "$R/etc/default/limine")"
expect "syslinux" "APPEND root=UUID=$NR" "$(cat "$R/boot/syslinux/syslinux.cfg")"
expect "mapper NAME in fstab untouched" "/dev/mapper/luks-$OL none swap sw 0 0" "$(sed -n 3p "$R/etc/fstab")"
expect "crypttab NAME untouched" "luks-$OL UUID=$NL none discard" "$(cat "$R/etc/crypttab")"
expect "non-carrier untouched" "root=UUID=$OR must not be touched" "$(cat "$R/home/x/notes.txt")"
expect "/boot id not in map untouched" "UUID=$OB /boot ext4 defaults 0 0" "$(sed -n 2p "$R/etc/fstab")"
expect "reported 11 changed files" 11 "$(grep -c . <<<"$changed")"

echo "== idempotent"
expect "second rewrite changes nothing" "" "$(cl_rewrite_ids "$R" "$T/map")"

echo "== mismatches AFTER the rewrite"
left=$(cl_carrier_mismatches "$R")
# Only the swap UUID remains: the synthetic fstab swaps by mapper name, so
# resume=UUID=<swap> is legitimately absent from fstab/crypttab.
expect "only resume= swap id is undeclared" "$NS
$NS" "$(cut -f4 <<<"$left")"

echo "== Raspberry Pi tree: PARTUUID root, CRLF cmdline.txt"
P="$T/pi"
mk "$P/etc/fstab"              "PARTUUID=$NP / ext4 defaults 0 1\nPARTUUID=${NP%-02}-01 /boot/firmware vfat defaults 0 2\n"
mk "$P/boot/firmware/cmdline.txt" "console=tty1 root=PARTUUID=$OP rootfstype=ext4 rootwait\r\n"
expect "cmdline.txt is the carrier" "cmdlinetxt" "$(cl_find_carriers "$P" | cut -f1)"
expect "PARTUUID ref kind" "partuuid $OP" "$(cl_ids_in_file "$P/boot/firmware/cmdline.txt" | tr '\t' ' ' | tr -d '\r')"
expect "old PARTUUID is a mismatch" "partuuid $OP" "$(cl_carrier_mismatches "$P" | cut -f3,4 | tr '\t' ' ' | tr -d '\r')"
cl_rewrite_ids "$P" "$T/map" >/dev/null
expect "PARTUUID rewritten, CRLF kept" "console=tty1 root=PARTUUID=$NP rootfstype=ext4 rootwait"$'\r' "$(cat "$P/boot/firmware/cmdline.txt")"
expect "Pi tree consistent after rewrite" "" "$(cl_carrier_mismatches "$P")"

echo "== stale ids with a stubbed blkid"
stub() { case "$2" in "$NR"|"$NL"|"$NS"|"$OB"|"$NP") return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2034  # read by cl_id_exists in the sourced library
CL_ID_EXISTS_CMD=stub
expect "nothing stale after rewrite" "" "$(cl_stale_ids "$R")"
printf 'root=UUID=%s\n' "$OR" > "$R/etc/kernel/cmdline"
expect "stale old root id detected" "cmdline $R/etc/kernel/cmdline uuid $OR" "$(cl_stale_ids "$R" | tr '\t' ' ')"
unset CL_ID_EXISTS_CMD

echo "== fstab / crypttab references parsed by field (PARTUUID is not a UUID)"
F="$T/tab"; mkdir -p "$F/etc"
FP=abcd1234-01                                 # a PARTUUID whose tail must not read as a UUID
printf '%b' "PARTUUID=$FP /boot/efi vfat umask=0077 0 2\nUUID=$OR  /      btrfs subvol=root 0 0\nUUID=$OR\t/home\tbtrfs subvol=home 0 0\n# UUID=$OR /old ext4 x 0 0\nLABEL=\"EOSBOOT\" /boot vfat defaults 0 2\n/swapfile none swap defaults 0 0\n/dev/mapper/vg-data /data ext4 defaults 0 2\n" > "$F/etc/fstab"
printf '%b' "cryptroot PARTUUID=$FP none luks\ncrypthome UUID=$OL /etc/k luks\n" > "$F/etc/crypttab"
expect "fstab: PARTUUID entry is kind PARTUUID" "PARTUUID $FP" "$(cl_fstab_ref "$F/etc/fstab" /boot/efi | tr '\t' ' ')"
expect "fstab: root UUID" "UUID $OR" "$(cl_fstab_ref "$F/etc/fstab" / | tr '\t' ' ')"
expect "fstab: quoted LABEL" "LABEL EOSBOOT" "$(cl_fstab_ref "$F/etc/fstab" /boot | tr '\t' ' ')"
expect "fstab: swapfile is a PATH" "PATH /swapfile" "$(cl_fstab_ref "$F/etc/fstab" swap | tr '\t' ' ')"
expect "fstab: commented entry ignored" "" "$(cl_fstab_ref "$F/etc/fstab" /old)"
expect "fstab: no substring match on a mount prefix" "" "$(cl_fstab_ref "$F/etc/fstab" /bo)"
expect "crypttab: PARTUUID device" "PARTUUID $FP" "$(cl_crypttab_ref "$F/etc/crypttab" cryptroot | tr '\t' ' ')"
expect "crypttab: UUID device" "UUID $OL" "$(cl_crypttab_ref "$F/etc/crypttab" crypthome | tr '\t' ' ')"
expect "fstab refs: every active line" "PARTUUID UUID UUID LABEL PATH PATH" "$(cl_table_refs "$F/etc/fstab" 1 | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
cp "$F/etc/fstab" "$F/fstab.orig"
cl_table_set_ref "$F/etc/fstab" 1 UUID "$OR" "$NR"
expect "set_ref: both btrfs lines rewritten, whitespace kept" "UUID=$NR  /      btrfs subvol=root 0 0|UUID=$NR"$'\t'"/home"$'\t'"btrfs subvol=home 0 0" "$(sed -n '2p;3p' "$F/etc/fstab" | paste -sd'|')"
expect "set_ref: comment line untouched" "# UUID=$OR /old ext4 x 0 0" "$(sed -n 4p "$F/etc/fstab")"
expect "set_ref: PARTUUID line untouched" "PARTUUID=$FP /boot/efi vfat umask=0077 0 2" "$(sed -n 1p "$F/etc/fstab")"
cl_table_set_ref "$F/etc/fstab" 1 UUID "${FP}" "$NR"
expect "set_ref: UUID=<partuuid value> does not match PARTUUID=" "PARTUUID=$FP /boot/efi vfat umask=0077 0 2" "$(sed -n 1p "$F/etc/fstab")"
cl_table_set_ref "$F/etc/fstab" 1 PARTUUID "$FP" "$NP"
expect "set_ref: PARTUUID rewritten as a PARTUUID" "PARTUUID=$NP /boot/efi vfat umask=0077 0 2" "$(sed -n 1p "$F/etc/fstab")"
cl_table_set_ref "$F/etc/fstab" 1 LABEL EOSBOOT 'A&B'
expect "set_ref: quoted LABEL, & in the new value" "LABEL=A&B /boot vfat defaults 0 2" "$(sed -n 5p "$F/etc/fstab")"
expect "set_ref: line count unchanged" "$(wc -l < "$F/fstab.orig")" "$(wc -l < "$F/etc/fstab")"
cl_table_set_ref "$F/etc/crypttab" 2 PARTUUID "$FP" "$NP"
expect "set_ref: crypttab column 2 only" "cryptroot PARTUUID=$NP none luks|crypthome UUID=$OL /etc/k luks" "$(paste -sd'|' "$F/etc/crypttab")"
refstub() { case "$1:$2" in "partuuid:$NP"|"uuid:$NR") return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2034  # read by cl_ref_exists in the sourced library
CL_ID_EXISTS_CMD=refstub
cl_ref_exists PARTUUID "$NP" && ok "ref_exists: PARTUUID looked up as a partuuid" || bad "ref_exists: PARTUUID not found"
cl_ref_exists UUID "$NP" && bad "ref_exists: a partuuid value passed as a UUID" || ok "ref_exists: kind matters"
cl_ref_exists PATH /swapfile && ok "ref_exists: paths are not checked" || bad "ref_exists: PATH failed"
unset CL_ID_EXISTS_CMD
for rs in borg-restore.sh backintime-restore.sh; do
    # The restore scripts' own fstab step, run against a synthetic fstab with blkid stubbed.
    fn=$(sed -n '/^fix_fstab_ref() {/,/^}/p' "$HERE/../$rs")
    [ -n "$fn" ] || { bad "$rs: fix_fstab_ref not found"; continue; }
    (
        log() { :; }; warn() { echo "WARN $*"; }
        blkid() { # blkid -s KIND -o value DEV
            case "$2:$5" in
                UUID:/dev/newroot) echo "$NR" ;; PARTUUID:/dev/newesp) echo "$NP" ;;
                UUID:/dev/newesp) echo "FFFF-0001" ;; LABEL:/dev/newboot) echo "EOSBOOT" ;;
                *) return 2 ;;
            esac; }
        eval "$fn"
        FSTAB="$F/rs-fstab"
        printf '%b' "PARTUUID=$FP /efi vfat umask=0077 0 2\nUUID=$OR / btrfs subvol=root 0 0\nUUID=$OR /home btrfs subvol=home 0 0\nLABEL=EOSBOOT /boot vfat defaults 0 2\n/swapfile none swap defaults 0 0\n/dev/sda9 /data ext4 defaults 0 2\n" > "$FSTAB"
        fix_fstab_ref root / /dev/newroot;   echo "MAP root $FIX_OLD $FIX_NEW"
        fix_fstab_ref /home /home /dev/newroot; echo "MAP home ${FIX_OLD:-none}"
        fix_fstab_ref ESP /efi /dev/newesp;  echo "MAP esp $FIX_OLD $FIX_NEW"
        fix_fstab_ref /boot /boot /dev/newboot; echo "MAP boot ${FIX_OLD:-none}"
        fix_fstab_ref swap swap "";          echo "MAP swap ${FIX_OLD:-none}"
        fix_fstab_ref data /data /dev/x
        echo "---"; cat "$FSTAB"
    ) > "$F/rs.out" 2>&1
    expect "$rs: root UUID rewritten on both btrfs lines" "2" "$(grep -c "^UUID=$NR " "$F/rs.out")"
    expect "$rs: root pair handed to the command-line map" "MAP root $OR $NR" "$(grep '^MAP root' "$F/rs.out")"
    expect "$rs: /home already correct after root, no second pair" "MAP home none" "$(grep '^MAP home' "$F/rs.out")"
    expect "$rs: PARTUUID ESP gets the new PARTUUID, not the fs UUID" "PARTUUID=$NP /efi vfat umask=0077 0 2" "$(grep ' /efi ' "$F/rs.out")"
    expect "$rs: ESP pair is PARTUUID old -> new" "MAP esp $FP $NP" "$(grep '^MAP esp' "$F/rs.out")"
    expect "$rs: unchanged LABEL kept, not mapped" "MAP boot none" "$(grep '^MAP boot' "$F/rs.out")"
    expect "$rs: swapfile left alone" "/swapfile none swap defaults 0 0" "$(grep '^/swapfile' "$F/rs.out")"
    grep -q 'WARN .*/dev/sda9' "$F/rs.out" && ok "$rs: kernel device name in fstab is warned about" || bad "$rs: no warning for /dev/sda9"
done
for rs in borg-restore.sh backintime-restore.sh; do
    # The SELinux relabel step, run against synthetic restored systems.
    blk=$(sed -n '/^SELINUX_MODE=\$(/,/^esac/p' "$HERE/../$rs")
    [ -n "$blk" ] || { bad "$rs: SELinux relabel step not found"; continue; }
    for mode in enforcing permissive disabled none; do
        TARGET="$T/se-$mode"; mkdir -p "$TARGET/etc/selinux"
        [ "$mode" = none ] || printf '# comment\nSELINUX=%s\nSELINUXTYPE=targeted\n' "$mode" > "$TARGET/etc/selinux/config"
        ( log() { :; }; eval "$blk" )
        case "$mode" in
            enforcing|permissive) [ -f "$TARGET/.autorelabel" ] && ok "$rs: SELinux $mode -> /.autorelabel" || bad "$rs: SELinux $mode but no /.autorelabel" ;;
            *) [ -f "$TARGET/.autorelabel" ] && bad "$rs: /.autorelabel created with SELinux $mode" || ok "$rs: SELinux $mode -> no relabel" ;;
        esac
    done
done
RB="$HERE/../restore-rebuild-boot.sh"
grep -q 'limine bios-install' "$RB" && grep -q 'efi_boot_entry Limine' "$RB" && ok "boot rebuild reinstalls Limine (UEFI binary + boot entry, BIOS)" || bad "boot rebuild lacks the Limine step"
grep -q 'refind-install --yes' "$RB" && grep -q 'efi_boot_entry rEFInd' "$RB" && ok "boot rebuild reinstalls rEFInd" || bad "boot rebuild lacks the rEFInd step"
# The ESP-relative loader path efibootmgr wants, from the formula the script uses.
ln=$(grep -m1 'rel="\\\\' "$RB")
# shellcheck disable=SC2034,SC2154  # ESP/loader are read and rel is set by the eval'd line
out=$(ESP=/boot/efi; loader=/boot/efi/EFI/limine/BOOTX64.EFI; eval "${ln#"${ln%%[![:space:]]*}"}"; printf '%s' "$rel")
expect "efibootmgr loader path is backslashed and ESP-relative" '\EFI\limine\BOOTX64.EFI' "$out"
grep -qE "grep -oP 'UUID=\\\\K" "$HERE/../borg-restore.sh" "$HERE/../backintime-restore.sh" && bad "a restore script still extracts ids with a substring UUID= match" || ok "restore scripts parse fstab/crypttab by field"
echo "== same-machine restore: the root container, the swapfile resume, references off the target disk"
Z="$T/zen"
OLDC=da69add4-1121-4c19-bf51-1307a674abeb; OLDFS=d5a89928-3d28-48ba-aca9-c32318eda426
mk "$Z/etc/kernel/cmdline" "rd.luks.name=$OLDC=luks-$OLDC rd.luks.options=$OLDC=discard root=/dev/mapper/luks-$OLDC rw rootflags=subvol=@ resume=UUID=$OLDFS resume_offset=41207506 quiet\n"
mk "$Z/etc/crypttab.initramfs" "luks-$OLDC UUID=$OLDC - discard\n"
mk "$Z/etc/crypttab" "luks-7ac9a064-f5fc-4f23-8a52-a78a0d1ee580 UUID=7ac9a064-f5fc-4f23-8a52-a78a0d1ee580 /etc/luks-keys/k nofail\n"
mk "$Z/etc/fstab" "UUID=D265-F4A4 /boot vfat umask=0077 0 2\nUUID=B68A-6FA8 /efi vfat umask=0077 0 2\n/dev/mapper/luks-$OLDC / btrfs subvol=/@ 0 0\n/swap/swapfile none swap defaults 0 0\n"
expect "root container from root=/dev/mapper/<name> + rd.luks.name (Manjaro sd-encrypt)" "$OLDC" "$(cl_root_luks_id "$Z")"
mk "$T/arch/etc/default/grub" "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=AAAA1111-2222-3333-4444-555566667777:cryptroot root=/dev/mapper/cryptroot\"\n"
expect "root container from cryptdevice=UUID=<id>:<name> (Arch encrypt hook)" "aaaa1111-2222-3333-4444-555566667777" "$(cl_root_luks_id "$T/arch")"
mk "$T/fed/boot/loader/entries/x.conf" "options root=UUID=$NR ro rd.luks.uuid=luks-$OL rhgb\n"
expect "root container: the only rd.luks.uuid when root=UUID= (Fedora)" "$OL" "$(cl_root_luks_id "$T/fed")"
mk "$T/two/etc/kernel/cmdline" "root=UUID=$NR rd.luks.uuid=$OL rd.luks.uuid=$OB\n"
expect "two containers and root=UUID=: undecidable, nothing" "" "$(cl_root_luks_id "$T/two")"
mk "$T/plain/etc/kernel/cmdline" "root=UUID=$NR ro quiet\n"
expect "no LUKS at all: nothing" "" "$(cl_root_luks_id "$T/plain")"

expect "swapfile resume: fs id and offset" "$OLDFS	41207506" "$(cl_resume_file_ref "$Z")"
expect "resume=UUID= without resume_offset (a swap partition) is not a swapfile ref" "" "$(cl_resume_file_ref "$R")"
CL_DRY=1 cl_set_resume_offset "$Z" 1234 >/dev/null; grep -q 'resume_offset=41207506' "$Z/etc/kernel/cmdline" && ok "resume_offset dry run writes nothing" || bad "dry run wrote"
cl_set_resume_offset "$Z" 1234 >/dev/null
grep -q ' resume_offset=1234 ' "$Z/etc/kernel/cmdline" && ! grep -q 41207506 "$Z/etc/kernel/cmdline" && ok "resume_offset rewritten" || bad "resume_offset not rewritten: $(cat "$Z/etc/kernel/cmdline")"
cl_set_resume_offset "$Z" "12;rm" >/dev/null && bad "a non-number offset was accepted" || ok "a non-number offset is refused"

# The old disk is still installed: /dev/nvme0n1 holds the old container, its
# filesystem and ESP; the restore target is /dev/sdb.
fake_disk() { case "$2" in "$OLDC"|"$OLDFS"|B68A-6FA8|D265-F4A4|7ac9a064-f5fc-4f23-8a52-a78a0d1ee580) echo /dev/nvme0n1 ;; NEWC*|NEWFS*|NEWESP|NEWBOOT) echo /dev/sdb ;; esac; }
export -f fake_disk; export OLDC OLDFS
off=$(CL_REF_DISK_CMD=fake_disk cl_refs_off_target "$Z" "/dev/sdb")
grep -q "kernel/cmdline	luks	$OLDC	/dev/nvme0n1" <<<"$off" && ok "old root container on the installed old disk is flagged" || bad "root container not flagged: $off"
grep -q "kernel/cmdline	uuid	$OLDFS	/dev/nvme0n1" <<<"$off" && ok "resume= onto the old disk's filesystem is flagged" || bad "resume not flagged"
grep -q "crypttab.initramfs	UUID	$OLDC" <<<"$off" && ok "crypttab.initramfs entry for the old container is flagged" || bad "crypttab.initramfs not flagged"
grep -q "fstab(/efi)	UUID	B68A-6FA8" <<<"$off" && ok "fstab /efi on the old disk's ESP is flagged" || bad "fstab /efi not flagged"
grep -q "7ac9a064" <<<"$off" && bad "a data drive in crypttab (not the boot chain) was flagged" || ok "other crypttab drives are not the boot chain and are not flagged"
printf '%s NEWC-0000-0000-0000-000000000000\n%s NEWFS-000-0000-0000-000000000000\nB68A-6FA8 NEWESP\nD265-F4A4 NEWBOOT\n' "$OLDC" "$OLDFS" > "$T/zmap"
cl_rewrite_ids "$Z" "$T/zmap" >/dev/null
cl_table_set_ref "$Z/etc/crypttab.initramfs" 2 UUID "$OLDC" NEWC-0000-0000-0000-000000000000
cl_table_set_ref "$Z/etc/fstab" 1 UUID B68A-6FA8 NEWESP; cl_table_set_ref "$Z/etc/fstab" 1 UUID D265-F4A4 NEWBOOT
off=$(CL_REF_DISK_CMD=fake_disk cl_refs_off_target "$Z" "/dev/sdb")
expect "after the mapping nothing in the boot chain points at the old disk" "" "$off"
grep -q "root=/dev/mapper/luks-$OLDC" "$Z/etc/kernel/cmdline" && grep -q "rd.luks.name=NEWC-0000-0000-0000-000000000000=luks-$OLDC" "$Z/etc/kernel/cmdline" \
    && ok "the mapper NAME is kept (fstab's /dev/mapper path still matches), only the id changed" || bad "cmdline: $(cat "$Z/etc/kernel/cmdline")"

echo "== optional crypttab drives; UKI embedded command lines; extra expected ids"
mk "$T/ct/etc/crypttab" "data1 UUID=$OL none discard,nofail,noauto\ndata2 UUID=$OB /k nofail\nroot UUID=$NL none discard\n# old UUID=$OR none noauto\n"
cl_crypttab_optional "$T/ct/etc/crypttab" data1 && ok "noauto,nofail entry is optional" || bad "data1 not optional"
cl_crypttab_optional "$T/ct/etc/crypttab" data2 && ok "nofail alone is optional" || bad "data2 not optional"
cl_crypttab_optional "$T/ct/etc/crypttab" root && bad "a plain entry was called optional" || ok "a plain entry is required"
cl_crypttab_optional "$T/ct/etc/crypttab" old && bad "a commented-out entry matched" || ok "commented-out entries never match"
cl_crypttab_optional "$T/ct/etc/crypttab" absent && bad "an absent name matched" || ok "an absent name is not optional"

# A minimal PE with a .cmdline section, laid out the way systemd-stub/ukify write it.
python3 - "$T/uki.efi" "rd.luks.name=$OL=luks-root root=/dev/mapper/luks-root resume=UUID=$OS resume_offset=42 quiet" <<'PY'
import struct, sys
path, cmd = sys.argv[1], sys.argv[2].encode() + b"\0"
pe = 0x80; optsz = 0xF0; nsec = 2
secoff = pe + 24 + optsz; dataoff = 0x400
d = bytearray(dataoff + 0x1000)
d[0:2] = b"MZ"; struct.pack_into("<I", d, 0x3c, pe)
d[pe:pe+4] = b"PE\0\0"; struct.pack_into("<HH", d, pe+4, 0x8664, nsec); struct.pack_into("<H", d, pe+20, optsz)
struct.pack_into("<8sIIII", d, secoff,      b".text\0\0\0", 0x10, 0x1000, 0x10, dataoff)
struct.pack_into("<8sIIII", d, secoff + 40, b".cmdline",    len(cmd), 0x2000, 0x200, dataoff + 0x10)
d[dataoff+0x10:dataoff+0x10+len(cmd)] = cmd
open(path, "wb").write(d)
PY
expect "cmdline read from the PE section table (NUL stripped)" "rd.luks.name=$OL=luks-root root=/dev/mapper/luks-root resume=UUID=$OS resume_offset=42 quiet" "$(cl_uki_cmdline "$T/uki.efi")"
printf 'not a PE file\n' > "$T/notpe.efi"
expect "a non-PE file yields nothing" "" "$(cl_uki_cmdline "$T/notpe.efi")"
mkdir -p "$T/uk/boot/EFI/Linux" "$T/uk/efi/EFI/Linux"; : > "$T/uk/boot/EFI/Linux/a.efi"; : > "$T/uk/efi/EFI/Linux/B.EFI"; : > "$T/uk/boot/EFI/Linux/notes.txt"
expect "UKIs under /boot and /efi, either case, nothing else" "$T/uk/boot/EFI/Linux/a.efi $T/uk/efi/EFI/Linux/B.EFI " "$(cl_ukis "$T/uk" | tr '\n' ' ')"

mk "$T/xe/etc/fstab" "/dev/mapper/root / btrfs subvol=@ 0 0\n"
mk "$T/xe/etc/kernel/cmdline" "root=/dev/mapper/root resume=UUID=$NR resume_offset=5\n"
expect "without extra ids the root fs is reported undeclared" "uuid $NR" "$(cl_carrier_mismatches "$T/xe" | cut -f3,4 | tr '\t' ' ')"
expect "CL_EXTRA_EXPECTED declares it (uppercase given)" "" "$(CL_EXTRA_EXPECTED="${NR^^}" cl_carrier_mismatches "$T/xe")"

grep -qE '\(\([A-Z_]+\+\+\)\)' "$HERE/../borg-restore.sh" "$HERE/../backintime-restore.sh" && bad "a restore script uses ((X++)) under set -e (exits when X is 0)" || ok "no ((X++)) under set -e in the restore scripts"

echo
echo "cmdline-fixture-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
