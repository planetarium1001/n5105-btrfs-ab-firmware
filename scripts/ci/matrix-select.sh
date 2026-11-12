#!/usr/bin/env bash
# Matrix candidates for one upstream release: the new version plus the formal releases
# that came before it.
#
# A release is only believable when the same pipeline also refreshes the releases around
# it, and the interesting neighbour is always "the previous formal release", not "the
# previous release of this minor": 26.0.0 opens a new minor with no history of its own,
# so a same-minor rule would produce a matrix of one. The list is therefore global and
# version-ordered, and it never falls back to an older major to fill a hole - a 24.x
# build would exercise a different initramfs-tools and kmods layout, which is a
# different product, not an older build of this one.
#
# Usage:
#   matrix-select.sh --version <X.Y.Z> [--index <releases-index.html>] [--count 3]
#
# Inputs (environment):
#   CI_UPSTREAM_INDEX     local copy of the `releases/` index (tests; skips the download)
#   CI_UPSTREAM_BASE      mirror root (default: https://downloads.immortalwrt.org)
#   CI_WORK_DIR           scratch directory (default: $CI_TMP_ROOT/matrix-select)
#   CI_MIN_UPSTREAM_MAJOR lowest supported upstream major (default: 25)
#   GITHUB_OUTPUT, CI_OUTPUT_ENV
#                         where ci_emit_output writes
#
# Outputs:
#   candidates   space separated, the new version first, then the previous formal
#                releases newest first
#   gaps         how many previous formal releases short of --count the index left us
#                (0 when full); a previous release below the supported major is available
#                but can never be used as a candidate
#   gap_note     one human readable sentence when gaps > 0, empty otherwise
#   count        number of candidates, i.e. min(--count, usable previous) + 1

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init matrix-select

CI_MIN_UPSTREAM_MAJOR="${CI_MIN_UPSTREAM_MAJOR:-25}"

usage() {
    cat <<'USAGE'
usage: matrix-select.sh --version <X.Y.Z> [--index <releases-index.html>] [--count 3]

  --version  the upstream release being built (required, formal release only)
  --index    local copy of the mirror's releases/ index (default: download it)
  --count    how many previous formal releases to add (default: 3)
USAGE
}

# formal_releases_desc <index-file> <output-file>
#
# Write every formal release of <index-file> to <output-file>, newest first, one per
# line, and log the entries that were dropped. Formal means an exact `X.Y.Z` directory:
# an `-rc`/`-beta` suffix, a two-part version or `SNAPSHOT` is a different artefact line.
#
# The supported-major filter is *not* applied here, unlike in scripts/ci/upstream-watch.sh:
# a 24.x release cannot fill a candidate slot, but it is still a previous formal release
# that exists in the index, and `gaps` reports how many previous formal releases the
# index offers at all. Applying the major filter while counting would turn "the index
# only has an unusable 24.x" into "no gap", which is exactly the misreport the gap
# exists to prevent.
formal_releases_desc() {
    local index_file="$1" out_file="$2"
    local work dirs unique versioned raw
    work="$(dirname "${out_file}")"
    dirs="${work}/release-dirs.txt"
    unique="${work}/release-dirs-unique.txt"
    versioned="${work}/release-entries.txt"

    grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' "${index_file}" \
        | sed -e 's/^href="//' -e 's|/"$||' >"${dirs}" || true

    # Candidates and betas sit in the same index; name them once so the run log answers
    # "why not 25.13.0-rc1" without anyone opening the mirror.
    grep -oE 'href="[0-9][^"]*/"' "${index_file}" >"${versioned}" || true
    while IFS= read -r raw; do
        [ -n "${raw}" ] || continue
        raw="${raw#href=\"}"
        raw="${raw%/\"}"
        case "${raw}" in
            *[!0-9.]*) ci_log "ignored non-formal upstream entry ${raw}" ;;
        esac
    done <"${versioned}"

    LC_ALL=C sort -u "${dirs}" >"${unique}"
    LC_ALL=C sort -uV "${unique}" \
        | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' >"${out_file}"
}

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #

version=""
index_arg=""
count="3"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || ci_die "--version needs a value"
            version="$2"
            shift 2
            ;;
        --version=*)
            version="${1#--version=}"
            shift
            ;;
        --index)
            [ "$#" -ge 2 ] || ci_die "--index needs a file"
            index_arg="$2"
            shift 2
            ;;
        --index=*)
            index_arg="${1#--index=}"
            shift
            ;;
        --count)
            [ "$#" -ge 2 ] || ci_die "--count needs a number"
            count="$2"
            shift 2
            ;;
        --count=*)
            count="${1#--count=}"
            shift
            ;;
        -h | --help | help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            ci_die "unknown argument: $1"
            ;;
    esac
done

[ -n "${version}" ] || {
    usage >&2
    ci_die "--version is required"
}
ci_match "${version}" "${CI_VERSION_RE}" "upstream version"
major="${version%%.*}"
if [ "${major}" -lt "${CI_MIN_UPSTREAM_MAJOR}" ]; then
    ci_die "upstream version ${version} is below the supported major ${CI_MIN_UPSTREAM_MAJOR} (${major}.x)"
fi
ci_match "${count}" '^[0-9]+$' "--count"
if [ "${count}" -lt 1 ]; then
    ci_die "--count must be at least 1"
fi

# --------------------------------------------------------------------------- #
# Index
# --------------------------------------------------------------------------- #

work="${CI_WORK_DIR:-${CI_TMP_ROOT}/matrix-select}"
mkdir -p "${work}"
formal_list="${work}/formal-descending.txt"
older_desc="${work}/older-descending.txt"

index_path="${index_arg}"
if [ -z "${index_path}" ]; then
    index_path="${CI_UPSTREAM_INDEX:-}"
fi
if [ -z "${index_path}" ]; then
    index_path="${work}/releases-index.html"
    ci_download "${CI_UPSTREAM_BASE}/releases/" "${index_path}"
else
    [ -f "${index_path}" ] || ci_die "upstream index not found: ${index_path}"
    ci_log "index source: ${index_path}"
fi

formal_releases_desc "${index_path}" "${formal_list}"

# --------------------------------------------------------------------------- #
# Selection
# --------------------------------------------------------------------------- #

# Older formal releases, newest first: sort the published releases together with the
# target version and keep what sorts before it. `sort -u` collapses the case where the
# target is already published, so it can never appear as its own predecessor.
{
    cat "${formal_list}"
    printf '%s\n' "${version}"
} | LC_ALL=C sort -uV \
    | awk -v stop="${version}" '
        $0 == stop { seen = 1; next }
        !seen { line[++n] = $0 }
        END { for (i = n; i > 0; i--) print line[i] }
    ' >"${older_desc}"

candidates="${version}"
older_formal=0
selected=0
while IFS= read -r candidate; do
    [ -n "${candidate}" ] || continue
    older_formal=$((older_formal + 1))
    candidate_major="${candidate%%.*}"
    if [ "${candidate_major}" -lt "${CI_MIN_UPSTREAM_MAJOR}" ]; then
        # It exists and it is older, so it counts as "available" below, but it can never
        # take a candidate slot: a 24.x build is a different product line.
        ci_log "excluded candidate ${candidate}: major ${candidate_major} is below ${CI_MIN_UPSTREAM_MAJOR}"
        continue
    fi
    [ "${selected}" -lt "${count}" ] || continue
    candidates="${candidates} ${candidate}"
    selected=$((selected + 1))
done <"${older_desc}"

# A gap is a candidate slot that stays empty, so it is counted on the *selected* set: an
# older formal release below the supported major exists but can never fill a slot, and a
# silent 0 there would report a full matrix that is one release short.
gaps=0
if [ "${selected}" -lt "${count}" ]; then
    gaps=$((count - selected))
fi
gap_note=""
if [ "${gaps}" -gt 0 ]; then
    gap_note="only ${selected} of ${count} candidate slots filled"
    if [ "${older_formal}" -lt "${count}" ]; then
        gap_note="${gap_note}; the index publishes only ${older_formal} older formal release(s)"
    fi
    if [ "${older_formal}" -gt "${selected}" ]; then
        gap_note="${gap_note}; $((older_formal - selected)) older formal release(s) are below major ${CI_MIN_UPSTREAM_MAJOR} and cannot be candidates"
    fi
fi
candidate_count=$((selected + 1))

ci_log "candidates: ${candidates}"
if [ "${gaps}" -gt 0 ]; then
    ci_warn "${gap_note}"
fi

ci_emit_output "candidates" "${candidates}"
ci_emit_output "gaps" "${gaps}"
ci_emit_output "gap_note" "${gap_note}"
ci_emit_output "count" "${candidate_count}"
