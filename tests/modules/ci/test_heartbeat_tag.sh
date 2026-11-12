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
# ac-5: the name never matches ^v, and the script never pushes
# --------------------------------------------------------------------------- #

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
