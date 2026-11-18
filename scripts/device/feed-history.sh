#!/bin/sh
# feed-history.sh - one release's own package feeds, probed, judged, and printed as a list.
#
# ac-9 asks whether every hop of the rise chain can install the community samples from
# *that release's own* feeds. Three facts answer it, and they are the three this driver
# collects:
#
#   1. the seven indexes a release publishes - five user-land catalogues (base, luci,
#      packages, routing, telephony), the target's own packages, and the kernel modules of
#      that release's kernel - are still fetchable and really are indexes;
#   2. which kmods directory that release's kernel has: <kernel>-1-<build hash>;
#   3. the pasteable list of those seven indexes, for
#      /etc/apk/repositories.d/customfeeds.list.
#
# Why customfeeds.list and not distfeeds.list: platform/lib/upgrade/packages.sh rewrites
# the distfeeds it owns to the new base's release on every hop (packages.sh:254) and never
# touches customfeeds.list (packages.sh:217,445,708), so a list that has to keep naming the
# release a machine was installed from has exactly one safe place to live. A distfeeds list
# still naming the old release is also what makes the follow probe judge `feeds-stale`
# (packages.sh:1112-1121) - a verdict about the machine, not about the feed.
#
# Why the kmods segment is read and never assembled: <kernel>-1-<build hash> is a build fact
# of that release. Measured on 2026-11-19, the three releases this round hops through carry
# 6.12.87-1-bd81971a…, 6.12.94-1-0413601b… and 6.12.103-1-0413601b…, and a path built from
# another release's segment answers 404 - so a guessed segment is a broken feed list that
# looks like a typed one. The segment is read from the release's own kmods/ directory page;
# a page that does not list it, or lists more than one, is a GAP with kmod=unknown and the
# one command that unblocks it (--kmod <the segment the release's own distfeeds.list
# names>), never a guess.
#
# Why the status code is not the verdict: a mirror that fronts its files with an anti-bot
# page answers 200 with HTML - measured on one mirror for all three releases - and a probe
# that reads only the status calls that usable. An apk v3 index starts with the four bytes
# `ADBd`, the same test platform/lib/ab-net-probe.sh uses on the device, so each answer is
# read and a 200 that is not an index is FAIL, not PASS.
#
#   feed-history.sh 25.12.0
#   feed-history.sh 25.12.0 --mirror https://mirrors.ustc.edu.cn/immortalwrt
#   feed-history.sh 25.12.0 --repos customfeeds.list     # just the URLs, for the device
#   feed-history.sh 25.12.0 --json                       # one object, for a caller
#   feed-history.sh 25.12.0 --kmod 6.12.87-1-bd81971a…   # when the listing is unreadable
#   feed-history.sh 25.12.0 --dry-run                    # the URLs, without a single call
#
# Output: one context line, one line per answer as it arrives, one verdict line, then the
# list. The verdict line is the only line that says PASS, FAIL or GAP.
#
#   feed-history release=25.12.0 mirror=… target=x86/64 arch=x86_64
#   feed-history feed=base http=200 index=ok url=…
#   … one per index, plus feed=kmods-dir for the page that names the kernel
#   feed-history kmods-segment=6.12.87-1-bd81971a… source=listing
#   feed-history verdict=PASS release=25.12.0 kernel=6.12.87 kmod=6.12.87-1-bd81971a… feeds=7/7
#   feed-history repositories begin
#   <one URL per line: the release's own index files>
#   feed-history repositories end
#
# Everything between `repositories begin` and `repositories end` can be pasted into
# /etc/apk/repositories.d/customfeeds.list as it stands; --repos writes those bytes to a
# file instead, which is what a device-side step wants. The kmods line is left out when the
# segment could not be read - a URL with a placeholder in it is a 404 somebody debugs on
# the device - and the verdict then says GAP rather than PASS.
#
# Environment:
#   AB_FH_MIRROR      default --mirror
#   AB_FH_TARGET      target directory under releases/<v>/targets (default x86/64)
#   AB_FH_ARCH        package architecture under releases/<v>/packages (default x86_64)
#   AB_FH_CURL        the fetcher (default curl); the seam a test points at a stub
#   AB_FH_TIMEOUT     default --timeout
#   AB_FH_REPOS       default --repos
#   AB_RESULTS        default --results
#   AB_EVIDENCE_DIR   default --evidence-dir
#   AB_DRY_RUN        default --dry-run
#
# This driver runs on the workstation and touches no machine: no ssh, no apk, one fetch per
# URL. It writes nothing except the files named on the command line.
#
# Exit status: 0 PASS (all seven are indexes and the segment was read), 1 FAIL (this
# release, on this mirror, does not publish an index it claims), 2 usage, 4 GAP (the
# question could not be answered: no fetcher, no network, kmods segment unknown).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=tests/lib/device_config.sh
. "${AB_REPO_ROOT}/tests/lib/device_config.sh"

# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #

MIRROR=${AB_FH_MIRROR:-https://downloads.immortalwrt.org}
TARGET=${AB_FH_TARGET:-x86/64}
ARCH=${AB_FH_ARCH:-x86_64}
FETCHER=${AB_FH_CURL:-curl}
TIMEOUT=${AB_FH_TIMEOUT:-60}
DRY_RUN=${AB_DRY_RUN:-0}
RESULTS=${AB_RESULTS:-}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
REPOS_OUT=${AB_FH_REPOS:-}

# The five user-land catalogues a release publishes beside its two target feeds. The order
# is this driver's, not the release's: a feed list is read as a set, and naming the members
# in one place keeps two runs of this script diffable.
FEEDS="base luci packages routing telephony"
# Bytes asked for per request. Four are the index magic; 8 KiB is more than any directory
# page needs, and both are range requests, so a megabyte index costs a handful of bytes on
# a server that honours them (one that does not sends the whole file, which is what the
# timeout is for).
INDEX_BYTES="0-7"
PAGE_BYTES="0-8191"
TAB=$(printf '\t')

RELEASE=""
KMOD=""
JSON=0
VERDICT=""
REASON=""
KERNEL=""
KMOD_PROBLEM=""
KMOD_FATAL=0
FEEDS_OK=0
FEEDS_TOTAL=0
FIELDS=""
ANSWERED=0
REPOS=""
EVIDENCE=""
WORK_DIR=""

usage() {
    cat <<'USAGE'
usage: feed-history.sh [RELEASE] [--release VERSION] [--mirror URL] [--kmod SEGMENT]
                       [--repos FILE] [--results FILE] [--evidence-dir DIR]
                       [--timeout SECONDS] [--dry-run] [--json]

  RELEASE              the release to question, e.g. 25.12.0 (also --release)
  --mirror URL         where the releases live (default https://downloads.immortalwrt.org)
  --kmod SEGMENT       the kmods directory this release uses, e.g.
                       6.12.87-1-bd81971a1c3f0490e17f340fe09229ea; read from the
                       release's own kmods/ page when omitted
  --repos FILE         write only the repository URLs to FILE (for customfeeds.list)
  --results FILE       append one FH-<release> row to this results TSV
  --evidence-dir DIR   where the per-release log goes (default <results dir>/evidence)
  --timeout SECONDS    per-request cap (default 60)
  --dry-run            print the URLs that would be probed; contact nothing
  --json               print one JSON object instead of the pasteable block

Exit status: 0 PASS, 1 FAIL, 2 usage, 4 GAP.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --release)
            RELEASE=${2:?--release needs a version}
            shift 2
            ;;
        --mirror)
            MIRROR=${2:?--mirror needs a URL}
            shift 2
            ;;
        --kmod)
            KMOD=${2:?--kmod needs a directory name}
            shift 2
            ;;
        --repos)
            REPOS_OUT=${2:?--repos needs a file}
            shift 2
            ;;
        --results)
            RESULTS=${2:?--results needs a file}
            shift 2
            ;;
        --evidence-dir)
            EVIDENCE_DIR=${2:?--evidence-dir needs a directory}
            shift 2
            ;;
        --timeout)
            TIMEOUT=${2:?--timeout needs a number}
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --json)
            JSON=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            printf 'feed-history.sh: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
        *)
            # A bare first argument is the release, because that is the one fact every run
            # has and typing it twice for a flag nobody reads is friction.
            if [ -n "${RELEASE}" ]; then
                printf 'feed-history.sh: unknown argument: %s\n' "${1}" >&2
                usage >&2
                exit 2
            fi
            RELEASE=${1}
            shift
            ;;
    esac
done

if [ -z "${RELEASE}" ]; then
    printf 'feed-history.sh: a release is required, e.g. 25.12.0\n' >&2
    usage >&2
    exit 2
fi
# A release is digits and dots, and the shape is checked before anything is fetched: a typo
# like `25.12` or `releases/25.12.0` would otherwise spend seven requests learning that the
# mirror answers 404.
case "${RELEASE}" in
    [0-9]*.[0-9]*) : ;;
    *)
        printf 'feed-history.sh: release %s is not a version, e.g. 25.12.0\n' "${RELEASE}" >&2
        exit 2
        ;;
esac
case "${RELEASE}" in
    *[!0-9.]*)
        printf 'feed-history.sh: release %s carries something other than digits and dots\n' \
            "${RELEASE}" >&2
        exit 2
        ;;
esac
case "${TIMEOUT}" in
    '' | *[!0-9]*)
        printf 'feed-history.sh: --timeout %s is not a whole number of seconds\n' "${TIMEOUT}" >&2
        exit 2
        ;;
esac
MIRROR=${MIRROR%/}
case "${MIRROR}" in
    http://* | https://*) : ;;
    *)
        printf 'feed-history.sh: --mirror %s is not an http:// or https:// URL\n' "${MIRROR}" >&2
        exit 2
        ;;
esac
if [ "${JSON}" = "1" ] && [ "${DRY_RUN}" = "1" ]; then
    # A plan is not a result: --json is what a caller parses to decide something, so it has
    # to carry a verdict, and --dry-run has none to carry.
    printf 'feed-history.sh: --json needs a verdict; --dry-run only has a plan\n' >&2
    exit 2
fi
if [ -n "${REPOS_OUT}" ] && ! : >"${REPOS_OUT}" 2>/dev/null; then
    # Checked before a single request: a run that judged the feeds and then could not hand
    # the list over has done half its job, and the caller would read the missing file as
    # "the probe was never run".
    printf 'feed-history.sh: --repos %s is not writable\n' "${REPOS_OUT}" >&2
    exit 2
fi

cleanup() {
    [ -z "${WORK_DIR}" ] || rm -rf "${WORK_DIR}" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------------------------------- #
# URLs
# --------------------------------------------------------------------------- #

# _release_url: the directory one release publishes on this mirror. Every other URL is
# built from it, so a mirror is one substitution and not seven.
_release_url() {
    printf '%s/releases/%s' "${MIRROR}" "${RELEASE}"
}

# _feed_url <catalogue>: the index URL of one user-land catalogue.
_feed_url() {
    printf '%s/packages/%s/%s/packages.adb' "$(_release_url)" "${ARCH}" "$1"
}

# _target_url: the index of the target's own, trimmed package set (the one carrying the
# kernel-bound few of the 103 apks the release measured).
_target_url() {
    printf '%s/targets/%s/packages/packages.adb' "$(_release_url)" "${TARGET}"
}

# _kmods_dir_url: the directory this release's kernel modules live under. This is the page
# that names the segment - the URL is never assembled from a version string.
_kmods_dir_url() {
    printf '%s/targets/%s/kmods/' "$(_release_url)" "${TARGET}"
}

# _kmods_url: the kmods index, once the segment is known.
_kmods_url() {
    printf '%s/targets/%s/kmods/%s/packages.adb' "$(_release_url)" "${TARGET}" "${KMOD}"
}

# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

# _emit <line>: one line of the human block - stdout unless --json, the evidence log
# always. A red or a GAP run is read from its log, so every fact has to be there even when
# the caller asked for the object only.
_emit() {
    if [ "${JSON}" != "1" ]; then
        printf '%s\n' "$1"
    fi
    if [ -n "${EVIDENCE}" ]; then
        printf '%s\n' "$1" >>"${EVIDENCE}" 2>/dev/null || true
    fi
}

# _bad <feed> <token>: remember the first thing that is wrong. The verdict line has room for
# one reason, so it carries the first; the per-feed lines above it name every one.
_bad() {
    if [ -z "${REASON}" ]; then
        REASON="$1=$2"
    fi
}

# --------------------------------------------------------------------------- #
# One request, and what its answer means
# --------------------------------------------------------------------------- #

# _fetch <url> <range> <body>: one request through the fetcher. The body lands in <body>,
# the status in _http, and a fetcher that cannot even start reads as 000 - "no answer" -
# rather than as a status nobody sent.
_fetch() {
    _http=$("${FETCHER}" -sS -o "$3" -w '%{http_code}' --max-time "${TIMEOUT}" -L \
        -r "$2" "$1" 2>"${WORK_DIR}/fetch.err")
    _http=$(printf '%s' "${_http}" | tr -d ' \t\r\n')
    case "${_http}" in
        [1-5][0-9][0-9]) : ;;
        *) _http=000 ;;
    esac
}

# _index_magic <body>: is it an apk v3 index? The four bytes `ADBd` are the one thing an
# anti-bot page, a directory listing or a hijacked DNS answer cannot produce.
_index_magic() {
    [ -f "$1" ] || return 1
    _im=$(head -c 4 "$1" 2>/dev/null) || return 1
    [ "${_im}" = "ADBd" ]
}

# _token <http> <body|->: what one answer means, in the word the row carries.
_token() {
    case "${1}" in
        200 | 206)
            if [ "$2" = "-" ]; then
                printf 'ok'
            elif _index_magic "$2"; then
                printf 'ok'
            else
                printf 'not-an-index'
            fi
            ;;
        000) printf 'unreachable' ;;
        *) printf 'http-%s' "${1}" ;;
    esac
}

# _probe_index <name> <url>: ask for one index and remember the answer. One line per probe,
# printed as it arrives: a run that dies half way still shows which URLs answered before it
# did, and the count in the verdict line is read from FEEDS_OK/FEEDS_TOTAL and not restated.
_probe_index() {
    _pi_name=$1
    _pi_url=$2
    _pi_body="${WORK_DIR}/index-${_pi_name}.body"
    _fetch "${_pi_url}" "${INDEX_BYTES}" "${_pi_body}"
    _pi_token=$(_token "${_http}" "${_pi_body}")
    FEEDS_TOTAL=$((FEEDS_TOTAL + 1))
    if [ "${_http}" != "000" ]; then
        ANSWERED=$((ANSWERED + 1))
    fi
    if [ "${_pi_token}" = "ok" ]; then
        FEEDS_OK=$((FEEDS_OK + 1))
    else
        _bad "${_pi_name}" "${_pi_token}"
    fi
    FIELDS="${FIELDS}${_pi_name}${TAB}${_http}${TAB}${_pi_token}${TAB}${_pi_url}
"
    _emit "$(printf 'feed-history feed=%s http=%s index=%s url=%s' \
        "${_pi_name}" "${_http}" "${_pi_token}" "${_pi_url}")"
}

# _kmods_page <url>: ask the release's own kmods/ directory page for its entries. Sets
# _kp_http and _kp_entries (the segments the page names, one per line, empty when it names
# none) and _kp_found (how many). The page bytes stay in the work dir for a reader who wants
# the listing itself.
_kmods_page() {
    _kp_body="${WORK_DIR}/kmods-dir.body"
    _fetch "$1" "${PAGE_BYTES}" "${_kp_body}"
    _kp_http=${_http}
    _kp_entries=""
    if [ "${_kp_http}" = "200" ] || [ "${_kp_http}" = "206" ]; then
        # The entries are the segment: <kernel>-1-<build hash>. Matched on the shape a
        # build hash has, because the rest of the page (sizes, dates, the parent link) is
        # not the answer and must not be able to look like one.
        _kp_entries=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]{8,}' "${_kp_body}" \
            2>/dev/null | sort -u)
    fi
    _kp_found=$(printf '%s\n' "${_kp_entries}" | sed '/^$/d' | wc -l | tr -d ' ')
    _emit "$(printf 'feed-history feed=kmods-dir http=%s segments=%s url=%s' \
        "${_kp_http}" "${_kp_found}" "$1")"
}

# _compose_repositories: the list a machine would be given. The five user-land indexes, the
# target's own, and - when the kernel is known - the kmods index of that kernel.
_compose_repositories() {
    REPOS=""
    # shellcheck disable=SC2086  # FEEDS is a space separated list by construction
    for _cr_feed in ${FEEDS}; do
        REPOS="${REPOS}$(_feed_url "${_cr_feed}")
"
    done
    REPOS="${REPOS}$(_target_url)
"
    if [ -n "${KMOD}" ]; then
        REPOS="${REPOS}$(_kmods_url)
"
    fi
}

# _repos_lines: how many URLs the list carries, for the row and the reader.
_repos_lines() {
    printf '%s' "${REPOS}" | wc -l | tr -d ' '
}

# _emit_json: the same facts as one object. Printed to stdout only - the evidence log keeps
# the block, which is what a reviewer reads.
_emit_json() {
    _json_sep=""
    printf '{"tool":"feed-history","release":"%s","mirror":"%s","target":"%s",' \
        "${RELEASE}" "${MIRROR}" "${TARGET}"
    printf '"arch":"%s","kernel":"%s","kmod":"%s","verdict":"%s","reason":"%s","feeds":[' \
        "${ARCH}" "${KERNEL:-unknown}" "${KMOD:-unknown}" "${VERDICT}" "${REASON:-none}"
    while IFS="${TAB}" read -r _j_name _j_http _j_token _j_url; do
        [ -n "${_j_name}" ] || continue
        printf '%s{"name":"%s","http":"%s","index":"%s","url":"%s"}' \
            "${_json_sep}" "${_j_name}" "${_j_http}" "${_j_token}" "${_j_url}"
        _json_sep=","
    done <<EOF
${FIELDS}
EOF
    printf '],"repositories":['
    _json_sep=""
    while IFS= read -r _j_url; do
        [ -n "${_j_url}" ] || continue
        printf '%s"%s"' "${_json_sep}" "${_j_url}"
        _json_sep=","
    done <<EOF
${REPOS}
EOF
    printf ']}\n'
}

# _row: one row in the shape every driver writes, so full-test.sh can audit this release
# like any other case. The note carries the facts a reader of the TSV needs without opening
# the log; the log carries the URLs.
_row() {
    [ -n "${RESULTS}" ] || return 0
    # Exported, not merely set: devcfg_record reads it from its own shell, and a variable
    # assigned in a caller's shell without export reaches the library as nothing - which is
    # how a driver silently writes its rows into a file nobody reads.
    DEVCFG_RESULTS=${RESULTS}
    export DEVCFG_RESULTS
    _row_note="reason=${REASON:-none} kernel=${KERNEL:-unknown} kmod=${KMOD:-unknown}"
    _row_note="${_row_note} feeds=${FEEDS_OK}/${FEEDS_TOTAL} repos=$(_repos_lines)"
    devcfg_record "FH-${RELEASE}" "${VERDICT}" "${EVIDENCE:--}" "${_row_note}"
}

# _finish <verdict> [reason]: settle the run. One place for the block, the list, the row and
# the exit status, so no path can print one verdict and exit with another path's code.
_finish() {
    VERDICT=$1
    if [ -n "${2:-}" ]; then
        REASON=$2
    fi
    _compose_repositories

    _finish_reason=""
    [ -z "${REASON}" ] || _finish_reason=$(printf ' reason=%s' "${REASON}")
    _emit "$(printf 'feed-history verdict=%s release=%s kernel=%s kmod=%s feeds=%s/%s%s' \
        "${VERDICT}" "${RELEASE}" "${KERNEL:-unknown}" "${KMOD:-unknown}" \
        "${FEEDS_OK}" "${FEEDS_TOTAL}" "${_finish_reason}")"

    if [ "${JSON}" = "1" ]; then
        _emit_json
    else
        _emit 'feed-history repositories begin'
        while IFS= read -r _finish_url; do
            [ -n "${_finish_url}" ] || continue
            _emit "${_finish_url}"
        done <<EOF
${REPOS}
EOF
        _emit 'feed-history repositories end'
    fi

    if [ -n "${REPOS_OUT}" ]; then
        printf '%s' "${REPOS}" >"${REPOS_OUT}"
        _emit "$(printf 'feed-history wrote %s lines=%s' "${REPOS_OUT}" "$(_repos_lines)")"
    fi

    _row

    case "${VERDICT}" in
        PASS) exit 0 ;;
        FAIL) exit 1 ;;
        *) exit 4 ;;
    esac
}

# --------------------------------------------------------------------------- #
# The plan, when nothing is to be contacted
# --------------------------------------------------------------------------- #

if [ "${DRY_RUN}" = "1" ]; then
    printf 'feed-history dry-run release=%s mirror=%s target=%s arch=%s\n' \
        "${RELEASE}" "${MIRROR}" "${TARGET}" "${ARCH}"
    # shellcheck disable=SC2086  # FEEDS is a space separated list by construction
    for _d_feed in ${FEEDS}; do
        printf 'feed-history dry-run feed=%s url=%s\n' "${_d_feed}" "$(_feed_url "${_d_feed}")"
    done
    printf 'feed-history dry-run feed=target url=%s\n' "$(_target_url)"
    if [ -n "${KMOD}" ]; then
        printf 'feed-history dry-run feed=kmods url=%s (segment from --kmod)\n' "$(_kmods_url)"
    else
        # Two URLs, because the second one is the point of the first: the segment in it is
        # read from the page, and a plan that invented one would hide that.
        printf 'feed-history dry-run feed=kmods-dir url=%s (the segment is read from this page)\n' \
            "$(_kmods_dir_url)"
        printf 'feed-history dry-run feed=kmods url=%s<segment>/packages.adb\n' \
            "$(_kmods_dir_url)"
    fi
    printf 'feed-history dry-run verdict=none note="a plan is not a verdict; run without --dry-run"\n'
    exit 0
fi

# --------------------------------------------------------------------------- #
# Run
# --------------------------------------------------------------------------- #

# Evidence and results are optional: the probe is useful from a terminal, and a run that
# invented a log file in the caller's directory would be worse than one that printed.
if [ -n "${RESULTS}" ] && [ -z "${EVIDENCE_DIR}" ]; then
    EVIDENCE_DIR=$(dirname "${RESULTS}")/evidence
fi
if [ -n "${EVIDENCE_DIR}" ]; then
    if mkdir -p "${EVIDENCE_DIR}" 2>/dev/null; then
        EVIDENCE="${EVIDENCE_DIR}/FH-${RELEASE}.log"
        # One log per release, replaced by each run: the probe is a fact about the mirror,
        # and two runs an hour apart are one answer, not two.
        : >"${EVIDENCE}" 2>/dev/null || EVIDENCE=""
    fi
fi

_emit "$(printf 'feed-history release=%s mirror=%s target=%s arch=%s' \
    "${RELEASE}" "${MIRROR}" "${TARGET}" "${ARCH}")"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ab-feed-history.XXXXXX" 2>/dev/null) || WORK_DIR=""
if [ -z "${WORK_DIR}" ]; then
    _finish GAP no-temp-dir
fi

if ! command -v "${FETCHER}" >/dev/null 2>&1; then
    # Not "the feed is down": without a fetcher nothing was asked, and a FAIL here would
    # blame a release for a workstation that has no curl.
    _finish GAP no-fetch-tool
fi

# shellcheck disable=SC2086  # FEEDS is a space separated list by construction
for _f in ${FEEDS}; do
    _probe_index "${_f}" "$(_feed_url "${_f}")"
done
_probe_index target "$(_target_url)"

if [ "${ANSWERED}" -eq 0 ]; then
    # Not one URL answered. That is a network fact, not a release fact: a machine with no
    # route would otherwise turn every hop of the rise chain red for the wrong reason.
    _finish GAP no-network
fi

if [ -n "${KMOD}" ]; then
    _emit "$(printf 'feed-history kmods-segment=%s source=--kmod' "${KMOD}")"
else
    _kmods_page "$(_kmods_dir_url)"
    case "${_kp_http}" in
        200 | 206)
            case "${_kp_found}" in
                1)
                    KMOD=${_kp_entries}
                    _emit "$(printf 'feed-history kmods-segment=%s source=listing' "${KMOD}")"
                    ;;
                0)
                    # A page that answered and lists nothing: an autoindex that is off, a
                    # proxy that ate the body. The directory may well be there; this probe
                    # cannot say which segment, and --kmod is how a caller who knows says.
                    KMOD_PROBLEM=kmods-listing-unreadable
                    _emit 'feed-history kmods-segment=unknown source=listing (the page names none)'
                    ;;
                *)
                    KMOD_PROBLEM=kmods-ambiguous
                    _emit "$(printf 'feed-history kmods-segment=unknown source=listing (the page names %s, so none is chosen)' \
                        "${_kp_found}")"
                    ;;
            esac
            ;;
        404)
            # The release publishes no kmods directory at all. That is the release being
            # incomplete, not this probe being unable to see it.
            KMOD_PROBLEM=kmods-dir-http-404
            KMOD_FATAL=1
            ;;
        *)
            if [ "${_kp_http}" = "000" ]; then
                KMOD_PROBLEM=kmods-dir-unreachable
            else
                KMOD_PROBLEM="kmods-dir-http-${_kp_http}"
            fi
            ;;
    esac
fi

if [ -n "${KMOD}" ]; then
    # The version half of the segment, which is the kernel the release runs. Read out of the
    # segment rather than parsed from a version string again.
    KERNEL=${KMOD%%-*}
    _probe_index kmods "$(_kmods_url)"
fi

if [ "${FEEDS_OK}" -ne "${FEEDS_TOTAL}" ]; then
    _finish FAIL "${REASON:-feed-incomplete}"
fi
if [ -n "${KMOD_PROBLEM}" ]; then
    if [ "${KMOD_FATAL}" -eq 1 ]; then
        _finish FAIL "${KMOD_PROBLEM}"
    fi
    _finish GAP "${KMOD_PROBLEM}"
fi
_finish PASS
