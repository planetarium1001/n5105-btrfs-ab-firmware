#!/usr/bin/env bash
# Module: device
# Exercises the real-device driver without a device, a key or a network: a stub `ssh`
# on PATH answers with canned output, so everything below is about parsing, polling,
# verdicts and step order rather than about hardware.
#   ac-1 a status line is parsed field by field, and an unknown field is an error
#   ac-2 wait_up polls until the machine answers and prints nothing per attempt
#   ac-3 a payload reaches the guest over a stdin pipe, because it has no sftp-server
#   ac-4 a failing assertion exits non-zero and prints a line that can be pasted back
#   ac-5 results.tsv is TAB separated, append-only and limited to PASS/FAIL/GAP
#   ac-6 matrix.sh --dry-run prints the fixed skeleton in order and touches nothing
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the stub machine ------------------------------------------------------ #
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"

# A fake `ssh` that records its argv and answers the few questions the driver asks.
# The device command is the last argument, which is how ssh itself passes it on.
cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for arg in "$@"; do last="$arg"; done
case "${last}" in
    *"ab-slot status"*)
        # A queue makes the status line change between polls, which is what a machine
        # that has not finished committing looks like from the outside.
        if [ -n "${STUB_STATUS_QUEUE:-}" ] && [ -s "${STUB_STATUS_QUEUE}" ]; then
            head -n 1 "${STUB_STATUS_QUEUE}"
            tail -n +2 "${STUB_STATUS_QUEUE}" >"${STUB_STATUS_QUEUE}.tmp"
            mv "${STUB_STATUS_QUEUE}.tmp" "${STUB_STATUS_QUEUE}"
            exit 0
        fi
        cat "${STUB_STATUS_FILE:?stub needs STUB_STATUS_FILE}"
        printf 'ab-slot: running slot a, the human summary goes to stderr\n' >&2
        exit 0
        ;;
    *"ab-slot rootfs"*)
        printf '%s\n' "${STUB_RUNNING_VERSION:-25.12.2}"
        exit 0
        ;;
    "cat /boot/ab/state.json")
        cat "${STUB_STATE_FILE:?stub needs STUB_STATE_FILE}"
        ;;
    true)
        n=$(( $(cat "${STUB_UP_COUNTER:?stub needs STUB_UP_COUNTER}" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" >"${STUB_UP_COUNTER}"
        [ "$n" -gt "${STUB_UP_AFTER:-0}" ]
        ;;
    *"cat >"*)
        cat >"${STUB_PUSH_DEST:?stub needs STUB_PUSH_DEST}"
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$stub_bin/ssh"

# wait_up sleeps five seconds between attempts; on the test host the only thing that
# sleep has to do is not take five seconds.
printf '#!/bin/sh\nexit 0\n' >"$stub_bin/sleep"
chmod +x "$stub_bin/sleep"

STUB_CALLS="$tmp/calls.log"
STUB_STATUS_FILE="$tmp/status.txt"
STUB_UP_COUNTER="$tmp/up.counter"
STUB_PUSH_DEST="$tmp/pushed.bin"
STUB_PUSH_CMD_FILE="$tmp/push-cmd.txt"
STUB_STATE_FILE="$tmp/state.json"
export STUB_CALLS STUB_STATUS_FILE STUB_UP_COUNTER STUB_PUSH_DEST STUB_STATE_FILE
export PATH="$stub_bin:$PATH"

# One healthy machine, in the shape ab-slot status really prints: one line on stdout,
# the human summary on stderr, disk identity carried as two extra tokens.
cat >"$STUB_STATUS_FILE" <<'STATUS'
slot=a upper=@overlay-25.12.2 generation=7 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=by-id boot=ok esp=ok
STATUS

# The state file as ab-slot writes it: one slot per line, both slots' layers visible.
cat >"$STUB_STATE_FILE" <<'STATE'
{
  "generation": 7,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" },
    "b": { "rootfs": "25.12.1", "upper": "@overlay-25.12.1" }
  }
}
STATE

AB_REPO_ROOT="$root"
AB_HOST="root@stub"
AB_KEY="$tmp/abkey"
AB_RESULTS="$tmp/results.tsv"
AB_ASSERT_FAILURES=0
export AB_REPO_ROOT AB_HOST AB_KEY AB_RESULTS
# shellcheck source=../../../scripts/device/lib.sh
. "$root/scripts/device/lib.sh"

: >"$STUB_CALLS"

# --- ac-1: status parsing -------------------------------------------------- #
assert_eq "$(dev_status_field boot)" "ok" "boot= is read from the status line"
assert_eq "$(dev_status_field esp)" "ok" "esp= is read from the status line"
assert_eq "$(dev_status_field generation)" "7" "generation= is read as an integer"
assert_eq "$(dev_status_field upper)" "@overlay-25.12.2" "upper= keeps its leading @"
assert_eq "$(dev_status_field next)" "a" "next= is the GRUB hint"
assert_eq "$(dev_status_field method)" "by-id" "a field after the two-word disk identity is still found"

rc=0
dev_status_field nosuchfield >/dev/null 2>&1 || rc=1
assert_eq "$rc" "1" "an absent field exits non-zero instead of printing nothing"
rc=0
dev_status_field 'bad field' >/dev/null 2>&1 || rc=1
assert_eq "$rc" "1" "a field name that is not a token is rejected"
assert_contains "$(cat "$STUB_CALLS")" "ab-slot status" "the status line comes from ab-slot status"
assert_contains "$(cat "$STUB_CALLS")" "-o ControlPath=none" "ssh runs without a control socket"
assert_contains "$(cat "$STUB_CALLS")" "-o BatchMode=yes" "ssh cannot stop for a prompt"
assert_contains "$(cat "$STUB_CALLS")" "UserKnownHostsFile=/dev/null" "a reflashed host key is not an obstacle"

# --- ac-2: wait_up --------------------------------------------------------- #
printf '0\n' >"$STUB_UP_COUNTER"
export STUB_UP_AFTER=1
out=$(dev_wait_up 30 2>&1)
assert_eq "$?" "0" "wait_up succeeds once the machine answers"
assert_eq "$out" "" "wait_up prints nothing per attempt"
assert_eq "$(cat "$STUB_UP_COUNTER")" "2" "wait_up stops on the first answer instead of polling out the budget"

printf '0\n' >"$STUB_UP_COUNTER"
export STUB_UP_AFTER=99
dev_wait_up 15 >/dev/null 2>&1
assert_eq "$?" "1" "wait_up fails when the machine never comes back within the budget"
assert_eq "$(cat "$STUB_UP_COUNTER")" "3" "the timeout buys three five-second attempts, not an endless loop"

# The budgets come from the measured start-up on the reference machine (ssh ~8-10 s),
# so the numbers below are what a caller actually gets, and the hard cap is a ceiling
# that no caller can raise by asking for more.
printf '0\n' >"$STUB_UP_COUNTER"
dev_wait_up >/dev/null 2>&1
assert_eq "$(cat "$STUB_UP_COUNTER")" "24" "the default budget is the 120 s plain reboot (24 x 5 s)"

printf '0\n' >"$STUB_UP_COUNTER"
dev_wait_up_after after-install >/dev/null 2>&1
assert_eq "$(cat "$STUB_UP_COUNTER")" "36" "the first boot of a new rootfs waits 180 s (36 x 5 s)"
printf '0\n' >"$STUB_UP_COUNTER"
dev_wait_up_after plain >/dev/null 2>&1
assert_eq "$(cat "$STUB_UP_COUNTER")" "24" "a plain reboot waits 120 s (24 x 5 s)"

printf '0\n' >"$STUB_UP_COUNTER"
dev_wait_up 1000 >/dev/null 2>&1
assert_eq "$(cat "$STUB_UP_COUNTER")" "40" "the hard cap stops at 200 s (40 x 5 s) even when a caller asks for longer"

# --- settle: a boot that has not committed yet is not a red machine -------- #
# wait_up answers when dropbear is up, before the initramfs has written the commit, so
# the status line has to be allowed to move from pending=<slot> to pending=none.
queue="$tmp/status.queue"
cat >"$queue" <<'QUEUE'
slot=a upper=@overlay-25.12.2 generation=8 committed=a pending=b p4=ok data=ok docker=ok swap=ok next=b disk=/dev/sda method=by-id boot=pending esp=ok
slot=b upper=@overlay-25.12.1 generation=8 committed=b pending=none p4=ok data=ok docker=ok swap=ok next=b disk=/dev/sda method=by-id boot=ok esp=ok
QUEUE
export STUB_STATUS_QUEUE="$queue"
out=$(dev_wait_settled 30 2>&1)
assert_eq "$?" "0" "settle returns the line of a boot that finished committing"
assert_contains "$out" "committed=b pending=none" "settle waits past the queued candidate instead of reporting it"
assert_contains "$out" "boot=ok" "settle returns the healthy line, not the first one it saw"

printf '%s\n%s\n' \
    'slot=a upper=@overlay-25.12.2 generation=8 committed=a pending=b p4=ok data=ok docker=ok swap=ok next=b disk=/dev/sda method=by-id boot=pending esp=ok' \
    'slot=a upper=@overlay-25.12.2 generation=8 committed=a pending=b p4=ok data=ok docker=ok swap=ok next=b disk=/dev/sda method=by-id boot=pending esp=ok' >"$queue"
out=$(dev_wait_settled 10 2>&1)
assert_eq "$?" "0" "settle still returns the last line it saw when the boot never commits"
assert_contains "$out" "pending=b" "the never-settled line is reported, so the field assertions can name it"

: >"$tmp/empty-status"
: >"$queue"
export STUB_STATUS_FILE="$tmp/empty-status"
out=$(dev_wait_settled 10 2>&1)
assert_eq "$?" "1" "settle fails when no status line can be read at all"
export STUB_STATUS_FILE="$tmp/status.txt"
unset STUB_STATUS_QUEUE

# --- ac-3: push over a stdin pipe ------------------------------------------ #
printf 'PAYLOAD-BYTES-25.12.1' >"$tmp/payload-25.12.1.tar"
: >"$STUB_CALLS"
dev_push "$tmp/payload-25.12.1.tar" /tmp/payload-25.12.1.tar
assert_eq "$?" "0" "dev_push reports success"
assert_eq "$(cat "$STUB_PUSH_DEST")" "PAYLOAD-BYTES-25.12.1" "the bytes arrive on the remote command's stdin"
push_calls=$(cat "$STUB_CALLS")
assert_contains "$push_calls" "cat > /tmp/payload-25.12.1.tar" "the remote side is a plain shell redirect"
rc=0
printf '%s' "$push_calls" | grep -q 'scp' || rc=1
assert_eq "$rc" "1" "no scp is attempted, the guest image has no sftp-server"

dev_push "$tmp/does-not-exist.tar" /tmp/x.tar >/dev/null 2>&1
assert_eq "$?" "1" "a missing local file is refused before ssh runs"

# --- ac-4: a failing assertion is a usable line ---------------------------- #
AB_STATUS_LINE="slot=a upper=@overlay-25.12.2 generation=7 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=by-id boot=degraded esp=ok"
AB_EVIDENCE_LOG="$tmp/M1.log"
: >"$AB_EVIDENCE_LOG"
out=$(assert_field boot ok M1 2>&1)
rc=$?
assert_eq "$rc" "1" "assert_field exits non-zero when the field disagrees"
assert_contains "$out" "FAIL M1 assert_field boot" "the failure names the case and the field"
assert_contains "$out" "expected=ok got=degraded" "the failure states both values"
assert_contains "$out" "rerun: ./scripts/device/matrix.sh --case M1" "the failure carries the reproducing command"
assert_contains "$(cat "$AB_EVIDENCE_LOG")" "FAIL M1 assert_field boot" "the failure is written to the evidence log too"

AB_STATUS_LINE="slot=a upper=@overlay-25.12.2 generation=7 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=by-id boot=ok esp=ok"
assert_field boot ok M1
assert_eq "$?" "0" "assert_field is silent and zero when the field agrees"

assert_ge 7 6 M1 generation
assert_eq "$?" "0" "assert_ge accepts a growing generation"
assert_ge 7 7 M1 generation
assert_eq "$?" "0" "assert_ge accepts an unchanged generation"
out=$(assert_ge 7 8 M1 generation 2>&1)
assert_eq "$?" "1" "assert_ge rejects a generation that went backwards"
assert_contains "$out" "expected>=8 got=7" "the generation failure states both values"
out=$(assert_ge "" 8 M1 generation 2>&1)
assert_eq "$?" "1" "assert_ge refuses to compare an empty value as zero"

AB_LAYERS="@overlay-25.12.2 @overlay-25.12.1 "
assert_layer_count 2 M1
assert_eq "$?" "0" "a layer count can still be reported as a hint"
AB_LAYERS="@overlay-25.12.2 "
assert_layer_count 2 M1 >/dev/null 2>&1
assert_eq "$?" "1" "the hint disagrees when the count moves"
# --- ac-4b: the layer invariant ------------------------------------------- #
# Both slots exist, both are named, nothing else is on the partition: the steady state.
AB_LAYERS="@overlay-25.12.2 @overlay-25.12.1 "
AB_UPPER_A="@overlay-25.12.2"
AB_UPPER_B="@overlay-25.12.1"
out=$(assert_layer_invariant M1 2>&1)
assert_eq "$?" "0" "two layers, each named by a slot, is the steady state"
assert_eq "$out" "" "a passing invariant prints nothing"

AB_LAYERS="@overlay-25.12.2 "
AB_UPPER_A="@overlay-25.12.2"
AB_UPPER_B="@overlay-25.12.1"
out=$(assert_layer_invariant M1 2>&1)
assert_contains "$out" "@overlay-25.12.1 is missing from the partition" \
    "a slot whose layer is gone is an invariant failure even when the count looks right"


# Installing 25.12.2 a second time gives the target slot @overlay-25.12.2-r2 while the
# other slot keeps @overlay-25.12.2: two layers, both named, and the suffix is healthy.
AB_LAYERS="@overlay-25.12.2 @overlay-25.12.2-r2 "
AB_UPPER_A="@overlay-25.12.2"
AB_UPPER_B="@overlay-25.12.2-r2"
assert_layer_invariant M1
assert_eq "$?" "0" "an upper with a -r2 suffix is healthy, not a leaked layer"
# Four layers is a steady state too, as long as the two slots name two of them and the
# rest are history a later gc will reclaim -- which is exactly what this must reject.
AB_LAYERS="@overlay-25.12.2 @overlay-25.12.2-r2 @overlay-25.12.1 "
AB_UPPER_A="@overlay-25.12.2"
AB_UPPER_B="@overlay-25.12.1"
out=$(assert_layer_invariant M1 2>&1)
assert_eq "$?" "1" "a third layer that no slot names is a leak even when both uppers exist"
assert_contains "$out" "@overlay-25.12.2-r2 is referenced by no slot" \
    "the failure names the layer no slot points at"

# One layer nobody points at will never be reclaimed: that is the leak to catch.
AB_LAYERS="@overlay-25.12.2 @overlay-25.12.1 @overlay-x "
AB_UPPER_A="@overlay-25.12.2"
AB_UPPER_B="@overlay-25.12.1"
out=$(assert_layer_invariant M1 2>&1)
assert_eq "$?" "1" "an unreferenced @overlay-* makes the invariant fail"
assert_contains "$out" "@overlay-x is referenced by no slot" "the failure names the leaked layer"
assert_contains "$out" "layers='@overlay-25.12.2 @overlay-25.12.1 @overlay-x '" \
    "the failure prints the whole layer list"
assert_contains "$out" "uppers='a=@overlay-25.12.2 b=@overlay-25.12.1'" \
    "the failure prints both slots' uppers so it can be read without ssh"

AB_LAYERS="@overlay-25.12.2 @overlay-25.12.1 "
AB_UPPER_A=""
AB_UPPER_B="@overlay-25.12.1"
out=$(assert_layer_invariant M1 2>&1)
assert_eq "$?" "1" "a slot that records no layer fails even when the partition looks tidy"
assert_contains "$out" "slot a records no layer" "the failure names the slot without a layer"
AB_UPPER_A="@overlay-25.12.2"

# dev_slot_upper reads the other slot's layer out of the state file, which is the only
# place ab-slot records it: `ab-slot status` names the running slot alone.
assert_eq "$(dev_slot_upper a)" "@overlay-25.12.2" "the running slot's layer comes from the state file"
assert_eq "$(dev_slot_upper b)" "@overlay-25.12.1" "the inactive slot's layer comes from the state file"
rc=0
dev_slot_upper c >/dev/null 2>&1 || rc=1
assert_eq "$rc" "1" "a slot name that is not a or b is refused"

# --- ac-4c: the boot log lives in the ring, not in one fixed file ---------- #
bootdir="$tmp/bootlogs"
mkdir -p "$bootdir"
boot0="$bootdir/boot-0.log"
boot1="$bootdir/boot-1.log"
AB_EVIDENCE_LOG="$tmp/M1-boot.log"
: >"$AB_EVIDENCE_LOG"
AB_BOOT_LOG_LOCAL="$boot0"
AB_BOOT_LOG_PREV_LOCAL="$boot1"

# The current boot wrote both breadcrumbs: the answer is boot-0.log.
cat >"$boot0" <<'LOG'
stage=slot-cfg slot=a
stage=healthcheck-done slot=a result=ok
stage=commit slot=a upper=@overlay-25.12.2 rootfs=25.12.2 result=ok action=commit
LOG
: >"$boot1"
out=$(assert_boot_log M1 25.12.2 2>&1)
assert_eq "$?" "0" "breadcrumbs in boot-0.log pass"
assert_contains "$(cat "$AB_EVIDENCE_LOG")" "boot-mark healthcheck-done: hit boot-0.log" \
    "the evidence records which file answered"
assert_contains "$(cat "$AB_EVIDENCE_LOG")" "boot-mark commit-line: hit boot-0.log" \
    "the commit line records its source too"

# The ring rotated: what the hop needs to see is only in boot-1.log. Grepping boot-0.log
# alone is what used to turn every healthy hop red.
: >"$AB_EVIDENCE_LOG"
cat >"$boot1" <<'LOG'
stage=healthcheck-done slot=a result=ok
stage=commit slot=a upper=@overlay-25.12.2 rootfs=25.12.2 result=ok action=commit
LOG
printf 'stage=device slot=a\n' >"$boot0"
out=$(assert_boot_log M1 25.12.2 2>&1)
assert_eq "$?" "0" "breadcrumbs only in boot-1.log still pass"
assert_eq "$out" "" "a rotated hit is not a failure line"
assert_contains "$(cat "$AB_EVIDENCE_LOG")" "boot-mark healthcheck-done: hit boot-1.log" \
    "the evidence says the previous boot's file carried the breadcrumb"

# Neither file has it and `ab-slot log --prev` has no answer either: that is a red hop,
# and the failure has to name every source that was searched.
: >"$AB_EVIDENCE_LOG"
printf 'stage=device slot=a\n' >"$boot0"
printf 'stage=grow result=ok\n' >"$boot1"
out=$(assert_boot_log M1 25.12.2 2>&1)
assert_eq "$?" "1" "a breadcrumb that no source has fails"
assert_contains "$out" "FAIL M1 assert_boot_mark healthcheck-done" "the failure names the breadcrumb"
assert_contains "$out" "boot-0.log" "the failure names the file that was searched first"
assert_contains "$out" "boot-1.log" "the failure names the rotated file"
assert_contains "$out" "ab-slot log --prev" "the failure names the last resort that was tried"

# A healthcheck line without the commit line of the version under test: the commit
# pattern has to keep the version literal, or 25.12.20 would satisfy a 25.12.2 hop.
cat >"$boot0" <<'LOG'
stage=healthcheck-done slot=a result=ok
stage=commit slot=a upper=@overlay-25.12.20 rootfs=25.12.20 result=ok action=commit
LOG
: >"$boot1"
: >"$AB_EVIDENCE_LOG"
out=$(assert_boot_log M1 25.12.2 2>&1)
assert_eq "$?" "1" "a commit line for a different version does not satisfy the hop"
assert_contains "$out" "rootfs=25\\.12\\.2" "the version is matched literally, so 25.12.20 cannot pass"
AB_BOOT_LOG_LOCAL=""
AB_BOOT_LOG_PREV_LOCAL=""

# --- ac-5: results.tsv ----------------------------------------------------- #
AB_RESULTS="$tmp/results.tsv"
record M1 PASS "$tmp/M1.log" "two hops committed"
record M2 FAIL - "hop 1 failed"
record M3 GAP - "payload for 25.12.0 missing"
assert_eq "$(wc -l <"$AB_RESULTS" | tr -d ' ')" "3" "three cases produce three rows"
assert_eq "$(awk -F'\t' 'NF != 4' "$AB_RESULTS" | wc -l | tr -d ' ')" "0" "every row has four TAB separated columns"
assert_eq "$(awk -F'\t' '{print $2}' "$AB_RESULTS" | tr '\n' ' ')" "PASS FAIL GAP " "all three verdicts are accepted"
assert_eq "$(awk -F'\t' 'NR == 2 {print $3}' "$AB_RESULTS")" "-" "a missing evidence path is recorded as a dash"

record M4 PASS - "note with	a tab"
assert_eq "$(awk -F'\t' 'NR == 4 {print NF}' "$AB_RESULTS")" "4" "a tab inside a note cannot shift the columns"

rc=0
record M5 BROKEN - "nope" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "an unknown verdict is refused instead of written"

record_passed M1
assert_eq "$?" "0" "--resume sees an earlier PASS"
rc=0
record_passed M2 || rc=1
assert_eq "$rc" "1" "--resume does not skip a case that failed"

# --- ac-6: dry-run order --------------------------------------------------- #
dry_dir="$tmp/dry"
calls_before=$(wc -l <"$STUB_CALLS" | tr -d ' ')
out=$(sh "$root/scripts/device/matrix.sh" --dry-run --payload-dir "$tmp/payloads" --results "$dry_dir/results.tsv" 2>&1)
assert_eq "$?" "0" "matrix.sh --dry-run exits zero"
assert_eq "$(printf '%s\n' "$out" | grep '^# case ' | awk '{print $3}' | tr '\n' ' ')" \
    "M1 M2 M3 M4 M5 M6 M7 " "the seven cases are planned in order"
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "M1" && $2 == "1/2" {print $3}' | tr '\n' ',')" \
    "unmount,push,check,install,reboot,wait_up,settle,status,collect,assert,assert,assert,assert," \
    "one hop runs the fixed skeleton in order"
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "M1" && $2 == "2/2" {print $3}' | tr '\n' ',' | cut -d, -f1)" \
    "unmount" "M1 plans a second hop for the last version"
assert_contains "$out" "M1 1/2 assert boot=ok esp=ok" "the assert step names the fields it reads"
assert_contains "$out" "M1 1/2 assert boot-log healthcheck-done-result-ok commit-action-commit in boot-0.log, else boot-1.log, else \`ab-slot log --prev\`" \
    "the plan says where the breadcrumb is searched, in the order the ring log dictates"
assert_contains "$out" "M1 1/2 collect /boot/ab/log/boot-0.log /boot/ab/log/boot-1.log (a missing file is not an error)" \
    "the plan collects both ring files and lets boot-1.log be missing"
assert_contains "$out" "M1 1/2 assert layer-invariant every slot upper exists and no unreferenced @overlay-* survives" \
    "the layer step asserts the invariant, not a count"
assert_contains "$out" "M1 1/2 unmount /mnt/slots/a /mnt/slots/b (left behind by an earlier --check; their absence is deliberately not asserted)" \
    "the plan unmounts leftovers instead of asserting that none appear"
assert_contains "$out" "state.json unchanged; --check still rewrites ab/conflicts.log" \
    "the plan no longer claims --check is read-only"
assert_contains "$out" "M5 check /tmp/payload-25.12.2.tar expect=74-payload-already-installed-or-0" \
    "M5 plans for a same-version refusal"
assert_contains "$out" "M7 check /tmp/payload-bad.tar expect=exit-74" "M7 plans for a refusal, not an install"
rc=0
printf '%s\n' "$out" | grep -q '^M7 .*install' || rc=1
assert_eq "$rc" "1" "M7 never plans an install"
[ -e "$dry_dir/results.tsv" ] && rc=0 || rc=1
assert_eq "$rc" "1" "a dry run writes no results file"
assert_eq "$(wc -l <"$STUB_CALLS" | tr -d ' ')" "$calls_before" \
    "a dry run leaves the stub untouched, so nothing reached a machine"

# The planned wait comes from the measured budgets, not from a literal in the plan: a
# machine with a different start-up is handled by changing the constants.
assert_contains "$out" "M1 1/2 wait_up 180 (plain reboot 120, hard cap 200)" \
    "the plan uses the after-install budget and prints the plain budget and the cap"
assert_contains "$out" "settle until boot=ok pending=none (wait_up answers before the commit lands; 20 s left of the 200 s cap)" \
    "the settle poll is planned as the rest of the hard cap, not as a fourth budget"
assert_eq "$AB_WAIT_SETTLE" "20" "one boot stays inside the 200 s cap: 180 s of wait_up plus 20 s of settle"
assert_eq "$(AB_WAIT_UP_HARD=30 AB_WAIT_UP_FIRST=10 sh -c \
    '. "${1}/scripts/device/lib.sh"; printf %s "${AB_WAIT_SETTLE}"' _ "$root")" "20" \
    "the remainder follows the constants rather than a fixed number"
assert_eq "$(AB_WAIT_UP_HARD=4 AB_WAIT_UP_FIRST=4 sh -c \
    '. "${1}/scripts/device/lib.sh"; printf %s "${AB_WAIT_SETTLE}"' _ "$root")" "5" \
    "a cap smaller than one poll interval still leaves one poll"
budget_out=$(AB_WAIT_UP_FIRST=240 AB_WAIT_UP=90 AB_WAIT_UP_HARD=260 \
    sh "$root/scripts/device/matrix.sh" --dry-run --case M1 --payload-dir "$tmp/payloads" \
    --results "$tmp/dry-budget/results.tsv" 2>&1)
assert_contains "$budget_out" "M1 1/2 wait_up 240 (plain reboot 90, hard cap 260)" \
    "overriding the constants changes the plan, so the plan is not hardcoded"

# --- M6 is the long chain -------------------------------------------------- #
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "M6" && $3 == "push" {print $4}' | wc -l | tr -d ' ')" \
    "6" "M6 is six changes of direction"
assert_eq "$(printf '%s\n' "$out" | awk '$1 == "M6" && $3 == "push" {print $4}' | sed -e 's|.*payload-||' -e 's|\.tar||' | tr '\n' ' ')" \
    "25.12.1 25.12.2 25.12.1 25.12.2 25.12.1 25.12.2 " \
    "M6 alternates direction twice"

# --- matrix.sh end to end against a simulated device ----------------------- #
# The stub above answers single questions; this one keeps a state directory and
# moves it the way ab-upgrade, ab-slot and a reboot really move it. That is what makes
# the whole skeleton runnable without hardware: a case either produces PASS, FAIL or a
# red-line abort, and the test checks which.

devbin="$tmp/devbin"
mkdir -p "$devbin"
cat >"$devbin/ssh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
last=""
for arg in "$@"; do last="$arg"; done
dev=${FAKE_DEV:?}
slot=$(cat "$dev/committed")
if [ "$slot" = "a" ]; then other=b; else other=a; fi
version_of() { printf '%s' "$1" | sed -e 's|.*/payload-||' -e 's|\.tar$||'; }
pending=$(cat "$dev/pending")
case "${last}" in
    "ab-slot status")
        if [ "$pending" = "none" ]; then next=${slot}; else next=${pending}; fi
        printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/sda method=by-id boot=%s esp=ok\n' \
            "${slot}" "$(cat "$dev/upper-${slot}")" "$(cat "$dev/generation")" \
            "${slot}" "${pending}" "${next}" "$(cat "$dev/boot")"
        ;;
    "ab-slot rootfs")
        cat "$dev/rootfs-${slot}"
        ;;
    "ab-slot gc")
        exit 0
        ;;
    "btrfs subvolume list /mnt/p4")
        printf 'ID 256 gen 10 top level 5 path %s\n' "$(cat "$dev/upper-a")"
        printf 'ID 257 gen 11 top level 5 path %s\n' "$(cat "$dev/upper-b")"
        # A layer nobody references is a leak; the invariant has to find it.
        [ -n "${FAKE_ORPHAN_LAYER:-}" ] && printf 'ID 258 gen 12 top level 5 path %s\n' "${FAKE_ORPHAN_LAYER}"
        ;;
    "cat /boot/ab/state.json")
        # ab-slot writes one slot per line; both slots' layers are the reference set.
        if [ "${pending}" = "none" ]; then pend=null; else pend="\"${pending}\""; fi
        printf '{\n  "generation": %s,\n  "committed": "%s",\n  "pending": %s,\n  "slots": {\n' \
            "$(cat "$dev/generation")" "${slot}" "${pend}"
        printf '    "a": { "rootfs": "%s", "upper": "%s" },\n' "$(cat "$dev/rootfs-a")" "$(cat "$dev/upper-a")"
        printf '    "b": { "rootfs": "%s", "upper": "%s" }\n' "$(cat "$dev/rootfs-b")" "$(cat "$dev/upper-b")"
        printf '  }\n}\n'
        ;;
    "ab-upgrade --check "*)
        ver=$(version_of "${last}")
        if [ "${ver}" = "bad" ]; then
            printf 'ab-upgrade: refused, reason=digest-mismatch-rootfs.tar.gz\n'
            exit 74
        fi
        if [ "${ver}" = "$(cat "$dev/rootfs-${slot}")" ]; then
            printf 'ab-upgrade: slot %s already runs %s\n' "${slot}" "${ver}"
            printf 'ab-upgrade: refused, reason=payload-already-installed\n'
            exit 74
        fi
        printf 'ab-upgrade: %s validated\n' "${ver}"
        ;;
    "ab-upgrade "*)
        ver=$(version_of "${last}")
        printf '%s' "${ver}" >"$dev/rootfs-${other}"
        printf '@overlay-%s%s' "${ver}" "${FAKE_LAYER_SUFFIX:-}" >"$dev/upper-${other}"
        printf '%s' "${other}" >"$dev/pending"
        printf '%s' "$(( $(cat "$dev/generation") + 1 ))" >"$dev/generation"
        printf 'ab-upgrade: installed %s into slot %s\n' "${ver}" "${other}"
        ;;
    "sync; reboot")
        if [ "${pending}" != "none" ]; then
            printf '%s' "${pending}" >"$dev/committed"
            printf 'none' >"$dev/pending"
            {
                printf 'stage=healthcheck-done slot=%s upper=%s rootfs=%s result=ok\n' \
                    "${pending}" "$(cat "$dev/upper-${pending}")" "$(cat "$dev/rootfs-${pending}")"
                printf 'stage=commit slot=%s upper=%s rootfs=%s result=ok action=commit\n' \
                    "${pending}" "$(cat "$dev/upper-${pending}")" "$(cat "$dev/rootfs-${pending}")"
            } >"$dev/${FAKE_BOOT_LOG_DEST:-boot-0.log}"
        fi
        printf '%s' "${FAKE_BOOT_AFTER:-ok}" >"$dev/boot"
        ;;
    *"cat >"*)
        cat >/dev/null
        ;;
    "cat "*)
        cat "$dev/$(basename "${last#cat }")" 2>/dev/null || exit 1
        ;;
    *"uci get"*)
        cat "$dev/hostname"
        ;;
    "true")
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKE
chmod +x "$devbin/ssh"
printf '#!/bin/sh\nexit 0\n' >"$devbin/sleep"
chmod +x "$devbin/sleep"

FAKE_DEV="$tmp/device"
export FAKE_DEV
export PATH="$devbin:$PATH"

setup_fake_device() { # <version the machine runs>
    rm -rf "$FAKE_DEV"
    mkdir -p "$FAKE_DEV"
    printf 'a' >"$FAKE_DEV/committed"
    printf 'none' >"$FAKE_DEV/pending"
    printf '3' >"$FAKE_DEV/generation"
    printf 'ok' >"$FAKE_DEV/boot"
    printf '%s' "$1" >"$FAKE_DEV/rootfs-a"
    printf '@overlay-%s' "$1" >"$FAKE_DEV/upper-a"
    printf '%s' "$1" >"$FAKE_DEV/rootfs-b"
    printf '@overlay-%s' "$1" >"$FAKE_DEV/upper-b"
    printf 'ab-test\n' >"$FAKE_DEV/hostname"
    printf 'marker-token\n' >"$FAKE_DEV/ab-matrix.marker"
    : >"$FAKE_DEV/boot-0.log"
    rm -f "$FAKE_DEV/boot-1.log"
}

payloads="$tmp/payloads"
mkdir -p "$payloads"
for v in 25.12.0 25.12.1 25.12.2; do
    printf 'payload %s\n' "$v" >"$payloads/payload-${v}.tar"
done
printf 'broken payload\n' >"$payloads/payload-bad.tar"

run_matrix() { # <results dir> [matrix args...]
    _dir=$1
    shift
    AB_WAIT_UP=10 AB_WAIT_UP_FIRST=10 AB_WAIT_UP_HARD=20 \
        sh "$root/scripts/device/matrix.sh" \
        --payload-dir "$payloads" --results "$_dir/results.tsv" "$@" 2>&1
}

# A downgrade on a machine that already runs the higher version: the whole skeleton,
# one hop, and the row the Lead reads.
setup_fake_device 25.12.2
: >"$STUB_CALLS"
out=$(run_matrix "$tmp/e2e-pass" --case M3)
assert_eq "$?" "0" "a healthy downgrade exits zero"
assert_eq "$(awk -F'\t' 'NR == 1 {print $1" "$2}' "$tmp/e2e-pass/results.tsv")" "M3 PASS" \
    "a healthy downgrade records one PASS row"
assert_eq "$(cat "$FAKE_DEV/committed")" "b" "the downgrade committed the other slot"
assert_eq "$(cat "$FAKE_DEV/rootfs-b")" "25.12.1" "the committed slot carries the target version"
assert_eq "$(cat "$FAKE_DEV/generation")" "4" "the install bumped generation once"
assert_contains "$out" "M3: 1 hop(s) committed" "the summary names how far the case got"
assert_file_exists "$tmp/e2e-pass/evidence/$(date -u +%Y%m%d)-m3.log" "the evidence log is where the results row points"

# The same hop, on a machine whose new slot boots degraded: the verdict has to be FAIL,
# and only because the field says so.
setup_fake_device 25.12.2
export FAKE_BOOT_AFTER=degraded
out=$(run_matrix "$tmp/e2e-fail" --case M3)
rc=$?
unset FAKE_BOOT_AFTER
assert_eq "$rc" "1" "a degraded boot makes the run non-zero"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-fail/results.tsv")" "FAIL" \
    "a degraded boot records FAIL"
assert_contains "$out" "expected=ok got=degraded" "the failing field is named"

# A pass is only believable if it says what it looked at: the evidence records which ring
# file carried the breadcrumb and that the layer invariant held.
m3log="$tmp/e2e-pass/evidence/$(date -u +%Y%m%d)-m3.log"
assert_contains "$(cat "$m3log")" "boot-mark commit-line: hit boot-0.log" \
    "the evidence records that the current boot's file carried the commit line"
assert_contains "$(cat "$m3log")" "layer-invariant ok" "the evidence records the layer invariant"
assert_contains "$(cat "$m3log")" "pre-check: /mnt/slots/* unmounted" \
    "the evidence records the unmount that ab-upgrade --check does not guarantee"

# The ring rotated: the commit line is only in boot-1.log, which is what a machine that
# rebooted more than once really looks like. The hop must still pass.
setup_fake_device 25.12.2
export FAKE_BOOT_LOG_DEST=boot-1.log
out=$(run_matrix "$tmp/e2e-rotated" --case M3)
assert_eq "$?" "0" "a commit line found in boot-1.log is not a failed hop"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-rotated/results.tsv")" "PASS" \
    "the rotated ring log still records PASS"
assert_contains "$(cat "$tmp/e2e-rotated/evidence/$(date -u +%Y%m%d)-m3.log")" \
    "boot-mark commit-line: hit boot-1.log" "the evidence says the rotated file answered"
unset FAKE_BOOT_LOG_DEST

# No ring log at all: that is a red hop, not a silent pass, and it has to name both files
# and the fallback it tried.
setup_fake_device 25.12.2
export FAKE_BOOT_LOG_DEST=none
out=$(run_matrix "$tmp/e2e-nolog" --case M3)
rc=$?
unset FAKE_BOOT_LOG_DEST
assert_eq "$rc" "1" "a hop with no breadcrumb anywhere fails"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-nolog/results.tsv")" "FAIL" \
    "a missing breadcrumb records FAIL"
assert_contains "$out" "assert_boot_mark healthcheck-done" "the failure names the breadcrumb"
assert_contains "$out" "boot-1.log" "the failure names the rotated file it also searched"

# A layer no slot references is a leak: the hop has to fail and name it.
setup_fake_device 25.12.2
export FAKE_ORPHAN_LAYER=@overlay-25.12.0
out=$(run_matrix "$tmp/e2e-layer" --case M3)
rc=$?
unset FAKE_ORPHAN_LAYER
assert_eq "$rc" "1" "an unreferenced layer fails the hop"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-layer/results.tsv")" "FAIL" \
    "a leaked layer records FAIL"
assert_contains "$out" "@overlay-25.12.0 is referenced by no slot" "the failure names the leaked layer"
assert_contains "$out" "uppers='a=" "the failure prints both slots' uppers"

# A repeated version produces @overlay-<ver>-r2 on the new slot: healthy, and the upper
# assertion must accept the suffix while the invariant still requires a reference.
setup_fake_device 25.12.2
export FAKE_LAYER_SUFFIX=-r2
out=$(run_matrix "$tmp/e2e-r2" --case M3)
rc=$?
unset FAKE_LAYER_SUFFIX
assert_eq "$rc" "0" "a -r2 layer name is not a failed hop"
assert_eq "$(cat "$FAKE_DEV/upper-$(cat "$FAKE_DEV/committed")")" "@overlay-25.12.1-r2" \
    "the simulated repeated version landed on a suffixed layer"

# A machine with no committed slot must stop the run before anything is written.
setup_fake_device 25.12.2
printf 'none' >"$FAKE_DEV/committed"
: >"$STUB_CALLS"
out=$(run_matrix "$tmp/e2e-red" --case M3)
rc=$?
assert_eq "$rc" "3" "no committed slot stops the run with the red-line status"
assert_contains "$out" "ABORT red-line [M3]" "the abort says which case stopped it"
assert_eq "$(grep -c 'ab-upgrade' "$STUB_CALLS" || true)" "0" \
    "nothing was installed after the red line"
[ -e "$tmp/e2e-red/results.tsv" ] && rc=0 || rc=1
assert_eq "$rc" "1" "an aborted run writes no row at all"

# Same-version reinstall: the refusal is the documented behaviour, so the row is PASS
# and the note carries the reason.
setup_fake_device 25.12.2
out=$(run_matrix "$tmp/e2e-same" --case M5)
assert_eq "$?" "0" "a same-version refusal is not a failure"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-same/results.tsv")" "PASS" \
    "a same-version refusal records PASS"
assert_contains "$(awk -F'\t' 'NR == 1 {print $4}' "$tmp/e2e-same/results.tsv")" \
    "payload-already-installed" "the note records why the machine said no"
assert_eq "$(cat "$FAKE_DEV/generation")" "3" "a refusal changes no generation"

# Bad payload: refused, nothing written, PASS with the reason in the evidence.
setup_fake_device 25.12.2
out=$(run_matrix "$tmp/e2e-bad" --case M7)
assert_eq "$?" "0" "a refused bad payload is the pass condition"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-bad/results.tsv")" "PASS" \
    "a bad payload records PASS"
assert_contains "$(cat "$tmp/e2e-bad/evidence/$(date -u +%Y%m%d)-m7.log")" \
    "reason=digest-mismatch" "the evidence keeps the refusal reason"
assert_eq "$(cat "$FAKE_DEV/generation")" "3" "a refused payload changes no generation"

# A payload that was never built is a gap, not a failure: the machine is never touched
# and the row says which artifact is missing.
setup_fake_device 25.12.0
mkdir -p "$tmp/payloads-partial"
cp "$payloads/payload-25.12.0.tar" "$tmp/payloads-partial/"
: >"$STUB_CALLS"
out=$(AB_WAIT_UP=10 AB_WAIT_UP_FIRST=10 AB_WAIT_UP_HARD=20 sh "$root/scripts/device/matrix.sh" --payload-dir "$tmp/payloads-partial" \
    --results "$tmp/e2e-gap/results.tsv" --case M2 2>&1)
assert_eq "$?" "4" "a missing payload exits with the gap status"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/e2e-gap/results.tsv")" "GAP" \
    "a missing payload records GAP, not FAIL"
assert_eq "$(grep -c 'ab-upgrade' "$STUB_CALLS" || true)" "0" \
    "a case with no payload never installs anything"

# A case whose start version is not the running one is positioned first, so the seven
# cases can be run in any order on one machine.
setup_fake_device 25.12.0
out=$(run_matrix "$tmp/e2e-position" --case M4)
assert_eq "$?" "0" "positioning plus the case itself both commit"
assert_eq "$(cat "$FAKE_DEV/rootfs-$(cat "$FAKE_DEV/committed")")" "25.12.0" \
    "the case ended on the version it was asked for"
assert_contains "$(cat "$tmp/e2e-position/evidence/$(date -u +%Y%m%d)-m4.log")" \
    "positioning: 25.12.0 -> 25.12.2" "the extra install is logged as positioning, not as a result"

# --resume skips what already passed and still runs the rest.
out=$(run_matrix "$tmp/e2e-pass" --case M3 --resume)
assert_eq "$?" "0" "--resume on a finished matrix exits zero"
assert_contains "$out" "M3: already PASS" "--resume skips a case with a PASS row"
assert_eq "$(wc -l <"$tmp/e2e-pass/results.tsv" | tr -d ' ')" "1" "--resume appends no second row"

finish
