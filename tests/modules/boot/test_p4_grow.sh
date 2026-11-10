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
# Fixture disk: the 450 MiB image (921600 sectors) with p4 still at its shipped size
# --------------------------------------------------------------------------- #

sys="$tmp/sys/block"
mkdir -p "$sys/vda" "$tmp/work" "$tmp/bin" "$tmp/table"
# /sys/class/block/<part> is a symlink into the disk directory in the real kernel, which
# is what makes <part>/.. resolve to the disk. Mirroring that here keeps the sector-size
# lookup and the parent-disk derivation on the same code path as the device itself.
mkdir -p "$sys/vda/vda4"
printf '4\n' >"$sys/vda/vda4/partition"
printf 'DEVTYPE=partition\nDEVNAME=vda4\nPARTN=4\nPARTNAME=ab-data\n' >"$sys/vda/vda4/uevent"
ln -sfn "vda/vda4" "$sys/vda4"
disk_sectors=921600
last_lba=$((disk_sectors - 34))
p4_start=788480
p4_shipped_size=131072
p4_grown_size=$((last_lba - p4_start + 1))
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
/dev/vda4 : start=      788480, size=      $1, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=12121212-3434-5656-7878-909090909090, name="ab-data"
TABLE
}

reset_fixture() {
  table_for "${p4_shipped_size}" >"$tmp/table/current"
  rm -f "$tmp/table/written" "$tmp/sfdisk.calls" "$tmp/blockdev.calls" "$tmp/btrfs.calls"
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
WF_SYS_BLOCK="$sys"
WF_GROW_TMP="$tmp/work"
WF_GROW_VERIFY_TRIES=2
WF_MOUNTS="$tmp/mounts"
export WF_SFDISK WF_BLOCKDEV WF_PARTX WF_BTRFS WF_SLEEP WF_SYS_BLOCK WF_GROW_TMP \
  WF_GROW_VERIFY_TRIES WF_MOUNTS
mkdir -p "$tmp/mnt/p4"
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "$tmp/mnt/p4" >"$WF_MOUNTS"

reset_fixture

# --------------------------------------------------------------------------- #
# Decision: the whole idempotency rule, without touching a disk
# --------------------------------------------------------------------------- #

decision=$(wf_grow_decide "$tmp/table/current" /dev/vda4 "${disk_sectors}")
assert_eq "${decision}" "grow ${last_lba} ${p4_grown_size}" \
  "ac-1 a p4 short of the last usable LBA grows to it"

table_for "${p4_grown_size}" >"$tmp/table/grown"
assert_eq "$(wf_grow_decide "$tmp/table/grown" /dev/vda4 "${disk_sectors}")" \
  "already-full ${last_lba}" "ac-1 p4 already at the last usable LBA is already-full"

# One sector short of the end is still a grow, and the size never shrinks.
table_for "$((p4_grown_size - 1))" >"$tmp/table/short"
assert_eq "$(wf_grow_decide "$tmp/table/short" /dev/vda4 "${disk_sectors}")" \
  "grow ${last_lba} ${p4_grown_size}" "ac-1 a single sector of tail space still grows"
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

# wf_grow_fs is the post-mount half of the contract: the target is a MOUNT POINT, and a
# device path or an unmounted directory must never reach btrfs-progs.
reset_fixture
p4_mount="$tmp/mnt/p4"
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "${p4_mount}" >"$WF_MOUNTS"
assert_eq "$(wf_grow_fs "${p4_mount}")" "done" \
  "ac-3 btrfs filesystem resize max is reported as done"
assert_contains "$(cat "$tmp/btrfs.calls")" "filesystem resize max ${p4_mount}" \
  "ac-3 the resize is run against the p4 mount point"
assert_eq "$(STUB_BTRFS_FAIL=1 wf_grow_fs "${p4_mount}")" "fail:btrfs-resize" \
  "ac-3 a failed filesystem resize is recorded as fail:btrfs-resize"

# The device is not a resize target: btrfs would have no filesystem to name.
rm -f "$tmp/btrfs.calls"
assert_eq "$(wf_grow_fs /dev/vda4)" "fail:resize-target" \
  "ac-3 a device path is refused as a resize target"
assert_eq "$(wf_grow_fs /mnt/never-mounted)" "fail:resize-target" \
  "ac-3 an unmounted directory is refused as a resize target"
assert_eq "$(wf_grow_fs "")" "fail:resize-target" "ac-3 an empty target is refused"
assert_eq "$(cat "$tmp/btrfs.calls" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 no refused target ever reaches btrfs-progs"

# --------------------------------------------------------------------------- #
# 4Kn disks: sysfs counts 512-byte units, sfdisk counts logical sectors
# --------------------------------------------------------------------------- #
# A 4096-byte-sector disk reports `size` in 512-byte units and partition sizes in
# logical sectors, so a comparison that mixes the two is off by a factor of eight and
# reports fail:size-unchanged on a disk that grew perfectly.

reset_fixture
printf '4096\n' >"$sys/vda/queue/logical_block_size"
printf '%s\n' "${p4_shipped_size}" >"$sys/vda4/size"
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
assert_contains "$boot_init" 'mount -o rw,noatime,"subvol=/" "${p4}" /mnt/p4root' \
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
assert_contains "${builder}" \
  '*/initramfs/boot/init) CI_TOOL_BINARIES_OPTIONAL="sfdisk blockdev btrfs blkid"' \
  "ac-2 the boot initramfs defaults to sfdisk, blockdev, btrfs and blkid"
assert_contains "${builder}" 'blkid' \
  "ac-2 blkid travels with the boot initramfs, for the label-based identity fallback"
assert_contains "${builder}" 'ci_warn "optional tool not found in the build host, skipped: ${name}"' \
  "ac-3 a missing optional tool warns instead of failing the build"
assert_contains "${builder}" 'copy_tool "${tool_path}"' \
  "ac-2 the resolved optional tool is copied with its libraries"

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
assert_contains "$boot_init" 'grow_fs="$(wf_grow_fs /mnt/p4)"' \
  "ac-3 the resize is called with the mount point"
assert_eq "$(printf '%s' "${boot_init}" | grep -c 'wf_grow_fs "${p4}"')" "0" \
  "ac-3 the device is never passed as a resize target"
assert_contains "$boot_init" 'mount -o rw,noatime,"subvol=/" "${p4}" /mnt/p4root' \
  "ac-3 the record mount is the p4 root subvolume"
record_mount_line=$(code_line_of 'subvol=/" "${p4}" /mnt/p4root')
record_umount_line=$(code_line_of 'umount /mnt/p4root')
overlay_compose_line=$(code_line_of 'mount -t overlay overlay')
assert_eq "$((record_umount_line < overlay_compose_line))" "1" \
  "ac-3 the record mount is given back before the overlay is composed"
assert_contains "$boot_init" 'umount /mnt/p4root failed, retrying once' \
  "ac-3 a busy record mount is retried instead of being ignored"
assert_contains "$boot_init" 'p4 root subvolume is still mounted at /mnt/p4root' \
  "ac-3 a leftover record mount is reported"
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
