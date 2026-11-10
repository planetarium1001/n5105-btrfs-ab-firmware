#!/bin/sh
# ab-slot-cfg - the only writer and reader of the file that tells GRUB which slot to
# boot.
#
# The file is /boot/grub/ab-slot.cfg on the ESP and it carries two GRUB commands, in
# this order:
#
#   set fallback=<committed slot>
#   set default=<pending slot, or the committed slot when nothing is pending>
#
# Nothing else: no signature, no key=value block, no modules. The GRUB that ships in
# the upstream ESP is a standalone EFI binary with its modules built in, and it has no
# `env` module, so `load_env` and `save_env` do not exist there. `source` does, and a
# file of two commands is the whole mechanism.
#
# Why a second file instead of rewriting grub.cfg: grub.cfg is written once at build
# time and never touched again. Rewriting a whole menu on FAT at runtime risks a
# truncated configuration, which is a machine that does not boot.
#
# The write order is the power-cut contract, and it is why `fallback` comes first:
#
#   * grub.cfg sets `default` and `fallback` to the committed slot before the menu
#     entries, and the file is sourced after them
#   * a write cut short after its first line has therefore written only
#     `set fallback=<committed>`, which equals the static value: `default` stays on the
#     committed slot and the machine boots it
#   * a complete file moves `default` to the slot being tried and keeps `fallback` on
#     the committed slot, which is exactly "try the new slot, fall back to the old one"
#   * a truncation can never leave `fallback` pointing at the slot that is being tried,
#     so a failed try always has somewhere to go
#
# Entry indices are fixed by the order of the menu entries in grub.cfg, and
# scripts/ci/grub-render.sh asserts that order: slot a is entry 0, slot b is entry 1.
#
# Sourced by platform/usr/sbin/ab-slot, platform/etc/init.d/ab-boot,
# platform/lib/upgrade/platform.sh, the boot initramfs (the fail-safe abandon path) and
# (at build time) scripts/ci/grub-render.sh, so the build and the running system share
# one implementation and cannot drift.
#
# POSIX sh with no `local`: this runs under the busybox in the image. Every variable is
# prefixed per function (abscg_ in the reader, abscv_ in the verifier, abscw_ in the
# writer, absf_ in the fail-safe path), because a shared prefix lets one function
# overwrite another's state.

# Entry index of each slot, fixed by the menu order in grub.cfg.
AB_SLOT_CFG_INDEX_A=0
AB_SLOT_CFG_INDEX_B=1

# Set by the verifier, the writer and the fail-safe path when they return non-zero.
AB_SLOT_CFG_REASON=''

# ab_slot_cfg_index <slot>: the menu entry index of that slot.
ab_slot_cfg_index() {
    case "$1" in
        a) printf '%s' "${AB_SLOT_CFG_INDEX_A}" ;;
        b) printf '%s' "${AB_SLOT_CFG_INDEX_B}" ;;
        *) return 1 ;;
    esac
}

# ab_slot_cfg_slot <index>: the slot of that menu entry.
ab_slot_cfg_slot() {
    case "$1" in
        "${AB_SLOT_CFG_INDEX_A}") printf 'a' ;;
        "${AB_SLOT_CFG_INDEX_B}") printf 'b' ;;
        *) return 1 ;;
    esac
}

# ab_slot_cfg_other <slot>: the other slot.
ab_slot_cfg_other() {
    case "$1" in
        a) printf 'b' ;;
        b) printf 'a' ;;
        *) return 1 ;;
    esac
}

# ab_slot_cfg_get <path>: the slot the menu will boot, from the `default` line.
#
# A file holding only its first line (`set fallback=`) answers nothing, which is the
# honest answer: the menu then uses the committed default from grub.cfg.
ab_slot_cfg_get() {
    abscg_file="$1"
    [ -f "${abscg_file}" ] || return 1
    abscg_line="$(sed -n '/^[[:space:]]*set default=/p' "${abscg_file}" | head -n 1)"
    [ -n "${abscg_line}" ] || return 1
    abscg_index="${abscg_line#*=}"
    abscg_index="$(printf '%s' "${abscg_index}" | tr -d ' \t')"
    ab_slot_cfg_slot "${abscg_index}" || return 1
}

# ab_slot_cfg_fallback <path>: the slot the menu falls back to.
ab_slot_cfg_fallback() {
    abscf_file="$1"
    [ -f "${abscf_file}" ] || return 1
    abscf_line="$(sed -n '/^[[:space:]]*set fallback=/p' "${abscf_file}" | head -n 1)"
    [ -n "${abscf_line}" ] || return 1
    abscf_index="${abscf_line#*=}"
    abscf_index="$(printf '%s' "${abscf_index}" | tr -d ' \t')"
    ab_slot_cfg_slot "${abscf_index}" || return 1
}

# ab_slot_cfg_verify <path>: 0 when the file is a complete, usable pair of commands.
#
# Checks the order too: `fallback` first, `default` second. That order is what makes a
# write cut short harmless, so a file with the lines swapped is refused even though
# GRUB itself would not care. "Complete" matters for the writer, not for GRUB.
ab_slot_cfg_verify() {
    abscv_file="$1"
    AB_SLOT_CFG_REASON=''

    if [ ! -f "${abscv_file}" ]; then
        AB_SLOT_CFG_REASON='missing'
        return 1
    fi
    abscv_size="$(wc -c <"${abscv_file}" | tr -d ' \t')"
    if [ "${abscv_size}" = "0" ]; then
        AB_SLOT_CFG_REASON='empty'
        return 1
    fi

    abscv_lines="$(grep -c . "${abscv_file}" | tr -d ' \t')"
    if [ "${abscv_lines}" = "1" ]; then
        AB_SLOT_CFG_REASON='lines-1'
        return 1
    fi
    if [ "${abscv_lines}" != "2" ]; then
        AB_SLOT_CFG_REASON="lines-${abscv_lines}"
        return 1
    fi

    abscv_first="$(sed -n '1p' "${abscv_file}" | cut -c1-13)"
    if [ "${abscv_first}" != "set fallback=" ]; then
        AB_SLOT_CFG_REASON='fallback-not-first'
        return 1
    fi
    abscv_second="$(sed -n '2p' "${abscv_file}" | cut -c1-12)"
    if [ "${abscv_second}" != "set default=" ]; then
        AB_SLOT_CFG_REASON='default-not-second'
        return 1
    fi

    abscv_fallback="$(sed -n 's/^set fallback=\([0-9][0-9]*\)$/\1/p' "${abscv_file}")"
    if [ -z "${abscv_fallback}" ]; then
        AB_SLOT_CFG_REASON='no-fallback'
        return 1
    fi
    abscv_default="$(sed -n 's/^set default=\([0-9][0-9]*\)$/\1/p' "${abscv_file}")"
    if [ -z "${abscv_default}" ]; then
        AB_SLOT_CFG_REASON='no-default'
        return 1
    fi
    if ! ab_slot_cfg_slot "${abscv_fallback}" >/dev/null; then
        AB_SLOT_CFG_REASON="fallback-not-a-slot-${abscv_fallback}"
        return 1
    fi
    if ! ab_slot_cfg_slot "${abscv_default}" >/dev/null; then
        AB_SLOT_CFG_REASON="default-not-a-slot-${abscv_default}"
        return 1
    fi
    return 0
}

# ab_slot_cfg_check_pair <path> <committed-slot>: the file and the state agree.
#
# With nothing pending the two lines name the same slot on purpose (the committed
# one); with a pending slot, `default` names the candidate and `fallback` has to stay
# on the committed slot, so a failed try has somewhere to go.
ab_slot_cfg_check_pair() {
    abscp_file="$1"
    abscp_committed="$2"
    ab_slot_cfg_verify "${abscp_file}" || return 1
    abscp_fallback="$(ab_slot_cfg_fallback "${abscp_file}")" || return 1
    abscp_default="$(ab_slot_cfg_get "${abscp_file}")" || return 1
    if [ "${abscp_fallback}" != "${abscp_committed}" ]; then
        AB_SLOT_CFG_REASON="fallback-is-${abscp_fallback}-not-committed-${abscp_committed}"
        return 1
    fi
    printf '%s %s' "${abscp_default}" "${abscp_fallback}"
}

# ab_slot_cfg_write <path> <fallback-slot> <default-slot>: replace the file atomically.
#
# The first line is always the fallback, because that is the line a power cut may leave
# behind. Callers pass the committed slot as the fallback and the slot to try as the
# default, which is the same slot when nothing is pending.
ab_slot_cfg_write() {
    abscw_file="$1"
    abscw_fallback="$2"
    abscw_default="$3"

    if ! abscw_fallback_index="$(ab_slot_cfg_index "${abscw_fallback}")"; then
        AB_SLOT_CFG_REASON="not-a-slot-${abscw_fallback}"
        return 1
    fi
    if ! abscw_default_index="$(ab_slot_cfg_index "${abscw_default}")"; then
        AB_SLOT_CFG_REASON="not-a-slot-${abscw_default}"
        return 1
    fi

    abscw_dir="$(dirname "${abscw_file}")"
    mkdir -p "${abscw_dir}" || {
        AB_SLOT_CFG_REASON='no-directory'
        return 1
    }
    abscw_tmp="${abscw_file}.tmp.$$"

    {
        printf 'set fallback=%s\n' "${abscw_fallback_index}" || exit 1
        printf 'set default=%s\n' "${abscw_default_index}" || exit 1
    } >"${abscw_tmp}" || {
        rm -f "${abscw_tmp}"
        AB_SLOT_CFG_REASON='cannot-write'
        return 1
    }

    if ! ab_slot_cfg_verify "${abscw_tmp}"; then
        abscw_reason="${AB_SLOT_CFG_REASON}"
        rm -f "${abscw_tmp}"
        AB_SLOT_CFG_REASON="verify-${abscw_reason}"
        return 1
    fi

    sync
    if ! mv "${abscw_tmp}" "${abscw_file}"; then
        rm -f "${abscw_tmp}"
        AB_SLOT_CFG_REASON='cannot-rename'
        return 1
    fi
    sync
    return 0
}

# --------------------------------------------------------------------------- #
# Fail-safe abandon, used by the boot initramfs
#
# The initramfs runs before anything can mount the platform layer, so it cannot call
# ab-slot. It can still leave the ESP in a state that boots: clear `pending` in
# ab/state.json and point the menu at the committed slot. That turns "the candidate
# failed before userspace" from a reboot loop into one more boot of the system that
# worked.
#
# The state file is patched in place, as text, because the initramfs has no JSON
# writer: `pending` is the only field that changes and the replacement keeps the
# surrounding bytes, so slots, layers and generation survive unchanged.
# --------------------------------------------------------------------------- #

# ab_slot_state_committed <state.json>: the committed slot, or non-zero.
ab_slot_state_committed() {
    absf_json="$(tr -d ' \t\r\n' <"$1" 2>/dev/null)" || return 1
    absf_value="$(printf '%s' "${absf_json}" | sed -n 's/.*"committed":"\([ab]\)".*/\1/p')"
    [ -n "${absf_value}" ] || return 1
    printf '%s' "${absf_value}"
}

# ab_slot_state_pending <state.json>: "none", a slot, or non-zero when unreadable.
ab_slot_state_pending() {
    absf_json="$(tr -d ' \t\r\n' <"$1" 2>/dev/null)" || return 1
    case "${absf_json}" in
        *'"pending":null'*) printf 'none' ;;
        *'"pending":"'*)
            absf_value="$(printf '%s' "${absf_json}" | sed -n 's/.*"pending":"\([ab]\)".*/\1/p')"
            [ -n "${absf_value}" ] || return 1
            printf '%s' "${absf_value}"
            ;;
        *) return 1 ;;
    esac
}

# ab_slot_cfg_write_committed <esp-mountpoint> [<state.json>]
#
# Clear `pending` and point the menu at the committed slot. Prints the slot it moved
# to. Every step is best effort: the caller is already on a failure path and must only
# log what happened, never refuse to continue.
ab_slot_cfg_write_committed() {
    absf_esp="${1:?ab_slot_cfg_write_committed needs the ESP mount point}"
    absf_state="${2:-${absf_esp}/ab/state.json}"
    absf_cfg="${absf_esp}/boot/grub/ab-slot.cfg"
    AB_SLOT_CFG_REASON=''

    absf_committed="$(ab_slot_state_committed "${absf_state}")" || {
        AB_SLOT_CFG_REASON='state-unreadable'
        return 1
    }
    absf_pending="$(ab_slot_state_pending "${absf_state}")" || {
        AB_SLOT_CFG_REASON='state-unreadable'
        return 1
    }

    if [ "${absf_pending}" != "none" ]; then
        absf_tmp="${absf_state}.tmp.$$"
        # Format preserving: only the pending value changes, everything else on the
        # line and in the file stays byte for byte.
        if ! sed 's/"pending"[[:space:]]*:[[:space:]]*"[ab]"/"pending": null/' \
            "${absf_state}" >"${absf_tmp}" 2>/dev/null; then
            rm -f "${absf_tmp}"
            AB_SLOT_CFG_REASON='pending-not-cleared'
            return 1
        fi
        sync
        if ! mv "${absf_tmp}" "${absf_state}"; then
            rm -f "${absf_tmp}"
            AB_SLOT_CFG_REASON='pending-not-cleared'
            return 1
        fi
        sync
    fi

    if ! ab_slot_cfg_write "${absf_cfg}" "${absf_committed}" "${absf_committed}"; then
        return 1
    fi
    printf '%s' "${absf_committed}"
}
