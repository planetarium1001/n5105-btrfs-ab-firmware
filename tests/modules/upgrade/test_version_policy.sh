#!/usr/bin/env bash
# Module: upgrade
# The version layer behind the update prompt: platform/lib/ab-version.sh.
#
# Three numbers describe an update and none of them may be inferred from another:
#   base      upstream ImmortalWrt release ("25.12.2") - rootfs and kernel come from it
#   kernel    kernel package version ("6.12.103") - moves with base, not necessarily
#   platform  this project's layer ("0.0.8") - ab-slot, ab-upgrade, initramfs, menu
#
# This test covers the parts that decide what the user is told:
#   ac-5  a version is X.Y.Z and nothing else
#   ac-5  comparison is numeric per segment, so 0.0.10 > 0.0.9
#   ac-5  the delta names major/minor/patch and how large it is
#   ac-5  the level is Z1 (patch <= 3), Z2 (patch > 3), Y1 (one minor), Y2 (more),
#         X1 (any major), plus the two states that are not an update at all
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-version.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the version library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi
# shellcheck source=platform/lib/ab-version.sh
. "$lib"

# --- ac-5: shape ------------------------------------------------------------
# Two local wrappers keep the assertion counter honest: assert.sh only counts when the
# helper itself reports, and a bare `if` in the test would not.
assert_ok() {
  local message=$1
  shift
  if "$@" >/dev/null 2>&1; then
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    _ASSERT_FAILURES=$((_ASSERT_FAILURES + 1))
    printf 'not ok %d - %s\n' "$_ASSERT_COUNT" "$message" >&2
  fi
}

assert_not_ok() {
  local message=$1
  shift
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if "$@" >/dev/null 2>&1; then
    _ASSERT_FAILURES=$((_ASSERT_FAILURES + 1))
    printf 'not ok %d - %s\n' "$_ASSERT_COUNT" "$message" >&2
  else
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  fi
}

for v in 0.0.8 25.12.2 1.0.0 10.20.30; do
  assert_ok "$v is a version" ab_version_valid "$v"
done
for v in "" 0.0 1.2.3.4 0.0.8-r1 v0.0.8 0.0.x 25.12.SNAPSHOT 1..3; do
  assert_not_ok "$v is refused" ab_version_valid "$v"
done

# --- ac-5: comparison is numeric, not lexical -------------------------------
assert_eq "$(ab_version_cmp 0.0.9 0.0.10)" "-1" "0.0.9 sorts before 0.0.10"
assert_eq "$(ab_version_cmp 0.0.10 0.0.9)" "1" "0.0.10 sorts after 0.0.9"
assert_eq "$(ab_version_cmp 25.12.2 25.12.2)" "0" "identical versions compare equal"
assert_eq "$(ab_version_cmp 26.0.0 25.12.9)" "1" "a new major outranks the old line"
assert_eq "$(ab_version_cmp 25.12.2 25.13.0)" "-1" "a new minor outranks the old line"
assert_eq "$(ab_version_cmp 010.02.3 10.2.3)" "0" "leading zeroes do not change the value"

# --- ac-5: delta ------------------------------------------------------------
assert_eq "$(ab_version_delta 25.12.2 25.12.5)" "patch 3" "three patch releases"
assert_eq "$(ab_version_delta 25.12.2 25.18.2)" "minor 6" "six release lines"
assert_eq "$(ab_version_delta 25.12.2 26.0.0)" "major 1" "one major line"
assert_eq "$(ab_version_delta 25.12.2 25.12.2)" "none" "no change at all"

# --- ac-5: level ------------------------------------------------------------
assert_eq "$(ab_version_level 25.12.2 25.12.5)" "Z1" "three patch releases are Z1"
assert_eq "$(ab_version_level 25.12.2 25.12.2)" "current" "identical versions are current"
assert_eq "$(ab_version_level 25.12.9 25.12.2)" "downgrade" "an older base is a downgrade"
assert_eq "$(ab_version_level 25.12.2 25.12.9)" "Z2" "seven patch releases are Z2"
assert_eq "$(ab_version_level 25.12.2 25.13.0)" "Y1" "one release line forward is Y1"
assert_eq "$(ab_version_level 25.12.2 26.0.0)" "X1" "a new major is X1"
assert_eq "$(ab_version_level 25.12.2 26.2.0)" "X1" "a major always outranks the minor delta"
assert_eq "$(ab_version_level 25.12.2 25.19.0)" "Y2" "several release lines forward are Y2"

# --- ac-5: invalid input is an error, not a guess ---------------------------
assert_not_ok "comparing a malformed version fails" ab_version_cmp 0.0.8 0.0
assert_not_ok "a malformed candidate cannot be levelled" ab_version_level 25.12.2 26

finish
