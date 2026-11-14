#!/bin/sh
# power-cut.sh - prove the interrupted-candidate-boot path on the real machine.
#
# The hole this covers (2026-11-14): a candidate slot whose first boot never reaches
# `ab-commit` - a power cut, a hang - left nothing behind. GRUB's `default` stayed on the
# pending slot and the machine retried the same slot on every restart. The fix counts the
# attempt in `${ESP}/ab/candidate` and, past one retry, moves the menu back to the committed
# slot and reboots into it.
#
# A power cut needs no power switch here. The driver writes the two files the boot path
# reads, in exactly the form it writes them - the candidate marker and the interruption
# record - and then reboots. That is an injected state, not a pulled plug, and the evidence
# says so; what it proves is the decision logic and the boot wiring, which is where the
# defect was.
#
#   scripts/device/power-cut.sh --case I1     # a leftover marker -> retry, then commit
#   scripts/device/power-cut.sh --case I2     # a marker past the cap -> abandon, end on committed
#   scripts/device/power-cut.sh --case I1 --case I2
#   scripts/device/power-cut.sh --dry-run     # print the steps, touch nothing
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run because the machine is not in a state it needs.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

AB_POWER_RESULTS=${AB_POWER_RESULTS:-power-cut-results.tsv}
AB_BOOT_RETRY_MAX=${AB_BOOT_RETRY_MAX:-1}
DRY_RUN=${AB_DRY_RUN:-0}
CASES=""

usage() {
    sed -n '17,25p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            CASES="${CASES} ${2:?--case needs I1 or I2}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help) usage ;;
        *) printf 'power-cut.sh: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "${CASES}" ] || CASES=" I1 I2"

CASE_NOTE=""
CASE_FAILURES=0

# _fail <case> <message>: one assertion, recorded and printed.
_fail() {
    CASE_FAILURES=$((CASE_FAILURES + 1))
    printf 'FAIL [%s] %s\n' "$1" "$2" >&2
    ev "FAIL ${1}: ${2}"
}

# _ok <case> <message>: one assertion that held.
_ok() {
    printf 'ok [%s] %s\n' "$1" "$2"
}

# _assert_contains <case> <file> <needle> <message>
_assert_contains() {
    if grep -q -- "$3" "$2" 2>/dev/null; then
        _ok "$1" "$4"
    else
        _fail "$1" "$4 (missing '$3' in $2)"
    fi
}

# _field <status-line> <key>: one key=value from `ab-slot status`.
_field() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# _log_search <case>: the ring log of the boot that just happened, plus the previous one.
_log_has() { # <case> <needle>
    _case=$1
    _needle=$2
    if dev_ssh "grep -q -- '${_needle}' /boot/ab/log/boot-0.log 2>/dev/null || grep -q -- '${_needle}' /boot/ab/log/boot-1.log 2>/dev/null"; then
        _ok "${_case}" "ring log carries ${_needle}"
        return 0
    fi
    _fail "${_case}" "ring log carries no ${_needle}"
    return 1
}

# require_idle_machine <case>: a committed, healthy machine with no candidate queued.
# Anything else would make the injected state mean two things at once.
require_idle_machine() {
    _case=$1
    if ! STATUS_LINE=$(dev_status 2>/dev/null); then
        CASE_NOTE="ab-slot status did not answer"
        return 4
    fi
    _pending=$(_field "${STATUS_LINE}" pending)
    _boot=$(_field "${STATUS_LINE}" boot)
    _esp=$(_field "${STATUS_LINE}" esp)
    if [ "${_boot}" != "ok" ] || [ "${_esp}" != "ok" ]; then
        CASE_NOTE="machine is not healthy before the case (boot=${_boot:-?} esp=${_esp:-?})"
        return 4
    fi
    if [ "${_pending}" != "none" ]; then
        CASE_NOTE="pending=${_pending} is already queued; resolve it before running power-cut cases"
        return 4
    fi
    return 0
}

# inject_marker <slot> <attempt>: write the candidate marker in the form the boot writes.
inject_marker() {
    _slot=$1
    _attempt=$2
    _stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    dev_ssh "printf '%s %s %s\n' '${_slot}' '${_stamp}' '${_attempt}' > /boot/ab/candidate && cat /boot/ab/candidate" ||
        return 1
}

# run_retry <case>: a leftover marker inside the budget -> retry, then the candidate commits.
run_retry() {
    _case=$1
    require_idle_machine "${_case}" || return $?
    _committed=$(_field "${STATUS_LINE}" committed)
    case "${_committed}" in
        '' | *[!ab]*) CASE_NOTE="no committed slot to move to (committed=${_committed:-?})"; return 4 ;;
    esac
    if [ "${_committed}" = "a" ]; then _target=b; else _target=a; fi

    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/6 arm pending=%s (ab-slot pending %s)\n' "${_case}" "${_target}" "${_target}"
        printf '%s 2/6 inject candidate marker attempt=1 for slot %s\n' "${_case}" "${_target}"
        printf '%s 3/6 reboot, wait for ssh, settle\n' "${_case}"
        printf '%s 4/6 expect stage=interrupted ... result=retry in the ring log\n' "${_case}"
        printf '%s 5/6 expect committed=%s pending=none\n' "${_case}" "${_target}"
        printf '%s 6/6 expect the candidate marker gone\n' "${_case}"
        return 0
    fi

    ev "I1: committed=${_committed}, arming pending=${_target} and injecting attempt=1"
    if ! dev_ssh "ab-slot pending ${_target}" >/dev/null 2>&1; then
        CASE_NOTE="ab-slot pending ${_target} refused"
        return 4
    fi
    if ! _marker=$(inject_marker "${_target}" 1); then
        CASE_NOTE="could not write the candidate marker on the ESP"
        return 4
    fi
    ev "I1: injected marker '${_marker}' (a candidate boot that never reached ab-commit)"
    # `ab-slot pending` moves the menu already; the reboot is what runs the guard.
    dev_reboot >/dev/null 2>&1
    if ! dev_wait_up_after after-install; then
        CASE_NOTE="the machine did not come back after the injected candidate boot"
        return 1
    fi
    dev_wait_settled >/dev/null 2>&1
    _log_has "${_case}" "stage=interrupted"
    _log_has "${_case}" "result=retry"
    _status=$(dev_status 2>/dev/null) || _status=""
    [ "$(_field "${_status}" pending)" = "none" ] &&
        _ok "${_case}" "pending cleared after the retry committed" ||
        _fail "${_case}" "pending is $(_field "${_status}" pending), expected none"
    if dev_ssh 'test -f /boot/ab/candidate'; then
        _fail "${_case}" "the candidate marker survived a committed boot"
    else
        _ok "${_case}" "the candidate marker is gone after the decision"
    fi
    CASE_NOTE="injected leftover marker -> stage=interrupted result=retry, then committed=$(_field "${_status}" committed)"
    return 0
}

# run_cap <case>: a marker past the retry budget -> abandon, machine back on committed.
run_cap() {
    _case=$1
    require_idle_machine "${_case}" || return $?
    _committed=$(_field "${STATUS_LINE}" committed)
    case "${_committed}" in
        '' | *[!ab]*) CASE_NOTE="no committed slot (committed=${_committed:-?})"; return 4 ;;
    esac
    if [ "${_committed}" = "a" ]; then _target=b; else _target=a; fi
    _past=$((AB_BOOT_RETRY_MAX + 1))

    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/6 arm pending=%s\n' "${_case}" "${_target}"
        printf '%s 2/6 inject marker attempt=%s (already past the cap %s)\n' "${_case}" "${_past}" "${AB_BOOT_RETRY_MAX}"
        printf '%s 3/6 reboot, wait for ssh, settle\n' "${_case}"
        printf '%s 4/6 expect stage=interrupted ... result=abandon reason=attempt-limit\n' "${_case}"
        printf '%s 5/6 expect committed=%s pending=none and the marker gone\n' "${_case}" "${_committed}"
        printf '%s 6/6 expect the machine to answer on slot %s\n' "${_case}" "${_committed}"
        return 0
    fi

    ev "I2: committed=${_committed}, arming pending=${_target} with attempt=${_past} (cap=${AB_BOOT_RETRY_MAX})"
    if ! dev_ssh "ab-slot pending ${_target}" >/dev/null 2>&1; then
        CASE_NOTE="ab-slot pending ${_target} refused"
        return 4
    fi
    if ! inject_marker "${_target}" "${_past}" >/dev/null; then
        CASE_NOTE="could not write the candidate marker on the ESP"
        return 4
    fi
    dev_reboot >/dev/null 2>&1
    if ! dev_wait_up_after after-install; then
        CASE_NOTE="the machine did not come back after the abandon path"
        return 1
    fi
    dev_wait_settled >/dev/null 2>&1
    _log_has "${_case}" "result=abandon"
    _log_has "${_case}" "reason=attempt-limit"
    _status=$(dev_status 2>/dev/null) || _status=""
    [ "$(_field "${_status}" pending)" = "none" ] &&
        _ok "${_case}" "pending cleared by the abandon" ||
        _fail "${_case}" "pending is $(_field "${_status}" pending), expected none"
    [ "$(_field "${_status}" committed)" = "${_committed}" ] &&
        _ok "${_case}" "the committed slot did not move (${_committed})" ||
        _fail "${_case}" "committed moved to $(_field "${_status}" committed), expected ${_committed}"
    if dev_ssh 'test -f /boot/ab/candidate'; then
        _fail "${_case}" "the candidate marker survived the abandon"
    else
        _ok "${_case}" "the marker is gone, so the next candidate boot counts from 1"
    fi
    CASE_NOTE="injected attempt=${_past} -> abandon reason=attempt-limit, back on committed=${_committed}"
    return 0
}

# run_case <case>: one case, one verdict line in the results file.
run_case() {
    _case=$1
    CASE_NOTE=""
    CASE_FAILURES=0
    case "${_case}" in
        I1) run_retry "${_case}" ;;
        I2) run_cap "${_case}" ;;
        *)
            CASE_NOTE="unknown case"
            return 2
            ;;
    esac
    _rc=$?
    case "${_rc}" in
        0)
            if [ "${CASE_FAILURES}" -eq 0 ]; then
                printf '%s\tPASS\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_POWER_RESULTS}"
                printf '== %s PASS %s\n' "${_case}" "${CASE_NOTE}"
                return 0
            fi
            printf '%s\tFAIL\t%s\t%s assertion(s) failed; %s\n' "${_case}" "${AB_HOST}" "${CASE_FAILURES}" "${CASE_NOTE}" >>"${AB_POWER_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
        4)
            printf '%s\tGAP\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_POWER_RESULTS}"
            printf '== %s GAP %s\n' "${_case}" "${CASE_NOTE}"
            return 4
            ;;
        *)
            printf '%s\tFAIL\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_POWER_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
    esac
}

_rc_all=0
for _case in ${CASES}; do
    run_case "${_case}" || _rc_all=1
done
exit "${_rc_all}"
