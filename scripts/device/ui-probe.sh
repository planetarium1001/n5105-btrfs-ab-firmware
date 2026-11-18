#!/bin/sh
# ui-probe.sh - can a person at another host on the bench LAN open the LuCI entry?
#
#   ui-probe.sh                        # open the WAN zone, probe, restore: one line per item
#   ui-probe.sh --open                 # only open the WAN zone (wan-open.sh's verdict line)
#   ui-probe.sh --restore              # only restore, and verify the restored digest
#   ui-probe.sh --status               # what the zone and the backup say now
#   ui-probe.sh --host 192.168.2.49    # a different machine (user@host is accepted)
#   ui-probe.sh --dry-run              # the plan; no ssh, no HTTP, no firewall change
#
# One line per item, then one verdict line:
#
#   probe=<firewall|homepage|login|assets|dhcp|restore> ac=ac-14 status=<pass|fail|gap|skip> <fact=value...>
#   ui-probe=<pass|fail|gap|open|status|dry-run> host=<host> <facts...>
#
#   firewall  after wan-open.sh ran, the zone named `wan` has uci input=ACCEPT. The value
#             is read back with a second, independent ssh call rather than trusted from
#             wan-open's own verdict, so the row is a measurement and not an echo
#   homepage  GET / from the TEST HOST answers 200 and the body carries both `<form` and
#             `luci`. The status code alone is not the criterion; see below. uhttpd's index
#             may be a redirect stub, so when `/` has no form the page it names is fetched
#             once and judged the same way, `via=` says which page answered, and an
#             unauthenticated 403 counts only with LuCI's `x-luci-login-required: yes`
#   login     POST luci_username=<user>&luci_password=<password> answers a redirect or a
#             `sysauth_http` session cookie, and never 401/403. This is an HTTP form POST,
#             never an interactive ssh session; see below
#   assets    GET /luci-static/argon/css/cascade.css answers 200, the criterion
#             tests/fixtures/follow-samples.json already fixes for the theme
#   dhcp      the LAN really handed out a lease: dnsmasq runs, dhcp.lan is not ignored,
#             and the lease table (or the ring log) carries an entry. Zero leases is
#             printed with the configuration facts beside it, so "nobody asked" and "the
#             server is off" cannot be read as the same thing
#   restore   wan-open.sh --restore put the firewall back and
#             sha256(/etc/config/firewall) equals sha256(/root/firewall.before-open-wan.bak)
#
# Exit status: 0 every item passed, 1 at least one failed or the requested step failed,
# 2 usage, 4 no failure but at least one question could not be answered (no machine, no
# HTTP client). `skip` never makes a run pass and never makes it fail: it is an item this
# run deliberately did not measure (a dry run, or a restore that had nothing to undo).
#
# Why this driver exists next to luci-entry-probe.sh
# --------------------------------------------------
# luci-entry-probe.sh asks the same questions over 127.0.0.1 on the machine itself. That is
# the right probe for "is the entry usable" and it is blind to zone policy: loopback is
# never filtered. ac-14 is the other half - a person at another host on the lab LAN types
# the address and gets the UI - and that path crosses the WAN zone's `input` policy, so it
# can only be measured from outside, and only after the zone is opened.
#
# Why the whole zone and not a list of ports
# ------------------------------------------
# Enumerating 22/80/443 turns every missing rule into a fault that reads like a product
# defect ("the UI does not load") when it is a firewall answer. scripts/device/wan-open.sh
# already owns that bench edit, its backup and its restore, so this driver calls it and
# never edits /etc/config/firewall itself. The backup path wan-open reports is reused for
# the restore assertion, so the two drivers cannot drift about where the backup lives.
#
# Why 200 plus body markers, not the status code
# ----------------------------------------------
# The loopback probe learned this the hard way: LuCI's unauthenticated answer is a *403*
# that carries the login form on purpose, and a bare 403 without it is uhttpd's own error
# page, so the number alone cannot separate the two. The same trap exists from the WAN side
# in both directions - a landing page can answer 200 with an error body, and a login page
# that renders is not a login that works - so this driver reads the body of `/` for the
# literal `<form` and `luci` markers, then *submits* the form and asks for a session, and
# only then judges the theme asset.
#
# Why the login is an HTTP POST and not an interactive ssh session
# ----------------------------------------------------------------
# docs/known-limitations.md records the dropbear 2025.89 defect behind every false
# "interactive login is broken" reading: `ssh -tt host '<cmd>' </dev/null` closes the pty
# master before the child owns it. The web login is a different mechanism, and every ssh
# call here is non-interactive: this driver never allocates a pty and never writes that
# form. Driving the login the pty way would measure the same client mistake a second time.
#
# Why DHCP is a row and not an assumption
# ---------------------------------------
# The LAN is the device's own 192.168.100.0/24 while the test host reaches the machine on
# its WAN address, so no interface on the test host is assumed to be cabled to br-lan. The
# lease decision is read from the machine's own table and ring log over the same
# non-interactive ssh, and a zero-lease answer is a FAIL that carries `dnsmasq`, `ignore`
# and `range` in the row. The driver does not start a DHCP client on the test host: which
# of its interfaces sits on that LAN is not something a probe may assume.
#
# Why the restore is part of the verdict and not cleanup
# ------------------------------------------------------
# A probe that leaves the bench firewall open has changed the thing it measured, and the
# next probe would then read a machine somebody else prepared. So the restore is the sixth
# item, and its row is PASS only when sha256(restored) equals sha256(backup). The one case
# where nothing is restored is a zone that was already ACCEPT before this run: restoring
# then would close a bench state this driver did not open. If the machine stops answering
# before the restore can run, the restore row is a GAP and names `--restore` as the next
# command: that is the one state in which this driver leaves the bench open, and the row
# says so instead of hiding it.
#
# Environment: AB_HOST (root@host), AB_KEY, AB_UI_HOST (host part of AB_HOST), AB_UI_PORT
#              (80), AB_UI_CURL (curl), AB_UI_TIMEOUT (10 s), AB_UI_USER (root),
#              AB_UI_PASSWORD (empty), AB_UI_ENTRY (/cgi-bin/luci/),
#              AB_UI_ASSET (/luci-static/argon/css/cascade.css),
#              AB_UI_LEASES (/tmp/dhcp.leases), AB_EVIDENCE_LOG, AB_DRY_RUN.
set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
: "${AB_REPO_ROOT:=$(cd "${DEVICE_DIR}/../.." && pwd)}"
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

MODE=probe
DRY_RUN=${AB_DRY_RUN:-0}
UI_PORT=${AB_UI_PORT:-80}
CURL=${AB_UI_CURL:-curl}
TIMEOUT=${AB_UI_TIMEOUT:-10}
UI_USER=${AB_UI_USER:-root}
UI_PASSWORD=${AB_UI_PASSWORD:-}
ASSET=${AB_UI_ASSET:-/luci-static/argon/css/cascade.css}
# The entry, not `/`: on this image uhttpd's index is a redirect stub, so the login page an
# unauthenticated client gets is the entry's answer.
UI_ENTRY=${AB_UI_ENTRY:-/cgi-bin/luci/}
LEASES=${AB_UI_LEASES:-/tmp/dhcp.leases}
HOST_ARG=""

PROBES=0
FAILED=0
GAPS=0

usage() {
    cat <<'USAGE'
usage: ui-probe.sh [--open|--restore|--status] [--host <host>] [--dry-run]

  --open      open the WAN zone on the bench machine (wan-open.sh --open)
  --restore   restore the firewall and verify the restored sha256 against the backup
  --status    print the WAN zone's input value and whether a backup exists
  --host <h>  the machine to probe; `user@host` is accepted, the HTTP half uses the host
  --dry-run   print the plan and exit; no ssh, no HTTP, no firewall change
  -h, --help  this text

Default (no mode flag): open, five probes, restore, one verdict line.
Environment: AB_HOST, AB_KEY, AB_UI_HOST, AB_UI_PORT (80), AB_UI_CURL (curl),
             AB_UI_TIMEOUT (10), AB_UI_USER (root), AB_UI_PASSWORD (empty),
             AB_UI_ENTRY (/cgi-bin/luci/), AB_UI_ASSET, AB_UI_LEASES,
             AB_EVIDENCE_LOG, AB_DRY_RUN.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --open) MODE=open; shift ;;
        --restore) MODE=restore; shift ;;
        --status) MODE=status; shift ;;
        --host)
            [ $# -ge 2 ] || { printf 'ui-probe.sh: --host needs a value\n' >&2; usage >&2; exit 2; }
            HOST_ARG=$2
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'ui-probe.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${UI_PORT}" in
    '' | *[!0-9]*)
        printf 'ui-probe.sh: AB_UI_PORT must be a port number, got: %s\n' "${UI_PORT}" >&2
        exit 2
        ;;
esac

if [ -n "${HOST_ARG}" ]; then
    case "${HOST_ARG}" in
        *@*) AB_HOST=${HOST_ARG}; UI_HOST=${HOST_ARG##*@} ;;
        *) AB_HOST=root@${HOST_ARG}; UI_HOST=${HOST_ARG} ;;
    esac
else
    UI_HOST=${AB_UI_HOST:-${AB_HOST##*@}}
fi

# The measurement is defined as "from the test host, over the network". A loopback target
# would turn this driver back into luci-entry-probe.sh while still printing ac-14, which is
# exactly the confusion the two drivers exist to avoid.
case "${UI_HOST}" in
    127.* | localhost | ::1 | \[::1\])
        printf 'ui-probe.sh: %s is the machine this driver runs on; ac-14 is measured from the test host, not over loopback\n' \
            "${UI_HOST}" >&2
        exit 2
        ;;
esac

# The child wan-open.sh is a separate process and has to reach the same machine.
export AB_HOST AB_KEY AB_SSH_CONNECT_TIMEOUT
[ "${DRY_RUN}" = "1" ] && export AB_DRY_RUN=1

UI_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ab-ui-probe.XXXXXX" 2>/dev/null) || UI_TMP=""
if [ -z "${UI_TMP}" ]; then
    printf 'ui-probe.sh: mktemp failed; nothing was probed\n' >&2
    exit 2
fi
trap 'rm -rf "${UI_TMP}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# _kv <text> <key>: the value of `key=` in the first line carrying it, empty when absent.
# wan-open's verdict lines are `key=value` tokens, and both the open and the status line
# carry the fields this driver needs (input, zone, backup, reason).
_kv() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^${2}=//p" | head -n 1
}

# _kv_status <text> <key>: wan-open's --status line begins `wan=input=...`, so its keys sit
# one `=` deeper than the open/restore verdicts'. Strip that marker once and reuse _kv.
_kv_status() {
    _kvs_line=$(printf '%s\n' "$1" | sed 's/^wan=//')
    _kv "${_kvs_line}" "$2"
}

# _row_field <row> <column> <text>: one column of the TSV row the remote half printed.
_row_field() {
    printf '%s\n' "$3" | awk -F'\t' -v r="$1" -v n="$2" '$1 == r { print $n; exit }'
}

# _emit <item> <status> <facts...>: one machine-parseable row and the same row in the
# evidence log. A row is counted exactly once, here.
_emit() {
    _e_item=$1
    _e_status=$2
    shift 2
    PROBES=$((PROBES + 1))
    case "${_e_status}" in
        fail) FAILED=$((FAILED + 1)) ;;
        gap) GAPS=$((GAPS + 1)) ;;
    esac
    printf 'probe=%s ac=ac-14 status=%s' "${_e_item}" "${_e_status}"
    if [ $# -gt 0 ]; then
        printf ' %s' "$*"
    fi
    printf '\n'
    ev "ui-probe probe=${_e_item} status=${_e_status} $*"
}

# _finish: the one verdict line. FAIL wins over GAP: a measured failure is a finding, a gap
# is only a question the test host could not ask.
_finish() {
    _f_verdict=pass
    if [ "${FAILED}" -gt 0 ]; then
        _f_verdict=fail
    elif [ "${GAPS}" -gt 0 ]; then
        _f_verdict=gap
    fi
    printf 'ui-probe=%s host=%s probes=%s failed=%s gap=%s\n' \
        "${_f_verdict}" "${UI_HOST}" "${PROBES}" "${FAILED}" "${GAPS}"
    ev "ui-probe verdict=${_f_verdict} host=${UI_HOST} probes=${PROBES} failed=${FAILED} gap=${GAPS}"
    [ "${FAILED}" -gt 0 ] && return 1
    [ "${GAPS}" -gt 0 ] && return 4
    return 0
}

# --------------------------------------------------------------------------- #
# The remote half: one ssh call, one TSV row, the local half decides
# --------------------------------------------------------------------------- #

# Same zone lookup as wan-open.sh: by name, so a config that grew a zone cannot make this
# row about the wrong one. The value is read after the open, which is the measurement.
_remote_firewall() {
    cat <<REMOTE
set -u
zone=\$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -n 1)
input=\$(uci -q get "firewall.\${zone}.input")
printf 'ui-firewall\t%s\t%s\n' "\${input:-unknown}" "\${zone:-none}"
REMOTE
}

# The LAN-side lease decision. `pidof` is the witness for "the server is running" (a probe
# may not start one), the configured lease file is the witness for "a client got an
# address", and the DHCPACK count keeps a lease table that /tmp lost at the last boot from
# reading as "never answered". Every field is a measured value, including the zeroes.
_remote_dhcp() {
    cat <<REMOTE
set -u
leases_file='${LEASES}'
if pidof dnsmasq >/dev/null 2>&1; then running=running; else running=stopped; fi
ignore=\$(uci -q get dhcp.lan.ignore)
[ -n "\${ignore}" ] || ignore=0
start=\$(uci -q get dhcp.lan.start)
limit=\$(uci -q get dhcp.lan.limit)
n=0
if [ -f "\${leases_file}" ]; then
    n=\$(grep -c '[^[:space:]]' "\${leases_file}" 2>/dev/null) || :
fi
[ -n "\${n}" ] || n=0
ack=\$(logread 2>/dev/null | grep -c 'DHCPACK') || :
[ -n "\${ack}" ] || ack=0
printf 'ui-dhcp\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "\${running}" "\${ignore}" "\${n}" "\${ack}" "\${start:-none}" "\${limit:-none}"
REMOTE
}

# The restore assertion: the restored file is the backup, byte for byte, or this row fails.
_remote_restore_check() {
    cat <<REMOTE
set -u
restored=\$(sha256sum /etc/config/firewall 2>/dev/null | cut -d' ' -f1)
want=\$(sha256sum '${1}' 2>/dev/null | cut -d' ' -f1)
printf 'ui-sha256\t%s\t%s\n' "\${restored:-none}" "\${want:-none}"
REMOTE
}

# --------------------------------------------------------------------------- #
# The HTTP half, from this host
# --------------------------------------------------------------------------- #

_url() {
    printf 'http://%s:%s%s' "${UI_HOST}" "${UI_PORT}" "$1"
}

# _curl_get <path> <body-file> <header-file>: prints the status code and returns curl's own
# exit status. The body and the headers are files, not a pipe: the markers are read after
# curl has finished writing them, so a slow CGI cannot be read half-way.
_curl_get() {
    "${CURL}" -sS -m "${TIMEOUT}" -o "$2" -D "$3" -w '%{http_code}' "$(_url "$1")" \
        2>"${UI_TMP}/curl.err"
}

# _curl_post <path> <data> <body-file> <header-file>: same shape for the login form.
_curl_post() {
    "${CURL}" -sS -m "${TIMEOUT}" -o "$3" -D "$4" -w '%{http_code}' -d "$2" "$(_url "$1")" \
        2>"${UI_TMP}/curl.err"
}

# _count <file> <pattern>: a count, never a second 0 when nothing matched (`grep -c` prints
# 0 and exits 1, which is why the rc is swallowed here).
_count() {
    grep -ic "$2" "$1" 2>/dev/null || :
}

_no_machine() {
    _emit firewall gap reason=unreachable-host
    _emit homepage gap reason=unreachable-host
    _emit login gap reason=unreachable-host
    _emit assets gap reason=unreachable-host
    _emit dhcp gap reason=unreachable-host
    _emit restore skip reason=not-opened
}

# --------------------------------------------------------------------------- #
# wan-open.sh: the firewall half, reused and never reimplemented
# --------------------------------------------------------------------------- #

# _do_restore <backup-path>: run the restore, then compare the restored file with the
# backup over a second ssh. `wan-restore=ok` is wan-open's own claim; the digest is the
# evidence, and only the evidence makes this row PASS.
_do_restore() {
    _dr_backup=$1
    _dr_out=$(sh "${DEVICE_DIR}/wan-open.sh" --restore 2>&1)
    ev "ui-probe wan-open-restore ${_dr_out}"
    _dr_ok=no
    case "${_dr_out}" in *"wan-restore=ok"*) _dr_ok=yes ;; esac
    _dr_reason=$(_kv "${_dr_out}" reason)
    _dr_input=$(_kv "${_dr_out}" input)
    _dr_sidecar=$(_kv "${_dr_out}" sha256)
    _dr_restored=none
    _dr_want=none
    if [ "${_dr_ok}" = "yes" ] && [ -n "${_dr_backup}" ] && [ "${_dr_backup}" != "none" ]; then
        _dr_out2=$(dev_ssh "$(_remote_restore_check "${_dr_backup}")" 2>/dev/null)
        _dr_restored=$(_row_field ui-sha256 2 "${_dr_out2}")
        _dr_want=$(_row_field ui-sha256 3 "${_dr_out2}")
        [ -n "${_dr_restored}" ] || _dr_restored=none
        [ -n "${_dr_want}" ] || _dr_want=none
    fi
    _dr_match=unknown
    if [ "${_dr_restored}" != "none" ] && [ "${_dr_want}" != "none" ]; then
        if [ "${_dr_restored}" = "${_dr_want}" ]; then _dr_match=yes; else _dr_match=no; fi
    fi
    case "${_dr_reason}" in
        unreachable)
            _emit restore gap reason=unreachable-host "backup=${_dr_backup:-none}"
            printf '  next: scripts/device/ui-probe.sh --restore --host %s\n' "${UI_HOST}"
            return 0
            ;;
    esac
    if [ "${_dr_ok}" = "yes" ] && [ "${_dr_match}" = "yes" ]; then
        _emit restore pass "input=${_dr_input:-unknown} sha256_match=yes sidecar=${_dr_sidecar:-unrecorded} backup=${_dr_backup}"
        return 0
    fi
    _dr_why=${_dr_reason}
    if [ -z "${_dr_why}" ]; then
        _dr_why=restore-failed
        if [ "${_dr_ok}" = "yes" ]; then
            _dr_why=sha256-mismatch
            [ "${_dr_match}" = "unknown" ] && _dr_why=sha256-unreadable
        fi
    fi
    _emit restore fail "reason=${_dr_why} input=${_dr_input:-unknown} sha256_match=${_dr_match} backup=${_dr_backup:-none}"
    printf '  next: ssh %s sha256sum %s /etc/config/firewall\n' "${AB_HOST}" "${_dr_backup:-/root/firewall.before-open-wan.bak}"
    return 0
}

# _open_firewall: run wan-open, keep its verdict for the firewall row, and return the
# parsed facts through OPENED / OPEN_STATE / OPEN_BACKUP / OPEN_REASON.
_open_firewall() {
    _open_out=$(sh "${DEVICE_DIR}/wan-open.sh" --open 2>&1)
    ev "ui-probe wan-open-open ${_open_out}"
    OPENED=no
    OPEN_STATE=""
    OPEN_BACKUP=""
    OPEN_REASON=""
    case "${_open_out}" in
        *"wan-open=ok"*)
            OPENED=yes
            OPEN_STATE=$(_kv "${_open_out}" input)
            OPEN_BACKUP=$(_kv "${_open_out}" backup)
            ;;
        *"wan=unchanged"*)
            # The operator already opened the zone: this run changed nothing, so it must
            # not close it either (see the header).
            OPENED=unchanged
            OPEN_STATE=ACCEPT->ACCEPT
            OPEN_BACKUP=$(_kv "${_open_out}" backup)
            ;;
        *)
            OPEN_REASON=$(_kv "${_open_out}" reason)
            [ -n "${OPEN_REASON}" ] || OPEN_REASON=open-failed
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Modes that do one thing
# --------------------------------------------------------------------------- #
# Every mode ends with exactly one `ui-probe=` line, so a caller never has to know which
# mode it ran to parse the outcome: pass/fail/gap for a judged run, `open`/`status` for a
# step that reports a state, `dry-run` for a plan.

case "${MODE}" in
    open)
        if [ "${DRY_RUN}" = "1" ]; then
            sh "${DEVICE_DIR}/wan-open.sh" --open --dry-run
            exit 0
        fi
        _o_out=$(sh "${DEVICE_DIR}/wan-open.sh" --open 2>&1)
        _o_rc=$?
        printf '%s\n' "${_o_out}"
        ev "ui-probe mode=open rc=${_o_rc} ${_o_out}"
        _o_reason=$(_kv "${_o_out}" reason)
        case "${_o_out}" in
            *"reason=unreachable"*)
                printf 'ui-probe=gap host=%s reason=unreachable\n' "${UI_HOST}"
                exit 4
                ;;
            *"=fail"*)
                printf 'ui-probe=fail host=%s reason=%s\n' "${UI_HOST}" "${_o_reason:-open-failed}"
                exit 1
                ;;
        esac
        printf 'ui-probe=open host=%s input=%s zone=%s backup=%s\n' "${UI_HOST}" \
            "$(_kv "${_o_out}" input)" "$(_kv "${_o_out}" zone)" "$(_kv "${_o_out}" backup)"
        exit 0
        ;;
    status)
        if [ "${DRY_RUN}" = "1" ]; then
            sh "${DEVICE_DIR}/wan-open.sh" --status --dry-run
            exit 0
        fi
        _s_out=$(sh "${DEVICE_DIR}/wan-open.sh" --status 2>&1)
        _s_rc=$?
        ev "ui-probe mode=status rc=${_s_rc} ${_s_out}"
        if [ "${_s_rc}" -ne 0 ]; then
            _s_reason=$(_kv_status "${_s_out}" reason)
            printf 'ui-probe=gap host=%s reason=%s\n' "${UI_HOST}" "${_s_reason:-unreachable}"
            exit 4
        fi
        _s_input=$(_kv_status "${_s_out}" input)
        _s_zone=$(_kv_status "${_s_out}" zone)
        _s_backup=$(_kv_status "${_s_out}" backup)
        printf 'ui-probe=status host=%s input=%s zone=%s backup=%s\n' \
            "${UI_HOST}" "${_s_input:-unknown}" "${_s_zone:-none}" "${_s_backup:-none}"
        exit 0
        ;;
    restore)
        if [ "${DRY_RUN}" = "1" ]; then
            sh "${DEVICE_DIR}/wan-open.sh" --restore --dry-run
            exit 0
        fi
        _r_out=$(sh "${DEVICE_DIR}/wan-open.sh" --status 2>&1)
        _r_backup=$(_kv_status "${_r_out}" backup)
        [ -n "${_r_backup}" ] || _r_backup=none
        _do_restore "${_r_backup}"
        _finish
        exit $?
        ;;
esac

# --------------------------------------------------------------------------- #
# The full probe
# --------------------------------------------------------------------------- #

if [ "${DRY_RUN}" = "1" ]; then
    printf 'dry-run: sh %s/wan-open.sh --open       # WAN zone input -> ACCEPT, backup under /root/\n' "${DEVICE_DIR}"
    printf 'dry-run: ssh %s uci show firewall        # firewall: the `wan` zone input is ACCEPT\n' "${AB_HOST}"
    printf 'dry-run: curl GET %s   # homepage: 200 and the body carries both <form and luci\n' "$(_url "/")"
    printf 'dry-run: curl GET %s  # homepage fallback: the page the front door points at\n' "$(_url "${UI_ENTRY}")"
    printf 'dry-run: curl POST %s  # login: redirect or sysauth_http cookie, never 401/403\n' "$(_url "${UI_ENTRY}")"
    printf 'dry-run: curl GET %s%s   # assets: 200 (follow-samples.json criterion)\n' "$(_url "")" "${ASSET}"
    printf 'dry-run: ssh %s leases/dhcp              # dhcp: dnsmasq running, ignore=0, a lease exists\n' "${AB_HOST}"
    printf 'dry-run: sh %s/wan-open.sh --restore     # restore: sha256(restored) == sha256(backup)\n' "${DEVICE_DIR}"
    for _dp in firewall homepage login assets dhcp restore; do
        _emit "${_dp}" skip reason=dry-run
    done
    printf 'ui-probe=dry-run host=%s probes=%s\n' "${UI_HOST}" "${PROBES}"
    exit 0
fi

# 1. One non-interactive question first: an offline machine is a gap with a reason, not a
#    firewall failure that reads like a product defect.
if ! dev_ssh true >/dev/null 2>&1; then
    _no_machine
    _finish
    exit $?
fi

# 2. No HTTP client means none of the five questions can be asked; opening the zone to
#    measure nothing would leave the bench changed for no evidence.
if ! command -v "${CURL}" >/dev/null 2>&1; then
    printf 'ui-probe.sh: no HTTP client (%s); nothing was opened\n' "${CURL}" >&2
    _emit firewall skip reason=no-http-client
    _emit homepage gap reason=no-http-client
    _emit login gap reason=no-http-client
    _emit assets gap reason=no-http-client
    _emit dhcp skip reason=no-http-client
    _emit restore skip reason=not-opened
    _finish
    exit $?
fi

# 3. Open the zone through the driver that owns that edit.
_open_firewall

# 4. firewall: the value is read back, not echoed from wan-open's line.
_fw_out=$(dev_ssh "$(_remote_firewall)" 2>/dev/null)
_fw_rc=$?
_fw_input=$(_row_field ui-firewall 2 "${_fw_out}")
_fw_zone=$(_row_field ui-firewall 3 "${_fw_out}")
[ -n "${_fw_input}" ] || _fw_input=unknown
[ -n "${_fw_zone}" ] || _fw_zone=none
if [ "${_fw_rc}" -ne 0 ]; then
    _emit firewall gap reason=no-answer "input=${_fw_input}"
else
    if [ "${_fw_input}" = "ACCEPT" ]; then
        _emit firewall pass "zone=${_fw_zone} input=ACCEPT opened=${OPEN_STATE:-none} backup=${OPEN_BACKUP:-none}"
    else
        _emit firewall fail "zone=${_fw_zone} input=${_fw_input} opened=${OPEN_STATE:-none} open_error=${OPEN_REASON:-none}"
    fi
fi

# 5. homepage: 200 from `/` *and* the login form's markers in the body. The front door on
#    this image is uhttpd's index, which may itself be a redirect stub rather than the form,
#    so when `/` has no form the page it points at (${UI_ENTRY}) is fetched once and
#    judged the same way. Both codes and both marker counts stay in the row, so "the entry
#    answered but the front door did not" is visible instead of averaged away.
_home_code=$(_curl_get "/" "${UI_TMP}/home.body" "${UI_TMP}/home.hdr")
_home_rc=$?
_home_code=${_home_code:-000}
_home_form=$(_count "${UI_TMP}/home.body" '<form')
_home_luci=$(_count "${UI_TMP}/home.body" 'luci')
_home_bytes=$(wc -c <"${UI_TMP}/home.body" 2>/dev/null | tr -d ' ')
[ -n "${_home_bytes}" ] || _home_bytes=0
_entry_code=-
_entry_form=-
_entry_luci=-
_entry_hdr=-
_home_via=/
_home_status=fail
if [ "${_home_code}" = "200" ] && [ "${_home_form:-0}" -gt 0 ] && [ "${_home_luci:-0}" -gt 0 ]; then
    _home_status=pass
elif [ "${_home_code}" = "200" ]; then
    _entry_code=$(_curl_get "${UI_ENTRY}" "${UI_TMP}/entry.body" "${UI_TMP}/entry.hdr")
    _entry_code=${_entry_code:-000}
    _entry_form=$(_count "${UI_TMP}/entry.body" '<form')
    _entry_luci=$(_count "${UI_TMP}/entry.body" 'luci')
    # LuCI answers an unauthenticated request with the login page *and* a deliberate 403;
    # the header is what separates that guard from uhttpd's own error page (the same rule
    # luci-entry-probe.sh documents). Any other code has to be 200 to count.
    _entry_hdr=$(_count "${UI_TMP}/entry.hdr" 'x-luci-login-required: *yes')
    if [ "${_entry_form:-0}" -gt 0 ] && [ "${_entry_luci:-0}" -gt 0 ]; then
        case "${_entry_code}" in
            200) _home_status=pass ;;
            403) [ "${_entry_hdr:-0}" -gt 0 ] && _home_status=pass ;;
        esac
    fi
    _home_via=${UI_ENTRY}
fi
_emit homepage "${_home_status}" \
    "code=${_home_code} form=${_home_form:-0} luci=${_home_luci:-0} bytes=${_home_bytes} entry=${_entry_code} entry_form=${_entry_form:--} entry_header=${_entry_hdr:--} via=${_home_via} curl_rc=${_home_rc}"
if [ "${_home_status}" = "fail" ]; then
    printf '  next: curl -sS -D - %s   # the body and the headers, not just the code\n' "$(_url "/")"
    printf '  next: curl -sS -D - %s   # the page the front door points at\n' "$(_url "${UI_ENTRY}")"
fi

# 6. login: submit the form. A session cookie or a redirect is the pass; 401/403 is the
#    fail the old criterion could not name.
_login_body=${UI_TMP}/login.body
_login_hdr=${UI_TMP}/login.hdr
_login_code=$(_curl_post "${UI_ENTRY}" \
    "luci_username=${UI_USER}&luci_password=${UI_PASSWORD}" \
    "${_login_body}" "${_login_hdr}")
_login_rc=$?
_login_code=${_login_code:-000}
_login_session=$(_count "${_login_hdr}" '^[Ss]et-[Cc]ookie: *sysauth')
_login_loc=$(_count "${_login_hdr}" '^[Ll]ocation:')
_login_status=fail
_login_why=no-session
case "${_login_code}" in
    401 | 403) _login_why=rejected ;;
    *)
        if [ "${_login_session:-0}" -gt 0 ]; then
            _login_status=pass
            _login_why=session
        elif [ "${_login_code}" = "302" ] && [ "${_login_loc:-0}" -gt 0 ]; then
            _login_status=pass
            _login_why=redirect
        fi
        ;;
esac
_emit login "${_login_status}" \
    "code=${_login_code} session=${_login_session:-0} location=${_login_loc:-0} via=${_login_why} curl_rc=${_login_rc}"
if [ "${_login_status}" = "fail" ]; then
    printf '  next: curl -sS -D - %s -d "luci_username=%s&luci_password="  # check the headers\n' \
        "$(_url "${UI_ENTRY}")" "${UI_USER}"
fi

# 7. assets: the theme's own stylesheet, the criterion follow-samples.json already fixes.
_asset_code=$(_curl_get "${ASSET}" "${UI_TMP}/asset.body" "${UI_TMP}/asset.hdr")
_asset_rc=$?
_asset_code=${_asset_code:-000}
_asset_status=fail
[ "${_asset_code}" = "200" ] && _asset_status=pass
_emit assets "${_asset_status}" "css=${_asset_code} path=${ASSET} curl_rc=${_asset_rc}"

# 8. dhcp: what the LAN side actually did.
_dhcp_out=$(dev_ssh "$(_remote_dhcp)" 2>/dev/null)
_dhcp_rc=$?
if [ "${_dhcp_rc}" -ne 0 ]; then
    _emit dhcp gap reason=no-answer
else
    _dhcp_running=$(_row_field ui-dhcp 2 "${_dhcp_out}")
    _dhcp_ignore=$(_row_field ui-dhcp 3 "${_dhcp_out}")
    _dhcp_leases=$(_row_field ui-dhcp 4 "${_dhcp_out}")
    _dhcp_ack=$(_row_field ui-dhcp 5 "${_dhcp_out}")
    _dhcp_start=$(_row_field ui-dhcp 6 "${_dhcp_out}")
    _dhcp_limit=$(_row_field ui-dhcp 7 "${_dhcp_out}")
    [ -n "${_dhcp_running}" ] || _dhcp_running=unknown
    [ -n "${_dhcp_ignore}" ] || _dhcp_ignore=unknown
    [ -n "${_dhcp_leases}" ] || _dhcp_leases=0
    [ -n "${_dhcp_ack}" ] || _dhcp_ack=0
    [ -n "${_dhcp_start}" ] || _dhcp_start=none
    [ -n "${_dhcp_limit}" ] || _dhcp_limit=none
    # A lease table or a DHCPACK is the only evidence that a client was served; the
    # configuration facts beside it say whether a zero means "nobody asked".
    _dhcp_served=0
    case "${_dhcp_leases}" in
        '' | *[!0-9]*) : ;;
        *) [ "${_dhcp_leases}" -gt 0 ] && _dhcp_served=1 ;;
    esac
    case "${_dhcp_ack}" in
        '' | *[!0-9]*) : ;;
        *) [ "${_dhcp_ack}" -gt 0 ] && _dhcp_served=1 ;;
    esac
    _dhcp_status=fail
    if [ "${_dhcp_running}" = "running" ] && [ "${_dhcp_ignore}" = "0" ] && [ "${_dhcp_served}" -eq 1 ]; then
        _dhcp_status=pass
    fi
    _emit dhcp "${_dhcp_status}" \
        "dnsmasq=${_dhcp_running} ignore=${_dhcp_ignore} leases=${_dhcp_leases} dhcpack=${_dhcp_ack} range=${_dhcp_start}-${_dhcp_limit}"
    if [ "${_dhcp_status}" = "fail" ]; then
        printf '  next: plug a client into a LAN port, or read the table directly: ssh %s "cat %s"\n' \
            "${AB_HOST}" "${LEASES}"
    fi
fi

# 9. restore: the sixth item is the one that leaves the bench as it was found.
case "${OPENED}" in
    unchanged)
        _emit restore skip reason=already-open "input=ACCEPT"
        ;;
    yes)
        _do_restore "${OPEN_BACKUP}"
        ;;
    *)
        if [ "${_fw_input}" = "ACCEPT" ]; then
            _do_restore "${OPEN_BACKUP}"
        else
            _emit restore skip reason=open-failed "open_error=${OPEN_REASON:-none}"
        fi
        ;;
esac

_finish
exit $?
