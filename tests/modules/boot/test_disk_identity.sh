#!/usr/bin/env bash
# Module: boot
# Drives platform/lib/disk-identity.sh from a fixture sysfs tree, so the five resolution
# levels are verified without any real disk, root or loop device:
#   ac-1 the parent disk comes from sysfs, so sda/nvme0n1/mmcblk0 all work and a whole
#        disk is never reported as its own parent
#   ac-2 the five levels resolve in order and each one is only accepted on evidence:
#        kernel parameter (reverse-checked), PARTUUID from ab/device.json, PARTNAME,
#        mount reverse lookup, unique candidate
#   ac-3 refusals: partitions split across disks, removable or non-disk devices, and
#        nothing to choose from all return a reason token and a non-zero status instead
#        of guessing
#   ac-4 the resolver is quiet on stdout: one result line, warnings on stderr
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
source "$root/platform/lib/disk-identity.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/fixture"
sys="$fixture/sys/block"
mkdir -p "$sys" "$fixture/bin" "$tmp/esp/ab"

export GROW_FIXTURE="$fixture"
DI_SYS_BLOCK="$sys"
DI_DEV_DIR="/dev"
DI_CMDLINE="$fixture/cmdline"
DI_MOUNTS="$fixture/mounts"
DI_BLKID="$fixture/bin/blkid"
export DI_SYS_BLOCK DI_DEV_DIR DI_CMDLINE DI_MOUNTS DI_BLKID

# --------------------------------------------------------------------------- #
# Fixtures: a sysfs tree plus the blkid table, both in the shape the kernel uses
# --------------------------------------------------------------------------- #

reset_fixture() {
  rm -rf "$sys"
  mkdir -p "$sys"
  : >"$fixture/cmdline"
  : >"$fixture/mounts"
  : >"$fixture/blkid.db"
}

# fixture_disk <name> <logical block size> [removable] [devtype]
fixture_disk() {
  mkdir -p "$sys/$1/queue"
  printf 'DEVTYPE=%s\nDEVNAME=%s\n' "${4:-disk}" "$1" >"$sys/$1/uevent"
  printf '%s\n' "${3:-0}" >"$sys/$1/removable"
  printf '%s\n' "$2" >"$sys/$1/queue/logical_block_size"
}

# fixture_part <disk> <device name> <PARTN> <PARTNAME> <LABEL> <PARTUUID>
#
# The partition directory lives inside the disk directory and /sys/class/block/<part>
# is a symlink to it, exactly as the kernel exposes it. That is what makes
# /sys/class/block/<part>/.. resolve to the disk instead of to /sys/class/block, and it
# is the whole reason the parent disk needs no naming rules.
fixture_part() {
  local disk="$1" dev="$2" number="$3" partname="$4" label="$5" uuid="$6"
  mkdir -p "$sys/${disk}/${dev}"
  printf '%s\n' "${number}" >"$sys/${disk}/${dev}/partition"
  printf 'DEVTYPE=partition\nDEVNAME=%s\nPARTN=%s\nPARTNAME=%s\n' \
    "${dev}" "${number}" "${partname}" >"$sys/${disk}/${dev}/uevent"
  ln -sfn "${disk}/${dev}" "$sys/${dev}"
  printf 'PARTUUID=%s %s\nLABEL %s %s\n' "${uuid}" "/dev/${dev}" "/dev/${dev}" "${label}" \
    >>"$fixture/blkid.db"
}

# fixture_layout <disk> <partition prefix> <with partnames 1|0>
fixture_layout() {
  local disk="$1" prefix="$2" names="${3:-1}"
  fixture_disk "$disk" 512 0 disk
  local spec=("1 ab-esp ESP 11111111-0000-0000-0000-000000000001"
              "2 ab-slot-a slot-a 11111111-0000-0000-0000-000000000002"
              "3 ab-slot-b slot-b 11111111-0000-0000-0000-000000000003"
              "4 ab-data data 11111111-0000-0000-0000-000000000004")
  local entry n partname label uuid
  for entry in "${spec[@]}"; do
    read -r n partname label uuid <<<"${entry}"
    if [ "${names}" = "1" ]; then
      fixture_part "${disk}" "${prefix}${n}" "${n}" "${partname}" "${label}" "${uuid}"
    else
      fixture_part "${disk}" "${prefix}${n}" "${n}" "" "${label}" "${uuid}"
    fi
  done
}

cat >"$fixture/bin/blkid" <<'STUB'
#!/bin/sh
db="${GROW_FIXTURE}/blkid.db"
case "$1" in
  -t)
    want="${2#PARTUUID=}"
    while read -r key dev rest; do
      case "${key}" in
        "PARTUUID=${want}") printf '%s\n' "${dev}"; exit 0 ;;
      esac
    done <"${db}"
    exit 2
    ;;
  -p)
    # -p -o value -s <FIELD> <device>
    dev="${6:-}"
    field="${5:-}"
    case "${field}" in
      PARTUUID)
        while read -r key a b; do
          case "${key}" in
            PARTUUID=*)
              if [ "${a}" = "${dev}" ]; then
                printf '%s\n' "${key#PARTUUID=}"
                exit 0
              fi
              ;;
          esac
        done <"${db}"
        exit 2
        ;;
      LABEL)
        while read -r key a b; do
          case "${key}" in
            LABEL)
              if [ "${a}" = "${dev}" ]; then
                printf '%s\n' "${b}"
                exit 0
              fi
              ;;
          esac
        done <"${db}"
        exit 2
        ;;
    esac
    exit 2
    ;;
  *)
    exit 2
    ;;
esac
STUB
chmod +x "$fixture/bin/blkid"

# resolve_out <args...>: stdout of di_resolve, status kept in resolve_rc
resolve_out=""
resolve_rc=0
resolve() {
  resolve_out="$(di_resolve "$@" 2>/dev/null)"
  resolve_rc=$?
}

# --------------------------------------------------------------------------- #
# ac-1 parent derivation, independent of the naming style
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 1
fixture_layout nvme0n1 "nvme0n1p" 1
fixture_layout mmcblk0 "mmcblk0p" 1

assert_eq "$(di_parent_disk /dev/sda4)" "/dev/sda" "ac-1 sda4 resolves to sda"
assert_eq "$(di_parent_disk /dev/nvme0n1p4)" "/dev/nvme0n1" \
  "ac-1 nvme0n1p4 resolves to nvme0n1 without trimming a p"
assert_eq "$(di_parent_disk /dev/mmcblk0p4)" "/dev/mmcblk0" \
  "ac-1 mmcblk0p4 resolves to mmcblk0"
assert_eq "$(di_parent_disk sda1)" "/dev/sda" "ac-1 a bare device name works too"
whole=$(di_parent_disk /dev/sda)
assert_eq "$?" "1" "ac-1 a whole disk is not its own parent"
assert_eq "${whole}" "" "ac-1 no parent is invented for a disk"
missing=$(di_parent_disk /dev/sr0)
assert_eq "$?" "1" "ac-1 an unknown device has no parent"

assert_eq "$(di_sector_size /dev/sda)" "512" "ac-1 the logical block size is read for a disk"
assert_eq "$(di_sector_size /dev/sda4)" "512" \
  "ac-1 the logical block size is read through a partition"
printf '4096\n' >"$sys/sda/queue/logical_block_size"
assert_eq "$(di_sector_size /dev/sda4)" "4096" "ac-1 a 4Kn disk reports 4096"

# --------------------------------------------------------------------------- #
# ac-2 level 3: PARTNAME, the always-on default
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 1
resolve
assert_eq "${resolve_rc}" "0" "ac-2 a complete layout resolves"
assert_eq "${resolve_out}" "disk=/dev/sda method=partname" "ac-2 level 3 finds the disk by PARTNAME"

reset_fixture
fixture_layout nvme0n1 "nvme0n1p" 1
resolve
assert_eq "${resolve_out}" "disk=/dev/nvme0n1 method=partname" \
  "ac-2 level 3 works on nvme naming"
reset_fixture
fixture_layout mmcblk0 "mmcblk0p" 1
resolve
assert_eq "${resolve_out}" "disk=/dev/mmcblk0 method=partname" \
  "ac-2 level 3 works on mmcblk naming"
assert_eq "$(di_partition_on_disk /dev/mmcblk0 4)" "/dev/mmcblk0p4" \
  "ac-2 the partition-number fallback is sysfs based"
assert_eq "$(di_partition_on_disk /dev/mmcblk0 9)" "" \
  "ac-2 a partition number that is not there yields nothing"

# The lookup itself: through the blkid index, and through sysfs when there is no udev
# cache in the initramfs. One disk only, so "first match" cannot be another fixture.
reset_fixture
fixture_layout sda "sda" 1
assert_eq "$(di_lookup_partname ab-slot-b)" "/dev/sda3" "ac-2 PARTNAME lookup returns the node"
assert_eq "$(di_lookup_partuuid 11111111-0000-0000-0000-000000000002)" "/dev/sda2" \
  "ac-2 PARTUUID lookup goes through blkid"
gone=$(di_lookup_partname ab-nope)
assert_eq "$?" "1" "ac-2 an unknown PARTNAME lookup fails instead of printing nothing"
cat >"$fixture/bin/blkid-noindex" <<'STUB'
#!/bin/sh
case "$1" in
  -t) exit 2 ;;
  -p)
    field="${5:-}"
    dev="${6:-}"
    [ "${field}" = "PARTUUID" ] || exit 2
    while read -r key a rest; do
      case "${key}" in
        PARTUUID=*)
          if [ "${a}" = "${dev}" ]; then
            printf '%s\n' "${key#PARTUUID=}"
            exit 0
          fi
          ;;
      esac
    done <"${GROW_FIXTURE}/blkid.db"
    exit 2
    ;;
esac
exit 2
STUB
chmod +x "$fixture/bin/blkid-noindex"
assert_eq "$(DI_BLKID="$fixture/bin/blkid-noindex" di_lookup_partuuid \
  11111111-0000-0000-0000-000000000004)" "/dev/sda4" \
  "ac-2 a PARTUUID lookup works without a blkid cache, from sysfs partitions"

# --------------------------------------------------------------------------- #
# ac-2 level 1: kernel parameters, accepted only with the reverse lookup
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 1
fixture_layout sdb "sdb" 1
printf 'ab.disk=/dev/sdb wf.dev=/dev/sda\n' >"$fixture/cmdline"
resolve
assert_eq "${resolve_out}" "disk=/dev/sdb method=cmdline" \
  "ac-2 level 1 wins over PARTNAME and ab.disk wins over wf.dev"

printf 'wf.dev=/dev/sda\n' >"$fixture/cmdline"
resolve
assert_eq "${resolve_out}" "disk=/dev/sda method=cmdline" "ac-2 wf.dev is the same hint"

# The same names on a second disk are a stale copy, and without a hint that is not a
# decision: it is reported instead of picking the first one that matched.
: >"$fixture/cmdline"
resolve
assert_eq "${resolve_rc}" "1" "ac-3 a duplicated partition set is refused"
assert_eq "${resolve_out}" "reason=ambiguous-disk" \
  "ac-3 a duplicated partition set is reported as ambiguous"

# A hint that does not carry ab-esp is not evidence, and level 3 still answers.
reset_fixture
fixture_layout sda "sda" 1
fixture_layout sdc "sdc" 0
printf 'ab.disk=/dev/sdc\n' >"$fixture/cmdline"
resolve
assert_eq "${resolve_out}" "disk=/dev/sda method=partname" \
  "ac-2 a hint that carries no ab-esp partition is ignored"

# A removable disk is never accepted, not even when the kernel names it.
reset_fixture
fixture_disk sdz 512 1 disk
printf 'ab.disk=/dev/sdz\n' >"$fixture/cmdline"
resolve
assert_eq "${resolve_rc}" "1" "ac-2 a removable hint is refused"
assert_eq "${resolve_out}" "reason=no-disk" "ac-2 a removable hint leaves nothing to resolve"

# --------------------------------------------------------------------------- #
# ac-2 level 2: PARTUUID recorded on the ESP at build time
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 1
fixture_layout sdb "sdb" 1
# The file the disk stage actually writes: ab/device.json, one "partuuid" per name.
cat >"$tmp/esp/ab/device.json" <<'JSON'
{
  "format": "ab-device/1",
  "disk": { "label_id": "4f2b1c3d-5e6f-7081-9203-a4b5c6d7e8f9" },
  "partitions": {
    "ab-esp": { "partuuid": "aaaa0000-0000-0000-0000-00000000aaaa" },
    "ab-slot-a": { "partuuid": "bbbb0000-0000-0000-0000-00000000bbbb" }
  },
  "labels": {
    "ab-esp": "ESP",
    "ab-slot-a": "slot-a"
  }
}
JSON
# The ESP named by device.json lives on sdb, while the PARTNAME scan finds one on sda.
printf 'PARTUUID=aaaa0000-0000-0000-0000-00000000aaaa /dev/sdb1\n' >>"$fixture/blkid.db"
resolve "$tmp/esp"
assert_eq "${resolve_out}" "disk=/dev/sdb method=partuuid" \
  "ac-2 level 2 beats PARTNAME and follows device.json"

# blkid prints UUIDs in upper case while the build records them in lower case.
printf 'PARTUUID=CCCC0000-0000-0000-0000-00000000CCCC /dev/sdb2\n' >>"$fixture/blkid.db"
printf '{"partitions":{"ab-esp":{"partuuid":"cccc0000-0000-0000-0000-00000000cccc"}}}\n' \
  >"$tmp/esp/ab/device.json"
resolve "$tmp/esp"
assert_eq "${resolve_out}" "disk=/dev/sdb method=partuuid" \
  "ac-2 a lower-case PARTUUID matches the upper-case blkid output"

# The older boot/ab/ placement still resolves, but it is reported, not hidden.
cat >"$tmp/esp/ab/device.json" <<'JSON'
{
  "partitions": {
    "ab-esp": { "partuuid": "aaaa0000-0000-0000-0000-00000000aaaa" }
  }
}
JSON
mkdir -p "$tmp/esp/boot/ab"
mv "$tmp/esp/ab/device.json" "$tmp/esp/boot/ab/device.json"
resolve "$tmp/esp"
assert_eq "${resolve_out}" "disk=/dev/sdb method=partuuid" \
  "ac-2 the boot/ab/ layout of the identity file still resolves"
warning="$(di_resolve "$tmp/esp" 2>&1 >/dev/null)"
assert_contains "${warning}" "expected ab/device.json" \
  "ac-2 the non-standard identity path is reported on stderr"
rm -rf "$tmp/esp/boot"

# Two disks carrying the same names is ambiguous on its own, so the fall-through cases
# below run on a single disk: they are about device.json, not about duplicates.
rm -rf "$sys/sdb" "$sys/sdb1" "$sys/sdb2" "$sys/sdb3" "$sys/sdb4"
rm -f "$tmp/esp/ab/device.json"
resolve "$tmp/esp"
assert_eq "${resolve_out}" "disk=/dev/sda method=partname" \
  "ac-2 a missing device.json falls through to PARTNAME"

# device.json present but its PARTUUID is not on any disk: fall through, never guess.
printf '{"parts":[{"name":"ab-esp","partuuid":"DEAD0000-0000-0000-0000-000000000000"}]}\n' \
  >"$tmp/esp/ab/device.json"
resolve "$tmp/esp"
assert_eq "${resolve_out}" "disk=/dev/sda method=partname" \
  "ac-2 an unknown PARTUUID falls through to PARTNAME"
rm -f "$tmp/esp/ab/device.json"

# --------------------------------------------------------------------------- #
# ac-2 level 4: mount reverse lookup, for a kernel without PARTNAME
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 0
printf '/dev/sda1 /boot vfat rw 0 0\n' >"$fixture/mounts"
resolve
assert_eq "${resolve_out}" "disk=/dev/sda method=mount" \
  "ac-2 level 4 resolves through the mounted /boot when PARTNAME is missing"

reset_fixture
fixture_layout mmcblk0 "mmcblk0p" 0
: >"$fixture/mounts"
DI_ESP_DEV=/dev/mmcblk0p1
export DI_ESP_DEV
resolve
unset DI_ESP_DEV
assert_eq "${resolve_out}" "disk=/dev/mmcblk0 method=mount" \
  "ac-2 the initramfs ESP partition is a mount reverse lookup too"

# --------------------------------------------------------------------------- #
# ac-2 level 5: the only disk that can be ours
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 0
resolve
assert_eq "${resolve_out}" "disk=/dev/sda method=unique" \
  "ac-2 level 5 accepts a single disk carrying all four filesystem labels"

# Two such disks are not a decision but a question.
reset_fixture
fixture_layout sda "sda" 0
fixture_layout sdb "sdb" 0
resolve
assert_eq "${resolve_rc}" "1" "ac-2 two possible disks fail"
assert_eq "${resolve_out}" "reason=ambiguous-disk" "ac-2 two possible disks are reported as ambiguous"

# A disk that carries the labels but is removable is not a candidate.
reset_fixture
fixture_disk sda 512 1 disk
fixture_part sda sda1 1 "" ESP 11111111-0000-0000-0000-000000000001
fixture_part sda sda2 2 "" slot-a 11111111-0000-0000-0000-000000000002
fixture_part sda sda3 3 "" slot-b 11111111-0000-0000-0000-000000000003
fixture_part sda sda4 4 "" data 11111111-0000-0000-0000-000000000004
resolve
assert_eq "${resolve_out}" "reason=no-disk" "ac-3 a removable disk is never a unique candidate"

# A loop device or any other DEVTYPE is not a disk we may write to.
reset_fixture
fixture_disk loop0 512 0 loop
fixture_part loop0 loop0p1 1 "" ESP 11111111-0000-0000-0000-000000000001
fixture_part loop0 loop0p2 2 "" slot-a 11111111-0000-0000-0000-000000000002
fixture_part loop0 loop0p3 3 "" slot-b 11111111-0000-0000-0000-000000000003
fixture_part loop0 loop0p4 4 "" data 11111111-0000-0000-0000-000000000004
resolve
assert_eq "${resolve_out}" "reason=no-disk" "ac-3 a non-disk DEVTYPE is refused even with our labels"

# --------------------------------------------------------------------------- #
# ac-3 two disks carry the same image: mounting must follow the resolved disk
# --------------------------------------------------------------------------- #
# The regression this guards: with the same four PARTNAMEs on sda and nvme0n1, the sysfs
# glob order answers `sda*` first. Resolve would correctly refuse to write a table, but
# the mount would still land on the wrong disk (or on a USB stick).

reset_fixture
fixture_layout sda "sda" 1
fixture_layout nvme0n1 "nvme0n1p" 1
printf 'ab.disk=/dev/nvme0n1\n' >"$fixture/cmdline"
resolve
assert_eq "${resolve_out}" "disk=/dev/nvme0n1 method=cmdline" \
  "ac-3 the resolved disk is the one the kernel parameter names"

assert_eq "$(di_lookup_partname ab-esp /dev/nvme0n1)" "/dev/nvme0n1p1" \
  "ac-3 a scoped name lookup answers on the resolved disk, not in glob order"
assert_eq "$(di_lookup_partname ab-data /dev/sda)" "/dev/sda4" \
  "ac-3 a scoped name lookup can still ask for the other disk explicitly"
for pair in "ab-esp 1" "ab-slot-a 2" "ab-slot-b 3" "ab-data 4"; do
  set -- ${pair}
  chosen="$(di_find_partition "$1" "$2" /dev/nvme0n1)" || chosen=""
  assert_eq "${chosen}" "/dev/nvme0n1p$2" \
    "ac-3 di_find_partition picks $1 on the resolved disk"
  assert_eq "$(di_parent_disk "${chosen}")" "/dev/nvme0n1" \
    "ac-3 the chosen $1 lives on the resolved disk"
done
# The same four names asked for on the other disk stay on the other disk.
assert_eq "$(di_find_partition ab-data 4 /dev/sda)" "/dev/sda4" \
  "ac-3 the disk argument is honoured in both directions"
# Without a resolved disk the bare name lookup answers, but never from a removable disk.
# Without a resolved disk the answer is the first copy in glob order (nvme0n1 sorts
# before sda) -- still a real disk, which is all this level promises.
assert_eq "$(di_parent_disk "$(di_find_partition ab-esp 1 "")")" "/dev/nvme0n1" \
  "ac-3 the unresolved fallback answers from a non-removable disk"

# --------------------------------------------------------------------------- #
# ac-3 a removable disk is never a candidate, resolved or not
# --------------------------------------------------------------------------- #

reset_fixture
fixture_disk sda 512 1 disk
fixture_part sda sda1 1 ab-esp ESP 11111111-0000-0000-0000-000000000001
fixture_part sda sda2 2 ab-slot-a slot-a 11111111-0000-0000-0000-000000000002
fixture_part sda sda3 3 ab-slot-b slot-b 11111111-0000-0000-0000-000000000003
fixture_part sda sda4 4 ab-data data 11111111-0000-0000-0000-000000000004
removable_lookup="$(di_lookup_partname ab-esp)"
assert_eq "$?" "1" "ac-3 a bare name lookup refuses a partition on a removable disk"
assert_eq "${removable_lookup}" "" "ac-3 a removable candidate yields no device"
removable_find="$(di_find_partition ab-esp 1)"
assert_eq "$?" "1" "ac-3 di_find_partition refuses a removable disk without a resolution"
assert_eq "${removable_find}" "" "ac-3 no partition is returned for a removable disk"
removable_scoped="$(di_find_partition ab-esp 1 /dev/sda)"
assert_eq "$?" "1" "ac-3 an explicitly named removable disk is still refused"
assert_eq "$(di_partition_on_disk /dev/sda 1)" "" \
  "ac-3 the partition-number lookup refuses a removable disk too"

# A removable disk next to a real one: the removable copy is skipped, not chosen.
reset_fixture
fixture_disk sda 512 1 disk
fixture_part sda sda1 1 ab-esp ESP 11111111-0000-0000-0000-000000000001
fixture_layout nvme0n1 "nvme0n1p" 1
assert_eq "$(di_lookup_partname ab-esp)" "/dev/nvme0n1p1" \
  "ac-3 a bare name lookup skips the removable copy in front of it in glob order"

# --------------------------------------------------------------------------- #
# ac-3 the partition number is only trusted when the name agrees
# --------------------------------------------------------------------------- #

reset_fixture
fixture_disk sdb 512 0 disk
# Partition order differs from the documented 1..4: the name has to win.
fixture_part sdb sdb1 1 ab-slot-a slot-a 11111111-0000-0000-0000-000000000002
fixture_part sdb sdb2 2 ab-esp ESP 11111111-0000-0000-0000-000000000001
printf 'ab.disk=/dev/sdb\n' >"$fixture/cmdline"
assert_eq "$(di_find_partition ab-esp 1 /dev/sdb)" "/dev/sdb2" \
  "ac-3 a swapped partition order is not mounted by number"
swapped_warning="$(di_find_partition ab-esp 1 /dev/sdb 2>&1 >/dev/null)"
assert_contains "${swapped_warning}" "is not ab-esp" \
  "ac-3 the order mismatch is reported"

# A kernel that does not expose PARTNAME at all still gets the number.
reset_fixture
fixture_disk sdc 512 0 disk
fixture_part sdc sdc1 1 "" ESP 11111111-0000-0000-0000-000000000001
assert_eq "$(di_find_partition ab-esp 1 /dev/sdc)" "/dev/sdc1" \
  "ac-3 without PARTNAME the partition number on the resolved disk answers"

# --------------------------------------------------------------------------- #
# ac-3 partitions on different disks
# --------------------------------------------------------------------------- #

reset_fixture
# Three partitions on one disk, the fourth on another: our own set is inconsistent.
fixture_disk sda 512 0 disk
fixture_part sda sda1 1 ab-esp ESP 11111111-0000-0000-0000-000000000001
fixture_part sda sda2 2 ab-slot-a slot-a 11111111-0000-0000-0000-000000000002
fixture_part sda sda3 3 ab-slot-b slot-b 11111111-0000-0000-0000-000000000003
fixture_disk sdb 512 0 disk
fixture_part sdb sdb4 4 ab-data data 11111111-0000-0000-0000-000000000004
resolve
assert_eq "${resolve_rc}" "1" "ac-3 a split partition set is refused"
assert_eq "${resolve_out}" "reason=partitions-split" "ac-3 a split set is reported as partitions-split"

# --------------------------------------------------------------------------- #
# ac-4 output discipline
# --------------------------------------------------------------------------- #

reset_fixture
fixture_layout sda "sda" 1
resolve
assert_eq "$(printf '%s\n' "${resolve_out}" | wc -l | tr -d ' ')" "1" \
  "ac-4 a successful resolution prints one line"
assert_matches "${resolve_out}" '^disk=/dev/[A-Za-z0-9]+ method=(cmdline|partuuid|partname|mount|unique)$' \
  "ac-4 the line is disk=<dev> method=<token>"
noisy="$(di_resolve 2>/dev/null)"
assert_eq "${noisy}" "disk=/dev/sda method=partname" \
  "ac-4 warnings never reach stdout"
stderr_only="$(di_resolve 2>&1 >/dev/null)"
assert_eq "${stderr_only}" "" "ac-4 a clean run has nothing on stderr"

finish
