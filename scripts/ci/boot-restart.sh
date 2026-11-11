#!/usr/bin/env bash
# Boot-restart judgement for the QEMU harness: how many times did the guest boot, how many
# times did it reboot on purpose, and was that one too many?
#
# Why this file exists: the first-boot growth of p4 takes two boots. The boot that rewrites
# the partition table ends in a controlled `reboot -f`, because the reboot IS the partition
# table re-read - nothing in the boot path asks the kernel to re-read it any more. A guest
# therefore restarts once, by design, in the middle of a stage.
#
# The harness used to run QEMU with `-no-reboot`, so that reboot made QEMU exit after 14s and
# the stage died with "the guest never printed the stop pattern" - a working image reported
# as a broken one. The reboot now has to be allowed, which means the harness needs to know
# three things apart:
#
#   zero reboots + stop pattern  -> the disk did not have to grow (or it was already grown)
#   one reboot   + stop pattern  -> the two-stage growth did what it is designed to do
#   two or more  -> a restart loop, reported as `restart-loop` and NOT as a missing line
#
# The judgement itself is separated from QEMU on purpose: it is a function of the serial log,
# so it is tested from fixtures (tests/modules/ci/test_qemu_restart.sh) instead of needing a
# virtual machine that actually reboots.
#
# Sourced by scripts/ci/qemu-smoke.sh; exercised by tests/modules/ci/test_qemu_restart.sh.

# How many restarts one boot is allowed to spend. One: the two-stage growth reboots exactly
# once, and a second reboot means the machine is going round in circles.
BR_MAX_DEFAULT=1

# What a boot start looks like in the serial log. The kernel prints its banner once per boot,
# which is what makes a panic loop (a reboot with no growth line at all) countable too.
BR_BOOT_PATTERN='^Linux version '

# The controlled reboot that ends stage 1 of the first-boot growth (initramfs/lib/grow.sh,
# wf_grow_reboot). Anchored at the start of the line because the console writes it as one
# line, and loose at the end so a trailing detail cannot hide it.
BR_REBOOT_PATTERN='^\[grow\] rebooting so the kernel re-reads the partition table'

# boot_restart_counts <serial log>: the standard pair, printed as "<boots> <reboots>".
#
# This is the only place the two patterns above are applied, so a stage that wants the
# standard counts has one call to make and nothing to keep in step.
boot_restart_counts() {
    local br_std_log="${1:-}"
    printf '%s %s' \
        "$(boot_restart_count "${br_std_log}" "${BR_BOOT_PATTERN}")" \
        "$(boot_restart_count "${br_std_log}" "${BR_REBOOT_PATTERN}")"
}

# boot_restart_count <serial log> <extended regex>: how many lines match. A missing log, an
# empty pattern or a grep that fails all answer 0 - a stage that never wrote a serial log is
# "no evidence of a restart", not a broken harness.
boot_restart_count() {
    local br_log="${1:-}" br_pattern="${2:-}" br_count=0
    if [ -z "${br_log}" ] || [ -z "${br_pattern}" ] || [ ! -f "${br_log}" ]; then
        printf '%s' 0
        return 0
    fi
    br_count="$(grep -c -E -- "${br_pattern}" "${br_log}" 2>/dev/null || true)"
    case "${br_count}" in
        '' | *[!0-9]*) br_count=0 ;;
    esac
    printf '%s' "${br_count}"
}

# boot_restart_verdict <boots> <reboots> <max reboots>: `ok` or `restart-loop`.
#
# Both counts are budgeted, which is what makes the judgement robust in the two directions
# that matter: a growth reboot shows up as one extra boot and one extra line, and a panic
# loop shows up as extra boots with no line at all. Anything over the budget is a loop.
#
# The two patterns above are the counting contract for that: a caller that wants the
# standard judgement (rather than a hand-picked regex) uses them here, so the harness and
# the stages cannot disagree about what a boot start or a growth reboot looks like.
boot_restart_verdict() {
    local br_boots="${1:-}" br_reboots="${2:-}" br_max="${3:-}"
    case "${br_boots}" in
        '' | *[!0-9]*) br_boots=0 ;;
    esac
    case "${br_reboots}" in
        '' | *[!0-9]*) br_reboots=0 ;;
    esac
    case "${br_max}" in
        '' | *[!0-9]*) br_max="${BR_MAX_DEFAULT}" ;;
    esac
    if [ "${br_reboots}" -gt "${br_max}" ]; then
        printf 'restart-loop'
        return 0
    fi
    if [ "${br_boots}" -gt "$((br_max + 1))" ]; then
        printf 'restart-loop'
        return 0
    fi
    printf 'ok'
}
