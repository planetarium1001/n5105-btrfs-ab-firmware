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
# when it is `degraded`, and prints nothing - with status 0, so a login shell never
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
# *Sourced*, not executed - and that is the whole shape of this file. `/etc/profile` runs
# every snippet with `.`, so the shell this file runs in is the login shell the user is
# about to type into: an `exit` here does not end this file, it ends that shell. Measured
# on the n5105 on 2026-11-17 (task 20261117-02): with this file installed, SSH printed the
# banner and then closed the connection, and the console dropped back to nothing on the
# first Enter; `sh -l -c 'echo AFTER'` printed nothing, because the healthy boot took
# `... || exit 0` and the caller was the login shell itself. So the body lives in a
# function that only ever `return`s, and the top level decides how to leave: `exit` for
# the process that ran this file as a program, `return` for the shell that sourced it.
# The decision is made on the name the shell was started with (`${0##*/}`): that is this
# file's own name when it is executed, and the caller's name (`sh`, `-bash`) when it is
# sourced. Asking the shell instead - `(return 0)` succeeds when sourced - would not be
# portable: dash accepts a top-level `return` in a script too, so a program would believe
# it had been sourced.
#
# Environment:
#   AB_ESP        ESP mount point     (default /boot)
#   AB_SLOT_BIN   ab-slot to ask      (default: ab-slot on PATH or /usr/sbin/ab-slot)

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

# ab_degraded_banner: the body. Every way out of it is a `return`, because when this file
# is sourced the alternative ends the caller's shell instead of this file.
ab_degraded_banner() {
    set -u
    _bin="$(ab_slot_path)" || return 0
    [ -n "${_bin}" ] || return 0

    if [ -x "${_bin}" ]; then
        _line="$("${_bin}" status 2>/dev/null)" || return 0
    else
        _line="$(sh "${_bin}" status 2>/dev/null)" || return 0
    fi

    _boot=""
    for _kv in ${_line}; do
        case "${_kv}" in
            boot=*) _boot="${_kv#*=}" ;;
        esac
    done

    [ "${_boot}" = "degraded" ] || return 0

    printf '%s\n' "warning: this boot is degraded - the writable layer is a tmpfs, so changes will not survive a reboot (see: ab-slot status; ab-slot log)" >&2
    return 0
}

# Whether the caller runs with `set -u`, remembered before the banner can set it: `set -u`
# is this file's own typo net, and one left on in a login shell would abort the first
# command a user types that mentions an unset variable.
case "$-" in
    *u*) _ab_caller_had_u=1 ;;
    *) _ab_caller_had_u=0 ;;
esac

case "${0##*/}" in
    ab-degraded.sh)
        # Executed as a program (`sh /etc/profile.d/ab-degraded.sh`): there is nobody to
        # hand the shell back to, and the status a program reports is this file's own.
        ab_degraded_banner
        exit 0
        ;;
    *)
        # Sourced by `/etc/profile`: give the shell back alive, with the option state it
        # had, and with no `exit` anywhere on this path.
        ab_degraded_banner
        [ "${_ab_caller_had_u}" = 1 ] || set +u
        return 0
        ;;
esac
