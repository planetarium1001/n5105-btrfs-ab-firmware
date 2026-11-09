#!/usr/bin/env bash
# Stage "disk": assemble the four-partition disk image.
#
# Geometry, frozen by docs/partitions.md:
#
#   p1  wf-esp     128 MiB  vfat   GRUB, vmlinuz-a/b, initrd-a/b, ab/, ab/log/
#   p2  wf-slot-a  128 MiB  btrfs  @sys, @wf
#   p3  wf-slot-b  128 MiB  btrfs  @sys, @wf
#   p4  wf-shared   64 MiB  btrfs  @overlay.gen0001 (upper/, work/), @docker, @swap, @data
#
# The image is 450 MiB: 1 MiB of alignment before p1, 448 MiB of partitions and 1 MiB
# of tail so the backup GPT has room. p4 only ships 64 MiB by design; first boot grows
# it to the end of the real disk.
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
#   CI_PLATFORM_VERSION  version recorded in the @wf skeleton
#   CI_UPSTREAM_VERSION  upstream release label recorded in @wf
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
image="${CI_DISK_OUT:-${disk_dir}/wf-ab-image.img}"
platform_version="${CI_PLATFORM_VERSION:-0.0.1}"
upstream_version="${CI_UPSTREAM_VERSION:-unknown}"

[ -f "${rootfs_tar}" ] || ci_die "upstream rootfs not found: ${rootfs_tar}"
[ -f "${kernel}" ] || ci_die "upstream kernel not found: ${kernel}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"
[ -d "${esp_dir}/EFI/BOOT" ] || ci_die "ESP tree looks incomplete: ${esp_dir}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required to build the image"

mkdir -p "${disk_dir}"

# --------------------------------------------------------------------------- #
# 1. Partition table
# --------------------------------------------------------------------------- #

# 450 MiB in 512-byte sectors: 1 MiB alignment, 448 MiB of partitions, 1 MiB tail.
image_sectors=921600
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

start=   2048, size=262144, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="wf-esp"
start= 264192, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="wf-slot-a"
start= 526336, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="wf-slot-b"
start= 788480, size=131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="wf-shared"
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
# 2. p1: ESP
# --------------------------------------------------------------------------- #

# shellcheck disable=SC2024  # the log path is owned by the runner user
sudo mkfs.vfat -F 32 -n "WF-ESP" "${dev_p1}" >"${disk_dir}/mkfs-p1.log" 2>&1
mount_part "${dev_p1}" p1
p1="${mount_target}"

# The upstream bootloader tree first, then the two slot payloads and the state dirs.
sudo cp -a "${esp_dir}/." "${p1}/"
sudo mkdir -p "${p1}/ab/log"
sudo cp "${kernel}" "${p1}/vmlinuz-a"
sudo cp "${kernel}" "${p1}/vmlinuz-b"
# S2 installs the probe initramfs in both slots; S3 replaces it with the real one.
sudo cp "${initramfs}" "${p1}/initrd-a"
sudo cp "${initramfs}" "${p1}/initrd-b"
sudo chmod 0644 "${p1}/vmlinuz-a" "${p1}/vmlinuz-b" "${p1}/initrd-a" "${p1}/initrd-b"
unmount_part "${p1}"
ci_log "p1 populated: ESP tree, ab/, ab/log/, vmlinuz-a/b, initrd-a/b"

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

# populate_slot <device> <label> <partition-name>
populate_slot() {
    local device="$1" label="$2" tag="$3"
    # shellcheck disable=SC2024  # the log path is owned by the runner user
    sudo mkfs.btrfs -f -m dup -d single -L "${label}" "${device}" >"${disk_dir}/mkfs-${tag}.log" 2>&1
    mount_part "${device}" "${tag}"
    local mnt="${mount_target}"
    sudo btrfs subvolume create "${mnt}/@sys" "${mnt}/@wf" >/dev/null
    sudo cp -a "${rootfs_tree}/." "${mnt}/@sys/"

    # @wf is only a skeleton until S5 fills the platform layer; the paths it will
    # mirror (/usr/sbin, /etc) are already there so the overlay lowerdir is valid.
    sudo mkdir -p "${mnt}/@wf/usr/sbin" "${mnt}/@wf/etc"
    sudo touch "${mnt}/@wf/usr/sbin/.keep"
    {
        printf 'WF_PLATFORM=%s\n' "${platform_version}"
        printf 'WF_UPSTREAM=%s\n' "${upstream_version}"
        printf 'WF_STAGE=s2-skeleton\n'
    } | sudo tee "${mnt}/@wf/etc/wf-release" >/dev/null
    sudo chmod 0644 "${mnt}/@wf/etc/wf-release"

    unmount_part "${mnt}"
    ci_log "p${tag#p} populated: @sys (${rootfs_files} file(s)) + @wf skeleton"
}

populate_slot "${dev_p2}" "wf-slot-a" p2
populate_slot "${dev_p3}" "wf-slot-b" p3

# --------------------------------------------------------------------------- #
# 4. p4: the shared writable partition
# --------------------------------------------------------------------------- #

# shellcheck disable=SC2024  # the log path is owned by the runner user
sudo mkfs.btrfs -f -m single -d single -L "wf-shared" "${dev_p4}" >"${disk_dir}/mkfs-p4.log" 2>&1
mount_part "${dev_p4}" p4
p4="${mount_target}"
sudo btrfs subvolume create "${p4}/@overlay.gen0001" "${p4}/@docker" "${p4}/@swap" "${p4}/@data" >/dev/null
sudo mkdir -p "${p4}/@overlay.gen0001/upper" "${p4}/@overlay.gen0001/work"
# Writable-container and swap subvolumes are allocated without COW or checksums.
sudo chattr +C "${p4}/@docker" "${p4}/@swap"
unmount_part "${p4}"
ci_log "p4 populated: @overlay.gen0001, @docker, @swap, @data"

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

ci_emit_output "image_path" "${image}"
ci_emit_output "image_gz_path" "${gz_path}"
ci_emit_output "image_bytes" "${image_bytes}"
ci_emit_output "image_gz_bytes" "${gz_bytes}"
ci_emit_output "rootfs_files" "${rootfs_files}"
ci_emit_output "rootfs_bytes" "${rootfs_bytes}"
ci_emit_output "part_layout" "wf-esp:2048+262144,wf-slot-a:264192+262144,wf-slot-b:526336+262144,wf-shared:788480+131072"

ci_log "image bytes: ${image_bytes}, gz bytes: ${gz_bytes}"
ci_log "stage disk finished"
