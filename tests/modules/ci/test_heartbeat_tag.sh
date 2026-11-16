#!/usr/bin/env bash
# Module: ci
# Guards scripts/ci/heartbeat-tag.sh: the tag that keeps the scheduled upstream watch
# alive.
#
# GitHub disables a scheduled workflow in a public repository after 60 days without
# activity, and the auto-release workflow is idle whenever upstream is idle. The
# heartbeat is the monthly activity that keeps the schedule enabled, so three things have
# to hold: it fires when it is due (including the very first time), it never fires twice
# in the same month, and its name never matches `v*` - `v*` is the release trigger, so a
# heartbeat with that prefix would publish a firmware release built from nothing.
#
# Every case runs in its own throw-away repository: `git tag -a` dates come from
# GIT_COMMITTER_DATE, so the "40 days" and "60 days" cases are real git state, not a mock.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/heartbeat-tag.sh"

# new_repo <dir> <commit-date>: an empty repository with one commit at that date.
new_repo() {
  local dir=$1 date=$2
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.name "ci test"
  git -C "$dir" config user.email "ci@example.test"
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$dir" commit -q --allow-empty -m "base ${date}"
}

# dated_tag <dir> <tag> <date>: an annotated tag whose tagger date is <date>.
dated_tag() {
  local dir=$1 tag=$2 date=$3
  GIT_COMMITTER_DATE="$date" git -C "$dir" tag -a "$tag" -m "tag ${tag} at ${date}"
}

# tag_run <repo> <output-env-file> [arguments...]
tag_run() {
  local repo=$1 out=$2
  shift 2
  tag_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out" \
    CI_TMP_ROOT="$tmp/ci" CI_REPO_ROOT="$repo" bash "$SCRIPT" "$@" 2>&1)"
  tag_status=$?
}

# output_of <output-env-file> <key>
output_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# --------------------------------------------------------------------------- #
# ac-5: the first heartbeat is due, and a dry run proves it without tagging
# --------------------------------------------------------------------------- #

fresh="$tmp/fresh"
new_repo "$fresh" "2026-08-13T00:00:00Z"

tag_run "$fresh" "$tmp/o-first-dry.env" --now 2026-10-12 --dry-run
assert_eq "$tag_status" "0" "ac-5 a repository without any tag is due and exits 0"
assert_eq "$(output_of "$tmp/o-first-dry.env" action)" "would-create" \
  "ac-5 --dry-run reports would-create instead of tagging"
assert_eq "$(output_of "$tmp/o-first-dry.env" tag)" "heartbeat-202610" \
  "ac-5 the tag name is heartbeat- plus the year and month of --now"
assert_eq "$(output_of "$tmp/o-first-dry.env" reason)" "first-heartbeat" \
  "ac-5 a repository with no baseline is due for its first heartbeat"
assert_eq "$(git -C "$fresh" tag -l | wc -l | tr -d ' ')" "0" \
  "ac-5 --dry-run creates no tag"

tag_run "$fresh" "$tmp/o-first.env" --now 2026-10-12
assert_eq "$tag_status" "0" "ac-5 the first heartbeat is created"
assert_eq "$(output_of "$tmp/o-first.env" action)" "created" "ac-5 a due heartbeat is created"
assert_contains "$tag_log" "created annotated tag heartbeat-202610" \
  "ac-5 the run log names the tag it created"
assert_eq "$(git -C "$fresh" tag -l heartbeat-202610)" "heartbeat-202610" \
  "ac-5 the created tag is named heartbeat-<year><month>"
assert_eq "$(git -C "$fresh" cat-file -t heartbeat-202610)" "tag" \
  "ac-5 the heartbeat is an annotated tag"

# --------------------------------------------------------------------------- #
# ac-5: a heartbeat younger than 50 days is not due
# --------------------------------------------------------------------------- #

recent="$tmp/recent"
new_repo "$recent" "2026-08-13T00:00:00Z"
dated_tag "$recent" "heartbeat-202609" "2026-09-02T00:00:00Z"

tag_run "$recent" "$tmp/o-recent.env" --now 2026-10-12
assert_eq "$tag_status" "0" "ac-5 a heartbeat that is too young still exits 0"
assert_eq "$(output_of "$tmp/o-recent.env" action)" "skipped" \
  "ac-5 a heartbeat 40 days old is not due yet"
assert_eq "$(output_of "$tmp/o-recent.env" days_since)" "40" \
  "ac-5 days_since counts from the heartbeats tagger date"
assert_eq "$(output_of "$tmp/o-recent.env" reason)" "too-soon" \
  "ac-5 the skip reason names the interval"
assert_eq "$(git -C "$recent" tag -l | wc -l | tr -d ' ')" "1" \
  "ac-5 a skipped heartbeat creates no tag"

# --------------------------------------------------------------------------- #
# ac-5: 50 days and more is due
# --------------------------------------------------------------------------- #

due="$tmp/due"
new_repo "$due" "2026-08-13T00:00:00Z"
dated_tag "$due" "heartbeat-202608" "2026-08-13T00:00:00Z"

tag_run "$due" "$tmp/o-due.env" --now 2026-10-12
assert_eq "$tag_status" "0" "ac-5 a heartbeat 60 days old is created"
assert_eq "$(output_of "$tmp/o-due.env" action)" "created" \
  "ac-5 60 days without a heartbeat is due"
assert_eq "$(output_of "$tmp/o-due.env" tag)" "heartbeat-202610" \
  "ac-5 the new tag is named for the month of --now, not the previous one"
assert_eq "$(output_of "$tmp/o-due.env" days_since)" "60" \
  "ac-5 days_since reports the real gap"

edge="$tmp/edge"
new_repo "$edge" "2026-08-13T00:00:00Z"
dated_tag "$edge" "heartbeat-202608" "2026-08-23T00:00:00Z"
tag_run "$edge" "$tmp/o-edge.env" --now 2026-10-12
assert_eq "$(output_of "$tmp/o-edge.env" days_since)" "50" \
  "ac-5 the boundary case is exactly 50 days"
assert_eq "$(output_of "$tmp/o-edge.env" action)" "created" \
  "ac-5 50 days is due, not skipped"

# --------------------------------------------------------------------------- #
# ac-5: the same month is idempotent
# --------------------------------------------------------------------------- #

same="$tmp/same"
new_repo "$same" "2026-10-01T00:00:00Z"
dated_tag "$same" "heartbeat-202610" "2026-10-01T00:00:00Z"

tag_run "$same" "$tmp/o-same.env" --now 2026-10-12
assert_eq "$tag_status" "0" "ac-5 a second run in the same month exits 0"
assert_eq "$(output_of "$tmp/o-same.env" action)" "skipped" \
  "ac-5 the same month is not tagged twice"
assert_eq "$(output_of "$tmp/o-same.env" reason)" "already-tagged" \
  "ac-5 the idempotent skip says already-tagged"
assert_eq "$(git -C "$same" tag -l heartbeat-202610 | wc -l | tr -d ' ')" "1" \
  "ac-5 the existing tag is still the only one"

# --------------------------------------------------------------------------- #
# ac-5: a release, or a pin bump, is activity too
# --------------------------------------------------------------------------- #

released="$tmp/released"
new_repo "$released" "2026-08-13T00:00:00Z"
dated_tag "$released" "25.12.2" "2026-09-20T00:00:00Z"
tag_run "$released" "$tmp/o-released.env" --now 2026-10-12
assert_eq "$(output_of "$tmp/o-released.env" days_since)" "22" \
  "ac-5 a bare version tag counts as the baseline"
assert_eq "$(output_of "$tmp/o-released.env" action)" "skipped" \
  "ac-5 a recent release makes the heartbeat unnecessary"

# ac-4: the tags this repository actually publishes are `v*` (v0.0.1 ... v0.0.11), so a
# release tag that only the bare spelling matched was never a baseline at all: every gap
# fell through to "no activity" and the heartbeat fired as if it were the first one.
released_v="$tmp/released-v"
new_repo "$released_v" "2026-08-13T00:00:00Z"
dated_tag "$released_v" "v0.0.10" "2026-09-20T00:00:00Z"
tag_run "$released_v" "$tmp/o-released-v.env" --now 2026-10-12
assert_eq "$tag_status" "0" "ac-4 a repository whose only tag is v0.0.10 exits 0"
assert_eq "$(output_of "$tmp/o-released-v.env" days_since)" "22" \
  "ac-4 a v-prefixed release tag is the baseline, measured from the tag's own date"
assert_eq "$(output_of "$tmp/o-released-v.env" reason)" "too-soon" \
  "ac-4 the v* baseline makes the heartbeat not due, instead of a first-heartbeat"
assert_eq "$(output_of "$tmp/o-released-v.env" action)" "skipped" \
  "ac-4 a release 22 days ago makes the heartbeat unnecessary"
assert_contains "$tag_log" "release tag v0.0.10" \
  "ac-4 the log names the v* release tag it judged against"

# The other half of ac-4: the same v* tag, old enough, is due *because of the tag*. A
# repository with no recognisable baseline reports `first-heartbeat` instead, so the reason
# is what proves the tag was read rather than ignored.
released_v_old="$tmp/released-v-old"
new_repo "$released_v_old" "2026-01-05T00:00:00Z"
dated_tag "$released_v_old" "v0.0.3" "2026-07-01T00:00:00Z"
tag_run "$released_v_old" "$tmp/o-released-v-old.env" --now 2026-10-12
assert_eq "$(output_of "$tmp/o-released-v-old.env" days_since)" "103" \
  "ac-4 the gap is measured from the v* release tag, not from the beginning of history"
assert_eq "$(output_of "$tmp/o-released-v-old.env" reason)" "due" \
  "ac-4 a v* release 103 days old is due, not a first heartbeat"
assert_eq "$(output_of "$tmp/o-released-v-old.env" action)" "created" \
  "ac-4 the due heartbeat of a v*-released repository is created"

pinned="$tmp/pinned"
new_repo "$pinned" "2026-08-13T00:00:00Z"
mkdir -p "$pinned/.github"
printf 'UPSTREAM_VERSION=25.12.2\n' >"$pinned/.github/upstream-pin.conf"
git -C "$pinned" add .github/upstream-pin.conf
GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" GIT_COMMITTER_DATE="2026-10-01T00:00:00Z" \
  git -C "$pinned" commit -q -m "pin 25.12.2"
tag_run "$pinned" "$tmp/o-pinned.env" --now 2026-10-12
assert_eq "$(output_of "$tmp/o-pinned.env" days_since)" "11" \
  "ac-5 the last commit touching the pin counts as the baseline"
assert_eq "$(output_of "$tmp/o-pinned.env" action)" "skipped" \
  "ac-5 a recent pin bump makes the heartbeat unnecessary"

# --------------------------------------------------------------------------- #
# ac-1: what a shallow clone sees, and why the workflow fetches depth and tags
# --------------------------------------------------------------------------- #
#
# The decision is "the newest activity this checkout can see", so `fetch-depth: 1` changes
# the answer instead of only making it faster: the commit that last touched the pin becomes
# the shallow root and its age reads as zero. The two cases below are real clones over
# file:// (no network) and pin both halves: a shallow clone of a genuinely quiet repository
# still fires, and a shallow clone of an active one silently answers too-soon while the
# deep clone of the same repository is due.

# clone_of <src> <dst> [--depth N]: a local clone, so the fixture needs no network.
clone_of() {
  local src=$1 dst=$2
  shift 2
  git clone -q "$@" "file://${src}" "$dst"
}

# quiet: the tip IS the commit that last touched the pin, and it is old.
quiet="$tmp/quiet"
new_repo "$quiet" "2026-01-05T00:00:00Z"
mkdir -p "$quiet/.github"
printf 'UPSTREAM_VERSION=25.12.2\n' >"$quiet/.github/upstream-pin.conf"
git -C "$quiet" add .github/upstream-pin.conf
GIT_AUTHOR_DATE="2026-01-05T00:00:00Z" GIT_COMMITTER_DATE="2026-01-05T00:00:00Z" \
  git -C "$quiet" commit -q -m "pin 25.12.2"
clone_of "$quiet" "$tmp/quiet-shallow" --depth 1
assert_eq "$(git -C "$tmp/quiet-shallow" rev-parse --is-shallow-repository)" "true" \
  "ac-1 the fixture really is a shallow clone"
assert_eq "$(git -C "$tmp/quiet-shallow" tag -l | wc -l | tr -d ' ')" "0" \
  "ac-1 a depth-1 clone carries no tags"
tag_run "$tmp/quiet-shallow" "$tmp/o-quiet-shallow.env" --now 2026-11-15 --dry-run
assert_eq "$tag_status" "0" "ac-1 a shallow clone of a quiet repository still exits 0"
assert_eq "$(output_of "$tmp/o-quiet-shallow.env" shallow)" "true" \
  "ac-1 the script reports that it judged a shallow clone"
assert_eq "$(output_of "$tmp/o-quiet-shallow.env" action)" "would-create" \
  "ac-1 a quiet repository is due even in a shallow clone"
assert_eq "$(output_of "$tmp/o-quiet-shallow.env" reason)" "due" \
  "ac-1 the shallow answer is due because the visible activity is genuinely old"

# active: an unrelated recent commit hides an old pin bump from a depth-1 clone.
active="$tmp/active"
new_repo "$active" "2026-01-05T00:00:00Z"
mkdir -p "$active/.github"
printf 'UPSTREAM_VERSION=25.12.2\n' >"$active/.github/upstream-pin.conf"
git -C "$active" add .github/upstream-pin.conf
GIT_AUTHOR_DATE="2026-01-05T00:00:00Z" GIT_COMMITTER_DATE="2026-01-05T00:00:00Z" \
  git -C "$active" commit -q -m "pin 25.12.2"
printf 'a later, unrelated change\n' >"$active/unrelated.txt"
git -C "$active" add unrelated.txt
GIT_AUTHOR_DATE="2026-11-14T00:00:00Z" GIT_COMMITTER_DATE="2026-11-14T00:00:00Z" \
  git -C "$active" commit -q -m "unrelated recent commit"
clone_of "$active" "$tmp/active-shallow" --depth 1
tag_run "$tmp/active-shallow" "$tmp/o-active-shallow.env" --now 2026-11-15 --dry-run
assert_eq "$(output_of "$tmp/o-active-shallow.env" action)" "skipped" \
  "ac-1 a depth-1 clone answers too-soon: the pin bump is its own root"
assert_eq "$(output_of "$tmp/o-active-shallow.env" reason)" "too-soon" \
  "ac-1 the wrong answer names the reason the workflow has to fetch history"
assert_contains "$tag_log" "shallow clone" \
  "ac-1 the skip says out loud that the checkout was shallow"

# The control: the same repository, cloned deeply, is due. This is the behaviour the
# workflow's fetch-depth/fetch-tags makes reachable; the assertion is on the clone, not on
# a mock, so it fails if git ever changes what `--depth 1` hides.
clone_of "$active" "$tmp/active-deep"
assert_eq "$(git -C "$tmp/active-deep" rev-parse --is-shallow-repository)" "false" \
  "ac-1 the control clone is complete"
tag_run "$tmp/active-deep" "$tmp/o-active-deep.env" --now 2026-11-15 --dry-run
assert_eq "$(output_of "$tmp/o-active-deep.env" shallow)" "false" \
  "ac-1 a complete clone is reported as such"
assert_eq "$(output_of "$tmp/o-active-deep.env" action)" "would-create" \
  "ac-1 the deep clone of the same repository is due"
assert_eq "$(output_of "$tmp/o-active-deep.env" reason)" "due" \
  "ac-1 the deep clone's baseline is the old pin bump"
assert_eq "$(output_of "$tmp/o-active-deep.env" days_since)" "314" \
  "ac-1 the deep clone measures the real gap from the pin commit"

# The workflow, not the script, is where the shallow case is fixed: the script reports what
# it saw, and the detect job is the one that has to hand it tags and history.
WORKFLOW="$root/.github/workflows/upstream-watch.yml"
detect_block=$(awk '/^  detect:$/ { flag = 1 } flag && /^  [a-z-]+:$/ && !/^  detect:$/ { exit } flag' "$WORKFLOW")
assert_contains "$detect_block" "fetch-tags: true" \
  "ac-1 the detect job fetches tags, without which the heartbeat baseline is empty"
assert_contains "$detect_block" "fetch-depth: 0" \
  "ac-5 the detect job fetches the full history, so the pin commit has a real age"
assert_eq "$(grep -c 'fetch-depth: 50' "$WORKFLOW" || true)" "0" \
  "ac-5 the workflow no longer declares the empirical depth 50"


assert_eq "$(git -C "$due" tag -l 'v*' | wc -l | tr -d ' ')" "0" \
  "ac-5 no tag in the repository matches v*"
assert_eq "$(git -C "$fresh" tag -l 'v*' | wc -l | tr -d ' ')" "0" \
  "ac-5 the first heartbeat is not a v* tag either"
assert_eq "$(git -C "$due" tag -l | grep -c '^v' || true)" "0" \
  "ac-5 git tag -l output has no v-prefixed name at all"

assert_contains "$(cat "$SCRIPT")" 'grep -Eq' "ac-5 the script asserts the tag name it builds"
assert_contains "$(cat "$SCRIPT")" '^v' "ac-5 the assertion is about the v prefix"
assert_eq "$(grep -c 'git push' "$SCRIPT")" "0" \
  "ac-5 the script never pushes: the workflow decides that"

tag_run "$due" "$tmp/o-unknown.env" --tomorrow
assert_eq "$tag_status" "1" "ac-5 an unknown argument is refused"

finish
