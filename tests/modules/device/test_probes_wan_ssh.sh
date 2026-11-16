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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

# --------------------------------------------------------------------------- #
# --dry-run is a plan, not a run: it writes nothing
#
# The defect this locks (measured on the lab machine 2026-11-17): the probe's per-probe
# emitter went through lib.sh's record() even under --dry-run, so a plan appended eight
# GAP rows to AB_PROBE_RESULTS and created the results directory on the way. The operator
# had to archive the file and delete it before the real run, because a real row mixed with
# those eight GAPs is a results file nobody can read as evidence.
#
# Two halves: a dry run touches neither the results file nor the evidence log, and a run
# that really measured still writes its row - a "fix" that simply deleted record() would
# pass the first half and break the acceptance.
# --------------------------------------------------------------------------- #
dry_root="$tmp/dry"
dry_results="$dry_root/nested/probe-results.tsv"
dry_evidence="$dry_root/evidence.log"
dry_out=$(AB_DRY_RUN=1 AB_KEY="$probes" AB_HOST="root@127.0.0.1" \
    AB_PROBE_RESULTS="$dry_results" AB_EVIDENCE_LOG="$dry_evidence" \
    sh "$probes" --dry-run 2>&1)
dry_rc=$?
assert_eq "$dry_rc" "0" "dry-run a plan still exits 0"
assert_contains "$dry_out" "result=dry-run" "dry-run the summary says the run was a plan"
assert_eq "$(printf '%s\n' "$dry_out" | grep -c '^probe=.*status=skip reason=dry-run')" "8" \
    "dry-run the plan names every selected probe as a skip"
if [ -e "$dry_results" ]; then
    assert_eq "results-written" "no-results-file" \
        "dry-run a plan appends no results row (eight GAPs used to land here)"
else
    assert_eq "no-results-file" "no-results-file" \
        "dry-run a plan appends no results row (eight GAPs used to land here)"
fi
if [ -d "$dry_root" ]; then
    assert_eq "results-dir-created" "results-dir-absent" \
        "dry-run a plan does not create the results directory"
else
    assert_eq "results-dir-absent" "results-dir-absent" \
        "dry-run a plan does not create the results directory"
fi
if [ -e "$dry_evidence" ]; then
    assert_eq "evidence-written" "no-evidence" \
        "dry-run a plan writes no evidence line"
else
    assert_eq "no-evidence" "no-evidence" \
        "dry-run a plan writes no evidence line"
fi

# The counterweight: a machine that does not answer still produces a row, so the guard
# above cannot regress into "record() is never called".
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
exit 255
STUB
chmod +x "$stub_bin/ssh"
real_results="$tmp/real/probe-results.tsv"
PATH="$stub_bin:$PATH" AB_KEY="$probes" AB_HOST="root@127.0.0.1" \
    AB_PROBE_RESULTS="$real_results" sh "$probes" --probe grow >/dev/null 2>&1
real_rc=$?
assert_eq "$real_rc" "1" "dry-run a machine that does not answer makes the probe fail"
assert_eq "$(awk -F'\t' 'NR == 1 { print $1, $2, $3 }' "$real_results" 2>/dev/null)" \
    "grow FAIL -" "dry-run a measured run still writes its results row"

finish
