#!/usr/bin/env bash
# Module: device
# Offline test for scripts/device/ui-probe.sh, the driver that answers ac-14: after the
# whole WAN zone is opened, a person at the test host can reach the LuCI entry.
#
# The criteria this file pins, one case each, because each one is a way the row could pass
# while the machine is broken:
#
#   - every item PASS: firewall ACCEPT + homepage 200 with the form + login session + theme
#     asset 200 + a lease + the restored digest equal to the backup
#   - homepage answers 200 but carries no `<form`: the body is the criterion, not the code
#     (the loopback probe learned the same lesson with LuCI's deliberate 403)
#   - `/` is a redirect stub with no form of its own: the page it names is judged instead,
#     because that is what uhttpd's index looks like on this image and a criterion that
#     insisted on `<form` in `/` would fail a healthy machine
#   - the entry answers 403 *with* `x-luci-login-required: yes` and the login form: that is
#     the authentication guard, and the same 403 without the header is uhttpd's error page
#   - the login POST answers 403: a rendered form is not a working login
#   - the restored file does not match the backup sha256: the restore item fails even
#     though wan-open printed its own `ok`
#   - --dry-run: the plan, and zero ssh/curl calls; a planner that contacts the machine is
#     not a planner
#   - --host 127.0.0.1 is a usage error: ac-14 is measured from the test host, so a loopback
#     target would print ac-14 while measuring what luci-entry-probe.sh already measures
#
# A stub `ssh` stands in for the machine and a stub `curl` for the test host's HTTP client:
# the judging half of the driver is local, so those two processes are the whole seam.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probe="$root/scripts/device/ui-probe.sh"
assert_file_exists "$probe" "the external UI probe exists"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# --- the machine --------------------------------------------------------- #
# The driver only ever calls ssh non-interactively (true, one remote script), so the stub
# reads the last argument and answers the row that script would have printed. The open and
# restore scripts keep wan-open.sh's own fail text as their marker, which is why routing
# stays readable as the driver and the firewall driver gain lines.
cat >"$tmp/bin/ssh" <<'STUB'
#!/bin/sh
# Stub ssh: answer the TSV row the real remote half would print.
last=
for a in "$@"; do last=$a; done
if [ -n "${STUB_SSH_LOG:-}" ]; then
    printf '%s\n' "$last" >>"${STUB_SSH_LOG}"
fi
case "$last" in
    true) exit 0 ;;
    *ui-firewall*) cat "${STUB_FW:?stub ssh: STUB_FW}" ;;
    *ui-dhcp*) cat "${STUB_DHCP:?stub ssh: STUB_DHCP}" ;;
    *ui-sha256*) cat "${STUB_SHA:?stub ssh: STUB_SHA}" ;;
    *wan-restore*) cat "${STUB_WAN_RESTORE:?stub ssh: STUB_WAN_RESTORE}" ;;
    *wan-open*) cat "${STUB_WAN_OPEN:?stub ssh: STUB_WAN_OPEN}" ;;
    *'wan=input='*) cat "${STUB_WAN_STATUS:?stub ssh: STUB_WAN_STATUS}" ;;
    *)
        printf 'stub ssh: unhandled remote script\n' >&2
        exit 255
        ;;
esac
STUB
chmod +x "$tmp/bin/ssh"

# --- the test host ------------------------------------------------------- #
# curl writes the body and the headers to the files the driver names and prints the code,
# exactly as `curl -o ... -D ... -w '%{http_code}'` does. The URL decides the answer, so a
# case flips one variable instead of rewriting the stub.
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
out=
hdr=
post=
url=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=${2:-}; shift 2 ;;
        -D) hdr=${2:-}; shift 2 ;;
        -d) post=${2:-}; shift 2 ;;
        -m | -w) shift 2 ;;
        -*) shift ;;
        *)
            url=$1
            shift
            ;;
    esac
done
if [ -n "${STUB_CURL_LOG:-}" ]; then
    if [ -n "$post" ]; then verb=POST; else verb=GET; fi
    printf '%s %s\n' "$verb" "$url" >>"${STUB_CURL_LOG}"
fi
setcookie=no
location=no
required=no
case "$url" in
    */luci-static/*)
        code=${STUB_ASSET_CODE:-200}
        body='/* theme */'
        ;;
    */cgi-bin/luci/*)
        if [ -n "$post" ]; then
            code=${STUB_LOGIN_CODE:-302}
            body='<html><body>signed in</body></html>'
            setcookie=${STUB_LOGIN_COOKIE:-yes}
            location=${STUB_LOGIN_LOCATION:-yes}
        else
            code=${STUB_ENTRY_CODE:-200}
            body=${STUB_ENTRY_BODY:-'<html><body><form id="luci-login" method="post"></form></body></html>'}
            required=${STUB_ENTRY_REQUIRED:-no}
        fi
        ;;
    *)
        code=${STUB_HOME_CODE:-200}
        body=${STUB_HOME_BODY:-'<html><body><form id="luci-login" action="/cgi-bin/luci/"></form></body></html>'}
        ;;
esac
if [ -n "$out" ]; then
    printf '%s\n' "$body" >"$out"
fi
if [ -n "$hdr" ]; then
    {
        printf 'HTTP/1.1 %s something\r\n' "$code"
        if [ "$setcookie" = yes ]; then
            printf 'Set-Cookie: sysauth_http=abc123; path=/; HttpOnly\r\n'
        fi
        if [ "$location" = yes ]; then
            printf 'Location: /cgi-bin/luci/admin/status/overview\r\n'
        fi
        if [ "$required" = yes ]; then
            printf 'X-LuCI-Login-Required: yes\r\n'
        fi
        printf '\r\n'
    } >"$hdr"
fi
printf '%s\n' "$code"
STUB
chmod +x "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"

# --- the answers --------------------------------------------------------- #
printf 'wan-open=ok zone=@zone[1] input=REJECT->ACCEPT backup=/root/firewall.before-open-wan.bak\n' \
    >"$tmp/wan-open.answer"
printf 'wan-restore=ok input=REJECT sha256=verified\n' >"$tmp/wan-restore.answer"
printf 'wan=input=ACCEPT zone=@zone[1] backup=/root/firewall.before-open-wan.bak\n' \
    >"$tmp/wan-status.answer"
printf 'ui-firewall\tACCEPT\t@zone[1]\n' >"$tmp/fw-accept.answer"
printf 'ui-firewall\tREJECT\t@zone[1]\n' >"$tmp/fw-reject.answer"
printf 'ui-dhcp\trunning\t0\t2\t1\t100\t150\n' >"$tmp/dhcp-leased.answer"
printf 'ui-dhcp\trunning\t0\t0\t0\t100\t150\n' >"$tmp/dhcp-empty.answer"
digest=8d3f0c2a1b4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8
printf 'ui-sha256\t%s\t%s\n' "$digest" "$digest" >"$tmp/sha-equal.answer"
printf 'ui-sha256\tdeadbeef\tcafebabe\n' >"$tmp/sha-mismatch.answer"

# Per-case knobs the wrapper below forwards. The defaults are a healthy machine.
STUB_FW="$tmp/fw-accept.answer"
STUB_DHCP="$tmp/dhcp-leased.answer"
STUB_SHA="$tmp/sha-equal.answer"
STUB_HOME_CODE=200
STUB_HOME_BODY='<html><body><form id="luci-login" action="/cgi-bin/luci/"></form></body></html>'
STUB_LOGIN_CODE=302
STUB_LOGIN_COOKIE=yes
STUB_LOGIN_LOCATION=yes
STUB_ASSET_CODE=200
STUB_ENTRY_CODE=200
STUB_ENTRY_BODY='<html><body><form id="luci-login" method="post"></form></body></html>'
STUB_ENTRY_REQUIRED=no
STUB_SSH_LOG=""
STUB_CURL_LOG=""
EXTRA_ENV_STR=""

probe_run() {
    env $EXTRA_ENV_STR \
        PATH="$tmp/bin:$PATH" \
        AB_UI_CURL="$tmp/bin/curl" \
        AB_KEY=/dev/null \
        STUB_FW="$STUB_FW" \
        STUB_DHCP="$STUB_DHCP" \
        STUB_SHA="$STUB_SHA" \
        STUB_WAN_OPEN="$tmp/wan-open.answer" \
        STUB_WAN_RESTORE="$tmp/wan-restore.answer" \
        STUB_WAN_STATUS="$tmp/wan-status.answer" \
        STUB_HOME_CODE="$STUB_HOME_CODE" \
        STUB_HOME_BODY="$STUB_HOME_BODY" \
        STUB_LOGIN_CODE="$STUB_LOGIN_CODE" \
        STUB_LOGIN_COOKIE="$STUB_LOGIN_COOKIE" \
        STUB_LOGIN_LOCATION="$STUB_LOGIN_LOCATION" \
        STUB_ASSET_CODE="$STUB_ASSET_CODE" \
        STUB_ENTRY_CODE="$STUB_ENTRY_CODE" \
        STUB_ENTRY_BODY="$STUB_ENTRY_BODY" \
        STUB_ENTRY_REQUIRED="$STUB_ENTRY_REQUIRED" \
        STUB_SSH_LOG="$STUB_SSH_LOG" \
        STUB_CURL_LOG="$STUB_CURL_LOG" \
        $EXTRA_ENV_STR \
        sh "$probe" "$@"
}

# --- 1. a healthy machine: every item PASS, one verdict ------------------ #
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 a healthy machine passes (exit 0)"
assert_contains "$out" "ui-probe=pass host=192.168.2.49 probes=6 failed=0 gap=0" \
    "ac-14 the verdict line counts six items and no failure"
for item in firewall homepage login assets dhcp restore; do
    assert_contains "$out" "probe=$item ac=ac-14 status=pass" \
        "ac-14 $item passes on a healthy machine"
done
assert_contains "$out" "probe=firewall ac=ac-14 status=pass zone=@zone[1] input=ACCEPT" \
    "ac-14 the firewall row carries the measured ACCEPT value"
assert_contains "$out" "probe=homepage ac=ac-14 status=pass code=200 form=1 luci=1" \
    "ac-14 the homepage needs both the 200 and the form markers"
assert_contains "$out" "via=/ " "ac-14 a front door that carries the form is judged on itself"
assert_contains "$out" "probe=login ac=ac-14 status=pass code=302 session=1" \
    "ac-14 the login row proves a session, not a page"
assert_contains "$out" "probe=assets ac=ac-14 status=pass css=200 path=/luci-static/argon/css/cascade.css" \
    "ac-14 the theme asset uses the follow-samples criterion"
assert_contains "$out" "probe=dhcp ac=ac-14 status=pass dnsmasq=running ignore=0 leases=2" \
    "ac-14 a lease is evidence, not an assumption"
assert_contains "$out" "probe=restore ac=ac-14 status=pass input=REJECT sha256_match=yes" \
    "ac-14 the restore row verifies the restored digest"

# --- 2. 200 with no form marker is a FAIL -------------------------------- #
STUB_HOME_BODY='<html><body>Welcome to LuCI</body></html>'
STUB_ENTRY_BODY='<html><body>Welcome to LuCI</body></html>'
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 a homepage without the form fails (exit 1)"
assert_contains "$out" "probe=homepage ac=ac-14 status=fail code=200 form=0 luci=1" \
    "ac-14 200 alone is not the criterion"
assert_contains "$out" "entry=200 entry_form=0" \
    "ac-14 the page the front door points at is judged too, and also carries no form"
assert_contains "$out" "probe=restore ac=ac-14 status=pass" \
    "ac-14 the restore still runs after a failed item"
STUB_HOME_BODY='<html><body><form id="luci-login" action="/cgi-bin/luci/"></form></body></html>'
STUB_ENTRY_BODY='<html><body><form id="luci-login" method="post"></form></body></html>'

# --- 2b. a redirect stub front door is followed once, not failed --------- #
# What uhttpd's index actually is on this image: a page that points at the entry and renders
# no form of its own. A criterion that insisted on `<form` in `/` would fail a healthy
# machine, so the page it names is fetched and judged the same way.
STUB_HOME_BODY='<html><head><meta http-equiv="refresh" content="0; URL=/cgi-bin/luci/"></head></html>'
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 a front door that only redirects still passes (exit 0)"
assert_contains "$out" "probe=homepage ac=ac-14 status=pass code=200 form=0" \
    "ac-14 the front door is judged 200 even without the form"
assert_contains "$out" "entry=200 entry_form=1" \
    "ac-14 the entry's own markers are what the pass rests on"
assert_contains "$out" "via=/cgi-bin/luci/" \
    "ac-14 the row names which page carried the form"

# --- 2c. LuCI's deliberate 403 with the login page is a pass ------------- #
# The unauthenticated answer IS 403 plus the login form plus the header; a bare 403 without
# them is uhttpd's error page and is not (the loopback probe's criterion, same reading).
STUB_ENTRY_CODE=403
STUB_ENTRY_REQUIRED=yes
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 403 with the login page is the guard, not a failure"
assert_contains "$out" "entry=403 entry_form=1 entry_header=1" \
    "ac-14 the header is what separates the guard from an error page"
STUB_ENTRY_REQUIRED=no
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 a bare 403 without the header fails (exit 1)"
STUB_ENTRY_CODE=200
STUB_HOME_BODY='<html><body><form id="luci-login" action="/cgi-bin/luci/"></form></body></html>'

# --- 3. a login answered 403 is a FAIL ----------------------------------- #
STUB_LOGIN_CODE=403
STUB_LOGIN_COOKIE=no
STUB_LOGIN_LOCATION=no
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 a rejected login fails (exit 1)"
assert_contains "$out" "probe=login ac=ac-14 status=fail code=403 session=0 location=0 via=rejected" \
    "ac-14 403 is named as a rejection, not a session"
STUB_LOGIN_CODE=302
STUB_LOGIN_COOKIE=yes
STUB_LOGIN_LOCATION=yes

# --- 4. a restored file that is not the backup is a FAIL ----------------- #
STUB_SHA="$tmp/sha-mismatch.answer"
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 a restore whose digest does not match fails (exit 1)"
assert_contains "$out" "probe=restore ac=ac-14 status=fail reason=sha256-mismatch" \
    "ac-14 sha256(restored) != sha256(backup) is stated as the reason"
STUB_SHA="$tmp/sha-equal.answer"

# --- 5. the firewall row is a measurement -------------------------------- #
STUB_FW="$tmp/fw-reject.answer"
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 a zone that did not open fails (exit 1)"
assert_contains "$out" "probe=firewall ac=ac-14 status=fail zone=@zone[1] input=REJECT" \
    "ac-14 REJECT is reported as measured, not as an open verdict"
STUB_FW="$tmp/fw-accept.answer"

# --- 6. DHCP with no lease reports the evidence that settles it ---------- #
STUB_DHCP="$tmp/dhcp-empty.answer"
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-14 no lease fails (exit 1)"
assert_contains "$out" "probe=dhcp ac=ac-14 status=fail dnsmasq=running ignore=0 leases=0 dhcpack=0 range=100-150" \
    "ac-14 a zero lease row carries the facts that explain it"
assert_contains "$out" "next: plug a client into a LAN port" \
    "ac-14 the row names the way to settle it"
STUB_DHCP="$tmp/dhcp-leased.answer"

# --- 7. --dry-run contacts nothing --------------------------------------- #
rm -f "$tmp/ssh.calls" "$tmp/curl.calls"
STUB_SSH_LOG="$tmp/ssh.calls"
STUB_CURL_LOG="$tmp/curl.calls"
EXTRA_ENV_STR="AB_DRY_RUN=1"
out=$(probe_run 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 --dry-run exits 0"
assert_contains "$out" "ui-probe=dry-run host=192.168.2.49 probes=6" \
    "ac-14 --dry-run prints a dry-run verdict"
assert_contains "$out" "wan-open.sh --open" \
    "ac-14 the plan reuses the firewall driver instead of reimplementing it"
assert_eq "$([ -s "$tmp/ssh.calls" ] && echo called || echo none)" "none" \
    "ac-14 --dry-run sends no ssh"
assert_eq "$([ -s "$tmp/curl.calls" ] && echo called || echo none)" "none" \
    "ac-14 --dry-run sends no HTTP"
STUB_SSH_LOG=""
STUB_CURL_LOG=""
EXTRA_ENV_STR=""

# --- 8. the single-action modes ----------------------------------------- #
out=$(probe_run --open 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 --open exits 0"
assert_contains "$out" "wan-open=ok zone=@zone[1] input=REJECT->ACCEPT" \
    "ac-14 --open prints wan-open's own verdict"
assert_contains "$out" "ui-probe=open host=192.168.2.49 input=REJECT->ACCEPT" \
    "ac-14 --open still ends with one ui-probe= line"

out=$(probe_run --status 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 --status exits 0"
assert_contains "$out" "ui-probe=status host=192.168.2.49 input=ACCEPT zone=@zone[1]" \
    "ac-14 --status reports the zone and the backup"

out=$(probe_run --restore 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 --restore exits 0"
assert_contains "$out" "probe=restore ac=ac-14 status=pass" \
    "ac-14 --restore verifies the digest on its own"
assert_contains "$out" "ui-probe=pass host=192.168.2.49 probes=1" \
    "ac-14 --restore has one item and one verdict"

# --- 9. --host reaches both halves -------------------------------------- #
rm -f "$tmp/curl.calls"
STUB_CURL_LOG="$tmp/curl.calls"
out=$(probe_run --host 192.0.2.7 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-14 --host runs against the named machine"
assert_contains "$out" "ui-probe=pass host=192.0.2.7" \
    "ac-14 the verdict names the host that was measured"
assert_contains "$(cat "$tmp/curl.calls")" "GET http://192.0.2.7:80/" \
    "ac-14 the HTTP half uses the host, not the machine's loopback"
STUB_CURL_LOG=""

# --- 10. usage errors --------------------------------------------------- #
out=$(sh "$probe" --bogus 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "ac-14 an unknown argument exits 2"
assert_contains "$out" "unknown argument: --bogus" "ac-14 the usage error names the argument"

out=$(sh "$probe" --host 127.0.0.1 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "ac-14 a loopback target exits 2"
assert_contains "$out" "not over loopback" \
    "ac-14 loopback is refused because ac-14 is measured from the test host"

finish
