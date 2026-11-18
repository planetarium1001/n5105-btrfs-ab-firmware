#!/bin/sh
# matrix-rise.sh - the rise chain (ac-8): one machine climbs 25.12.0 -> 25.12.1 -> 25.12.2
# with the community sample set installed, and every hop is judged on the same facts.
#
#   scripts/device/matrix-rise.sh                      # the whole chain, from 25.12.0
#   scripts/device/matrix-rise.sh --only R2            # one hop
#   scripts/device/matrix-rise.sh --from-version 25.12.1   # the machine already runs this
#   scripts/device/matrix-rise.sh --resume             # skip the hops already PASS
#   scripts/device/matrix-rise.sh --dry-run            # print the chain, touch nothing
#   scripts/device/matrix-rise.sh --feed off           # walk without a historical feed
#
# The round-2 chain (matrix-round2.sh) walks down and back up on one machine and asks
# whether every switch commits. This is the other direction, and the question that is left
# once the switching itself works: **does the machine keep its installed packages while the
# base underneath climbs one release at a time**, or do the samples fall off at the first
# hop and only look healthy again because nobody looked? A downgrade is walked by round-2
# as well; a rise is the direction a user actually takes, and it is the direction where the
# feed of the release being left has to be reachable, because that is where the packages
# installed before the hop came from.
#
#   R1  25.12.0 -> 25.12.1   payload-25.12.1.tar, samples installed and judged
#   R2  25.12.1 -> 25.12.2   payload-25.12.2.tar, ditto
#
# What a hop has to show (the same six fields plus the base and the layer):
#   committed=<the slot that was not running>, boot=ok, esp=ok, pending=none,
#   packages=aligned, generation >= before+1, rootfs=<the base it installs>,
#   direction=up (computed from the numbers, never read off a case name),
#   upper=@overlay-<base>(-rN)?, the two groups lib.sh defines (STABLE must not move,
#   IDENTITY must move), the /data marker and the /etc/config marker unchanged, and the
#   sample set still USABLE with its fake config and data marker byte-identical
#   (follow-probe.sh --verify).
#
# The sample set: installed and marked ONCE, before the first hop walked, and never
# re-marked. follow-baseline.sh does install+mark in one call, and re-running it after a
# hop would re-baseline exactly the fact the hop is there to measure - a config the new
# base rewrote would be recorded as the new truth instead of as drift. A baseline that is
# already there (from full-test.sh's `follow` phase, which exports the same
# AB_FOLLOW_STATE) is the one the chain judges against, and the evidence says which of the
# two happened. The install itself goes through follow-probe.sh, so a sample the feed does
# not offer is a GAP row from that driver and never a FAIL of the A/B machinery.
#
# The historical feed, and why it goes through customfeeds.list
# ------------------------------------------------------------
# The kmods directory of each release has its own kernel segment (`6.12.87-1-...`,
# `6.12.94-1-...`, `6.12.103-1-...`; the cross-segment path is a 404), so a package that
# carries a kernel module can only come from the release the machine is running. The
# upgrade aligner rewrites every `/releases/<x>/` it finds to the payload's version and it
# never touches `customfeeds.list` (platform/lib/upgrade/packages.sh:217,445,708), which
# makes that one file the only place a release-specific feed can live: a list under any
# other name is rewritten on the next hop, and an old release in `distfeeds.list` makes the
# follow probe report `feeds-stale`.
#
# Which URL belongs to a release is not this driver's question, and it must not become one:
# scripts/device/feed-history.sh probes the upstream tree and answers in its own published
# shape, which this driver reads rather than re-invents:
#
#   feed-history release=25.12.1 mirror=<root> target=x86/64 arch=x86_64
#   feed-history feed=<name> http=200 index=ok url=<index URL>     one per index
#   feed-history kmods-segment=<segment|unknown> source=listing
#   feed-history verdict=PASS|FAIL|GAP release=25.12.1 kernel=<k> kmod=<segment> feeds=7/7
#   feed-history repositories begin
#   <one repository URL per line>                                  the block to install
#   feed-history repositories end
#
#   exit 0 PASS (every index fetched and is an index), 1 FAIL (this release, on this
#   mirror, does not publish an index it claims), 2 usage, 4 GAP (the question could not be
#   answered).
#
# Only the `verdict=` and the block are acted on; `mirror=` classifies the source as
# upstream or mirror and the `feed=` lines are counted, so a row says what was probed
# without this file ever knowing a URL. Both are recorded, never judged here: what a hop
# judges is whether the feed its samples were installed from can still be fetched.
#
# A missing or differently-shaped answer is a GAP naming the script, never a silent skip:
# the row has to say that the feed leg was not measured, and `--feed off` exists for walking
# the chain without that leg - it is recorded in every row as `feed=off(requested)`, so a
# run that skipped the leg cannot be read as one that measured it.
#
# The block the driver writes (and removes again at the end of the run) is marked, so it
# can be stripped without touching a custom feed the operator put in that file:
#
#   # >>> ab-rise begin
#   <feed_line>...
#   # <<< ab-rise end
#
# What is recorded and not judged: the config drift across a hop (the whole `/etc/config`
# set, diffed with tests/lib/device_config.sh). A file moving there is ac-4/ac-11's finding
# and not a reason to call a committed rise hop red - the sample configs themselves are
# judged, through follow-probe.sh --verify. The package set is deliberately not diffed: a
# rise hop is *supposed* to install new versions of the same packages, and a drift report
# about the behaviour under test would be noise.
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run (no committed slot that booted and mounted the ESP cleanly), 4 a case
# could not run for want of its payload, its sample baseline or its feed (GAP). The
# vocabulary is matrix-round2.sh's, so a caller reading full-test.sh's rows cannot tell the
# two chains apart by their exit codes.
#
# `--dry-run` prints the chain and every hop's expected fields, sends no ssh, runs no feed
# probe (feed-history.sh reaches the network), creates no result directory and writes no
# row.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The whole-config snapshot/diff written once for the acceptance drivers (task
# 20261118-01, unit 01) is reused as it is: a second implementation is how two drivers
# start disagreeing about what "the config moved" means.
# shellcheck source=tests/lib/device_config.sh
. "${AB_DEVCFG_LIB:-${AB_REPO_ROOT}/tests/lib/device_config.sh}"

# Version ordering, so a hop's direction and its position in the chain are computed from
# the numbers instead of being read off a case name.
# shellcheck source=platform/lib/ab-version.sh
. "${AB_VERSION_LIB:-${AB_REPO_ROOT}/platform/lib/ab-version.sh}"

# --------------------------------------------------------------------------- #
# Defaults and arguments
# --------------------------------------------------------------------------- #

# The chain, as steps. One machine walks it in this order; --from-version cuts the front
# off it and --only picks a single step out of it. A new release is added here and to the
# case table below, and nowhere else.
CHAIN=${AB_RISE_CHAIN:-"R1 R2"}

PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
# The baseline the sample set is judged against. The default is the path follow-probe.sh
# writes by default, so a rise chain started right after full-test.sh's `follow` phase
# judges the baseline that phase recorded instead of inventing a second one.
FOLLOW_STATE=${AB_FOLLOW_STATE:-/tmp/ab-follow-state.tsv}
# The two sample drivers are called as programs, and which file answers is a knob for the
# same reason AB_DEVCFG_LIB and AB_VERSION_LIB are: the offline test drives this chain
# against stubs that answer in the interface's own shape, because the alternative is a test
# that must install packages on a device to reach the hop's judgement. The default is the
# real script, and every run writes the three paths it used into the evidence, so a run
# that measured with a stand-in cannot be read as one that measured with the product.
FOLLOW_PROBE=${AB_FOLLOW_PROBE:-${DEVICE_DIR}/follow-probe.sh}
FOLLOW_BASELINE=${AB_FOLLOW_BASELINE:-${DEVICE_DIR}/follow-baseline.sh}
# Where the release-specific feed for a hop comes from; see the header for the interface.
FEED_HISTORY=${AB_FEED_HISTORY:-${DEVICE_DIR}/feed-history.sh}
FEED_MODE=${AB_RISE_FEED:-on}
# The one file the aligner never rewrites. The path is a knob so the offline test can name
# a file it owns; on the machine it is the apk-tools 3 source directory.
CUSTOMFEEDS=${AB_RISE_CUSTOMFEEDS:-/etc/apk/repositories.d/customfeeds.list}
# The two lines that bracket the block this run owns. They carry no shell or sed syntax on
# purpose: the block is matched by exact string equality on the machine (see the remote
# halves below), so a marker cannot be read as a pattern by whatever strips it.
FEED_MARK_BEGIN="# ab-rise feed block begin"
FEED_MARK_END="# ab-rise feed block end"
# The config a hop has to carry across, for the recorded (not judged) drift. A file that is
# not there is a state the snapshot records, not an error.
CONFIG_PATHS=${AB_RISE_CONFIG_PATHS:-"/etc/config/system /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/openclash /etc/config/dockerd"}
PAYLOAD_SPECS=${AB_RISE_PAYLOAD_SPECS:-}

START_VERSION=""
ONLY_CASE=""
FROM_STEP=""
RESUME=0
DRY_RUN=0
FIRST_HOP=0
CASE_NOTE=""
STATUS_LINE=""
HOP_FAILED=0
DRIFT=""
DRIFT_CFG=""
SNAP_CFG=""
SAMPLES_MODE=""
SAMPLES_VERDICT=""
SAMPLES_GAP=0
SAMPLES_RC=0
FEED_SOURCE=""
FEED_ROOT=""
FEED_KMODS=""
FEED_INDEX=""
FEED_URLS=""
FEED_NOTE=""
FEED_RESOLVED_FOR=""
FEED_VERSION=""
FEED_PRE_RC=0
FEED_POST_RC=0

usage() {
    cat <<'USAGE'
usage: matrix-rise.sh [--only <case>] [--from <step>] [--from-version <v>] [--resume]
                      [--payload-dir DIR] [--payload <case>=<path>] [--results FILE]
                      [--evidence-dir DIR] [--feed on|off] [--dry-run]

  --only <case>          walk one step: R1 R2
  --from <step>          start at this step (1..2 or a case id) and walk the rest
  --from-version <v>     the base the machine runs now (default: the chain's own start,
                         25.12.0); the hops below it are cut off, and it is recorded
  --resume               skip the PASS rows whose predecessors are all PASS
  --payload-dir DIR      where payload-<version>.tar lives (default: payloads)
  --payload C=PATH       use PATH for case C instead of <payload-dir>/payload-<version>.tar
  --results FILE         results.tsv to append to (default: results.tsv)
  --evidence-dir DIR     evidence directory (default: <results dir>/evidence/rise)
  --feed on|off          point customfeeds at each hop's release (default: on); off is
                         recorded in every row as feed=off(requested)
  --dry-run              print the chain and each hop's expected fields; no ssh is sent

Exit: 0 all PASS, 1 a FAIL, 2 usage, 3 red line, 4 GAP (payload, baseline or feed missing).
USAGE
}

while [ $# -gt 0 ]; do
    case "${1}" in
        --only)
            ONLY_CASE=${2:?--only needs a value}
            shift 2
            ;;
        --from)
            FROM_STEP=${2:?--from needs a value}
            shift 2
            ;;
        --from-version)
            START_VERSION=${2:?--from-version needs a version}
            shift 2
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a value}
            shift 2
            ;;
        --payload)
            PAYLOAD_SPECS="${PAYLOAD_SPECS} ${2:?--payload needs <case>=<path>}"
            shift 2
            ;;
        --results)
            RESULTS=${2:?--results needs a value}
            shift 2
            ;;
        --evidence-dir)
            EVIDENCE_DIR=${2:?--evidence-dir needs a value}
            shift 2
            ;;
        --feed)
            case "${2:-}" in
                on | off) FEED_MODE=${2} ;;
                *)
                    printf 'matrix-rise: --feed takes on or off, not "%s"\n' "${2:-}" >&2
                    usage >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'matrix-rise: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "${ONLY_CASE}" ] && [ -n "${FROM_STEP}" ]; then
    printf 'matrix-rise: --only and --from answer different questions; pass one\n' >&2
    exit 2
fi

AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence/rise
AB_EVIDENCE_LOG=""
AB_MATRIX_CMD="$0"

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: the planner below only prints, and every ssh helper refuses anyway.
    AB_DRY_RUN=1
fi
export AB_DRY_RUN AB_RESULTS AB_EVIDENCE_LOG AB_MATRIX_CMD

# --------------------------------------------------------------------------- #
# The step table
#
# One function per fact, so a hop is described once and both the plan and the assertions
# read that description. Adding a step means adding it here and to CHAIN; nothing else in
# this file names a base.
# --------------------------------------------------------------------------- #

case_kind() {
    case "${1}" in
        R1 | R2) printf 'base\n' ;;
        *) return 1 ;;
    esac
}

case_from_rootfs() { # the base the machine must be running before the hop
    case "${1}" in
        R1) printf '25.12.0\n' ;;
        R2) printf '25.12.1\n' ;;
        *) return 1 ;;
    esac
}

case_to_rootfs() { # the base the hop installs
    case "${1}" in
        R1) printf '25.12.1\n' ;;
        R2) printf '25.12.2\n' ;;
        *) return 1 ;;
    esac
}

case_payload() { # the payload file the hop carries, in PAYLOAD_DIR
    case "${1}" in
        R1) printf 'payload-25.12.1.tar\n' ;;
        R2) printf 'payload-25.12.2.tar\n' ;;
        *) return 1 ;;
    esac
}

case_step() { # 1-based position in the whole chain, so it does not move under --only
    _i=0
    for _c in ${CHAIN}; do
        _i=$((_i + 1))
        if [ "${_c}" = "${1}" ]; then
            printf '%s\n' "${_i}"
            return 0
        fi
    done
    return 1
}

case_total() {
    printf '%s\n' ${CHAIN} | wc -l | tr -d ' '
}

# direction_of <from> <to>: up, down or same-base - computed, never read off a name.
direction_of() {
    if ! _cmp=$(ab_version_cmp "${1:-}" "${2:-}" 2>/dev/null); then
        printf 'unknown\n'
        return 0
    fi
    # ab_version_cmp <a> <b> prints 1 when a is the newer one, so a "from" that is newer
    # than its "to" is a hop down.
    case "${_cmp}" in
        1) printf 'down\n' ;;
        -1) printf 'up\n' ;;
        *) printf 'same-base\n' ;;
    esac
}

# relation_of <landing> <rollback>: how the slot left behind compares with the one the hop
# lands in. After a rise the fallback is the older rootfs.
relation_of() {
    if ! _cmp=$(ab_version_cmp "${1:-}" "${2:-}" 2>/dev/null); then
        printf 'unknown\n'
        return 0
    fi
    case "${_cmp}" in
        1) printf 'older\n' ;;
        -1) printf 'newer\n' ;;
        *) printf 'same\n' ;;
    esac
}

# hop_expect <case>: the one description of what the hop must do and end in.
# hop_expect_value <case> <key> reads a field out of it, so an assertion cannot promise
# something the plan does not print.
hop_expect() {
    _c=${1:?hop_expect needs a case}
    _kind=$(case_kind "${_c}") || return 2
    _step=$(case_step "${_c}") || return 2
    printf 'step=%s/%s kind=%s direction=%s from-rootfs=%s to-rootfs=%s rollback=%s payload=%s samples=install-if-absent feed=%s\n' \
        "${_step}" "$(case_total)" "${_kind}" \
        "$(direction_of "$(case_from_rootfs "${_c}")" "$(case_to_rootfs "${_c}")")" \
        "$(case_from_rootfs "${_c}")" "$(case_to_rootfs "${_c}")" \
        "$(relation_of "$(case_to_rootfs "${_c}")" "$(case_from_rootfs "${_c}")")" \
        "$(case_payload "${_c}")" "${FEED_MODE}"
}

hop_expect_value() { # <case> <key>
    hop_expect "${1}" | tr ' ' '\n' | sed -n "s/^${2:?hop_expect_value needs a key}=//p" | head -n 1
}

# chain_ceiling: the base the last step lands on - the end of the chain, by construction.
chain_ceiling() {
    _last=""
    for _c in ${CHAIN}; do
        _last=${_c}
    done
    case_to_rootfs "${_last}" || return 2
}

# chain_from_versions: every base the chain can start from, space separated, for the usage
# message a wrong --from-version gets.
chain_from_versions() {
    _out=""
    for _c in ${CHAIN}; do
        _out="${_out} $(case_from_rootfs "${_c}")"
    done
    printf '%s\n' "${_out# }"
}

# chain_for_start <version>: the steps a machine running <version> still has to walk.
# A hop whose "from" is below the start is already behind the machine and is cut off.
chain_for_start() {
    _cfs_v=${1:?chain_for_start needs a version}
    _cfs_out=""
    for _cfs in ${CHAIN}; do
        _cfs_from=$(case_from_rootfs "${_cfs}") || return 2
        _cfs_cmp=$(ab_version_cmp "${_cfs_from}" "${_cfs_v}" 2>/dev/null) || return 2
        case "${_cfs_cmp}" in
            -1) continue ;;
            *) _cfs_out="${_cfs_out} ${_cfs}" ;;
        esac
    done
    printf '%s\n' "${_cfs_out# }"
}

# start_version_ok <version>: a version the chain can be walked from. The ceiling is not
# one of them: a machine already there has nothing left to climb.
start_version_ok() {
    case "${1:-}" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    ab_version_valid "${1}" || return 1
    for _c in ${CHAIN}; do
        [ "$(case_from_rootfs "${_c}")" = "${1}" ] && return 0
    done
    return 1
}

# --------------------------------------------------------------------------- #
# Where a hop's payload comes from, and what line it belongs to
# --------------------------------------------------------------------------- #

payload_override() { # <case>: the --payload C=PATH the caller gave, if any
    for _spec in ${PAYLOAD_SPECS}; do
        case "${_spec}" in
            "$1="*) printf '%s\n' "${_spec#*=}"; return 0 ;;
        esac
    done
    return 1
}

hop_payload_path() { # <case>
    if _ov=$(payload_override "${1}"); then
        printf '%s\n' "${_ov}"
        return 0
    fi
    _name=$(case_payload "${1}") || return 1
    printf '%s/%s\n' "${PAYLOAD_DIR}" "${_name}"
}

# check_payload_line <case> <path>: refuse a payload this chain may not walk, before
# anything is written. The same rule matrix-round2.sh applies, restated here because that
# file is a driver and not a library: 24.x is opkg-era (different package manager, firewall
# model and kernel-module layout), so a verdict from it says nothing about this product and
# `require_supported_line` (lib.sh) is the one place that rule is written. A payload named
# after a platform release (0.0.x) is equally out of place on a base hop: the chain would
# install a rootfs nobody described.
check_payload_line() {
    _c=${1:?check_payload_line needs a case}
    _p=${2:?check_payload_line needs a payload path}
    _name=${_p##*/}
    _v=$(printf '%s\n' "${_name}" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9]*$/\1/p')
    if [ -z "${_v}" ]; then
        printf 'unsupported payload name: %s carries no version this chain can read (want payload-<version>.tar)\n' \
            "${_name}"
        return 1
    fi
    case "${_v}" in
        0.*)
            printf 'unsupported payload line: %s is a platform payload, but %s is a %s hop; a base hop installs a base\n' \
                "${_v}" "${_c}" "$(case_kind "${_c}")"
            return 1
            ;;
        *) require_supported_line "${_v}" "${_p}" ;;
    esac
}

# --------------------------------------------------------------------------- #
# Red lines
# --------------------------------------------------------------------------- #

_red_line() { # <case> <reason>
    printf 'ABORT red-line [%s]: %s\n' "${1:-?}" "${2:-unspecified}" >&2
    printf 'ABORT: the machine has no committed healthy slot to fall back to; nothing else is touched\n' >&2
    ev "ABORT red-line: ${2:-unspecified}"
    exit 3
}

# require_healthy <case>: sets STATUS_LINE, or stops the run here.
# The same two red lines matrix.sh and matrix-round2.sh apply, restated because those files
# are drivers and not a library: the running slot must be the committed one, and both boot=
# and esp= are facts a machine cannot claim without evidence.
require_healthy() {
    _case=${1:-?}
    _line=$(dev_status) || _red_line "${_case}" "ab-slot status is unreadable"
    _boot=$(status_field "${_line}" boot) || _boot=unknown
    _esp=$(status_field "${_line}" esp) || _esp=unknown
    _committed=$(status_field "${_line}" committed) || _committed=""
    case "${_committed}" in
        a | b) : ;;
        *) _red_line "${_case}" "no committed slot (committed='${_committed}')" ;;
    esac
    [ "${_boot}" = "ok" ] || _red_line "${_case}" "boot=${_boot}: the running slot is not proven healthy"
    [ "${_esp}" = "ok" ] || _red_line "${_case}" "esp=${_esp}: the ESP was not proven healthy at boot"
    STATUS_LINE=${_line}
    return 0
}

# require_safe_target <case> <status-line>: an install writes the slot that is not running,
# so the committed layer is only out of reach while the running slot is the committed one.
require_safe_target() {
    _case=${1:-?}
    _line=${2:-}
    _slot=$(status_field "${_line}" slot) || _slot=""
    _committed=$(status_field "${_line}" committed) || _committed=""
    _pending=$(status_field "${_line}" pending) || _pending=""
    if [ "${_slot}" != "${_committed}" ]; then
        _red_line "${_case}" "running slot ${_slot:-?} is not the committed slot ${_committed:-?}: an install would overwrite the only healthy slot"
    fi
    if [ "${_pending}" != "none" ]; then
        printf 'unsafe target [%s]: pending=%s is already queued, resolve it before installing\n' \
            "${_case}" "${_pending:-?}" >&2
        ev "unsafe target: pending=${_pending:-?}"
        return 1
    fi
    return 0
}

other_slot() {
    case "${1}" in
        a) printf 'b\n' ;;
        b) printf 'a\n' ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# The historical feed for one release (ac-9's per-hop fact)
#
# This half only carries out a decision feed-history.sh made: which URL, and whether the
# release has one at all. Keeping the URL knowledge out of this file is what stops the two
# from disagreeing about where 25.12.1 lives.
# --------------------------------------------------------------------------- #

# _sq <text>: single-quote a value for the remote shell. The URLs come from another
# program's stdout, and a driver that pastes them into a remote command line without
# quoting is one fixture edit away from running somebody else's command on the machine.
_sq() {
    case "${1-}" in
        *"'"*) printf "'%s'" "$(printf '%s' "${1}" | sed "s/'/'\\\\''/g")" ;;
        *) printf "'%s'" "${1-}" ;;
    esac
}

# _feed_write_script: the remote half that installs the block, written from a quoted
# heredoc so nothing here can be expanded by the shell that runs it. The machine is busybox,
# so the strip is an awk pass over the file rather than `sed -i` with a range: the markers
# are compared as whole lines, and a custom feed that happens to contain a bracket is not a
# pattern that decides what gets deleted.
_feed_write_script() {
    cat <<'REMOTE'
set -u
f=$1
begin=$2
end=$3
shift 3
mkdir -p "${f%/*}" 2>/dev/null || true
[ -f "$f" ] || : >"$f" 2>/dev/null || { echo "ab-rise: cannot create $f"; exit 1; }
_strip() {
    awk -v b="$begin" -v e="$end" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; next }
        !inside { print }
    ' "$1" >"$1.ab-rise.$$" && mv "$1.ab-rise.$$" "$1"
}
# The previous block is stripped before this one is written, so a second run replaces its
# own lines instead of stacking a second copy of them.
_strip "$f" || { rm -f "$f.ab-rise.$$"; echo "ab-rise: cannot strip the previous block from $f"; exit 1; }
{
    printf '%s\n' "$begin"
    for u in "$@"; do printf '%s\n' "$u"; done
    printf '%s\n' "$end"
} >>"$f" 2>/dev/null || { echo "ab-rise: cannot append to $f"; exit 1; }
printf 'ab-rise: %s feed line(s) written to %s\n' "$#" "$f"
REMOTE
}

# _feed_remove_script: undo it. The file is removed only when nothing but comments is left,
# because a custom feed the operator put there is not this run's to delete.
_feed_remove_script() {
    cat <<'REMOTE'
set -u
f=$1
begin=$2
end=$3
[ -f "$f" ] || { echo "ab-rise: no $f, nothing to remove"; exit 0; }
awk -v b="$begin" -v e="$end" '
    $0 == b { inside = 1; next }
    $0 == e { inside = 0; next }
    !inside { print }
' "$f" >"$f.ab-rise.$$" && mv "$f.ab-rise.$$" "$f" ||
    { rm -f "$f.ab-rise.$$"; echo "ab-rise: cannot strip the block from $f"; exit 1; }
if grep -qv '^[[:space:]]*\(#\|$\)' "$f"; then
    echo "ab-rise: block removed from $f; the file still carries feeds of its own"
elif rm -f "$f" 2>/dev/null; then
    echo "ab-rise: block removed and $f deleted (it held nothing else)"
else
    echo "ab-rise: block removed from $f; the empty file stayed"
fi
REMOTE
}

# _remote_script_run <host-script> <argv...>: send a program over stdin and its arguments
# as argv. The script goes over stdin and not as one long command line because dropbear
# closes the connection for a command line past its limit, and the arguments stay short
# enough for argv - which is also what lets the test read back the URLs this run wrote.
_remote_script_run() {
    _rsr_prog=${1:?_remote_script_run needs a script}
    shift
    _rsr_args=""
    for _rsr_a in "$@"; do
        _rsr_args="${_rsr_args} $(_sq "${_rsr_a}")"
    done
    dev_ssh "sh -s --${_rsr_args}" <"${_rsr_prog}"
}

# resolve_feed <version>: ask feed-history.sh what this release's feed is.
#   0 usable, 1 measured unavailable, 3 nothing reachable, 4 no answer this driver reads.
resolve_feed() {
    _rv=${1:?resolve_feed needs a version}
    FEED_SOURCE=""
    FEED_ROOT=""
    FEED_KMODS=""
    FEED_INDEX=""
    FEED_URLS=""
    FEED_NOTE=""
    FEED_RESOLVED_FOR=""
    if [ "${FEED_MODE}" = "off" ]; then
        FEED_SOURCE=off
        FEED_RESOLVED_FOR=${_rv}
        return 0
    fi
    if [ ! -f "${FEED_HISTORY}" ]; then
        FEED_NOTE="no feed-history.sh at ${FEED_HISTORY}: the feed for ${_rv} was not resolved (pass --feed off to walk the chain without it, and every row will say feed=off(requested))"
        return 4
    fi
    _out=$(sh "${FEED_HISTORY}" --release "${_rv}" 2>&1)
    _rc=$?
    _verdict=$(printf '%s\n' "${_out}" | sed -n 's/^feed-history verdict=\([A-Za-z]*\) .*/\1/p' | head -n 1)
    _mirror=$(printf '%s\n' "${_out}" | sed -n 's/^feed-history release=[^ ]* mirror=\([^ ]*\).*/\1/p' | head -n 1)
    FEED_KMODS=$(printf '%s\n' "${_out}" \
        | sed -n 's/^feed-history kmods-segment=\([^ ]*\) .*/\1/p' | head -n 1)
    case "${FEED_KMODS}" in
        unknown | '') FEED_KMODS="" ;;
    esac
    _ok_count=$(printf '%s\n' "${_out}" | grep -c '^feed-history feed=.* index=ok' || true)
    _feed_count=$(printf '%s\n' "${_out}" | grep -c '^feed-history feed=' || true)
    FEED_INDEX="${_ok_count}/${_feed_count}"
    # The block between the two markers and nothing else: a caller that pasted the whole
    # output into customfeeds.list would paste verdict lines into apk's source file.
    FEED_URLS=$(printf '%s\n' "${_out}" \
        | sed -n '/^feed-history repositories begin$/,/^feed-history repositories end$/p' \
        | sed '1d;$d' | grep -v '^feed-history ' )
    if [ -n "${_mirror}" ]; then
        case "${_mirror}" in
            *downloads.immortalwrt.org* | *releases.immortalwrt.org*) FEED_SOURCE=upstream ;;
            *) FEED_SOURCE=mirror ;;
        esac
        FEED_ROOT=${_mirror%/}/releases/${_rv}
    fi
    case "${_rc}" in
        0) ;;
        1)
            FEED_NOTE="feed-history.sh measured no usable feed for ${_rv} (verdict=${_verdict:-?} feeds=${FEED_INDEX}): $(printf '%s\n' "${_out}" | grep -m 1 'verdict=' | cut -c1-200)"
            return 1
            ;;
        4)
            FEED_NOTE="feed-history.sh could not answer for ${_rv}, so the feed was not measured (verdict=${_verdict:-GAP} feeds=${FEED_INDEX}): $(printf '%s\n' "${_out}" | grep -m 1 'verdict=' | cut -c1-200)"
            return 4
            ;;
        *)
            FEED_NOTE="feed-history.sh exited ${_rc} for ${_rv}, which is not an answer this driver can read: $(printf '%s\n' "${_out}" | grep -m 1 . | cut -c1-200)"
            return 4
            ;;
    esac
    _want_rel=$(printf '%s\n' "${_out}" | sed -n 's/^feed-history release=\([^ ]*\) .*/\1/p' | head -n 1)
    if [ -n "${_want_rel}" ] && [ "${_want_rel}" != "${_rv}" ]; then
        FEED_NOTE="feed-history.sh answered for ${_want_rel} when asked about ${_rv}"
        return 4
    fi
    if [ -z "${FEED_URLS}" ]; then
        FEED_NOTE="feed-history.sh passed ${_rv} but printed no repositories block, so there is nothing to point the machine at"
        return 4
    fi
    # The URLs are about to be pasted into a command line on the machine, so what they may
    # contain is decided here: an http(s) URL and nothing that a shell would read.
    for _u in ${FEED_URLS}; do
        case "${_u}" in
            https://* | http://*) ;;
            *)
                FEED_NOTE="feed-history.sh printed a repository URL that is not http(s): ${_u}"
                return 4
                ;;
        esac
        case "${_u}" in
            *"'"* | *'"'* | *' '*) FEED_NOTE="feed-history.sh printed a repository URL with a quote or a space in it: ${_u}"; return 4 ;;
        esac
    done
    FEED_RESOLVED_FOR=${_rv}
    return 0
}

# feed_point <version> <label>: make the machine's customfeeds.list name this release's
# feed, and refresh the index so the next apk operation can use it.
#   0 written or reused, 1 measured unavailable, 3 nothing reachable, 4 could not apply.
feed_point() {
    _fp_v=${1:?feed_point needs a version}
    _fp_label=${2:-?}
    if [ "${FEED_MODE}" = "off" ]; then
        FEED_SOURCE=off
        FEED_VERSION=${_fp_v}
        printf 'feed [%s]: off (requested); nothing was pointed at %s\n' "${_fp_label}" "${_fp_v}"
        ev "feed ${_fp_label}: off (requested)"
        return 0
    fi
    if [ "${FEED_VERSION}" = "${_fp_v}" ] && [ -n "${FEED_SOURCE}" ]; then
        printf 'feed [%s]: %s already points at the %s feed (%s); reused\n' \
            "${_fp_label}" "${CUSTOMFEEDS}" "${_fp_v}" "${FEED_SOURCE}"
        ev "feed ${_fp_label}: ${_fp_v} reused ($(feed_fact))"
        return 0
    fi
    if [ "${FEED_RESOLVED_FOR}" != "${_fp_v}" ]; then
        resolve_feed "${_fp_v}"
        _fp_rc=$?
        if [ "${_fp_rc}" -ne 0 ]; then
            printf 'feed [%s]: %s\n' "${_fp_label}" "${FEED_NOTE}"
            ev "feed ${_fp_label}: rc=${_fp_rc} ${FEED_NOTE}"
            return "${_fp_rc}"
        fi
    fi
    _fp_prog=$(devcfg_tmpfile) || return 4
    _feed_write_script >"${_fp_prog}" || {
        rm -f "${_fp_prog}"
        return 4
    }
    _out=$(_remote_script_run "${_fp_prog}" "${CUSTOMFEEDS}" "${FEED_MARK_BEGIN}" "${FEED_MARK_END}" ${FEED_URLS} 2>&1)
    _fp_rc=$?
    rm -f "${_fp_prog}"
    printf '%s\n' "${_out}"
    if [ "${_fp_rc}" -ne 0 ]; then
        FEED_NOTE="the feed block for ${_fp_v} could not be written to ${CUSTOMFEEDS} (rc=${_fp_rc})"
        ev "feed ${_fp_label}: rc=4 ${FEED_NOTE}"
        return 4
    fi
    # The index refresh is what turns "the URL is written" into "apk can read it". Whether
    # a mirror is up is not this driver's judgement, so a failure here is a GAP: the feed
    # leg was not measured, which is a different sentence from "the release has no feed".
    if ! _out=$(dev_ssh 'apk update' 2>&1); then
        FEED_NOTE="apk update failed on the machine after ${_fp_v}'s feed was written: $(printf '%s\n' "${_out}" | grep -m 1 . | cut -c1-200)"
        ev "feed ${_fp_label}: rc=4 ${FEED_NOTE}"
        return 4
    fi
    FEED_VERSION=${_fp_v}
    printf 'feed [%s]: %s %s (kmods=%s); %s feed line(s) written, apk update ok\n' \
        "${_fp_label}" "${FEED_SOURCE:-unknown}" "${FEED_ROOT:-?}" "${FEED_KMODS:-?}" \
        "$(printf '%s\n' "${FEED_URLS}" | grep -c .)"
    ev "feed ${_fp_label}: ${_fp_v} written ($(feed_fact)); apk update ok"
    return 0
}

# feed_unpoint: remove this run's block again. A block left behind names a release the
# machine may no longer run, and leaving one would give every later apk operation a second
# source for packages of that release.
feed_unpoint() {
    [ -n "${FEED_VERSION}" ] || return 0
    [ "${FEED_MODE}" = "on" ] || return 0
    _fu_prog=$(devcfg_tmpfile) || return 4
    _feed_remove_script >"${_fu_prog}" || {
        rm -f "${_fu_prog}"
        return 4
    }
    _remote_script_run "${_fu_prog}" "${CUSTOMFEEDS}" "${FEED_MARK_BEGIN}" "${FEED_MARK_END}"
    _fu_rc=$?
    rm -f "${_fu_prog}"
    FEED_VERSION=""
    return "${_fu_rc}"
}

# --------------------------------------------------------------------------- #
# The sample set: installed and marked once, then judged after every hop
# --------------------------------------------------------------------------- #

# ensure_samples <case> <from-version>: the baseline this chain judges against.
#   0 there is a baseline, 1 it could not be recorded, 4 the baseline cannot be created
#   here (no follow-baseline.sh, or no feed to install from).
ensure_samples() {
    _case=${1:?ensure_samples needs a case}
    _sv=${2:-?}
    SAMPLES_MODE=""
    if [ -f "${FOLLOW_STATE}" ]; then
        SAMPLES_MODE="baseline-existing"
        printf 'samples [%s]: %s already holds a baseline; not re-marked (re-marking would re-baseline what this hop measures)\n' \
            "${_case}" "${FOLLOW_STATE}"
        ev "samples ${_case}: baseline-existing ${FOLLOW_STATE}"
        return 0
    fi
    if [ ! -f "${FOLLOW_BASELINE}" ]; then
        SAMPLES_MODE="no-baseline-driver"
        printf 'samples [%s]: no %s, so the sample set cannot be installed and marked\n' \
            "${_case}" "${FOLLOW_BASELINE}"
        return 4
    fi
    _out=$(sh "${FOLLOW_BASELINE}" --state "${FOLLOW_STATE}" 2>&1)
    _rc=$?
    printf '%s\n' "${_out}" | sed 's/^/  /'
    ev "samples ${_case}: follow-baseline rc=${_rc} state=${FOLLOW_STATE} (installing from ${_sv})"
    if [ "${_rc}" -ne 0 ]; then
        SAMPLES_MODE="baseline-failed"
        return 1
    fi
    SAMPLES_MODE="baseline-created"
    return 0
}

# verify_samples <case>: the sample set is still USABLE and its fake config and data marker
# still hash to what the baseline recorded. 0 pass or gap, 1 fail.
# A gap is not a failure: a sample the feed does not offer is a finding about the feed
# (PRD risk 3, and the judgement follow-probe.sh already makes), so it is carried in the
# row's note and in the evidence rather than turning a committed hop red.
verify_samples() {
    _case=${1:?verify_samples needs a case}
    SAMPLES_VERDICT=""
    SAMPLES_GAP=0
    if [ ! -f "${FOLLOW_STATE}" ]; then
        SAMPLES_VERDICT=none
        printf 'samples [%s]: no baseline at %s, so nothing was judged\n' "${_case}" "${FOLLOW_STATE}"
        return 4
    fi
    if [ ! -f "${FOLLOW_PROBE}" ]; then
        SAMPLES_VERDICT=none
        printf 'samples [%s]: no %s, so the samples were not judged\n' "${_case}" "${FOLLOW_PROBE}"
        return 4
    fi
    # The hop that just happened may still be finishing: a first boot on a new base also
    # runs the package refresh, and on this box that is minutes of apk against the feeds.
    # A driver that reports "no machine answered" is retried; a real verdict is not.
    _attempt=0
    while :; do
        _attempt=$((_attempt + 1))
        _rc=0
        _out=$(sh "${FOLLOW_PROBE}" --verify --state "${FOLLOW_STATE}" 2>&1) || _rc=$?
        [ "${_rc}" -eq 3 ] && [ "${_attempt}" -lt 4 ] || break
        case "${_out}" in
            *no-machine*) sleep "${AB_POLL_INTERVAL}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "${_out}" | sed 's/^/  /'
    SAMPLES_GAP=$(printf '%s\n' "${_out}" | sed -n 's/.*action=verify .*gap=\([0-9][0-9]*\).*/\1/p' | tail -n 1)
    [ -n "${SAMPLES_GAP}" ] || SAMPLES_GAP=0
    ev "samples ${_case}: follow-probe --verify rc=${_rc} gap=${SAMPLES_GAP}"
    case "${_rc}" in
        0)
            SAMPLES_VERDICT=pass
            printf 'ok [%s] samples usable, config and data sha256 unchanged\n' "${_case}"
            return 0
            ;;
        4)
            SAMPLES_VERDICT=gap
            printf 'GAP [%s] samples: a sample the feed does not offer (see the rows above)\n' "${_case}"
            return 0
            ;;
        *)
            SAMPLES_VERDICT=fail
            printf 'FAIL [%s] samples: see the rows above\n' "${_case}"
            return 1
            ;;
    esac
}

# assert_markers <case> <marker-before> <config-before>: the user state survived the hop.
# The same pair matrix.sh judges (restated for the same reason as the red lines above): a
# file on the shared partition, written once and read afterwards, and a value read out of
# /etc/config - both read-only on this side, so asserting on them cannot itself change what
# is being measured. The sample set's own config and data sha256 values are a second,
# per-sample reading of the same question, through follow-probe.sh.
assert_markers() {
    _am_case=${1:-?}
    _am_marker=${2:-}
    _am_config=${3:-}
    _marker_after=$(dev_marker_read) || _marker_after=""
    _check assert_match "${_marker_after}" '.' "${_am_case}" data-marker-present
    _check assert_value "${_marker_after}" "${_am_marker}" "${_am_case}" data-marker
    _check assert_value "$(dev_config_marker)" "${_am_config}" "${_am_case}" config-marker
}

# --------------------------------------------------------------------------- #
# Drift: the config the user owns (recorded, not judged)
# --------------------------------------------------------------------------- #

# _snapshot_boundary <tag>: one boundary of the chain - the config the hops carry across.
_snapshot_boundary() {
    _tag=${1:?_snapshot_boundary needs a tag}
    SNAP_CFG="${EVIDENCE_DIR}/${_tag}.cfg.tsv"
    devcfg_snapshot "${SNAP_CFG}" ${CONFIG_PATHS} >/dev/null 2>&1
    _cfg_rc=$?
    # rc 1 means "at least one file is not there", which is a state and not a failure.
    [ "${_cfg_rc}" -le 1 ] || ev "config snapshot ${_tag}: devcfg_snapshot exited ${_cfg_rc}"
    return 0
}

# _drift <label> <before> <after>: sets DRIFT to none / <n> change(s) / unreadable and
# writes every differing line into the evidence.
_drift() {
    _label=${1:-drift}
    DRIFT=""
    if [ -z "${2:-}" ] || [ ! -s "${2:-/nonexistent}" ] || [ -z "${3:-}" ] || [ ! -s "${3:-/nonexistent}" ]; then
        DRIFT=unreadable
        return 0
    fi
    _diff=$(devcfg_diff "${2}" "${3}")
    case "$?" in
        0) DRIFT=none ;;
        1)
            DRIFT="$(printf '%s\n' "${_diff}" | wc -l | tr -d ' ') change(s)"
            printf '%s\n' "${_diff}" | while IFS= read -r _line; do
                [ -n "${_line}" ] || continue
                ev "${_label}-drift ${_line}"
            done
            ;;
        *) DRIFT=unreadable ;;
    esac
    return 0
}

# --------------------------------------------------------------------------- #
# One hop
# --------------------------------------------------------------------------- #

_check() { "$@" || HOP_FAILED=1; }

# hop_run <case>: 0 PASS, 1 FAIL, 2 GAP (payload missing or refused as out of scope).
hop_run() {
    _case=${1:?hop_run needs a case}
    CASE_NOTE=""
    SAMPLES_MODE=""
    SAMPLES_VERDICT=""
    SAMPLES_GAP=0
    FEED_PRE_RC=0
    FEED_POST_RC=0
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/${_case}.log"
    AB_MATRIX_CMD="$0 --only ${_case}"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"

    _local=$(hop_payload_path "${_case}") || {
        CASE_NOTE="no payload name for ${_case}"
        return 2
    }
    if [ ! -f "${_local}" ]; then
        CASE_NOTE="no payload at ${_local}"
        ev "${CASE_NOTE}"
        return 2
    fi

    _from=$(case_from_rootfs "${_case}") || return 1
    _to=$(case_to_rootfs "${_case}") || return 1
    _dir=$(direction_of "${_from}" "${_to}")

    require_healthy "${_case}" || return 1
    _before=${STATUS_LINE}
    AB_STATUS_LINE=${_before}
    require_safe_target "${_case}" "${_before}" || return 1
    _gen=$(status_field "${_before}" generation) || _gen=0
    _slot=$(status_field "${_before}" slot) || _slot=""
    _target=$(other_slot "${_slot}") || return 1
    _running=$(dev_running_version) || _running=""
    if ! assert_value "${_running}" "${_from}" "${_case}" "chain-position"; then
        CASE_NOTE="chain broken: the machine runs ${_running:-unknown}, this hop starts from ${_from}; rerun with --from-version ${_running:-<version>}"
        ev "${CASE_NOTE}"
        return 1
    fi
    _marker_before=$(dev_marker_read) || _marker_before=""
    _config_before=$(dev_config_marker) || _config_before=""
    ev "hop ${_case}: ${_from} -> ${_to} (${_dir}); slot ${_slot}, target ${_target}, generation ${_gen}"
    ev "hop ${_case}: user state before: data-marker='${_marker_before:-none}' config-marker='${_config_before}'"

    # 1) The feed for the release this hop starts from. The samples are installed from it
    #    (the first hop) and it is the release a package repair would have to match, so a
    #    feed that is not this release's own is worse than none.
    FEED_PRE_RC=0
    feed_point "${_from}" "${_case}-start"
    FEED_PRE_RC=$?

    # 2) The sample set. A baseline that is already there is the one judged; installing it
    #    here only happens when there is none, and it needs the feed that was just pointed.
        # The start release's feed was measured absent, or could not be measured at all. The two
    # are different sentences and get different verdicts: no feed for the release this chain
    # starts from is a finding about that release (ac-9), while a mirror nobody could reach
    # says nothing about it. With no baseline there is also nothing to install the samples
    # from, which turns the second case into a gap rather than a note.
    case "${FEED_PRE_RC}" in
        0) ;;
        1)
            CASE_NOTE="the release this hop starts from has no usable feed, so ac-9's fact for it is answered no: ${FEED_NOTE}; $(feed_fact)"
            ev "${CASE_NOTE}"
            return 1
            ;;
        *)
            if [ ! -f "${FOLLOW_STATE}" ]; then
                CASE_NOTE="the sample baseline cannot be created without a feed for ${_from}: ${FEED_NOTE:-rc=${FEED_PRE_RC}}; $(feed_fact)"
                ev "${CASE_NOTE}"
                return 2
            fi
            ev "feed for ${_from} could not be measured (rc=${FEED_PRE_RC}); the baseline is already there, so this hop does not need it: ${FEED_NOTE}"
            ;;
    esac
    SAMPLES_RC=0
    ensure_samples "${_case}" "${_from}"
    SAMPLES_RC=$?
    if [ "${SAMPLES_RC}" -ne 0 ]; then
        CASE_NOTE="the sample set could not be installed and marked before the hop (samples=${SAMPLES_MODE:-?})"
        ev "${CASE_NOTE}"
        if [ "${SAMPLES_RC}" -eq 4 ]; then
            return 2
        fi
        return 1
    fi

    _remote="${AB_REMOTE_TMP}/${_local##*/}"
    dev_ssh 'ab-slot gc' >/dev/null 2>&1 || ev "gc reported problems (not a hop failure)"
    if ! dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" >/dev/null; then
        CASE_NOTE="the payload could not be pushed to ${_remote}"
        ev "${CASE_NOTE}"
        return 1
    fi
    # ab-upgrade --check is not read-only: it publishes ab/conflicts.log and may leave
    # p2/p3 mounted. The hop therefore starts from a clean mount state and says so.
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    case "${_rc}" in
        0) ;;
        74)
            # Every hop of this chain changes the base, so the already-installed guard has
            # nothing to refuse; a refusal here is a different machine than the one this
            # chain describes, and --force would hide it.
            CASE_NOTE="ab-upgrade --check refused a cross-base payload (exit 74): $(printf '%s\n' "${_out}" | grep -m 1 'refused' || printf 'no refusal line')"
            ev "${CASE_NOTE}"
            return 1
            ;;
        *)
            CASE_NOTE="ab-upgrade --check exited ${_rc}: $(printf '%s\n' "${_out}" | tail -n 1)"
            ev "${CASE_NOTE}"
            return 1
            ;;
    esac

    if ! _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}"); then
        CASE_NOTE="ab-upgrade did not install ${_to}"
        ev "${CASE_NOTE}"
        return 1
    fi

    _armed=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || {
        CASE_NOTE="ab-slot status is unreadable after the install"
        return 1
    }
    AB_STATUS_LINE=${_armed}
    HOP_FAILED=0
    _check assert_field pending "${_target}" "${_case}"
    _check assert_ge "$(status_field "${_armed}" generation || printf 0)" "$((_gen + 1))" "${_case}" generation
    if [ "${HOP_FAILED}" -ne 0 ]; then
        CASE_NOTE="the install did not arm slot ${_target} (pending/generation)"
        ev "${CASE_NOTE}"
        return 1
    fi

    dev_reboot
    if ! dev_wait_up_after after-install; then
        CASE_NOTE="no ssh answer within ${AB_WAIT_UP_FIRST}s after the reboot"
        ev "${CASE_NOTE}"
        return 1
    fi
    if ! _booted=$(dev_capture "${AB_EVIDENCE_LOG}" dev_wait_settled "${AB_WAIT_SETTLE}"); then
        CASE_NOTE="no status line within ${AB_WAIT_SETTLE}s after the machine answered ssh"
        ev "${CASE_NOTE}"
        return 1
    fi
    # lib.sh's assertions read the captured line out of AB_STATUS_LINE instead of paying for
    # one ssh call per field, so the line the hop settled on is published here once.
    # shellcheck disable=SC2034 # read by the assert_* helpers in lib.sh
    AB_STATUS_LINE=${_booted}

    HOP_FAILED=0
    # The two groups lib.sh defines: what must not move across a switch, and what must.
    _check ab_status_switch_check "${_before}" "${_booted}" "${_case}"
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_field packages aligned "${_case}"
    _check assert_ge "$(status_field "${_booted}" generation || printf 0)" "$((_gen + 1))" "${_case}" generation
    _running_now=$(dev_running_version) || _running_now=""
    _check assert_value "${_running_now}" "${_to}" "${_case}" rootfs
    # The direction is judged from the numbers, so a hop described as "up" that landed
    # lower is red here rather than being retold by the note.
    _check assert_value "$(direction_of "${_from}" "${_running_now}")" "${_dir}" "${_case}" direction
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_to}")(-r[0-9]+)?\$" "${_case}" upper
    _check assert_markers "${_case}" "${_marker_before}" "${_config_before}"

    # 3) The feed of the release this hop landed on. It is what the next hop starts from,
    #    and it is ac-9's per-hop fact: can this release's own index still be fetched.
    FEED_POST_RC=0
    feed_point "${_to}" "${_case}-landing"
    FEED_POST_RC=$?

    # 4) The sample set, judged after the hop.
    SAMPLES_RC=0
    verify_samples "${_case}"
    SAMPLES_RC=$?

    # Drift is measured on every hop, including a red one: the two snapshots are the only
    # record of what the payload did to the config the user owns.
    _prev_cfg=${SNAP_CFG}
    _snapshot_boundary "post-${_case}"
    _drift config "${_prev_cfg}" "${SNAP_CFG}"
    DRIFT_CFG=${DRIFT}

    _gen_now=$(status_field "${_booted}" generation) || _gen_now="?"
    _pkg_now=$(status_field "${_booted}" packages) || _pkg_now="?"
    _start_fact=""
    [ "${FIRST_HOP}" = "1" ] && _start_fact="start=${START_VERSION}; "
    _samples_fact="samples=${SAMPLES_VERDICT:-unknown}"
    [ "${SAMPLES_GAP}" = "0" ] || _samples_fact="${_samples_fact} gap=${SAMPLES_GAP}"
    _base_fact="base ${_from}->${_to} (${_dir}), committed ${_target}, generation ${_gen}->${_gen_now}, packages=${_pkg_now}"
    _tail_fact="$(feed_fact); ${_samples_fact}; config-drift=${DRIFT_CFG}"

    if [ "${HOP_FAILED}" -ne 0 ]; then
        # The evidence lines are timestamped, so the case name is matched anywhere in the line.
        _first_fail=$(grep -m 1 "FAIL ${_case} " "${AB_EVIDENCE_LOG}" 2>/dev/null) || _first_fail=""
        _first_fail=$(printf '%s\n' "${_first_fail}" | sed 's/^FAIL [^ ]* //')
        CASE_NOTE="assertions failed on this hop: ${_first_fail}; the chain stops here; ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 1
    fi
    if [ "${FEED_POST_RC}" -eq 1 ]; then
        CASE_NOTE="the feed for ${_to} was measured unavailable: ${FEED_NOTE}; ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 1
    fi
    if [ "${FEED_POST_RC}" -ne 0 ] && [ "${FEED_POST_RC}" -ne 1 ]; then
        CASE_NOTE="the feed for ${_to} could not be resolved or applied, so ac-9's fact for this hop was not measured: ${FEED_NOTE:-rc=${FEED_POST_RC}}; ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ "${SAMPLES_RC}" -ne 0 ] && [ "${SAMPLES_RC}" -ne 4 ]; then
        CASE_NOTE="the samples did not survive the hop: ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 1
    fi
    if [ "${SAMPLES_RC}" -eq 4 ]; then
        CASE_NOTE="samples were not judged (no baseline or no probe), which is a gap and not a pass: ${_base_fact}; ${_tail_fact}"
        ev "${CASE_NOTE}"
        return 2
    fi

    CASE_NOTE="${_start_fact}${_base_fact}; ${_tail_fact}"
    ev "hop ${_case} ok: ${CASE_NOTE}"
    return 0
}

# feed_fact: the feed facts of the hop, one line's worth, for the row and the evidence.
feed_fact() {
    _ff="feed=${FEED_SOURCE:-unknown}"
    [ -n "${FEED_ROOT}" ] && _ff="${_ff} root=${FEED_ROOT}"
    [ -n "${FEED_KMODS}" ] && _ff="${_ff} kmods=${FEED_KMODS}"
    [ -n "${FEED_INDEX}" ] && _ff="${_ff} index=${FEED_INDEX}"
    printf '%s\n' "${_ff}"
}

# --------------------------------------------------------------------------- #
# Selection, and the plan
# --------------------------------------------------------------------------- #

select_cases() {
    _sel=$(chain_for_start "${START_VERSION}") || {
        printf 'matrix-rise: --from-version %s is not a version this chain can be walked from (want one of: %s)\n' \
            "${START_VERSION}" "$(chain_from_versions)" >&2
        return 2
    }
    if [ -z "${_sel}" ]; then
        printf 'matrix-rise: --from-version %s is the top of this chain (%s); there is nothing to walk\n' \
            "${START_VERSION}" "$(chain_ceiling)" >&2
        return 2
    fi
    if [ -n "${ONLY_CASE}" ]; then
        case_step "${ONLY_CASE}" >/dev/null || {
            printf 'matrix-rise: unknown case: %s (want one of: %s)\n' "${ONLY_CASE}" "${CHAIN}" >&2
            return 2
        }
        case " ${_sel} " in
            *" ${ONLY_CASE} "*) _sel=${ONLY_CASE} ;;
            *)
                printf 'matrix-rise: --only %s is not in the chain a machine at %s walks (%s)\n' \
                    "${ONLY_CASE}" "${START_VERSION}" "${_sel}" >&2
                return 2
                ;;
        esac
    elif [ -n "${FROM_STEP}" ]; then
        _started=0
        _out=""
        for _c in ${_sel}; do
            if [ "${_started}" = "0" ]; then
                if [ "${FROM_STEP}" = "$(case_step "${_c}")" ] || [ "${FROM_STEP}" = "${_c}" ]; then
                    _started=1
                else
                    continue
                fi
            fi
            _out="${_out} ${_c}"
        done
        if [ "${_started}" = "0" ]; then
            printf 'matrix-rise: --from %s is not a step of the chain this start version walks (%s)\n' \
                "${FROM_STEP}" "${_sel}" >&2
            return 2
        fi
        _sel=${_out# }
    fi
    if [ "${RESUME}" = "1" ]; then
        # A chain is only resumable at a point it actually reached, so a PASS row is skipped
        # only while every row before it is PASS too: skipping a hole would walk a later
        # hop on a machine that never made the earlier one.
        _out=""
        _skip=1
        for _c in ${_sel}; do
            if [ "${_skip}" = "1" ] && record_passed "${_c}"; then
                printf 'matrix-rise: resume: %s already has a PASS row in %s, skipped\n' \
                    "${_c}" "${AB_RESULTS}" >&2
                continue
            fi
            _skip=0
            _out="${_out} ${_c}"
        done
        _sel=${_out# }
    fi
    printf '%s\n' "${_sel}"
}

# plan_case <case>: what the hop will do, printed and not done.
plan_case() {
    _case=${1:?plan_case needs a case}
    printf '# %s %s\n' "${_case}" "$(hop_expect "${_case}")"
    _local=$(hop_payload_path "${_case}") || return 1
    if [ ! -f "${_local}" ]; then
        printf '# warning: no payload at %s; the run would record GAP\n' "${_local}"
    fi
    _from=$(case_from_rootfs "${_case}")
    _to=$(case_to_rootfs "${_case}")
    if [ "${FEED_MODE}" = "on" ]; then
        printf '%s feed %s --release %s, then write the block into %s and run apk update\n' \
            "${_case}" "${FEED_HISTORY}" "${_from}" "${CUSTOMFEEDS}"
    else
        printf '%s feed off (requested): %s is not pointed at %s\n' "${_case}" "${CUSTOMFEEDS}" "${_from}"
    fi
    printf '%s samples %s --state %s when no baseline is there (installed and marked once, never re-marked)\n' \
        "${_case}" "${FOLLOW_BASELINE}" "${FOLLOW_STATE}"
    printf '%s status (red line: a committed slot, boot=ok, esp=ok, pending=none)\n' "${_case}"
    printf '%s gc\n' "${_case}"
    printf '%s push %s -> %s/%s\n' "${_case}" "${_local}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s check %s/%s expect=exit-0, any refusal is a FAIL (no hop of this chain is same-base)\n' \
        "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s install %s/%s\n' "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    printf '%s reboot, then wait_up %ss, then settle until boot=ok pending=none\n' \
        "${_case}" "${AB_WAIT_UP_FIRST}"
    printf '%s assert boot=ok esp=ok pending=none committed=<the slot that is not running> generation>=+1 packages=aligned rootfs=%s upper=@overlay-%s(-rN)? direction=%s\n' \
        "${_case}" "${_to}" "${_to}" "$(hop_expect_value "${_case}" direction)"
    printf '%s assert the stable fields did not move: %s\n' "${_case}" "${AB_STATUS_FIELDS_STABLE}"
    printf '%s assert the /data marker and the /etc/config marker unchanged, then %s --verify --state %s\n' \
        "${_case}" "${FOLLOW_PROBE}" "${FOLLOW_STATE}"
    if [ "${FEED_MODE}" = "on" ]; then
        printf '%s feed %s --release %s, write the block into %s and run apk update (ac-9 fact for this hop)\n' \
            "${_case}" "${FEED_HISTORY}" "${_to}" "${CUSTOMFEEDS}"
    fi
    printf '%s snapshot %s and diff against the previous boundary (config drift recorded, not judged)\n' \
        "${_case}" "${CONFIG_PATHS}"
    printf '%s record\n' "${_case}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

# The start version is the one thing that has to be true before anything is planned: a
# machine the chain cannot be walked from would otherwise spend a boot finding that out.
if [ -z "${START_VERSION}" ]; then
    START_VERSION=$(case_from_rootfs "$(printf '%s\n' ${CHAIN} | head -n 1)")
fi
if ! start_version_ok "${START_VERSION}"; then
    printf 'matrix-rise: --from-version %s is not a version this chain can be walked from (want one of: %s)\n' \
        "${START_VERSION}" "$(chain_from_versions)" >&2
    exit 2
fi

SELECTED=$(select_cases) || exit 2

if [ "${DRY_RUN}" = "1" ]; then
    printf '# run from-version=%s ceiling=%s chain="%s" feed=%s resume=%s results=%s\n' \
        "${START_VERSION}" "$(chain_ceiling)" "${SELECTED}" "${FEED_MODE}" "${RESUME}" "${AB_RESULTS}"
    for _case in ${SELECTED}; do
        plan_case "${_case}" || exit 2
    done
    exit 0
fi

if [ -z "${SELECTED}" ]; then
    printf 'matrix-rise: nothing to walk: every hop of "%s" already has a PASS row in %s\n' \
        "${CHAIN}" "${AB_RESULTS}"
    exit 0
fi

# Every case writes its evidence before it decides anything, so the directory is made once
# here.
mkdir -p "${EVIDENCE_DIR}" || {
    printf 'matrix-rise: cannot create %s\n' "${EVIDENCE_DIR}" >&2
    exit 2
}

# The payloads are judged before the machine is touched: a 24.x payload or a platform
# payload on a base hop is a scope violation, and discovering it after a failed boot would
# look like a product defect.
_preflight() { # <case> <verdict> <note>
    printf '== %s (refused before any machine was touched)\n' "${1}"
    record "${1}" "${2}" - "${3}"
    printf '   %s: %s\n' "${1}" "${3}"
}

for _case in ${SELECTED}; do
    _p=$(hop_payload_path "${_case}") || {
        _preflight "${_case}" FAIL "no payload name for ${_case}"
        exit 1
    }
    if [ ! -f "${_p}" ]; then
        _preflight "${_case}" GAP "no payload at ${_p} (build it, or pass --payload ${_case}=<path>)"
        exit 4
    fi
    if ! _msg=$(check_payload_line "${_case}" "${_p}" 2>&1); then
        _preflight "${_case}" FAIL "${_msg}"
        exit 1
    fi
done

# The feed for the start release is resolved here, host side: a chain whose first hop has no
# feed cannot install its samples, and saying so before the machine is touched keeps the
# difference between "nothing to install from" and "the payload broke the machine".
resolve_feed "${START_VERSION}"
_feed_rc=$?
if [ "${_feed_rc}" -ne 0 ]; then
    _first=${SELECTED%% *}
    if [ "${_feed_rc}" -eq 1 ]; then
        _preflight "${_first}" FAIL "${FEED_NOTE}"
        exit 1
    fi
    _preflight "${_first}" GAP "${FEED_NOTE}"
    exit 4
fi

AB_EVIDENCE_LOG="${EVIDENCE_DIR}/00-baseline.log"
AB_MATRIX_CMD="$0"
export AB_EVIDENCE_LOG AB_MATRIX_CMD
: >"${AB_EVIDENCE_LOG}"
# Baseline: the chain may only start from a machine that can fall back, and the boundaries
# before the first hop are what every later drift is measured against.
_first=${SELECTED%% *}
require_healthy "${_first}"
_machine_start=$(dev_running_version) || _machine_start=""
ev "run start-version=${START_VERSION} (requested) machine=${_machine_start:-unknown} ceiling=$(chain_ceiling) chain=\"${SELECTED}\" feed=${FEED_MODE}"
ev "baseline: ${STATUS_LINE}"
ev "baseline: config paths ${CONFIG_PATHS}"
ev "helpers: follow-probe=${FOLLOW_PROBE} follow-baseline=${FOLLOW_BASELINE} feed-history=${FEED_HISTORY}"
printf 'matrix-rise: start version %s (the machine reports %s), ceiling %s, chain %s, feed %s\n' \
    "${START_VERSION}" "${_machine_start:-unknown}" "$(chain_ceiling)" "${SELECTED}" "${FEED_MODE}"
# The start version is a claim about the machine, and a claim nobody checked is how a chain
# walks a hop whose payload is already installed. It is stated here, before the first boot,
# with the flag that fixes it: the hop's own chain-position assertion would find it too, but
# only after a push and a reboot.
if [ -n "${_machine_start}" ] && [ "${_machine_start}" != "${START_VERSION}" ]; then
    printf 'matrix-rise: warning: the machine runs %s but this run was told to start at %s; the first hop will refuse it - rerun with --from-version %s if the machine is right and the flag is wrong\n' \
        "${_machine_start}" "${START_VERSION}" "${_machine_start}"
    ev "start mismatch: requested ${START_VERSION}, machine reports ${_machine_start}"
fi
dev_marker_init >/dev/null 2>&1 || ev "the /data marker could not be created (recorded, not judged)"
_snapshot_boundary pre

_passed=0
_failed=0
_gapped=0

for _case in ${SELECTED}; do
    FIRST_HOP=0
    [ "${_case}" = "${SELECTED%% *}" ] && FIRST_HOP=1
    printf '== %s %s\n' "${_case}" \
        "kind=$(hop_expect_value "${_case}" kind) direction=$(hop_expect_value "${_case}" direction) $(hop_expect_value "${_case}" from-rootfs)->$(hop_expect_value "${_case}" to-rootfs)"
    hop_run "${_case}"
    _rc=$?
    case "${_rc}" in
        0)
            record "${_case}" PASS "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _passed=$((_passed + 1))
            ;;
        2)
            record "${_case}" GAP "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _gapped=$((_gapped + 1))
            printf '   %s: %s\n' "${_case}" "${CASE_NOTE}"
            break
            ;;
        *)
            record "${_case}" FAIL "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _failed=$((_failed + 1))
            printf '   %s: %s\n' "${_case}" "${CASE_NOTE}"
            break
            ;;
    esac
    printf '   %s: %s (%s)\n' "${_case}" "${CASE_NOTE}" "${AB_EVIDENCE_LOG}"
done

# The block this run wrote names a release the machine may no longer run, so it goes away
# again on every way out of the loop. A machine that is not answering keeps it, and the
# evidence says so instead of pretending the cleanup happened.
AB_EVIDENCE_LOG="${EVIDENCE_DIR}/99-teardown.log"
AB_MATRIX_CMD="$0"
export AB_EVIDENCE_LOG AB_MATRIX_CMD
: >"${AB_EVIDENCE_LOG}"
if ! dev_capture "${AB_EVIDENCE_LOG}" feed_unpoint; then
    ev "feed: the block in ${CUSTOMFEEDS} could not be removed; the machine may still point at ${FEED_VERSION:-a release}"
    printf 'matrix-rise: warning: %s may still carry this run feed block for %s; strip it by hand (it is marked) or let a later run replace it\n' \
        "${CUSTOMFEEDS}" "${FEED_VERSION:-a release}"
fi

printf '\nmatrix-rise: start=%s passed=%s failed=%s gap=%s results=%s\n' \
    "${START_VERSION}" "${_passed}" "${_failed}" "${_gapped}" "${AB_RESULTS}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
exit 0
