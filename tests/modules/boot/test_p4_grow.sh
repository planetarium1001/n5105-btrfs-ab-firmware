#!/usr/bin/env bash
# Module: boot
# Drives the first-boot growth of p4 from fixture partition tables, so the whole state
# machine is verified on a machine with no loop device, no btrfs and no root:
#   ac-1 the decision only depends on the table: p4 short of the last usable LBA grows,
#        p4 already at it is already-full, and the arithmetic fallback agrees with the
#        `last-lba` sfdisk prints
#   ac-2 a run writes the table back with --no-reread, changes nothing but the p4 size,
#        re-reads the kernel table, verifies the device grew, and a second run on the
#        same disk is already-full without writing again (idempotent)
#   ac-3 every failure is a recorded token, never a boot failure: missing-sfdisk when the
#        tool is absent, fail:<token> for a dump, write, re-read or size-check problem,
#        and fail:btrfs-resize when the filesystem cannot be extended
#   ac-4 the recorded file is <p4 root subvolume>/.ab/grow with `result=<state>
#        last_lba=<n>`, written through a rename and readable after a failure
#   ac-5 the boot init grows p4 before the overlay is mounted, discovers ab-data, mounts
#        @data/@docker/@swap with the documented options, and never aborts on a failure
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
source "$root/initramfs/lib/grow.sh"
source "$root/platform/lib/disk-identity.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# Fixture disk: the image from scripts/ci/disk.sh, with p4 still at its shipped size.
# The geometry is read from disk.sh instead of being written down here: the shipped p4
# size is a build decision (64 MiB once, 128 MiB later) and a test that pins it turns
# every layout change into a red module.
# --------------------------------------------------------------------------- #

disk_script="$root/scripts/ci/disk.sh"
p4_start="$(sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="ab-data".*/\1/p' \
  "${disk_script}" | head -n 1)"
p4_shipped_size="$(sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="ab-data".*/\2/p' \
  "${disk_script}" | head -n 1)"
case "${p4_start}" in '' | *[!0-9]*) p4_start=788480 ;; esac
case "${p4_shipped_size}" in '' | *[!0-9]*) p4_shipped_size=262144 ;; esac
# Tail after the partitions: 2045 sectors, chosen so the available size is NOT a multiple
# of eight whatever the shipped p4 size is (131072 and 262144 both are), plus the 34
# sectors the backup GPT reserves.
disk_sectors=$((p4_start + p4_shipped_size - 1 + 34 + 2045))
last_lba=$((disk_sectors - 34))
# The tail the disk offers is the upper bound; the grown size is that, rounded DOWN to a
# multiple of 8 sectors, because btrfs refuses a device size that is not a multiple of its
# 4096-byte sectorsize.
p4_want_size=$((last_lba - p4_start + 1))
p4_grown_size=$((p4_want_size / 8 * 8))

sys="$tmp/sys/block"
mkdir -p "$sys/vda" "$tmp/work" "$tmp/bin" "$tmp/table"
# /sys/class/block/<part> is a symlink into the disk directory in the real kernel, which
# is what makes <part>/.. resolve to the disk. Mirroring that here keeps the sector-size
# lookup and the parent-disk derivation on the same code path as the device itself.
mkdir -p "$sys/vda/vda4"
printf '4\n' >"$sys/vda/vda4/partition"
printf 'DEVTYPE=partition\nDEVNAME=vda4\nPARTN=4\nPARTNAME=ab-data\n' >"$sys/vda/vda4/uevent"
ln -sfn "vda/vda4" "$sys/vda4"
mkdir -p "$sys/vda/queue"
printf '512\n' >"$sys/vda/queue/logical_block_size"
printf '%s\n' "${disk_sectors}" >"$sys/vda/size"
printf '%s\n' "${p4_shipped_size}" >"$sys/vda4/size"

# sfdisk -d output for the image, byte for byte in the shape util-linux prints.
table_for() { # <p4 size>
  cat <<TABLE
label: gpt
label-id: 4F2B1C3D-5E6F-7081-9203-A4B5C6D7E8F9
device: /dev/vda
unit: sectors
first-lba: 34
last-lba: ${last_lba}
sector-size: 512

/dev/vda1 : start=        2048, size=      262144, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=11111111-2222-3333-4444-555555555555, name="ab-esp"
/dev/vda2 : start=      264192, size=      262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=66666666-7777-8888-9999-AAAAAAAAAAAA, name="ab-slot-a"
/dev/vda3 : start=      526336, size=      262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF, name="ab-slot-b"
/dev/vda4 : start=      ${p4_start}, size=      $1, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=12121212-3434-5656-7878-909090909090, name="ab-data"
TABLE
}

reset_fixture() {
  table_for "${p4_shipped_size}" >"$tmp/table/current"
  rm -f "$tmp/table/written" "$tmp/sfdisk.calls" "$tmp/blockdev.calls" "$tmp/btrfs.calls" \
    "$tmp/mount.calls" "$tmp/umount.calls"
  printf '%s\n' "${p4_shipped_size}" >"$sys/vda4/size"
}

# --------------------------------------------------------------------------- #
# Command fixtures: sfdisk, blockdev, partx, btrfs and sleep, all recorded
# --------------------------------------------------------------------------- #

cat >"$tmp/bin/sfdisk" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/sfdisk.calls"
case "$1" in
  -d)
    [ "${STUB_DUMP_FAIL:-0}" = "1" ] && exit 1
    cat "${GROW_FIXTURE}/table/current"
    ;;
  --no-reread)
    [ "${STUB_WRITE_FAIL:-0}" = "1" ] && exit 1
    cat >"${GROW_FIXTURE}/table/written"
    cp "${GROW_FIXTURE}/table/written" "${GROW_FIXTURE}/table/current"
    if [ "${STUB_NO_SIZE_CHANGE:-0}" != "1" ]; then
      size="$(sed -n 's|^/dev/vda4 : start= *[0-9]*, size= *\([0-9]*\).*|\1|p' \
        "${GROW_FIXTURE}/table/written")"
      # sysfs `size` is always in 512-byte units; the table is in logical sectors.
      lbs="$(cat "${GROW_FIXTURE}/sys/block/vda/queue/logical_block_size" 2>/dev/null)"
      case "${lbs}" in '' | *[!0-9]*) lbs=512 ;; esac
      printf '%s\n' "$(( size * lbs / 512 ))" >"${GROW_FIXTURE}/sys/block/vda4/size"
    fi
    ;;
  *)
    exit 2
    ;;
esac
STUB

cat >"$tmp/bin/blockdev" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/blockdev.calls"
case "$1" in
  --rereadpt)
    [ "${STUB_REREAD_FAIL:-0}" = "1" ] && exit 1
    exit 0
    ;;
  --getsize64)
    printf '%s\n' "$(( $(cat "${GROW_FIXTURE}/sys/block/vda/size") * 512 ))"
    ;;
  *)
    exit 2
    ;;
esac
STUB

cat >"$tmp/bin/partx" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/partx.calls"
[ "${STUB_PARTX_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB

cat >"$tmp/bin/btrfs" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/btrfs.calls"
[ "${STUB_BTRFS_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB

cat >"$tmp/bin/mount" <<'STUB'
#!/bin/sh
printf '%s
' "$*" >>"${GROW_FIXTURE}/mount.calls"
[ "${STUB_MOUNT_FAIL:-0}" = "1" ] && exit 1
# The only form the boot path uses: -t btrfs -o <opts> <device> <mount point>
printf '%s %s btrfs rw,noatime 0 0\n' "$5" "$6" >>"${WF_MOUNTS}"
STUB
cat >"$tmp/bin/umount" <<'STUB'
#!/bin/sh
printf '%s
' "$*" >>"${GROW_FIXTURE}/umount.calls"
mp="$1"
{ grep -v " ${mp} " "${WF_MOUNTS}" 2>/dev/null || :; } >"${WF_MOUNTS}.new"
mv "${WF_MOUNTS}.new" "${WF_MOUNTS}"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin"/*

export GROW_FIXTURE="$tmp"
DI_SYS_BLOCK="$sys"
DI_DEV_DIR="/dev"
DI_CMDLINE="$tmp/cmdline"
DI_MOUNTS="$tmp/mounts"
DI_BLKID="$tmp/bin/blkid-grow"
export DI_SYS_BLOCK DI_DEV_DIR DI_CMDLINE DI_MOUNTS DI_BLKID
WF_SFDISK="$tmp/bin/sfdisk"
WF_BLOCKDEV="$tmp/bin/blockdev"
WF_PARTX="$tmp/bin/partx"
WF_BTRFS="$tmp/bin/btrfs"
WF_SLEEP="$tmp/bin/sleep"
WF_MOUNT="$tmp/bin/mount"
WF_UMOUNT="$tmp/bin/umount"
WF_SYS_BLOCK="$sys"
WF_GROW_TMP="$tmp/work"
WF_GROW_VERIFY_TRIES=2
WF_MOUNTS="$tmp/mounts"
export WF_SFDISK WF_BLOCKDEV WF_PARTX WF_BTRFS WF_SLEEP WF_SYS_BLOCK WF_GROW_TMP \
  WF_GROW_VERIFY_TRIES WF_MOUNTS WF_MOUNT WF_UMOUNT
mkdir -p "$tmp/mnt/p4"
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "$tmp/mnt/p4" >"$WF_MOUNTS"

reset_fixture

# --------------------------------------------------------------------------- #
# Decision: the whole idempotency rule, without touching a disk
# --------------------------------------------------------------------------- #

# The fixture follows disk.sh rather than pinning one layout: prove the parser actually
# answers with the script's numbers, and that it would follow a 128 MiB p4 too.
assert_eq "${p4_shipped_size}" \
  "$(sed -n 's/.*start= *[0-9]*, size= *\([0-9]*\),.*name="ab-data".*/\1/p' "${disk_script}" | head -n 1)" \
  "ac-1 the fixture uses the p4 size scripts/ci/disk.sh ships"
assert_eq "${p4_start}" \
  "$(sed -n 's/.*start= *\([0-9]*\), size= *[0-9]*,.*name="ab-data".*/\1/p' "${disk_script}" | head -n 1)" \
  "ac-1 the fixture uses the p4 start scripts/ci/disk.sh ships"
sim_geometry="$(printf '%s\n' \
  'start= 788480, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ab-data"' \
  | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="ab-data".*/\1 \2/p')"
assert_eq "${sim_geometry}" "788480 262144" \
  "ac-1 the geometry parser follows a 128 MiB p4 instead of today's size"

decision=$(wf_grow_decide "$tmp/table/current" /dev/vda4 "${disk_sectors}")
assert_eq "${decision}" "grow ${last_lba} ${p4_grown_size}" \
  "ac-1 a p4 short of the last usable LBA grows to the aligned size"
assert_eq "$((p4_want_size % 8))" "5" \
  "ac-1 the fixture tail is deliberately unaligned"
assert_eq "$((p4_want_size - p4_grown_size))" "5" \
  "ac-1 rounding down costs only the unaligned remainder"
assert_eq "$((p4_grown_size % 8))" "0" \
  "ac-1 the grown size is a multiple of the 4096-byte sectorsize in 512-byte sectors"
assert_eq "$((p4_grown_size * 512 % 4096))" "0" \
  "ac-1 the grown size in bytes is a multiple of 4096"

table_for "${p4_grown_size}" >"$tmp/table/grown"
assert_eq "$(wf_grow_decide "$tmp/table/grown" /dev/vda4 "${disk_sectors}")" \
  "already-full ${last_lba}" "ac-1 p4 already at the last usable LBA is already-full"

# One sector short of the end is still a grow, and the size never shrinks.
table_for "$((p4_grown_size - 1))" >"$tmp/table/short"
assert_eq "$(wf_grow_decide "$tmp/table/short" /dev/vda4 "${disk_sectors}")" \
  "grow ${last_lba} ${p4_grown_size}" "ac-1 a single sector of tail space still grows"
# Rounding can take the whole gain away: a few sectors of slack must not turn into a
# table write that grows nothing. The shipped size is a multiple of eight, so three
# sectors of tail round straight back to it.
slack_last_lba=$((p4_start + p4_shipped_size - 1 + 3))
cat >"$tmp/table/slack" <<SLACK
label: gpt
device: /dev/vda
unit: sectors
first-lba: 34
last-lba: ${slack_last_lba}
sector-size: 512

/dev/vda4 : start=      ${p4_start}, size=      ${p4_shipped_size}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000004, name="ab-data"
SLACK
# The device, not the dump, decides where the disk ends (measured on real hardware:
# `sfdisk -d` keeps reporting the table's own last-lba after an image lands on a bigger
# disk). The device here ends three sectors past p4, which is the slack this cases is
# about, so the alignment still rounds the gain away.
assert_eq "$(wf_grow_decide "$tmp/table/slack" /dev/vda4 "$((slack_last_lba + 34))")" \
  "already-full ${slack_last_lba}" \
  "ac-1 slack that rounds back to the current size is already-full"

# A partition that starts after p4 means p4 is not the last one: growing it to the end of
# the disk would run over that partition, so the decision refuses instead.
cat >"$tmp/table/follower" <<FOLLOWER
label: gpt
device: /dev/vda
unit: sectors
first-lba: 34
last-lba: ${last_lba}
sector-size: 512

/dev/vda4 : start=      ${p4_start}, size=      ${p4_shipped_size}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000004, name="ab-data"
/dev/vda5 : start=      $((p4_start + p4_shipped_size)), size=        2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000005, name="vendor"
FOLLOWER
assert_eq "$(wf_grow_decide "$tmp/table/follower" /dev/vda4 "${disk_sectors}")" \
  "fail:p4-not-last" \
  "ac-1 a partition after p4 stops the growth instead of overwriting it"

# A filesystem with 512-byte sectors needs no alignment: the behaviour is unchanged.
assert_eq "$(WF_GROW_SECTORSIZE=512 wf_grow_decide "$tmp/table/current" /dev/vda4 "${disk_sectors}")" \
  "grow ${last_lba} ${p4_want_size}" \
  "ac-1 a 512-byte sectorsize grows to the unaligned end"

# Down-rounding is reported, so the geometry can be checked later.
aligned_log="$(wf_grow_decide "$tmp/table/current" /dev/vda4 "${disk_sectors}" 2>&1 >/dev/null)"
assert_contains "${aligned_log}" "aligned size=${p4_grown_size}" \
  "ac-1 the aligned size is logged"
assert_contains "${aligned_log}" "sectorsize=4096" \
  "ac-1 the sectorsize used for the alignment is logged"
assert_contains "${aligned_log}" "unaligned ${p4_want_size}" \
  "ac-1 the unaligned request is logged next to it"

table_for "$((p4_grown_size + 4096))" >"$tmp/table/oversized"
assert_eq "$(wf_grow_decide "$tmp/table/oversized" /dev/vda4 "${disk_sectors}")" \
  "fail:p4-beyond-disk" "ac-1 a p4 past the usable area is refused, never shrunk"

# The arithmetic fallback has to agree with what sfdisk itself prints, otherwise a dump
# without `last-lba` would grow p4 over the backup GPT.
grep -v '^last-lba:' "$tmp/table/current" >"$tmp/table/no-last-lba"
assert_eq "$(wf_grow_decide "$tmp/table/no-last-lba" /dev/vda4 "${disk_sectors}")" \
  "grow ${last_lba} ${p4_grown_size}" \
  "ac-1 the computed last usable LBA equals the one sfdisk prints"
assert_eq "$(wf_grow_decide "$tmp/table/current" /dev/vda4 "")" \
  "grow ${last_lba} ${p4_grown_size}" \
  "ac-1 the dump alone is enough when the disk size is unknown"

assert_eq "$(wf_grow_decide "$tmp/table/current" /dev/vda9 "${disk_sectors}")" \
  "fail:partition-table-unreadable" "ac-3 a table without a p4 line is a failure token"
assert_eq "$(wf_grow_decide "$tmp/table/no-last-lba" /dev/vda4 "")" \
  "fail:disk-size-unknown" "ac-3 no table end and no disk size is a failure token"

# --------------------------------------------------------------------------- #
# Run: one boot, then a second boot on the same disk
# --------------------------------------------------------------------------- #

first=$(wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${first}" "done ${last_lba}" "ac-2 a first boot grows p4 and reports done"
assert_eq "$(printf '%s\n' "${first}" | wc -l | tr -d ' ')" "1" \
  "ac-2 the run prints exactly one result line"

assert_contains "$(cat "$tmp/sfdisk.calls")" "--no-reread /dev/vda" \
  "ac-2 the table is written back with --no-reread"
assert_contains "$(cat "$tmp/blockdev.calls")" "--rereadpt /dev/vda" \
  "ac-2 the kernel is asked to re-read the table"
assert_eq "$(cat "$sys/vda4/size")" "${p4_grown_size}" \
  "ac-2 the p4 device really became the grown size"

# Only the p4 size may differ from the pre-growth table: the other three partitions keep
# their start, size, type and UUID, so the ESP and both slots stay addressable.
grep -v '^/dev/vda4 :' "$tmp/table/current" >"$tmp/table/other.expected"
table_for "${p4_shipped_size}" | grep -v '^/dev/vda4 :' >"$tmp/table/other.before"
assert_eq "$(diff -u "$tmp/table/other.before" "$tmp/table/other.expected" >/dev/null 2>&1; echo $?)" \
  "0" "ac-2 every non-p4 table line is written back unchanged"
assert_eq "$(sed -n 's|^/dev/vda4 : start= *\([0-9]*\), size= *\([0-9]*\),.*|\1 \2|p' "$tmp/table/current")" \
  "${p4_start} ${p4_grown_size}" "ac-2 p4 keeps its start and only its size changed"
assert_eq "$(sed -n 's|^/dev/vda4 :.*name="\([^"]*\)".*|\1|p' "$tmp/table/current")" \
  "ab-data" "ac-2 the p4 partition name survives the rewrite"

writes_before=$(grep -c '^--no-reread' "$tmp/sfdisk.calls" || true)
second=$(wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${second}" "already-full ${last_lba}" \
  "ac-2 a second boot on the same disk is already-full (idempotent)"
writes_after=$(grep -c '^--no-reread' "$tmp/sfdisk.calls" || true)
assert_eq "${writes_after}" "${writes_before}" \
  "ac-2 the idempotent boot does not write the partition table again"
assert_eq "$(cat "$sys/vda4/size")" "${p4_grown_size}" \
  "ac-2 the idempotent boot leaves the device size alone"

# --------------------------------------------------------------------------- #
# Failures: every one of them is a token, and the disk is left as it was
# --------------------------------------------------------------------------- #

reset_fixture
missing=$(WF_SFDISK="$tmp/bin/absent-sfdisk" wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${missing}" "missing-sfdisk 0" \
  "ac-3 a boot initramfs without sfdisk reports missing-sfdisk"
assert_eq "$(cat "$tmp/table/current")" "$(table_for "${p4_shipped_size}")" \
  "ac-3 missing-sfdisk leaves the partition table untouched"

dump_fail=$(STUB_DUMP_FAIL=1 wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${dump_fail}" "fail:partition-table-read 0" \
  "ac-3 an unreadable table is recorded as fail:partition-table-read"

write_fail=$(STUB_WRITE_FAIL=1 wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${write_fail}" "fail:partition-table-write ${last_lba}" \
  "ac-3 a refused write is recorded as fail:partition-table-write"
assert_eq "$(cat "$sys/vda4/size")" "${p4_shipped_size}" \
  "ac-3 a refused write leaves the device size alone"

reread_fail=$(STUB_REREAD_FAIL=1 STUB_PARTX_FAIL=1 wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${reread_fail}" "fail:partition-table-reread ${last_lba}" \
  "ac-3 a failed re-read is recorded as fail:partition-table-reread"

# blockdev missing from the initramfs is not fatal: partx does the same job.
reset_fixture
partx_only=$(WF_BLOCKDEV="$tmp/bin/absent-blockdev" wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${partx_only}" "done ${last_lba}" \
  "ac-3 partx -u replaces a missing blockdev"
assert_contains "$(cat "$tmp/partx.calls")" "-u /dev/vda" \
  "ac-3 partx is called with -u"

reset_fixture
unchanged=$(STUB_NO_SIZE_CHANGE=1 wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "${unchanged}" "fail:size-unchanged ${last_lba}" \
  "ac-3 a kernel that never shows the new size is recorded as fail:size-unchanged"

# wf_grow_fs takes the DEVICE while nothing of the filesystem is mounted (the boot
# order), or a mount point when it is already mounted. Everything else is refused.
reset_fixture
p4_mount="$tmp/mnt/p4"
: >"$WF_MOUNTS"
assert_eq "$(wf_grow_fs /dev/vda4 /dev/vda)" "done" \
  "ac-3 the unmounted device is a valid resize target"
assert_contains "$(cat "$tmp/btrfs.calls")" "filesystem resize max /dev/vda4" \
  "ac-3 the resize ran against the device, before any mount"

# Once the device is mounted, the device path is the race that produced EBUSY/EINVAL.
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "${p4_mount}" >"$WF_MOUNTS"
rm -f "$tmp/btrfs.calls"
assert_eq "$(wf_grow_fs /dev/vda4 /dev/vda)" "fail:resize-target" \
  "ac-3 a mounted device is refused as a resize target"
assert_eq "$(cat "$tmp/btrfs.calls" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 the refused mounted device never reaches btrfs-progs"
assert_eq "$(wf_grow_fs "${p4_mount}")" "done" \
  "ac-3 a mount point is accepted when the filesystem is mounted"
assert_contains "$(cat "$tmp/btrfs.calls")" "filesystem resize max ${p4_mount}" \
  "ac-3 the resize is run against the mount point"

assert_eq "$(STUB_BTRFS_FAIL=1 wf_grow_fs "${p4_mount}")" "fail:btrfs-resize" \
  "ac-3 a failed filesystem resize is recorded as fail:btrfs-resize"
rm -f "$tmp/btrfs.calls"
assert_eq "$(wf_grow_fs /mnt/never-mounted)" "fail:resize-target" \
  "ac-3 an unmounted directory is refused as a resize target"
assert_eq "$(wf_grow_fs "")" "fail:resize-target" "ac-3 an empty target is refused"
assert_eq "$(cat "$tmp/btrfs.calls" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 no refused target ever reaches btrfs-progs"

# btrfs-progs output is the only evidence for why a resize failed, so it is kept in the
# [grow] log instead of being thrown away.
cat >"$tmp/bin/btrfs-noisy" <<'STUB'
#!/bin/sh
echo "ERROR: cannot resize /mnt/p4root: device is busy" >&2
exit 1
STUB
chmod +x "$tmp/bin/btrfs-noisy"
# The boot path resizes the unmounted device, so that is the shape the diagnostics take.
: >"$WF_MOUNTS"
reset_fixture
: >"$WF_MOUNTS"
noisy_out="$(WF_BTRFS="$tmp/bin/btrfs-noisy" wf_grow_fs /dev/vda4 /dev/vda 2>&1)"
assert_contains "${noisy_out}" "fail:btrfs-resize" \
  "ac-3 a failed resize still returns its token"
assert_contains "${noisy_out}" "device is busy" \
  "ac-3 the btrfs-progs error is kept in the grow log"
assert_contains "${noisy_out}" "[grow] btrfs filesystem resize max /dev/vda4 failed" \
  "ac-3 the failing command and its target are logged"
assert_contains "${noisy_out}" "[grow] diag btrfs:" \
  "ac-3 the failure dumps what btrfs-progs thinks the filesystem is"
assert_contains "${noisy_out}" "[grow] diag device /dev/vda4:" \
  "ac-3 the failure dumps the kernel's device size"
assert_contains "${noisy_out}" "[grow] diag table: /dev/vda4 : start=" \
  "ac-3 the failure dumps the partition table line"

# --------------------------------------------------------------------------- #
# The boot path's resize: a clean mount, the resize, the mount given back
# --------------------------------------------------------------------------- #
# The btrfs-progs in the image answers `ERROR: not a directory: /dev/vda4` for an
# unmounted device, so the resize needs a mount — one without compress=, discard= or
# subvol=, so a failing resize cannot be confused with an option interaction.

reset_fixture
: >"$WF_MOUNTS"
resize_mp="$tmp/mnt/p4resize"
resize_out="$(wf_grow_resize_mounted /dev/vda4 "${resize_mp}" /dev/vda 2>"$tmp/stderr.txt")"
assert_eq "${resize_out}" "done" "ac-3 the clean-mount resize reports done"
assert_contains "$(cat "$tmp/mount.calls")" "-t btrfs -o rw,noatime /dev/vda4 ${resize_mp}" \
  "ac-3 the resize pass mounts with no compress/discard/subvol options"
assert_eq "$(printf '%s' "$(cat "$tmp/mount.calls")" | grep -c 'compress=\|discard=\|subvol=')" "0" \
  "ac-3 the clean mount carries none of the option-carrying mount's flags"
assert_contains "$(cat "$tmp/btrfs.calls")" "filesystem resize max ${resize_mp}" \
  "ac-3 the resize runs against the clean mount point"
assert_contains "$(cat "$tmp/umount.calls")" "${resize_mp}" \
  "ac-3 the clean mount is given back"
assert_eq "$(awk -v mp="${resize_mp}" '$2 == mp { found = 1 } END { exit !found }' "$WF_MOUNTS"; echo $?)" \
  "1" "ac-3 nothing is left mounted after the resize pass"

# A clean mount that fails is a token, not a crash.
reset_fixture
: >"$WF_MOUNTS"
mount_fail="$(STUB_MOUNT_FAIL=1 wf_grow_resize_mounted /dev/vda4 "${resize_mp}" /dev/vda 2>&1)"
assert_contains "${mount_fail}" "fail:resize-mount" \
  "ac-3 a failed clean mount is recorded as fail:resize-mount"
assert_eq "$(printf '%s' "${mount_fail}" | grep -c 'filesystem resize')" "0" \
  "ac-3 no resize is attempted when the clean mount failed"

# A failing resize still gives the mount back and leaves the diagnostics behind.
reset_fixture
: >"$WF_MOUNTS"
resize_fail="$(WF_BTRFS="$tmp/bin/btrfs-noisy" wf_grow_resize_mounted \
  /dev/vda4 "${resize_mp}" /dev/vda 2>&1)"
assert_contains "${resize_fail}" "fail:btrfs-resize" "ac-3 a failed resize is recorded"
assert_contains "${resize_fail}" "[grow] diag btrfs --version:" \
  "ac-3 the btrfs version is logged with the failure"
assert_contains "${resize_fail}" "filesystem resize 1:max ${resize_mp}" \
  "ac-3 the explicit-devid retry is attempted"
assert_contains "${resize_fail}" "[grow] diag usage:" \
  "ac-3 the usage table is logged with the failure"
assert_contains "$(cat "$tmp/umount.calls")" "${resize_mp}" \
  "ac-3 the mount is given back even when the resize failed"

assert_eq "$(wf_grow_resize_mounted "" "${resize_mp}")" "fail:resize-target" \
  "ac-3 a resize pass without a device is refused"

# --------------------------------------------------------------------------- #
# 4Kn disks: sysfs counts 512-byte units, sfdisk counts logical sectors
# --------------------------------------------------------------------------- #
# A 4096-byte-sector disk reports `size` in 512-byte units and partition sizes in
# logical sectors, so a comparison that mixes the two is off by a factor of eight and
# reports fail:size-unchanged on a disk that grew perfectly.

reset_fixture
printf '4096\n' >"$sys/vda/queue/logical_block_size"
# 16384 logical sectors of 4096 bytes are 131072 sysfs units of 512 bytes.
printf '%s\n' 131072 >"$sys/vda4/size"
# The disk ends where this table's last usable LBA is, so the growth target comes from
# the table above and the case stays about the 512/4096 unit conversion.
# 115166 + 34 = 115200 logical sectors of 4096 bytes = 921600 sysfs units.
printf '%s\n' 921600 >"$sys/vda/size"
cat >"$tmp/table/current" <<'TABLE4K'
label: gpt
label-id: 4F2B1C3D-5E6F-7081-9203-A4B5C6D7E8F0
device: /dev/vda
unit: sectors
first-lba: 6
last-lba: 115166
sector-size: 4096

/dev/vda1 : start=         256, size=       32768, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=11111111-2222-3333-4444-555555555555, name="ab-esp"
/dev/vda2 : start=       33024, size=       32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=66666666-7777-8888-9999-AAAAAAAAAAAA, name="ab-slot-a"
/dev/vda3 : start=       65792, size=       32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF, name="ab-slot-b"
/dev/vda4 : start=       98560, size=       16384, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=12121212-3434-5656-7878-909090909090, name="ab-data"
TABLE4K
assert_eq "$(wf_grow_sector_size /dev/vda4)" "4096" \
  "ac-2 the logical block size of a 4Kn disk is the conversion unit"
assert_eq "$(wf_grow_sectors /dev/vda4)" "16384" \
  "ac-2 a partition size is reported in logical sectors, not in sysfs 512-byte units"
k4=$(wf_grow_run /dev/vda /dev/vda4 2>/dev/null)
assert_eq "$(wf_grow_alignment /dev/vda4)" "1" \
  "ac-2 a 4Kn disk needs no alignment: one logical sector is one sectorsize"
assert_eq "${k4}" "done 115166" \
  "ac-2 a 4Kn disk grows without a false fail:size-unchanged"
assert_eq "$(cat "$sys/vda4/size")" "$(( (115166 - 98560 + 1) * 8 ))" \
  "ac-2 the 4Kn partition really became the larger size"

# --------------------------------------------------------------------------- #
# The pre-growth partition table has to reach the disk, not just the initramfs
# --------------------------------------------------------------------------- #

reset_fixture
wf_grow_run /dev/vda /dev/vda4 >/dev/null 2>&1
backup_dir="$tmp/p4root-backup"
assert_command_ok "ac-2 the pre-growth table can be kept" wf_grow_backup "$backup_dir"
assert_file_exists "$backup_dir/.ab/partitions.before" \
  "ac-2 the table is kept at .ab/partitions.before"
assert_eq "$(cat "$backup_dir/.ab/partitions.before")" "$(table_for "${p4_shipped_size}")" \
  "ac-2 the kept table is the geometry from before the write, not the grown one"
assert_eq "$(ls -A "$backup_dir/.ab" | paste -sd, -)" "partitions.before" \
  "ac-2 no temporary file is left behind next to the backup"
assert_eq "$(cd "$tmp/work/grow" && wf_grow_backup "" >/dev/null 2>&1; echo $?)" "1" \
  "ac-2 a backup without a destination is refused"

# --------------------------------------------------------------------------- #
# The record: <p4 root subvolume>/.ab/grow, `result=<state> last_lba=<n>`
# --------------------------------------------------------------------------- #

record_dir="$tmp/p4root"
assert_command_ok "ac-4 the growth record can be written" wf_grow_record "$record_dir" done "${last_lba}"
assert_file_exists "$record_dir/.ab/grow" "ac-4 the record lives at .ab/grow"
assert_eq "$(cat "$record_dir/.ab/grow")" "result=done last_lba=${last_lba}" \
  "ac-4 the record is result=<state> last_lba=<n> on one line"
assert_matches "$(cat "$record_dir/.ab/grow")" '^result=[a-z:-]+ last_lba=[0-9]+$' \
  "ac-4 the record matches the documented shape"
assert_eq "$(ls -A "$record_dir/.ab" | paste -sd, -)" "grow" \
  "ac-4 no temporary file is left behind"

wf_grow_record "$record_dir" already-full "${last_lba}" >/dev/null 2>&1
assert_eq "$(cat "$record_dir/.ab/grow")" "result=already-full last_lba=${last_lba}" \
  "ac-4 a later boot overwrites the record instead of appending"
wf_grow_record "$record_dir" "fail:partition-table-write" "${last_lba}" >/dev/null 2>&1
assert_eq "$(cat "$record_dir/.ab/grow")" \
  "result=fail:partition-table-write last_lba=${last_lba}" \
  "ac-4 a failure token is recorded verbatim"
record_status=0
wf_grow_record "$record_dir" "" 0 >/dev/null 2>&1 || record_status=$?
assert_eq "${record_status}" "1" "ac-4 an empty state is refused instead of recorded"

# --------------------------------------------------------------------------- #
# Static contract of the boot init and the helper
# --------------------------------------------------------------------------- #

boot_init="$(cat "$root/initramfs/boot/init")"
grow_lib="$(cat "$root/initramfs/lib/grow.sh")"

assert_contains "$boot_init" ". /lib/grow.sh" "ac-5 the init sources the growth helper"
assert_contains "$boot_init" 'grow_line="$(wf_grow_run "${dev}" "${p4}")"' \
  "ac-5 growth runs against the resolved disk and p4"
assert_contains "$boot_init" "done | already-full | missing-sfdisk" \
  "ac-5 the init knows the four documented states"
assert_contains "$boot_init" "fail:?*" "ac-5 fail:<token> states are accepted as they are"
assert_contains "$boot_init" 'slot_a="$(di_find_partition ab-slot-a 2 "${dev}")" || slot_a=""' \
  "ac-5 the slot partitions are discovered on the resolved disk too"
assert_contains "$boot_init" '. /lib/disk-identity.sh' \
  "ac-5 the init loads the single device identity implementation"
assert_eq "$(printf '%s' "${boot_init}" | grep -c 'ab-shared')" "0" \
  "ac-5 the retired ab-shared PARTNAME is gone from the boot path"
assert_contains "$boot_init" \
  'mount -o rw,noatime,compress=zstd:6,discard=async,"subvol=/" "${p4}" /mnt/p4root' \
  "ac-4 the record is written on the p4 root subvolume, not in a generation layer"
assert_contains "$boot_init" "p4-partial" "ac-5 a failed subvolume mount is reported as p4-partial"

for spec in \
  '@data:/newroot/data:rw,noatime' \
  '@docker:/newroot/opt/docker:rw,noatime,nodatacow,nodatasum' \
  '@swap:/newroot/swap:rw,noatime,nodatacow,nodatasum'
do
  assert_contains "${boot_init}" "\"${spec}\"" "ac-5 the mount table carries ${spec}"
done
assert_eq "$(printf '%s' "${boot_init}" | sed -n 's/^ *"\(@[a-z]*:.*\)".*/\1/p' \
  | grep -c 'compress=')" "0" \
  "ac-5 no subvolume mount repeats a compress= level"
assert_contains "$boot_init" 'mkdir -p "${target}"' \
  "ac-5 the mount point is created before it is mounted"

# The mount table is written as "<subvolume>:<mount point>:<options>" and split by the
# init with the same parameter expansions; replaying them here proves the strings in the
# script really decode to the documented contract.
mount_plan=$(sed -n 's/^    "\(@[a-z]*:[^"]*\)".*/\1/p' "$root/initramfs/boot/init" | while read -r spec; do
  subvol="${spec%%:*}"
  rest="${spec#*:}"
  target="${rest%%:*}"
  options="${rest#*:}"
  printf '%s|%s|%s;' "${subvol}" "${target}" "${options}"
done)
assert_eq "${mount_plan}" \
  "@data|/newroot/data|rw,noatime;@docker|/newroot/opt/docker|rw,noatime,nodatacow,nodatasum;@swap|/newroot/swap|rw,noatime,nodatacow,nodatasum;" \
  "ac-5 the mount table decodes to the documented subvolume, mount point and options"
assert_contains "$boot_init" 'subvol=/${subvol}' "ac-5 each subvolume is mounted by name"

# Ordering: growth before the first p4 mount, and the overlay last. Comment lines are
# skipped so the header that describes the order cannot satisfy the check itself.
code_line_of() {
  printf '%s\n' "${boot_init}" \
    | awk -v pat="$1" '!/^[[:space:]]*#/ && index($0, pat) { print NR; exit }'
}
grow_line_no=$(code_line_of 'grow_line="$(wf_grow_run')
p4_mount_no=$(code_line_of 'subvol=/${upper}')
overlay_no=$(code_line_of 'lowerdir=/mnt/@platform:/mnt/@sys')
assert_eq "$((grow_line_no < p4_mount_no))" "1" \
  "ac-5 growth happens before the first p4 mount"
assert_eq "$((p4_mount_no < overlay_no))" "1" \
  "ac-5 the writable layer is mounted before the overlay is composed"
subvol_mount_no=$(code_line_of 'subvol=/${subvol}')
assert_eq "$((subvol_mount_no > overlay_no))" "1" \
  "ac-5 the user data subvolumes are mounted through the composed root"

# Growth must never be able to abort a boot: no failure exit in the helper, and the
# init's growth block does not call one either.
assert_eq "$(printf '%s' "${grow_lib}" | grep -c 'wf_fail')" "0" \
  "ac-3 the growth helper cannot abort a boot"
growth_block=$(printf '%s' "${boot_init}" | sed -n '/# 1. First-boot growth/,/# 2. State from the ESP/p')
assert_eq "$(printf '%s' "${growth_block}" | grep -c 'wf_fail')" "0" \
  "ac-3 the growth step in the init records instead of failing"
assert_contains "${grow_lib}" '"${wf_grecord_dir}/.ab/grow"' \
  "ac-4 the helper owns the .ab/grow path"

# The builder has to carry the helper and the tools into the boot initramfs; without it
# the growth step would report missing-sfdisk on every real disk.
builder="$(cat "$root/scripts/ci/initramfs.sh")"
assert_contains "${builder}" 'lib_dir="${CI_INITRAMFS_LIB_DIR-${CI_REPO_ROOT}/initramfs/lib}"' \
  "ac-5 the builder stages initramfs/lib by default"
assert_contains "${builder}" 'install -m 0644 "${lib}" "${stage}/lib/$(basename "${lib}")"' \
  "ac-5 every helper is installed into /lib of the initramfs"
assert_contains "${builder}" '*initramfs/boot/init) toolset="boot"' \
  "ac-2 the boot initramfs stages the locked boot toolset (relative paths select it too)"
assert_contains "$(cat "$root/scripts/ci/initramfs-tools.lock.json")" '"/usr/sbin/blkid"' \
  "ac-2 blkid travels with the boot initramfs, for the label-based identity fallback"
assert_contains "${builder}" 'missing /lib/ld-musl-x86_64.so.1' \
  "ac-3 a toolset without its loader fails the build instead of booting without /dev"
assert_contains "${builder}" 'initramfs-tools.sh" --toolset "${toolset}"' \
  "ac-2 the toolset is staged from the lockfile, not from the build host"

# --------------------------------------------------------------------------- #
# Device identity wiring (ac-7): no hard-coded boot disk anywhere on the path
# --------------------------------------------------------------------------- #

assert_eq "$(printf '%s' "${boot_init}" | grep -c 'DEV=/dev/vda')" "0" \
  "ac-7 the boot init no longer hard-codes /dev/vda"
assert_eq "$(printf '%s' "${boot_init}" | grep -c 'shared="${DEV}')" "0" \
  "ac-7 no partition node is built by gluing a digit onto a device name"
assert_contains "${boot_init}" 'identity="$(di_resolve)"' \
  "ac-7 the disk is resolved, not assumed"
assert_contains "${boot_init}" "stage=device disk=" \
  "ac-7 the resolution is reported with its method"
assert_contains "${boot_init}" 'grow_line="fail:${dev_error} 0"' \
  "ac-7 an unresolved disk is recorded as fail:<reason> and the table is left alone"
assert_contains "${boot_init}" 'if [ -n "${dev}" ] && [ -n "${p4}" ]; then' \
  "ac-7 growth only runs on a resolved disk with a data partition"
assert_contains "${boot_init}" 'esp="$(di_find_partition ab-esp 1 "${dev}")" || esp=""' \
  "ac-7 every partition lookup is scoped to the resolved disk"
assert_contains "${boot_init}" 'p4="$(di_find_partition ab-data 4 "${dev}")" || p4=""' \
  "ac-7 p4 comes from the resolved disk, not from a bare name match"

builder="$(cat "$root/scripts/ci/initramfs.sh")"
assert_contains "${builder}" 'platform/lib/disk-identity.sh' \
  "ac-7 the boot initramfs stages the shared identity library"
assert_contains "${builder}" 'cmp -s "${shared}" "${stage}/lib/$(basename "${shared}")"' \
  "ac-7 the staged library is compared with the source"
assert_contains "${builder}" '|| ci_die "staged $(basename "${shared}") differs' \
  "ac-7 a rewritten copy is a build failure"
assert_contains "$boot_init" 'wf_grow_backup /mnt/p4root' \
  "ac-2 the init keeps the pre-growth table on the p4 root subvolume"

# The p4 mount sequence: one mount for the resize and the upper, one short-lived mount
# for the growth record, and no leftover mount when the root is composed.
assert_contains "$boot_init" \
  'grow_fs="$(wf_grow_resize_mounted "${p4}" "${P4_RESIZE_MOUNT}" "${dev}")"' \
  "ac-3 the resize runs on a clean mount of p4"
assert_eq "$(printf '%s' "${boot_init}" | grep -c 'wf_grow_fs "${p4}"')" "0" \
  "ac-3 the device is never handed to btrfs-progs as a resize target"
assert_contains "$boot_init" 'P4_RESIZE_MOUNT=/mnt/p4resize' \
  "ac-3 the resize pass has its own mount point"
assert_contains "$boot_init" \
  'mount -o rw,noatime,compress=zstd:6,discard=async,"subvol=/" "${p4}" /mnt/p4root' \
  "ac-3 the record mount is the p4 root subvolume"

# The order is the fix for the EBUSY: exactly one mount while btrfs-progs resizes.
root_mount_line=$(code_line_of 'subvol=/" "${p4}" /mnt/p4root')
resize_line=$(code_line_of 'wf_grow_resize_mounted "${p4}"')
record_line=$(code_line_of 'wf_grow_record /mnt/p4root')
record_umount_line=$(code_line_of 'umount /mnt/p4root')
generation_mount_line=$(code_line_of 'subvol=/${upper}" "${p4}" /mnt/p4')
overlay_compose_line=$(code_line_of 'mount -t overlay overlay')
assert_eq "$((resize_line < root_mount_line))" "1" \
  "ac-3 the resize runs before the first mount of the filesystem"
assert_eq "$((resize_line < record_line))" "1" \
  "ac-3 the resize happens before the growth record is written"
assert_eq "$((record_line < record_umount_line))" "1" \
  "ac-3 the record is written before the mount is given back"
assert_eq "$((record_umount_line < generation_mount_line))" "1" \
  "ac-3 the generation mount happens only after the root subvolume is unmounted"
assert_eq "$((generation_mount_line < overlay_compose_line))" "1" \
  "ac-3 the generation layer is mounted before the overlay is composed"
assert_contains "$boot_init" 'umount /mnt/p4root failed, retrying once' \
  "ac-3 a busy record mount is retried instead of being ignored"
assert_contains "$boot_init" 'p4 root subvolume is still mounted at /mnt/p4root' \
  "ac-3 a leftover record mount is reported"
assert_contains "$boot_init" 'p4 step=resize target=${p4} state=' \
  "ac-3 the resize step names the device and says it is unmounted"
assert_contains "$boot_init" 'if [ "${degraded}" = "1" ]; then' \
  "ac-3 no p4 subvolume is mounted when p4 itself is degraded"

# --------------------------------------------------------------------------- #
# The guest assertion runs the same decision, so it must load the helper first and
# own a scratch directory: the initramfs has no /tmp, and a missing one silently
# skipped the whole check in CI.
# --------------------------------------------------------------------------- #

guest_assert="$(cat "$root/tests/modules/image/guest-assert.sh")"
assert_contains "${guest_assert}" 'mkdir -p /tmp' \
  "ac-2 the guest creates its scratch directory before writing a table"
assert_contains "${guest_assert}" '. /lib/grow.sh' \
  "ac-2 the guest sources the growth helper it calls"
assert_contains "${guest_assert}" 'GROW_LIB=loaded' \
  "ac-2 the guest records that the helper really loaded"
assert_contains "${guest_assert}" 'SKIP growth decision: /lib/grow.sh is missing or defines nothing' \
  "ac-2 a missing helper is reported as such, not blamed on sfdisk"
assert_contains "${guest_assert}" 'PARTUUID' \
  "ac-2 the guest cross-checks PARTUUIDs against ab/device.json"
assert_contains "${guest_assert}" 's#^${DEV}${part}[[:space:]]*:.*uuid=' \
  "ac-2 PARTUUID readback uses the sfdisk table, not only a blkid probe"
assert_contains "${guest_assert}" 'WARNING no PARTUUID for ${DEV}${part}' \
  "ac-2 an unreadable PARTUUID is a warning, not a red stage"

finish
