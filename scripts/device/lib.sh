#!/bin/sh
# Device driver primitives: one ssh call, one status line, one verdict.
#
# Sourced by scripts/device/*.sh, and by tests/modules/device/* with a stub `ssh`
# on PATH, so nothing in here may decide to reach a machine by itself.
#
#   . scripts/device/lib.sh
#   dev_status                                 # one machine readable line
#   dev_ssh_tty 8 'readlink /proc/$$/fd/0'     # interactive: pty, stdin kept open
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
# The key is the project secret (workflow project secret, mode 600, never committed):
# a task's scratch/ directory is not a home for it, because archive does not carry
# scratch along and a default that points there rots silently - every dev_ssh then
# fails as "Permission denied" and dev_wait_up reports it as "machine is down".
AB_KEY=${AB_KEY:-${AB_REPO_ROOT}/.workflow/secrets/n5105-device-ssh-key}
AB_SSH_CONNECT_TIMEOUT=${AB_SSH_CONNECT_TIMEOUT:-8}
# How long dev_ssh_tty keeps the client stdio open, in seconds. It is the session clock of
# an interactive probe: the pty lives exactly as long as this hold, so a probe that needs
# the login shell to print a prompt gives it a few seconds, not a fixed minute.
AB_SSH_TTY_HOLD=${AB_SSH_TTY_HOLD:-8}

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

# The boot ring log. boot-0.log belongs to the current boot, boot-1.log to the one before
# it and boot-2.log to the one before that: ab-boot's rotate_logs keeps exactly three
# generations, deleting boot-2.log before it shifts the other two. A reader that searches
# only two of them can report a healthy hop as silent. That is not hypothetical: the first
# boot of a new base runs the package follow (168 packages measured on this box), and the
# machine can be rebooted again before the commit line of that boot is read, which moves
# the line to boot-2.log. `ab-slot log` has --prev (boot-1) and --upgrade, but no --prev2,
# so the third generation is read by its path.
AB_BOOT_LOG=${AB_BOOT_LOG:-/boot/ab/log/boot-0.log}
AB_BOOT_LOG_PREV=${AB_BOOT_LOG_PREV:-/boot/ab/log/boot-1.log}
AB_BOOT_LOG_PREV2=${AB_BOOT_LOG_PREV2:-/boot/ab/log/boot-2.log}
AB_CURRENT_LOG_CMD=${AB_CURRENT_LOG_CMD:-ab-slot log}
AB_PREV_LOG_CMD=${AB_PREV_LOG_CMD:-ab-slot log --prev}
# The third generation is read by its path, not by a subcommand: `ab-slot log` answers for
# boot-0 and has --prev for boot-1, and there is no --prev2 to invent here. Empty means
# "build it from AB_BOOT_LOG_PREV2 at the moment of the search", so a caller that repoints
# the path also repoints the fallback instead of leaving a stale command behind.
AB_PREV2_LOG_CMD=${AB_PREV2_LOG_CMD:-}
# Local copies of those three files for the hop under test; empty means "not collected",
# which is normal for boot-1.log on a machine that booted once and for boot-2.log on one
# that booted twice.
AB_BOOT_LOG_LOCAL=${AB_BOOT_LOG_LOCAL:-}
AB_BOOT_LOG_PREV_LOCAL=${AB_BOOT_LOG_PREV_LOCAL:-}
AB_BOOT_LOG_PREV2_LOCAL=${AB_BOOT_LOG_PREV2_LOCAL:-}
# A commit breadcrumb is retried, bounded: ab-commit records the decision in ab/state.json
# before it appends the ring line, so a settle poll that watches pending=none can read the
# log a moment too early. The last attempt decides, so a machine that wrote nothing still
# fails.
AB_BOOT_MARK_TRIES=${AB_BOOT_MARK_TRIES:-3}
AB_BOOT_MARK_WAIT=${AB_BOOT_MARK_WAIT:-2}
# A hop reboots the machine and then runs the package follow as a background worker, and a
# sample whose criterion needs a service can be mid-restart while that worker moves packages
# under it. docker is the measured case: on this box its criterion answered `client=yes
# daemon=no` right after a hop whose first boot followed 168 packages, and answered again a
# few minutes later without anything else changing. A failing verify is therefore retried,
# bounded, and the last attempt decides: a service that needed to come back is not reported
# as a broken package, while a package that really stopped working - dropped from the world,
# config hash moved - fails every attempt and still lands red.
# The budget is the measured window, not a guess: 6 x 10 s covers the follow of a first boot
# plus procd's respawn, and each attempt is written into the evidence with the
# `packages=`/`follow=` pair so the next run can tell "still following" from "broken".
AB_FOLLOW_TRIES=${AB_FOLLOW_TRIES:-6}
AB_FOLLOW_WAIT=${AB_FOLLOW_WAIT:-10}

# ab_packages_state <status_line>: `packages=` and `follow=` as one token pair, for evidence.
# The first boot of a new base runs the package follow in a background worker, and a sample
# whose criterion needs one of the packages that follow is moving can fail for as long as the
# worker runs. Recording the pair beside a retry is what lets a reader tell "the probe asked
# while the follow was still running" from "the package did not survive the hop" without
# another device run.
ab_packages_state() {
    _aps_packages=$(status_field "${1:-}" packages) || _aps_packages=unknown
    _aps_follow=$(status_field "${1:-}" follow) || _aps_follow=unknown
    printf 'packages=%s follow=%s\n' "${_aps_packages}" "${_aps_follow}"
}

AB_RESULTS=${AB_RESULTS:-results.tsv}
AB_ASSERT_FAILURES=0

# --------------------------------------------------------------------------- #
# What this project may be tested against
# --------------------------------------------------------------------------- #

# require_supported_line <version> [payload]: the matrix and the scenario driver only run
# the 25.x / apk line. Below major 25 the upstream tree is opkg-era: a different package
# manager, a different firewall model and a different kernel-module layout, so a verdict
# from it says nothing about this project - and `scripts/ci/upstream-watch.sh` already
# refuses to pin anything below 25 for the same reason. The rule is enforced here, in the
# driver, so a 24.x payload is refused before a slot is written instead of failing
# somewhere that looks like a product defect.
#
# When the payload file is there, a second check looks at its shape: an apk-era payload
# carries `platform.tar`, and one without it is refused even if the version string looks
# right. A missing file is not this function's business - callers report GAP themselves.
require_supported_line() {
    _rsl_version=${1:-}
    _rsl_payload=${2:-}
    case "${_rsl_version}" in
        '' | *[!0-9.]*)
            printf 'unsupported payload line: %s is not a version number this matrix can use\n' \
                "${_rsl_version:-empty}"
            return 1
            ;;
    esac
    _rsl_major=${_rsl_version%%.*}
    case "${_rsl_major}" in
        '' | *[!0-9]*)
            printf 'unsupported payload line: %s has no numeric major\n' "${_rsl_version}"
            return 1
            ;;
    esac
    if [ "${_rsl_major}" -lt 25 ]; then
        printf 'unsupported payload line: %s is below 25; this project covers only the 25.x/apk line (24.x and older are opkg-era and out of scope)\n' \
            "${_rsl_version}"
        return 1
    fi
    if [ -n "${_rsl_payload}" ] && [ -f "${_rsl_payload}" ]; then
        # The shape check only speaks for a file that is really a tar: a driver test uses a
        # placeholder where the payload would be, and "not a tar" is a different problem
        # that the installer reports on its own.
        if _rsl_members=$(tar -tf "${_rsl_payload}" 2>/dev/null); then
            if ! printf '%s\n' "${_rsl_members}" | grep -qx 'platform.tar'; then
                printf 'unsupported payload shape: %s carries no platform.tar, so it is not an apk-era payload of this project\n' \
                    "${_rsl_payload}"
                return 1
            fi
        fi
    fi
    printf 'supported payload line: %s\n' "${_rsl_version}"
    return 0
}

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
        -o PreferredAuthentications=publickey \
        -o PubkeyAuthentication=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o "ConnectTimeout=${AB_SSH_CONNECT_TIMEOUT}" \
        "${AB_HOST}" "$@"
}

# dev_ssh_tty <hold_s> <cmd...>: one ssh call over a pty, driven the way a person drives
# it. This is the only form a probe of interactive login may use.
#
#   dev_ssh_tty 8 'readlink /proc/$$/fd/0'    # pty facts, exits when the command ends
#   dev_ssh_tty 8                             # no command = login shell; the hold ends it
#
# Why the stdin keeper and not `</dev/null`
# -----------------------------------------
# The device runs dropbear 2025.89 (ImmortalWrt 25.12.2). Commit e28ba1b "Don't try to
# shutdown() a pty" changed the pty channel to `channel->bidir_fd = 0` (svr-chansession.c),
# and `close_chan_fd()` in common-channel.c then calls `m_close()` instead of `shutdown()`
# as soon as *either* direction of the channel is finished. A client whose stdin is already
# at EOF - `</dev/null`, or a heredoc, or any redirect of an empty file - finishes the write
# direction before the child has run `setsid()` + `TIOCSCTTY`, so dropbear closes the pty
# master first and the child lands on a tty that is already gone. Upstream bug report:
# mkj/dropbear#365, still open; the behaviour is in dropbear master too.
#
# The three errors that follow are pinned to that single cause, measured on the reference
# machine on 2026-11-17 (task 20261117-03, research/agent-3.md: the errno-by-errno kernel
# source reading, the sampling of the slave node appearing and being unlinked, and the
# controlled comparison that changed only the stdin the client offered). The same reasoning
# without the task-local evidence is in docs/troubleshooting.md:
#
#   ioctl(TIOCSCTTY): I/O error       EIO from tiocsctty() can only come from
#                                     hung_up_tty_ioctl(): the tty is already hung up
#   /dev/pts/N: No such file...       ENOENT for a devpts slave can only come from
#                                     devpts_pty_kill(), i.e. the master was released
#   open /dev/tty failed - ENXIO      "no controlling terminal", a consequence, not a cause
#
# So `/dev/pts`, `/dev/ptmx` and `/dev/tty` are fine, and no amount of device-node work in
# an initramfs changes the outcome: procd owns the runtime /dev and rebuilds it. A client
# whose stdin stays open for the length of the session - a person's terminal, or the keeper
# below - gets a prompt on the same machine.
#
# Why `sleep N | ssh -tt`, and not `< <(sleep N)`
# ----------------------------------------------
# scripts/device/*.sh are POSIX sh and run under dash in CI (tests/modules/device/
# test_device_scripts_posix.sh enforces it), so process substitution is not available. A
# `sleep` at the head of a pipeline holds the write end of the pipe open for N seconds and
# writes nothing, which is exactly what `<(sleep N)` provides: an stdin that is open, empty
# and not at EOF. The pipeline exits with ssh's status; the call lasts up to <hold_s>
# seconds even when the remote side finishes sooner, which is the bound, not a delay.
#
# /dev/null appears in this file only as the value of UserKnownHostsFile, never as stdin.
dev_ssh_tty() {
    _tty_hold=${1:-${AB_SSH_TTY_HOLD}}
    if [ $# -gt 0 ]; then
        shift
    fi
    case "${_tty_hold}" in
        '' | *[!0-9]*) _tty_hold=${AB_SSH_TTY_HOLD} ;;
    esac
    [ "${_tty_hold}" -ge 1 ] || _tty_hold=1
    if [ "${AB_DRY_RUN:-0}" = "1" ]; then
        printf 'dry-run: sleep %s | ssh -tt %s %s\n' "${_tty_hold}" "${AB_HOST}" "$*" >&2
        return 0
    fi
    sleep "${_tty_hold}" | ssh -i "${AB_KEY}" \
        -tt \
        -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey \
        -o PubkeyAuthentication=yes \
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

# --------------------------------------------------------------------------- #
# What a slot switch is allowed to change
#
# A harness that compares two `ab-slot status` lines around a switch has to know which
# fields must move and which must not. Left to each harness, that judgement gets written
# two different ways: one round of device acceptance asserted "everything equal" and failed
# every time a slot actually switched, while another asserted nothing at all.
#
# The groups below are read off the archived device runs of 20261116-01
# (evidence/results/s34/), not off reasoning - the first version of this block was reasoned
# and would have reported five false failures on a correct switch:
#
#   00-guard-h1  slot=b gen=5 committed=b pending=none   next=b packages=unknown/other-slot
#   07-pre-h1    slot=b gen=6 committed=b pending=a      next=a packages=unknown/other-slot
#   09-post-h1   slot=a gen=6 committed=a pending=none   next=a packages=aligned/none
#
# Two facts from those lines decide the whole split: `generation` advances when the payload
# is laid down, not when it is committed (6 before the reboot, 6 after), and a real upgrade
# realigns packages (unknown/other-slot -> aligned/none). Neither is a property of "a
# switch", so neither may be required to move or to stay.
#
# STABLE      - must not move, in every switch observed. This is what the acceptance proves.
# IDENTITY    - names which slot the machine is committed to; a switch that leaves these
#               unchanged did not land.
# MONITORED   - reported, never judged: their movement depends on *which* pair of lines is
#               compared (generation/pending/next) or on whether the upgrade realigned
#               packages (packages/packages_reason). Demanding either behaviour is the
#               defect this file exists to prevent.
# --------------------------------------------------------------------------- #

AB_STATUS_FIELDS_STABLE="disk method p4 data docker swap boot esp"
AB_STATUS_FIELDS_IDENTITY="slot upper committed"
AB_STATUS_FIELDS_MONITORED="generation pending next packages packages_reason"

# ab_status_fields: every field of `ab-slot status`, sorted. The groups have to cover
# exactly this set; a field added to the status line and not to a group would otherwise be
# judged by nobody.
ab_status_fields() {
    printf '%s\n' ${AB_STATUS_FIELDS_STABLE} ${AB_STATUS_FIELDS_IDENTITY} ${AB_STATUS_FIELDS_MONITORED} |
        LC_ALL=C sort
}

# ab_status_switch_check <before-line> <after-line> [case]
# Compares two captured status lines and reports the two ways a switch can go wrong:
#   changed_stable:      a field that must not move did -> FAIL
#   unchanged_on_switch: a field that identifies the slot did not move -> FAIL
# The monitored fields are printed as `monitored` lines and never affect the status.
#
# The variables are deliberately not named `_case`/`_f`: the callers are POSIX shell
# scripts that reuse those names across a step, so a helper that assigns them silently
# rewrites the caller's next printf. The first version did exactly that and every plan line
# after the assertion grew an extra hop label.
ab_status_switch_check() {
    _sw_before=${1:-}
    _sw_after=${2:-}
    _sw_case=${3:-?}
    [ -n "${_sw_before}" ] && [ -n "${_sw_after}" ] || {
        _dev_assert_fail "${_sw_case}" "switch check: a status line is empty"
        return 1
    }
    _sw_bad=0
    for _sw_f in ${AB_STATUS_FIELDS_STABLE}; do
        _sw_b=$(status_field "${_sw_before}" "${_sw_f}") || _sw_b=missing
        _sw_a=$(status_field "${_sw_after}" "${_sw_f}") || _sw_a=missing
        [ "${_sw_a}" = "${_sw_b}" ] && continue
        _dev_assert_fail "${_sw_case}" "changed_stable ${_sw_f}: before=${_sw_b} after=${_sw_a}"
        _sw_bad=1
    done
    for _sw_f in ${AB_STATUS_FIELDS_IDENTITY}; do
        _sw_b=$(status_field "${_sw_before}" "${_sw_f}") || _sw_b=missing
        _sw_a=$(status_field "${_sw_after}" "${_sw_f}") || _sw_a=missing
        [ "${_sw_a}" != "${_sw_b}" ] && continue
        _dev_assert_fail "${_sw_case}" "unchanged_on_switch ${_sw_f}: still ${_sw_a} (the switch did not land)"
        _sw_bad=1
    done
    for _sw_f in ${AB_STATUS_FIELDS_MONITORED}; do
        _sw_b=$(status_field "${_sw_before}" "${_sw_f}") || _sw_b=missing
        _sw_a=$(status_field "${_sw_after}" "${_sw_f}") || _sw_a=missing
        [ "${_sw_a}" = "${_sw_b}" ] || ev "${_sw_case} monitored ${_sw_f}: ${_sw_b} -> ${_sw_a}"
    done
    return ${_sw_bad}
}

# ab_status_switch_expect <case> <target-slot> [upper-prefix] [hop]
# The plan line a dry run prints for a switch. It states exactly what the check above
# enforces - no more: a plan line that promised the monitored fields would be lying, and the
# monitored fields are exactly the ones an earlier plan got wrong.
ab_status_switch_expect() {
    _se_case=${1:?ab_status_switch_expect needs a case}
    _se_target=${2:?ab_status_switch_expect needs the target slot}
    _se_prefix=${3:-}
    _se_hop=${4:-}
    printf '%s' "${_se_case}"
    [ -n "${_se_hop}" ] && printf ' %s' "${_se_hop}"
    printf ' assert boot=ok esp=ok committed=%s generation>=+1 pending=none' "${_se_target}"
    [ -n "${_se_prefix}" ] && printf ' upper=@overlay-%s(-rN)?' "${_se_prefix}"
    printf ' and these stay equal: %s (reported, not judged: %s)\n' \
        "${AB_STATUS_FIELDS_STABLE}" "${AB_STATUS_FIELDS_MONITORED}"
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
# A ring log is normal to be missing on a machine that has not booted that many times, so a
# missing boot-1.log or boot-2.log is recorded and not treated as a failed step.
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

# dev_install <payload>: write the inactive slot and mark it pending. The plan question is
# answered up front: these drivers run without a terminal, and an unanswered question is a
# refusal (exit 74) that writes nothing - measured 2026-11-18 against ab-upgrade's plan block.
dev_install() {
    dev_ssh "ab-upgrade --yes ${1:?dev_install needs a payload path}"
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

# _packages_assert <got> <want> <case>: `packages` is the one field whose expected value
# is a floor, not an equality.
#
# The product reports three states it can stand behind (platform/usr/sbin/ab-slot
# packages_state): `aligned` (the metadata names this base, the packages have not moved),
# `followed` (the same metadata after the follow transaction moved the packages onto this
# base) and `limited` (the metadata is partial; `packages_reason` names why). `followed` is
# strictly stronger than `aligned`, so a hop that installed a payload with packages to
# follow lands in `followed` and used to fail an `aligned` assertion exactly when the
# feature worked. `limited` is not accepted here: for a hop that claims the packages are
# usable it is a real defect, and the reason is named so the reader knows which part of the
# world broke. `unknown` stays a failure too: it means no record, never "already aligned".
_packages_assert() {
    _pkg_got=${1-}
    _pkg_want=${2-}
    _pkg_case=${3:-?}
    case "${_pkg_want}" in
        aligned)
            case "${_pkg_got}" in
                aligned | followed) return 0 ;;
                limited)
                    _pkg_reason=$(status_field "${AB_STATUS_LINE:-}" packages_reason) || _pkg_reason=unknown
                    _dev_assert_fail "${_pkg_case}" \
                        "assert_field packages: expected=aligned got=limited (packages_reason=${_pkg_reason})"
                    return 1
                    ;;
                *)
                    _dev_assert_fail "${_pkg_case}" \
                        "assert_field packages: expected=aligned got=${_pkg_got}"
                    return 1
                    ;;
            esac
            ;;
        *)
            [ "${_pkg_got}" = "${_pkg_want}" ] && return 0
            _dev_assert_fail "${_pkg_case}" \
                "assert_field packages: expected=${_pkg_want} got=${_pkg_got}"
            return 1
            ;;
    esac
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
    if [ "${_field}" = "packages" ]; then
        _packages_assert "${_got}" "${_want}" "${_case}"
        return $?
    fi
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
# Prints "<source>: <line>" for the first source that has it, searching the collected
# boot-0/boot-1/boot-2 copies, then the live ring on the machine (`ab-slot log`, then
# `ab-slot log --prev`, then the boot-2 path). That order is what the ring log dictates:
# boot-0.log carries the current boot's stage=commit, stage=mark lives in a previous boot's
# file, and the first boot of a new base can be followed by enough reboots that the commit
# line is in boot-2.log. The live sources come last so a normal hop pays no ssh at all,
# while a line that landed after the copy was collected is still found. The source is named
# by the remote file or command, not by the local copy, so a reader of the evidence sees
# the file on the machine and not the name this run happened to give it.
boot_mark_find() {
    _pattern=${1?boot_mark_find needs a pattern}
    for _pair in "${AB_BOOT_LOG_LOCAL}|${AB_BOOT_LOG}" \
        "${AB_BOOT_LOG_PREV_LOCAL}|${AB_BOOT_LOG_PREV}" \
        "${AB_BOOT_LOG_PREV2_LOCAL}|${AB_BOOT_LOG_PREV2}"; do
        _file=${_pair%%|*}
        [ -n "${_file}" ] || continue
        [ -f "${_file}" ] || continue
        _hit=$(grep -E "${_pattern}" "${_file}" 2>/dev/null | tail -n 1)
        [ -n "${_hit}" ] || continue
        printf '%s: %s\n' "$(basename "${_pair#*|}")" "${_hit}"
        return 0
    done
    for _cmd in "${AB_CURRENT_LOG_CMD}" "${AB_PREV_LOG_CMD}" \
        "${AB_PREV2_LOG_CMD:-cat ${AB_BOOT_LOG_PREV2}}"; do
        [ -n "${_cmd}" ] || continue
        _hit=$(dev_ssh "${_cmd}" 2>/dev/null | grep -E "${_pattern}" | tail -n 1)
        [ -n "${_hit}" ] || continue
        printf '%s: %s\n' "${_cmd}" "${_hit}"
        return 0
    done
    return 1
}

# assert_boot_mark <case> <extended regex> <label>: the breadcrumb exists somewhere the
# ring log can have put it. The evidence records which source answered, because a reader
# of a red row has to tell "the machine wrote nothing" from "the matrix looked in the
# wrong file". A miss is retried, bounded: ab-commit records the decision in ab/state.json
# before it appends the ring line, so a settle poll that watches pending=none can collect
# the log a moment too early. The retry re-reads the live ring, and the last attempt still
# fails a machine that wrote nothing.
assert_boot_mark() {
    _case=${1:-?}
    _pattern=${2?assert_boot_mark needs a pattern}
    _label=${3:-log line}
    _attempt=0
    while :; do
        _attempt=$((_attempt + 1))
        if _hit=$(boot_mark_find "${_pattern}"); then
            ev "boot-mark ${_label}: hit ${_hit}"
            return 0
        fi
        [ "${_attempt}" -lt "${AB_BOOT_MARK_TRIES}" ] || break
        sleep "${AB_BOOT_MARK_WAIT}"
    done
    _dev_assert_fail "${_case}" \
        "assert_boot_mark ${_label}: /${_pattern}/ not in ${AB_BOOT_LOG}, ${AB_BOOT_LOG_PREV}, ${AB_BOOT_LOG_PREV2} (collected as ${AB_BOOT_LOG_LOCAL:-none}, ${AB_BOOT_LOG_PREV_LOCAL:-none}, ${AB_BOOT_LOG_PREV2_LOCAL:-none}), and not in \`${AB_CURRENT_LOG_CMD}\`, \`${AB_PREV_LOG_CMD}\`, \`${AB_PREV2_LOG_CMD:-cat ${AB_BOOT_LOG_PREV2}}\`"
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
