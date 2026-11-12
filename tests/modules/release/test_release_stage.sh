#!/usr/bin/env bash
# Module: release
# Verifies the release stage and the publishing rules.
#   ac-1 the stage produces the named artifacts, the checksums and the notes
#   ac-2 the file names follow n5105-ab-<upstream>-<role> and carry no firmware version
#   ac-3 a damaged artifact is refused instead of published
#   ac-4 publishing is a tag action, main validates but never publishes
#   ac-5 the install documentation exists in both languages with the same sections
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# macOS has shasum only; the target and CI both have sha256sum.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sha256sum" <<'STUB'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  exec shasum -a 256
fi
for f in "$@"; do shasum -a 256 "$f"; done
STUB
chmod +x "$tmp/bin/sha256sum"

image="$tmp/build.img"
head -c 262144 /dev/urandom >"$image"
payload="$tmp/payload.tar"
printf 'not really a payload\n' >"$payload"

run_release() {
  env PATH="$tmp/bin:$PATH" CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" "$@" \
    bash scripts/ci/release.sh 2>&1
}

# --- ac-1 and ac-2 ----------------------------------------------------------
out="$(run_release CI_IMAGE="$image" CI_PAYLOAD="$payload" CI_PLATFORM_VERSION=0.0.5 \
  CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.5)"
assert_eq "$?" "0" "ac-1 the release stage succeeds"
rel="$tmp/ci/release"
assert_file_exists "$rel/n5105-ab-25.12.2-install.img.gz" "ac-2 the image is named upstream-then-role"
assert_file_exists "$rel/n5105-ab-25.12.2-upgrade.tar" "ac-2 the payload follows the same name"
versioned="$(find "$rel" -maxdepth 1 -name '*0.0.5*' -print)"
assert_eq "${versioned}" "" "ac-2 no release file name carries our own firmware version"
assert_file_exists "$rel/SHA256SUMS" "ac-1 SHA256SUMS is produced"
assert_file_exists "$rel/release-notes.md" "ac-1 release notes are produced"
assert_eq "$(wc -l <"$rel/SHA256SUMS" | tr -d ' ')" "2" "ac-1 both artifacts are covered by the checksums"

# the published image must decompress to exactly the built image
expected="$(shasum -a 256 "$image" | cut -d' ' -f1)"
actual="$(gzip -dc "$rel/n5105-ab-25.12.2-install.img.gz" | shasum -a 256 | cut -d' ' -f1)"
assert_eq "$actual" "$expected" "ac-1 the compressed image round-trips to the built image"
assert_contains "$out" "round trip verified" "ac-1 the round trip is reported"

notes="$(cat "$rel/release-notes.md")"
assert_contains "$notes" "N5105 AB firmware 0.0.5 (upstream 25.12.2)" "ac-1 the notes name both versions"
assert_contains "$notes" "ab-upgrade" "ac-1 the notes point at the update path"
assert_contains "$notes" "docs/install.md" "ac-1 the notes point at the install guide"
assert_contains "$notes" "$expected" "ac-1 the notes record the uncompressed digest"

# --- ac-3 refusals ---------------------------------------------------------
out="$(run_release CI_IMAGE="$tmp/missing.img" CI_PLATFORM_VERSION=0.0.5 \
  CI_UPSTREAM_VERSION=25.12.2)"
assert_eq "$?" "1" "ac-3 a missing image is refused"
assert_contains "$out" "image not found" "ac-3 the refusal names the cause"

# a truncated compressed image cannot round-trip to the raw digest
cp "$rel/n5105-ab-25.12.2-install.img.gz" "$tmp/truncated.img.gz"
head -c 100 "$tmp/truncated.img.gz" >"$tmp/cut.img.gz"
out="$(run_release CI_IMAGE_GZ="$tmp/cut.img.gz" CI_PLATFORM_VERSION=0.0.5 \
  CI_UPSTREAM_VERSION=25.12.2)"
assert_eq "$?" "1" "ac-3 a damaged compressed image is refused"

# --- ac-4 publishing rules -------------------------------------------------
release_yml="$(cat .github/workflows/release.yml)"
publish_yml="$(cat .github/workflows/release-publish.yml)"
assert_contains "$release_yml" 'tags: ["v*"]' "ac-4 releases trigger on tags"
assert_contains "$release_yml" "uses: ./.github/workflows/ci.yml" "ac-4 the release reuses the pipeline"
# The publishing steps were extracted so the upstream automatic line publishes with the
# same implementation; the rules follow the steps into the reusable workflow.
assert_contains "$publish_yml" "contents: write" "ac-4 publishing is granted write access"
assert_contains "$publish_yml" "gh release create" "ac-4 the release is created by gh"
assert_eq "$(printf '%s' "$release_yml" | grep -c 'branches:')" "0" \
  "ac-4 no branch can trigger a release"

entry_yml="$(cat .github/workflows/ci.yml)"
assert_contains "$entry_yml" "workflow_call" "ac-4 the pipeline is callable by the release"
assert_eq "$(printf '%s' "$entry_yml" | grep -c 'contents: write')" "0" \
  "ac-4 the ordinary pipeline never gets write access"

# --- ac-5 the install documentation ---------------------------------------
assert_file_exists docs/install.md "ac-5 the install guide exists"
assert_file_exists docs/install.zh-CN.md "ac-5 the Chinese install guide exists"
left="$(grep -c '^## ' docs/install.md)"
right="$(grep -c '^## ' docs/install.zh-CN.md)"
assert_eq "$right" "$left" "ac-5 both guides have the same sections"

guide="$(cat docs/install.md)"
for needle in "ab-slot status" "ab-upgrade" "ab-slot rollback" "SHA256SUMS" "p4=degraded"; do
  assert_contains "$guide" "$needle" "ac-5 the guide covers ${needle}"
done
zh_guide="$(cat docs/install.zh-CN.md)"
for needle in "ab-slot status" "ab-upgrade" "ab-slot rollback" "SHA256SUMS" "p4=degraded"; do
  assert_contains "$zh_guide" "$needle" "ac-5 the Chinese guide covers ${needle}"
done

finish
