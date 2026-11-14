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
fetch="$(cat .github/workflows/ci-fetch.yml)"
s3wf="$(cat .github/workflows/ci-s3.yml)"
setup_action="$(cat .github/actions/setup-ci/action.yml)"
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

# --- ac-2: the payload is built once, not twice -----------------------------
# The stage used to call ci-assemble.yml again for the same release. Two artifacts named
# payload-upgrade in one run made the download above ambiguous (run 43564031421 shows both,
# and both logs-assemble), and the second build spent ten minutes of the stage's budget
# rebuilding what the run had already built.
assert_eq "$(grep -c 'ci-assemble.yml' .github/workflows/ci-upgrade-cross.yml)" "0" \
  "ac-2 the cross stage does not assemble the payload a second time"
assert_contains "$stage" "needs: [select-previous, old-image]" \
  "ac-2 the grading waits for the previous image and for nothing else"
assert_contains "$stage" "uses: ./.github/workflows/ci-s3.yml" \
  "ac-2 the previous image is still built"
assert_contains "$script" "cross-upgrade=ok" "ac-2 the grading still runs"

# One run, one artifact name: upload-artifact v4 refuses a second upload of a name it already
# has, so the facts are published once - after the grading step that writes them, or the
# artifact would be empty.
assert_eq "$(grep -c 'name: evidence-cross' .github/workflows/ci-upgrade-cross.yml)" "1" \
  "ac-2 the cross facts are uploaded once, under one name"
grade_line=$(grep -n '      id: grade' .github/workflows/ci-upgrade-cross.yml | cut -d: -f1)
facts_line=$(grep -n 'name: evidence-cross' .github/workflows/ci-upgrade-cross.yml | cut -d: -f1)
assert_eq "$([ -n "${grade_line}" ] && [ -n "${facts_line}" ] && [ "${facts_line}" -gt "${grade_line}" ] && echo after)" \
  "after" "ac-2 the facts are collected after the run that writes them"

# --- ac-2: the old image is built from the old release's own files ----------
# The old image used to download this run's `upstream-files`, an artifact the fetch stage had
# already filled with the new release: the boot carried kernel 6.12.103 and the modules were
# packaged for 6.12.94, so the boot hook found no module directory for its `uname -r`
# (run 43564031421, job "build the previous image"). The cross stage now fetches the previous
# release's files itself, under a name of its own.
assert_contains "$stage" "uses: ./.github/workflows/ci-fetch.yml" \
  "ac-2 the cross stage fetches the previous release's own upstream files"
assert_contains "$stage" "needs: [resolve-new, select-previous, resolve-old]" \
  "ac-2 that fetch runs after the previous release is resolved, not before"
assert_contains "$fetch" 'name: upstream-files${{ inputs.artifact_suffix }}' \
  "ac-2 the fetch stage names its artifact from the suffix it is given"

# The tag line runs this release's own stages in the same run, so the old build and this
# release's build must not meet in one artifact list. Both calls take the suffix, and both
# the file it downloads and the image it publishes derive their name from that one input.
assert_eq "$(grep -c 'artifact_suffix: "-old"' .github/workflows/ci-upgrade-cross.yml)" "2" \
  "ac-2 the old fetch and the old build both take the -old suffix"
assert_contains "$stage" "name: image-install-old" \
  "ac-2 the cross stage boots the old build's image, not this release's"
assert_contains "$s3wf" 'artifact: upstream-files${{ inputs.artifact_suffix }}' \
  "ac-2 the old build downloads the files fetched under its own suffix"
assert_eq "$(grep -cE '^ +fetch_artifact: ' .github/workflows/ci-s3.yml)" "0" \
  "ac-2 the download name is derived from the suffix, never spelled twice"

# The uploads the old build would otherwise collide with this release's own S3 artifacts.
assert_contains "$s3wf" 'name: image-install${{ inputs.artifact_suffix }}' \
  "ac-2 the install image carries the suffix"
assert_contains "$s3wf" 'name: image-install-wan-ssh${{ inputs.artifact_suffix }}' \
  "ac-2 the convenience image carries the suffix"
assert_contains "$s3wf" 'name: evidence-s3${{ inputs.artifact_suffix }}' \
  "ac-2 the old build's evidence cannot overwrite this release's"
assert_contains "$s3wf" 'suffix: ${{ inputs.artifact_suffix }}' \
  "ac-2 the old build's logs artifact cannot overwrite this release's"

# Nothing else changes behaviour: the new inputs are optional, and their defaults leave the
# new-release path and every other caller exactly as they were.
s3_input="$(grep -E '^ +artifact_suffix: ' .github/workflows/ci-s3.yml)"
assert_contains "$s3_input" 'required: false' \
  "ac-2 ci-s3 accepts the suffix as an optional input"
assert_contains "$s3_input" 'default: ""' \
  "ac-2 an unconfigured ci-s3 call keeps today's artifact names"
fetch_input="$(grep -E '^ +artifact_suffix: ' .github/workflows/ci-fetch.yml)"
assert_contains "$fetch_input" 'default: ""' \
  "ac-2 an unconfigured ci-fetch call keeps today's artifact names"
setup_clause="$(awk '/^  artifact:$/ {found = 1} found {print} found && /^    default:/ {exit}' \
  .github/actions/setup-ci/action.yml)"
assert_contains "$setup_clause" 'default: "upstream-files"' \
  "ac-2 setup-ci still defaults to upstream-files"
assert_contains "$setup_action" 'name: ${{ inputs.artifact }}' \
  "ac-2 setup-ci downloads the artifact it was told about"

# --- ac-2: the grading job needs QEMU on its runner -------------------------
# The stage boots the old image under QEMU and mounts its partition, so a job that only checks
# out and downloads runs cross-upgrade.sh with no qemu-system-x86_64. The script then prints
# `skipped reason=qemu-not-available` and the step fails on the skip: a missing tool turned a
# real verification into a skip, and a skip is not a passed proof (run 43568028301).
cross_job="$(awk '/^  cross:$/ {found = 1} found {print}' .github/workflows/ci-upgrade-cross.yml)"
assert_contains "${cross_job}" 'uses: ./.github/actions/setup-ci' \
  "ac-2 the grading job prepares its runner instead of running on a bare image"
assert_contains "${cross_job}" 'qemu-system-x86' \
  "ac-2 that preparation installs QEMU, or the boot is skipped rather than graded"
assert_contains "$script" 'command -v qemu-system-x86_64' \
  "ac-2 the script refuses to boot without QEMU, so the job has to provide it"
assert_contains "${cross_job}" '${{ runner.temp }}/ci/logs' \
  "ac-2 the verdict's own log travels with the facts, not only the diagnostics summary"
setup_line=$(awk '/^  cross:$/ {job = 1} job && /uses: .\/\.github\/actions\/setup-ci/ {print NR; exit}' \
  .github/workflows/ci-upgrade-cross.yml)
download_line=$(awk '/^  cross:$/ {job = 1} job && /uses: actions\/download-artifact@/ {print NR; exit}' \
  .github/workflows/ci-upgrade-cross.yml)
assert_eq "$([ -n "${setup_line}" ] && [ -n "${download_line}" ] && [ "${setup_line}" -lt "${download_line}" ] && echo before)" \
  "before" "ac-2 the runner is prepared before the artifacts are downloaded"

# --- ac-5: no previous release --------------------------------------------
assert_contains "$stage" "cross-upgrade=skipped reason=no-previous-formal-release" \
  "ac-5 a missing previous release is skipped with its reason"
assert_contains "$stage" "has_previous" "ac-5 the decision is made from the selector's output"

# --- ac-5: the selector's answer has to reach the decision -----------------
# The selector emits its keys through ci_emit_output, which writes $GITHUB_OUTPUT in
# Actions and CI_OUTPUT_ENV only when that is set. This step read a file nothing wrote, so
# candidates/gaps came back empty, `previous` became none, and every downstream job was
# skipped - the stage reported success while never running. Run 43561858131 is the one
# that showed it: only the first two cross jobs ran, the rest were skipped.
assert_contains "$stage" 'export CI_OUTPUT_ENV=' \
  "ac-5 the selector is given a file to write, not only the step's GITHUB_OUTPUT"
assert_contains "$stage" 'env_file="${CI_OUTPUT_ENV}"' \
  "ac-5 the file it reads is the file it exported"
case "$stage" in
  *'env_file="${RUNNER_TEMP}/ci/matrix-select/matrix-select.env"'*)
    assert_eq "hardcoded-file-nobody-writes" "exported-file" \
      "ac-5 the step does not read an env file it never asked for" ;;
  *) assert_eq "exported-file" "exported-file" "ac-5 the step does not read an env file it never asked for" ;;
esac

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
