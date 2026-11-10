#!/usr/bin/env bash
# Module: ci
# The network defaults are rendered twice per release (image and payload) from one
# template, and the hook that applies them only runs if its rcS start link exists and
# sorts before `network`. Both are build-time wiring and both are cheap to get wrong:
#   ac-7 the render writes every key, refuses placeholders and unknown modes
#   ac-2 the shipped defaults are the ones the README promises
#   ac-5 START places ab-net-seed after ab-boot and before network
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

# shellcheck source=scripts/ci/lib.sh
source "$root/scripts/ci/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# ac-7: the render
# --------------------------------------------------------------------------- #

ci_render_net_defaults "$tmp/layer" >/dev/null 2>&1
conf="$tmp/layer/etc/net-defaults.conf"
assert_file_exists "$conf" "ac-7 the template is rendered into the platform layer"
rendered="$(cat "$conf" 2>/dev/null)"
assert_contains "$rendered" "NET_WAN_DEV=eth0" "ac-2 the WAN port default is eth0"
assert_contains "$rendered" "NET_LAN_DEVS=auto" "ac-2 the LAN ports default to every other port"
assert_contains "$rendered" "NET_LAN_ADDR=192.168.100.1" "ac-2 the LAN address default is 192.168.100.1"
assert_contains "$rendered" "NET_LAN_PREFIX=24" "ac-2 the LAN prefix default is /24"
assert_contains "$rendered" "NET_WAN_SSH=open" "ac-4 the WAN SSH exception is on by default"
case "$rendered" in
    *@*@*) assert_eq "placeholder" "none" "ac-7 no placeholder survives the render" ;;
    *) assert_eq "none" "none" "ac-7 no placeholder survives the render" ;;
esac

# The build-time overrides are how a second release line is produced.
(
    CI_NET_WAN_SSH=closed CI_NET_LAN_ADDR=10.10.10.1 ci_render_net_defaults "$tmp/alt"
) >/dev/null 2>&1
assert_contains "$(cat "$tmp/alt/etc/net-defaults.conf" 2>/dev/null)" "NET_WAN_SSH=closed" "ac-7 the WAN exception can be switched off from the build"
assert_contains "$(cat "$tmp/alt/etc/net-defaults.conf" 2>/dev/null)" "NET_LAN_ADDR=10.10.10.1" "ac-7 the LAN address can be overridden from the build"

# A mode that is neither open nor closed is a typo, not a policy.
if (
    CI_NET_WAN_SSH=maybe ci_render_net_defaults "$tmp/bad-mode"
) >/dev/null 2>&1; then
    assert_eq "accepted" "rejected" "ac-7 an unknown NET_WAN_SSH value fails the build"
else
    assert_eq "rejected" "rejected" "ac-7 an unknown NET_WAN_SSH value fails the build"
fi

# A template that keeps a placeholder after substitution must never reach an image.
printf 'NET_WAN_DEV=@NET_WAN_DEV@\nNET_LAN_UNKNOWN=@NET_NOPE@\n' >"$tmp/bad.conf.in"
if (
    CI_NET_DEFAULTS_TEMPLATE="$tmp/bad.conf.in" ci_render_net_defaults "$tmp/bad"
) >/dev/null 2>&1; then
    assert_eq "accepted" "rejected" "ac-7 a leftover placeholder fails the build"
else
    assert_eq "rejected" "rejected" "ac-7 a leftover placeholder fails the build"
fi

# --------------------------------------------------------------------------- #
# ac-5: the hook runs before netifd
# --------------------------------------------------------------------------- #

ci_platform_startlinks "$tmp/rc" >/dev/null 2>&1
# The links point into ../init.d, so they are dangling in this scratch tree by design.
for link in S15ab-boot S16ab-net-seed S99ab-commit; do
    target="$(readlink "$tmp/rc/etc/rc.d/$link" 2>/dev/null)"
    assert_eq "${target}" "../init.d/${link#S[0-9][0-9]}" "ac-5 the start link ${link} exists"
done

start_of() {
    sed -n 's/^START=//p' "$1" | tail -n 1
}
boot_start="$(start_of "$root/platform/etc/init.d/ab-boot")"
seed_start="$(start_of "$root/platform/etc/init.d/ab-net-seed")"
assert_eq "$seed_start" "16" "ac-5 ab-net-seed declares START=16"
[ "${boot_start:-0}" -lt "${seed_start:-0}" ] &&
    assert_eq "after-ab-boot" "after-ab-boot" "ac-5 the seed runs after ab-boot" ||
    assert_eq "start=${boot_start:-?}" "start<${seed_start}" "ac-5 the seed runs after ab-boot"
[ "${seed_start:-99}" -lt 20 ] &&
    assert_eq "before-network" "before-network" "ac-5 the seed runs before network (S20)" ||
    assert_eq "start=${seed_start}" "start<20" "ac-5 the seed runs before network (S20)"

# The library and the hook are part of the platform layer, not of the rootfs: the
# rootfs has to stay byte identical to upstream.
assert_file_exists "$root/platform/lib/net-defaults.sh" "ac-5 the library ships in the platform layer"
assert_file_exists "$root/platform/etc/init.d/ab-net-seed" "ac-5 the hook ships in the platform layer"

finish
