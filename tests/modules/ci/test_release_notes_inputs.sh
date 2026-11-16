#!/usr/bin/env bash
# Module: ci
# The release page has to describe the bytes it publishes, and it must never print a
# placeholder where the payload already holds the answer.
#
# Why this file exists: the v0.0.11 page said `not recorded` for the kernel package while
# the very same release's index.txt carried 6.12.103, and it told the reader the feed entry
# said `kernel not recorded` while the published index said `kernel 6.12.103`. The payload
# manifest (scripts/ci/assemble.sh writes it into the tar) had the answer all along; the
# release stage only looked at environment variables, so a caller that did not pass them got
# a page that contradicted its own artifacts.
#
#   ac-1 the Inputs table and the feed identity read the kernel package, both upstream
#        digests and the index's kernel version out of the payload manifest, so a release
#        invoked with none of those variables still names 6.12.103
#   ac-2 no field is filled with "not recorded": a value that is genuinely absent is
#        explained by a sentence that says why, and the kernel row is omitted rather than
#        carrying prose that feed-index.sh would read as a version
#   ac-3 an explicit environment variable that contradicts the manifest stops the release
#        instead of publishing one of the two answers
#   ac-4 the S5 judge line is printed when the caller has it; when it is absent the page
#        points at the run that recorded it instead of claiming the upgrade was never graded
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# macOS has shasum only; the target and CI both have sha256sum, and release.sh requires it.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sha256sum" <<'STUB'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  exec shasum -a 256
fi
for f in "$@"; do shasum -a 256 "$f"; done
STUB
chmod +x "$tmp/bin/sha256sum"

# The values v0.0.11's payload manifest carried: the package release suffix is part of the
# `kernel` field, the index carries only the version derived from it.
kernel_package='6.12.103~0413601b1c3f0490e17f340fe09229ea-r1'
kernel_version='6.12.103'
rootfs_sha='29b6a86c9bc14a10dc1769f0c4afe33092ce669f667a5b7636d25271aff6a3cb'
kernel_sha='980c16f57a5178abf0ac8fadbac2fcad965d92fbacf70c5334704b4aba420113'

# build_payload <path>: a payload tar whose root carries manifest.json, exactly where
# assemble.sh puts it. The members themselves are not needed by the release stage.
build_payload() {
  local tar_path=$1 dir
  dir=$(mktemp -d "$tmp/payload.XXXXXX")
  cat >"$dir/manifest.json" <<JSON
{
  "format": "ab-payload/1",
  "rootfs": "25.12.2",
  "kernel": "${kernel_package}",
  "platform": "0.0.11",
  "created": "2026-11-16T07:47:10Z",
  "members": {
    "boot.tar": {
      "sha256": "f0d34e46724cfa03fa9f656c0e226b9b5b0c58b4ec66f9700bbf54c298079e9f",
      "size": 655360
    },
    "initramfs.cpio.gz": {
      "sha256": "b799b79376b6b5a4d7d4955609270363e598f1686cc6ff8cd450c5c52d793c99",
      "size": 3059546
    },
    "kernel.bin": {
      "sha256": "${kernel_sha}",
      "size": 7709696
    },
    "platform.tar": {
      "sha256": "0ec3e70147795574d7696d3664dd95494d8663bcac7b8ff5ce5313cf6c7c4fd1",
      "size": 1607680
    },
    "rootfs.tar.gz": {
      "sha256": "${rootfs_sha}",
      "size": 10587455
    }
  }
}
JSON
  tar -cf "$tar_path" -C "$dir" manifest.json
}

image="$tmp/build.img"
head -c 131072 /dev/urandom >"$image"
payload="$tmp/payload.tar"
build_payload "$payload"
no_manifest_payload="$tmp/no-manifest.tar"
printf 'not a payload tar\n' >"$no_manifest_payload"

run_release() {
  local ci_root=$1
  shift
  env PATH="$tmp/bin:$PATH" CI_TMP_ROOT="$ci_root" CI_LOG_DIR="$ci_root/logs" "$@" \
    bash scripts/ci/release.sh 2>&1
}

# --------------------------------------------------------------------------- #
# ac-1: a complete manifest is enough - no kernel or digest variables needed
# --------------------------------------------------------------------------- #

out="$(run_release "$tmp/ci-manifest" CI_IMAGE="$image" CI_PAYLOAD="$payload" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11)"
assert_eq "$?" "0" "ac-1 a release whose caller passes only the image and the payload succeeds"

rel="$tmp/ci-manifest/release"
notes_path="$rel/release-notes.md"
assert_file_exists "$notes_path" "ac-1 the release page is written"

assert_eq "$(sed -n 's/^| Kernel package | `\(.*\)` |$/\1/p' "$notes_path")" "$kernel_package" \
  "ac-1 the Kernel package row equals the manifest's kernel field"
assert_eq "$(sed -n 's/^| Upstream kernel sha256 | `\(.*\)` |$/\1/p' "$notes_path")" "$kernel_sha" \
  "ac-1 the upstream kernel digest is the kernel.bin member's digest"
assert_eq "$(sed -n 's/^| Upstream rootfs sha256 | `\(.*\)` |$/\1/p' "$notes_path")" "$rootfs_sha" \
  "ac-1 the upstream rootfs digest is the rootfs.tar.gz member's digest"

assert_file_exists "$rel/index.txt" "ac-1 the feed index is generated from the manifest kernel"
assert_eq "$(sed -n 's/^  kernel  *//p' "$rel/index.txt" | head -n 1)" "$kernel_version" \
  "ac-1 the published index carries the kernel version, not the package release"

notes="$(cat "$notes_path")"
assert_contains "$notes" "\`kernel ${kernel_version}\`" \
  "ac-1 the feed identity names the same kernel version the index carries"
assert_eq "$(grep -c 'not recorded' "$notes_path" || true)" "0" \
  "ac-1 no field on the page is a placeholder"

# --------------------------------------------------------------------------- #
# ac-2: absent values are explained, never faked with a placeholder
# --------------------------------------------------------------------------- #

# A payload that is not a tar: the manifest cannot be read, so the page has to say so.
out="$(run_release "$tmp/ci-no-manifest" CI_IMAGE="$image" CI_PAYLOAD="$no_manifest_payload" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11)"
assert_eq "$?" "0" "ac-2 a payload without a readable manifest still publishes"
notes_path="$tmp/ci-no-manifest/release/release-notes.md"
assert_eq "$(grep -c 'not recorded' "$notes_path" || true)" "0" \
  "ac-2 an unreadable manifest does not become a placeholder"
assert_contains "$(cat "$notes_path")" "the payload carries no readable manifest" \
  "ac-2 the page says why the value is absent"
assert_eq "$(grep -c '^| Kernel package |' "$notes_path")" "0" \
  "ac-2 the kernel row is omitted, so feed-index.sh cannot read prose as a version"
assert_contains "$(cat "$notes_path")" "publishes" \
  "ac-2 the omission is explained instead of left as an empty cell"
assert_eq "$([ -f "$tmp/ci-no-manifest/release/index.txt" ] && echo present || echo absent)" \
  "absent" "ac-2 no index is published without a kernel"

# An image-only release: there is no payload manifest at all, and the page says that.
out="$(run_release "$tmp/ci-image-only" CI_IMAGE="$image" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2)"
assert_eq "$?" "0" "ac-2 an image-only release still succeeds"
notes_path="$tmp/ci-image-only/release/release-notes.md"
assert_eq "$(grep -c 'not recorded' "$notes_path" || true)" "0" \
  "ac-2 an image-only release carries no placeholder either"
assert_contains "$(cat "$notes_path")" "this release carries no payload manifest" \
  "ac-2 the page names the absent payload, not a missing value"

# --------------------------------------------------------------------------- #
# ac-3: a disagreement between the caller and the artifact stops the release
# --------------------------------------------------------------------------- #

out="$(run_release "$tmp/ci-mismatch" CI_IMAGE="$image" CI_PAYLOAD="$payload" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11 \
  CI_KERNEL_PACKAGE='6.12.999~deadbeef-r1')"
assert_eq "$?" "1" "ac-3 a kernel package that contradicts the manifest is refused"
assert_contains "$out" "payload manifest says" \
  "ac-3 the refusal quotes the manifest value"

# --------------------------------------------------------------------------- #
# ac-4: the S5 line is printed when known, and its absence says where it lives
# --------------------------------------------------------------------------- #

out="$(run_release "$tmp/ci-s5" CI_IMAGE="$image" CI_PAYLOAD="$payload" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.2 CI_RELEASE_TAG=v0.0.11 \
  CI_S5_LINE='S5-RESULT=ok upgrade=b conflicts=0 reclaimed=1')"
assert_eq "$?" "0" "ac-4 a release with a recorded S5 line succeeds"
assert_contains "$(cat "$tmp/ci-s5/release/release-notes.md")" \
  'Last recorded S5 line: `S5-RESULT=ok upgrade=b conflicts=0 reclaimed=1`' \
  "ac-4 the S5 line is recorded verbatim when the caller has it"

notes_path="$tmp/ci-manifest/release/release-notes.md"
assert_contains "$(cat "$notes_path")" "S5 upgrade verdict was recorded by the build run" \
  "ac-4 without a line, the page points at the run that recorded it"
assert_contains "$(cat "$notes_path")" "run's report" \
  "ac-4 the pointer names the report a reader can open"
assert_eq "$(grep -c 'Last recorded S5 line' "$notes_path" || true)" "0" \
  "ac-4 the page does not print an empty S5 line"

finish
