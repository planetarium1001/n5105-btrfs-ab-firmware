#!/usr/bin/env bash
# Stage "fetch": download and verify the upstream artifacts.
#
# The downloads are content-addressed by the pinned sha256 from the release's
# sha256sums, so a leftover directory from actions/cache is reused only when every
# digest still matches; a mismatch forces a fresh download and then fails hard.
#
# Inputs (environment):
#   CI_UPSTREAM_VERSION     upstream version label, used in the receipt
#   CI_UPSTREAM_BASE_URL    release directory URL
#   CI_KMODS_DIR            kernel-module directory name
#   CI_KERNEL_PACKAGE       kernel package version, recorded for later stages
#   CI_ROOTFS_NAME          upstream rootfs file name
#   CI_KERNEL_NAME          upstream kernel file name
#   CI_BTRFS_KMOD_NAME      upstream btrfs module file name
#   CI_ROOTFS_SHA256        expected digests
#   CI_KERNEL_SHA256
#   CI_BTRFS_KMOD_SHA256
#   CI_FETCH_DIR            destination directory (default: $CI_TMP_ROOT/fetch)
#   CI_RESOLVE_ENV          optional KEY=VALUE file from the resolve stage
#
# Layout produced:
#   $CI_FETCH_DIR/upstream/rootfs.tar.gz     cached, payload-contract name
#   $CI_FETCH_DIR/upstream/kernel.bin        cached, payload-contract name
#   $CI_FETCH_DIR/upstream/<kmod>.apk        upstream file name
#   $CI_FETCH_DIR/receipt.json               provenance and digests

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init fetch

ci_require_cmd curl awk grep

ci_load_env_file "${CI_RESOLVE_ENV:-}"

# Accept both the GitHub Actions style (secrets-free inputs) and local env names.
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
base_url="${CI_UPSTREAM_BASE_URL:?CI_UPSTREAM_BASE_URL is required}"
kmods_dir="${CI_KMODS_DIR:?CI_KMODS_DIR is required}"
kernel_package="${CI_KERNEL_PACKAGE:?CI_KERNEL_PACKAGE is required}"
rootfs_name="${CI_ROOTFS_NAME:?CI_ROOTFS_NAME is required}"
kernel_name="${CI_KERNEL_NAME:?CI_KERNEL_NAME is required}"
btrfs_kmod_name="${CI_BTRFS_KMOD_NAME:?CI_BTRFS_KMOD_NAME is required}"
rootfs_sha256="${CI_ROOTFS_SHA256:?CI_ROOTFS_SHA256 is required}"
kernel_sha256="${CI_KERNEL_SHA256:?CI_KERNEL_SHA256 is required}"
btrfs_kmod_sha256="${CI_BTRFS_KMOD_SHA256:?CI_BTRFS_KMOD_SHA256 is required}"

fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
upstream_dir="${fetch_dir}/upstream"
mkdir -p "${upstream_dir}"

downloaded=0
reused=0

# fetch_member <local-name> <url> <expected-sha256>
fetch_member() {
    local name="$1" url="$2" expected="$3"
    local dest="${upstream_dir}/${name}"
    local actual
    if [ -f "${dest}" ]; then
        actual="$(ci_sha256 "${dest}")"
        if [ "${actual}" = "${expected}" ]; then
            ci_log "reuse ${name} (sha256 ${actual})"
            reused=$((reused + 1))
            return 0
        fi
        ci_warn "${name} does not match the pinned sha256, re-downloading"
        rm -f "${dest}"
    fi
    ci_download "${url}" "${dest}"
    actual="$(ci_sha256 "${dest}")"
    if [ "${actual}" != "${expected}" ]; then
        ci_die "sha256 mismatch for ${name}: expected ${expected}, got ${actual}"
    fi
    ci_log "verified ${name} (${actual})"
    downloaded=$((downloaded + 1))
}

fetch_member "rootfs.tar.gz" "${base_url}/${rootfs_name}" "${rootfs_sha256}"
fetch_member "kernel.bin" "${base_url}/${kernel_name}" "${kernel_sha256}"
fetch_member "${btrfs_kmod_name}" "${base_url}/kmods/${kmods_dir}/${btrfs_kmod_name}" "${btrfs_kmod_sha256}"

rootfs_size="$(ci_file_size "${upstream_dir}/rootfs.tar.gz")"
kernel_size="$(ci_file_size "${upstream_dir}/kernel.bin")"
kmod_size="$(ci_file_size "${upstream_dir}/${btrfs_kmod_name}")"
total_size=$((rootfs_size + kernel_size + kmod_size))

if [ "${downloaded}" -eq 0 ]; then
    cache_hit="true"
else
    cache_hit="false"
fi

receipt_dir="${fetch_dir}"
receipt="${receipt_dir}/receipt.json"
fetched_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The receipt is written with printf so the member order stays stable and the file
# is diffable; all values are plain ASCII identifiers or digests.
{
    printf '{\n'
    printf '  "upstream_version": "%s",\n' "${upstream_version}"
    printf '  "upstream_base_url": "%s",\n' "${base_url}"
    printf '  "kmods_dir": "%s",\n' "${kmods_dir}"
    printf '  "kernel_package": "%s",\n' "${kernel_package}"
    printf '  "fetched_at": "%s",\n' "${fetched_at}"
    printf '  "cache_hit": %s,\n' "${cache_hit}"
    printf '  "members": [\n'
    printf '    { "name": "rootfs.tar.gz", "upstream_name": "%s", "size": %s, "sha256": "%s" },\n' \
        "${rootfs_name}" "${rootfs_size}" "${rootfs_sha256}"
    printf '    { "name": "kernel.bin", "upstream_name": "%s", "size": %s, "sha256": "%s" },\n' \
        "${kernel_name}" "${kernel_size}" "${kernel_sha256}"
    printf '    { "name": "%s", "upstream_name": "%s", "size": %s, "sha256": "%s" }\n' \
        "${btrfs_kmod_name}" "${btrfs_kmod_name}" "${kmod_size}" "${btrfs_kmod_sha256}"
    printf '  ],\n'
    printf '  "total_bytes": %s\n' "${total_size}"
    printf '}\n'
} >"${receipt}"

ci_log "fetched ${downloaded} member(s), reused ${reused} from cache"
ci_log "total size ${total_size} bytes, receipt ${receipt}"

ci_emit_output "fetch_dir" "${fetch_dir}"
ci_emit_output "receipt_path" "${receipt}"
ci_emit_output "cache_hit" "${cache_hit}"
ci_emit_output "fetch_total_bytes" "${total_size}"
ci_emit_output "rootfs_size_bytes" "${rootfs_size}"
ci_emit_output "kernel_size_bytes" "${kernel_size}"
ci_emit_output "btrfs_kmod_size_bytes" "${kmod_size}"
ci_emit_output "members" "rootfs.tar.gz,kernel.bin,${btrfs_kmod_name}"

ci_log "stage fetch finished"
