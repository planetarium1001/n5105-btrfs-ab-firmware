#!/bin/sh
# full-test.sh - one run of the whole device acceptance suite, in one order, with one verdict.
#
# The drivers next to this file each answer one question and each write their own rows:
#
#   probes.sh          the baseline of a freshly flashed machine
#   matrix.sh          M1..M7  does a version jump keep a bootable machine
#   scenarios.sh       S1..S7  does the user's data and software survive it
#   package-revert.sh  P1..P2  the package snapshot and the offline way back
#   recovery-probe.sh  R1/B1   a bad version rolls itself back; `ab-slot rollback`
#   power-cut.sh       I1..I2  an interrupted candidate boot is not retried forever
#   feed-install.sh    ac-12/ac-13  the feed has a candidate and the machine takes it
#   evidence-audit.sh  every ac of the PRD is backed by evidence under the name it uses
#
# Run by hand, that is eight commands in an order a person has to remember, eight result
# files a person has to add up, and a preflight nobody runs because the matrix says
# "unreachable" a minute later anyway. This script is the one order and the one verdict:
#
#   scripts/device/full-test.sh --dry-run            # the plan, nothing touched
#   scripts/device/full-test.sh --preflight-only     # is this machine even the one?
#   scripts/device/full-test.sh --yes                # the whole suite
#   scripts/device/full-test.sh --yes --from matrix  # continue after probes passed
#   scripts/device/full-test.sh --yes --only M3 --only M4
#   scripts/device/full-test.sh --yes --stop-after scenarios
#
# Per phase it writes two files, and nothing else:
#
#   results/<phase>.log   everything the phase printed, plus its start/result markers
#   results/<phase>.tsv   rows in the one shape the whole project reads:
#                         case<TAB>verdict<TAB>evidence<TAB>note
#
# The rows are the phase driver's own: every one of them already has a results channel
# (--results, or AB_*_RESULTS), so this script points that channel at its per-phase file
# instead of parsing prose out of the log. Only when a phase exits without a row does the
# orchestrator write one, so "exit 0 and said nothing" can never read as a silent pass.
#
# Verdict (ac-7): the per-phase files are concatenated into results/verdict.tsv, and
#
#   verdict: PASS   no row is FAIL and no row is GAP    (exit 0)
#   verdict: GAP    nothing failed, something was not decided   (exit 1)
#   verdict: FAIL   at least one row is FAIL            (exit 1)
#
# Exit status: 0 PASS, 1 not PASS, 2 bad usage.
#
# Red lines:
#   * a destructive phase (matrix, recovery, power-cut) writes slots and reboots the
#     device, so it needs --yes or a typed `yes`; a refusal is recorded as GAP, never as
#     a pass;
#   * --dry-run executes nothing at all: no ssh, no mkdir, no results file;
#   * a preflight failure stops the run before a single slot is written. A preflight that
#     cannot confirm the machine is the one under test is a FAIL line, never a skip;
#   * a phase whose script is not installed is a GAP row, not an omission: "we did not
#     ask" and "the machine said yes" must not look the same in the record.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT

# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

# The order is the acceptance order of ac-7 and it is not negotiable: the baseline probes
# come before anything is installed, the evidence audit comes last because it judges the
# record every other phase just wrote.
PHASES="preflight probes matrix scenarios package-revert recovery power-cut feed-install audit"
# A phase that writes a slot, reboots the machine, or both.
DESTRUCTIVE_PHASES="matrix recovery power-cut"
# The probes a caller may name with --only; probes.sh owns these names.
PROBE_NAMES="grow network wan22 key platform adapter initrd packages"

RESULTS_DIR=${AB_FULLTEST_RESULTS:-results}
PAYLOAD_DIR=${AB_FULLTEST_PAYLOAD_DIR:-}
FROM_PHASE=""
FROM_INDEX=""
STOP_AFTER=""
STOP_INDEX=""
ONLY_CASES=""
ASSUME_YES=0
DRY_RUN=0
PREFLIGHT_ONLY=0

# Below this a phase is not started: an install writes tens of MiB into the inactive
# slot and the payload is kept on /data, so a nearly full disk fails in the middle of a
# transaction instead of before it.
MIN_FREE_MB=${AB_FULLTEST_MIN_FREE_MB:-256}

SKIPPED=0
PHASE_REPORT=""
TSV=""
LOG=""

usage() {
    cat <<'USAGE'
usage: full-test.sh [--dry-run] [--preflight-only] [--from PHASE] [--stop-after PHASE]
                    [--only CASE]... [--results DIR] [--payload-dir DIR] [--yes]

  Runs the device acceptance suite in one order:
      preflight probes matrix scenarios package-revert recovery power-cut
      feed-install audit

  --help               print this and exit 0
  --dry-run            print the plan for every phase and exit; nothing is executed and
                       no file is written
  --preflight-only     run preflight and stop there; its rows are the whole result
  --from PHASE         start at PHASE; every phase before it is skipped
  --only CASE          run only the phases that own CASE; repeatable
                         M3 matrix     S3 scenarios    P1 package-revert
                         R1/B1 recovery    I1 power-cut    ac-12/ac-13 feed-install
                         grow/network/... probes
  --stop-after PHASE   stop once PHASE has run
  --results DIR        where <phase>.log, <phase>.tsv, verdict.tsv and summary.txt go
                       (default: results)
  --payload-dir DIR    directory holding payload-<version>.tar; preflight refuses to
                       start when it is given and holds no payload-*.tar
  --yes                allow the destructive phases (matrix, recovery, power-cut);
                       without it they ask for a typed `yes` and are recorded as GAP
                       when refused

  A phase that already has only PASS rows in its results file is skipped, so a rerun
  continues where the last one stopped. Remove results/<phase>.tsv to force a phase.

  Verdict: 'verdict: PASS' when no row is FAIL and no row is GAP, 'verdict: GAP' when
  nothing failed but something was not decided, 'verdict: FAIL' otherwise.
  Exit status: 0 only on PASS, 1 otherwise, 2 bad usage.
USAGE
}

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

# _in_list <word> <list>: is the word one of the space separated list.
_in_list() {
    case " ${2} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# _phase_index <phase>: its position in the acceptance order, or 1 when it is not a phase.
_phase_index() {
    _pi_n=0
    for _pi_p in ${PHASES}; do
        if [ "${_pi_p}" = "${1}" ]; then
            printf '%s\n' "${_pi_n}"
            return 0
        fi
        _pi_n=$((_pi_n + 1))
    done
    return 1
}

# _phase_script <phase>: the driver that answers this phase, empty for preflight (which
# is this script's own work: nothing else may decide that the machine is reachable).
_phase_script() {
    case "${1}" in
        probes) printf '%s\n' "${DEVICE_DIR}/probes.sh" ;;
        matrix) printf '%s\n' "${DEVICE_DIR}/matrix.sh" ;;
        scenarios) printf '%s\n' "${DEVICE_DIR}/scenarios.sh" ;;
        package-revert) printf '%s\n' "${DEVICE_DIR}/package-revert.sh" ;;
        recovery) printf '%s\n' "${DEVICE_DIR}/recovery-probe.sh" ;;
        power-cut) printf '%s\n' "${DEVICE_DIR}/power-cut.sh" ;;
        feed-install) printf '%s\n' "${DEVICE_DIR}/feed-install.sh" ;;
        audit) printf '%s\n' "${DEVICE_DIR}/evidence-audit.sh" ;;
        *) printf '%s\n' "" ;;
    esac
}

# _phase_owns <phase> <case>: does --only CASE belong to this phase.
# The tokens are the drivers' own case names, so a caller who has just read a red row
# (`rerun: matrix.sh --case M3`) can ask for exactly that case.
_phase_owns() {
    case "${1}" in
        probes) _in_list "${2}" "${PROBE_NAMES}" ;;
        matrix) case "${2}" in M[0-9]) return 0 ;; esac; return 1 ;;
        scenarios) case "${2}" in S[0-9]) return 0 ;; esac; return 1 ;;
        package-revert) case "${2}" in P[0-9]) return 0 ;; esac; return 1 ;;
        recovery) case "${2}" in R[0-9] | B[0-9]) return 0 ;; esac; return 1 ;;
        power-cut) case "${2}" in I[0-9]) return 0 ;; esac; return 1 ;;
        feed-install) case "${2}" in ac-12 | ac-13 | check | install | both) return 0 ;; esac; return 1 ;;
        *) return 1 ;;
    esac
}

# _phase_selected_cases <phase>: the --only tokens this phase owns, space separated.
_phase_selected_cases() {
    _psc_out=""
    for _psc_c in ${ONLY_CASES}; do
        _phase_owns "${1}" "${_psc_c}" && _psc_out="${_psc_out} ${_psc_c}"
    done
    printf '%s' "${_psc_out}"
}

# _phase_wanted <phase>: 0 when the phase is in the run at all under --only.
# preflight and audit are the frame of every run: a case selected with --only is still
# judged on a machine that was checked first, and still lands in an audited record.
_phase_wanted() {
    [ -n "${ONLY_CASES}" ] || return 0
    case "${1}" in
        preflight | audit) return 0 ;;
    esac
    for _pw_c in ${ONLY_CASES}; do
        _phase_owns "${1}" "${_pw_c}" && return 0
    done
    return 1
}

# _feed_case_args <tokens>: feed-install.sh takes one --case value, not a list.
_feed_case_args() {
    _fca_check=0
    _fca_install=0
    for _fca_t in $1; do
        case "${_fca_t}" in
            ac-12 | check) _fca_check=1 ;;
            ac-13 | install) _fca_install=1 ;;
            both) _fca_check=1; _fca_install=1 ;;
        esac
    done
    if [ "${_fca_check}" = 1 ] && [ "${_fca_install}" = 1 ]; then
        printf 'both'
    elif [ "${_fca_check}" = 1 ]; then
        printf 'check'
    elif [ "${_fca_install}" = 1 ]; then
        printf 'install'
    fi
}

# _phase_args <phase>: the arguments, from the flags each driver already supports.
# Nothing here invents an option: probes takes --probe, the matrix and the scenarios take
# --case/--payload-dir/--results/--evidence-dir, the three case drivers take --case.
_phase_args() {
    _pa_sel=$(_phase_selected_cases "${1}")
    case "${1}" in
        probes)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--probe" "${_pa_c}"
            done
            ;;
        matrix | scenarios)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            if [ -n "${PAYLOAD_DIR}" ]; then
                printf '%s %s ' "--payload-dir" "${PAYLOAD_DIR}"
            fi
            printf '%s %s ' "--results" "${TSV}"
            printf '%s %s ' "--evidence-dir" "${RESULTS_DIR}/evidence"
            ;;
        package-revert | recovery | power-cut)
            for _pa_c in ${_pa_sel}; do
                printf '%s %s ' "--case" "${_pa_c}"
            done
            ;;
        feed-install)
            _pa_fc=$(_feed_case_args "${_pa_sel}")
            if [ -n "${_pa_fc}" ]; then
                printf '%s %s ' "--case" "${_pa_fc}"
            fi
            ;;
    esac
    return 0
}

# _phase_env <phase>: the results channel of a driver that has no --results flag.
# probes.sh, package-revert.sh, recovery-probe.sh, power-cut.sh and feed-install.sh each
# append their own four (or five) column rows through a variable of their own.
_phase_env() {
    case "${1}" in
        probes) printf 'AB_PROBE_RESULTS=%s' "${TSV}" ;;
        package-revert) printf 'AB_PKG_RESULTS=%s' "${TSV}" ;;
        recovery) printf 'AB_RECOVERY_RESULTS=%s' "${TSV}" ;;
        power-cut) printf 'AB_POWER_RESULTS=%s' "${TSV}" ;;
        feed-install) printf 'AB_FEED_INSTALL_RESULTS=%s' "${TSV}" ;;
        *) printf '' ;;
    esac
}

# _phase_plan <phase>: the one line --dry-run prints for a phase. It is the command that
# would run, so the plan cannot drift away from the run.
_phase_plan() {
    _pp_script=$(_phase_script "${1}")
    if [ "${1}" = "preflight" ]; then
        printf 'internal: key file, ssh reachability, platform identity, free space on %s and /data, payload-dir contents' \
            "${AB_P4_MOUNT}"
        return 0
    fi
    _pp_args=$(_phase_args "${1}")
    _pp_env=$(_phase_env "${1}")
    if [ ! -f "${_pp_script}" ]; then
        printf '%s%s (script not present, would be recorded GAP)' \
            "${_pp_env:+${_pp_env} }" "${_pp_script}"
        return 0
    fi
    printf '%s%s%s' "${_pp_env:+${_pp_env} }" "${_pp_script}" "${_pp_args:+ ${_pp_args}}"
}

# --------------------------------------------------------------------------- #
# preflight
# --------------------------------------------------------------------------- #

# The five questions a run cannot answer for itself once it has written a slot. Each one
# is a row of its own (`preflight-key`, `preflight-ssh`, ...) so a rerun that skips the
# section on an all-PASS file has really asked all five.
_preflight_pass() { # <check> <detail>
    printf 'preflight: ok %s %s\n' "${1}" "${2}"
    AB_RESULTS="${TSV}"
    record "preflight-${1}" PASS "${LOG}" "${2}"
}

_preflight_fail() { # <check> <reason>
    printf 'preflight: FAIL %s\n' "${2}"
    AB_RESULTS="${TSV}"
    record "preflight-${1}" FAIL "${LOG}" "${2}"
    return 1
}

_preflight() {
    # 1. the key. BatchMode=yes means a missing key is a wall, not a prompt, so it is
    #    answered here instead of as "the machine is down" three phases later.
    if [ ! -e "${AB_KEY}" ]; then
        _preflight_fail key "key file missing: ${AB_KEY}"
        return 1
    fi
    if [ ! -r "${AB_KEY}" ]; then
        _preflight_fail key "key file not readable: ${AB_KEY}"
        return 1
    fi
    _preflight_pass key "key=${AB_KEY}"

    # 2. the machine. dev_ssh carries the ssh options every driver uses (BatchMode,
    #    IdentitiesOnly, no ControlMaster), so this is the same hop the phases make.
    if ! dev_ssh true >/dev/null 2>&1; then
        _preflight_fail ssh "device unreachable over ssh: ${AB_HOST} (key ${AB_KEY})"
        return 1
    fi
    _preflight_pass ssh "host=${AB_HOST}"

    # 3. the platform identity. A reachable machine that is not this project's image
    #    produces red rows that look like product defects, so the version is read first.
    _pf_plat=$(dev_ssh 'cat /etc/platform-release 2>/dev/null || cat /etc/os-release 2>/dev/null' 2>/dev/null | head -n 20)
    _pf_ver=""
    if [ -n "${_pf_plat}" ]; then
        _pf_ver=$(printf '%s\n' "${_pf_plat}" | sed -n 's/^PLATFORM_VERSION=//p' | head -n 1)
        if [ -z "${_pf_ver}" ]; then
            _pf_ver=$(printf '%s\n' "${_pf_plat}" | sed -n 's/^VERSION_ID=//p' | head -n 1 | tr -d '"')
        fi
    fi
    if [ -z "${_pf_plat}" ] || [ -z "${_pf_ver}" ]; then
        _preflight_fail platform "platform identity unreadable on ${AB_HOST}: neither /etc/platform-release nor /etc/os-release names a version"
        return 1
    fi
    _preflight_pass platform "platform=${_pf_ver}"

    # 4. the two partitions the phases write into. /mnt/p4 holds the overlay layers and
    #    /data holds the payloads and the user's files; a phase that starts on a full disk
    #    fails inside a transaction instead of before it.
    _pf_df=$(dev_ssh "df -Pk ${AB_P4_MOUNT} /data" 2>/dev/null)
    _pf_free_report=""
    for _pf_m in "${AB_P4_MOUNT}" /data; do
        _pf_free=$(printf '%s\n' "${_pf_df}" \
            | awk -v m="${_pf_m}" 'NR > 1 && $NF == m { printf "%d", $4 / 1024 }')
        if [ -z "${_pf_free}" ]; then
            _preflight_fail disk "no free space reported for ${_pf_m} (df -Pk ${AB_P4_MOUNT} /data gave no line for it)"
            return 1
        fi
        if [ "${_pf_free}" -lt "${MIN_FREE_MB}" ]; then
            _preflight_fail disk "${_pf_m} has ${_pf_free} MiB free, the phases need ${MIN_FREE_MB} MiB"
            return 1
        fi
        _pf_free_report="${_pf_free_report}${_pf_free_report:+,}${_pf_m}:${_pf_free}MiB"
    done
    _preflight_pass disk "${_pf_free_report}"

    # 5. the payloads, when the caller said where they are. Without --payload-dir the
    #    phases fall back to their own default (payloads) and this question is not asked.
    if [ -n "${PAYLOAD_DIR}" ]; then
        if [ ! -d "${PAYLOAD_DIR}" ]; then
            _preflight_fail payload "payload-dir does not exist: ${PAYLOAD_DIR}"
            return 1
        fi
        _pf_n=0
        for _pf_f in "${PAYLOAD_DIR}"/payload-*.tar; do
            [ -f "${_pf_f}" ] || continue
            _pf_n=$((_pf_n + 1))
        done
        if [ "${_pf_n}" -eq 0 ]; then
            _preflight_fail payload "payload-dir holds no payload-*.tar: ${PAYLOAD_DIR}"
            return 1
        fi
        _preflight_pass payload "payload-dir=${PAYLOAD_DIR} files=${_pf_n}"
    else
        _preflight_pass payload "no --payload-dir given; the phases use their own default (payloads)"
    fi

    printf 'preflight: ok\n'
    return 0
}

# --------------------------------------------------------------------------- #
# Running one phase
# --------------------------------------------------------------------------- #

# _phase_run <phase>: the phase's process. Its stdout and stderr are the caller's.
_phase_run() {
    if [ "${1}" = "preflight" ]; then
        _preflight
        return $?
    fi
    _pr_script=$(_phase_script "${1}")
    _pr_args=$(_phase_args "${1}")
    _pr_env=$(_phase_env "${1}")
    (
        # The results channel is exported in a subshell so a value with spaces survives
        # the round trip (the arguments themselves are space separated, which is the
        # repo's own convention).
        case "${_pr_env}" in
            *"="*)
                export "${_pr_env%%=*}"="${_pr_env#*=}"
                ;;
        esac
        # shellcheck disable=SC2086
        set -- ${_pr_args}
        "${_pr_script}" "$@"
    )
}

# _normalize_tsv <file>: keep the four columns of the project's row shape.
# recovery-probe.sh and feed-install.sh append a fifth `checks=.. failures=.. gaps=..`
# column; the counters are already in the log, and verdict.tsv has to stay one shape.
_normalize_tsv() {
    [ -s "${1}" ] || return 0
    if awk -F'\t' 'NF > 4 { wide = 1 } END { exit !wide }' "${1}"; then
        awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $2, $3, $4 }' "${1}" >"${1}.tmp" \
            && mv "${1}.tmp" "${1}"
    fi
    return 0
}

# _audit_rows: the audit phase writes no results file of its own, so its verdict is read
# off the two summary lines it prints. Missing evidence is a GAP and not a FAIL: nothing
# about the machine was judged, the record is incomplete.
_audit_rows() {
    _ar_sum=$(grep '^evidence-audit summary' "${LOG}" 2>/dev/null | head -n 1)
    _ar_res=$(grep '^evidence-audit result=' "${LOG}" 2>/dev/null | head -n 1)
    case "${_ar_res}" in
        *result=covered)
            AB_RESULTS="${TSV}"
            record audit PASS "${LOG}" "${_ar_sum:-every ac carries its evidence}"
            ;;
        *result=gaps)
            AB_RESULTS="${TSV}"
            record audit GAP "${LOG}" "${_ar_sum:-evidence-audit reports acs whose evidence is not named}"
            ;;
    esac
    return 0
}

# _ensure_rows <phase> <exit status>: a phase that wrote no row gets one here.
# "exit 0 and said nothing" must not be readable as a pass: the row says how the phase
# ended, and the note says that no case-level row came with it.
_ensure_rows() {
    [ -s "${TSV}" ] && return 0
    AB_RESULTS="${TSV}"
    case "${2}" in
        0) record "${1}" PASS - "exit 0, no per-case row was written" ;;
        4) record "${1}" GAP - "exit 4: the phase could not run (missing precondition)" ;;
        *) record "${1}" FAIL - "exit ${2}: the phase failed before writing a row" ;;
    esac
    return 0
}

# _phase_verdict <tsv>: the worst row of a phase file.
_phase_verdict() {
    if [ ! -s "${1}" ]; then
        printf 'GAP'
        return 0
    fi
    if awk -F'\t' '$2 == "FAIL" { f = 1 } END { exit !f }' "${1}"; then
        printf 'FAIL'
    elif awk -F'\t' '$2 == "GAP" { g = 1 } END { exit !g }' "${1}"; then
        printf 'GAP'
    else
        printf 'PASS'
    fi
}

# _already_pass <tsv>: every row PASS, so this phase has nothing left to prove.
# A file holding a FAIL or a GAP is not a reason to skip: the phase runs again.
_already_pass() {
    [ -s "${1}" ] || return 1
    awk -F'\t' '$2 != "PASS" { bad = 1 } END { exit bad }' "${1}"
}

# _confirm_destructive <phase>: a destructive phase needs a yes a person typed.
# Refusing is allowed and is recorded as GAP: the run then continues with the phases that
# only read the machine.
_confirm_destructive() {
    _cd_is=0
    for _cd_p in ${DESTRUCTIVE_PHASES}; do
        [ "${_cd_p}" = "${1}" ] && _cd_is=1
    done
    [ "${_cd_is}" = 1 ] || return 0
    [ "${ASSUME_YES}" = 1 ] && return 0
    printf '%s writes slots and reboots %s. type yes to continue: ' "${1}" "${AB_HOST}" >&2
    _cd_answer=""
    IFS= read -r _cd_answer || _cd_answer=""
    [ "${_cd_answer}" = "yes" ]
}

_phase_start() { # <phase>
    mkdir -p "${RESULTS_DIR}" || return 1
    printf 'phase %s: start\n' "${1}"
    printf '### phase %s start %s\n' "${1}" "$(dev_stamp)" >>"${LOG}"
    return 0
}

_phase_done() { # <phase> <result>
    _pd_rows=0
    if [ -s "${TSV}" ]; then
        _pd_rows=$(awk -F'\t' 'END { printf "%d", NR }' "${TSV}")
    fi
    printf 'phase %s: %s\n' "${1}" "${2}"
    printf '### phase %s result=%s rows=%s %s\n' "${1}" "${2}" "${_pd_rows}" "$(dev_stamp)" >>"${LOG}"
    PHASE_REPORT="${PHASE_REPORT}${1} ${2} rows=${_pd_rows}
"
}

_skip() { # <phase> <reason>
    SKIPPED=$((SKIPPED + 1))
    printf 'phase %s: skipped\n' "${1}"
    printf '  %s\n' "${2}"
    PHASE_REPORT="${PHASE_REPORT}${1} skipped: ${2}
"
}

# --------------------------------------------------------------------------- #
# The verdict
# --------------------------------------------------------------------------- #

_count_rows() { # <tsv> <verdict>
    [ -s "${1}" ] || {
        printf '0'
        return 0
    }
    awk -F'\t' -v v="${2}" '$2 == v { n++ } END { printf "%d", n }' "${1}"
}

_write_verdict() {
    mkdir -p "${RESULTS_DIR}" || return 1
    : >"${RESULTS_DIR}/verdict.tsv"
    for _wv_p in ${PHASES}; do
        [ -f "${RESULTS_DIR}/${_wv_p}.tsv" ] || continue
        cat "${RESULTS_DIR}/${_wv_p}.tsv" >>"${RESULTS_DIR}/verdict.tsv"
    done
    _wv_passed=$(_count_rows "${RESULTS_DIR}/verdict.tsv" PASS)
    _wv_failed=$(_count_rows "${RESULTS_DIR}/verdict.tsv" FAIL)
    _wv_gap=$(_count_rows "${RESULTS_DIR}/verdict.tsv" GAP)

    _wv_verdict=PASS
    if [ "${_wv_failed}" -gt 0 ]; then
        _wv_verdict=FAIL
    elif [ "${_wv_gap}" -gt 0 ]; then
        _wv_verdict=GAP
    fi

    {
        printf 'passed=%s failed=%s gap=%s skipped=%s\n' \
            "${_wv_passed}" "${_wv_failed}" "${_wv_gap}" "${SKIPPED}"
        printf '%s' "${PHASE_REPORT}"
        printf 'verdict: %s\n' "${_wv_verdict}"
    } >"${RESULTS_DIR}/summary.txt"

    printf 'full-test: results=%s passed=%s failed=%s gap=%s skipped=%s\n' \
        "${RESULTS_DIR}" "${_wv_passed}" "${_wv_failed}" "${_wv_gap}" "${SKIPPED}"
    printf 'verdict: %s\n' "${_wv_verdict}"
    printf 'full-test: rows in %s, summary in %s\n' \
        "${RESULTS_DIR}/verdict.tsv" "${RESULTS_DIR}/summary.txt"

    [ "${_wv_verdict}" = "PASS" ]
}

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #

while [ $# -gt 0 ]; do
    case "${1}" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=1
            shift
            ;;
        --from)
            FROM_PHASE=${2:?--from needs a phase}
            shift 2
            ;;
        --stop-after)
            STOP_AFTER=${2:?--stop-after needs a phase}
            shift 2
            ;;
        --only)
            ONLY_CASES="${ONLY_CASES} ${2:?--only needs a case, e.g. M3}"
            shift 2
            ;;
        --results)
            RESULTS_DIR=${2:?--results needs a directory}
            shift 2
            ;;
        --payload-dir)
            PAYLOAD_DIR=${2:?--payload-dir needs a directory}
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'full-test: unknown argument: %s\n' "${1}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# --preflight-only is --stop-after preflight, so there is one window rule and not two.
if [ "${PREFLIGHT_ONLY}" = 1 ]; then
    if [ -n "${STOP_AFTER}" ] && [ "${STOP_AFTER}" != "preflight" ]; then
        printf 'full-test: --preflight-only and --stop-after %s contradict each other\n' "${STOP_AFTER}" >&2
        exit 2
    fi
    STOP_AFTER=preflight
fi

if [ -n "${FROM_PHASE}" ]; then
    if ! FROM_INDEX=$(_phase_index "${FROM_PHASE}"); then
        printf 'full-test: --from: not a phase: %s (want one of: %s)\n' "${FROM_PHASE}" "${PHASES}" >&2
        exit 2
    fi
fi

if [ -n "${STOP_AFTER}" ]; then
    if ! STOP_INDEX=$(_phase_index "${STOP_AFTER}"); then
        printf 'full-test: --stop-after: not a phase: %s (want one of: %s)\n' "${STOP_AFTER}" "${PHASES}" >&2
        exit 2
    fi
fi

if [ -n "${FROM_INDEX}" ] && [ -n "${STOP_INDEX}" ] && [ "${FROM_INDEX}" -gt "${STOP_INDEX}" ]; then
    printf 'full-test: --from %s comes after --stop-after %s, so no phase would run\n' \
        "${FROM_PHASE}" "${STOP_AFTER}" >&2
    exit 2
fi

# A --only token no phase owns is a typo, and a typo that skips everything would read as
# a green run over nothing.
if [ -n "${ONLY_CASES}" ]; then
    for _arg_c in ${ONLY_CASES}; do
        _arg_own=0
        for _arg_p in ${PHASES}; do
            _phase_owns "${_arg_p}" "${_arg_c}" && _arg_own=1
        done
        if [ "${_arg_own}" = 0 ]; then
            printf 'full-test: --only: no phase owns case: %s\n' "${_arg_c}" >&2
            printf 'full-test: cases are M1..M7, S1..S7, P*, R*, B*, I*, ac-12, ac-13, %s\n' \
                "${PROBE_NAMES}" >&2
            exit 2
        fi
    done
fi

# --------------------------------------------------------------------------- #
# The run
# --------------------------------------------------------------------------- #

if [ "${DRY_RUN}" = "1" ]; then
    # Belt and braces: nothing below the plan is reached, and every ssh helper would
    # refuse anyway.
    AB_DRY_RUN=1
    export AB_DRY_RUN
    printf 'plan: results=%s payload-dir=%s yes=%s\n' \
        "${RESULTS_DIR}" "${PAYLOAD_DIR:-default}" "${ASSUME_YES}"
    if [ -n "${FROM_PHASE}" ]; then
        printf 'plan: --from %s\n' "${FROM_PHASE}"
    fi
    if [ -n "${STOP_AFTER}" ]; then
        printf 'plan: --stop-after %s\n' "${STOP_AFTER}"
    fi
    printf 'plan: --only %s\n' "${ONLY_CASES:-all cases}"
fi

_run_i=0
for _run_phase in ${PHASES}; do
    TSV="${RESULTS_DIR}/${_run_phase}.tsv"
    LOG="${RESULTS_DIR}/${_run_phase}.log"
    _run_idx=${_run_i}
    _run_i=$((_run_i + 1))

    if [ -n "${FROM_INDEX}" ] && [ "${_run_idx}" -lt "${FROM_INDEX}" ]; then
        _skip "${_run_phase}" "before --from ${FROM_PHASE}"
        continue
    fi
    if [ -n "${STOP_INDEX}" ] && [ "${_run_idx}" -gt "${STOP_INDEX}" ]; then
        _skip "${_run_phase}" "after --stop-after ${STOP_AFTER}"
        continue
    fi
    if ! _phase_wanted "${_run_phase}"; then
        _skip "${_run_phase}" "no case selected by --only"
        continue
    fi
    if [ "${DRY_RUN}" != "1" ] && _already_pass "${TSV}"; then
        _skip "${_run_phase}" "already PASS in ${TSV}"
        continue
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        printf 'phase %s: plan %s\n' "${_run_phase}" "$(_phase_plan "${_run_phase}")"
        continue
    fi

    mkdir -p "${RESULTS_DIR}" || {
        printf 'full-test: cannot create results directory: %s\n' "${RESULTS_DIR}" >&2
        exit 1
    }
    _phase_start "${_run_phase}" || exit 1

    _run_script=$(_phase_script "${_run_phase}")
    if [ "${_run_phase}" != "preflight" ] && [ ! -f "${_run_script}" ]; then
        AB_RESULTS="${TSV}"
        record "${_run_phase}" GAP - "script not present: ${_run_script}"
        printf '  script not present: %s\n' "${_run_script}"
        _phase_done "${_run_phase}" "GAP"
        continue
    fi

    if ! _confirm_destructive "${_run_phase}"; then
        AB_RESULTS="${TSV}"
        record "${_run_phase}" GAP - "destructive phase not confirmed (pass --yes)"
        printf '  not confirmed: pass --yes to let %s write slots\n' "${_run_phase}"
        _phase_done "${_run_phase}" "GAP"
        continue
    fi

    _run_rcfile="${RESULTS_DIR}/.${_run_phase}.rc"
    {
        _phase_run "${_run_phase}" 2>&1
        printf '%s\n' "$?" >"${_run_rcfile}"
    } | tee -a "${LOG}"
    _run_rc=$(cat "${_run_rcfile}" 2>/dev/null || printf '1')
    rm -f "${_run_rcfile}"

    _normalize_tsv "${TSV}"
    if [ "${_run_phase}" = "audit" ] && [ ! -s "${TSV}" ]; then
        _audit_rows
    fi
    _ensure_rows "${_run_phase}" "${_run_rc}"
    _run_result=$(_phase_verdict "${TSV}")
    _phase_done "${_run_phase}" "${_run_result}"

    if [ "${_run_phase}" = "preflight" ] && [ "${_run_result}" != "PASS" ]; then
        # Everything after preflight assumes a reachable machine that is the one under
        # test; running it on a machine nobody could confirm is how a red preflight turns
        # into a page of unrelated reds.
        printf 'full-test: preflight did not pass, the run stops here\n' >&2
        printf 'full-test: fix the line above, then rerun with --from %s\n' "${FROM_PHASE:-preflight}" >&2
        break
    fi
done

if [ "${DRY_RUN}" = "1" ]; then
    printf 'plan: nothing was executed and no file was written (--dry-run)\n'
    exit 0
fi

_write_verdict
exit $?
