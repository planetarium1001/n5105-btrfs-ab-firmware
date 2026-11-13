#!/usr/bin/env bash
# Module: ci
# The cross-version stage: where it runs, what it costs, and what it is not allowed to
# become.
#
#   ac-1  the stage runs on the tag line only, inside a 35 minute ceiling
#   ac-2  the old image and the new payload come from the same selectors as everything else
#   ac-5  a run with no previous release is reported as skipped, never as passed
#   ac-6  the stage is in the documents that describe the pipeline
#   ac-7  the PR chain is untouched: ci.yml does not call it
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

stage="$(cat .github/workflows/ci-upgrade-cross.yml)"
release="$(cat .github/workflows/release.yml)"
main="$(cat .github/workflows/ci.yml)"
script="$(cat scripts/ci/cross-upgrade.sh)"
readme="$(cat scripts/ci/README.md)"
pipeline="$(cat docs/ci-pipeline.md)"
pipeline_zh="$(cat docs/ci-pipeline.zh-CN.md)"

# --- ac-1: where and how long ----------------------------------------------
assert_contains "$stage" "workflow_call:" "ac-1 the stage is a reusable workflow"
assert_contains "$stage" "timeout-minutes: 35" "ac-1 the whole stage has a 35 minute ceiling"
assert_contains "$release" "uses: ./.github/workflows/ci-upgrade-cross.yml" "ac-1 the tag line calls it"

# --- ac-2: the two sides come from the selectors ---------------------------
assert_contains "$stage" "matrix-select.sh --version" "ac-2 the previous release comes from the selector"
assert_contains "$stage" "scripts/ci/resolve.sh" "ac-2 the old release's mirror layout is resolved, not guessed"
assert_contains "$stage" "name: image-install" "ac-2 it boots the image the S3 stage built"
assert_contains "$stage" "name: payload-upgrade" "ac-2 it installs the payload the assemble stage built"

# --- ac-5: no previous release --------------------------------------------
assert_contains "$stage" "cross-upgrade=skipped reason=no-previous-formal-release" \
  "ac-5 a missing previous release is skipped with its reason"
assert_contains "$stage" "has_previous" "ac-5 the decision is made from the selector's output"

# --- ac-6: documented ------------------------------------------------------
assert_contains "$readme" "cross-upgrade.sh" "ac-6 the stage script is in the stage table"
assert_contains "$pipeline" "cross-version" "ac-6 the English pipeline page names the stage"
assert_contains "$pipeline_zh" "跨版本" "ac-6 the Chinese pipeline page names the stage"

# --- ac-7: the PR chain is untouched ---------------------------------------
case "$main" in
  *ci-upgrade-cross*) assert_eq "referenced" "absent" "ac-7 ci.yml does not call the cross stage" ;;
  *) assert_eq "absent" "absent" "ac-7 ci.yml does not call the cross stage" ;;
esac

# --- the script is graded, not guessed -------------------------------------
assert_contains "$script" "cross-upgrade=ok" "ac-3 the script prints a verdict"
assert_contains "$script" "cross-upgrade=fail reason=" "ac-3 a failure names its reason"
assert_contains "$script" "abandon-not-recorded" "ac-4 the injected failure is graded"

finish
