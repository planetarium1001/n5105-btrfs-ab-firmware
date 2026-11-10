#!/usr/bin/env bash
# Stage "disk": assemble the four-partition disk image.
#
# Geometry, frozen by docs/partitions.md. Every partition carries two names: the GPT
# PARTNAME that the code discovers partitions by, and the filesystem LABEL humans read.
#
#   p1  ab-esp     128 MiB  vfat   ESP      GRUB, ab-slot.cfg, vmlinuz-a/b, initrd-a/b, ab/, ab/log/
#   p2  ab-slot-a  128 MiB  btrfs  slot-a   @sys, @platform
#   p3  ab-slot-b  128 MiB  btrfs  slot-b   @sys, @platform
#   p4  ab-data    128 MiB  btrfs  data     @overlay-<version> (upper/, work/), @docker, @swap, @data
#
# PARTNAME keeps the ab- prefix because discovery walks /sys/class/block/*/uevent, where
# a bare "data" or "esp" would collide with any other disk attached to the same machine.
# LABEL carries no version: the version already lives in @overlay-<version>,
# /etc/platform-release and ab/state.json, and relabelling on every release adds a FAT
# and btrfs superblock write that power loss can interrupt.
#
# The image is 514 MiB: 1 MiB of alignment before p1, 512 MiB of partitions and 1 MiB
# of tail so the backup GPT has room. p4 ships 128 MiB: a writable layer of 64 MiB could
# not hold the update fixture (20 MiB into upper left it at 63/64 MiB and overlayfs could
# not create work/). First boot still grows p4 to the end of the real disk.
#
# Filesystem arguments are taken verbatim from docs/partitions.md:
#   p2/p3  mkfs.btrfs -m dup -d single     (metadata duplication inside a slot)
#   p4     mkfs.btrfs -m single -d single  (container layers inflate metadata)
#
# Inputs (environment):
#   CI_FETCH_DIR      directory holding upstream/rootfs.tar.gz and upstream/kernel.bin
#   CI_ESP_DIR        ESP tree prepared by the esp stage
#   CI_INITRAMFS      initramfs image to install as initrd-a/b for now
#   CI_DISK_DIR       scratch directory (default: $CI_TMP_ROOT/disk)
#   CI_DISK_OUT       output image path (default: $CI_DISK_DIR/<name>.img)
#   CI_PLATFORM_VERSION  version recorded in the platform release file
#   CI_UPSTREAM_VERSION  upstream release label recorded in the platform release file
#   CI_PLATFORM_SRC      platform layer source tree (default: platform/)
#   CI_PLATFORM_RUNTIME_DIR  btrfs tooling staged by the runtime stage (default: $CI_TMP_ROOT/runtime)
#   CI_PLATFORM_LIMIT_BYTES  budget for the unpacked @platform layer (default: 8 MiB)
#   CI_GRUB_TEMPLATE     GRUB template (default: scripts/ci/grub.cfg.in)
#   CI_AB_SLOT_CFG_SOURCE  host path of the rendered ab-slot.cfg (default: the path
#                        grub-render reports, else <grub.cfg dir>/ab-slot.cfg)
#
# Outputs: image_path, image_gz_path, image_bytes, image_gz_bytes, rootfs_files,
#          rootfs_bytes, esp_bytes, part_layout

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

ci_stage_init disk

ci_require_cmd sudo losetup sfdisk mkfs.vfat mkfs.btrfs chattr gzip tar

fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
esp_dir="${CI_ESP_DIR:?CI_ESP_DIR is required}"
initramfs="${CI_INITRAMFS:?CI_INITRAMFS is required}"
rootfs_tar="${fetch_dir}/upstream/rootfs.tar.gz"
kernel="${fetch_dir}/upstream/kernel.bin"
disk_dir="${CI_DISK_DIR:-${CI_TMP_ROOT}/disk}"
image="${CI_DISK_OUT:-${disk_dir}/n5105-ab-image.img}"
platform_version="${CI_PLATFORM_VERSION:-0.0.1}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required, the writable layer is named after it}"
# The writable layer is named after the upstream release: @overlay-<version>, with a
# -r<N> suffix when the same release is shipped again with a different platform layer.
overlay_name="${CI_OVERLAY_NAME:-@overlay-${upstream_version}}"

[ -f "${rootfs_tar}" ] || ci_die "upstream rootfs not found: ${rootfs_tar}"
[ -f "${kernel}" ] || ci_die "upstream kernel not found: ${kernel}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"
[ -n "$(find "${esp_dir}" -type f -iname '*.efi' | head -n 1)" ] \
    || ci_die "ESP tree has no EFI loader: ${esp_dir}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required to build the image"

mkdir -p "${disk_dir}"

# --------------------------------------------------------------------------- #
# 1. Partition table
# --------------------------------------------------------------------------- #

# 514 MiB in 512-byte sectors: 1 MiB alignment, 512 MiB of partitions, 1 MiB tail.
image_sectors=1052672
truncate -s $((image_sectors * 512)) "${image}"
ci_log "blank image: ${image} ($((image_sectors * 512)) bytes)"

loopdev=""
mounted=()
cleanup() {
    if [ -n "${loopdev}" ]; then
        local mnt
        for mnt in ${mounted[@]+"${mounted[@]}"}; do
            sudo umount "${mnt}" 2>/dev/null || true
        done
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Write the table through the loop device so the kernel owns the block device from
# the start; p1 begins at 1 MiB, which is the alignment firmware and GRUB expect.
loopdev="$(sudo losetup --find --show --partscan "${image}")"
# shellcheck disable=SC2024  # the log path is owned by the runner user
sudo sfdisk --wipe=always "${loopdev}" >"${disk_dir}/sfdisk.log" 2>&1 <<'SFDISK'
label: gpt
label-id: 6E353130-352D-4142-4653-000000000001
unit: sectors

start=   2048, size=262144, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ab-esp"
start= 264192, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ab-slot-a"
start= 526336, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ab-slot-b"
start= 788480, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ab-data"
SFDISK
# Re-attach so the kernel scans the table it has just been given; this is more
# reliable than poking the in-kernel table with partx.
sudo partx -u "${loopdev}" 2>/dev/null || true
if [ ! -b "${loopdev}p4" ]; then
    sudo losetup -d "${loopdev}"
    loopdev="$(sudo losetup --find --show --partscan "${image}")"
fi
ci_log "partition table written, loop device ${loopdev}"

dev_p1="${loopdev}p1"
dev_p2="${loopdev}p2"
dev_p3="${loopdev}p3"
dev_p4="${loopdev}p4"
attempt=0
until [ -b "${dev_p4}" ] || [ "${attempt}" -ge 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
done
for dev in "${dev_p1}" "${dev_p2}" "${dev_p3}" "${dev_p4}"; do
    [ -b "${dev}" ] || ci_die "partition device did not appear: ${dev}"
done
ci_log "loop device ${loopdev} with four partitions"

# mount_part <device> <tag>: mount under the scratch directory and remember it.
# The result is returned through mount_target rather than stdout: a command
# substitution would run this in a subshell and lose the cleanup bookkeeping.
mount_target=""
mount_part() {
    local device="$1" tag="$2"
    mount_target="${disk_dir}/mnt/${tag}"
    mkdir -p "${mount_target}"
    sudo mount "${device}" "${mount_target}"
    mounted+=("${mount_target}")
}

unmount_part() {
    local target="$1"
    sudo sync
    sudo umount "${target}"
}

# --------------------------------------------------------------------------- #
# 1b. Platform layer tarball and GRUB configuration
# --------------------------------------------------------------------------- #

platform_src="${CI_PLATFORM_SRC:-${CI_REPO_ROOT}/platform}"
[ -d "${platform_src}" ] || ci_die "platform source tree not found: ${platform_src}"
platform_stage="${disk_dir}/platform-stage"
rm -rf "${platform_stage}"
mkdir -p "${platform_stage}"
cp -a "${platform_src}/." "${platform_stage}/"

# platform/etc/platform-release is a template: the version comes from the build.
ci_render_release "${platform_stage}/etc/platform-release" \
    "${platform_version}" "${upstream_version}" "image"

# The btrfs user space tooling has no place in @sys (that tree must stay byte
# identical to upstream), so stage "runtime" hands over a ready tree that is merged
# into the platform layer here: usr/sbin/btrfs plus the libraries the root
# filesystem does not provide.
runtime_tree="${CI_PLATFORM_RUNTIME_DIR:-${CI_TMP_ROOT}/runtime}"
if [ -d "${runtime_tree}" ]; then
    mkdir -p "${platform_stage}/usr/sbin" "${platform_stage}/usr/lib"
    cp -a "${runtime_tree}/." "${platform_stage}/"
    ci_log "platform layer carries the runtime tooling from ${runtime_tree}"
else
    ci_warn "no runtime tree at ${runtime_tree}: the platform layer will have no btrfs tool"
fi
[ -x "${platform_stage}/usr/sbin/btrfs" ] ||
    ci_die "the platform layer has no runnable usr/sbin/btrfs, reclamation would be blind"

platform_tar="${disk_dir}/platform.tar"
( cd "${platform_stage}" && tar --numeric-owner --owner=0 --group=0 -cf "${platform_tar}" . )
ci_log "platform layer: $(tar -tf "${platform_tar}" | wc -l | tr -d ' ') entries, $(ci_file_size "${platform_tar}") bytes"

grub_output="${disk_dir}/grub.cfg"
# grub-render publishes its results through ci_emit_output. Point CI_OUTPUT_ENV at a file
# of our own so this stage can read the menu and ab-slot.cfg paths back; the step's
# Actions output file keeps receiving the same keys as before.
grub_outputs="${disk_dir}/grub-render.outputs"
: >"${grub_outputs}"
CI_GRUB_OUTPUT="${grub_output}" \
    CI_GRUB_TEMPLATE="${CI_GRUB_TEMPLATE:-${CI_REPO_ROOT}/scripts/ci/grub.cfg.in}" \
    CI_COMMITTED_SLOT="${CI_COMMITTED_SLOT:-a}" \
    CI_OUTPUT_ENV="${grub_outputs}" \
    bash "${CI_SCRIPT_DIR}/grub-render.sh" >"${disk_dir}/grub-render.log" 2>&1 \
    || ci_die "GRUB configuration rendering failed, see ${disk_dir}/grub-render.log"
grub_sha="$(ci_sha256 "${grub_output}")"
ci_log "GRUB configuration rendered (sha256 ${grub_sha})"

# The menu learns which slot to try from a two-line config fragment next to it. GRUB's
# own environment block is not available here: the shipped BOOTX64.EFI carries no env
# module, so `load_env`/`save_env` do not exist and the fragment is plain `set` lines the
# menu `source`s. grub-render writes it from ab/state.json, so this stage never invents
# its content: it installs the file, or stops. A missing fragment on a real machine is a
# menu with no slot decision at all.
ab_slot_cfg_src="$(sed -n 's/^ab_slot_cfg_path=//p' "${grub_outputs}" | tail -n 1)"
[ -n "${ab_slot_cfg_src}" ] || ab_slot_cfg_src="${CI_AB_SLOT_CFG_SOURCE:-}"
[ -n "${ab_slot_cfg_src}" ] || ab_slot_cfg_src="$(dirname "${grub_output}")/ab-slot.cfg"
[ -f "${ab_slot_cfg_src}" ] \
    || ci_die "GRUB slot configuration not found: ${ab_slot_cfg_src} (grub-render must publish ab_slot_cfg_path)"
ci_log "GRUB slot configuration: ${ab_slot_cfg_src} ($(ci_file_size "${ab_slot_cfg_src}") bytes)"

# --------------------------------------------------------------------------- #
# 2. p1: ESP
# --------------------------------------------------------------------------- #

# The FAT label is the short human-facing name: "ESP", not a versioned or vendor-prefixed
# string. mkfs.vfat stores it in the FAT32 label field, which is 11 characters wide.
# shellcheck disable=SC2024  # the log path is owned by the runner user
sudo mkfs.vfat -F 32 -n "ESP" "${dev_p1}" >"${disk_dir}/mkfs-p1.log" 2>&1
mount_part "${dev_p1}" p1
p1="${mount_target}"

# The upstream bootloader tree first, then the two slot payloads and the state dirs.
sudo cp -a "${esp_dir}/." "${p1}/"
# Our own menu, rendered for the committed slot; the upstream tree supplies the
# modules and the EFI loader, not the configuration.
sudo mkdir -p "${p1}/boot/grub"
sudo cp "${grub_output}" "${p1}/boot/grub/grub.cfg"
# The fragment sits next to the menu it configures. The menu `source`s it at the very
# end, after every entry is defined, so a missing or truncated fragment still leaves a
# bootable menu behind; nothing in the image's GRUB can write an env block.
sudo cp "${ab_slot_cfg_src}" "${p1}/boot/grub/ab-slot.cfg"
sudo chmod 0644 "${p1}/boot/grub/ab-slot.cfg"
sudo mkdir -p "${p1}/ab/log"

# ab/state.json describes the installed state: both slots on generation 1, slot a
# committed (see the installation row of docs/lifecycle.md). The boot initramfs reads
# it before it can mount anything, so the image has to ship it; S4 starts updating it.
sudo tee "${p1}/ab/state.json" >/dev/null <<STATE
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "${upstream_version}", "upper": "${overlay_name}" },
    "b": { "rootfs": "${upstream_version}", "upper": "${overlay_name}" }
  }
}
STATE
sudo chmod 0644 "${p1}/ab/state.json"
sudo cp "${kernel}" "${p1}/vmlinuz-a"
sudo cp "${kernel}" "${p1}/vmlinuz-b"
# S2 installs the probe initramfs in both slots; S3 replaces it with the real one.
sudo cp "${initramfs}" "${p1}/initrd-a"
sudo cp "${initramfs}" "${p1}/initrd-b"
sudo chmod 0644 "${p1}/vmlinuz-a" "${p1}/vmlinuz-b" "${p1}/initrd-a" "${p1}/initrd-b"
unmount_part "${p1}"
ci_log "p1 populated: ESP tree, grub.cfg, ab-slot.cfg, ab/state.json, ab/log/, vmlinuz-a/b, initrd-a/b"

# --------------------------------------------------------------------------- #
# 3. p2 / p3: the two system slots
# --------------------------------------------------------------------------- #

rootfs_tree="${disk_dir}/rootfs"
if [ ! -d "${rootfs_tree}" ]; then
    mkdir -p "${rootfs_tree}"
    ci_log "extracting the upstream rootfs"
    sudo tar -xzf "${rootfs_tar}" -C "${rootfs_tree}" --numeric-owner
fi
rootfs_files="$(sudo find "${rootfs_tree}" -type f | wc -l | tr -d ' ')"
rootfs_bytes="$(sudo du -sb "${rootfs_tree}" | cut -f1)"
ci_log "rootfs tree: ${rootfs_files} file(s), ${rootfs_bytes} bytes"

# populate_slot <device> <partname> <label> <partition-tag>
# partname goes into the GPT (already written above), label into the btrfs superblock.
populate_slot() {
    local device="$1" partname="$2" label="$3" tag="$4"
    # shellcheck disable=SC2024  # the log path is owned by the runner user
    sudo mkfs.btrfs -f -m dup -d single -L "${label}" "${device}" >"${disk_dir}/mkfs-${tag}.log" 2>&1
    mount_part "${device}" "${tag}"
    local mnt="${mount_target}"
    sudo btrfs subvolume create "${mnt}/@sys" "${mnt}/@platform" >/dev/null
    sudo cp -a "${rootfs_tree}/." "${mnt}/@sys/"

    # The platform layer is the source tree under platform/, mirrored onto the final
    # filesystem paths: /usr/sbin/ab-slot, /etc/init.d/ab-boot, /etc/init.d/ab-commit.
    sudo tar -xpf "${platform_tar}" -C "${mnt}/@platform"
    # Executability follows the directory convention, so a new tool under usr/sbin is
    # runnable without touching this script.
    ci_platform_modes "${mnt}/@platform" sudo
    ci_platform_startlinks "${mnt}/@platform" sudo

    # Platform layer budget: the layer lives inside a slot filesystem, so an
    # oversized layer eats the space the slot needs for its own writes.
    platform_bytes="$(sudo du -sk "${mnt}/@platform" | awk '{ print $1 * 1024 }')"
    ci_log "p${tag#p} @platform unpacked: ${platform_bytes} bytes"
    if [ "${platform_bytes}" -gt "${CI_PLATFORM_LIMIT_BYTES:-8388608}" ]; then
        sudo umount "${mnt}" 2>/dev/null || true
        ci_die "the platform layer is ${platform_bytes} bytes, over the budget of ${CI_PLATFORM_LIMIT_BYTES:-8388608}"
    fi

    unmount_part "${mnt}"
    ci_log "p${tag#p} (${partname}/${label}) populated: @sys (${rootfs_files} file(s)) + @platform (${platform_bytes} bytes)"
}

populate_slot "${dev_p2}" "ab-slot-a" "slot-a" p2
populate_slot "${dev_p3}" "ab-slot-b" "slot-b" p3

# --------------------------------------------------------------------------- #
# 4. p4: the writable data partition
# --------------------------------------------------------------------------- #

# shellcheck disable=SC2024  # the log path is owned by the runner user
sudo mkfs.btrfs -f -m single -d single -L "data" "${dev_p4}" >"${disk_dir}/mkfs-p4.log" 2>&1
mount_part "${dev_p4}" p4
p4="${mount_target}"
sudo btrfs subvolume create "${p4}/${overlay_name}" "${p4}/@docker" "${p4}/@swap" "${p4}/@data" >/dev/null
sudo mkdir -p "${p4}/${overlay_name}/upper" "${p4}/${overlay_name}/work"
# Writable-container and swap subvolumes are allocated without COW or checksums.
sudo chattr +C "${p4}/@docker" "${p4}/@swap"
unmount_part "${p4}"
ci_log "p4 (ab-data/data) populated: ${overlay_name}, @docker, @swap, @data"

# --------------------------------------------------------------------------- #
# 4b. Device identity: the PARTUUIDs the running system recognises this disk by
# --------------------------------------------------------------------------- #

# PARTUUID comes from the GPT, not from any filesystem: the disk GUID and the per
# partition GUIDs live in the partition table, so they are identical after `dd` to
# another disk of any size or name. That is exactly why the running system can trust
# them as the first identity level that owes nothing to a device name (design section
# 6): /dev/sda, /dev/nvme0n1 and /dev/mmcblk0 all carry the same PARTUUIDs as the image.
gpt_id="$(sudo blkid -s PTUUID -o value "${loopdev}" 2>/dev/null || true)"
if [ -z "${gpt_id}" ]; then
    gpt_id="$(sudo sfdisk -d "${loopdev}" 2>/dev/null | sed -n 's/^label-id: *//p' | head -n 1)"
fi
[ -n "${gpt_id}" ] || ci_die "no GPT disk GUID on ${loopdev}: blkid and sfdisk both returned nothing"
gpt_id="$(printf '%s' "${gpt_id}" | tr 'A-F' 'a-f')"

# partuuid <device>: blkid first, the sfdisk dump second, never an empty value. A build
# that writes a blank PARTUUID would disable the strongest identity level silently.
partuuid() {
    local device="$1" value=""
    value="$(sudo blkid -s PARTUUID -o value "${device}" 2>/dev/null || true)"
    if [ -z "${value}" ]; then
        value="$(sudo sfdisk -d "${loopdev}" 2>/dev/null \
            | sed -n "s#^${device}[[:space:]]*:.*uuid=\([0-9A-Fa-f-]*\).*#\1#p" | head -n 1)"
    fi
    [ -n "${value}" ] \
        || ci_die "no PARTUUID for ${device}: blkid and the sfdisk dump both returned nothing"
    printf '%s' "${value}" | tr 'A-F' 'a-f'
}

partuuid_esp="$(partuuid "${dev_p1}")"
partuuid_slot_a="$(partuuid "${dev_p2}")"
partuuid_slot_b="$(partuuid "${dev_p3}")"
partuuid_data="$(partuuid "${dev_p4}")"

# p1 is mounted a second time: the identity file belongs on the ESP, but the PARTUUIDs
# only exist once every partition device does. The ESP mounts at /boot on the running
# system, so the file lands at ab/device.json on the ESP and reads back as
# /boot/ab/device.json -- the same directory that already holds state.json.
mount_part "${dev_p1}" p1-identity
p1_identity="${mount_target}"
sudo mkdir -p "${p1_identity}/ab"
sudo tee "${p1_identity}/ab/device.json" >/dev/null <<DEVICE
{
  "format": "ab-device/1",
  "disk": { "label_id": "${gpt_id}" },
  "partitions": {
    "ab-esp": { "partuuid": "${partuuid_esp}" },
    "ab-slot-a": { "partuuid": "${partuuid_slot_a}" },
    "ab-slot-b": { "partuuid": "${partuuid_slot_b}" },
    "ab-data": { "partuuid": "${partuuid_data}" }
  },
  "labels": {
    "ab-esp": "ESP",
    "ab-slot-a": "slot-a",
    "ab-slot-b": "slot-b",
    "ab-data": "data"
  }
}
DEVICE
sudo chmod 0644 "${p1_identity}/ab/device.json"
unmount_part "${p1_identity}"
ci_log "ab/device.json written: disk ${gpt_id} with four PARTUUIDs"

# --------------------------------------------------------------------------- #
# 5. Close the image
# --------------------------------------------------------------------------- #

sudo sync
sudo losetup -d "${loopdev}"
loopdev=""
image_bytes="$(ci_file_size "${image}")"

now_start="$(date +%s)"
gz_path="${image}.gz"
ci_log "compressing to ${gz_path}"
gzip -9 -c "${image}" >"${gz_path}"
gz_bytes="$(ci_file_size "${gz_path}")"
ci_log "compressed in $(( $(date +%s) - now_start ))s: ${gz_bytes} bytes"

ci_emit_output "overlay_name" "${overlay_name}"
ci_emit_output "platform_tar" "${platform_tar}"
ci_emit_output "platform_bytes" "${platform_bytes:-0}"
ci_emit_output "grub_cfg" "${grub_output}"
ci_emit_output "grub_cfg_sha256" "${grub_sha}"
ci_emit_output "image_path" "${image}"
ci_emit_output "image_gz_path" "${gz_path}"
ci_emit_output "image_bytes" "${image_bytes}"
ci_emit_output "image_gz_bytes" "${gz_bytes}"
ci_emit_output "rootfs_files" "${rootfs_files}"
ci_emit_output "rootfs_bytes" "${rootfs_bytes}"
# part_layout names partitions by GPT PARTNAME, the same key image-verify.sh reads back.
ci_emit_output "part_layout" "ab-esp:2048+262144,ab-slot-a:264192+262144,ab-slot-b:526336+262144,ab-data:788480+262144"

ci_log "image bytes: ${image_bytes}, gz bytes: ${gz_bytes}"
ci_log "stage disk finished"
