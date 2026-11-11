#!/bin/sh
# Device driver primitives: one ssh call, one status line, one verdict.
#
# Sourced by scripts/device/*.sh, and by tests/modules/device/* with a stub `ssh`
# on PATH, so nothing in here may decide to reach a machine by itself.
#
#   . scripts/device/lib.sh
#   dev_status                                 # one machine readable line
#   dev_push payload.tar /tmp/payload.tar      # stdin pipe, the guest has no sftp
#   dev_install /tmp/payload.tar               # ab-upgrade
#   dev_reboot; dev_wait_up_after after-install
#   dev_collect_optional /boot/ab/log/boot-1.log ./boot-1.log
#   assert_field boot ok M1
#   assert_boot_log M1 25.12.2
#   assert_layer_invariant M1
#
# Every function returns non-zero on failure and prints a line that can be pasted
# back into a shell: the reader of a red matrix row is a person with one device.
#
# The library never writes ab/state.json. Slot state moves only through ab-slot and
# ab-upgrade, which own the lock and the ESP.

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #

# A caller that sources this file from another directory has to say where the repo
# is; the scripts under scripts/device/ derive it from their own path.
: "${AB_REPO_ROOT:=$PWD}"

AB_HOST=${AB_HOST:-root@192.168.2.49}
# The key lives in the earlier real-device task's scratch directory: it is the one
# key the machine already trusts, and it is reachable without touching ~/.ssh.
AB_KEY=${AB_KEY:-${AB_REPO_ROOT}/.workflow/tasks/20261111-04-real-device-functional-validation/scratch/abkey}
AB_SSH_CONNECT_TIMEOUT=${AB_SSH_CONNECT_TIMEOUT:-8}

AB_REMOTE_TMP=${AB_REMOTE_TMP:-/tmp}
AB_P4_MOUNT=${AB_P4_MOUNT:-/mnt/p4}
AB_STATE_PATH=${AB_STATE_PATH:-/boot/ab/state.json}
# Markers that prove the user's state survived the transaction. The data marker is a
# file on the shared partition; the config marker is read, not written, so asserting
# on it cannot itself change what is being measured.
AB_MARKER_PATH=${AB_MARKER_PATH:-/data/ab-matrix.marker}
AB_CONFIG_MARKER_CMD=${AB_CONFIG_MARKER_CMD:-uci get system.@system[0].hostname}
# A hint only, never an assertion. A version installed twice gets a suffixed layer
# (@overlay-25.12.2-r2, measured), so the steady state is "as many layers as the slots
# name", not a fixed number.
AB_LAYER_COUNT=${AB_LAYER_COUNT:-2}

# Boot budgets, from the measured start-up of the reference machine (device-facts.md §8):
# boot point 22:19:54, last healthcheck write 22:20:04, and dropbear listening before
# the healthcheck finishes, so ssh answers about 8-10 s after a reboot. The budgets are
# multiples of that measurement, not a guess at the worst case: 120 s is 12x, 180 s is
# 18x for the first boot of a new rootfs (that boot also writes the ESP, runs
# btrfs-check and runs gc), and 200 s (40 x 5 s) is the hard cap at which the machine
# is recorded as offline.
AB_WAIT_UP=${AB_WAIT_UP:-120}
AB_WAIT_UP_FIRST=${AB_WAIT_UP_FIRST:-180}
AB_WAIT_UP_HARD=${AB_WAIT_UP_HARD:-200}
AB_POLL_INTERVAL=${AB_POLL_INTERVAL:-5}
# What is left of the hard cap once ssh has answered, for the commit to land. One whole
# boot is bounded by AB_WAIT_UP_HARD, so this is a remainder and not a fourth budget:
# wait_up may have spent AB_WAIT_UP_FIRST of it, and the settle poll spends the rest.
AB_WAIT_SETTLE=$(( AB_WAIT_UP_HARD - AB_WAIT_UP_FIRST ))
[ "${AB_WAIT_SETTLE}" -ge "${AB_POLL_INTERVAL}" ] || AB_WAIT_SETTLE=${AB_POLL_INTERVAL}

# The boot ring log. boot-0.log belongs to the current boot and boot-1.log to the one
# before it, and the ring rotates: the breadcrumb of the boot that committed is not
# always in boot-0.log (measured: stage=mark only ever appears in boot-1.log/boot-2.log)
# while the current boot's stage=commit is. Every reader therefore searches both files
# and only then falls back to `ab-slot log --prev`.
AB_BOOT_LOG=${AB_BOOT_LOG:-/boot/ab/log/boot-0.log}
AB_BOOT_LOG_PREV=${AB_BOOT_LOG_PREV:-/boot/ab/log/boot-1.log}
AB_PREV_LOG_CMD=${AB_PREV_LOG_CMD:-ab-slot log --prev}
# Local copies of those two files for the hop under test; empty means "not collected",
# which is normal for boot-1.log on a machine that has only booted once.
AB_BOOT_LOG_LOCAL=${AB_BOOT_LOG_LOCAL:-}
AB_BOOT_LOG_PREV_LOCAL=${AB_BOOT_LOG_PREV_LOCAL:-}

AB_RESULTS=${AB_RESULTS:-results.tsv}
AB_ASSERT_FAILURES=0

# --------------------------------------------------------------------------- #
# ssh
# --------------------------------------------------------------------------- #

# dev_ssh <cmd...>: run one command on the device.
#
#   ControlMaster=no, ControlPath=none  a multiplexed master outlives a reboot and
#                                       then reports the machine as unreachable; the
#                                       sandbox also cannot create ~/.ssh/sockets
#   BatchMode=yes                       a missing or wrong key must fail, not prompt
#   StrictHostKeyChecking=no,
#   UserKnownHostsFile=/dev/null        every flash regenerates the host key, so a
#                                       remembered key would refuse a healthy machine
#   IdentitiesOnly=yes                  only the key given here is offered
#
# AB_DRY_RUN=1 makes the whole driver inert: planner code paths can then be walked
# without a single packet leaving the host.
dev_ssh() {
    if [ "${AB_DRY_RUN:-0}" = "1" ]; then
        printf 'dry-run: ssh %s %s\n' "${AB_HOST}" "$*" >&2
        return 0
    fi
    ssh -i "${AB_KEY}" \
        -o IdentitiesOnly=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
        "${AB_HOST}" "$@"
}

# dev_wait_up <timeout_s>: poll until the machine answers ssh again.
# One short try per interval and no per-try logging: a rebooting machine produces
# dozens of failed attempts, and each of them would otherwise land in the report.
# The hard cap is applied here, so no caller can wait past AB_WAIT_UP_HARD by passing a
# larger number: that cap is the point where the machine is treated as offline.
dev_wait_up() {
    _timeout=${1:-${AB_WAIT_UP}}
    [ "${_timeout}" -le "${AB_WAIT_UP_HARD}" ] || _timeout=${AB_WAIT_UP_HARD}
    _tries=$(( _timeout / AB_POLL_INTERVAL ))
    [ "${_tries}" -ge 1 ] || _tries=1
    for _i in $(seq 1 "${_tries}"); do
        sleep "${AB_POLL_INTERVAL}"
        dev_ssh true >/dev/null 2>&1 && return 0
    done
    return 1
}

# dev_wait_up_after <plain|after-install>: wait with the budget the boot at hand needs.
dev_wait_up_after() {
    case "${1:-plain}" in
        after-install) dev_wait_up "${AB_WAIT_UP_FIRST}" ;;
        *) dev_wait_up "${AB_WAIT_UP}" ;;
    esac
}

# dev_wait_settled: the status line of a boot that finished its healthcheck and commit.
# wait_up returns as soon as dropbear answers, which is before the initramfs has written
# the commit line (measured: ssh at ~8-10 s, commit at ~10 s). Asserting on that first
# line would report a healthy machine as red, and would collect a boot log that is still
# being written, so the hop waits for boot=ok pending=none first. It prints the last line
# it saw even when it never settled: the field assertions then say which field is red,
# which is a better verdict than a bare "did not settle".
dev_wait_settled() {
    _timeout=${1:-${AB_WAIT_SETTLE}}
    [ "${_timeout}" -le "${AB_WAIT_UP_HARD}" ] || _timeout=${AB_WAIT_UP_HARD}
    _tries=$(( _timeout / AB_POLL_INTERVAL ))
    [ "${_tries}" -ge 1 ] || _tries=1
    _line=""
    _i=0
    while [ "${_i}" -lt "${_tries}" ]; do
        _i=$((_i + 1))
        _line=$(dev_status) || _line=""
        if [ -n "${_line}" ]; then
            _boot=$(status_field "${_line}" boot) || _boot=""
            _pending=$(status_field "${_line}" pending) || _pending=""
            [ "${_boot}" = "ok" ] && [ "${_pending}" = "none" ] && break
        fi
        [ "${_i}" -lt "${_tries}" ] || break
        sleep "${AB_POLL_INTERVAL}"
    done
    [ -n "${_line}" ] || return 1
    printf '%s\n' "${_line}"
}

# --------------------------------------------------------------------------- #
# Status
# --------------------------------------------------------------------------- #

# status_field <status_line> <field>: value of one `field=value` token.
# Pure string work, so a caller can capture ab-slot status once and assert many
# times without paying for an ssh round trip per field.
status_field() {
    _line=${1:-}
    _field=${2:-}
    case "${_field}" in
        "" | *[!a-z0-9_]*) return 2 ;;
    esac
    _value=$(printf '%s\n' "${_line}" | tr ' ' '\n' | sed -n "s/^${_field}=//p" | head -n 1)
    [ -n "${_value}" ] || return 1
    printf '%s\n' "${_value}"
}

# dev_status: the machine readable line of ab-slot status.
# The human summary there goes to stderr on purpose; only the first line counts.
dev_status() {
    _out=$(dev_ssh 'ab-slot status' 2>/dev/null) || return 1
    _line=$(printf '%s\n' "${_out}" | head -n 1)
    [ -n "${_line}" ] || return 1
    printf '%s\n' "${_line}"
}

# dev_status_field <field>: one field, fetched now.
dev_status_field() {
    _line=$(dev_status) || return 1
    status_field "${_line}" "${1:?dev_status_field needs a field}"
}

# dev_running_version: the upstream version the running slot records.
# Positioning a case reads this instead of the layer name, because a repeated version
# gets a suffixed layer (`@overlay-25.12.1-r2`) that no version comparison should see.
dev_running_version() {
    _value=$(dev_ssh 'ab-slot rootfs' 2>/dev/null) || return 1
    _value=$(printf '%s\n' "${_value}" | head -n 1)
    [ -n "${_value}" ] || return 1
    printf '%s\n' "${_value}"
}

# dev_layers: every @overlay-* subvolume on the writable partition, space separated.
# The list is what exists; which of them count as referenced is a question for the two
# slots' recorded uppers (dev_slot_upper), not for the length of this list.
dev_layers() {
    dev_ssh "btrfs subvolume list ${AB_P4_MOUNT}" 2>/dev/null \
        | sed -n 's/.* path //p' \
        | grep '^@overlay-' \
        | sort \
        | tr '\n' ' '
}

# dev_slot_upper <a|b>: the writable layer one slot records.
# `ab-slot status` names only the running slot's layer, while the layer invariant is
# about both slots, so the other one is read from the state file — read-only, through
# cat, and never rewritten here.
dev_slot_upper() {
    _slot=${1:?dev_slot_upper needs a slot}
    case "${_slot}" in
        a | b) : ;;
        *) return 2 ;;
    esac
    _json=$(dev_ssh "cat ${AB_STATE_PATH}" 2>/dev/null) || return 1
    _value=$(printf '%s' "${_json}" | tr '\n' ' ' \
        | sed -n "s/.*\"${_slot}\": *{[^}]*\"upper\": *\"\([^\"]*\)\".*/\1/p")
    [ -n "${_value}" ] || return 1
    printf '%s\n' "${_value}"
}

# dev_layer_state: fill AB_LAYERS, AB_UPPER_A and AB_UPPER_B for assert_layer_invariant.
dev_layer_state() {
    AB_LAYERS=$(dev_layers) || AB_LAYERS=""
    AB_UPPER_A=$(dev_slot_upper a) || AB_UPPER_A=""
    AB_UPPER_B=$(dev_slot_upper b) || AB_UPPER_B=""
}

# dev_cleanup_slot_mounts: unmount what an earlier --check left behind.
# ab-upgrade --check is not read-only: before it exits 0 it publishes ab/conflicts.log on
# the ESP and may mount p2/p3 under /mnt/slots/<slot> without unmounting them (measured).
# The hop therefore starts from a clean slate, and the evidence records that it did.
# Nothing asserts those mounts are absent afterwards, because they legitimately appear.
dev_cleanup_slot_mounts() {
    dev_ssh 'for d in /mnt/slots/a /mnt/slots/b; do umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null || true; done; ls /mnt/slots 2>/dev/null || true; true'
}

# dev_marker_read / dev_marker_init: token on the shared partition.
# The file is only created when missing, so every later case measures a value that
# was written in a different run rather than one written right before the assertion.
dev_marker_read() {
    dev_ssh "cat ${AB_MARKER_PATH}" 2>/dev/null | head -n 1
}

dev_marker_init() {
    _have=$(dev_marker_read)
    [ -n "${_have}" ] && return 0
    dev_ssh "printf '%s\n' 'created-by-ab-matrix-$(dev_stamp)' > ${AB_MARKER_PATH}"
}

# dev_config_marker: a value the user (or bring-up) put in /etc/config.
# Read-only: the point is to notice that the next rootfs changed or dropped it.
dev_config_marker() {
    _value=$(dev_ssh "${AB_CONFIG_MARKER_CMD}" 2>/dev/null) || _value=""
    printf '%s\n' "${_value:-unknown}"
}

# --------------------------------------------------------------------------- #
# Transfer and transactions
# --------------------------------------------------------------------------- #

# dev_push <local> <remote>: copy a file to the device.
# The guest image carries no sftp-server, so scp fails with a protocol error;
# a stdin pipe through `cat` needs nothing but the shell already there.
dev_push() {
    _local=${1:?dev_push needs a local path}
    _remote=${2:?dev_push needs a remote path}
    if [ ! -f "${_local}" ]; then
        printf 'dev_push: no such file: %s\n' "${_local}" >&2
        return 1
    fi
    cat "${_local}" | dev_ssh "cat > ${_remote}"
}

# dev_collect <remote_path> <local_path>: pull a file back the same way.
dev_collect() {
    _remote=${1:?dev_collect needs a remote path}
    _local=${2:?dev_collect needs a local path}
    mkdir -p "$(dirname "${_local}")" || return 1
    if dev_ssh "cat ${_remote}" >"${_local}" 2>/dev/null; then
        return 0
    fi
    rm -f "${_local}"
    return 1
}

# dev_collect_optional <remote_path> <local_path>: pull a file that may not exist.
# boot-1.log is normal to be missing on a machine that booted once, so a missing ring
# log is recorded and not treated as a failed step.
dev_collect_optional() {
    dev_collect "${1:?dev_collect_optional needs a remote path}" \
        "${2:?dev_collect_optional needs a local path}"
}

# dev_ab_check <payload>: validate only. Exit 74 is the documented pre-write refusal,
# which is the pass condition for a bad payload. "Pre-write" is about slot state, not
# about the ESP: a --check that exits 0 has already published ab/conflicts.log and may
# have left p2/p3 mounted under /mnt/slots/<slot> (measured). Nothing here asserts the
# ESP is unchanged; the matrix only asserts that slot state is, and it unmounts
# /mnt/slots/* before it validates (dev_cleanup_slot_mounts).
dev_ab_check() {
    dev_ssh "ab-upgrade --check ${1:?dev_ab_check needs a payload path}"
}

# dev_install <payload>: write the inactive slot and mark it pending.
dev_install() {
    dev_ssh "ab-upgrade ${1:?dev_install needs a payload path}"
}

# dev_reboot: reboot and do not wait for the answer.
# The kernel closes the session under us, so a non-zero status here means "the
# machine went away", which is what a reboot looks like from the outside.
dev_reboot() {
    dev_ssh 'sync; reboot' >/dev/null 2>&1
    return 0
}

# --------------------------------------------------------------------------- #
# Evidence
# --------------------------------------------------------------------------- #

dev_stamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ev <text>: append one timestamped line to the open evidence log.
ev() {
    [ -n "${AB_EVIDENCE_LOG:-}" ] || return 0
    printf '%s %s\n' "$(dev_stamp)" "$*" >>"${AB_EVIDENCE_LOG}"
}

# dev_capture <evidence|-> <command...>: run a host-side driver function, keep its
# output in the evidence log together with the exit status, still print it.
dev_capture() {
    _ev=${1:-}
    [ "${_ev}" = "-" ] && _ev=""
    shift
    _out=$("$@" 2>&1)
    _rc=$?
    if [ -n "${_ev}" ]; then
        {
            printf '### %s :: %s\n' "$(dev_stamp)" "$*"
            printf '%s\n' "${_out}"
            printf '### exit=%s\n' "${_rc}"
        } >>"${_ev}"
    fi
    printf '%s\n' "${_out}"
    return "${_rc}"
}

# --------------------------------------------------------------------------- #
# Assertions
# --------------------------------------------------------------------------- #

# The failure line is the deliverable: field, expected, actual, the status line it
# came from, and the command that reproduces it.
_dev_assert_fail() { # <case> <message>
    AB_ASSERT_FAILURES=$((AB_ASSERT_FAILURES + 1))
    printf 'FAIL %s %s\n' "${1:--}" "${2:-assertion failed}"
    printf '  status: %s\n' "${AB_STATUS_LINE:-unknown}"
    printf '  evidence: %s\n' "${AB_EVIDENCE_LOG:-none}"
    printf '  rerun: %s\n' "${AB_MATRIX_CMD:-./scripts/device/matrix.sh --case ${1:--}}"
    ev "FAIL ${1:--} ${2:-assertion failed}"
}

# assert_field <field> <expected> <case>: a field of the captured status line.
assert_field() {
    _field=${1:?assert_field needs a field}
    _want=${2?assert_field needs an expected value}
    _case=${3:-?}
    if [ -z "${AB_STATUS_LINE:-}" ]; then
        if ! AB_STATUS_LINE=$(dev_status); then
            AB_STATUS_LINE=""
            _dev_assert_fail "${_case}" "assert_field ${_field}: ab-slot status unreadable"
            return 1
        fi
    fi
    _got=$(status_field "${AB_STATUS_LINE}" "${_field}") || _got=missing
    [ "${_got}" = "${_want}" ] && return 0
    _dev_assert_fail "${_case}" "assert_field ${_field}: expected=${_want} got=${_got}"
    return 1
}

# assert_value <actual> <expected> <case> <label>
# Named this way, not assert_eq: the test framework in tests/lib/assert.sh already owns
# that name, and a sourced library that shadows it silently turns a failing test green.
assert_value() {
    _actual=${1-}
    _want=${2-}
    _case=${3:-?}
    _label=${4:-value}
    [ "${_actual}" = "${_want}" ] && return 0
    _dev_assert_fail "${_case}" "assert_value ${_label}: expected=${_want} got=${_actual}"
    return 1
}

# assert_ge <actual> <floor> <case> <label>: actual >= floor, integers only.
# generation is the value this exists for: it orders layers and may never go back.
assert_ge() {
    _actual=${1-}
    _floor=${2-}
    _case=${3:-?}
    _label=${4:-value}
    case "${_actual}" in
        "" | *[!0-9]*) _dev_assert_fail "${_case}" "assert_ge ${_label}: not a number: '${_actual}'"; return 1 ;;
    esac
    case "${_floor}" in
        "" | *[!0-9]*) _dev_assert_fail "${_case}" "assert_ge ${_label}: not a number: '${_floor}'"; return 1 ;;
    esac
    [ "${_actual}" -ge "${_floor}" ] && return 0
    _dev_assert_fail "${_case}" "assert_ge ${_label}: expected>=${_floor} got=${_actual}"
    return 1
}

# assert_match <value> <extended regex> <case> <label>
assert_match() {
    _value=${1-}
    _pattern=${2?assert_match needs a pattern}
    _case=${3:-?}
    _label=${4:-value}
    if printf '%s\n' "${_value}" | grep -Eq "${_pattern}"; then
        return 0
    fi
    _dev_assert_fail "${_case}" "assert_match ${_label}: got='${_value}' want=/${_pattern}/"
    return 1
}

# assert_log <file> <extended regex> <case> <label>: a line the boot wrote itself.
# A machine can claim boot=ok; only the breadcrumb shows it reached the commit.
# This one file and no other: for a breadcrumb that the ring log may have rotated away
# from, use assert_boot_mark below.
assert_log() {
    _file=${1:?assert_log needs a file}
    _pattern=${2?assert_log needs a pattern}
    _case=${3:-?}
    _label=${4:-log line}
    if [ ! -f "${_file}" ]; then
        _dev_assert_fail "${_case}" "assert_log ${_label}: no such file: ${_file}"
        return 1
    fi
    if grep -Eq "${_pattern}" "${_file}"; then
        return 0
    fi
    _dev_assert_fail "${_case}" "assert_log ${_label}: /${_pattern}/ not in ${_file}"
    return 1
}

# dev_version_re <version>: the version as an extended regex, dots escaped.
# One definition, because both the layer-name assertion and the commit-line assertion
# depend on 25.12.2 not matching 25x12x2.
dev_version_re() {
    printf '%s' "${1?dev_version_re needs a version}" | sed 's/\./\\./g'
}

# boot_mark_find <extended regex>: where the boot wrote one breadcrumb.
# Prints "<source>: <line>" for the first source that has it, searching boot-0.log, then
# boot-1.log, then `ab-slot log --prev` on the machine. That order is what the ring log
# dictates: boot-0.log carries the current boot's stage=commit, while stage=mark lives
# in the previous boot's file, and a log that is still being written has neither. A
# caller that only ever grepped boot-0.log would report every healthy hop as red.
# The source is named by the remote file, not by the local copy, so a reader of the
# evidence sees the file on the machine and not the name this run happened to give it.
boot_mark_find() {
    _pattern=${1?boot_mark_find needs a pattern}
    for _pair in "${AB_BOOT_LOG_LOCAL}|${AB_BOOT_LOG}" \
        "${AB_BOOT_LOG_PREV_LOCAL}|${AB_BOOT_LOG_PREV}"; do
        _file=${_pair%%|*}
        [ -n "${_file}" ] || continue
        [ -f "${_file}" ] || continue
        _hit=$(grep -E "${_pattern}" "${_file}" 2>/dev/null | tail -n 1)
        [ -n "${_hit}" ] || continue
        printf '%s: %s\n' "$(basename "${_pair#*|}")" "${_hit}"
        return 0
    done
    _hit=$(dev_ssh "${AB_PREV_LOG_CMD}" 2>/dev/null | grep -E "${_pattern}" | tail -n 1)
    [ -n "${_hit}" ] || return 1
    printf '%s: %s\n' "${AB_PREV_LOG_CMD}" "${_hit}"
}

# assert_boot_mark <case> <extended regex> <label>: the breadcrumb exists somewhere the
# ring log can have put it. The evidence records which source answered, because a reader
# of a red row has to tell "the machine wrote nothing" from "the matrix looked in the
# wrong file".
assert_boot_mark() {
    _case=${1:-?}
    _pattern=${2?assert_boot_mark needs a pattern}
    _label=${3:-log line}
    if _hit=$(boot_mark_find "${_pattern}"); then
        ev "boot-mark ${_label}: hit ${_hit}"
        return 0
    fi
    _dev_assert_fail "${_case}" \
        "assert_boot_mark ${_label}: /${_pattern}/ not in ${AB_BOOT_LOG}, not in ${AB_BOOT_LOG_PREV} (collected as ${AB_BOOT_LOG_LOCAL:-none} and ${AB_BOOT_LOG_PREV_LOCAL:-none}), and not in \`${AB_PREV_LOG_CMD}\`"
    return 1
}

# assert_boot_log <case> <version>: the breadcrumbs of the boot that committed.
assert_boot_log() {
    _case=${1:-?}
    _version=${2?assert_boot_log needs a version}
    _v_re=$(dev_version_re "${_version}")
    assert_boot_mark "${_case}" 'stage=healthcheck-done .*result=ok' healthcheck-done || return 1
    assert_boot_mark "${_case}" "stage=commit .*rootfs=${_v_re} .*result=ok action=commit" commit-line || return 1
}

# assert_layer_count <expected> <case>: a hint, not an invariant.
# Kept so a run can say "two layers, as expected" versus "three, because a version was
# installed twice"; never use it as a hard assertion (a suffixed layer -rN is healthy).
assert_layer_count() {
    _want=${1:?assert_layer_count needs a count}
    _case=${2:-?}
    _have=$(printf '%s' "${AB_LAYERS:-}" | wc -w | tr -d ' ')
    [ "${_have}" = "${_want}" ] && return 0
    _dev_assert_fail "${_case}" "assert_layer_count: expected=${_want} got=${_have} layers='${AB_LAYERS:-}'"
    return 1
}

# assert_layer_invariant <case>: the layers on the writable partition are the ones the
# two slots point at, and nothing else.
# A count cannot express this. A version installed twice gets a suffixed layer
# (@overlay-25.12.2-r2, measured on the reference machine), so three or four layers can
# be the steady state while two layers can also be a leak. What must hold instead:
#   * each slot records a layer, and that layer still exists on the partition;
#   * every @overlay-* on the partition is named by one of the two slots.
# Inputs: AB_LAYERS, AB_UPPER_A, AB_UPPER_B (dev_layer_state fills all three). On
# failure the whole layer list and both uppers are printed, because that is the only way
# a reader can tell a leak from a rotation.
assert_layer_invariant() {
    _case=${1:-?}
    _a=${AB_UPPER_A:-}
    _b=${AB_UPPER_B:-}
    _layers=${AB_LAYERS:-}
    _bad=0
    for _slot in a b; do
        case "${_slot}" in
            a) _upper=${_a} ;;
            b) _upper=${_b} ;;
        esac
        case "${_upper}" in
            @overlay-?*) : ;;
            *)
                _dev_assert_fail "${_case}" "assert_layer_invariant: slot ${_slot} records no layer (upper='${_upper}'); uppers='a=${_a} b=${_b}' layers='${_layers}'"
                _bad=1
                continue
                ;;
        esac
        case " ${_layers} " in
            *" ${_upper} "*) : ;;
            *)
                _dev_assert_fail "${_case}" "assert_layer_invariant: slot ${_slot} upper ${_upper} is missing from the partition; uppers='a=${_a} b=${_b}' layers='${_layers}'"
                _bad=1
                ;;
        esac
    done
    for _layer in ${_layers}; do
        case "${_layer}" in
            "${_a}" | "${_b}") continue ;;
        esac
        _dev_assert_fail "${_case}" "assert_layer_invariant: ${_layer} is referenced by no slot, so nothing will ever reclaim it; uppers='a=${_a} b=${_b}' layers='${_layers}'"
        _bad=1
    done
    [ "${_bad}" -eq 0 ] || return 1
    ev "layer-invariant ok: layers='${_layers}' uppers='a=${_a} b=${_b}'"
    return 0
}

# --------------------------------------------------------------------------- #
# Record
# --------------------------------------------------------------------------- #

# record <case> <verdict> <evidence> <note>: one row per case in results.tsv.
# TAB separated and append-only, because the Lead reads this file and nothing else,
# and a rerun must not rewrite what an earlier round saw.
record() {
    _case=${1:?record needs a case}
    _verdict=${2:?record needs a verdict}
    _evidence=${3:--}
    _note=${4:-}
    case "${_verdict}" in
        PASS | FAIL | GAP) : ;;
        *)
            printf 'record: invalid verdict: %s (want PASS, FAIL or GAP)\n' "${_verdict}" >&2
            return 2
            ;;
    esac
    [ -n "${_evidence}" ] || _evidence=-
    _note=$(printf '%s' "${_note}" | tr '\t\n' '  ')
    mkdir -p "$(dirname "${AB_RESULTS}")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "${_case}" "${_verdict}" "${_evidence}" "${_note}" >>"${AB_RESULTS}"
}

# record_passed <case>: the case already has a PASS row, so --resume can skip it.
record_passed() {
    [ -f "${AB_RESULTS}" ] || return 1
    grep -q "^${1}	PASS	" "${AB_RESULTS}"
}
