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
#   ac-6  ci-s3.yml takes net_wan_ssh/artifact_name/boots and maps the first to the render
#   ac-6  ci.yml builds the variant on tags only, without repeating the boot assertions
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

# --- ac-6: the build wiring -------------------------------------------------
s3="$(cat .github/workflows/ci-s3.yml)"
assert_contains "$s3" "net_wan_ssh:" "ac-6 S3 takes the WAN SSH default as an input"
assert_contains "$s3" "CI_NET_WAN_SSH: \${{ inputs.net_wan_ssh }}" "ac-6 S3 passes it to the render"
assert_contains "$s3" "variant:" "ac-6 S3 takes a variant flag"
assert_contains "$s3" "name: image-install-wan-ssh" "ac-6 the variant artifact has a literal name"
assert_contains "$s3" "boots:" "ac-6 S3 can skip the boot assertions for the variant"

ci="$(cat .github/workflows/ci.yml)"
assert_contains "$ci" "s3-wan-ssh:" "ac-6 the pipeline has a variant job"
assert_contains "$ci" "net_wan_ssh: open" "ac-6 the variant is the open one"
assert_contains "$ci" "variant: true" "ac-6 the variant job asks for the convenience image"
assert_contains "$ci" "boots: false" "ac-6 the variant does not repeat the boot assertions"
assert_contains "$ci" "startsWith(github.ref, 'refs/tags/v')" "ac-6 the variant is built on tags only"

# The published names have to be distinguishable at a glance.
assert_contains "$(cat scripts/ci/release.sh)" '-install${release_variant:+-${release_variant}}.img.gz' \
  "ac-6 the release name carries the variant"
assert_contains "$(cat scripts/ci/release.sh)" 'unknown release variant' \
  "ac-6 an unknown variant is refused instead of being published under a typo"

finish
