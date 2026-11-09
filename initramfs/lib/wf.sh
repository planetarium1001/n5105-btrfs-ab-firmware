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
#     "slots": { "a": { "rootfs": "25.12.3", "upper_gen": 3 },
#                "b": { "rootfs": "25.12.2", "upper_gen": 2 } }
#   }
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

# wf_upper_gen <file> <slot>: the generation number recorded for that slot.
wf_upper_gen() {
    wf_g_json="$(wf_squeeze "$1")" || return 1
    case "${wf_g_json}" in
        *'"slots":'*) : ;;
        *) return 1 ;;
    esac
    wf_g_slots="${wf_g_json#*\"slots\":}"
    wf_g_slot_obj="$(printf '%s' "${wf_g_slots}" \
        | sed -n 's/.*"'"$2"'":{\([^}]*\)}.*/\1/p')"
    [ -n "${wf_g_slot_obj}" ] || return 1
    wf_g_value="$(printf '%s' "${wf_g_slot_obj}" \
        | sed -n 's/.*"upper_gen":\([0-9][0-9]*\).*/\1/p')"
    [ -n "${wf_g_value}" ] || return 1
    printf '%s' "${wf_g_value}"
}

# wf_gen_name <number>: the subvolume name for a generation, @overlay.genNNNN.
wf_gen_name() {
    printf '@overlay.gen%04d' "$1"
}
