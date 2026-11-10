#!/usr/bin/env bash
# Stage "image-verify": assert the assembled image against docs/partitions.md.
#
# This runs on the host against the raw image, so a regression is caught with a
# precise message and without waiting for a boot. The QEMU stage repeats the
# structural part from inside the guest, which is the independent view.
#
# Checks:
#   1. four partitions, GPT PARTNAMEs exactly ab-esp / ab-slot-a / ab-slot-b / ab-data
#      and filesystem LABELs exactly ESP / slot-a / slot-b / data
#   2. sizes exactly 128/128/128/128 MiB, p1 typed as EFI system partition
#   3. p2/p3 hold exactly @sys and @platform; p4 holds @overlay-<version>, @docker, @swap,
#      @data; every subvolume is top level and nothing is nested
#   4. @sys matches the upstream rootfs tree file for file (content compare)
#   5. p1 content stays under 64 MiB
#   6. @docker and @swap carry the nodatacow attribute
#   7. p1 carries boot/grub/ab-slot.cfg: `set default=`/`set fallback=` only, default on
#      the committed slot, and no environment-block calls this GRUB cannot run
#   8. p1 carries ab/device.json: four distinct PARTUUIDs that match the partition
#      table, a disk GUID that matches the table, and the labels the filesystems carry
#
# Inputs (environment):
#   CI_IMAGE          raw image produced by the disk stage
#   CI_DISK_DIR       scratch directory used by the disk stage (holds rootfs tree)
#   CI_EXPECT_OUT     where to write the guest expectation file
#   CI_SAMPLES        how many @sys files to sample for the guest (default: 12)
#   CI_OVERLAY_NAME   writable layer name (default: @overlay-${CI_UPSTREAM_VERSION})
#
# Outputs: image_bytes, rootfs_files, esp_bytes, expect_file, part_names_file,
#          device_json, verified_checks

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init image-verify

ci_require_cmd sudo losetup sfdisk blkid lsblk python3 diff sha256sum

image="${CI_IMAGE:?CI_IMAGE is required}"
disk_dir="${CI_DISK_DIR:-${CI_TMP_ROOT}/disk}"
expect_out="${CI_EXPECT_OUT:-${disk_dir}/s2-expect.txt}"
sample_count="${CI_SAMPLES:-12}"
rootfs_tree="${disk_dir}/rootfs"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
overlay_name="${CI_OVERLAY_NAME:-@overlay-${upstream_version}}"

[ -f "${image}" ] || ci_die "image not found: ${image}"
[ -d "${rootfs_tree}" ] || ci_die "rootfs tree not found: ${rootfs_tree}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required to inspect the image"

checks=0
note() {
    checks=$((checks + 1))
    ci_log "ok ${checks}: $1"
}

mntroot="${disk_dir}/verify-mnt"
mkdir -p "${mntroot}"
loopdev=""
cleanup() {
    if [ -n "${loopdev}" ]; then
        for dir in "${mntroot}"/p1 "${mntroot}"/p2 "${mntroot}"/p3 "${mntroot}"/p4; do
            sudo umount "${dir}" 2>/dev/null || true
        done
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --show --partscan "${image}")"
attempt=0
until [ -b "${loopdev}p4" ] || [ "${attempt}" -ge 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
done

# --------------------------------------------------------------------------- #
# 1./2. Partition table
# --------------------------------------------------------------------------- #

# Read both name sets back from the image itself, never from the script that wrote it:
# PARTNAME comes from the GPT entry, LABEL from the filesystem superblock. A drift in
# either one is caught here, before QEMU costs a boot cycle.
part_name() {
    local device="$1" field="$2" value=""
    value="$(sudo blkid -p -o value -s "${field}" "${device}" 2>/dev/null || true)"
    if [ -z "${value}" ]; then
        # lsblk reads the same fields through udev; it covers a blkid without -p.
        value="$(sudo lsblk -ndo "${field}" "${device}" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')"
    fi
    printf '%s' "${value}"
}

# shellcheck disable=SC2024  # the redirect target is owned by the runner user
sudo sfdisk -J "${loopdev}" >"${disk_dir}/sfdisk-verify.json"
: >"${disk_dir}/part-names.txt"
: >"${disk_dir}/part-uuids.txt"
for index in 1 2 3 4; do
    printf 'p%s|%s|%s\n' "${index}" \
        "$(part_name "${loopdev}p${index}" PARTLABEL)" \
        "$(part_name "${loopdev}p${index}" LABEL)" >>"${disk_dir}/part-names.txt"
    printf 'p%s|%s|%s\n' "${index}" \
        "$(part_name "${loopdev}p${index}" PARTLABEL)" \
        "$(part_name "${loopdev}p${index}" PARTUUID)" >>"${disk_dir}/part-uuids.txt"
done
python3 - "${disk_dir}/sfdisk-verify.json" "${disk_dir}/part-names.txt" <<'PYTHON'
import json, sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))["partitiontable"]
parts = doc["partitions"]
# (GPT PARTNAME, filesystem LABEL, size in sectors, partition type)
want = [
    ("ab-esp", "ESP", 262144, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"),
    ("ab-slot-a", "slot-a", 262144, "0FC63DAF-8483-4772-8E79-3D69D8477DE4"),
    ("ab-slot-b", "slot-b", 262144, "0FC63DAF-8483-4772-8E79-3D69D8477DE4"),
    ("ab-data", "data", 262144, "0FC63DAF-8483-4772-8E79-3D69D8477DE4"),
]

readback = {}
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    index, partname, fslabel = line.split("|")
    readback[index] = (partname, fslabel)

problems = []
if len(parts) != len(want):
    problems.append(f"expected 4 partitions, found {len(parts)}")
for index, (partname, fslabel, sectors, type_guid) in enumerate(want):
    number = index + 1
    if index >= len(parts):
        problems.append(f"p{number}: missing partition")
        continue
    part = parts[index]
    if part.get("name") != partname:
        problems.append(f"p{number}: GPT PARTNAME {part.get('name')!r} != {partname!r}")
    if part.get("size") != sectors:
        problems.append(f"p{number}: size {part.get('size')} sectors != {sectors}")
    if part.get("type", "").upper() != type_guid.upper():
        problems.append(f"p{number}: type {part.get('type')} != {type_guid}")
    have_partname, have_label = readback.get(f"p{number}", ("", ""))
    if have_partname != partname:
        problems.append(f"p{number}: read-back PARTNAME {have_partname!r} != {partname!r}")
    if have_label != fslabel:
        problems.append(f"p{number}: filesystem LABEL {have_label!r} != {fslabel!r}")
if problems:
    print("[image-verify] partition naming problems:", file=sys.stderr)
    for item in problems:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
print("[image-verify] PARTNAME ab-esp/ab-slot-a/ab-slot-b/ab-data and "
      "LABEL ESP/slot-a/slot-b/data match docs/partitions.md")
PYTHON
note "four partitions carry the documented PARTNAME and LABEL, plus the sizes and types"

# --------------------------------------------------------------------------- #
# 3.-6. Filesystems
# --------------------------------------------------------------------------- #

# subvolumes <partition-index> -> sorted "path|top-level" lines
subvolumes() {
    local part="$1" mnt="${mntroot}/p$1"
    mkdir -p "${mnt}"
    sudo mount -o ro "${loopdev}p${part}" "${mnt}"
    sudo btrfs subvolume list "${mnt}" | sed -n 's/.*top level \([0-9]*\) path \(.*\)$/\2|\1/p' | LC_ALL=C sort
    sudo umount "${mnt}"
}

assert_subvolumes() {
    local part="$1" expected="$2" actual
    actual="$(subvolumes "${part}" | cut -d'|' -f1 | paste -sd, -)"
    # Compare as sets: the listing is sorted, so naming changes reorder a valid result.
    local sorted_actual sorted_expected
    sorted_actual="$(printf '%s\n' ${actual//,/ } | LC_ALL=C sort | paste -sd, -)"
    sorted_expected="$(printf '%s\n' ${expected//,/ } | LC_ALL=C sort | paste -sd, -)"
    if [ "${sorted_actual}" != "${sorted_expected}" ]; then
        ci_die "p${part} subvolumes are '${actual}', expected '${expected}'"
    fi
    if subvolumes "${part}" | grep -qv '|5$'; then
        ci_die "p${part} has a subvolume outside the top level: $(subvolumes "${part}" | grep -v '|5$')"
    fi
    # btrfs subvolume list -o lists subvolumes below a path, and every subvolume is
    # below the filesystem root, so asking at the root proves nothing. Mount each
    # subvolume by name and assert that nothing lives underneath it.
    local name mnt nested
    for name in ${expected//,/ }; do
        mnt="${mntroot}/p${part}-${name#@}"
        mkdir -p "${mnt}"
        sudo mount -o "ro,subvol=/${name}" "${loopdev}p${part}" "${mnt}"
        nested="$(sudo btrfs subvolume list -o "${mnt}")"
        sudo umount "${mnt}"
        if [ -n "${nested}" ]; then
            ci_die "p${part}/${name} has nested subvolumes: ${nested}"
        fi
    done
}

assert_subvolumes 2 "@sys,@platform"
note "p2 holds @sys and @platform at the top level, no nesting"

assert_subvolumes 3 "@sys,@platform"
note "p3 holds @sys and @platform at the top level, no nesting"

# If btrfs refuses `subvolume list -o` a nested subvolume can still be caught through
# the sorted path list: a nested entry would be listed as e.g. "@sys/child".
for part in 2 3; do
    if subvolumes "${part}" | cut -d'|' -f1 | grep -q '/'; then
        ci_die "p${part} contains a nested subvolume path"
    fi
done

assert_subvolumes 4 "@data,@docker,${overlay_name},@swap"
note "p4 holds ${overlay_name}, @docker, @swap and @data at the top level"

p4="${mntroot}/p4"
mkdir -p "${p4}"
sudo mount -o ro "${loopdev}p4" "${p4}"
for entry in upper work; do
    [ -d "${p4}/${overlay_name}/${entry}" ] || ci_die "${overlay_name}/${entry} is missing"
    if sudo btrfs subvolume list "${p4}" | grep -q "${overlay_name}/${entry}"; then
        ci_die "${overlay_name}/${entry} must be a plain directory, not a subvolume"
    fi
done
note "${overlay_name} contains plain upper/ and work/ directories"

for swap_like in "@docker" "@swap"; do
    attrs="$(sudo lsattr -d "${p4}/${swap_like}" | awk '{print $1}')"
    case "${attrs}" in
        *C*) : ;;
        *) ci_die "${swap_like} is missing the nodatacow attribute (lsattr: ${attrs})" ;;
    esac
done
sudo umount "${p4}"
note "@docker and @swap are marked nodatacow"

# --------------------------------------------------------------------------- #
# 4. @sys must be byte-identical to the upstream rootfs tree
# --------------------------------------------------------------------------- #

p2="${mntroot}/p2"
mkdir -p "${p2}"
sudo mount -o ro "${loopdev}p2" "${p2}"
tree_files="$(sudo find "${rootfs_tree}" -type f | wc -l | tr -d ' ')"
sys_files="$(sudo find "${p2}/@sys" -type f | wc -l | tr -d ' ')"
if [ "${tree_files}" != "${sys_files}" ]; then
    ci_die "@sys has ${sys_files} file(s), the upstream rootfs tree has ${tree_files}"
fi
# shellcheck disable=SC2024  # the redirect target is owned by the runner user
if ! sudo diff -r --no-dereference "${rootfs_tree}" "${p2}/@sys" >"${disk_dir}/sys-diff.log" 2>&1; then
    head -n 20 "${disk_dir}/sys-diff.log" | sed 's/^/[image-verify]   /'
    ci_die "@sys differs from the upstream rootfs tree, see ${disk_dir}/sys-diff.log"
fi
note "@sys matches the upstream rootfs tree (${sys_files} files, content compared)"

# Sample digests for the guest assertion; the guest recomputes them from inside.
: >"${expect_out}"
printf 'files=%s\n' "${sys_files}" >"${expect_out}"
printf 'images=%s\n' "$(ci_file_size "${image}")" >>"${expect_out}"
printf 'parts=4\n' >>"${expect_out}"
printf 'overlay=%s\n' "${overlay_name}" >>"${expect_out}"
printf 'p1max_kib=65536\n' >>"${expect_out}"
# awk bounds the list without closing the pipe early: head would make sort die on
# SIGPIPE, and pipefail turns that into a stage failure.
sudo find "${rootfs_tree}" -type f -size +0 -size -256k | LC_ALL=C sort \
    | awk -v n="${sample_count}" 'NR<=n' \
    | while IFS= read -r path; do
        rel="${path#"${rootfs_tree}"}"
        printf 'sample %s %s\n' "${rel}" "$(sudo sha256sum "${path}" | cut -d' ' -f1)"
    done >>"${expect_out}"
sudo umount "${p2}"
note "wrote ${expect_out} with ${sample_count} sample digest(s)"

p1="${mntroot}/p1"
mkdir -p "${p1}"
sudo mount -o ro "${loopdev}p1" "${p1}"

# The state file the boot initramfs reads has to name the layer that exists.
state_uppers="$(sudo sed -n 's/.*"upper": *"\([^"]*\)".*/\1/p' "${p1}/ab/state.json" 2>/dev/null | sort -u | paste -sd, -)"
[ "${state_uppers}" = "${overlay_name}" ] \
    || ci_die "ab/state.json names '${state_uppers}', the image carries '${overlay_name}'"
note "ab/state.json names the ${overlay_name} layer"

# --------------------------------------------------------------------------- #
# 5. p1 budget and structure
# --------------------------------------------------------------------------- #

esp_bytes="$(sudo du -sb "${p1}" | cut -f1)"
esp_kib="$(sudo du -sk "${p1}" | cut -f1)"
if [ "${esp_bytes}" -ge $((64 * 1024 * 1024)) ]; then
    ci_die "p1 content is ${esp_bytes} bytes, over the 64 MiB budget"
fi
[ -n "$(sudo find "${p1}" -type f -iname '*.efi' | head -n 1)" ] \
    || ci_die "p1 has no EFI loader"
for required in \
    boot/grub \
    vmlinuz-a vmlinuz-b \
    initrd-a initrd-b \
    ab ab/log; do
    [ -e "${p1}/${required}" ] || ci_die "p1 is missing ${required}"
done
esp_source="${CI_ESP_DIR:-${CI_TMP_ROOT}/esp}"
# disk.sh installs files of its own into the prepared tree (the rendered menu, the slot
# fragment and ab/device.json); the comparison is about the module set the upstream
# bootloader archive supplied, so every one of them is excluded on both sides.
grub_installed='(^|/)(grub\.cfg|ab-slot\.cfg|device\.json)$'
if [ -d "${esp_source}/boot/grub" ]; then
    if ! diff -q \
        <(sudo find "${p1}/boot/grub" -type f | sed "s|${p1}/||" | grep -vE "${grub_installed}" | sort) \
        <(find "${esp_source}/boot/grub" -type f | sed "s|${esp_source}/||" | grep -vE "${grub_installed}" | sort) >/dev/null; then
        ci_die "p1 boot/grub differs from the prepared ESP tree"
    fi
else
    ci_warn "prepared ESP tree not available, skipping the grub tree comparison"
fi

# The menu `source`s this fragment to learn which slot to try first. The shipped
# BOOTX64.EFI has no env module, so the fragment is plain config: `load_env` or
# `save_env` in it would be a silent no-op on a real machine, which is worse than a
# build failure here.
ab_slot_cfg="${p1}/boot/grub/ab-slot.cfg"
[ -f "${ab_slot_cfg}" ] || ci_die "p1 is missing boot/grub/ab-slot.cfg"
ab_slot_body="$(sudo cat "${ab_slot_cfg}")"
ab_slot_default="$(printf '%s\n' "${ab_slot_body}" | sed -n 's/^set default=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
ab_slot_fallback="$(printf '%s\n' "${ab_slot_body}" | sed -n 's/^set fallback=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
[ -n "${ab_slot_default}" ] \
    || ci_die "boot/grub/ab-slot.cfg has no 'set default=<index>' line"
[ -n "${ab_slot_fallback}" ] \
    || ci_die "boot/grub/ab-slot.cfg has no 'set fallback=<index>' line"
for env_call in load_env save_env; do
    if printf '%s\n' "${ab_slot_body}" | grep -q "${env_call}"; then
        ci_die "boot/grub/ab-slot.cfg calls ${env_call}, the shipped GRUB has no environment block"
    fi
done
# `default` has to name the committed slot, the same slot ab/state.json reports: entry 0
# is slot a and entry 1 is slot b, the only menu order the image ships. A freshly built
# image has nothing pending, so `default` and `fallback` naming the same slot is correct
# here (platform/lib/ab-slot-cfg.sh documents the pair); they only diverge once a slot is
# pending, which is a runtime state this stage never sees.
committed="$(sudo sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "${p1}/ab/state.json" | head -n 1)"
[ -n "${committed}" ] || ci_die "ab/state.json names no committed slot"
case "${committed}" in
    a) committed_index=0 ;;
    b) committed_index=1 ;;
esac
[ "${ab_slot_default}" = "${committed_index}" ] \
    || ci_die "boot/grub/ab-slot.cfg defaults to entry ${ab_slot_default}, the committed slot ${committed} is entry ${committed_index}"
note "boot/grub/ab-slot.cfg defaults to the committed slot ${committed} and calls no env command"

# The identity file is what the running system recognises this disk by, before it looks
# at any device name. A PARTUUID that is missing, blank, duplicated or out of step with
# the table turns disk identification into a guess, so each of those is a build failure.
device_json="${p1}/ab/device.json"
[ -f "${device_json}" ] || ci_die "p1 is missing ab/device.json"
python3 - "${device_json}" "${disk_dir}/sfdisk-verify.json" "${disk_dir}/part-uuids.txt" \
    "${disk_dir}/part-names.txt" <<'PYTHON'
import json, sys

device_path, table_path, uuid_path, name_path = sys.argv[1:5]
partnames = ("ab-esp", "ab-slot-a", "ab-slot-b", "ab-data")

problems = []
try:
    device = json.load(open(device_path, encoding="utf-8"))
except (OSError, ValueError) as exc:
    print(f"[image-verify] ab/device.json is not readable JSON: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(device, dict):
    print("[image-verify] ab/device.json is not a JSON object", file=sys.stderr)
    sys.exit(1)

if device.get("format") != "ab-device/1":
    problems.append(f"format {device.get('format')!r} != 'ab-device/1'")

table = json.load(open(table_path, encoding="utf-8"))["partitiontable"]
disk = device.get("disk") or {}
partitions = device.get("partitions") or {}
labels = device.get("labels") or {}

gpt_id = str(table.get("id", ""))
label_id = str(disk.get("label_id", ""))
if not label_id:
    problems.append("disk.label_id is missing")
elif label_id.lower() != gpt_id.lower():
    problems.append(f"disk.label_id {label_id!r} != the table GUID {gpt_id!r}")

# What the devices carry, read back with blkid: pN|PARTNAME|PARTUUID and pN|PARTNAME|LABEL.
def read_pairs(path):
    pairs = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        _, partname, value = line.split("|")
        pairs[partname] = value
    return pairs


carried_uuids = read_pairs(uuid_path)
carried_labels = read_pairs(name_path)

extra = sorted(set(partitions) - set(partnames))
if extra:
    problems.append(f"partitions describes unexpected entries: {', '.join(extra)}")

seen = {}
for partname in partnames:
    entry = partitions.get(partname) or {}
    partuuid = str(entry.get("partuuid", ""))
    if not partuuid:
        problems.append(f"partitions.{partname}.partuuid is missing")
    elif partuuid.lower() in seen:
        problems.append(
            f"partitions.{partname}.partuuid repeats partitions.{seen[partuuid.lower()]}"
        )
    else:
        seen[partuuid.lower()] = partname
        carried = carried_uuids.get(partname, "")
        if partuuid.lower() != carried.lower():
            problems.append(
                f"partitions.{partname}.partuuid {partuuid!r} != the device PARTUUID {carried!r}"
            )
    recorded_label = labels.get(partname)
    if recorded_label is None:
        problems.append(f"labels.{partname} is missing")
    elif recorded_label != carried_labels.get(partname):
        problems.append(
            f"labels.{partname} {recorded_label!r} != the filesystem label "
            f"{carried_labels.get(partname)!r}"
        )

if problems:
    print("[image-verify] ab/device.json problems:", file=sys.stderr)
    for item in problems:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
print("[image-verify] ab/device.json carries four distinct PARTUUIDs and matching labels")
PYTHON
note "ab/device.json carries four distinct PARTUUIDs that match the partition table"

sudo umount "${p1}"
note "p1 carries GRUB, both kernels, both initrds, ab/ and ab/log/ (${esp_kib} KiB of 65536)"

sudo losetup -d "${loopdev}"
loopdev=""
trap on_error ERR

ci_log "all ${checks} host check(s) passed"
ci_emit_output "image_bytes" "$(ci_file_size "${image}")"
ci_emit_output "rootfs_files" "${sys_files}"
ci_emit_output "esp_bytes" "${esp_bytes}"
ci_emit_output "expect_file" "${expect_out}"
ci_emit_output "part_names_file" "${disk_dir}/part-names.txt"
ci_emit_output "device_json" "${device_json}"
ci_emit_output "verified_checks" "${checks}"

ci_log "stage image-verify finished"
