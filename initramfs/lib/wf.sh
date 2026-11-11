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

# The breadcrumb log, and the two landing zones it can live in.
#
# A machine that powers itself off hands a serial log to nobody, so "how far did this boot
# get" has to be a line on a disk. WF_MARK_LOG is the file wf_mark appends to; it stays
# empty during the early boot, when neither the ESP nor p4 is mounted yet and there is
# simply nowhere to write - wf_mark then writes no file at all and only reaches the
# console. wf_mark_zone answers "where would a breadcrumb go right now", in the order the
# boot makes the zones available: the ESP once it is mounted, then the p4 side, then the
# serial port alone.
WF_MARK_LOG="${WF_MARK_LOG:-}"
# 32 KiB is the same cap the runtime ring log uses (platform/etc/init.d/ab-boot), so the
# two halves of one boot's timeline cannot grow beyond a readable size.
WF_MARK_MAX="${WF_MARK_MAX:-32768}"
# The sequence survives inside one boot even when there is no file to read it back from.
WF_MARK_SEQ="${WF_MARK_SEQ:-0}"
# p4 is the second landing zone: when the ESP is the thing that broke, the evidence still
# has to land on this disk. /mnt/p4root is where the initramfs mounts p4 before the overlay.
WF_P4_MOUNT="${WF_P4_MOUNT:-/mnt/p4root}"

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
# Where the coldplug reads major:minor from; overridable so a test can drive it without /sys.
WF_SYS_BLOCK="${WF_SYS_BLOCK:-/sys/class/block}"
WF_CONSOLES="${WF_CONSOLES:-/proc/consoles}"

# wf_coldplug_dev [dir]: create the block device nodes the kernel already knows about.
#
# This kernel ships without devtmpfs (it is not in /proc/filesystems) and the upstream
# busybox has no mdev applet, so /dev holds only the two nodes the kernel unpacks out of
# the initramfs archive (`console`, `null`). The nodes are therefore built from sysfs by
# hand: every /sys/class/block/<name>/dev holds "<major>:<minor>", which is exactly the
# walk `mdev -s` used to do. Call it again after a partition table rewrite, because the
# kernel publishes the new partition kobjects at that point and nothing creates their
# nodes for us.
wf_coldplug_dev() {
    wf_cd_dir="${1:-/dev}"
    [ -d "${wf_cd_dir}" ] || mkdir -p "${wf_cd_dir}"
    for wf_cd_entry in "${WF_SYS_BLOCK}"/*; do
        [ -e "${wf_cd_entry}/dev" ] || continue
        wf_cd_name="$(basename "${wf_cd_entry}")"
        if [ -e "${wf_cd_dir}/${wf_cd_name}" ]; then
            continue
        fi
        read -r wf_cd_numbers <"${wf_cd_entry}/dev" || continue
        wf_cd_major="${wf_cd_numbers%%:*}"
        wf_cd_minor="${wf_cd_numbers##*:}"
        case "${wf_cd_major}" in ""|*[!0-9]*) continue ;; esac
        case "${wf_cd_minor}" in ""|*[!0-9]*) continue ;; esac
        mknod "${wf_cd_dir}/${wf_cd_name}" b "${wf_cd_major}" "${wf_cd_minor}" 2>/dev/null || true
    done
    return 0
}

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

# wf_say_serial <line...>: mirror one line to the serial device and nowhere else.
#
# Helpers whose stdout is captured and parsed (initramfs/lib/grow.sh) must be able to
# reach the serial log without writing a single byte to stdout: a `[grow] ...` line that
# leaks into the captured value turns `done 921566` into `[grow]` and the whole growth
# state into fail:grow-crashed.
wf_say_serial() {
    [ -e "${WF_SERIAL}" ] || return 0
    wf_console_is_serial && return 0
    # Append, not overwrite: a character device does not care, but a regular file (a
    # fixture, or a serial port redirected to a file) must keep every line.
    printf '%s\n' "$*" >>"${WF_SERIAL}" 2>/dev/null || :
    return 0
}

# wf_say <line...>: one milestone line on every console that can carry it.
wf_say() {
    printf '%s\n' "$*"
    wf_say_serial "$@"
}

wf_log() {
    wf_say "[boot] $*"
}

# wf_mountpoint_active <mount point>: is it in the mount table right now.
wf_mountpoint_active() {
    awk -v mp="$1" '$2 == mp { found = 1 } END { exit !found }' "${WF_MOUNTS}" 2>/dev/null
}

# wf_mark_zone_esp: the ring log on the ESP, but only once the ESP is really mounted.
#
# The mount table, not `[ -d ]`, is the test on purpose: a directory on the initramfs
# tmpfs is not the ESP, and writing there loses the line when the real mount covers it and
# the initramfs is thrown away (that is how a whole boot's growth diagnostics disappeared
# once already).
wf_mark_zone_esp() {
    [ -n "${WF_ESP_MOUNT}" ] || return 0
    wf_mountpoint_active "${WF_ESP_MOUNT}" || return 0
    printf '%s' "${WF_ESP_MOUNT}/ab/log/boot-0.log"
    return 0
}

# wf_mark_zone_p4: the p4 side, which needs no mount table entry to be believable - it is
# a btrfs subvolume, and the test is that the directory is there and writable.
wf_mark_zone_p4() {
    [ -n "${WF_P4_MOUNT}" ] || return 0
    [ -d "${WF_P4_MOUNT}" ] || return 0
    [ -w "${WF_P4_MOUNT}" ] || return 0
    printf '%s' "${WF_P4_MOUNT}/.ab/init-fail.log"
    return 0
}

# wf_mark_zone: the file a breadcrumb would go to right now. Empty output means "no
# landing zone yet, serial only" and is never an error.
wf_mark_zone() {
    wf_mz_zone="$(wf_mark_zone_esp)"
    if [ -z "${wf_mz_zone}" ]; then
        wf_mz_zone="$(wf_mark_zone_p4)"
    fi
    printf '%s' "${wf_mz_zone}"
    return 0
}

# wf_mark_last_seq <file>: the highest seq the log already holds, 0 when there is none.
#
# Read back from the file rather than counted in memory, so a breadcrumb written by an
# earlier process (or an earlier initramfs) is never numbered from 1 again.
wf_mark_last_seq() {
    wf_ml_seq="$(sed -n 's/.*stage=mark seq=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null \
        | sort -n | tail -n 1)"
    case "${wf_ml_seq}" in
        '' | *[!0-9]*) wf_ml_seq=0 ;;
    esac
    printf '%s' "${wf_ml_seq}"
    return 0
}

# wf_mark_append <file> <line>: append one line and keep the log under WF_MARK_MAX.
#
# The write goes through `<file>.tmp.$$` and a rename, the same shape log_append uses in
# platform/etc/init.d/ab-boot: the log is never truncated in place, so a power cut can
# lose the newest line but can never leave a half-written or empty log where the previous
# boot's breadcrumbs used to be. Over the cap the tail is kept (the newest lines are the
# ones worth reading) and one TRUNCATED=1 line records that lines were dropped.
wf_mark_append() {
    wf_ma_file="$1"
    wf_ma_line="$2"
    wf_ma_dir="${wf_ma_file%/*}"
    [ "${wf_ma_dir}" = "${wf_ma_file}" ] && wf_ma_dir="."
    mkdir -p "${wf_ma_dir}" 2>/dev/null || return 1
    wf_ma_tmp="${wf_ma_file}.tmp.$$"
    : >"${wf_ma_tmp}" 2>/dev/null || return 1
    if [ -f "${wf_ma_file}" ]; then
        cat "${wf_ma_file}" >"${wf_ma_tmp}" 2>/dev/null || :
    fi
    printf '%s\n' "${wf_ma_line}" >>"${wf_ma_tmp}" 2>/dev/null || return 1
    # BSD wc pads its count with spaces, busybox does not: strip whatever comes first.
    wf_ma_size="$(wc -c <"${wf_ma_tmp}" 2>/dev/null | tr -d ' \t')"
    case "${wf_ma_size}" in
        '' | *[!0-9]*) wf_ma_size=0 ;;
    esac
    if [ "${wf_ma_size}" -gt "${WF_MARK_MAX}" ]; then
        wf_ma_tail="${wf_ma_tmp}.tail"
        tail -c $((WF_MARK_MAX - 512)) "${wf_ma_tmp}" 2>/dev/null \
            | sed '/^TRUNCATED=1$/d' >"${wf_ma_tail}" 2>/dev/null || :
        # Only replace the log when the tail really was produced: a failed tail/sed must
        # not turn a housekeeping step into an empty log.
        if [ -s "${wf_ma_tail}" ]; then
            mv "${wf_ma_tail}" "${wf_ma_tmp}" 2>/dev/null || :
        else
            rm -f "${wf_ma_tail}" 2>/dev/null || :
        fi
        printf 'TRUNCATED=1\n' >>"${wf_ma_tmp}" 2>/dev/null || :
    fi
    sync
    mv "${wf_ma_tmp}" "${wf_ma_file}" 2>/dev/null || return 1
    sync
    return 0
}

# wf_mark <step> [key=value ...]: one breadcrumb line, "this boot got this far".
#
# Never changes a boot decision and always returns 0: a breadcrumb that cannot be written
# is a missing diagnostic, not a reason to stop the machine. With WF_MARK_LOG empty there
# is no landing zone yet (early boot), so nothing is written and the line goes to the
# console only, where the sequence still counts up inside this process.
wf_mark() {
    wf_mk_step="${1:-}"
    if [ "$#" -gt 0 ]; then
        shift
    fi
    wf_mk_extra=""
    for wf_mk_arg in "$@"; do
        wf_mk_extra="${wf_mk_extra} ${wf_mk_arg}"
    done
    if [ -z "${WF_MARK_LOG}" ]; then
        WF_MARK_SEQ=$((WF_MARK_SEQ + 1))
        wf_log "stage=mark seq=${WF_MARK_SEQ} step=${wf_mk_step}${wf_mk_extra}"
        return 0
    fi
    wf_mk_seq="$(wf_mark_last_seq "${WF_MARK_LOG}")"
    case "${wf_mk_seq}" in
        '' | *[!0-9]*) wf_mk_seq=0 ;;
    esac
    wf_mk_seq=$((wf_mk_seq + 1))
    wf_mk_line="stage=mark seq=${wf_mk_seq} step=${wf_mk_step}${wf_mk_extra}"
    # A landing zone that refuses the write (read-only ESP, full disk, no directory) must
    # not swallow the line: it falls back to the console, where the operator still sees it.
    wf_mark_append "${WF_MARK_LOG}" "${wf_mk_line}" || wf_log "${wf_mk_line}"
    WF_MARK_SEQ="${wf_mk_seq}"
    return 0
}

# wf_abandon_evidence <result> <reason> [slot] [zone]: what the fail-safe abandon did.
#
# One line per branch, on disk, in a shape that greps: `action=fail-safe-abandon
# result=<ok|fail|skip> reason=<token>`. <zone> overrides the landing zone (the branch that
# could not write the ESP sends its line to p4 instead); empty means "resolve it now".
# The console copy is a convenience - the file is the evidence.
wf_abandon_evidence() {
    wf_ae_result="$1"
    wf_ae_reason="$2"
    wf_ae_slot="${3:-}"
    wf_ae_zone="${4:-}"
    if [ -z "${wf_ae_zone}" ]; then
        wf_ae_zone="$(wf_mark_zone)"
    fi
    if [ -n "${wf_ae_zone}" ]; then
        wf_ae_saved="${WF_MARK_LOG}"
        WF_MARK_LOG="${wf_ae_zone}"
        if [ -n "${wf_ae_slot}" ]; then
            wf_mark abandon "action=fail-safe-abandon" "result=${wf_ae_result}" \
                "reason=${wf_ae_reason}" "slot=${wf_ae_slot}"
        else
            wf_mark abandon "action=fail-safe-abandon" "result=${wf_ae_result}" \
                "reason=${wf_ae_reason}"
        fi
        WF_MARK_LOG="${wf_ae_saved}"
    fi
    if [ -n "${wf_ae_slot}" ]; then
        wf_say "[boot] action=fail-safe-abandon result=${wf_ae_result} reason=${wf_ae_reason} slot=${wf_ae_slot}"
    else
        wf_say "[boot] action=fail-safe-abandon result=${wf_ae_result} reason=${wf_ae_reason}"
    fi
    return 0
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
# no slot is pending, so a failing committed slot does not rewrite the FAT - but every
# branch now leaves one `action=fail-safe-abandon result=... reason=...` line behind, on
# the ESP when it is writable and on the p4 side when it is not. Without that line the
# failure was observable on the serial port only, which is exactly the port a machine
# that powered itself off does not bring to the person holding the disk.
wf_failsafe_abandon() {
    if [ ! -f "${WF_SLOT_CFG_LIB}" ]; then
        wf_log "fail-safe abandon skipped: ${WF_SLOT_CFG_LIB} is not in this initramfs"
        wf_abandon_evidence skip lib-missing
        return 0
    fi
    # shellcheck source=platform/lib/ab-slot-cfg.sh
    if ! . "${WF_SLOT_CFG_LIB}" 2>/dev/null; then
        wf_log "fail-safe abandon skipped: cannot read ${WF_SLOT_CFG_LIB}"
        wf_abandon_evidence skip lib-unreadable
        return 0
    fi
    if ! command -v ab_slot_cfg_write_committed >/dev/null 2>&1; then
        wf_log "fail-safe abandon skipped: ${WF_SLOT_CFG_LIB} has no writer"
        wf_abandon_evidence skip lib-no-writer
        return 0
    fi
    wf_ab_state="${WF_ESP_MOUNT}/ab/state.json"
    if [ ! -f "${wf_ab_state}" ]; then
        if wf_mountpoint_active "${WF_ESP_MOUNT}"; then
            # The ESP is there and still has no readable state file. Mounting the same
            # device on the same mount point a second time cannot work (util-linux:
            # "already mounted or mount point busy"), so the old code always failed here
            # and only said so on the serial port. Record the reason, land the evidence on
            # p4, and let the caller power off.
            wf_log "fail-safe abandon skipped: ${wf_ab_state} is unreadable, the ESP is already mounted (reason=state-unreadable)"
            wf_abandon_evidence skip state-unreadable "" "$(wf_mark_zone_p4)"
            return 0
        fi
        if [ -z "${WF_ESP_DEV}" ]; then
            wf_log "fail-safe abandon skipped: the ESP is not mounted"
            wf_abandon_evidence skip esp-not-mounted
            return 0
        fi
        mkdir -p "${WF_ESP_MOUNT}" 2>/dev/null
        if ! "${WF_MOUNT}" -t vfat -o rw,noatime "${WF_ESP_DEV}" "${WF_ESP_MOUNT}" >/dev/null 2>&1; then
            wf_log "fail-safe abandon skipped: cannot mount ${WF_ESP_DEV} on ${WF_ESP_MOUNT}"
            wf_abandon_evidence skip esp-not-writable "" "$(wf_mark_zone_p4)"
            return 0
        fi
    fi
    wf_ab_pending="$(ab_slot_state_pending "${WF_ESP_MOUNT}/ab/state.json" 2>/dev/null)" || wf_ab_pending=""
    case "${wf_ab_pending}" in
        a | b) : ;;
        *)
            wf_log "fail-safe abandon: no pending slot to clear"
            wf_abandon_evidence skip no-pending
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
        wf_abandon_evidence ok none "${wf_ab_slot}" "$(wf_mark_zone_esp)"
        wf_say "[boot] action=fail-safe-abandon slot=${wf_ab_slot}"
        wf_log "fail-safe abandon: the next boot runs the committed slot ${wf_ab_slot}"
    else
        # The write to the ESP is what failed, so the evidence goes to the other side.
        wf_abandon_evidence fail "${AB_SLOT_CFG_REASON:-unknown}" "" "$(wf_mark_zone_p4)"
        wf_say "[boot] action=fail-safe-abandon result=fail reason=${AB_SLOT_CFG_REASON:-unknown}"
        wf_log "fail-safe abandon failed: ${AB_SLOT_CFG_REASON:-unknown}"
    fi
    return 0
}

# wf_fail <reason>: single failure exit for the pre-switch phase.
#
# The breadcrumb goes first, then the fail-safe abandon, then the judge line - in that
# order, and `poweroff -f` last. After the poweroff there is no serial log and no shell, so
# the line on the disk is the only record that survives; a harness that stops the machine
# as soon as it sees the judge line would otherwise cut the write in half.
wf_fail() {
    wf_mark fail "reason=${1:-unknown}"
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
