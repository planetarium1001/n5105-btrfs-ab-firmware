#!/usr/bin/env bash
# Module: ci
# Guards the conventions every workflow in .github/workflows/ci*.yml has to follow,
# and the one interface the CI tree exposes to other tasks: the upstream pin.
#
# The pin is the first thing this file grew, because task 20261112-02 (upstream auto
# release) bumps it from a branch that does not own scripts/ci/lib.sh. The contract is:
#
#   * the value lives in .github/upstream-pin.conf, nowhere else
#   * scripts/ci/lib.sh reads it (ci_upstream_pin_read) and is its only reader
#   * ci_write_upstream_pin is the only writer
#   * precedence is explicit CI_UPSTREAM_VERSION_PIN > pin file > 25.12.2 default
#
# A missing or malformed pin file must fall back, never produce an empty pin: an empty
# pin makes the fetch stage resolve "latest" and quietly build a different release.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pin_file="$root/.github/upstream-pin.conf"
lib="$root/scripts/ci/lib.sh"

# pin_read <pin-file>: read the pin with the library, in a clean subshell so the
# `set -euo pipefail` inside lib.sh cannot leak into the test.
pin_read() {
  CI_UPSTREAM_PIN_FILE="$1" bash -c '. "$1" >/dev/null 2>&1; ci_upstream_pin_read' _ "$lib" 2>/dev/null
}

# pin_resolved <pin-file> [explicit]: the value a stage script actually sees after
# lib.sh resolves the precedence chain (explicit env > file > default).
pin_resolved() {
  CI_UPSTREAM_PIN_FILE="$1" CI_UPSTREAM_VERSION_PIN="${2:-}" \
    bash -c '. "$1" >/dev/null 2>&1; printf "%s\n" "${CI_UPSTREAM_VERSION_PIN}"' _ "$lib" 2>/dev/null
}

# pin_write <pin-file> <version>: write through the single entry point.
pin_write() {
  CI_UPSTREAM_PIN_FILE="$1" bash -c '. "$1" >/dev/null 2>&1; ci_write_upstream_pin "$2"' _ "$lib" "$2" 2>/dev/null
}

# --------------------------------------------------------------------------- #
# ac-13: the pin has exactly one home, one reader and one writer
# --------------------------------------------------------------------------- #

assert_file_exists "$pin_file" "ac-13 the pin lives in .github/upstream-pin.conf"

assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_file" | wc -l | tr -d ' ')" "1" \
  "ac-13 the pin file declares exactly one UPSTREAM_VERSION line"

assert_eq "$(pin_read "$pin_file")" "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_file")" \
  "ac-13 ci_upstream_pin_read returns the tracked pin"

# The only lines in the CI tree that start with UPSTREAM_VERSION= are the pin itself and
# the release-file renderer in lib.sh (platform-release carries its own copy of that
# format). Any other hit would be a second source of truth.
pin_writers=$(grep -rln '^UPSTREAM_VERSION=' scripts/ci .github --include='*.sh' \
  --include='*.yml' --include='*.conf' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
assert_eq "$pin_writers" ".github/upstream-pin.conf scripts/ci/lib.sh " \
  "ac-13 the pin is declared only in .github/upstream-pin.conf (lib.sh holds the release template)"

# lib.sh must read the file, not inline a version of its own.
assert_contains "$(grep -F 'CI_UPSTREAM_VERSION_PIN="${CI_UPSTREAM_VERSION_PIN:-' "$lib")" \
  '$(ci_upstream_pin_read)}' "ac-13 lib.sh resolves the pin through ci_upstream_pin_read"
assert_contains "$(grep -F 'CI_UPSTREAM_PIN_FILE=' "$lib")" '.github/upstream-pin.conf' \
  "ac-13 lib.sh points the reader at .github/upstream-pin.conf"

# The write entry is defined once, in lib.sh, and nowhere else.
writers=$(grep -rl '^ci_write_upstream_pin()' --include='*.sh' --include='*.yml' . 2>/dev/null || true)
assert_eq "$writers" "./scripts/ci/lib.sh" "ac-13 ci_write_upstream_pin is defined only in scripts/ci/lib.sh"

# --------------------------------------------------------------------------- #
# ac-13: fallbacks never yield an empty pin
# --------------------------------------------------------------------------- #

assert_eq "$(pin_read "$tmp/absent.env")" "25.12.2" \
  "ac-13 a missing pin file falls back to the built-in default"

: >"$tmp/empty.env"
assert_eq "$(pin_read "$tmp/empty.env")" "25.12.2" \
  "ac-13 an empty pin file falls back to the built-in default"

printf 'UPSTREAM_VERSION=\n' >"$tmp/blank.env"
assert_eq "$(pin_read "$tmp/blank.env")" "25.12.2" \
  "ac-13 a blank pin value falls back to the built-in default"

printf 'UPSTREAM_VERSION=25.12\n' >"$tmp/short.env"
assert_eq "$(pin_read "$tmp/short.env")" "25.12.2" \
  "ac-13 a non X.Y.Z pin falls back to the built-in default"

printf 'UPSTREAM_VERSION=25.12.3-rc1\n' >"$tmp/rc.env"
assert_eq "$(pin_read "$tmp/rc.env")" "25.12.2" \
  "ac-13 an rc pin falls back to the built-in default"

# An explicit value in the environment still wins, which is how one run pins a release
# without touching the tracked file.
assert_eq "$(pin_resolved "$pin_file" "25.12.9")" "25.12.9" \
  "ac-13 an explicit CI_UPSTREAM_VERSION_PIN wins over the file"
assert_eq "$(pin_resolved "$tmp/absent.env")" "25.12.2" \
  "ac-13 with no file and no override the resolved pin is the built-in default"

# --------------------------------------------------------------------------- #
# ac-13: writing rewrites one line and keeps the explanation
# --------------------------------------------------------------------------- #

cp "$pin_file" "$tmp/pin.env"
before_comments=$(grep -c '^#' "$tmp/pin.env")
pin_write "$tmp/pin.env" "25.12.3"
assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$tmp/pin.env")" "25.12.3" \
  "ac-13 ci_write_upstream_pin bumps the value"
assert_eq "$(pin_read "$tmp/pin.env")" "25.12.3" \
  "ac-13 the written pin reads back"
assert_eq "$(grep -c '^#' "$tmp/pin.env")" "$before_comments" \
  "ac-13 the write keeps the comment block"
assert_eq "$(grep -c '^UPSTREAM_VERSION=' "$tmp/pin.env")" "1" \
  "ac-13 the write leaves exactly one pin line"

# A version the resolver could never use must be refused, and must not touch the file.
if pin_write "$tmp/pin.env" "latest"; then
  _assert_fail "ac-13 ci_write_upstream_pin rejects a non X.Y.Z version" "it accepted 'latest'"
else
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-13 ci_write_upstream_pin rejects a non X.Y.Z version"
fi
assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$tmp/pin.env")" "25.12.3" \
  "ac-13 a refused write leaves the pin unchanged"

# The auto-release task writes into a repo that has no pin file yet (first bump after a
# checkout of an older branch): the entry has to create one, not fail.
pin_write "$tmp/fresh/pin.env" "25.12.4"
assert_eq "$(pin_read "$tmp/fresh/pin.env")" "25.12.4" \
  "ac-13 ci_write_upstream_pin creates the pin file when it is absent"

# --------------------------------------------------------------------------- #
# ac-9: every workflow carries a timeout budget and a lane-scoped concurrency group
#
# The group used to be `ci-<workflow>-<ref>` with cancel-in-progress: true, so a manual
# workflow_dispatch of a stage was cancelled by the next push to the same ref, and a
# push was cancelled by a manual run. The lane segment is what separates them.
# --------------------------------------------------------------------------- #

workflows=$(ls .github/workflows/ci*.yml)

# job_timeout <workflow-file> <job-id>: the job-level timeout-minutes of one job.
job_timeout() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:$/ { job = $1; sub(":$", "", job); injob = (job == want); next }
    injob && /^    timeout-minutes:/ { print $2; exit }
  ' "$1"
}

GROUP='group: ci-${{ github.workflow }}-${{ github.event_name == '"'"'workflow_dispatch'"'"' && '"'"'manual'"'"' || '"'"'auto'"'"' }}-${{ github.ref }}'
CANCEL='cancel-in-progress: ${{ github.event_name != '"'"'workflow_dispatch'"'"' }}'

for wf in $workflows; do
  assert_contains "$(cat "$wf")" "$GROUP" "ac-9 $(basename "$wf") scopes its concurrency group by lane"
  assert_contains "$(cat "$wf")" "$CANCEL" "ac-9 $(basename "$wf") never cancels a manual run"
  assert_eq "$(grep -c 'cancel-in-progress:' "$wf")" "1" \
    "ac-9 $(basename "$wf") declares exactly one cancel-in-progress"
  assert_eq "$(grep -c '^concurrency:' "$wf")" "1" \
    "ac-9 $(basename "$wf") declares exactly one concurrency block"
  # A workflow with no timeout anywhere lets a hung QEMU boot sit on a runner for the
  # six-hour default.
  assert_eq "$(grep -c 'timeout-minutes:' "$wf" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes" \
    "ac-9 $(basename "$wf") declares a timeout budget"
done

# GitHub only accepts timeout-minutes at job and step level, so every cap has to sit on a
# job that actually runs: a reusable-workflow call (`jobs.<id>.uses:`) accepts neither a
# timeout nor a step, and the workflow level has no such key at all.
assert_eq "$(job_timeout .github/workflows/ci-report.yml report)" "20" \
  "ac-9 the report job is capped at 20 minutes"
assert_eq "$(job_timeout .github/workflows/ci-debug.yml debug)" "290" \
  "ac-9 the debug job is capped at 290 minutes, under a 300-minute graph budget"
assert_contains "$(cat .github/workflows/ci-debug.yml)" 'timeout-minutes: 150' \
  "ac-9 the upterm session keeps its own 150-minute keepalive"
# ci.yml schedules no runnable job of its own, so its budget has to come from the one job
# it does run (the version reader). A cap on a reusable-workflow call is not valid YAML.
_assert_count=$((_ASSERT_COUNT + 1))
if [ "$(job_timeout .github/workflows/ci.yml versions)" = "5" ]; then
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-9 the ci.yml version job is capped at 5 minutes"
else
  _assert_fail "ac-9 the ci.yml version job is capped at 5 minutes" \
    "got [$(job_timeout .github/workflows/ci.yml versions)]"
fi

# --------------------------------------------------------------------------- #
# ac-10: every third-party action is pinned to a commit sha
# --------------------------------------------------------------------------- #

unpinned=$(grep -rhE '^\s*uses:' .github/workflows/ci*.yml \
  | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
  | grep -vE '^\./' \
  | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}( # v[0-9].*)?$' || true)
assert_eq "$unpinned" "" "ac-10 every third-party action is pinned to a 40-character sha"

uncommented=$(grep -rhE '^\s*uses:' .github/workflows/ci*.yml \
  | sed -E 's/^[[:space:]]*uses:[[:space:]]*//' \
  | grep -vE '^\./' \
  | grep -vE ' # v[0-9]' || true)
assert_eq "$uncommented" "" "ac-10 every pinned action names the release it pins"

# --------------------------------------------------------------------------- #
# ac-11: the duplicates live in composites, and the workflows keep their contracts
# --------------------------------------------------------------------------- #

line_total=$(cat .github/workflows/ci*.yml | wc -l | tr -d ' ')
_assert_count=$((_ASSERT_COUNT + 1))
if [ "$line_total" -le 2288 ]; then
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-11 the workflows total $line_total lines (<=2288, baseline 3269)"
else
  _assert_fail "ac-11 the workflows total $line_total lines (<=2288, baseline 3269)" \
    "the composite refactor did not remove a third of the duplicated YAML"
fi

assert_eq "$(grep -c 'uses: actions/checkout@' "$root/.github/actions/setup-ci/action.yml" 2>/dev/null || true)" "0" \
  "ac-11 setup-ci does not check out (a local action cannot run before checkout)"

for action in setup-ci run-stage-script stage-evidence stage-summary qemu-boot; do
  assert_file_exists "$root/.github/actions/$action/action.yml" "ac-11 composite $action exists"
done

# Each stage publishes its evidence and its summary through the shared composites, so a
# stage cannot silently lose its artifact upload.
for stage in s1 s2 s3 s4 s5; do
  wf=".github/workflows/ci-$stage.yml"
  assert_contains "$(cat "$wf")" './.github/actions/stage-evidence' \
    "ac-11 $stage publishes evidence through the shared composite"
  assert_contains "$(cat "$wf")" './.github/actions/stage-summary' \
    "ac-11 $stage renders its summary through the shared composite"
  assert_contains "$(cat "$wf")" './.github/actions/setup-ci' \
    "ac-11 $stage sets up through the shared composite"
  # A local composite cannot be the first step of a job: GitHub resolves
  # `./.github/actions/setup-ci` before the workspace exists. The checkout therefore stays
  # a step of the job, once, and setup-ci never does it.
  assert_eq "$(grep -c 'actions/checkout@' "$wf")" "1" \
    "ac-11 $stage checks out exactly once, before the composite"
  assert_eq "$(grep -c 'persist-credentials: false' "$wf")" "1" \
    "ac-11 $stage leaves no credentials in the workspace"
done

# The artifact names and the judge-line vocabulary are the run page contract: nothing in
# this refactor is allowed to rename them.
for stage in s1 s2 s3 s4 s5; do
  assert_contains "$(cat .github/actions/stage-evidence/action.yml .github/workflows/ci-$stage.yml)" \
    "evidence-$stage" "ac-11 the artifact evidence-$stage still exists"
done
assert_contains "$(cat .github/workflows/ci-fetch.yml .github/actions/setup-ci/action.yml)" \
  'upstream-files' "ac-11 the upstream-files artifact name is unchanged"

# --------------------------------------------------------------------------- #
# ac-8 / ac-14: the lint gate is real, and its verdict reaches the run page
# --------------------------------------------------------------------------- #

assert_file_exists "$root/.github/actions/actionlint/action.yml" "ac-8 the actionlint composite exists"
assert_contains "$(cat .github/workflows/ci-verify.yml)" './.github/actions/actionlint' \
  "ac-8 the verify stage installs and runs actionlint"
assert_contains "$(cat scripts/ci/verify.sh)" 'actionlint' \
  "ac-8 verify.sh lints the workflows"
# A soft skip is exactly the failure mode this acceptance exists to kill.
assert_eq "$(grep -c 'lint skipped' scripts/ci/verify.sh)" "0" \
  "ac-8 verify.sh no longer skips the lint when the tool is missing"
assert_contains "$(cat scripts/ci/verify.sh)" 'GITHUB_STEP_SUMMARY' \
  "ac-14 verify.sh writes its verdicts to the run summary"
for key in actionlint shellcheck tests design; do
  assert_contains "$(cat scripts/ci/verify.sh)" "$key:" \
    "ac-14 the run summary carries a $key line"
done

# When actionlint is installed on the machine running the suite, the workflows have to
# pass it right now. Without the tool the test says so and moves on: the CI verify stage
# is where the gate itself is hard.
if command -v actionlint >/dev/null 2>&1; then
  # actionlint 1.7.7 has no `-color=never` and refuses a directory argument, and its
  # shellcheck integration would make this gate depend on which shell, in which version,
  # happens to be on PATH (see the verify stage for the same decision).
  if actionlint -no-color --shellcheck= .github/workflows/*.yml >"$tmp/actionlint.out" 2>&1; then
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-8 actionlint accepts every workflow"
  else
    _assert_fail "ac-8 actionlint accepts every workflow" "$(head -20 "$tmp/actionlint.out")"
  fi
else
  printf '# actionlint is not installed here; ac-8 is enforced by the verify stage\n'
fi

finish
