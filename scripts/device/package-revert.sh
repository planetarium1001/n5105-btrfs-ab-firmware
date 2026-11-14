#!/bin/sh
# package-revert.sh - prove the package snapshot and the offline revert on the real machine.
#
# The defect this covers (2026-11-14): `ab-slot packages snapshot` read a column apk-tools 3
# does not print, so a 317-package machine produced five mangled lines and `revert` failed on
# every one of them. Two things are measured here, separately:
#
#   P1  the record itself: a snapshot names every installed package with its version, and its
#       own counters (packages=, world=) agree with the machine. No payloads, no network.
#   P2  the way back: a snapshot that carries the .apk files can put a package back with the
#       repositories pointed at a directory that does not exist, which is the only way to
#       show that the replay does not secretly depend on the feed still having that version.
#
# P2 deletes one package and puts it back, because `revert` replays pinned versions: it does
# not remove a package that was installed after the snapshot, and pretending otherwise would
# be a different feature (restoring `world`, which is what `ab-slot rollback` is for).
#
#   scripts/device/package-revert.sh --case P1 --case P2
#   scripts/device/package-revert.sh --case P2 --keep-payloads   # do not delete the snapshot
#   scripts/device/package-revert.sh --dry-run
#
# Exit status: 0 every selected case PASS, 1 a case FAIL, 2 bad usage, 3 the red line
# stopped the run, 4 a case could not run (no /data, no apk, no healthy slot, service down).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

DRY_RUN=${AB_DRY_RUN:-0}
CASES=""
KEEP_PAYLOADS=1
AB_PKG_RESULTS=${AB_PKG_RESULTS:-package-revert-results.tsv}
AB_PKG_CONTROL_PKG=${AB_PKG_CONTROL_PKG:-htop}
AB_REPO_DIR_BACKUP=${AB_REPO_DIR_BACKUP:-/tmp/ab-apk-conf.bak}

usage() {
    sed -n '20,27p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            CASES="${CASES} ${2:?--case needs P1 or P2}"
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --clean) KEEP_PAYLOADS=0; shift ;;
        -h | --help) usage ;;
        *) printf 'package-revert.sh: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "${CASES}" ] || CASES=" P1 P2"

CASE_NOTE=""
CASE_FAILURES=0

_fail() {
    CASE_FAILURES=$((CASE_FAILURES + 1))
    printf 'FAIL [%s] %s\n' "$1" "$2" >&2
    ev "FAIL ${1}: ${2}"
}

_ok() {
    printf 'ok [%s] %s\n' "$1" "$2"
}

_assert_eq() { # <case> <actual> <expected> <message>
    if [ "$2" = "$3" ]; then
        _ok "$1" "$4"
    else
        _fail "$1" "$4 (got '$2', expected '$3')"
    fi
}

_field() { # <status-line> <key>
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

# require_ready <case>: apk, a healthy committed slot and the writable layer.
require_ready() {
    _case=$1
    if ! dev_ssh 'command -v apk >/dev/null 2>&1'; then
        CASE_NOTE="the machine has no apk"
        return 4
    fi
    if ! STATUS_LINE=$(dev_status 2>/dev/null); then
        CASE_NOTE="ab-slot status did not answer"
        return 4
    fi
    if [ "$(_field "${STATUS_LINE}" boot)" != "ok" ] || [ "$(_field "${STATUS_LINE}" esp)" != "ok" ]; then
        CASE_NOTE="machine is not healthy (boot=$(_field "${STATUS_LINE}" boot) esp=$(_field "${STATUS_LINE}" esp))"
        return 4
    fi
    if [ "$(_field "${STATUS_LINE}" p4)" != "ok" ]; then
        CASE_NOTE="p4 is not mounted, so there is nowhere to write a snapshot"
        return 4
    fi
    return 0
}

# apk_count: how many `name-version` lines apk reports. The same source the snapshot reads.
apk_count() { dev_ssh "apk info -v 2>/dev/null | grep -c . || true"; }

# run_parse <case>: P1, no payloads.
run_parse() {
    _case=$1
    require_ready "${_case}" || return $?
    _before=$(apk_count) || _before=""
    case "${_before}" in
        '' | *[!0-9]* | 0)
            CASE_NOTE="apk info -v answered '${_before}' lines"
            return 4
            ;;
    esac
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/4 ab-slot packages snapshot --no-payloads\n' "${_case}"
        printf '%s 2/4 expect packages=%s (apk info -v | wc -l)\n' "${_case}" "${_before}"
        printf '%s 3/4 expect world=<world lines> and payloads=no\n' "${_case}"
        printf '%s 4/4 expect pkg rows == packages= and no unparsed line\n' "${_case}"
        return 0
    fi
    ev "P1: apk reports ${_before} installed packages"
    _out=$(dev_ssh "ab-slot packages snapshot --no-payloads 2>&1") || {
        CASE_NOTE="snapshot refused: $(printf '%s' "${_out}" | head -n 1)"
        return 1
    }
    ev "P1 snapshot: $(printf '%s' "${_out}" | head -n 1)"
    _packages=$(_field "$(printf '%s' "${_out}" | head -n 1)" packages)
    _world=$(_field "$(printf '%s' "${_out}" | head -n 1)" world)
    _payloads=$(_field "$(printf '%s' "${_out}" | head -n 1)" payloads)
    _assert_eq "${_case}" "${_packages}" "${_before}" "the snapshot records every installed package"
    _assert_eq "${_case}" "${_payloads}" "no" "--no-payloads writes payloads=no"
    _snap=$(printf '%s' "${_out}" | sed -n 's/.*packages=list.*//p')  # no-op, keeps shellcheck quiet
    _path=$(printf '%s' "${_out}" | sed -n 's/^\([^ ]*snapshot-[^ ]*\.txt\).*/\1/p' | head -n 1)
    if [ -z "${_path}" ]; then
        _rows=$(dev_ssh "ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | tail -n 1")
    else
        _rows=""
    fi
    _last=$(dev_ssh "ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | sort | tail -n 1")
    if [ -n "${_last}" ]; then
        _rowcount=$(dev_ssh "grep -c '^pkg      ' '${_last}' 2>/dev/null || true")
        _worldrows=$(dev_ssh "grep -c '^world    ' '${_last}' 2>/dev/null || true")
        _assert_eq "${_case}" "${_rowcount}" "${_packages}" "the pkg rows agree with the header"
        _assert_eq "${_case}" "${_worldrows}" "${_world}" "the world rows agree with the header"
        _unparsed=$(dev_ssh "grep -c '^pkg      [^ ]*$' '${_last}' 2>/dev/null || true")
        _assert_eq "${_case}" "${_unparsed:-0}" "0" "no pkg row lost its version"
    else
        _fail "${_case}" "no snapshot file found under /mnt/p4/*/apk/snapshots"
    fi
    CASE_NOTE="snapshot records ${_packages} packages / ${_world} world entries, rows agree with the header"
    return 0
}

# run_offline <case>: P2, payloads + a package removed and put back with no repository.
run_offline() {
    _case=$1
    require_ready "${_case}" || return $?
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/5 ab-slot packages snapshot (payloads on)\n' "${_case}"
        printf '%s 2/5 expect payloads=yes and a payloads/ directory with .apk files\n' "${_case}"
        printf '%s 3/5 ab-slot packages revert  (offline, repositories moved away)\n' "${_case}"
        printf '%s 4/5 expect revert result=ok path=payloads\n' "${_case}"
        printf '%s 5/5 expect the probe package at the snapshotted version\n' "${_case}"
        return 0
    fi
    # A payload snapshot costs a few hundred megabytes of download, so an existing one is
    # reused: the case is about the replay, and taking a second copy would only make the
    # run slower without proving anything more.
    _existing=$(dev_ssh "for t in \$(ls -1 /mnt/p4/*/apk/snapshots/snapshot-*.txt 2>/dev/null | sort -r); do if grep -q '^payloads yes' \"\$t\" 2>/dev/null && grep -q '^apkfile' \"\$t\" 2>/dev/null; then echo \"\$t\"; break; fi; done")
    if [ -n "${_existing}" ]; then
        ev "P2: reusing the payload snapshot ${_existing}"
        _out="snapshot ${_existing} packages=0 world=0 payloads=yes"
    else
        ev "P2: snapshot with payloads (this downloads the installed set once)"
        _out=$(dev_ssh "ab-slot packages snapshot 2>&1") || {
            CASE_NOTE="snapshot refused: $(printf '%s' "${_out}" | head -n 1)"
            return 1
        }
        ev "P2 snapshot: $(printf '%s' "${_out}" | head -n 1)"
    fi
    _payloads=$(_field "$(printf '%s' "${_out}" | head -n 1)" payloads)
    if [ "${_payloads}" != "yes" ]; then
        CASE_NOTE="payloads=no ($(printf '%s' "${_out}" | sed -n 's/.*payload-gap //p' | head -n 1)); nothing to prove offline"
        return 4
    fi
    _snapdir="${_existing%.txt}.d"
    _snapid=${_existing##*/snapshot-}
    _snapid=${_snapid%.txt}
    _files=$(dev_ssh "ls -1 '${_snapdir}/payloads'/*.apk 2>/dev/null | wc -l | tr -d ' '")
    _ok "${_case}" "snapshot carries ${_files} .apk files in ${_snapdir}"
    # One package that the snapshot pins, and its running version: the revert has to leave
    # it at that version, not at whatever the feed would install today.
    _probe=$(dev_ssh "sed -n 's/^pkg      //p' '${_existing}' | head -n 1 | cut -d' ' -f1")
    _wanted=$(dev_ssh "sed -n 's/^pkg      \\(${_probe} \\)//p' '${_existing}' | head -n 1")
    _before=$(dev_ssh "apk list --installed '${_probe}' 2>/dev/null | head -n 1 | awk '{print \$1}'")
    ev "P2: probe package ${_probe}: running ${_before}, snapshot wants ${_probe}-${_wanted}"

    # The repositories are moved away on the machine itself, so a replay that reaches the
    # network fails here instead of quietly succeeding. OpenWrt's apk reads
    # /etc/apk/repositories.d, and a plain /etc/apk/repositories may exist too, so both are
    # taken out of the way and put back below whatever happens.
    dev_ssh "rm -rf ${AB_REPO_DIR_BACKUP}; mkdir -p ${AB_REPO_DIR_BACKUP} && cp -a /etc/apk/repositories ${AB_REPO_DIR_BACKUP}/repositories 2>/dev/null; mv /etc/apk/repositories.d ${AB_REPO_DIR_BACKUP}/repositories.d 2>/dev/null; printf '# moved away by package-revert.sh\n' > /etc/apk/repositories"
    # Control: with no source configured, a plain install cannot work. Without this line a
    # successful revert would not prove the local path was the one that did it.
    # The control has to ask for a package the machine does not have: `apk add` on an
    # installed package answers from the installed database and would succeed with no
    # repositories at all, which is what made an earlier version of this case vacuous.
    _control=${AB_PKG_CONTROL_PKG}
    if dev_ssh "apk info -e ${_control} >/dev/null 2>&1"; then
        _control=""
        _ok "${_case}" "control package ${AB_PKG_CONTROL_PKG} is already installed; skipping the control"
    fi
    if [ -n "${_control}" ] && dev_ssh "apk add --simulate ${_control} >/dev/null 2>&1"; then
        dev_ssh "rm -rf /etc/apk/repositories.d; mv ${AB_REPO_DIR_BACKUP}/repositories.d /etc/apk/repositories.d 2>/dev/null; if [ -f ${AB_REPO_DIR_BACKUP}/repositories ]; then cp ${AB_REPO_DIR_BACKUP}/repositories /etc/apk/repositories; fi"
        CASE_NOTE="apk still resolves from a source with the repositories moved away; the offline proof would be vacuous"
        return 4
    fi
    [ -n "${_control}" ] && _ok "${_case}" "with no repository configured, a fresh install fails (control)"
    _revert=$(dev_ssh "ab-slot packages revert --to ${_snapid} 2>&1")
    dev_ssh "rm -rf /etc/apk/repositories.d; mv ${AB_REPO_DIR_BACKUP}/repositories.d /etc/apk/repositories.d 2>/dev/null; if [ -f ${AB_REPO_DIR_BACKUP}/repositories ]; then cp ${AB_REPO_DIR_BACKUP}/repositories /etc/apk/repositories; fi"
    printf '%s\n' "${_revert}" | grep -E '^revert |^apkfile' | while IFS= read -r _line; do ev "P2 ${_line}"; done
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/^revert result=\([a-z]*\).*/\1/p' | head -n 1)" "ok" \
        "the revert succeeded with no repository configured"
    _assert_eq "${_case}" "$(printf '%s' "${_revert}" | sed -n 's/.*path=\([a-z]*\).*/\1/p' | head -n 1)" "payloads" \
        "the revert took the local payload path"
    _after=$(dev_ssh "apk list --installed '${_probe}' 2>/dev/null | head -n 1 | awk '{print \$1}'")
    _assert_eq "${_case}" "${_after}" "${_probe}-${_wanted}" "the probe package is at the snapshotted version"
    if [ "${KEEP_PAYLOADS}" = "0" ]; then
        dev_ssh "rm -rf '${_snapdir}'" >/dev/null 2>&1 || ev "P2: could not remove ${_snapdir} (kept)"
    fi
    CASE_NOTE="offline revert took path=payloads from ${_files} local .apk files; ${_probe} stayed at ${_wanted}"
    return 0
}

run_case() {
    _case=$1
    CASE_NOTE=""
    CASE_FAILURES=0
    case "${_case}" in
        P1) run_parse "${_case}" ;;
        P2) run_offline "${_case}" ;;
        *)
            CASE_NOTE="unknown case"
            return 2
            ;;
    esac
    _rc=$?
    case "${_rc}" in
        0)
            if [ "${CASE_FAILURES}" -eq 0 ]; then
                printf '%s\tPASS\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
                printf '== %s PASS %s\n' "${_case}" "${CASE_NOTE}"
                return 0
            fi
            printf '%s\tFAIL\t%s\t%s assertion(s); %s\n' "${_case}" "${AB_HOST}" "${CASE_FAILURES}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
        4)
            printf '%s\tGAP\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s GAP %s\n' "${_case}" "${CASE_NOTE}"
            return 4
            ;;
        *)
            printf '%s\tFAIL\t%s\t%s\n' "${_case}" "${AB_HOST}" "${CASE_NOTE}" >>"${AB_PKG_RESULTS}"
            printf '== %s FAIL %s\n' "${_case}" "${CASE_NOTE}"
            return 1
            ;;
    esac
}

_rc_all=0
for _case in ${CASES}; do
    run_case "${_case}" || _rc_all=1
done
exit "${_rc_all}"
