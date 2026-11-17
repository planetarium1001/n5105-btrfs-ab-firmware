#!/bin/sh
# follow-baseline.sh - the one phase that records what "still usable" will be judged against.
#
#   follow-baseline.sh --results <tsv> [--state <file>]
#
# Installs the sample set from tests/fixtures/follow-samples.json, writes the fake
# configuration and the data marker for each sample, and records the baseline (package
# version, config sha256, data sha256) in a state file on the OPERATOR side.
#
# The state file has to live here and not on the machine: the machine's /tmp is a tmpfs and
# the sample set is judged across a reboot, so a baseline kept there would be gone exactly
# when it is needed. full-test.sh exports AB_FOLLOW_STATE once and matrix.sh reads it, so
# "which file is the baseline" is one answer for the whole run.
#
# Rows: one per sample, plus a summary row the phase verdict uses.
set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
: "${AB_REPO_ROOT:=$(cd "${DEVICE_DIR}/../.." && pwd)}"
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

RESULTS=${AB_FOLLOW_RESULTS:-}
STATE=${AB_FOLLOW_STATE:-/tmp/ab-follow-state.tsv}
while [ $# -gt 0 ]; do
    case "$1" in
        --results) RESULTS=${2:-}; shift 2 ;;
        --state) STATE=${2:-}; shift 2 ;;
        -h|--help) printf 'usage: follow-baseline.sh [--results <tsv>] [--state <file>]\n'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -n "${AB_DRY_RUN:-}" ] && [ "${AB_DRY_RUN}" = "1" ]; then
    printf 'dry-run: follow-probe --install, then --mark --state %s\n' "${STATE}"
    exit 0
fi

if ! dev_ssh true >/dev/null 2>&1; then
    printf 'follow-baseline: no machine answered, nothing recorded\n' >&2
    exit 3
fi

_install_out=$(sh "${DEVICE_DIR}/follow-probe.sh" --install 2>&1) || _install_rc=$?
_install_rc=${_install_rc:-0}
printf '%s\n' "${_install_out}"

_mark_out=$(sh "${DEVICE_DIR}/follow-probe.sh" --mark --state "${STATE}" 2>&1) || _mark_rc=$?
_mark_rc=${_mark_rc:-0}
printf '%s\n' "${_mark_out}"

_installed=$(printf '%s\n' "${_mark_out}" | grep -c 'status=pass' || true)
_gap=$(printf '%s\n' "${_mark_out}" | grep -c 'status=gap' || true)
printf 'follow-baseline: installed=%s gap=%s state=%s\n' "${_installed}" "${_gap}" "${STATE}"

if [ -n "${RESULTS}" ]; then
    if [ "${_mark_rc}" -ne 0 ] && [ "${_mark_rc}" -ne 4 ]; then
        printf 'follow-baseline\tFAIL\t-\tmark rc=%s state=%s\n' "${_mark_rc}" "${STATE}" >>"${RESULTS}"
        exit 1
    fi
    printf 'follow-baseline\tPASS\t%s\tinstalled=%s gap=%s\n' "${STATE}" "${_installed}" "${_gap}" >>"${RESULTS}"
fi
exit 0
