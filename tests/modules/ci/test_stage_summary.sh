#!/usr/bin/env bash
# Module: ci
# Guards the two renderers that make a run page readable: scripts/ci/stage-summary.sh
# (one fixed block per stage) and the report table in scripts/ci/report.sh.
#
# Both are pure rendering: they must never change a verdict, and the summary must never
# fail a job. A missing artifact, a missing log or a missing Actions API dump may only
# degrade a cell to `n/a`.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

summary="$root/scripts/ci/stage-summary.sh"
report="$root/scripts/ci/report.sh"

HEADER='| stage | verdict | key line | artifact and sha256 | next command |'

# --------------------------------------------------------------------------- #
# ac-4: the stage block is the same five columns whatever the state
# --------------------------------------------------------------------------- #

pass_out="$(bash "$summary" --stage s2 --result success \
  --judge-line 'S2-RESULT=ok parts=4 images=538968064' \
  --artifact image-probe --artifact-file "$root/README.md" 2>&1)"
assert_eq "$?" "0" "ac-4 a passing stage renders with exit 0"
assert_contains "$pass_out" "## S2 image - PASS" "ac-4 the block names the stage and the verdict"
assert_contains "$pass_out" "$HEADER" "ac-4 the block carries the fixed five columns"
assert_contains "$pass_out" '`S2-RESULT=ok parts=4 images=538968064`' "ac-4 the judge line is the key line"
assert_contains "$pass_out" 'README.md' "ac-4 the artifact file is named"
digest="$(shasum -a 256 "$root/README.md" 2>/dev/null | cut -d' ' -f1)"
assert_contains "$pass_out" "${digest:0:12}" "ac-4 the artifact file carries a sha256 prefix"

fail_out="$(printf 'boot ok\nS2-RESULT=fail reason=part-count-mismatch\nS2-RESULT=ok parts=4\n' >"$tmp/judge.log"
  bash "$summary" --stage s2 --result failure --judge-log "$tmp/judge.log" \
    --artifact image-probe 2>&1)"
assert_eq "$?" "0" "ac-4 a failing stage still renders with exit 0"
assert_contains "$fail_out" "## S2 image - FAIL" "ac-4 a failing stage says FAIL"
assert_contains "$fail_out" 'S2-RESULT=fail reason=part-count-mismatch' \
  "ac-4 the failing judge line wins over a later passing one"
assert_contains "$fail_out" "bash scripts/ci/disk.sh" "ac-4 the failure names the local reproduction"

degraded_out="$(bash "$summary" --stage s4 --result success \
  --judge-line 'S4-RESULT=ok phase=commit slot=a' \
  --artifact evidence-s4 --artifact-file "$tmp/does-not-exist.img" 2>&1)"
assert_eq "$?" "0" "ac-4 a missing artifact file does not fail the step"
assert_contains "$degraded_out" 'does-not-exist.img' "ac-4 the missing file is still named"
assert_contains "$degraded_out" 'n/a' "ac-4 the missing digest degrades to n/a"

unknown_out="$(bash "$summary" --stage s9 --result success 2>&1)"
assert_eq "$?" "0" "ac-4 an unknown stage does not fail the step"
assert_contains "$unknown_out" "WARNING" "ac-4 an unknown stage is reported"

summary_file="$tmp/step-summary.md"
GITHUB_STEP_SUMMARY="$summary_file" bash "$summary" --stage s1 --result success \
  --judge-line 'S1-RESULT=ok kernel=6.12 modules=20 btrfs=mounted' >/dev/null 2>&1
assert_file_exists "$summary_file" "ac-4 the block is appended to the step summary"
assert_contains "$(cat "$summary_file")" "## S1 probe - PASS" \
  "ac-4 the step summary carries the block"

# --------------------------------------------------------------------------- #
# ac-5 / ac-6: the report table and its duration column
# --------------------------------------------------------------------------- #

cat >"$tmp/jobs.json" <<'JSON'
{"jobs": [
  {"name": "resolve upstream", "started_at": "2026-11-11T10:00:00Z", "completed_at": "2026-11-11T10:00:42Z"},
  {"name": "S1 probe - kernel mounts btrfs", "started_at": "2026-11-11T10:01:00Z", "completed_at": "2026-11-11T10:04:12Z"},
  {"name": "S3 boot - layered root", "started_at": "2026-11-11T10:05:00Z", "completed_at": "2026-11-11T10:09:05Z"}
]}
JSON

report_query() {
  env CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" CI_JOBS_JSON="$tmp/jobs.json" "$@"
}

ok_out="$(report_query CI_RESOLVE_RESULT=success CI_FETCH_RESULT=success CI_ASSEMBLE_RESULT=success \
  CI_S1_RESULT=success CI_S2_RESULT=success CI_S3_RESULT=success CI_S4_RESULT=success \
  CI_S5_RESULT=success CI_VERIFY_RESULT=success \
  CI_S3_LINE='S3-RESULT=ok slot=a upper=@overlay-25.12.2' \
  bash "$report" 2>&1)"
assert_eq "$?" "0" "ac-5 a passing run renders with exit 0"
assert_contains "$ok_out" '| stage | verdict | duration | artifact |' "ac-5 the report has the four columns"
assert_contains "$ok_out" "Verdict: all scheduled stages passed" "ac-5 the verdict is the first line"
assert_contains "$ok_out" "| S1 probe | PASS | 3m12s |" "ac-6 the duration comes from jobs.json"
assert_contains "$ok_out" "| resolve upstream | PASS | 42s |" "ac-6 a helper job duration is rendered too"
assert_contains "$ok_out" "| S2 image | PASS | n/a |" "ac-6 a job missing from jobs.json degrades to n/a"
assert_contains "$ok_out" "image-install" "ac-5 the artifact column names the install image"
assert_contains "$ok_out" "<details><summary>Judge lines</summary>" "ac-5 the judge lines are collapsed"

fail_report="$(report_query CI_RESOLVE_RESULT=success CI_FETCH_RESULT=success CI_S1_RESULT=success \
  CI_S2_RESULT=success CI_S3_RESULT=failure CI_S4_RESULT=skipped CI_S5_RESULT=skipped \
  CI_VERIFY_RESULT=success bash "$report" 2>&1)"
fail_code=$?
assert_eq "${fail_code}" "1" "ac-5 a failing run still exits non-zero"
assert_contains "$fail_report" "Verdict: failed at S3 boot" "ac-5 the first line names the stage that failed"
assert_contains "$fail_report" "--log-failed" "ac-5 the first line names the next command"

if command -v python3 >/dev/null 2>&1; then
  no_durations="$(env CI_TMP_ROOT="$tmp/ci2" CI_LOG_DIR="$tmp/ci2/logs" \
    CI_S1_RESULT=success bash "$report" 2>&1)"
  assert_eq "$?" "0" "ac-6 a run without jobs.json still reports"
  assert_contains "$no_durations" "| S1 probe | PASS | n/a |" \
    "ac-6 the duration degrades to n/a without the API dump"
fi

finish
