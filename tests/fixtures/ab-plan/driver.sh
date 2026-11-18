#!/bin/sh
# Driver for tests/modules/upgrade/test_plan_{render,confirm}.sh - the one place a test
# reaches platform/lib/ab-plan.sh through, so both tests answer with the same shell the
# device runs (POSIX sh, not bash).
#
#   sh driver.sh <repo-root> width
#   sh driver.sh <repo-root> prompttext <n>
#   sh driver.sh <repo-root> render <plan-file>
#   sh driver.sh <repo-root> ask <n> [<mode>]
#   sh driver.sh <repo-root> present <plan-file> [<mode>] [<marker>]
#
# `present` is the whole exchange with the caller's side made visible: the marker file is
# written only after a 0, exactly as ab-upgrade would write the slot only after a 0. That is
# how "no write before the confirmation" is asserted at the call site and not just inside the
# library. The exit code of the library call is this driver's exit code.
set -u

root=$1
shift
. "${root}/platform/lib/ab-plan.sh" || exit 99

case "${1:-}" in
    width)
        ab_plan_width
        printf '\n'
        ;;
    prompttext)
        ab_plan_prompt_text "$2"
        ;;
    render)
        ab_plan_render "$2"
        ;;
    ask)
        shift
        ab_plan_ask "$@"
        ;;
    present)
        shift
        _drv_plan=$1
        _drv_mode=${2:-follow}
        _drv_marker=${3:-}
        ab_plan_present "${_drv_plan}" "${_drv_mode}"
        _drv_rc=$?
        if [ "${_drv_rc}" -eq 0 ] && [ -n "${_drv_marker}" ]; then
            printf 'written\n' >"${_drv_marker}"
        fi
        exit "${_drv_rc}"
        ;;
    *)
        printf 'driver: unknown command %s\n' "${1:-}" >&2
        exit 2
        ;;
esac
