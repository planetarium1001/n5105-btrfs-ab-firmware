#!/usr/bin/env bash
# Module: ci
# ac-5 / ac-6: the schedule-state check, and the ci.yml job that runs it.
#
# Why this file exists: a scheduled workflow that GitHub disabled after 60 days of
# inactivity looks exactly like a repository where upstream stopped publishing - nothing
# happens, and nothing says anything. This check is the one place a run can notice it, so
# its three answers have to be told apart, because they lead to different actions:
#   0  active    nothing to do
#   1  disabled  re-enable the schedule, and find out why the keepalive did not hold
#   2  an error  the check itself could not ask - not the same fact, and not a pass
#
# Every case runs against a stub `gh` injected through PATH: the check never reaches the
# network, and the stub can answer with the state (or the failure) no real repository would
# produce on demand.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/schedule-health.sh"
CI_YML="$root/.github/workflows/ci.yml"

# The stub answers with $GH_STUB_STATE, records its arguments, and fails when the state is
# the literal `error`. Written with printf lines rather than a heredoc so the fixture is
# visible next to the assertions it serves.
mkdir -p "$tmp/bin"
{
  printf '#!/bin/sh\n'
  printf 'if [ -n "${GH_STUB_LOG:-}" ]; then printf "%%s\\n" "$*" >>"${GH_STUB_LOG}"; fi\n'
  printf 'if [ "${GH_STUB_STATE:-active}" = "error" ]; then\n'
  printf '  printf "HTTP 404: Not Found\\n" >&2\n'
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'printf "%%s\\n" "${GH_STUB_STATE:-active}"\n'
} >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

# health_run [arguments...]: run the check with the stub first on PATH, capturing the exit
# status in run_status and the output in run_out.
health_run() {
  run_out="$(PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY="example/repo" \
    GH_STUB_STATE="${GH_STUB_STATE:-active}" GH_STUB_LOG="$tmp/gh.log" \
    GITHUB_STEP_SUMMARY="$tmp/summary.md" sh "$SCRIPT" "$@" 2>&1)"
  run_status=$?
}

# --------------------------------------------------------------------------- #
# ac-5: active
# --------------------------------------------------------------------------- #

rm -f "$tmp/summary.md" "$tmp/gh.log"
health_run
assert_eq "$run_status" "0" "ac-5 an active schedule exits 0"
assert_contains "$run_out" "state=active" \
  "ac-5 the active answer is published as state=active"
assert_eq "$(grep -c 'state=disabled' <<<"$run_out" || true)" "0" \
  "ac-5 an active schedule is not reported as disabled"

# The request has to be the one the design names: the workflow file through the API, and
# the repository from the environment.
assert_contains "$(cat "$tmp/gh.log" 2>/dev/null || true)" \
  "api repos/example/repo/actions/workflows/upstream-watch.yml" \
  "ac-5 the state is read for the upstream watch workflow of this repository"
assert_contains "$(cat "$tmp/gh.log" 2>/dev/null || true)" "--jq .state" \
  "ac-5 only the state field is asked for"

health_run --workflow release.yml
assert_eq "$run_status" "0" "ac-5 --workflow selects another workflow and still exits 0"
assert_contains "$(cat "$tmp/gh.log" 2>/dev/null || true)" "workflows/release.yml" \
  "ac-5 the selected workflow is the one asked about"

# --------------------------------------------------------------------------- #
# ac-5: disabled
# --------------------------------------------------------------------------- #

for state in disabled_inactivity disabled_manually; do
  rm -f "$tmp/summary.md"
  GH_STUB_STATE="$state" health_run
  assert_eq "$run_status" "1" "ac-5 '${state}' is an error: the watch does not run"
  assert_contains "$run_out" "state=disabled" \
    "ac-5 '${state}' is published as state=disabled"
  assert_contains "$run_out" "${state}" \
    "ac-5 the run log says which state the API answered"
  assert_contains "$(cat "$tmp/summary.md" 2>/dev/null || true)" "## Schedule disabled" \
    "ac-5 the run page carries the reason, not only the red job"
  assert_contains "$(cat "$tmp/summary.md" 2>/dev/null || true)" \
    "gh workflow enable upstream-watch.yml --repo example/repo" \
    "ac-5 the run page carries the command that fixes it"
done

# A state this check has never seen is not healthy: `active` is the only value that means
# the schedule runs, and anything else has to be looked at.
GH_STUB_STATE="deleted" health_run
assert_eq "$run_status" "1" "ac-5 an unexpected state is not treated as active"
assert_contains "$run_out" "state=disabled" \
  "ac-5 an unexpected state is published as disabled"

# --------------------------------------------------------------------------- #
# ac-5: the check itself failing is a third answer
# --------------------------------------------------------------------------- #

GH_STUB_STATE=error health_run
assert_eq "$run_status" "2" "ac-5 a gh/API error exits 2"
assert_contains "$run_out" "gh api failed" \
  "ac-5 the error says which layer failed"
assert_contains "$run_out" "HTTP 404" \
  "ac-5 ... and repeats what gh answered"

run_out="$(env -u GITHUB_REPOSITORY -u GITHUB_STEP_SUMMARY PATH="$tmp/bin:$PATH" \
  sh "$SCRIPT" 2>&1)"
assert_eq "$?" "2" "ac-5 an unknown repository exits 2 instead of guessing one"

# A PATH that carries the shells the test needs but no gh: the script has to notice the
# missing client instead of failing for a reason of its own.
run_out="$(PATH="$tmp/empty-bin:/bin:/usr/bin" GITHUB_REPOSITORY="example/repo" sh "$SCRIPT" 2>&1)"
assert_eq "$?" "2" "ac-5 a host without gh exits 2 instead of pretending"
assert_contains "$run_out" "gh is not on PATH" \
  "ac-5 the missing gh is named"

run_out="$(PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY="example/repo" sh "$SCRIPT" --nope 2>&1)"
assert_eq "$?" "2" "ac-5 an unknown argument exits 2"

# --------------------------------------------------------------------------- #
# ac-6: the ci.yml job that runs it
# --------------------------------------------------------------------------- #

assert_eq "$(head -n 1 "$SCRIPT")" "#!/bin/sh" \
  "ac-5 the script is POSIX sh, the dialect the runner's /bin/sh is"

# job_block <workflow> <job-id>: one job of a workflow, header to the next job.
job_block() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:$/ { id = $1; sub(":$", "", id); injob = (id == want); if (injob) print; next }
    injob { print }
  ' "$1"
}

state_job="$(job_block "$CI_YML" schedule-state)"
assert_contains "${state_job}" "name: Schedule State" \
  "ac-6 ci.yml carries the schedule-state job"
assert_contains "${state_job}" "bash scripts/ci/schedule-health.sh" \
  "ac-6 the job runs the script, and the script owns the answer"
assert_contains "${state_job}" "actions: read" \
  "ac-6 the job asks for the one permission reading the workflow state needs"
assert_contains "${state_job}" "contents: read" \
  "ac-6 ... and no more than that"
for event in push pull_request workflow_dispatch; do
  assert_contains "${state_job}" "github.event_name == '${event}'" \
    "ac-6 the check runs on ${event}"
done
# A called run inherits the caller's event name, and ci.yml has no schedule trigger, so the
# `schedule` event is the one that means "upstream-watch.yml is calling this file".
assert_eq "$(grep -c "github.event_name != 'workflow_call'" <<<"${state_job}" || true)" "0" \
  "ac-6 the skip is not spelled as a workflow_call event, which a called run never sees"
assert_eq "$(grep -c "github.event_name == 'schedule'" <<<"${state_job}" || true)" "0" \
  "ac-6 a scheduled (called) run is excluded by naming the three events that are not it"
assert_eq "$(grep -c 'timeout-minutes:' <<<"${state_job}")" "1" \
  "ac-6 the job carries its own timeout budget"

finish
