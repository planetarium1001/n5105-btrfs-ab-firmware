#!/usr/bin/env bash
# Stage "release-same-base": the same-base half of the upgrade gates.
#
# The cross-version gate answers "can release N install over release N-1", and it does not
# know whether the two releases share a base: cross-upgrade.sh grades the A/B slot state,
# the packages and the ESP/payload digests, never the base or the kernel. An install across
# two different upstream bases is a real upgrade, but it proves nothing about the patch
# range a user is told is covered. This stage adds the facts that make that claim, and it
# does it from published assets instead of building the old image: the previous release's
# own `n5105-ab-<base>-install.img.gz`, taken from its tag and verified against that tag's
# SHA256SUMS.
#
# Two releases can publish an asset with the same file name - v0.0.9 and v0.0.10 both carry
# `n5105-ab-25.12.2-install.img.gz` - so the tag is part of the identity: a lookup that only
# matched the name would silently install the wrong image. Every subcommand carries the tag,
# and `fetch` refuses bytes that do not hash to the digest the tag's own SHA256SUMS lists.
#
# Subcommands:
#
#   select  --version <x.y.z> [--previous-tag <tag>] --out <dir>
#           Which release to download, and the digest to expect. Downloads that tag's
#           index.txt and SHA256SUMS into <dir> (they are the evidence the criteria are
#           graded from), reads the platform/base/kernel/payload identity out of the index,
#           and names the image as `n5105-ab-<base>-install.img.gz`. Emits tag, platform,
#           base, kernel, asset, sha256, index, sums.
#           No previous release - or an unreadable one - is a failure, never a skip: a gate
#           that cannot judge is not a passed gate.
#
#   fetch   --tag <tag> --asset <name> --sha256 <hex> --dest <dir>
#           Download one release asset and verify it against the digest the selector read
#           from that tag's SHA256SUMS. Emits path, sha256, size.
#
#   judge   --dir <dir> [--new-version <x.y.z>] [--pin <x.y.z>] [--new-payload <tar>]
#           Grade the same-base criteria from files alone. <dir> carries the old release's
#           evidence staged by the caller (old-index.txt, old-SHA256SUMS) and the new
#           release's (new-manifest.json, new-payload.sha256, new-payload.size,
#           new-version, new-pin). Prints one `same-base-check <name>=<ok|fail>` line per
#           criterion and a final `same-base=ok` or `same-base=fail reason=<first failure>`.
#           A failed grade still exits 0 - like cross-upgrade.sh, the verdict is the
#           interface, not the exit status - so the caller reads one line and not a trace.
#
# `gh` goes through ${CI_GH}: the test suite drives all three subcommands from fixture
# directories with a stub, so nothing here needs a network or a token.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

# No ci_stage_init on purpose: it writes a banner to stdout, and two of the subcommands
# below publish their answer on stdout. The stage tag is set by hand so the log lines are
# still attributable, and the scratch root is the caller's business - this script only reads
# directories it was handed and writes one download directory.
CI_STAGE="${CI_STAGE:-release-same-base}"

# The one external command this stage talks to. A variable, not a hard-coded `gh`, is what
# makes the offline test possible: the stub is a script that copies fixtures.
CI_GH="${CI_GH:-gh}"

usage() {
    cat >&2 <<'USAGE'
usage: release-same-base.sh <subcommand>

  select  --version <x.y.z> [--previous-tag <tag>] --out <dir>
          download the previous release's index.txt and SHA256SUMS, and answer which tag,
          which image asset and which digest this gate has to boot
  fetch   --tag <tag> --asset <name> --sha256 <hex> --dest <dir>
          download one release asset and verify it against the published digest
  judge   --dir <dir> [--new-version <x.y.z>] [--pin <x.y.z>] [--new-payload <tar>]
          grade the four same-base criteria from files alone and print same-base=ok|fail
USAGE
    exit 2
}

die_usage() {
    printf '[%s] ERROR: %s\n' "${CI_STAGE}" "$*" >&2
    exit 2
}

# version_lt <a> <b>: true when a < b, segment by segment, numerically.
# `sort -V` is GNU-only (the test suite also runs on a macOS laptop), and a string sort puts
# 0.0.10 before 0.0.9 - the one comparison this stage must not get wrong.
version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, A, "."); nb = split(b, B, ".")
        for (i = 1; i <= 3; i++) {
            x = (i <= na) ? A[i] + 0 : 0
            y = (i <= nb) ? B[i] + 0 : 0
            if (x != y) exit (x < y) ? 0 : 1
        }
        exit 1
    }'
}

# index_fields <index.txt>: the `key=value` lines of the first AB-FEED entry.
index_fields() {
    awk '
        $1 == "entry" { inentry = 1; next }
        $1 == "end" && inentry { exit }
        inentry && $1 ~ /^(platform|base|kernel|payload|size|sha256)$/ {
            value = $2
            for (i = 3; i <= NF; i++) value = value " " $i
            print $1 "=" value
        }
    ' "$1"
}

# blob_value <blob> <key>: one value out of an index_fields block.
blob_value() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# sums_digest <SHA256SUMS> <name>: the digest a checksum file lists for one name.
sums_digest() {
    awk -v want="$2" '
        { name = $2; sub(/^\*/, "", name); if (name == want) { print $1; exit } }
    ' "$1"
}

# first_line <file>: a one-value file, whitespace trimmed, empty when absent.
first_line() {
    [ -f "$1" ] || return 0
    sed -n '1p' "$1" | tr -d '[:space:]'
}

# newest_release_below <version>: the newest published v* release older than <version>.
#
# The list comes from `gh release list`, not from local tags: a shallow tag-line checkout has
# no tags to sort, and "published" is the stronger fact anyway. The numeric compare keeps the
# order honest (0.0.10 is newer than 0.0.9), and nothing is inferred from the base: the
# previous release of this product, whatever base it pinned, is the one to upgrade from.
newest_release_below() {
    local want="$1" best="" tag candidate
    while IFS= read -r tag; do
        case "${tag}" in v[0-9]*) : ;; *) continue ;; esac
        candidate="${tag#v}"
        printf '%s\n' "${candidate}" | grep -Eq "${CI_VERSION_RE}" || continue
        version_lt "${candidate}" "${want}" || continue
        if [ -z "${best}" ] || version_lt "${best}" "${candidate}"; then
            best="${candidate}"
        fi
    done < <("${CI_GH}" release list --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null || true)
    # An empty answer is an answer, and the caller reads it as one: a function that returned
    # non-zero here would end the stage under `set -e` before it could say why.
    [ -n "${best}" ] && printf 'v%s\n' "${best}"
    return 0
}

# --------------------------------------------------------------------------- #
# select: which release, and which digest to expect
# --------------------------------------------------------------------------- #
cmd_select() {
    local version="" previous_tag="" out=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version) version="${2:?--version needs a value}"; shift 2 ;;
            --previous-tag) previous_tag="${2:?--previous-tag needs a value}"; shift 2 ;;
            --out) out="${2:?--out needs a directory}"; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [ -n "${version}" ] || die_usage "--version is required"
    [ -n "${out}" ] || die_usage "--out is required"
    ci_match "${version}" "${CI_VERSION_RE}" "new platform version"
    mkdir -p "${out}"
    rm -f "${out}/index.txt" "${out}/SHA256SUMS"

    if [ -z "${previous_tag}" ]; then
        previous_tag="$(newest_release_below "${version}")"
    fi
    if [ -z "${previous_tag}" ]; then
        printf 'same-base=fail reason=no-previous-platform-release version=%s\n' "${version}"
        return 1
    fi
    previous_tag="v${previous_tag#v}"
    ci_log "previous release: ${previous_tag}" >&2

    # One file at a time, and the answer is read from what arrived, not from the exit status:
    # `gh release download` exits 1 both for "the release has no such asset" and for a network
    # failure, and those two are fixed differently (an index is absent when the build could
    # not name its kernel package; a network failure is retried). The distinction is made on
    # gh's own words for the first case, so a real outage is not misreported as a missing
    # asset - and a release that never published an index still gets the reason a reader can
    # act on.
    local file downloaded
    for file in index.txt SHA256SUMS; do
        downloaded=1
        if ! "${CI_GH}" release download "${previous_tag}" -p "${file}" -D "${out}" \
            >"${out}/${file}.download.log" 2>&1; then
            downloaded=0
        fi
        if [ -f "${out}/${file}" ]; then
            rm -f "${out}/${file}.download.log"
            continue
        fi
        if [ "${downloaded}" = "0" ] &&
            ! grep -Eqi 'no assets? match|no such asset|not found' "${out}/${file}.download.log"; then
            printf 'same-base=fail reason=cannot-download-the-previous-release tag=%s file=%s\n' \
                "${previous_tag}" "${file}"
            return 1
        fi
        rm -f "${out}/${file}.download.log"
        case "${file}" in
            index.txt)
                printf 'same-base=fail reason=previous-release-has-no-index tag=%s\n' "${previous_tag}"
                ;;
            *)
                printf 'same-base=fail reason=previous-release-has-no-sha256sums tag=%s\n' \
                    "${previous_tag}"
                ;;
        esac
        return 1
    done

    local fields platform base kernel payload size sha256 asset image_sha
    fields="$(index_fields "${out}/index.txt")"
    platform="$(blob_value "${fields}" platform)"
    base="$(blob_value "${fields}" base)"
    kernel="$(blob_value "${fields}" kernel)"
    payload="$(blob_value "${fields}" payload)"
    size="$(blob_value "${fields}" size)"
    sha256="$(blob_value "${fields}" sha256)"
    if [ -z "${platform}" ] || [ -z "${base}" ] || [ -z "${kernel}" ] ||
        [ -z "${payload}" ] || [ -z "${sha256}" ]; then
        printf 'same-base=fail reason=previous-index-is-incomplete tag=%s\n' "${previous_tag}"
        return 1
    fi
    ci_match "${base}" "${CI_VERSION_RE}" "previous base version"
    ci_match "${kernel}" "${CI_VERSION_RE}" "previous kernel version"
    ci_match "${sha256}" "${CI_SHA256_RE}" "previous payload digest"
    # The tag names the platform version; an index that disagrees with the tag it shipped
    # under is a release nobody can map back to what it proved.
    if [ "v${platform}" != "${previous_tag}" ]; then
        printf 'same-base=fail reason=tag-and-index-disagree tag=%s index-platform=%s\n' \
            "${previous_tag}" "${platform}"
        return 1
    fi

    asset="n5105-ab-${base}-install.img.gz"
    image_sha="$(sums_digest "${out}/SHA256SUMS" "${asset}")"
    if [ -z "${image_sha}" ]; then
        printf 'same-base=fail reason=sums-has-no-entry-for-the-image asset=%s tag=%s\n' \
            "${asset}" "${previous_tag}"
        return 1
    fi
    ci_match "${image_sha}" "${CI_SHA256_RE}" "image digest for ${asset}: ${out}/SHA256SUMS"

    ci_emit_output "tag" "${previous_tag}"
    ci_emit_output "platform" "${platform}"
    ci_emit_output "base" "${base}"
    ci_emit_output "kernel" "${kernel}"
    ci_emit_output "asset" "${asset}"
    ci_emit_output "sha256" "${image_sha}"
    ci_emit_output "payload" "${payload}"
    ci_emit_output "payload_size" "${size}"
    ci_emit_output "index" "${out}/index.txt"
    ci_emit_output "sums" "${out}/SHA256SUMS"
    printf '[%s] select tag=%s platform=%s base=%s kernel=%s asset=%s sha256=%s\n' \
        "${CI_STAGE}" "${previous_tag}" "${platform}" "${base}" "${kernel}" "${asset}" "${image_sha}" >&2
}

# --------------------------------------------------------------------------- #
# fetch: the image, verified against the digest the tag published
# --------------------------------------------------------------------------- #
cmd_fetch() {
    local tag="" asset="" sha256="" dest=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
            --asset) asset="${2:?--asset needs a value}"; shift 2 ;;
            --sha256) sha256="${2:?--sha256 needs a value}"; shift 2 ;;
            --dest) dest="${2:?--dest needs a directory}"; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [ -n "${tag}" ] || die_usage "--tag is required"
    [ -n "${asset}" ] || die_usage "--asset is required"
    [ -n "${sha256}" ] || die_usage "--sha256 is required"
    [ -n "${dest}" ] || die_usage "--dest is required"
    ci_match "${sha256}" "${CI_SHA256_RE}" "expected image digest"
    mkdir -p "${dest}"

    if ! "${CI_GH}" release download "${tag}" -p "${asset}" -D "${dest}" >&2; then
        printf 'same-base=fail reason=cannot-download-the-image tag=%s asset=%s\n' "${tag}" "${asset}"
        return 1
    fi
    local file="${dest}/${asset}" actual size
    if [ ! -f "${file}" ]; then
        printf 'same-base=fail reason=download-wrote-no-image tag=%s asset=%s\n' "${tag}" "${asset}"
        return 1
    fi
    actual="$(ci_sha256 "${file}")"
    if [ "${actual}" != "${sha256}" ]; then
        printf 'same-base=fail reason=image-digest-mismatch tag=%s asset=%s expected=%s got=%s\n' \
            "${tag}" "${asset}" "${sha256}" "${actual}"
        return 1
    fi
    size="$(ci_file_size "${file}")"
    ci_emit_output "path" "${file}"
    ci_emit_output "sha256" "${actual}"
    ci_emit_output "size" "${size}"
    printf '[%s] fetch tag=%s asset=%s sha256=%s size=%s\n' \
        "${CI_STAGE}" "${tag}" "${asset}" "${actual}" "${size}" >&2
}

# --------------------------------------------------------------------------- #
# judge: the four same-base criteria, from files alone
# --------------------------------------------------------------------------- #

# same_base_fail <reason>: the verdict line, and the one place a reason is spelled.
same_base_fail() {
    printf 'same-base=fail reason=%s\n' "$1"
}

cmd_judge() {
    local dir="" new_version="" pin="" new_payload=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dir) dir="${2:?--dir needs a directory}"; shift 2 ;;
            --new-version) new_version="${2:?--new-version needs a value}"; shift 2 ;;
            --pin) pin="${2:?--pin needs a value}"; shift 2 ;;
            --new-payload) new_payload="${2:?--new-payload needs a file}"; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [ -n "${dir}" ] || die_usage "--dir is required"

    [ -n "${new_version}" ] || new_version="$(first_line "${dir}/new-version")"
    # A caller may pass the tag it is publishing (`v0.0.11`); the comparison is between
    # platform versions, and `v` is the tag's spelling, not part of the number.
    new_version="${new_version#v}"
    [ -n "${pin}" ] || pin="$(first_line "${dir}/new-pin")"
    [ -n "${pin}" ] || pin="${CI_UPSTREAM_VERSION_PIN}"

    # --- the old release's evidence ----------------------------------------- #
    local old_index="${dir}/old-index.txt" old_sums="" candidate
    if [ ! -f "${old_index}" ]; then
        printf 'same-base-check old-index=fail\n'
        same_base_fail old-index-missing
        return 0
    fi
    local fields old_platform old_base old_kernel old_payload old_size old_sha
    fields="$(index_fields "${old_index}")"
    old_platform="$(blob_value "${fields}" platform)"
    old_base="$(blob_value "${fields}" base)"
    old_kernel="$(blob_value "${fields}" kernel)"
    old_payload="$(blob_value "${fields}" payload)"
    old_size="$(blob_value "${fields}" size)"
    old_sha="$(blob_value "${fields}" sha256)"
    if [ -z "${old_platform}" ] || [ -z "${old_base}" ] || [ -z "${old_kernel}" ] ||
        [ -z "${old_payload}" ] || [ -z "${old_sha}" ]; then
        printf 'same-base-check old-index=fail\n'
        same_base_fail old-index-is-incomplete
        return 0
    fi
    printf 'same-base-check old-index=ok platform=%s\n' "${old_platform}"

    for candidate in "${dir}/old-SHA256SUMS" "${dir}/SHA256SUMS"; do
        if [ -f "${candidate}" ]; then
            old_sums="${candidate}"
            break
        fi
    done
    if [ -z "${old_sums}" ]; then
        printf 'same-base-check old-sums=fail\n'
        same_base_fail old-sha256sums-missing
        return 0
    fi
    local old_sums_sha
    old_sums_sha="$(sums_digest "${old_sums}" "${old_payload}")"
    if [ -z "${old_sums_sha}" ] || [ "${old_sums_sha}" != "${old_sha}" ]; then
        printf 'same-base-check old-sums=fail payload=%s\n' "${old_payload}"
        same_base_fail old-sha256sums-do-not-match-the-index
        return 0
    fi
    printf 'same-base-check old-sums=ok payload=%s\n' "${old_payload}"

    # --- the new release's evidence ----------------------------------------- #
    local new_sha="" new_size=""
    if [ -n "${new_payload}" ]; then
        if [ ! -f "${new_payload}" ]; then
            printf 'same-base-check new-payload=fail\n'
            same_base_fail new-payload-missing
            return 0
        fi
        new_sha="$(ci_sha256 "${new_payload}")"
        new_size="$(ci_file_size "${new_payload}")"
    else
        new_sha="$(first_line "${dir}/new-payload.sha256")"
        new_size="$(first_line "${dir}/new-payload.size")"
    fi
    if [ -z "${new_sha}" ] || [ -z "${new_size}" ]; then
        printf 'same-base-check new-payload=fail\n'
        same_base_fail new-payload-identity-missing
        return 0
    fi

    # The caller may hand over the payload tar instead of the manifest: the manifest is a
    # member of that tar, so reading it out of the artifact the gate installs is one fact
    # fewer the caller could state wrongly.
    local manifest="${dir}/new-manifest.json" manifest_tmp="" kernel_package new_kernel
    if [ ! -f "${manifest}" ] && [ -n "${new_payload}" ]; then
        manifest_tmp="$(mktemp "${TMPDIR:-/tmp}/same-base-manifest.XXXXXX")"
        if tar -xOf "${new_payload}" manifest.json >"${manifest_tmp}" 2>/dev/null; then
            manifest="${manifest_tmp}"
        fi
    fi
    if [ ! -f "${manifest}" ]; then
        rm -f "${manifest_tmp}"
        printf 'same-base-check new-manifest=fail\n'
        same_base_fail new-payload-manifest-missing
        return 0
    fi
    # The manifest records the kernel *package*; the index records the kernel *version*. The
    # criteria compare what a reader compares, so the package suffix is stripped here - the
    # same reduction feed-index.sh does when it writes the index.
    # Not anchored to the start of a line: the manifest the build writes is pretty-printed,
    # but a fixture hands this one line, and the fact is the same fact in both shapes.
    kernel_package="$(sed -n 's/.*"kernel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${manifest}" | head -n 1)"
    rm -f "${manifest_tmp}"
    new_kernel="$(printf '%s' "${kernel_package}" |
        sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    if [ -z "${new_kernel}" ]; then
        printf 'same-base-check new-manifest=fail\n'
        same_base_fail new-payload-kernel-unknown
        return 0
    fi
    printf 'same-base-check new-payload=ok sha256=%s size=%s kernel=%s\n' \
        "${new_sha}" "${new_size}" "${new_kernel}"
    if [ -z "${new_version}" ]; then
        printf 'same-base-check new-version=fail\n'
        same_base_fail new-platform-version-unknown
        return 0
    fi
    ci_match "${new_version}" "${CI_VERSION_RE}" "new platform version"
    if [ -z "${pin}" ]; then
        printf 'same-base-check pin=fail\n'
        same_base_fail upstream-pin-unknown
        return 0
    fi

    # --- 1. the old image runs the base this release pins -------------------- #
    if [ "${old_base}" != "${pin}" ]; then
        printf 'same-base-check base=fail expected=%s got=%s\n' "${pin}" "${old_base}"
        same_base_fail base-is-not-the-pin
        return 0
    fi
    printf 'same-base-check base=ok base=%s\n' "${old_base}"

    # --- 2. the kernel did not move ------------------------------------------ #
    if [ "${old_kernel}" != "${new_kernel}" ]; then
        printf 'same-base-check kernel=fail expected=%s got=%s\n' "${new_kernel}" "${old_kernel}"
        same_base_fail kernel-is-not-the-payload-kernel
        return 0
    fi
    printf 'same-base-check kernel=ok kernel=%s\n' "${new_kernel}"

    # --- 3. the payload really changed --------------------------------------- #
    # A digest that did not move means the new artifact is the old one: the install proved
    # nothing about the patch range, whatever the slot state says. The size is printed beside
    # it because "same digest, same size" is the readable form of the same finding.
    if [ "${old_sha}" = "${new_sha}" ]; then
        printf 'same-base-check payload-differs=fail sha256=%s size=%s\n' "${new_sha}" "${new_size}"
        same_base_fail payload-digest-did-not-change
        return 0
    fi
    printf 'same-base-check payload-differs=ok old=%s new=%s old_size=%s new_size=%s\n' \
        "${old_sha}" "${new_sha}" "${old_size}" "${new_size}"

    # --- 4. forward, never a downgrade --------------------------------------- #
    if ! version_lt "${old_platform}" "${new_version}"; then
        printf 'same-base-check platform-advances=fail old=%s new=%s\n' \
            "${old_platform}" "${new_version}"
        same_base_fail platform-did-not-advance
        return 0
    fi
    printf 'same-base-check platform-advances=ok old=%s new=%s\n' \
        "${old_platform}" "${new_version}"

    printf 'same-base=ok old=%s new=%s base=%s kernel=%s\n' \
        "${old_platform}" "${new_version}" "${old_base}" "${new_kernel}"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "${cmd}" in
    select) cmd_select "$@" ;;
    fetch) cmd_fetch "$@" ;;
    judge) cmd_judge "$@" ;;
    -h | --help | help) usage ;;
    *) usage ;;
esac
