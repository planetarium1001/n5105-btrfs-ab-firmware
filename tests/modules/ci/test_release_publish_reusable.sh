#!/usr/bin/env bash
# Module: ci
# ac-6: the publishing half of a release is one reusable workflow both release lines call.
#
# Why this file exists: the publish job used to live inside release.yml, which meant the
# upstream auto-release line (task 20261112-02) would have had to grow a second copy of
# "what publishing means" — image kind check, payload, SHA256SUMS, notes, summary — and the
# two copies would drift. release-publish.yml is that job, extracted; release.yml and
# upstream-watch.yml are two callers of it.
#
# The assertions below are structural on purpose: a reusable workflow's inputs are the
# contract with its callers, and a publish step that runs before the preflight is exactly
# the failure this task exists to prevent.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

publish=".github/workflows/release-publish.yml"
release=".github/workflows/release.yml"

assert_file_exists "$publish" "ac-6 the reusable publish workflow exists"
assert_file_exists "$release" "ac-6 the tagged release line still exists"

publish_text=$(cat "$publish")
release_text=$(cat "$release")

# --------------------------------------------------------------------------- #
# ac-6: the reusable workflow is callable and declares its contract
# --------------------------------------------------------------------------- #

assert_contains "$publish_text" "on:
  workflow_call:" "ac-6 release-publish.yml is a reusable workflow"

# input_decl <name> <file>: the whole `name:` line of one workflow_call input.
input_line() {
  awk -v want="$2" '
    /^    inputs:$/ { ininputs = 1; next }
    ininputs && /^    [a-z-]+:$/ { ininputs = 0 }
    ininputs && $1 == want ":" { print; got = 1; exit }
    END { exit(got ? 0 : 1) }
  ' "$1"
}

for input in tag tag-policy title platform_version upstream_version image-artifact payload-artifact extra-notes dry-run; do
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if input_line "$publish" "$input" >/dev/null; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-6 release-publish.yml declares the input $input"
  else
    _assert_fail "ac-6 release-publish.yml declares the input $input" "not found under workflow_call.inputs"
  fi
done

# The tag is the caller's decision, so it has to be required: a release published under an
# empty tag is a release nobody can find.
assert_contains "$(sed -n '/^      tag:$/,/^        type:/p' "$publish")" "required: true" \
  "ac-6 the tag input is required"

# dry-run defaults to false: a rehearsal is opt-in, publishing is the default.
assert_contains "$(sed -n '/^      dry-run:$/,/^permissions:/p' "$publish")" "default: false" \
  "ac-6 dry-run defaults to false"

# --------------------------------------------------------------------------- #
# ac-6: publishing keeps the least privilege it needs
# --------------------------------------------------------------------------- #

assert_contains "$publish_text" "permissions:
  contents: read" "ac-6 the reusable workflow asks for contents: read by default"
write_blocks=$(grep -c 'contents: write' "$publish")
assert_eq "$write_blocks" "1" "ac-6 exactly one step of the reusable workflow may write contents"

# --------------------------------------------------------------------------- #
# ac-6: the preflight runs before anything is created
# --------------------------------------------------------------------------- #

preflight_line=$(grep -n 'bash scripts/ci/release-preflight.sh' "$publish" | head -n 1 | cut -d: -f1)
create_line=$(grep -n 'gh release create' "$publish" | head -n 1 | cut -d: -f1)
_ASSERT_COUNT=$((_ASSERT_COUNT + 1))
if [ -n "$preflight_line" ] && [ -n "$create_line" ] && [ "$preflight_line" -lt "$create_line" ]; then
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" \
    "ac-6 the release preflight runs before the release is created (line $preflight_line < $create_line)"
else
  _assert_fail "ac-6 the release preflight runs before the release is created" \
    "preflight=[$preflight_line] create=[$create_line]"
fi

# The exit status of the preflight has to reach the step: `| tee` without pipefail would
# swallow it, and a refused release would then be published.
step_block() {
  awk -v want="$2" '
    /^      - / { if (found) exit; block = $0 "\n"; next }
    { block = block $0 "\n" }
    index($0, want) { found = 1 }
    END { if (found) printf "%s", block }
  ' "$1"
}
preflight_step=$(step_block "$publish" 'bash scripts/ci/release-preflight.sh')
assert_contains "$preflight_step" "set -euo pipefail" \
  "ac-6 the preflight step fails the job when the preflight fails"
assert_contains "$preflight_step" "tee -a" \
  "ac-6 the preflight verdict reaches the stage log"

# --------------------------------------------------------------------------- #
# ac-6: the image defence-in-depth check came along
# --------------------------------------------------------------------------- #

for needle in 'kind' 'S3 boot init' 'S1-RESULT' 'publish.img'; do
  assert_contains "$publish_text" "$needle" "ac-6 the reusable publish keeps the image check ($needle)"
done
assert_contains "$publish_text" 'image-install' "ac-6 the install image artifact keeps its name"
assert_contains "$publish_text" 'payload-upgrade' "ac-6 the payload artifact keeps its name"
assert_contains "$publish_text" 'gh release upload "${TAG}"' "ac-6 re-publishing an existing tag uploads again"
assert_contains "$publish_text" '--clobber' "ac-6 re-publishing overwrites instead of failing"

# --------------------------------------------------------------------------- #
# ac-1: a re-run over a draft publishes it, and a published release stays alone
# --------------------------------------------------------------------------- #

# Uploading the bytes again is not publishing. The v0.0.8 pre-review found the branch that
# only does `gh release upload --clobber`: a release left as a draft stays invisible while
# the run reports success, which is the one failure mode nobody notices in time.
publish_step=$(step_block "$publish" 'id: publish')
assert_contains "$publish_step" 'gh release edit "${TAG}" --draft=false' \
  "ac-1 re-running over a draft publishes the release"
assert_contains "$publish_step" '--json isDraft --jq .isDraft' \
  "ac-1 the draft state is read before it is changed"

# Idempotent in the other direction: a published release is never deleted and recreated, so
# a second automatic run cannot withdraw a release a machine may already have downloaded.
republish="$(sed -n '/elif gh release view/,/^          fi$/p' "$publish")"
assert_eq "$(printf '%s\n' "$republish" | grep -c 'gh release delete' || true)" "0" \
  "ac-1 re-running over a published release never deletes it"
assert_eq "$(printf '%s\n' "$republish" | grep -c 'gh release edit' || true)" "1" \
  "ac-1 the exists branch edits the release in exactly one place"

# --------------------------------------------------------------------------- #
# ac-3: the release notes carry the conclusion, not a fixed claim
# --------------------------------------------------------------------------- #

# A re-run publishes whatever the tag/CI actually proves; the notes must not assert a stage
# result the publish job never read.
assert_eq "$(grep -c 'S1 to S5 all passed' "$publish" || true)" "0" \
  "ac-3 the notes never claim the five stages passed"
assert_contains "$publish_step" 'Verified by CI run %s' \
  "ac-3 the notes still name the run that proved the release"
assert_contains "$publish_step" "The stage verdicts are in that" \
  "ac-3 the notes point at the run's report instead of restating its verdict"

# --------------------------------------------------------------------------- #
# ac-6: dry-run publishes nothing
# --------------------------------------------------------------------------- #

publish_step=$(step_block "$publish" 'id: publish')
assert_contains "$publish_step" 'if [ "${DRY_RUN}" = "true" ]' \
  "ac-6 the publish step branches on dry-run"
assert_contains "$publish_step" '--draft' \
  "ac-6 a dry run creates a draft, never a published release"

# --------------------------------------------------------------------------- #
# ac-6: release.yml is only the caller now
# --------------------------------------------------------------------------- #

assert_contains "$release_text" 'uses: ./.github/workflows/ci.yml' \
  "ac-6 the tagged line still builds through the ordinary pipeline"
assert_contains "$release_text" 'uses: ./.github/workflows/release-publish.yml' \
  "ac-6 the tagged line publishes through the reusable workflow"
assert_contains "$(sed -n '/publish:/,/^$/p' "$release" | grep -v '^\s*#')" 'tag-policy: v' \
  "ac-6 the tagged line asks for the v tag policy"
assert_contains "$release_text" 'tag: ${{ github.ref_name }}' \
  "ac-6 the tagged line publishes the tag it was triggered by"

assert_eq "$(grep -c 'gh release' "$release")" "0" \
  "ac-6 release.yml no longer carries publishing steps of its own"
assert_eq "$(grep -c 'runs-on:' "$release")" "0" \
  "ac-6 release.yml schedules no job of its own, so it needs no timeout"

# --------------------------------------------------------------------------- #
# ac-6 / ac-10 tail: the three floating @v4 pins in release.yml are gone
# --------------------------------------------------------------------------- #

for wf in "$release" "$publish"; do
  floating=$(grep -E '^\s*uses:' "$wf" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
    | grep -vE '^\./' | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}( # v[0-9].*)?$' || true)
  assert_eq "$floating" "" "ac-6 every third-party action in $wf is pinned to a 40-character sha"
  uncommented=$(grep -E '^\s*uses:' "$wf" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
    | grep -vE '^\./' | grep -vE ' # v[0-9]' || true)
  assert_eq "$uncommented" "" "ac-6 every pin in $wf names the release it pins"
done

# --------------------------------------------------------------------------- #
# ac-6: a reusable workflow owns no concurrency and declares a budget
# --------------------------------------------------------------------------- #

assert_eq "$(grep -c '^concurrency:' "$publish")" "0" \
  "ac-6 the reusable workflow leaves concurrency to its caller"
assert_eq "$(grep -c 'cancel-in-progress:' "$publish")" "0" \
  "ac-6 the reusable workflow never cancels its caller"
assert_eq "$(grep -c 'timeout-minutes:' "$publish" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes" \
  "ac-6 the reusable workflow declares a timeout budget"

# --------------------------------------------------------------------------- #
# ac-6: the files still parse as workflows
# --------------------------------------------------------------------------- #

if command -v actionlint >/dev/null 2>&1; then
  for wf in "$publish" "$release"; do
    out=$(actionlint -no-color -shellcheck "" "$wf" 2>&1)
    assert_eq "$out" "" "ac-6 actionlint accepts $wf"
  done
else
  printf 'ok %d - %s\n' "$((_ASSERT_COUNT = _ASSERT_COUNT + 1))" \
    "ac-6 actionlint is not installed here (the verify stage installs it and gates on it)"
fi

finish
