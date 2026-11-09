#!/usr/bin/env bash
# Stage "resolve": pick the upstream release and derive the cache key.
#
# Responsibilities:
#   1. accept a requested upstream version (input, "latest", or the pinned default)
#   2. download the release's sha256sums and package manifest
#   3. resolve the kernel-module directory name and cross-check it against the
#      kernel package version (the preflight required by docs/conflicts-payload.md)
#   4. compute the cache key from upstream version + tool versions + CI scripts
#
# Inputs (environment):
#   CI_UPSTREAM_VERSION  requested version, "latest", or empty for the pin
#   CI_WORK_DIR          scratch directory (default: $CI_TMP_ROOT/resolve)
#   GITHUB_OUTPUT        GitHub Actions output file (optional)
#   CI_OUTPUT_ENV        KEY=VALUE output file for local runs (optional)
#
# Outputs: see the ci_emit_output calls at the end of the script.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init resolve

ci_require_cmd curl awk grep sort

work_dir="${CI_WORK_DIR:-${CI_TMP_ROOT}/resolve}"
mkdir -p "${work_dir}"

# --------------------------------------------------------------------------- #
# 1. Upstream version
# --------------------------------------------------------------------------- #

requested="${CI_UPSTREAM_VERSION:-}"
if [ -z "${requested}" ]; then
    version="${CI_UPSTREAM_VERSION_PIN}"
    version_source="pin"
elif [ "${requested}" = "latest" ]; then
    version=""
    version_source="latest"
else
    version="${requested}"
    version_source="input"
fi

# resolve_latest_version: highest release directory published on the mirror.
resolve_latest_version() {
    local index="${work_dir}/releases-index.html"
    ci_download "${CI_UPSTREAM_BASE}/releases/" "${index}"
    grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' "${index}" \
        | sed -e 's/^href="//' -e 's|/"$||' \
        | LC_ALL=C sort -uV \
        | tail -n 1
}

if [ "${version_source}" = "latest" ]; then
    version="$(resolve_latest_version)"
    [ -n "${version}" ] || ci_die "could not resolve the latest upstream version"
    ci_log "resolved latest upstream version: ${version}"
fi

ci_match "${version}" "${CI_VERSION_RE}" "upstream version"

base_url="${CI_UPSTREAM_BASE}/releases/${version}/${CI_UPSTREAM_TARGET}"
ci_log "upstream version ${version} (source: ${version_source})"
ci_log "upstream base url ${base_url}"

rootfs_name="immortalwrt-${version}-x86-64-rootfs.tar.gz"
kernel_name="immortalwrt-${version}-x86-64-generic-kernel.bin"
manifest_name="immortalwrt-${version}-x86-64.manifest"

# --------------------------------------------------------------------------- #
# 2. Release metadata
# --------------------------------------------------------------------------- #

sums="${work_dir}/sha256sums"
manifest="${work_dir}/${manifest_name}"
ci_download "${base_url}/sha256sums" "${sums}"
ci_download "${base_url}/${manifest_name}" "${manifest}"

# Expected digests for the three members this project consumes.
rootfs_sha256="$(ci_lookup_sha256 "${sums}" "${rootfs_name}")"
kernel_sha256="$(ci_lookup_sha256 "${sums}" "${kernel_name}")"

# The btrfs module is the only way to get btrfs on this target, because the
# upstream kernel image is built without CONFIG_KERNEL_BTRFS_FS.
btrfs_kmod_line="$(awk '$2 ~ /\*kmods\/[^\/]+\/kmod-fs-btrfs-[^\/]+$/ { print $1 " " $2 }' "${sums}")"
[ -n "${btrfs_kmod_line}" ] || ci_die "sha256sums lists no kmod-fs-btrfs package"
if [ "$(printf '%s\n' "${btrfs_kmod_line}" | wc -l | tr -d ' ')" != "1" ]; then
    ci_die "sha256sums lists more than one kmod-fs-btrfs package"
fi
btrfs_kmod_sha256="${btrfs_kmod_line%% *}"
btrfs_kmod_path="${btrfs_kmod_line##* }"
btrfs_kmod_path="${btrfs_kmod_path#\*}"
kmods_dir="${btrfs_kmod_path#kmods/}"
kmods_dir="${kmods_dir%%/*}"
btrfs_kmod_name="${btrfs_kmod_path##*/}"

ci_match "${rootfs_sha256}" "${CI_SHA256_RE}" "rootfs.tar.gz sha256"
ci_match "${kernel_sha256}" "${CI_SHA256_RE}" "kernel.bin sha256"
ci_match "${btrfs_kmod_sha256}" "${CI_SHA256_RE}" "kmod-fs-btrfs sha256"
ci_match "${kmods_dir}" "${CI_KMODS_DIR_RE}" "kmods directory name"

# --------------------------------------------------------------------------- #
# 3. Kernel preflight: kmods directory hash must match the kernel package
# --------------------------------------------------------------------------- #

kernel_package_line="$(grep -E '^kernel - ' "${manifest}")"
[ -n "${kernel_package_line}" ] || ci_die "package manifest has no kernel entry"
if [ "$(printf '%s\n' "${kernel_package_line}" | wc -l | tr -d ' ')" != "1" ]; then
    ci_die "package manifest has more than one kernel entry"
fi
kernel_package="${kernel_package_line#kernel - }"
kernel_version="${kernel_package%%~*}"
kernel_hash="${kernel_package#*~}"
kernel_hash="${kernel_hash%%-*}"

kmods_version="$(printf '%s\n' "${kmods_dir}" | sed -E 's/-[0-9]+-[0-9a-f]{32}$//')"
kmods_rest="${kmods_dir#"${kmods_version}"-}"
kmods_hash="${kmods_rest##*-}"

[ "${kmods_version}" = "${kernel_version}" ] \
    || ci_die "kmods directory kernel version ${kmods_version} differs from kernel package ${kernel_version}"
[ "${kmods_hash}" = "${kernel_hash}" ] \
    || ci_die "kmods directory hash ${kmods_hash} differs from kernel package hash ${kernel_hash}"
ci_log "preflight ok: kmods dir matches kernel package ${kernel_package}"

# --------------------------------------------------------------------------- #
# 4. Cache key: upstream version + tool versions + CI script content
# --------------------------------------------------------------------------- #

script_files=()
while IFS= read -r path; do
    script_files+=("${path}")
done < <(
    {
        find "${CI_REPO_ROOT}/scripts/ci" -maxdepth 1 -type f -name '*.sh'
        find "${CI_REPO_ROOT}/.github/workflows" -type f -name '*.yml'
    } | LC_ALL=C sort
)
if [ "${#script_files[@]}" -eq 0 ]; then
    ci_die "no CI scripts found under ${CI_REPO_ROOT}"
fi

key_material="$(
    {
        printf 'upstream_version=%s\n' "${version}"
        printf 'kmods_dir=%s\n' "${kmods_dir}"
        printf 'kernel_package=%s\n' "${kernel_package}"
        printf 'rootfs_sha256=%s\n' "${rootfs_sha256}"
        printf 'kernel_sha256=%s\n' "${kernel_sha256}"
        printf 'btrfs_kmod_sha256=%s\n' "${btrfs_kmod_sha256}"
        printf 'tools_version=%s\n' "${CI_TOOLS_VERSION}"
        printf 'tools=%s\n' "${CI_TOOLS}"
        ci_hash_manifest "${script_files[@]}"
    }
)"
key_hash="$(printf '%s\n' "${key_material}" | ci_sha256_text)"
ci_match "${key_hash}" "${CI_SHA256_RE}" "cache key hash"

cache_key="upstream-${version}-${key_hash:0:16}"
cache_restore_prefix="upstream-${version}-"

ci_log "cache key ${cache_key}"
ci_log "cache key material:"
printf '%s\n' "${key_material}" | sed -e 's/^/  /'

# --------------------------------------------------------------------------- #
# Results
# --------------------------------------------------------------------------- #

ci_emit_output "upstream_version" "${version}"
ci_emit_output "upstream_base_url" "${base_url}"
ci_emit_output "version_source" "${version_source}"
ci_emit_output "rootfs_name" "${rootfs_name}"
ci_emit_output "kernel_name" "${kernel_name}"
ci_emit_output "rootfs_sha256" "${rootfs_sha256}"
ci_emit_output "kernel_sha256" "${kernel_sha256}"
ci_emit_output "kmods_dir" "${kmods_dir}"
ci_emit_output "btrfs_kmod_name" "${btrfs_kmod_name}"
ci_emit_output "btrfs_kmod_sha256" "${btrfs_kmod_sha256}"
ci_emit_output "kernel_package" "${kernel_package}"
ci_emit_output "cache_key" "${cache_key}"
ci_emit_output "cache_restore_prefix" "${cache_restore_prefix}"
ci_emit_output "cache_key_hash" "${key_hash}"

ci_log "stage resolve finished"
