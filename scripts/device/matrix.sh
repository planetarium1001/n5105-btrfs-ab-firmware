#!/bin/sh
# Matrix driver for the 25.x version cases: M1-M7.
#
# One case is one path through the A/B state machine, and one verdict. The skeleton
# of a hop never changes:
#
#   status -> gc -> unmount /mnt/slots/* -> push payload -> ab-upgrade --check ->
#   ab-upgrade -> reboot -> wait_up -> settle -> status -> collect boot logs -> assert
#   -> record
#
# Everything a hop asserts is mechanical: fields of `ab-slot status`, the breadcrumbs
# the new boot wrote itself (searching the rotated ring log, not one fixed file), the
# two markers the user's state lives in, and the layer invariant on the writable
# partition (every slot's upper exists, no unreferenced @overlay-* survives). "It looks
# like it came up" is never a verdict.
#
#   scripts/device/matrix.sh                       # M1..M7, all of them
#   scripts/device/matrix.sh --case M3 --case M4   # two cases
#   scripts/device/matrix.sh --resume              # skip cases that already PASS
#   scripts/device/matrix.sh --dry-run             # print the steps, touch nothing
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run because its payload is missing (GAP).
#
# Red lines, enforced in code and not in a checklist:
#   * a destructive step is only ever aimed at the slot that is not committed, so the
#     running slot must equal the committed slot and no candidate may be queued
#     (require_safe_target);
#   * any moment without a committed slot that booted and mounted the ESP cleanly
#     stops the whole run with a non-zero exit before anything else is written
#     (require_healthy_committed -> _red_line);
#   * ab/state.json is never written here. Slot state moves only through ab-slot and
#     ab-upgrade, which hold the ESP lock and keep the GRUB hint in step.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

CASES_ALL="M1 M2 M3 M4 M5 M6 M7"

PAYLOAD_DIR=${AB_PAYLOAD_DIR:-payloads}
RESULTS=${AB_RESULTS:-results.tsv}
EVIDENCE_DIR=${AB_EVIDENCE_DIR:-}
WANT_CASES=""
RESUME=0
DRY_RUN=0
CASE_NOTE=""
HOP_FAILED=0
STATUS_LINE=""

usage() {
    cat <<'USAGE'
usage: matrix.sh [--case M1..M7]... [--payload-dir DIR] [--results FILE]
                 [--evidence-dir DIR] [--resume] [--dry-run]

  --case M1..M7      case to run, repeatable; default is all seven
  --payload-dir DIR  directory holding payload-<version>.tar (default: payloads)
  --results FILE     results.tsv to append to (default: results.tsv)
  --evidence-dir DIR evidence directory (default: <results dir>/evidence)
  --resume           skip a case that already has a PASS row in the results file
  --dry-run          print the step sequence and exit; no ssh call is made
USAGE
}

while [ $# -gt 0 ]; do
    case "${1}" in
        --case)
            WANT_CASES="${WANT_CASES} ${2:?--case needs a value}"
            shift 2
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a value}
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
        --resume)
            RESUME=1
            shift
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
            printf 'matrix: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "${WANT_CASES}" ] || WANT_CASES=${CASES_ALL}
AB_RESULTS=${RESULTS}
[ -n "${EVIDENCE_DIR}" ] || EVIDENCE_DIR=$(dirname "${AB_RESULTS}")/evidence
AB_EVIDENCE_LOG=""

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: the planner below prints instead of acting, and every ssh
    # helper would refuse anyway.
    AB_DRY_RUN=1
fi
export AB_DRY_RUN AB_RESULTS AB_EVIDENCE_LOG AB_MATRIX_CMD

# --------------------------------------------------------------------------- #
# The case table
# --------------------------------------------------------------------------- #

# case_path <case>: the versions the case walks through. The first one is the state
# the case must start in; every later one is installed and must commit.
case_path() {
    case "${1}" in
        # Stepwise upgrade: two small steps, so each step's commit is observed on its own.
        M1) printf '25.12.0 25.12.1 25.12.2' ;;
        # Version-skipping upgrade: skip the middle version; uci/procd migration has one chance.
        M2) printf '25.12.0 25.12.2' ;;
        # Minor downgrade: ab-upgrade compares for difference, not for order.
        M3) printf '25.12.2 25.12.1' ;;
        # Version-skipping downgrade: the worst direction; the committed slot has to survive it.
        M4) printf '25.12.2 25.12.0' ;;
        # Same-version reinstall: record what the machine does today (payload-already-installed).
        M5) printf '25.12.2 25.12.2' ;;
        # Long chain: six changes of direction including two downgrades.
        M6) printf '25.12.0 25.12.1 25.12.2 25.12.1 25.12.2 25.12.1 25.12.2' ;;
        # Bad payload: a payload with a broken member digest must be refused, not written.
        M7) printf 'bad' ;;
        *) return 1 ;;
    esac
}

path_label() {
    _label=""
    for _v in ${1}; do
        if [ -z "${_label}" ]; then
            _label=${_v}
        else
            _label="${_label}->${_v}"
        fi
    done
    printf '%s\n' "${_label}"
}

other_slot() {
    case "${1}" in
        a) printf 'b' ;;
        b) printf 'a' ;;
        *) return 1 ;;
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

# require_healthy_committed <case>: sets STATUS_LINE, or stops the run here.
# The line comes back through a variable, not through stdout: a command substitution
# runs in a subshell, and the exit that is the whole point of the red line would then
# only leave the subshell instead of stopping the matrix.
# boot= and esp= are the two facts a machine cannot claim without evidence.
require_healthy_committed() {
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

# require_safe_target <case> <status_line>: the install must land on the inactive slot.
# ab-upgrade writes the slot it is not running, so the committed layer is only out of
# reach while the running slot is the committed one and no candidate is queued.
require_safe_target() {
    _case=${1:-?}
    _line=${2:-}
    _slot=$(status_field "${_line}" slot) || _slot=""
    _committed=$(status_field "${_line}" committed) || _committed=""
    _pending=$(status_field "${_line}" pending) || _pending=""
    [ "${_slot}" = "${_committed}" ] \
        || _red_line "${_case}" "running slot ${_slot:-?} is not the committed slot ${_committed:-?}: an install would overwrite the only healthy slot"
    if [ "${_pending}" != "none" ]; then
        printf 'unsafe target [%s]: pending=%s is already queued, resolve it before installing\n' \
            "${_case}" "${_pending:-?}" >&2
        ev "unsafe target: pending=${_pending:-?}"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Assertions that must all run
# --------------------------------------------------------------------------- #

# One red hop should report every broken invariant, not just the first, so the
# assertions are collected and the verdict is the aggregate.
_check() {
    "$@" || HOP_FAILED=1
}

# assert_boot_health <case> <generation_floor>: fields of the captured status line.
assert_boot_health() {
    _case=$1
    _gen_floor=$2
    _check assert_field boot ok "${_case}"
    _check assert_field esp ok "${_case}"
    _check assert_field pending none "${_case}"
    _check assert_ge "$(status_field "${AB_STATUS_LINE:-}" generation || printf 0)" "${_gen_floor}" "${_case}" generation
}

# assert_boot_log is in lib.sh: it has to search the rotated ring log and is therefore
# shared with the unit tests rather than living in the orchestrator.

# assert_markers <case> <marker_before> <config_before>: user state survived the hop.
assert_markers() {
    _case=$1
    _marker_before=$2
    _config_before=$3
    _marker_after=$(dev_marker_read)
    _check assert_match "${_marker_after}" '.' "${_case}" data-marker-present
    _check assert_value "${_marker_after}" "${_marker_before}" "${_case}" data-marker
    _check assert_value "$(dev_config_marker)" "${_config_before}" "${_case}" config-marker
}

# --------------------------------------------------------------------------- #
# One hop
# --------------------------------------------------------------------------- #

# hop_install <case> <version> <phase>
#   phase=position  bring the machine to the version the case starts in; not a result
#   phase=ladder    a step under test
# Returns 0 ok, 1 a step or an assertion failed, 2 the payload is missing (GAP),
# 20 the machine refused the payload before writing anything (exit 74).
hop_install() {
    _case=$1
    _version=$2
    _phase=$3
    _local="${PAYLOAD_DIR}/payload-${_version}.tar"
    _remote="${AB_REMOTE_TMP}/payload-${_version}.tar"

    if [ ! -f "${_local}" ]; then
        ev "payload missing: ${_local}"
        return 2
    fi

    require_healthy_committed "${_case}" || return 1
    _before=${STATUS_LINE}
    require_safe_target "${_case}" "${_before}" || return 1
    AB_STATUS_LINE=${_before}
    _gen_before=$(status_field "${_before}" generation) || return 1
    _slot_before=$(status_field "${_before}" slot) || return 1
    _target=$(other_slot "${_slot_before}") || return 1
    _marker_before=$(dev_marker_read)
    _config_before=$(dev_config_marker)

    ev "${_phase} ${_version}: slot ${_slot_before} generation ${_gen_before}, target ${_target}"
    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" || return 1

    # ab-upgrade --check is not read-only: it publishes ab/conflicts.log on the ESP and
    # may leave p2/p3 mounted under /mnt/slots/<slot> (measured). The hop therefore
    # starts from a clean mount state and says so in the evidence, and nothing later
    # asserts that no such mount reappeared, because it legitimately does.
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"

    # A payload that cannot be validated is reported as what it is: for M7 a refusal
    # is the pass, for every other case it is a failed step.
    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    case "${_rc}" in
        0) : ;;
        74)
            ev "ab-upgrade --check refused the payload (exit 74)"
            printf '%s\n' "${_out}"
            return 20
            ;;
        *)
            ev "ab-upgrade --check failed with exit ${_rc}"
            printf '%s\n' "${_out}"
            return 1
            ;;
    esac

    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_install "${_remote}") || return 1

    _after=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || return 1
    AB_STATUS_LINE=${_after}
    HOP_FAILED=0
    _check assert_field pending "${_target}" "${_case}"
    _check assert_ge "$(status_field "${_after}" generation || printf 0)" "$((_gen_before + 1))" "${_case}" generation
    [ "${HOP_FAILED}" -eq 0 ] || return 1

    dev_reboot
    # The first boot of a new rootfs gets the longer budget: that boot also writes the
    # ESP, runs btrfs-check and runs gc before it commits.
    if ! dev_wait_up_after after-install; then
        ev "wait_up: no answer within ${AB_WAIT_UP_FIRST}s after reboot (hard cap ${AB_WAIT_UP_HARD}s)"
        return 1
    fi

    # wait_up returns when dropbear answers; the commit is written a moment later, so the
    # hop waits for boot=ok pending=none before it reads the status line or the log.
    if ! _booted=$(dev_capture "${AB_EVIDENCE_LOG}" dev_wait_settled "${AB_WAIT_SETTLE}"); then
        ev "settle: no status line within ${AB_WAIT_SETTLE}s after the machine answered ssh"
        return 1
    fi
    AB_STATUS_LINE=${_booted}
    # Both files of the ring log are collected, and a missing one is normal rather than an
    # error: boot-1.log does not exist on a machine that has booted once, and boot-0.log is
    # the one that is still being written. Which file carried the breadcrumb is decided by
    # assert_boot_log and recorded in the evidence.
    _log_base="${AB_EVIDENCE_LOG%.log}-boot-${_version}"
    AB_BOOT_LOG_LOCAL="${_log_base}-0.log"
    AB_BOOT_LOG_PREV_LOCAL="${_log_base}-1.log"
    dev_capture "${AB_EVIDENCE_LOG}" dev_collect_optional "${AB_BOOT_LOG}" "${AB_BOOT_LOG_LOCAL}" \
        || ev "boot log not collected: ${AB_BOOT_LOG}"
    dev_capture "${AB_EVIDENCE_LOG}" dev_collect_optional "${AB_BOOT_LOG_PREV}" "${AB_BOOT_LOG_PREV_LOCAL}" \
        || ev "previous boot log not collected: ${AB_BOOT_LOG_PREV} (normal on a machine that booted once)"

    HOP_FAILED=0
    assert_boot_health "${_case}" "$((_gen_before + 1))"
    _check assert_field slot "${_target}" "${_case}"
    _check assert_field committed "${_target}" "${_case}"
    _check assert_match "$(status_field "${_booted}" upper || printf '')" \
        "^@overlay-$(dev_version_re "${_version}")(-r[0-9]+)?\$" "${_case}" upper
    _check assert_boot_log "${_case}" "${_version}"
    assert_markers "${_case}" "${_marker_before}" "${_config_before}"
    dev_layer_state
    _check assert_layer_invariant "${_case}"
    # A count is only a hint now: a repeated version adds a -rN layer, so a healthy
    # steady state can be three or four layers, and two can also be a leak.
    _layer_n=$(printf '%s' "${AB_LAYERS}" | wc -w | tr -d ' ')
    [ "${_layer_n}" = "${AB_LAYER_COUNT}" ] \
        || ev "layer-count hint: ${_layer_n} layers (not ${AB_LAYER_COUNT}); the invariant above is what was asserted"

    if [ "${HOP_FAILED}" -eq 0 ]; then
        ev "${_phase} ${_version}: ok, slot ${_target}, generation $((_gen_before + 1))"
        return 0
    fi
    ev "${_phase} ${_version}: assertions failed"
    return 1
}

# --------------------------------------------------------------------------- #
# Cases
# --------------------------------------------------------------------------- #

# run_bad_payload <case>: M7. The payload's member digest is broken on purpose, so
# the only correct outcome is a refusal before anything was written.
run_bad_payload() {
    _case=$1
    _local="${PAYLOAD_DIR}/payload-bad.tar"
    _remote="${AB_REMOTE_TMP}/payload-bad.tar"
    if [ ! -f "${_local}" ]; then
        CASE_NOTE="no bad payload at ${_local}"
        return 2
    fi

    require_healthy_committed "${_case}" || return 1
    _before=${STATUS_LINE}
    require_safe_target "${_case}" "${_before}" || return 1
    AB_STATUS_LINE=${_before}
    _gen=$(status_field "${_before}" generation) || return 1
    _committed=$(status_field "${_before}" committed) || return 1
    _pending=$(status_field "${_before}" pending) || return 1
    _upper=$(status_field "${_before}" upper) || return 1

    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" || return 1
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"
    # A payload refused at the structure stage exits before the conflict scan, so this
    # --check touches nothing at all; the assertions below are about slot state, and the
    # ESP is deliberately not checked for changes (a --check that exits 0 writes
    # ab/conflicts.log by design).
    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?
    _after=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || return 1
    AB_STATUS_LINE=${_after}

    HOP_FAILED=0
    _check assert_value "${_rc}" 74 "${_case}" check-exit
    _check assert_match "${_out}" 'refused, reason=' "${_case}" refusal-line
    _check assert_value "$(status_field "${_after}" generation || printf 'x')" "${_gen}" "${_case}" generation
    _check assert_value "$(status_field "${_after}" committed || printf 'x')" "${_committed}" "${_case}" committed
    _check assert_value "$(status_field "${_after}" pending || printf 'x')" "${_pending}" "${_case}" pending
    _check assert_value "$(status_field "${_after}" upper || printf 'x')" "${_upper}" "${_case}" upper
    ev "refusal: $(printf '%s' "${_out}" | grep -m 1 'refused' || printf 'no refusal line')"
    [ "${HOP_FAILED}" -eq 0 ] || return 1
    CASE_NOTE="refused with exit 74, slot state unchanged"
    return 0
}

# run_same_version <case>: M5. Records what the machine does today; a refusal is the
# documented behaviour, and a machine that instead reinstalls is walked as a hop.
run_same_version() {
    _case=$1
    _version=$2
    _local="${PAYLOAD_DIR}/payload-${_version}.tar"
    _remote="${AB_REMOTE_TMP}/payload-${_version}.tar"
    if [ ! -f "${_local}" ]; then
        CASE_NOTE="no payload at ${_local}"
        return 2
    fi

    require_healthy_committed "${_case}" || return 1
    _before=${STATUS_LINE}
    require_safe_target "${_case}" "${_before}" || return 1
    AB_STATUS_LINE=${_before}
    _gen=$(status_field "${_before}" generation) || return 1
    _committed=$(status_field "${_before}" committed) || return 1
    _pending=$(status_field "${_before}" pending) || return 1

    dev_capture "${AB_EVIDENCE_LOG}" dev_push "${_local}" "${_remote}" || return 1
    dev_capture "${AB_EVIDENCE_LOG}" dev_cleanup_slot_mounts >/dev/null
    ev "pre-check: /mnt/slots/* unmounted; --check may remount them, so their absence is not asserted"
    _out=$(dev_capture "${AB_EVIDENCE_LOG}" dev_ab_check "${_remote}")
    _rc=$?

    if [ "${_rc}" = "0" ]; then
        # The machine accepts reinstalling the version it runs. That is the finding;
        # walk the transaction so the row carries what actually happened. This --check
        # already rewrote ab/conflicts.log on the ESP, which is why the hop does not
        # claim the ESP was untouched -- only slot state is asserted.
        hop_install "${_case}" "${_version}" ladder || return 1
        CASE_NOTE="same-version reinstall accepted; hop committed"
        return 0
    fi

    _after=$(dev_capture "${AB_EVIDENCE_LOG}" dev_status) || return 1
    AB_STATUS_LINE=${_after}
    HOP_FAILED=0
    _check assert_value "${_rc}" 74 "${_case}" check-exit
    _check assert_match "${_out}" 'payload-already-installed' "${_case}" refusal-reason
    _check assert_value "$(status_field "${_after}" generation || printf 'x')" "${_gen}" "${_case}" generation
    _check assert_value "$(status_field "${_after}" committed || printf 'x')" "${_committed}" "${_case}" committed
    _check assert_value "$(status_field "${_after}" pending || printf 'x')" "${_pending}" "${_case}" pending
    [ "${HOP_FAILED}" -eq 0 ] || return 1
    CASE_NOTE="refused with exit 74 payload-already-installed, slot state unchanged"
    return 0
}

# run_case <case>: 0 PASS, 1 FAIL, 2 GAP; the note for the row lands in CASE_NOTE.
run_case() {
    _case=$1
    CASE_NOTE=""
    _path=$(case_path "${_case}") || {
        CASE_NOTE="unknown case"
        return 1
    }
    mkdir -p "${EVIDENCE_DIR}" || {
        CASE_NOTE="cannot create ${EVIDENCE_DIR}"
        return 1
    }
    AB_EVIDENCE_LOG="${EVIDENCE_DIR}/$(date -u +%Y%m%d)-$(printf '%s' "${_case}" | tr 'A-Z' 'a-z').log"
    AB_MATRIX_CMD="$0 --case ${_case}"
    export AB_EVIDENCE_LOG AB_MATRIX_CMD
    : >"${AB_EVIDENCE_LOG}"
    ev "case=${_case} path=$(path_label "${_path}")"

    if [ "${_case}" = "M7" ]; then
        run_bad_payload "${_case}"
        return $?
    fi

    # Baseline: the case is only allowed to start from a machine that can fall back.
    require_healthy_committed "${_case}" || return 1
    _baseline=${STATUS_LINE}
    AB_STATUS_LINE=${_baseline}
    # A queued candidate means an earlier transaction never finished; installing over
    # it would decide two questions at once. The case stops here, the machine does not.
    _pending=$(status_field "${_baseline}" pending) || _pending=""
    if [ "${_pending}" != "none" ]; then
        CASE_NOTE="baseline has pending=${_pending:-unknown}; resolve it before running the case"
        ev "${CASE_NOTE}"
        return 1
    fi
    dev_marker_init || ev "data marker not created: ${AB_MARKER_PATH}"
    dev_capture "${AB_EVIDENCE_LOG}" dev_ssh "ab-slot gc" >/dev/null || ev "gc reported problems"

    # A case declares the version it starts in. Getting there is not a result, so it
    # is logged as positioning and only has to end in a committed healthy slot; that
    # keeps the seven cases independent of the order they are run in.
    _start=$(printf '%s' "${_path}" | tr ' ' '\n' | head -n 1)
    _running=$(dev_running_version) || _running=""
    if [ "${_running}" != "${_start}" ]; then
        ev "positioning: ${_running:-unknown} -> ${_start}"
        hop_install "${_case}" "${_start}" position
        case "$?" in
            0) : ;;
            2)
                CASE_NOTE="no payload for the start version ${_start}"
                return 2
                ;;
            *)
                CASE_NOTE="positioning to ${_start} failed; the case did not start"
                return 1
                ;;
        esac
    fi

    if [ "${_case}" = "M5" ]; then
        run_same_version "${_case}" "${_start}"
        return $?
    fi

    _total=$(( $(printf '%s' "${_path}" | wc -w | tr -d ' ') - 1 ))
    _idx=0
    _first=1
    _last=""
    for _version in ${_path}; do
        if [ "${_first}" = "1" ]; then
            _first=0
            continue
        fi
        _idx=$((_idx + 1))
        ev "hop ${_idx}/${_total}: install ${_version}"
        hop_install "${_case}" "${_version}" ladder
        case "$?" in
            0) : ;;
            2)
                CASE_NOTE="no payload for ${_version}"
                return 2
                ;;
            20)
                CASE_NOTE="hop ${_idx}/${_total} to ${_version} refused with exit 74"
                return 1
                ;;
            *)
                CASE_NOTE="hop ${_idx}/${_total} to ${_version} failed"
                return 1
                ;;
        esac
        _last=${_version}
    done
    CASE_NOTE="${_total} hop(s) committed, ended on ${_last}"
    return 0
}

# --------------------------------------------------------------------------- #
# Plan (--dry-run)
# --------------------------------------------------------------------------- #

plan_case() {
    _case=$1
    _path=$(case_path "${_case}") || return 1
    printf '# case %s %s\n' "${_case}" "$(path_label "${_path}")"
    if [ "${_case}" = "M7" ]; then
        printf '%s status\n' "${_case}"
        printf '%s gc\n' "${_case}"
        printf '%s unmount /mnt/slots/a /mnt/slots/b (left behind by an earlier --check; their absence is deliberately not asserted)\n' "${_case}"
        printf '%s push %s/payload-bad.tar -> %s/payload-bad.tar\n' "${_case}" "${PAYLOAD_DIR}" "${AB_REMOTE_TMP}"
        printf '%s check %s/payload-bad.tar expect=exit-74 (slot state unchanged; the ESP is not inspected)\n' "${_case}" "${AB_REMOTE_TMP}"
        printf '%s status expect=unchanged generation/committed/pending\n' "${_case}"
        printf '%s record\n' "${_case}"
        return 0
    fi
    printf '%s status\n' "${_case}"
    printf '%s gc\n' "${_case}"
    printf '%s position %s (only when the machine runs something else)\n' "${_case}" \
        "$(printf '%s' "${_path}" | tr ' ' '\n' | head -n 1)"
    if [ "${_case}" = "M5" ]; then
        _version=$(printf '%s' "${_path}" | tr ' ' '\n' | tail -n 1)
        printf '%s unmount /mnt/slots/a /mnt/slots/b (left behind by an earlier --check; their absence is deliberately not asserted)\n' "${_case}"
        printf '%s push %s/payload-%s.tar -> %s/payload-%s.tar\n' "${_case}" "${PAYLOAD_DIR}" "${_version}" "${AB_REMOTE_TMP}" "${_version}"
        printf '%s check %s/payload-%s.tar expect=74-payload-already-installed-or-0 (state.json unchanged; --check still rewrites ab/conflicts.log)\n' "${_case}" "${AB_REMOTE_TMP}" "${_version}"
        printf '%s status expect=unchanged on a refusal\n' "${_case}"
        printf '%s record\n' "${_case}"
        return 0
    fi
    _total=$(( $(printf '%s' "${_path}" | wc -w | tr -d ' ') - 1 ))
    _idx=0
    _first=1
    for _version in ${_path}; do
        if [ "${_first}" = "1" ]; then
            _first=0
            continue
        fi
        _idx=$((_idx + 1))
        printf '%s %s/%s unmount /mnt/slots/a /mnt/slots/b (left behind by an earlier --check; their absence is deliberately not asserted)\n' "${_case}" "${_idx}" "${_total}"
        printf '%s %s/%s push %s/payload-%s.tar -> %s/payload-%s.tar\n' "${_case}" "${_idx}" "${_total}" "${PAYLOAD_DIR}" "${_version}" "${AB_REMOTE_TMP}" "${_version}"
        printf '%s %s/%s check %s/payload-%s.tar expect=0 (state.json unchanged; --check still rewrites ab/conflicts.log and may leave /mnt/slots/<slot> mounted)\n' "${_case}" "${_idx}" "${_total}" "${AB_REMOTE_TMP}" "${_version}"
        printf '%s %s/%s install %s/payload-%s.tar\n' "${_case}" "${_idx}" "${_total}" "${AB_REMOTE_TMP}" "${_version}"
        printf '%s %s/%s reboot\n' "${_case}" "${_idx}" "${_total}"
        printf '%s %s/%s wait_up %s (plain reboot %s, hard cap %s)\n' "${_case}" "${_idx}" "${_total}" \
            "${AB_WAIT_UP_FIRST}" "${AB_WAIT_UP}" "${AB_WAIT_UP_HARD}"
        printf '%s %s/%s settle until boot=ok pending=none (wait_up answers before the commit lands; %s s left of the %s s cap)\n' \
            "${_case}" "${_idx}" "${_total}" "${AB_WAIT_SETTLE}" "${AB_WAIT_UP_HARD}"
        printf '%s %s/%s status\n' "${_case}" "${_idx}" "${_total}"
        printf '%s %s/%s collect %s %s (a missing file is not an error)\n' "${_case}" "${_idx}" "${_total}" \
            "${AB_BOOT_LOG}" "${AB_BOOT_LOG_PREV}"
        printf '%s %s/%s assert boot=ok esp=ok committed=%s pending=none generation>=+1 upper=@overlay-%s(-rN)?\n' \
            "${_case}" "${_idx}" "${_total}" "<other>" "${_version}"
        printf '%s %s/%s assert boot-log healthcheck-done-result-ok commit-action-commit in boot-0.log, else boot-1.log, else `%s`\n' \
            "${_case}" "${_idx}" "${_total}" "${AB_PREV_LOG_CMD}"
        printf '%s %s/%s assert markers data+config replaced-nothing\n' "${_case}" "${_idx}" "${_total}"
        printf '%s %s/%s assert layer-invariant every slot upper exists and no unreferenced @overlay-* survives (count %s is a hint, not the assertion)\n' \
            "${_case}" "${_idx}" "${_total}" "${AB_LAYER_COUNT}"
    done
    printf '%s record\n' "${_case}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

if [ "${DRY_RUN}" = "1" ]; then
    for _case in ${WANT_CASES}; do
        plan_case "${_case}" || {
            printf 'matrix: unknown case: %s\n' "${_case}" >&2
            exit 2
        }
    done
    exit 0
fi

_passed=0
_failed=0
_gapped=0
_skipped=0
for _case in ${WANT_CASES}; do
    if ! case_path "${_case}" >/dev/null; then
        printf 'matrix: unknown case: %s\n' "${_case}" >&2
        exit 2
    fi
    if [ "${RESUME}" = "1" ] && record_passed "${_case}"; then
        printf '%s: already PASS in %s, skipped\n' "${_case}" "${AB_RESULTS}"
        _skipped=$((_skipped + 1))
        continue
    fi
    printf '== %s %s\n' "${_case}" "$(path_label "$(case_path "${_case}")")"
    run_case "${_case}"
    _rc=$?
    case "${_rc}" in
        0)
            record "${_case}" PASS "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _passed=$((_passed + 1))
            ;;
        2)
            record "${_case}" GAP "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _gapped=$((_gapped + 1))
            ;;
        *)
            record "${_case}" FAIL "${AB_EVIDENCE_LOG}" "${CASE_NOTE}"
            _failed=$((_failed + 1))
            ;;
    esac
    printf '   %s: %s (%s)\n' "${_case}" "${CASE_NOTE}" "${AB_EVIDENCE_LOG}"
done

printf '\nmatrix: passed=%s failed=%s gap=%s skipped=%s assertions-failed=%s results=%s\n' \
    "${_passed}" "${_failed}" "${_gapped}" "${_skipped}" "${AB_ASSERT_FAILURES}" "${AB_RESULTS}"
[ "${_failed}" -eq 0 ] || exit 1
[ "${_gapped}" -eq 0 ] || exit 4
