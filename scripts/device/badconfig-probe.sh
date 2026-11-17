#!/bin/sh
# badconfig-probe.sh - ac-5: five wrong configurations, and the three questions each of them
# has to answer.
#
#   ac-5 假配置与坏配置不产生不良反应：坏 openclash 配置、坏 daemon.json、坏 UCI 段、
#        坏 firewall 规则、假订阅源各一次，记录「谁拒绝了它/谁恢复了它」，以及机器可达性、
#        `ab-slot status`、包与数据是否受损
#
# A person with a text editor gets /etc/config/firewall wrong far more often than an upgrade
# does, so this driver asks the machine what it does with a file that is simply wrong. Per
# class, the same three questions -- and each one gets its own answer, because collapsing
# them is how "the tool said 0" becomes "nothing happened":
#
#   1 refused?   Which tool declined the file, and in whose words. A tool's exit status is
#                never the whole answer: `fw4 check` warns "option 'dest_port' specifies
#                invalid value 'not-a-port' / Section ... skipped due to invalid options" and
#                still exits 0 (measured on the 25.x line), so "adopted" and "refused" are
#                told apart by the rendered ruleset (`fw4 print`), not by rc. Likewise
#                `ubus call network reload` answers 0 whatever netifd made of the section.
#   2 restored?  The original goes back byte for byte and is verified by sha256, and then the
#                thing that has to work is asked to work: uci parses it, fw4 checks it,
#                dockerd accepts it, netifd has dropped the section. A restore that cannot be
#                applied is not a restore. A restore that fails is a FAIL and names where the
#                backup is kept -- silence there would leave a bad file on a live machine.
#   3 adverse?   Five checks with their own row, so "the class was refused" and "the machine
#                is still a machine" cannot hide behind one another: ssh still answers,
#                `ab-slot status` still answers with boot/esp/data (and docker, when the image
#                has it) still ok, the installed package set (`apk info -v`) did not move,
#                the /data marker and the docker volume set are unchanged, and ubus/rpcd
#                still respond.
#
# The five classes, and the witness each one actually rests on:
#
#   C1 openclash  an unterminated quote -- libuci refuses to parse it -- and a boolean that
#                 is not a boolean and a port that is not a number, which the parser has to
#                 accept because uci has no schema. Who refuses the second one is therefore a
#                 measurement: the app's init script is run and its answer recorded. A value
#                 nobody refuses is reported as `tolerated=` and as a finding, because
#                 "silently coerced" is a fact the defect list should carry, not a PASS in
#                 disguise.
#   C2 docker     a truncated daemon.json and an option dockerd does not know. `dockerd
#                 --validate --config-file` is asked first, because it answers without
#                 starting anything; on an image whose dockerd has no --validate the daemon is
#                 restarted and `docker info` is polled, because procd re-spawns a dockerd
#                 that died and `pidof dockerd` therefore proves nothing (measured on a
#                 truncated file: restart rc=0, pid present, `docker info` rc=1).
#   C3 network    a section naming a device nothing has, and a section naming a protocol no
#                 handler answers. netifd cannot create what is not there; the witnesses are
#                 `ip link show <dev>` and `ubus call network.interface.<name> status`, never
#                 the reload's exit status. Only a section that can touch no real link is
#                 written, and the live file is only ever appended to.
#   C4 firewall   a rule with `dest_port not-a-port` and `target AB-BOGUS`. `fw4 check` is run
#                 and never a reload -- pushing a broken ruleset onto a live firewall is how a
#                 test takes its own ssh session away -- its warning is recorded, and the rule
#                 is asserted *absent* from `fw4 print`. A rule that shows up in the rendered
#                 ruleset is a FAIL: that is the fail-open case this class exists to catch.
#                 An image with fw3 has no `check` subcommand and is a named GAP.
#   C5 fake source a subscription URL whose domain does not resolve and one that answers 404,
#                 written into the proxy app's configuration. The refusals come from the
#                 resolver and from the remote host, and the same fetcher fetching a known-good
#                 URL is the control: without it, "the fake source was refused" cannot be told
#                 apart from "this machine has no network from here", so a failed control is a
#                 GAP and never a PASS (S8's 404 lesson, scripts/device/scenarios.sh).
#
# Every class writes its bad configuration through tests/lib/device_config.sh, whose promise is
# the order of the steps: read the original, copy it on the machine, register the restore, and
# only then write. So there is no window in which a bad config exists without a way back --
# not when the write fails, not when it lands mangled, not when this driver dies behind a
# signal (the library's trap covers that). The originals are also copied to <evidence>/<tag>.orig
# for the defect report.
#
#   scripts/device/badconfig-probe.sh                    # C1..C5
#   scripts/device/badconfig-probe.sh --case C4          # the firewall rule only
#   scripts/device/badconfig-probe.sh --dry-run          # the plan, no ssh, no file written
#   scripts/device/badconfig-probe.sh --defects x.tsv    # FAILs as defect candidate lines
#
# Output: one line per assertion (`ok`, `FAIL` or `GAP`, with a `rerun:` line on a failure),
# one `finding` line for a value nobody refused, and two rows per class in <results>:
#
#   case<TAB>verdict<TAB>evidence<TAB>note
#   C4            PASS  <evidence>/C4.log  syntax... refused_by=fw4 adopted=no warning=yes restored=yes
#   C4-adverse    PASS  <evidence>/C4.log  reachable=ok status=ok packages=ok data=ok volumes=ok ubus=ok
#
# Exit status: 0 every selected class PASSed, 1 at least one FAIL, 2 bad usage, 3 the red line
# (the machine does not run the 25.x/apk line, so nothing was written), 4 no verdict (a GAP: a
# precondition or the network was missing, so the class was never judged).
#
# What this driver does not do: it never reloads the live firewall, never rewrites an existing
# network section, never touches a slot, ESP or payload, and it does not judge the app's own
# correctness. A wrong value the app tolerates is recorded; fixes belong to another task (the
# round is measure-only).

set -u

BADC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${BADC_DIR}/../.." && pwd)
: "${AB_REPO_ROOT:=${REPO_ROOT}}"
AB_RESULTS_FROM_ENV=${AB_RESULTS:-}

# shellcheck source=scripts/device/lib.sh
. "${BADC_DIR}/lib.sh"
# The shared verifier: snapshots, value assertions, and the injection whose entire point is
# that the original is backed up and registered before the bad bytes land.
# shellcheck source=../../tests/lib/device_config.sh
. "${REPO_ROOT}/tests/lib/device_config.sh"

# --------------------------------------------------------------------------- #
# Tunables
# --------------------------------------------------------------------------- #

DRY_RUN=${AB_DRY_RUN:-0}
CASES=""
CASES_ALL="C1 C2 C3 C4 C5"
RESULTS=${AB_BADCFG_RESULTS:-${AB_RESULTS_FROM_ENV:-badconfig-results.tsv}}
DEFECTS=${AB_BADCFG_DEFECTS:-}
EV_DIR=${AB_BADCFG_EVIDENCE_DIR:-}

# The files this driver breaks. Overridable so the same code can be walked against a stub
# machine in the tests, where every one of them is a path in a temporary tree.
OPENCLASH=${AB_BADCFG_OPENCLASH:-/etc/config/openclash}
OPENCLASH_INIT=${AB_BADCFG_OPENCLASH_INIT:-/etc/init.d/openclash}
DOCKER_JSON=${AB_BADCFG_DOCKER_JSON:-/etc/docker/daemon.json}
DOCKER_INIT=${AB_BADCFG_DOCKER_INIT:-/etc/init.d/docker}
NETWORK=${AB_BADCFG_NETWORK:-/etc/config/network}
FIREWALL=${AB_BADCFG_FIREWALL:-/etc/config/firewall}
MARKER=${AB_BADCFG_MARKER:-${AB_MARKER_PATH}}

# The bad values themselves.
NET_NAME=${AB_BADCFG_NET_NAME:-ab_badcfg_probe}
NET_DEV=${AB_BADCFG_NET_DEV:-ab-badcfg-nosuch0}
NET_PROTO=${AB_BADCFG_NET_PROTO:-ab-badcfg-proto}
FW_RULE=${AB_BADCFG_FW_RULE:-ab-badcfg-rule}
SUB_FAKE=${AB_BADCFG_SUB_FAKE:-https://ab-badcfg-nonexistent.invalid/subscription.yaml}
SUB_404=${AB_BADCFG_SUB_404:-https://downloads.immortalwrt.org/releases/0.0.0-ab-badcfg-404/subscription.yaml}
CONTROL_URL=${AB_BADCFG_CONTROL_URL:-https://downloads.immortalwrt.org/releases/}
FETCH_TIMEOUT=${AB_BADCFG_FETCH_TIMEOUT:-10}

# dockerd takes three to four seconds after a restart before `docker info` answers, and a
# single call made right after the restart reads a healthy daemon as broken (measured). Both
# budgets are cut to zero in the tests, where a poll interval is pure waiting.
DOCKER_TRIES=${AB_BADCFG_DOCKER_TRIES:-4}
DOCKER_PAUSE=${AB_BADCFG_DOCKER_PAUSE:-1}

AB_RESULTS=${RESULTS}
DEVCFG_RESULTS=${RESULTS}

TOT_PASS=0
TOT_FAIL=0
TOT_GAP=0
N_CASES=0

usage() {
    cat <<'USAGE'
usage: badconfig-probe.sh [--case C1|C2|C3|C4|C5]... [--results FILE] [--defects FILE]
                          [--dry-run]

  --case <id>      run one class; repeatable (default: all five)
                     C1  a bad openclash configuration: an unterminated quote (the parser's
                         refusal) and a boolean that is not a boolean (the app's)
                     C2  a bad /etc/docker/daemon.json: truncated JSON, and an option dockerd
                         does not know
                     C3  a bad UCI section in /etc/config/network: a device nothing has, and
                         a protocol no handler answers
                     C4  a bad firewall rule: the one fw4 warns about and still exits 0
                     C5  a fake subscription source: a domain that does not resolve and a URL
                         that answers 404
  --results <file> results TSV (default badconfig-results.tsv); two rows per class, the
                   class itself and its adverse effects
  --defects <file> append every FAIL as a defect candidate line (case, kind, check, detail,
                   rerun)
  --dry-run        print the injections and the witnesses; contact nothing, write nothing

Environment: AB_HOST, AB_KEY, AB_DRY_RUN, AB_BADCFG_RESULTS, AB_BADCFG_DEFECTS,
             AB_BADCFG_EVIDENCE_DIR, AB_BADCFG_OPENCLASH, AB_BADCFG_OPENCLASH_INIT,
             AB_BADCFG_DOCKER_JSON, AB_BADCFG_DOCKER_INIT, AB_BADCFG_NETWORK,
             AB_BADCFG_FIREWALL, AB_BADCFG_MARKER, AB_BADCFG_SUB_FAKE, AB_BADCFG_SUB_404,
             AB_BADCFG_CONTROL_URL, AB_BADCFG_DOCKER_TRIES, AB_BADCFG_DOCKER_PAUSE,
             AB_EVIDENCE_LOG, DEVCFG_EXEC.

Exit status: 0 every selected class PASSed, 1 at least one FAIL, 2 bad usage, 3 red line
(the machine is not on the 25.x/apk line, so nothing was written), 4 no verdict (GAP).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            _want=$(printf '%s' "${2:?--case needs C1, C2, C3, C4 or C5}" | tr 'a-z' 'A-Z')
            case " ${CASES_ALL} " in
                *" ${_want} "*) CASES="${CASES} ${_want}" ;;
                *)
                    printf 'badconfig-probe.sh: unknown case: %s (want one of: %s)\n' \
                        "${2}" "${CASES_ALL}" >&2
                    usage >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --results) RESULTS=${2:?--results needs a file}; shift 2 ;;
        --defects) DEFECTS=${2:?--defects needs a file}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help | help) usage; exit 0 ;;
        *)
            printf 'badconfig-probe.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "${CASES}" ] || CASES=" ${CASES_ALL} "
CASES=$(printf '%s' "${CASES}" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//')
N_CASES=$(printf '%s' "${CASES}" | wc -w | tr -d ' ')
AB_RESULTS=${RESULTS}
DEVCFG_RESULTS=${RESULTS}
: "${EV_DIR:=$(dirname "${RESULTS}")/badconfig-evidence}"

# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

# Every line goes to stdout and into the class's own evidence log, so the evidence column of
# a row names a file that really holds that class's narrative.
_emit() {
    printf '%s\n' "${1}"
    [ -n "${CASE_LOG}" ] && printf '%s\n' "${1}" >>"${CASE_LOG}" 2>/dev/null
    return 0
}

_bc_cur=""       # the case, or "<case>-adverse", the line is about
_bc_fails=0      # failures inside the case at hand
_bc_gaps=0       # things the case could not be judged on
_bc_note=""      # the k=v facts the case row will carry
_bc_ev="-"       # the evidence file the row will name
_bc_skip_adverse=0
CASE_LOG=""
CASE_RERUN="./scripts/device/badconfig-probe.sh"

ok_line() { # <check> [detail]
    _emit "$(printf 'ok   [%s] %s %s' "${_bc_cur}" "$1" "${2:-}")"
}

fail_line() { # <check> [detail]
    _bc_fails=$((_bc_fails + 1))
    _emit "$(printf 'FAIL [%s] %s %s' "${_bc_cur}" "$1" "${2:-}")"
    _emit "  rerun: ${CASE_RERUN}"
    _defect "${_bc_cur}" defect "$1" "${2:-}"
}

gap_line() { # <check> [detail]
    _bc_gaps=$((_bc_gaps + 1))
    _emit "$(printf 'GAP  [%s] %s %s' "${_bc_cur}" "$1" "${2:-}")"
    _emit "  rerun: ${CASE_RERUN}"
    _note_add "gap=$1"
}

# A fact worth carrying into the defect list that is not a failure of the machine: a value
# nobody refused, a warning that never appeared. It never moves a verdict.
finding_line() { # <check> [detail]
    _emit "$(printf 'finding [%s] %s %s' "${_bc_cur}" "$1" "${2:-}")"
    _defect "${_bc_cur}" finding "$1" "${2:-}"
}

_note_add() { # <key=value>
    _na_key=${1%%=*}
    case " ${_bc_note}" in
        *" ${_na_key}="*) return 0 ;;
    esac
    _bc_note="${_bc_note} $1"
    return 0
}

_defect() { # <case> <kind> <check> <detail>
    [ -n "${DEFECTS}" ] || return 0
    mkdir -p "$(dirname "${DEFECTS}")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${CASE_RERUN}" >>"${DEFECTS}" 2>/dev/null || true
    return 0
}

case_title() {
    case "$1" in
        C1) printf 'bad openclash config: an unterminated quote and a wrong field type' ;;
        C2) printf 'bad /etc/docker/daemon.json: truncated JSON and an unknown option' ;;
        C3) printf 'bad UCI section in /etc/config/network: no such device and a bad proto' ;;
        C4) printf 'bad firewall rule: the one fw4 warns about and still exits 0' ;;
        C5) printf 'fake subscription source: no such domain and a 404' ;;
        *) printf '?' ;;
    esac
}

# --------------------------------------------------------------------------- #
# Talking to the machine
# --------------------------------------------------------------------------- #

# Everything goes through the shared executor, so the bad config is written through the same
# channel a snapshot is read through, and a stub `ssh` in the tests sees every command.
_rsh() { devcfg_exec "${1:?badconfig-probe: a remote command is required}"; }

_sq() { devcfg_sq "$1"; }

_file_exists() { _rsh "test -f $(_sq "$1")" >/dev/null 2>&1; }

_have() { _rsh "command -v $(_sq "$1") >/dev/null 2>&1"; }

_read_file() { _rsh "cat $(_sq "$1")" 2>/dev/null; }

uci_export() { _rsh "uci -q export $(_sq "$1")" 2>&1; }

# app_start <init script>: "rc=<n>" when the app was asked to start, "absent" when this image
# has no such init script. Deliberately not `pidof`: a service that procd re-spawns keeps a
# pid while refusing its configuration (the dockerd lesson, measured).
app_start() {
    _rsh "if [ -x $(_sq "$1") ]; then $(_sq "$1") start >/dev/null 2>&1; printf 'rc=%s' \$?; else printf 'absent'; fi" 2>/dev/null
}

# docker_info_poll: "info=ok" when the API answers within the budget, "info=fail" otherwise.
docker_info_poll() {
    _rsh "i=0; while [ \$i -lt ${DOCKER_TRIES} ]; do i=\$((i+1)); docker info >/dev/null 2>&1 && { printf 'info=ok'; exit 0; }; sleep ${DOCKER_PAUSE}; done; printf 'info=fail'" 2>/dev/null
}

_docker_validate_support() {
    [ -n "${_BADC_DV:-}" ] && return 0
    if _rsh 'dockerd --help 2>&1 | grep -q -- --validate' >/dev/null 2>&1; then
        _BADC_DV=yes
    else
        _BADC_DV=no
    fi
    return 0
}

# dockerd_refuses <daemon.json path>: 0 when dockerd declined the file, 1 when it accepted it.
# Sets _DW_BY (which witness answered) and _DW_REASON (the tool's own words).
dockerd_refuses() {
    _DW_BY=""
    _DW_REASON=""
    _docker_validate_support
    if [ "${_BADC_DV}" = "yes" ]; then
        _dw_out=$(_rsh "dockerd --validate --config-file $(_sq "$1")" 2>&1)
        _dw_rc=$?
        _DW_BY="dockerd-validate"
        _DW_REASON=$(printf '%s\n' "${_dw_out}" | head -n 1)
        _emit "  dockerd --validate --config-file $1 rc=${_dw_rc}: ${_DW_REASON}"
        [ "${_dw_rc}" -ne 0 ]
        return $?
    fi
    _DW_BY="docker-info"
    _rsh "$(_sq "${DOCKER_INIT}") restart >/dev/null 2>&1" >/dev/null 2>&1
    _DW_REASON=$(docker_info_poll)
    _emit "  ${DOCKER_INIT} restart; docker info -> ${_DW_REASON}"
    [ "${_DW_REASON}" != "info=ok" ]
}

# fetch_tool: the fetcher the app itself would use, in the order OpenWrt images carry them.
fetch_tool() {
    _rsh 'for c in uclient-fetch wget curl; do command -v "$c" >/dev/null 2>&1 && { printf "%s" "$c"; break; }; done' 2>/dev/null
}

# _fetch <url>: the fetcher's verdict, with its output in _FETCH_OUT.
_fetch() {
    if [ "${_FETCH_TOOL}" = "curl" ]; then
        _FETCH_OUT=$(devcfg_exec "curl -sS -m ${FETCH_TIMEOUT} -o /dev/null $(_sq "$1")" 2>&1)
        return $?
    fi
    _FETCH_OUT=$(devcfg_exec "${_FETCH_TOOL} -T ${FETCH_TIMEOUT} -O /dev/null $(_sq "$1")" 2>&1)
    return $?
}

# fetch_kind <status> <output>: who refused a fetch, in the words the fetcher used.
fetch_kind() {
    [ "$1" -eq 0 ] && {
        printf 'none'
        return 0
    }
    case "${2}" in
        *"Bad address"* | *"bad address"* | *"Name does not resolve"* | *"no address"*)
            printf 'dns'
            ;;
        *404*) printf 'http-404' ;;
        *nreachable* | *"timeout"* | *"timed out"* | *"Connection refused"*) printf 'network' ;;
        *) printf 'unknown' ;;
    esac
}

# --------------------------------------------------------------------------- #
# The injection, and the way back
# --------------------------------------------------------------------------- #

_inject() { # <tag> <path> <content>
    if devcfg_inject_bad "$1" "$2" "$3" "${EV_DIR}" >>"${CASE_LOG}" 2>&1; then
        ok_line assert_injected "tag=$1 path=$2 bytes=$(printf '%s' "$3" | wc -c | tr -d ' ')"
        return 0
    fi
    gap_line assert_injected \
        "tag=$1 path=$2: the bad content could not be written, so nothing was changed and the class was never put"
    return 1
}

_restore() { # <tag> <path>
    if devcfg_restore "$1" >>"${CASE_LOG}" 2>&1; then
        ok_line assert_restored "restored_by=devcfg_restore tag=$1 sha256=verified"
        _note_add "restored=yes"
        _note_add "restored_by=backup-sha256"
        return 0
    fi
    fail_line assert_restored \
        "restored_by=none: the original of $2 is not back; the backup is kept at $2.devcfg-bak-$1 and the retry is: cp -a $2.devcfg-bak-$1 $2"
    _note_add "restored=no"
    return 1
}

# --------------------------------------------------------------------------- #
# C1: the proxy app's own configuration
# --------------------------------------------------------------------------- #

class_openclash() {
    if ! _file_exists "${OPENCLASH}"; then
        gap_line precondition \
            "${OPENCLASH} is not on the machine: no proxy app to hold a bad configuration (the sample layer installs it)"
        _bc_skip_adverse=1
        return 0
    fi
    _c1_name=$(basename "${OPENCLASH}")

    # (a) the parser. An unterminated quote is the one thing libuci cannot read past.
    _c1_syntax="config openclash 'config'
	option enable '1
"
    _inject c1-syntax "${OPENCLASH}" "${_c1_syntax}" || return 0
    _c1_out=$(uci_export "${_c1_name}")
    _c1_rc=$?
    _emit "  uci -q export ${_c1_name} rc=${_c1_rc}: $(printf '%s\n' "${_c1_out}" | head -n 1)"
    if [ "${_c1_rc}" -ne 0 ] && printf '%s\n' "${_c1_out}" | grep -Eqi 'parse error|unterminated'; then
        ok_line assert_syntax_refused "refused_by=uci rc=${_c1_rc}"
        _note_add "syntax=refused_by=uci"
    else
        fail_line assert_syntax_refused \
            "refused_by=none: the UCI parser read a file with an unterminated quote (uci -q export ${_c1_name} rc=${_c1_rc})"
        _note_add "syntax=adopted"
    fi
    _restore c1-syntax "${OPENCLASH}" || return 0
    if uci_export "${_c1_name}" >/dev/null 2>&1; then
        ok_line assert_restored_parses "the restored ${OPENCLASH} parses again"
    else
        fail_line assert_restored_parses "the restored ${OPENCLASH} still does not parse"
    fi

    # (b) the wrong type. The parser cannot help -- uci has no schema -- so who refuses it is a
    # measurement, and "nobody did" is a finding rather than a pass in disguise.
    _c1_type="config openclash 'config'
	option enable 'maybe'
	option daemon_port 'not-a-port'
"
    _inject c1-type "${OPENCLASH}" "${_c1_type}" || return 0
    _c1_out=$(uci_export "${_c1_name}")
    _c1_rc=$?
    _emit "  uci -q export ${_c1_name} rc=${_c1_rc}: the wrong type is not the parser's to refuse"
    _c1_app=$(app_start "${OPENCLASH_INIT}")
    _emit "  ${OPENCLASH_INIT} start -> ${_c1_app}"
    case "${_c1_app}" in
        rc=0)
            finding_line assert_type_refused \
                "tolerated=yes refused_by=none: a boolean that is not a boolean starts the app anyway (config_get_bool coerces it), so the user is told nothing"
            _note_add "type=tolerated"
            ;;
        absent)
            gap_line assert_type_refused \
                "refused_by=unknown: ${OPENCLASH_INIT} is not on the machine, so no app could have refused the wrong type"
            _note_add "type=unknown"
            ;;
        *)
            ok_line assert_type_refused "refused_by=init ${_c1_app}"
            _note_add "type=refused_by=init"
            ;;
    esac
    _restore c1-type "${OPENCLASH}" || return 0
    case "$(app_start "${OPENCLASH_INIT}")" in
        rc=0) ok_line assert_restored_starts "the app starts on the restored configuration" ;;
        absent) : ;;
        *)
            fail_line assert_restored_starts "the app does not start on the restored configuration"
            ;;
    esac
    return 0
}

# --------------------------------------------------------------------------- #
# C2: the docker daemon's configuration
# --------------------------------------------------------------------------- #

class_docker() {
    if ! _have docker || ! _have dockerd; then
        gap_line precondition "no docker client/daemon on this image, so no daemon.json could be refused"
        _bc_skip_adverse=1
        return 0
    fi
    if ! _file_exists "${DOCKER_JSON}"; then
        gap_line precondition \
            "${DOCKER_JSON} is not on the machine: the image ships no daemon configuration to break (enable docker first)"
        _bc_skip_adverse=1
        return 0
    fi

    _c2_truncated='{
  "log-driver": "json-file",'
    _inject c2-truncated "${DOCKER_JSON}" "${_c2_truncated}" || return 0
    if dockerd_refuses "${DOCKER_JSON}"; then
        ok_line assert_truncated_refused "refused_by=${_DW_BY}: ${_DW_REASON}"
        _note_add "truncated=refused_by=${_DW_BY}"
    else
        finding_line assert_truncated_refused \
            "tolerated=yes: ${_DW_BY} accepted a file that never finished being written"
        _note_add "truncated=tolerated"
    fi
    _restore c2-truncated "${DOCKER_JSON}" || return 0
    if dockerd_refuses "${DOCKER_JSON}"; then
        fail_line assert_restored_valid "the restored ${DOCKER_JSON} is still refused by ${_DW_BY}"
    else
        ok_line assert_restored_valid "the restored ${DOCKER_JSON} is accepted again (${_DW_BY})"
    fi

    _c2_unknown='{
  "log-driver": "json-file",
  "ab-badcfg-unknown": true
}'
    _inject c2-unknown "${DOCKER_JSON}" "${_c2_unknown}" || return 0
    if dockerd_refuses "${DOCKER_JSON}"; then
        ok_line assert_unknown_refused "refused_by=${_DW_BY}: ${_DW_REASON}"
        _note_add "unknown=refused_by=${_DW_BY}"
    else
        finding_line assert_unknown_refused \
            "tolerated=yes: ${_DW_BY} accepted an option it does not know"
        _note_add "unknown=tolerated"
    fi
    _restore c2-unknown "${DOCKER_JSON}" || return 0
    _c2_info=$(docker_info_poll)
    if [ "${_c2_info}" = "info=ok" ]; then
        ok_line assert_daemon_answers "docker info answers again after the restore"
    else
        fail_line assert_daemon_answers "docker info does not answer after the restore"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# C3: a UCI section in /etc/config/network
# --------------------------------------------------------------------------- #

_reload_network() {
    _RELOAD_RC=0
    _rsh 'ubus call network reload' >/dev/null 2>&1 || _RELOAD_RC=$?
}

class_network() {
    if ! _file_exists "${NETWORK}"; then
        gap_line precondition "${NETWORK} is not on the machine, so no section could be added to it"
        _bc_skip_adverse=1
        return 0
    fi
    _c3_orig=$(_read_file "${NETWORK}")
    if [ -z "${_c3_orig}" ]; then
        gap_line precondition "${NETWORK} answered nothing, so the live configuration could not be read"
        _bc_skip_adverse=1
        return 0
    fi

    _c3_dev_bad="${_c3_orig}

config interface '${NET_NAME}'
	option proto 'static'
	option device '${NET_DEV}'
	option ipaddr '10.255.255.254'
	option netmask '255.255.255.0'
"
    _inject c3-device "${NETWORK}" "${_c3_dev_bad}" || return 0
    _reload_network
    _c3_devout=$(_rsh "ip link show $(_sq "${NET_DEV}")" 2>&1)
    _c3_devrc=$?
    _c3_ifc=$(_rsh "ubus call network.interface.${NET_NAME} status" 2>&1)
    _c3_ifcrc=$?
    _emit "  network reload rc=${_RELOAD_RC}; ip link show ${NET_DEV} rc=${_c3_devrc}: $(printf '%s\n' "${_c3_devout}" | head -n 1)"
    _emit "  ubus call network.interface.${NET_NAME} status rc=${_c3_ifcrc}: $(printf '%s\n' "${_c3_ifc}" | head -n 1)"
    if [ "${_c3_devrc}" -ne 0 ] && ! printf '%s\n' "${_c3_ifc}" | grep -q '"up": *true'; then
        ok_line assert_device_refused "refused_by=netifd device=${NET_DEV} created=no up=no"
        _note_add "device=refused_by=netifd"
    else
        fail_line assert_device_refused \
            "refused_by=none: netifd took a section naming a device that does not exist (ip link show rc=${_c3_devrc}, status rc=${_c3_ifcrc})"
        _note_add "device=adopted"
    fi
    _restore c3-device "${NETWORK}" || return 0
    _reload_network
    if _rsh "ubus call network.interface.${NET_NAME} status" >/dev/null 2>&1; then
        fail_line assert_restored_effect "the bogus interface is still there after the restore"
    else
        ok_line assert_restored_effect "the bogus interface is gone after the restore"
    fi

    _c3_proto_bad="${_c3_orig}

config interface '${NET_NAME}_proto'
	option proto '${NET_PROTO}'
"
    _inject c3-proto "${NETWORK}" "${_c3_proto_bad}" || return 0
    _reload_network
    _c3_ifc2=$(_rsh "ubus call network.interface.${NET_NAME}_proto status" 2>&1)
    _c3_ifc2rc=$?
    _emit "  ubus call network.interface.${NET_NAME}_proto status rc=${_c3_ifc2rc}: $(printf '%s\n' "${_c3_ifc2}" | head -n 1)"
    if [ "${_c3_ifc2rc}" -ne 0 ] || ! printf '%s\n' "${_c3_ifc2}" | grep -q '"up": *true'; then
        ok_line assert_proto_refused "refused_by=netifd proto=${NET_PROTO} handler=none up=no"
        _note_add "proto=refused_by=netifd"
    else
        fail_line assert_proto_refused \
            "refused_by=none: netifd brought up an interface with a protocol no handler answers (${NET_PROTO})"
        _note_add "proto=adopted"
    fi
    _restore c3-proto "${NETWORK}" || return 0
    _reload_network
    if uci_export "$(basename "${NETWORK}")" >/dev/null 2>&1; then
        ok_line assert_restored_parses "the restored ${NETWORK} parses again"
    else
        fail_line assert_restored_parses "the restored ${NETWORK} does not parse"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# C4: a firewall rule fw4 skips
# --------------------------------------------------------------------------- #

class_firewall() {
    if ! _have fw4; then
        gap_line precondition \
            "no fw4 on this image (fw3 has no check subcommand), so the warn-and-skip case cannot be put"
        _bc_skip_adverse=1
        return 0
    fi
    if ! _file_exists "${FIREWALL}"; then
        gap_line precondition "${FIREWALL} is not on the machine, so no rule could be added to it"
        _bc_skip_adverse=1
        return 0
    fi
    _c4_orig=$(_read_file "${FIREWALL}")
    if [ -z "${_c4_orig}" ]; then
        gap_line precondition "${FIREWALL} answered nothing, so the live rules could not be read"
        _bc_skip_adverse=1
        return 0
    fi

    _c4_bad="${_c4_orig}

config rule
	option name '${FW_RULE}'
	option src 'wan'
	option proto 'tcp'
	option dest_port 'not-a-port'
	option target 'AB-BOGUS'
"
    _inject c4-rule "${FIREWALL}" "${_c4_bad}" || return 0

    # `check`, not a reload: a bad rule pushed to a live firewall is how a test takes its own
    # ssh session away. `check` parses and translates without touching the running ruleset.
    _c4_chk=$(_rsh 'fw4 check' 2>&1)
    _c4_chk_rc=$?
    _c4_print=$(_rsh 'fw4 print' 2>&1)
    _c4_print_rc=$?
    _c4_warn=no
    case "${_c4_chk}" in
        *invalid* | *skipped* | *Warning*) _c4_warn=yes ;;
    esac
    _c4_adopted=no
    case "${_c4_print}" in
        *"${FW_RULE}"* | *not-a-port*) _c4_adopted=yes ;;
    esac
    _emit "  fw4 check rc=${_c4_chk_rc} warning=${_c4_warn}: $(printf '%s\n' "${_c4_chk}" | grep -Ei 'warning|skipped' | head -n 2 | tr '\n' ' ')"
    _emit "  fw4 print rc=${_c4_print_rc}: $(printf '%s\n' "${_c4_print}" | grep -Eic "${FW_RULE}|not-a-port") line(s) carry the invalid rule"

    if [ "${_c4_adopted}" = "yes" ]; then
        fail_line assert_not_adopted \
            "adopted=yes: fw4 rendered the invalid rule into the ruleset, so a rule it should have skipped is live (check rc=${_c4_chk_rc})"
        _note_add "adopted=yes"
    else
        ok_line assert_not_adopted \
            "adopted=no: the rule is absent from the rendered ruleset (check rc=${_c4_chk_rc}, which is not the witness)"
        _note_add "adopted=no"
        _note_add "refused_by=fw4"
    fi
    if [ "${_c4_warn}" = "yes" ]; then
        ok_line assert_warning "warning=yes: $(printf '%s\n' "${_c4_chk}" | grep -Ei 'warning|skipped' | tr '\n' ' ')"
        _note_add "warning=yes"
    else
        finding_line assert_warning \
            "warning=no: fw4 dropped the section without saying why (check rc=${_c4_chk_rc})"
        _note_add "warning=no"
    fi
    _restore c4-rule "${FIREWALL}" || return 0
    _c4_chk2=$(_rsh 'fw4 check' 2>&1)
    _c4_chk2_rc=$?
    if [ "${_c4_chk2_rc}" -eq 0 ]; then
        ok_line assert_restored_parses "the restored firewall parses again (fw4 check rc=0)"
    else
        fail_line assert_restored_parses \
            "the restored firewall does not pass fw4 check (rc=${_c4_chk2_rc}): $(printf '%s\n' "${_c4_chk2}" | head -n 1)"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# C5: a fake subscription source
# --------------------------------------------------------------------------- #

class_subscription() {
    _FETCH_TOOL=$(fetch_tool)
    if [ -z "${_FETCH_TOOL}" ]; then
        gap_line precondition \
            "no uclient-fetch, wget or curl on this machine: a fake source cannot be refused by nothing"
        _bc_skip_adverse=1
        return 0
    fi
    if ! _file_exists "${OPENCLASH}"; then
        gap_line precondition "${OPENCLASH} is not on the machine: nowhere to write the fake source into"
        _bc_skip_adverse=1
        return 0
    fi
    _c5_orig=$(_read_file "${OPENCLASH}")
    _c5_bad="${_c5_orig}

config subscription '${NET_NAME}_sub'
	option url '${SUB_FAKE}'
"
    _inject c5-fake "${OPENCLASH}" "${_c5_bad}" || return 0

    # The control comes first: without a fetch that works, "the fake source was refused" cannot
    # be told apart from "this machine has no network from here".
    _fetch "${CONTROL_URL}"
    _c5_ctrl_rc=$?
    if [ "${_c5_ctrl_rc}" -ne 0 ]; then
        gap_line assert_control_fetch \
            "control=fetch-failed: ${CONTROL_URL} did not fetch either (${_FETCH_OUT}), so a refusal cannot be attributed to the fake source"
        _note_add "control=fetch-failed"
    else
        ok_line assert_control_fetch "control=fetch-ok url=${CONTROL_URL}: the machine's own fetcher still works"
        _note_add "control=fetch-ok"

        _fetch "${SUB_FAKE}"
        _c5_fake_rc=$?
        _c5_fake_kind=$(fetch_kind "${_c5_fake_rc}" "${_FETCH_OUT}")
        _emit "  ${_FETCH_TOOL} ${SUB_FAKE} rc=${_c5_fake_rc} kind=${_c5_fake_kind}: $(printf '%s\n' "${_FETCH_OUT}" | head -n 1)"
        case "${_c5_fake_kind}" in
            none)
                fail_line assert_fake_domain_refused \
                    "refused_by=none: ${SUB_FAKE} was fetched (rc=0), so a source that does not exist was accepted"
                _note_add "domain=accepted"
                ;;
            unknown)
                fail_line assert_fake_domain_refused \
                    "refused_by=unknown: the fetcher failed and said nothing this driver can attribute: $(printf '%s\n' "${_FETCH_OUT}" | head -n 1)"
                _note_add "domain=refused_by=unknown"
                ;;
            *)
                ok_line assert_fake_domain_refused "refused_by=${_c5_fake_kind}: $(printf '%s\n' "${_FETCH_OUT}" | head -n 1)"
                _note_add "domain=refused_by=${_c5_fake_kind}"
                ;;
        esac

        _fetch "${SUB_404}"
        _c5_404_rc=$?
        _c5_404_kind=$(fetch_kind "${_c5_404_rc}" "${_FETCH_OUT}")
        _emit "  ${_FETCH_TOOL} ${SUB_404} rc=${_c5_404_rc} kind=${_c5_404_kind}: $(printf '%s\n' "${_FETCH_OUT}" | head -n 1)"
        if [ "${_c5_404_kind}" = "http-404" ]; then
            ok_line assert_404_refused "refused_by=http-404: the host answered 404 and the fetcher failed"
            _note_add "404=refused_by=http-404"
        else
            fail_line assert_404_refused \
                "refused_by=${_c5_404_kind}: ${SUB_404} was not refused by an HTTP 404 (rc=${_c5_404_rc})"
            _note_add "404=refused_by=${_c5_404_kind}"
        fi
    fi

    _restore c5-fake "${OPENCLASH}" || return 0
    return 0
}

# --------------------------------------------------------------------------- #
# The other question: did the bad configuration damage anything?
# --------------------------------------------------------------------------- #

pre_capture() { # <dir>
    _pc_dir=$1
    mkdir -p "${_pc_dir}" 2>/dev/null || true
    _rsh "apk info -v 2>/dev/null | sort" >"${_pc_dir}/packages.pre" 2>/dev/null ||
        : >"${_pc_dir}/packages.pre"
    _rsh "docker volume ls -q 2>/dev/null | sort" >"${_pc_dir}/volumes.pre" 2>/dev/null ||
        : >"${_pc_dir}/volumes.pre"
    _rsh "cat $(_sq "${MARKER}") 2>/dev/null" >"${_pc_dir}/marker.pre" 2>/dev/null ||
        : >"${_pc_dir}/marker.pre"
    return 0
}

_ac_add() { _ac_note="${_ac_note} $1=$2"; }

# adverse_check <case> <pre-dir>: the five facts that say the machine is still a machine. They
# are their own row, because a class that was refused and a machine that was damaged are two
# different findings.
adverse_check() {
    _ac_case=$1
    _ac_pre=$2
    _ac_saved_cur=${_bc_cur}
    _ac_saved_fails=${_bc_fails}
    _bc_cur="${_ac_case}-adverse"
    _bc_fails=0
    _ac_note=""

    # 1. the machine still answers
    if _rsh 'true' >/dev/null 2>&1; then
        ok_line assert_reachable "the machine answered ssh with the bad configuration in place"
        _ac_add reachable ok
    else
        fail_line assert_reachable "the machine stopped answering ssh"
        _ac_add reachable fail
    fi

    # 2. ab-slot status: degraded is fine, unreadable or a moved destructive field is not
    _ac_line=$(dev_status) || _ac_line=""
    if [ -z "${_ac_line}" ]; then
        fail_line assert_status "ab-slot status answered nothing (it must degrade, not crash)"
        _ac_add status fail
    else
        _ac_sbad=0
        for _ac_f in boot esp data; do
            _ac_v=$(status_field "${_ac_line}" "${_ac_f}") || _ac_v=missing
            if [ "${_ac_v}" != "ok" ]; then
                fail_line assert_status "${_ac_f}=${_ac_v} (expected ok): ${_ac_line}"
                _ac_sbad=1
            fi
        done
        if _have docker; then
            _ac_v=$(status_field "${_ac_line}" docker) || _ac_v=missing
            if [ "${_ac_v}" != "ok" ]; then
                fail_line assert_status "docker=${_ac_v} (expected ok): ${_ac_line}"
                _ac_sbad=1
            fi
        fi
        if [ "${_ac_sbad}" -eq 0 ]; then
            ok_line assert_status "ab-slot status still answers with boot/esp/data ok"
            _ac_add status ok
        else
            _ac_add status fail
        fi
    fi

    # 3. the installed package set did not move
    _rsh "apk info -v 2>/dev/null | sort" >"${_ac_pre}/packages.post" 2>/dev/null ||
        : >"${_ac_pre}/packages.post"
    if cmp -s "${_ac_pre}/packages.pre" "${_ac_pre}/packages.post"; then
        ok_line assert_packages "apk info -v is unchanged ($(wc -l <"${_ac_pre}/packages.pre" | tr -d ' ') package lines)"
        _ac_add packages ok
    else
        fail_line assert_packages \
            "apk info -v moved: $(wc -l <"${_ac_pre}/packages.pre" | tr -d ' ') package lines before, $(wc -l <"${_ac_pre}/packages.post" | tr -d ' ') after (see ${_ac_pre}/packages.pre and packages.post)"
        _ac_add packages fail
    fi

    # 4. /data and the docker volumes
    _rsh "cat $(_sq "${MARKER}") 2>/dev/null" >"${_ac_pre}/marker.post" 2>/dev/null ||
        : >"${_ac_pre}/marker.post"
    if cmp -s "${_ac_pre}/marker.pre" "${_ac_pre}/marker.post"; then
        ok_line assert_data "the /data marker is unchanged (${MARKER})"
        _ac_add data ok
    else
        fail_line assert_data "the /data marker changed: ${MARKER} is not what it was"
        _ac_add data fail
    fi
    if _have docker; then
        _rsh "docker volume ls -q 2>/dev/null | sort" >"${_ac_pre}/volumes.post" 2>/dev/null ||
            : >"${_ac_pre}/volumes.post"
        if cmp -s "${_ac_pre}/volumes.pre" "${_ac_pre}/volumes.post"; then
            ok_line assert_docker_volumes "the docker volume set is unchanged ($(wc -l <"${_ac_pre}/volumes.pre" | tr -d ' ') volumes)"
            _ac_add volumes ok
        else
            fail_line assert_docker_volumes "the docker volume set changed: $(printf '%s ' "$(cat "${_ac_pre}/volumes.pre")") -> $(printf '%s ' "$(cat "${_ac_pre}/volumes.post")")"
            _ac_add volumes fail
        fi
    else
        ok_line assert_docker_volumes "no docker on this image, so there is no volume set to damage"
        _ac_add volumes none
    fi

    # 5. ubus and rpcd still answer
    if _rsh 'ubus -t 5 call system board >/dev/null 2>&1 && ubus -t 5 call session list >/dev/null 2>&1'; then
        ok_line assert_ubus "ubus and rpcd still answer (system board, session list)"
        _ac_add ubus ok
    else
        fail_line assert_ubus "ubus/rpcd stopped answering (ubus call system board / session list)"
        _ac_add ubus fail
    fi

    _ac_seen=${_bc_fails}
    _bc_fails=${_ac_saved_fails}
    _bc_cur=${_ac_saved_cur}
    if [ "${_ac_seen}" -eq 0 ]; then
        _ac_verdict=PASS
        TOT_PASS=$((TOT_PASS + 1))
    else
        _ac_verdict=FAIL
        TOT_FAIL=$((TOT_FAIL + 1))
    fi
    record "${_ac_case}-adverse" "${_ac_verdict}" "${_bc_ev}" "$(printf '%s' "${_ac_note}" | sed 's/^ //')"
    return 0
}

# --------------------------------------------------------------------------- #
# One class
# --------------------------------------------------------------------------- #

run_case() {
    _rc_id=$1
    _bc_cur=${_rc_id}
    _bc_fails=0
    _bc_gaps=0
    _bc_note=""
    _bc_skip_adverse=0
    CASE_RERUN="${AB_MATRIX_CMD:-./scripts/device/badconfig-probe.sh --case ${_rc_id}}"
    mkdir -p "${EV_DIR}" 2>/dev/null || true
    CASE_LOG="${EV_DIR}/${_rc_id}.log"
    : >"${CASE_LOG}" 2>/dev/null || CASE_LOG=""
    _bc_ev=${CASE_LOG:-${RESULTS}}

    _emit ""
    _emit "== ${_rc_id} $(case_title "${_rc_id}") =="
    pre_capture "${EV_DIR}/${_rc_id}-pre"
    case "${_rc_id}" in
        C1) class_openclash ;;
        C2) class_docker ;;
        C3) class_network ;;
        C4) class_firewall ;;
        C5) class_subscription ;;
    esac

    _rc_verdict=PASS
    [ "${_bc_gaps}" -gt 0 ] && _rc_verdict=GAP
    [ "${_bc_fails}" -gt 0 ] && _rc_verdict=FAIL
    case "${_rc_verdict}" in
        PASS) TOT_PASS=$((TOT_PASS + 1)) ;;
        FAIL) TOT_FAIL=$((TOT_FAIL + 1)) ;;
        *) TOT_GAP=$((TOT_GAP + 1)) ;;
    esac
    record "${_rc_id}" "${_rc_verdict}" "${_bc_ev}" "$(printf '%s' "${_bc_note}" | sed 's/^ //')"
    _emit "== ${_rc_id} ${_rc_verdict}$(printf '%s' "${_bc_note}")"

    [ "${_bc_skip_adverse}" -eq 0 ] && adverse_check "${_rc_id}" "${EV_DIR}/${_rc_id}-pre"
    CASE_LOG=""
    return 0
}

# --------------------------------------------------------------------------- #
# Plan, and the way in
# --------------------------------------------------------------------------- #

print_plan() {
    printf 'badconfig-probe dry-run host=%s cases=%s results=%s\n' "${AB_HOST}" "${CASES}" "${RESULTS}"
    for _pl_c in ${CASES}; do
        printf 'plan [%s] %s\n' "${_pl_c}" "$(case_title "${_pl_c}")"
        case "${_pl_c}" in
            C1)
                printf 'plan [C1] inject %s syntax=unterminated-quote type=wrong-boolean; witness "uci -q export" + "%s start"; restore by backup+sha256; adverse reachable, ab-slot status, apk info -v, %s, ubus\n' \
                    "${OPENCLASH}" "${OPENCLASH_INIT}" "${MARKER}"
                ;;
            C2)
                printf 'plan [C2] inject %s truncated-json unknown-option; witness "dockerd --validate --config-file" else "%s restart" + "docker info" x%s; restore by backup+sha256; adverse as C1\n' \
                    "${DOCKER_JSON}" "${DOCKER_INIT}" "${DOCKER_TRIES}"
                ;;
            C3)
                printf 'plan [C3] inject %s +interface device=%s and +interface proto=%s; witness "ubus call network reload" + "ip link show" + "ubus call network.interface.<name> status"; restore by backup+sha256; adverse as C1\n' \
                    "${NETWORK}" "${NET_DEV}" "${NET_PROTO}"
                ;;
            C4)
                printf 'plan [C4] inject %s +rule name=%s dest_port=not-a-port target=AB-BOGUS; witness "fw4 check" (rc is not the answer) + "fw4 print" must not carry the rule; never reloads; restore by backup+sha256; adverse as C1\n' \
                    "${FIREWALL}" "${FW_RULE}"
                ;;
            C5)
                printf 'plan [C5] inject %s +subscription url=%s; control fetch %s first; witness the fetcher on %s and %s; restore by backup+sha256; adverse as C1\n' \
                    "${OPENCLASH}" "${SUB_FAKE}" "${CONTROL_URL}" "${SUB_FAKE}" "${SUB_404}"
                ;;
        esac
    done
    printf 'badconfig-probe result=dry-run cases=%s writes=0\n' "${N_CASES}"
}

if [ "${DRY_RUN}" = "1" ]; then
    print_plan
    exit 0
fi

# --- the machine, before anything is written ------------------------------- #
if ! _rsh 'true' >/dev/null 2>&1; then
    printf 'badconfig-probe unreachable: %s did not answer ssh\n' "${AB_HOST}"
    for _c in ${CASES}; do
        record "${_c}" GAP - "machine unreachable"
        TOT_GAP=$((TOT_GAP + 1))
    done
    printf 'badconfig-probe cases=%s pass=%s fail=%s gap=%s results=%s\n' \
        "${N_CASES}" "${TOT_PASS}" "${TOT_FAIL}" "${TOT_GAP}" "${RESULTS}"
    printf 'badconfig-probe exit=4\n'
    exit 4
fi

# The red line: a bad configuration on a 24.x machine says nothing about this product (24.x is
# the opkg line, a different package manager, a different firewall model and a different kmod
# layout), so the run stops here rather than writing a verdict that cannot be transferred.
_ver=$(dev_running_version 2>/dev/null) || _ver=""
if ! _line=$(require_supported_line "${_ver}" 2>&1); then
    printf '%s\n' "${_line}"
    printf 'badconfig-probe: red line: the machine runs %s, which is not on the 25.x/apk line, so nothing was written\n' \
        "${_ver:-an unknown version}"
    printf 'badconfig-probe exit=3\n'
    exit 3
fi
printf 'badconfig-probe %s\n' "${_line}"

for _c in ${CASES}; do
    run_case "${_c}"
done

_rc=0
[ "${TOT_GAP}" -gt 0 ] && _rc=4
[ "${TOT_FAIL}" -gt 0 ] && _rc=1
printf '\nbadconfig-probe cases=%s pass=%s fail=%s gap=%s results=%s\n' \
    "${N_CASES}" "${TOT_PASS}" "${TOT_FAIL}" "${TOT_GAP}" "${RESULTS}"
printf 'badconfig-probe exit=%s\n' "${_rc}"
exit "${_rc}"
