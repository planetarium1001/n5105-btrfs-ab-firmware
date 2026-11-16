#!/usr/bin/env bash
# Module: device
# Offline unit test for the network probe's WAN SSH rule count in scripts/device/probes.sh.
#
# The defect this test exists for (measured on the lab machine 2026-11-16): the probe counted
# the rules matching `tcp dport 22` with a plain substring grep. A machine whose ruleset also
# carries `tcp dport 2222` (a lab SSH rule) therefore counted 2 while it has exactly one
# 22/tcp rule, and because the count is compared against AB_PROBE_WAN_SSH_RULES (=1), a
# healthy machine failed the network probe permanently. The pattern has to stop at the end of
# the port number instead of matching a prefix of it.
#
#   ac-12 the network probe does not count `tcp dport 2222` as a 22/tcp rule
#
# Nothing here touches a device: --dry-run prints the exact remote script the probe would
# send, which is the seam this judgement lives behind.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probes="$root/scripts/device/probes.sh"
assert_file_exists "$probes" "the probe driver exists"

# --dry-run prints the remote script for each probe instead of running it. The network
# script is the one that computes wan_ssh.
out=$(AB_DRY_RUN=1 AB_KEY="$probes" AB_HOST="root@127.0.0.1" \
    sh "$probes" --probe network --dry-run 2>&1)

# The remote script must hand the counted value to the caller under the wan_ssh key: a
# missing line would make the assertion read "unknown" instead of a number.
assert_contains "$out" "wan_ssh=" "ac-12 the network probe reports a wan_ssh count"

# The counted expression must be anchored so 2222 cannot satisfy it. The literal anchored
# form is asserted rather than the behaviour, because the behaviour needs a real nft ruleset;
# what can be checked offline is that the pattern the driver ships is the anchored one.
assert_contains "$out" "22([^0-9]|$)" \
    "ac-12 the wan_ssh pattern anchors the port so 2222 is not counted"

# A loose pattern (bare `grep -c 'tcp dport 22'`) must be gone: it is the defect, and leaving
# it anywhere in the network script means the probe can regress to counting 2222 again.
if printf '%s\n' "$out" | grep -qF "grep -c 'tcp dport 22'"; then
    assert_eq "loose-pattern-present" "loose-pattern-absent" \
        "ac-12 the unanchored tcp dport 22 count is gone"
else
    assert_eq "loose-pattern-absent" "loose-pattern-absent" \
        "ac-12 the unanchored tcp dport 22 count is gone"
fi

finish
