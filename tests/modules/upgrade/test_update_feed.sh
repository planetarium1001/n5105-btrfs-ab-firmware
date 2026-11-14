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
#   ac-12 the shipped config is rendered from one template, and the release source builds
#         <base>/<repo>/releases/latest/download; a body that is not an index has its own
#         reason, because "no index yet" is not "the server is unreachable"
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

# The feed source still needs its URL. A file that only names the feed source is incomplete,
# and the reason says which key is missing rather than which rule failed.
printf 'UPDATE_SOURCE=feed\nUPDATE_CHANNEL=stable\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "a feed config without a URL must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-missing-url" "a feed config without a URL names the reason"
fi

# With no source and no URL the file is read as the release source (that is the default), so
# what is missing is the repository to build the release root from.
printf 'UPDATE_CHANNEL=stable\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "a config without a source or a URL must be refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-repo" \
    "an unset source falls back to release, which needs a repository"
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
  assert_eq "$AB_FEED_SOURCE" "feed" "a config that only carries a URL keeps working as feed"
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

# --- ac-2: an index that guesses is refused --------------------------------
dup="$tmp/dup.txt"
cat >"$dup" <<'IDX'
AB-FEED 1
channel  stable
entry
  platform 0.0.8
  base     25.12.2
  base     26.0.0
  kernel   6.12.103
  payload  p.tar
  size     1
  sha256   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
end
IDX
assert_kind "an entry with two bases is refused" "feed-index-field" "$dup"

late="$tmp/late.txt"
cat >"$late" <<'IDX'
# comment
channel  stable
AB-FEED 1
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  p.tar
  size     1
  sha256   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
end
IDX
assert_kind "a header that is not first is refused" "feed-index-field" "$late"

plain="$tmp/plain.txt"
cat >"$plain" <<'IDX'
AB-FEED 1
channel  stable
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  p.tar
  size     1
  sha256   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  url      http://mirror.invalid/p.tar
end
IDX
assert_kind "an unencrypted explicit url is refused" "feed-index-field" "$plain"

# A pin written by hand is validated like one given on the command line.
printf 'UPDATE_FEED_URL=https://example.org/feed\nUPDATE_PIN=0.0.8-r1\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "an unparsable pin in the file is refused"
else
  assert_eq "$AB_FEED_REASON" "pin-invalid-version" "an unparsable pin in the file names the reason"
fi
printf 'UPDATE_FEED_URL=https://example.org/feed\n' >"$conf"

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

# --- ac-12: the shipped default config --------------------------------------
# A freshly flashed machine answers "is there something newer?" with no setup, and the
# answer is this project's own releases. The file is rendered from one template by the
# build, so the image and a payload cannot ship different answers, and a fork or a proxy is
# a build-time override of the same four keys.
render() {
  bash -c 'set -uo pipefail; . "$1"; shift; ci_render_update_conf "$@"' \
    _ "$root/scripts/ci/lib.sh" "$@"
}

layer="$tmp/layer"
if render "$layer" >/dev/null 2>&1; then
  shipped="$layer/etc/ab/update.conf"
  assert_file_exists "$shipped" "ac-12 the template is rendered into the platform layer"
  rendered="$(cat "$shipped" 2>/dev/null)"
  assert_contains "$rendered" "UPDATE_SOURCE=release" \
    "ac-12 the shipped source is the project's releases"
  assert_contains "$rendered" "UPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware" \
    "ac-12 the shipped repository is this project"
  assert_contains "$rendered" "UPDATE_RELEASE_BASE=https://github.com" \
    "ac-12 the shipped base is github"
  assert_contains "$rendered" "UPDATE_CHANNEL=stable" "ac-12 the shipped channel is stable"
  case "$rendered" in
    *@*@*) assert_eq "placeholder" "none" "ac-12 no placeholder survives the render" ;;
    *) assert_eq "none" "none" "ac-12 no placeholder survives the render" ;;
  esac
else
  assert_eq "rendered" "failed" "ac-12 the template is rendered into the platform layer"
fi

# The build environment is how a second line is produced: another repository (a fork), a
# proxy prefix, another channel. No code change, and no device-side edit.
if (
  CI_UPDATE_SOURCE=feed \
    CI_UPDATE_REPO=fork/own-line \
    CI_UPDATE_BASE=https://gh-proxy.example/https://github.com \
    CI_UPDATE_CHANNEL=edge \
    render "$tmp/alt"
) >/dev/null 2>&1; then
  alt="$(cat "$tmp/alt/etc/ab/update.conf" 2>/dev/null)"
  assert_contains "$alt" "UPDATE_SOURCE=feed" "ac-12 the source can be overridden from the build"
  assert_contains "$alt" "UPDATE_RELEASE_REPO=fork/own-line" "ac-12 the repository can be overridden from the build"
  assert_contains "$alt" "UPDATE_RELEASE_BASE=https://gh-proxy.example/https://github.com" \
    "ac-12 the base can be overridden from the build"
  assert_contains "$alt" "UPDATE_CHANNEL=edge" "ac-12 the channel can be overridden from the build"
else
  assert_eq "rendered" "failed" "ac-12 the build-time overrides render"
fi

# The template and the reader have to agree on the key names, or an image ships a file whose
# every key the device ignores: the rendered file is loaded by the same library that will
# read it on the machine.
if ab_feed_config_load "$layer/etc/ab/update.conf" 2>/dev/null; then
  assert_eq "$AB_FEED_SOURCE" "release" "ac-12 the rendered file is read as the release source"
  assert_eq "$AB_FEED_URL" \
    "https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download" \
    "ac-12 the rendered file builds the documented release root"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 the rendered file loads"
fi

# A value that would not be accepted on the device must not reach an image: the build
# stops, one key at a time.
render_bad() {
  if render "$1" >/dev/null 2>&1; then printf 'accepted'; else printf 'rejected'; fi
}
assert_eq "$(CI_UPDATE_SOURCE=maybe render_bad "$tmp/bad-source")" "rejected" \
  "ac-12 an unknown UPDATE_SOURCE fails the build"
assert_eq "$(CI_UPDATE_REPO=n5105-btrfs-ab-firmware render_bad "$tmp/bad-repo")" "rejected" \
  "ac-12 a repository that is not owner/name fails the build"
assert_eq "$(CI_UPDATE_REPO=a/b/c render_bad "$tmp/bad-repo2")" "rejected" \
  "ac-12 a repository with two slashes fails the build"
assert_eq "$(CI_UPDATE_BASE=http://github.com render_bad "$tmp/bad-base")" "rejected" \
  "ac-12 a non-https base fails the build"
assert_eq "$(CI_UPDATE_CHANNEL=nightly render_bad "$tmp/bad-channel")" "rejected" \
  "ac-12 an unknown channel fails the build"

# A template with a placeholder no rule replaces is the failure this guard exists for.
printf 'UPDATE_SOURCE=@UPDATE_SOURCE@\nUPDATE_UNKNOWN=@UPDATE_NOPE@\n' >"$tmp/bad.conf.in"
assert_eq "$(CI_UPDATE_CONF_TEMPLATE="$tmp/bad.conf.in" render_bad "$tmp/bad-tpl")" "rejected" \
  "ac-12 a leftover placeholder fails the build"

# The file has to reach every layer the project ships: the image, the disk image and the
# payload are three producers of the same layer, and one missing render is a machine that
# answers no-feed-config for the rest of its life.
for script in assemble.sh disk.sh payload-build.sh; do
  hits="$(grep -c 'ci_render_update_conf' "$root/scripts/ci/$script" 2>/dev/null || true)"
  assert_eq "${hits:-0}" "1" "ac-12 scripts/ci/$script renders the shipped update.conf"
  order="$(awk '
    /ci_render_net_defaults/ { net = NR }
    /ci_render_update_conf/ { upd = NR }
    END {
      if (upd && net && upd > net && upd - net <= 2) print "aligned"
      else print "misplaced"
    }' "$root/scripts/ci/$script" 2>/dev/null)"
  assert_eq "$order" "aligned" "ac-12 scripts/ci/$script renders it beside the net defaults"
done

# --- ac-12: the release source ----------------------------------------------
# The release root is a stable URL: releases/latest/download. No API, no JSON, no listing:
# the device fetches one index.txt from a path that is the same for every release.
conf="$tmp/default.conf"
cat >"$conf" <<'CONF'
UPDATE_SOURCE=release
UPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware
UPDATE_RELEASE_BASE=https://github.com
UPDATE_CHANNEL=stable
CONF
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "$AB_FEED_SOURCE" "release" "ac-12 the source in use is named"
  assert_eq "$AB_FEED_URL" \
    "https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download" \
    "ac-12 the release root is <base>/<repo>/releases/latest/download"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 the shipped default config loads"
fi

# A fork is a repository change and nothing else.
printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=fork/own-line\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "$AB_FEED_URL" "https://github.com/fork/own-line/releases/latest/download" \
    "ac-12 a fork only changes the repository, the base keeps its default"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 a fork config loads"
fi

# A proxy only adds a prefix: the path after it is the same one github serves.
printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware\nUPDATE_RELEASE_BASE=https://gh-proxy.example/https://github.com\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "$AB_FEED_URL" \
    "https://gh-proxy.example/https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download" \
    "ac-12 a proxy base keeps the release path unchanged"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 a proxy config loads"
fi

# A trailing slash on the base is one slash in the built URL, not two.
printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=fork/own-line\nUPDATE_RELEASE_BASE=https://github.com/\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "$AB_FEED_URL" "https://github.com/fork/own-line/releases/latest/download" \
    "ac-12 a trailing slash on the base is not doubled"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 a base with a trailing slash loads"
fi

# The feed source is unchanged, and it is selected explicitly.
printf 'UPDATE_SOURCE=feed\nUPDATE_FEED_URL=https://example.org/feed\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "$AB_FEED_SOURCE" "feed" "ac-12 an explicit feed source is honoured"
  assert_eq "$AB_FEED_URL" "https://example.org/feed" "ac-12 the feed URL is used as given"
else
  assert_eq "$AB_FEED_REASON" "none" "ac-12 an explicit feed config loads"
fi

# A value the device cannot act on is refused with the key that is wrong.
printf 'UPDATE_SOURCE=maybe\nUPDATE_FEED_URL=https://example.org/feed\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "ac-12 an unknown source is refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-source" "ac-12 an unknown source names the reason"
fi

printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=n5105-btrfs-ab-firmware\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "ac-12 a repository without an owner is refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-repo" "ac-12 a repository without an owner names the reason"
fi

printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware\nUPDATE_RELEASE_BASE=http://github.com\n' >"$conf"
if ab_feed_config_load "$conf" 2>/dev/null; then
  assert_eq "loaded" "refused" "ac-12 a non-https release base is refused"
else
  assert_eq "$AB_FEED_REASON" "feed-conf-url" "ac-12 a non-https release base names the reason"
fi

# --- ac-12: a source that answers with something else -----------------------
# The newest release of a project that predates the index answers with a page, not with an
# index. That is a different fact from an unreachable server, so it has its own reason, and
# it is decided before the parser can call the page a broken field.
printf '<!doctype html>\n<title>404</title>\n' >"$tmp/not-an-index.txt"
if ab_feed_index_check "$tmp/not-an-index.txt" 2>/dev/null; then
  assert_eq "accepted" "refused" "ac-12 a body that is not an index is refused"
else
  assert_eq "$AB_FEED_REASON" "feed-index-missing" \
    "ac-12 a body that is not an index names the missing index"
fi

: >"$tmp/empty.txt"
if ab_feed_index_check "$tmp/empty.txt" 2>/dev/null; then
  assert_eq "accepted" "refused" "ac-12 an empty body is refused"
else
  assert_eq "$AB_FEED_REASON" "feed-index-missing" "ac-12 an empty body names the missing index"
fi

assert_command_ok "ac-12 a real index passes the check" ab_feed_index_check "$index"

# The check skips the same lines the parser skips, so an index with a leading comment is
# still an index.
printf '# published by hand\n\nAB-FEED 1\nchannel stable\n' >"$tmp/commented.txt"
assert_command_ok "ac-12 a leading comment does not hide the header" \
  ab_feed_index_check "$tmp/commented.txt"

# An AB-FEED 2 header is a format this reader does not have, not a missing index: the
# parser names that difference, and the check must not steal it.
printf 'AB-FEED 2\nchannel stable\n' >"$tmp/v2-header.txt"
assert_command_ok "ac-12 a header of another format passes the header check" \
  ab_feed_index_check "$tmp/v2-header.txt"

finish
