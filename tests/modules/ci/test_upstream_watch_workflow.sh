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
assert_contains "$text" 'cron: "0 20 * * *"' \
  "ac-2 the watch runs at 20:00 UTC (04:00 in Beijing, outside the working day)"
assert_contains "$text" "  workflow_dispatch:" "ac-2 the watch can be dispatched by hand"
assert_eq "$(grep -c '^  push:' "$watch")" "0" \
  "ac-2 the watch is not triggered by a push: a push by GITHUB_TOKEN would not trigger it anyway"

# Concurrency belongs to the entry point and never cancels a manual run.
assert_contains "$text" 'group: ci-${{ github.workflow }}-${{ github.event_name == '"'"'workflow_dispatch'"'"' && '"'"'manual'"'"' || '"'"'auto'"'"' }}-${{ github.ref }}' \
  "ac-2 the watch scopes its concurrency group by lane"
assert_contains "$text" 'cancel-in-progress: ${{ github.event_name != '"'"'workflow_dispatch'"'"' }}' \
  "ac-2 the watch never cancels a manual run"
assert_eq "$(grep -c '^concurrency:' "$watch")" "1" \
  "ac-2 the watch declares exactly one concurrency block"

# --------------------------------------------------------------------------- #
# ac-2: nothing happens when nothing is new
# --------------------------------------------------------------------------- #

assert_contains "$(job_block bump)" "needs.detect.outputs.changed == 'true'" \
  "ac-2 the branch is only opened when a release was detected"
assert_contains "$(job_block heartbeat)" "needs.detect.outputs.changed != 'true'" \
  "ac-2 a heartbeat only happens on a run that found nothing"
assert_contains "$(job_block heartbeat)" "would-create" \
  "ac-2 the heartbeat tag is only created when it is due"

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
assert_eq "$(grep -cE 'push.*refs/heads/(main|master)"' "$watch")" "0" \
  "ac-2 no job pushes straight to main"
assert_contains "$(job_block bump)" 'main|master) echo "a dry run may not open a PR against' \
  "ac-2 a rehearsal may not open a pull request against main"

# --------------------------------------------------------------------------- #
# ac-2 / ac-3: the whole chain is one run graph
# --------------------------------------------------------------------------- #

# The discovery, the build, the merge, the tag and the publish are jobs of this workflow,
# linked by `needs`. Nothing waits for a push or a tag to start the next step.
for job in detect bump build locks merge publish; do
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

if command -v actionlint >/dev/null 2>&1; then
  out=$(actionlint -no-color -shellcheck "" "$watch" 2>&1)
  assert_eq "$out" "" "ac-2 actionlint accepts the watch workflow"
else
  printf 'ok %d - %s\n' "$((_ASSERT_COUNT = _ASSERT_COUNT + 1))" \
    "ac-2 actionlint is not installed here (the verify stage installs it and gates on it)"
fi

finish
