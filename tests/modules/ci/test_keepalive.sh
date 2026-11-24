#!/usr/bin/env bash
# Module: ci
# ac-2 / ac-4: the monthly keepalive is a log line in .github/keepalive.log, and the
# heartbeat tag it replaced is gone.
#
# Why this file exists: the scheduled watch is disabled after 60 days without repository
# activity, and "no activity" is the normal state of a repository whose upstream publishes
# twice a year. The keepalive is the activity. Three things have to hold, and each of them
# failed silently in the tag this replaced:
#   * it fires only when the baseline is old enough - a script that appended a line per day
#     would turn the mechanism into noise and the log into a diary
#   * re-running is a no-op - the workflow can be re-run by hand, and a second line for the
#     same day would make the file look like two months of activity
#   * it never writes without saying so - the workflow pushes the file, so "created" and
#     "skipped" are the workflow's only two decisions
#
# Every case runs in its own throw-away repository with GIT_*_DATE-set commits: the
# "24 days" and "25 days" cases are real git state, not a mock of one.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/keepalive.sh"
WATCH="$root/.github/workflows/upstream-watch.yml"
LOG_REL=".github/keepalive.log"

# new_repo <dir> <commit-date>: an empty repository with one commit at that date. The date
# is the keepalive's whole baseline, so it is the fixture's one input.
new_repo() {
  local dir=$1 date=$2
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.name "ci test"
  git -C "$dir" config user.email "ci@example.test"
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$dir" commit -q --allow-empty -m "base ${date}"
}

# keepalive_run <repo> <output-env-file> [arguments...]: run the script the way the workflow
# does - as `sh`, because the file is POSIX sh and the runner's /bin/sh is dash - with the
# caller's output channels taken away so the assertions read CI_OUTPUT_ENV.
keepalive_run() {
  local repo=$1 out=$2
  shift 2
  run_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out" \
    CI_TMP_ROOT="$tmp/ci" CI_REPO_ROOT="$repo" sh "$SCRIPT" "$@" 2>&1)"
  run_status=$?
}

# output_of <output-env-file> <key>
output_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# log_lines <repo>: how many keepalive lines the repository carries, 0 when there is no file.
log_lines() {
  if [ -f "$1/$LOG_REL" ]; then
    wc -l <"$1/$LOG_REL" | tr -d ' '
  else
    printf '0'
  fi
}

# --------------------------------------------------------------------------- #
# ac-2: 0-24 days skip, 25 days append one line
# --------------------------------------------------------------------------- #

young="$tmp/young"
new_repo "$young" "2026-08-13T00:00:00Z"
keepalive_run "$young" "$tmp/o-young.env" run --now 2026-09-06
assert_eq "$run_status" "0" "ac-2 a repository younger than the interval exits 0"
assert_eq "$(output_of "$tmp/o-young.env" action)" "skipped" \
  "ac-2 24 days since the last commit is not yet due"
assert_eq "$(output_of "$tmp/o-young.env" days_since)" "24" \
  "ac-2 days_since counts whole days from the last commit"
assert_eq "$(output_of "$tmp/o-young.env" reason)" "too-soon" \
  "ac-2 the skip says why it skipped"
assert_eq "$(log_lines "$young")" "0" \
  "ac-2 a skipped run writes no file at all"

edge="$tmp/edge"
new_repo "$edge" "2026-08-13T00:00:00Z"
keepalive_run "$edge" "$tmp/o-edge.env" run --now 2026-09-07
assert_eq "$(output_of "$tmp/o-edge.env" action)" "created" \
  "ac-2 25 days is due: the boundary is inclusive"
assert_eq "$(output_of "$tmp/o-edge.env" days_since)" "25" \
  "ac-2 the boundary case reports 25 days"
assert_eq "$(log_lines "$edge")" "1" \
  "ac-2 a due run appends exactly one line"

# The line is the record: its shape is what a reader three months later parses, so the
# timestamp, the token, the commit and the gap are asserted one by one rather than loosely.
line="$(cat "$edge/$LOG_REL")"
assert_matches "$line" '^2026-09-07T00:00:00Z keepalive last_commit=[0-9a-f]{40} days_since=25$' \
  "ac-2 the appended line is '<UTC ISO8601> keepalive last_commit=<sha> days_since=<n>'"
assert_eq "$(output_of "$tmp/o-edge.env" line)" "$line" \
  "ac-2 the script publishes the line it appended"
assert_eq "$(output_of "$tmp/o-edge.env" last_commit)" \
  "$(git -C "$edge" rev-parse HEAD)" \
  "ac-2 last_commit is the default branch's last commit"
assert_contains "$run_log" "appended to ${LOG_REL}" \
  "ac-2 the run log names the file it wrote"

# A real run has no --now: the timestamp is then the actual UTC instant, and the same line
# shape still has to hold. Without this the format is only ever proved against the
# injected clock.
realtime="$tmp/realtime"
new_repo "$realtime" "2026-01-05T00:00:00Z"
keepalive_run "$realtime" "$tmp/o-realtime.env" run
assert_eq "$(output_of "$tmp/o-realtime.env" action)" "created" \
  "ac-2 a repository idle for months is due without --now"
assert_matches "$(cat "$realtime/$LOG_REL")" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z keepalive last_commit=[0-9a-f]{40} days_since=[0-9]+$' \
  "ac-2 the line written without --now carries the real UTC timestamp"

# --------------------------------------------------------------------------- #
# ac-2: the same day, and the same commit, are a no-op
# --------------------------------------------------------------------------- #

keepalive_run "$edge" "$tmp/o-edge2.env" run --now 2026-09-07
assert_eq "$run_status" "0" "ac-2 a second run on the same day exits 0"
assert_eq "$(output_of "$tmp/o-edge2.env" action)" "skipped" \
  "ac-2 a second run on the same day writes nothing"
assert_eq "$(output_of "$tmp/o-edge2.env" reason)" "already-logged-today" \
  "ac-2 the idempotent skip says the day is already recorded"
assert_eq "$(log_lines "$edge")" "1" \
  "ac-2 the idempotent run leaves exactly one line"
assert_eq "$(output_of "$tmp/o-edge2.env" line)" "" \
  "ac-2 a skipped run publishes no line"

# A month later the same repository still has the same HEAD: the keepalive line it already
# carries names that commit, so appending a second line for one commit would be a lie about
# how often the repository changed.
keepalive_run "$edge" "$tmp/o-edge3.env" run --now 2026-10-07
assert_eq "$(output_of "$tmp/o-edge3.env" action)" "skipped" \
  "ac-2 a commit already recorded in the log is not recorded twice"
assert_eq "$(output_of "$tmp/o-edge3.env" reason)" "already-recorded" \
  "ac-2 the reason names the existing record"
assert_eq "$(log_lines "$edge")" "1" \
  "ac-2 the same commit still has one line"

# ... and a new commit moves the baseline, so the log can grow again when it has to.
GIT_AUTHOR_DATE="2026-10-08T00:00:00Z" GIT_COMMITTER_DATE="2026-10-08T00:00:00Z" \
  git -C "$edge" commit -q --allow-empty -m "later work"
keepalive_run "$edge" "$tmp/o-edge4.env" run --now 2026-11-03
assert_eq "$(output_of "$tmp/o-edge4.env" action)" "created" \
  "ac-2 a new commit restarts the interval"
assert_eq "$(log_lines "$edge")" "2" \
  "ac-2 the second line is appended after the first, not instead of it"

# --------------------------------------------------------------------------- #
# ac-2: the interval is configurable, and the default is 25 days
# --------------------------------------------------------------------------- #

ten="$tmp/ten"
new_repo "$ten" "2026-08-13T00:00:00Z"
run_log="$(env -u GITHUB_OUTPUT CI_OUTPUT_ENV="$tmp/o-ten.env" CI_TMP_ROOT="$tmp/ci" \
  CI_REPO_ROOT="$ten" CI_KEEPALIVE_INTERVAL_DAYS=10 sh "$SCRIPT" run --now 2026-08-23 2>&1)"
assert_eq "$?" "0" "ac-2 an explicit interval is accepted"
assert_eq "$(output_of "$tmp/o-ten.env" action)" "created" \
  "ac-2 CI_KEEPALIVE_INTERVAL_DAYS moves the boundary"
assert_eq "$(output_of "$tmp/o-ten.env" days_since)" "10" \
  "ac-2 the moved boundary is exactly the configured interval"

# The default is a contract the workflow relies on: it passes no interval at all.
assert_eq "$(output_of "$tmp/o-young.env" days_since)" "24" \
  "ac-2 without an interval the script judged 24 days (not due)"
assert_eq "$(output_of "$tmp/o-edge.env" action)" "created" \
  "ac-2 without an interval 25 days is due: the default is 25"

# --------------------------------------------------------------------------- #
# ac-2: --dry-run proves the decision without writing
# --------------------------------------------------------------------------- #

dry="$tmp/dry"
new_repo "$dry" "2026-08-13T00:00:00Z"
keepalive_run "$dry" "$tmp/o-dry.env" run --now 2026-10-12 --dry-run
assert_eq "$run_status" "0" "ac-2 --dry-run exits 0"
assert_eq "$(output_of "$tmp/o-dry.env" action)" "would-create" \
  "ac-2 --dry-run reports would-create instead of created"
assert_eq "$(output_of "$tmp/o-dry.env" reason)" "due" \
  "ac-2 --dry-run still reports the decision it made"
assert_eq "$(log_lines "$dry")" "0" \
  "ac-2 --dry-run writes nothing"

# --------------------------------------------------------------------------- #
# ac-2: refusals
# --------------------------------------------------------------------------- #

keepalive_run "$edge" "$tmp/o-badnow.env" run --now 2026-13-99
assert_eq "$run_status" "1" "ac-2 an unparsable --now is refused"
keepalive_run "$edge" "$tmp/o-unknown.env" --tomorrow
assert_eq "$run_status" "1" "ac-2 an unknown argument is refused"
keepalive_run "$edge" "$tmp/o-norun.env" --now 2026-09-07
assert_eq "$run_status" "1" "ac-2 the run subcommand is required"

mkdir -p "$tmp/not-a-repo"
run_log="$(env -u GITHUB_OUTPUT CI_OUTPUT_ENV="$tmp/o-norepo.env" CI_REPO_ROOT="$tmp/not-a-repo" \
  sh "$SCRIPT" run 2>&1)"
assert_eq "$?" "1" "ac-2 a directory that is not a git repository is refused"
assert_contains "$run_log" "not a git repository" \
  "ac-2 the refusal names what is wrong"

# --------------------------------------------------------------------------- #
# ac-2 / ac-4: the workflow half, and the tag that is gone
# --------------------------------------------------------------------------- #

assert_file_exists "$SCRIPT" "ac-2 the keepalive script exists"
assert_eq "$(head -n 1 "$SCRIPT")" "#!/bin/sh" \
  "ac-2 the keepalive script is POSIX sh, the dialect the runner's /bin/sh is"

# job_block <job-id>: one job of the workflow, header to the next job.
job_block() {
  awk -v want="$1" '
    /^  [A-Za-z0-9_-]+:$/ { id = $1; sub(":$", "", id); injob = (id == want); if (injob) print; next }
    injob { print }
  ' "$WATCH"
}

keepalive_job="$(job_block keepalive)"
assert_contains "${keepalive_job}" "name: Keepalive Commit" \
  "ac-2 the watch has a keepalive job"
assert_contains "${keepalive_job}" "github.event_name == 'schedule'" \
  "ac-2 the keepalive runs on the schedule, not on a rehearsal dispatch"
assert_contains "${keepalive_job}" "contents: write" \
  "ac-2 the keepalive job may write, because it commits its own line"
assert_contains "${keepalive_job}" "fetch-depth: 0" \
  "ac-2 the keepalive job fetches the history the rebase retry needs"
assert_contains "${keepalive_job}" 'bash scripts/ci/keepalive.sh run' \
  "ac-2 the job runs the script, and the script owns the decision"
assert_contains "${keepalive_job}" 'git add .github/keepalive.log' \
  "ac-2 only the log file is committed"
assert_contains "${keepalive_job}" 'git push' \
  "ac-2 the line reaches the default branch"
assert_contains "${keepalive_job}" 'git rebase' \
  "ac-2 a rejected push is rebased onto the branch as it is now"
assert_contains "${keepalive_job}" 'attempt}" -le 3' \
  "ac-2 the retry is bounded at three attempts"
assert_contains "${keepalive_job}" 'ACTION}" = "created"' \
  "ac-2 the push only happens when the script created a line"

# --------------------------------------------------------------------------- #
# ac-2: the line is committable, not only writable
# --------------------------------------------------------------------------- #

# The commit step runs `git add .github/keepalive.log` under `set -euo pipefail`, so one
# refused add is one red job - and it is the failure the schedule cannot show on the day:
# 24 runs out of 25 answer `skipped` and never reach that step, so it would surface only
# on the day the line matters. The ignore rules are therefore asked in a throw-away
# repository that carries this repository's .gitignore and no tracked file yet:
# `git check-ignore` also answers "not ignored" for a path that merely happens to be
# tracked already, which is how the `*.log` rule hid behind a green suite before.
fresh="$tmp/fresh-clone"
new_repo "$fresh" "2026-11-25T00:00:00Z"
cp "$root/.gitignore" "$fresh/.gitignore"
mkdir -p "$fresh/.github"
printf '2026-11-25T00:00:00Z keepalive last_commit=%s days_since=25\n' \
  "$(git -C "$fresh" rev-parse HEAD)" >"$fresh/$LOG_REL"
: >"$fresh/.github/automation-log.md"
git -C "$fresh" add "$LOG_REL" 2>"$tmp/add-keepalive.err"
assert_eq "$?" "0" "ac-2 this repository's ignore rules accept .github/keepalive.log"
git -C "$fresh" add .github/automation-log.md 2>"$tmp/add-automation.err"
assert_eq "$?" "0" "ac-2 this repository's ignore rules accept .github/automation-log.md"

# In the repository itself the exception in `.gitignore` is the contract, and it has to be
# asked without the index: a tracked path answers "not ignored" whatever the rules say, and
# `git check-ignore -v` exits 0 even when the rule it prints is a negation
# (`!.github/keepalive.log`), so the verdict comes from `-q --no-index` and `-v` only
# explains it. `keepalive.log` stays untracked until the first due run appends to it.
for record in "$LOG_REL" .github/automation-log.md; do
  if git check-ignore -q --no-index -- "$record"; then
    _assert_fail "ac-2 $record is not ignored in this repository" \
      "git check-ignore -q --no-index matched an ignore rule: $(git check-ignore -v --no-index -- "$record" 2>&1)"
  else
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-2 $record is not ignored in this repository"
  fi
done

# Two paths, one contract: the guard above is only worth its bytes while the file the
# workflow adds is the file the script writes. A rename on one side alone would leave the
# workflow adding a path nothing writes and this test still green.
script_log_rel=$(sed -n 's/^CI_KEEPALIVE_LOG_REL="\(.*\)"$/\1/p' "$SCRIPT")
assert_eq "$script_log_rel" "$LOG_REL" "ac-2 the script writes the record path this test names"
workflow_add=$(printf '%s\n' "${keepalive_job}" | sed -n 's/^ *git add \(.*\)$/\1/p' | head -n 1)
assert_eq "$workflow_add" "$script_log_rel" \
  "ac-2 the workflow commits the file the script writes"

# The tag is the thing that left: no job, no script, no test. A stale job would push a tag
# nothing reads; a stale script would keep its own tests alive.
assert_eq "$(grep -c 'heartbeat' "$WATCH" || true)" "0" \
  "ac-4 the watch carries no heartbeat left over: no job, step, output or log name"
assert_eq "$(grep -c '^  heartbeat:$' "$WATCH" || true)" "0" \
  "ac-4 the heartbeat job is gone from the graph"
if [ -e "$root/scripts/ci/heartbeat-tag.sh" ]; then
  _assert_fail "ac-4 scripts/ci/heartbeat-tag.sh is deleted" "the script is still there"
else
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-4 scripts/ci/heartbeat-tag.sh is deleted"
fi
if [ -e "$root/tests/modules/ci/test_heartbeat_tag.sh" ]; then
  _assert_fail "ac-4 tests/modules/ci/test_heartbeat_tag.sh is deleted" "the test is still there"
else
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-4 tests/modules/ci/test_heartbeat_tag.sh is deleted"
fi
# The code and the workflow may not call it. The prose (scripts/ci/README.md, docs/, and
# the fingerprint baseline) is a separate edit: this assertion is the one that catches a
# job still running a script nobody ships. The literal is assembled so this file does not
# match itself.
retired="heartbeat-""tag.sh"
assert_eq "$(grep -rl "${retired}" .github scripts/ci/*.sh 2>/dev/null | wc -l | tr -d ' ')" \
  "0" "ac-4 no workflow or CI script still calls the deleted script"

finish
