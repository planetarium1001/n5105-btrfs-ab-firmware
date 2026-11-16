#!/usr/bin/env bash
# Module: device
# R1's way in: the payload a full run now hands it (ac-11).
#
# Why this file exists: scripts/device/full-test.sh used to run the recovery phase without
# --payload, so R1 wrote `GAP [R1] no --payload given and --installed is not set` while B1
# passed. Wiring the payload back is only half the fix: in a full run the phases before
# recovery have already brought the machine up to the candidate, so `ab-upgrade <payload>`
# answers exit 74 `payload-already-installed` - and reporting that as a red R1 line would
# turn the round's most important rollback row into a defect of a machine that is healthy.
#
# The stub machine below replays the two states the driver can meet:
#   * the running slot already carries the release  -> the candidate is laid down with the
#     `ab-upgrade --force` the refusal itself names, and R1 goes on to its injection step
#   * the running slot does not                      -> the plain install is kept, no --force
#
# Nothing here reaches a device: the stub `ssh` writes the state file the driver reads and
# records every command it was asked to run.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

probe="$root/scripts/device/recovery-probe.sh"
assert_file_exists "$probe" "ac-11 the recovery driver exists"

bin="$tmp/bin"
calls="$tmp/calls"
state="$tmp/state"
rows="$tmp/recovery-results.tsv"
key="$tmp/key"
payload="$tmp/payload-0.0.12.tar"
mkdir -p "$bin" "$state"
: >"$key"
: >"$payload"
export AB_STATE_DIR="$state"

cat >"$bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for a in "$@"; do last=$a; done
state=${STUB_STATE:?stub needs STUB_STATE}
pending=$(cat "$state/pending" 2>/dev/null || printf 'none')
case "${last}" in
    'ab-slot status')
        printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=%s p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=aligned packages_reason=none\n' \
            "$pending"
        ;;
    'ab-slot rootfs')
        printf '25.12.2\n'
        ;;
    *ab-matrix.marker*)
        printf 'created-by-ab-matrix-2026-11-17\n'
        ;;
    *'uci get system'*)
        printf 'n5105-lab\n'
        ;;
    'cat > /tmp/ab-recovery-candidate.tar')
        # dev_push pipes the payload through cat, so the stub has to drain stdin.
        cat >/dev/null
        ;;
    'ab-upgrade /tmp/ab-recovery-candidate.tar')
        printf 'ab-upgrade: 41%% free on /mnt/p4\n'
        if [ "${STUB_ALREADY_INSTALLED:-1}" = "1" ]; then
            printf 'ab-upgrade: slot a already runs 25.12.2 (platform 0.0.12)\n'
            printf 'Next: ab-upgrade --force to reinstall the version this slot already runs\n'
            printf 'ab-upgrade: refused, reason=payload-already-installed\n'
            exit 74
        fi
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        ;;
    'ab-upgrade --force /tmp/ab-recovery-candidate.tar')
        printf 'ab-upgrade: forcing reinstall of 0.0.12 into slot b (slot a already runs it)\n'
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2-r2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        ;;
    'cat /boot/ab/state.json')
        # Slot b records no layer, which is where this replay stops: the candidate is armed
        # and the injection step has nothing to rewrite, so R1 ends GAP with the slot still
        # pending - the state the driver itself refuses to leave silently.
        printf '{\n    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }\n}\n'
        ;;
    *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$bin/ssh"

reset_state() {
    rm -rf "$state"
    mkdir -p "$state"
    printf 'none\n' >"$state/pending"
    : >"$calls"
    rm -f "$rows"
}

# run_r1 [env assignments...]: the driver against the stub machine, with the budgets cut to
# seconds so nothing in the test waits on a poll interval.
run_r1() {
    PATH="$bin:$PATH" STUB_CALLS="$calls" STUB_STATE="$state" AB_KEY="$key" \
        AB_HOST=root@stub AB_RECOVERY_RESULTS="$rows" AB_EVIDENCE_LOG="$tmp/evidence.log" \
        AB_POLL_INTERVAL=1 AB_WAIT_UP=1 AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
        "$@" sh "$probe" --case R1 --payload "$payload" 2>&1
}

# --- ac-11: a machine that already carries the release is still R1's machine --
reset_state
out="$(run_r1)"
rc=$?
assert_eq "$rc" "3" \
    "ac-11 a machine that already runs the candidate leaves R1 a GAP, never a FAIL"
assert_contains "$out" "ab-upgrade: slot a already runs 25.12.2 (platform 0.0.12)" \
    "ac-11 the driver quotes the refusal the machine gave"
assert_contains "$out" "laying the candidate down with --force" \
    "ac-11 the driver says why it is reinstalling instead of stopping"
assert_contains "$out" "ok [R1] candidate installed into slot b with --force" \
    "ac-11 the forced install is asserted, and it names the slot it went into"
assert_contains "$(cat "$calls")" "ab-upgrade --force /tmp/ab-recovery-candidate.tar" \
    "ac-11 the second attempt is ab-upgrade --force, the flag the refusal names"
assert_eq "$(printf '%s\n' "$out" | grep -c 'not ac-11' || true)" "0" \
    "ac-11 the already-installed refusal is not reported as matrix.sh M7's path"
assert_eq "$(awk -F'\t' '{ print $1, $2 }' "$rows")" "R1 GAP" \
    "ac-11 the row is the GAP the replay ends on, not a FAIL"
assert_contains "$(awk -F'\t' '{ print $4 }' "$rows")" "slot b left pending" \
    "ac-11 the row says the replay left slot b pending"

# --- ac-11: the plain install is kept when it is the one that works ----------
reset_state
out="$(run_r1 env STUB_ALREADY_INSTALLED=0)"
rc=$?
assert_eq "$rc" "3" "ac-11 a machine that does not carry the candidate still reports its GAP"
assert_contains "$out" "ok [R1] candidate installed into slot b" \
    "ac-11 the plain install is asserted as itself"
case "$(cat "$calls")" in
    *"--force"*)
        assert_eq "forced" "plain" "ac-11 --force is a fallback for one refusal, not the default"
        ;;
    *)
        assert_eq "plain" "plain" "ac-11 --force is a fallback for one refusal, not the default"
        ;;
esac

# --- ac-11: --installed is the operator's way in, and it needs a queued slot --
reset_state
out="$(PATH="$bin:$PATH" STUB_CALLS="$calls" STUB_STATE="$state" AB_KEY="$key" \
    AB_HOST=root@stub AB_RECOVERY_RESULTS="$rows" sh "$probe" --case R1 --installed 2>&1)"
rc=$?
assert_eq "$rc" "3" "ac-11 --installed with nothing queued is a GAP"
assert_contains "$out" "no candidate is queued (pending=none)" \
    "ac-11 the GAP names the precondition --installed needs: a slot that is already armed"

finish
