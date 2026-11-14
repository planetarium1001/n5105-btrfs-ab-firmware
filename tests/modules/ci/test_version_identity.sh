#!/usr/bin/env bash
# Module: ci
# The version a build ships is the version the source tree says, and nothing else.
#
# The 2026-11-14 real-device run found a tag (`v0.0.9-rc1`) whose image reported
# `PLATFORM_VERSION=0.0.8`, which made `--feed-check` compare against a number that was not
# the one that had been published. This test pins the one chain that must stay closed:
#
#   VERSION  ->  ci_render_release  ->  <layer>/etc/platform-release  ->  ab-slot --version
#
#   ac-17 VERSION is one MAJOR.MINOR.PATCH line and the renderer copies it verbatim
#   ac-17 every file this project renders the identity into comes from that one value
#   ac-17 the prose (README) states the same version, so a release note cannot lag behind
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

version_file="$root/VERSION"
assert_file_exists "$version_file" "ac-17 the VERSION file exists"

version=$(tr -d ' \t\r\n' <"$version_file")
assert_matches "$version" '^[0-9]+\.[0-9]+\.[0-9]+$' \
  "ac-17 VERSION is MAJOR.MINOR.PATCH ($version)"

# The renderer is the only writer of platform-release; it takes the version as an argument,
# so the caller's value is what the image will report.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
render="$tmp/platform-release"
# ci_render_release rewrites a file that is already there: the template is copied into the
# staged layer first, exactly as assemble.sh / disk.sh / payload-build.sh do it.
cp "$root/platform/etc/platform-release" "$render"
# shellcheck source=scripts/ci/lib.sh
. "$root/scripts/ci/lib.sh"
ci_render_release "$render" "$version" "25.12.2" "image" >/dev/null 2>&1
assert_file_exists "$render" "ac-17 ci_render_release writes the identity file"
assert_contains "$(cat "$render")" "PLATFORM_VERSION=${version}" \
  "ac-17 the rendered identity carries the VERSION value"
if grep -Eq '@[A-Z_][A-Z0-9_]*@' "$render"; then
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  _assert_fail "ac-17 the rendered identity has no placeholders" "$(cat "$render")"
else
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - ac-17 the rendered identity has no placeholders\n' "$_ASSERT_COUNT"
fi

# Every producer of a platform layer passes the same value: the three call sites read VERSION
# rather than a literal, which is what kept 0.0.8 alive inside a 0.0.9-rc image.
for caller in scripts/ci/assemble.sh scripts/ci/disk.sh scripts/ci/payload-build.sh; do
  assert_contains "$(cat "$root/$caller")" 'VERSION' \
    "ac-17 ${caller} takes the platform version from VERSION"
done
assert_eq "$(grep -c '0\.0\.8' "$root/scripts/ci/assemble.sh" "$root/scripts/ci/disk.sh" "$root/scripts/ci/payload-build.sh" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')" "0" \
  "ac-17 no staging script hard codes an old platform version"

# The prose has to move with the number: a README that still announces 0.0.8 is how a
# release note and the image start disagreeing.
for readme in README.md README.zh-CN.md; do
  assert_contains "$(cat "$root/$readme")" "${version}" \
    "ac-17 ${readme} states the current version"
  if grep -qE "0\.0\.(8|7|6)\b" "$root/$readme"; then
    # Older versions may be mentioned as history, but not as "current".
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    if grep -qE "Current version: \`${version}\`|当前版本：\`${version}\`" "$root/$readme"; then
      printf 'ok %d - ac-17 %s names %s as the current version\n' "$_ASSERT_COUNT" "$readme" "$version"
    else
      _assert_fail "ac-17 ${readme} names ${version} as the current version" "older versions are mentioned without a current one"
    fi
  fi
done

finish
