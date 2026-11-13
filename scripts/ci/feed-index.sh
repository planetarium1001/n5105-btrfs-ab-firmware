#!/usr/bin/env bash
# Stage "feed-index": render the AB-FEED 1 index a machine reads to find updates.
#
# This is the producer half of the device update feed. The consumer half is
# platform/lib/ab-feed.sh, which parses the index with awk and enforces two rules that
# therefore have to hold in everything this stage writes:
#
#   * every entry carries all three identities - platform, base, kernel - because the
#     device shows them side by side and never infers one from another (a minor bump can
#     keep the kernel, a patch bump can move it, and the platform number says nothing
#     about the system underneath);
#   * entries are ordered newest platform first, strictly. The device checks the order
#     instead of sorting, because a sorted view would hide a publisher that stopped
#     maintaining it.
#
# Format (one `key value` per line, `entry` ... `end` blocks, `#` starts a comment):
#
#   AB-FEED 1
#   channel   stable
#   generated 2026-11-13T00:00:00Z
#   entry
#     platform 0.0.8
#     base     25.12.2
#     kernel   6.12.103
#     payload  n5105-ab-25.12.2-upgrade.tar
#     size     20480000
#     sha256   3f2a<62 more hex>
#     url      https://example.org/n5105/feed/v1/n5105-ab-25.12.2-upgrade.tar
#   end
#
# `url` is written only when a base URL is known. A relative `url` would be resolved by
# the device's fetcher against the wrong base, so the line is omitted instead and the
# device falls back to its own feed URL plus `payload`.
#
# Usage:
#   feed-index.sh --out <file> [--channel <name>] [--base-url <url>]
#                 [--kernel <x.y.z>] [--payload <name>]
#                 --release <dir> [--release <dir> ...]
#
# Each --release directory is one published release and must carry:
#   release-notes.md   produced by release.sh; read for platform, base and kernel
#   SHA256SUMS         produced by release.sh; the payload digest, re-checked here
#   <payload>          the payload tar itself, measured here for its size
#
# A release may be listed any number of times, in any order: the index is sorted by
# platform version, so the release job can pass its directories in whatever order the
# downloads arrive.
#
# Environment:
#   CI_FEED_CHANNEL   default --channel
#   CI_FEED_BASE_URL  default --base-url, the directory the index will be served from
#   CI_FEED_GENERATED default --generated, for a reproducible index in a test
#   CI_KERNEL_PACKAGE default --kernel, the kernel package version from the build
#
# Exit status:
#   0   the index was written
#   1   a release directory is incomplete, or a value contradicts the files beside it
#   2   a usage error
#   3   a release directory does not say which kernel it ships. This is the one shortfall
#       that is not an error: release.sh reports it and publishes without an index, which
#       leaves the release installable by hand and the feed one release behind.
#
# Outputs: feed_index, feed_index_entries, feed_index_platforms

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

ci_stage_init feed-index

usage() {
    sed -n '/^# Usage:/,/^# Outputs:/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' >&2
    exit 2
}

die_usage() {
    printf '[%s] ERROR: %s\n' "${CI_STAGE}" "$*" >&2
    exit 2
}

# A release that cannot name its kernel is not an error here: the caller decides whether
# that is worth failing a release over. See the exit status table above.
die_no_kernel() {
    printf '[%s] ERROR: %s\n' "${CI_STAGE}" "$*" >&2
    exit 3
}

out=""
channel="${CI_FEED_CHANNEL:-stable}"
base_url="${CI_FEED_BASE_URL:-}"
generated="${CI_FEED_GENERATED:-}"
kernel_override="${CI_KERNEL_PACKAGE:-}"
payload_override=""
release_dirs=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) out="${2:?--out needs a file}"; shift 2 ;;
        --channel) channel="${2:?--channel needs a name}"; shift 2 ;;
        --base-url) base_url="${2:?--base-url needs a url}"; shift 2 ;;
        --generated) generated="${2:?--generated needs a timestamp}"; shift 2 ;;
        --kernel) kernel_override="${2:?--kernel needs a version}"; shift 2 ;;
        --payload) payload_override="${2:?--payload needs a file name}"; shift 2 ;;
        --release) release_dirs+=("${2:?--release needs a directory}"); shift 2 ;;
        --from-github)
            # The listing is one `gh release list` away, but it needs network and a token
            # in a stage that is otherwise a pure function of files. The release job
            # already has the directories it published, so it passes those instead.
            die_usage "--from-github is not supported; pass --release <dir> for each release"
            ;;
        -h | --help) usage ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

[ -n "${out}" ] || die_usage "--out is required"
[ "${#release_dirs[@]}" -gt 0 ] || die_usage "at least one --release <dir> is required"
ci_match "${channel}" '^[a-z][a-z0-9-]*$' "channel name"
[ -n "${generated}" ] || generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ci_match "${generated}" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "generated timestamp"
if [ -n "${base_url}" ]; then
    case "${base_url}" in
        *[[:space:]]*) ci_die "--base-url contains whitespace: '${base_url}'" ;;
    esac
fi

# --------------------------------------------------------------------------- #
# Reading one release directory
# --------------------------------------------------------------------------- #

# note_field <notes> <label>: the value of a `| label | value |` row of the notes table.
# The notes are written by release.sh and copied into the release by hand in the wild, so
# the parse is by label and tolerates padding, not by column position.
note_field() {
    awk -F'|' -v want="$2" '
        NF >= 3 {
            key = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != want) next
            value = $3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/`/, "", value)
            print value
            exit
        }
    ' "$1"
}

# kernel_in_payload <dir> <payload>: the `kernel` member of the payload manifest, used
# when the notes predate the kernel row. The manifest is the build's own record of the
# kernel package, so this reads the same fact from the artifact instead of a second place.
kernel_in_payload() {
    local dir="$1" payload="$2" value=""
    case "${payload}" in
        *.tar) : ;;
        *) return 0 ;;
    esac
    [ -f "${dir}/${payload}" ] || return 0
    ci_have tar || return 0
    value="$(tar -xOf "${dir}/${payload}" manifest.json 2>/dev/null |
        sed -n 's/^[[:space:]]*"kernel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1)" || value=""
    printf '%s' "${value}"
}

# kernel_version <kernel-package>: `6.12.103~<source hash>-r1` -> `6.12.103`.
# The index carries the kernel version, because that is what a reader compares; the
# package release suffix changes whenever the package is rebuilt and says nothing about
# which kernel runs.
kernel_version() {
    printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# payload_in_sums <sums>: the one archive in the checksum file that a device can install.
payload_in_sums() {
    awk '{ name = $2; sub(/^\*/, "", name); if (name ~ /-upgrade\.tar$/) print name }' "$1"
}

# sums_digest <sums> <name>
sums_digest() {
    awk -v want="$2" '
        { name = $2; sub(/^\*/, "", name); if (name == want) { print $1; exit } }
    ' "$1"
}

staging="$(mktemp "${TMPDIR:-/tmp}/feed-index.XXXXXX")"
seen="$(mktemp "${TMPDIR:-/tmp}/feed-index-seen.XXXXXX")"
sorted=""
out_tmp=""
cleanup() {
    rm -f "${staging}" "${seen}" "${sorted:-}" "${out_tmp:-}"
}
trap cleanup EXIT INT TERM

ci_log "index out=${out} channel=${channel} releases=${#release_dirs[@]}"

for dir in "${release_dirs[@]}"; do
    [ -d "${dir}" ] || ci_die "release directory not found: ${dir}"
    notes="${dir}/release-notes.md"
    sums="${dir}/SHA256SUMS"
    [ -f "${notes}" ] || ci_die "no release-notes.md in ${dir}; it is where the platform and base versions are recorded"
    [ -f "${sums}" ] || ci_die "no SHA256SUMS in ${dir}; it is where the payload digest comes from"

    platform="$(note_field "${notes}" "Platform version")"
    base="$(note_field "${notes}" "Upstream version")"
    [ -n "${platform}" ] || ci_die "${notes} has no '| Platform version |' row"
    [ -n "${base}" ] || ci_die "${notes} has no '| Upstream version |' row"
    ci_match "${platform}" "${CI_VERSION_RE}" "platform version (${dir})"
    ci_match "${base}" "${CI_VERSION_RE}" "base version (${dir})"

    if [ -n "${payload_override}" ]; then
        payload="${payload_override}"
    else
        payloads="$(payload_in_sums "${sums}")"
        payload_count="$(printf '%s\n' "${payloads}" | grep -c '[^[:space:]]' || true)"
        [ "${payload_count}" -ge 1 ] ||
            ci_die "${sums} lists no *-upgrade.tar: ${dir} has nothing a device can install"
        [ "${payload_count}" -eq 1 ] ||
            ci_die "${sums} lists ${payload_count} payloads: pass --payload <name> for ${dir}"
        payload="${payloads}"
    fi
    [ -f "${dir}/${payload}" ] ||
        ci_die "${sums} names ${payload} but ${dir} does not contain it"

    sha256="$(sums_digest "${sums}" "${payload}")"
    [ -n "${sha256}" ] || ci_die "${sums} has no digest for ${payload}"
    ci_match "${sha256}" "${CI_SHA256_RE}" "payload digest for ${payload}"
    # The digest in SHA256SUMS is the published claim; the file beside it is the bytes
    # that will actually be served. Hashing the bytes catches a stale or hand-edited
    # checksum file here instead of on a machine that already downloaded them.
    actual_sha="$(ci_sha256 "${dir}/${payload}")"
    [ "${actual_sha}" = "${sha256}" ] ||
        ci_die "${sums} claims ${sha256} for ${payload} but the file is ${actual_sha} (${dir})"
    size="$(ci_file_size "${dir}/${payload}")"
    printf '%s\n' "${size}" | grep -Eq '^[0-9]+$' || ci_die "could not size ${dir}/${payload}"
    [ "${size}" -gt 0 ] || ci_die "${dir}/${payload} is empty"

    kernel_package=""
    if [ -n "${kernel_override}" ]; then
        kernel_package="${kernel_override}"
    else
        kernel_package="$(note_field "${notes}" "Kernel package")"
    fi
    case "${kernel_package}" in
        "" | "not recorded") kernel_package="$(kernel_in_payload "${dir}" "${payload}")" ;;
    esac
    [ -n "${kernel_package}" ] ||
        die_no_kernel "${dir} does not say which kernel it ships (no '| Kernel package |' row in ${notes}, no kernel in ${payload}); pass --kernel <x.y.z> or set CI_KERNEL_PACKAGE"
    kernel="$(kernel_version "${kernel_package}")"
    [ -n "${kernel}" ] ||
        ci_die "kernel '${kernel_package}' in ${dir} is not a version like 6.12.103"
    ci_match "${kernel}" "${CI_VERSION_RE}" "kernel version (${dir})"

    # Two directories claiming the same platform version would give the device two
    # identical candidates and no way to tell which payload belongs to which release.
    if grep -Fxq "${platform}" "${seen}"; then
        ci_die "platform version ${platform} appears in more than one release directory"
    fi
    printf '%s\n' "${platform}" >>"${seen}"

    url=""
    if [ -n "${base_url}" ]; then
        url="${base_url%/}/${payload}"
    fi

    major="$(printf '%s' "${platform%%.*}")"
    rest="${platform#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    # Ten tab-separated fields, the last one possibly empty: `read` fills a missing final
    # field with the empty string, so an index without a base URL still sorts and reads.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${major}" "${minor}" "${patch}" "${platform}" "${base}" "${kernel}" \
        "${payload}" "${size}" "${sha256}" "${url}" >>"${staging}"

    ci_log "entry platform=${platform} base=${base} kernel=${kernel} payload=${payload} size=${size} sha256=${sha256}${url:+ url=${url}}"
done

entries_count="${#release_dirs[@]}"

# --------------------------------------------------------------------------- #
# Order: newest platform first, strictly descending
# --------------------------------------------------------------------------- #

sorted="$(mktemp "${TMPDIR:-/tmp}/feed-index-sorted.XXXXXX")"
# Numeric, per segment: a string sort would put 0.0.10 before 0.0.9, and the device would
# refuse the whole index with feed-index-order - the failure this sort exists to prevent.
LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3nr "${staging}" >"${sorted}"

out_dir="$(dirname "${out}")"
mkdir -p "${out_dir}"
out_tmp="${out}.tmp.$$"

{
    printf 'AB-FEED 1\n'
    printf '%-9s %s\n' 'channel' "${channel}"
    printf '%-9s %s\n' 'generated' "${generated}"
    while IFS="$(printf '\t')" read -r _major _minor _patch platform base kernel payload size sha256 url; do
        printf 'entry\n'
        printf '  %-8s %s\n' 'platform' "${platform}"
        printf '  %-8s %s\n' 'base' "${base}"
        printf '  %-8s %s\n' 'kernel' "${kernel}"
        printf '  %-8s %s\n' 'payload' "${payload}"
        printf '  %-8s %s\n' 'size' "${size}"
        printf '  %-8s %s\n' 'sha256' "${sha256}"
        if [ -n "${url}" ]; then
            printf '  %-8s %s\n' 'url' "${url}"
        fi
        printf 'end\n'
    done <"${sorted}"
} >"${out_tmp}"

mv "${out_tmp}" "${out}"
out_tmp=""

platforms="$(awk -F'\t' '{ printf "%s%s", sep, $4; sep = " " }' "${sorted}")"
ci_log "wrote ${out}: ${entries_count} entry/entries, platform ${platforms}"
ci_log "index content:"
sed -e 's/^/[feed-index]   /' "${out}"

ci_emit_output "feed_index" "${out}"
ci_emit_output "feed_index_entries" "${entries_count}"
ci_emit_output "feed_index_platforms" "${platforms}"

ci_log "stage feed-index finished"
