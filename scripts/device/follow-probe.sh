#!/bin/sh
# follow-probe.sh - after a base hop, are the community samples still USABLE, and did their
# configuration and data survive the hop?
#
#   follow-probe.sh --install           # install the samples the manifest names
#   follow-probe.sh --mark              # write the fake config + data marker, record baseline
#   ... hop the machine to the next base ...
#   follow-probe.sh --verify            # usable? config sha256 unchanged? data sha256 unchanged?
#   follow-probe.sh --unmark            # put the machine back the way --mark found it
#
#   --sample NAME    repeatable; restrict any action to the named samples
#   --state FILE     the baseline TSV (default /tmp/ab-follow-state.tsv)
#   --manifest FILE  the sample list (default tests/fixtures/follow-samples.json)
#   --dry-run        print the remote script and exit; no ssh call, no state file, no row
#
# One line per sample:
#
#   probe=<pkg> status=<pass|fail|gap|skip> ac=<ac-2|ac-3> <fact=value ...>
#
#   pass  the sample's own criterion matched, and both sha256 values are what --mark saw
#   fail  it did not: the row carries a reason token (not-installed, unusable,
#         check-crashed, config-changed, data-lost, no-answer, no-baseline) and the facts
#   gap   the sample could not be installed when --mark ran (reason=install-gap). This is
#         the only GAP class the matrix accepts: a package the feed does not offer is a
#         finding about the feed, not a defect of the A/B machinery (PRD risk 3, istore
#         measured rc=1 in round 03)
#   skip  no machine answered, or --dry-run asked for nothing: never a pass
#
# Exit status: 0 every sample passed, 1 at least one failed, 2 usage, 3 nothing failed but
# at least one sample was skipped, 4 nothing failed but at least one sample is a gap.
#
# Why a manifest and not a case statement
# --------------------------------------
# "Is this package still usable" has a different answer per package, and the whole point of
# the sample set is that each answer is reviewable on its own: the theme is its stylesheet
# served by this base's web server, docker is `docker info` answering, a kmod is its .ko
# present under the RUNNING kernel's /lib/modules, htop is the binary starting. That
# criterion lives in tests/fixtures/follow-samples.json as one command plus the ERE its
# output has to match, so this driver never grows a per-package branch and adding a ninth
# sample is a fixture edit. The manifest is therefore code: it is reviewed like a script.
#
# What is measured, and where
# ---------------------------
# --mark writes two markers and records three facts per sample:
#   config   /etc/config/<name> gains `option ab_marker '<sha>'` under a
#            `config marker 'ab_follow'` section (the sha is derived from the sample name,
#            so a second --mark writes the same bytes - the baseline is idempotent)
#   data     <data_marker> (default /data/ab-follow/<name>.marker) is written on the shared
#            data partition, which is what proves the data half of the machine survived
#   version  the installed apk version, recorded as a fact and NOT asserted later: a package
#            that followed the new base has a new version and is still the same package
# The baseline (version, config sha256, data sha256) lands in --state, on the operator's
# machine, because /tmp on the device does not survive the hop it is there to measure.
#
# Hygiene on a machine somebody else is using
# -------------------------------------------
# The config marker is appended, never overwritten: the file --mark found is copied once to
# <config><suffix> (.ab-follow-bak) and a file --mark had to create is recorded as an empty
# backup, which is how --unmark knows whether to restore or delete. --unmark restores every
# backup and removes the data markers. Nothing here starts a daemon, reboots or writes
# outside /etc/config/<name>, /data/ab-follow and /tmp.
#
# Environment: AB_HOST, AB_KEY, AB_FOLLOW_MANIFEST, AB_FOLLOW_STATE, AB_FOLLOW_MARKER_DIR,
#              AB_FOLLOW_BAK_SUFFIX, AB_FOLLOW_INSTALL_TIMEOUT (180 s), AB_DRY_RUN.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

MANIFEST=${AB_FOLLOW_MANIFEST:-${AB_REPO_ROOT}/tests/fixtures/follow-samples.json}
STATE=${AB_FOLLOW_STATE:-/tmp/ab-follow-state.tsv}
MARKER_DIR=${AB_FOLLOW_MARKER_DIR:-/data/ab-follow}
BAK_SUFFIX=${AB_FOLLOW_BAK_SUFFIX:-.ab-follow-bak}
INSTALL_TIMEOUT=${AB_FOLLOW_INSTALL_TIMEOUT:-180}
TAB=$(printf '\t')

ACTION=""
SAMPLES=""
DRY_RUN=0
ROWS=0
PASS_N=0
FAIL_N=0
GAP_N=0
SKIP_N=0
_records=""
_answer=""
_answer_rc=0
_tmpfile=""
_row_name=""
_row_pkgs=""
_row_cfg=""
_row_dat=""
_row_cmd=""
_row_exp=""
_row_needs=""

usage() {
    cat <<'USAGE'
usage: follow-probe.sh --install | --mark | --verify | --unmark
                       [--sample NAME]... [--state FILE] [--manifest FILE] [--dry-run]

  --install   install the samples the manifest names; a sample that cannot be installed is
              a GAP with the command to rerun, never a FAIL
  --mark      write the fake config and the data marker, and record (version, config
              sha256, data sha256) per sample in --state
  --verify    read the baseline back and assert, per sample: still usable, config sha256
              unchanged, data marker unchanged
  --unmark    restore the configs and remove the markers --mark left behind
  --sample NAME    repeatable; only this sample
  --state FILE     the baseline TSV (default /tmp/ab-follow-state.tsv)
  --manifest FILE  the sample list (default tests/fixtures/follow-samples.json)
  --dry-run        print the remote script and exit; no ssh call, no row

Exit status: 0 all passed, 1 a failure, 2 usage, 3 a skip, 4 a gap and no failure.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install | --mark | --verify | --unmark)
            if [ -n "${ACTION}" ]; then
                printf 'follow-probe: one action at a time: %s came after --%s\n' "$1" "${ACTION}" >&2
                exit 2
            fi
            ACTION=${1#--}
            shift
            ;;
        --sample)
            SAMPLES="${SAMPLES} ${2:?--sample needs a name}"
            shift 2
            ;;
        --state)
            STATE=${2:?--state needs a file}
            shift 2
            ;;
        --manifest)
            MANIFEST=${2:?--manifest needs a file}
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'follow-probe: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "${ACTION}" ]; then
    printf 'follow-probe: one of --install --mark --verify --unmark is required\n' >&2
    usage >&2
    exit 2
fi
[ "${AB_DRY_RUN:-0}" = "1" ] && DRY_RUN=1

# --------------------------------------------------------------------------- #
# Bookkeeping
# --------------------------------------------------------------------------- #

_cleanup() {
    [ -n "${_records}" ] && rm -f "${_records}" 2>/dev/null
    [ -n "${_tmpfile}" ] && rm -f "${_tmpfile}" 2>/dev/null
    return 0
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM

# _sq <text>: single-quote a value for the remote shell. Sample names and paths come from
# the manifest and are simple, but a probe that pastes strings into a remote script without
# quoting is one fixture edit away from running somebody else's command on the machine.
_sq() {
    case "${1}" in
        *"'"*) printf "'%s'" "$(printf '%s' "${1}" | sed "s/'/'\\\\''/g")" ;;
        *) printf "'%s'" "${1}" ;;
    esac
}

_short() { # <sha256>: enough of it to compare in a report, not enough to be the baseline
    printf '%s' "${1}" | cut -c1-12
}

_emit() { # <name> <status> <ac> <facts>
    ROWS=$((ROWS + 1))
    case "${2}" in
        pass) PASS_N=$((PASS_N + 1)) ;;
        fail) FAIL_N=$((FAIL_N + 1)) ;;
        gap) GAP_N=$((GAP_N + 1)) ;;
        skip) SKIP_N=$((SKIP_N + 1)) ;;
    esac
    if [ -n "${4}" ]; then
        printf 'probe=%s status=%s ac=%s %s\n' "${1}" "${2}" "${3}" "${4}"
    else
        printf 'probe=%s status=%s ac=%s\n' "${1}" "${2}" "${3}"
    fi
}

_summary() {
    printf 'follow-probe summary action=%s rows=%s pass=%s fail=%s gap=%s skip=%s\n' \
        "${ACTION}" "${ROWS}" "${PASS_N}" "${FAIL_N}" "${GAP_N}" "${SKIP_N}"
}

_verdict() {
    if [ "${FAIL_N}" -gt 0 ]; then
        return 1
    elif [ "${SKIP_N}" -gt 0 ]; then
        return 3
    elif [ "${GAP_N}" -gt 0 ]; then
        return 4
    fi
    return 0
}

_rerun() { # <action> <sample>: the command a reader pastes to repeat one sample
    printf 'sh scripts/device/follow-probe.sh --%s --sample %s' "${1}" "${2}"
}

# --------------------------------------------------------------------------- #
# The manifest
# --------------------------------------------------------------------------- #

# _manifest_dump <file>: the manifest as flat records, one per line:
#   meta    <key>   <value>                    (schema, updated, version_line)
#   sample  <name>  <packages>  <config_path>  <data_marker>  <cmd>  <expect>  <needs>
#
# python3 and not awk: the descriptor holds a nested object (check) and an array
# (packages), which a character scanner reads only by accident. The driver runs on the
# operator's machine, where the repository's own scripts already require python3.
_manifest_dump() {
    python3 - "${1}" "${MARKER_DIR}" <<'PY'
import json
import sys

path = sys.argv[1]
marker_dir = sys.argv[2].rstrip("/")
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    sys.exit("follow-probe: %s: %s" % (path, exc))

out = []
for key in ("schema", "updated", "version_line"):
    value = doc.get(key)
    if isinstance(value, (str, int)):
        out.append("meta\t%s\t%s" % (key, value))

samples = doc.get("samples") or []
if not samples:
    sys.exit("follow-probe: %s: the manifest names no samples" % path)

seen = set()
for sample in samples:
    name = (sample.get("name") or "").strip()
    if not name:
        sys.exit("follow-probe: %s: a sample has no name" % path)
    if name in seen:
        sys.exit("follow-probe: %s: sample %s is listed twice" % (path, name))
    seen.add(name)
    check = sample.get("check") or {}
    cmd = (check.get("cmd") or "").strip()
    expect = (check.get("expect") or "").strip() or "^ok"
    if not cmd:
        sys.exit("follow-probe: %s: sample %s has no check command" % (path, name))
    for value in (name, cmd, expect):
        if "\n" in value or "\t" in value:
            sys.exit("follow-probe: %s: sample %s: a manifest string carries a newline or a tab"
                     % (path, name))
    # A sample may leave the two paths out; the defaults are the ones the task's design
    # names, so a ninth sample does not have to repeat them.
    config_path = sample.get("config_path") or "/etc/config/%s" % name
    data_marker = sample.get("data_marker") or "%s/%s.marker" % (marker_dir, name)
    fields = [
        "sample",
        name,
        " ".join(sample.get("packages") or []),
        config_path,
        data_marker,
        cmd,
        expect,
        ",".join(sample.get("needs") or []),
    ]
    out.append("\t".join(fields))

sys.stdout.write("\n".join(out) + "\n")
PY
}

_load_manifest() {
    if [ ! -f "${MANIFEST}" ]; then
        printf 'follow-probe: %s: no such manifest\n' "${MANIFEST}" >&2
        return 1
    fi
    _records=$(mktemp) || return 1
    if ! _manifest_dump "${MANIFEST}" >"${_records}"; then
        printf 'follow-probe: %s: the sample manifest could not be read\n' "${MANIFEST}" >&2
        return 1
    fi
    _known=$(awk -F'\t' '$1 == "sample" { print $2 }' "${_records}")
    for _name in ${SAMPLES}; do
        if ! printf '%s\n' "${_known}" | grep -qx "${_name}"; then
            printf 'follow-probe: --sample %s: not in %s\n' "${_name}" "${MANIFEST}" >&2
            return 1
        fi
    done
    return 0
}

_want() { # <name>: did the caller ask for this sample?
    [ -n "${SAMPLES}" ] || return 0
    case " ${SAMPLES} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# _each_sample <callback>: walk the wanted samples, one call per line, with the row fields
# in _row_* . The loop reads a file rather than a pipe, so the counters a callback bumps
# keep their value after the walk.
_each_sample() {
    while IFS= read -r _line; do
        _split_row "${_line}"
        [ "${_f1}" = "sample" ] || continue
        _row_name=${_f2}
        _row_pkgs=${_f3}
        _row_cfg=${_f4}
        _row_dat=${_f5}
        _row_cmd=${_f6}
        _row_exp=${_f7}
        _row_needs=${_f8}
        _want "${_row_name}" || continue
        "${1}"
    done <"${_records}"
}

_want_list() {
    if [ -n "${SAMPLES}" ]; then
        printf '%s\n' "${SAMPLES# }" | tr ' ' '\n' | awk 'NF { printf "%s ", $0 }'
    else
        awk -F'\t' '$1 == "sample" { printf "%s ", $2 }' "${_records}"
    fi | sed 's/ $//'
}

# --------------------------------------------------------------------------- #
# The remote half
# --------------------------------------------------------------------------- #

# The helpers a manifest command may use. Every one of them answers a question about the
# machine as it is - none of them starts, loads or enables anything, because the machine a
# hop lands on is also a machine somebody else may be measuring.
_remote_preamble() {
    cat <<'REMOTE'
_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
_ver() { apk list --installed "$1" 2>/dev/null | head -1 | awk '{print $1}'; }
# Payload files the package record names that disk no longer has. etc/uci-defaults/* is
# excluded on purpose: the base runs those once at first boot and deletes them, so their
# absence is the normal state of an installed package (measured 2026-11-18: two of the
# three samples checked on the reference machine).
_missing() {
    apk info -L "$1" 2>/dev/null | sed -n '/ contains:$/,$p' | tail -n +2 |
        grep -v '/$' | grep -v '^etc/uci-defaults/' |
        while IFS= read -r _mf; do [ -z "$_mf" ] || [ -e "/$_mf" ] || printf 'x'; done |
        wc -c | tr -d ' '
}
# The status code of one path from the machine's own web server. Port 80 is firewalled from
# the LAN side (measured 2026-11-17), so the request goes over loopback, and nc is what the
# base ships.
_http() {
    printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' "$1" |
        nc 127.0.0.1 80 2>/dev/null | head -1 | awk '{print $2}'
}
# A service's state, without starting it: running, stopped, expected-not-running (enabled
# at boot but no process now, which is the app being broken) or missing.
_svc() {
    [ -x "$1" ] || { echo missing; return 0; }
    if pidof "$2" >/dev/null 2>&1; then echo running; return 0; fi
    if "$1" enabled >/dev/null 2>&1; then echo expected-not-running; return 0; fi
    echo stopped
}
REMOTE
}

_inst_helpers() {
    printf 'SFX=%s\n' "$(_sq "${BAK_SUFFIX}")"
}

# One sample's install: apk add, the status, and the first 240 characters of what it said.
_remote_install_block() {
    [ -n "${_row_pkgs}" ] || return 0
    printf '_to apk add %s >/tmp/ab-follow-inst.$$ 2>&1\n' "${_row_pkgs}"
    printf '_rc=$?\n'
    printf 'printf "%%s\\t%%s\\t%%s\\n" %s "$_rc" "$(tr "\\n" " " </tmp/ab-follow-inst.$$ | cut -c1-240)"\n' \
        "$(_sq "${_row_name}")"
    printf 'rm -f /tmp/ab-follow-inst.$$\n'
}

# One sample's mark: the fake config, the data marker, and the three baseline facts.
_remote_mark_block() {
    printf 'name=%s\n' "$(_sq "${_row_name}")"
    printf 'cfg=%s\n' "$(_sq "${_row_cfg}")"
    printf 'dat=%s\n' "$(_sq "${_row_dat}")"
    printf 'pkg0=%s\n' "$(_sq "${_row_pkgs%% *}")"
    cat <<'REMOTE'
ms=$(printf 'ab-follow:%s:v1' "$name" | sha256sum | awk '{print $1}')
v=$(_ver "$pkg0")
if [ -z "$v" ] || [ -z "$cfg" ] || [ -z "$dat" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" 0 "" "" "" not-installed
else
    _rc=0
    _d=marked
    _dd=${dat%/*}
    [ -d "$_dd" ] || mkdir -p "$_dd" 2>/dev/null || { _rc=1; _d=mkdir-failed; }
    _cd=${cfg%/*}
    [ -d "$_cd" ] || mkdir -p "$_cd" 2>/dev/null || { _rc=1; _d=mkdir-failed; }
    if [ "$_rc" = 0 ]; then
        if [ -f "$cfg" ]; then
            [ -f "$cfg$SFX" ] || cp "$cfg" "$cfg$SFX" 2>/dev/null || true
        else
            [ -f "$cfg$SFX" ] || : >"$cfg$SFX" 2>/dev/null || true
        fi
        sed -i "/ab_marker/d; /^config marker 'ab_follow'\$/d" "$cfg" 2>/dev/null
        printf "config marker 'ab_follow'\n\toption ab_marker '%s'\n" "$ms" >>"$cfg" 2>/dev/null ||
            { _rc=1; _d=config-write-failed; }
        printf 'pkg=%s\nmarker=%s\n' "$name" "$ms" >"$dat" 2>/dev/null ||
            { _rc=1; _d=data-write-failed; }
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$_rc" "$v" "$(_sha "$cfg")" "$(_sha "$dat")" "$_d"
fi
REMOTE
}

# One sample's verify: the installed version, both sha256 values, and the sample's own
# criterion (verbatim from the manifest) with its exit status and output.
_remote_verify_block() {
    printf 'name=%s\n' "$(_sq "${_row_name}")"
    printf 'cfg=%s\n' "$(_sq "${_row_cfg}")"
    printf 'dat=%s\n' "$(_sq "${_row_dat}")"
    printf 'pkg0=%s\n' "$(_sq "${_row_pkgs%% *}")"
    # The driver's own variables are underscore-prefixed because the criterion below is
    # somebody else's shell: a criterion may use `v`, `cs` or `co` for its own facts, and a
    # probe that shares those names with the code that records the result measures the
    # variable, not the package.
    printf '_pv=$(_ver "$pkg0")\n'
    printf '_pcs=$(_sha "$cfg")\n'
    printf '_pds=$(_sha "$dat")\n'
    printf '_pcr=0\n'
    printf '_pco=$( { %s\n} 2>&1 ) || _pcr=$?\n' "${_row_cmd}"
    printf 'printf "%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\n" "$name" "$_pv" "$_pcs" "$_pds" "$_pcr" "$(printf "%%s" "$_pco" | tr "\\n\\t" "  " | cut -c1-240)"\n'
}

_remote_unmark_block() {
    printf 'name=%s\n' "$(_sq "${_row_name}")"
    printf 'cfg=%s\n' "$(_sq "${_row_cfg}")"
    printf 'dat=%s\n' "$(_sq "${_row_dat}")"
    cat <<'REMOTE'
if [ -f "$cfg$SFX" ]; then
    if [ -s "$cfg$SFX" ]; then
        mv "$cfg$SFX" "$cfg" 2>/dev/null && _d=restored || _d=restore-failed
    else
        rm -f "$cfg" "$cfg$SFX" 2>/dev/null && _d=removed || _d=remove-failed
    fi
elif [ -f "$cfg" ]; then
    sed -i "/ab_marker/d; /^config marker 'ab_follow'\$/d" "$cfg" 2>/dev/null && _d=stripped || _d=strip-failed
else
    _d=absent
fi
[ -f "$dat" ] && rm -f "$dat" 2>/dev/null && _d="$_d+data-removed"
# The marker's directory is this run's creation too: leaving an empty /data/ab-follow
# behind would be a trace on a machine somebody else is looking at.
rmdir "${dat%/*}" 2>/dev/null || true
printf '%s\t%s\t%s\n' "$name" 0 "$_d"
REMOTE
}

_remote_script() { # <install|mark|verify|unmark>: the whole remote half on stdout
    case "${1}" in
        install)
            printf 'set -u\n'
            printf '_t=%s\n' "${INSTALL_TIMEOUT}"
            printf '_to() { if command -v timeout >/dev/null 2>&1; then timeout "$_t" "$@"; else "$@"; fi; }\n'
            _each_sample _remote_install_block
            ;;
        mark | unmark)
            printf 'set -u\n'
            _inst_helpers
            _remote_preamble
            _each_sample "_remote_${1}_block"
            ;;
        verify)
            printf 'set -u\n'
            _remote_preamble
            _each_sample "_remote_verify_block"
            ;;
        *)
            printf 'follow-probe: unknown remote half: %s\n' "${1}" >&2
            return 2
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Asking the machine
# --------------------------------------------------------------------------- #

# _ask: run the script _remote_script produced for this action, in one ssh call.
# Returns 1 when no machine answered: an unanswered probe is a skip, never a pass.
_ask() {
    _tmpfile=$(mktemp) || return 1
    if ! _remote_script "${ACTION}" >"${_tmpfile}"; then
        return 1
    fi
    _answer=$(dev_ssh "$(cat "${_tmpfile}")")
    _answer_rc=$?
    rm -f "${_tmpfile}"
    _tmpfile=""
    if [ "${_answer_rc}" -ne 0 ] || [ -z "${_answer}" ]; then
        return 1
    fi
    return 0
}

_plan() {
    printf 'follow-probe dry-run: action=%s samples="%s" state=%s manifest=%s\n' \
        "${ACTION}" "$(_want_list)" "${STATE}" "${MANIFEST}"
    _each_sample _plan_row
    printf '%s\n' 'follow-probe dry-run: remote script:'
    _remote_script "${ACTION}" | sed 's/^/    /'
    printf 'follow-probe dry-run: ssh %s (script above); nothing was contacted\n' "${AB_HOST}"
    return 0
}

_skip_all() { # <ac> <reason>
    _skip_ac=${1}
    _skip_reason=${2}
    _each_sample _row_skip
}

_row_skip() {
    _emit "${_row_name}" skip "${_skip_ac}" "reason=${_skip_reason}"
}

# One line per sample in a dry run: what would be installed and what the criterion needs
# (network, service, http, kernel), so a reader can see the prerequisites before a run
# touches the machine.
_plan_row() {
    printf 'follow-probe dry-run: sample=%s packages="%s" needs=%s\n' \
        "${_row_name}" "${_row_pkgs}" "${_row_needs:--}"
}

# A TSV row is split with parameter expansion, not with `read`: IFS treats the tab as
# whitespace, so `read` collapses the empty field an uninstallable sample leaves where its
# version would be and the row shifts one column left - the contract test caught exactly
# that on 2026-11-18 (istore's "not-installed" arrived in the version column). One awk per
# row and not one per field, because this driver is called once per hop, not once per fact.
_pop_field() {
    case "${_rest}" in
        *"${TAB}"*)
            _pop=${_rest%%"${TAB}"*}
            _rest=${_rest#*"${TAB}"}
            ;;
        *)
            _pop=${_rest}
            _rest=""
            ;;
    esac
}

_split_row() { # <line>: _f1 .. _f8, empty fields included
    _rest=${1}
    _pop_field
    _f1=${_pop}
    _pop_field
    _f2=${_pop}
    _pop_field
    _f3=${_pop}
    _pop_field
    _f4=${_pop}
    _pop_field
    _f5=${_pop}
    _pop_field
    _f6=${_pop}
    _pop_field
    _f7=${_pop}
    _pop_field
    _f8=${_pop}
}

_answer_row() { # <name>: 1 when the machine said nothing about this sample
    _line=$(printf '%s\n' "${_answer}" | awk -F'\t' -v n="${1}" '$1 == n { print; exit }')
    [ -n "${_line}" ] || return 1
    _split_row "${_line}"
    return 0
}

_baseline_row() { # <name>: 1 when the baseline does not cover this sample
    [ -f "${STATE}" ] || return 1
    _line=$(awk -F'\t' -v n="${1}" '$1 == n && $1 !~ /^#/ { print; exit }' "${STATE}")
    [ -n "${_line}" ] || return 1
    _split_row "${_line}"
    return 0
}

# _quoted <text>: a fact value wrapped in quotes, so a criterion's output with spaces in it
# stays one field a reader can copy.
_quoted() {
    printf '"%s"' "$(printf '%s' "${1}" | tr '\t\n' '  ' | cut -c1-240)"
}

# --------------------------------------------------------------------------- #
# --install
# --------------------------------------------------------------------------- #

_do_install() {
    if [ "${DRY_RUN}" = 1 ]; then
        _plan
        return 0
    fi
    if ! _ask; then
        _skip_all ac-2 no-machine
        return 0
    fi
    _each_sample _row_install
    return 0
}

_row_install() {
    if ! _answer_row "${_row_name}"; then
        _emit "${_row_name}" fail ac-2 "reason=no-answer packages=${_row_pkgs}"
        return 0
    fi
    _rc=${_f2}
    if [ "${_rc}" = "0" ]; then
        _emit "${_row_name}" pass ac-2 "packages=${_row_pkgs}"
        return 0
    fi
    _emit "${_row_name}" gap ac-2 \
        "reason=install-failed rc=${_rc} packages=${_row_pkgs} detail=$(_quoted "${_f3}") rerun=\"$(_rerun install "${_row_name}")\""
}

# --------------------------------------------------------------------------- #
# --mark
# --------------------------------------------------------------------------- #

_do_mark() {
    if [ "${DRY_RUN}" = 1 ]; then
        _plan
        return 0
    fi
    if ! _ask; then
        _skip_all ac-3 no-machine
        return 0
    fi
    _state_tmp=$(mktemp) || return 2
    printf '# follow-probe state schema=1 action=mark manifest=%s columns=%s\n' \
        "${MANIFEST}" "pkg,state,version,config_path,config_sha256,data_path,data_sha256,note" \
        >"${_state_tmp}"
    _each_sample _row_mark
    if ! mv "${_state_tmp}" "${STATE}" 2>/dev/null; then
        printf 'follow-probe: cannot write the baseline to %s\n' "${STATE}" >&2
        rm -f "${_state_tmp}"
        return 2
    fi
    return 0
}

_row_mark() {
    if ! _answer_row "${_row_name}"; then
        _emit "${_row_name}" fail ac-3 "reason=no-answer"
        return 0
    fi
    _rc=${_f2}
    _ver=${_f3}
    _cs=${_f4}
    _ds=${_f5}
    _detail=${_f6}
    if [ "${_rc}" != "0" ]; then
        _emit "${_row_name}" fail ac-3 "reason=mark-failed rc=${_rc} detail=$(_quoted "${_detail}")"
        return 0
    fi
    if [ -z "${_ver}" ]; then
        _emit "${_row_name}" gap ac-3 \
            "reason=install-gap rerun=\"$(_rerun install "${_row_name}")\""
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${_row_name}" gap "" "${_row_cfg}" "" "${_row_dat}" "" \
            "install-gap; rerun: $(_rerun install "${_row_name}")" >>"${_state_tmp}"
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${_row_name}" pass "${_ver}" "${_row_cfg}" "${_cs}" "${_row_dat}" "${_ds}" "${_detail}" \
        >>"${_state_tmp}"
    _emit "${_row_name}" pass ac-3 \
        "version=${_ver} config_sha256=$(_short "${_cs}") data_sha256=$(_short "${_ds}")"
}

# --------------------------------------------------------------------------- #
# --verify
# --------------------------------------------------------------------------- #

_do_verify() {
    if [ "${DRY_RUN}" = 1 ]; then
        _plan
        return 0
    fi
    if [ ! -f "${STATE}" ]; then
        printf 'follow-probe: no baseline at %s: run --mark before the hop\n' "${STATE}" >&2
        return 2
    fi
    if ! _ask; then
        _skip_all ac-2 no-machine
        return 0
    fi
    _each_sample _row_verify
    return 0
}

_row_verify() {
    if ! _baseline_row "${_row_name}"; then
        _emit "${_row_name}" fail ac-3 "reason=no-baseline"
        return 0
    fi
    _bstate=${_f2}
    _bcs=${_f5}
    _bds=${_f7}
    if [ "${_bstate}" = "gap" ]; then
        _emit "${_row_name}" gap ac-3 \
            "reason=install-gap rerun=\"$(_rerun install "${_row_name}")\""
        return 0
    fi
    if ! _answer_row "${_row_name}"; then
        _emit "${_row_name}" fail ac-2 "reason=no-answer"
        return 0
    fi
    _ver=${_f2}
    _cs=${_f3}
    _ds=${_f4}
    _crc=${_f5}
    _cout=${_f6}
    if [ -z "${_ver}" ]; then
        _emit "${_row_name}" fail ac-2 "reason=not-installed"
        return 0
    fi
    if [ "${_crc}" != "0" ]; then
        _emit "${_row_name}" fail ac-2 "reason=check-crashed rc=${_crc} check=$(_quoted "${_cout}")"
        return 0
    fi
    if ! printf '%s\n' "${_cout}" | grep -Eq "${_row_exp}"; then
        _emit "${_row_name}" fail ac-2 \
            "reason=unusable expect=\"${_row_exp}\" check=$(_quoted "${_cout}")"
        return 0
    fi
    if [ "${_cs}" != "${_bcs}" ]; then
        _emit "${_row_name}" fail ac-3 \
            "reason=config-changed config=${_row_cfg} baseline=$(_short "${_bcs}") now=$(_short "${_cs}")"
        return 0
    fi
    if [ "${_ds}" != "${_bds}" ]; then
        _emit "${_row_name}" fail ac-3 \
            "reason=data-lost marker=${_row_dat} baseline=$(_short "${_bds}") now=$(_short "${_ds}")"
        return 0
    fi
    _emit "${_row_name}" pass ac-2 \
        "usable=yes version=${_ver} config=unchanged data=unchanged check=$(_quoted "${_cout}")"
}

# --------------------------------------------------------------------------- #
# --unmark
# --------------------------------------------------------------------------- #

_do_unmark() {
    if [ "${DRY_RUN}" = 1 ]; then
        _plan
        return 0
    fi
    if ! _ask; then
        _skip_all ac-3 no-machine
        return 0
    fi
    _each_sample _row_unmark
    return 0
}

_row_unmark() {
    if ! _answer_row "${_row_name}"; then
        _emit "${_row_name}" fail ac-3 "reason=no-answer"
        return 0
    fi
    _detail=${_f3}
    case "${_detail}" in
        *-failed)
            _emit "${_row_name}" fail ac-3 "reason=unmark-failed detail=$(_quoted "${_detail}")"
            ;;
        *)
            _emit "${_row_name}" pass ac-3 "config=${_row_cfg} restored=${_detail}"
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

_load_manifest || exit 2

case "${ACTION}" in
    install) _do_install ;;
    mark) _do_mark ;;
    verify) _do_verify ;;
    unmark) _do_unmark ;;
esac
_rc=$?

[ "${ROWS}" -gt 0 ] && _summary
[ "${_rc}" -ne 0 ] && exit "${_rc}"
_verdict
exit $?
