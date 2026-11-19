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
#         check-crashed, config-changed, data-lost, no-answer, no-baseline, not-ready) and
#         the facts. not-ready is the one the readiness wait adds: a sample whose daemon
#         did not come up within the manifest's timeout, and the row carries waited=<n>s
#         and daemon=<starting|booting|down> so a slow start is not read as a broken
#         package nor a broken package as a slow start
#   gap   the sample cannot speak about the hop: it could not be installed when --mark ran
#         (reason=install-gap), its setup did not run (reason=setup-failed), or its own
#         criterion was already failing on the baseline image (reason=baseline-unusable).
#         A GAP is never a defect of the A/B machinery: a package the feed does not offer
#         is a finding about the feed (PRD risk 3, istore measured rc=1 in round 03), and a
#         criterion that never matched is a finding about the manifest (round 1: one
#         hard-coded ttyd path read as a regression on five matrix cases)
#   skip  no machine answered, or --dry-run asked for nothing: never a pass
#
# Why a failing criterion is only a regression when it passed before
# -----------------------------------------------------------------
# --mark runs each sample's criterion too and records what it printed in the state file.
# --verify re-matches that recorded output against the same ERE before it decides: a
# criterion that already failed on the image the chain started from says nothing about any
# hop, so it is a GAP that names the sample. Only pass -> fail is a regression. The
# criterion is re-matched and not stored as a verdict, so the manifest stays the single
# place "usable" is defined: a fixture fixed between --mark and --verify is judged by the
# fixed criterion.
#
# Setup: the one place a sample may change the machine's running state
# -------------------------------------------------------------------
# A sample's `setup` (docker's `enable && start`) runs during --install, after apk add
# succeeded and before --mark records the baseline, and the install row carries
# setup=ok|failed|skipped|absent. That is deliberate and it is the only action that does
# it: docker's criterion is `docker info` answering, and a daemon that is only enabled at
# boot comes back on its own after every hop. --mark, --verify and --unmark start nothing,
# because they run while the machine is being measured.
#
# Readiness: a daemon sample is asked until the machine can answer
# ----------------------------------------------------------------
# "It is not up yet" and "it will never come up" are different facts, and a probe that asks
# once cannot tell them apart. The hop's own ssh answers about 10 s after the reboot, but
# this product's first boot hands the package follow to a detached worker and restarts the
# daemons procd gave up on only once that follow has settled: measured 2026-11-19, the
# ring log carries `stage=services-reconciled ... started=1 down=dockerd` at an uptime of
# about 120 s, while the probe asked at about 25 s. docker's criterion therefore printed
# `client=yes daemon=no` on a healthy machine and six matrix cases went red (round 5).
#
# A sample may declare `ready` in the manifest: the process and init script of the daemon
# its criterion needs, the ring-log line the boot writes when it has finished restarting
# those daemons, and a bounded timeout with a poll interval. The criterion is then asked
# again while the machine can still be expected to change its answer, and the row carries
# how long that took and what the machine last said (`waited=<n>s daemon=<state>`):
#
#   ready     the criterion printed what the manifest's ERE requires
#   starting  the daemon runs but does not answer yet; the timeout ran out
#   booting   the daemon is down and the boot has not reconciled services yet; the timeout
#             ran out, so the machine never got as far as starting it
#   down      the daemon is down and nothing is left to start it: reported at once
#
# The wait is bounded on purpose. A criterion that never answers is a FAIL that names the
# seconds it waited, never a pass: treating `daemon=no` as usable would hide exactly the
# defect the sample exists to see, and waiting without a bound would turn a broken package
# into a hung probe. A sample that declares no `ready` is asked once, as before.
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
# --mark runs each sample's criterion and records four facts per sample:
#   config   /etc/config/<name> gains `option ab_marker '<sha>'` under a
#            `config marker 'ab_follow'` section (the sha is derived from the sample name,
#            so a second --mark writes the same bytes - the baseline is idempotent)
#   data     <data_marker> (default /data/ab-follow/<name>.marker) is written on the shared
#            data partition, which is what proves the data half of the machine survived
#   version  the installed apk version, recorded as a fact and NOT asserted later: a package
#            that followed the new base has a new version and is still the same package
#   check    what the sample's criterion printed before the hop, which is what lets --verify
#            tell "this criterion never matched here" from "this hop broke it"
# The baseline (state, version, config sha256, data sha256, check) lands in --state, on the
# operator's machine, because /tmp on the device does not survive the hop it is there to
# measure.
#
# Hygiene on a machine somebody else is using
# -------------------------------------------
# The config marker is appended, never overwritten: the file --mark found is copied once to
# <config><suffix> (.ab-follow-bak) and a file --mark had to create is recorded as an empty
# backup, which is how --unmark knows whether to restore or delete. --unmark restores every
# backup and removes the data markers. Nothing here starts a daemon, reboots or writes
# outside /etc/config/<name>, /data/ab-follow and /tmp - the one exception is a sample's own
# `setup`, which only --install runs and which the install row reports. --unmark does not
# undo it: the enable half is what carries the daemon across the next hop, so stopping it
# would remove the evidence the next --verify is there to read.
#
# Environment: AB_HOST, AB_KEY, AB_FOLLOW_MANIFEST, AB_FOLLOW_STATE, AB_FOLLOW_MARKER_DIR,
#              AB_FOLLOW_BAK_SUFFIX, AB_FOLLOW_INSTALL_TIMEOUT (180 s),
#              AB_FOLLOW_BOOT_LOG (/boot/ab/log/boot-0.log: the ring log the readiness wait
#              reads the boot's own reconcile line from), AB_DRY_RUN.

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
# The boot's ring log, rotated at boot, so boot-0.log is this boot's own record. It is what
# tells the readiness wait whether the machine has already restarted the daemons procd gave
# up on; the path is a device fact like the state path, so it is a seam here and not a
# literal inside the remote script.
BOOT_LOG=${AB_FOLLOW_BOOT_LOG:-/boot/ab/log/boot-0.log}
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
_row_setup=""
_row_ready=""
_ready_proc=""
_ready_init=""
_ready_settle=""
_ready_timeout=""
_ready_interval=""

usage() {
    cat <<'USAGE'
usage: follow-probe.sh --install | --mark | --verify | --unmark
                       [--sample NAME]... [--state FILE] [--manifest FILE] [--dry-run]

  --install   install the samples the manifest names and run the setup of the ones that
              carry one; a sample that cannot be installed is a GAP with the command to
              rerun, never a FAIL
  --mark      write the fake config and the data marker, and record per sample (version,
              config sha256, data sha256, criterion output) in --state
  --verify    read the baseline back and assert, per sample: still usable, config sha256
              unchanged, data marker unchanged; a criterion that already failed on the
              baseline image is reported as a gap, not as a failure
  --unmark    restore the configs and remove the markers --mark left behind
  --sample NAME    repeatable; only this sample
  --state FILE     the baseline TSV (default /tmp/ab-follow-state.tsv)
  --manifest FILE  the sample list (default tests/fixtures/follow-samples.json)
  --dry-run        print the remote script and exit; no ssh call, no row

A sample whose criterion needs a daemon declares `ready` in the manifest (proc, init script,
the boot line that says the daemon was given its start, and a bounded timeout). Its criterion
is then asked until the daemon answers, and the row carries waited=<n>s daemon=<state>; a
sample that declares no `ready` is asked once, as before.

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
#   sample  <name>  <packages>  <config_path>  <data_marker>  <cmd>  <expect>  <needs>  <setup>  <ready>
#
# <ready> is the sample's readiness contract flattened, `proc,init,settle,timeout,interval`,
# or empty for a sample that can be asked once. One column and not five because it is one
# fact - "this criterion needs a daemon and here is how the machine says the daemon is up" -
# and the driver hands it to the remote half whole (see _split_ready).
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
    setup = (sample.get("setup") or "").strip()
    if not cmd:
        sys.exit("follow-probe: %s: sample %s has no check command" % (path, name))
    for value in (name, cmd, expect, setup):
        if "\n" in value or "\t" in value:
            sys.exit("follow-probe: %s: sample %s: a manifest string carries a newline or a tab"
                     % (path, name))
    # A sample may leave the two paths out; the defaults are the ones the task's design
    # names, so a ninth sample does not have to repeat them.
    config_path = sample.get("config_path") or "/etc/config/%s" % name
    data_marker = sample.get("data_marker") or "%s/%s.marker" % (marker_dir, name)
    # The readiness contract is checked here and not in the driver: a half-declared one
    # ("wait for a daemon" with no bound, or with a timeout that is not a number) would
    # otherwise reach the machine as a loop that cannot end, and the failure would land on
    # a device run instead of on the fixture edit that caused it.
    ready = sample.get("ready")
    ready_spec = ""
    if ready is not None:
        if not isinstance(ready, dict):
            sys.exit("follow-probe: %s: sample %s: ready is not an object" % (path, name))
        ready_proc = (ready.get("proc") or "").strip()
        ready_init = (ready.get("init") or "").strip()
        ready_settle = (ready.get("settle") or "").strip()
        if not ready_proc or not ready_init:
            sys.exit("follow-probe: %s: sample %s: ready names no proc or no init script"
                     % (path, name))
        ready_fields = []
        for key, value in (("timeout", ready.get("timeout")),
                           ("interval", ready.get("interval", 5))):
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                sys.exit("follow-probe: %s: sample %s: ready.%s is not a positive whole number"
                         % (path, name, key))
            ready_fields.append(value)
        for value in (ready_proc, ready_init, ready_settle):
            if "\n" in value or "\t" in value or "," in value:
                sys.exit("follow-probe: %s: sample %s: ready carries a comma, newline or tab"
                         % (path, name))
        ready_spec = ",".join([ready_proc, ready_init, ready_settle] +
                              [str(v) for v in ready_fields])
    fields = [
        "sample",
        name,
        " ".join(sample.get("packages") or []),
        config_path,
        data_marker,
        cmd,
        expect,
        ",".join(sample.get("needs") or []),
        setup,
        ready_spec,
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
        _row_setup=${_f9}
        _row_ready=${_f10}
        _split_ready "${_row_ready}"
        _want "${_row_name}" || continue
        "${1}"
    done <"${_records}"
}

# _split_ready <spec>: the sample's readiness contract into the _ready_* variables.
#
# The manifest is validated when it is read (see _manifest_dump), so this only splits: an
# empty spec is a sample that declares no daemon, and every _ready_* stays empty, which is
# what makes the remote half ask the criterion exactly once.
_split_ready() {
    _ready_proc=""
    _ready_init=""
    _ready_settle=""
    _ready_timeout=""
    _ready_interval=""
    [ -n "${1}" ] || return 0
    _ready_proc=$(printf '%s' "${1}" | cut -d, -f1)
    _ready_init=$(printf '%s' "${1}" | cut -d, -f2)
    _ready_settle=$(printf '%s' "${1}" | cut -d, -f3)
    _ready_timeout=$(printf '%s' "${1}" | cut -d, -f4)
    _ready_interval=$(printf '%s' "${1}" | cut -d, -f5)
    return 0
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
# Where the base keeps the binary an init script runs: the script's own PROG first, then
# whatever PATH resolves. Not a fixed directory: on this image ttyd lives in /usr/bin and
# the criterion that looked in /usr/sbin failed a healthy machine for five matrix cases
# (measured 2026-11-19). The caller prints the path, so a base that moves the binary is
# visible in the row instead of collapsing into a yes/no.
_bin() {
    _bd=""
    if [ -x "$1" ]; then
        _bd=$(sed -n 's/^PROG=//p' "$1" 2>/dev/null | head -1 | awk '{print $1}' | tr -d "\"'")
    fi
    if [ -n "$_bd" ] && [ -x "$_bd" ]; then printf '%s' "$_bd"; return 0; fi
    command -v "$2" 2>/dev/null || true
    return 0
}
# _ready_settled <marker>: has this boot finished restarting the daemons procd gave up on?
#
# The answer is the boot's own ring log: this product's ab-boot hands the first boot's
# package follow to a detached worker, and that worker appends one line per stage, the last
# of which is the service reconciliation (`stage=services-reconciled`, measured 2026-11-19
# with started=1 down=dockerd). Until that line is there a daemon that is down is not yet a
# failed one - the boot itself may still start it. The log is rotated at boot, so boot-0.log
# is this boot's record and no earlier boot's line can answer for it. An empty marker means
# the sample declares no such gate, and a machine whose boot never writes the line is bounded
# by the wait's timeout, which the row then reports.
_ready_settled() {
    [ -n "$1" ] || return 0
    # The marker is an extended regex, not a literal: a boot that reconciles writes
    # `result=ok` (or `result=partial` when a service refused), and a boot that could not
    # reconcile writes `result=skipped reason=follow-unsettled` in the very same line shape.
    # Counting the skip as "settled" is what turned a follow still waiting for a network into
    # "the daemon is dead": the window it was waiting out had not closed, and the reconcile it
    # was waiting for had explicitly not run.
    grep -qE "$1" "$BOOT_LOG" 2>/dev/null
}
# _ready_wait <fn> <expect> <proc> <init> <settle> <timeout> <interval>: ask a sample's
# criterion until it answers, or until the machine says it never will.
#
# It leaves the evidence in _rw_rc (the criterion's exit status on the last attempt),
# _rw_out (its output), _rw_secs (how long the wait took) and _rw_state (what the machine
# said when the wait ended):
#
#   ready     the criterion printed what the manifest's ERE requires
#   starting  the daemon runs but does not answer yet; the timeout ran out
#   booting   the daemon is down and the boot has not reconciled services yet; the timeout
#             ran out, so the machine never got as far as starting it
#   down      the daemon is down and nothing is left to start it: answered at once, because
#             waiting for a package that is not coming back would hide the failure
#   none      the sample declares no daemon: one attempt, and the criterion decides
#
# Why a loop at all: a hop lands on a machine that has only just booted, and the daemon a
# criterion needs can be absent for the first two minutes of that boot while the follow
# worker is still moving packages (measured: the hop's ssh answers at an uptime of about
# 10 s, the reconcile line lands at about 120 s, and the probe used to ask at about 25 s).
# Asking once therefore measured the clock instead of the package, and six matrix cases went
# red for it in round 5.
_ready_wait() {
    _rw_fn=$1
    _rw_exp=$2
    _rw_proc=$3
    _rw_init=$4
    _rw_settle=$5
    _rw_to=$6
    _rw_iv=$7
    case "$_rw_to" in '' | *[!0-9]*) _rw_to=0 ;; esac
    case "$_rw_iv" in '' | *[!0-9]*) _rw_iv=5 ;; esac
    _rw_rc=0
    _rw_out=""
    _rw_secs=0
    _rw_state=none
    while :; do
        _rw_rc=0
        _rw_out=$( { "$_rw_fn"; } 2>&1 ) || _rw_rc=$?
        if [ "$_rw_rc" = 0 ] && printf '%s\n' "$_rw_out" | grep -Eq "$_rw_exp"; then
            _rw_state=ready
            return 0
        fi
        # Nothing is coming for a sample that declares no daemon, so its one answer is the
        # verdict the probe has always given.
        [ -n "$_rw_proc" ] || return "$_rw_rc"
        case "$(_svc "$_rw_init" "$_rw_proc")" in
            running)
                _rw_state=starting
                ;;
            expected-not-running)
                # Enabled at boot with no process: procd gave up on it. That is either a
                # broken package (report now) or a boot that has not reconciled services yet
                # (wait), and the ring log is what tells the two apart.
                if _ready_settled "$_rw_settle"; then
                    _rw_state=down
                else
                    _rw_state=booting
                fi
                ;;
            *)
                _rw_state=down
                ;;
        esac
        [ "$_rw_state" = down ] && return "$_rw_rc"
        [ "$_rw_secs" -lt "$_rw_to" ] || return "$_rw_rc"
        sleep "$_rw_iv"
        _rw_secs=$((_rw_secs + _rw_iv))
    done
}
REMOTE
}

_inst_helpers() {
    printf 'SFX=%s\n' "$(_sq "${BAK_SUFFIX}")"
}

# The ring log the readiness wait reads the boot's own reconcile line from. Emitted as a
# variable and not as a literal inside the remote preamble, so the path stays the one fact
# this driver was pointed at (AB_FOLLOW_BOOT_LOG) and a test can point it at a file.
_boot_log_helper() {
    printf 'BOOT_LOG=%s\n' "$(_sq "${BOOT_LOG}")"
}

# One sample's install: apk add, then the sample's setup when it declares one, and the
# status of each. Five fields: name, apk rc, apk output, setup rc, setup output. The setup
# status is a word rather than a number when there was nothing to run, so a row can tell
# "this sample has no setup" from "the setup did not run".
_remote_install_block() {
    [ -n "${_row_pkgs}" ] || return 0
    printf ': >/tmp/ab-follow-setup.$$\n'
    printf '_to apk add %s >/tmp/ab-follow-inst.$$ 2>&1\n' "${_row_pkgs}"
    printf '_rc=$?\n'
    if [ -n "${_row_setup}" ]; then
        # Only after the packages are on the machine: a setup that ran against a half
        # installed package would report the install's failure as the daemon's.
        printf '_srt=skipped\n'
        printf 'if [ "$_rc" = 0 ]; then\n'
        printf '    _to sh -c %s >/tmp/ab-follow-setup.$$ 2>&1\n' "$(_sq "${_row_setup}")"
        printf '    _srt=$?\n'
        printf 'fi\n'
    else
        printf '_srt=absent\n'
    fi
    printf 'printf "%%s\\t%%s\\t%%s\\t%%s\\t%%s\\n" %s "$_rc" \\\n' "$(_sq "${_row_name}")"
    printf '    "$(tr "\\n" " " </tmp/ab-follow-inst.$$ | cut -c1-240)" "$_srt" \\\n'
    printf '    "$(tr "\\n" " " </tmp/ab-follow-setup.$$ | cut -c1-200)"\n'
    printf 'rm -f /tmp/ab-follow-inst.$$ /tmp/ab-follow-setup.$$\n'
}

# _remote_criterion_block <prefix>: one sample's criterion, asked the way the manifest says
# it has to be asked, and the facts that make the answer auditable.
#
# The criterion becomes a shell function so the readiness wait can ask it more than once
# without the driver pasting it twice; the wait itself is _ready_wait in the preamble, so
# what a dry run prints is the loop the machine will actually run. <prefix> is the fact
# prefix - m while --mark records a baseline, p while --verify judges a hop, so the facts
# are _mcr/_mco/_mwait/_mst and _pcr/_pco/_pwait/_pst - and the facts it leaves are
#   <p>cr    the criterion's exit status on the last attempt
#   <p>co    its output, newlines flattened and capped
#   <p>wait  the seconds spent waiting for the sample to become ready
#   <p>st    what the machine said when the wait ended (ready|starting|booting|down|none)
#
# A sample that declares no readiness contract passes empty values and is asked exactly
# once: _ready_wait answers "none" without waiting, so the row for it reads as it always did.
_remote_criterion_block() {
    _cfx=$1
    printf '_%s_fn() {\n' "${_cfx}"
    printf '    %s\n' "${_row_cmd}"
    printf '}\n'
    printf '_ready_wait _%s_fn %s %s %s %s %s %s\n' "${_cfx}" \
        "$(_sq "${_row_exp}")" "$(_sq "${_ready_proc}")" "$(_sq "${_ready_init}")" \
        "$(_sq "${_ready_settle}")" "${_ready_timeout:-0}" "${_ready_interval:-5}"
    printf '_%scr=$_rw_rc\n' "${_cfx}"
    printf '_%swait=$_rw_secs\n' "${_cfx}"
    printf '_%sst=$_rw_state\n' "${_cfx}"
    printf '_%sco=$(printf "%%s" "$_rw_out" | tr "\\n\\t" "  " | cut -c1-240)\n' "${_cfx}"
}

# One sample's mark: the criterion as the machine answers it now, the fake config, the data
# marker, and the baseline facts.
#
# The criterion runs first and before anything is written, so what is recorded is the
# machine as the hop is about to find it. Its output is what --verify compares against: a
# criterion that already failed here cannot be evidence about any hop. It is asked through
# the readiness wait as well, because --mark runs straight after a setup that may have just
# started a daemon: a baseline recorded while the daemon is still coming up would say the
# sample was broken before the hop and turn every later verdict about it into a GAP.
_remote_mark_block() {
    printf 'name=%s\n' "$(_sq "${_row_name}")"
    printf 'cfg=%s\n' "$(_sq "${_row_cfg}")"
    printf 'dat=%s\n' "$(_sq "${_row_dat}")"
    printf 'pkg0=%s\n' "$(_sq "${_row_pkgs%% *}")"
    # The criterion is asked only of a sample that is on the machine: the answer for a
    # package the feed does not offer is not a fact about the criterion.
    printf 'v=$(_ver "$pkg0")\n'
    printf '_mcr=0\n'
    printf '_mco=""\n'
    printf '_mwait=0\n'
    printf '_mst=none\n'
    printf 'if [ -n "$v" ]; then\n'
    _remote_criterion_block m
    printf 'fi\n'
    cat <<'REMOTE'
ms=$(printf 'ab-follow:%s:v1' "$name" | sha256sum | awk '{print $1}')
if [ -z "$v" ] || [ -z "$cfg" ] || [ -z "$dat" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" 0 "" "" "" not-installed \
        "$_mcr" "$_mco" "$_mwait" "$_mst"
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$_rc" "$v" "$(_sha "$cfg")" \
        "$(_sha "$dat")" "$_d" "$_mcr" "$_mco" "$_mwait" "$_mst"
fi
REMOTE
}

# One sample's verify: the installed version, both sha256 values, and the sample's own
# criterion (verbatim from the manifest) with its exit status, its output, and the evidence
# of how long the machine was given to become able to answer it.
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
    _remote_criterion_block p
    printf 'printf "%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\t%%s\\n" "$name" "$_pv" "$_pcs" "$_pds" "$_pcr" "$_pco" "$_pwait" "$_pst"\n'
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
            _boot_log_helper
            _remote_preamble
            _each_sample "_remote_${1}_block"
            ;;
        verify)
            printf 'set -u\n'
            _boot_log_helper
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
    # The remote half goes over stdin, not as an argv: dropbear closes the connection for a
    # command line past its limit, and the eight-sample mark script is past it (measured
    # 2026-11-18: rc=255 with no output, which the old code reported as "no machine").
    _answer=$(dev_ssh 'sh -s' <"${_tmpfile}")
    _answer_rc=$?
    rm -f "${_tmpfile}"
    _tmpfile=""
    if [ "${_answer_rc}" -ne 0 ] || [ -z "${_answer}" ]; then
        # Not "no machine": a remote script that ran and failed looks nothing like a machine
        # that did not answer, and calling both "no-machine" hides the reason (measured
        # 2026-11-18: the mark script failed on a live machine and every row said no-machine).
        printf 'follow-probe: remote %s failed rc=%s out=%s\n' \
            "${ACTION}" "${_answer_rc}" "${_answer:-<empty>}" >&2
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

# One line per sample in a dry run: what would be installed, what would be set up, what the
# criterion needs (network, service, http, kernel), and the readiness contract a daemon
# sample is judged against - so a reader can see the prerequisites, the one command that
# changes the machine, and how long the probe will wait for a daemon, before a run touches
# it.
_plan_row() {
    _plan_ready=""
    if [ -n "${_row_ready}" ]; then
        _plan_ready=$(printf ' ready="proc=%s init=%s settle=%s timeout=%ss interval=%ss"' \
            "${_ready_proc}" "${_ready_init}" "${_ready_settle:--}" \
            "${_ready_timeout}" "${_ready_interval}")
    fi
    if [ -n "${_row_setup}" ]; then
        printf 'follow-probe dry-run: sample=%s packages="%s" needs=%s setup="%s"%s\n' \
            "${_row_name}" "${_row_pkgs}" "${_row_needs:--}" "${_row_setup}" "${_plan_ready}"
    else
        printf 'follow-probe dry-run: sample=%s packages="%s" needs=%s%s\n' \
            "${_row_name}" "${_row_pkgs}" "${_row_needs:--}" "${_plan_ready}"
    fi
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

_split_row() { # <line>: _f1 .. _f10, empty fields included
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
    _pop_field
    _f9=${_pop}
    _pop_field
    _f10=${_pop}
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

# _wait_facts <waited> <state>: the readiness evidence a row carries, or nothing at all.
#
# It prints nothing for a sample that declares no readiness contract (its row keeps the
# shape it always had) and nothing for a remote half that predates the two columns, so a
# baseline or a machine running an older driver still produces rows a reader can compare.
# The leading space is deliberate: callers append it to the fact list they already built.
_wait_facts() {
    [ -n "${_row_ready}" ] || return 0
    case "${1}" in
        '' | *[!0-9]*) return 0 ;;
    esac
    printf ' waited=%ss daemon=%s' "${1}" "${2:-unknown}"
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
    _detail=${_f3}
    _srt=${_f4}
    _sdetail=${_f5}
    # A three-field answer comes from a remote half that predates setup, and a sample with
    # no setup reports "absent" itself: neither is a failed step.
    case "${_srt}" in
        "") _srt=absent ;;
    esac
    if [ "${_rc}" != "0" ]; then
        _emit "${_row_name}" gap ac-2 \
            "reason=install-failed rc=${_rc} packages=${_row_pkgs} detail=$(_quoted "${_detail}") setup=skipped rerun=\"$(_rerun install "${_row_name}")\""
        return 0
    fi
    if [ "${_srt}" != "0" ] && [ "${_srt}" != "absent" ]; then
        # The sample is installed but its own setup did not run, so its criterion would
        # measure a daemon that was never started. Reporting that as a pass would be a
        # green row about nothing, and as a failure would blame the hop for the baseline.
        _emit "${_row_name}" gap ac-2 \
            "reason=setup-failed rc=${_srt} packages=${_row_pkgs} setup=$(_quoted "${_sdetail}") rerun=\"$(_rerun install "${_row_name}")\""
        return 0
    fi
    if [ "${_srt}" = "absent" ]; then
        _emit "${_row_name}" pass ac-2 "packages=${_row_pkgs} setup=absent"
    else
        _emit "${_row_name}" pass ac-2 "packages=${_row_pkgs} setup=ok"
    fi
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
    printf '# follow-probe state schema=2 action=mark manifest=%s columns=%s\n' \
        "${MANIFEST}" "pkg,state,version,config_path,config_sha256,data_path,data_sha256,note,check" \
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
    _bcheck=${_f8}
    _mwait=${_f9}
    _mst=${_f10}
    _waitf=$(_wait_facts "${_mwait}" "${_mst}")
    if [ "${_rc}" != "0" ]; then
        _emit "${_row_name}" fail ac-3 "reason=mark-failed rc=${_rc} detail=$(_quoted "${_detail}")"
        return 0
    fi
    if [ -z "${_ver}" ]; then
        _emit "${_row_name}" gap ac-3 \
            "reason=install-gap rerun=\"$(_rerun install "${_row_name}")\""
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${_row_name}" gap "" "${_row_cfg}" "" "${_row_dat}" "" \
            "install-gap; rerun: $(_rerun install "${_row_name}")" "" >>"${_state_tmp}"
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${_row_name}" pass "${_ver}" "${_row_cfg}" "${_cs}" "${_row_dat}" "${_ds}" "${_detail}" \
        "${_bcheck}" >>"${_state_tmp}"
    # The baseline row reports whether the criterion held before the hop, because that is
    # the difference between "this sample works here" and "this criterion never matched
    # here". The second is not a failure of --mark: the samples still have to be carried.
    _baseline_matched
    case "$?" in
        0)
            _emit "${_row_name}" pass ac-3 \
                "usable=yes version=${_ver} config_sha256=$(_short "${_cs}") data_sha256=$(_short "${_ds}")${_waitf}"
            ;;
        1)
            _emit "${_row_name}" pass ac-3 \
                "usable=no version=${_ver} config_sha256=$(_short "${_cs}") data_sha256=$(_short "${_ds}") check=$(_quoted "${_bcheck}")${_waitf}"
            ;;
        *)
            # The remote half answered without the criterion's output, which is the shape of
            # a manifest or a driver that predates this column. Saying "usable=no" here
            # would blame the sample for the answer nobody collected.
            _emit "${_row_name}" pass ac-3 \
                "usable=unknown version=${_ver} config_sha256=$(_short "${_cs}") data_sha256=$(_short "${_ds}")${_waitf}"
            ;;
    esac
}

# _baseline_matched: 0 when the criterion output the baseline recorded satisfies the ERE
# --verify applies, 1 when it does not, 2 when the baseline predates this column.
# The recorded output is re-matched rather than stored as a verdict, so the manifest stays
# the single place "usable" is defined: a criterion fixed between --mark and --verify is
# judged by the fixed one, and a baseline written by an older driver is still readable.
_baseline_matched() {
    [ -n "${_bcheck}" ] || return 2
    printf '%s\n' "${_bcheck}" | grep -Eq "${_row_exp}"
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
    _bcheck=${_f9}
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
    _pwait=${_f7}
    _pst=${_f8}
    _waitf=$(_wait_facts "${_pwait}" "${_pst}")
    if [ -z "${_ver}" ]; then
        _emit "${_row_name}" fail ac-2 "reason=not-installed"
        return 0
    fi
    # Both survival checks come before the criterion's own verdict. They are hop-caused by
    # construction - the two values were hashed on this machine at --mark - so they are
    # reported as failures even for a sample whose criterion never matched: a broken
    # criterion must not be able to hide a config or a data marker this hop destroyed.
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
    # The criterion's own verdict, in one place: 0 when the sample's own ERE matched.
    _usable=yes
    [ "${_crc}" = "0" ] || _usable=no
    if [ "${_usable}" = "yes" ] && ! printf '%s\n' "${_cout}" | grep -Eq "${_row_exp}"; then
        _usable=no
    fi
    if [ "${_usable}" = "no" ]; then
        # The readiness wait separates "the machine never got the daemon up" from "the
        # criterion answered and the answer was wrong". Both are failures - the row never
        # turns them into a pass - but a reader has to be able to tell a daemon that was
        # still starting when the budget ran out from a package that is broken.
        case "${_pst}" in
            starting | booting)
                _why="reason=not-ready expect=\"${_row_exp}\""
                ;;
            *)
                if [ "${_crc}" = "0" ]; then
                    _why="reason=unusable expect=\"${_row_exp}\""
                else
                    _why="reason=check-crashed rc=${_crc}"
                fi
                ;;
        esac
        _baseline_matched
        case "$?" in
            0)
                _emit "${_row_name}" fail ac-2 "${_why} check=$(_quoted "${_cout}")${_waitf}"
                ;;
            1)
                # The criterion was already failing on the baseline image: this hop is not
                # what broke it, and letting it read as a failure is what turned one wrong
                # path into five red matrix cases (round 1). The row names the sample and
                # carries both answers so a reader can see it is the same defect.
                _emit "${_row_name}" gap ac-2 \
                    "reason=baseline-unusable baseline_check=$(_quoted "${_bcheck}") check=$(_quoted "${_cout}")${_waitf}"
                ;;
            *)
                # A baseline written before the criterion output was recorded: the row
                # cannot tell the two classes apart, so it stays a failure and says why.
                _emit "${_row_name}" fail ac-2 "${_why} baseline=unrecorded check=$(_quoted "${_cout}")${_waitf}"
                ;;
        esac
        return 0
    fi
    _emit "${_row_name}" pass ac-2 \
        "usable=yes version=${_ver} config=unchanged data=unchanged check=$(_quoted "${_cout}")${_waitf}"
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
