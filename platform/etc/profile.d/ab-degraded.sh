#!/bin/sh
# ab-degraded.sh - say it out loud when this boot is degraded.
#
# A boot that could not mount the writable partition runs with a tmpfs as its upper:
# everything written looks normal and disappears on the next reboot, and the only human
# who could notice is whoever logs in after that boot. So the fact is announced once, on
# stderr, at login.
#
# The judgement is not made here. `ab-slot status` already answers it from the ring log
# (the line `ab-boot` wrote carries `action=degraded-boot`), and a second implementation
# would eventually disagree with the first. This script reads that answer, prints one line
# when it is `degraded`, and prints nothing - with exit status 0, so a login shell never
# breaks - for a healthy boot and for one it cannot judge.
#
# It writes no file: the ring log is the record, and a second copy of a boot fact is a
# second truth to keep in step.
#
# How it gets run: the upstream `/etc/profile` sources every `/etc/profile.d/*.sh` unless
# `FAILSAFE` is set, and skips a file when `${FILE%.sh}.hush` exists - so
# `/etc/profile.d/ab-degraded.hush` is the documented way for an operator to silence this
# one banner without patching anything.
#
# Environment:
#   AB_ESP        ESP mount point     (default /boot)
#   AB_SLOT_BIN   ab-slot to ask      (default: ab-slot on PATH or /usr/sbin/ab-slot)

set -u

AB_ESP="${AB_ESP:-/boot}"
AB_SLOT_BIN="${AB_SLOT_BIN:-}"

# ab_slot_path: the tool that owns the answer. Installed it is on PATH; a checkout or a
# test names it directly.
ab_slot_path() {
    if [ -n "${AB_SLOT_BIN}" ]; then
        if [ -f "${AB_SLOT_BIN}" ]; then
            printf '%s' "${AB_SLOT_BIN}"
            return 0
        fi
        return 1
    fi
    for _candidate in "$(command -v ab-slot 2>/dev/null)" /usr/sbin/ab-slot; do
        if [ -n "${_candidate}" ] && [ -f "${_candidate}" ]; then
            printf '%s' "${_candidate}"
            return 0
        fi
    done
    return 1
}

_bin="$(ab_slot_path)" || exit 0
[ -n "${_bin}" ] || exit 0

if [ -x "${_bin}" ]; then
    _line="$("${_bin}" status 2>/dev/null)" || exit 0
else
    _line="$(sh "${_bin}" status 2>/dev/null)" || exit 0
fi

_boot=""
for _kv in ${_line}; do
    case "${_kv}" in
        boot=*) _boot="${_kv#*=}" ;;
    esac
done

[ "${_boot}" = "degraded" ] || exit 0

printf '%s\n' "warning: this boot is degraded - the writable layer is a tmpfs, so changes will not survive a reboot (see: ab-slot status; ab-slot log)" >&2
exit 0
