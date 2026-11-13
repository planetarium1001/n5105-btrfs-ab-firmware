#!/usr/bin/env bash
# Module: image
# Verifies the S2 contracts that hold without root and without a kernel:
#   ac-1 the naming contract from design.md section 1 holds on both sides: GPT PARTNAME
#        ab-esp / ab-slot-a / ab-slot-b / ab-data in the frozen geometry, filesystem
#        LABEL ESP / slot-a / slot-b / data in the mkfs arguments, and the image
#        verifier asserts the same two sets
#   ac-2 the btrfs mkfs arguments are the ones docs/partitions.md prescribes
#   ac-3 the judge-line gate in scripts/ci/qemu-smoke.sh accepts an S2 ok line and
#        rejects an S2 failure line
#   ac-4 the expectation file written by the host verifier parses back into the
#        values the guest assertion needs (the two sides share one format)
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

disk_script="$root/scripts/ci/disk.sh"
verify_script="$root/scripts/ci/image-verify.sh"
qemu_script="$root/scripts/ci/qemu-smoke.sh"
assemble_script="$root/scripts/ci/assemble.sh"
payload_script="$root/scripts/ci/payload-build.sh"

# ac-1 partition geometry, normalised so reformatting does not break the test
geometry=$(sed -n '/^label: gpt$/,/^SFDISK$/p' "$disk_script" \
  | grep -E 'name="' \
  | sed -E 's/.*start=[[:space:]]*([0-9]+), size=[[:space:]]*([0-9]+).*name="([^"]+)".*/\3 \1 \2/' \
  | paste -sd';' -)
assert_eq "$geometry" \
  "ab-esp 2048 262144;ab-slot-a 264192 262144;ab-slot-b 526336 262144;ab-data 788480 262144" \
  "ac-1 partition geometry matches the documented layout"

esp_type=$(sed -n '/^label: gpt$/,/^SFDISK$/p' "$disk_script" | grep 'name="ab-esp"' || true)
assert_contains "$esp_type" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" \
  "ac-1 p1 is typed as an EFI system partition"

# ac-1b the two name sets are independent: PARTNAME is what discovery reads out of
# /sys/class/block/*/uevent, LABEL is what a human reads out of blkid.
partnames=$(sed -n '/^label: gpt$/,/^SFDISK$/p' "$disk_script" \
  | grep -E 'name="' \
  | sed -E 's/.*name="([^"]+)".*/\1/' \
  | paste -sd, -)
assert_eq "$partnames" "ab-esp,ab-slot-a,ab-slot-b,ab-data" \
  "ac-1 GPT PARTNAMEs are ab-esp / ab-slot-a / ab-slot-b / ab-data"

assert_contains "$(cat "$disk_script")" 'mkfs.vfat -F 32 -n "ESP"' \
  "ac-1 the ESP carries the FAT label ESP"
assert_contains "$(cat "$disk_script")" '"ab-slot-a" "slot-a"' \
  "ac-1 p2 is ab-slot-a with label slot-a"
assert_contains "$(cat "$disk_script")" '"ab-slot-b" "slot-b"' \
  "ac-1 p3 is ab-slot-b with label slot-b"
assert_contains "$(cat "$disk_script")" '-L "data" "${dev_p4}"' \
  "ac-1 p4 is ab-data with label data"
assert_contains "$(cat "$disk_script")" 'ab-data:788480+262144' \
  "ac-1 the emitted part_layout uses the PARTNAME ab-data"

# The p4 name ab-shared described a partition that is not shared with anything; it is
# retired in design.md section 1 and must not survive in either build file.
assert_eq "$(grep -c 'ab-shared' "$disk_script" || true)" "0" \
  "ac-1 the retired name ab-shared is gone from disk.sh"
assert_eq "$(grep -c 'WF-ESP' "$disk_script" || true)" "0" \
  "ac-1 the retired ESP label WF-ESP is gone from disk.sh"

# ac-1c the verifier reads both name sets back from the image and compares them with
# the same contract, so a drift in either set fails the build.
verify_want=$(sed -n '/^want = \[$/,/^\]$/p' "$verify_script" | tr -d ' \n')
assert_contains "$verify_want" '("ab-esp","ESP",262144,' \
  "ac-1 image-verify expects PARTNAME ab-esp with label ESP"
assert_contains "$verify_want" '("ab-slot-a","slot-a",262144,' \
  "ac-1 image-verify expects PARTNAME ab-slot-a with label slot-a"
assert_contains "$verify_want" '("ab-slot-b","slot-b",262144,' \
  "ac-1 image-verify expects PARTNAME ab-slot-b with label slot-b"
assert_contains "$verify_want" '("ab-data","data",262144,' \
  "ac-1 image-verify expects PARTNAME ab-data with label data"
assert_contains "$(cat "$verify_script")" 'blkid -p -o value -s "${field}"' \
  "ac-1 image-verify reads PARTNAME and LABEL back from the image"
assert_eq "$(grep -c 'ab-shared' "$verify_script" || true)" "0" \
  "ac-1 the retired name ab-shared is gone from image-verify.sh"

# ac-1e the guest repeats the check from inside the kernel: it reads PARTNAMEs from the
# GPT and LABELs from the superblock, so one relabelled side cannot hide behind the other.
guest_assert="$root/tests/modules/image/guest-assert.sh"
assert_contains "$(cat "$guest_assert")" 'ab-esp,ab-slot-a,ab-slot-b,ab-data' \
  "ac-1 the guest assertion expects the contract PARTNAMEs"
assert_contains "$(cat "$guest_assert")" 'slot-a slot-b data' \
  "ac-1 the guest assertion expects the contract LABELs"

# ac-1f the documents state the same contract, so code and prose cannot drift apart.
for doc in docs/partitions.md docs/partitions.zh-CN.md README.md README.zh-CN.md; do
  assert_contains "$(cat "$root/$doc")" '| p4 | `ab-data` | `data` |' \
    "ac-1 $doc documents p4 as ab-data with label data"
done
assert_contains "$(cat "$root/docs/partitions.md")" "GPT PARTNAME" \
  "ac-1 partitions.md states the PARTNAME and LABEL columns"
assert_contains "$(cat "$root/docs/partitions.zh-CN.md")" "GPT PARTNAME" \
  "ac-1 partitions.zh-CN.md states the PARTNAME and LABEL columns"

# ac-2 filesystem arguments and subvolume layout
assert_contains "$(cat "$disk_script")" "mkfs.btrfs -f -m dup -d single" \
  "ac-2 p2/p3 use metadata duplication"
assert_contains "$(cat "$disk_script")" "mkfs.btrfs -f -m single -d single" \
  "ac-2 p4 uses single metadata"
assert_contains "$(cat "$disk_script")" '@overlay-${upstream_version}' \
  "ac-2 the writable layer is named after the upstream version"
assert_contains "$(cat "$disk_script")" '"upper": "${overlay_name}"' \
  "ac-2 the state file records the layer name, not a number"
assert_contains "$(cat "$disk_script")" 'chattr +C' \
  "ac-2 @docker and @swap are allocated without COW"

# ac-3 judge-line gate, driven through stubs so no QEMU is needed
stubs="$tmp/stubs"
mkdir -p "$stubs" "$tmp/work"
printf '#!/bin/sh\nexit 0\n' >"$stubs/mkfs.btrfs"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$stubs/timeout"
cat >"$stubs/qemu-system-x86_64" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in file:*) log="${arg#file:}" ;; esac
done
if [ "${STUB_RESULT:-ok}" = "ok" ]; then
  printf '[s2] partitions ok\nS2-RESULT=ok parts=4 images=538968064\n' >"$log"
else
  printf '[s2] subvolume layout wrong\nS2-RESULT=fail reason=p2-subvolumes-@sys\n' >"$log"
fi
STUB
chmod +x "$stubs"/*
: >"$tmp/work/kernel.bin"
: >"$tmp/work/initramfs.cpio.gz"
: >"$tmp/work/disk.img"

run_gate() {
  PATH="$stubs:$PATH" \
    CI_TMP_ROOT="$tmp/work/ci" \
    CI_LOG_DIR="$tmp/work/ci/logs" \
    CI_QEMU_DIR="$tmp/work/qemu-$1" \
    CI_KERNEL="$tmp/work/kernel.bin" \
    CI_INITRAMFS="$tmp/work/initramfs.cpio.gz" \
    CI_QEMU_DISK="$tmp/work/disk.img" \
    CI_QEMU_INIT=/s2.sh \
    CI_JUDGE_PREFIX=S2-RESULT \
    bash "$qemu_script" 2>&1
}

ok_output=$(STUB_RESULT=ok run_gate ok)
assert_eq "$?" "0" "ac-3 an S2 ok line passes the gate"
assert_contains "$ok_output" "S2-RESULT=ok parts=4 images=538968064" \
  "ac-3 the judge line is reported verbatim"

fail_output=$(STUB_RESULT=fail run_gate fail)
fail_status=$?
assert_eq "$fail_status" "1" "ac-3 an S2 failure line fails the gate"
assert_contains "$fail_output" "S2-RESULT failed" \
  "ac-3 the failure names the judged prefix"

# ac-4 expectation file contract: the writer is image-verify.sh, the reader is the
# guest assertion; both must agree on the exact bytes in between.
expect_file="$tmp/expect.txt"
{
  printf 'files=%s\n' "1483"
  printf 'images=%s\n' "538968064"
  printf 'parts=4\n'
  printf 'p1max_kib=65536\n'
  printf 'sample %s %s\n' "/bin/busybox" "5c1b0ac1d4c0c0e0aa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"
} >"$expect_file"

read -r -d '' reader <<'READER'
set -u
expect_files=""
expect_images=""
expect_parts=""
expect_p1max=""
SAMPLES=""
while IFS=' =' read -r key value extra; do
    case "${key}" in
        files) expect_files="${value}" ;;
        images) expect_images="${value}" ;;
        parts) expect_parts="${value}" ;;
        p1max_kib) expect_p1max="${value}" ;;
        sample) SAMPLES="${SAMPLES}${value}=${extra} " ;;
        *) : ;;
    esac
done <"$1"
printf '%s|%s|%s|%s|%s\n' "$expect_files" "$expect_images" "$expect_parts" "$expect_p1max" "$SAMPLES"
READER

parsed=$(sh -c "$reader" sh "$expect_file")
assert_eq "$parsed" "1483|538968064|4|65536|/bin/busybox=5c1b0ac1d4c0c0e0aa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071 " \
  "ac-4 the expectation file round-trips through the guest parser"

# The guest parser and the script must not drift apart: the assertion below fails if
# guest-assert.sh stops using the same field separator.
assert_contains "$(cat "$root/tests/modules/image/guest-assert.sh")" "IFS=' =' read -r key value extra" \
  "ac-4 the guest assertion reads the expectation file with the shared separator"

# The ESP must carry the slot fragment the menu `source`s, otherwise GRUB has no slot
# decision at all. GRUB's own environment block is not an option here: the shipped
# BOOTX64.EFI has no env module. Unit 03 renders the fragment; this stage only installs
# the file the render stage reports.
ab_cfg=$(cat "$disk_script")
assert_contains "$ab_cfg" '/boot/grub/ab-slot.cfg' \
  "ab-slot.cfg disk.sh installs the slot fragment on the ESP"
assert_contains "$ab_cfg" 'ab_slot_cfg_path=' \
  "ab-slot.cfg disk.sh reads the path grub-render reports"
assert_contains "$ab_cfg" 'GRUB slot configuration not found' \
  "ab-slot.cfg a missing fragment stops the disk stage instead of being skipped"
assert_eq "$(grep -c 'grubenv' "$disk_script" || true)" "0" \
  "ab-slot.cfg the retired grubenv hand-over is gone from disk.sh"

verify_cfg=$(cat "$verify_script")
assert_contains "$verify_cfg" 'boot/grub/ab-slot.cfg' \
  "ab-slot.cfg image-verify looks for the fragment"
assert_contains "$verify_cfg" 'set default=' \
  "ab-slot.cfg image-verify reads the default line"
assert_contains "$verify_cfg" 'set fallback=' \
  "ab-slot.cfg image-verify reads the fallback line"
assert_contains "$verify_cfg" 'for env_call in load_env save_env' \
  "ab-slot.cfg image-verify rejects environment-block calls"
assert_contains "$verify_cfg" 'committed slot ${committed} is entry ${committed_index}' \
  "ab-slot.cfg image-verify ties default to the committed slot"
assert_eq "$(grep -c 'grubenv' "$verify_script" || true)" "0" \
  "ab-slot.cfg the retired grubenv hand-over is gone from image-verify.sh"

# --------------------------------------------------------------------------- #
# ac-7 build side: the device identity file
# --------------------------------------------------------------------------- #
# The running system's first identity level is the PARTUUID, which only the run-time
# side can exercise, but the image has to carry it: ab/device.json with the GPT
# disk GUID, the four partition UUIDs and the labels the filesystems really hold. The
# check below is the one image-verify runs, driven here against fixtures so the three
# ways the file goes wrong (missing field, repeated PARTUUID, label that is not there)
# are proven to fail the build.

id_cfg=$(cat "$disk_script")
assert_contains "$id_cfg" '${p1_identity}/ab/device.json' \
  "ac-7 disk.sh writes the identity file at the ESP root, next to ab/state.json"
assert_contains "$id_cfg" '"format": "ab-device/1"' \
  "ac-7 the identity file declares its format"
assert_contains "$id_cfg" 'blkid -s PARTUUID -o value' \
  "ac-7 PARTUUIDs come from blkid first"
assert_contains "$id_cfg" 'no PARTUUID for' \
  "ac-7 a partition without a PARTUUID stops the build"
for name in ab-esp ab-slot-a ab-slot-b ab-data; do
  assert_contains "$id_cfg" "\"${name}\": { \"partuuid\":" \
    "ac-7 the identity file names ${name}"
done
assert_contains "$(cat "$verify_script")" 'ab-slot\.cfg|device\.json' \
  "ac-7 the identity file is excluded from the ESP tree comparison"

device_check="$tmp/device-check.py"
awk '/^python3 - "\$\{device_json\}"/{seen=1} seen && /<<.PYTHON.$/{body=1; next} body && /^PYTHON$/{body=0} body' \
  "$verify_script" >"$device_check"
assert_file_exists "$device_check" "ac-7 the identity check is extractable from image-verify.sh"
assert_contains "$(cat "$device_check")" "repeats partitions" \
  "ac-7 the check rejects a repeated PARTUUID"
assert_contains "$(cat "$device_check")" "the filesystem label" \
  "ac-7 the check compares labels with the filesystems"

table_json="$tmp/table.json"
uuids_txt="$tmp/part-uuids.txt"
names_txt="$tmp/part-names.txt"
device_json="$tmp/device.json"
cat >"$table_json" <<'JSON'
{"partitiontable": {"label": "gpt", "id": "6E353130-352D-4142-4653-000000000001",
 "partitions": [{"name": "ab-esp"}, {"name": "ab-slot-a"},
                {"name": "ab-slot-b"}, {"name": "ab-data"}]}}
JSON
cat >"$uuids_txt" <<'TXT'
p1|ab-esp|11111111-1111-1111-1111-111111111111
p2|ab-slot-a|22222222-2222-2222-2222-222222222222
p3|ab-slot-b|33333333-3333-3333-3333-333333333333
p4|ab-data|44444444-4444-4444-4444-444444444444
TXT
cat >"$names_txt" <<'TXT'
p1|ab-esp|ESP
p2|ab-slot-a|slot-a
p3|ab-slot-b|slot-b
p4|ab-data|data
TXT
cat >"$device_json" <<'JSON'
{
  "format": "ab-device/1",
  "disk": { "label_id": "6e353130-352d-4142-4653-000000000001" },
  "partitions": {
    "ab-esp": { "partuuid": "11111111-1111-1111-1111-111111111111" },
    "ab-slot-a": { "partuuid": "22222222-2222-2222-2222-222222222222" },
    "ab-slot-b": { "partuuid": "33333333-3333-3333-3333-333333333333" },
    "ab-data": { "partuuid": "44444444-4444-4444-4444-444444444444" }
  },
  "labels": {
    "ab-esp": "ESP", "ab-slot-a": "slot-a", "ab-slot-b": "slot-b", "ab-data": "data"
  }
}
JSON

# device_output/device_status are set by check_device; a command substitution around the
# call would run it in a subshell and lose both.
device_output=""
device_status=0
check_device() {
  device_output="$(python3 "$device_check" "$1" "$table_json" "$uuids_txt" "$names_txt" 2>&1)"
  device_status=$?
}

# mutate <mode> <out>: a deliberately broken copy of the identity file.
mutate() {
  python3 - "$device_json" "$2" "$1" <<'PY'
import json, sys
src, out, mode = sys.argv[1:4]
data = json.load(open(src, encoding="utf-8"))
if mode == "missing":
    del data["partitions"]["ab-slot-b"]["partuuid"]
elif mode == "duplicate":
    data["partitions"]["ab-data"]["partuuid"] = data["partitions"]["ab-esp"]["partuuid"]
elif mode == "label":
    data["labels"]["ab-data"] = "ab-shared"
json.dump(data, open(out, "w", encoding="utf-8"))
PY
}

check_device "$device_json"
assert_eq "$device_status" "0" "ac-7 a complete identity file passes"

mutate missing "$tmp/missing.json"
check_device "$tmp/missing.json"
assert_eq "$device_status" "1" "ac-7 a missing PARTUUID fails the build"
assert_contains "$device_output" "partitions.ab-slot-b.partuuid is missing" \
  "ac-7 the failure names the missing field"

mutate duplicate "$tmp/duplicate.json"
check_device "$tmp/duplicate.json"
assert_eq "$device_status" "1" "ac-7 a repeated PARTUUID fails the build"
assert_contains "$device_output" "repeats partitions.ab-esp" \
  "ac-7 the failure names the partition it repeats"

mutate label "$tmp/label.json"
check_device "$tmp/label.json"
assert_eq "$device_status" "1" "ac-7 a label that disagrees with the filesystem fails the build"
assert_contains "$device_output" "labels.ab-data" \
  "ac-7 the failure names the label entry"

# --------------------------------------------------------------------------- #
# ac-3/ac-4 network seed in the artifacts: hook, start link and rendered constants
# --------------------------------------------------------------------------- #
# A first boot only reaches a configuration if three things ship together: the hook,
# the rcS start link that runs it before netifd, and the rendered constants it applies.
# The image (disk.sh) and the release payload (assemble.sh) are produced by two
# different scripts, and each has to render before it tars. A render placed after the
# tar produces a layer without etc/net-defaults.conf, and the box then quietly falls
# back to the library's built-in defaults - a difference that only becomes visible when
# a build overrides a CI_NET_* value, i.e. exactly on the release where it matters.
first_line_of() { grep -n "$2" "$1" | head -n 1 | cut -d: -f1; }

assert_contains "$(cat "$disk_script")" 'ci_render_net_defaults "${platform_stage}"' \
  "ac-4 disk.sh renders net-defaults into the image's platform layer"
assert_contains "$(cat "$assemble_script")" 'ci_render_net_defaults "${platform_stage}"' \
  "ac-4 assemble.sh renders net-defaults into the payload's platform layer"
# payload-build.sh is the payload the upgrade test installs; it ships a platform layer
# too, so the same render has to happen there or an upgraded slot comes up on fallback
# defaults.
assert_contains "$(cat "$payload_script")" 'ci_render_net_defaults "' \
  "ac-4 the upgrade payload renders net-defaults into its platform layer"

for pair in "disk:${disk_script}" "assemble:${assemble_script}"; do
  name="${pair%%:*}"
  script="${pair#*:}"
  render_line="$(first_line_of "$script" 'ci_render_net_defaults')"
  tar_line="$(grep -n -- '-cf' "$script" | grep 'platform.tar' | head -n 1 | cut -d: -f1)"
  [ -n "$render_line" ] && [ -n "$tar_line" ] && [ "$render_line" -lt "$tar_line" ] &&
    assert_eq "before-tar" "before-tar" \
      "ac-8 $name renders net-defaults before the platform layer is tarred" ||
    assert_eq "render=${render_line:-none} tar=${tar_line:-none}" "render-before-tar" \
      "ac-8 $name renders net-defaults before the platform layer is tarred"
done

# The behaviour, not just the call: stage the platform tree exactly the way both
# producers do, tar it, and read the artifact back. This is what the image and the
# payload really carry, so a function that stops writing the file, or a start link
# that stops pointing at the hook, fails here.
seed_stage="$tmp/platform-stage"
mkdir -p "$seed_stage"
cp -a "$root/platform/." "$seed_stage/"
# In a subshell: scripts/ci/lib.sh turns on `set -e`, which this test must not inherit.
(
  # shellcheck source=scripts/ci/lib.sh
  . "$root/scripts/ci/lib.sh"
  ci_render_net_defaults "$seed_stage"
  ci_platform_startlinks "$seed_stage"
) >"$tmp/stage.log" 2>&1 || {
  cat "$tmp/stage.log" >&2
  assert_eq "staging-failed" "staged" "ac-4 the platform layer stages with the seed files"
}
seed_tar="$tmp/platform.tar"
tar -cf "$seed_tar" -C "$seed_stage" .
seed_members="$(tar -tf "$seed_tar" | sed 's|^\./||' | paste -sd, -)"
assert_contains "${seed_members}," "etc/net-defaults.conf," \
  "ac-4 the platform tarball carries etc/net-defaults.conf"
assert_contains "${seed_members}," "etc/init.d/ab-net-seed," \
  "ac-4 the platform tarball carries the seed hook"
assert_contains "${seed_members}," "etc/rc.d/S16ab-net-seed," \
  "ac-4 the platform tarball carries the S16 start link"
assert_eq "$(printf '%s' "$seed_members" | tr ',' '\n' | grep -c '^etc/config/network$')" "0" \
  "ac-3 the platform tarball does not bake a static /etc/config/network"

seed_conf="$(tar -xOf "$seed_tar" ./etc/net-defaults.conf 2>/dev/null)"
assert_contains "${seed_conf}" "NET_WAN_SSH=closed" \
  "ac-4 the shipped constants keep the WAN SSH exception closed"
assert_contains "${seed_conf}" "NET_LAN_ADDR=192.168.100.1" \
  "ac-4 the shipped constants use the project LAN address, not 192.168.1.1"
assert_contains "${seed_conf}" "NET_WAN_DEV=eth0" \
  "ac-4 the shipped constants name eth0 as the WAN"
# A placeholder that reached the artifact is a literal value to the library.
if printf '%s' "${seed_conf}" | grep -Eq '@[A-Z_][A-Z0-9_]*@'; then
  assert_eq "placeholder" "none" "ac-4 no placeholder survives into the platform tarball"
else
  assert_eq "none" "none" "ac-4 no placeholder survives into the platform tarball"
fi

seed_link_target="$(tar -tvf "$seed_tar" | sed -n 's|.*etc/rc\.d/S16ab-net-seed -> ||p' | head -n 1)"
assert_eq "${seed_link_target}" "../init.d/ab-net-seed" \
  "ac-4 the S16 start link points at the hook, so rcS runs it"
seed_hook_body="$(tar -xOf "$seed_tar" ./etc/init.d/ab-net-seed 2>/dev/null)"
assert_contains "${seed_hook_body}" "wf_net_seed" \
  "ac-4 the shipped hook calls the library, not a copy of it"
seed_lib_body="$(tar -xOf "$seed_tar" ./lib/net-defaults.sh 2>/dev/null)"
assert_contains "${seed_lib_body}" "wf_net_seed()" \
  "ac-4 the shipped library defines the entry point the hook calls"

# The in-guest assertion runs before the first boot, so it reads the same three facts
# out of the image. Pinning them here keeps the two halves of one contract together.
guest_assert_body="$(cat "$root/tests/modules/image/guest-assert.sh")"
for token in net-seed-startlink-missing net-seed-network-baked-in net-seed-placeholder \
  net-seed-board-detect-missing; do
  assert_contains "${guest_assert_body}" "${token}" \
    "ac-3 the S2 guest assertion fails on ${token#net-seed-}"
done

# The one runtime half a boot can observe: S4 boot 1 carries the network fixture written
# into the writable layer, so S16 has to log result=skip instead of rewriting it. That is
# "no overwrite" seen on a real boot rather than in a stub, and it only holds while both
# halves stay put - the fixture step and the log expectation.
s4_flow="$(cat "$root/.github/workflows/ci-s4.yml")"
assert_contains "${s4_flow}" 'ab-fixtures.sh --network' \
  "ac-3 S4 injects a network fixture before the first boot"
assert_contains "${s4_flow}" "--expect-log 'stage=net-seed result=skip'" \
  "ac-3 S4 boot 1 asserts the seed skipped the existing configuration"

finish
