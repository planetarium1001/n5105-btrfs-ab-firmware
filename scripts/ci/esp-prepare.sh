#!/usr/bin/env bash
# Stage "esp": prepare the ESP content by reusing the upstream bootloader.
#
# The image needs a UEFI bootloader in p1. Instead of building GRUB ourselves, this
# stage takes it from the upstream combined-EFI image for the same release: the ESP
# of `immortalwrt-<ver>-x86-64-generic-squashfs-combined-efi.img.gz` already contains
# EFI/BOOT/BOOTX64.EFI and the matching boot/grub module tree. Reusing it keeps the
# firmware and the kernel from diverging and adds no build dependency.
#
# The upstream GPT types the ESP as a plain Linux filesystem, so the partition is
# located by probing for a FAT signature rather than by trusting the type GUID.
#
# Inputs (environment):
#   CI_UPSTREAM_BASE_URL  release directory URL
#   CI_UPSTREAM_VERSION   upstream release label
#   CI_ESP_DIR            output directory for the ESP tree (default: $CI_TMP_ROOT/esp)
#   CI_ESP_CACHE          download cache (default: $CI_TMP_ROOT/esp-cache)
#
# Outputs: esp_dir, esp_bytes, esp_files, efi_loader, grub_dir, source_image,
#          source_sha256

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

ci_stage_init esp

ci_require_cmd sudo losetup blkid gunzip

base_url="${CI_UPSTREAM_BASE_URL:?CI_UPSTREAM_BASE_URL is required}"
version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
esp_dir="${CI_ESP_DIR:-${CI_TMP_ROOT}/esp}"
cache_dir="${CI_ESP_CACHE:-${CI_TMP_ROOT}/esp-cache}"
image_name="immortalwrt-${version}-x86-64-generic-squashfs-combined-efi.img.gz"
image_gz="${cache_dir}/${image_name}"
image_raw="${cache_dir}/${image_name%.gz}"

mkdir -p "${esp_dir}" "${cache_dir}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required to mount the upstream image"

# --------------------------------------------------------------------------- #
# 1. Fetch and verify the upstream image
# --------------------------------------------------------------------------- #

sums="${cache_dir}/sha256sums"
[ -s "${sums}" ] || ci_download "${base_url}/sha256sums" "${sums}"
expected="$(ci_lookup_sha256 "${sums}" "${image_name}")"
ci_match "${expected}" "${CI_SHA256_RE}" "ESP source sha256"

if [ -s "${image_gz}" ] && [ "$(ci_sha256 "${image_gz}")" = "${expected}" ]; then
    ci_log "reuse ${image_name}"
else
    ci_download "${base_url}/${image_name}" "${image_gz}"
    actual="$(ci_sha256 "${image_gz}")"
    [ "${actual}" = "${expected}" ] || ci_die "${image_name}: digest ${actual} != ${expected}"
fi
ci_log "ESP source verified: ${image_name} (${expected})"

if [ ! -s "${image_raw}" ] || [ "${image_gz}" -nt "${image_raw}" ]; then
    ci_log "decompressing ${image_name}"
    gunzip -c "${image_gz}" >"${image_raw}"
fi

# --------------------------------------------------------------------------- #
# 2. Locate the FAT partition and copy its tree out
# --------------------------------------------------------------------------- #

mount_dir="${CI_TMP_ROOT}/esp-mnt"
mkdir -p "${mount_dir}"
loopdev=""
cleanup() {
    if [ -n "${loopdev}" ]; then
        sudo umount "${mount_dir}" 2>/dev/null || true
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --show --partscan "${image_raw}")"

esp_partition=""
for part in "${loopdev}"p*; do
    [ -b "${part}" ] || continue
    fstype="$(sudo blkid -p -o value -s TYPE "${part}" 2>/dev/null || true)"
    ci_log "  ${part}: ${fstype:-unknown}"
    case "${fstype}" in
        vfat | fat | fat16 | fat32)
            esp_partition="${part}"
            break
            ;;
    esac
done
[ -n "${esp_partition}" ] || ci_die "no FAT partition found in ${image_name}"

sudo mount -o ro "${esp_partition}" "${mount_dir}"
sudo cp -a "${mount_dir}/." "${esp_dir}/"
sudo umount "${mount_dir}"
sudo losetup -d "${loopdev}"
loopdev=""

# --------------------------------------------------------------------------- #
# 3. Assert the pieces the boot chain depends on
# --------------------------------------------------------------------------- #

# FAT is case insensitive, the build host is not, and upstream does not guarantee the
# exact spelling. Locate the loader by pattern and record what was actually found.
efi_loader="$(find "${esp_dir}" -type f \( -iname 'bootx64.efi' -o -iname '*.efi' \) \
    | sort | head -n 1)"
if [ -z "${efi_loader}" ]; then
    ci_log "ESP tree as laid out upstream:"
    find "${esp_dir}" -mindepth 1 -maxdepth 3 | sort | head -n 40 | sed 's/^/[esp]   /'
    ci_die "upstream ESP contains no EFI loader"
fi
grub_dir="$(find "${esp_dir}" -type d -iname grub | sort | head -n 1)"
[ -n "${grub_dir}" ] || grub_dir="$(dirname "${efi_loader}")"

esp_bytes="$(du -sb "${esp_dir}" | cut -f1)"
esp_files="$(find "${esp_dir}" -type f | wc -l | tr -d ' ')"
[ "${esp_bytes}" -lt $((64 * 1024 * 1024)) ] \
    || ci_die "ESP content is ${esp_bytes} bytes, over the 64 MiB budget"

ci_log "ESP tree: ${esp_bytes} bytes in ${esp_files} file(s)"
ci_log "  loader: ${efi_loader#"${esp_dir}"/}"
ci_log "  grub:   ${grub_dir#"${esp_dir}"/} ($(find "${grub_dir}" -type f | wc -l | tr -d ' ') file(s))"

ci_emit_output "esp_dir" "${esp_dir}"
ci_emit_output "esp_bytes" "${esp_bytes}"
ci_emit_output "esp_files" "${esp_files}"
ci_emit_output "efi_loader" "${efi_loader#"${esp_dir}"/}"
ci_emit_output "grub_dir" "boot/grub"
ci_emit_output "source_image" "${image_name}"
ci_emit_output "source_sha256" "${expected}"

ci_log "stage esp finished"
