#!/usr/bin/env bash
# Module: boot
# Drives the first-boot growth of p4 from fixture partition tables, so the whole state
# machine is verified on a machine with no loop device, no btrfs and no root:
#   ac-1 the growth never re-reads the partition table: no --rereadpt, no partx, and no
#        blockdev call at all while sysfs answers the size; the decision only depends on
#        the table (p4 short of the last usable LBA grows, p4 at it is already-full)
#   ac-2 the first boot writes the table with --no-reread, changes nothing but the p4
#        size, re-dumps the table to prove the write landed, records `table-written` and
#        asks for exactly one controlled reboot - after the record is on disk
#   ac-3 the boot after the reboot only runs `btrfs filesystem resize max` (no table
#        write at all) and records `done`; the kernel sees the new size because the
#        reboot made it re-read the table
#   ac-4 the third boot is the steady state: `already-full`, no write, no reboot; a record
#        written by the one-phase firmware is still understood, and a `table-written`
#        record with a table that is still short (the write was lost) refuses to loop
#   ac-5 every stage leaves its own evidence on p4: `table-write-pending` before the
#        write, `table-written` after it, `done`/`already-full` later, an append-only
#        grow.log line per record, and no temporary file left behind
#   ac-6 every failure is a recorded token and never a boot failure: a refused write, a
#        write the re-dump cannot see, an unsupported or failing verify, a reboot that
#        returns, and a failed filesystem resize
#   ac-7 the pre-change table is kept at <p4 root subvolume>/.ab/partitions.before, only
#        the p4 size may differ in the written table, and the backup is byte-identical
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
  rm -f "$tmp/table/written" "$tmp/sfdisk.calls" "$tmp/blockdev.calls" \
    "$tmp/btrfs.calls" "$tmp/mount.calls" "$tmp/umount.calls" "$tmp/reboot.calls" \
    "$tmp/sync.calls"
  printf '%s\n' "${p4_shipped_size}" >"$sys/vda4/size"
}

# --------------------------------------------------------------------------- #
# Command fixtures: sfdisk, blockdev, btrfs, mount, umount, reboot and sync,
# all recorded. None of them is a real tool: the state machine is driven from the fixture
# table, and every call a stage makes is counted - "the table write never asks the kernel
# to re-read" is only believable if the counters say so.
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
    # STUB_NO_SIZE_CHANGE models a write that never reaches the medium: the command
    # succeeds, the dump afterwards still shows the old table.
    if [ "${STUB_NO_SIZE_CHANGE:-0}" != "1" ]; then
      cp "${GROW_FIXTURE}/table/written" "${GROW_FIXTURE}/table/current"
    fi
    ;;
  --verify)
    [ "${STUB_VERIFY_FAIL:-0}" = "1" ] && { echo "The backup GPT table is corrupt." >&2; exit 1; }
    if [ "${STUB_VERIFY_UNSUPPORTED:-0}" = "1" ]; then
      echo "sfdisk: unrecognized option '--verify'" >&2
      exit 1
    fi
    exit 0
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
    # Recorded so the test can prove it is never called: the re-read is the reboot's job.
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

cat >"$tmp/bin/btrfs" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/btrfs.calls"
[ "${STUB_BTRFS_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB

cat >"$tmp/bin/mount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/mount.calls"
[ "${STUB_MOUNT_FAIL:-0}" = "1" ] && exit 1
# The only form the boot path uses: -t btrfs -o <opts> <device> <mount point>
printf '%s %s btrfs rw,noatime 0 0\n' "$5" "$6" >>"${WF_MOUNTS}"
STUB
cat >"$tmp/bin/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/umount.calls"
mp="$1"
{ grep -v " ${mp} " "${WF_MOUNTS}" 2>/dev/null || :; } >"${WF_MOUNTS}.new"
mv "${WF_MOUNTS}.new" "${WF_MOUNTS}"
exit 0
STUB

# probe: what the kernel does before any of our code runs - read the GPT and create the p4
# node with the size the table names. Called between boots, which is how the second boot
# sees the grown device without a single reread ioctl.
cat >"$tmp/bin/probe" <<'STUB'
#!/bin/sh
size="$(sed -n 's|^/dev/vda4 : start= *[0-9]*, size= *\([0-9]*\).*|\1|p' "${GROW_FIXTURE}/table/current")"
case "${size}" in '' | *[!0-9]*) exit 1 ;; esac
lbs="$(cat "${GROW_FIXTURE}/sys/block/vda/queue/logical_block_size" 2>/dev/null)"
case "${lbs}" in '' | *[!0-9]*) lbs=512 ;; esac
printf '%s\n' "$(( size * lbs / 512 ))" >"${GROW_FIXTURE}/sys/block/vda4/size"
exit 0
STUB

# reboot: counted with the record it was asked for (so "after the record was on disk" is
# measurable), and it makes the kernel read the table again - what the second boot sees.
cat >"$tmp/bin/reboot" <<'STUB'
#!/bin/sh
printf 'reboot %s\n' "$*" >>"${GROW_FIXTURE}/reboot.calls"
cat "${GROW_FIXTURE}/p4root/.ab/grow" >>"${GROW_FIXTURE}/reboot.calls" 2>/dev/null || :
if [ "${STUB_REBOOT_FAIL:-0}" = "1" ]; then exit 1; fi
"${GROW_FIXTURE}/bin/probe" || exit 1
exit 0
STUB

printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/sleep"
cat >"$tmp/bin/sync" <<'STUB'
#!/bin/sh
printf 'sync\n' >>"${GROW_FIXTURE}/sync.calls"
exit 0
STUB
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
WF_BTRFS="$tmp/bin/btrfs"
WF_SLEEP="$tmp/bin/sleep"
WF_MOUNT="$tmp/bin/mount"
WF_UMOUNT="$tmp/bin/umount"
WF_REBOOT="$tmp/bin/reboot"
WF_SYNC_CMD="$tmp/bin/sync"
WF_SYS_BLOCK="$sys"
WF_GROW_TMP="$tmp/work"
WF_MOUNTS="$tmp/mounts"
export WF_SFDISK WF_BLOCKDEV WF_BTRFS WF_SLEEP WF_SYS_BLOCK WF_GROW_TMP \
  WF_MOUNTS WF_MOUNT WF_UMOUNT WF_REBOOT WF_SYNC_CMD
mkdir -p "$tmp/mnt/p4"
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "$tmp/mnt/p4" >"$WF_MOUNTS"

# calls <tool>: what that stub was asked to do, in order.
calls() { cat "$tmp/$1.calls" 2>/dev/null || :; }
# count_lines <tool>: how many lines the stub recorded (0 when it was never called).
count_lines() { cat "$tmp/$1.calls" 2>/dev/null | grep -c . || :; }
# count_calls <tool> <pattern>: how many of those lines match.
count_calls() { printf '%s\n' "$(calls "$1")" | grep -c -- "$2" 2>/dev/null || :; }


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
# Two boots: boot 1 writes the table and reboots, boot 2 grows the filesystem,
# boot 3 is the steady state
# --------------------------------------------------------------------------- #
# init's own sequence is: plan (no mount) -> mount the root subvolume and write the
# write-ahead breadcrumb -> give it back -> write the table -> mount again, record the
# outcome and reboot. Each step is a function below, so the test drives exactly the calls
# a real boot makes - including the one thing a unit test cannot do, the reboot, which the
# stub turns into "the kernel reads the table again".

record="$tmp/p4root"
rm -rf "${record}"
mkdir -p "${record}"
WF_GROW_LOG_FILE="$tmp/work/grow.log"
export WF_GROW_LOG_FILE
: >"${WF_GROW_LOG_FILE}"

reset_fixture
plan="$(wf_grow_plan /dev/vda /dev/vda4 2>/dev/null)"
assert_eq "${plan}" "grow ${last_lba} ${p4_grown_size}" \
  "ac-2 the first boot plans the growth"
assert_eq "$(printf '%s\n' "${plan}" | wc -l | tr -d ' ')" "1" \
  "ac-2 the plan is exactly one line"
assert_file_exists "$tmp/work/grow/partitions.before" \
  "ac-7 the pre-change table is dumped before anything is written"
assert_eq "$(cat "$sys/vda4/size")" "${p4_shipped_size}" \
  "ac-1 planning the growth does not touch the device"

# Stage 1a: the write-ahead breadcrumb. It is the only durable fact a panic in the write
# window can leave, which is the evidence the first-boot incident had none of.
assert_command_ok "ac-5 the write-ahead breadcrumb can be written" \
  wf_grow_stage1_prepare "${record}" "${last_lba}"
assert_eq "$(cat "${record}/.ab/grow")" "result=table-write-pending last_lba=${last_lba}" \
  "ac-5 the stage-1 breadcrumb says a table write is in flight"
assert_eq "$(cat "${record}/.ab/partitions.before")" "$(table_for "${p4_shipped_size}")" \
  "ac-7 the kept table is the geometry from before the write"
assert_eq "$(cat "${WF_GROW_LOG_FILE}")" "" \
  "ac-5 the buffer is emptied once its lines are on p4"
assert_contains "$(cat "${record}/.ab/grow.log" 2>/dev/null)" "record result=table-write-pending" \
  "ac-5 the record itself is logged on the p4 side"

# Stage 1b: the table itself. No mount is live here and nothing asks the kernel to re-read.
written="$(wf_grow_write_table /dev/vda /dev/vda4 "${p4_grown_size}" \
  "$tmp/work/grow/partitions.before" "${last_lba}" 2>/dev/null)"
assert_eq "${written}" "written" "ac-2 the table write reports written"
assert_contains "$(cat "$tmp/sfdisk.calls")" "--no-reread /dev/vda" \
  "ac-2 the table is written back with --no-reread"
assert_eq "$(cat "$sys/vda4/size")" "${p4_shipped_size}" \
  "ac-1 the kernel keeps the old size: the re-read is the reboot, not this boot"
assert_eq "$(count_lines blockdev)" "0" \
  "ac-1 no blockdev call at all while sysfs answers the device size"
# Comments may name the retired ioctl - that is how the removal stays explained - so the
# check is on the code lines only: there is no partx call site left to count.
grow_code="$(sed -n '/^[[:space:]]*#/!p' "$root/initramfs/lib/grow.sh")"
assert_eq "$(printf '%s\n' "${grow_code}" | grep -c -- 'rereadpt' || :)" "0" \
  "ac-1 the helper contains no table re-read at all"
assert_eq "$(printf '%s\n' "${grow_code}" | grep -c -- 'partx' || :)" "0" \
  "ac-1 the partx fallback is gone, not merely unused"
assert_contains "$(cat "$tmp/sfdisk.calls")" "--verify /dev/vda" \
  "ac-7 the written table is verified before the reboot"

# Only the p4 size may differ from the pre-write table.
grep -v '^/dev/vda4 :' "$tmp/table/current" >"$tmp/table/others.after"
table_for "${p4_shipped_size}" | grep -v '^/dev/vda4 :' >"$tmp/table/others.before"
assert_eq "$(diff -u "$tmp/table/others.before" "$tmp/table/others.after" >/dev/null 2>&1; echo $?)" \
  "0" "ac-7 every non-p4 table line is written back unchanged"
assert_eq "$(sed -n 's|^/dev/vda4 : start= *\([0-9]*\), size= *\([0-9]*\).*|\1 \2|p' "$tmp/table/current")" \
  "${p4_start} ${p4_grown_size}" "ac-7 p4 keeps its start and only its size changed"
assert_eq "$(sed -n 's|^/dev/vda4 :.*name="\([^"]*\)".*|\1|p' "$tmp/table/current")" \
  "ab-data" "ac-7 the p4 partition name survives the rewrite"

# Stage 1c, in the three steps init takes: record the outcome, give the mount back through
# the one release path, and only then reboot. Splitting them is what keeps the release the
# only way a mount is ever given back.
staged="$(wf_grow_record_stage1 "${record}" "${last_lba}" "${written}" 2>/dev/null)"
assert_eq "${staged}" "table-written" \
  "ac-2 the outcome of a verified write is recorded as table-written"
assert_eq "$(cat "${record}/.ab/grow")" "result=table-written last_lba=${last_lba}" \
  "ac-2 the record says the table was written"
assert_eq "$(count_calls reboot '-f')" "0" \
  "ac-2 recording the outcome does not reboot by itself"
assert_command_ok "ac-2 a verified table is the state that reboots" \
  wf_grow_should_reboot "${staged}"
assert_eq "$( ( wf_grow_should_reboot fail:partition-table-write ); echo $? )" "1" \
  "ac-6 a failure token never reboots"
"$WF_UMOUNT" "${record}" >/dev/null 2>&1 || :
wf_grow_reboot 2>/dev/null || :
assert_eq "$(count_calls reboot '-f')" "1" "ac-2 exactly one reboot request"
assert_contains "$(calls reboot)" "result=table-written" \
  "ac-2 the reboot was issued after the record was on disk"
assert_contains "$(calls umount)" "${record}" \
  "ac-2 the root subvolume is given back before the reboot"
assert_eq "$(count_lines sync)" "2" "ac-2 the writes are flushed before the reset"
assert_eq "$(cat "$sys/vda4/size")" "${p4_grown_size}" \
  "ac-3 after the reboot the kernel reports the grown p4"
assert_contains "$(cat "${record}/.ab/grow.log")" "record result=table-written" \
  "ac-5 the stage-1 outcome is in the append-only log"

# Boot 2: the kernel read the table, so nothing of this boot may write it again.
writes_before="$(count_calls sfdisk '--no-reread')"
plan2="$(wf_grow_plan /dev/vda /dev/vda4 2>/dev/null)"
assert_eq "${plan2}" "already-full ${last_lba}" \
  "ac-3 the boot after the reboot has nothing left to write"
assert_eq "$(count_calls sfdisk '--no-reread')" "${writes_before}" \
  "ac-3 the second boot does not write the table again"
prev="$(wf_grow_record_state "${record}/.ab/grow")"
assert_eq "${prev}" "table-written ${last_lba}" \
  "ac-4 the record is parsed back into state and last_lba"
: >"$WF_MOUNTS"
resize="$(wf_grow_resize_mounted /dev/vda4 "$tmp/mnt/p4resize" /dev/vda 2>/dev/null)"
assert_eq "${resize}" "done" "ac-3 the second boot resizes the filesystem"
assert_contains "$(calls btrfs)" "filesystem resize max $tmp/mnt/p4resize" \
  "ac-3 the resize runs on the clean mount"
token="$(wf_grow_finalize already-full "${last_lba}" "${resize}" "${prev%% *}" "${prev##* }")"
assert_eq "${token}" "done" "ac-3 the boot that resized the filesystem records done"
assert_command_ok "ac-3 the outcome is recorded on p4" \
  wf_grow_record "${record}" "${token}" "${last_lba}"
assert_eq "$(cat "${record}/.ab/grow")" "result=done last_lba=${last_lba}" \
  "ac-4 the record keeps the single-line result=<state> last_lba=<n> shape"
wf_grow_flush_log "${record}" || true
assert_eq "$(cat "${WF_GROW_LOG_FILE}")" "" "ac-5 the second boot's lines are on p4 too"
assert_contains "$(cat "${record}/.ab/grow.log")" "record result=done" \
  "ac-5 the second boot's record joined the append-only log"

# Boot 3: the steady state. The table is full and the record already says so.
prev2="$(wf_grow_record_state "${record}/.ab/grow")"
token3="$(wf_grow_finalize already-full "${last_lba}" done "${prev2%% *}" "${prev2##* }")"
assert_eq "${token3}" "already-full" "ac-4 the third boot is the steady state"
assert_eq "$(count_calls reboot '-f')" "1" "ac-4 the steady state asks for no reboot"
assert_eq "$(count_calls sfdisk '--no-reread')" "${writes_before}" \
  "ac-4 the steady state writes the table a total of once"

# --------------------------------------------------------------------------- #
# Records written by other builds, and the write that was lost
# --------------------------------------------------------------------------- #

mkdir -p "$tmp/legacy/.ab"
legacy="$tmp/legacy/.ab/grow"
printf 'result=done last_lba=%s\n' "${last_lba}" >"${legacy}"
assert_eq "$(wf_grow_record_state "${legacy}")" "done ${last_lba}" \
  "ac-4 a done record of the one-phase firmware is understood"
assert_eq "$(wf_grow_finalize already-full "${last_lba}" done done "${last_lba}")" \
  "already-full" "ac-4 a machine the old firmware grew is already-full on the first new boot"
printf 'result=already-full last_lba=%s\n' "${last_lba}" >"${legacy}"
assert_eq "$(wf_grow_record_state "${legacy}")" "already-full ${last_lba}" \
  "ac-4 an already-full record is understood"
printf 'result=fail:partition-table-reread last_lba=%s\n' "${last_lba}" >"${legacy}"
assert_eq "$(wf_grow_record_state "${legacy}")" "fail:partition-table-reread ${last_lba}" \
  "ac-4 a retired failure token is still readable"
printf 'result=done\n' >"${legacy}"
assert_eq "$(wf_grow_record_state "${legacy}")" "done 0" \
  "ac-4 a record without last_lba is readable instead of fatal"
rm -f "${legacy}"
assert_eq "$(wf_grow_record_state "${legacy}")" "missing 0" \
  "ac-4 a missing record is a state of its own, not an error"
assert_eq "$(wf_grow_finalize already-full "${last_lba}" done missing 0)" "done" \
  "ac-4 without a record the resize result is what gets recorded"

assert_eq "$( ( wf_grow_steady done "${last_lba}" "${last_lba}" ); echo $? )" "0" \
  "ac-4 a done record at the same disk end is the steady state"
assert_eq "$( ( wf_grow_steady done 100 "${last_lba}" ); echo $? )" "1" \
  "ac-4 a disk that grew since is grown again"
assert_eq "$( ( wf_grow_steady done 0 "${last_lba}" ); echo $? )" "1" \
  "ac-4 a record without a disk end proves nothing"
assert_eq "$( ( wf_grow_steady fail:table-verify "${last_lba}" "${last_lba}" ); echo $? )" "1" \
  "ac-4 a failure token is never the steady state"

assert_eq "$(wf_grow_guard table-written "${last_lba}" "${last_lba}")" "refuse" \
  "ac-4 a verified write that is not on the disk refuses to write again"
assert_eq "$(wf_grow_guard fail:table-write-lost "${last_lba}" "${last_lba}")" "refuse" \
  "ac-4 the refusal survives the record that boot writes itself"
assert_eq "$(wf_grow_guard fail:table-write-lost 100 "${last_lba}")" "write" \
  "ac-4 ... but not on another disk end"
assert_eq "$(wf_grow_guard table-write-pending "${last_lba}" "${last_lba}")" "write" \
  "ac-4 an in-flight write is what a retry is for"
assert_eq "$(wf_grow_guard done "${last_lba}" "${last_lba}")" "write" \
  "ac-4 a done record proves nothing about the table"
assert_eq "$(wf_grow_guard missing 0 "${last_lba}")" "write" \
  "ac-4 no record at all is the normal first boot"
assert_eq "$(wf_grow_guard table-written 100 "${last_lba}")" "write" \
  "ac-4 a record about another disk end does not block this one"
# A steady record must not launder an unrelated plan into `already-full`: only the
# already-full plan has a done/already-full label to decide.
assert_eq "$(wf_grow_finalize missing-sfdisk "${last_lba}" done done "${last_lba}")" \
  "missing-sfdisk" "ac-4 a steady record does not turn missing-sfdisk into already-full"
assert_eq "$(wf_grow_finalize fail:table-write-lost "${last_lba}" done done "${last_lba}")" \
  "fail:table-write-lost" "ac-4 ... nor a lost write into already-full"
assert_eq "$(wf_grow_finalize already-full "${last_lba}" "" done "${last_lba}")" "already-full" \
  "ac-4 and the already-full plan does get the steady label"

# The soft loop the refusal exists for, boot by boot: the refusal overwrites the record with
# a token that the next boot must still refuse, or every second boot writes and reboots.
sim="$tmp/loop"
mkdir -p "${sim}/.ab"
printf 'result=table-written last_lba=%s\n' "${last_lba}" >"${sim}/.ab/grow"
sim_state="$(wf_grow_record_state "${sim}/.ab/grow")"
assert_eq "$(wf_grow_guard "${sim_state%% *}" "${sim_state##* }" "${last_lba}")" "refuse" \
  "ac-4 the boot after a verified-but-lost write refuses to write"
wf_grow_record "${sim}" fail:table-write-lost "${last_lba}" >/dev/null 2>&1
sim_state="$(wf_grow_record_state "${sim}/.ab/grow")"
assert_eq "${sim_state}" "fail:table-write-lost ${last_lba}" \
  "ac-4 the refusing boot overwrites the record with its own token"
assert_eq "$(wf_grow_guard "${sim_state%% *}" "${sim_state##* }" "${last_lba}")" "refuse" \
  "ac-4 ... and the boot after that refuses again: no write/reboot loop"

# --------------------------------------------------------------------------- #
# Failures: every one of them is a token, and none of them reboots
# --------------------------------------------------------------------------- #

fail_record="$tmp/fail-record"

# <state>: a fresh fixture whose dump and write-ahead breadcrumb exist, so each failure
# below starts from the same place a real boot does.
fail_setup() {
  reset_fixture
  rm -rf "${fail_record}"
  mkdir -p "${fail_record}"
  wf_grow_plan /dev/vda /dev/vda4 >/dev/null 2>&1
  wf_grow_stage1_prepare "${fail_record}" "${last_lba}" >/dev/null 2>&1
}
fail_write() {
  wf_grow_write_table /dev/vda /dev/vda4 "${p4_grown_size}" \
    "$tmp/work/grow/partitions.before" "${last_lba}"
}

fail_setup
write_fail="$(STUB_WRITE_FAIL=1 fail_write 2>/dev/null)"
assert_eq "${write_fail}" "fail:partition-table-write" \
  "ac-6 a refused table write is a token"
assert_eq "$(cat "$sys/vda4/size")" "${p4_shipped_size}" \
  "ac-6 a refused write leaves the device size alone"
out_fail="$(wf_grow_record_stage1 "${fail_record}" "${last_lba}" "${write_fail}" 2>/dev/null)"
assert_eq "${out_fail}" "${write_fail}" \
  "ac-6 the failure is recorded, under its own token"
assert_eq "$( ( wf_grow_should_reboot "${out_fail}" ); echo $? )" "1" \
  "ac-6 ... and a failure token asks for no reboot"
assert_eq "$(cat "${fail_record}/.ab/grow")" \
  "result=${write_fail} last_lba=${last_lba}" "ac-6 the failure is on the p4 side"
assert_eq "$(count_calls reboot '-f')" "0" "ac-6 a failed write never reboots"

# The other half of what killed the machine: writing the table while the root subvolume is
# still mounted. init checks the release's return code and the helper refuses as well, so a
# failed umount can never be followed by `sfdisk`.
fail_setup
printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "${fail_record}" >"$WF_MOUNTS"
: >"$tmp/sfdisk.calls"
mounted_write="$(wf_grow_write_table /dev/vda /dev/vda4 "${p4_grown_size}" \
  "$tmp/work/grow/partitions.before" "${last_lba}" "${fail_record}" 2>/dev/null)"
assert_eq "${mounted_write}" "fail:p4-still-mounted" \
  "ac-6 a root subvolume that is still mounted blocks the table write"
assert_eq "$(count_calls sfdisk '--no-reread')" "0" \
  "ac-6 ... so sfdisk is never called with p4 still mounted"
: >"$WF_MOUNTS"

fail_setup
not_written="$(STUB_NO_SIZE_CHANGE=1 fail_write 2>/dev/null)"
assert_eq "${not_written}" "fail:table-write-not-verified" \
  "ac-6 a write the re-dump cannot see is not believed"

fail_setup
verify_fail="$(STUB_VERIFY_FAIL=1 fail_write 2>/dev/null)"
assert_eq "${verify_fail}" "fail:table-verify" \
  "ac-6 a table that does not verify is a token"

fail_setup
unsupported="$(STUB_VERIFY_UNSUPPORTED=1 fail_write 2>"$tmp/stderr.txt")"
assert_eq "${unsupported}" "written" \
  "ac-7 an sfdisk without --verify does not stop the growth"
assert_contains "$(cat "$tmp/stderr.txt")" "verify=unsupported" \
  "ac-7 the missing verify option is recorded instead of guessed"

fail_setup
dump_fail="$(STUB_DUMP_FAIL=1 wf_grow_plan /dev/vda /dev/vda4 2>/dev/null)"
assert_eq "${dump_fail}" "fail:partition-table-read 0" \
  "ac-6 an unreadable table is recorded as fail:partition-table-read"

reset_fixture
missing="$(WF_SFDISK="$tmp/bin/absent-sfdisk" wf_grow_plan /dev/vda /dev/vda4 2>/dev/null)"
assert_eq "${missing}" "missing-sfdisk 0" \
  "ac-6 a boot initramfs without sfdisk reports missing-sfdisk"
assert_eq "$(cat "$tmp/table/current")" "$(table_for "${p4_shipped_size}")" \
  "ac-6 missing-sfdisk leaves the partition table untouched"

assert_eq "$(count_calls reboot '-f')" "0" "ac-6 no failure above asked for a reboot"

# A reboot that comes back: the record stays (it is true), and the boot continues on the
# old geometry instead of pretending the kernel saw the new table.
fail_setup
written_ok="$(fail_write 2>/dev/null)"
assert_eq "${written_ok}" "written" "ac-6 the write itself succeeded"
recorded_ok="$(wf_grow_record_stage1 "${fail_record}" "${last_lba}" "${written_ok}" 2>/dev/null)"
assert_eq "${recorded_ok}" "table-written" "ac-6 the verified write is recorded first"
"$WF_UMOUNT" "${fail_record}" >/dev/null 2>&1 || :
reboot_back="$(STUB_REBOOT_FAIL=1 wf_grow_reboot 2>"$tmp/stderr.txt"; echo "rc=$?")"
assert_contains "${reboot_back}" "rc=1" "ac-6 a reboot that fails reports its status"
assert_eq "$(cat "${fail_record}/.ab/grow")" "result=table-written last_lba=${last_lba}" \
  "ac-6 the record stays truthful when the reboot returns"
assert_contains "$(cat "$tmp/stderr.txt")" "continues on the old geometry" \
  "ac-6 a reboot that returned is logged as such"

# The resize failures carry their own tokens, and neither turns into a reboot.
assert_eq "$(wf_grow_finalize already-full "${last_lba}" fail:btrfs-resize done "${last_lba}")" \
  "fail:btrfs-resize" "ac-6 a failed filesystem resize is recorded"
assert_eq "$(wf_grow_finalize already-full "${last_lba}" fail:resize-mount missing 0)" \
  "fail:resize-mount" "ac-6 a failed clean mount is recorded"
assert_eq "$(count_calls reboot '-f')" "1" \
  "ac-6 only the reboot-that-returned case ever asked for one"

# Nothing in the helper may end a boot: it records and returns.
grow_lib="$(cat "$root/initramfs/lib/grow.sh")"
assert_eq "$(printf '%s' "${grow_lib}" | grep -c 'wf_fail')" "0" \
  "ac-6 the growth helper cannot abort a boot"
assert_eq "$(printf '%s' "${grow_lib}" | grep -c 'poweroff')" "0" \
  "ac-6 the growth helper cannot power the machine off"

# --------------------------------------------------------------------------- #
# The record: <p4 root subvolume>/.ab/grow, `result=<state> last_lba=<n>`
# --------------------------------------------------------------------------- #

record_dir="$tmp/p4root-record"
assert_command_ok "ac-5 the growth record can be written" wf_grow_record "${record_dir}" done "${last_lba}"
assert_file_exists "${record_dir}/.ab/grow" "ac-5 the record lives at .ab/grow"
assert_eq "$(cat "${record_dir}/.ab/grow")" "result=done last_lba=${last_lba}" \
  "ac-5 the record is result=<state> last_lba=<n> on one line"
assert_matches "$(cat "${record_dir}/.ab/grow")" '^result=[a-z:-]+ last_lba=[0-9]+$' \
  "ac-5 the record matches the documented shape"
assert_eq "$(ls -A "${record_dir}/.ab" | paste -sd, -)" "grow" \
  "ac-5 no temporary file is left behind"

for shape in table-write-pending table-written already-full fail:table-write-not-verified; do
  wf_grow_record "${record_dir}" "${shape}" "${last_lba}" >/dev/null 2>&1
  assert_matches "$(cat "${record_dir}/.ab/grow")" '^result=[a-z:-]+ last_lba=[0-9]+$' \
    "ac-5 the ${shape} token fits the one-line record shape"
done

wf_grow_record "${record_dir}" already-full "${last_lba}" >/dev/null 2>&1
assert_eq "$(cat "${record_dir}/.ab/grow")" "result=already-full last_lba=${last_lba}" \
  "ac-5 a later boot overwrites the record instead of appending"
record_status=0
wf_grow_record "${record_dir}" "" 0 >/dev/null 2>&1 || record_status=$?
assert_eq "${record_status}" "1" "ac-5 an empty state is refused instead of recorded"
assert_eq "$( ( wf_grow_stage1_prepare "" "${last_lba}" ) >/dev/null 2>&1; echo $? )" "1" \
  "ac-5 a write-ahead breadcrumb without a mount point is refused"

# --------------------------------------------------------------------------- #
# Static contract of the boot init and the helper
# --------------------------------------------------------------------------- #

boot_init="$(cat "$root/initramfs/boot/init")"
grow_lib="$(cat "$root/initramfs/lib/grow.sh")"

assert_contains "${boot_init}" ". /lib/grow.sh" "ac-2 the init sources the growth helper"
assert_contains "${boot_init}" 'grow_plan="$(wf_grow_plan "${dev}" "${p4}")"' \
  "ac-2 growth is planned against the resolved disk and p4"
assert_contains "${boot_init}" "already-full | missing-sfdisk)" \
  "ac-2 the init knows the planned states"
# `grow <lba> <size>` has three fields: taking the last one as the disk end would record the
# new size as a LBA, so the middle field is read explicitly and the test pins that.
assert_contains "${boot_init}" 'grow_last_lba="${grow_plan_rest%% *}"' \
  "ac-2 the disk end is the middle field of a growth plan, not the last"
assert_contains "${boot_init}" "fail:?*" "ac-2 fail:<token> plans are accepted as they are"
assert_contains "${boot_init}" 'wf_grow_stage1_prepare /mnt/p4root' \
  "ac-5 the write-ahead breadcrumb goes to the p4 root subvolume"
assert_contains "${boot_init}" 'wf_grow_record_stage1 /mnt/p4root' \
  "ac-2 the outcome is recorded there"
assert_contains "${boot_init}" 'wf_grow_write_table "${dev}" "${p4}"' \
  "ac-2 the table is written by the helper, with no mount live"
assert_contains "${boot_init}" '"${grow_last_lba}" "/mnt/p4root")' \
  "ac-6 the table write is told which mount point has to be free"
assert_contains "${boot_init}" 'if ! wf_p4root_release; then' \
  "ac-6 a release that fails stops the write window instead of being ignored"
assert_eq "$(printf '%s\n' "${boot_init}" | grep -c 'wf_grow_reboot')" "1" \
  "ac-2 the reboot has exactly one call site"
assert_contains "${boot_init}" "wf_grow_guard" \
  "ac-4 the init asks whether the last write is on the disk before writing again"
assert_contains "${boot_init}" "wf_p4root_mount()" \
  "ac-8 the root subvolume has one mount helper"
assert_contains "${boot_init}" "wf_p4root_release()" \
  "ac-8 and one release helper"
assert_eq "$(printf '%s\n' "${boot_init}" | grep -c 'subvol=/"')" "1" \
  "ac-8 the root subvolume is named in exactly one place"
boot_code="$(printf '%s\n' "${boot_init}" | sed -n '/^[[:space:]]*#/!p')"
assert_eq "$(printf '%s\n' "${boot_code}" | grep -c -- '--rereadpt' || :)" "0" \
  "ac-1 the init never asks the kernel to re-read the table"
assert_eq "$(printf '%s\n' "${boot_code}" | grep -c -- 'partx' || :)" "0" \
  "ac-1 and never reaches for partx either"

# The order the two stages need: breadcrumb -> write -> record+reboot, and the reboot
# before anything mounts a generation layer.
code_line_of() {
  printf '%s\n' "${boot_init}" \
    | awk -v pat="$1" '!/^[[:space:]]*#/ && index($0, pat) { print NR; exit }'
}
prepare_no=$(code_line_of 'wf_grow_stage1_prepare')
write_no=$(code_line_of 'wf_grow_write_table')
finish_no=$(code_line_of 'wf_grow_record_stage1')
resize_no=$(code_line_of 'wf_grow_resize_mounted')
generation_no=$(code_line_of 'subvol=/${upper}')
overlay_no=$(code_line_of 'lowerdir=/mnt/@platform:/mnt/@sys')
assert_eq "$((prepare_no < write_no))" "1" \
  "ac-5 the write-ahead breadcrumb is written before the table"
assert_eq "$((write_no < finish_no))" "1" \
  "ac-2 the record comes after the write"
# record -> release -> reboot, in that order, and the release in between is the one the init
# runs after the record (the write window has one before it, which is a different release).
first_after() {
  printf '%s\n' "${boot_init}" \
    | awk -v pat="$1" -v from="$2" '!/^[[:space:]]*#/ && index($0, pat) && NR > from { print NR; exit }'
}
release_after_record="$(first_after 'wf_p4root_release' "${finish_no}")"
reboot_no=$(code_line_of 'wf_grow_reboot')
assert_eq "$((release_after_record > finish_no))" "1" \
  "ac-2 the mount is given back after the outcome is recorded"
assert_eq "$((reboot_no > release_after_record))" "1" \
  "ac-2 ... and only then is the reboot issued"
assert_eq "$((finish_no < generation_no))" "1" \
  "ac-2 a boot that writes the table ends before the generation layer is mounted"
assert_eq "$((resize_no < generation_no))" "1" \
  "ac-3 the resize happens before the writable layer is mounted"
assert_eq "$((generation_no < overlay_no))" "1" \
  "ac-8 the writable layer is mounted before the overlay is composed"

# The resize belongs to the already-full branch only: a boot that wrote the table must not
# resize a filesystem whose device the kernel has not re-read yet.
resize_block="$(printf '%s\n' "${boot_init}" | sed -n '/^case "${grow_plan_state}" in$/,/^esac$/p' \
  | sed -n '/already-full)/,/;;/p')"
assert_contains "${resize_block}" "already-full" \
  "ac-3 the resize branch is the already-full one"
assert_eq "$(printf '%s\n' "${boot_code}" | grep -c 'wf_grow_resize_mounted')" "1" \
  "ac-3 there is exactly one resize call in the init"
assert_contains "${resize_block}" "wf_grow_resize_mounted" \
  "ac-3 and it sits inside that branch"

# The growth block still never fails the boot.
stage1_block="$(printf '%s\n' "${boot_init}" | sed -n '/# 3a. Stage 1: rewrite the table/,/# 3b. Stage 2/p')"
assert_eq "$(printf '%s\n' "${stage1_block}" | grep -c 'wf_fail')" "0" \
  "ac-6 the table-writing stage records instead of failing the boot"
assert_eq "$(printf '%s\n' "${boot_code}" | grep -c 'reboot -f')" "0" \
  "ac-2 the reboot is issued by the helper, not spelled out in the init"

assert_contains "$grow_lib" '"${wf_grecord_dir}/.ab/grow"' \
  "ac-5 the helper owns the .ab/grow path"
assert_eq "$(printf '%s' "${grow_lib}" | grep -c 'wf_coldplug_dev')" "0" \
  "ac-1 no partition node is rebuilt, because no table is re-read"

# --------------------------------------------------------------------------- #
# Device identity wiring: no hard-coded boot disk anywhere on the path
# --------------------------------------------------------------------------- #

assert_contains "${boot_init}" 'identity="$(di_resolve)"' "ac-8 the disk is resolved, not assumed"
assert_contains "${boot_init}" 'p4="$(di_find_partition ab-data 4 "${dev}")" || p4=""' \
  "ac-8 p4 comes from the resolved disk, not from a bare name match"
assert_contains "${boot_init}" 'grow_plan="fail:${dev_error} 0"' \
  "ac-8 an unresolved disk is recorded as fail:<reason> and the table is left alone"
assert_contains "${boot_init}" 'if [ -n "${dev}" ] && [ -n "${p4}" ]; then' \
  "ac-8 growth only runs on a resolved disk with a data partition"
assert_eq "$(printf '%s' "${boot_init}" | grep -c 'DEV=/dev/vda')" "0" \
  "ac-8 the boot init no longer hard-codes /dev/vda"

# The mount table of the user data subvolumes is unchanged by this task.
for spec in \
  '@data:/newroot/data:rw,noatime' \
  '@docker:/newroot/opt/docker:rw,noatime,nodatacow,nodatasum' \
  '@swap:/newroot/swap:rw,noatime,nodatacow,nodatasum'
do
  assert_contains "${boot_init}" "\"${spec}\"" "ac-8 the mount table carries ${spec}"
done

builder="$(cat "$root/scripts/ci/initramfs.sh")"
assert_contains "${builder}" 'lib_dir="${CI_INITRAMFS_LIB_DIR-${CI_REPO_ROOT}/initramfs/lib}"' \
  "ac-2 the builder stages initramfs/lib by default"
assert_contains "$(cat "$root/scripts/ci/initramfs-tools.lock.json")" '"/usr/sbin/blkid"' \
  "ac-1 blkid travels with the boot initramfs, for the label-based identity fallback"

finish
