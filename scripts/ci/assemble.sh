#!/usr/bin/env bash
# Stage "assemble": build the update payload and validate it with the product's own
# checker.
#
# The payload is the real thing: the upstream root filesystem and kernel, the boot
# initramfs this project builds, and the platform layer including the btrfs tooling.
# Nothing is faked and nothing is left out, so a payload that fails validation here
# would also fail on the target.
#
# There is exactly one definition of "a valid payload": platform/usr/sbin/ab-upgrade
# --check. This stage produces the tar and then hands it to that checker, so the build
# cannot drift away from what the device accepts.
#
# Inputs (environment):
#   CI_FETCH_DIR             directory produced by the fetch stage
#   CI_UPSTREAM_VERSION      upstream release label
#   CI_KERNEL_PACKAGE        kernel package version, recorded in the manifest
#   CI_PLATFORM_VERSION      platform version, recorded in the release file
#   CI_INITRAMFS             boot initramfs to ship as the payload's initrd
#   CI_PLATFORM_RUNTIME_DIR  btrfs tooling staged by the runtime stage
#   CI_PLATFORM_SRC          platform layer source tree (default: platform/)
#   CI_ASSEMBLE_DIR          destination directory (default: $CI_TMP_ROOT/assemble)
#
# Outputs: payload_path, payload_dir, manifest_path, payload_manifest_sha256,
#          payload_members, payload_total_bytes, payload_check

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

ci_stage_init assemble

ci_require_cmd tar gzip python3

upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
kernel_package="${CI_KERNEL_PACKAGE:?CI_KERNEL_PACKAGE is required}"
platform_version="${CI_PLATFORM_VERSION:-0.0.5}"
initramfs="${CI_INITRAMFS:?CI_INITRAMFS is required, the payload needs the boot initramfs}"
runtime_tree="${CI_PLATFORM_RUNTIME_DIR:?CI_PLATFORM_RUNTIME_DIR is required, the payload needs the btrfs tooling}"
platform_src="${CI_PLATFORM_SRC:-${CI_REPO_ROOT}/platform}"
fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
upstream_dir="${fetch_dir}/upstream"
assemble_dir="${CI_ASSEMBLE_DIR:-${CI_TMP_ROOT}/assemble}"
payload_dir="${assemble_dir}/payload"
payload_tar="${assemble_dir}/payload.tar"

[ -d "${upstream_dir}" ] || ci_die "fetch output not found: ${upstream_dir}"
[ -d "${platform_src}" ] || ci_die "platform tree not found: ${platform_src}"
[ -d "${runtime_tree}" ] || ci_die "runtime tree not found: ${runtime_tree}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"

rm -rf "${payload_dir}"
mkdir -p "${payload_dir}"

# --------------------------------------------------------------------------- #
# 1. Upstream members, digest re-checked so the payload never carries an
#    unverified file
# --------------------------------------------------------------------------- #

# assemble_member <name> <expected-sha256>
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

cp "${initramfs}" "${payload_dir}/initramfs.cpio.gz"
ci_log "staged initramfs.cpio.gz ($(ci_sha256 "${payload_dir}/initramfs.cpio.gz"))"

# --------------------------------------------------------------------------- #
# 2. Platform layer: the source tree plus the btrfs tooling, with the modes and
#    the rcS start links every platform layer needs
# --------------------------------------------------------------------------- #

platform_stage="${assemble_dir}/platform-stage"
rm -rf "${platform_stage}"
mkdir -p "${platform_stage}"
cp -a "${platform_src}/." "${platform_stage}/"
cp -a "${runtime_tree}/." "${platform_stage}/"

ci_render_release "${platform_stage}/etc/platform-release" \
    "${platform_version}" "${upstream_version}" "payload"
ci_platform_modes "${platform_stage}"
ci_platform_startlinks "${platform_stage}"
[ -x "${platform_stage}/usr/sbin/btrfs" ] ||
    ci_die "the platform layer in the payload has no runnable btrfs tool"

tar --numeric-owner --owner=0 --group=0 -cf "${payload_dir}/platform.tar" -C "${platform_stage}" .
ci_log "staged platform.tar ($(ci_sha256 "${payload_dir}/platform.tar"), $(ci_file_size "${payload_dir}/platform.tar") bytes)"

# --------------------------------------------------------------------------- #
# 3. Manifest
# --------------------------------------------------------------------------- #

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "${payload_dir}" "${upstream_version}" "${kernel_package}" \
    "${platform_version}" "${created_at}" <<'PYTHON'
import hashlib, json, pathlib, sys

payload_dir = pathlib.Path(sys.argv[1])
version, kernel_package, platform_version, created = sys.argv[2:6]
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    data = (payload_dir / name).read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
doc = {
    "format": "ab-payload/1",
    "rootfs": version,
    "kernel": kernel_package,
    "platform": platform_version,
    "created": created,
    "members": members,
}
(payload_dir / "manifest.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(json.dumps(members, indent=2, sort_keys=True))
PYTHON

tar -cf "${payload_tar}" -C "${payload_dir}" manifest.json rootfs.tar.gz kernel.bin \
    initramfs.cpio.gz platform.tar
payload_total_bytes="$(ci_file_size "${payload_tar}")"
manifest_sha256="$(ci_sha256 "${payload_dir}/manifest.json")"
ci_log "payload ${payload_tar} (${payload_total_bytes} bytes, sha256 $(ci_sha256 "${payload_tar}"))"

# --------------------------------------------------------------------------- #
# 4. Validation by the product's own checker
#
# ab-upgrade --check is the definition of a valid payload. It runs in the same shell
# dialect it uses on the target, against a scratch ESP and a scratch writable
# partition, so a payload that fails here would fail on the device too.
# --------------------------------------------------------------------------- #

check_dir="${assemble_dir}/check"
rm -rf "${check_dir}"
mkdir -p "${check_dir}/esp/ab/log" "${check_dir}/p4" "${check_dir}/slots"
cat >"${check_dir}/esp/ab/state.json" <<JSON
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "${upstream_version}", "upper": "@overlay-${upstream_version}" },
    "b": { "rootfs": "${upstream_version}", "upper": "@overlay-${upstream_version}" }
  }
}
JSON

# ab-slot derives p4's health from /proc/mounts, so the scratch partition has to be a
# real mount. A tmpfs is enough: the check only needs free space and a mount point.
p4_mounted="false"
cleanup_p4() {
    if [ "${p4_mounted}" = "true" ]; then
        sudo umount "${check_dir}/p4" 2>/dev/null || true
    fi
}
trap cleanup_p4 EXIT
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo mount -t tmpfs -o size=64M tmpfs "${check_dir}/p4" 2>/dev/null && p4_mounted="true"
fi
[ "${p4_mounted}" = "true" ] ||
    ci_die "cannot mount a scratch writable partition, the payload check needs one"

check_output="${assemble_dir}/payload-check.log"
if ! PATH="${CI_REPO_ROOT}/platform/usr/sbin:${PATH}" \
    AB_ESP="${check_dir}/esp" AB_P4="${check_dir}/p4" \
    AB_SLOTS_ROOT="${check_dir}/slots" \
    AB_LIB="${CI_REPO_ROOT}/platform/lib/upgrade/platform.sh" \
    sh "${CI_REPO_ROOT}/platform/usr/sbin/ab-upgrade" --check "${payload_tar}" \
    >"${check_output}" 2>&1; then
    sed 's/^/[assemble]   /' "${check_output}" >&2 || true
    ci_die "the payload does not pass ab-upgrade --check, see ${check_output}"
fi
sed 's/^/[assemble]   /' "${check_output}"

ci_emit_output "payload_path" "${payload_tar}"
ci_emit_output "payload_dir" "${payload_dir}"
ci_emit_output "manifest_path" "${payload_dir}/manifest.json"
ci_emit_output "payload_manifest_sha256" "${manifest_sha256}"
ci_emit_output "payload_members" "initramfs.cpio.gz,kernel.bin,platform.tar,rootfs.tar.gz"
ci_emit_output "payload_total_bytes" "${payload_total_bytes}"
ci_emit_output "payload_check" "ok"

ci_log "stage assemble finished"
