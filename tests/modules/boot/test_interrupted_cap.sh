#!/usr/bin/env bash
# Module: boot
# What happens after a candidate slot ran out of retries (ac-6 in the 2026-11-14 task), and
# where the pieces are wired in the three files that share this state.
#
# The machine cannot change slots in the middle of a boot - the kernel of the pending slot is
# already loaded - so "stop retrying" means: record it, move the menu back to the committed
# slot through the one writer that owns ab-slot.cfg (ab_slot_cfg_write_committed), drop the
# marker so the next candidate boot starts counting again, and reboot. A fail-safe that
# cannot write must not reboot: the machine boots the candidate it already started, which is
# the behaviour it had before this feature, and the marker stays for the next attempt.
#
#   ac-6  the abandonment records one line, clears the marker, and reboots exactly once
#   ac-6  when the fail-safe write fails the marker survives and no reboot is issued
#   ac-6  init calls the guard before it switches root, and escalates on abandon
#   ac-5  ab-boot publishes the interruption record into the ring log, once
#   ac-8  ab-commit clears both candidate and interruption record when it decides
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/reboot" <<STUB
#!/bin/sh
printf 'reboot %s\n' "\$*" >>"$tmp/reboot.trace"
STUB
chmod +x "$bin/reboot"
export PATH="$bin:$PATH"

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

# --- ac-6: the escalation path -------------------------------------------
rm -f "$marker" "$record" "$tmp/reboot.trace"
printf 'a %s 2\n' "$old" >"$marker"
# The guard leaves the record; the escalation is the half that moves the machine.
out=$(wf_boot_attempt_guard "$marker" a a "$now" 1)
assert_eq "$out" "abandon 3 $old" "ac-6 the guard hands over an abandon decision"

wf_failsafe_abandon() { WF_ABANDON_STATE=ok; }
wf_interrupted_escalate "$marker" a 3 "$old"
rc=$?
assert_eq "$rc" "0" "ac-6 a successful fail-safe write returns 0"
assert_eq "$([ -f "$marker" ] && echo kept || echo gone)" "gone" \
  "ac-6 the marker is dropped so the next candidate boot counts from 1"
assert_eq "$(grep -c '^reboot' "$tmp/reboot.trace" 2>/dev/null || echo 0)" "1" \
  "ac-6 the machine reboots exactly once into the committed slot"

# --- ac-6: a fail-safe that cannot write must not reboot ------------------
rm -f "$marker" "$record" "$tmp/reboot.trace"
printf 'a %s 2\n' "$old" >"$marker"
wf_failsafe_abandon() { WF_ABANDON_STATE=fail; }
wf_interrupted_escalate "$marker" a 3 "$old"
rc=$?
assert_eq "$rc" "1" "ac-6 a failed fail-safe write reports non-zero"
assert_eq "$([ -f "$marker" ] && echo kept || echo gone)" "kept" \
  "ac-6 the marker survives so the next boot can try again"
assert_eq "$([ -s "$tmp/reboot.trace" ] && echo rebooted || echo quiet)" "quiet" \
  "ac-6 a failed fail-safe write does not reboot into a slot the menu still points at"
assert_contains "$(cat "$record")" "result=abandon-failed" \
  "ac-6 the record stops claiming an abandon that did not happen"
assert_contains "$(cat "$record")" "reason=" \
  "ac-6 the failed abandon carries the reason the fail-safe reported"

# --- ac-5: ab-boot publishes the record into the ring log -----------------
boot_src="$(cat "$root/platform/etc/init.d/ab-boot")"
assert_contains "$boot_src" "ab/interrupted" "ac-5 ab-boot reads the interruption record"
assert_contains "$boot_src" "stage=interrupted" "ac-5 ab-boot writes a stage=interrupted line"
# One publication per boot: the record is removed after it lands, or an ESP that cannot be
# written would replay the same interruption on every boot forever.
publish_body="$(printf '%s\n' "$boot_src" | sed -n '/publish_interrupted()/,/^}/p')"
assert_contains "$publish_body" "rm -f" "ac-5 the record is cleared after it is published"
assert_contains "$publish_body" "log_append" "ac-5 the publication goes through the ring log"

# --- ac-5/ac-6: the init calls the guard before it switches root ----------
init_src="$(cat "$root/initramfs/boot/init")"
guard_line=$(printf '%s\n' "$init_src" | grep -n 'wf_boot_attempt_guard' | head -n1 | cut -d: -f1)
switch_line=$(printf '%s\n' "$init_src" | grep -n 'switching-root' | grep -v '^[0-9]*: *#' | head -n1 | cut -d: -f1)
assert_eq "$([ -n "$guard_line" ] && echo found || echo missing)" "found" \
  "ac-6 init runs the candidate guard"
assert_eq "$([ -n "$guard_line" ] && [ -n "$switch_line" ] && [ "$guard_line" -lt "$switch_line" ] && echo ordered || echo unordered)" \
  "ordered" "ac-6 the guard runs before the root switch (${guard_line:-?} < ${switch_line:-?})"
assert_contains "$init_src" "wf_interrupted_escalate" "ac-6 init escalates an abandon decision"
# An empty `last` field (a damaged or hand-edited marker) must not be read as an attempt
# number in the log line: `retry 2 ` has no timestamp, and printing the 2 as `last=` would
# be a line that lies about when the interrupted boot started.
assert_contains "$init_src" 'candidate_last="?"' \
  "ac-5 init names a missing timestamp instead of reusing the attempt"

# --- ac-8: ab-commit clears both files when it decides --------------------
commit_src="$(cat "$root/platform/etc/init.d/ab-commit")"
assert_contains "$commit_src" 'rm -f "${AB_ESP}/ab/candidate"' \
  "ac-8 ab-commit still clears the candidate marker"
assert_contains "$commit_src" 'rm -f "${AB_ESP}/ab/interrupted"' \
  "ac-8 ab-commit clears a stale interruption record as well"

finish
