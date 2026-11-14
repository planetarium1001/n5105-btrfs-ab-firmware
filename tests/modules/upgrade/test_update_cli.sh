#!/usr/bin/env bash
# Module: upgrade
# The ab-upgrade feed modes: what the operator sees, and what the exit status means.
# Everything is local: the feed is a directory, the fetcher is `cp`, and the machine's
# version comes from a file this test writes. No slot, no ESP, no network.
#
#   ac-3  --feed-check prints one machine-readable line and exits 0 / 10 / 74
#   ac-6  the tier picks the prompt: Z1/Z2/Y1/Y2 ask a question, X1 demands a route
#   ac-8  a feed whose newest release is older than what runs here is a downgrade
#   ac-11 --version prints the three identity lines through the shared helper
#   ac-12 UPDATE_PIN holds the machine, and --pin/--unpin edit exactly one line
#   ac-12 a check says which source answered, and a fork or a proxy is one-run override
#   ac-14 the prompt text is a contract, asserted word for word
#   ac-14 --help lists every option the feed path has
#   ac-15 one question, one safe default: Enter, n, N and no decline; y accepts
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

upgrade="$root/platform/usr/sbin/ab-upgrade"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

release="$tmp/platform-release"
printf 'PLATFORM_VERSION=0.0.6\nUPSTREAM_VERSION=25.12.2\nPLATFORM_STAGE=release\n' >"$release"
conf="$tmp/update.conf"
printf 'UPDATE_FEED_URL=https://feed.invalid/v1\n' >"$conf"
feed="$tmp/feed"
mkdir -p "$feed"
export FEED_LOCAL="$feed"
# The fetcher contract: the command gets the url as $1 and the output as $2.
export UPDATE_FETCH_CMD='cp "$FEED_LOCAL/$(basename "$1")" "$2"'

# write_index <platform> <base> <kernel>: one release, with a payload of two bytes.
write_index() {
  local platform=$1 base=$2 kernel=$3
  local payload="n5105-ab-${base}-upgrade.tar"
  printf 'payload\n' >"$feed/$payload"
  local sha size
  sha=$(shasum -a 256 "$feed/$payload" | cut -d' ' -f1)
  size=$(wc -c <"$feed/$payload" | tr -d ' ')
  cat >"$feed/index.txt" <<IDX
AB-FEED 1
channel  stable
generated 2026-11-13T00:00:00Z
entry
  platform ${platform}
  base     ${base}
  kernel   ${kernel}
  payload  ${payload}
  size     ${size}
  sha256   ${sha}
end
IDX
}

run() {
  AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" AB_FEED_DIR="$tmp/dl" \
    sh "$upgrade" "$@" 2>&1
}

# --- ac-1/ac-3: no config, then a normal check ------------------------------
rm -f "$conf"
set +e
out=$(AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" sh "$upgrade" --feed-check 2>&1)
rc=$?
set -e
assert_eq "$rc" "74" "a missing config exits 74"
assert_contains "$out" "reason=no-feed-config" "a missing config names the reason"

printf 'UPDATE_FEED_URL=https://feed.invalid/v1\n' >"$conf"
write_index 0.0.8 25.12.2 6.12.103
set +e
out=$(run --feed-check)
rc=$?
set -e
assert_eq "$rc" "10" "an available release exits 10"
assert_contains "$out" "platform=0.0.6 platform_available=0.0.8" "the line names both platform versions"
assert_contains "$out" "base=25.12.2 base_available=25.12.2" "the line names both base versions"
assert_contains "$out" "level=Z1" "the same base stays Z1"
assert_contains "$out" "status=update" "the status says update"

write_index 0.0.6 25.12.2 6.12.103
set +e
out=$(run --feed-check)
rc=$?
set -e
assert_eq "$rc" "0" "the running release exits 0"
assert_contains "$out" "status=current" "the status says current"

# --- ac-6: the tier decides the prompt -------------------------------------
write_index 0.0.9 25.12.9 6.12.110
set +e
out=$(run --feed-check)
set -e
assert_contains "$out" "level=Z2" "seven patch releases are Z2"

set +e
out=$(run --feed)
rc=$?
set -e
assert_eq "$rc" "74" "a non-interactive run without --yes is refused"
assert_contains "$out" "reason=feed-noninteractive" "the refusal names the missing confirmation"
assert_contains "$out" "Tested  NO         · span outside the covered range" "the Z2 prompt states its coverage"
assert_contains "$out" "Backup    ab-backup --help   (recommended)" "Z2 recommends a backup"

write_index 0.1.0 25.13.0 6.12.120
set +e
out=$(run --feed)
rc=$?
set -e
assert_eq "$rc" "74" "a one-line move still needs the confirmation"
assert_contains "$out" "Tested  PARTLY     · neighbouring lines built together; one cross-line upgrade in CI" "Y1 states what is partly covered"
assert_contains "$out" "Risk    REAL       · installed packages may need rebuilding for the new base" "Y1 states the risk as a possibility"

write_index 1.0.0 26.0.0 6.18.2
set +e
out=$(run --feed)
rc=$?
set -e
assert_eq "$rc" "74" "a major move without a route is refused"
assert_contains "$out" "reason=feed-route-required" "the refusal asks for a route"
assert_contains "$out" "Route     --stepwise" "both routes are printed"

# --- ac-8: downgrade --------------------------------------------------------
write_index 0.0.5 25.12.2 6.12.103
set +e
out=$(run --feed-check)
rc=$?
set -e
assert_eq "$rc" "0" "a downgrade is still a successful check"
assert_contains "$out" "status=downgrade" "the status says downgrade"

set +e
out=$(run --feed --yes)
rc=$?
set -e
assert_eq "$rc" "74" "a downgrade is refused without --force"
assert_contains "$out" "reason=feed-would-downgrade" "the refusal names the downgrade"

# --- ac-12: pin -------------------------------------------------------------
set +e
AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" sh "$upgrade" --pin 0.0.7 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "pinning succeeds"
assert_eq "$(sed -n 's/^UPDATE_PIN=//p' "$conf")" "0.0.7" "the pin is written"

write_index 0.0.8 25.12.2 6.12.103
set +e
out=$(run --feed-check)
set -e
assert_contains "$out" "status=pinned" "a check reports the pin"
set +e
out=$(run --feed --yes)
rc=$?
set -e
assert_eq "$rc" "74" "a held machine refuses to install"
assert_contains "$out" "reason=feed-pinned" "the refusal names the pin"

set +e
AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" sh "$upgrade" --unpin 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "unpinning succeeds"
assert_eq "$(sed -n 's/^UPDATE_PIN=//p' "$conf")" "" "the pin line is gone"

# --- ac-4: a bad download never reaches the installer ----------------------
write_index 0.0.8 25.12.2 6.12.103
printf 'tampered\n' >>"$feed/n5105-ab-25.12.2-upgrade.tar"
set +e
out=$(run --feed --yes)
rc=$?
set -e
assert_eq "$rc" "74" "a tampered payload is refused"
assert_contains "$out" "reason=feed-size-mismatch" "the refusal names the size"

# --- the guards the review asked for ---------------------------------------

# An override URL goes through the same https-only rule as the file.
set +e
out=$(run --feed-check --feed-url http://plaintext.invalid/v1)
rc=$?
set -e
assert_eq "$rc" "74" "an http override is refused"
assert_contains "$out" "reason=feed-conf-url" "the refusal names the url rule"

# A release file this code cannot compare is not something it can advise about.
printf 'PLATFORM_VERSION=0.0.6\nUPSTREAM_VERSION=25.12\n' >"$tmp/bad-release"
set +e
out=$(AB_PLATFORM_RELEASE="$tmp/bad-release" UPDATE_CONF="$conf" sh "$upgrade" --feed-check 2>&1)
rc=$?
set -e
assert_eq "$rc" "74" "a malformed base version is refused"
assert_contains "$out" "reason=platform-release-invalid" "the refusal names the release file"
printf 'PLATFORM_VERSION=0.0.6\nUPSTREAM_VERSION=25.12.2\nPLATFORM_STAGE=release\n' >"$release"

# A downgrade on the same base is a downgrade, not Z1.
write_index 0.0.5 25.12.2 6.12.103
set +e
out=$(run --feed --yes --force)
rc=$?
set -e
assert_contains "$out" "level=downgrade" "an older release on the same base is downgraded"
case "$out" in
  *"Tested  YES"*) assert_eq "Z1 block" "absent" "a downgrade does not borrow the Z1 block" ;;
  *) assert_eq "absent" "absent" "a downgrade does not borrow the Z1 block" ;;
esac

# A platform-only update says what it is, and still reaches the installer.
write_index 0.0.8 25.12.2 6.12.103
set +e
out=$(run --feed --yes)
rc=$?
set -e
assert_contains "$out" "base unchanged; this updates the platform layer only" \
  "a same-base update announces that only the platform layer moves"
assert_eq "$rc" "74" "it reaches the installer, which refuses the fixture payload"

# Flags that only mean something with --feed are a usage error on their own.
set +e
out=$(run --direct /tmp/payload.tar)
rc=$?
set -e
assert_eq "$rc" "2" "--direct without --feed is a usage error"

set +e
out=$(AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" sh "$upgrade" --pin 0.0.8 --unpin 2>&1)
rc=$?
set -e
assert_eq "$rc" "2" "--pin and --unpin contradict each other"

# --- ac-11: the identity ----------------------------------------------------
# A machine answers "which version are you" about itself, from the file it was built with,
# and both CLIs print the same three lines through one helper. The question needs no root,
# no config and no payload: `--version` is answered before the command line is parsed.
identity_file="$tmp/platform-release-identity"
printf 'PLATFORM_VERSION=0.0.9\nUPSTREAM_VERSION=25.12.2\nPLATFORM_STAGE=release\n' >"$identity_file"
set +e
out=$(AB_RELEASE_FILE="$identity_file" sh "$upgrade" --version 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "ac-11 --version succeeds"
assert_eq "$out" "$(printf 'PLATFORM_VERSION=0.0.9\nUPSTREAM_VERSION=25.12.2\nPLATFORM_STAGE=release')" \
  "ac-11 --version prints the three identity lines"

helper_out=$(AB_RELEASE_FILE="$identity_file" sh -c \
  '. "$1"; ab_version_identity' sh "$root/platform/lib/ab-version.sh" 2>&1)
assert_eq "$out" "$helper_out" "ac-11 the lines come from ab_version_identity, not a second parser"

set +e
out=$(AB_RELEASE_FILE="$tmp/no-such-release" sh "$upgrade" --version 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "ac-11 a machine without a release file still answers"
assert_contains "$out" "PLATFORM_VERSION=unknown" "ac-11 and says the version is unknown"
assert_contains "$out" "PLATFORM_STAGE=unknown" "ac-11 including the stage"

# Parsed first: a config file and an unknown option cannot turn `--version` into an error,
# which is what makes it usable from a support script.
set +e
out=$(AB_RELEASE_FILE="$identity_file" UPDATE_CONF="$tmp/absent.conf" \
  sh "$upgrade" --version --definitely-not-an-option 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "ac-11 --version is answered before the rest of the command line"
assert_contains "$out" "PLATFORM_VERSION=0.0.9" "ac-11 and it still prints the identity"

# --- ac-14: every option is in the help -------------------------------------
set +e
out=$(UPDATE_CONF="$tmp/absent.conf" sh "$upgrade" --help 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "ac-14 --help is not an error"
for option in --check --feed-check --feed --feed-url --release-repo --release-base \
  --pin --unpin --direct --stepwise --yes --force; do
  assert_contains "$out" "$option" "ac-14 --help lists ${option}"
done

# --- ac-12: where the answer came from --------------------------------------
# The first line of a check names the source, so a comparison and a refusal can never be
# read as each other, and an operator can see which URL was used without opening the config.
printf 'UPDATE_SOURCE=release\nUPDATE_RELEASE_REPO=planetarium1001/n5105-btrfs-ab-firmware\nUPDATE_RELEASE_BASE=https://github.com\nUPDATE_CHANNEL=stable\n' >"$conf"
write_index 0.0.8 25.12.2 6.12.103
set +e
out=$(run --feed-check)
rc=$?
set -e
assert_eq "$rc" "10" "ac-12 the shipped default config finds the release"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" \
  "source=release feed=https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download" \
  "ac-12 the first line names the source and the release root"

# The other source names itself the same way, so a script can tell which one answered.
printf 'UPDATE_FEED_URL=https://feed.invalid/v1\n' >"$tmp/feed-only.conf"
set +e
out=$(AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$tmp/feed-only.conf" AB_FEED_DIR="$tmp/dl" \
  sh "$upgrade" --feed-check 2>&1)
rc=$?
set -e
assert_eq "$rc" "10" "ac-12 a feed configuration still checks"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" "source=feed feed=https://feed.invalid/v1" \
  "ac-12 the first line names the feed it used"

# A fork and a proxy are one-run overrides, exactly like --feed-url.
set +e
out=$(run --feed-check --release-repo fork/own-line)
rc=$?
set -e
assert_eq "$rc" "10" "ac-12 a fork override still checks the feed"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" \
  "source=release feed=https://github.com/fork/own-line/releases/latest/download" \
  "ac-12 --release-repo builds the fork's release root"

set +e
out=$(run --feed-check --release-base https://gh-proxy.example/https://github.com)
rc=$?
set -e
assert_eq "$rc" "10" "ac-12 a proxy override still checks the feed"
assert_eq "$(printf '%s\n' "$out" | head -n 1)" \
  "source=release feed=https://gh-proxy.example/https://github.com/planetarium1001/n5105-btrfs-ab-firmware/releases/latest/download" \
  "ac-12 --release-base only adds a prefix to the same path"

set +e
out=$(run --feed-check --release-base http://plaintext.invalid)
rc=$?
set -e
assert_eq "$rc" "74" "ac-12 a non-https release base is refused"
assert_contains "$out" "reason=feed-conf-url" "ac-12 and it names the url rule"

set +e
out=$(run --feed-check --release-repo n5105-btrfs-ab-firmware)
rc=$?
set -e
assert_eq "$rc" "74" "ac-12 a repository without an owner is refused"
assert_contains "$out" "reason=feed-conf-repo" "ac-12 and it names the repository rule"

# A release that predates the index answers with a page. "There is no index at that URL
# yet" is a different answer from "the server could not be reached", and the source line
# still comes first so the operator knows which URL answered.
cp "$feed/index.txt" "$tmp/index.txt.good"
printf '<!doctype html>\n<title>404 Not Found</title>\n' >"$feed/index.txt"
set +e
out=$(run --feed-check)
rc=$?
set -e
assert_eq "$rc" "74" "ac-12 a body that is not an index is refused"
assert_contains "$out" "reason=feed-index-missing" "ac-12 and the missing index has its own reason"
assert_contains "$(printf '%s\n' "$out" | head -n 1)" "source=release" \
  "ac-12 the source line precedes the refusal"
cp "$tmp/index.txt.good" "$feed/index.txt"

# --- ac-15: one question, one safe default ----------------------------------
# Every question is `Proceed? [y/N] `: Enter, n, N and no all decline, and a decline is not
# an error. Only y, Y, yes and YES accept. The answer is fed through a pipe and the prompt is
# told there is a terminal, because a test process has none: what is asserted is the
# decision, not the pty.
ask() {
  local answer=$1
  shift
  printf '%s\n' "$answer" | AB_UPGRADE_ASSUME_TTY=1 AB_PLATFORM_RELEASE="$release" \
    UPDATE_CONF="$conf" AB_FEED_DIR="$tmp/dl" sh "$upgrade" "$@" 2>&1
}

printf 'UPDATE_FEED_URL=https://feed.invalid/v1\n' >"$conf"
write_index 0.0.8 25.12.2 6.12.103

set +e
out=$(ask "" --feed)
rc=$?
set -e
assert_contains "$out" "Proceed? [y/N] " "ac-15 the question offers the safe default"
assert_eq "$rc" "0" "ac-15 Enter declines and is not an error"
assert_contains "$out" "ab-upgrade: declined, nothing was written reason=declined" \
  "ac-15 Enter says nothing was written"

for answer in n N no NO; do
  set +e
  out=$(ask "$answer" --feed)
  rc=$?
  set -e
  assert_eq "$rc" "0" "ac-15 an answer of [$answer] exits 0"
  assert_contains "$out" "ab-upgrade: declined, nothing was written reason=declined" \
    "ac-15 an answer of [$answer] declines"
done

for answer in y Y yes YES; do
  set +e
  out=$(ask "$answer" --feed)
  rc=$?
  set -e
  assert_contains "$out" "ab-upgrade: 0.0.8 verified, installing" \
    "ac-15 an answer of [$answer] accepts the update"
  assert_eq "$rc" "74" "ac-15 an accepted update reaches the installer (which refuses the fixture)"
done

# Anything that is not one of those words is a decline, including a word that merely starts
# with a y: a firmware write starts on an exact answer, never on a guess.
set +e
out=$(ask yesplease --feed)
rc=$?
set -e
assert_eq "$rc" "0" "ac-15 an unrecognised answer declines"
assert_contains "$out" "reason=declined" "ac-15 and it says so"

# Without a terminal and without --yes the command refuses instead of waiting for an answer
# that will never come.
set +e
out=$(AB_PLATFORM_RELEASE="$release" UPDATE_CONF="$conf" AB_FEED_DIR="$tmp/dl" \
  sh "$upgrade" --feed 2>&1 </dev/null)
rc=$?
set -e
assert_eq "$rc" "74" "ac-15 no terminal and no --yes is a refusal"
assert_contains "$out" "reason=feed-noninteractive" "ac-15 and the reason says why"

finish
