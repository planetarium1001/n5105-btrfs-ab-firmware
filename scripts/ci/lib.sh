#!/usr/bin/env bash
# Shared helpers for the CI stage scripts.
#
# This file is sourced by scripts/ci/*.sh, never executed on its own. Every stage
# script calls `ci_stage_init <name>` first so that log lines are tagged, scratch
# directories live under one root, and the pinned upstream inputs are defined in
# exactly one place.
#
# Conventions:
#   * all scratch data lives under $CI_TMP_ROOT (defaults to $RUNNER_TEMP/ci), so
#     nothing is written into the repository tree
#   * stage scripts communicate with the orchestrating workflow through
#     `ci_emit_output`, which writes to $GITHUB_OUTPUT when running in Actions and
#     to $CI_OUTPUT_ENV (a plain KEY=VALUE file) for local reproduction
#   * external tools are used without version pinning, so the cache key carries an
#     explicit tool epoch (CI_TOOLS_VERSION) next to the tool list

if [ -n "${CI_LIB_LOADED:-}" ]; then
    return 0
fi
CI_LIB_LOADED=1

set -euo pipefail

# --------------------------------------------------------------------------- #
# Pinned inputs
# --------------------------------------------------------------------------- #

# Upstream ImmortalWrt release consumed when no explicit version is requested.
# Bumping this value changes the cache key, so cached downloads are never reused
# across upstream versions.
CI_UPSTREAM_VERSION_PIN="${CI_UPSTREAM_VERSION_PIN:-25.12.2}"

# Official mirror root and target path (x86-64, UEFI only).
CI_UPSTREAM_BASE="${CI_UPSTREAM_BASE:-https://downloads.immortalwrt.org}"
# shellcheck disable=SC2034  # consumed by the sourcing stage scripts
CI_UPSTREAM_TARGET="targets/x86/64"

# Tool set that can influence the produced bytes, plus a manual epoch. Both are
# part of the cache key: a toolchain change invalidates cached downloads even when
# the upstream version is unchanged.
CI_TOOLS_VERSION="${CI_TOOLS_VERSION:-1}"
CI_TOOLS="${CI_TOOLS:-bash curl tar gzip zstd python3}"

# Regex for a release directory name, used by the "latest" resolver.
# shellcheck disable=SC2034  # consumed by the sourcing stage scripts
CI_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
# Kernel module directory name: <kernel-version>-<pkg-release>-<source-hash>.
# shellcheck disable=SC2034  # consumed by the sourcing stage scripts
CI_KMODS_DIR_RE='^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]{32}$'
# shellcheck disable=SC2034  # consumed by the sourcing stage scripts
CI_SHA256_RE='^[0-9a-f]{64}$'

# --------------------------------------------------------------------------- #
# Locations
# --------------------------------------------------------------------------- #

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd "${CI_LIB_DIR}/../.." && pwd)}"
export CI_REPO_ROOT

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #

ci_log() {
    printf '[%s] %s\n' "${CI_STAGE:-ci}" "$*"
}

ci_warn() {
    printf '[%s] WARNING: %s\n' "${CI_STAGE:-ci}" "$*" >&2
}

ci_die() {
    printf '[%s] ERROR: %s\n' "${CI_STAGE:-ci}" "$*" >&2
    exit 1
}

# ci_stage_init <stage-name>: set the stage tag and create the scratch layout.
ci_stage_init() {
    CI_STAGE="${1:?ci_stage_init requires a stage name}"
    CI_TMP_ROOT="${CI_TMP_ROOT:-${RUNNER_TEMP:-/tmp}/ci}"
    CI_LOG_DIR="${CI_LOG_DIR:-${CI_TMP_ROOT}/logs}"
    export CI_STAGE CI_TMP_ROOT CI_LOG_DIR
    mkdir -p "${CI_LOG_DIR}"
    # The local output file belongs to a single stage run; truncate it so a second
    # local run does not leave stale keys in front of the fresh ones. The Actions
    # output file is appended to by design and is never touched here.
    if [ -n "${CI_OUTPUT_ENV:-}" ]; then
        mkdir -p "$(dirname "${CI_OUTPUT_ENV}")"
        : >"${CI_OUTPUT_ENV}"
    fi
    ci_log "stage ${CI_STAGE} started, repo root ${CI_REPO_ROOT}"
}

# --------------------------------------------------------------------------- #
# Environment helpers
# --------------------------------------------------------------------------- #

ci_have() {
    command -v "$1" >/dev/null 2>&1
}

ci_require_cmd() {
    local cmd
    for cmd in "$@"; do
        ci_have "${cmd}" || ci_die "required command not found: ${cmd}"
    done
}

# ci_require_var <name>: fail early when a required value is empty.
ci_require_var() {
    local name="$1"
    local value="${!name:-}"
    [ -n "${value}" ] || ci_die "required environment variable is empty: ${name}"
}

# ci_match <value> <regex> <label>: assert a value has the expected shape.
ci_match() {
    local value="$1" regex="$2" label="$3"
    if ! printf '%s\n' "${value}" | grep -Eq "${regex}"; then
        ci_die "invalid ${label}: '${value}' does not match ${regex}"
    fi
}

# ci_emit_output <name> <value>: publish a stage result.
# Writes to $GITHUB_OUTPUT inside Actions, to $CI_OUTPUT_ENV for local runs, and
# to stdout when neither is configured.
ci_emit_output() {
    local name="$1"
    local value="${2-}"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "${name}" "${value}" >>"${GITHUB_OUTPUT}"
    fi
    if [ -n "${CI_OUTPUT_ENV:-}" ]; then
        printf '%s=%s\n' "${name}" "${value}" >>"${CI_OUTPUT_ENV}"
    fi
    if [ -z "${GITHUB_OUTPUT:-}" ] && [ -z "${CI_OUTPUT_ENV:-}" ]; then
        printf '%s=%s\n' "${name}" "${value}"
    fi
}

# ci_load_env_file <path>: load the outputs published by an earlier stage.
#
# Stage outputs are emitted with lowercase names because they become GitHub step
# outputs; a local run writes them to a KEY=VALUE file instead. This loader exports
# every entry as CI_<UPPERCASE>, which is exactly how the workflow passes the same
# values on to a stage, so one code path serves both. Values that are already set in
# the environment win over the file.
ci_load_env_file() {
    local path="${1:-}"
    local line key value var
    [ -n "${path}" ] || return 0
    [ -f "${path}" ] || ci_die "stage input file not found: ${path}"
    while IFS= read -r line; do
        case "${line}" in
            "" | \#*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        [ -n "${key}" ] || continue
        var="CI_$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]')"
        # printenv keeps this portable: bash 3.2 has no ${!var:-} default expansion.
        if [ -z "$(printenv "${var}" 2>/dev/null || true)" ]; then
            export "${var}=${value}"
        fi
    done <"${path}"
    ci_log "loaded stage inputs from ${path}"
}

# --------------------------------------------------------------------------- #
# Hashing and sizes
# --------------------------------------------------------------------------- #

ci_sha256() {
    local file="$1"
    [ -f "${file}" ] || ci_die "cannot hash missing file: ${file}"
    if ci_have sha256sum; then
        sha256sum "${file}" | cut -d' ' -f1
    elif ci_have shasum; then
        shasum -a 256 "${file}" | cut -d' ' -f1
    else
        ci_die "no sha256 implementation found (sha256sum or shasum)"
    fi
}

# ci_sha256_text: hash stdin, used for stable cache key material.
ci_sha256_text() {
    if ci_have sha256sum; then
        sha256sum | cut -d' ' -f1
    elif ci_have shasum; then
        shasum -a 256 | cut -d' ' -f1
    else
        ci_die "no sha256 implementation found (sha256sum or shasum)"
    fi
}

# ci_file_size <file>: byte size, without relying on GNU stat.
ci_file_size() {
    local file="$1" size
    [ -f "${file}" ] || ci_die "cannot size missing file: ${file}"
    size="$(wc -c <"${file}")"
    printf '%s' "${size// /}"
}

# ci_hash_manifest <file...>: repo-relative path plus sha256 for each file, one
# line per file, sorted so the result does not depend on argument order.
ci_hash_manifest() {
    local path digest
    for path in "$@"; do
        [ -f "${path}" ] || ci_die "missing file for cache key: ${path}"
        digest="$(ci_sha256 "${path}")"
        printf '%s %s\n' "${path#"${CI_REPO_ROOT}"/}" "${digest}"
    done | LC_ALL=C sort
}

# --------------------------------------------------------------------------- #
# Network
# --------------------------------------------------------------------------- #

# ci_download <url> <destination>: atomic, retrying download.
ci_download() {
    local url="$1" dest="$2"
    local dest_dir
    dest_dir="$(dirname "${dest}")"
    mkdir -p "${dest_dir}"
    ci_log "download ${url}"
    if ! curl --fail --location --silent --show-error \
        --retry 4 --retry-delay 2 --retry-connrefused \
        --connect-timeout 20 --max-time 900 \
        --output "${dest}.part" "${url}"; then
        rm -f "${dest}.part"
        ci_die "download failed: ${url}"
    fi
    mv "${dest}.part" "${dest}"
}

# ci_lookup_sha256 <sums-file> <path-as-listed-in-sums>
# The mirror's sha256sums uses the "<hash> *<path>" form.
ci_lookup_sha256() {
    local sums="$1" want="$2" found
    found="$(awk -v want="${want}" '$2 == "*" want { print $1 }' "${sums}")"
    if [ -z "${found}" ]; then
        ci_die "sha256sums has no entry for ${want}"
    fi
    if [ "$(printf '%s\n' "${found}" | wc -l | tr -d ' ')" != "1" ]; then
        ci_die "sha256sums has multiple entries for ${want}"
    fi
    printf '%s' "${found}"
}

# ci_platform_modes <dir>: the platform layer gets its executability from the directory
# convention rather than from how the files happen to be stored in git or in a tarball,
# so both the image build and the payload build produce a runnable layer.
ci_platform_modes() {
    local dir="$1" argv="chmod"
    if [ "${2:-}" = "sudo" ]; then
        argv="sudo chmod"
    fi
    [ -d "${dir}" ] || return 0
    find "${dir}" -type f -exec ${argv} 0644 {} +
    local sub
    for sub in usr/sbin etc/init.d lib/upgrade; do
        [ -d "${dir}/${sub}" ] || continue
        find "${dir}/${sub}" -type f -exec ${argv} 0755 {} +
    done
}

# ci_platform_startlinks <dir> [sudo]: the init.d hooks only run when the rcS start
# links exist, and those links are not part of the source tree, so every producer of a
# platform layer has to create them.
ci_platform_startlinks() {
    local dir="$1" ln="ln" mkdir="mkdir"
    if [ "${2:-}" = "sudo" ]; then
        ln="sudo ln"; mkdir="sudo mkdir"
    fi
    ${mkdir} -p "${dir}/etc/rc.d"
    ${ln} -sf ../init.d/ab-boot "${dir}/etc/rc.d/S15ab-boot"
    ${ln} -sf ../init.d/ab-commit "${dir}/etc/rc.d/S99ab-commit"
}
