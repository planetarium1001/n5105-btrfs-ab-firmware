#!/usr/bin/env bash
# Stage "assemble": build the update payload.
#
# S0 scope: this stage is a skeleton. It publishes a payload directory that already
# follows the contract from docs/conflicts-payload.md (member names, per-member size
# and sha256, format tag, rootfs version) but only carries the members produced by
# the upstream consumer. `initramfs.cpio.gz` and `wf.tar` are reported as
# `missing_members` instead of being faked with empty files, so downstream
# validation fails loudly rather than silently shipping an empty payload.
#
# Inputs (environment):
#   CI_FETCH_DIR         directory produced by the fetch stage
#   CI_ASSEMBLE_DIR      destination directory (default: $CI_TMP_ROOT/assemble)
#   CI_UPSTREAM_VERSION  rootfs version recorded in the manifest
#   CI_KERNEL_PACKAGE    kernel package version recorded in the manifest
#
# Layout produced:
#   $CI_ASSEMBLE_DIR/payload/manifest.json
#   $CI_ASSEMBLE_DIR/payload/rootfs.tar.gz
#   $CI_ASSEMBLE_DIR/payload/kernel.bin

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init assemble

ci_require_cmd cp

ci_load_env_file "${CI_RESOLVE_ENV:-}"

upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
kernel_package="${CI_KERNEL_PACKAGE:?CI_KERNEL_PACKAGE is required}"
fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
upstream_dir="${fetch_dir}/upstream"
[ -d "${upstream_dir}" ] || ci_die "fetch output not found: ${upstream_dir}"

assemble_dir="${CI_ASSEMBLE_DIR:-${CI_TMP_ROOT}/assemble}"
payload_dir="${assemble_dir}/payload"
rm -rf "${payload_dir}"
mkdir -p "${payload_dir}"

# assemble_member <name> <expected-sha256>: copy a fetched member into the payload
# and re-check its digest, so the payload never contains an unverified file.
assemble_member() {
    local name="$1" expected="$2"
    local source="${upstream_dir}/${name}"
    local dest="${payload_dir}/${name}"
    [ -f "${source}" ] || ci_die "fetch output is missing ${name}"
    cp "${source}" "${dest}"
    local actual
    actual="$(ci_sha256 "${dest}")"
    if [ "${actual}" != "${expected}" ]; then
        ci_die "payload member ${name} changed during assembly: expected ${expected}, got ${actual}"
    fi
    ci_log "staged ${name} (${actual})"
}

rootfs_sha256="$(ci_sha256 "${upstream_dir}/rootfs.tar.gz")"
kernel_sha256="$(ci_sha256 "${upstream_dir}/kernel.bin")"

assemble_member "rootfs.tar.gz" "${rootfs_sha256}"
assemble_member "kernel.bin" "${kernel_sha256}"

rootfs_size="$(ci_file_size "${payload_dir}/rootfs.tar.gz")"
kernel_size="$(ci_file_size "${payload_dir}/kernel.bin")"
total_size=$((rootfs_size + kernel_size))

manifest="${payload_dir}/manifest.json"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Member order is alphabetical so the manifest is byte-stable; the values are plain
# ASCII identifiers and digests, so no escaping is required.
{
    printf '{\n'
    printf '  "format": "wf-ab-payload/1",\n'
    printf '  "rootfs": "%s",\n' "${upstream_version}"
    printf '  "kernel": "%s",\n' "${kernel_package}"
    printf '  "stage": "s0-skeleton",\n'
    printf '  "created": "%s",\n' "${created_at}"
    printf '  "members": {\n'
    printf '    "kernel.bin": { "size": %s, "sha256": "%s" },\n' "${kernel_size}" "${kernel_sha256}"
    printf '    "rootfs.tar.gz": { "size": %s, "sha256": "%s" }\n' "${rootfs_size}" "${rootfs_sha256}"
    printf '  },\n'
    printf '  "missing_members": ["initramfs.cpio.gz", "wf.tar"],\n'
    printf '  "notes": "S0 skeleton: only upstream members are present. initramfs.cpio.gz and wf.tar arrive with the assembly stage."\n'
    printf '}\n'
} >"${manifest}"

manifest_sha256="$(ci_sha256 "${manifest}")"
ci_log "payload members: rootfs.tar.gz, kernel.bin (${total_size} bytes total)"
ci_log "payload manifest ${manifest} (sha256 ${manifest_sha256})"
ci_warn "S0 skeleton payload: initramfs.cpio.gz and wf.tar are not built yet"

ci_emit_output "payload_dir" "${payload_dir}"
ci_emit_output "manifest_path" "${manifest}"
ci_emit_output "payload_manifest_sha256" "${manifest_sha256}"
ci_emit_output "payload_members" "kernel.bin,rootfs.tar.gz"
ci_emit_output "payload_total_bytes" "${total_size}"

ci_log "stage assemble finished"
