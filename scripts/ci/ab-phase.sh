#!/usr/bin/env bash
# Stage "ab-phase": assert the outcome of an A/B boot by reading the image.
#
# The guest cannot be trusted to grade itself, so the QEMU boot only has to reach the
# point where ab-commit decided; this script then mounts the ESP of the image file and
# checks what the system actually wrote: the state file, the boot log and the
# candidate marker. Only then is the frozen judge line printed:
#
#   S4-RESULT=ok phase=<commit|abandon|rollback> slot=<a|b>
#   S4-RESULT=fail reason=<token>
#
# Usage:
#   ab-phase.sh --phase commit --slot a --expect-committed a --expect-pending none \
#               [--expect-log 'stage=commit slot=a'] ...
#
# Inputs (environment): CI_IMAGE, CI_DIAG_DIR (optional, receives the raw evidence)

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

ci_stage_init ab-phase

image="${CI_IMAGE:?CI_IMAGE is required}"
work="${CI_TMP_ROOT}/ab-phase"
phase=""
slot=""
expect_committed=""
expect_pending=""
expect_logs=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --phase)
            phase="${2:?--phase needs a value}"
            shift 2
            ;;
        --slot)
            slot="${2:?--slot needs a value}"
            shift 2
            ;;
        --expect-committed)
            expect_committed="${2:?}"
            shift 2
            ;;
        --expect-pending)
            expect_pending="${2:?}"
            shift 2
            ;;
        --expect-log)
            expect_logs+=("${2:?}")
            shift 2
            ;;
        *) ci_die "unknown argument: $1" ;;
    esac
done

[ -n "${phase}" ] || ci_die "--phase is required"
[ -n "${slot}" ] || ci_die "--slot is required"
[ -f "${image}" ] || ci_die "image not found: ${image}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required"

mkdir -p "${work}"
esp="${work}/esp"
mkdir -p "${esp}"

fail_phase() {
    printf 'S4-RESULT=fail reason=%s\n' "$1"
    exit 1
}

loopdev=""
cleanup() {
    if [ -n "${loopdev}" ]; then
        sudo umount "${esp}" 2>/dev/null || true
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --show --partscan "${image}")"
attempt=0
until [ -b "${loopdev}p1" ] || [ "${attempt}" -ge 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
done
sudo mount -t vfat -o ro "${loopdev}p1" "${esp}"

state="${esp}/ab/state.json"
[ -f "${state}" ] || fail_phase state-missing
boot_log="${esp}/ab/log/boot-0.log"

# Keep the raw evidence for the report and for triage.
evidence="${CI_DIAG_DIR:-${work}/evidence}"
mkdir -p "${evidence}"
sudo cp "${state}" "${evidence}/${phase}-state.json"
[ -f "${boot_log}" ] && sudo cp "${boot_log}" "${evidence}/${phase}-boot-0.log"
ci_log "state after the ${phase} phase:"
sudo sed -e 's/^/  /' "${state}"

committed="$(sudo sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
if sudo grep -q '"pending": *null' "${state}"; then
    pending="none"
else
    pending="$(sudo sed -n 's/.*"pending": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
fi
ci_log "committed=${committed:-?} pending=${pending:-?}"

if [ -n "${expect_committed}" ] && [ "${committed}" != "${expect_committed}" ]; then
    fail_phase "committed-is-${committed:-unknown}"
fi
if [ -n "${expect_pending}" ] && [ "${pending}" != "${expect_pending}" ]; then
    fail_phase "pending-is-${pending:-unknown}"
fi

if [ "${#expect_logs[@]}" -gt 0 ]; then
    [ -f "${boot_log}" ] || fail_phase boot-log-missing
    for fragment in "${expect_logs[@]}"; do
        if ! sudo grep -qF "${fragment}" "${boot_log}"; then
            ci_warn "boot log does not contain '${fragment}'"
            sudo tail -n 30 "${boot_log}" | sed 's/^/[ab-phase]   /'
            fail_phase "log-missing-$(printf '%s' "${fragment}" | tr ' /=' '---')"
        fi
        ci_log "boot log contains '${fragment}'"
    done
fi

# A committed boot must leave no candidate marker behind.
if [ "${phase}" = "commit" ] && [ -f "${esp}/ab/candidate" ]; then
    ci_warn "candidate marker survived a commit"
    fail_phase candidate-marker-left-behind
fi

printf 'S4-RESULT=ok phase=%s slot=%s\n' "${phase}" "${slot}"
ci_emit_output "judge_line" "S4-RESULT=ok phase=${phase} slot=${slot}"
ci_emit_output "phase" "${phase}"
ci_emit_output "slot" "${slot}"
ci_emit_output "committed" "${committed}"
ci_emit_output "pending" "${pending}"
ci_log "phase ${phase} verified for slot ${slot}"
