#!/bin/sh
# Helpers for the boot initramfs: logging, failure reporting, state parsing.
#
# Sourced by initramfs/boot/init and exercised by tests/modules/boot/. POSIX sh on
# purpose: this runs under the busybox in the initramfs. Variables are prefixed
# instead of declared `local`, because `local` is not POSIX.
#
# The state file is ab/state.json on the ESP:
#
#   {
#     "generation": 2,
#     "committed": "b",
#     "pending": null,
#     "slots": { "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
#                "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" } }
#   }
#
# Two different things live in there, on purpose:
#
#   * `slots.<slot>.upper` is the writable layer name, which follows the upstream
#     version (`@overlay-25.12.2`) so it reads as what it is
#   * `generation` is an integer that only ever grows; it orders generations and
#     drives reclamation, because version strings do not sort correctly
#     (`@overlay-25.12.10` < `@overlay-25.12.9` as text)
#
# The layer name is never derived from the generation number.
#
# It is parsed with sed rather than a JSON library because the initramfs only has
# busybox. Whitespace is stripped first, so pretty-printed and compact files behave
# identically, and every parser returns non-zero instead of inventing a default.

wf_log() {
    printf '[boot] %s\n' "$*"
}

# wf_fail <reason>: single failure exit for the pre-switch phase.
wf_fail() {
    printf 'S3-RESULT=fail reason=%s\n' "$1"
    sync
    poweroff -f
    exit 1
}

# wf_squeeze <file>: the file with all insignificant whitespace removed.
wf_squeeze() {
    tr -d ' \t\r\n' <"$1"
}

# wf_committed <file>: the committed slot, "a" or "b". Empty output is a failure,
# never a default: the caller must not boot a slot the state file did not name.
wf_committed() {
    wf_c_json="$(wf_squeeze "$1")" || return 1
    wf_c_value="$(printf '%s' "${wf_c_json}" \
        | sed -n 's/.*"committed":"\([^"]*\)".*/\1/p')"
    [ -n "${wf_c_value}" ] || return 1
    printf '%s' "${wf_c_value}"
}

# wf_upper <file> <slot>: the writable layer name for that slot, for example
# "@overlay-25.12.2". Anything that does not carry the @overlay- prefix is rejected,
# so a stale schema cannot be mounted by accident.
wf_upper() {
    wf_u_json="$(wf_squeeze "$1")" || return 1
    case "${wf_u_json}" in
        *'"slots":'*) : ;;
        *) return 1 ;;
    esac
    wf_u_slots="${wf_u_json#*\"slots\":}"
    wf_u_obj="$(printf '%s' "${wf_u_slots}" \
        | sed -n 's/.*"'"$2"'":{\([^}]*\)}.*/\1/p')"
    [ -n "${wf_u_obj}" ] || return 1
    wf_u_value="$(printf '%s' "${wf_u_obj}" \
        | sed -n 's/.*"upper":"\([^"]*\)".*/\1/p')"
    [ -n "${wf_u_value}" ] || return 1
    case "${wf_u_value}" in
        @overlay-?*) : ;;
        *) return 1 ;;
    esac
    printf '%s' "${wf_u_value}"
}

# wf_generation <file>: the integer generation. Used for ordering and reclamation,
# never to build a layer name.
wf_generation() {
    wf_n_json="$(wf_squeeze "$1")" || return 1
    wf_n_value="$(printf '%s' "${wf_n_json}" \
        | sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p')"
    [ -n "${wf_n_value}" ] || return 1
    printf '%s' "${wf_n_value}"
}
