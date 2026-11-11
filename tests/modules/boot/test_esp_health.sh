#!/usr/bin/env bash
# Module: boot
# The ESP health probe: a read-only verdict on the EFI system partition, taken before it
# is mounted. The machine that powered itself off at 05:36 left nothing behind to look at,
# and the ESP is the one surface that cannot be repaired from the running system, so this
# round only has to make it *observable*:
#   ac-7 one line `esp=<ok|dirty|unreadable> boot=<n> sig=<ok|bad> dirty_bit=<0|1>
#        fsinfo=<ok|bad|na> mount=<rw|fail>` combines the boot sector signature, the FAT's
#        clean-shutdown bit, the FSInfo sector and the real `mount -t vfat -o rw` result;
#        it is recorded on p4 as `.ab/esp-health` through a temp file, a sync and a rename
#        (the same shape as `.ab/grow`), the offsets follow the volume's own sector size
#        (a 4Kn ESP is not read at a 512-byte offset), and a volume with no FSInfo sector
#        says so instead of claiming a check it could not run
#   ac-8 the probe writes nothing: the volume holds the same bytes afterwards, every
#        `dd` it runs is a read, and the verdict never takes part in a boot decision
#
# The volumes below are built byte by byte, so the fixture is a real FAT32 layout and the
# assertions do not depend on a host `mkfs.vfat`.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# A FAT32 volume, built byte by byte
# --------------------------------------------------------------------------- #

raw() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }

# put <file> <offset> <hex bytes>: write those bytes at that offset, leaving the rest be.
put() { raw "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }

# le_hex <decimal> <byte count>: the little-endian hex string the volume stores.
le_hex() {
  local value=$1 bytes=$2 out="" i
  for ((i = 0; i < bytes; i++)); do
    out+=$(printf '%02x' $((value & 255)))
    value=$((value >> 8))
  done
  printf '%s' "$out"
}

# build_volume <path> <clean|dirty|fsinfo-bad|no-signature|fsinfo-none> [bytes per sector]
#
# Layout: 512-byte (or 4096-byte) sectors, one sector per cluster, 32 reserved sectors,
# two FATs of four sectors, no root directory (FAT32 never has one), 2048 sectors in
# total. FAT[0] is the media entry, FAT[1] carries the clean-shutdown bit.
build_volume() {
  local vol=$1 mode=$2 bps=${3:-512}
  local fat_off=$((32 * bps))
  local fsinfo_off=$bps
  rm -f "$vol"
  dd if=/dev/zero of="$vol" bs=1024 count=2048 2>/dev/null
  put "$vol" 11 "$(le_hex "$bps" 2)"
  put "$vol" 13 "$(le_hex 1 1)"
  put "$vol" 14 "$(le_hex 32 2)"
  put "$vol" 16 "$(le_hex 2 1)"
  put "$vol" 17 "$(le_hex 0 2)"
  put "$vol" 21 "f8"
  put "$vol" 22 "$(le_hex 0 2)"
  put "$vol" 32 "$(le_hex 2048 4)"
  put "$vol" 36 "$(le_hex 4 4)"
  put "$vol" 48 "$(le_hex 1 2)"
  put "$vol" 510 "55aa"
  put "$vol" "$fat_off" "f8ffff0f"
  put "$vol" $((fat_off + 4)) "ffffff0f"
  put "$vol" "$fsinfo_off" "52526141"
  put "$vol" $((fsinfo_off + 484)) "72724161"
  put "$vol" $((fsinfo_off + 488)) "$(le_hex 2000 4)"
  put "$vol" $((fsinfo_off + 492)) "$(le_hex 3 4)"
  put "$vol" $((fsinfo_off + 508)) "000055aa"
  case "$mode" in
    # The kernel clears bit 27 of FAT[1] while the volume is in use and a clean unmount
    # sets it again, so a hard power cut leaves 0x07FFFFFF behind.
    dirty) put "$vol" $((fat_off + 4)) "ffffff07" ;;
    # A FSInfo sector whose structure signature did not survive: the free-count in it is
    # not believable any more, even though the boot sector still is.
    fsinfo-bad) put "$vol" $((fsinfo_off + 484)) "00000000" ;;
    no-signature) put "$vol" 510 "0000" ;;
    # The BPB names no FSInfo sector at all: nothing to check, and the line has to say so
    # rather than report a clean FSInfo it never read.
    fsinfo-none) put "$vol" 48 "$(le_hex 65535 2)" ;;
  esac
}

# --------------------------------------------------------------------------- #
# Stubs: the host's dd records every call and then does the real read, dmesg replays one
# kernel line, sync is counted.
# --------------------------------------------------------------------------- #

mkdir -p "$tmp/bin" "$tmp/run" "$tmp/p4root" "$tmp/sys" "$tmp/esp"
real_dd=$(command -v dd)
cat >"$tmp/bin/dd" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"\${ESP_FIXTURE}/dd.calls"
exec ${real_dd} "\$@"
STUB
cat >"$tmp/bin/dmesg" <<'STUB'
#!/bin/sh
[ -f "${ESP_FIXTURE}/dmesg.dirty" ] || exit 0
printf '[    1.234567] FAT-fs (vda1): Volume was not properly unmounted. Some data may be corrupt. Please run fsck.\n'
STUB
cat >"$tmp/bin/sync" <<'STUB'
#!/bin/sh
printf 'sync\n' >>"${ESP_FIXTURE}/sync.calls"
STUB
chmod +x "$tmp/bin/dd" "$tmp/bin/dmesg" "$tmp/bin/sync"
export PATH="$tmp/bin:$PATH"
export ESP_FIXTURE="$tmp"

# Never touch a real serial port or a real mount table from a test.
: >"$tmp/ttyS0"
: >"$tmp/consoles"
: >"$tmp/mounts"
: >"$tmp/dd.calls"
WF_SERIAL="$tmp/ttyS0"
WF_CONSOLES="$tmp/consoles"
WF_MOUNTS="$tmp/mounts"
WF_ESP_MOUNT="$tmp/esp"
WF_P4_MOUNT="$tmp/p4root"
WF_MARK_LOG=""
WF_SYS_BLOCK="$tmp/sys"
WF_ESP_HEALTH_TMP="$tmp/run/esp-health"
WF_DMESG="$tmp/bin/dmesg"
export WF_SERIAL WF_CONSOLES WF_MOUNTS WF_ESP_MOUNT WF_P4_MOUNT WF_MARK_LOG \
  WF_SYS_BLOCK WF_ESP_HEALTH_TMP WF_DMESG

source "$root/initramfs/lib/wf.sh"
source "$root/initramfs/lib/esp-health.sh"

# --------------------------------------------------------------------------- #
# ac-7 a clean, cleanly unmounted volume
# --------------------------------------------------------------------------- #

vol="$tmp/fat32-clean.img"
build_volume "$vol" clean
: >"$tmp/dd.calls"
probe="$(wf_esp_health_probe "$vol")"
assert_eq "$probe" "sig=ok dirty_bit=0 fsinfo=ok read=ok" \
  "ac-7 a healthy boot sector, a clean FAT and a believable FSInfo are three separate answers"

line="$(wf_esp_health_finish "$probe" 3 rw)"
assert_eq "$line" "esp=ok boot=3 sig=ok dirty_bit=0 fsinfo=ok mount=rw read=ok" \
  "ac-7 the verdict line starts with esp=, names the boot, and ends with the mount"
assert_eq "$(wf_esp_health_state "$line")" "ok" \
  "ac-7 the token is read back out of the line, not passed around separately"

assert_eq "$(grep -c 'stage=esp-health' "$vol" 2>/dev/null || true)" "0" \
  "ac-7 the probe does not write a diagnostic into the volume it is judging"

# The record goes through a temporary file and a rename, like `.ab/grow` does: a power cut
# during the write leaves the previous line, never half of a new one.
: >"$tmp/sync.calls"
record_dir="$tmp/p4root"
assert_command_ok "ac-7 the record is written on the p4 side" \
  wf_esp_health_record "$record_dir" "esp=ok boot=3 sig=ok dirty_bit=0 fsinfo=ok mount=rw read=ok"
assert_eq "$(cat "$record_dir/.ab/esp-health")" \
  "esp=ok boot=3 sig=ok dirty_bit=0 fsinfo=ok mount=rw read=ok" \
  "ac-7 .ab/esp-health carries exactly the one line"
assert_eq "$(wc -l <"$record_dir/.ab/esp-health" | tr -d ' ')" "1" \
  "ac-7 ... one line, so a reader never has to pick between two verdicts"
assert_eq "$(find "$record_dir/.ab" -name 'esp-health.tmp*' | wc -l | tr -d ' ')" "0" \
  "ac-7 the temporary file is renamed away, not left behind"
assert_eq "$(wc -l <"$tmp/sync.calls" | tr -d ' ')" "2" \
  "ac-7 the record syncs before and after the rename"

# A second boot overwrites the record: the file describes the boot that just happened.
wf_esp_health_record "$record_dir" "esp=dirty boot=4 sig=ok dirty_bit=1 fsinfo=ok mount=rw read=ok"
assert_eq "$(cat "$record_dir/.ab/esp-health")" \
  "esp=dirty boot=4 sig=ok dirty_bit=1 fsinfo=ok mount=rw read=ok" \
  "ac-7 a later boot replaces the verdict instead of appending a second one"

# --------------------------------------------------------------------------- #
# ac-7 a dirty volume: the bit and the kernel's own opinion, together
# --------------------------------------------------------------------------- #

vol_dirty="$tmp/fat32-dirty.img"
build_volume "$vol_dirty" dirty
: >"$tmp/dmesg.dirty"
probe_dirty="$(wf_esp_health_probe "$vol_dirty")"
assert_eq "$probe_dirty" "sig=ok dirty_bit=1 fsinfo=ok read=ok" \
  "ac-7 the clean-shutdown bit of FAT[1] is read, and a volume in use reports it"
assert_eq "$(wf_esp_health_finish "$probe_dirty" 2 rw)" \
  "esp=dirty boot=2 sig=ok dirty_bit=1 fsinfo=ok mount=rw read=ok" \
  "ac-7 a dirty bit the kernel confirms makes the volume dirty"

# The mitigation from the PRD: a hard power cut always lights that bit, so the bit alone
# is not a verdict - without a second witness the volume is reported as it is, ok, with
# the bit visible in the line for whoever pulls the disk.
rm -f "$tmp/dmesg.dirty"
assert_eq "$(wf_esp_health_finish "$probe_dirty" 2 rw)" \
  "esp=ok boot=2 sig=ok dirty_bit=1 fsinfo=ok mount=rw read=ok" \
  "ac-7 a lone dirty bit is recorded but does not turn the verdict into dirty"

# A FSInfo sector that lost its signature is the second witness the bit needs.
vol_fsinfo="$tmp/fat32-dirty-fsinfo.img"
build_volume "$vol_fsinfo" fsinfo-bad
put "$vol_fsinfo" $((512 * 32 + 4)) "ffffff07"
assert_eq "$(wf_esp_health_probe "$vol_fsinfo")" "sig=ok dirty_bit=1 fsinfo=bad read=ok" \
  "ac-7 a FSInfo sector whose structure signature is gone is reported as bad"
assert_eq "$(wf_esp_health_finish "$(wf_esp_health_probe "$vol_fsinfo")" 2 rw)" \
  "esp=dirty boot=2 sig=ok dirty_bit=1 fsinfo=bad mount=rw read=ok" \
  "ac-7 a dirty bit plus an unreadable FSInfo is a dirty volume"

# --------------------------------------------------------------------------- #
# ac-7 unreadable: the signature is gone, or the kernel refuses the mount
# --------------------------------------------------------------------------- #

vol_bad="$tmp/fat32-no-signature.img"
build_volume "$vol_bad" no-signature
assert_eq "$(wf_esp_health_probe "$vol_bad")" "sig=bad dirty_bit=0 fsinfo=ok read=ok" \
  "ac-7 a volume without the 55AA signature at offset 510 is reported as such"
assert_eq "$(wf_esp_health_finish "$(wf_esp_health_probe "$vol_bad")" 1 rw)" \
  "esp=unreadable boot=1 sig=bad dirty_bit=0 fsinfo=ok mount=rw read=ok" \
  "ac-7 a broken boot sector makes the verdict unreadable, whatever the FAT says"

vol_clean="$tmp/fat32-clean-again.img"
build_volume "$vol_clean" clean
assert_eq "$(wf_esp_health_finish "$(wf_esp_health_probe "$vol_clean")" 1 fail)" \
  "esp=unreadable boot=1 sig=ok dirty_bit=0 fsinfo=ok mount=fail read=ok" \
  "ac-7 a volume the kernel will not mount is unreadable, whatever its boot sector says"

# --------------------------------------------------------------------------- #
# ac-7 the offsets follow the volume's sector size, and the probe says so when it has to
# --------------------------------------------------------------------------- #

# 4Kn: the BPB says 4096 bytes per sector, so the FAT starts at 32 * 4096 = 128 KiB. A
# probe that assumed 512 would look at zeroes and report a dirty bit that is not there
# (or, worse, read past the FAT and find nothing).
vol_4kn="$tmp/fat32-4kn.img"
build_volume "$vol_4kn" dirty 4096
assert_eq "$(wf_esp_health_probe "$vol_4kn")" "sig=ok dirty_bit=1 fsinfo=ok read=ok" \
  "ac-7 a 4096-byte-sector volume is read at the offset its own BPB names"

# A BPB that does not parse falls back to the logical block size the kernel reports for
# the device - the same lookup initramfs/lib/grow.sh does before it writes a table.
vol_bpb="$tmp/dev/vda1"
mkdir -p "$tmp/dev" "$tmp/sys/vda1/queue"
build_volume "$vol_bpb" dirty 4096
put "$vol_bpb" 11 "0000"
printf '4096\n' >"$tmp/sys/vda1/queue/logical_block_size"
WF_SYS_BLOCK="$tmp/sys"
export WF_SYS_BLOCK
assert_eq "$(wf_esp_health_probe "$vol_bpb")" "sig=ok dirty_bit=1 fsinfo=ok read=ok" \
  "ac-7 an unusable BPB sector size falls back to the device's logical block size"

# No FSInfo sector named by the BPB: the line says na instead of inventing a check.
vol_none="$tmp/fat32-no-fsinfo.img"
build_volume "$vol_none" fsinfo-none
assert_eq "$(wf_esp_health_probe "$vol_none")" "sig=ok dirty_bit=0 fsinfo=na read=ok" \
  "ac-7 a volume without an FSInfo sector reports na, not a check that never ran"
assert_eq "$(wf_esp_health_finish "$(wf_esp_health_probe "$vol_none")" 1 rw)" \
  "esp=ok boot=1 sig=ok dirty_bit=0 fsinfo=na mount=rw read=ok" \
  "ac-7 ... and the missing FSInfo does not by itself make the verdict dirty"

# --------------------------------------------------------------------------- #
# ac-7 a read that fails is not a zero
#
# Everything above is about *where* to read. This is about a read that does not happen: a
# short read used to become the number 0, and 0 for the clean-shutdown bit means "unmounted
# cleanly", so a volume the probe could not read came out as `ok`. That is the one thing a
# probe must never say, so a failed read has its own token and its own verdict floor.
# --------------------------------------------------------------------------- #

# A dd that refuses the byte-wise reads off the device and still serves the buffered boot
# sector: the FAT and the FSInfo are exactly the two structures that cannot be read.
cat >"$tmp/bin/dd-partial" <<STUB
#!/bin/sh
# Read off the device, byte by byte: that is the volume's own FAT and FSInfo.
case " \$* " in
    *" if=${vol_4kn} "*) ;;
    *) exec ${real_dd} "\$@" ;;
esac
case " \$* " in
    *" bs=1 "*) exit 1 ;;
esac
exec ${real_dd} "\$@"
STUB
chmod +x "$tmp/bin/dd-partial"
WF_DD="$tmp/bin/dd-partial"
export WF_DD
probe_partial="$(wf_esp_health_probe "$vol_4kn")"
assert_eq "$probe_partial" "sig=ok dirty_bit=unknown fsinfo=unknown read=error" \
  "ac-7 a FAT that cannot be read is reported as unknown, never as a clean bit"
assert_eq "$(wf_esp_health_state "$(wf_esp_health_finish "$probe_partial" 1 rw)")" "unreadable" \
  "ac-7 ... and the verdict is unreadable, not ok"

# Nothing readable at all: even the boot sector read fails.
WF_DD="$tmp/bin/dd-broken"
cat >"$tmp/bin/dd-broken" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$tmp/bin/dd-broken"
probe_broken="$(wf_esp_health_probe "$vol_clean")"
assert_eq "$probe_broken" "sig=bad dirty_bit=0 fsinfo=na read=error" \
  "ac-7 a device that cannot be read at all says so instead of describing a volume"
assert_eq "$(wf_esp_health_state "$(wf_esp_health_finish "$probe_broken" 1 rw)")" "unreadable" \
  "ac-7 ... and never reaches a verdict of ok"
WF_DD="dd"
export WF_DD

# --------------------------------------------------------------------------- #
# ac-7 the parser is spelled the way the shipped busybox spells it
# --------------------------------------------------------------------------- #
# The probe reads the volume through `hexdump -v -e '1/1 "%02x"'`. A busybox binary on this
# host is driven with the exact invocation; without one, the applet has to be in the shipped
# toolset and the literal format string has to be the one the probe uses - the remaining doubt
# (does busybox's hexdump accept it) is a real-image question and is listed as such.
busybox_bin="$(command -v busybox 2>/dev/null || true)"
if [ -n "${busybox_bin}" ]; then
  assert_eq "$(printf '\125\252' | "${busybox_bin}" hexdump -v -e '1/1 "%02x"' | tr -d ' \n')" \
    "55aa" "ac-7 busybox hexdump prints one byte per %02x, exactly as the probe parses it"
else
  assert_eq "$(( $(grep -c '"hexdump"' "$root/scripts/ci/initramfs-tools.lock.json") > 0 ))" "1" \
    "ac-7 the shipped busybox carries the hexdump applet the probe needs"
  assert_eq "$(grep -cF '1/1 "%02x"' "$root/initramfs/lib/esp-health.sh")" "1" \
    "ac-7 the format string is the documented one-byte-hex form"
fi

# --------------------------------------------------------------------------- #
# ac-8 zero writes
# --------------------------------------------------------------------------- #

# The strongest form of "the probe wrote nothing": the volume is byte for byte the file
# it was before the probe ran.
vol_write="$tmp/fat32-zero-write.img"
build_volume "$vol_write" dirty
: >"$tmp/dd.calls"
before_sum="$(cksum <"$vol_write")"
before_size="$(wc -c <"$vol_write" | tr -d ' ')"
probe_write="$(wf_esp_health_probe "$vol_write")"
wf_esp_health_finish "$probe_write" 1 rw >/dev/null
assert_eq "$before_sum" "$(cksum <"$vol_write")" \
  "ac-8 the volume holds exactly the bytes it held"
assert_eq "$before_size" "$(wc -c <"$vol_write" | tr -d ' ')" \
  "ac-8 the volume is not a byte shorter or longer"

assert_eq "$(grep -cF "of=${vol_write}" "$tmp/dd.calls" || true)" "0" \
  "ac-8 no dd call names the volume as an output"
assert_eq "$(( $(grep -cF "if=${vol_write}" "$tmp/dd.calls") > 0 ))" "1" \
  "ac-8 the probe really did read the volume (the assertions above are not vacuous)"
assert_eq "$(grep -c 'of=' "$tmp/dd.calls")" "1" \
  "ac-8 the probe performs exactly one write, the boot sector buffer"
assert_eq "$(grep 'of=' "$tmp/dd.calls" | grep -cF "of=${tmp}/run/esp-health/")" "1" \
  "ac-8 ... and that write goes to the probe's own buffer, never to the volume"

# The source says the same thing: every output is a buffer, no output is a device.
esp_lib="$root/initramfs/lib/esp-health.sh"
of_targets="$(grep -oE 'of="[^"]*"' "$esp_lib")"
assert_eq "$(printf '%s\n' "${of_targets}" | grep -c '_boot' || true)" "1" \
  "ac-8 the probe has exactly one output, the boot sector buffer"
assert_eq "$(printf '%s\n' "${of_targets}" | grep -c '_dev\|/dev/' || true)" "0" \
  "ac-8 no output target anywhere names a device"
assert_eq "$(grep -c 'mkfs' "$esp_lib" || true)" "0" \
  "ac-8 the probe carries no formatter"
assert_command_ok "ac-8 initramfs/lib/esp-health.sh parses as POSIX sh with dash" \
  sh -n "$esp_lib"

# The verdict is diagnostics: every consumer in init is a log line, a breadcrumb or the
# record on p4. A dirty or unreadable ESP must still boot on the read-only strategy.
boot_init="$root/initramfs/boot/init"
assert_eq \
  "$(grep -n 'esp_state' "$boot_init" \
    | grep -Ec '\[ .*esp_state|\[\[ .*esp_state|case .*esp_state|if .*esp_state' || true)" \
  "0" \
  "ac-8 the ESP verdict never appears in a condition, so it cannot change a boot decision"
assert_contains "$(cat "$boot_init")" 'wf_esp_health_record' \
  "ac-8 the verdict is recorded on the p4 side"
assert_contains "$(cat "$boot_init")" '. /lib/esp-health.sh' \
  "ac-8 the init sources the probe"

finish
