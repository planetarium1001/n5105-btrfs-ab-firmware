#!/bin/sh
# matrix-round2.sh - the round-2 acceptance chain (ac-6, ac-7): one machine, one pass,
# no reflash in the middle.
#
# The round-1 matrix (matrix.sh) starts every case from whatever the machine happens to
# run, which costs a positioning hop per case. This round is the other question, the one
# a person with one device actually asks: *walk one machine through the whole line and
# see whether it keeps committing*. So the cases below are the steps of one continuous
# chain, in the order the device phase walks them:
#
#   1. P1  0.0.11 payload            platform-only hop, base stays 25.12.2
#   2. P2  25.12.2 @ p0.0.12 payload platform-only hop, the release this round is about
#   3. D1  25.12.2 -> 25.12.1        base down
#   4. D2  25.12.1 -> 25.12.0        base down
#   5. U1  25.12.0 -> 25.12.1        base up
#   6. U2  25.12.1 -> 25.12.2        base up
#   7. REL the v0.0.12 assets against their index.txt (offline, no machine at all)
#
# Every hop is judged on the same six fields of `ab-slot status` - committed, generation,
# pending, boot, esp, packages - plus the rootfs the machine reports and the layer it
# records, plus the two switch groups lib.sh already defines (STABLE must not move,
# IDENTITY must move). "It came back" is never a verdict.
#
#   scripts/device/matrix-round2.sh                    # the whole chain
#   scripts/device/matrix-round2.sh --only D1          # one hop
#   scripts/device/matrix-round2.sh --from 4           # resume at D2 (step numbers 1-7)
#   scripts/device/matrix-round2.sh --dry-run          # print the chain, touch nothing
#   scripts/device/matrix-round2.sh --release-dir DIR  # the v0.0.12 assets, for REL
#
# Direction is not read off the name of a case: `direction=up|down|same-base` is computed
# from the two versions with platform/lib/ab-version.sh, the same comparison the updater
# uses, so a hand-edited chain and its expectations cannot disagree. What a hop expects is
# printed by hop_expect() and *judged* from the same function - one description, not two.
#
# The platform-only hop and --force. A payload for the base a slot already runs is refused
# with exit 74 `payload-already-installed` unless --force is given, and two releases on the
# same base differ precisely in the platform, which the guard now compares. Round 1 measured
# the older behaviour on a v0.0.10 image: the hop was refused and only went through with
# --force. Both are recorded as facts, neither is a failure:
#   * refused with exit 74 payload-already-installed -> the hop is reinstalled with --force
#     and the row carries `regression=refused-payload-already-installed`;
#   * accepted without --force -> the row carries `regression=not-refused`, which is the
#     fixed behaviour (the platform-only guard is in the running release);
#   * refused for any other reason, or a cross-base payload refused -> FAIL, because that is
#     a different machine than the one this chain describes.
#
# Config and package drift. `tests/lib/device_config.sh` (unit 01) snapshots the config on
# both sides of a hop and the installed package list is diffed with the same comparator;
# both drifts are written into the evidence and summarised in the row. They are recorded,
# not judged: ac-6 is about the six fields, and a config that moves across a base change is
# ac-4/ac-11's finding, not a reason to call a committed hop red.
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run (no committed slot that booted and mounted the ESP cleanly), 4 a case
# could not run for want of its payload or of the release assets (GAP).
#
# `--dry-run` prints the chain and every hop's expected fields, sends no ssh, creates no
# result directory and writes no row. The release-byte case (REL) reads a directory and
# never touches the machine, so it still runs when a hop stopped the chain; the run's exit
# status is about the hop that failed.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The shared config verifier and the sample list of this round were written once (unit 01)
# and are reused here as they are: a second snapshot/diff implementation is how four
# drivers start disagreeing about what "the config moved" means.
# shellcheck source=tests/lib/device_config.sh
. "${AB_DEVCFG_LIB:-${AB_REPO_ROOT}/tests/lib/device_config.sh}"

# Version ordering, so the direction of a hop is computed from the numbers.
# shellcheck source=platform/lib/ab-version.sh
. "${AB_VERSION_LIB:-${AB_REPO_ROOT}/platform/lib/ab-version.sh}"

# --------------------------------------------------------------------------- #
# Defaults and arguments
# --------------------------------------------------------------------------- #

# The chain, as steps. One machine walks it in this order; --from resets the start and
# --only picks a single step out of it.
CHAIN=${AB_R2_CHAIN:-"P1 P2 D1 D2 U1 U2 REL"}

PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
RELEASE_DIR=${AB_R2_RELEASE_DIR:-${AB_RELEASE_DIR:-}}
RELEASE_TAG=${AB_R2_RELEASE_TAG:-v0.0.12}
RELEASE_VERSION=${AB_R2_RELEASE_VERSION:-0.0.12}
RELEASE_VERIFY=${AB_RELEASE_VERIFY:-${DEVICE_DIR}/release-verify.sh}
# The config a hop has to carry across. A file that is not there is a state the snapshot
# records, not an error: an app that is not installed owns no config.
CONFIG_PATHS=${AB_R2_CONFIG_PATHS:-"/etc/config/system /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/openclash /etc/config/dockerd"}
PAYLOAD_SPECS=${AB_R2_PAYLOAD_SPECS:-}

ONLY_CASE=""
FROM_STEP=""
DRY_RUN=0
CASE_NOTE=""
CASE_REGRESSION=""
STATUS_LINE=""
HOP_FAILED=0
DRIFT=""
DRIFT_CFG=""
DRIFT_PKG=""
SNAP_CFG=""
SNAP_PKG=""
PREFLIGHT_CASE=""
PREFLIGHT_NOTE=""
PREFLIGHT_VERDICT=""

usage() {
    cat <<'USAGE'
usage: matrix-round2.sh [--only <case>] [--from <step>] [--payload-dir DIR]
                        [--payload <case>=<path>]... [--results FILE]
                        [--evidence-dir DIR] [--release-dir DIR] [--release-tag TAG]
                        [--dry-run]

  --only <case>       walk one step: P1 P2 D1 D2 U1 U2 REL
  --from <step>       start at this step (1..7 or a case id) and walk the rest
  --payload-dir DIR   where payload-<version>.tar lives (default: payloads)
  --payload C=PATH    use PATH for case C instead of <payload-dir>/payload-<version>.tar
  --results FILE      results.tsv to append to (default: results.tsv)
  --evidence-dir DIR  evidence directory (default: <results dir>/evidence/r2)
  --release-dir DIR   downloaded v0.0.12 assets, for the REL case (offline)
  --release-tag TAG   the release the REL case reads (default: v0.0.12)
  --dry-run           print the chain and each hop's expected fields; no ssh is sent

Exit: 0 all PASS, 1 a FAIL, 2 usage, 3 red line, 4 GAP (payload or assets missing).
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
        --release-dir)
            RELEASE_DIR=${2:?--release-dir needs a value}
            shift 2
            ;;
        --release-tag)
            RELEASE_TAG=${2:?--release-tag needs a value}
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
            printf 'matrix-round2: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "${ONLY_CASE}" ] && [ -n "${FROM_STEP}" ]; then
    printf 'matrix-round2: --only and --from answer different questions; pass one\n' >&2
    exit 2
fi

AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence/r2
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
# this file names a version.
# --------------------------------------------------------------------------- #

case_kind() {
    case "${1}" in
        P1 | P2) printf 'platform\n' ;;
        D1 | D2 | U1 | U2) printf 'base\n' ;;
        REL) printf 'release\n' ;;
        *) return 1 ;;
    esac
}

case_from_rootfs() { # the base the machine must be running before the hop
    case "${1}" in
        P1 | P2 | D1) printf '25.12.2\n' ;;
        U1) printf '25.12.0\n' ;;
        D2 | U2) printf '25.12.1\n' ;;
        *) return 1 ;;
    esac
}

case_to_rootfs() { # the base the hop installs
    case "${1}" in
        P1 | P2 | U2) printf '25.12.2\n' ;;
        D1 | U1) printf '25.12.1\n' ;;
        D2) printf '25.12.0\n' ;;
        *) return 1 ;;
    esac
}

case_from_platform() {
    case "${1}" in
        P1) printf '0.0.10\n' ;;
        P2) printf '0.0.11\n' ;;
        D1 | D2 | U1 | U2) printf '0.0.12\n' ;;
        *) return 1 ;;
    esac
}

case_to_platform() {
    case "${1}" in
        P1) printf '0.0.11\n' ;;
        P2) printf '0.0.12\n' ;;
        D1 | D2 | U1 | U2) printf '0.0.12\n' ;;
        *) return 1 ;;
    esac
}

case_payload() { # the payload file the hop carries, in PAYLOAD_DIR
    case "${1}" in
        P1) printf 'payload-0.0.11.tar\n' ;;
        P2) printf 'payload-0.0.12.tar\n' ;;
        D1 | U1) printf 'payload-25.12.1.tar\n' ;;
        D2) printf 'payload-25.12.0.tar\n' ;;
        U2) printf 'payload-25.12.2.tar\n' ;;
        *) return 1 ;;
    esac
}

case_step() { # 1-based position in the chain
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
# lands in. After a downgrade the fallback is the newer rootfs; after an upgrade, the older.
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

# same_base <case>: a hop whose payload carries the base the machine already runs. Only
# those can meet the already-installed guard, so only those may spend --force.
same_base() {
    [ "$(case_from_rootfs "${1}")" = "$(case_to_rootfs "${1}")" ]
}

# hop_expect <case>: the one description of what the hop must do and end in.
# hop_expect_value <case> <key> reads a field out of it, so an assertion cannot promise
# something the plan does not print.
hop_expect() {
    _c=${1:?hop_expect needs a case}
    _kind=$(case_kind "${_c}") || return 2
    _step=$(case_step "${_c}") || return 2
    _total=$(printf '%s\n' ${CHAIN} | wc -l | tr -d ' ')
    if [ "${_kind}" = "release" ]; then
        printf 'step=%s/%s kind=release direction=none tag=%s version=%s assets=%s verifier=%s\n' \
            "${_step}" "${_total}" "${RELEASE_TAG}" "${RELEASE_VERSION}" \
            "${RELEASE_DIR:-unset}" "$(basename "${RELEASE_VERIFY}")"
        return 0
    fi
    _from=$(case_from_rootfs "${_c}") || return 2
    _to=$(case_to_rootfs "${_c}") || return 2
    _force=none
    _regression=none
    if same_base "${_c}"; then
        _force=on-refusal
    fi
    # What round 1 measured on the v0.0.10 image, stated before the hop runs: that release
    # guards on the base alone, so its own platform-only hop was refused. Later platform
    # hops on a machine that already runs the fixed guard are not expected to be refused.
    case "${_c}" in
        P1) _regression=payload-already-installed ;;
    esac
    printf 'step=%s/%s kind=%s direction=%s from-rootfs=%s to-rootfs=%s from-platform=%s to-platform=%s rollback=%s payload=%s force=%s regression=%s\n' \
        "${_step}" "${_total}" "${_kind}" "$(direction_of "${_from}" "${_to}")" \
        "${_from}" "${_to}" "$(case_from_platform "${_c}")" "$(case_to_platform "${_c}")" \
        "$(relation_of "${_to}" "${_from}")" "$(case_payload "${_c}")" "${_force}" "${_regression}"
}

hop_expect_value() { # <case> <key>
    hop_expect "${1}" | tr ' ' '\n' | sed -n "s/^${2:?hop_expect_value needs a key}=//p" | head -n 1
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

# check_payload_line <case> <path>: refuse a payload this round may not walk, before
# anything is written.
#
# 24.x is opkg-era: a different package manager, firewall model and kernel-module layout,
# so a verdict from it says nothing about this product, and `require_supported_line`
# (lib.sh) is the one place that rule is written. A payload named after a platform release
# (0.0.x) is equally out of place on a base hop: the chain would install a rootfs nobody
# described. Both are refused here, with no ssh.
check_payload_line() {
    _c=${1:?check_payload_line needs a case}
    _p=${2:?check_payload_line needs a payload path}
    _name=${_p##*/}
    _v=$(printf '%s\n' "${_name}" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9]*$/\1/p')
    if [ -z "${_v}" ]; then
        printf 'unsupported payload name: %s carries no version this matrix can read (want payload-<version>.tar or n5105-ab-<base>-upgrade.tar)\n' \
            "${_name}"
        return 1
    fi
    case "${_v}" in
        0.*)
            if [ "$(case_kind "${_c}")" != "platform" ]; then
                printf 'unsupported payload line: %s is a platform payload, but %s is a %s hop; a base hop installs a base\n' \
                    "${_v}" "${_c}" "$(case_kind "${_c}")"
                return 1
            fi
            printf 'supported platform payload: %s\n' "${_v}"
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
# Same two red lines as matrix.sh, restated because that file is a driver and not a
# library: the running slot must be the committed one, and both boot= and esp= are facts a
# machine cannot claim without evidence.
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
# Drift: the config the user owns and the packages the machine carries
# --------------------------------------------------------------------------- #

# packages_snapshot <out>: the installed packages, written in the snapshot format
# devcfg_diff already compares, so "did the package set move across this hop" is answered
# by the same comparator as the config drift and not by a second one.
#   <package-name>  ok  <version>  -
# The third column carries the version where a config snapshot carries a hash: a package's
# identity is its name and what moves is its version. The split is on the last dash, done
# the same way on both sides of a hop, so a package whose own name ends in digits still
# compares against itself.
packages_snapshot() {
    _out=${1:?packages_snapshot needs an output path}
    _raw=$(devcfg_tmpfile) || return 3
    if ! dev_ssh 'apk list --installed 2>/dev/null' >"${_raw}" 2>/dev/null; then
        rm -f "${_raw}"
        return 1
    fi
    if [ ! -s "${_raw}" ]; then
        rm -f "${_raw}"
        return 1
    fi
    LC_ALL=C awk 'NF {
        name = $1
        sub(/-[^-]*$/, "", name)
        ver = $1
        sub(/^.*-/, "", ver)
        if (name != "" && ver != "" && ver != $1) printf "%s\tok\t%s\t-\n", name, ver
    }' "${_raw}" | LC_ALL=C sort -u >"${_out}"
    rm -f "${_raw}"
    return 0
}

# snapshot_boundary <tag>: one boundary of the chain - the config and the package list.
_snapshot_boundary() {
    _tag=${1:?_snapshot_boundary needs a tag}
    SNAP_CFG="${EVIDENCE_DIR}/${_tag}.cfg.tsv"
    SNAP_PKG="${EVIDENCE_DIR}/${_tag}.pkg.tsv"
    devcfg_snapshot "${SNAP_CFG}" ${CONFIG_PATHS} >/dev/null 2>&1
    _cfg_rc=$?
    # rc 1 means "at least one file is not there", which is a state and not a failure.
    [ "${_cfg_rc}" -le 1 ] || ev "config snapshot ${_tag}: devcfg_snapshot exited ${_cfg_rc}"
    packages_snapshot "${SNAP_PKG}" || ev "package snapshot ${_tag}: apk list --installed answered nothing"
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

# hop_run <case>: 0 PASS, 1 FAIL, 2 GAP (payload missing, refused as out of scope).
hop_run() {
    _case=${1:?hop_run needs a case}
    CASE_NOTE=""
    CASE_REGRESSION=""
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
        CASE_NOTE="chain broken: the machine runs ${_running:-unknown}, this hop starts from ${_from}; resume with --from ${_case}"
        ev "${CASE_NOTE}"
        return 1
    fi
    ev "hop ${_case}: ${_from} -> ${_to} (${_dir}); slot ${_slot}, target ${_target}, generation ${_gen}"

    _remote="${AB_REMOTE_TMP}/${_local##*/}"
    dev_ssh 'ab-slot gc' >/dev/null 2>&1 || ev "gc reported problems (not a hop failure)"
    if ! dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" >/dev/null; then
        CASE_NOTE="the payload could not be pushed to ${_remote}"
        ev "${CASE_NOTE}"
        return 1
    fi
    # ab-upgrade --check is not read-only: it publishes ab/conflicts.log and may leave
    # p2/p3 mounted. The hop therefore starts from a clean mount state and says so; nothing
    # later asserts those mounts are absent, because they legitimately reappear.
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    _force=0
    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    case "${_rc}" in
        0)
            if same_base "${_case}"; then
                CASE_REGRESSION=not-refused
                ev "regression: the payload for the running base was accepted without --force (the platform-only guard is in the running release)"
            fi
            ;;
        74)
            case "${_out}" in
                *payload-already-installed*)
                    if ! same_base "${_case}"; then
                        CASE_NOTE="refused a cross-base payload with exit 74 payload-already-installed, which no hop of this chain may be"
                        ev "${CASE_NOTE}"
                        return 1
                    fi
                    _force=1
                    CASE_REGRESSION=refused-payload-already-installed
                    ev "regression: refused with exit 74 payload-already-installed; installing with --force, the flag the refusal names"
                    ;;
                *)
                    CASE_NOTE="refused with exit 74 for another reason: $(printf '%s\n' "${_out}" | grep -m 1 'refused' || printf 'no refusal line')"
                    ev "${CASE_NOTE}"
                    return 1
                    ;;
            esac
            ;;
        *)
            CASE_NOTE="ab-upgrade --check exited ${_rc}: $(printf '%s\n' "${_out}" | tail -n 1)"
            ev "${CASE_NOTE}"
            return 1
            ;;
    esac

    if [ "${_force}" = "1" ]; then
        _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ssh "ab-upgrade --yes --force ${_remote}")
    else
        _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}")
    fi
    if [ "$?" -ne 0 ]; then
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
    # The direction is judged from the numbers, so a hop described as "down" that landed
    # higher is red here rather than being retold by the note.
    _check assert_value "$(direction_of "${_from}" "${_running_now}")" "${_dir}" "${_case}" direction
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_to}")(-r[0-9]+)?\$" "${_case}" upper

    # Drift is measured on every hop, including a red one: the two snapshots are the only
    # record of what the payload did to the config the user owns.
    _prev_cfg=${SNAP_CFG}
    _prev_pkg=${SNAP_PKG}
    _snapshot_boundary "post-${_case}"
    _drift config "${_prev_cfg}" "${SNAP_CFG}"
    DRIFT_CFG=${DRIFT}
    _drift packages "${_prev_pkg}" "${SNAP_PKG}"
    DRIFT_PKG=${DRIFT}

    _gen_now=$(status_field "${_booted}" generation) || _gen_now="?"
    _pkg_now=$(status_field "${_booted}" packages) || _pkg_now="?"
    if [ "${HOP_FAILED}" -eq 0 ]; then
        _force_used=none
        [ "${_force}" = "1" ] && _force_used=used
        CASE_NOTE="hop ok: platform $(case_from_platform "${_case}")->$(case_to_platform "${_case}"), base ${_from}->${_to} (${_dir}), committed ${_target}, generation ${_gen}->${_gen_now}, packages=${_pkg_now}; regression=${CASE_REGRESSION:-none}, force=${_force_used}; config-drift=${DRIFT_CFG}; pkg-drift=${DRIFT_PKG}"
        ev "${CASE_NOTE}"
        return 0
    fi
    # The evidence lines are timestamped, so the case name is matched anywhere in the line.
    _first_fail=$(grep -m 1 "FAIL ${_case} " "${AB_EVIDENCE_LOG}" 2>/dev/null) || _first_fail=""
    CASE_NOTE="assertions failed on this hop: ${_first_fail#FAIL ${_case} }; the chain stops here; config-drift=${DRIFT_CFG}; pkg-drift=${DRIFT_PKG}"
    ev "${CASE_NOTE}"
    return 1
}

# --------------------------------------------------------------------------- #
# The release-byte case (REL): the v0.0.12 assets against their own index.txt
#
# Offline by construction. release-verify.sh --dir already answers this question - every
# line of SHA256SUMS against the bytes beside it, and the entry's payload digest against
# the asset the release publishes - so the case runs it rather than writing a second
# comparison that could disagree with the script the release is verified with.
# --------------------------------------------------------------------------- #

release_run() {
    _case=${1:?release_run needs a case}
    CASE_NOTE=""
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/${_case}.log"
    AB_MATRIX_CMD="$0 --only ${_case}"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"

    if [ ! -f "${RELEASE_VERIFY}" ]; then
        CASE_NOTE="no ${RELEASE_VERIFY}: the release bytes cannot be checked"
        ev "${CASE_NOTE}"
        return 2
    fi
    if [ -z "${RELEASE_DIR}" ] || [ ! -d "${RELEASE_DIR}" ]; then
        CASE_NOTE="no asset directory for ${RELEASE_TAG} (got '${RELEASE_DIR:-unset}'); fetch it with: gh release download ${RELEASE_TAG} --dir <dir>, then rerun with --release-dir <dir>"
        ev "${CASE_NOTE}"
        return 2
    fi

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" sh "${RELEASE_VERIFY}" \
        --tag "${RELEASE_TAG}" --version "${RELEASE_VERSION}" --dir "${RELEASE_DIR}")
    _rc=$?
    case "${_rc}" in
        0)
            CASE_NOTE="release bytes match index.txt: $(printf '%s\n' "${_out}" | grep -m 1 '^release-verify result=' || printf 'release-verify result=pass')"
            ev "${CASE_NOTE}"
            return 0
            ;;
        1)
            # The first check that failed, not the summary: the row has to name which
            # comparison disagreed with the bytes.
            CASE_NOTE="release bytes do not match index.txt: $(printf '%s\n' "${_out}" | grep -m 1 'result=fail' || printf 'release-verify result=fail')"
            ev "${CASE_NOTE}"
            return 1
            ;;
        3)
            CASE_NOTE="no verdict on ${RELEASE_TAG}: $(printf '%s\n' "${_out}" | grep -m 1 'result=none' || printf 'release-verify result=none')"
            ev "${CASE_NOTE}"
            return 2
            ;;
        *)
            CASE_NOTE="release-verify exited ${_rc} on ${RELEASE_TAG}: $(printf '%s\n' "${_out}" | tail -n 1)"
            ev "${CASE_NOTE}"
            return 1
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Selection, and the plan
# --------------------------------------------------------------------------- #

select_cases() {
    if [ -n "${ONLY_CASE}" ]; then
        case_step "${ONLY_CASE}" >/dev/null || {
            printf 'matrix-round2: unknown case: %s (want one of: %s)\n' "${ONLY_CASE}" "${CHAIN}" >&2
            return 2
        }
        printf '%s\n' "${ONLY_CASE}"
        return 0
    fi
    if [ -z "${FROM_STEP}" ]; then
        printf '%s\n' "${CHAIN}"
        return 0
    fi
    _started=0
    _out=""
    for _c in ${CHAIN}; do
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
        printf 'matrix-round2: --from %s is not a step of this chain (1..%s or a case id)\n' \
            "${FROM_STEP}" "$(printf '%s\n' ${CHAIN} | wc -l | tr -d ' ')" >&2
        return 2
    fi
    printf '%s\n' "${_out# }"
}

# plan_case <case>: what the hop will do, printed and not done.
plan_case() {
    _case=${1:?plan_case needs a case}
    _kind=$(case_kind "${_case}") || return 2
    printf '# %s %s\n' "${_case}" "$(hop_expect "${_case}")"
    if [ "${_kind}" = "release" ]; then
        printf '%s verify %s --tag %s --version %s --dir %s (every SHA256SUMS line against the bytes, and the payload digest against index.txt; no ssh)\n' \
            "${_case}" "${RELEASE_VERIFY}" "${RELEASE_TAG}" "${RELEASE_VERSION}" "${RELEASE_DIR:-<release-dir>}"
        printf '%s record\n' "${_case}"
        return 0
    fi
    _local=$(hop_payload_path "${_case}") || return 1
    if [ ! -f "${_local}" ]; then
        printf '# warning: no payload at %s; the run would record GAP\n' "${_local}"
    fi
    _to=$(case_to_rootfs "${_case}")
    printf '%s status (red line: a committed slot, boot=ok, esp=ok, pending=none)\n' "${_case}"
    printf '%s gc\n' "${_case}"
    printf '%s push %s -> %s/%s\n' "${_case}" "${_local}" "${AB_REMOTE_TMP}" "${_local##*/}"
    if same_base "${_case}"; then
        printf '%s check %s/%s expect=exit-0, or exit-74 payload-already-installed (the v0.0.10 image did that; recorded as a regression and reinstalled with --force)\n' \
            "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
        printf '%s install %s/%s with --force when the check refused with payload-already-installed\n' \
            "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    else
        printf '%s check %s/%s expect=exit-0, any refusal is a FAIL\n' "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
        printf '%s install %s/%s\n' "${_case}" "${AB_REMOTE_TMP}" "${_local##*/}"
    fi
    printf '%s reboot, then wait_up %ss, then settle until boot=ok pending=none\n' \
        "${_case}" "${AB_WAIT_UP_FIRST}"
    printf '%s assert boot=ok esp=ok pending=none committed=<the slot that is not running> generation>=+1 packages=aligned rootfs=%s upper=@overlay-%s(-rN)? direction=%s rollback=%s\n' \
        "${_case}" "${_to}" "${_to}" "$(hop_expect_value "${_case}" direction)" \
        "$(hop_expect_value "${_case}" rollback)"
    printf '%s assert the stable fields did not move: %s\n' "${_case}" "${AB_STATUS_FIELDS_STABLE}"
    printf '%s snapshot %s and diff against the previous boundary (config drift recorded, not judged)\n' \
        "${_case}" "${CONFIG_PATHS}"
    printf '%s snapshot apk list --installed and diff ditto (package drift recorded, not judged)\n' "${_case}"
    printf '%s record\n' "${_case}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

SELECTED=$(select_cases) || exit 2

if [ "${DRY_RUN}" = "1" ]; then
    for _case in ${SELECTED}; do
        plan_case "${_case}" || exit 2
    done
    exit 0
fi

# Every case writes its evidence before it decides anything, so the directory is made
# once here - the release case included, which runs on a machine-less host.
mkdir -p "${EVIDENCE_DIR}" || {
    printf 'matrix-round2: cannot create %s\n' "${EVIDENCE_DIR}" >&2
    exit 2
}

_hops=""
_want_release=0
for _case in ${SELECTED}; do
    case "$(case_kind "${_case}")" in
        release) _want_release=1 ;;
        *) _hops="${_hops} ${_case}" ;;
    esac
done
_hops=${_hops# }

_passed=0
_failed=0
_gapped=0

if [ -n "${_hops}" ]; then
    # The payloads are judged before the machine is touched: a 24.x payload or a platform
    # payload on a base hop is a scope violation, and discovering it after a failed boot
    # would look like a product defect.
    PREFLIGHT_CASE=""
    PREFLIGHT_NOTE=""
    PREFLIGHT_VERDICT=""
    _preflight_rc=0
    for _case in ${_hops}; do
        _p=$(hop_payload_path "${_case}") || {
            PREFLIGHT_CASE=${_case}
            PREFLIGHT_VERDICT=FAIL
            PREFLIGHT_NOTE="no payload name for ${_case}"
            _preflight_rc=1
            break
        }
        if [ ! -f "${_p}" ]; then
            PREFLIGHT_CASE=${_case}
            PREFLIGHT_VERDICT=GAP
            PREFLIGHT_NOTE="no payload at ${_p} (build it, or pass --payload ${_case}=<path>)"
            _preflight_rc=2
            break
        fi
        if ! _msg=$(check_payload_line "${_case}" "${_p}" 2>&1); then
            PREFLIGHT_CASE=${_case}
            PREFLIGHT_VERDICT=FAIL
            PREFLIGHT_NOTE=${_msg}
            _preflight_rc=1
            break
        fi
    done
    if [ "${_preflight_rc}" -ne 0 ]; then
        printf '== %s (refused before any machine was touched)\n' "${PREFLIGHT_CASE}"
        record "${PREFLIGHT_CASE}" "${PREFLIGHT_VERDICT}" - "${PREFLIGHT_NOTE}"
        printf '   %s: %s\n' "${PREFLIGHT_CASE}" "${PREFLIGHT_NOTE}"
        [ "${PREFLIGHT_VERDICT}" = "GAP" ] && exit 4
        exit 1
    fi

    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/00-baseline.log"
    AB_MATRIX_CMD="$0"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"
    # Baseline: the chain may only start from a machine that can fall back, and the
    # boundaries before the first hop are what every later drift is measured against.
    require_healthy "${_hops%% *}"
    AB_STATUS_LINE=${STATUS_LINE}
    ev "baseline: ${STATUS_LINE}"
    ev "baseline: config paths ${CONFIG_PATHS}"
    _snapshot_boundary pre

    for _case in ${_hops}; do
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
fi

if [ "${_want_release}" = "1" ]; then
    # A directory, not a machine: this case still runs when a hop stopped the chain, and
    # the run's exit status stays the hop's.
    printf '== REL %s\n' "kind=release tag=${RELEASE_TAG} assets=${RELEASE_DIR:-unset}"
    release_run REL
    _rc=$?
    case "${_rc}" in
        0)
            record REL PASS "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _passed=$((_passed + 1))
            ;;
        2)
            record REL GAP "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _gapped=$((_gapped + 1))
            ;;
        *)
            record REL FAIL "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _failed=$((_failed + 1))
            ;;
    esac
    printf '   REL: %s (%s)\n' "${CASE_NOTE}" "${AB_EVIDENCE_LOG}"
fi

printf '\nmatrix-round2: passed=%s failed=%s gap=%s results=%s\n' \
    "${_passed}" "${_failed}" "${_gapped}" "${AB_RESULTS}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
exit 0
