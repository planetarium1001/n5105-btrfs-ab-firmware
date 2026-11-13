#!/usr/bin/env bash
# Module: upgrade
# The feed layer: configuration, fetching and the AB-FEED 1 index.
# platform/lib/ab-feed.sh never writes a slot; it turns bytes on a server into
# "there is a release <x>, here is its payload and its digest", or into a reason.
#
#   ac-1  a missing or incomplete /etc/ab/update.conf is a refusal, not a default
#   ac-2  the index is validated field by field; a broken entry is named, not skipped
#   ac-4  a payload is only accepted when its size and sha256 match the index
#   ac-7  a fetcher is a command, so the tests never touch the network
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-feed.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the feed library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi
# shellcheck source=platform/lib/ab-version.sh
. "$root/platform/lib/ab-version.sh"
# shellcheck source=platform/lib/ab-feed.sh
. "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- ac-1: configuration ----------------------------------------------------
conf="$tmp/update.conf"
rm -f "$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "a missing config must be refused"
else
  assert_eq "$AB_FEED_REASON" "no-feed-config" "a missing config names the reason"
fi

printf 'UPDATE_CHANNEL=stable\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "a config without a URL must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-missing-url" "a config without a URL names the reason"
fi

printf 'UPDATE_FEED_URL=ftp://example.org/feed\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "a non-https URL must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-url" "a non-https URL names the reason"
fi

printf 'UPDATE_FEED_URL=https://example.org/feed\nUPDATE_VERIFY=minisign\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "an unsupported verify mode must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-verify-unsupported" "an unsupported verify mode names the reason"
fi

printf '# comment\nUPDATE_FEED_URL=https://example.org/feed\n' >"$conf"
if ab_feed_config_load "$conf"; then
  assert_eq "$AB_FEED_URL" "https://example.org/feed" "the URL is read"
  assert_eq "$AB_FEED_CHANNEL" "stable" "the channel defaults to stable"
  assert_eq "$AB_FEED_VERIFY" "sha256" "the verify mode defaults to sha256"
else
  assert_eq "$AB_FEED_REASON" "none" "a minimal config loads"
fi

# --- ac-2: the index --------------------------------------------------------
index="$tmp/index.txt"
cat >"$index" <<'IDX'
AB-FEED 1
channel  stable
generated 2026-11-13T00:00:00Z
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  n5105-ab-25.12.2-upgrade.tar
  size     2048
  sha256   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  url      https://example.org/feed/n5105-ab-25.12.2-upgrade.tar
end
entry
  platform 0.0.7
  base     25.12.2
  kernel   6.12.103
  payload  n5105-ab-25.12.2-upgrade-0.0.7.tar
  size     1024
  sha256   bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
end
IDX

parsed="$tmp/parsed.txt"
if ab_feed_index_parse "$index" stable >"$parsed"; then
  assert_eq "$(wc -l <"$parsed" | tr -d ' ')" "2" "two entries parsed"
  assert_eq "$(sed -n 1p "$parsed")" \
    "0.0.8|25.12.2|6.12.103|2048|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|https://example.org/feed/n5105-ab-25.12.2-upgrade.tar|" \
    "the newest entry comes first and keeps every field"
  assert_eq "$(sed -n 2p "$parsed" | cut -d'|' -f6)" \
    "https://example.org/feed/n5105-ab-25.12.2-upgrade-0.0.7.tar" \
    "a missing url is resolved against the feed base"
else
  assert_eq "$AB_FEED_REASON" "none" "the sample index parses"
fi

assert_kind() {
  local message=$1 expected=$2 file=$3
  if ab_feed_index_parse "$file" stable >/dev/null 2>&1; then
    assert_eq "parsed" "refused" "$message"
  else
    assert_eq "$AB_FEED_REASON" "$expected" "$message"
  fi
}

printf 'AB-FEED 2\nchannel stable\n' >"$tmp/v2.txt"
assert_kind "an unknown index format is refused" "feed-index-version" "$tmp/v2.txt"

printf 'AB-FEED 1\nchannel stable\nentry\n  base 25.12.2\n  kernel 6.12.103\n  payload p.tar\n  size 1\n  sha256 %s\nend\n' \
  "$(printf 'a%.0s' $(seq 64))" >"$tmp/noplatform.txt"
assert_kind "an entry without a platform version is refused" "feed-index-field" "$tmp/noplatform.txt"

printf 'AB-FEED 1\nchannel stable\nentry\n  platform 0.0.8\n  base 25.12.2\n  payload p.tar\n  size 1\n  sha256 %s\nend\n' \
  "$(printf 'a%.0s' $(seq 64))" >"$tmp/nokernel.txt"
assert_kind "an entry without a kernel version is refused" "feed-index-field" "$tmp/nokernel.txt"

printf 'AB-FEED 1\nchannel stable\nentry\n  platform 0.0.8\n  base 25.12.2\n  kernel 6.12.103\n  payload p.tar\n  size 1\n  sha256 deadbeef\nend\n' \
  >"$tmp/badsha.txt"
assert_kind "a short digest is refused" "feed-index-field" "$tmp/badsha.txt"

printf 'AB-FEED 1\nchannel edge\nentry\n  platform 0.0.8\n  base 25.12.2\n  kernel 6.12.103\n  payload p.tar\n  size 1\n  sha256 %s\nend\n' \
  "$(printf 'a%.0s' $(seq 64))" >"$tmp/edge.txt"
assert_kind "a channel mismatch is refused" "feed-index-channel" "$tmp/edge.txt"

# --- ac-2: selection --------------------------------------------------------
assert_eq "$(ab_feed_pick "$parsed" 0.0.6)" "0.0.8" "the newest platform is the candidate"
assert_eq "$(ab_feed_pick "$parsed" 0.0.8)" "" "the installed release is not offered again"
assert_eq "$(ab_feed_stepwise "$parsed" 0.0.6)" "0.0.7" "stepwise takes the smallest release above the installed one"
assert_eq "$(ab_feed_stepwise "$parsed" 0.0.7)" "0.0.8" "stepwise moves one release at a time"

# --- ac-4: payload verification --------------------------------------------
payload="$tmp/payload.tar"
printf 'payload-bytes' >"$payload"
size=$(wc -c <"$payload" | tr -d ' ')
sha=$(ab_feed_sha256 "$payload")
entry_ok="0.0.8|25.12.2|6.12.103|${size}|${sha}|https://example.org/feed/p.tar|"
assert_command_ok "a matching size and digest are accepted" ab_feed_verify_member "$payload" "$entry_ok"

entry_bad_sha="0.0.8|25.12.2|6.12.103|${size}|$(printf 'b%.0s' $(seq 64))|u|"
if ab_feed_verify_member "$payload" "$entry_bad_sha" 2>/dev/null; then
  assert_eq "accepted" "refused" "a wrong digest must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-digest-mismatch" "a wrong digest names the reason"
fi

entry_bad_size="0.0.8|25.12.2|6.12.103|$((size + 1))|${sha}|u|"
if ab_feed_verify_member "$payload" "$entry_bad_size" 2>/dev/null; then
  assert_eq "accepted" "refused" "a wrong size must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-size-mismatch" "a wrong size names the reason"
fi

if ab_feed_space_ok "$tmp" 999999999999 2>/dev/null; then
  assert_eq "ok" "refused" "an impossible download must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-download-space" "an impossible download names the reason"
fi

finish
