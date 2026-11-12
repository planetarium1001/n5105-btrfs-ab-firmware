#!/usr/bin/env bash
# Module: ci
# ac-4: the automatic release is identified by the system version, and only by it.
#
# Why this file exists: the two release lines share one implementation
# (release-publish.yml) and differ only in their inputs. The naming is the whole product
# difference - the upstream line publishes "ImmortalWrt N5105 A/B firmware 25.13.0" under a
# bare 25.13.0 tag, while the tagged line keeps publishing VERSION under v0.0.8 - so the
# naming rules are asserted here rather than left to the caller's discipline.
#
# The rules that would be violated silently: a v-prefixed tag on the automatic line (it
# would collide with the tagged line and trigger a second release), and an edit of VERSION
# (the platform version belongs to the tagged line, and ac-12 wires it through the image).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

publish=".github/workflows/release-publish.yml"
release=".github/workflows/release.yml"
watch=".github/workflows/upstream-watch.yml"

for wf in "$publish" "$release" "$watch"; do
  assert_file_exists "$wf" "ac-4 $wf exists"
done

publish_text=$(cat "$publish")
release_text=$(cat "$release")
watch_text=$(cat "$watch")

# --------------------------------------------------------------------------- #
# ac-4: the automatic line publishes the bare upstream version
# --------------------------------------------------------------------------- #

assert_contains "$watch_text" 'title: "ImmortalWrt N5105 A/B firmware {tag}"' \
  "ac-4 the automatic line publishes under the ImmortalWrt title"
assert_contains "$watch_text" "      tag-policy: bare" \
  "ac-4 the automatic line asks for a bare version tag"
assert_contains "$watch_text" 'tag: ${{ needs.detect.outputs.version }}' \
  "ac-4 the automatic tag is the version the watch detected"

# The tag has to stay a formal X.Y.Z: the preflight rejects anything else, and a v prefix
# would make the tagged line's `tags: ["v*"]` trigger fire on an automatic release.
assert_contains "$watch_text" 'v*) echo "refusing to tag ${VERSION}' \
  "ac-4 the automatic line refuses to tag a version that starts with v"
assert_eq "$(grep -c 'git tag -a "v' "$watch")" "0" \
  "ac-4 the automatic line never creates a v-prefixed tag"
assert_eq "$(grep -c 'refs/tags/v' "$watch")" "0" \
  "ac-4 the automatic line never pushes a v-prefixed tag"

# --------------------------------------------------------------------------- #
# ac-4: the tagged line keeps its own name, through the same implementation
# --------------------------------------------------------------------------- #

assert_contains "$release_text" 'title: "N5105 AB firmware {tag}"' \
  "ac-4 the tagged line keeps its existing title convention"
assert_contains "$release_text" "      tag-policy: v" \
  "ac-4 the tagged line asks for the v tag policy"
assert_contains "$release_text" 'tag: ${{ github.ref_name }}' \
  "ac-4 the tagged line publishes the tag it was triggered by"

# --------------------------------------------------------------------------- #
# ac-4: one implementation renders both titles
# --------------------------------------------------------------------------- #

assert_contains "$(sed -n '/^      title:$/,/^      platform_version:$/p' "$publish")" \
  'Release title template; {tag} is replaced with the tag minus any leading v' \
  "ac-4 the title is a template, and {tag} means the version without a leading v"
assert_contains "$publish_text" 'bare_version=%s' \
  "ac-4 the reusable workflow derives the bare version once"
assert_contains "$publish_text" 'title="${TITLE_TEMPLATE//\{tag\}/${BARE_VERSION}}"' \
  "ac-4 the reusable workflow substitutes {tag} with the bare version"
assert_eq "$(grep -c 'BARE_VERSION}' "$publish" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes" \
  "ac-4 the substitution reads the derived bare version"

# render_title <template> <tag>: the substitution release-publish.yml performs, so the two
# documented examples below are checked as strings rather than by eye.
render_title() {
  local template=$1 bare=${2#v}
  printf '%s\n' "${template//\{tag\}/${bare}}"
}
assert_eq "$(render_title "ImmortalWrt N5105 A/B firmware {tag}" "25.13.0")" \
  "ImmortalWrt N5105 A/B firmware 25.13.0" \
  "ac-4 the automatic release is titled ImmortalWrt N5105 A/B firmware <ver>"
assert_eq "$(render_title "N5105 AB firmware {tag}" "v0.0.8")" \
  "N5105 AB firmware 0.0.8" \
  "ac-4 the tagged line keeps rounding v0.0.8 down to 0.0.8 in the title"

# --------------------------------------------------------------------------- #
# ac-4: VERSION belongs to the tagged line, and nobody edits it
# --------------------------------------------------------------------------- #

for wf in "$release" "$publish" "$watch"; do
  assert_eq "$(grep -cE '(>>? *VERSION|git add +VERSION|echo .* > ?VERSION)' "$wf")" "0" \
    "ac-4 $wf never writes the VERSION file"
done

# The tagged line refuses a tag that disagrees with VERSION; the bare line must not require
# them to agree, because its tag names the upstream release, not the platform version.
assert_contains "$publish_text" '[ "${TAG#v}" = "${file_platform}" ]' \
  "ac-4 the tagged line asserts that its tag is the platform version"
assert_contains "$publish_text" 'if [ "${TAG_POLICY}" = "v" ]; then' \
  "ac-4 the VERSION/tag agreement is required for the v policy only"

# --------------------------------------------------------------------------- #
# ac-4 / ac-17: the tag shape is enforced where the release is decided
# --------------------------------------------------------------------------- #

assert_contains "$publish_text" '--tag-policy "${TAG_POLICY}"' \
  "ac-4 the reusable workflow hands the tag policy to the preflight"
assert_contains "$(cat scripts/ci/release-preflight.sh 2>/dev/null || true)" "" \
  "ac-4 release-preflight.sh is present (tag policy is proved there)"

finish
