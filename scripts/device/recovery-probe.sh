#!/bin/sh
# recovery-probe.sh - the two recovery paths ac-11 and ac-10 name, on the real machine.
#
# Two cases, one script, because both end with "and the machine is still the one it was":
#
#   R1  ac-11 (1) a bad version rolls itself back
#       install a candidate whose *runtime* is broken, let its first boot fail its health
#       check, then prove the machine recorded `action=reboot-to-committed`, stayed on the
#       slot it was on, and answers ssh again.
#
#   B1  ac-10 `ab-slot rollback`
#       move the committed slot backwards on purpose, boot it, and prove the data and the
#       configuration marker are the ones from before - and that `ab-slot status` does not
#       answer `packages=... reason=other-slot` afterwards, which is what `cmd_rollback`'s
#       `packages_record_retarget` exists for.
#
#   scripts/device/recovery-probe.sh --case R1 --payload /tmp/n5105-ab-25.12.2-upgrade.tar
#   scripts/device/recovery-probe.sh --case R1 --installed --inject none
#   scripts/device/recovery-probe.sh --case B1
#   scripts/device/recovery-probe.sh --case R1 --case B1
#   AB_DRY_RUN=1 scripts/device/recovery-probe.sh     # print the steps, touch nothing
#
# Which way in R1 installs the candidate, and why it is the one it is
# -------------------------------------------------------------------
# `--payload <file>` is the normal way in, and it is what scripts/device/full-test.sh hands
# the phase: the round's own candidate, named <payload-dir>/payload-<expect>.tar.
#
# A machine whose running slot already carries that release refuses the payload with exit 74
# `payload-already-installed` (ab-upgrade's guard, and matrix.sh M5's judgement - not this
# case's). R1 is about what the candidate's first boot does, so the candidate is laid into the
# other slot anyway, with the `ab-upgrade --force` the refusal itself names. `--installed` is
# not the alternative in a full run: it needs a candidate already queued, and every phase
# before recovery either commits or abandons its slot, so nothing is pending by then. The row
# says which of the two installs was used.
#
# Why R1 needs an injection, and why matrix.sh M7 is not it
# ---------------------------------------------------------
# M7 asks `ab-upgrade --check` about a payload with a bad digest and expects exit 74: the
# payload is refused *before anything is written*, so no candidate ever boots and the
# `action=reboot-to-committed` line - written by `ab-commit` when a candidate's health check
# fails (`platform/etc/init.d/ab-commit:356`) - cannot appear. A green M7 says nothing about
# ac-11's first clause; it is a different path.
#
# That line needs a candidate that boots into userspace and then fails one of the three
# probes (`overlay-writable`, `fw4-present`, `wan-present`) or the preflight. A payload with
# a broken kernel or initramfs does not produce it either: that candidate never reaches
# userspace, so nothing writes a decision - it hangs, which is the failure mode PRD risk 4
# calls unrecoverable without physical access.
#
# So R1 has two ways in:
#   --inject uci-wan  (default) break one option in the *candidate's own* writable layer
#                     before the reboot: `network.wan.device` is set to an interface that
#                     does not exist, which makes `wan-present` fail with
#                     `no-interface:...`. The layer is a throwaway snapshot of the running
#                     one (`platform/lib/upgrade/platform.sh` snapshots it), so nothing the
#                     user can see is touched, and the original file is put back at the end.
#   --inject none     the operator queued an unhealthy candidate by other means (a
#                     hand-built payload whose manifest is honest but whose runtime is
#                     not). The driver only asserts; it injects nothing.
#
# If the injection misses the file the candidate actually reads, the candidate boots
# healthily and commits - the run says so (committed moved) and names the rollback command,
# because a probe that quietly moved a healthy machine would be worse than the gap it was
# closing.
#
# Assertion shape: one line per assertion, `ok` / `FAIL` / `GAP` plus a pasteable next step.
# Exit status: 0 every selected case passed, 1 a case failed, 2 usage, 3 no verdict
# (the machine could not be put into the state a case needs).

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

AB_RECOVERY_RESULTS=${AB_RECOVERY_RESULTS:-recovery-results.tsv}
DRY_RUN=${AB_DRY_RUN:-0}

CASES=""
payload=""
armed=0
inject=uci-wan
# The helper has to survive the candidate boot: /tmp is tmpfs and is empty after the reboot,
# which is how the restore step used to fail and leave wan.device=ab-inject-none0 behind.
INJECT_CMD=${INJECT_CMD:-/mnt/p4/ab/recovery-inject.sh}

usage() {
    sed -n '17,21p' "$0"
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            case "${2:-}" in
                R1 | B1) CASES="${CASES} ${2}" ;;
                *) printf 'recovery-probe.sh: --case takes R1 or B1\n' >&2; usage ;;
            esac
            shift 2
            ;;
        --payload) payload=${2:?--payload needs a tar path}; shift 2 ;;
        --installed) armed=1; shift ;;
        --inject)
            case "${2:-}" in
                uci-wan | none) inject=${2} ;;
                *) printf 'recovery-probe.sh: --inject takes uci-wan or none\n' >&2; usage ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage ;;
        *) printf 'recovery-probe.sh: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "${CASES}" ] || CASES=" R1 B1"

CHECKS=0
FAILURES=0
GAPS=0
# Per-case counters: the first pair answers "did this run pass", the second "did this case".
CASE_CHECKS=0
CASE_FAILURES=0
CASE_GAPS=0
CASE_STATUS=""
CASE_NOTE=""

_ok() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    printf 'ok [%s] %s\n' "$1" "$2"
    ev "ok ${1}: ${2}"
}

_fail() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    CASE_FAILURES=$((CASE_FAILURES + 1))
    printf 'FAIL [%s] %s\n' "$1" "$2"
    if [ -n "${3:-}" ]; then
        printf '  next: %s\n' "$3"
    fi
    ev "FAIL ${1}: ${2}${3:+ | next: ${3}}"
}

_gap() {
    CHECKS=$((CHECKS + 1))
    CASE_CHECKS=$((CASE_CHECKS + 1))
    GAPS=$((GAPS + 1))
    CASE_GAPS=$((CASE_GAPS + 1))
    printf 'GAP [%s] %s\n' "$1" "$2"
    if [ -n "${3:-}" ]; then
        printf '  next: %s\n' "$3"
    fi
    ev "GAP ${1}: ${2}${3:+ | next: ${3}}"
}

_assert_eq() {
    if [ "$3" = "$4" ]; then
        _ok "$1" "$2=$3"
        return 0
    fi
    _fail "$1" "$2=$3, expected $4" "${5:-}"
    return 1
}

_field() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

other_slot() {
    case "$1" in
        a) printf 'b' ;;
        b) printf 'a' ;;
        *) return 1 ;;
    esac
}

# require_machine <case> <none|armed>: a committed, healthy machine, with either no
# candidate queued or exactly the candidate the caller is about to probe.
# R1 is about a candidate being rejected and B1 about the committed slot moving; either one
# run on a machine already mid-transaction measures two things at once. The one exception is
# `R1 --installed`, where an armed candidate is the precondition rather than a surprise.
require_machine() {
    _case=$1
    _want_pending=${2:-none}
    if ! STATUS_LINE=$(dev_status 2>/dev/null); then
        _gap "${_case}" "ab-slot status did not answer" "ab-slot status"
        return 1
    fi
    _boot=$(_field "${STATUS_LINE}" boot)
    _esp=$(_field "${STATUS_LINE}" esp)
    _pending=$(_field "${STATUS_LINE}" pending)
    case "${_want_pending}" in
        armed)
            case "${_pending}" in
                a | b) : ;;
                *)
                    _gap "${_case}" "no candidate is queued (pending=${_pending:-?})" "ab-upgrade --check /tmp/payload.tar"
                    return 1
                    ;;
            esac
            ;;
        *)
            if [ "${_pending}" != "none" ]; then
                _gap "${_case}" "a candidate is already queued (pending=${_pending:-?}); resolve it first" \
                    "ab-slot status; ab-slot abandon"
                return 1
            fi
            ;;
    esac
    if [ "${_boot}" != "ok" ] || [ "${_esp}" != "ok" ]; then
        _gap "${_case}" "machine is not healthy (boot=${_boot:-?} esp=${_esp:-?})" "ab-slot log"
        return 1
    fi
    _ok "${_case}" "machine is healthy (slot=$(_field "${STATUS_LINE}" slot) committed=$(_field "${STATUS_LINE}" committed) pending=${_pending:-?})"
    return 0
}

# marker_read: the two values ac-10 says have to survive, as this run sees them now.
# Printed as `data=<v> config=<v>` so one assertion can compare the whole pair.
marker_read() {
    _data=$(dev_marker_read 2>/dev/null) || _data=""
    _config=$(dev_config_marker 2>/dev/null) || _config=""
    printf 'data=%s config=%s\n' "${_data:-none}" "${_config:-unknown}"
}

# --------------------------------------------------------------------------- #
# The injection helper: a small script pushed to the machine, because quoting a
# `uci -c <dir> set ...` inside an ssh argument is exactly where this kind of step goes
# wrong. It edits one file - the network config inside the candidate's own writable layer -
# keeps a copy of it beside itself, and touches nothing in the running slot.
# --------------------------------------------------------------------------- #

# The helper below is a script for the *machine*, so its ${...} must not expand here.
# shellcheck disable=SC2016
INJECT_HELPER='#!/bin/sh
# ab-recovery-inject.sh - break or restore one option in a candidate network config.
set -u
mode=${1:?set or restore}
layer=${2:?the candidate layer path, e.g. /mnt/p4/@overlay-25.12.2}
[ -d "${layer}" ] || { echo "reason=no-layer path=${layer}"; exit 1; }

# Every etc/config/network under the layer, shallowest first: a layer may keep its files at
# the top or under an upper/ subvolume, and the shallow one is the one the candidate reads.
all=$(find "${layer}" -maxdepth 4 -type f -path "*/etc/config/network" 2>/dev/null)
candidates=$(printf "%s\n" "${all}" | tr "\n" " ")
cfg=$(printf "%s\n" "${all}" | awk "{ print length, \$0 }" | sort -n | awk "NR == 1 { print \$2 }")

case "${mode}" in
    set)
        [ -n "${cfg}" ] || { echo "reason=no-network-config layer=${layer} candidates=${candidates:-none}"; exit 1; }
        cfgdir=$(dirname "${cfg}")
        cp "${cfg}" "${cfg}.recovery-probe.bak" 2>/dev/null || { echo "reason=cannot-back-up cfg=${cfg}"; exit 1; }
        before=$(uci -c "${cfgdir}" -q get network.wan.device 2>/dev/null || uci -c "${cfgdir}" -q get network.wan.ifname 2>/dev/null || echo "")
        uci -c "${cfgdir}" set network.wan.device="ab-inject-none0" || { echo "reason=uci-set-failed cfg=${cfg}"; exit 1; }
        uci -c "${cfgdir}" commit network || { echo "reason=uci-commit-failed cfg=${cfg}"; exit 1; }
        after=$(uci -c "${cfgdir}" -q get network.wan.device 2>/dev/null || echo "")
        echo "cfg=${cfg} candidates=${candidates:-none} before=${before:-none} after=${after:-none}"
        ;;
    restore)
        [ -n "${cfg}" ] || { echo "reason=no-network-config layer=${layer}"; exit 1; }
        [ -f "${cfg}.recovery-probe.bak" ] || { echo "restored=nothing-to-do cfg=${cfg}"; exit 0; }
        mv "${cfg}.recovery-probe.bak" "${cfg}" || { echo "reason=restore-failed cfg=${cfg}"; exit 1; }
        echo "restored=${cfg}"
        ;;
    *)
        echo "reason=unknown-mode mode=${mode}"
        exit 2
        ;;
esac
'

push_inject_helper() {
    dev_ssh 'mkdir -p /mnt/p4/ab' >/dev/null 2>&1 || return 1
    if ! hlp=$(mktemp "${TMPDIR:-/tmp}/ab-recovery-inject.XXXXXX"); then
        return 1
    fi
    printf '%s\n' "${INJECT_HELPER}" >"${hlp}"
    if dev_push "${hlp}" "${INJECT_CMD}" >/dev/null 2>&1; then
        rm -f "${hlp}"
        return 0
    fi
    rm -f "${hlp}"
    return 1
}

# restore_injection <layer|none>: put the file the injection touched back, and say so.
# Leaving it broken would make the next candidate boot on that slot fail for a reason this
# run created - a defect the next run would then have to explain.
restore_injection() {
    _layer=${1:-}
    case "${_layer}" in
        '' | none) return 0 ;;
    esac
    if restore_out=$(dev_ssh "sh ${INJECT_CMD} restore '${_layer}'" 2>&1); then
        _ok R1 "restored the injected file: $(printf '%s' "${restore_out}" | tr '\n' ' ')"
        return 0
    fi
    _fail R1 "the injected file could not be restored (${restore_out:-no output})" \
        "sh ${INJECT_CMD} restore ${_layer}   # on the machine"
    return 1
}

# --------------------------------------------------------------------------- #
# R1: a bad version rolls itself back
# --------------------------------------------------------------------------- #

run_bad_version() {
    _case=R1

    # A dry run is a planner: it prints the plan without reading the machine, because
    # AB_DRY_RUN=1 makes every dev_ssh inert and an assertion over no output would report a
    # red that says nothing about the product.
    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/8 install the candidate into the other slot (payload=%s installed=%s)
' \
            "${_case}" "${payload:-current pending}" "${armed}"
        printf '%s 2/8 expect exit 0, pending=<other>, committed unchanged
' "${_case}"
        printf '%s 3/8 inject=%s: set network.wan.device=ab-inject-none0 in the candidate layer
' "${_case}" "${inject}"
        printf '%s 4/8 reboot, wait for 22 through two boots (budget %ss)
' "${_case}" "${AB_WAIT_UP_HARD}"
        printf '%s 5/8 expect stage=abandon .*action=reboot-to-committed in the ring log
' "${_case}"
        printf '%s 6/8 expect committed unchanged, pending=none, slot=<committed>, generation +0 or +1 (abandon writes the ESP counter)
' "${_case}"
        printf '%s 7/8 expect the rootfs version and the markers from before the install
' "${_case}"
        printf '%s 8/8 put the injected file back
' "${_case}"
        CASE_NOTE="dry-run"
        CASE_STATUS=PASS
        return 0
    fi

    if [ "${armed}" = "1" ]; then
        require_machine "${_case}" armed || {
            CASE_STATUS=GAP
            return 1
        }
    else
        require_machine "${_case}" none || {
            CASE_STATUS=GAP
            return 1
        }
    fi
    before_committed=$(_field "${STATUS_LINE}" committed)
    before_generation=$(_field "${STATUS_LINE}" generation)
    before_slot=$(_field "${STATUS_LINE}" slot)
    before_version=$(dev_running_version 2>/dev/null) || before_version=""
    before_markers=$(marker_read)
    target=""
    # "force" once the candidate had to be laid down with `ab-upgrade --force` because the
    # running slot already carried this release; empty for the plain install and for
    # --installed. It ends up in the row, so a reader can tell a reinstalled candidate from a
    # fresh one.
    install_mode=""

    if [ "${armed}" = "1" ]; then
        target=$(_field "${STATUS_LINE}" pending)
        if [ "${target}" = "none" ] || [ -z "${target}" ]; then
            _gap "${_case}" "--installed was given and nothing is pending" \
                "ab-upgrade --check /tmp/payload.tar; ab-slot status"
            CASE_STATUS=GAP
            return 1
        fi
        _ok "${_case}" "using the candidate already queued on slot ${target} (--installed)"
    elif [ -z "${payload}" ]; then
        _gap "${_case}" "no --payload given and --installed is not set" \
            "scripts/device/recovery-probe.sh --case R1 --payload /tmp/n5105-ab-25.12.2-upgrade.tar"
        CASE_STATUS=GAP
        return 1
    fi

    if [ "${armed}" != "1" ]; then
        if ! dev_push "${payload}" /tmp/ab-recovery-candidate.tar >/dev/null 2>&1; then
            _gap "${_case}" "could not push ${payload} to the machine" "ls -l ${payload}"
            CASE_STATUS=GAP
            return 1
        fi
        install_out=$(dev_ssh 'ab-upgrade /tmp/ab-recovery-candidate.tar' 2>&1)
        install_rc=$?
        printf '%s\n' "${install_out}" | sed 's/^/  | /' >&2
        # A machine whose running slot already carries this release refuses the same payload
        # with exit 74 payload-already-installed. That refusal is matrix.sh M5's judgement,
        # not R1's: R1 is about what the candidate's *first boot* does, so the candidate still
        # has to be laid into the other slot. `--installed` is not the alternative here - it
        # needs a candidate already queued, and in a full run every phase before recovery
        # either commits or abandons its slot, so nothing is pending by the time this runs.
        # The second attempt is `ab-upgrade --force`, which the refusal itself names as the
        # next step ("Next: ab-upgrade --force to reinstall the version this slot already
        # runs"). Without it, handing R1 the round's own payload would turn the round's most
        # important rollback row into a red line against a machine that is perfectly healthy.
        if [ "${install_rc}" -eq 74 ] &&
            [ "$(printf '%s\n' "${install_out}" | sed -n 's/^ab-upgrade: refused, reason=//p' | head -n 1)" = "payload-already-installed" ]; then
            printf 'note [%s] the running slot already carries this release; laying the candidate down with --force so R1 can judge the rollback (the refusal belongs to M5)\n' \
                "${_case}"
            ev "R1: plain install refused with payload-already-installed; retrying with --force"
            install_out=$(dev_ssh 'ab-upgrade --force /tmp/ab-recovery-candidate.tar' 2>&1)
            install_rc=$?
            printf '%s\n' "${install_out}" | sed 's/^/  | /' >&2
            install_mode="force"
        fi
        if [ "${install_rc}" -ne 0 ]; then
            reason=$(printf '%s\n' "${install_out}" | grep -E '^ab-upgrade: refused, reason=' | head -n 1 | sed 's/.*reason=//')
            if [ "${install_rc}" -eq 74 ]; then
                # This is matrix.sh M7's path: nothing was written, so there is no candidate
                # to fail and nothing for ac-11's first clause to be read from.
                _fail "${_case}" \
                    "the payload was refused before anything was written (reason=${reason:-unknown}); that is M7's path, not ac-11's" \
                    "scripts/device/matrix.sh --case M7   # then hand R1 an installable payload"
            else
                _fail "${_case}" "ab-upgrade exited ${install_rc} installing the candidate" \
                    "ab-upgrade /tmp/ab-recovery-candidate.tar; ab-slot log"
            fi
            CASE_STATUS=FAIL
            return 1
        fi
        installed_line=$(printf '%s\n' "${install_out}" | grep -E '^ab-upgrade: installed ' | head -n 1)
        target=$(printf '%s\n' "${installed_line}" | sed -n 's/.*into slot \([ab]\).*/\1/p')
        if [ "${install_mode}" = "force" ]; then
            _ok "${_case}" "candidate installed into slot ${target:-?} with --force (slot ${before_slot} already carried it)"
        else
            _ok "${_case}" "candidate installed into slot ${target:-?}"
        fi
        if [ -z "${target}" ] || [ "${target}" = "${before_slot}" ]; then
            _fail "${_case}" "the candidate did not go into a slot other than the running one (${before_slot})" \
                "ab-slot status"
            CASE_STATUS=FAIL
            return 1
        fi
    fi

    pending=$(dev_status_field pending 2>/dev/null) || pending=""
    _assert_eq "${_case}" "pending" "${pending}" "${target}" \
        "ab-slot status   # an armed candidate is what the next boot tries"
    committed_now=$(dev_status_field committed 2>/dev/null) || committed_now=""
    _assert_eq "${_case}" "committed_before_reboot" "${committed_now}" "${before_committed}" "ab-slot status"

    # The injection: the candidate's layer is a snapshot of the running one, so it is a path
    # under the writable partition and needs no mount.
    injected=""
    upper=$(dev_slot_upper "${target}" 2>/dev/null) || upper=""
    if [ "${inject}" = "none" ]; then
        injected=none
        _ok "${_case}" "no injection: the candidate is expected to fail its own health check (--inject none)"
    elif [ -z "${upper}" ]; then
        _gap "${_case}" "state records no writable layer for slot ${target}, so nothing could be injected" \
            "cat ${AB_STATE_PATH}"
    elif ! push_inject_helper; then
        _gap "${_case}" "could not push the injection helper to the machine" "ab-slot status"
    else
        layer="${AB_P4_MOUNT}/${upper}"
        set_out=$(dev_ssh "sh ${INJECT_CMD} set '${layer}'" 2>&1) || set_out="reason=helper-failed ${set_out}"
        printf '%s\n' "${set_out}" | sed 's/^/  | /' >&2
        case "${set_out}" in
            *after=ab-inject-none0*)
                injected=${layer}
                _ok "${_case}" "injected: $(printf '%s' "${set_out}" | tr '\n' ' ')"
                ;;
            *)
                _gap "${_case}" "the candidate's network config could not be broken (${set_out:-no output})" \
                    "scripts/device/recovery-probe.sh --case R1 --installed --inject none   # with an operator-made bad payload"
                ;;
        esac
    fi
    if [ "${CASE_GAPS}" -gt 0 ]; then
        # The candidate is armed and nothing will be rebooted into it, which is the one
        # state this script must not leave behind silently.
        printf 'note [%s] slot %s is still pending; clear it with: ab-slot abandon\n' "${_case}" "${target}"
        CASE_STATUS=GAP
        CASE_NOTE="injection could not be established; slot ${target} left pending"
        return 1
    fi

    # Two boots happen under this wait: the candidate's, which fails and reboots, and the
    # committed slot's, which is the one that answers. The hard cap budgets both.
    ev "R1: rebooting into candidate ${target}, expecting the health check to fail"
    dev_reboot >/dev/null 2>&1
    if ! dev_wait_up "${AB_WAIT_UP_HARD}"; then
        _fail "${_case}" "the machine did not answer ssh after the candidate boot" \
            "physical console: the candidate did not roll back, so it is hung (PRD risk 4)"
        CASE_STATUS=FAIL
        restore_injection "${injected}"
        return 1
    fi
    _ok "${_case}" "ssh answers again after the failed candidate boot"
    dev_wait_settled >/dev/null 2>&1

    if hit=$(boot_mark_find 'stage=abandon .*action=reboot-to-committed'); then
        _ok "${_case}" "ring log records the rollback: ${hit}"
    else
        _fail "${_case}" "no 'stage=abandon ... action=reboot-to-committed' line in the ring log" \
            "ab-slot log; ab-slot log --prev"
    fi
    # What the probe said: a reader has to be able to tell a health check that failed from a
    # boot that never got that far.
    if why=$(boot_mark_find 'probe=.*result=fail'); then
        _ok "${_case}" "reason the candidate was abandoned: ${why}"
    else
        printf 'note [%s] the ring log carries no probe failure line; look for stage=preflight\n' "${_case}"
    fi

    after_status=$(dev_status 2>/dev/null) || after_status=""
    _assert_eq "${_case}" "committed_after" "$(_field "${after_status}" committed)" "${before_committed}" \
        "ab-slot status   # a candidate that fails must not move the committed slot"
    _assert_eq "${_case}" "pending_after" "$(_field "${after_status}" pending)" "none" "ab-slot status"
    _assert_eq "${_case}" "slot_after" "$(_field "${after_status}" slot)" "${before_committed}" \
        "ab-slot status   # the machine has to be running the slot it was on"
    # An abandon is not a commit, but it does write the ESP counter (measured: 7 -> 8 on
    # 2026-11-15). The invariant is "the committed slot did not move and the counter did not
    # jump by more than the one abandon write", not "the generation is frozen".
    after_generation=$(_field "${after_status}" generation)
    case "${after_generation}" in
        '' | *[!0-9]*)
            _fail "${_case}" "generation_after is not a number (${after_generation:-empty})" \
                "ab-slot status"
            ;;
        *)
            if [ "${after_generation}" -ge "${before_generation}" ] &&
                [ "${after_generation}" -le "$((before_generation + 1))" ]; then
                _ok "${_case}" "generation ${before_generation} -> ${after_generation} (an abandon may write the ESP counter once)"
            else
                _fail "${_case}" \
                    "generation moved ${before_generation} -> ${after_generation}; an abandon may advance it by at most one" \
                    "ab-slot status; ab-slot log --prev"
            fi
            ;;
    esac
    after_version=$(dev_running_version 2>/dev/null) || after_version=""
    _assert_eq "${_case}" "rootfs_after" "${after_version}" "${before_version}" "ab-slot rootfs"
    _assert_eq "${_case}" "markers_after" "$(marker_read)" "${before_markers}" \
        "cat ${AB_MARKER_PATH}; ${AB_CONFIG_MARKER_CMD}"

    restore_injection "${injected}"
    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi
    CASE_NOTE="candidate ${target} abandoned, machine back on ${before_committed} running ${before_version:-?}${install_mode:+ (installed with --force: the running slot already carried it)}"
    CASE_STATUS=PASS
    return 0
}

# --------------------------------------------------------------------------- #
# B1: ab-slot rollback, and the user's state is still there afterwards
# --------------------------------------------------------------------------- #

run_rollback() {
    _case=B1

    if [ "${DRY_RUN}" = "1" ]; then
        printf '%s 1/6 ab-slot rollback (committed moves to the other slot, pending stays none)\n' "${_case}"
        printf '%s 2/6 expect "rolled back from slot <from> to slot <to>" and pending=none\n' "${_case}"
        printf '%s 3/6 expect packages_reason is not other-slot (packages_record_retarget)\n' "${_case}"
        printf '%s 4/6 reboot, wait for 22, wait for boot=ok pending=none\n' "${_case}"
        printf '%s 5/6 expect slot=committed=<the other slot>\n' "${_case}"
        printf '%s 6/6 expect the data marker and the hostname from before the rollback\n' "${_case}"
        CASE_NOTE="dry-run"
        CASE_STATUS=PASS
        return 0
    fi

    require_machine "${_case}" none || {
        CASE_STATUS=GAP
        return 1
    }
    before_committed=$(_field "${STATUS_LINE}" committed)
    before_generation=$(_field "${STATUS_LINE}" generation)
    before_packages=$(_field "${STATUS_LINE}" packages)
    before_packages_reason=$(_field "${STATUS_LINE}" packages_reason)
    before_markers=$(marker_read)
    start_version=$(dev_running_version 2>/dev/null) || start_version=""

    case "${before_committed}" in
        a | b) : ;;
        *)
            _gap "${_case}" "no committed slot to roll back from (committed=${before_committed:-?})" "ab-slot status"
            CASE_STATUS=GAP
            return 1
            ;;
    esac
    target=$(other_slot "${before_committed}")

    # Without a marker, "the data is still there" has nothing to be measured against: an
    # empty value before and an empty value after compare equal and prove nothing.
    case "${before_markers}" in
        data=none*)
            _gap "${_case}" "no data marker on ${AB_MARKER_PATH}, so 'the data survived' cannot be measured" \
                "printf 'created-by-ab-matrix\\n' > ${AB_MARKER_PATH}"
            CASE_STATUS=GAP
            return 1
            ;;
    esac

    roll_out=$(dev_ssh 'ab-slot rollback' 2>&1)
    roll_rc=$?
    printf '%s\n' "${roll_out}" | sed 's/^/  | /' >&2
    if [ "${roll_rc}" -ne 0 ]; then
        _fail "${_case}" "ab-slot rollback exited ${roll_rc}" "ab-slot status; ab-slot rollback"
        CASE_STATUS=FAIL
        return 1
    fi
    if printf '%s\n' "${roll_out}" | grep -q "rolled back from slot ${before_committed} to slot ${target}"; then
        _ok "${_case}" "ab-slot rollback moved committed ${before_committed} -> ${target}"
    else
        _fail "${_case}" "ab-slot rollback did not report the move it was asked for" "ab-slot status"
    fi

    after_roll=$(dev_status 2>/dev/null) || after_roll=""
    _assert_eq "${_case}" "committed" "$(_field "${after_roll}" committed)" "${target}" "ab-slot status"
    _assert_eq "${_case}" "pending" "$(_field "${after_roll}" pending)" "none" "ab-slot status"
    _assert_eq "${_case}" "generation" "$(_field "${after_roll}" generation)" "${before_generation}" \
        "ab-slot status   # a rollback moves the pointer, it is not a new generation"
    # ac-10 says the packages are still there; the machine-readable part of that is the
    # package verdict, which must not be left describing the slot that is no longer committed.
    if [ "$(_field "${after_roll}" packages_reason)" = "other-slot" ]; then
        _fail "${_case}" "packages= still describes the other slot after the rollback (reason=other-slot)" \
            "ab-slot status   # cmd_rollback is supposed to re-target the verdict"
    else
        _ok "${_case}" "packages=$(_field "${after_roll}" packages) reason=$(_field "${after_roll}" packages_reason) (before ${before_packages}/${before_packages_reason})"
    fi

    dev_reboot >/dev/null 2>&1
    if ! dev_wait_up_after after-install; then
        _fail "${_case}" "the machine did not answer ssh after the rollback boot" \
            "physical console: a rolled-back slot that does not boot needs the other one, see docs/install.md"
        CASE_STATUS=FAIL
        return 1
    fi
    settled=$(dev_wait_settled 2>/dev/null) || settled=""
    if [ -z "${settled}" ]; then
        _fail "${_case}" "the machine answered ssh but never settled after the rollback" "ab-slot status"
        CASE_STATUS=FAIL
        return 1
    fi
    _assert_eq "${_case}" "slot_after" "$(_field "${settled}" slot)" "${target}" "ab-slot status"
    _assert_eq "${_case}" "committed_after" "$(_field "${settled}" committed)" "${target}" "ab-slot status"
    _assert_eq "${_case}" "boot_after" "$(_field "${settled}" boot)" "ok" "ab-slot log"
    _assert_eq "${_case}" "esp_after" "$(_field "${settled}" esp)" "ok" "ab-slot log"

    after_version=$(dev_running_version 2>/dev/null) || after_version=""
    if [ -n "${start_version}" ] && [ "${after_version}" = "${start_version}" ]; then
        printf 'note [%s] both slots run rootfs %s, so the version says nothing here; slot=%s does\n' \
            "${_case}" "${after_version}" "${target}"
    else
        _ok "${_case}" "rootfs went ${start_version:-?} -> ${after_version:-?}"
    fi
    _assert_eq "${_case}" "markers_after" "$(marker_read)" "${before_markers}" \
        "cat ${AB_MARKER_PATH}; ${AB_CONFIG_MARKER_CMD}"

    if [ "${CASE_FAILURES}" -gt 0 ]; then
        CASE_STATUS=FAIL
        return 1
    fi
    CASE_NOTE="rolled back ${before_committed} -> ${target} (rootfs ${after_version:-?}), markers unchanged"
    CASE_STATUS=PASS
    return 0
}

run_case() {
    _case=$1
    CASE_CHECKS=0
    CASE_FAILURES=0
    CASE_GAPS=0
    CASE_STATUS=""
    CASE_NOTE=""
    case "${_case}" in
        R1) run_bad_version ;;
        B1) run_rollback ;;
        *)
            CASE_NOTE="unknown case"
            return 2
            ;;
    esac
    _rc=$?
    _status=${CASE_STATUS:-FAIL}
    if [ "${DRY_RUN}" = "1" ]; then
        # A planner reached no verdict, so it writes no row: the results file is what the
        # Lead reads as evidence, and a PASS in it has to mean a run happened.
        printf '== %s %s %s\n' "${_case}" "${_status}" "${CASE_NOTE:-dry-run}"
        return "${_rc}"
    fi
    mkdir -p "$(dirname "${AB_RECOVERY_RESULTS}")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\tchecks=%s failures=%s gaps=%s\n' \
        "${_case}" "${_status}" "${AB_HOST}" "${CASE_NOTE}" \
        "${CASE_CHECKS}" "${CASE_FAILURES}" "${CASE_GAPS}" >>"${AB_RECOVERY_RESULTS}"
    printf '== %s %s %s\n' "${_case}" "${_status}" "${CASE_NOTE}"
    return "${_rc}"
}

if [ "${DRY_RUN}" = "1" ]; then
    printf 'recovery-probe.sh: dry run, cases=%s inject=%s payload=%s\n' \
        "${CASES}" "${inject}" "${payload:-none}"
    ev "recovery-probe dry-run cases=${CASES} inject=${inject}"
fi

_rc_all=0
for _case in ${CASES}; do
    run_case "${_case}" || _rc_all=1
done

if [ "${DRY_RUN}" = "1" ]; then
    # Nothing was asserted against a machine, so nothing is claimed about one.
    printf 'recovery-probe result=dry-run checks=0 failed=0 gaps=0\n'
    exit 0
fi
if [ "${FAILURES}" -gt 0 ]; then
    printf 'recovery-probe result=fail checks=%s failed=%s gaps=%s\n' "${CHECKS}" "${FAILURES}" "${GAPS}"
    exit 1
fi
if [ "${GAPS}" -gt 0 ]; then
    printf 'recovery-probe result=gap checks=%s failed=0 gaps=%s\n' "${CHECKS}" "${GAPS}"
    exit 3
fi
printf 'recovery-probe result=pass checks=%s failed=0 gaps=0\n' "${CHECKS}"
exit 0
