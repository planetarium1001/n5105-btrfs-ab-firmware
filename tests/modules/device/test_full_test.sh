#!/usr/bin/env bash
# Module: device
# Offline unit test for scripts/device/full-test.sh, the orchestrator that runs the whole
# acceptance suite in one order and reduces it to one verdict.
#
# Nothing here touches a device: a stub `ssh` on PATH answers with canned strings, so the
# test is about the orchestrator's own judgements -- phase order, the plan, the verdict
# arithmetic, skipping, case ownership and the preflight refusal.
#   ac-7 full-test.sh runs the phases in the order preflight .. audit, feed-install before
#        the phases that upgrade the machine, docker in two windows around the switches
#   ac-7 --help exits 0 and --dry-run prints the plan for every phase and touches nothing
#   ac-7 the verdict is PASS / GAP / FAIL for the three row combinations, exit 0 only on PASS
#   ac-7 --from skips the earlier phases instead of running them
#   ac-7 --only picks the phase that owns a case, including D1/D2/D3, S8, P3, U1, pin, all
#   ac-7 the audit phase is given the round's task id and is a GAP row without one
#   ac-7 docker, docker-after and release are not destructive (they never write a slot)
#   ac-7 a missing key file is a preflight FAIL, not a silent skip into the phases
#   ac-2 the round-2 phases (software, badconfig, matrix2) are registered: listed by
#        --list, in an order that matches the drivers' dependencies, selected by --only,
#        a GAP row when the driver is not installed, and matrix2 gated behind --yes
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

ft="$root/scripts/device/full-test.sh"
assert_file_exists "$ft" "ac-7 the orchestrator exists"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The acceptance order, spelled once. Both the order assertion and the verdict arithmetic
# read it, so a phase added to the script fails here instead of silently leaving a hole in
# the coverage of this test. The round-2 phases sit between the docker windows and the
# package phase: the samples are installed on the release the jumps landed on, the bad
# configurations are injected once those samples own /etc/config/<app>, and matrix2 is the
# chain that then carries both across the base down/up hops. The three chains this round
# added keep their own neighbours: feed-history is asked before any hop because it describes
# the feeds the hops will read, rise follows matrix because both carry the samples across a
# hop, package-classes follows software because the three origins are installed on the same
# release the samples landed on, and platform-chain sits last of the jumps because what it
# asserts is that the base did NOT move.
phase_list="preflight probes feed-install docker follow feed-history matrix rise scenarios docker-after software package-classes badconfig matrix2 platform-chain package-revert recovery power-cut release audit"
# shellcheck disable=SC2086
set -- ${phase_list}
phase_count=$#
# shellcheck disable=SC2086
set --

# --- the stub machine ------------------------------------------------------- #
# The stub records every call, so "the plan executed nothing" is a fact and not a hope.
# It answers only the commands preflight asks, with the fixed strings a healthy machine of
# this project would print.
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

# The round's task id: never hardcoded in the script, always handed over here.
round_task="20261116-12-pre-release-acceptance-0-0-12"
# The candidate the feed is expected to offer. The script must not know it on its own.
round_expect="0.0.12"
round_base_expect="25.12.2"

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

# The version this checkout declares, read from the same file the orchestrator reads. The
# fixtures below are built from it rather than from a literal, so a version bump does not
# turn the matching case into a mismatch behind the test's back.
want_version=$(sed -n '1p' "$root/VERSION")

# payload_tar <path> <platform> [rootfs]: a payload tar carrying the one member the
# preflight reads. The members a device unpacks are not needed to decide which platform a
# payload declares, and a fixture that shipped them would cost 23 MB per case.
payload_tar() {
    _pt_dir=$(mktemp -d "$tmp/payload.XXXXXX")
    printf '{\n  "format": "ab-payload/1",\n  "platform": "%s",\n  "rootfs": "%s",\n  "members": {}\n}\n' \
        "$2" "${3:-25.12.2}" >"$_pt_dir/manifest.json"
    tar -cf "$1" -C "$_pt_dir" manifest.json
    rm -rf "$_pt_dir"
}

# payload_tar_without_manifest <path>: a tar that is a payload by its name and carries no
# manifest, so its platform cannot be read at all.
payload_tar_without_manifest() {
    _pwm_dir=$(mktemp -d "$tmp/payload.XXXXXX")
    printf 'not a manifest\n' >"$_pwm_dir/kernel.bin"
    tar -cf "$1" -C "$_pwm_dir" kernel.bin
    rm -rf "$_pwm_dir"
}

# planned_phases: every `phase <name>:` line in $out, in the order it was printed. Skipped
# phases print too, so this is the order of the whole suite and not only of what ran. The
# name may carry a digit (matrix2), so the character class is not letters and dashes alone.
planned_phases() {
    printf '%s\n' "$out" | sed -n 's/^phase \([a-z0-9-]*\):.*/\1/p' | tr '\n' ' '
}

# plan_line <phase>: the `phase <name>: plan ...` line for one phase, empty when the phase
# was skipped or ran.
plan_line() {
    printf '%s\n' "$out" | grep "^phase $1: plan " | head -n 1
}

# --- ac-7: --help ----------------------------------------------------------- #
: >"$stub_calls"
run_ft --help
assert_eq "$code" 0 "ac-7 --help exits 0"
assert_contains "$out" "usage: full-test.sh" "ac-7 --help prints the usage"
assert_contains "$out" "verdict: PASS" "ac-7 --help states the verdict rule"
assert_contains "$out" "scenarios docker-after" \
    "ac-7 --help lists the phase order it runs"
assert_contains "$out" "docker follow feed-history matrix rise" \
    "ac-7 --help lists the round-2 phases where they run"
assert_contains "$out" "package-revert recovery power-cut release audit" \
    "ac-7 --help ends the order with the package, recovery, power-cut, release and audit phases"
assert_contains "$out" "--list" "ac-7 --help documents the phase list"
assert_contains "$out" "D1 docker" "ac-7 --help names the docker case tokens"
assert_contains "$out" "D2/D3 docker-after" "ac-7 --help says which segment D2/D3 belong to"
assert_contains "$out" "--task ID" "ac-7 --help documents the audit's task id"
assert_contains "$out" "--expect VERSION" "ac-7 --help documents the expected candidate"
assert_contains "$out" "ac-12/ac-13/ac-3" "ac-7 --help names the feed cases"
assert_contains "$out" "never write a slot" "ac-7 --help says docker/release are not destructive"
assert_eq "$(stub_calls_count)" "0" "ac-7 --help contacts no machine"

# --- ac-7: --dry-run prints the plan for every phase, in the acceptance order #
dry_results="$tmp/results-dry"
: >"$stub_calls"
run_ft --dry-run --results "$dry_results"
assert_eq "$code" 0 "ac-7 --dry-run exits 0"
for phase in $phase_list; do
    assert_contains "$out" "phase $phase:" "ac-7 --dry-run plans phase $phase"
done
# The order itself: feed-install has to come before the phases that upgrade the machine,
# docker splits around the slot switches, release comes after them and audit last.
assert_eq "$(planned_phases)" "$phase_list " \
    "ac-7 the phases run in the acceptance order: feed-install before matrix, docker split, audit last"
assert_contains "$out" "plan: nothing was executed" "ac-7 --dry-run says nothing was executed"
assert_eq "$(stub_calls_count)" "0" "ac-7 --dry-run reaches no machine"
if [ -e "$dry_results" ]; then
    assert_eq "results dir created" "results dir absent" "ac-7 --dry-run writes no results"
else
    assert_eq "results dir absent" "results dir absent" "ac-7 --dry-run writes no results"
fi

# The two docker windows are one script, two case sets and ONE snapshot directory: D1 writes
# the baseline there and docker-after has to read the same file back.
: >"$stub_calls"
run_ft --dry-run --results "$dry_results"
assert_contains "$(plan_line docker)" "--case D1" "ac-7 the docker phase plans D1, the baseline"
assert_contains "$(plan_line docker)" "--snapshot-dir $dry_results/docker-snapshots" \
    "ac-7 the docker phase writes its baseline under <results>/docker-snapshots"
assert_contains "$(plan_line docker-after)" "--case D2 --case D3" \
    "ac-7 docker-after plans D2 and D3, judged after the switches"
assert_contains "$(plan_line docker-after)" "--snapshot-dir $dry_results/docker-snapshots" \
    "ac-7 docker-after reads the same snapshot directory D1 wrote"
assert_contains "$(plan_line docker)" "AB_RESULTS=$dry_results/docker.tsv" \
    "ac-7 the docker phase is pointed at its results file through AB_RESULTS"
assert_contains "$(plan_line docker-after)" "AB_RESULTS=$dry_results/docker-after.tsv" \
    "ac-7 docker-after has a results file of its own"

# The release phase reads the published release; it is handed the assets directory only
# when the payload directory really holds release assets, and the tag always from the
# checkout's own VERSION.
assert_contains "$(plan_line release)" "--work-dir $dry_results/release" \
    "ac-7 the release phase keeps its downloaded assets beside the results"
assert_contains "$(plan_line release)" "--tag v$want_version" \
    "ac-7 the release phase reads the release this checkout declares, v$want_version"
# --expect names the candidate the feed offers and the payload R1 installs, which is the
# upstream base, not this project's release. Measured 2026-11-19: the tag was derived from
# it, the driver was asked for v25.12.2, answered no-such-release, and a healthy release was
# recorded as a FAIL.
run_ft --dry-run --results "$dry_results" --expect "$round_base_expect"
assert_contains "$(plan_line release)" "--tag v$want_version" \
    "ac-7 an upstream --expect does not move the release tag off this checkout's version"
case "$(plan_line release)" in
    *"--tag v$round_base_expect"*)
        assert_eq "the upstream base leaked into the release tag" "the tag is v$want_version" \
            "ac-7 --expect is not the release version"
        ;;
    *)
        assert_eq "the tag is v$want_version" "the tag is v$want_version" \
            "ac-7 --expect is not the release version"
        ;;
esac
mkdir -p "$tmp/assets"
: >"$tmp/assets/index.txt"
: >"$tmp/assets/SHA256SUMS"
run_ft --dry-run --results "$dry_results" --payload-dir "$tmp/assets"
assert_contains "$(plan_line release)" "--dir $tmp/assets" \
    "ac-7 a payload directory that holds release assets is passed on as release-verify --dir"
mkdir -p "$tmp/payloadonly"
: >"$tmp/payloadonly/payload-$round_expect.tar"
run_ft --dry-run --results "$dry_results" --payload-dir "$tmp/payloadonly"
assert_contains "$(plan_line release)" "--work-dir" \
    "ac-7 a payload-only directory is not handed to release-verify as --dir"
planned_release=$(plan_line release)
case "$planned_release" in
    *"--dir $tmp/payloadonly"*)
        assert_eq "payload dir passed as --dir" "payload dir not passed" \
            "ac-7 a payload-only directory is not handed to release-verify as --dir"
        ;;
    *)
        assert_eq "payload dir not passed" "payload dir not passed" \
            "ac-7 a payload-only directory is not handed to release-verify as --dir"
        ;;
esac

# --- ac-7: --from skips the earlier phases ---------------------------------- #
: >"$stub_calls"
run_ft --dry-run --from matrix --results "$tmp/results-from"
assert_eq "$code" 0 "ac-7 --dry-run --from exits 0"
assert_contains "$out" "phase preflight: skipped" "ac-7 --from skips preflight"
assert_contains "$out" "phase feed-install: skipped" "ac-7 --from matrix skips feed-install"
assert_contains "$out" "phase matrix: plan" "ac-7 --from starts at matrix"
assert_contains "$out" "phase audit: plan" "ac-7 --from keeps the phases after matrix"
assert_eq "$(stub_calls_count)" "0" "ac-7 --from --dry-run reaches no machine"

# The new names are phases, and only phases: --from/--stop-after take a phase, not a case.
run_ft --dry-run --from docker-after --stop-after docker-after
assert_eq "$code" 0 "ac-7 docker-after is a phase name --from accepts"
assert_contains "$out" "phase docker-after: plan" "ac-7 --from docker-after plans the second window"
run_ft --dry-run --from M3
assert_eq "$code" 2 "ac-7 --from with a case name is refused"

# --- ac-7: --only picks the phase that owns the case ------------------------ #
run_ft --dry-run --only M3 --results "$tmp/results-only"
assert_eq "$code" 0 "ac-7 --dry-run --only exits 0"
assert_contains "$out" "phase matrix: plan" "ac-7 --only M3 plans matrix"
assert_contains "$out" "phase scenarios: skipped" "ac-7 --only M3 skips the other case phases"
assert_contains "$out" "--case M3" "ac-7 --only M3 is passed to the matrix as --case"

# D1 belongs to the window before the switches; D2 and D3 to the one after. Asking for one
# must not run the other, or --only D1 would overwrite the baseline D2 compares against.
run_ft --dry-run --only D1 --results "$tmp/results-d1"
assert_eq "$code" 0 "ac-7 --dry-run --only D1 exits 0"
assert_contains "$out" "phase docker: plan" "ac-7 --only D1 plans the docker phase"
assert_contains "$out" "phase docker-after: skipped" "ac-7 --only D1 skips docker-after"
assert_contains "$(plan_line docker)" "--case D1" "ac-7 --only D1 asks docker-probe.sh for D1 only"
case "$(plan_line docker)" in
    *"--case D2"*)
        assert_eq "D2 planned by the baseline window" "D2 not planned" \
            "ac-7 --only D1 does not ask for D2"
        ;;
    *)
        assert_eq "D2 not planned" "D2 not planned" "ac-7 --only D1 does not ask for D2"
        ;;
esac
run_ft --dry-run --only D2 --results "$tmp/results-d2"
assert_eq "$code" 0 "ac-7 --dry-run --only D2 exits 0"
assert_contains "$out" "phase docker: skipped" "ac-7 --only D2 skips the docker baseline"
assert_contains "$out" "phase docker-after: plan" "ac-7 --only D2 plans docker-after"
assert_contains "$(plan_line docker-after)" "--case D2" "ac-7 --only D2 asks docker-probe.sh for D2"
run_ft --dry-run --only D3 --results "$tmp/results-d3"
assert_contains "$out" "phase docker-after: plan" "ac-7 --only D3 plans docker-after"
assert_contains "$(plan_line docker-after)" "--case D3" "ac-7 --only D3 asks docker-probe.sh for D3"

# The new case names of the drivers that gained them.
run_ft --dry-run --only S8 --results "$tmp/results-s8"
assert_contains "$out" "phase scenarios: plan" "ac-7 --only S8 plans the scenarios"
assert_contains "$(plan_line scenarios)" "--case S8" "ac-7 --only S8 is passed through as --case"
run_ft --dry-run --only P3 --results "$tmp/results-p3"
assert_contains "$(plan_line package-revert)" "--case P3" "ac-7 --only P3 is passed to package-revert"
run_ft --dry-run --only P4 --results "$tmp/results-p4"
assert_contains "$(plan_line package-revert)" "--case P4" "ac-7 --only P4 is passed to package-revert"
run_ft --dry-run --only U1 --results "$tmp/results-u1"
assert_contains "$out" "phase package-revert: plan" "ac-7 --only U1 plans package-revert"
assert_contains "$(plan_line package-revert)" "--case U1" "ac-7 --only U1 is a case of its own"

# feed-install.sh takes one --case value, so the acceptance names are folded into it.
run_ft --dry-run --only ac-3 --results "$tmp/results-pin"
assert_contains "$out" "phase feed-install: plan" "ac-7 --only ac-3 plans feed-install"
assert_contains "$(plan_line feed-install)" "--case pin" "ac-7 --only ac-3 asks for the pin case"
run_ft --dry-run --only pin --results "$tmp/results-pin2"
assert_contains "$(plan_line feed-install)" "--case pin" "ac-7 --only pin is the same request"
run_ft --dry-run --only ac-12 --only ac-13 --results "$tmp/results-both"
assert_contains "$(plan_line feed-install)" "--case both" "ac-7 ac-12 with ac-13 is the both case"
run_ft --dry-run --only ac-12 --only ac-3 --results "$tmp/results-mixed"
assert_contains "$(plan_line feed-install)" "--case all" \
    "ac-7 check with pin has no value of its own, so the whole driver order is asked for"
run_ft --dry-run --only all --results "$tmp/results-all"
assert_contains "$(plan_line feed-install)" "--case all" "ac-7 --only all is passed through"
# A run that selects nothing runs all three feed cases: ac-3 is only provable while the
# machine is below the candidate, which is exactly this phase's window.
run_ft --dry-run --results "$tmp/results-feed-default"
assert_contains "$(plan_line feed-install)" "--case all" "ac-7 the default feed case includes the pin"
run_ft --dry-run --only release --results "$tmp/results-release"
assert_contains "$out" "phase release: plan" "ac-7 --only release plans the release phase"
assert_contains "$out" "phase docker: skipped" "ac-7 --only release skips the machine phases"
run_ft --dry-run --only sums --results "$tmp/results-sums"
assert_contains "$out" "phase release: plan" "ac-7 --only sums selects the release phase"
run_ft --dry-run --only Z9
assert_eq "$code" 2 "ac-7 --only with an unknown case is refused"

# --- ac-7: the audit is told which round it audits -------------------------- #
# Preview: the plan passes the id through, and says what is missing when there is none.
run_ft --dry-run --only M3 --task "$round_task" --results "$tmp/results-task"
assert_contains "$(plan_line audit)" "evidence-audit.sh --task $round_task" \
    "ac-7 the audit phase passes --task to evidence-audit.sh"
run_ft --dry-run --only M3 --results "$tmp/results-notask"
assert_contains "$(plan_line audit)" "no task id" \
    "ac-7 the plan says the audit has no task id"
case "$(plan_line audit)" in
    *"--task 20261115-01"*)
        assert_eq "stale task id planned" "no stale task id planned" \
            "ac-7 the plan never falls back to the previous round's task id"
        ;;
    *)
        assert_eq "no stale task id planned" "no stale task id planned" \
            "ac-7 the plan never falls back to the previous round's task id"
        ;;
esac
# AB_TASK_ID is the same knob for a caller that assembles an environment.
AB_TASK_ID="$round_task" run_ft --dry-run --only M3 --results "$tmp/results-taskenv"
assert_contains "$(plan_line audit)" "--task $round_task" "ac-7 AB_TASK_ID is accepted as the task id"

# Run: with no task id the audit is a GAP row and evidence-audit.sh is not executed at all.
audit_results="$tmp/results-audit-notask"
: >"$stub_calls"
run_ft --from audit --results "$audit_results"
assert_eq "$code" 1 "ac-7 an audit with no task id does not exit 0"
assert_contains "$out" "no task id" "ac-7 the run says what is missing"
assert_contains "$(cat "$audit_results/audit.tsv")" "GAP" "ac-7 the audit with no task id is a GAP row"
assert_contains "$(cat "$audit_results/audit.tsv")" "no task id" "ac-7 the row names the missing task id"
case "$out" in
    *"evidence-audit task="*)
        assert_eq "evidence-audit executed" "evidence-audit not executed" \
            "ac-7 an audit with no task id does not read the previous round's record"
        ;;
    *)
        assert_eq "evidence-audit not executed" "evidence-audit not executed" \
            "ac-7 an audit with no task id does not read the previous round's record"
        ;;
esac
assert_eq "$(tail -n 1 "$audit_results/summary.txt")" "verdict: GAP" \
    "ac-7 a GAP row makes the verdict GAP, not FAIL"
assert_eq "$(stub_calls_count)" "0" "ac-7 an audit with no task id reaches no machine"

# With a task id the audit really runs. A task id nobody has a record for is a GAP and not a
# FAIL: no PRD means the audit could not be made, and nothing about this machine was judged -
# "the record is incomplete" and "the machine is broken" must not share a verdict. The id is
# deliberately one that does not exist, so this assertion does not depend on the state of
# .workflow/tasks on the machine running the test.
no_such_task="20990101-99-no-such-task"
audit_run_results="$tmp/results-audit-run"
: >"$stub_calls"
run_ft --from audit --results "$audit_run_results" --task "$no_such_task"
# evidence-audit.sh refuses before it prints its own `task=` header when the task has no PRD,
# so the proof that the id travelled is the message naming it plus the row's own note.
assert_contains "$(cat "$audit_run_results/audit.log")" "$no_such_task" \
    "ac-7 the audit runs the round it was told about, not the default one"
assert_contains "$(cat "$audit_run_results/audit.tsv")" "$no_such_task" \
    "ac-7 the audit row names the task id it could not audit"
assert_contains "$(cat "$audit_run_results/audit.tsv")" "GAP" \
    "ac-7 an audit that cannot be made is a GAP row"
case "$(cat "$audit_run_results/audit.tsv")" in
    *"	FAIL	"*)
        assert_eq "audit row is FAIL" "audit row is GAP" \
            "ac-7 an unmakeable audit is not a machine FAIL"
        ;;
    *)
        assert_eq "audit row is GAP" "audit row is GAP" \
            "ac-7 an unmakeable audit is not a machine FAIL"
        ;;
esac
assert_eq "$(tail -n 1 "$audit_run_results/summary.txt")" "verdict: GAP" \
    "ac-7 an unmakeable audit leaves the round at GAP"

# --- ac-7: the two phases that write no results file ------------------------ #
# audit and release are judged from the lines the driver printed, so the mapping from those
# lines to a row is a piece of code of its own - and it is the piece that decides whether an
# incomplete record or a dead mirror turns the whole round red. It is exercised here against
# stubs in a copy of the device directory, so no real record and no network is involved:
# evidence-audit.sh prints `result=gaps open=<n>` and release-verify.sh prints
# `result=none`, and neither of those may become a FAIL.
hx="$tmp/hx/scripts/device"
mkdir -p "$hx"
cp "$ft" "$hx/full-test.sh"
cp "$root/scripts/device/lib.sh" "$hx/lib.sh"
cat >"$hx/evidence-audit.sh" <<'STUB'
#!/bin/sh
printf 'evidence-audit task=%s acs=13\n' "${4:-stub}"
printf 'evidence-audit summary acs=13 covered=%s missing=%s mismatch=0 unchecked=0 absent=0 unused=0\n' \
    "${STUB_AUDIT_COVERED:-0}" "${STUB_AUDIT_MISSING:-13}"
case "${STUB_AUDIT_RESULT:-gaps}" in
    covered)
        printf 'evidence-audit result=covered\n'
        exit 0
        ;;
    *)
        printf 'evidence-audit result=gaps open=%s\n' "${STUB_AUDIT_MISSING:-13}"
        exit 1
        ;;
esac
STUB
cat >"$hx/release-verify.sh" <<'STUB'
#!/bin/sh
printf 'release-verify check=tag-version result=pass tag=v0.0.12 version=0.0.12 from=git\n'
case "${STUB_RELEASE_RESULT:-pass}" in
    pass)
        printf 'release-verify result=pass checks=15 failed=0 skipped=0 tag=v0.0.12\n'
        exit 0
        ;;
    none)
        printf 'release-verify result=none reason=gh-not-installed tag=v0.0.12\n'
        exit 3
        ;;
    *)
        printf 'release-verify result=fail checks=1 failed=1 skipped=0 tag=v0.0.12\n'
        exit 1
        ;;
esac
STUB
chmod +x "$hx/evidence-audit.sh" "$hx/release-verify.sh"

# The recovery driver's contract is one row per case in AB_RECOVERY_RESULTS, and its two
# flags are --case and --payload. This stub prints what it was asked for and reaches no
# machine, so the orchestrator's own wiring - which payload it names, which cases it leaves
# out - can be read back instead of inferred from prose.
cat >"$hx/recovery-probe.sh" <<'STUB'
#!/bin/sh
cases=""
payload=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --case) cases="${cases} $2"; shift 2 ;;
        --payload) payload=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "${cases}" ] || cases=" R1 B1"
printf 'recovery-probe-stub cases=%s payload=%s\n' "${cases# }" "${payload:-none}"
for c in ${cases}; do
    printf '%s\tPASS\tstub.log\tstub row\n' "${c}" >>"${AB_RECOVERY_RESULTS:?stub needs AB_RECOVERY_RESULTS}"
done
exit 0
STUB
chmod +x "$hx/recovery-probe.sh"

# run_hx: the copy, with the same stub machine on PATH.
run_hx() {
    out=$(bash "$hx/full-test.sh" "$@" </dev/null 2>&1)
    code=$?
    return 0
}

# The audit's own GAP is a GAP row: the record is incomplete, and that is not the machine.
run_hx --from audit --results "$tmp/hx-audit-gap" --task "$round_task"
assert_contains "$(cat "$tmp/hx-audit-gap/audit.tsv")" "GAP" \
    "ac-7 evidence-audit result=gaps is recorded as a GAP row"
assert_contains "$(cat "$tmp/hx-audit-gap/audit.tsv")" "covered=0" \
    "ac-7 the audit row carries the summary the driver printed"
assert_eq "$code" 1 "ac-7 a GAP row still exits 1"
assert_eq "$(tail -n 1 "$tmp/hx-audit-gap/summary.txt")" "verdict: GAP" \
    "ac-7 an incomplete record is GAP, never FAIL"
STUB_AUDIT_RESULT=covered STUB_AUDIT_COVERED=13 STUB_AUDIT_MISSING=0 \
    run_hx --from audit --results "$tmp/hx-audit-ok" --task "$round_task"
assert_eq "$code" 0 "ac-7 a covered audit exits 0"
assert_contains "$(cat "$tmp/hx-audit-ok/audit.tsv")" "PASS" \
    "ac-7 evidence-audit result=covered is recorded as a PASS row"

# The release phase reads the driver's last line: pass, none (GAP) and fail.
run_hx --from release --stop-after release --results "$tmp/hx-rel-pass"
assert_eq "$code" 0 "ac-7 a passing release exits 0"
assert_contains "$(cat "$tmp/hx-rel-pass/release.tsv")" "PASS" \
    "ac-7 release-verify result=pass is a PASS row"
STUB_RELEASE_RESULT=none run_hx --from release --stop-after release --results "$tmp/hx-rel-none"
assert_eq "$code" 1 "ac-7 a release that could not be read exits 1"
assert_contains "$(cat "$tmp/hx-rel-none/release.tsv")" "GAP" \
    "ac-7 release-verify result=none (no network, no gh) is a GAP row and not a FAIL"
assert_eq "$(tail -n 1 "$tmp/hx-rel-none/summary.txt")" "verdict: GAP" \
    "ac-7 an unreachable release leaves the round at GAP"
STUB_RELEASE_RESULT=fail run_hx --from release --stop-after release --results "$tmp/hx-rel-fail"
assert_eq "$code" 1 "ac-7 a release that does not match ac-1 exits 1"
assert_contains "$(cat "$tmp/hx-rel-fail/release.tsv")" "FAIL" \
    "ac-7 release-verify result=fail is a FAIL row"
assert_eq "$(tail -n 1 "$tmp/hx-rel-fail/summary.txt")" "verdict: FAIL" \
    "ac-7 a wrong release is FAIL, not GAP"

# --- ac-11: the recovery phase is handed the payload R1 installs ------------ #
# Measured defect (the 0.0.12 full run): the phase ran without --payload, so R1 - the
# rollback evidence ac-11 exists for - wrote `GAP [R1] no --payload given and --installed is
# not set` while B1 passed. The orchestration knew which payload the round meant and never
# named it, and the most important A/B rollback row of the round was missing for that reason
# alone. The file is named the way every other driver names one:
# <payload-dir>/payload-<expect>.tar.
rec_payloads="$tmp/rec-payloads"
mkdir -p "$rec_payloads"
: >"$rec_payloads/payload-$round_expect.tar"

# The plan is the command that would run, so --dry-run shows the payload in it.
run_ft --dry-run --only R1 --expect "$round_expect" --payload-dir "$rec_payloads" \
    --results "$tmp/results-rec-plan"
assert_contains "$(plan_line recovery)" "--payload $rec_payloads/payload-$round_expect.tar" \
    "ac-11 the recovery phase is planned with the payload R1 installs"
assert_contains "$(plan_line recovery)" "--case R1" \
    "ac-11 the recovery phase is planned with the case that needs it"

# And the run really passes it: the stub driver prints what it was asked for.
run_hx --from recovery --stop-after recovery --yes --expect "$round_expect" \
    --payload-dir "$rec_payloads" --results "$tmp/hx-rec-ok"
assert_eq "$code" 0 "ac-11 a recovery phase with its payload passes"
assert_contains "$(cat "$tmp/hx-rec-ok/recovery.log")" \
    "payload=$rec_payloads/payload-$round_expect.tar" \
    "ac-11 the payload reaches recovery-probe.sh as --payload"
assert_eq "$(awk -F'\t' '$1 == "R1" { print $2 }' "$tmp/hx-rec-ok/recovery.tsv")" "PASS" \
    "ac-11 R1 is judged, not skipped, when its payload is on this host"

# Not there is not the same as not asked. The row names the file the orchestration meant, and
# B1 - which needs no payload - is still put to the machine.
rec_empty="$tmp/rec-empty"
mkdir -p "$rec_empty"
run_hx --from recovery --stop-after recovery --yes --expect "$round_expect" \
    --payload-dir "$rec_empty" --results "$tmp/hx-rec-gap"
assert_eq "$code" 1 "ac-11 a recovery without its payload does not exit 0"
assert_contains "$(cat "$tmp/hx-rec-gap/recovery.tsv")" "R1	GAP" \
    "ac-11 the missing payload is a GAP row for R1"
assert_contains "$(cat "$tmp/hx-rec-gap/recovery.tsv")" "$rec_empty/payload-$round_expect.tar" \
    "ac-11 the GAP names the payload path that is missing"
assert_contains "$(cat "$tmp/hx-rec-gap/recovery.log")" "cases=B1" \
    "ac-11 B1 still runs when R1 has no payload"
assert_eq "$(awk -F'\t' '$1 == "B1" { print $2 }' "$tmp/hx-rec-gap/recovery.tsv")" "PASS" \
    "ac-11 B1 is still judged when R1 cannot be"

# R1 on its own with no payload is a GAP and not an empty phase: the driver is not asked for
# cases it was not given, so the row stays the only thing the phase says.
run_hx --from recovery --stop-after recovery --yes --only R1 --expect "$round_expect" \
    --payload-dir "$rec_empty" --results "$tmp/hx-rec-r1only"
assert_eq "$code" 1 "ac-11 R1 alone without a payload is not a pass"
assert_contains "$(cat "$tmp/hx-rec-r1only/recovery.tsv")" "R1	GAP" \
    "ac-11 R1 alone without a payload is the GAP row"
case "$out" in
    *recovery-probe-stub*)
        assert_eq "driver executed" "driver not executed" \
            "ac-11 nothing is run for a phase whose only case has no payload"
        ;;
    *)
        assert_eq "driver not executed" "driver not executed" \
            "ac-11 nothing is run for a phase whose only case has no payload"
        ;;
esac

# B1 needs no payload, so it is not gated behind one either.
run_hx --from recovery --stop-after recovery --yes --only B1 --expect "$round_expect" \
    --payload-dir "$rec_empty" --results "$tmp/hx-rec-b1"
assert_eq "$code" 0 "ac-11 B1 needs no payload"
assert_contains "$(cat "$tmp/hx-rec-b1/recovery.log")" "payload=none" \
    "ac-11 B1 is asked for without a payload argument"

# A round that names no candidate can name no payload either, and says so.
AB_EXPECT="" run_hx --from recovery --stop-after recovery --yes --payload-dir "$rec_payloads" \
    --results "$tmp/hx-rec-noexpect"
assert_contains "$(cat "$tmp/hx-rec-noexpect/recovery.tsv")" "no --expect" \
    "ac-11 a round with no --expect says why R1 cannot name a payload"

# The plan can say a GAP before anything is executed: the answer is a file on this host.
run_ft --dry-run --expect 9.9.9 --results "$tmp/results-rec-miss"
assert_contains "$(plan_line recovery)" "R1 would be a GAP" \
    "ac-11 the plan names the GAP a missing payload would produce"
assert_contains "$(plan_line recovery)" "payloads/payload-9.9.9.tar" \
    "ac-11 the plan names the payload path it looked for"

# --- ac-7: docker, docker-after and release are not destructive -------------- #
# The docker baseline writes /data and /docker and never a slot, so it runs without --yes.
# With the stub machine it cannot reach a verdict (no docker output at all) and says GAP --
# the point here is that it was allowed to ask, not that it passed.
docker_results="$tmp/results-docker"
: >"$stub_calls"
run_ft --from docker --stop-after docker --results "$docker_results"
assert_contains "$out" "docker-probe start" "ac-7 the docker phase runs without --yes"
case "$out" in
    *"not confirmed"*)
        assert_eq "destructive refusal" "no destructive refusal" \
            "ac-7 the docker phase is not asked for a typed yes"
        ;;
    *)
        assert_eq "no destructive refusal" "no destructive refusal" \
            "ac-7 the docker phase is not asked for a typed yes"
        ;;
esac
assert_file_exists "$docker_results/docker.tsv" "ac-7 the docker phase writes its own rows"
assert_contains "$(cat "$docker_results/docker.tsv")" "D1" \
    "ac-7 the docker rows name the case and land in AB_RESULTS"

# The docker-after window is not gated either: it only reads the machine.
run_ft --from docker-after --stop-after docker-after --results "$tmp/results-docker-after"
assert_contains "$out" "docker-probe start" "ac-7 docker-after runs without --yes"
assert_contains "$out" "cases=D2,D3" "ac-7 docker-after asks for D2 and D3 and never for D1"

# The destructive set is exactly the phases that write a slot and reboot. docker,
# docker-after and release are not in it: D1 writes /data and @docker and no slot, D2/D3 only
# read, and the release phase never reaches a machine.
destructive_set=$(sed -n 's/^DESTRUCTIVE_PHASES="\(.*\)"$/\1/p' "$ft")
assert_eq "$destructive_set" "matrix rise matrix2 platform-chain recovery power-cut" \
    "ac-7 only the phases that write a slot, matrix2 included, are destructive"
for not_destructive in docker docker-after release; do
    case " $destructive_set " in
        *" $not_destructive "*)
            assert_eq "$not_destructive is destructive" "$not_destructive is not destructive" \
                "ac-7 $not_destructive is not gated behind --yes"
            ;;
        *)
            assert_eq "$not_destructive is not destructive" "$not_destructive is not destructive" \
                "ac-7 $not_destructive is not gated behind --yes"
            ;;
    esac
done

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
payload_tar "$tmp/payloads/payload-25.12.2.tar" "$want_version" 25.12.2
: >"$stub_calls"
run_ft --preflight-only --results "$tmp/results-pf" --payload-dir "$tmp/payloads"
assert_eq "$code" 0 "ac-7 --preflight-only exits 0 on a healthy machine"
assert_contains "$out" "phase preflight: PASS" "ac-7 a healthy preflight is a PASS phase"
assert_contains "$out" "phase matrix: skipped" "ac-7 --preflight-only stops before the matrix"
assert_contains "$(cat "$tmp/results-pf/preflight.tsv")" "preflight-ssh" "ac-7 every preflight question is a row"
assert_file_exists "$tmp/results-pf/summary.txt" "ac-7 --preflight-only still writes a summary"
assert_eq "$(tail -n 1 "$tmp/results-pf/summary.txt")" "verdict: PASS" "ac-7 a healthy preflight verdicts PASS"
assert_contains "$out" "platforms=ok" "ac-8 a payload declaring this checkout's platform is reported as checked"

# A payload directory with no payload-*.tar is refused before the run, not during it.
mkdir -p "$tmp/empty-payloads"
run_ft --preflight-only --results "$tmp/results-pf2" --payload-dir "$tmp/empty-payloads"
assert_eq "$code" 1 "ac-7 an empty --payload-dir exits 1"
assert_contains "$out" "payload-*.tar" "ac-7 the failure names what payload-dir is missing"

# --- ac-8/ac-9: a payload built from older code refuses the run ------------- #
# This is the failure the check exists for: the payloads of the 2026-11-19 round carried
# platform 0.0.12 while the checkout was 0.0.13, so every jump installed the older layer,
# nothing rewrote the feeds of the image it landed in, and the round failed at
# `apk ... rc=99` in a way that read as a product defect.
mkdir -p "$tmp/stale-payloads"
payload_tar "$tmp/stale-payloads/payload-25.12.0.tar" "9.9.9" 25.12.0
payload_tar "$tmp/stale-payloads/payload-25.12.1.tar" "9.9.9" 25.12.1
: >"$stub_calls"
run_ft --preflight-only --results "$tmp/results-stale" --payload-dir "$tmp/stale-payloads"
assert_eq "$code" 1 "ac-8 a payload from an older platform refuses the run"
assert_contains "$out" "preflight: FAIL" "ac-8 the stale payload is a preflight FAIL"
assert_contains "$out" "payload-25.12.0.tar" "ac-8 the refusal names the first tar"
assert_contains "$out" "payload-25.12.1.tar" "ac-8 the refusal names every offending tar, not only the first"
assert_contains "$out" "declares platform 9.9.9" "ac-8 the refusal names the platform the payload declares"
assert_contains "$out" "want $want_version" "ac-8 the refusal names the platform the checkout being accepted declares"
assert_contains "$(cat "$tmp/results-stale/preflight.tsv")" "preflight-payload-platform" \
    "ac-8 the refusal is its own preflight row"
assert_eq "$(tail -n 1 "$tmp/results-stale/summary.txt")" "verdict: FAIL" \
    "ac-8 the refusal is a FAIL, not a GAP"
# The run stops at preflight, so no phase that writes a slot is ever planned. Asserted
# against the phase names rather than against the whole line, because a run that refuses
# at preflight still prints the preflight phase once more when it reports the verdict.
case " $(planned_phases) " in
    *" matrix "* | *" rise "* | *" matrix2 "* | *" platform-chain "* | *" recovery "* | *" power-cut "*)
        assert_eq "a slot-writing phase is planned" "no slot-writing phase is planned" \
            "ac-8 the refusal stops the run before any slot is written"
        ;;
    *)
        assert_eq "no slot-writing phase is planned" "no slot-writing phase is planned" \
            "ac-8 the refusal stops the run before any slot is written"
        ;;
esac

# The directory a round uses also holds payloads of the other role: a platform chain step,
# named after its own version, and the deliberately broken payload M7 hands the machine.
# Refusing those would forbid two cases instead of checking one.
mkdir -p "$tmp/mixed-payloads"
payload_tar "$tmp/mixed-payloads/payload-25.12.2.tar" "$want_version" 25.12.2
payload_tar "$tmp/mixed-payloads/payload-0.0.12.tar" "0.0.12" 25.12.2
payload_tar "$tmp/mixed-payloads/payload-bad.tar" "0.0.12" 25.12.2
run_ft --preflight-only --results "$tmp/results-mixed" --payload-dir "$tmp/mixed-payloads"
assert_eq "$code" 0 \
    "ac-8 a current base payload passes beside a platform chain step and the deliberately broken payload"

# A platform payload that does not declare the version it is named for is the same defect
# in the other role: the chain would install a layer nobody described.
mkdir -p "$tmp/lying-platform"
payload_tar "$tmp/lying-platform/payload-0.0.99.tar" "0.0.98" 25.12.2
run_ft --preflight-only --results "$tmp/results-lying" --payload-dir "$tmp/lying-platform"
assert_eq "$code" 1 "ac-8 a platform payload declaring another version refuses the run"
assert_contains "$out" "payload-0.0.99.tar" "ac-8 the platform refusal names the tar"
assert_contains "$out" "declares platform 0.0.98" "ac-8 the platform refusal names what it declares"
assert_contains "$out" "want 0.0.99" "ac-8 the platform refusal names the version its name claims"

# A payload whose platform cannot be read is refused as well: an unreadable manifest is not
# evidence that the payload was built from this checkout.
mkdir -p "$tmp/nomanifest-payloads"
payload_tar_without_manifest "$tmp/nomanifest-payloads/payload-25.12.1.tar"
run_ft --preflight-only --results "$tmp/results-nomanifest" --payload-dir "$tmp/nomanifest-payloads"
assert_eq "$code" 1 "ac-8 a payload without a readable manifest refuses the run"
assert_contains "$out" "payload-25.12.1.tar declares no readable manifest.platform" \
    "ac-8 the refusal names the tar and what is missing"

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
for phase in $phase_list; do
    printf '%s-row\tPASS\t%s.log\tok\n' "$phase" "$phase" >"$agg/$phase.tsv"
done
: >"$stub_calls"
run_ft --results "$agg" --from audit
assert_eq "$code" 0 "ac-7 $phase_count PASS rows exit 0"
assert_contains "$out" "already PASS" "ac-7 a phase that already PASSes is skipped"
assert_eq "$(stub_calls_count)" "0" "ac-7 skipping a PASSed phase reaches no machine"
assert_eq "$(head -n 1 "$agg/summary.txt")" "passed=$phase_count failed=0 gap=0 skipped=$phase_count" \
    "ac-7 the summary counts every row and every skipped phase"
assert_eq "$(tail -n 1 "$agg/summary.txt")" "verdict: PASS" "ac-7 no FAIL and no GAP is PASS"
assert_eq "$(wc -l <"$agg/verdict.tsv" | tr -d ' ')" "$phase_count" \
    "ac-7 verdict.tsv is the concatenation of the phase files"

# One GAP: nothing failed, something was not decided. A mirror that did not answer (the
# docker phase) is a GAP and must not turn the round into a FAIL.
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

# --- ac-2: the round-2 phases are registered, ordered and never silently skipped ---- #
# software, badconfig and matrix2 are the three drivers this round adds. They are phases of
# this orchestrator like any other: listed, ordered, selectable by --only/--from, and a GAP
# row when the driver is not installed on this host.

# phase_pos <phase>: its 1-based position in the planned order, 0 when it is not planned.
phase_pos() {
    local want=$1 i=1 p
    for p in $(planned_phases); do
        if [ "$p" = "$want" ]; then
            printf '%s' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    printf '0'
}

# assert_before <first> <second> <message>: both are planned and the first comes first.
assert_before() {
    local first second
    first=$(phase_pos "$1")
    second=$(phase_pos "$2")
    if [ "$first" -gt 0 ] && [ "$second" -gt 0 ] && [ "$first" -lt "$second" ]; then
        assert_eq "$1 before $2" "$1 before $2" "$3"
    else
        assert_eq "$1@$first, $2@$second" "$1 before $2" "$3"
    fi
}

# --list is the one-line answer to "which phases, in which order": no machine, no results
# directory, no plan line. It is also the cheapest way for a reader to see that the three
# new phases are really registered rather than only mentioned in a comment.
list_results="$tmp/results-list"
: >"$stub_calls"
run_ft --list --results "$list_results"
assert_eq "$code" 0 "ac-2 --list exits 0"
assert_eq "$(printf '%s\n' "$out" | tr '\n' ' ')" "$phase_list " \
    "ac-2 --list prints every phase in the acceptance order, one per line"
for new_phase in software badconfig matrix2; do
    assert_contains "$out" "$new_phase" "ac-2 --list names the round-2 phase $new_phase"
done
assert_eq "$(stub_calls_count)" "0" "ac-2 --list contacts no machine"
if [ -e "$list_results" ]; then
    assert_eq "results dir created" "results dir absent" "ac-2 --list writes nothing"
else
    assert_eq "results dir absent" "results dir absent" "ac-2 --list writes nothing"
fi

# The order is the drivers' dependency, not the order this round's authors happen to have
# written them down in: software needs the machine the jumps brought to the newest release,
# badconfig needs the samples' /etc/config/<app>, and matrix2 is the chain that carries both
# across the base hops - so it comes after them and before the package phase.
: >"$stub_calls"
run_ft --dry-run --results "$tmp/results-round2-plan"
assert_eq "$code" 0 "ac-2 the plan with the round-2 phases exits 0"
assert_before matrix software "ac-2 software runs after the first version jump"
assert_before scenarios software \
    "ac-2 software runs after the jumps that bring the machine to the newest release"
assert_before software badconfig "ac-2 badconfig runs once the samples are installed"
assert_before badconfig matrix2 "ac-2 matrix2 runs after the samples and their bad configs"
assert_before matrix2 package-revert "ac-2 matrix2 runs before the phase that changes packages"
assert_eq "$(stub_calls_count)" "0" "ac-2 planning the round-2 phases reaches no machine"

# --only selects a round-2 phase by its own name, and the plan says what would run.
run_ft --dry-run --only software --results "$tmp/results-only-software"
assert_eq "$code" 0 "ac-2 --only software exits 0"
assert_contains "$out" "phase software: plan" "ac-2 --only software plans the software phase"
assert_contains "$out" "phase badconfig: skipped" "ac-2 --only software skips badconfig"
assert_contains "$out" "phase matrix2: skipped" "ac-2 --only software skips matrix2"
assert_contains "$(plan_line software)" "--results $tmp/results-only-software/software.tsv" \
    "ac-2 the software phase is pointed at its own results file"
run_ft --dry-run --only matrix2 --results "$tmp/results-only-matrix2"
assert_contains "$out" "phase matrix2: plan" "ac-2 --only matrix2 plans the round-2 chain"
assert_contains "$(plan_line matrix2)" "--results $tmp/results-only-matrix2/matrix2.tsv" \
    "ac-2 matrix2 writes a results file of its own"
run_ft --dry-run --only badconfig --results "$tmp/results-only-badconfig"
assert_contains "$out" "phase badconfig: plan" "ac-2 --only badconfig plans the bad-config phase"
# The defect list of the bad-config phase goes under the results directory: without it the
# driver has nowhere to put "who refused it / who restored it" and drops those candidates.
assert_contains "$(plan_line badconfig)" "--defects $tmp/results-only-badconfig/badconfig-defects.tsv" \
    "ac-2 the badconfig phase is given a defect list under the results directory"
# matrix2 jumps payload to payload, so it is told where the round keeps them, exactly like
# matrix and scenarios: a chain that fell back to its own default would jump from a
# directory this round never filled.
run_ft --dry-run --only matrix2 --payload-dir "$tmp/payloads" --results "$tmp/results-m2-payload"
assert_contains "$(plan_line matrix2)" "--payload-dir $tmp/payloads" \
    "ac-2 matrix2 is told where the round's payloads are"

# --from/--stop-after take these names as phases, and the segment in between is what runs.
run_ft --dry-run --from software --stop-after matrix2 --results "$tmp/results-round2-seg"
assert_eq "$code" 0 "ac-2 --from software --stop-after matrix2 exits 0"
assert_contains "$out" "phase docker-after: skipped" "ac-2 the segment starts after docker-after"
assert_contains "$out" "phase software: plan" "ac-2 the segment plans software"
assert_contains "$out" "phase badconfig: plan" "ac-2 the segment plans badconfig"
assert_contains "$out" "phase matrix2: plan" "ac-2 the segment plans matrix2"
assert_contains "$out" "phase package-revert: skipped" "ac-2 the segment stops before package-revert"

# --dry-run of a phase that writes slots executes nothing: no ssh, no results directory.
: >"$stub_calls"
run_ft --dry-run --only matrix2 --yes --results "$tmp/results-dry-matrix2"
assert_eq "$(stub_calls_count)" "0" "ac-2 --dry-run of matrix2 reaches no machine"
assert_contains "$out" "plan: nothing was executed" "ac-2 --dry-run of matrix2 says it executed nothing"
if [ -e "$tmp/results-dry-matrix2" ]; then
    assert_eq "results dir created" "results dir absent" "ac-2 --dry-run of matrix2 writes no results"
else
    assert_eq "results dir absent" "results dir absent" "ac-2 --dry-run of matrix2 writes no results"
fi

# A driver that is not installed is a GAP row and not an omission: hx is a copy of this
# orchestrator with no round-2 driver beside it, so "we did not ask" cannot look like
# "the machine said yes".
for absent in software badconfig matrix2; do
    miss_results="$tmp/round2-miss-$absent"
    : >"$stub_calls"
    run_hx --from "$absent" --stop-after "$absent" --results "$miss_results"
    assert_eq "$code" 1 "ac-2 a missing $absent driver does not exit 0"
    assert_contains "$(cat "$miss_results/$absent.tsv")" "GAP" \
        "ac-2 a missing $absent driver is a GAP row, not a skip"
    assert_contains "$(cat "$miss_results/$absent.tsv")" "script not present" \
        "ac-2 the $absent GAP names the missing script"
    assert_eq "$(tail -n 1 "$miss_results/summary.txt")" "verdict: GAP" \
        "ac-2 a missing $absent driver leaves the round at GAP"
    assert_eq "$(stub_calls_count)" "0" "ac-2 a missing $absent driver reaches no machine"
done
run_hx --dry-run --from software --stop-after software
assert_contains "$(plan_line software)" "would be recorded GAP" \
    "ac-2 the plan says a missing driver would be recorded GAP"

# The same three phases with their drivers present: the rows land in the phase's own file
# through --results, software and badconfig are not gated (they write no slot and reboot
# nothing), and matrix2 is gated behind --yes like the other slot-writing phases.
hx2="$tmp/hx2/scripts/device"
mkdir -p "$hx2"
cp "$ft" "$hx2/full-test.sh"
cp "$root/scripts/device/lib.sh" "$hx2/lib.sh"
# package-classes.sh is in this set for the same reason the other three are: it stands
# between software and badconfig in the phase order, so a window that spans those two runs
# it, and a harness without its driver would report a GAP that says nothing about the phase
# under test.
for round2_driver in software-probe.sh:SW1 follow-baseline.sh:FB1 matrix-round2.sh:T1 package-classes.sh:PC1 badconfig-probe.sh:BC1; do
    driver=${round2_driver%%:*}
    case_name=${round2_driver##*:}
    cat >"$hx2/$driver" <<STUB
#!/bin/sh
res=""
for a in "\$@"; do
    case "\$a" in
        --results) res=next ;;
        *) [ "\${res:-}" = next ] && res=\${a:-} ;;
    esac
done
printf '${driver%.sh}-stub args=%s\n' "\$*"
printf '${case_name}\tPASS\tstub.log\tstub row\n' >>"\${res:?stub needs --results}"
exit 0
STUB
    chmod +x "$hx2/$driver"
done

run_hx2() {
    out=$(bash "$hx2/full-test.sh" "$@" </dev/null 2>&1)
    code=$?
    return 0
}

run_hx2 --from software --stop-after badconfig --results "$tmp/hx2-samples"
assert_eq "$code" 0 "ac-2 software and badconfig run without --yes"
assert_contains "$(cat "$tmp/hx2-samples/software.log")" "--results $tmp/hx2-samples/software.tsv" \
    "ac-2 software-probe.sh is pointed at its results file through --results"
assert_eq "$(awk -F'\t' '$1 == "SW1" { print $2 }' "$tmp/hx2-samples/software.tsv")" "PASS" \
    "ac-2 the software rows land in the software phase's own file"
assert_eq "$(awk -F'\t' '$1 == "BC1" { print $2 }' "$tmp/hx2-samples/badconfig.tsv")" "PASS" \
    "ac-2 the badconfig rows land in the badconfig phase's own file"
assert_contains "$(cat "$tmp/hx2-samples/badconfig.log")" \
    "--defects $tmp/hx2-samples/badconfig-defects.tsv" \
    "ac-2 the defect list reaches badconfig-probe.sh as --defects"
# Nothing here invents case names for the round-2 drivers: their vocabularies are theirs.
case "$(cat "$tmp/hx2-samples/software.log")" in
    *--case*)
        assert_eq "software asked for a case" "software asked for no case" \
            "ac-2 the software phase is not given a case name this script made up"
        ;;
    *)
        assert_eq "software asked for no case" "software asked for no case" \
            "ac-2 the software phase is not given a case name this script made up"
        ;;
esac

run_hx2 --from matrix2 --stop-after matrix2 --results "$tmp/hx2-matrix2-noyes"
assert_eq "$code" 1 "ac-2 matrix2 without --yes does not exit 0"
assert_contains "$(cat "$tmp/hx2-matrix2-noyes/matrix2.tsv")" "GAP" \
    "ac-2 matrix2 is gated behind --yes like the other slot-writing phases"
assert_contains "$(cat "$tmp/hx2-matrix2-noyes/matrix2.tsv")" "not confirmed" \
    "ac-2 the matrix2 refusal names --yes as the way through"
case "$out" in
    *matrix-round2-stub*)
        assert_eq "driver executed" "driver not executed" \
            "ac-2 an unconfirmed matrix2 executes nothing"
        ;;
    *)
        assert_eq "driver not executed" "driver not executed" \
            "ac-2 an unconfirmed matrix2 executes nothing"
        ;;
esac
run_hx2 --from matrix2 --stop-after matrix2 --yes --results "$tmp/hx2-matrix2"
assert_eq "$code" 0 "ac-2 matrix2 with --yes runs"
assert_eq "$(awk -F'\t' '$1 == "T1" { print $2 }' "$tmp/hx2-matrix2/matrix2.tsv")" "PASS" \
    "ac-2 the matrix2 rows land in the matrix2 phase's own file"

# --- ac-2: the orchestrator carries no second copy of the round's own lists ---------- #
# The samples are tests/fixtures/software-samples.json (read by software-probe.sh) and the
# 25.x line is decided by the drivers, not here. A sample name or a 24.x path baked into this
# script would be a second list to keep in sync, and a version line the round has excluded
# would come back in through the orchestration. Comments are skipped: they are allowed to
# explain what the phases judge.
script_hits=$(grep -nE 'openclash|istore|luci-app|argon|24\.[0-9]' "$ft" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)
assert_eq "${script_hits:-none}" "none" \
    "ac-2 full-test.sh names no sample and no 24.x path of its own"

finish
