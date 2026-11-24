#!/usr/bin/env bash
# Module: ci
# ac-2: the watch is the only entry point, and a day without a new upstream release ends
# successfully without leaving anything behind.
#
# Why this file exists: "nothing new" is the outcome of most runs, and it is the one
# outcome nobody notices when it breaks. A watch that opens an empty branch, an empty pull
# request or a heartbeat release every night is worse than no watch at all, so the shape of
# the workflow - not only its behaviour - is what these assertions pin down.
#
# ac-3 evidence (a green rehearsal and a red run) is not in this file: it comes from real
# runs of this workflow and is recorded as evidence:auto-release-green/red.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

watch=".github/workflows/upstream-watch.yml"
assert_file_exists "$watch" "ac-2 the upstream watch workflow exists"
text=$(cat "$watch")

# job_block <job-id>: one job of the workflow, header to the next job.
job_block() {
  awk -v want="$1" '
    /^  [A-Za-z0-9_-]+:$/ { id = $1; sub(":$", "", id); injob = (id == want); if (injob) print; next }
    injob { print }
  ' "$watch"
}

# --------------------------------------------------------------------------- #
# ac-2: one entry point, on a schedule and on demand
# --------------------------------------------------------------------------- #

assert_contains "$text" "on:
  schedule:" "ac-2 the watch runs on a schedule"
# The cron is anchored at UTC 16:00, which is Beijing midnight: UTC+8 and no daylight
# saving, so the two clocks never drift apart. The anchor is the intent (one run per Beijing
# day, at 00:00) and nothing shifts it to compensate for GitHub's queue delay.
assert_contains "$text" 'cron: "0 16 * * *"' \
  "ac-1 the watch runs at UTC 16:00, which is Beijing midnight"
assert_eq "$(grep -c 'cron:' "$watch")" "1" \
  "ac-1 one cron, not a pair: a second daily run buys a hit rate and costs a full build"
schedule_comment=$(sed -n '/^  schedule:/,/^    - cron:/p' "$watch")
assert_contains "$schedule_comment" "best-effort" \
  "ac-1 the comment above the cron says the start time is best-effort, not a guarantee"
assert_contains "$schedule_comment" "Beijing midnight" \
  "ac-1 the comment names the local time the anchor is meant to be"
assert_contains "$schedule_comment" "UTC 16:00" \
  "ac-1 ... and the UTC spelling it is actually written in"
assert_contains "$schedule_comment" "no daylight saving" \
  "ac-1 the comment says why the offset never needs a seasonal correction"
# `timezone:` would be the other spelling of the same intent, and it is refused: the
# actionlint this repository pins at 1.7.7 may not know a newer trigger key, and a workflow
# that fails to parse stops a run before it starts.
assert_eq "$(grep -cE '^ +timezone:' "$watch" || true)" "0" \
  "ac-1 the schedule declares no timezone field: the offset lives in the cron"
# The old anchor is asserted out: a run at UTC midnight was 08:00 in Beijing, the morning
# this anchor deliberately moves away from. The literal is assembled rather than written out,
# because a test that contains the string it searches for matches itself.
old_cron="0 0 $(printf '%s %s %s' '*' '*' '*')"
assert_eq "$(grep -cF "${old_cron}" "$watch" || true)" "0" \
  "ac-1 the workflow declares no UTC-midnight cron any more"
# The tests are the other half of the same claim. The bracket forms keep this file from
# matching its own pattern: what is grepped for is the literal text, not this regex.
assert_eq "$(grep -rEn '0 0 [*] [*] [*]' tests/modules/ci 2>/dev/null | wc -l | tr -d ' ')" \
  "0" "ac-1 no CI test still asserts the old anchor"
assert_contains "$text" "  workflow_dispatch:" "ac-2 the watch can be dispatched by hand"
assert_eq "$(grep -c '^  push:' "$watch")" "0" \
  "ac-2 the watch is not triggered by a push: a push by GITHUB_TOKEN would not trigger it anyway"

# GitHub cannot nest concurrency: a reusable workflow that declares a concurrency group is
# silently dropped when its caller declares one too, and the pipeline this run builds with
# (ci.yml) declares one. Single-flight is covered by the merge guard instead, so both facts
# are asserted here: no concurrency block, and a guard that stops a second run.
assert_eq "$(grep -c '^concurrency:' "$watch")" "0" \
  "ac-2 the watch declares no concurrency group, so the pipeline call is not dropped"
assert_contains "$text" "GitHub cannot nest concurrency" \
  "ac-2 the reason the group is absent is written down where the group would be"
assert_contains "$(job_block merge)" "already pins" \
  "ac-2 a second overlapping run stops when the base branch already carries the pin"
# Two halves of the idempotency, decided separately: a failure can land between the squash
# and the tag, so "the release already happened" has two different answers.
assert_contains "$(job_block merge)" "skip_merge" \
  "ac-3 the merge reads whether the squash already landed"
assert_contains "$(job_block merge)" "skip_tag" \
  "ac-3 the merge reads whether the tag already exists"
assert_contains "$(job_block merge)" "ls-remote --tags" \
  "ac-3 the pushed tag is read from the remote, not from a checkout that may not have it"
assert_contains "$(job_block merge)" "tags are immutable" \
  "ac-3 a tag that points at another commit is refused, never moved"

# --------------------------------------------------------------------------- #
# ac-2: nothing happens when nothing is new
# --------------------------------------------------------------------------- #

assert_contains "$(job_block bump)" "needs.detect.outputs.changed == 'true'" \
  "ac-2 the branch is only opened when a release was detected"
# The quiet day is no longer a tag. The keepalive job runs on the schedule and lets the
# script decide (24 days out of 25 answer `skipped` and write nothing), and the audit row
# only exists when a release was detected - so "nothing new" still leaves the graph green
# and the two record files untouched.
assert_contains "$(job_block keepalive)" "github.event_name == 'schedule'" \
  "ac-2 the keepalive runs on the schedule, where a disabled watch is the risk"
assert_contains "$(job_block audit)" "changed == 'true'" \
  "ac-2 the audit row is only written when a release was detected"
assert_eq "$(grep -c 'heartbeat' "$watch" || true)" "0" \
  "ac-4 the heartbeat tag job is gone from the graph"

# The side effects that may not happen on a quiet day: one place each, and every one of them
# inside a job that the detection gates.
assert_eq "$(grep -c 'gh pr create' "$watch")" "1" \
  "ac-2 exactly one job opens a pull request"
assert_contains "$(job_block bump)" "gh pr create" \
  "ac-2 the pull request is opened by the bump job"
assert_eq "$(grep -c 'gh release create' "$watch")" "0" \
  "ac-2 the watch never creates a release itself: the reusable workflow does"

for job in locks merge; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  block=$(job_block "$job")
  case "${block}" in
    *"needs:"*bump*) printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-2 the $job job depends on the bump job" ;;
    *) _assert_fail "ac-2 the $job job depends on the bump job" "needs does not mention bump" ;;
  esac
done

# --------------------------------------------------------------------------- #
# ac-2: the change is a branch and a pull request, never a push to main
# --------------------------------------------------------------------------- #

assert_contains "$(job_block bump)" 'branch="auto/upstream-${VERSION}"' \
  "ac-2 the automatic branch is named auto/upstream-<ver>"
assert_contains "$(job_block bump)" 'git push --force-with-lease' \
  "ac-2 the branch is pushed so a re-run updates it instead of failing"
assert_eq "$(grep -cE 'push.*refs/heads/(main|master)"' <<<"$(job_block bump)" || true)" "0" \
  "ac-2 the pin change is never pushed straight to main"
assert_eq "$(grep -c 'gh pr create' <<<"$(job_block bump)")" "1" \
  "ac-2 the pin change is a pull request"
# Two jobs do push to the default branch, and each pushes exactly one record file. That is
# the one exception to the rule above, and it is the opposite case: a keepalive line or an
# audit row that waited for a pull request would arrive days after the event it records.
# The pin, the lockfiles and VERSION are still never part of such a push.
for job in keepalive audit; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  block=$(job_block "$job")
  case "${block}" in
    *"git add .github/keepalive.log"* | *"git add .github/automation-log.md"*)
      printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-2 the $job job commits only its record file" ;;
    *) _assert_fail "ac-2 the $job job commits only its record file" "no record-file git add in the job" ;;
  esac
done
assert_contains "$(job_block bump)" 'main|master) echo "a dry run may not open a PR against' \
  "ac-2 a rehearsal may not open a pull request against main"

# --------------------------------------------------------------------------- #
# ac-2 / ac-3: the whole chain is one run graph
# --------------------------------------------------------------------------- #

# The discovery, the build, the merge, the tag and the publish are jobs of this workflow,
# linked by `needs`. Nothing waits for a push or a tag to start the next step.
for job in detect keepalive bump build locks merge publish audit; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [ -n "$(job_block "$job")" ]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-3 the watch graph carries the $job job"
  else
    _assert_fail "ac-3 the watch graph carries the $job job" "no such job in $watch"
  fi
done
assert_contains "$(job_block merge)" "needs: [detect, bump, build, locks]" \
  "ac-3 the merge waits for the detection, the branch, the build and the lockfiles"
assert_contains "$(job_block publish)" "needs: [detect, merge]" \
  "ac-3 the publish runs after the merge, in the same graph"
assert_contains "$(job_block publish)" 'uses: ./.github/workflows/release-publish.yml' \
  "ac-6 the upstream line publishes through the shared reusable workflow"

# The build is ci.yml itself, called as a reusable workflow in this run: one graph, one
# verdict. A commit pushed with GITHUB_TOKEN would not trigger that pipeline, which is why
# it cannot be a push away.
assert_contains "$(job_block build)" 'uses: ./.github/workflows/ci.yml' \
  "ac-3 the build is the ordinary pipeline, not a copy of it"
assert_contains "$(job_block build)" 'upstream_version: ${{ needs.detect.outputs.version }}' \
  "ac-3 the pipeline is told which upstream release to build"
# ci.yml skips a stage it was not asked for when the triggering event is a
# workflow_dispatch, and a rehearsal is always dispatched. Leaving the stage to its default
# skipped S1-S5 and assemble, the run went green, and publish then failed with
# "Artifact not found for name: image-install" (run 43789908639): the automatic release
# had nothing to publish. The build therefore names the whole pipeline.
assert_contains "$(job_block build)" 'stage: all' \
  "ac-3 the build asks for every stage: a dispatched run would otherwise skip all of them"
assert_eq "$(grep -c 'stage: ' <<<"$(job_block build)")" "1" \
  "ac-6 the stage is named once, so a second value cannot silently disagree"
# A reusable workflow only accepts an input it declares. The stage was declared under
# workflow_dispatch alone, so passing it through workflow_call failed the run at startup
# with no job list at all (run 43791166821) - the caller looked broken, not the input.
ci_yml=".github/workflows/ci.yml"
assert_file_exists "$ci_yml" "ac-3 the pipeline the watch calls exists"
assert_eq "$(awk '/^  workflow_call:/{f=1;next} f&&/^  [a-z_]+:/{exit} f&&/^      stage:/{print "declared"}' "$ci_yml")" \
  "declared" "ac-3 ci.yml accepts the stage through workflow_call, not only through dispatch"
assert_eq "$(grep -c 'gh workflow run' "$watch")" "0" \
  "ac-3 the watch starts no second workflow run"

# --------------------------------------------------------------------------- #
# ac-3: red does not merge, does not tag, and leaves one place to look
# --------------------------------------------------------------------------- #

assert_contains "$(job_block issue)" 'if: ${{ failure() || cancelled() }}' \
  "ac-3 a failed run still runs the reporting job"
assert_contains "$(job_block issue)" 'issues: write' \
  "ac-3 the reporting job may write an issue"
assert_contains "$(job_block issue)" 'title="[auto-release] ${VERSION:-unknown}"' \
  "ac-3 the failure issue title is stable per upstream version"
assert_contains "$(job_block issue)" 'gh issue create' \
  "ac-3 a failure opens a fixed issue"
assert_contains "$(job_block issue)" 'gh issue comment "${existing}"' \
  "ac-3 a second failure updates the same issue instead of opening another one"
assert_contains "$(job_block issue)" 'gh label create auto-release' \
  "ac-3 the issue carries a stable label"

# The merge may only run when the build and the lockfiles were green: `needs` already
# enforces that, so no `if: always()` may sneak in and bypass it.
assert_eq "$(job_block merge | grep -c 'if: always()')" "0" \
  "ac-3 the merge never runs unconditionally"
assert_eq "$(job_block publish | grep -c 'if: always()')" "0" \
  "ac-3 the publish never runs unconditionally"

# What gets merged is what was built.
assert_contains "$(job_block merge)" 'the automatic branch changes files a build did not prove' \
  "ac-3 the merge refuses a branch that touches anything but the pin and the lockfiles"

# --------------------------------------------------------------------------- #
# ac-2: conventions every workflow in this repository follows
# --------------------------------------------------------------------------- #

assert_eq "$(python3 - "$watch" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read().split("\njobs:\n", 1)[1]
jobs = re.findall(r"^  ([A-Za-z0-9_-]+):\n((?:    .*\n|\n)*)", text, re.M)
problems = []
for job, body in jobs:
    if re.search(r"^    uses:", body, re.M):
        if re.search(r"^    timeout-minutes:", body, re.M):
            problems.append(f"{job}: a reusable-workflow call cannot carry a timeout")
        continue
    if not re.search(r"^    timeout-minutes:", body, re.M):
        problems.append(f"{job}: no timeout-minutes")
print("\n".join(problems))
PY
)" "" "ac-2 every runnable job of the watch declares a timeout budget"

unpinned=$(grep -E '^\s*uses:' "$watch" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
  | grep -vE '^\./' | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}( # v[0-9].*)?$' || true)
assert_eq "$unpinned" "" "ac-2 every third-party action of the watch is pinned to a 40-character sha"

# The watch may not write the platform version: the release is identified by the upstream
# version, and VERSION belongs to the tagged line.
assert_eq "$(grep -cE '(>>? *VERSION|git add +VERSION)' "$watch")" "0" \
  "ac-4 the watch never edits VERSION"

# --------------------------------------------------------------------------- #
# ac-2: the security and correctness details the shape depends on
# --------------------------------------------------------------------------- #

# Read by default, write where it writes: a workflow-level write grant is how a job that
# never needed it ends up able to push.
assert_contains "$(sed -n '/^permissions:/,/^$/p' "$watch")" "contents: read" \
  "ac-2 the watch asks for contents: read at workflow level"
assert_eq "$(grep -c 'permissions:' "$watch" | awk '{print ($1 >= 6) ? "yes" : "no"}')" "yes" \
  "ac-2 every writing job narrows the grant itself"

# What each checkout has to carry is what its job reads. `detect` answers "where did this
# release stop" from the pin the *base branch* carries, so it needs the branches, not the
# tags; the tag state comes from the remote. `keepalive` needs the history its rebase-and-
# retry rebases onto. Neither of them needs an empirical depth.
assert_contains "$(job_block detect)" "fetch-depth: 0" \
  "ac-5 the detect job fetches the full history, so origin/<base> is readable"
assert_eq "$(grep -c 'fetch-tags: true' "$watch" || true)" "0" \
  "ac-5 no checkout fetches tags any more: the tag state is read from the remote"
assert_contains "$(job_block keepalive)" "fetch-depth: 0" \
  "ac-5 the keepalive job fetches the history its rebase retry needs"
assert_eq "$(grep -c 'fetch-depth: 50' "$watch" || true)" "0" \
  "ac-5 no checkout declares depth 50: an empirical depth drifts with commit density"
# The dead parameter: the heartbeat script never read CI_MATRIX_CANDIDATES, so passing it
# looked like wiring while carrying nothing - and the step itself is gone.
assert_eq "$(grep -c 'CI_MATRIX_CANDIDATES: \${{ steps.matrix' "$watch")" "0" \
  "ac-1 the detect job does not pass a variable no script reads"
assert_eq "$(grep -c 'steps.heartbeat' "$watch" || true)" "0" \
  "ac-4 no job still reads the deleted heartbeat step's outputs"

# The tag has to name what the merge produced, not whatever the branch points at now.
assert_contains "$(job_block merge)" "mergeCommit" \
  "ac-3 the tag is created on the merge commit the API reports"

# --------------------------------------------------------------------------- #
# ac-2: a rehearsal may not merge, tag or publish
# --------------------------------------------------------------------------- #

# The switch is the job-level env, read by the two steps that publish. `inputs.dry-run` on
# a schedule run is empty rather than "false", so it is normalised once, at job level.
assert_contains "$(job_block merge)" 'DRY_RUN: ${{ inputs.dry-run }}' \
  "ac-2 the merge job normalises the rehearsal switch once"
# The two publishing steps, plus the audit commit: a rehearsal may publish a draft release
# and write its row in the workspace, but it may not move the default branch.
assert_eq "$(grep -c 'env.DRY_RUN != .true.' "$watch")" "3" \
  "ac-2 the two publishing steps and the audit commit are gated on the rehearsal switch"
assert_contains "$(job_block audit)" "if: env.DRY_RUN != 'true'" \
  "ac-6 a rehearsal does not push its audit row to the default branch"
assert_contains "$(job_block merge)" "if: steps.state.outputs.skip_merge != 'true' && env.DRY_RUN != 'true'" \
  "ac-2 a rehearsal does not squash-merge"
assert_contains "$(job_block merge)" "if: steps.state.outputs.skip_tag != 'true' && env.DRY_RUN != 'true'" \
  "ac-2 a rehearsal does not tag"
# Skipping must be legible on the run page: a silently skipped step reads as a failure.
assert_contains "$(job_block merge)" "A rehearsal still publishes a draft release" \
  "ac-2 the skipped tag step says the rehearsal still publishes a draft"
# What a rehearsal must still do, or it would prove nothing.
for kept in "Guard the diff" "Squash merge" "Read the merge state"; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [ -n "$(job_block merge | grep -F -- "$kept")" ]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-2 the rehearsal still reaches '$kept'"
  else
    _assert_fail "ac-2 the rehearsal still reaches '$kept'" "the step is gone from the merge job"
  fi
done
# Publishing is not skipped with the tag: a rehearsal creates the release as a draft, which
# is the only way to prove the publishing half without publishing.
assert_contains "$(job_block publish)" 'dry-run: ${{ inputs.dry-run }}' \
  "ac-2 the publish is still called with the rehearsal switch, so it creates a draft"
assert_eq "$(grep -c 'needs: \[detect, merge\]' "$watch")" "1" \
  "ac-2 the publish still runs in the rehearsal: it is not short-circuited away"

# --------------------------------------------------------------------------- #
# ac-3: the recovery contract is wired through the graph
# --------------------------------------------------------------------------- #

# `resume` is an input, so a failed run can be told where to continue instead of being
# rediscovered - which is impossible once the pin already moved.
assert_contains "$(sed -n '/^    inputs:/,/^permissions:/p' "$watch")" "resume:" \
  "ac-3 the dispatch accepts a resume stage"
assert_contains "$(sed -n '/^      resume:/,/^      base:/p' "$watch")" "merge" \
  "ac-3 the resume input documents the merge stage"
assert_contains "$(sed -n '/^      resume:/,/^      base:/p' "$watch")" "publish" \
  "ac-3 the resume input documents the publish stage"
assert_contains "$(job_block detect)" 'CI_RESUME: ${{ inputs.resume }}' \
  "ac-3 detection is told which stage it is resuming"
assert_contains "$(job_block detect)" "resume-stage:" \
  "ac-3 the detected resume stage is published as a job output"
assert_contains "$(job_block detect)" "pin-in-base:" \
  "ac-3 the pin the base branch carries is published as a job output"
assert_contains "$(job_block detect)" "merged-sha:" \
  "ac-3 the merge commit is published as a job output"
assert_contains "$(job_block detect)" "tag-exists:" \
  "ac-3 the tag state is published as a job output"
# A discovery failure is fatal now (ac-1/ac-2), so the issue job is the only place the
# operator looks. The reason has to travel there as a value: the workflow cannot read the
# failed step's log, and a body saying "see the run log" is not a reason.
assert_contains "$(job_block detect)" "detect-error:" \
  "ac-1 the discovery failure reason is published as a job output"
assert_contains "$(job_block issue)" 'CI_DETECT_ERROR: ${{ needs.detect.outputs.detect-error }}' \
  "ac-1 the failure issue is told why discovery failed"
assert_contains "$(job_block issue)" 'auto_reason="${CI_DETECT_ERROR}"' \
  "ac-1 the detect failure's own reason becomes the issue's reason row"
# The issue body has to be chosen from the state, not assumed: after a merge the sentence
# "nothing was merged" is false, and it is the sentence an on-call acts on.
assert_contains "$(job_block issue)" 'CI_PIN_IN_BASE: ${{ needs.detect.outputs.pin-in-base }}' \
  "ac-3 the failure issue is told what the base branch pins"
assert_contains "$(job_block issue)" 'CI_MERGED_SHA: ${{ needs.detect.outputs.merged-sha }}' \
  "ac-3 the failure issue is told the merge commit"
assert_contains "$(job_block issue)" 'CI_TAG_EXISTS: ${{ needs.detect.outputs.tag-exists }}' \
  "ac-3 the failure issue is told whether the tag was pushed"
assert_contains "$(job_block issue)" "The merge already landed" \
  "ac-3 a post-merge failure says the merge landed instead of pretending it did not"

# The two record jobs are part of "a red run leaves one place to look": a keepalive commit
# that could not be pushed, or an audit row that could not be written, is a failure like any
# other, and the issue body's job table names it instead of blaming `detect`.
assert_contains "$(job_block issue)" "keepalive" \
  "ac-4 the failure issue is told what the keepalive job did"
assert_contains "$(job_block issue)" "audit" \
  "ac-6 the failure issue is told what the audit job did"

# The detect job reads tags and the merge commit, so it needs to see them: the remote URL is
# how it reads a tag this checkout did not fetch, and the PR read permission is how it reads
# the merge commit.
assert_contains "$(job_block detect)" "CI_REMOTE_URL" \
  "ac-3 the tag state is read from the remote, not from an unfetched local ref"
assert_contains "$(job_block detect)" "pull-requests: read" \
  "ac-3 the detect job may read the merge commit of the pull request"

# An issue may not advertise an artifact the run never uploads.
assert_eq "$(grep -c 'upload-artifact' "$watch")" "0" \
  "ac-3 the watch uploads no artifact of its own"
assert_eq "$(grep -c 'CI_LOG_ARTIFACT' "$watch")" "0" \
  "ac-3 the failure issue promises no artifact that does not exist"

if command -v actionlint >/dev/null 2>&1; then
  out=$(actionlint -no-color -shellcheck "" "$watch" 2>&1)
  assert_eq "$out" "" "ac-2 actionlint accepts the watch workflow"
else
  printf 'ok %d - %s\n' "$((_ASSERT_COUNT = _ASSERT_COUNT + 1))" \
    "ac-2 actionlint is not installed here (the verify stage installs it and gates on it)"
fi

finish
