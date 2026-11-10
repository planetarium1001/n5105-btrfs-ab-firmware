#!/usr/bin/env bash
# Module: ab
# Verifies platform/lib/ab-partitions.sh: the glue that turns "which disk did we boot
# from" into the device nodes the boot path mounts. The identity library resolves the
# disk; this file must never let a second disk with the same `ab-*` GPT names be
# mounted by accident, which is the mistake a name-only lookup makes on a machine with
# two disks or a USB stick holding a copy of the image.
# The whole state machine is driven from a fixture sysfs tree, without root, btrfs or a
# real disk:
#   ac-1 the resolved disk decides: the partition is taken from that disk, not from the
#        first partition carrying the name
#   ac-2 a name that exists only on the other disk is refused while a disk is resolved
#   ac-3 with no resolvable disk, the name stands alone only when exactly one usable
#        disk carries it: two disks are ambiguous, a removable one is not ours
#   ac-4 without the identity library nothing is guessed
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

partitions_lib="$root/platform/lib/ab-partitions.sh"
identity_lib="$root/platform/lib/disk-identity.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/fixture"
sys="$fixture/sys/block"
mkdir -p "$sys" "$fixture/bin" "$tmp/esp/ab"

export DI_SYS_BLOCK="$sys"
export DI_DEV_DIR="/dev"
export DI_CMDLINE="$fixture/cmdline"
export DI_MOUNTS="$fixture/mounts"
export DI_BLKID="$fixture/bin/blkid"
export DI_ESP="$tmp/esp"
: >"$fixture/cmdline"
: >"$fixture/mounts"
: >"$fixture/blkid.db"

# --------------------------------------------------------------------------- #
# Fixture: the shape sysfs exposes, two disks at a time
# --------------------------------------------------------------------------- #

reset_fixture() {
  rm -rf "$sys"
  mkdir -p "$sys"
  : >"$fixture/cmdline"
  : >"$fixture/mounts"
  : >"$fixture/blkid.db"
}

# fixture_disk <name> [removable]
fixture_disk() {
  mkdir -p "$sys/$1/queue"
  printf 'DEVTYPE=disk\nDEVNAME=%s\n' "$1" >"$sys/$1/uevent"
  printf '%s\n' "${2:-0}" >"$sys/$1/removable"
  printf '512\n' >"$sys/$1/queue/logical_block_size"
}

# fixture_part <disk> <device> <PARTN> <PARTNAME> <LABEL>
#
# The partition lives inside the disk directory and /sys/class/block/<part> is a
# symlink to it, exactly as the kernel does it: that is what makes <part>/.. resolve to
# the disk.
fixture_part() {
  mkdir -p "$sys/$1/$2"
  printf '%s\n' "$3" >"$sys/$1/$2/partition"
  printf 'DEVTYPE=partition\nDEVNAME=%s\nPARTN=%s\nPARTNAME=%s\n' "$2" "$3" "$4" \
    >"$sys/$1/$2/uevent"
  ln -sfn "$1/$2" "$sys/$2"
}

# fixture_layout <disk> [removable] [extra PARTNAME]
#
# The device name of a partition is built the way the fixture disk would be spelled
# (sda1, nvme0n1p1); the production lookup never sees that rule, it reads PARTN.
fixture_layout() {
  local disk="$1" removable="${2:-0}" extra="${3:-}" prefix
  case "${disk}" in
    *[0-9]) prefix="${disk}p" ;;
    *) prefix="${disk}" ;;
  esac
  fixture_disk "${disk}" "${removable}"
  fixture_part "${disk}" "${prefix}1" 1 ab-esp ESP
  fixture_part "${disk}" "${prefix}2" 2 ab-slot-a slot-a
  fixture_part "${disk}" "${prefix}3" 3 ab-slot-b slot-b
  fixture_part "${disk}" "${prefix}4" 4 ab-data data
  if [ -n "${extra}" ]; then
    fixture_part "${disk}" "${prefix}5" 5 "${extra}" extra
  fi
}

# find <partname> <number> [<AB_DISK_IDENTITY_LIB>]
find_partition() {
  AB_DISK_IDENTITY_LIB="${3:-$identity_lib}" \
    sh -c ". '${partitions_lib}'; ab_find_partition '$1' '$2'" 2>/dev/null
}

# --------------------------------------------------------------------------- #
# ac-1: the resolved disk decides
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda
fixture_layout sdb
printf 'console=ttyS0 wf.dev=/dev/sdb\n' >"$fixture/cmdline"
assert_eq "$(find_partition ab-esp 1)" "/dev/sdb1" \
  "ac-1 slot a's ESP comes from the disk we booted from, not from the first match"
assert_eq "$(find_partition ab-slot-a 2)" "/dev/sdb2" "ac-1 the slot partitions follow the same disk"
assert_eq "$(find_partition ab-data 4)" "/dev/sdb4" "ac-1 the writable partition follows too"

printf 'console=ttyS0 wf.dev=/dev/sda\n' >"$fixture/cmdline"
assert_eq "$(find_partition ab-esp 1)" "/dev/sda1" "ac-1 the other hint moves every answer"

# The device name is not a rule either: nvme spellings come from sysfs, not from
# concatenating a number onto a disk name.
reset_fixture
fixture_layout nvme0n1
printf 'console=ttyS0 wf.dev=/dev/nvme0n1\n' >"$fixture/cmdline"
assert_eq "$(find_partition ab-data 4)" "/dev/nvme0n1p4" \
  "ac-1 a split device spelling works because the lookup is by PARTN on the disk"

# --------------------------------------------------------------------------- #
# ac-2: a name on the other disk is not an answer
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda
fixture_layout sdb 0 ab-esp-old
printf 'console=ttyS0 wf.dev=/dev/sda\n' >"$fixture/cmdline"
assert_eq "$(find_partition ab-esp-old 5)" "" \
  "ac-2 a name that only exists on the other disk is refused"
# A partition number the disk does not have falls back to the name on that same disk,
# and a name that is nowhere is simply refused.
assert_eq "$(find_partition ab-esp 9)" "/dev/sda1" \
  "ac-2 a missing partition number still resolves through the name on that disk"
assert_eq "$(find_partition ab-nowhere 9)" "" "ac-2 a name the disk does not carry is refused"

# --------------------------------------------------------------------------- #
# ac-3: no disk resolved, the name alone and only when unambiguous
# --------------------------------------------------------------------------- #

# One internal disk and no hints: the name resolves, and it is the only candidate.
reset_fixture
fixture_layout sda
: >"$fixture/mounts"
AB_DISK_IDENTITY_LIB="$identity_lib" sh -c ". '${partitions_lib}'; ab_disk_device" >"$tmp/disk" 2>/dev/null
assert_eq "$(cat "$tmp/disk")" "/dev/sda" "ac-3 a single disk is still identified without a hint"
assert_eq "$(find_partition ab-slot-a 2)" "/dev/sda2" "ac-3 and its partitions are found"

# Two disks with the same names and nothing to choose from: refuse, do not pick one.
reset_fixture
fixture_layout sda
fixture_layout sdb
: >"$fixture/mounts"
assert_eq "$(AB_DISK_IDENTITY_LIB="$identity_lib" sh -c ". '${partitions_lib}'; ab_disk_device" 2>/dev/null)" "" \
  "ac-3 two identical disks leave the identity unresolved"
assert_eq "$(find_partition ab-esp 1)" "" \
  "ac-3 with two identical disks the name is ambiguous and nothing is mounted"

# A removable disk is never ours, even when it is the only one carrying the names.
reset_fixture
fixture_layout sda
# Turn the only disk into a USB stick: same partitions, removable.
printf '1\n' >"$sys/sda/removable"
: >"$fixture/mounts"
assert_eq "$(find_partition ab-esp 1)" "" \
  "ac-3 a removable disk is refused rather than mounted"

# The helpers this glue depends on are the library's public interface: if one of these
# names changes, the lookup below must change with it, so a rename fails here.
for helper in di_resolve di_partition_on_disk di_lookup_partname di_parent_disk di_disk_ok di_find_partitions_by_name; do
  assert_eq "$(grep -cE "^${helper}\(\)" "$identity_lib")" "1" \
    "ac-4 the identity library still exports ${helper}"
done

# --------------------------------------------------------------------------- #
# ac-4: no identity library, no guess
# --------------------------------------------------------------------------- #

assert_eq "$(find_partition ab-esp 1 /nonexistent/disk-identity.sh)" "" \
  "ac-4 without the identity library nothing is guessed"

finish
