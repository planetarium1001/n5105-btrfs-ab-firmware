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
#   ac-1  the run grades the guest serial qemu-smoke leaves in CI_LOG_DIR, never its own
#         progress on stdout, and cross_prepare gives the candidate a wan to pass the
#         health check on a single-NIC boot
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

script_path="scripts/ci/cross-upgrade.sh"
stage="$(cat .github/workflows/ci-upgrade-cross.yml)"
release="$(cat .github/workflows/release.yml)"
main="$(cat .github/workflows/ci.yml)"
fetch="$(cat .github/workflows/ci-fetch.yml)"
s3wf="$(cat .github/workflows/ci-s3.yml)"
setup_action="$(cat .github/actions/setup-ci/action.yml)"
script="$(cat "$script_path")"
readme="$(cat scripts/ci/README.md)"
pipeline="$(cat docs/ci.md)"
pipeline_zh="$(cat docs/ci.zh-CN.md)"

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

# --- ac-2: a crashed grading must not be silent ----------------------------
# The verdict is captured with $( ), so the script's own output has to be tee-ed to the
# run log as well: run 43575531830 failed with a bare "exit code 1" and the real reason
# (a missing CI_KERNEL for qemu-smoke) was only in an artifact.
assert_contains "$stage" 'tee -a "${log}"' \
  "ac-2 the grading output reaches the run log, not only the captured verdict"
assert_contains "$stage" 'produced no verdict line' \
  "ac-2 a script that dies before printing a verdict says so"

# --- ac-1: the graded serial is the guest's, not qemu-smoke's stdout -------
# qemu-smoke's stdout is stage progress; the guest console is the copy it leaves in
# ${CI_LOG_DIR}/serial-<case>.log. The stage graded the stdout, extract_blocks never saw
# a CROSS-STATUS-* line, and every graded run ended reason=status-after-missing (tag run
# 43622253559). Where the serial comes from and that the stdout no longer reaches the
# graded file are both asserted here; the run half itself is exercised in test_cross_upgrade.
run_fn="$(sed -n '/^run_stage()/,/^}/p' "$script_path")"
assert_contains "$run_fn" 'CI_LOG_DIR' \
  "ac-1 run_stage looks for the guest serial where qemu-smoke leaves it"
assert_contains "$run_fn" '_log_dir="${CI_LOG_DIR:-' \
  "ac-1 the serial directory falls back the way qemu-smoke does, so a local run reads the same file"
assert_eq "$(grep -cF 'serial-cross-boot1.log' "$script_path")" "1" \
  "ac-1 the first boot's serial copy is named"
assert_eq "$(grep -cF 'serial-cross-boot2.log' "$script_path")" "1" \
  "ac-1 the second boot's serial copy is named"
assert_eq "$(grep -cF 'cat "${_serial}" >>"${_out}/serial.log"' "$script_path")" "3" \
  "ac-1 all three boots are appended to the one log the grader reads"
assert_eq "$(grep -cF ': >"${_out}/serial.log"' "$script_path")" "1" \
  "ac-1 the graded serial log starts empty once, then only grows by appending"
assert_eq "$(grep -cF 'no guest serial at' "$script_path")" "3" \
  "ac-1 an absent serial copy is spelled out instead of graded as an empty boot"
assert_contains "$run_fn" 'boot1.stdout.log' \
  "ac-1 the wrapper's stdout is kept as a diagnostic file"
assert_contains "$run_fn" 'boot2.stdout.log' \
  "ac-1 the second wrapper's stdout is kept as a diagnostic file"
assert_eq "$(grep -cF 'qemu-smoke.sh" >"${_out}/serial.log"' "$script_path")" "0" \
  "ac-1 qemu-smoke's stdout is not redirected into the graded serial log"
assert_eq "$(grep -cF 'qemu-smoke.sh" >>"${_out}/serial.log"' "$script_path")" "0" \
  "ac-1 nor appended to it by the second boot"
extract_line=$(grep -nF 'extract_blocks "${_out}/serial.log" "${_out}"' "$script_path" | cut -d: -f1)
last_serial_line=$(grep -nF 'serial-cross-boot2.log' "$script_path" | head -n 1 | cut -d: -f1)
assert_eq "$([ -n "${extract_line}" ] && [ -n "${last_serial_line}" ] && [ "${last_serial_line}" -lt "${extract_line}" ] && echo after)" \
  "after" "ac-1 the serial is appended before the blocks are extracted, not after"

# --- ac-1: the candidate has a wan to pass the health check ----------------
# The boot has one virtio NIC, so net-seed degrades to lan-only and ab-commit's
# wan-present probe fails; boot 2 of tag run 43622253559 abandoned the candidate with
# reason=healthcheck-failed. cross_prepare has to write the network fixture itself, into
# the same writable layer as the boot hook.
# The hook itself now lives in cross_fixture_rc_local (so a test can print it without a loop
# device); cross_prepare is what installs it. Read both, or these assertions would pass on
# a script whose hook is never written.
prepare_fn="$(sed -n '/^cross_prepare()/,/^}/p' "$script_path")"
# The hook's own text is asserted on what actually lands on the machine, not on the source:
# the fixture is rendered by the script's `fixture` subcommand, which is the same text
# cross_prepare pipes into rc.local. Reading the rendered bytes also survives the escaping a
# parameterised heredoc needs, without asking the assertion to know about it.
hook_fn="$(bash "$script_path" fixture 2>/dev/null)"
assert_contains "$prepare_fn" 'etc/config/network' \
  "ac-1 cross_prepare writes the network fixture into the writable layer"
assert_contains "$prepare_fn" 'sudo tee "${_upper}/etc/config/network"' \
  "ac-1 the fixture lands where the guest reads it"
assert_contains "$prepare_fn" "config interface 'loopback'" \
  "ac-1 the fixture carries the loopback interface"
assert_contains "$prepare_fn" "config interface 'wan'" \
  "ac-1 the fixture names a wan section, which is what the probe reads"
assert_contains "$prepare_fn" "option device 'eth0'" \
  "ac-1 that wan is the single NIC the QEMU boot provides"
assert_contains "$prepare_fn" "option proto 'dhcp'" \
  "ac-1 the wan is a dhcp client, like the ab stage's fixture"
assert_contains "$prepare_fn" 'etc/rc.local' \
  "ac-1 the boot hook is still written beside it"
assert_contains "$prepare_fn" 'payload.tar' \
  "ac-1 and so is the payload it installs"
assert_eq "$(grep -c "^RCLOCAL'$" "$script_path")" "0" \
  "ac-1 the rc.local heredoc terminator is not left quoted, so the file holds one hook"

# --- ac-1: the committed status is printed from a settled state, not before the commit ---
# rc.local is S95 and ab-commit is S99, so status printed on the candidate boot describes a
# state the commit has not produced. v0.0.10-rc1/rc2 committed the candidate and still failed
# with reason=packages-not-aligned-after-commit because the third block was empty or
# pre-commit. The stage therefore takes a third boot of the committed slot, where the state
# is already settled at S95; the hook only prints when pending=none and slot==committed.
assert_contains "$hook_fn" 'CROSS-STATUS-COMMITTED' \
  "ac-1 the fixture announces the committed status"
assert_contains "$hook_fn" ' pending=none ' \
  "ac-1 it only prints when the state has settled (pending=none)"
assert_contains "$hook_fn" '[ "${slot}" = "${committed}" ]' \
  "ac-1 and when the running slot is the committed one"
assert_contains "$hook_fn" '/boot/cross-fixture-installed' \
  "ac-1 the installed marker lives on the shared ESP, so a snapshot cannot replay the install"
assert_contains "$hook_fn" 'if [ -f /payload.tar ] && [ ! -f /boot/cross-fixture-installed ]' \
  "ac-1 the candidate boot (snapshot carries payload + rc.local) does not install a second time"
# The hook moved into cross_fixture_rc_local, so this negative check has to read the rendered
# fixture: against $prepare_fn it would match nothing and pass forever (a dead assertion).
case "$hook_fn" in
  *'rm -f /etc/rc.local'*) assert_eq "removed-before-install" "kept-until-boot-3" \
    "ac-1 rc.local must survive into the candidate snapshot, or boot 3 never prints" ;;
  *) assert_eq "kept-until-boot-3" "kept-until-boot-3" "ac-1 rc.local is not removed before the snapshot" ;;
esac

# --- ac-1: boot 2 stops on the commit, boot 3 supplies the committed status ---
assert_contains "$script" 'CI_QEMU_CASE="cross-boot3"' \
  "ac-1 a third boot of the committed slot is part of the run"
assert_contains "$script" 'serial-cross-boot3.log' \
  "ac-1 and its guest serial reaches the grader"
assert_contains "$script" "ab-commit: committed slot=" \
  "ac-1 boot 2 stops on the commit line, so boot 3 starts from a committed state"

# --- ac-5: the second gate - same base, and it cannot be skipped ------------
# The cross gate answers "release N installs over N-1". It never reads a base or a kernel, so
# a release that moved the upstream base would pass it, and the update prompt's "patch ranges
# are covered" sentence would keep claiming something CI never proved. The same-base gate is
# the second half of ac-5, and it lives in a new reusable workflow so ci-upgrade-cross.yml -
# the tag line's one long-standing gate - is not touched.
gates_path=".github/workflows/ci-upgrade-gates.yml"
assert_file_exists "$root/$gates_path" "ac-5 the new gates workflow exists"
assert_eq "$(grep -c '' "$root/$gates_path" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes" \
  "ac-5 and it carries content"

# It is reusable, with the mode the caller picks and everything else optional: a caller that
# only knows which gate it wants must not have to pass the versions, because release.yml
# cannot (ci.yml exposes no workflow-level outputs) and a caller-supplied version that the
# tree disagrees with is how two answers to one question appear.
gates="$(cat "$gates_path")"
assert_contains "$gates" "workflow_call:" "ac-5 the gates are a reusable workflow"
for input in "mode:" "upstream_version:" "platform_version:" "previous-tag:"; do
  assert_contains "$gates" "${input}" "ac-5 the caller can pass ${input%,:}"
done
assert_contains "$gates" "required: true" "ac-5 the mode is the only required input"

# cross mode is the existing stage, reused rather than reimplemented: the risk of this unit
# is the new same-base gate, and a second copy of the cross stage would be a second thing to
# keep in step with the tag line.
assert_contains "$gates" "uses: ./.github/workflows/ci-upgrade-cross.yml" \
  "ac-5 the cross mode reuses the existing stage unchanged"
assert_eq "$(grep -cE '^ +uses: \./\.github/workflows/ci-upgrade-cross\.yml$' "$root/$gates_path")" "1" \
  "ac-5 and calls it exactly once"
assert_eq "$(grep -c 'ci-assemble.yml' "$root/$gates_path")" "0" \
  "ac-5 the gates stage never builds a second payload"
assert_contains "$gates" "name: payload-upgrade" \
  "ac-5 the same-base gate installs the payload this run already built"

# The same-base gate boots an image, so its job needs the runner QEMU and loop devices come
# with - the same preparation the cross stage gets, and the same budget class. It is cheaper
# than cross because the old image is downloaded, not rebuilt: 25 minutes is the QEMU half.
sb_job="$(awk '/^  same-base:$/ {found = 1} found {print}' "$root/$gates_path")"
assert_contains "${sb_job}" "timeout-minutes: 25" \
  "ac-5 the same-base job has a 25 minute ceiling"
assert_contains "${sb_job}" 'uses: ./.github/actions/setup-ci' \
  "ac-5 the same-base job prepares its runner"
assert_contains "${sb_job}" 'qemu-system-x86' \
  "ac-5 or the boot is skipped rather than graded"
assert_contains "${sb_job}" "scripts/ci/release-same-base.sh" \
  "ac-5 the previous release is selected by the stage's own script"
assert_contains "${sb_job}" "args=(select --version" \
  "ac-5 through the select subcommand, with the version it read from the tree"
assert_contains "${sb_job}" "scripts/ci/release-same-base.sh fetch" \
  "ac-5 and its image is fetched and verified by the same script"
assert_contains "${sb_job}" "cross-upgrade.sh run" \
  "ac-5 the install is the cross stage's own run half"
assert_contains "${sb_job}" "--expect-same-base" \
  "ac-5 and it runs with the same-base criteria switched on"

# ac-5: the invariant. A gate that cannot judge must fail. The three ways a stage can end up
# doing nothing - a skip file, an unreadable tool chain, a missing previous release - all end
# in a failure here, never in a green step, because release.yml publishes only when this is.
assert_contains "${sb_job}" 'if [ -f "${out}/skip" ]' \
  "ac-5 the same-base step inspects the stage's skip file"
assert_contains "${sb_job}" "a skipped gate is not a passed gate" \
  "ac-5 and says why a skip is refused"
assert_contains "${sb_job}" "grep -q '^same-base=ok'" \
  "ac-5 the step requires a graded same-base verdict, not only a cross one"
assert_contains "$(cat "$root/scripts/ci/release-same-base.sh")" \
  "same-base=fail reason=no-previous-platform-release" \
  "ac-5 no previous release is a failure in the selector"
assert_contains "$(cat "$root/scripts/ci/release-same-base.sh")" \
  "same-base=fail reason=previous-release-has-no-index" \
  "ac-5 and so is a previous release the criteria cannot be read from"

# The release line: publish waits for both gates, and the same-base gate is a job of its own
# rather than a second mode squeezed into the cross job.
assert_contains "$gates" "mode: same-base" "ac-5 same-base is one of the two modes"
assert_contains "$release" "uses: ./.github/workflows/ci-upgrade-gates.yml" \
  "ac-5 the tag line calls the gates workflow"
assert_contains "$release" "mode: same-base" \
  "ac-5 the tag line runs the same-base gate"

# job_needs over release.yml: written as a flow list, compared as words so the assertion does
# not depend on how the list is spelled.
release_needs() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:$/ { job = $1; sub(":$", "", job); injob = (job == want); next }
    injob && /^    needs:/ {
      sub(/^[[:space:]]*needs:[[:space:]]*/, "")
      gsub(/[][,]/, " "); gsub(/[[:space:]]+/, " ")
      sub(/^ /, ""); sub(/ $/, ""); print; exit
    }
  ' "$1"
}
publish_needs="$(release_needs .github/workflows/release.yml publish)"
assert_contains "${publish_needs}" "same-base" \
  "ac-5 publish waits for the same-base gate"
assert_contains "${publish_needs}" "cross" \
  "ac-5 and still waits for the cross gate"
assert_contains "${publish_needs}" "build" \
  "ac-5 and for the build, without which there is nothing to publish"

# The release line's cross job is untouched: it is the tag line's original proof, and a
# rename there is how a gate silently stops being waited for.
assert_contains "$release" 'uses: ./.github/workflows/ci-upgrade-cross.yml' \
  "ac-5 the tag line still calls the cross stage directly"
assert_eq "$(grep -c '^  cross:$' .github/workflows/release.yml)" "1" \
  "ac-5 the cross job is still a job of its own"

# The gates file follows the same conventions as every other reusable workflow: no
# concurrency (a reusable workflow inherits the caller's) and a pinned third-party action if
# it uses one at all.
assert_eq "$(grep -c '^concurrency:' "$root/$gates_path")" "0" \
  "ac-5 the gates workflow leaves concurrency to its caller"
floating_gates=$(grep -E '^\s*uses:' "$root/$gates_path" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
  | grep -vE '^\./' | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}( # v[0-9].*)?$' || true)
assert_eq "${floating_gates}" "" "ac-5 every third-party action in the gates file is pinned"

finish
