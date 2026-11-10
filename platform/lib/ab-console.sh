#!/bin/sh
# ab-console - one milestone line on every console that can carry it.
#
# Why this exists: Linux binds /dev/console to the *last* `console=` on the kernel
# command line. The image's menu used to end in `console=tty0`, which sent every line
# our hooks printed to the local screen and left the serial log with kernel messages
# only - a boot nobody can debug, and a CI run that times out with no evidence.
#
# Two things follow, and this file does both:
#
#   1. the menu now ends in `console=ttyS0,115200`, so /dev/console is the serial port
#   2. a milestone is written to /dev/console *and* to the other consoles the kernel
#      registered, so a machine with a monitor shows the same lines the serial log has,
#      and an older image that still ends in tty0 still reaches the serial port
#
# The line is never written twice to the same console: /proc/consoles flags the console
# /dev/console writes to (CON_CONSDEV, shown as C), and that one is skipped when the
# mirrors are written. A duplicated milestone would double every line of a judge log and
# break whatever counts them.
#
# Everything here is best effort: a console that is missing or not writable is skipped,
# and no caller is ever stopped by console output.
#
# Sourced by platform/etc/init.d/ab-boot, platform/etc/init.d/ab-commit and
# platform/usr/sbin/ab-upgrade. POSIX sh, no `local`; variables are prefixed ac_.

# The primary channel and the two consoles worth mirroring to. Overridable so a test can
# drive the whole decision from fixtures.
AB_CONSOLE_DEV="${AB_CONSOLE_DEV:-/dev/console}"
AB_CONSOLE_SERIAL="${AB_CONSOLE_SERIAL:-/dev/ttyS0}"
AB_CONSOLE_VT="${AB_CONSOLE_VT:-/dev/tty0}"
AB_CONSOLES="${AB_CONSOLES:-/proc/consoles}"

# ab_console_write_console: the console name /dev/console writes to, or non-zero.
ab_console_write_console() {
    [ -r "${AB_CONSOLES}" ] || return 1
    ac_wc_found=""
    while read -r ac_wc_name ac_wc_rest; do
        [ -n "${ac_wc_name}" ] || continue
        # The flags live in parentheses: "(EC p  )" means enabled and preferred, "(E  p a)"
        # means enabled only. C is the one that says /dev/console writes here.
        ac_wc_flags="$(printf '%s\n' "${ac_wc_rest}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
        case "${ac_wc_flags}" in
            *C*) ac_wc_found="${ac_wc_name}" ;;
        esac
    done <"${AB_CONSOLES}"
    [ -n "${ac_wc_found}" ] || return 1
    printf '%s' "${ac_wc_found}"
}

# console_say <line...>: the milestone on the primary console, plus one copy on each
# other console that exists and is writable.
console_say() {
    ac_line="$*"
    printf '%s\n' "${ac_line}" >"${AB_CONSOLE_DEV}" 2>/dev/null || :
    ac_write_console="$(ab_console_write_console 2>/dev/null)" || ac_write_console=""
    for ac_dev in "${AB_CONSOLE_SERIAL}" "${AB_CONSOLE_VT}"; do
        [ "$(basename "${ac_dev}")" = "${ac_write_console}" ] && continue
        [ -w "${ac_dev}" ] || continue
        printf '%s\n' "${ac_line}" >"${ac_dev}" 2>/dev/null || :
    done
    return 0
}
