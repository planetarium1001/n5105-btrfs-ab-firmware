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

# Overridable so tests can drive the fail-safe path without a real busybox `mount`.
WF_ESP_MOUNT="${WF_ESP_MOUNT:-/esp}"
WF_ESP_DEV="${WF_ESP_DEV:-}"
WF_SLOT_CFG_LIB="${WF_SLOT_CFG_LIB:-/lib/ab-slot-cfg.sh}"
WF_MOUNTS="${WF_MOUNTS:-/proc/mounts}"
WF_MOUNT="${WF_MOUNT:-mount}"
WF_TMP="${WF_TMP:-/run}"

# The boot milestones have to be visible on the serial port AND on HDMI. Linux binds
# /dev/console to the LAST console= parameter, so a command line that ends in
# `console=tty0` sends PID1's whole stdout to the local screen and leaves an empty
# serial log — which is a boot nobody can debug. Every milestone therefore goes through
# wf_say: stdout as before, plus one copy to the serial device when /dev/console is not
# already bound to it. The duplicate is skipped in that case so the judge line stays a
# single line for whatever parses it.
#
# Overridable for tests: WF_SERIAL (the device node), WF_CONSOLES (the kernel's console
# table, which marks the write console with a W flag).
WF_SERIAL="${WF_SERIAL:-/dev/ttyS0}"
WF_CONSOLES="${WF_CONSOLES:-/proc/consoles}"

# wf_console_is_serial: is /dev/console already bound to the serial device.
#
# The kernel lists every registered console in WF_CONSOLES as
# `<name> <flags> (<state>) <major>:<minor>`, where the flags are R (readable),
# W (writable) and U (unbound). Exactly one console is bound to /dev/console — the last
# `console=` on the command line — and it is the one without U. So: ttyS0 listed without
# U means stdout already reaches the serial port and a second copy would only duplicate
# the judge line.
wf_console_is_serial() {
    [ -r "${WF_CONSOLES}" ] || return 1
    wf_cis_flags="$(awk -v want="$(basename "${WF_SERIAL}")" \
        '$1 == want { print $2; exit }' "${WF_CONSOLES}" 2>/dev/null)"
    [ -n "${wf_cis_flags}" ] || return 1
    case "${wf_cis_flags}" in
        *U*) return 1 ;;
    esac
    return 0
}

# wf_say <line...>: one milestone line on every console that can carry it.
wf_say() {
    printf '%s\n' "$*"
    [ -e "${WF_SERIAL}" ] || return 0
    wf_console_is_serial && return 0
    # Append, not overwrite: a character device does not care, but a regular file (a
    # fixture, or a serial port redirected to a file) must keep every line.
    printf '%s\n' "$*" >>"${WF_SERIAL}" 2>/dev/null || :
    return 0
}

wf_log() {
    wf_say "[boot] $*"
}

# wf_mountpoint_active <mount point>: is it in the mount table right now.
wf_mountpoint_active() {
    awk -v mp="$1" '$2 == mp { found = 1 } END { exit !found }' "${WF_MOUNTS}" 2>/dev/null
}

# wf_failsafe_abandon: point the next boot at the committed slot before this one powers
# off. A pending slot that cannot even reach initramfs completion would otherwise be
# selected again by GRUB on every restart, and the machine would loop instead of
# reporting. platform/lib/ab-slot-cfg.sh does the writing (pending cleared in
# ab/state.json, ab-slot.cfg set to fallback=default=committed), so the failure path and
# `ab-slot abandon` move the machine through exactly one implementation.
#
# Everything here is best effort and always returns 0: the caller is on its way to
# poweroff and must not be stopped by a write that cannot happen. Nothing is written when
# no slot is pending, so a failing committed slot does not touch the FAT.
wf_failsafe_abandon() {
    if [ ! -f "${WF_SLOT_CFG_LIB}" ]; then
        wf_log "fail-safe abandon skipped: ${WF_SLOT_CFG_LIB} is not in this initramfs"
        return 0
    fi
    # shellcheck source=platform/lib/ab-slot-cfg.sh
    if ! . "${WF_SLOT_CFG_LIB}" 2>/dev/null; then
        wf_log "fail-safe abandon skipped: cannot read ${WF_SLOT_CFG_LIB}"
        return 0
    fi
    if ! command -v ab_slot_cfg_write_committed >/dev/null 2>&1; then
        wf_log "fail-safe abandon skipped: ${WF_SLOT_CFG_LIB} has no writer"
        return 0
    fi
    if [ ! -d "${WF_ESP_MOUNT}" ] || [ ! -f "${WF_ESP_MOUNT}/ab/state.json" ]; then
        if [ -z "${WF_ESP_DEV}" ]; then
            wf_log "fail-safe abandon skipped: the ESP is not mounted"
            return 0
        fi
        mkdir -p "${WF_ESP_MOUNT}" 2>/dev/null
        if ! "${WF_MOUNT}" -t vfat -o rw,noatime "${WF_ESP_DEV}" "${WF_ESP_MOUNT}" >/dev/null 2>&1; then
            wf_log "fail-safe abandon skipped: cannot mount ${WF_ESP_DEV} on ${WF_ESP_MOUNT}"
            return 0
        fi
    fi
    wf_ab_pending="$(ab_slot_state_pending "${WF_ESP_MOUNT}/ab/state.json" 2>/dev/null)" || wf_ab_pending=""
    case "${wf_ab_pending}" in
        a | b) : ;;
        *)
            wf_log "fail-safe abandon: no pending slot to clear"
            return 0
            ;;
    esac
    if wf_mountpoint_active "${WF_ESP_MOUNT}"; then
        if ! "${WF_MOUNT}" -o remount,rw "${WF_ESP_MOUNT}" >/dev/null 2>&1; then
            wf_log "fail-safe abandon: cannot remount ${WF_ESP_MOUNT} read-write"
        fi
    fi
    mkdir -p "${WF_TMP}" 2>/dev/null
    wf_ab_out="${WF_TMP}/wf-abandon.out"
    ab_slot_cfg_write_committed "${WF_ESP_MOUNT}" >"${wf_ab_out}" 2>/dev/null
    wf_ab_rc=$?
    wf_ab_slot="$(cat "${wf_ab_out}" 2>/dev/null)"
    rm -f "${wf_ab_out}" 2>/dev/null
    if [ "${wf_ab_rc}" -eq 0 ]; then
        wf_say "[boot] action=fail-safe-abandon slot=${wf_ab_slot}"
        wf_log "fail-safe abandon: the next boot runs the committed slot ${wf_ab_slot}"
    else
        wf_say "[boot] action=fail-safe-abandon result=fail reason=${AB_SLOT_CFG_REASON:-unknown}"
        wf_log "fail-safe abandon failed: ${AB_SLOT_CFG_REASON:-unknown}"
    fi
    return 0
}

# wf_fail <reason>: single failure exit for the pre-switch phase.
#
# The fail-safe abandon runs first, and before the judge line on purpose: a harness that
# stops the machine as soon as it sees the line would otherwise cut the write in half.
wf_fail() {
    wf_failsafe_abandon || :
    wf_say "S3-RESULT=fail reason=$1"
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
