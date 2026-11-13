#!/usr/bin/env bash
# Module: upgrade
# The ab-upgrade feed modes: what the operator sees, and what the exit status means.
# Everything is local: the feed is a directory, the fetcher is `cp`, and the machine's
# version comes from a file this test writes. No slot, no ESP, no network.
#
#   ac-3  --feed-check prints one machine-readable line and exits 0 / 10 / 74
#   ac-6  the tier picks the prompt: Z1/Z2/Y1/Y2 ask a question, X1 demands a route
#   ac-8  a feed whose newest release is older than what runs here is a downgrade
#   ac-12 UPDATE_PIN holds the machine, and --pin/--unpin edit exactly one line
#   ac-14 the prompt text is a contract, asserted word for word
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

finish
