#!/usr/bin/env bash
# Module: upgrade
# The publishing half of the update feed: scripts/ci/feed-index.sh and the release stage
# that calls it. The device half is covered by test_update_feed.sh; what is checked here
# is that the file the pipeline publishes is one the device can read, and that it
# describes the bytes that were actually published.
#
#   ac-9  an index is generated from one or more release directories, and release.sh
#         publishes it as index.txt without disturbing the other artifacts
#   ac-9a the header, the entry/end blocks and the newest-first order are the contract
#         platform/lib/ab-feed.sh enforces, so the producer is checked against it
#   ac-9b every entry's size, sha256 and absolute url match the published files
#   ac-9c a release directory that contradicts itself is refused, never half-indexed
#   ac-9d a release whose kernel version nobody recorded still publishes, without an
#         index, instead of failing or inventing a kernel
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tool="$root/scripts/ci/feed-index.sh"
if [ ! -f "$tool" ]; then
  printf 'not ok 1 - the feed index stage exists\n' >&2
  printf '    missing %s\n' "$tool" >&2
  exit 1
fi

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
PATH="$tmp/bin:$PATH"
export PATH

base_url="https://example.org/n5105/feed/v1"

# build_release <dir> <platform> <base> <kernel-package> [--no-kernel-row] [--no-sums]
#   One published release as the release stage leaves it: the payload, the image, the
#   checksum file and the notes. <kernel-package> is the manifest's `6.12.103~<hash>-r1`
#   form on purpose: the index has to carry the version, not the package release.
build_release() {
  local dir=$1 platform=$2 base=$3 kernel=$4
  shift 4
  local kernel_row=1 sums=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-kernel-row) kernel_row=0; shift ;;
      --no-sums) sums=0; shift ;;
      *) echo "bad arg $1" >&2; return 1 ;;
    esac
  done
  rm -rf "$dir"
  mkdir -p "$dir"
  printf 'payload for %s / %s\n' "$platform" "$base" >"$dir/n5105-ab-${base}-upgrade.tar"
  printf 'image for %s\n' "$platform" >"$dir/n5105-ab-${base}-install.img.gz"
  if [ "$sums" = 1 ]; then
    ( cd "$dir" && sha256sum "n5105-ab-${base}-install.img.gz" "n5105-ab-${base}-upgrade.tar" >SHA256SUMS )
  fi
  {
    printf '# N5105 AB firmware %s (upstream %s)\n' "$platform" "$base"
    printf '\n## Inputs\n\n| field | value |\n| --- | --- |\n'
    printf '| Upstream version | `%s` |\n' "$base"
    printf '| Upstream rootfs sha256 | `not recorded` |\n'
    if [ "$kernel_row" = 1 ]; then
      printf '| Kernel package | `%s` |\n' "$kernel"
    fi
    printf '| Platform version | `%s` |\n' "$platform"
  } >"$dir/release-notes.md"
}

run_index() {
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" bash "$tool" "$@" 2>&1
}

# index_field <index> <entry-number> <key>: one value out of one entry block.
index_field() {
  awk -v n="$2" -v k="$3" '
    /^entry$/ { entry++; next }
    entry == n {
      if ($1 != k) next
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", $0)
      print
      exit
    }
  ' "$1"
}

# parse_index <index> [channel]: run the device parser over the published file.
cat >"$tmp/parse.sh" <<'PARSE'
#!/bin/sh
set -u
root="$1" index="$2" channel="${3:-stable}"
. "$root/platform/lib/ab-version.sh"
. "$root/platform/lib/ab-feed.sh"
AB_FEED_URL="https://feed.invalid/v1"
if ab_feed_index_parse "$index" "$channel"; then
    exit 0
fi
printf 'reason=%s\n' "${AB_FEED_REASON}"
exit 1
PARSE

# --- ac-9a: two releases, handed over newest-last, come out newest-first -----
old="$tmp/rel-0.0.9"
new="$tmp/rel-0.0.10"
# 0.0.10 sorts before 0.0.9 as a string: the index must order these numerically.
build_release "$old" 0.0.9 25.12.9 "6.12.103~aaaa1111-r1"
build_release "$new" 0.0.10 25.12.10 "6.12.110~bbbb2222-r1"

index="$tmp/feed/index.txt"
out="$(run_index --out "$index" --base-url "$base_url" \
  --generated 2026-11-13T00:00:00Z --release "$old" --release "$new")"
assert_eq "$?" "0" "ac-9a the index stage succeeds for two release directories"
assert_file_exists "$index" "ac-9a the index is written to --out"

assert_eq "$(head -n 1 "$index")" "AB-FEED 1" "ac-9a the first line is the format line"
assert_contains "$(sed -n 's/^channel  *//p' "$index")" "stable" "ac-9a the channel is recorded"
assert_eq "$(sed -n 's/^generated //p' "$index")" "2026-11-13T00:00:00Z" \
  "ac-9a the generation time is recorded, and can be pinned for a reader"
assert_eq "$(grep -c '^entry$' "$index")" "2" "ac-9a one entry per release directory"
assert_eq "$(grep -c '^end$' "$index")" "2" "ac-9a every entry is closed"
assert_eq "$(grep -c '^AB-FEED ' "$index")" "1" "ac-9a exactly one format line"

assert_eq "$(index_field "$index" 1 platform)" "0.0.10" \
  "ac-9a the newest platform version comes first"
assert_eq "$(index_field "$index" 2 platform)" "0.0.9" \
  "ac-9a the older release follows, so 0.0.10 is not sorted as a string"
assert_eq "$(index_field "$index" 1 base)" "25.12.10" "ac-9a the base is the upstream version"
assert_eq "$(index_field "$index" 1 kernel)" "6.12.110" \
  "ac-9a the kernel is a version, not the package release"
assert_eq "$(index_field "$index" 2 kernel)" "6.12.103" "ac-9a each entry keeps its own kernel"

# --- ac-9b: the index describes the bytes that were published ---------------
payload="n5105-ab-25.12.10-upgrade.tar"
assert_eq "$(index_field "$index" 1 payload)" "$payload" "ac-9b the payload is named"
assert_eq "$(index_field "$index" 1 size)" "$(wc -c <"$new/$payload" | tr -d ' ')" \
  "ac-9b the size is the real one"
assert_eq "$(index_field "$index" 1 sha256)" "$(shasum -a 256 "$new/$payload" | cut -d' ' -f1)" \
  "ac-9b the digest is the real one, and matches SHA256SUMS"
assert_eq "$(grep -F "$(index_field "$index" 1 sha256)" "$new/SHA256SUMS" >/dev/null && echo same)" \
  "same" "ac-9b the published digest agrees with the checksum file"
assert_eq "$(index_field "$index" 1 url)" "$base_url/$payload" \
  "ac-9b the url is absolute and points at the payload"
assert_eq "$(index_field "$index" 1 url | grep -c '^https://')" "1" "ac-9b the url has a scheme"

# --- ac-9a: the device parser accepts it, and the channel is enforced --------
parsed="$(sh "$tmp/parse.sh" "$root" "$index")"
assert_eq "$?" "0" "ac-9a the index parses with nothing but the device's own parser"
assert_eq "$(printf '%s\n' "$parsed" | wc -l | tr -d ' ')" "2" "ac-9a the parser sees both entries"
assert_contains "$parsed" "0.0.10|25.12.10|6.12.110|" "ac-9a the parsed order is the published order"
also="$(sh "$tmp/parse.sh" "$root" "$index" edge 2>&1)"
assert_eq "$?" "1" "ac-9a a different channel is refused by the parser"
assert_contains "$also" "reason=feed-index-channel" "ac-9a the refusal names the channel mismatch"

# a different channel is written when asked for
out="$(run_index --out "$tmp/feed/edge.txt" --channel edge --release "$new")" 2>/dev/null
assert_eq "$(sed -n 's/^channel  *//p' "$tmp/feed/edge.txt")" "edge" \
  "ac-9a --channel is written into the index"

# no base URL means no url line: a relative url would be resolved against the wrong base
out="$(run_index --out "$tmp/feed/relative.txt" --release "$new")"
assert_eq "$?" "0" "ac-9b an index without a base URL is still written"
assert_eq "$(grep -c '^  url ' "$tmp/feed/relative.txt")" "0" \
  "ac-9b no url line without a base URL, so the device falls back to its own"
assert_eq "$(grep -c '^  payload ' "$tmp/feed/relative.txt")" "1" "ac-9b the payload name is still there"

# --- ac-9c: a release directory that contradicts itself is refused ----------
dup="$tmp/rel-dup"
build_release "$dup" 0.0.10 25.12.11 "6.12.110~cccc3333-r1"
out="$(run_index --out "$tmp/feed/dup.txt" --release "$new" --release "$dup")"
assert_eq "$?" "1" "ac-9c two directories for one platform version are refused"
assert_contains "$out" "more than one release directory" "ac-9c the refusal names the duplicate"

broken="$tmp/rel-no-sums"
build_release "$broken" 0.0.11 25.12.12 "6.12.111~dddd4444-r1" --no-sums
out="$(run_index --out "$tmp/feed/no-sums.txt" --release "$broken")"
assert_eq "$?" "1" "ac-9c a release directory without SHA256SUMS is refused"
assert_contains "$out" "SHA256SUMS" "ac-9c the refusal names the missing file"

stale="$tmp/rel-stale"
build_release "$stale" 0.0.12 25.12.13 "6.12.112~eeee5555-r1"
printf 'tampered\n' >>"$stale/n5105-ab-25.12.13-upgrade.tar"
out="$(run_index --out "$tmp/feed/stale.txt" --release "$stale")"
assert_eq "$?" "1" "ac-9c a payload that no longer matches SHA256SUMS is refused"
assert_contains "$out" "claims" "ac-9c the refusal quotes the published digest"

strays="$(cd "$tmp/feed" && for name in dup.txt no-sums.txt stale.txt; do
  [ -e "$name" ] && printf '%s\n' "$name"
done | wc -l | tr -d ' ')"
assert_eq "$strays" "0" "ac-9c nothing is written when the input is refused"

# --- ac-9d: an unrecorded kernel publishes the release, without an index ----
mystery="$tmp/rel-mystery"
build_release "$mystery" 0.0.13 25.12.14 "" --no-kernel-row
out="$(run_index --out "$tmp/feed/mystery.txt" --release "$mystery")"
assert_eq "$?" "3" "ac-9d a release with no kernel version is reported, not indexed"
assert_contains "$out" "Kernel package" "ac-9d the message names what is missing"
assert_contains "$out" "--kernel" "ac-9d the message says how to supply it"

# --- ac-9: the release stage publishes the index with the rest --------------
image="$tmp/build.img"
head -c 65536 /dev/urandom >"$image"
payload_tar="$tmp/payload.tar"
printf 'not a real payload\n' >"$payload_tar"
history="$tmp/rel-history"
build_release "$history" 0.0.9 25.12.9 "6.12.103~aaaa1111-r1"

release_dir="$tmp/ci/release"
out="$(CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
  CI_IMAGE="$image" CI_PAYLOAD="$payload_tar" \
  CI_PLATFORM_VERSION=0.0.10 CI_UPSTREAM_VERSION=25.12.10 CI_RELEASE_TAG=v0.0.10 \
  CI_KERNEL_PACKAGE='6.12.110~bbbb2222-r1' CI_FEED_BASE_URL="$base_url" \
  CI_FEED_HISTORY="$history" bash scripts/ci/release.sh 2>&1)"
assert_eq "$?" "0" "ac-9 the release stage succeeds"

released="$release_dir/index.txt"
assert_file_exists "$released" "ac-9 the release publishes index.txt"
assert_contains "$out" "artifact_list=" "ac-9 the stage publishes its artifact list"
assert_contains "$(printf '%s\n' "$out" | grep '^artifact_list=')" "index.txt" \
  "ac-9 index.txt is one of the published artifacts"
assert_contains "$(printf '%s\n' "$out" | grep '^feed_index=')" "index.txt" \
  "ac-9 index.txt is published as a stage output"

notes="$(cat "$release_dir/release-notes.md")"
assert_contains "$notes" "## Update feed" "ac-9 the release notes have a section for the index"
assert_contains "$notes" 'AB-FEED 1' "ac-9 the notes carry the index they published"
assert_contains "$notes" "docs/update.md" "ac-9 the notes point at the update page"
assert_contains "$notes" "| Kernel package |" "ac-9 the notes record the kernel package"

# the naming and the checksum file are untouched
assert_eq "$(wc -l <"$release_dir/SHA256SUMS" | tr -d ' ')" "2" \
  "ac-9 SHA256SUMS still covers exactly the two artifacts"
assert_eq "$(grep -c 'index.txt' "$release_dir/SHA256SUMS")" "0" \
  "ac-9 the index is not a line of SHA256SUMS, so the file cannot describe itself"
assert_file_exists "$release_dir/n5105-ab-25.12.10-install.img.gz" \
  "ac-9 the image keeps its name"
assert_file_exists "$release_dir/n5105-ab-25.12.10-upgrade.tar" \
  "ac-9 the payload keeps its name"

# the released index is a working feed: newest first, both releases, real digest
assert_eq "$(index_field "$released" 1 platform)" "0.0.10" "ac-9 the released index leads with this release"
assert_eq "$(index_field "$released" 2 platform)" "0.0.9" "ac-9 the earlier release is carried along"
assert_eq "$(index_field "$released" 1 sha256)" "$(shasum -a 256 "$release_dir/n5105-ab-25.12.10-upgrade.tar" | cut -d' ' -f1)" \
  "ac-9 the released digest is the digest of the released payload"
parsed="$(sh "$tmp/parse.sh" "$root" "$released")"
assert_eq "$?" "0" "ac-9 the released index parses on the device side"

# --- ac-9d: without a kernel version, the release still publishes -----------
rel2="$tmp/ci2"
out="$(CI_TMP_ROOT="$rel2" CI_LOG_DIR="$rel2/logs" \
  CI_IMAGE="$image" CI_PAYLOAD="$payload_tar" \
  CI_PLATFORM_VERSION=0.0.11 CI_UPSTREAM_VERSION=25.12.11 CI_RELEASE_TAG=v0.0.11 \
  bash scripts/ci/release.sh 2>&1)"
assert_eq "$?" "0" "ac-9d a release with no kernel version still succeeds"
assert_contains "$out" "index.txt not generated" "ac-9d it says the index was not generated"
assert_eq "$([ -f "$rel2/release/index.txt" ] && echo present || echo absent)" "absent" \
  "ac-9d no index is published rather than one with a guessed kernel"
assert_file_exists "$rel2/release/SHA256SUMS" "ac-9d the artifacts are still published"

finish
