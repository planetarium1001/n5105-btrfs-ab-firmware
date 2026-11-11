#!/usr/bin/env bash
# Module: ci
# The two-stage first-boot growth reboots the guest once, on purpose. A QEMU harness that
# treats any reboot as the end of the run reports "the guest never printed the stop pattern"
# and fails a working image - which is exactly what happened when the growth became two
# stages. This module pins the judgement that separates the three cases apart:
#   ac-1 zero reboots and the stop pattern reached  -> the run passed (not every disk grows)
#   ac-2 exactly one reboot and the stop pattern reached in the boot after it -> passed
#   ac-3 two or more reboots, or more boots than the budget allows -> restart-loop
# plus the mechanical wiring of scripts/ci/qemu-smoke.sh: no `-no-reboot` (a guest reboot has
# to be able to happen at all), the helper is sourced, the budget is one, and the verdict is
# enforced before the stop-pattern assertion so a loop is never reported as a missing line.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

harness="$root/scripts/ci/qemu-smoke.sh"
lib="$root/scripts/ci/boot-restart.sh"

assert_file_exists "$lib" "ac-1 the restart judgement lives in its own sourced file"
[ -f "${lib}" ] || { finish; exit 1; }
# shellcheck source=scripts/ci/boot-restart.sh
. "${lib}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# Serial-log fixtures: one file per shape of boot
# --------------------------------------------------------------------------- #
# These are trimmed copies of what the guest really prints, in the order the console gets it:
# the kernel banner, the growth decision, and - for the boot that writes the table - the
# record and the reboot line, then the whole thing again for the boot that follows.

banner() { printf 'Linux version 6.12.103 (builder@ci) #1 SMP\n'; }
stop_line() { printf 'S3-RESULT=ok slot=a upper=@overlay-25.12.2 lower=platform:sys root=overlay\n'; }

# grow boot (stage 1): prints the reboot line and stops there.
grow_boot1() {
    banner
    printf 'ab-boot: first boot growth result=table-written last_lba=921566\n'
    printf '[grow] record result=table-write-pending last_lba=921566 at /mnt/p4root/.ab/grow\n'
    printf '[grow] partition table written with p4 size=921567 (no re-read: the next boot'"'"'s kernel does that)\n'
    printf '[grow] verify=ok primary and backup GPT agree after the write\n'
    printf '[grow] record result=table-written last_lba=921566 at /mnt/p4root/.ab/grow\n'
    printf '[grow] rebooting so the kernel re-reads the partition table at probe time\n'
}
# grow boot (stage 2): the table is full now, so it resizes and reaches userspace.
grow_boot2() {
    banner
    printf '[grow] btrfs filesystem resize max /mnt/p4resize: Resize device id 1 (nvme0n1p4) from 128.00MiB to max\n'
    printf '[grow] record result=done last_lba=921566 at /mnt/p4root/.ab/grow\n'
    stop_line
}

: >"$tmp/none.log"                       # a boot that reaches userspace without growing
banner >>"$tmp/none.log"
printf '[grow] p4 growth plan: already-full (last usable LBA 921566)\n' >>"$tmp/none.log"
stop_line >>"$tmp/none.log"

{ grow_boot1; grow_boot2; } >"$tmp/one.log"

{ grow_boot1; grow_boot1; grow_boot1; } >"$tmp/loop.log"
stop_line >>"$tmp/loop.log"

# A panic loop: the guest restarts but never prints the growth reboot line at all.
{ banner; printf 'Kernel panic - not syncing: VFS: Unable to mount root fs\n';
  banner; printf 'Kernel panic - not syncing: VFS: Unable to mount root fs\n';
  banner; printf 'Kernel panic - not syncing: VFS: Unable to mount root fs\n'; } >"$tmp/panic.log"

# --------------------------------------------------------------------------- #
# ac-1/ac-2/ac-3 the counting helpers
# --------------------------------------------------------------------------- #

assert_eq "$(boot_restart_count "$tmp/none.log" "${BR_BOOT_PATTERN}")" "1" \
  "ac-1 a single boot is counted once"
assert_eq "$(boot_restart_count "$tmp/one.log" '^S9-RESULT=')" "0" \
  "ac-1 a file that exists but does not match counts zero"
assert_eq "$(boot_restart_count "$tmp/absent.log" "${BR_BOOT_PATTERN}")" "0" \
  "ac-1 a missing serial log counts zero instead of failing"
assert_eq "$(boot_restart_count "$tmp/one.log" "${BR_BOOT_PATTERN}")" "2" \
  "ac-2 the by-design reboot produces exactly two boots"
assert_eq "$(boot_restart_count "$tmp/one.log" "${BR_REBOOT_PATTERN}")" "1" \
  "ac-2 ... and exactly one growth reboot line"
assert_eq "$(boot_restart_count "$tmp/loop.log" "${BR_REBOOT_PATTERN}")" "3" \
  "ac-3 a machine that keeps rebooting prints the line every time"

# --------------------------------------------------------------------------- #
# ac-1/ac-2/ac-3 the verdict, from the three counts
# --------------------------------------------------------------------------- #

assert_eq "$(boot_restart_verdict 1 0 "${BR_MAX_DEFAULT}")" "ok" \
  "ac-1 no reboot at all is a pass: not every disk has to grow"
assert_eq "$(boot_restart_verdict 2 1 "${BR_MAX_DEFAULT}")" "ok" \
  "ac-2 one reboot and the boot after it is the design working"
assert_eq "$(boot_restart_verdict 3 2 "${BR_MAX_DEFAULT}")" "restart-loop" \
  "ac-3 a second reboot is a restart loop"
assert_eq "$(boot_restart_verdict 2 2 "${BR_MAX_DEFAULT}")" "restart-loop" \
  "ac-3 two reboot lines are a loop even when the boot count still looks plausible"
assert_eq "$(boot_restart_verdict 3 1 "${BR_MAX_DEFAULT}")" "restart-loop" \
  "ac-3 a boot that never printed a banner still spends budget: three boots is a loop"
assert_eq "$(boot_restart_verdict 4 0 "${BR_MAX_DEFAULT}")" "restart-loop" \
  "ac-3 a panic loop with no growth line is a loop, not a slow boot"
assert_eq "$(boot_restart_verdict 1 0 0)" "ok" \
  "ac-1 the budget is a parameter: zero reboots allowed still passes a single boot"
assert_eq "$(boot_restart_verdict 2 1 0)" "restart-loop" \
  "ac-1 ... and refuses the reboot when the caller allows none"
assert_eq "$(boot_restart_verdict "" "" "${BR_MAX_DEFAULT}")" "ok" \
  "ac-1 empty counts read as zero instead of breaking the harness"

# --------------------------------------------------------------------------- #
# The three fixtures through the same check the harness runs
# --------------------------------------------------------------------------- #
# judge <serial> <stop pattern>: what qemu-smoke.sh concludes - the verdict first, then
# whether the stop pattern ever appeared. Kept here in the harness's order on purpose.
judge() {
    judge_log="$1"
    judge_stop="$2"
    judge_verdict="$(boot_restart_verdict \
        "$(boot_restart_count "${judge_log}" "${BR_BOOT_PATTERN}")" \
        "$(boot_restart_count "${judge_log}" "${BR_REBOOT_PATTERN}")" \
        "${BR_MAX_DEFAULT}")"
    if [ "${judge_verdict}" != "ok" ]; then
        printf 'restart-loop'
        return 0
    fi
    if grep -Eq "${judge_stop}" "${judge_log}"; then
        printf 'ok'
        return 0
    fi
    printf 'no-stop-pattern'
}

assert_eq "$(judge "$tmp/none.log" '^S3-RESULT=')" "ok" \
  "ac-1 a boot that never grew passes"
assert_eq "$(judge "$tmp/one.log" '^S3-RESULT=')" "ok" \
  "ac-2 a boot that grew in two stages passes"
assert_eq "$(judge "$tmp/loop.log" '^S3-RESULT=')" "restart-loop" \
  "ac-3 a guest that keeps restarting is reported as a loop, not as a missing line"
assert_eq "$(judge "$tmp/panic.log" '^S3-RESULT=')" "restart-loop" \
  "ac-3 ... and so is a panic loop"
: >"$tmp/stopped-early.log"
banner >>"$tmp/stopped-early.log"
assert_eq "$(judge "$tmp/stopped-early.log" '^S3-RESULT=')" "no-stop-pattern" \
  "ac-1 one boot without the stop pattern is a plain missing-line failure"

# --------------------------------------------------------------------------- #
# The harness has to be wired to all of it
# --------------------------------------------------------------------------- #
harness_src="$(cat "$harness")"

assert_contains "${harness_src}" '. "${CI_SCRIPT_DIR}/boot-restart.sh"' \
  "ac-1 qemu-smoke.sh sources the restart judgement"
# Comments may name the flag - that is how the removal stays explained - so only the code
# lines count.
harness_code="$(printf '%s\n' "${harness_src}" | sed -n '/^[[:space:]]*#/!p')"
assert_eq "$(printf '%s\n' "${harness_code}" | grep -c -F -- '-no-reboot' || :)" "0" \
  "ac-2 the guest may reboot: QEMU must not be told to exit instead"
assert_contains "${harness_src}" 'CI_QEMU_MAX_REBOOTS:-${BR_MAX_DEFAULT}' \
  "ac-1 the reboot budget defaults to one and stays overridable"
assert_contains "${harness_src}" 'CI_QEMU_REBOOT_PATTERN:-${BR_REBOOT_PATTERN}' \
  "ac-2 the trigger is the growth reboot line"
assert_contains "${harness_src}" 'boot_restart_verdict' \
  "ac-3 the harness asks for the verdict"
assert_contains "${harness_src}" 'restart-loop' \
  "ac-3 the failure is named restart-loop"
assert_contains "${harness_src}" 'ci_emit_output "reboots"' \
  "ac-3 the reboot count is part of the stage outputs"
assert_contains "${harness_src}" 'ci_emit_output "boots"' \
  "ac-3 ... together with the boot count"

# The order matters: a loop must never be reported as "the guest never printed the stop
# pattern", which is the message that made this look like a broken image.
verdict_line=$(printf '%s\n' "${harness_src}" | awk '/boot_restart_verdict/ && !/^[[:space:]]*#/ { print NR; exit }')
stop_die_line=$(printf '%s\n' "${harness_src}" | awk '/never printed the stop pattern/ && !/^[[:space:]]*#/ { print NR; exit }')
assert_eq "$(( verdict_line > 0 ))" "1" "ac-3 the verdict is evaluated in the harness"
assert_eq "$(( stop_die_line > verdict_line ))" "1" \
  "ac-3 ... before the stop-pattern failure, so a loop keeps its own diagnosis"

# The budget has to be enforced while the machine is still running, not only at the end:
# otherwise a loop costs the full 900s timeout on every stage.
assert_contains "${harness_src}" 'restart_budget_hit' \
  "ac-3 the harness stops the machine as soon as the budget is spent"

finish
