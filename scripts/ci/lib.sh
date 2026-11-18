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
# Locations
#
# The repo root is needed before the pinned inputs are resolved: the upstream pin is
# read from a tracked file rather than inlined here.
# --------------------------------------------------------------------------- #

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd "${CI_LIB_DIR}/../.." && pwd)}"
export CI_REPO_ROOT

# --------------------------------------------------------------------------- #
# Pinned inputs
# --------------------------------------------------------------------------- #

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
# Upstream pin
#
# The pinned upstream release lives in .github/upstream-pin.conf, not in this file:
# the upstream auto-release workflow (task 20261112-02) has to bump it on a branch
# that does not own lib.sh, and two branches editing the same line is how a merge
# conflict turns into a silently stale pin. This file is therefore the only reader
# and `ci_write_upstream_pin` the only writer.
#
# Precedence: explicit CI_UPSTREAM_VERSION_PIN > pin file > CI_UPSTREAM_PIN_DEFAULT.
# --------------------------------------------------------------------------- #

CI_UPSTREAM_PIN_FILE="${CI_UPSTREAM_PIN_FILE:-${CI_REPO_ROOT}/.github/upstream-pin.conf}"
# Last-resort value, used only when the pin file is missing or unreadable. It is not
# the pin: CI_UPSTREAM_VERSION_PIN below is what the stage scripts consume.
CI_UPSTREAM_PIN_DEFAULT="25.12.2"

# ci_upstream_pin_file: where the pin lives (for messages and tests).
ci_upstream_pin_file() {
    printf '%s\n' "${CI_UPSTREAM_PIN_FILE}"
}

# ci_upstream_pin_read: the pin from the file, or the built-in default.
# An unreadable or malformed file must not produce an empty pin: the fetch stage would
# then resolve "latest" and quietly build a different release than the one under test.
ci_upstream_pin_read() {
    local file="${CI_UPSTREAM_PIN_FILE}" version=""
    if [ -f "${file}" ]; then
        version="$(sed -n 's/^[[:space:]]*UPSTREAM_VERSION=//p' "${file}" | tail -n 1)"
        version="${version%"${version##*[![:space:]]}"}"
        if ! printf '%s\n' "${version}" | grep -Eq "${CI_VERSION_RE}"; then
            printf '[ci] WARNING: ignoring invalid upstream pin in %s: %s\n' \
                "${file}" "${version:-<empty>}" >&2
            version=""
        fi
    fi
    [ -n "${version}" ] || version="${CI_UPSTREAM_PIN_DEFAULT}"
    printf '%s\n' "${version}"
}

# ci_write_upstream_pin <version>: the single write entry for the pin.
# Rewrites only the UPSTREAM_VERSION line, keeps the explaining comment block, and
# replaces the file atomically so a parallel reader never sees a half-written pin.
ci_write_upstream_pin() {
    local version="${1:-}"
    [ -n "${version}" ] || ci_die "ci_write_upstream_pin requires a version"
    ci_match "${version}" "${CI_VERSION_RE}" "upstream pin"
    local file="${CI_UPSTREAM_PIN_FILE}" dir tmp
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"
    tmp="$(mktemp "${dir}/.upstream-pin.XXXXXX")"
    if [ -f "${file}" ] && grep -q '^[[:space:]]*UPSTREAM_VERSION=' "${file}"; then
        sed "s|^[[:space:]]*UPSTREAM_VERSION=.*|UPSTREAM_VERSION=${version}|" "${file}" >"${tmp}"
    elif [ -f "${file}" ]; then
        cat "${file}" >"${tmp}"
        printf 'UPSTREAM_VERSION=%s\n' "${version}" >>"${tmp}"
    else
        {
            printf '# Upstream ImmortalWrt release pinned by the pipeline.\n'
            printf '# Written by ci_write_upstream_pin (scripts/ci/lib.sh); see that function.\n'
            printf 'UPSTREAM_VERSION=%s\n' "${version}"
        } >"${tmp}"
    fi
    mv "${tmp}" "${file}"
    printf '[ci] pinned upstream version: %s\n' "${version}" >&2
}

# Upstream ImmortalWrt release consumed when no explicit version is requested.
# Bumping this value changes the cache key, so cached downloads are never reused
# across upstream versions.
CI_UPSTREAM_VERSION_PIN="${CI_UPSTREAM_VERSION_PIN:-$(ci_upstream_pin_read)}"

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
    # Both roots, not just the log directory: stages put their scratch under CI_TMP_ROOT
    # with `mktemp -d`. setup-ci exports CI_LOG_DIR inside CI_TMP_ROOT, so creating the
    # logs used to create both by accident; anything that overrides one of the two (the
    # release preflight test overrides CI_TMP_ROOT and inherits CI_LOG_DIR from the job)
    # left the scratch root missing and every mktemp under it failed.
    mkdir -p "${CI_TMP_ROOT}" "${CI_LOG_DIR}"
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

# ci_part_field <device> <field>: one partition field, read from the block device.
# blkid reads the GPT entry and the filesystem superblock directly; lsblk reads the same
# fields through udev, which covers a blkid that cannot answer with -p. An empty answer
# means "not readable yet", not "wrong": the caller decides whether to wait.
ci_part_field() {
    local device="$1" field="$2" value=""
    value="$(sudo blkid -p -o value -s "${field}" "${device}" 2>/dev/null || true)"
    if [ -z "${value}" ]; then
        value="$(sudo lsblk -ndo "${field}" "${device}" 2>/dev/null \
            | head -n 1 | sed 's/[[:space:]]*$//' || true)"
    fi
    printf '%s' "${value}"
}

# ci_wait_part_field <device> <field> [attempts] [interval]
# `losetup --find --show --partscan` returns before the kernel and udev have named the
# partitions, so a read-back taken right after it can see an empty GPT PARTNAME on a
# correct image - that race is what lost S2 on run 43553833091 while the same commit
# passed on a branch run. Poll until the field reads something, then let the caller judge
# the value; give up after a bounded wait so a device nobody named still fails.
ci_wait_part_field() {
    local device="$1" field="$2" attempts="${3:-40}" interval="${4:-0.25}" i=0 value=""
    while :; do
        value="$(ci_part_field "${device}" "${field}")"
        [ -n "${value}" ] && return 0
        i=$((i + 1))
        [ "${i}" -ge "${attempts}" ] && return 1
        sleep "${interval}"
    done
}

# --------------------------------------------------------------------------- #
# Loop devices
#
# `losetup --find --show --partscan` returns as soon as the loop device exists. The
# kernel names its partitions afterwards and udev creates their nodes after that, so a
# stage that reads p1..p4 right away races the mount. Run 43627138902 lost S5 to exactly
# that: the fixture waited for p4 only, then read p1 and died 24 ms in with "partition 1
# did not appear". The helpers below are shared by every stage that mounts an image file.
# --------------------------------------------------------------------------- #

# ci_udev_settle [timeout-seconds]: let udev finish naming the nodes it just received.
# Used when udevadm exists (the runner and a Linux laptop); a host without it skips the
# settle, and the bounded block-device poll below is what proves the nodes exist.
ci_udev_settle() {
    local timeout="${1:-10}"
    ci_have udevadm || return 0
    udevadm settle --timeout="${timeout}" 2>/dev/null || true
}

# ci_loop_backing <loop-device>: the image file sysfs says the loop device is bound to.
# An empty answer means the device is gone or is not a loop device: the caller decides
# whether that is a mount that has not finished or a mount that failed.
ci_loop_backing() {
    local loopdev="$1" name path
    name="$(basename "${loopdev}")"
    path="/sys/block/${name}/loop/backing_file"
    [ -f "${path}" ] || return 0
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${path}" 2>/dev/null || true
}

# ci_path_absolute <path>: the absolute spelling of a path, resolved through the
# directory that has to exist already. sysfs records the path losetup was given, and
# that may be relative, so comparing it with the caller's image needs one spelling.
ci_path_absolute() {
    local path="$1" dir
    dir="$(cd "$(dirname "${path}")" 2>/dev/null && pwd -P)" || {
        printf '%s\n' "${path}"
        return 0
    }
    printf '%s/%s\n' "${dir}" "$(basename "${path}")"
}

# ci_loop_matches <loop-device> <image>: true when the loop device carries <image>.
# A loop device left over from an earlier stage also answers --find --show; waiting for
# its partitions would wait on a disk that will never carry these partitions.
ci_loop_matches() {
    local loopdev="$1" image="$2" backing
    backing="$(ci_loop_backing "${loopdev}")"
    [ -n "${backing}" ] || return 1
    [ "$(ci_path_absolute "${backing}")" = "$(ci_path_absolute "${image}")" ]
}

# ci_wait_block <block-device> [attempts] [interval]: wait for one block device node.
# `-b` rather than `-e` on purpose: the mount that follows needs a block device, and a
# leftover plain file with that name would pass an existence test it cannot mount.
ci_wait_block() {
    local device="$1" attempts="${2:-40}" interval="${3:-0.25}" i=0
    until [ -b "${device}" ]; do
        i=$((i + 1))
        [ "${i}" -ge "${attempts}" ] && return 1
        sleep "${interval}"
    done
}

# ci_loop_diagnostics <loop-device> [image]: the three views a failed loop mount needs,
# printed before ci_die. The interesting half of the failure is in the kernel, not in the
# stage script: losetup says which file the loop carries, lsblk says which partition nodes
# exist, and dmesg says why the partition scan did not produce them. One run with these
# lines replaces a rerun with a guess.
ci_loop_diagnostics() {
    local loopdev="$1" image="${2:-unknown image}" tag="${CI_STAGE:-ci}"
    {
        printf '[%s] loop %s on %s did not come up\n' "${tag}" "${loopdev}" "${image}"
        printf '[%s] sudo losetup -a:\n' "${tag}"
        sudo losetup -a 2>&1 || true
        printf '[%s] lsblk %s:\n' "${tag}" "${loopdev}"
        sudo lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "${loopdev}" 2>&1 || true
        printf '[%s] dmesg | tail -20:\n' "${tag}"
        sudo dmesg 2>&1 | tail -20 || true
    } >&2
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
    # etc/hotplug.d is in this list because a hook there is executed by netifd's
    # hotplug-call, not sourced: stored at 0644 it is silently skipped, and a fallback that
    # never runs looks exactly like one that found nothing to do (measured 2026-11-18, while
    # wiring the iface hook that retries a package follow when the network comes back).
    for sub in usr/sbin etc/init.d lib/upgrade etc/hotplug.d; do
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
    ${ln} -sf ../init.d/ab-net-seed "${dir}/etc/rc.d/S16ab-net-seed"
    ${ln} -sf ../init.d/ab-net-reconcile "${dir}/etc/rc.d/S25ab-net-reconcile"
    ${ln} -sf ../init.d/ab-commit "${dir}/etc/rc.d/S99ab-commit"
}

# ci_render_net_defaults <dir>: render scripts/ci/net-defaults.conf.in into the platform
# layer as etc/net-defaults.conf. These are the only values that decide which port is the
# WAN, which ports join the bridge and whether the WAN SSH exception exists, so they are
# rendered from one template instead of being written out twice (image and payload).
#
# The CI_NET_* variables are the build-time overrides: an unset one keeps the shipped
# default. NET_WAN_SSH=closed is how a second release line without the WAN exception is
# produced, without a code change.
ci_render_net_defaults() {
    local dir="${1:?platform layer directory}"
    local template="${CI_NET_DEFAULTS_TEMPLATE:-${CI_LIB_DIR}/net-defaults.conf.in}"
    [ -f "${template}" ] || ci_die "net-defaults template not found: ${template}"
    local out="${dir}/etc/net-defaults.conf"
    mkdir -p "${dir}/etc"
    sed \
        -e "s|@NET_WAN_DEV@|${CI_NET_WAN_DEV:-eth0}|g" \
        -e "s|@NET_LAN_DEVS@|${CI_NET_LAN_DEVS:-auto}|g" \
        -e "s|@NET_LAN_ADDR@|${CI_NET_LAN_ADDR:-192.168.100.1}|g" \
        -e "s|@NET_LAN_PREFIX@|${CI_NET_LAN_PREFIX:-24}|g" \
        -e "s|@NET_WAN_SSH@|${CI_NET_WAN_SSH:-closed}|g" \
        "${template}" >"${out}" || ci_die "could not render ${out}"
    if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${out}"; then
        ci_die "net-defaults still carries unreplaced placeholders: ${out}"
    fi
    case "$(sed -n 's/^NET_WAN_SSH=//p' "${out}")" in
        open|closed) : ;;
        *) ci_die "NET_WAN_SSH must be open or closed: ${out}" ;;
    esac
    ci_log "rendered net-defaults: $(tr '\n' ' ' <"${out}" | sed -e 's/  */ /g')"
}

# ci_render_update_conf <dir>: render scripts/ci/update.conf.in into the platform layer as
# etc/ab/update.conf. The shipped answer to "is there something newer?" is this project's
# own releases, and it is the same answer in the image, on the disk image and in a payload,
# so it is rendered from one template at all three staging times instead of being written
# out three times.
#
# The CI_UPDATE_SOURCE, CI_UPDATE_REPO, CI_UPDATE_BASE and CI_UPDATE_CHANNEL variables are
# the build-time overrides: an unset one keeps the shipped default. CI_UPDATE_REPO is how a
# fork ships its own line and CI_UPDATE_BASE is how a proxy (ghproxy and friends) is baked
# in; both are also one-run flags on ab-upgrade.
#
# The device refuses a value it cannot act on, so the build refuses it first: an image with
# a source that is neither release nor feed, a repository that is not owner/name, a base
# that is not https, or a channel that is neither stable nor edge would be a machine whose
# update check can only fail.
ci_render_update_conf() {
    local dir="${1:?platform layer directory}"
    local template="${CI_UPDATE_CONF_TEMPLATE:-${CI_LIB_DIR}/update.conf.in}"
    [ -f "${template}" ] || ci_die "update.conf template not found: ${template}"
    local source="${CI_UPDATE_SOURCE:-release}"
    local repo="${CI_UPDATE_REPO:-planetarium1001/n5105-btrfs-ab-firmware}"
    local base="${CI_UPDATE_BASE:-https://github.com}"
    local channel="${CI_UPDATE_CHANNEL:-stable}"
    local out="${dir}/etc/ab/update.conf"
    mkdir -p "${dir}/etc/ab"
    sed \
        -e "s|@UPDATE_SOURCE@|${source}|g" \
        -e "s|@UPDATE_RELEASE_REPO@|${repo}|g" \
        -e "s|@UPDATE_RELEASE_BASE@|${base}|g" \
        -e "s|@UPDATE_CHANNEL@|${channel}|g" \
        "${template}" >"${out}" || ci_die "could not render ${out}"
    if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${out}"; then
        ci_die "update.conf still carries unreplaced placeholders: ${out}"
    fi
    case "${source}" in
        release|feed) : ;;
        *) ci_die "UPDATE_SOURCE must be release or feed: ${source}" ;;
    esac
    # owner/name, exactly one slash and no character a URL path would have to escape. A
    # repository that is not that cannot be turned into a release URL on the device.
    if ! [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        ci_die "UPDATE_RELEASE_REPO must be owner/name: ${repo}"
    fi
    case "${base}" in
        https://*) : ;;
        *) ci_die "UPDATE_RELEASE_BASE must be an https:// address: ${base}" ;;
    esac
    case "${channel}" in
        stable|edge) : ;;
        *) ci_die "UPDATE_CHANNEL must be stable or edge: ${channel}" ;;
    esac
    ci_log "rendered update.conf: $(grep -v '^#' "${out}" | tr '\n' ' ' | sed -e 's/  */ /g')"
}

# ci_render_release <file> <platform-version> <upstream-version> <stage>
# The release file is a template in the source tree; every producer of a platform
# layer renders it the same way, and refuses to pack a file with placeholders left.
ci_render_release() {
    local file="${1:?release file}" platform="${2:?platform version}" upstream="${3:?upstream version}" stage="${4:?stage}"
    [ -f "${file}" ] || ci_die "release template not found: ${file}"
    cat >"${file}" <<RELEASE
PLATFORM_VERSION=${platform}
UPSTREAM_VERSION=${upstream}
PLATFORM_STAGE=${stage}
RELEASE
    if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${file}"; then
        ci_die "release file still carries unreplaced placeholders: ${file}"
    fi
}
