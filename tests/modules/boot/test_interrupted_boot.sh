#!/usr/bin/env bash
# Module: boot
# The candidate-boot counter behind `stage=interrupted` (ac-5 in the 2026-11-14 task).
#
# A candidate first boot that never reaches ab-commit - a power cut, a hang - used to leave
# nothing behind: the marker looked exactly like a boot that had just started, GRUB kept
# selecting the same pending slot, and the machine retried it forever. The counter lives in
# the candidate marker itself (`<slot> <last-start-ts> <attempt>`) so the only writer on the
# boot path stays the initramfs, and ab-commit still removes the file when it decides.
#
#   ac-5  a pending slot that is not the one booted writes nothing
#   ac-5  the first candidate boot writes attempt 1 and records no interruption
#   ac-5  a marker left behind means the last candidate boot never finished: attempt+1,
#         and one `stage=interrupted ... result=retry` record naming the attempt and the
#         timestamp of the boot that did not finish
#   ac-5  a two-field marker from an older image counts as attempt 1, not as attempt 0
#   ac-5  a marker that names another slot is not this slot's history
#   ac-6  past AB_BOOT_RETRY_MAX the guard reports abandon and records why
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The guard writes under WF_ESP_MOUNT and logs through the serial mirror; both are fixtures.
WF_ESP_MOUNT="$tmp/esp"
WF_SERIAL=/dev/null
WF_CONSOLES=/dev/null
WF_MARK_LOG=""
export WF_ESP_MOUNT WF_SERIAL WF_CONSOLES WF_MARK_LOG
mkdir -p "$WF_ESP_MOUNT/ab"

# shellcheck source=initramfs/lib/wf.sh
source "$root/initramfs/lib/wf.sh"

marker="$WF_ESP_MOUNT/ab/candidate"
record="$WF_ESP_MOUNT/ab/interrupted"
now="2026-11-14T21:00:00Z"
old="2026-11-14T20:00:00Z"

reset() {
  rm -f "$marker" "$record"
}

# --- ac-5: not a candidate -------------------------------------------------
reset
out=$(wf_boot_attempt_guard "$marker" a none "$now" 1)
assert_eq "$out" "not-candidate" "ac-5 no pending slot is not a candidate boot"
assert_eq "$([ -f "$marker" ] && echo yes || echo no)" "no" \
  "ac-5 a non-candidate boot writes no marker"

reset
out=$(wf_boot_attempt_guard "$marker" b a "$now" 1)
assert_eq "$out" "not-candidate" "ac-5 pending=a booted on b is not a candidate boot"
assert_eq "$([ -f "$marker" ] && echo yes || echo no)" "no" \
  "ac-5 a mismatched slot writes no marker"

# --- ac-5: the first candidate boot ---------------------------------------
reset
out=$(wf_boot_attempt_guard "$marker" a a "$now" 1)
assert_eq "$out" "first" "ac-5 the first candidate boot is not an interruption"
assert_eq "$(cat "$marker")" "a $now 1" "ac-5 the first candidate boot records attempt 1"
assert_eq "$([ -f "$record" ] && echo yes || echo no)" "no" \
  "ac-5 a first candidate boot records no interruption"

# --- ac-5: a leftover marker is an interrupted boot ------------------------
reset
printf 'a %s 1\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 1)
assert_eq "$out" "retry 2 $old" "ac-5 a leftover marker retries with the new attempt and the old start"
assert_eq "$(cat "$marker")" "a $now 2" "ac-5 the marker carries the new attempt"
assert_contains "$(cat "$record")" "slot=a" "ac-5 the interruption record names the slot"
assert_contains "$(cat "$record")" "attempt=2" "ac-5 the interruption record names the attempt"
assert_contains "$(cat "$record")" "last=$old" "ac-5 the interruption record names the boot that did not finish"
assert_contains "$(cat "$record")" "result=retry" "ac-5 the interruption record says what happens next"

# --- ac-5: an older two-field marker counts as attempt 1 -------------------
reset
printf 'a %s\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 1)
assert_eq "$out" "retry 2 $old" "ac-5 a two-field marker from an older image counts as attempt 1"

# --- ac-5: another slot's marker is not this slot's history ---------------
reset
printf 'b %s 7\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 2)
assert_eq "$out" "first" "ac-5 a marker naming another slot restarts the count"
assert_eq "$(cat "$marker")" "a $now 1" "ac-5 the marker is rewritten for this slot"

# --- ac-6: past the cap ----------------------------------------------------
reset
printf 'a %s 2\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 1)
assert_eq "$out" "abandon 3 $old" "ac-6 a second interruption past the cap reports abandon"
assert_contains "$(cat "$record")" "result=abandon" "ac-6 the record says abandon"
assert_contains "$(cat "$record")" "reason=attempt-limit" "ac-6 the record names the limit as the reason"

reset
printf 'a %s 1\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 2)
assert_eq "$out" "retry 2 $old" "ac-6 a raised cap keeps retrying"
reset
printf 'a %s 2\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 2)
assert_eq "$out" "retry 3 $old" "ac-6 a raised cap allows the second retry"
reset
printf 'a %s 3\n' "$old" >"$marker"
out=$(wf_boot_attempt_guard "$marker" a a "$now" 2)
assert_eq "$out" "abandon 4 $old" "ac-6 the raised cap is honoured as well"

# --- the record is one line, so `grep stage=interrupted` stays mechanical ---
reset
printf 'a %s 1\n' "$old" >"$marker"
wf_boot_attempt_guard "$marker" a a "$now" 1 >/dev/null
assert_eq "$(wc -l <"$record" | tr -d ' ')" "1" "ac-5 the interruption record is exactly one line"


# --- the pending slot is read through the one library that owns it --------
# A second parser in the initramfs is how the boot path and the runtime start disagreeing
# about what "pending" means, so the helper asks platform/lib/ab-slot-cfg.sh.
printf '#!/bin/sh\nab_slot_state_pending() { printf "b"; }\n' >"$tmp/slot-cfg.sh"
WF_SLOT_CFG_LIB="$tmp/slot-cfg.sh"
assert_eq "$(wf_pending_slot "$tmp/state.json")" "b" \
  "ac-5 the pending slot comes from the shared slot-config library"
WF_SLOT_CFG_LIB="$tmp/no-such-lib.sh"
assert_eq "$(wf_pending_slot "$tmp/state.json")" "" \
  "ac-5 a missing slot-config library reads as unknown, never as pending"
finish
