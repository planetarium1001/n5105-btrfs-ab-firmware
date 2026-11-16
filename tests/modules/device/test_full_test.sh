#!/usr/bin/env bash
# Module: device
# Offline unit test for scripts/device/full-test.sh, the orchestrator that runs the whole
# acceptance suite in one order and reduces it to one verdict.
#
# Nothing here touches a device: a stub `ssh` on PATH answers with canned strings, so the
# test is about the orchestrator's own judgements -- phase order, the plan, the verdict
# arithmetic, skipping and the preflight refusal.
#   ac-7 full-test.sh runs the phases in the order preflight .. audit
#   ac-7 --help exits 0 and --dry-run prints the plan for every phase and touches nothing
#   ac-7 the verdict is PASS / GAP / FAIL for the three row combinations, exit 0 only on PASS
#   ac-7 --from skips the earlier phases instead of running them
#   ac-7 a missing key file is a preflight FAIL, not a silent skip into the phases
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

ft="$root/scripts/device/full-test.sh"
assert_file_exists "$ft" "ac-7 the orchestrator exists"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the stub machine ------------------------------------------------------- #
# The stub records every call, so "the plan executed nothing" is a fact and not a hope.
# It answers only the three commands preflight asks, with the fixed strings a healthy
# machine of this project would print.
stub_bin="$tmp/bin"
stub_calls="$tmp/stub-calls.log"
mkdir -p "$stub_bin"
: >"$stub_calls"
export STUB_CALLS="$stub_calls"
export PATH="$stub_bin:$PATH"

cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for a in "$@"; do last=$a; done
case "$last" in
    *platform-release*)
        printf 'PLATFORM_VERSION=25.12.2\nDISTRIB_ID=OpenWrt\n'
        ;;
    *"df -Pk"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        printf '/dev/sda3 4194304 2097152 2097152 50%% /mnt/p4\n'
        printf '/dev/sda4 20971520 1048576 19922944 5%% /data\n'
        ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$stub_bin/ssh"

# A real file, so the key check passes and the stub is what answers the ssh calls.
export AB_HOST="root@127.0.0.1"
export AB_KEY="$tmp/id_test"
: >"$AB_KEY"
chmod 600 "$AB_KEY"

stub_calls_count() {
    if [ -f "$stub_calls" ]; then
        wc -l <"$stub_calls" | tr -d ' '
    else
        printf '0'
    fi
}

# run_ft: run the orchestrator, keep its output in $out and its status in $code.
out=""
code=0
run_ft() {
    # stdin is /dev/null so the typed `yes` a destructive phase can ask for can never
    # arrive from the terminal the test happens to run in.
    out=$(bash "$ft" "$@" </dev/null 2>&1)
    code=$?
    return 0
}

# --- ac-7: --help ----------------------------------------------------------- #
: >"$stub_calls"
run_ft --help
assert_eq "$code" 0 "ac-7 --help exits 0"
assert_contains "$out" "usage: full-test.sh" "ac-7 --help prints the usage"
assert_contains "$out" "verdict: PASS" "ac-7 --help states the verdict rule"
assert_eq "$(stub_calls_count)" "0" "ac-7 --help contacts no machine"

# --- ac-7: --dry-run prints the plan for all nine phases and executes nothing #
dry_results="$tmp/results-dry"
: >"$stub_calls"
run_ft --dry-run --results "$dry_results"
assert_eq "$code" 0 "ac-7 --dry-run exits 0"
for phase in preflight probes matrix scenarios package-revert recovery power-cut feed-install audit; do
    assert_contains "$out" "phase $phase:" "ac-7 --dry-run plans phase $phase"
done
assert_contains "$out" "plan: nothing was executed" "ac-7 --dry-run says nothing was executed"
assert_eq "$(stub_calls_count)" "0" "ac-7 --dry-run reaches no machine"
if [ -e "$dry_results" ]; then
    assert_eq "results dir created" "results dir absent" "ac-7 --dry-run writes no results"
else
    assert_eq "results dir absent" "results dir absent" "ac-7 --dry-run writes no results"
fi

# --- ac-7: --from skips the earlier phases ---------------------------------- #
: >"$stub_calls"
run_ft --dry-run --from matrix --results "$tmp/results-from"
assert_eq "$code" 0 "ac-7 --dry-run --from exits 0"
assert_contains "$out" "phase preflight: skipped" "ac-7 --from skips preflight"
assert_contains "$out" "phase probes: skipped" "ac-7 --from skips probes"
assert_contains "$out" "phase matrix: plan" "ac-7 --from starts at matrix"
assert_contains "$out" "phase audit: plan" "ac-7 --from keeps the phases after matrix"
assert_eq "$(stub_calls_count)" "0" "ac-7 --from --dry-run reaches no machine"

# An unknown phase is a usage error: a typo must not silently run the whole suite.
run_ft --from M3 --dry-run
assert_eq "$code" 2 "ac-7 --from with a case name is refused"

# --- ac-7: --only picks the phase that owns the case ------------------------ #
run_ft --dry-run --only M3 --results "$tmp/results-only"
assert_eq "$code" 0 "ac-7 --dry-run --only exits 0"
assert_contains "$out" "phase matrix: plan" "ac-7 --only M3 plans matrix"
assert_contains "$out" "phase scenarios: skipped" "ac-7 --only M3 skips the other case phases"
assert_contains "$out" "--case M3" "ac-7 --only M3 is passed to the matrix as --case"
run_ft --dry-run --only Z9
assert_eq "$code" 2 "ac-7 --only with an unknown case is refused"

# --- ac-7: preflight fails when the key file is missing -------------------- #
: >"$stub_calls"
missing_key="$tmp/no-such-key"
AB_KEY="$missing_key" run_ft --preflight-only --results "$tmp/results-nokey"
key_code=$code
key_out=$out
assert_eq "$key_code" 1 "ac-7 a missing key file exits 1"
assert_contains "$key_out" "preflight: FAIL" "ac-7 a missing key file prints preflight: FAIL"
assert_contains "$key_out" "$missing_key" "ac-7 the failure names the key file"
assert_eq "$(stub_calls_count)" "0" "ac-7 a missing key is caught before any ssh"
assert_file_exists "$tmp/results-nokey/preflight.tsv" "ac-7 the preflight refusal is recorded"
assert_contains "$(cat "$tmp/results-nokey/preflight.tsv")" "FAIL" "ac-7 the recorded preflight row is FAIL"

# --- ac-7: a healthy preflight passes and stops there ---------------------- #
mkdir -p "$tmp/payloads"
: >"$tmp/payloads/payload-25.12.2.tar"
: >"$stub_calls"
run_ft --preflight-only --results "$tmp/results-pf" --payload-dir "$tmp/payloads"
assert_eq "$code" 0 "ac-7 --preflight-only exits 0 on a healthy machine"
assert_contains "$out" "phase preflight: PASS" "ac-7 a healthy preflight is a PASS phase"
assert_contains "$out" "phase matrix: skipped" "ac-7 --preflight-only stops before the matrix"
assert_contains "$(cat "$tmp/results-pf/preflight.tsv")" "preflight-ssh" "ac-7 every preflight question is a row"
assert_file_exists "$tmp/results-pf/summary.txt" "ac-7 --preflight-only still writes a summary"
assert_eq "$(tail -n 1 "$tmp/results-pf/summary.txt")" "verdict: PASS" "ac-7 a healthy preflight verdicts PASS"

# A payload directory with no payload-*.tar is refused before the run, not during it.
mkdir -p "$tmp/empty-payloads"
run_ft --preflight-only --results "$tmp/results-pf2" --payload-dir "$tmp/empty-payloads"
assert_eq "$code" 1 "ac-7 an empty --payload-dir exits 1"
assert_contains "$out" "payload-*.tar" "ac-7 the failure names what payload-dir is missing"

# --- ac-7: a destructive phase without --yes executes nothing ---------------- #
# The window is narrowed to the matrix alone and no `yes` is typed, so the phase may not
# run: it is recorded as GAP and the suite stops there.
: >"$stub_calls"
run_ft --from matrix --stop-after matrix --results "$tmp/results-destructive"
assert_eq "$code" 1 "ac-7 an unconfirmed destructive phase does not exit 0"
assert_contains "$out" "phase matrix: GAP" "ac-7 an unconfirmed destructive phase is GAP"
assert_contains "$out" "not confirmed" "ac-7 the refusal names --yes as the way through"
assert_eq "$(stub_calls_count)" "0" "ac-7 an unconfirmed destructive phase reaches no machine"
assert_contains "$(cat "$tmp/results-destructive/matrix.tsv")" "GAP" "ac-7 the refusal is a GAP row"

# --- ac-7: the verdict arithmetic ------------------------------------------ #
# A results directory whose per-phase files are already all PASS: the phases are skipped
# (they have nothing left to prove) and the verdict is a pure function of the rows, which
# is exactly what this test wants to exercise without a machine.
agg="$tmp/results-verdict"
mkdir -p "$agg"
for phase in preflight probes matrix scenarios package-revert recovery power-cut feed-install audit; do
    printf '%s-row\tPASS\t%s.log\tok\n' "$phase" "$phase" >"$agg/$phase.tsv"
done
: >"$stub_calls"
run_ft --results "$agg" --from audit
assert_eq "$code" 0 "ac-7 nine PASS rows exit 0"
assert_contains "$out" "already PASS" "ac-7 a phase that already PASSes is skipped"
assert_eq "$(stub_calls_count)" "0" "ac-7 skipping a PASSed phase reaches no machine"
assert_eq "$(head -n 1 "$agg/summary.txt")" "passed=9 failed=0 gap=0 skipped=9" \
    "ac-7 the summary counts every row and every skipped phase"
assert_eq "$(tail -n 1 "$agg/summary.txt")" "verdict: PASS" "ac-7 no FAIL and no GAP is PASS"
assert_eq "$(wc -l <"$agg/verdict.tsv" | tr -d ' ')" "9" "ac-7 verdict.tsv is the concatenation of the phase files"

# One GAP: nothing failed, something was not decided.
printf 'feed-gap\tGAP\tfeed-install.log\tthe feed could not be read\n' >>"$agg/feed-install.tsv"
run_ft --results "$agg" --from audit
assert_eq "$code" 1 "ac-7 a GAP row exits 1"
assert_contains "$(head -n 1 "$agg/summary.txt")" "failed=0 gap=1" "ac-7 the GAP is counted"
assert_eq "$(tail -n 1 "$agg/summary.txt")" "verdict: GAP" "ac-7 no FAIL but a GAP is GAP"

# One FAIL outweighs everything else.
printf 'matrix-red\tFAIL\tmatrix.log\tthe candidate did not boot\n' >>"$agg/matrix.tsv"
run_ft --results "$agg" --from audit
assert_eq "$code" 1 "ac-7 a FAIL row exits 1"
assert_contains "$(head -n 1 "$agg/summary.txt")" "failed=1" "ac-7 the FAIL is counted"
assert_eq "$(tail -n 1 "$agg/summary.txt")" "verdict: FAIL" "ac-7 any FAIL is FAIL"

finish
