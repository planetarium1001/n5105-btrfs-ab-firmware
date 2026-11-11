#!/usr/bin/env bash
# Stage "release": turn a verified build into named, checksummed release artifacts.
#
# A release is only worth publishing if it can be checked after the fact, so this
# stage produces three things and nothing else:
#
#   n5105-ab-<upstream>-install.img.gz      the disk image, compressed
#   n5105-ab-<upstream>-upgrade.tar         the update payload
#   SHA256SUMS                              digests of both
#   release-notes.md                        versions, inputs, verification steps
#
# The compressed image is round-tripped and compared against the raw image's digest,
# so a truncated or corrupted compression cannot be published.
#
# Inputs (environment):
#   CI_PLATFORM_VERSION   platform version, recorded in the notes only
#   CI_UPSTREAM_VERSION   upstream release label, used in the file names
#   CI_IMAGE              raw image to compress      (one of the two is required)
#   CI_IMAGE_GZ           already compressed image
#   CI_PAYLOAD            payload tar to publish     (optional)
#   CI_RELEASE_DIR        output directory (default: $CI_TMP_ROOT/release)
#   CI_RELEASE_TAG        tag or run identifier recorded in the notes
#   CI_UPSTREAM_ROOTFS_SHA256, CI_UPSTREAM_KERNEL_SHA256
#                         upstream digests, recorded in the notes when set
#   CI_S5_LINE            judge line of the last verified firmware run, recorded
#
# Outputs: release_dir, image_gz, image_gz_sha256, image_sha256, payload_copy,
#          sums_path, notes_path, artifact_list

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

ci_stage_init release

ci_require_cmd gzip sha256sum

platform_version="${CI_PLATFORM_VERSION:?CI_PLATFORM_VERSION is required}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
release_dir="${CI_RELEASE_DIR:-${CI_TMP_ROOT}/release}"
tag="${CI_RELEASE_TAG:-local}"
base="n5105-ab-${upstream_version}"

image="${CI_IMAGE:-}"
image_gz_in="${CI_IMAGE_GZ:-}"
payload_in="${CI_PAYLOAD:-}"
[ -n "${image}" ] || [ -n "${image_gz_in}" ] || ci_die "either CI_IMAGE or CI_IMAGE_GZ is required"

mkdir -p "${release_dir}"
rm -f "${release_dir}"/*.img.gz "${release_dir}"/*.tar \
    "${release_dir}"/SHA256SUMS "${release_dir}"/release-notes.md

# --------------------------------------------------------------------------- #
# 1. Image
# --------------------------------------------------------------------------- #

image_gz="${release_dir}/${base}-install.img.gz"
if [ -n "${image_gz_in}" ]; then
    [ -f "${image_gz_in}" ] || ci_die "compressed image not found: ${image_gz_in}"
    cp "${image_gz_in}" "${image_gz}"
    ci_log "reusing the compressed image from the build"
else
    [ -f "${image}" ] || ci_die "image not found: ${image}"
    ci_log "compressing ${image} ($(ci_file_size "${image}") bytes)"
    gzip -9 -c "${image}" >"${image_gz}"
fi

# Round trip: the published artefact must decompress to exactly the built image.
image_sha256="$(gzip -dc "${image_gz}" | sha256sum | cut -d' ' -f1)"
image_gz_sha256="$(ci_sha256 "${image_gz}")"
if [ -n "${image}" ]; then
    built_sha256="$(ci_sha256 "${image}")"
    [ "${image_sha256}" = "${built_sha256}" ] ||
        ci_die "the compressed image decompresses to ${image_sha256}, not ${built_sha256}"
    ci_log "round trip verified: ${image_gz} -> ${image_sha256}"
else
    ci_log "decompressed image digest: ${image_sha256}"
fi
ci_log "image artefact: ${image_gz} ($(ci_file_size "${image_gz}") bytes, sha256 ${image_gz_sha256})"

# --------------------------------------------------------------------------- #
# 2. Payload
# --------------------------------------------------------------------------- #

payload_copy=""
if [ -n "${payload_in}" ]; then
    [ -f "${payload_in}" ] || ci_die "payload not found: ${payload_in}"
    payload_copy="${release_dir}/${base}-upgrade.tar"
    cp "${payload_in}" "${payload_copy}"
    ci_log "payload artefact: ${payload_copy} ($(ci_file_size "${payload_copy}") bytes, sha256 $(ci_sha256 "${payload_copy}"))"
else
    ci_warn "no payload given, the release carries the image only"
fi

# --------------------------------------------------------------------------- #
# 3. SHA256SUMS
# --------------------------------------------------------------------------- #

sums="${release_dir}/SHA256SUMS"
(
    cd "${release_dir}"
    sha256sum "${base}-install.img.gz" >"${sums}"
    if [ -n "${payload_copy}" ]; then
        sha256sum "${base}-upgrade.tar" >>"${sums}"
    fi
)
ci_log "checksums:"
sed 's/^/[release]   /' "${sums}"

# --------------------------------------------------------------------------- #
# 4. Release notes
# --------------------------------------------------------------------------- #

notes="${release_dir}/release-notes.md"
upstream_rootfs="${CI_UPSTREAM_ROOTFS_SHA256:-not recorded}"
upstream_kernel="${CI_UPSTREAM_KERNEL_SHA256:-not recorded}"
judge_line="${CI_S5_LINE:-not recorded}"

{
    printf '# N5105 AB firmware %s (upstream %s)\n' "${platform_version}" "${upstream_version}"
    printf '\n'
    printf 'Built by CI for the N5105 v5, x86-64, UEFI only, btrfs A/B slots.\n'
    printf 'Tag: `%s`\n' "${tag}"
    printf '\n'
    printf '## Artifacts\n'
    printf '\n'
    printf '| File | Size | SHA256 |\n'
    printf '| --- | --- | --- |\n'
    printf '| `%s-install.img.gz` | %s bytes | `%s` |\n' "${base}" "$(ci_file_size "${image_gz}")" "${image_gz_sha256}"
    if [ -n "${payload_copy}" ]; then
        printf '| `%s-upgrade.tar` | %s bytes | `%s` |\n' "${base}" "$(ci_file_size "${payload_copy}")" \
            "$(ci_sha256 "${payload_copy}")"
    fi
    printf '\n'
    printf '`SHA256SUMS` covers both files:\n'
    printf '\n'
    printf '```\n'
    cat "${sums}"
    printf '```\n'
    printf '\n'
    printf '## Inputs\n'
    printf '\n'
    printf '| Input | Value |\n'
    printf '| --- | --- |\n'
    printf '| Upstream version | `%s` |\n' "${upstream_version}"
    printf '| Upstream rootfs sha256 | `%s` |\n' "${upstream_rootfs}"
    printf '| Upstream kernel sha256 | `%s` |\n' "${upstream_kernel}"
    printf '| Platform version | `%s` |\n' "${platform_version}"
    printf '| Uncompressed image sha256 | `%s` |\n' "${image_sha256}"
    printf '\n'
    printf '## Verification\n'
    printf '\n'
    printf 'The build is accepted when these lines appear in the corresponding runs:\n'
    printf '\n'
    printf '```\n'
    printf 'S2-RESULT=ok\n'
    printf 'S3-RESULT=ok slot=a\n'
    printf 'S4-RESULT=ok phase=commit slot=b\n'
    printf 'S5-RESULT=ok upgrade=b\n'
    printf '```\n'
    printf '\n'
    printf 'Last recorded S5 line: `%s`\n' "${judge_line}"
    printf '\n'
    printf '## Installation\n'
    printf '\n'
    printf 'See `docs/install.md` for writing the image, the first boot, the acceptance\n'
    printf 'checklist and the rollback procedure. The short version:\n'
    printf '\n'
    printf '```\n'
    printf 'gunzip -c %s-install.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync\n' "${base}"
    printf '```\n'
    printf '\n'
    printf 'After the first boot run `ab-slot status`; it must report `p4=ok` and a\n'
    printf 'committed slot. Updates use `ab-upgrade` with the payload tar above.\n'
} >"${notes}"
ci_log "release notes: ${notes}"

artifacts="${base}-install.img.gz"
[ -n "${payload_copy}" ] && artifacts="${artifacts} ${base}-upgrade.tar"
artifacts="${artifacts} SHA256SUMS release-notes.md"

ci_emit_output "release_dir" "${release_dir}"
ci_emit_output "image_gz" "${image_gz}"
ci_emit_output "image_gz_sha256" "${image_gz_sha256}"
ci_emit_output "image_sha256" "${image_sha256}"
ci_emit_output "payload_copy" "${payload_copy}"
ci_emit_output "sums_path" "${sums}"
ci_emit_output "notes_path" "${notes}"
ci_emit_output "artifact_list" "${artifacts}"

ci_log "stage release finished"
