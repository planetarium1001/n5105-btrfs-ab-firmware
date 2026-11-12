#!/usr/bin/env bash
# Module: ci
# Guards the one number a release cannot get wrong: the platform version.
#
# History: `VERSION` said 0.0.7 while the pipeline never passed it down. assemble.sh fell
# back to 0.0.5, disk.sh to 0.0.1, and the debug entry point hardcoded 0.0.2, so an image
# could carry three different answers to "which firmware is this". The release check that
# compares the image, the payload manifest and the tag could never have matched.
#
# The contract asserted here:
#   * VERSION is the only source, and it is a formal X.Y.Z
#   * ci.yml reads it in one job and passes the value to every stage that records it
#   * no workflow and no stage script carries a 0.0.x literal or fallback any more
#   * a stage run without CI_PLATFORM_VERSION fails instead of inventing one
#   * the value ends up in ab/image.json, which is what the image is judged by
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# assert_ok <message> <command...>: turn a boolean fact into one numbered assertion.
assert_ok() {
  local message="$1"; shift
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if "$@"; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "condition is false"
  fi
}

version_file="$root/VERSION"
assemble="$root/scripts/ci/assemble.sh"
disk="$root/scripts/ci/disk.sh"
ci_yml="$root/.github/workflows/ci.yml"

# --------------------------------------------------------------------------- #
# ac-12: one source, read once, passed everywhere
# --------------------------------------------------------------------------- #

version="$(tr -d '[:space:]' <"$version_file")"
assert_matches "$version" '^[0-9]+\.[0-9]+\.[0-9]+$' \
  "ac-12 VERSION is a formal X.Y.Z release label"

assert_contains "$(cat "$ci_yml")" 'versions:' \
  "ac-12 ci.yml has one job that reads the platform version"
assert_contains "$(cat "$ci_yml")" '< VERSION' \
  "ac-12 that job reads VERSION from the tree"
assert_contains "$(cat "$ci_yml")" 'platform_version: ${{ steps.read.outputs.platform_version }}' \
  "ac-12 the job publishes the value it read"

# Every stage that records the platform version has to receive it: the payload release
# file (assemble) and the four stages that build or boot an image (S2..S5).
for job in assemble s2 s3 s4 s5; do
  block=$(awk -v want="$job" '
    /^  [A-Za-z0-9_-]+:$/ { name = $1; sub(":$", "", name); inside = (name == want); next }
    inside { print }
  ' "$ci_yml")
  assert_contains "$block" 'platform_version: ${{ needs.versions.outputs.platform_version }}' \
    "ac-12 the $job stage receives the platform version from ci.yml"
  assert_contains "$block" 'versions' \
    "ac-12 the $job stage waits for the version job"
done

# --------------------------------------------------------------------------- #
# ac-12: no fallback, no hardcoded 0.0.x anywhere in the pipeline
# --------------------------------------------------------------------------- #

for wf in "$root"/.github/workflows/ci*.yml; do
  assert_eq "$(grep -cE '0\.0\.[0-9]' "$wf")" "0" \
    "ac-12 $(basename "$wf") carries no hardcoded platform version"
done

for script in "$assemble" "$disk"; do
  assert_eq "$(grep -c ':-0\.0\.' "$script")" "0" \
    "ac-12 $(basename "$script") has no platform version fallback"
  assert_contains "$(cat "$script")" 'CI_PLATFORM_VERSION:?' \
    "ac-12 $(basename "$script") requires CI_PLATFORM_VERSION"
done

# --------------------------------------------------------------------------- #
# ac-12: a stage run without the value fails instead of inventing one
# --------------------------------------------------------------------------- #

missing=$(env -u CI_PLATFORM_VERSION \
  CI_UPSTREAM_VERSION=25.12.2 \
  CI_KERNEL_PACKAGE=test \
  CI_ESP_DIR="$tmp/esp" \
  CI_INITRAMFS="$tmp/initramfs.cpio.gz" \
  bash "$assemble" 2>&1)
status=$?
assert_ok "ac-12 assemble.sh fails without CI_PLATFORM_VERSION" test "$status" -ne 0
assert_contains "$missing" 'CI_PLATFORM_VERSION is required' \
  "ac-12 the failure names the missing platform version"

# disk.sh refuses to run without the loop/partition tooling at all, so this one is only
# measurable where that tooling exists (the CI runner). The static contract above still
# holds everywhere.
if command -v losetup >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1; then
  missing_disk=$(env -u CI_PLATFORM_VERSION \
    CI_UPSTREAM_VERSION=25.12.2 \
    CI_ESP_DIR="$tmp/esp" \
    CI_INITRAMFS="$tmp/initramfs.cpio.gz" \
    CI_ALLOW_PROBE_INIT=0 \
    bash "$disk" 2>&1)
  status=$?
  assert_ok "ac-12 disk.sh fails without CI_PLATFORM_VERSION" test "$status" -ne 0
  assert_contains "$missing_disk" 'CI_PLATFORM_VERSION is required' \
    "ac-12 the disk failure names the missing platform version"
else
  printf '# losetup/sfdisk missing here; the disk.sh behaviour is covered by the CI verify stage\n'
fi

# --------------------------------------------------------------------------- #
# ac-12: the value is what the image says about itself
#
# ab/image.json is the record the release refuses to publish unless it agrees with the
# tag; ii_image_json is the only writer of that record.
# --------------------------------------------------------------------------- #

# shellcheck source=scripts/ci/image-identity.sh
. "$root/scripts/ci/image-identity.sh"
image_json=$(ii_image_json boot init "$version" 25.12.2 2026-11-12T00:00:00Z)
assert_contains "$image_json" "\"platform_version\": \"$version\"" \
  "ac-12 ab/image.json records the platform version it was given"
assert_contains "$(cat "$disk")" 'ii_image_json "${initramfs_kind}"' \
  "ac-12 disk.sh writes ab/image.json from the platform version variable"
assert_contains "$(cat "$assemble")" '"platform": platform_version' \
  "ac-12 the payload manifest records the same value"

finish
