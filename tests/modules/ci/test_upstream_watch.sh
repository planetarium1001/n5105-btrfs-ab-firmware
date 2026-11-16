#!/usr/bin/env bash
# Module: ci
# Guards scripts/ci/upstream-watch.sh: the version discovery the daily auto-release run
# starts from, the single write path to the pin, and the two bodies it posts.
#
# The property under test is "only a formal release is a release". The mirror lists
# `25.13.0-rc1`, `25.13.0-beta2` and `SNAPSHOT` next to the real directories, and a
# detector that took the newest name would build an image nobody can reproduce. A 24.x
# release is not a candidate either: the initramfs-tools lock and the kmods layout only
# exist from 25 on.
#
# Everything here runs offline: `CI_UPSTREAM_INDEX` points at a fixture instead of
# `curl`ing the mirror, which is also how the workflow can be rehearsed without network.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/upstream-watch.sh"
FIXTURES="$root/tests/modules/ci/fixtures/upstream-watch"

# The pin file is the tracked one: the write path has to keep the file's comment block,
# so the fixture has to be the real thing rather than a two-line stand-in.
pin_readonly="$tmp/pin-detect.conf"
pin_writable="$tmp/pin-write.conf"
cp "$root/.github/upstream-pin.conf" "$pin_readonly"
cp "$root/.github/upstream-pin.conf" "$pin_writable"
# Kept before any run, so "detect did not touch the pin" is a real comparison and not a
# copy of whatever the run left behind.
cp "$root/.github/upstream-pin.conf" "$tmp/pin-detect.before"

# watch_run <pin-file> <output-env-file> [VAR=value ...] -- <arguments...>
# Runs the script with a scratch CI_TMP_ROOT and the caller's extra environment; the
# combined output lands in $watch_log and the exit status in $watch_status.
watch_run() {
  local pin_file="$1" out_env="$2"
  shift 2
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  watch_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out_env" \
    CI_TMP_ROOT="$tmp/ci" CI_UPSTREAM_PIN_FILE="$pin_file" "${envs[@]+"${envs[@]}"}" \
    bash "$SCRIPT" "$@" 2>&1)"
  watch_status=$?
}

# output_of <output-env-file> <key>: one emitted value, empty when absent.
output_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# --------------------------------------------------------------------------- #
# ac-1: discovery accepts formal releases only
# --------------------------------------------------------------------------- #

watch_run "$pin_readonly" "$tmp/o-detect.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index.html" -- detect
assert_eq "$watch_status" "0" "ac-1 detect exits 0 when the index has a newer formal release"
out="$tmp/o-detect.env"
assert_eq "$(output_of "$out" changed)" "true" "ac-1 a newer formal release reads as changed=true"
assert_eq "$(output_of "$out" version)" "25.13.0" "ac-1 the version to build is the newest formal release"
assert_eq "$(output_of "$out" latest_formal)" "25.13.0" "ac-1 latest_formal is the newest formal release"
assert_eq "$(output_of "$out" current_pin)" "25.12.2" "ac-1 current_pin is the tracked pin"
assert_eq "$(output_of "$out" formal_versions)" "25.13.0 25.12.2 25.12.1 25.12.0 25.11.3" \
  "ac-1 formal_versions lists the formal releases newest first"

# The pin file is an input of `detect`; a discovery run that rewrites it would move the
# pin before the build has proven anything.
assert_command_ok "ac-1 detect leaves the pin file untouched" \
  cmp -s "$pin_readonly" "$tmp/pin-detect.before"

assert_eq "$(output_of "$out" formal_versions | grep -c 'rc\|beta' || true)" "0" \
  "ac-1 an rc or beta directory never becomes a candidate"
assert_eq "$(output_of "$out" formal_versions | grep -c 'SNAPSHOT' || true)" "0" \
  "ac-1 SNAPSHOT never becomes a candidate"
assert_contains "$watch_log" "ignored non-formal upstream entry 25.13.0-rc1" \
  "ac-1 the run log names the rc it ignored"
assert_contains "$watch_log" "ignored non-formal upstream entry 25.13.0-beta2" \
  "ac-1 the run log names the beta it ignored"

assert_eq "$(output_of "$out" formal_versions | grep -c '24\.10\.0\|22\.03\.7' || true)" "0" \
  "ac-1 upstream releases below major 25 are excluded (24.10.0, 22.03.7)"
assert_contains "$watch_log" "excluded upstream release 24.10.0" \
  "ac-1 the run log names the 24.x release it excluded"
assert_contains "$watch_log" "excluded upstream release 22.03.7" \
  "ac-1 the run log names the 22.03.7 release it excluded"

# A pin that is already the newest formal release is not an update: the workflow must be
# able to finish successfully without building anything.
watch_run "$pin_readonly" "$tmp/o-atpin.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-at-pin.html" -- detect
assert_eq "$watch_status" "0" "ac-1 detect exits 0 when the pin is current"
assert_eq "$(output_of "$tmp/o-atpin.env" changed)" "false" \
  "ac-1 pin 25.12.2 against an index whose newest formal release is 25.12.2 is changed=false"
assert_eq "$(output_of "$tmp/o-atpin.env" version)" "25.12.2" \
  "ac-1 an unchanged pin still reports the version it names"

# An index that parses to no formal release at all is an anomaly, not "no update". The
# silent green this used to produce is exactly what the audit found: detect skipped every
# later job, so the run finished green and the `issue` job (which only fires on a failed
# job) never ran. A warn cannot be seen outside the log, so this has to fail.
watch_run "$pin_readonly" "$tmp/o-empty.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-empty.html" -- detect
# Read defensively: a run that dies before publishing leaves no output file at all, and
# "no changed=false was written" is the assertion, not "the file is readable".
empty_changed="$([ -f "$tmp/o-empty.env" ] && sed -n 's/^changed=//p' "$tmp/o-empty.env")"
assert_eq "$watch_status" "1" "ac-1 an index without formal releases fails instead of exiting green"
assert_contains "$watch_log" "ERROR" "ac-1 an empty index is reported as an error"
assert_contains "$watch_log" "no formal release" "ac-1 the error names what the index was missing"
assert_contains "$watch_log" 'not "no update"' \
  "ac-1 the error says an empty index is not the same thing as no update"
assert_eq "$empty_changed" "" \
  "ac-1 an empty index publishes no changed output at all, in particular not changed=false"
assert_eq "$(output_of "$tmp/o-empty.env" version)" "25.12.2" \
  "ac-1 the failing run still names the pin, so the failure issue says which release it is about"

watch_run "$pin_readonly" "$tmp/o-missing.env" \
  "CI_UPSTREAM_INDEX=$tmp/no-such-index.html" -- detect
assert_eq "$watch_status" "1" "ac-1 a missing local index fails instead of guessing"

# --------------------------------------------------------------------------- #
# ac-1: the pin moves through ci_write_upstream_pin only
# --------------------------------------------------------------------------- #

comments_before="$(grep -c '^#' "$pin_writable")"

for rejected in latest 24.10.0 25.13; do
  watch_run "$pin_writable" "$tmp/o-reject.env" -- pin "$rejected"
  assert_eq "$watch_status" "1" "ac-1 pin refuses '${rejected}'"
  assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_writable")" "25.12.2" \
    "ac-1 a refused pin '${rejected}' leaves the pin file alone"
done

watch_run "$pin_writable" "$tmp/o-pin.env" -- pin 25.13.0
assert_eq "$watch_status" "0" "ac-1 pin accepts a supported formal release"
assert_eq "$(output_of "$tmp/o-pin.env" previous_pin)" "25.12.2" "ac-1 pin reports the previous pin"
assert_eq "$(output_of "$tmp/o-pin.env" pinned_version)" "25.13.0" "ac-1 pin reports the version it wrote"
assert_eq "$(output_of "$tmp/o-pin.env" pin_file)" "$pin_writable" "ac-1 pin reports the file it wrote"
assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_writable")" "25.13.0" \
  "ac-1 the pin file carries the new version"
assert_eq "$(grep -c '^UPSTREAM_VERSION=' "$pin_writable")" "1" \
  "ac-1 the pin file still declares exactly one UPSTREAM_VERSION line"
assert_eq "$(grep -c '^#' "$pin_writable")" "$comments_before" \
  "ac-1 the write keeps the explaining comment block"

# The workflow may pass the version as an input instead of an argument.
watch_run "$pin_writable" "$tmp/o-pin-env.env" CI_UPSTREAM_VERSION=25.12.3 -- pin
assert_eq "$watch_status" "0" "ac-1 pin reads CI_UPSTREAM_VERSION when no argument is given"
assert_eq "$(output_of "$tmp/o-pin-env.env" pinned_version)" "25.12.3" \
  "ac-1 the version from the environment is the one that gets pinned"

# One writer, and it is lib.sh: a second write path is how the pin and the three
# derived locks end up describing different releases.
assert_contains "$(cat "$SCRIPT")" 'ci_write_upstream_pin' \
  "ac-1 upstream-watch.sh writes the pin through ci_write_upstream_pin"
assert_eq "$(grep -cE 'sed[[:space:]]+-i' "$SCRIPT")" "0" \
  "ac-1 upstream-watch.sh never edits the pin file with sed -i"
assert_eq "$(grep -cE '>>?[[:space:]]*"[^"]*CI_UPSTREAM_PIN_FILE' "$SCRIPT")" "0" \
  "ac-1 upstream-watch.sh never redirects into the pin file"

# --------------------------------------------------------------------------- #
# ac-1: the two bodies carry what the reviewer and the on-call need
# --------------------------------------------------------------------------- #

watch_run "$pin_readonly" "$tmp/o-none.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_PREVIOUS_PIN=25.12.2 \
  CI_MATRIX_CANDIDATES="25.13.0 25.12.2 25.12.1 25.12.0" CI_MATRIX_GAPS=1 \
  CI_RUN_URL="https://github.com/example/repo/actions/runs/42" -- pr-body --out "$tmp/pr.md"
assert_eq "$watch_status" "0" "ac-1 pr-body renders"
assert_file_exists "$tmp/pr.md" "ac-1 pr-body writes the file named by --out"
pr_body="$(cat "$tmp/pr.md")"
assert_contains "$pr_body" '# Upstream 25.13.0 (pin 25.12.2 -> 25.13.0)' \
  "ac-1 the PR heading carries the version and the pin before/after"
assert_contains "$pr_body" '.github/upstream-pin.conf' "ac-1 the PR body lists the pin change"
for lock in scripts/ci/kmod-closure.json scripts/ci/runtime-closure.json \
  scripts/ci/initramfs-tools.lock.json; do
  assert_contains "$pr_body" "$lock" "ac-1 the PR body lists the derived lock ${lock}"
done
assert_contains "$pr_body" '`25.13.0 25.12.2 25.12.1 25.12.0`' \
  "ac-1 the PR body carries the matrix candidates"
assert_contains "$pr_body" 'Gap: 1' "ac-1 the PR body carries the matrix gap"
assert_contains "$pr_body" 'https://github.com/example/repo/actions/runs/42' \
  "ac-1 the PR body carries the run link"
assert_contains "$pr_body" 'Created by the daily upstream-watch run' \
  "ac-1 the PR body says the daily watch opened it"

watch_run "$pin_readonly" "$tmp/o-nogap.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_PREVIOUS_PIN=25.12.2 \
  CI_MATRIX_CANDIDATES="25.13.0 25.12.2 25.12.1 25.12.0" CI_MATRIX_GAPS=0 \
  -- pr-body --out "$tmp/pr-nogap.md"
assert_contains "$(cat "$tmp/pr-nogap.md")" 'Gap: none' \
  "ac-1 a full matrix renders the gap as none"

watch_run "$pin_readonly" "$tmp/o-issue.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_AUTO_FAILED_STAGE=s5 \
  CI_AUTO_REASON="S5-RESULT=fail reason=qemu-timeout" \
  CI_RUN_URL="https://github.com/example/repo/actions/runs/42" \
  CI_LOG_ARTIFACT=evidence-s5 -- issue-body --out "$tmp/issue.md"
assert_eq "$watch_status" "0" "ac-1 issue-body renders"
issue_body="$(cat "$tmp/issue.md")"
assert_contains "$issue_body" '25.13.0' "ac-1 the issue names the upstream version"
assert_contains "$issue_body" '`s5`' "ac-1 the issue names the failed job"
assert_contains "$issue_body" 'S5-RESULT=fail reason=qemu-timeout' "ac-1 the issue carries the reason"
assert_contains "$issue_body" 'https://github.com/example/repo/actions/runs/42' \
  "ac-1 the issue carries the run link"
assert_contains "$issue_body" '`evidence-s5`' "ac-1 the issue names the log artifact"
assert_contains "$issue_body" 'Nothing was merged, tagged or published' \
  "ac-1 the issue states that nothing was merged, tagged or published"

# A discovery failure is the one case where the issue has no detected version and no
# recovery script: the run never compared the pin with anything. The body has to say so
# and carry the reason, because "see the run log" is not a reason and "detected upstream
# 25.12.2 (pin 25.12.2)" would describe a comparison that never happened.
discovery_reason='the upstream index lists no formal release at 25.x or newer: the index or its mirror is broken or lagging'
watch_run "$pin_readonly" "$tmp/o-issue-detect.env" \
  CI_UPSTREAM_VERSION=25.12.2 CI_AUTO_FAILED_STAGE=detect CI_DETECT_ERROR="$discovery_reason" \
  CI_RUN_URL="https://github.com/example/repo/actions/runs/43" \
  -- issue-body --out "$tmp/issue-detect.md"
assert_eq "$watch_status" "0" "ac-1 a discovery-failed issue renders"
detect_body="$(cat "$tmp/issue-detect.md")"
assert_contains "$detect_body" 'could not discover a new upstream release' \
  "ac-1 a discovery failure says the release was never identified"
assert_contains "$detect_body" "> ${discovery_reason}" \
  "ac-1 the issue carries the detect error instead of pointing at the log only"
assert_contains "$detect_body" "| reason | ${discovery_reason} |" \
  "ac-1 the reason row is the detect error, not the generic stage sentence"
assert_eq "$(printf '%s\n' "$detect_body" | grep -c 'resume=merge' || true)" "0" \
  "ac-1 a discovery failure does not offer a resume that would skip discovery"
assert_eq "$(printf '%s\n' "$detect_body" | grep -c 'detected upstream' || true)" "0" \
  "ac-1 a discovery failure does not claim a version was detected"

# And the failure itself has to publish that reason, or the issue job has nothing to carry.
watch_run "$pin_readonly" "$tmp/o-empty2.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-empty.html" -- detect
assert_eq "$watch_status" "1" "ac-1 an empty index still fails"
assert_contains "$(cat "$tmp/o-empty2.env")" 'detect_error=the upstream index lists no formal release' \
  "ac-1 the failing detect publishes the reason as an output for the issue job"
assert_eq "$(sed -n 's/^detect_error=//p' "$tmp/o-empty2.env" | grep -c '^the upstream index' || true)" "1" \
  "ac-1 the published reason is a single line, so it survives a GITHUB_OUTPUT round trip"

# An unknown subcommand has to be a usage error, not a silent no-op: a typo in the
# workflow would otherwise skip the whole release step and still look green.
watch_run "$pin_readonly" "$tmp/o-usage.env" -- publish
assert_eq "$watch_status" "1" "ac-1 an unknown subcommand exits non-zero"
assert_contains "$watch_log" "usage: upstream-watch.sh" "ac-1 an unknown subcommand prints the usage"

# --------------------------------------------------------------------------- #
# ac-3: detect can be told to recover a release instead of discovering one
#
# The recovery path exists because a failure after the merge leaves the pin equal to the
# version being released. On the discovery path that is a refusal ("nothing to rehearse");
# with `resume` set it is the state the run is supposed to start from.
# --------------------------------------------------------------------------- #

# A throw-away repository whose base branch pins <version>, so the pin-in-base read and
# the tag comparison are exercised against real git state rather than a stub.
repo="$tmp/repo"
mkdir -p "$repo/.github"
git -C "$repo" init -q .
git -C "$repo" config user.name "ci test"
git -C "$repo" config user.email "ci@example.test"
# The base branch is named, not inherited from the runner's `init.defaultBranch`: the pin
# is read from `main` by name, so a fixture on `master` would test the wrong thing.
git -C "$repo" checkout -q -b main
printf 'UPSTREAM_VERSION=25.12.2\n' >"$repo/.github/upstream-pin.conf"
git -C "$repo" add -A
GIT_AUTHOR_DATE="2026-11-01T00:00:00Z" GIT_COMMITTER_DATE="2026-11-01T00:00:00Z" \
  git -C "$repo" commit -q -m "base"

# detect_run <output-env-file> [VAR=value ...] -- <arguments...>: the same runner, but
# pointed at the fixture repository instead of the checkout.
detect_run() {
  local out_env="$1"
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  watch_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out_env" \
    CI_TMP_ROOT="$tmp/ci" CI_REPO_ROOT="$repo" CI_UPSTREAM_PIN_FILE="$repo/.github/upstream-pin.conf" \
    GH_TOKEN= "${envs[@]+"${envs[@]}"}" bash "$SCRIPT" "$@" 2>&1)"
  watch_status=$?
}

# The discovery path refuses a forced version that is already the pin: that refusal is the
# bug this unit fixes the consequences of, so it is asserted to still exist.
detect_run "$tmp/o-refuse.env" CI_FORCE_VERSION=25.12.2 -- detect
assert_eq "$watch_status" "1" "ac-3 discovery still refuses a version that is already the pin"
assert_contains "$watch_log" "already the pin" \
  "ac-3 the refusal is the one the recovery has to get past"
assert_contains "$watch_log" "pass resume=merge or resume=publish" \
  "ac-3 the refusal names the recovery that is allowed to continue"

# The same dispatch with resume=merge is the recovery: it does not compare against the
# mirror at all, and it reports where the release stopped.
detect_run "$tmp/o-resume.env" CI_FORCE_VERSION=25.12.2 CI_RESUME=merge -- detect
assert_eq "$watch_status" "0" "ac-3 resume=merge gets past 'already the pin'"
assert_eq "$(output_of "$tmp/o-resume.env" mode)" "resume" "ac-3 the run reports mode=resume"
assert_eq "$(output_of "$tmp/o-resume.env" resume_stage)" "merge" \
  "ac-3 the run reports which stage it resumes"
assert_eq "$(output_of "$tmp/o-resume.env" changed)" "true" \
  "ac-3 a recovery is a change even though it discovered nothing"
assert_eq "$(output_of "$tmp/o-resume.env" version)" "25.12.2" \
  "ac-3 a recovery builds the version it was told to recover"
assert_eq "$(output_of "$tmp/o-resume.env" pin_in_base)" "25.12.2" \
  "ac-3 the base branch is reported as already carrying the pin"
assert_eq "$(output_of "$tmp/o-resume.env" tag_exists)" "false" \
  "ac-3 no tag is reported before one is pushed"
assert_eq "$(output_of "$tmp/o-resume.env" latest_formal)" "" \
  "ac-3 a recovery does not rediscover a release from the mirror"
assert_contains "$watch_log" "resume merge: version 25.12.2" \
  "ac-3 the log says what it is resuming"

# A recovery without a version is a usage error: it may not silently rediscover one.
detect_run "$tmp/o-resume-nover.env" CI_RESUME=merge -- detect
assert_eq "$watch_status" "1" "ac-3 resume without a version fails instead of discovering one"

# Only the two stages the graph can resume from are accepted.
detect_run "$tmp/o-resume-bad.env" CI_FORCE_VERSION=25.12.2 CI_RESUME=locks -- detect
assert_eq "$watch_status" "1" "ac-3 an unknown resume stage is refused"
assert_contains "$watch_log" "CI_RESUME must be empty" "ac-3 the refusal names the accepted values"

# The discovery path is unchanged: a normal run still reports mode=discover.
watch_run "$pin_readonly" "$tmp/o-discover.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index.html" -- detect
assert_eq "$(output_of "$tmp/o-discover.env" mode)" "discover" \
  "ac-3 an ordinary run reports mode=discover"
assert_eq "$(output_of "$tmp/o-discover.env" resume_stage)" "" \
  "ac-3 an ordinary run has no resume stage"

# --------------------------------------------------------------------------- #
# ac-3: merge-state splits the idempotency into skip-merge and skip-tag
#
# A failure can land between the squash and the tag, so the two halves are decided
# separately. A tag that exists and names another commit is a hard failure: the tag is the
# release identity, and moving it would republish a release nobody rebuilt.
# --------------------------------------------------------------------------- #

# nothing merged yet: the base branch pins 25.12.2 and the release being recovered is
# 25.13.0, so both halves still have work to do.
watch_run "$pin_readonly" "$tmp/o-state-none.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN= -- merge-state 25.13.0
assert_eq "$watch_status" "0" "ac-3 merge-state runs offline"
assert_eq "$(output_of "$tmp/o-state-none.env" tag_exists)" "false" \
  "ac-3 no tag exists before the merge"
assert_eq "$(output_of "$tmp/o-state-none.env" skip_merge)" "false" \
  "ac-3 an earlier pin means the merge still has to happen"
assert_eq "$(output_of "$tmp/o-state-none.env" skip_tag)" "false" \
  "ac-3 an earlier pin means the tag still has to happen"

# merged: the base branch pins the version, so the squash is skipped and only the tag is left.
git -C "$repo" checkout -q -B main
printf 'UPSTREAM_VERSION=25.13.0\n' >"$repo/.github/upstream-pin.conf"
git -C "$repo" add -A
GIT_AUTHOR_DATE="2026-11-15T00:00:00Z" GIT_COMMITTER_DATE="2026-11-15T00:00:00Z" \
  git -C "$repo" commit -q -m "pin 25.13.0"
merged_sha="$(git -C "$repo" rev-parse HEAD)"

watch_run "$pin_readonly" "$tmp/o-state-merged.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN= CI_MERGED_SHA="$merged_sha" -- merge-state 25.13.0
assert_eq "$watch_status" "0" "ac-3 merge-state reads a merged release"
assert_eq "$(output_of "$tmp/o-state-merged.env" pin_in_base)" "25.13.0" \
  "ac-3 the base branch already pins the merged version"
assert_eq "$(output_of "$tmp/o-state-merged.env" skip_merge)" "true" \
  "ac-3 the squash is skipped once the base branch carries the pin"
assert_eq "$(output_of "$tmp/o-state-merged.env" skip_tag)" "false" \
  "ac-3 the tag is still owed: the merge landed without it"

# tagged at the merge commit: both halves are done, which is what makes a re-run idempotent.
git -C "$repo" tag -a 25.13.0 -m "tag 25.13.0" "$merged_sha"
watch_run "$pin_readonly" "$tmp/o-state-tagged.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN= CI_MERGED_SHA="$merged_sha" -- merge-state 25.13.0
assert_eq "$watch_status" "0" "ac-3 merge-state reads a merged and tagged release"
assert_eq "$(output_of "$tmp/o-state-tagged.env" tag_exists)" "true" \
  "ac-3 the pushed tag is visible"
assert_eq "$(output_of "$tmp/o-state-tagged.env" tag_sha)" "$merged_sha" \
  "ac-3 the annotated tag is read as the commit it points at, not as the tag object"
assert_eq "$(output_of "$tmp/o-state-tagged.env" skip_tag)" "true" \
  "ac-3 a tag that names the merge commit is an idempotent skip"

# tagged at another commit: hard failure, never a force push.
watch_run "$pin_readonly" "$tmp/o-state-moved.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN= CI_MERGED_SHA="$(git -C "$repo" rev-parse HEAD~1)" \
  -- merge-state 25.13.0
assert_eq "$watch_status" "1" "ac-3 a tag that points at another commit is a hard failure"
assert_contains "$watch_log" "tags are immutable" \
  "ac-3 the failure says why the tag will not be moved"
assert_eq "$(grep -cE 'tag -f|push -f|push --force' "$SCRIPT" || true)" "0" \
  "ac-3 the script has no force-tag or force-push path at all"

# The version is required, and it goes through the same formal-release gate as the pin.
watch_run "$pin_readonly" "$tmp/o-state-nover.env" CI_REPO_ROOT="$repo" GH_TOKEN= -- merge-state
assert_eq "$watch_status" "1" "ac-3 merge-state requires a version"
watch_run "$pin_readonly" "$tmp/o-state-vtag.env" \
  CI_REPO_ROOT="$repo" GH_TOKEN= -- merge-state v25.13.0
assert_eq "$watch_status" "1" "ac-3 merge-state refuses a v-prefixed version"

# --------------------------------------------------------------------------- #
# ac-3: the branch-name fallback asks for the newest merged pull request
#
# A recovery dispatch carries no PR number, so `merged_sha_of` falls back to a lookup by
# the deterministic branch name. That list is not ordered by merge time and it includes
# closed pull requests with no merge commit at all, so taking the first entry that has a
# mergeCommit answers with the *oldest* merge the branch ever had. Such a commit is far
# behind the base branch: tagging it publishes a tree without any of the fixes on main,
# and comparing an existing tag against it kills the recovery permanently.
#
# The double below is the only case in this file that reaches the API path on purpose:
# every other merge-state case injects CI_MERGED_SHA, which is exactly why the defect had
# no test coverage. The pull-request list is written oldest-first, so the list order and
# the merge-time order disagree and a "first entry" answer is caught.
# --------------------------------------------------------------------------- #

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# Test double for `gh`: answers the pull-request queries `merged_sha_of` can make from the
# JSON list in $GH_STUB_PRS. The caller's --jq expression is evaluated with the real jq,
# so what gets exercised is the query the script builds (state filter, sort key), not a
# canned answer.
set -u
printf 'gh %s\n' "$*" >>"${GH_STUB_CALLS:?GH_STUB_CALLS is not set}"
expr=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "--jq" ]; then
    i=$((i + 1))
    expr="${args[$i]:-}"
  fi
  i=$((i + 1))
done
if [ -n "$expr" ]; then
  jq -r "$expr" <"${GH_STUB_PRS:?GH_STUB_PRS is not set}"
  exit $?
fi
cat "${GH_STUB_PRS:?GH_STUB_PRS is not set}"
STUB
chmod +x "$stub_bin/gh"

# Two merged pull requests for the same branch, listed oldest first, with closed ones (no
# merge commit) interleaved the way the real API returns them.
cat >"$tmp/prs-two-merges.json" <<'JSON'
[
  {"number": 14, "state": "CLOSED", "mergeCommit": null, "mergedAt": null},
  {"number": 8, "state": "MERGED", "mergedAt": "2026-10-02T09:14:00Z",
   "mergeCommit": {"oid": "1111111111111111111111111111111111111111"}},
  {"number": 13, "state": "CLOSED", "mergeCommit": null, "mergedAt": null},
  {"number": 7, "state": "MERGED", "mergedAt": "2026-11-12T12:53:27Z",
   "mergeCommit": {"oid": "2222222222222222222222222222222222222222"}}
]
JSON

: >"$tmp/gh-calls.log"
watch_run "$pin_readonly" "$tmp/o-state-fallback.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN=stub-token CI_PR= CI_MERGED_SHA= \
  "PATH=$stub_bin:$PATH" GH_STUB_PRS="$tmp/prs-two-merges.json" \
  GH_STUB_CALLS="$tmp/gh-calls.log" -- merge-state 25.13.1
assert_eq "$watch_status" "0" "ac-3 merge-state reads the fallback answer without dying"
assert_eq "$(output_of "$tmp/o-state-fallback.env" merged_sha)" \
  "2222222222222222222222222222222222222222" \
  "ac-3 the fallback picks the newest merged commit, not the first entry in the list"
assert_eq "$(output_of "$tmp/o-state-fallback.env" tag_exists)" "false" \
  "ac-3 the fallback case has no tag yet"
gh_calls="$(cat "$tmp/gh-calls.log")"
assert_contains "$gh_calls" "--state merged" \
  "ac-3 the fallback asks for merged pull requests only"
assert_contains "$gh_calls" "--head auto/upstream-25.13.1" \
  "ac-3 the fallback looks the branch up by its deterministic name"
assert_contains "$gh_calls" "sort_by(.mergedAt)" \
  "ac-3 the fallback orders the list by merge time"
assert_eq "$(printf '%s\n' "$gh_calls" | grep -c 'pr view' || true)" "0" \
  "ac-3 no PR number is used, so only the branch-name lookup runs"

# Nothing merged at all stays "unknown": the fallback may not invent a commit, and an
# unknown merge commit must not stop the recovery from tagging.
cat >"$tmp/prs-no-merge.json" <<'JSON'
[
  {"number": 9, "state": "CLOSED", "mergeCommit": null, "mergedAt": null},
  {"number": 10, "state": "CLOSED", "mergeCommit": null, "mergedAt": null}
]
JSON
watch_run "$pin_readonly" "$tmp/o-state-nomerge.env" \
  CI_REPO_ROOT="$repo" CI_BASE=main GH_TOKEN=stub-token CI_PR= CI_MERGED_SHA= \
  "PATH=$stub_bin:$PATH" GH_STUB_PRS="$tmp/prs-no-merge.json" \
  GH_STUB_CALLS="$tmp/gh-calls-nomerge.log" -- merge-state 25.13.1
assert_eq "$watch_status" "0" \
  "ac-3 no merged pull request still leaves merge-state runnable"
assert_eq "$(output_of "$tmp/o-state-nomerge.env" merged_sha)" "" \
  "ac-3 no merged pull request answers with an empty commit instead of a guess"
assert_eq "$(output_of "$tmp/o-state-nomerge.env" skip_tag)" "false" \
  "ac-3 an unknown merge commit does not turn into skip-tag"

# --------------------------------------------------------------------------- #
# ac-2: a pin newer than the index is an anomaly, not "no update"
#
# A pin ahead of the mirror is either a pruned/lagging index or a pin bumped past it. Both
# used to end green with changed=false, which is indistinguishable from "upstream has not
# released anything". The pin is still not downgraded -- nothing may write an older version
# -- but the run has to fail so the issue job fires.
# --------------------------------------------------------------------------- #

cat >"$tmp/index-older.html" <<'HTML'
<a href="../">../</a>
<a href="25.12.1/">25.12.1/</a>
<a href="25.12.0/">25.12.0/</a>
<a href="24.10.6/">24.10.6/</a>
HTML
printf 'UPSTREAM_VERSION=25.12.2\n' >"$tmp/pin-newer.conf"
# The pin read-only fixture is not used here: the point is a pin the index cannot reach.
watch_run "$tmp/pin-newer.conf" "$tmp/o-newer.env" \
  CI_UPSTREAM_INDEX="$tmp/index-older.html" -- detect
newer_changed="$([ -f "$tmp/o-newer.env" ] && sed -n 's/^changed=//p' "$tmp/o-newer.env")"
assert_eq "$watch_status" "1" "ac-2 a pin newer than the index fails instead of exiting green"
assert_contains "$watch_log" "ERROR" "ac-2 a pin ahead of the mirror is reported as an error"
assert_contains "$watch_log" "the pin 25.12.2 is newer than the newest formal release 25.12.1" \
  "ac-2 the error names both the pin and the newest formal release"
assert_contains "$watch_log" 'not "no update"' \
  "ac-2 the error says a pin ahead of the mirror is not the same thing as no update"
assert_eq "$newer_changed" "" \
  "ac-2 a pin ahead of the mirror publishes no changed output, in particular not changed=false"
assert_eq "$(output_of "$tmp/o-newer.env" version)" "25.12.2" \
  "ac-2 the failing run still names the pin it was about, so the failure issue is actionable"
assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$tmp/pin-newer.conf")" "25.12.2" \
  "ac-2 the pin is kept, not downgraded to the newest release the index offers"

# The other half of ac-2: the pin already being the newest formal release stays a green run
# with changed=false, so "nothing to do" is still distinguishable from both anomalies.
watch_run "$pin_readonly" "$tmp/o-atpin2.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-at-pin.html" -- detect
assert_eq "$watch_status" "0" "ac-2 a pin equal to the newest formal release still exits 0"
assert_eq "$(output_of "$tmp/o-atpin2.env" changed)" "false" \
  "ac-2 a pin equal to the newest formal release still reads as changed=false"
assert_eq "$(output_of "$tmp/o-atpin2.env" latest_formal)" "25.12.2" \
  "ac-2 a pin equal to the newest formal release still reports the release it compared"

# A rehearsal names the release it wants, so a broken mirror may be reported but may not
# decide whether a human's dispatch runs. Without this, making the two anomalies fatal would
# also have made every rehearsal impossible during exactly the outage someone needs to
# rehearse through.
watch_run "$pin_readonly" "$tmp/o-force-broken.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-empty.html" CI_FORCE_VERSION=25.13.0 -- detect
assert_eq "$watch_status" "0" "ac-2 a rehearsal of a named version survives a broken index"
assert_eq "$(output_of "$tmp/o-force-broken.env" changed)" "true" \
  "ac-2 the rehearsal still asks for the build"
assert_eq "$(output_of "$tmp/o-force-broken.env" version)" "25.13.0" \
  "ac-2 the rehearsal builds the version it named, not the pin"
assert_contains "$watch_log" "WARNING" \
  "ac-2 the rehearsal reports the broken index instead of hiding it"

finish
