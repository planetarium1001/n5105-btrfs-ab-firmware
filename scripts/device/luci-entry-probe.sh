#!/bin/sh
# luci-entry-probe.sh - is the LuCI entry usable on this machine?
#
#   luci-entry-probe.sh                          # every probe, one line each
#   luci-entry-probe.sh --probe admin            # repeatable, one probe per line
#   AB_DRY_RUN=1 luci-entry-probe.sh             # print the ssh call, touch nothing
#
# Output shape, one line per probe:
#
#   probe=<frontdoor|login-page|login-post|admin|assets> ac=ac-7 status=<pass|fail|skip> <fact=value...>
#
#   frontdoor   GET / answers 200 and its body points at cgi-bin/luci/ - the landing page
#   login-page  an unauthenticated GET /cgi-bin/luci/ answers 403 AND carries
#               `x-luci-login-required: yes` AND the body is the login form
#               (`luci_username`). That combination is what an unauthenticated client is
#               *supposed* to get; a bare 403 without those two markers is uhttpd's own
#               error page and is a FAIL.
#   login-post  POST luci_username=root&luci_password=<empty> answers 302, sets a
#               `sysauth_http` cookie and names a `location:` - the session was created
#   admin       GET /cgi-bin/luci/admin/status/overview with that cookie answers 200
#   assets      GET /luci-static/bootstrap/cascade.css and /luci-static/resources/luci.js
#               answer 200 without a session - the login page can render itself
#
# Exit status: 0 every requested probe passed, 1 at least one failed, 3 nothing failed but
# at least one probe could not be answered (no machine, no http client), 2 bad usage.
#
# Why 403 on /cgi-bin/luci/ is the pass condition
# ----------------------------------------------
# LuCI answers an unauthenticated request with the login page and marks it
# `403 Forbidden` + `X-LuCI-Login-Required: yes` on purpose (ucode dispatcher
# /usr/share/ucode/luci/dispatcher.uc: `http.status(403,'Forbidden')` right before it
# renders the theme's `sysauth` template). A probe that reads only the status code reports
# a healthy machine as broken; a probe that reads the body and the header separates
# "LuCI wants a login" from "the web server cannot run the handler at all". Do not
# 'fix' the 403 by disabling the login - that 403 is the authentication guard itself.
#
# What this probe does not decide
# -------------------------------
# - It does not drive a browser: it proves the HTTP/CGI/session chain end to end (status
#   codes, cookie, admin page), not that the JavaScript bundle runs.
# - It logs in as `root` with an empty password, which this image allows (OpenWrt's
#   blank-root-password patches). A machine with a password set answers the login POST
#   with 403 and no cookie; that is a FAIL of `login-post` with the password as the likely
#   cause, not a broken entry.
# - The requests run on the machine itself over 127.0.0.1, because port 80 is firewalled
#   on the WAN side (measured 2026-11-17: refused from the LAN-side host). Nothing here
#   says anything about reachability from a specific zone.
#
# Environment: AB_HOST (root@host), AB_KEY (private key), AB_LUCI_HOST (127.0.0.1),
#              AB_LUCI_PORT (80), AB_SESSION_PATH (/tmp/luci-sessions), AB_DRY_RUN.
#
# This probe is a device driver and lives next to the others in scripts/device/. The 403
# it treats as a pass is why the task's acceptance criterion was rewritten: the entry is
# usable when an unauthenticated request is answered with the login page and the same
# entry answers 200 once a session exists (see docs/troubleshooting.md).

set -u

AB_HOST=${AB_HOST:-root@192.168.2.49}
AB_REPO_ROOT=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd) || AB_REPO_ROOT=.
AB_KEY=${AB_KEY:-${AB_REPO_ROOT}/.workflow/secrets/n5105-device-ssh-key}
AB_LUCI_HOST=${AB_LUCI_HOST:-127.0.0.1}
AB_LUCI_PORT=${AB_LUCI_PORT:-80}
AB_SESSION_PATH=${AB_SESSION_PATH:-/tmp/luci-sessions}
AB_SSH_CONNECT_TIMEOUT=${AB_SSH_CONNECT_TIMEOUT:-8}
DRY_RUN=${AB_DRY_RUN:-0}

ALL_PROBES="frontdoor login-page login-post admin assets"
SELECTED=""

usage() {
    cat <<'USAGE'
usage: luci-entry-probe.sh [--probe <name>]... [--dry-run]

  --probe <name>  run one probe; repeatable. One of:
                  frontdoor login-page login-post admin assets   (default: all)
  --dry-run       print the ssh call and exit; same as AB_DRY_RUN=1

Environment: AB_HOST (root@host), AB_KEY (private key), AB_LUCI_HOST (127.0.0.1),
             AB_LUCI_PORT (80), AB_SESSION_PATH (/tmp/luci-sessions), AB_DRY_RUN.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --probe) SELECTED="$SELECTED ${2:?--probe needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'luci-entry-probe: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$SELECTED" ] || SELECTED=$ALL_PROBES

for _p in $SELECTED; do
    case " $ALL_PROBES " in
        *" $_p "*) : ;;
        *)
            printf 'luci-entry-probe: unknown probe: %s\n' "$_p" >&2
            exit 2
            ;;
    esac
done

_run_ssh() {
    if [ "$DRY_RUN" = "1" ]; then
        printf 'dry-run: ssh %s %s\n' "$AB_HOST" "$1" >&2
        return 0
    fi
    ssh -i "$AB_KEY" \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PubkeyAuthentication=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
        "$AB_HOST" "$1"
}

# The remote half. One ssh call, one TSV field per answer; the local half decides.
# CRLF matters: uhttpd does not parse a bare-LF request line. Every response is written
# to a file first, because a pipe from `nc` loses the race against a CGI that needs a few
# hundred milliseconds to answer.
_remote() {
    cat <<REMOTE
set -u
H='$AB_LUCI_HOST'
P='$AB_LUCI_PORT'
SP='$AB_SESSION_PATH'
_t=/tmp/luci-entry-probe.\$\$

if ! command -v nc >/dev/null 2>&1; then
    printf 'nohttp\tno-nc\n'
    exit 0
fi

http() { # <raw request> ; the whole response lands in \$_t
    : >"\$_t"
    ( printf '%b' "\$1"; sleep 2 ) | nc "\$H" "\$P" >"\$_t" 2>/dev/null
    _n=0
    while [ ! -s "\$_t" ] && [ "\$_n" -lt 6 ]; do
        sleep 1
        _n=\$((_n + 1))
    done
}

code() { awk 'NR==1 { print \$2 }' "\$_t" 2>/dev/null; }
# grep -c already prints 0 when nothing matches (and then exits 1), so the no-match case
# must not print a second 0: one extra field shifts every column of the line it is in.
cnt() { grep -ic "\$1" "\$_t" 2>/dev/null || :; }

http 'GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'
printf 'frontdoor\t%s\t%s\n' "\$(code)" "\$(cnt 'cgi-bin/luci/')"

http 'GET /cgi-bin/luci/ HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'
printf 'login-page\t%s\t%s\t%s\n' "\$(code)" \
    "\$(cnt 'x-luci-login-required: *yes')" "\$(cnt 'luci_username')"

body='luci_username=root&luci_password='
http "POST /cgi-bin/luci/ HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \${#body}\r\n\r\n\$body"
post=\$(code)
sid=\$(sed -n 's/^[Ss]et-[Cc]ookie: *sysauth_http=\([0-9a-f]*\);.*/\1/p' "\$_t" | head -1)
loc=\$(cnt '^[Ll]ocation: */cgi-bin/luci')
printf 'login-post\t%s\t%s\t%s\n' "\$post" "\${sid:-none}" "\$loc"

if [ -n "\${sid:-}" ]; then
    http "GET /cgi-bin/luci/admin/status/overview HTTP/1.0\r\nHost: 127.0.0.1\r\nCookie: sysauth_http=\$sid\r\n\r\n"
    printf 'admin\t%s\n' "\$(code)"
    rm -f "\$SP/\$sid" 2>/dev/null
else
    printf 'admin\tnone\n'
fi

http 'GET /luci-static/bootstrap/cascade.css HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'
css=\$(code)
http 'GET /luci-static/resources/luci.js HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'
printf 'assets\t%s\t%s\n' "\$css" "\$(code)"

rm -f "\$_t" 2>/dev/null
REMOTE
}

out=$(_run_ssh "$(_remote)")
remote_rc=$?

# A dry run answered nothing on purpose; everything else that answered nothing is
# unanswered, and an unanswered probe is a skip, never a pass.
answered=1
[ "$DRY_RUN" = "1" ] && answered=0
[ "$remote_rc" -ne 0 ] && answered=0
[ -n "$out" ] || answered=0
case "$out" in *no-nc*) answered=0 ;; esac

_field() { # <row-name> <column> ; '-' when the row is missing
    _line=$(printf '%s\n' "$out" | awk -F'\t' -v n="$1" '$1 == n { print; exit }')
    if [ -z "$_line" ]; then
        printf '%s' '-'
        return 0
    fi
    printf '%s' "$_line" | cut -f"$2" | tr -d ' '
}

fail=0
skipped=0

_emit() { # <probe> <status> <facts>
    printf 'probe=%s ac=ac-7 status=%s %s\n' "$1" "$2" "$3"
    case "$2" in
        fail) fail=$((fail + 1)) ;;
        skip) skipped=$((skipped + 1)) ;;
    esac
}

for _p in $SELECTED; do
    if [ "$answered" -eq 0 ]; then
        _reason=no-machine
        [ "$DRY_RUN" = "1" ] && _reason=dry-run
        case "$out" in *no-nc*) _reason=no-http-client ;; esac
        _emit "$_p" skip "reason=${_reason}"
        continue
    fi
    case "$_p" in
        frontdoor)
            _c=$(_field frontdoor 2)
            _m=$(_field frontdoor 3)
            _s=fail
            [ "$_c" = "200" ] && [ "$_m" != "0" ] && [ "$_m" != "-" ] && _s=pass
            _emit "$_p" "$_s" "code=${_c} points_at_luci=${_m}"
            ;;
        login-page)
            _c=$(_field login-page 2)
            _h=$(_field login-page 3)
            _f=$(_field login-page 4)
            _s=fail
            [ "$_c" = "403" ] && [ "$_h" != "0" ] && [ "$_f" != "0" ] && _s=pass
            _emit "$_p" "$_s" "code=${_c} login_required_header=${_h} login_form=${_f}"
            ;;
        login-post)
            _c=$(_field login-post 2)
            _sd=$(_field login-post 3)
            _l=$(_field login-post 4)
            _s=fail
            [ "$_c" = "302" ] && [ "$_sd" != "none" ] && [ "$_sd" != "-" ] && [ "$_l" != "0" ] && _s=pass
            _emit "$_p" "$_s" "code=${_c} session=${_sd} location=${_l}"
            ;;
        admin)
            _c=$(_field admin 2)
            _s=fail
            [ "$_c" = "200" ] && _s=pass
            _emit "$_p" "$_s" "code=${_c}"
            ;;
        assets)
            _css=$(_field assets 2)
            _js=$(_field assets 3)
            _s=fail
            [ "$_css" = "200" ] && [ "$_js" = "200" ] && _s=pass
            _emit "$_p" "$_s" "cascade_css=${_css} luci_js=${_js}"
            ;;
    esac
done

[ "$fail" -gt 0 ] && exit 1
[ "$skipped" -gt 0 ] && exit 3
exit 0
