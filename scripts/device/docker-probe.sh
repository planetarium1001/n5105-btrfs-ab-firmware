#!/bin/sh
# docker-probe.sh - ac-9: a real docker payload has to survive the upgrade/downgrade hop.
#
# The PRD asks for one thing that no read-only probe can answer:
#
#   ac-9 真实 docker 负载跨跳留存：经国内镜像站真 pull >=2 镜像、容器写确定性产物、命名卷；
#   升/降级与重启后 `docker images --digests` 只增不减、容器/卷产物 sha256 相等、
#   `docker run --rm` 与 `docker info` rc=0、`docker=ok` 且 @docker 子卷身份不变。
#
# A machine can say `docker=ok` and still have lost every image, container and volume it
# had, because @docker is a btrfs subvolume and a new rootfs is a new overlay in front of
# it. The only way to know is to put real bytes there, jump, and look again. This script is
# that measurement, in three cases, each with its own verdict:
#
#   D1 baseline   (runs BEFORE the jump)
#       Really pulls >= 2 images through a mainland mirror (default
#       https://docker.m.daocloud.io, AB_DOCKER_MIRROR to override), starts one container
#       that writes a deterministic artifact, creates one named volume that writes a file,
#       commits the container to an image and reads the file back out of *that image* with
#       sha256, and records `docker images --digests`, `docker info` and the two subvolume
#       identities. D1 judges: every pull returned rc=0 with a digest; the bytes on the
#       machine equal the bytes this script declares (so a hidden timestamp is a failure,
#       not a surprise); the committed image carries the same file; the named volume still
#       carries its file; `docker info` and `docker run --rm` returned 0; docker=ok.
#       It leaves the snapshot in <snapshot-dir>/before.snapshot.
#
#   D2 jump       (runs AFTER the upgrade/downgrade phase)
#       Captures the same facts a second time (<snapshot-dir>/after.snapshot) and compares
#       it with D1's snapshot. D2 judges: the jump really happened (a witness is required,
#       see below), the image set only grew, the artifacts did not change one byte, and the
#       engine still answers `docker info` / `docker run --rm` with rc=0.
#
#   D3 identity   (runs AFTER the jump, next to D2)
#       `ab-slot status` says data=ok docker=ok swap=ok, and the identity of the two
#       subvolumes the docker store lives on (@docker under /opt/docker, @data) is
#       unchanged across the jump: `btrfs subvolume show` (id + uuid) and
#       `btrfs property get ... ro` must be identical before and after.
#
# "The image set only grows" is not the same statement as "the artifact sha256 is equal",
# and mixing them up is how an earlier round reported a healthy machine as broken:
#
#   images are CONTENT-ADDRESSED and only ADDITIVE. Pulling anything new appends blobs and
#   rows; the upgrade itself may even pull a base image for a package. So the rule is a
#   SUBSET rule: every (repo, tag, digest) D1 saw must still be there, and new rows are
#   allowed and expected. Requiring equality here would fail every run that pulls anything
#   between the two captures, which is exactly what a "docker still works" check does.
#
#   the container artifact, the volume file and the committed image are DATA this script
#   wrote itself with a fixed, timestamp-free content. Nothing in a healthy hop rewrites
#   them, so the rule is EQUALITY, byte for byte. A subset rule here would let the file
#   shrink, change, or vanish into a dangling layer and still pass.
#
# A whole block going missing and a single value changing are therefore reported with
# different `drift=` tokens - `missing-block`/`glued-header`/`empty-block` (structure) versus
# `content`/`subset-lost` (value) - so "nothing was compared" is never printed as "nothing
# changed". Before D2 compares anything it runs the comparator against samples it tampers
# with itself (the same routine `--selfcheck` exposes): a pristine pair must come out green,
# a tampered one red, and a verdict over an empty baseline must be red. A comparator that
# silently stopped matching would otherwise turn the rest of the run into a stream of PASSes.
#
#   scripts/device/docker-probe.sh                     # D1, D2, D3 in order
#   scripts/device/docker-probe.sh --case D1           # baseline only (before the jump)
#   scripts/device/docker-probe.sh --case D2 --case D3 # after the jump
#   scripts/device/docker-probe.sh --dry-run           # the plan, no ssh, no file written
#   scripts/device/docker-probe.sh --json              # one JSON object per line
#   scripts/device/docker-probe.sh --selfcheck         # is the comparator awake?
#   AB_DOCKER_INPUT=x.txt scripts/device/docker-probe.sh                # replay both captures
#
# Replay: AB_DOCKER_INPUT (or --input) names a recorded snapshot file. Its shape is exactly
# what this script writes to <snapshot-dir>/<label>.snapshot - one `## snapshot <label>`
# document per capture - and a file with two of them (before, after) replays a whole hop. A
# file with only one document replays one side: D1 then takes the `before` document and D2/D3
# write the `after` one back to disk, so a single-side replay ends in a GAP that says which
# half is missing instead of inventing it. In replay mode no packet leaves the host and the
# parser under test is the real one; that is how the judgement is tested without the machine.
#
# Network failures are GAP, never FAIL: a mirror that answers 404/429/503, a DNS failure or
# a timeout is not a defect of this product (PRD risk 3). Each such line carries the URL,
# the HTTP status when the daemon printed one, and the command that asks again; the pull is
# retried once before that, and the retry count is in the line.
#
# Output shape (one line per assertion, plus one row per case):
#
#   ok   [D2] assert_container_artifact rule=assert lines=3 unchanged=yes
#   FAIL [D2] subset_images drift=subset-lost rule=subset lost=1 kept=9: library/redis|7-alpine|sha256:...
#     next: ...
#   GAP  [D2] jump generation=6->6 slot=b->b upper=@overlay-25.12.2-r2->@overlay-25.12.2-r2
#     next: scripts/device/docker-probe.sh --case D2   # after the upgrade/downgrade phase
#   == D2 PASS before=.../before.snapshot after=.../after.snapshot
#
# Results rows (the shape full-test.sh concatenates into verdict.tsv):
#
#   case<TAB>verdict<TAB>evidence<TAB>note
#
# --json prints the same facts as one object per line, of two kinds:
#
#   {"case":"D2","check":"assert_volume","result":"ok","detail":"..."}     one assertion
#   {"case":"D2","verdict":"PASS","evidence":"...","note":"...",...}       one case row
#
# and a {"kind":"summary"} object last. The plan, under --dry-run --json, is a
# {"check":"plan"} object per remote script with the script in `script` (newlines escaped,
# so a caller can paste it back).
#
# Files this script writes on this host, and nothing else: <results> (default
# docker-probe-results.tsv) and <snapshot-dir>/{before,after}.snapshot. --dry-run writes
# neither and contacts nothing.
#
# What D1 writes on the machine, and nothing else: two images pulled through the mirror, one
# container (<container name>) that exits with its artifact, one committed image
# (acpt/docker-probe:baseline), one named volume (<volume name>), a throwaway container
# (dp-readback) created from the committed image and removed again, and logs under /tmp.
# D1 recreates its own container and volume on every run, so it is repeatable; it does not
# touch a slot, the ESP, dockerd's configuration or any other container. D2 and D3 only read
# (a `docker run --rm`, `docker cp`, `docker info`), which is why "docker" belongs in the
# acceptance run's non-destructive phase set.
#
# Exit status: 0 every selected case PASSed, 1 at least one FAIL, 3 nothing failed but at
# least one case had no verdict (GAP), 2 bad usage.
#
# What this script does not own: "the machine came back at all" (matrix.sh), "the container
# keeps running on the next boot" (scenarios.sh), and "the store did not grow without bound"
# (a human reading `docker system df` in the evidence block). A machine that does not answer
# ssh is a GAP here, not a FAIL, for the same reason a dead mirror is.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# full-test.sh points a phase's results channel at its per-phase TSV through AB_RESULTS.
# lib.sh fills AB_RESULTS with its own default when it is unset, so the caller's value has to
# be remembered BEFORE the library is sourced, or the orchestrator's file is silently
# ignored and this phase writes a second results file nobody concatenates.
AB_RESULTS_FROM_ENV=${AB_RESULTS:-}
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# --------------------------------------------------------------------------- #
# Tunables
# --------------------------------------------------------------------------- #

DRY_RUN=${AB_DRY_RUN:-0}
JSON=0
SELFCHECK=0
CASES=""
CASES_ALL="D1 D2 D3"

INPUT=${AB_DOCKER_INPUT:-}
# Precedence: --results, then this script's own AB_DOCKER_RESULTS, then the AB_RESULTS the
# orchestrator exported, then a file of its own. lib.sh's record() appends to AB_RESULTS.
RESULTS=${AB_DOCKER_RESULTS:-${AB_RESULTS_FROM_ENV:-docker-probe-results.tsv}}
SNAPSHOT_DIR=${AB_DOCKER_SNAPSHOT_DIR:-}

# The mirror is the point of the case: pulling from hub.docker.com on this network is what
# the acceptance run must not depend on. Overridable so a lab with its own registry can run
# the same case.
MIRROR=${AB_DOCKER_MIRROR:-https://docker.m.daocloud.io}
DOCKER=${AB_DOCKER_BIN:-/usr/bin/docker}

# Two images, two roles: the redis one is the workload (it is the one that is committed), the
# nginx one is a second, unrelated pull so ">=2 images" cannot be met by one manifest list.
IMAGES=${AB_DOCKER_IMAGES:-"library/redis:7-alpine library/nginx:alpine"}
MIN_IMAGES=${AB_DOCKER_MIN_IMAGES:-2}
WORKLOAD_IMAGE=${AB_DOCKER_WORKLOAD_IMAGE:-}
CONTAINER_NAME=${AB_DOCKER_CONTAINER:-acpt-docker-probe}
VOLUME_NAME=${AB_DOCKER_VOLUME:-acpt-docker-probe-vol}
COMMIT_IMAGE=${AB_DOCKER_COMMIT_IMAGE:-acpt/docker-probe:baseline}

# A comparison between two captures taken in the same boot proves nothing about a jump, so
# the witness is required by default. AB_DOCKER_REQUIRE_JUMP=0 is for a rerun that wants to
# ask "did the store change while nothing else did" and says so in its note.
REQUIRE_JUMP=${AB_DOCKER_REQUIRE_JUMP:-1}

# The artifacts. One line each, no timestamp anywhere: the content is declared here and the
# expected sha256 is computed from it, so a container that embeds `date` cannot pass. These
# are inputs rather than constants so a test can use its own bytes and still exercise the
# real grader.
MARKER_TEXT=${AB_DOCKER_MARKER_TEXT:-"docker-probe marker unit=dev-04 version=baseline"}
PAYLOAD_TEXT=${AB_DOCKER_PAYLOAD_TEXT:-"payload 0123456789abcdef deterministic"}
VOLUME_MARKER_TEXT=${AB_DOCKER_VOLUME_MARKER_TEXT:-"docker-probe volume uid=0"}
# A UTF-8 byte sequence on purpose: the archived device runs proved the pipeline is byte
# transparent, and a mangled encoding would change this sha256.
VOLUME_UTF8_TEXT=${AB_DOCKER_VOLUME_UTF8_TEXT:-"卷内容 UTF-8 baseline"}

MIRROR_HOST=$(printf '%s' "${MIRROR}" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##' | sed 's#/*$##')
[ -n "${MIRROR_HOST}" ] || MIRROR_HOST=${MIRROR}
if [ -z "${WORKLOAD_IMAGE}" ]; then
    _first_spec=${IMAGES%% *}
    WORKLOAD_IMAGE="${MIRROR_HOST}/${_first_spec}"
fi

# lib.sh's record() appends to AB_RESULTS; this is the only channel full-test.sh reads.
AB_RESULTS=${RESULTS}

usage() {
    cat <<'USAGE'
usage: docker-probe.sh [--case D1|D2|D3]... [--dry-run] [--json] [--selfcheck]
                       [--results FILE] [--snapshot-dir DIR] [--input FILE] [--mirror URL]

  --case <id>        run one case; repeatable (default: D1 D2 D3)
                       D1  baseline: pull >=2 images through the mirror, run one container,
                           one named volume, commit to an image, record everything
                       D2  after the jump: capture again and compare with D1's snapshot
                       D3  after the jump: ab-slot data/docker/swap=ok and @docker/@data
                           identity unchanged
  --dry-run          print the remote scripts and the rules, contact nothing, write nothing
  --json             one JSON object per line instead of the human report
  --selfcheck        feed the comparator known-good and known-bad samples; no device needed
  --results <file>   results TSV (default docker-probe-results.tsv)
  --snapshot-dir <d> where before.snapshot/after.snapshot live
                     (default <results dir>/docker-snapshots)
  --input <file>     replay a recorded snapshot file instead of contacting the machine
                     (same as AB_DOCKER_INPUT)
  --mirror <url>     image mirror (default https://docker.m.daocloud.io)

Environment: AB_HOST, AB_KEY, AB_DRY_RUN, AB_DOCKER_INPUT, AB_DOCKER_MIRROR,
             AB_DOCKER_IMAGES, AB_DOCKER_MIN_IMAGES, AB_DOCKER_BIN, AB_DOCKER_CONTAINER,
             AB_DOCKER_VOLUME, AB_DOCKER_COMMIT_IMAGE, AB_DOCKER_WORKLOAD_IMAGE,
             AB_DOCKER_RESULTS, AB_DOCKER_SNAPSHOT_DIR, AB_DOCKER_REQUIRE_JUMP,
             AB_DOCKER_MARKER_TEXT/PAYLOAD_TEXT/VOLUME_MARKER_TEXT/VOLUME_UTF8_TEXT,
             AB_EVIDENCE_LOG (lib.sh ev).

Exit status: 0 PASS, 1 FAIL, 3 no verdict (GAP), 2 bad usage.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            _want=$(printf '%s' "${2:?--case needs D1, D2 or D3}" | tr 'a-z' 'A-Z')
            case " ${CASES_ALL} " in
                *" ${_want} "*) CASES="${CASES} ${_want}" ;;
                *)
                    printf 'docker-probe.sh: unknown case: %s (want one of: %s)\n' "${2}" "${CASES_ALL}" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --json) JSON=1; shift ;;
        --selfcheck) SELFCHECK=1; shift ;;
        --input) INPUT=${2:?--input needs a file}; shift 2 ;;
        --mirror) MIRROR=${2:?--mirror needs a url}; shift 2 ;;
        --results) RESULTS=${2:?--results needs a file}; shift 2 ;;
        --snapshot-dir) SNAPSHOT_DIR=${2:?--snapshot-dir needs a dir}; shift 2 ;;
        -h | --help | help) usage; exit 0 ;;
        *)
            printf 'docker-probe.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Recompute what the flags changed.
MIRROR_HOST=$(printf '%s' "${MIRROR}" | sed 's#^[A-Za-z][A-Za-z0-9+.-]*://##' | sed 's#/*$##')
[ -n "${MIRROR_HOST}" ] || MIRROR_HOST=${MIRROR}
case " ${CASES} " in
    *" D1 "* | *" D2 "* | *" D3 "*) : ;;
    *) CASES=" ${CASES_ALL} " ;;
esac
CASES=$(printf '%s' "${CASES}" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
[ -n "${SNAPSHOT_DIR}" ] || SNAPSHOT_DIR="$(dirname "${RESULTS}")/docker-snapshots"
AB_RESULTS=${RESULTS}

# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

TMPD=""
CHECKS=0
FAILS=0
GAPS=0
CASE_CHECKS=0
CASE_FAILS=0
CASE_GAPS=0
QUIET=0
EVIDENCE=""

cleanup() {
    [ -n "${TMPD}" ] && rm -rf "${TMPD}"
    return 0
}
trap 'cleanup' EXIT INT TERM HUP

# _tmpd: the scratch directory. Created lazily so a dry run writes nothing at all.
_tmpd() {
    [ -n "${TMPD}" ] && return 0
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ab-docker-probe.XXXXXX" 2>/dev/null) || TMPD=""
    [ -n "${TMPD}" ] || {
        printf 'docker-probe.sh: no writable temporary directory (set TMPDIR)\n' >&2
        exit 2
    }
    return 0
}

# _json_str <text>: one string, safe inside a JSON object.
# Newlines are escaped rather than squashed: a dry-run plan is a whole remote script, and a
# caller that reads `script` has to be able to paste it back. One object stays on one line,
# so the `one JSON object per line` contract still holds.
_json_str() {
    printf '%s' "$1" | awk '
        BEGIN { out = "" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            out = out (NR > 1 ? "\\n" : "") $0
        }
        END { printf "%s", out }
    '
}

# _emit <case> <result> <check> <detail> [next command]
# One line per assertion. A FAIL or a GAP owes the reader the command that asks again, so
# every one of them carries it. The `drift=` token in a detail is the comparator's own
# classification and is what tells "a block vanished" from "a value changed".
_emit() {
    _em_case=$1
    _em_result=$2
    _em_check=$3
    _em_detail=$4
    _em_next=${5:-}
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    case "${_em_result}" in
        fail) FAILS=$((FAILS + 1)); CASE_FAILS=$((CASE_FAILS + 1)) ;;
        gap) GAPS=$((GAPS + 1)); CASE_GAPS=$((CASE_GAPS + 1)) ;;
    esac
    # QUIET is the comparator's self-check: it still counts, it just does not print. The
    # evidence log gets the line either way, because that is where a reader looks later.
    if [ "${JSON}" = "1" ]; then
        [ "${QUIET}" = "1" ] || printf '{"case":"%s","check":"%s","result":"%s","detail":"%s"}\n' \
            "$(_json_str "${_em_case}")" "$(_json_str "${_em_check}")" \
            "${_em_result}" "$(_json_str "${_em_detail}")"
    elif [ "${QUIET}" != "1" ]; then
        case "${_em_result}" in
            ok) printf 'ok   [%s] %s %s\n' "${_em_case}" "${_em_check}" "${_em_detail}" ;;
            fail) printf 'FAIL [%s] %s %s\n' "${_em_case}" "${_em_check}" "${_em_detail}" ;;
            gap) printf 'GAP  [%s] %s %s\n' "${_em_case}" "${_em_check}" "${_em_detail}" ;;
        esac
        [ -n "${_em_next}" ] && printf '  next: %s\n' "${_em_next}"
    fi
    ev "${_em_result} ${_em_case} ${_em_check}: ${_em_detail}${_em_next:+ | next: ${_em_next}}"
    return 0
}

_ok() { _emit "$1" ok "$2" "$3" ""; }
_fail() { _emit "$1" fail "$2" "$3" "${4:-}"; }
_gap() { _emit "$1" gap "$2" "$3" "${4:-}"; }

_case_begin() {
    CASE_CHECKS=0
    CASE_FAILS=0
    CASE_GAPS=0
}

_case_end() { # <case> <evidence> <note>
    _ce_case=$1
    _ce_ev=$2
    _ce_note=$3
    _ce_status=PASS
    [ "${CASE_GAPS}" -gt 0 ] && _ce_status=GAP
    # A FAIL outranks a GAP: a real defect next to an undecided question is still a defect.
    [ "${CASE_FAILS}" -gt 0 ] && _ce_status=FAIL
    # A plan is not a verdict: the last line says which one this run was.
    [ "${DRY_RUN}" = "1" ] && _ce_status=plan
    if [ "${JSON}" = "1" ]; then
        printf '{"case":"%s","verdict":"%s","evidence":"%s","note":"%s","checks":%s,"failures":%s,"gaps":%s}\n' \
            "$(_json_str "${_ce_case}")" "${_ce_status}" "$(_json_str "${_ce_ev}")" \
            "$(_json_str "${_ce_note}")" "${CASE_CHECKS}" "${CASE_FAILS}" "${CASE_GAPS}"
    else
        printf '== %s %s %s\n' "${_ce_case}" "${_ce_status}" "${_ce_note}"
    fi
    ev "case ${_ce_case} ${_ce_status} checks=${CASE_CHECKS} failures=${CASE_FAILS} gaps=${CASE_GAPS} note=${_ce_note}"
    # A dry run reached no verdict, so it writes no row: the results file is what the Lead
    # reads as evidence, and a PASS in it has to mean a run happened.
    if [ "${DRY_RUN}" != "1" ]; then
        record "${_ce_case}" "${_ce_status}" "${_ce_ev}" "${_ce_note}"
    fi
    if [ "${_ce_status}" = "FAIL" ]; then
        return 1
    fi
    return 0
}

# _dry_plan <case> <step> <script text>: the exact remote script, indented so a reader can
# see where it starts and ends. Under --json the same information becomes one object with the
# script embedded, because "--json prints only JSON objects" is a promise a caller's parser
# depends on.
_dry_plan() {
    if [ "${JSON}" = "1" ]; then
        printf '{"case":"%s","check":"plan","step":"%s","script":"%s"}\n' \
            "$(_json_str "$1")" "$(_json_str "$2")" "$(_json_str "$3")"
        return 0
    fi
    printf 'plan %s step=%s\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/    /'
}

# _dry_plan_capture <case>: the capture script is the same text for D1, D2 and D3, so it is
# printed once and referenced afterwards; three copies of 150 lines is a plan nobody reads.
PLANNED_CAPTURE=""
_dry_plan_capture() {
    if [ -n "${PLANNED_CAPTURE}" ]; then
        if [ "${JSON}" = "1" ]; then
            printf '{"case":"%s","check":"plan","step":"capture","same_as":"%s"}\n' \
                "$(_json_str "$1")" "${PLANNED_CAPTURE}"
            return 0
        fi
        printf 'plan %s step=capture (the same script as plan %s step=capture)\n' \
            "$1" "${PLANNED_CAPTURE}"
        return 0
    fi
    PLANNED_CAPTURE=$1
    _dry_plan "$1" capture "$(_remote_capture)"
}

_dry_note() {
    if [ "${JSON}" = "1" ]; then
        printf '{"check":"note","detail":"%s"}\n' "$(_json_str "$1")"
        return 0
    fi
    printf '  %s\n' "$1"
}

# --------------------------------------------------------------------------- #
# Local byte helpers
# --------------------------------------------------------------------------- #

_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" 2>/dev/null | sed 's/.*= *//'
    fi
}

_bytes_of_file() { wc -c <"$1" 2>/dev/null | tr -d ' '; }

# _expected_facts: what the deterministic content must hash to, measured here.
# The device is asked for the sha256 of the file it wrote; the comparison with this value is
# what makes "deterministic" a measurement instead of a promise.
_expected_facts() {
    _tmpd
    printf '%s\n' "${MARKER_TEXT}" >"${TMPD}/e-marker.txt"
    printf '%s\n' "${PAYLOAD_TEXT}" >"${TMPD}/e-payload.txt"
    printf '%s\n' "${VOLUME_MARKER_TEXT}" >"${TMPD}/e-vol-marker.txt"
    printf '%s\n' "${VOLUME_UTF8_TEXT}" >"${TMPD}/e-vol-utf8.txt"
    EXPECT_MARKER_SHA=$(_sha256_file "${TMPD}/e-marker.txt")
    EXPECT_MARKER_BYTES=$(_bytes_of_file "${TMPD}/e-marker.txt")
    EXPECT_PAYLOAD_SHA=$(_sha256_file "${TMPD}/e-payload.txt")
    EXPECT_PAYLOAD_BYTES=$(_bytes_of_file "${TMPD}/e-payload.txt")
    EXPECT_VOL_MARKER_SHA=$(_sha256_file "${TMPD}/e-vol-marker.txt")
    EXPECT_VOL_MARKER_BYTES=$(_bytes_of_file "${TMPD}/e-vol-marker.txt")
    EXPECT_VOL_UTF8_SHA=$(_sha256_file "${TMPD}/e-vol-utf8.txt")
    EXPECT_VOL_UTF8_BYTES=$(_bytes_of_file "${TMPD}/e-vol-utf8.txt")
}

# --------------------------------------------------------------------------- #
# Snapshot format
#
# One capture is a text document:
#
#   ## snapshot <label>
#   ## assert_<name>      lines that must be byte-identical between two captures
#   ## subset_<name>      lines of which every before-line must survive (growth is allowed)
#   ## info_<name>        reported, never judged (versions, timestamps, counts)
#
# The three prefixes are the whole contract; the comparator below only knows them. A block
# header standing alone on its own line matters: when a header is glued to the end of the
# previous line (a `tr` that forgot `\n`, a paste), an exact-match parser silently skips the
# block and a green verdict means nothing. That is checked, not assumed.
# --------------------------------------------------------------------------- #

# _snap_structure <file>: 0 clean, 1 a block header is not at the start of its line.
_snap_structure() {
    awk '
        /^## / { next }
        index($0, "## ") { printf "glued: %s\n", $0; bad = 1 }
        END { exit bad ? 1 : 0 }
    ' "$1" 2>/dev/null
}

# _snap_split <file> <outdir>: one file per `## snapshot <label>` document in outdir.
# Prints the labels in the order they appeared.
_snap_split() {
    rm -rf "$2"
    mkdir -p "$2" || return 1
    awk -v dir="$2" '
        /^## snapshot / {
            label = $3
            gsub(/[^A-Za-z0-9_.-]/, "_", label)
            if (label == "") label = "unlabelled"
            cur = dir "/" label
            print label >> (dir "/labels")
            next
        }
        cur != "" { print >> cur }
    ' "$1" || return 1
    [ -f "$2/labels" ] || return 1
    awk '!seen[$0]++' "$2/labels"
}

# _snap_section <file> <label>: the body of one labelled document.
# Returns 1 when the file carries no such label. A broken structure (a block header glued to
# the end of the previous line) is reported on stderr but NOT refused here: the section is
# still returned so the comparator can name the damage (`drift=glued-header`) instead of the
# case reporting "no baseline", which would look like a missing run.
_snap_section() {
    _ss_file=$1
    _ss_label=$2
    _tmpd
    _snap_structure "${_ss_file}" >"${TMPD}/structure.txt" 2>&1 || {
        printf 'docker-probe.sh: snapshot structure is broken (%s): %s\n' \
            "${_ss_file}" "$(head -n 1 "${TMPD}/structure.txt" 2>/dev/null)" >&2
    }
    _snap_split "${_ss_file}" "${TMPD}/split" >/dev/null 2>&1 || return 1
    [ -f "${TMPD}/split/${_ss_label}" ] || return 1
    cat "${TMPD}/split/${_ss_label}"
}

# _snap_blocks <section>: every block name, sorted, one per line.
_snap_blocks() {
    awk '/^## [^ ]/{ print $2 }' "$1" 2>/dev/null | LC_ALL=C sort -u
}

# _snap_judged <section>: the blocks a comparison has to decide on.
_snap_judged() {
    _snap_blocks "$1" | grep -E '^(assert|subset)_'
}

_snap_has_block() { _snap_blocks "$1" | grep -qx "$2"; }

# _snap_body <section> <block>: the block's lines, `volatile_` lines dropped.
_snap_body() {
    awk -v want="## $2" '
        $0 == want { inside = 1; next }
        inside && /^## / { inside = 0 }
        inside && /^volatile_/ { next }
        inside { print }
    ' "$1" 2>/dev/null
}

# _snap_value <section> <block> <key>: first `key=value` of a block, empty when absent.
_snap_value() {
    _snap_body "$1" "$2" | sed -n "s/^$3=//p" | head -n 1
}

# --------------------------------------------------------------------------- #
# The comparator
#
# It answers two questions per block and nothing else:
#   assert_ -> is the line set identical? (byte equality, both directions)
#   subset_ -> does every baseline line still exist? (growth allowed, loss is not)
# and one question per document: does the block still exist at all?
#
# A PASS line always carries the number of lines that were compared, and an empty baseline
# block is a FAIL - a comparator that cannot tell "0 lines" from "everything matched" turns
# a broken capture into a green run. CMP_FINDINGS is what the caller reads.
# --------------------------------------------------------------------------- #

CMP_FINDINGS=0

_cmp_finding() { # <case> <check> <drift> <detail> [next]
    CMP_FINDINGS=$((CMP_FINDINGS + 1))
    _fail "$1" "$2" "drift=$3 $4" "${5:-}"
}

_snap_compare() { # <case> <before-section> <after-section>
    _cmp_case=$1
    _cmp_before=$2
    _cmp_after=$3
    CMP_FINDINGS=0

    # 0) structure: a glued header makes every block below it unparseable.
    for _cmp_f in "${_cmp_before}" "${_cmp_after}"; do
        if ! _snap_structure "${_cmp_f}" >"${TMPD}/glue.txt" 2>&1; then
            _cmp_finding "${_cmp_case}" structure glued-header \
                "in $(basename "${_cmp_f}"): $(head -n 1 "${TMPD}/glue.txt" 2>/dev/null)" \
                "regenerate the snapshot: a '## <block>' header must stand on its own line"
        fi
    done
    [ "${CMP_FINDINGS}" -eq 0 ] || return 1

    for _cmp_b in $(_snap_judged "${_cmp_before}"); do
        case "${_cmp_b}" in
            assert_*) _cmp_rule=assert ;;
            *) _cmp_rule=subset ;;
        esac
        if ! _snap_has_block "${_cmp_after}" "${_cmp_b}"; then
            _cmp_finding "${_cmp_case}" "${_cmp_b}" missing-block \
                "rule=${_cmp_rule} the after capture has no '## ${_cmp_b}' block at all" \
                "cat <after snapshot>   # a vanished block is drift, not 'nothing changed'"
            continue
        fi
        _snap_body "${_cmp_before}" "${_cmp_b}" >"${TMPD}/cmp-a.txt"
        _snap_body "${_cmp_after}" "${_cmp_b}" >"${TMPD}/cmp-b.txt"
        _cmp_na=$(wc -l <"${TMPD}/cmp-a.txt" | tr -d ' ')
        _cmp_nb=$(wc -l <"${TMPD}/cmp-b.txt" | tr -d ' ')
        if [ "${_cmp_na}" -eq 0 ]; then
            _cmp_finding "${_cmp_case}" "${_cmp_b}" empty-block \
                "rule=${_cmp_rule} the baseline block is empty, so nothing was compared" \
                "scripts/device/docker-probe.sh --case D1   # regenerate the baseline"
            continue
        fi
        if [ "${_cmp_rule}" = "assert" ]; then
            if cmp -s "${TMPD}/cmp-a.txt" "${TMPD}/cmp-b.txt"; then
                _ok "${_cmp_case}" "${_cmp_b}" "rule=assert lines=${_cmp_na} unchanged=yes"
            else
                _cmp_finding "${_cmp_case}" "${_cmp_b}" content \
                    "rule=assert lines=${_cmp_na}->${_cmp_nb} changed: $(diff "${TMPD}/cmp-a.txt" "${TMPD}/cmp-b.txt" 2>/dev/null | sed -n '2,3p' | tr '\n' ';' | tr -s ' ')" \
                    "scripts/device/docker-probe.sh --case D2   # then read <after snapshot>"
            fi
            continue
        fi
        LC_ALL=C sort "${TMPD}/cmp-a.txt" >"${TMPD}/cmp-as.txt"
        LC_ALL=C sort "${TMPD}/cmp-b.txt" >"${TMPD}/cmp-bs.txt"
        comm -23 "${TMPD}/cmp-as.txt" "${TMPD}/cmp-bs.txt" >"${TMPD}/cmp-miss.txt" 2>/dev/null || :
        comm -13 "${TMPD}/cmp-as.txt" "${TMPD}/cmp-bs.txt" >"${TMPD}/cmp-add.txt" 2>/dev/null || :
        _cmp_miss=$(wc -l <"${TMPD}/cmp-miss.txt" | tr -d ' ')
        _cmp_add=$(wc -l <"${TMPD}/cmp-add.txt" | tr -d ' ')
        if [ "${_cmp_miss}" -eq 0 ]; then
            _ok "${_cmp_case}" "${_cmp_b}" "rule=subset kept=${_cmp_na} added=${_cmp_add} unchanged=yes"
        else
            _cmp_finding "${_cmp_case}" "${_cmp_b}" subset-lost \
                "rule=subset lost=${_cmp_miss} kept=${_cmp_na} added=${_cmp_add}: $(head -n 3 "${TMPD}/cmp-miss.txt" | tr '\n' ';' | tr -s ' ')" \
                "docker images --digests   # a digest the baseline saw is gone"
        fi
    done

    # A judged block that only the after capture has cannot be a silent pass either: the
    # baseline did not record it, so this comparison never covered it.
    for _cmp_b in $(_snap_judged "${_cmp_after}"); do
        _snap_has_block "${_cmp_before}" "${_cmp_b}" && continue
        _cmp_finding "${_cmp_case}" "${_cmp_b}" missing-in-baseline \
            "the after capture has '## ${_cmp_b}' but the baseline does not, so this block was never compared" \
            "scripts/device/docker-probe.sh --case D1   # the baseline predates this fact"
    done

    [ "${CMP_FINDINGS}" -eq 0 ]
}

# --------------------------------------------------------------------------- #
# The comparator's own test: tamper with a sample, the verdict must go red.
# Without this, a comparator that stopped matching anything (an empty baseline, a renamed
# block, a broken exact-match) would report PASS for the rest of the run and nobody would
# notice until the release was out.
# --------------------------------------------------------------------------- #

_sc_sample() { # <out> <label> <variant>
    _scs_out=$1
    _scs_label=$2
    _scs_variant=$3
    cat >"${_scs_out}" <<SAMPLE
## snapshot ${_scs_label}
## assert_engine
info_rc=0
run_rm_rc=0
## subset_images
example/one|1|sha256:aaaa|sha256:1111
example/two|2|sha256:bbbb|sha256:2222
## assert_container_artifact
state=ok
artifact=marker.txt sha256:cccc bytes=10
## end
SAMPLE
    case "${_scs_variant}" in
        "" ) : ;;
        add-image)
            # Growth is legal: a new (repo, tag, digest) row must stay green.
            awk -v add='example/three|3|sha256:e5e5|sha256:3333' '
                $0 ~ /^example\/two\|2\|/ { print; print add; next }
                { print }
            ' "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        drop-image)
            awk '!($0 ~ /^example\/one\|1\|/)' "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        artifact-sha)
            sed 's/^artifact=marker.txt sha256:cccc bytes=10$/artifact=marker.txt sha256:dead bytes=10/' \
                "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        drop-block)
            awk '
                /^## assert_container_artifact$/ { skip = 1; next }
                skip && /^## / { skip = 0 }
                !skip { print }
            ' "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        empty-block)
            awk '
                /^## assert_container_artifact$/ { print; skip = 1; next }
                skip && /^## / { skip = 0 }
                !skip { print }
            ' "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        glued-header)
            awk '
                $0 == "## subset_images" { print "junk,## subset_images" }
                { print }
            ' "${_scs_out}" >"${_scs_out}.n" && mv "${_scs_out}.n" "${_scs_out}"
            ;;
        extra-block)
            printf '## assert_only_in_one\nk=v\n' >>"${_scs_out}"
            ;;
    esac
    return 0
}

SELFCHECK_N=0

_sc_expect() { # <name> <green|red> <before> <after>
    _sce_name=$1
    _sce_want=$2
    _sce_before=$3
    _sce_after=$4
    # The selfcheck runs sample comparisons; their findings are not findings about this
    # machine, so every counter is saved and restored - including the per-case ones, which
    # an earlier version forgot and which turned a green case red from the inside.
    _sce_f=$FAILS
    _sce_g=$GAPS
    _sce_c=$CHECKS
    _sce_cf=$CASE_FAILS
    _sce_cg=$CASE_GAPS
    _sce_cc=$CASE_CHECKS
    _sce_quiet=$QUIET
    QUIET=1
    _snap_compare SC "${_sce_before}" "${_sce_after}" >/dev/null 2>&1
    _sce_got=green
    [ "${CMP_FINDINGS}" -gt 0 ] && _sce_got=red
    QUIET=${_sce_quiet}
    FAILS=${_sce_f}
    GAPS=${_sce_g}
    CHECKS=${_sce_c}
    CASE_FAILS=${_sce_cf}
    CASE_GAPS=${_sce_cg}
    CASE_CHECKS=${_sce_cc}
    SELFCHECK_N=$((SELFCHECK_N + 1))
    if [ "${_sce_got}" = "${_sce_want}" ]; then
        if [ "${JSON}" = "1" ]; then
            printf '{"kind":"selfcheck","name":"%s","want":"%s","got":"%s","result":"ok"}\n' \
                "$(_json_str "${_sce_name}")" "${_sce_want}" "${_sce_got}"
        else
            printf 'selfcheck %-16s want=%-5s got=%-5s result=ok\n' "${_sce_name}" "${_sce_want}" "${_sce_got}"
        fi
        return 0
    fi
    if [ "${JSON}" = "1" ]; then
        printf '{"kind":"selfcheck","name":"%s","want":"%s","got":"%s","result":"FAIL"}\n' \
            "$(_json_str "${_sce_name}")" "${_sce_want}" "${_sce_got}"
    else
        printf 'selfcheck %-16s want=%-5s got=%-5s result=FAIL (the comparator is not judging)\n' \
            "${_sce_name}" "${_sce_want}" "${_sce_got}"
    fi
    return 1
}

_selfcheck() {
    _tmpd
    SELFCHECK_N=0
    _sc_bad=0
    mkdir -p "${TMPD}/sc" || return 1

    _sc_sample "${TMPD}/sc/base.snap" before ""
    _sc_sample "${TMPD}/sc/same.snap" after ""

    # positives: a pristine pair and a pair that only grew
    _sc_expect unchanged green "${TMPD}/sc/base.snap" "${TMPD}/sc/same.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/add.snap" after add-image
    _sc_expect grew-image green "${TMPD}/sc/base.snap" "${TMPD}/sc/add.snap" || _sc_bad=1

    # negatives: each tampering must move the verdict, with the drift token that names it
    _sc_sample "${TMPD}/sc/drop-img.snap" after drop-image
    _sc_expect lost-image red "${TMPD}/sc/base.snap" "${TMPD}/sc/drop-img.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/sha.snap" after artifact-sha
    _sc_expect changed-bytes red "${TMPD}/sc/base.snap" "${TMPD}/sc/sha.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/noblock.snap" after drop-block
    _sc_expect missing-block red "${TMPD}/sc/base.snap" "${TMPD}/sc/noblock.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/glued.snap" after glued-header
    _sc_expect glued-header red "${TMPD}/sc/base.snap" "${TMPD}/sc/glued.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/emptybase.snap" before empty-block
    _sc_expect empty-baseline red "${TMPD}/sc/emptybase.snap" "${TMPD}/sc/same.snap" || _sc_bad=1
    _sc_sample "${TMPD}/sc/extra.snap" after extra-block
    _sc_expect uncompared-block red "${TMPD}/sc/base.snap" "${TMPD}/sc/extra.snap" || _sc_bad=1

    if [ "${_sc_bad}" -eq 0 ]; then
        if [ "${JSON}" = "1" ]; then
            printf '{"kind":"selfcheck","name":"summary","result":"PASS","cases":%s}\n' "${SELFCHECK_N}"
        else
            printf 'selfcheck result=PASS cases=%s\n' "${SELFCHECK_N}"
        fi
        return 0
    fi
    if [ "${JSON}" = "1" ]; then
        printf '{"kind":"selfcheck","name":"summary","result":"FAIL"}\n'
    else
        printf 'selfcheck result=FAIL (the comparator must go red on a tampered sample)\n'
    fi
    return 1
}

# --------------------------------------------------------------------------- #
# Remote scripts. One quoted heredoc each where nothing is expanded on this host; the two
# that carry this run's tunables are unquoted, and every `$` that must survive to the
# machine is escaped.
# --------------------------------------------------------------------------- #

_remote_workload() {
    cat <<REMOTE
D=${DOCKER}
M=${MIRROR_HOST}
C=${CONTAINER_NAME}
V=${VOLUME_NAME}
I=${COMMIT_IMAGE}
W=${WORKLOAD_IMAGE}
printf '## info_workload\n'
printf 'mirror=%s\n' "\$M"
printf 'workload_image=%s\n' "\$W"
printf 'container=%s\n' "\$C"
printf 'volume=%s\n' "\$V"
printf 'commit_image=%s\n' "\$I"
all_pulled=1
for spec in ${IMAGES}; do
    ref="\$M/\$spec"
    url="https://\$M/\$spec"
    log=/tmp/docker-probe-pull.log
    attempt=1
    rc=1
    while [ "\$attempt" -le 2 ]; do
        \$D pull "\$ref" >"\$log" 2>&1
        rc=\$?
        [ "\$rc" -eq 0 ] && break
        attempt=\$((attempt + 1))
    done
    http=none
    why=none
    if [ "\$rc" -ne 0 ]; then
        http=\$(grep -oE '[1-5][0-9][0-9] (Not Found|Unauthorized|Forbidden|Too Many Requests|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)' "\$log" 2>/dev/null | head -n 1 | awk '{print \$1}')
        [ -n "\$http" ] || http=\$(grep -oE '(status code|StatusCode): *[1-5][0-9][0-9]' "\$log" 2>/dev/null | head -n 1 | grep -oE '[1-5][0-9][0-9]')
        [ -n "\$http" ] || http=none
        case "\$http" in
            none)
                if grep -qiE 'no such host|server misbehaving|dns' "\$log" 2>/dev/null; then why=dns
                elif grep -qiE 'manifest unknown' "\$log" 2>/dev/null; then why=manifest
                elif grep -qiE 'i/o timeout|timeout' "\$log" 2>/dev/null; then why=timeout
                elif grep -qiE 'connection refused' "\$log" 2>/dev/null; then why=refused
                elif grep -qiE 'tls|x509' "\$log" 2>/dev/null; then why=tls
                else why=unknown
                fi
                ;;
            *) why=http ;;
        esac
    fi
    digest=\$(sed -n 's/^Digest:[[:space:]]*//p' "\$log" 2>/dev/null | head -n 1)
    [ -n "\$digest" ] || digest=none
    printf 'pull=%s rc=%s url=%s http=%s why=%s attempts=%s digest=%s\n' \\
        "\$spec" "\$rc" "\$url" "\$http" "\$why" "\$attempt" "\$digest"
    [ "\$rc" -eq 0 ] || all_pulled=0
done

if [ "\$all_pulled" -eq 1 ]; then
    \$D rm -f "\$C" >/dev/null 2>&1
    \$D run --name "\$C" --label acpt.case=ac-9 --label acpt.unit=dev-04 \\
        --label acpt.deterministic=1 --entrypoint sh "\$W" \\
        -c 'mkdir -p /artifact && printf "%s\n" "${MARKER_TEXT}" > /artifact/marker.txt && printf "%s\n" "${PAYLOAD_TEXT}" > /artifact/payload.txt' \\
        >/tmp/docker-probe-run.log 2>&1
    run_rc=\$?
    printf 'run_rc=%s\n' "\$run_rc"

    \$D volume rm "\$V" >/dev/null 2>&1
    \$D volume create "\$V" >/tmp/docker-probe-volume.log 2>&1
    volume_create_rc=\$?
    printf 'volume_create_rc=%s\n' "\$volume_create_rc"
    \$D run --rm -v "\$V:/v" --entrypoint sh "\$W" \\
        -c 'printf "%s\n" "${VOLUME_MARKER_TEXT}" > /v/volume-marker.txt && printf "%s\n" "${VOLUME_UTF8_TEXT}" > /v/volume-utf8.txt' \\
        >>/tmp/docker-probe-volume.log 2>&1
    volume_write_rc=\$?
    printf 'volume_write_rc=%s\n' "\$volume_write_rc"

    \$D commit --change 'LABEL acpt.case=ac-9' "\$C" "\$I" >/tmp/docker-probe-commit.log 2>&1
    commit_rc=\$?
    printf 'commit_rc=%s\n' "\$commit_rc"
else
    # The workload is what ac-9 asks for, and it needs images. Not attempting it keeps a
    # mirror outage from being reported as a broken container in the record.
    printf 'run_rc=skipped\nvolume_create_rc=skipped\nvolume_write_rc=skipped\ncommit_rc=skipped\n'
fi
REMOTE
}

_remote_capture() {
    cat <<REMOTE
D=${DOCKER}
C=${CONTAINER_NAME}
V=${VOLUME_NAME}
I=${COMMIT_IMAGE}
P=${AB_P4_MOUNT}
sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "\$1" 2>/dev/null | awk '{print \$1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "\$1" 2>/dev/null | awk '{print \$1}'
    else
        openssl dgst -sha256 "\$1" 2>/dev/null | sed 's/.*= *//'
    fi
}
bytes() { wc -c <"\$1" 2>/dev/null | tr -d ' '; }

printf '## info_capture\n'
printf 'captured_utc=%s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
printf 'mirror=%s\n' "${MIRROR}"
printf 'container=%s\n' "\$C"
printf 'volume=%s\n' "\$V"
printf 'commit_image=%s\n' "\$I"

printf '## info_device\n'
printf 'kernel=%s\n' "\$(uname -r 2>/dev/null)"
printf 'platform=%s\n' "\$(sed -n 's/^PLATFORM_VERSION=//p' /etc/platform-release 2>/dev/null | head -n 1)"
printf 'upstream=%s\n' "\$(sed -n 's/^UPSTREAM_VERSION=//p' /etc/platform-release 2>/dev/null | head -n 1)"

# The daemon's own report, as facts a reader can compare with the baseline. ServerVersion is
# deliberately info_, not assert_: an "apk upgrade" in the hop may legitimately move it.
printf '## info_docker_info\n'
printf 'server_version=%s\n' "\$(\$D info --format '{{.ServerVersion}}' 2>/dev/null)"
printf 'images_count=%s\n' "\$(\$D info --format '{{.Images}}' 2>/dev/null)"
printf 'containers_count=%s\n' "\$(\$D info --format '{{.Containers}}' 2>/dev/null)"
printf 'containers_running=%s\n' "\$(\$D info --format '{{.ContainersRunning}}' 2>/dev/null)"

printf '## assert_engine\n'
\$D info >/dev/null 2>&1
info_rc=\$?
run_rm_rc=127
if \$D image inspect "\$I" >/dev/null 2>&1; then
    \$D run --rm --entrypoint sh "\$I" -c 'true' >/dev/null 2>&1
    run_rm_rc=\$?
fi
printf 'info_rc=%s\n' "\$info_rc"
printf 'run_rm_rc=%s\n' "\$run_rm_rc"
printf 'driver=%s\n' "\$(\$D info --format '{{.Driver}}' 2>/dev/null)"
printf 'data_root=%s\n' "\$(\$D info --format '{{.DockerRootDir}}' 2>/dev/null)"

printf '## assert_slot\n'
line=\$(ab-slot status 2>/dev/null | sed -n '1p')
for f in data docker swap boot esp; do
    printf '%s=%s\n' "\$f" "\$(printf '%s\n' "\$line" | tr ' ' '\n' | sed -n "s/^\$f=//p" | head -n 1)"
done

printf '## subset_images\n'
\$D images --digests --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.Digest}}|{{.ID}}' 2>/dev/null | LC_ALL=C sort

printf '## assert_container_artifact\n'
ast=ok
if \$D container inspect "\$C" >/dev/null 2>&1; then
    rm -rf /tmp/docker-probe-cp
    \$D cp "\$C:/artifact" /tmp/docker-probe-cp/ >/dev/null 2>&1
    if [ -d /tmp/docker-probe-cp/artifact ]; then
        for f in /tmp/docker-probe-cp/artifact/*; do
            [ -f "\$f" ] || continue
            printf 'artifact=%s sha256=%s bytes=%s\n' "\$(basename "\$f")" "\$(sha "\$f")" "\$(bytes "\$f")"
        done
    else
        ast=cp-failed
    fi
    rm -rf /tmp/docker-probe-cp
else
    ast=container-missing
fi
printf 'state=%s\n' "\$ast"

# Read the files back OUT OF THE COMMITTED IMAGE. A throwaway container is created from the
# image (never started), the artifact is copied out, and the machine's own sha256sum hashes
# it: that is the claim "the image layer carries these bytes", measured.
printf '## assert_commit_artifact\n'
cst=ok
if \$D image inspect "\$I" >/dev/null 2>&1; then
    \$D container rm dp-readback >/dev/null 2>&1
    if \$D create --name dp-readback "\$I" >/dev/null 2>&1; then
        rm -rf /tmp/docker-probe-img
        \$D cp dp-readback:/artifact /tmp/docker-probe-img/ >/dev/null 2>&1
        if [ -d /tmp/docker-probe-img/artifact ]; then
            for f in /tmp/docker-probe-img/artifact/*; do
                [ -f "\$f" ] || continue
                printf 'artifact=%s sha256=%s bytes=%s\n' "\$(basename "\$f")" "\$(sha "\$f")" "\$(bytes "\$f")"
            done
        else
            cst=cp-failed
        fi
        rm -rf /tmp/docker-probe-img
        \$D container rm -f dp-readback >/dev/null 2>&1
    else
        cst=create-failed
    fi
else
    cst=image-missing
fi
printf 'state=%s\n' "\$cst"

printf '## assert_volume\n'
vst=ok
mp=\$(\$D volume inspect "\$V" --format '{{.Mountpoint}}' 2>/dev/null)
if [ -z "\$mp" ] || [ ! -d "\$mp" ]; then
    vst=volume-missing
else
    for f in "\$mp/volume-marker.txt" "\$mp/volume-utf8.txt"; do
        if [ -f "\$f" ]; then
            printf 'artifact=%s sha256=%s bytes=%s\n' "\$(basename "\$f")" "\$(sha "\$f")" "\$(bytes "\$f")"
        else
            vst=file-missing
        fi
    done
fi
printf 'state=%s\n' "\$vst"

# The two subvolumes the store lives on. The Subvolume ID is assigned when the subvolume is
# created and the UUID never changes for its lifetime, so either one moving means the hop
# recreated the store instead of reusing it.
printf '## assert_subvol_identity\n'
for sv in @docker @data; do
    o=\$(btrfs subvolume show "\$P/\$sv" 2>/dev/null)
    id=\$(printf '%s\n' "\$o" | sed -n 's/^[[:space:]]*Subvolume ID:[[:space:]]*//p' | head -n 1)
    uuid=\$(printf '%s\n' "\$o" | sed -n 's/^[[:space:]]*UUID:[[:space:]]*//p' | head -n 1)
    printf 'subvol=%s id=%s uuid=%s\n' "\$sv" "\${id:-none}" "\${uuid:-none}"
done

printf '## assert_subvol_property\n'
for sv in @docker @data; do
    ro=\$(btrfs property get -ts "\$P/\$sv" ro 2>/dev/null | sed -n 's/^ro=//p' | head -n 1)
    [ -n "\$ro" ] || ro=\$(btrfs property get "\$P/\$sv" ro 2>/dev/null | sed -n 's/^ro=//p' | head -n 1)
    printf 'subvol=%s ro=%s\n' "\$sv" "\${ro:-unknown}"
done

printf '## info_status_line\n'
printf 'line=%s\n' "\$line"

printf '## info_images\n'
\$D images --digests --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.Digest}}|{{.ID}}|{{.Size}}' 2>/dev/null | LC_ALL=C sort

printf '## info_volumes\n'
\$D volume ls --format '{{.Name}}' 2>/dev/null | LC_ALL=C sort

printf '## info_containers\n'
\$D ps -a --format '{{.Names}}|{{.Image}}|{{.State}}' 2>/dev/null | LC_ALL=C sort
REMOTE
}

# --------------------------------------------------------------------------- #
# Grading the docker payload itself (D1 on the baseline, D2 on the fresh capture)
# --------------------------------------------------------------------------- #

# _grade_artifact <case> <section> <block> <file> <expected-sha> <expected-bytes> [next]
_grade_artifact() {
    _ga_case=$1
    _ga_sec=$2
    _ga_block=$3
    _ga_file=$4
    _ga_sha=$5
    _ga_bytes=$6
    _ga_next=${7:-"scripts/device/docker-probe.sh --case D1"}
    _ga_state=$(_snap_value "${_ga_sec}" "${_ga_block}" state)
    case "${_ga_state}" in
        ok) : ;;
        "")
            _fail "${_ga_case}" "${_ga_block}" \
                "the block is empty or missing, so ${_ga_file} was never read and nothing was compared" \
                "${_ga_next}"
            return 1
            ;;
        *)
            _fail "${_ga_case}" "${_ga_block}" \
                "state=${_ga_state}, so ${_ga_file} was not read (docker cp / volume / image failed)" \
                "${_ga_next}"
            return 1
            ;;
    esac
    _ga_line=$(_snap_body "${_ga_sec}" "${_ga_block}" | grep "^artifact=${_ga_file} " | head -n 1)
    if [ -z "${_ga_line}" ]; then
        _fail "${_ga_case}" "${_ga_block}" \
            "no artifact=${_ga_file} line; the block carries: $(  _snap_body "${_ga_sec}" "${_ga_block}" | tr '\n' ';' | tr -s ' ')" \
            "${_ga_next}"
        return 1
    fi
    _ga_got_sha=$(printf '%s\n' "${_ga_line}" | sed -n 's/.* sha256=\([^ ]*\).*/\1/p')
    _ga_got_bytes=$(printf '%s\n' "${_ga_line}" | sed -n 's/.* bytes=\([0-9]*\).*/\1/p')
    _ga_bad=0
    if [ "${_ga_got_sha}" != "${_ga_sha}" ]; then
        _fail "${_ga_case}" "${_ga_block}" \
            "${_ga_file} sha256=${_ga_got_sha:-none} but the declared content hashes to ${_ga_sha} (a timestamp or a rewrite)" \
            "${_ga_next}"
        _ga_bad=1
    fi
    if [ "${_ga_got_bytes}" != "${_ga_bytes}" ]; then
        _fail "${_ga_case}" "${_ga_block}" \
            "${_ga_file} bytes=${_ga_got_bytes:-none} but the declared content is ${_ga_bytes} bytes" \
            "${_ga_next}"
        _ga_bad=1
    fi
    [ "${_ga_bad}" -eq 0 ] || return 1
    _ok "${_ga_case}" "${_ga_block}" "${_ga_file} sha256=${_ga_got_sha} bytes=${_ga_got_bytes} matches-declared-content=yes"
    return 0
}

# _grade_payload <case> <section>: the docker facts ac-9 names, judged on one capture.
_grade_payload() {
    _gp_case=$1
    _gp_sec=$2
    _gp_bad=0

    _gp_info_rc=$(_snap_value "${_gp_sec}" assert_engine info_rc)
    _gp_run_rc=$(_snap_value "${_gp_sec}" assert_engine run_rm_rc)
    if [ "${_gp_info_rc}" = "0" ]; then
        _ok "${_gp_case}" engine "docker info rc=0"
    else
        _fail "${_gp_case}" engine "docker info rc=${_gp_info_rc:-none} (ac-9 wants rc=0)" \
            "docker info   # then logread | grep -i dockerd"
        _gp_bad=1
    fi
    if [ "${_gp_run_rc}" = "0" ]; then
        _ok "${_gp_case}" engine "docker run --rm ${COMMIT_IMAGE} rc=0"
    else
        _fail "${_gp_case}" engine "docker run --rm rc=${_gp_run_rc:-none} (127 means the image is gone)" \
            "docker images | grep -F '${COMMIT_IMAGE}'"
        _gp_bad=1
    fi

    _gp_driver=$(_snap_value "${_gp_sec}" assert_engine driver)
    _gp_root=$(_snap_value "${_gp_sec}" assert_engine data_root)
    if [ -n "${_gp_driver}" ] && [ -n "${_gp_root}" ]; then
        _ok "${_gp_case}" engine "driver=${_gp_driver} data_root=${_gp_root}"
    else
        _fail "${_gp_case}" engine "docker info printed no driver/data_root, so the store cannot be named" \
            "docker info --format '{{.Driver}} {{.DockerRootDir}}'"
        _gp_bad=1
    fi

    # docker=ok is D3's headline, but the artifact below lives in @docker: without the
    # mount there is nothing to preserve, so the baseline checks it too.
    _gp_docker=$(_snap_value "${_gp_sec}" assert_slot docker)
    if [ "${_gp_docker}" = "ok" ]; then
        _ok "${_gp_case}" slot "docker=ok"
    else
        _fail "${_gp_case}" slot "docker=${_gp_docker:-missing} (ac-9 wants docker=ok)" \
            "ab-slot status; mount | grep ' /opt/docker '"
        _gp_bad=1
    fi

    # every image ac-9 asks for, keyed by the digest the mirror published
    _gp_img_lines=$(_snap_body "${_gp_sec}" subset_images | grep -c '|sha256:' || true)
    if [ "${_gp_img_lines}" -eq 0 ]; then
        _fail "${_gp_case}" images "subset_images carries no repo|tag|digest line, so no image could be judged" \
            "docker images --digests --no-trunc"
        _gp_bad=1
    else
        _ok "${_gp_case}" images "${_gp_img_lines} image(s) with a digest on the machine"
    fi
    # A name is matched with or without the mirror prefix, because `docker pull
    # <mirror>/<repo>:<tag>` stores it under the prefixed name while a machine that had the
    # image from before the mirror existed keeps the bare one. Both are the same image.
    for _gp_spec in ${IMAGES} "${COMMIT_IMAGE}"; do
        case "${_gp_spec}" in
            *:*) _gp_repo=${_gp_spec%:*} ; _gp_tag=${_gp_spec##*:} ;;
            *) _gp_repo=${_gp_spec} ; _gp_tag=latest ;;
        esac
        # Literal, not a pattern: the `|` separators in a `docker images` row are the field
        # divider, and grep -E would read them as alternation and match a row that only has
        # the tag in it. awk's index() is the literal test this needs.
        if _snap_body "${_gp_sec}" subset_images |
            awk -v want="/${_gp_repo}|${_gp_tag}|sha256:" -v bare="${_gp_repo}|${_gp_tag}|sha256:" \
                'index($0, want) > 0 || index($0, bare) == 1 { hit = 1 } END { exit hit ? 0 : 1 }'; then
            _ok "${_gp_case}" images "${_gp_repo}:${_gp_tag} present with a digest"
        else
            _fail "${_gp_case}" images "${_gp_repo}:${_gp_tag} is not in docker images --digests" \
                "docker images --digests | grep -F '${_gp_repo}'"
            _gp_bad=1
        fi
    done

    # The workload's own exit codes. "skipped" is what D1 writes when the mirror did not
    # serve the images: not judged here, so a mirror outage cannot look like a broken run.
    _gp_wl=""
    for _gp_k in run_rc volume_create_rc volume_write_rc commit_rc; do
        _gp_v=$(_snap_value "${_gp_sec}" info_workload "${_gp_k}")
        case "${_gp_v}" in
            "")
                _gp_wl="${_gp_wl} ${_gp_k}=absent"
                ;;
            *[!0-9]*)
                _gp_wl="${_gp_wl} ${_gp_k}=${_gp_v}"
                ;;
            0)
                _gp_wl="${_gp_wl} ${_gp_k}=0"
                ;;
            *)
                _fail "${_gp_case}" workload "${_gp_k}=${_gp_v} (the container, the volume or the commit failed)" \
                    "docker ps -a; docker volume ls; docker images | grep -F '${COMMIT_IMAGE}'"
                _gp_bad=1
                ;;
        esac
    done
    if [ "${_gp_bad}" -eq 0 ]; then
        _ok "${_gp_case}" workload "run/volume/commit exit codes:${_gp_wl}"
    fi

    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_container_artifact marker.txt \
        "${EXPECT_MARKER_SHA}" "${EXPECT_MARKER_BYTES}" "docker inspect ${CONTAINER_NAME}; docker cp ${CONTAINER_NAME}:/artifact /tmp/x" || _gp_bad=1
    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_container_artifact payload.txt \
        "${EXPECT_PAYLOAD_SHA}" "${EXPECT_PAYLOAD_BYTES}" "docker cp ${CONTAINER_NAME}:/artifact /tmp/x" || _gp_bad=1
    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_commit_artifact marker.txt \
        "${EXPECT_MARKER_SHA}" "${EXPECT_MARKER_BYTES}" "docker run --rm --entrypoint sh ${COMMIT_IMAGE} -c 'ls -l /artifact; cat /artifact/marker.txt'" || _gp_bad=1
    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_commit_artifact payload.txt \
        "${EXPECT_PAYLOAD_SHA}" "${EXPECT_PAYLOAD_BYTES}" "docker run --rm --entrypoint sh ${COMMIT_IMAGE} -c 'cat /artifact/payload.txt'" || _gp_bad=1
    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_volume volume-marker.txt \
        "${EXPECT_VOL_MARKER_SHA}" "${EXPECT_VOL_MARKER_BYTES}" "docker volume inspect ${VOLUME_NAME}" || _gp_bad=1
    _grade_artifact "${_gp_case}" "${_gp_sec}" assert_volume volume-utf8.txt \
        "${EXPECT_VOL_UTF8_SHA}" "${EXPECT_VOL_UTF8_BYTES}" "docker volume inspect ${VOLUME_NAME}" || _gp_bad=1

    [ "${_gp_bad}" -eq 0 ]
}

# _grade_pulls <case> <section>: did the mirror serve the images? A failure here is a GAP
# with the URL, the status and the retry, never a FAIL.
_grade_pulls() {
    _gpl_case=$1
    _gpl_sec=$2
    _gpl_n=0
    _gpl_ok=0
    _gpl_gap=0
    for _gpl_spec in ${IMAGES}; do
        _gpl_n=$((_gpl_n + 1))
        _gpl_line=$(_snap_body "${_gpl_sec}" info_workload | grep -F "pull=${_gpl_spec} " | head -n 1)
        if [ -z "${_gpl_line}" ]; then
            # No attempt was recorded at all, so the pull question was never asked: GAP, not
            # FAIL. Without images there is no workload either, which the caller reports.
            _gap "${_gpl_case}" pull \
                "no pull line for ${_gpl_spec}: the workload never ran (or the capture lost it)" \
                "scripts/device/docker-probe.sh --case D1"
            _gpl_gap=$((_gpl_gap + 1))
            continue
        fi
        _gpl_rc=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* rc=\([^ ]*\).*/\1/p')
        _gpl_url=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* url=\([^ ]*\).*/\1/p')
        _gpl_http=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* http=\([^ ]*\).*/\1/p')
        _gpl_why=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* why=\([^ ]*\).*/\1/p')
        _gpl_attempts=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* attempts=\([^ ]*\).*/\1/p')
        _gpl_digest=$(printf '%s\n' "${_gpl_line}" | sed -n 's/.* digest=\([^ ]*\).*/\1/p')
        if [ "${_gpl_rc}" = "0" ] && [ "${_gpl_digest}" != "none" ] && [ -n "${_gpl_digest}" ]; then
            _ok "${_gpl_case}" pull "${_gpl_spec} rc=0 attempts=${_gpl_attempts:-?} digest=${_gpl_digest}"
            _gpl_ok=$((_gpl_ok + 1))
        else
            _gap "${_gpl_case}" pull \
                "${_gpl_spec} rc=${_gpl_rc:-none} url=${_gpl_url:-none} http=${_gpl_http:-none} why=${_gpl_why:-none} attempts=${_gpl_attempts:-?} digest=${_gpl_digest:-none}" \
                "docker pull ${MIRROR_HOST}/${_gpl_spec}   # then scripts/device/docker-probe.sh --case D1"
            _gpl_gap=$((_gpl_gap + 1))
        fi
    done
    if [ "${_gpl_n}" -lt "${MIN_IMAGES}" ]; then
        _gap "${_gpl_case}" pull-count \
            "only ${_gpl_n} image(s) configured, ac-9 wants >= ${MIN_IMAGES} through ${MIRROR}" \
            "scripts/device/docker-probe.sh --case D1 --mirror ${MIRROR}   # or set AB_DOCKER_IMAGES"
    elif [ "${_gpl_gap}" -eq 0 ] && [ "${_gpl_ok}" -ge "${MIN_IMAGES}" ]; then
        _ok "${_gpl_case}" pull-count "pulled=${_gpl_ok} of ${_gpl_n} through ${MIRROR} (ac-9 wants >= ${MIN_IMAGES})"
    fi
    [ "${_gpl_gap}" -eq 0 ]
}

# _baseline_has_workload <section>: did the baseline get as far as writing the artifacts?
# A baseline taken while the mirror was down never pulled, so it never wrote a container, a
# committed image or a volume. Comparing against it would report every artifact as lost -
# a mirror outage dressed up as a regression - so D2 refuses to compare at all and says so.
#
# What this deliberately does NOT check is whether each artifact block has the right bytes
# or any lines at all: that is the comparator's job, and it names the damage precisely
# (`empty-block`, `missing-block`, `content`). Two different faults deserve two different
# lines, and the coarse test here would swallow the precise one.
_baseline_has_workload() {
    _bw_sec=$1
    for _bw_spec in ${IMAGES}; do
        _snap_body "${_bw_sec}" info_workload | grep -F "pull=${_bw_spec} " | grep -q ' rc=0 ' || return 1
    done
    for _bw_k in run_rc volume_create_rc volume_write_rc commit_rc; do
        [ "$(_snap_value "${_bw_sec}" info_workload "${_bw_k}")" = "0" ] || return 1
    done
    return 0
}

# _jump_witness <before> <after>: prints what moved, returns 0 when something did.
# generation advances when a payload is laid down, so a round trip that lands back on the
# same slot still shows up here; slot/upper cover the single-hop case.
_jump_witness() {
    _jw_b=$(_snap_value "$1" info_status_line line)
    _jw_a=$(_snap_value "$2" info_status_line line)
    _jw_bg=$(status_field "${_jw_b}" generation 2>/dev/null) || _jw_bg=""
    _jw_ag=$(status_field "${_jw_a}" generation 2>/dev/null) || _jw_ag=""
    _jw_bs=$(status_field "${_jw_b}" slot 2>/dev/null) || _jw_bs=""
    _jw_as=$(status_field "${_jw_a}" slot 2>/dev/null) || _jw_as=""
    _jw_bu=$(status_field "${_jw_b}" upper 2>/dev/null) || _jw_bu=""
    _jw_au=$(status_field "${_jw_a}" upper 2>/dev/null) || _jw_au=""
    _jw_moved=0
    case "${_jw_bg}:${_jw_ag}" in
        *[!0-9:]* | :*) : ;;
        *)
            [ "${_jw_ag}" -gt "${_jw_bg}" ] && _jw_moved=1
            ;;
    esac
    [ "${_jw_bs}" != "${_jw_as}" ] && _jw_moved=1
    [ "${_jw_bu}" != "${_jw_au}" ] && _jw_moved=1
    printf 'generation=%s->%s slot=%s->%s upper=%s->%s' \
        "${_jw_bg:-none}" "${_jw_ag:-none}" "${_jw_bs:-none}" "${_jw_as:-none}" "${_jw_bu:-none}" "${_jw_au:-none}"
    [ "${_jw_moved}" -eq 1 ]
}

# --------------------------------------------------------------------------- #
# Capture plumbing
# --------------------------------------------------------------------------- #

REACH=unknown
AFTER_SECTION=""

_preflight() {
    [ "${DRY_RUN}" = "1" ] && return 0
    if dev_ssh true >/dev/null 2>&1; then
        REACH=ok
        return 0
    fi
    REACH=unreachable
    return 1
}

# _load_label <label>: the body of one labelled snapshot, from the replay file when there is
# one, otherwise from the snapshot this run wrote. Returns 1 when there is none.
_load_label() {
    _ll_label=$1
    if [ -n "${INPUT}" ]; then
        _snap_section "${INPUT}" "${_ll_label}"
        return $?
    fi
    [ -f "${SNAPSHOT_DIR}/${_ll_label}.snapshot" ] || return 1
    _snap_section "${SNAPSHOT_DIR}/${_ll_label}.snapshot" "${_ll_label}"
}

# _store_snapshot <label> <body-file>: write <snapshot-dir>/<label>.snapshot and print the
# whole document. The file is the evidence, and it is by itself a valid replay input: one
# `## snapshot <label>` header followed by the blocks the capture printed.
_store_snapshot() {
    _sn_label=$1
    _sn_body=$2
    [ -s "${_sn_body}" ] || return 1
    mkdir -p "${SNAPSHOT_DIR}" 2>/dev/null || return 1
    {
        printf '## snapshot %s\n' "${_sn_label}"
        cat "${_sn_body}"
    } >"${SNAPSHOT_DIR}/${_sn_label}.snapshot" || return 1
    cat "${SNAPSHOT_DIR}/${_sn_label}.snapshot"
}

# _capture_live <label> [<prefix-file>]: capture the machine, store it, print the document.
# The prefix file carries a section already collected by another remote call (the D1
# workload facts), so the baseline is one document and not two that can drift apart.
_capture_live() {
    _cl_label=$1
    _cl_prefix=${2:-}
    _cl_body=$(dev_ssh "$(_remote_capture)" 2>/dev/null) || _cl_body=""
    if ! printf '%s\n' "${_cl_body}" | grep -q '^## '; then
        return 1
    fi
    {
        [ -n "${_cl_prefix}" ] && [ -s "${_cl_prefix}" ] && cat "${_cl_prefix}"
        printf '%s\n' "${_cl_body}"
    } >"${TMPD}/${_cl_label}.body" || return 1
    _store_snapshot "${_cl_label}" "${TMPD}/${_cl_label}.body"
}

# _capture_after: one capture for D2 and D3, so both cases judge the same boot.
_capture_after() {
    if [ -n "${AFTER_SECTION}" ] && [ -f "${AFTER_SECTION}" ]; then
        cat "${AFTER_SECTION}"
        return 0
    fi
    _tmpd
    if [ -n "${INPUT}" ]; then
        _snap_section "${INPUT}" after >"${TMPD}/after.raw" || return 1
        _store_snapshot after "${TMPD}/after.raw" >/dev/null || return 1
    else
        _capture_live after >/dev/null || return 1
    fi
    [ -s "${SNAPSHOT_DIR}/after.snapshot" ] || return 1
    # the section, not the document: the comparator takes block sections
    _snap_section "${SNAPSHOT_DIR}/after.snapshot" after >"${TMPD}/after.keep" || return 1
    AFTER_SECTION="${TMPD}/after.keep"
    cat "${AFTER_SECTION}"
}

_no_device() { # <case> <reason>
    _gap "$1" device "the machine did not answer ssh (reason=$2)" \
        "ssh -i ${AB_KEY} ${AB_HOST} true   # then scripts/device/docker-probe.sh --case $1"
}

# --------------------------------------------------------------------------- #
# D1 - the baseline, taken before the jump
# --------------------------------------------------------------------------- #

run_d1() {
    _case_begin
    EVIDENCE="${SNAPSHOT_DIR}/before.snapshot"
    if [ "${DRY_RUN}" = "1" ]; then
        _dry_plan D1 pull "$(_remote_workload)"
        _dry_plan_capture D1
        _dry_note "assert: >=${MIN_IMAGES} pulls rc=0 with a digest from https://${MIRROR_HOST}; the container, the"
        _dry_note "        committed image and the named volume must hash to this run's declared content;"
        _dry_note "        docker info rc=0 and docker run --rm rc=0; docker=ok. Writes ${EVIDENCE}"
        _case_end D1 "${EVIDENCE}" "dry-run"
        return 0
    fi

    _expected_facts
    _tmpd
    # The baseline is always a file on disk, whichever way it arrived: a replay input or a
    # live capture is normalised into <snapshot-dir>/before.snapshot and read back from
    # there, so D2 and D3 compare against exactly the bytes a reader can open.
    if [ -n "${INPUT}" ]; then
        if ! _snap_section "${INPUT}" before >"${TMPD}/before.raw" 2>/dev/null; then
            _gap D1 baseline "the replay input ${INPUT} carries no '## snapshot before' document" \
                "scripts/device/docker-probe.sh --case D1 --input <file>   # one document per capture"
            _case_end D1 "${INPUT}" "replay=no-before-document"
            return 1
        fi
        _store_snapshot before "${TMPD}/before.raw" >/dev/null || {
            _fail D1 baseline "cannot write ${EVIDENCE}" "TMPDIR=/tmp scripts/device/docker-probe.sh --case D1"
            _case_end D1 "${EVIDENCE}" "snapshot-unwritable"
            return 1
        }
    else
        _preflight || {
            _no_device D1 "${REACH}"
            _case_end D1 "-" "unreachable"
            return 1
        }
        _wl=$(dev_ssh "$(_remote_workload)" 2>/dev/null) || _wl=""
        printf '%s\n' "${_wl}" >"${TMPD}/workload.raw"
        # The workload prints its own `## info_workload` block. No block means the remote
        # shell never got to the pushes (or the output was mangled), and grading an empty
        # block would report "the mirror served nothing" for a reason that is not the mirror.
        if ! grep -q '^## info_workload' "${TMPD}/workload.raw" 2>/dev/null; then
            _gap D1 baseline "the workload step printed no ## info_workload block, so no pull was recorded" \
                "ssh -i ${AB_KEY} ${AB_HOST} 'docker info; docker images --digests'"
            _case_end D1 "${EVIDENCE}" "workload-unreadable"
            return 1
        fi
        # The workload block is carried over WITH its header: the stored baseline is one
        # document whose blocks the grader reads by name, and a headerless section would
        # make the pull facts unreadable to the very reader that asks for them.
        awk '/^## info_workload$/{f=1} f && /^## / && !/^## info_workload$/{exit} f{print}' \
            "${TMPD}/workload.raw" >"${TMPD}/workload.sec"
        _capture_live before "${TMPD}/workload.sec" >/dev/null || {
            _gap D1 baseline "the capture came back empty (no '## ' block), so nothing was recorded" \
                "ssh -i ${AB_KEY} ${AB_HOST} ab-slot status; docker info"
            _case_end D1 "${EVIDENCE}" "capture-empty"
            return 1
        }
    fi
    _snap_section "${EVIDENCE}" before >"${TMPD}/before.sec" 2>/dev/null || {
        _fail D1 baseline "the snapshot this run wrote cannot be re-read (structure)" \
            "cat ${EVIDENCE}"
        _case_end D1 "${EVIDENCE}" "snapshot-unreadable"
        return 1
    }

    # The pull first: while the mirror has not served the images there is no workload to
    # judge, and a GAP says exactly that instead of blaming the product.
    if _grade_pulls D1 "${TMPD}/before.sec"; then
        _grade_payload D1 "${TMPD}/before.sec" || :
    else
        _gap D1 workload "not graded: the mirror did not serve every image, so the container/image/volume facts were never written" \
            "scripts/device/docker-probe.sh --case D1   # rerun once the mirror answers"
    fi
    _case_end D1 "${EVIDENCE}" "mirror=${MIRROR} images=$(printf '%s' "${IMAGES}" | tr ' ' ',')"
}

# --------------------------------------------------------------------------- #
# D2 - the same facts after the jump, compared with D1's baseline
# --------------------------------------------------------------------------- #

run_d2() {
    _case_begin
    EVIDENCE="${SNAPSHOT_DIR}/after.snapshot"
    if [ "${DRY_RUN}" = "1" ]; then
        _dry_plan_capture D2
        _dry_note "compare ${SNAPSHOT_DIR}/before.snapshot with ${EVIDENCE}:"
        _dry_note "  assert_* blocks byte-identical, subset_* blocks only grow, a missing block is drift"
        _dry_note "  a missing/empty baseline block is a FAIL, never a silent pass (the comparator self-checks first)"
        _dry_note "  witness required: generation up, or slot/upper moved; otherwise GAP reason=no-jump"
        _case_end D2 "${EVIDENCE}" "dry-run"
        return 0
    fi
    _expected_facts
    _tmpd

    if ! _load_label before >"${TMPD}/before.sec" 2>/dev/null; then
        _gap D2 baseline "no baseline snapshot to compare against (${SNAPSHOT_DIR}/before.snapshot)" \
            "scripts/device/docker-probe.sh --case D1   # take the baseline before the jump"
        _case_end D2 "-" "no-baseline"
        return 1
    fi
    if [ -z "${INPUT}" ] && ! _preflight; then
        _no_device D2 "${REACH}"
        _case_end D2 "-" "unreachable"
        return 1
    fi
    if ! _capture_after >"${TMPD}/after.sec" 2>/dev/null; then
        _gap D2 capture "the after capture is empty or missing" \
            "scripts/device/docker-probe.sh --case D2"
        _case_end D2 "${EVIDENCE}" "capture-empty"
        return 1
    fi

    # A comparator that stopped judging would call the rest of this run PASS.
    if ! _selfcheck; then
        _fail D2 selfcheck "the comparator failed its own tamper samples, so this verdict is not trustworthy" \
            "scripts/device/docker-probe.sh --selfcheck"
        _case_end D2 "${EVIDENCE}" "comparator-asleep"
        return 1
    fi

    # A baseline whose artifacts were never written (D1 GAPed on the mirror) is not a
    # baseline. Comparing against it would report every artifact as lost, which is a mirror
    # outage dressed up as a regression - so the comparison does not happen at all.
    if ! _baseline_has_workload "${TMPD}/before.sec"; then
        _gap D2 baseline "the baseline carries no complete workload (no pulls, no container/volume/commit artifacts), so nothing here is about a hop" \
            "scripts/device/docker-probe.sh --case D1   # take the baseline while the mirror answers"
        _case_end D2 "${EVIDENCE}" "baseline-incomplete before=${SNAPSHOT_DIR}/before.snapshot"
        return 1
    fi

    _grade_payload D2 "${TMPD}/after.sec" || :
    _snap_compare D2 "${TMPD}/before.sec" "${TMPD}/after.sec" || :

    # $? is read into a variable right after the substitution: the witness is printed
    # whatever it decides, and the decision has to survive the printf.
    _witness=$(_jump_witness "${TMPD}/before.sec" "${TMPD}/after.sec")
    _jumped=$?
    if [ "${_jumped}" -eq 0 ] && [ "${REQUIRE_JUMP}" = "1" ]; then
        _ok D2 jump "${_witness} (moved)"
    else
        _gap D2 jump "${_witness} (nothing moved, so a comparison across a hop was never made)" \
            "scripts/device/docker-probe.sh --case D2   # run it after the upgrade/downgrade phase"
    fi
    _case_end D2 "${EVIDENCE}" "before=${SNAPSHOT_DIR}/before.snapshot jump=${_witness}"
}

# --------------------------------------------------------------------------- #
# D3 - the machine's own identity: mounts and the two subvolumes
# --------------------------------------------------------------------------- #

run_d3() {
    _case_begin
    EVIDENCE="${SNAPSHOT_DIR}/after.snapshot"
    if [ "${DRY_RUN}" = "1" ]; then
        _dry_plan_capture D3
        _dry_note "assert ab-slot status data=ok docker=ok swap=ok on both captures"
        _dry_note "assert btrfs subvolume show (id+uuid) and btrfs property get ro for @docker and @data"
        _dry_note "        are identical before and after the jump - the store was reused, not recreated"
        _case_end D3 "${EVIDENCE}" "dry-run"
        return 0
    fi
    _expected_facts
    _tmpd

    if ! _load_label before >"${TMPD}/before.sec" 2>/dev/null; then
        _gap D3 baseline "no baseline snapshot, so there is nothing to be identical with" \
            "scripts/device/docker-probe.sh --case D1"
        _case_end D3 "-" "no-baseline"
        return 1
    fi
    if [ -z "${INPUT}" ] && ! _preflight; then
        _no_device D3 "${REACH}"
        _case_end D3 "-" "unreachable"
        return 1
    fi
    if ! _capture_after >"${TMPD}/after.sec" 2>/dev/null; then
        _gap D3 capture "the after capture is empty or missing" \
            "scripts/device/docker-probe.sh --case D3"
        _case_end D3 "${EVIDENCE}" "capture-empty"
        return 1
    fi

    for _d3_f in data docker swap; do
        _d3_b=$(_snap_value "${TMPD}/before.sec" assert_slot "${_d3_f}")
        _d3_a=$(_snap_value "${TMPD}/after.sec" assert_slot "${_d3_f}")
        if [ "${_d3_b}" = "ok" ] && [ "${_d3_a}" = "ok" ]; then
            _ok D3 mount "${_d3_f}=ok->ok"
        else
            _fail D3 mount "${_d3_f}=${_d3_b:-none}->${_d3_a:-none} (ac-9 wants ok on both sides)" \
                "ab-slot status; mount | grep -E ' /(data|opt/docker|swap) '"
        fi
    done

    _snap_body "${TMPD}/before.sec" assert_subvol_identity >"${TMPD}/d3-id-b.txt"
    _snap_body "${TMPD}/after.sec" assert_subvol_identity >"${TMPD}/d3-id-a.txt"
    if [ ! -s "${TMPD}/d3-id-b.txt" ]; then
        _fail D3 subvol-identity "the baseline recorded no subvolume identity, so nothing was compared" \
            "btrfs subvolume show ${AB_P4_MOUNT}/@docker; btrfs subvolume show ${AB_P4_MOUNT}/@data"
    elif cmp -s "${TMPD}/d3-id-b.txt" "${TMPD}/d3-id-a.txt"; then
        _ok D3 subvol-identity "unchanged: $(tr '\n' ';' <"${TMPD}/d3-id-a.txt" | tr -s ' ')"
    else
        _fail D3 subvol-identity "drift=content @docker/@data identity changed: $(diff "${TMPD}/d3-id-b.txt" "${TMPD}/d3-id-a.txt" 2>/dev/null | sed -n '2,4p' | tr '\n' ';' | tr -s ' ')" \
            "btrfs subvolume show ${AB_P4_MOUNT}/@docker; btrfs subvolume list ${AB_P4_MOUNT}"
    fi
    for _d3_sv in @docker @data; do
        _d3_id=$(printf '%s\n' "$(grep "^subvol=${_d3_sv} " "${TMPD}/d3-id-b.txt" 2>/dev/null)" | sed -n 's/.* id=\([^ ]*\).*/\1/p')
        case "${_d3_id}" in
            "" | none)
                _fail D3 subvol-identity "${_d3_sv} has no subvolume id in the baseline (id=${_d3_id:-none})" \
                    "btrfs subvolume show ${AB_P4_MOUNT}/${_d3_sv}"
                ;;
        esac
    done

    _snap_body "${TMPD}/before.sec" assert_subvol_property >"${TMPD}/d3-p-b.txt"
    _snap_body "${TMPD}/after.sec" assert_subvol_property >"${TMPD}/d3-p-a.txt"
    if [ ! -s "${TMPD}/d3-p-b.txt" ]; then
        _fail D3 subvol-property "the baseline recorded no btrfs property for @docker/@data" \
            "btrfs property get -ts ${AB_P4_MOUNT}/@docker ro"
    elif cmp -s "${TMPD}/d3-p-b.txt" "${TMPD}/d3-p-a.txt"; then
        _ok D3 subvol-property "unchanged: $(tr '\n' ';' <"${TMPD}/d3-p-a.txt" | tr -s ' ')"
    else
        _fail D3 subvol-property "drift=content btrfs property changed: $(diff "${TMPD}/d3-p-b.txt" "${TMPD}/d3-p-a.txt" 2>/dev/null | sed -n '2,4p' | tr '\n' ';' | tr -s ' ')" \
            "btrfs property get -ts ${AB_P4_MOUNT}/@docker ro"
    fi

    _witness=$(_jump_witness "${TMPD}/before.sec" "${TMPD}/after.sec")
    _jumped=$?
    if [ "${_jumped}" -eq 0 ] && [ "${REQUIRE_JUMP}" = "1" ]; then
        _ok D3 jump "${_witness} (moved)"
    else
        _gap D3 jump "${_witness} (nothing moved, so 'identical after a hop' was not tested)" \
            "scripts/device/docker-probe.sh --case D3   # run it after the upgrade/downgrade phase"
    fi
    _case_end D3 "${EVIDENCE}" "before=${SNAPSHOT_DIR}/before.snapshot jump=${_witness}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

if [ "${SELFCHECK}" = "1" ]; then
    if [ "${JSON}" != "1" ]; then
        printf 'docker-probe selfcheck: the comparator must go red on a tampered sample\n'
    fi
    if _selfcheck; then exit 0; fi
    exit 1
fi

if [ "${JSON}" != "1" ]; then
    printf 'docker-probe start host=%s key=%s cases=%s mirror=%s dry_run=%s replay=%s\n' \
        "${AB_HOST}" "${AB_KEY}" \
        "$(printf '%s' "${CASES}" | tr -s ' ' ',' | sed 's/^,//; s/,$//')" \
        "${MIRROR}" "${DRY_RUN}" "${INPUT:-none}"
fi

# The cases run in the order the acceptance needs (baseline, then after the jump), and a
# case that could not reach a verdict does not stop the next one: D2 and D3 both compare
# against D1's snapshot and each reports its own reason.
for _case in ${CASES}; do
    case "${_case}" in
        D1) run_d1 ;;
        D2) run_d2 ;;
        D3) run_d3 ;;
    esac
done

# The exit status is about the run, the rows are about the cases: a GAP alone exits 3 so a
# caller can tell "nothing failed" from "everything was decided".
if [ "${DRY_RUN}" = "1" ]; then
    [ "${JSON}" = "1" ] || printf 'docker-probe result=dry-run checks=0 failed=0 gaps=0\n'
    exit 0
fi
if [ "${JSON}" = "1" ]; then
    if [ "${FAILS}" -gt 0 ]; then _result=fail
    elif [ "${GAPS}" -gt 0 ]; then _result=gap
    else _result=pass
    fi
    printf '{"kind":"summary","result":"%s","checks":%s,"failed":%s,"gaps":%s}\n' \
        "${_result}" "${CHECKS}" "${FAILS}" "${GAPS}"
elif [ "${FAILS}" -gt 0 ]; then
    printf 'docker-probe result=fail checks=%s failed=%s gaps=%s\n' "${CHECKS}" "${FAILS}" "${GAPS}"
elif [ "${GAPS}" -gt 0 ]; then
    printf 'docker-probe result=gap checks=%s failed=0 gaps=%s reason=network-or-window\n' \
        "${CHECKS}" "${GAPS}"
else
    printf 'docker-probe result=pass checks=%s failed=0 gaps=0\n' "${CHECKS}"
fi
[ "${FAILS}" -gt 0 ] && exit 1
[ "${GAPS}" -gt 0 ] && exit 3
exit 0
