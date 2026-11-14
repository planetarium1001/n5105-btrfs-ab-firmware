#!/usr/bin/env bash
# Module: ci
# The two images a release carries: the shipped default (no WAN exposure) and the
# convenience build (one tcp/22 rule, for a machine that cannot be reached from the LAN).
#
# The difference between them is one rendered file, so it is asserted where it is cheap
# to assert: the render itself, the seed hook that acts on it, and the wiring that
# produces the second artifact on a tag build.
#
#   ac-6  the default render opens nothing; the convenience render opens exactly one rule
#   ac-6  one build produces both images: ci-s3 always builds closed and derives the
#         convenience one from it (scripts/ci/derive-variant.sh)
#   ac-6  the derived image rewrites exactly one line, and refuses a template it cannot read
#   ac-6  the two artifacts stay distinguishable in the run page and in the release
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- ac-6: the render -------------------------------------------------------
# shellcheck source=scripts/ci/lib.sh
(
  # shellcheck disable=SC1091
  . "$root/scripts/ci/lib.sh"
  ci_render_net_defaults "$tmp/closed" >/dev/null 2>&1
  CI_NET_WAN_SSH=open ci_render_net_defaults "$tmp/open" >/dev/null 2>&1
) || true

closed="$(cat "$tmp/closed/etc/net-defaults.conf" 2>/dev/null)"
open="$(cat "$tmp/open/etc/net-defaults.conf" 2>/dev/null)"
assert_contains "$closed" "NET_WAN_SSH=closed" "ac-6 the shipped render closes the WAN"
assert_contains "$open" "NET_WAN_SSH=open" "ac-6 the convenience render opens it"

# Everything else must be identical: two images, one difference.
assert_eq "$(printf '%s\n' "$closed" | grep -v '^NET_WAN_SSH=')" \
  "$(printf '%s\n' "$open" | grep -v '^NET_WAN_SSH=')" \
  "ac-6 the two renders differ only in NET_WAN_SSH"

# --- ac-6: the seed hook acts on it ----------------------------------------
seed_hook="$root/platform/lib/net-defaults.sh"
assert_contains "$(cat "$seed_hook")" 'nd_ssh}" = "open"' "ac-6 the hook keys the rule off the rendered value"
assert_contains "$(cat "$seed_hook")" "wan-ssh-close:" "ac-6 the open branch prints how to close it"

# --- ac-6: the derivation --------------------------------------------------
# The convenience image is the default one with one line changed, so the rewrite is what
# is asserted: it must touch exactly that line, and it must refuse a tree where the knob
# is missing or duplicated rather than hand back an image nobody changed.
derive="$root/scripts/ci/derive-variant.sh"
tree="$tmp/tree"
mkdir -p "$tree/etc"
printf 'NET_WAN_DEV=eth0\nNET_WAN_SSH=closed\nNET_LAN_ADDR=192.168.100.1\n' >"$tree/etc/net-defaults.conf"
out="$(bash "$derive" --rewrite-tree "$tree" 2>&1)"
assert_eq "$?" "0" "ac-6 the rewrite succeeds on a rendered tree"
assert_contains "$out" "derive-variant=ok net_wan_ssh=open" "ac-6 the rewrite reports what it produced"
assert_eq "$(sed -n 's/^NET_WAN_SSH=//p' "$tree/etc/net-defaults.conf")" "open" \
  "ac-6 the knob now reads open"
assert_eq "$(sed -n 's/^NET_WAN_DEV=//p' "$tree/etc/net-defaults.conf")" "eth0" \
  "ac-6 nothing else in the file moved"

printf 'NET_WAN_DEV=eth0\n' >"$tree/etc/net-defaults.conf"
out="$(bash "$derive" --rewrite-tree "$tree" 2>&1)"
assert_eq "$?" "1" "ac-6 a template without the knob is refused"
assert_contains "$out" "net-defaults-knob-count-0" "ac-6 the refusal says the knob was not found"

printf 'NET_WAN_SSH=closed\nNET_WAN_SSH=open\n' >"$tree/etc/net-defaults.conf"
out="$(bash "$derive" --rewrite-tree "$tree" 2>&1)"
assert_eq "$?" "1" "ac-6 a duplicated knob is refused"

# --- ac-1: the slot filesystem ----------------------------------------------
# The image path as a whole needs a loop device and root, so it is asserted where it runs:
# the run itself. What broke there is testable here - which paths the script looks at, and
# what it refuses. A mounted slot carries @sys next to @platform, and @sys/root is a
# root-owned, unreadable directory in the real image, so the lookup has to stay out of
# @sys instead of walking the mount and letting `find` fail the whole step.
slot="$tmp/slot"
mkdir -p "$slot/@platform/etc" "$slot/@sys/root"
printf 'NET_WAN_SSH=closed\n' >"$slot/@platform/etc/net-defaults.conf"
printf 'untouched\n' >"$slot/@sys/root/secret"
chmod 0644 "$slot/@platform/etc/net-defaults.conf"
chmod 0000 "$slot/@sys/root"
out="$(bash "$derive" --rewrite-slot "$slot" 2>&1)"
assert_eq "$?" "0" "ac-1 the slot root is rewritten without walking the unreachable tree"
assert_contains "$out" "derive-variant=ok net_wan_ssh=open" "ac-1 the slot rewrite reports what it produced"
assert_eq "$(sed -n 's/^NET_WAN_SSH=//p' "$slot/@platform/etc/net-defaults.conf")" "open" \
  "ac-1 the knob in the slot now reads open"
conf_mode="$(stat -c %a "$slot/@platform/etc/net-defaults.conf" 2>/dev/null \
  || stat -f %Lp "$slot/@platform/etc/net-defaults.conf")"
assert_eq "$conf_mode" "644" "ac-1 the rewrite keeps the file mode, it only replaces the bytes"
chmod 0755 "$slot/@sys/root"
assert_eq "$(cat "$slot/@sys/root/secret")" "untouched" "ac-1 nothing under @sys was read or written"

empty_slot="$tmp/empty-slot"
mkdir -p "$empty_slot/@sys"
out="$(bash "$derive" --rewrite-slot "$empty_slot" 2>&1)"
assert_eq "$?" "1" "ac-1 a slot root without @platform is refused"
assert_contains "$out" "platform-tree-not-found" "ac-1 the refusal names the missing platform tree"

# --- ac-6: the build wiring -------------------------------------------------
s3="$(cat .github/workflows/ci-s3.yml)"
assert_contains "$s3" "CI_NET_WAN_SSH: closed" "ac-6 the stage always builds the closed image"
assert_contains "$s3" "name: Derive the convenience image" "ac-6 the variant is derived, not rebuilt"
assert_contains "$s3" "derive-variant.sh --image" "ac-6 the derivation runs on the image just built"
assert_contains "$s3" '*-wan-ssh.img.gz' "ac-6 the derived image is its own artifact"
assert_contains "$s3" 'name: image-install-wan-ssh${{ inputs.artifact_suffix }}' \
  "ac-6 the variant artifact has a literal name, plus the caller's suffix"

# The derived image is the only artifact nothing boots, so it gets the one proof that is
# cheap: the ESP preflight reads its GRUB menu and its slot file back off the copy.
assert_contains "$s3" "name: Preflight - the convenience ESP boots" \
  "ac-1 the derived image gets its own ESP preflight"
assert_contains "$s3" '${{ steps.variant.outputs.out }}' \
  "ac-1 that preflight reads the derived image, not the default one"

ci="$(cat .github/workflows/ci.yml)"
case "$ci" in
  *"s3-wan-ssh:"*) assert_eq "present" "absent" "ac-6 there is no second build job" ;;
  *) assert_eq "absent" "absent" "ac-6 there is no second build job" ;;
esac

# The published names have to be distinguishable at a glance.
assert_contains "$(cat scripts/ci/release.sh)" '-install${release_variant:+-${release_variant}}.img.gz' \
  "ac-6 the release name carries the variant"
assert_contains "$(cat scripts/ci/release.sh)" 'unknown release variant' \
  "ac-6 an unknown variant is refused instead of being published under a typo"

finish
