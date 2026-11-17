#!/usr/bin/env bash
# Module: device
# Offline test for scripts/device/luci-entry-probe.sh, the probe that answers ac-7.
#
# The defect this test exists for (measured on the lab machine 2026-11-17, task 20261117-03):
# the earlier acceptance criterion was "GET /cgi-bin/luci/ must not answer 403". LuCI answers
# an unauthenticated request with 403 *and* the login page on purpose - the ucode dispatcher
# calls http.status(403,'Forbidden') right before it renders the sysauth template and marks
# the answer with `x-luci-login-required: yes`. Reading only the status code therefore reports
# a healthy machine as broken, which is exactly what happened. The probe has to read the body
# and the header, and then prove the entry works by logging in.
#
#   ac-7 the LuCI entry is judged usable (login page + session + admin page), not by status alone
#
# A stub `ssh` stands in for the machine: the judging half is local, so the stub is the seam.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probe="$root/scripts/device/luci-entry-probe.sh"
assert_file_exists "$probe" "the LuCI entry probe exists"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# A stub ssh that prints the TSV the remote half would print. $1 is the host, $2 the script,
# so the stub only has to answer with the rows.
cat >"$tmp/bin/ssh" <<'STUB'
#!/bin/sh
cat "$STUB_ANSWER"
STUB
chmod +x "$tmp/bin/ssh"

# Healthy machine: 200 front page that points at the entry, 403 + login-required header + login
# form on the entry, a session on POST, 200 on the admin page, and the two assets.
cat >"$tmp/good.tsv" <<'TSV'
frontdoor	200	1
login-page	403	1	1
login-post	302	abc123	1
admin	200
assets	200	200
TSV

out=$(PATH="$tmp/bin:$PATH" STUB_ANSWER="$tmp/good.tsv" AB_KEY=/dev/null \
    sh "$probe" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "a healthy machine passes (exit 0)"
assert_contains "$out" "probe=frontdoor ac=ac-7 status=pass" "the front page passes"
assert_contains "$out" "probe=login-page ac=ac-7 status=pass" "403 with the login-required header is a pass"
assert_contains "$out" "probe=admin ac=ac-7 status=pass" "the admin page answers 200 after login"

# A bare 403 with neither marker is uhttpd's own error page, not the login page: that is the
# failure the old criterion could not tell apart from health.
cat >"$tmp/bare-403.tsv" <<'TSV'
frontdoor	200	1
login-page	403	0	0
login-post	none	none	0
admin	none
assets	200	200
TSV
out=$(PATH="$tmp/bin:$PATH" STUB_ANSWER="$tmp/bare-403.tsv" AB_KEY=/dev/null \
    sh "$probe" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "a bare 403 fails (exit 1)"
assert_contains "$out" "probe=login-page ac=ac-7 status=fail" "403 without the marker fails"

# Nothing answered is a skip: a probe that cannot reach the machine is not evidence.
cat >"$tmp/bin/ssh" <<'STUB'
#!/bin/sh
exit 255
STUB
chmod +x "$tmp/bin/ssh"
out=$(PATH="$tmp/bin:$PATH" AB_KEY=/dev/null sh "$probe" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "3" "an unreachable machine is a skip (exit 3)"
assert_contains "$out" "status=skip" "the skip is stated in the output"
