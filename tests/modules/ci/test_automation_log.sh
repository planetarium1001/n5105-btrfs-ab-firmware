#!/usr/bin/env bash
# Module: ci
# ac-3 / ac-6: the automation audit log, and the two jobs that write it.
#
# Why this file exists: the audit log is the only machine-readable answer to "which releases
# did this repository's automation produce, and what did it claim about them". A table that
# silently changes shape, escapes nothing, or invents an event name is worse than no table,
# because a reader trusts it. The four things asserted here are the four ways it can rot:
#   * the header is fixed and written once, so an existing row is never rewritten
#   * the four events render their own detail, and an unknown one is refused (a typo must
#     not become a fifth event nobody can grep for)
#   * `|` inside a cell is escaped, so the column count stays what the header promises
#   * the two workflows call it where the design says: the upstream watch after a published
#     release, ci.yml after a push to main that touched a platform path
#   * the file is in the repository and not only on one machine's disk, because the header it
#     was created with is what the first row of a fresh checkout appends to
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/automation-log.sh"
WATCH="$root/.github/workflows/upstream-watch.yml"
CI_YML="$root/.github/workflows/ci.yml"
LOG="$tmp/log/automation-log.md"

# al_run [arguments...]: run the script against a log under $tmp, so the repository's own
# file is never touched by an assertion.
al_run() {
  al_out="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_REPO_ROOT="$tmp" \
    CI_AUTOMATION_LOG="${LOG#"$tmp"/}" sh "$SCRIPT" "$@" 2>&1)"
  al_status=$?
}

# --------------------------------------------------------------------------- #
# ac-3: the header is fixed and written once
# --------------------------------------------------------------------------- #

rm -rf "$tmp/log"
al_run append --event upstream --version 25.13.0 --old-pin 25.12.2 \
  --result released --link https://example.test/runs/42
assert_eq "$al_status" "0" "ac-3 an upstream row is accepted"
assert_file_exists "$LOG" "ac-3 the missing log file is created"
assert_eq "$(head -n 1 "$LOG")" '| time | event | detail | result | link |' \
  "ac-3 the table header is the fixed five-column row"
assert_eq "$(sed -n '2p' "$LOG")" '| --- | --- | --- | --- | --- |' \
  "ac-3 the header is followed by its divider"
assert_matches "$(sed -n '3p' "$LOG")" \
  '^\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \| upstream \| .* \| released \| https://example\.test/runs/42 \|$' \
  "ac-3 the upstream row carries time, event, detail, result and link"
assert_contains "$(sed -n '3p' "$LOG")" 'version 25.13.0 (pin 25.12.2 -> 25.13.0)' \
  "ac-3 the upstream detail names the new version and both sides of the pin"

# The header is a one-time write: a second append must not repeat it, and must not touch the
# row that is already there.
first_row="$(sed -n '3p' "$LOG")"
al_run append --event release --version 25.13.0 --assets 3 --link https://example.test/rel/25.13.0
assert_eq "$al_status" "0" "ac-3 a release row is accepted"
assert_eq "$(grep -c '^| time | event | detail | result | link |$' "$LOG")" "1" \
  "ac-3 the header is written once, not per row"
assert_eq "$(sed -n '3p' "$LOG")" "$first_row" \
  "ac-3 the earlier row is byte-identical after the next append"
assert_contains "$(sed -n '4p' "$LOG")" 'version 25.13.0, 3 asset(s)' \
  "ac-3 the release detail names the version and the asset count"
assert_contains "$(sed -n '4p' "$LOG")" "| published |" \
  "ac-3 a release row defaults to published"

# --------------------------------------------------------------------------- #
# ac-3: all four events, and only those four
# --------------------------------------------------------------------------- #

rm -rf "$tmp/log"
al_run append --event upstream --version 25.13.0 --old-pin 25.12.2 --link https://example.test/u
al_run append --event release --version 25.13.0 --assets 2 --link https://example.test/r
al_run append --event platform --sha 0123456789abcdef --subject "fix: pin the loader" \
  --link https://example.test/p
al_run append --event failure --stage publish --reason "artifact missing" --link https://example.test/f
assert_eq "$al_status" "0" "ac-3 a failure row is accepted"
assert_eq "$(grep -c '^| ' "$LOG")" "6" \
  "ac-3 two header lines plus four event rows"
assert_eq "$(grep -c '| upstream |\|| release |\|| platform |\|| failure |' "$LOG")" "4" \
  "ac-3 all four event types are represented"
assert_contains "$(grep 'platform' "$LOG")" '0123456789abcdef: fix: pin the loader' \
  "ac-3 the platform detail is the commit and its subject"
assert_contains "$(grep 'platform' "$LOG")" "| recorded |" \
  "ac-3 a platform row defaults to recorded"
assert_contains "$(grep 'failure' "$LOG")" 'stage publish: artifact missing' \
  "ac-3 the failure detail names the stage and the reason"
assert_contains "$(grep 'failure' "$LOG")" "| failed |" \
  "ac-3 a failure row defaults to failed"

before="$(cat "$LOG")"
al_run append --event typo --link https://example.test/x
assert_eq "$al_status" "2" "ac-3 an unknown event is refused"
assert_contains "$al_out" "unknown event 'typo'" \
  "ac-3 the refusal names the event it did not understand"
assert_contains "$al_out" "upstream, release, platform or failure" \
  "ac-3 the refusal lists the four events that exist"
assert_eq "$(cat "$LOG")" "$before" \
  "ac-3 a refused row does not touch the file"

al_run append --event upstream
assert_eq "$al_status" "2" "ac-3 a row without a link is refused"
assert_contains "$al_out" "--link is required" \
  "ac-3 the refusal says which field is missing"

al_run append --event release --assets two --link https://example.test/x
assert_eq "$al_status" "2" "ac-3 a non-numeric asset count is refused"

al_run append --event upstream --version=v9.9.9 --link=https://example.test/eq
assert_eq "$al_status" "0" "ac-3 the --flag=value spelling is accepted too"
assert_contains "$(grep 'v9.9.9' "$LOG")" "| released |" \
  "ac-3 an explicit result still defaults per event with the equals spelling"

# --------------------------------------------------------------------------- #
# ac-3: a pipe inside a cell is escaped, so the columns stay five
# --------------------------------------------------------------------------- #

rm -rf "$tmp/log"
al_run append --event platform --sha abc1234 --subject "fix: platform | initramfs" \
  --result "ci ok" --link https://example.test/p
assert_eq "$al_status" "0" "ac-3 a subject carrying a pipe is accepted"
row="$(grep 'abc1234' "$LOG")"
assert_contains "$row" 'fix: platform \| initramfs' \
  "ac-3 a pipe in the detail is escaped as \\|"
assert_eq "$(printf '%s\n' "$row" | sed 's/\\|//g' | grep -o ' | ' | wc -l | tr -d ' ')" "4" \
  "ac-3 the escaped row still has exactly four column separators"

# --------------------------------------------------------------------------- #
# ac-3 / ac-6: the two jobs that call it, and the tracked file
# --------------------------------------------------------------------------- #

assert_eq "$(head -n 1 "$SCRIPT")" "#!/bin/sh" \
  "ac-3 the script is POSIX sh, the dialect the runner's /bin/sh is"

# job_block <workflow> <job-id>: one job of a workflow, header to the next job.
job_block() {
  awk -v want="$2" '
    /^  [A-Za-z0-9_-]+:$/ { id = $1; sub(":$", "", id); injob = (id == want); if (injob) print; next }
    injob { print }
  ' "$1"
}

watch_audit="$(job_block "$WATCH" audit)"
assert_contains "${watch_audit}" "needs: [detect, publish]" \
  "ac-6 the watch records the event only after the release exists"
assert_contains "${watch_audit}" "needs.detect.outputs.changed == 'true'" \
  "ac-6 a quiet day writes no audit row"
assert_contains "${watch_audit}" 'gh release view' \
  "ac-6 the row links the release, not only the run"
assert_contains "${watch_audit}" '--event upstream' \
  "ac-6 a detected release writes the upstream row"
assert_contains "${watch_audit}" '--event release' \
  "ac-6 a published release writes the release row"
assert_contains "${watch_audit}" 'git add .github/automation-log.md' \
  "ac-6 the watch commits the log file and nothing else"
assert_contains "${watch_audit}" "contents: write" \
  "ac-6 the audit job may write, because it commits its own row"

ci_audit="$(job_block "$CI_YML" audit)"
assert_contains "${ci_audit}" "needs: [report]" \
  "ac-6 ci.yml records the platform row after the pipeline reported"
assert_contains "${ci_audit}" "always()" \
  "ac-6 a red pipeline still records the change, because the run URL is the reason to look"
assert_contains "${ci_audit}" "github.ref == 'refs/heads/main'" \
  "ac-6 only a push to main is recorded"
assert_contains "${ci_audit}" 'git diff --name-only HEAD^1 HEAD' \
  "ac-6 the decision is the commit's own diff"
assert_contains "${ci_audit}" '\.github/upstream-pin\.conf$' \
  "ac-6 a pin-only bump is recorded"
for path in 'platform/' 'initramfs/' 'VERSION$'; do
  assert_contains "${ci_audit}" "${path}" \
    "ac-6 a push touching ${path} is recorded"
done
assert_contains "${ci_audit}" '--event platform' \
  "ac-6 the row is a platform event"
assert_contains "${ci_audit}" 'git add .github/automation-log.md' \
  "ac-6 ci.yml commits the log file and nothing else"

# The file is tracked so the first row of a fresh checkout appends to a table with a header
# instead of creating two files that disagree about its shape. "Tracked" is a claim about the
# git index, and `assert_file_exists` proves only the disk copy: this guard used to carry the
# name "the audit log is tracked" while checking nothing of the sort, and stayed green with
# `?? .github/automation-log.md` in `git status`. The claim is now the two checks that can
# back it up:
#   * git accepts the path: no ignore rule swallows either record file. Hard, because an
#     ignored path can never be committed at all, and it holds whether or not it is staged.
#   * the path is in the index. A file that HEAD has and the index does not lost a commit's
#     worth of history, so that fails; a brand-new file this working tree has not `git
#     add`ed yet prints skip:, because whether it belongs in the commit being prepared is the
#     committer's call and not a property of this code.
tracked_log="$root/.github/automation-log.md"
assert_file_exists "$tracked_log" "ac-3 the audit log exists in the checkout"
assert_contains "$(cat "$tracked_log")" '| time | event | detail | result | link |' \
  "ac-3 the checked-out file carries the fixed header row"
assert_contains "$(cat "$tracked_log")" '| --- | --- | --- | --- | --- |' \
  "ac-3 ... and its divider, so the first append lands in a table"
assert_eq "$(grep -c '^| 20' "$tracked_log" || true)" "0" \
  "ac-3 the checked-out file carries no invented event row: the log starts empty"
assert_contains "$(cat "$tracked_log")" "upstream" \
  "ac-3 the checked-out file explains the four events a reader will find"

# git_ignore_rule <path>: the ignore rule that swallows <path>, or "not-ignored". `--no-index`
# asks the rule set instead of the index, which matters: a tracked file is exempt from the
# ignore rules, so without the flag `.github/keepalive.log` would pass this check even with a
# `*.log` rule in .gitignore. The verdict comes from `-q`, not from `-v`: `-v` exits 0 as soon
# as a rule matches, including a `!` rule, which is the pattern that un-ignores the path and
# therefore the answer "not ignored" - only `-q` (1 there) can tell the two apart. `-v` is run
# afterwards for the rule text, which is the diagnosis a failure needs.
git_ignore_rule() {
  local rule status
  git -C "$root" check-ignore -q --no-index -- "$1" >/dev/null 2>&1
  status=$?
  case "$status" in
    0)
      rule="$(git -C "$root" check-ignore -v --no-index -- "$1" 2>/dev/null)"
      printf 'ignored by %s' "${rule:-an unnamed rule}"
      ;;
    1) printf 'not-ignored' ;;
    *) printf 'git check-ignore failed (exit %s)' "$status" ;;
  esac
}

# git_index_state <path>: what the index knows about <path>.
#   staged     `git ls-files` finds it, so a commit would carry it
#   committed  HEAD has it and the index does not: a staged deletion, not a new file
#   new        neither: a file this working tree has not added yet
git_index_state() {
  if git -C "$root" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; then
    printf 'staged'
  elif git -C "$root" cat-file -e "HEAD:$1" 2>/dev/null; then
    printf 'committed'
  else
    printf 'new'
  fi
}

# assert_indexed <path> <what>: the half of "tracked" that this file is named after.
# `git ls-files --error-unmatch` exits non-zero for a path git does not track, which is
# exactly the answer the old `assert_file_exists` could not give.
assert_indexed() {
  local path=$1 what=$2 state
  state="$(git_index_state "$path")"
  case "$state" in
    staged)
      # The ok line only: reaching this branch already means `git ls-files` matched.
      assert_eq "in the index" "in the index" \
        "ac-3 ${what} is tracked: git ls-files --error-unmatch finds it in the index"
      ;;
    committed)
      assert_eq "$state" "staged" \
        "ac-3 ${what} is in HEAD but no longer in the index: the next commit would delete it"
      ;;
    *)
      printf 'skip: %s is not in the index yet; the file is new in this checkout and no commit carries it to compare against\n' \
        "$path"
      ;;
  esac
}

# A source tarball is not a git work tree; say so rather than turning the missing index into a
# failure of the code under test. `-C "$root"` because the test may be started from anywhere.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  assert_eq "$(git_ignore_rule .github/automation-log.md)" "not-ignored" \
    "ac-3 no ignore rule swallows .github/automation-log.md, so git add accepts it"
  assert_eq "$(git_ignore_rule .github/keepalive.log)" "not-ignored" \
    "ac-3 ... and none swallows the keepalive log either: both record files can be committed"
  assert_indexed .github/automation-log.md "the audit log"
  assert_indexed .github/keepalive.log "the keepalive log"
else
  printf 'skip: %s is not inside a git work tree; the index and the ignore rules were not checked\n' \
    "$root"
fi

finish
