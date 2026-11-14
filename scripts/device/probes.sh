#!/bin/sh
# probes.sh - the baseline probes of a freshly flashed machine, one line per criterion.
#
# The acceptance checklist in docs/install.md is prose: "the growth finished", "the network
# was generated", "the key lands and works". A person with one device types five commands and
# the verdict then depends on who typed them. This script asks the same questions with one
# machine predicate each, prints exactly one `key=value` line per question, and ends with an
# exit code a caller can branch on.
#
#   scripts/device/probes.sh                          # every probe, one line each
#   scripts/device/probes.sh --probe grow --probe key # a subset
#   AB_DRY_RUN=1 scripts/device/probes.sh             # print the remote scripts, touch nothing
#
# Output shape:
#
#   probe=<name> ac=<ac-N> status=<pass|fail|gap|skip> <fact=value...>
#
#   probe=grow      ac-3   /data covers the end of the disk, and the growth recorded its two
#                          stages and result=done - see the window note below
#   probe=network   ac-4   br-lan 192.168.100.1/24, a DHCP lease on the WAN device, exactly
#                          one `tcp dport 22` in nft, no dropbear Interface binding
#   probe=wan22     ac-4   22/tcp answers from the WAN side - the transport this script is
#                          itself talking over, judged on its own line
#   probe=key       ac-5   AB_KEY's public key is in /etc/dropbear/authorized_keys (exactly
#                          one copy, mode 600/644) and key login is what answers afterwards
#   probe=platform  ac-2   /lib/upgrade/platform.sh carries platform_upgrade_begin
#                          (handoff §5.1: no ac names this, and no script asserted it)
#   probe=initrd    ac-11  the target slot's /boot/initrd-<slot> carries wf_boot_attempt_guard
#                          (handoff §5.2, moved from power-cut.sh to right after the flash)
#   probe=packages  ac-6   ab-slot status says packages=aligned and docker is executable
#
# A failure prints the verdict line first and then one or more `  next:` lines that can be
# pasted back into a shell on the machine. A `gap`/`skip` prints one too: "nothing was
# decided" is only useful to a reader who is told what to look at.
#
# Exit status: 0 every selected probe passed, 1 at least one failed, 3 nothing failed but at
# least one question was not answered (gap/skip), 2 bad usage.
#
# AB_DRY_RUN=1 (or --dry-run) prints, for each probe, the exact remote script `dev_ssh` would
# send, then `status=skip reason=dry-run`, and exits 0 with `result=dry-run` in the summary:
# a plan is not a pass, and the last line says which one this run was.
#
# The growth window (ac-3), the trap this probe exists for
# -------------------------------------------------------
# p4 ships at 128 MiB and grows in two boots: boot 1 writes the partition table and reboots
# (that reboot IS the re-read), boot 2 runs `btrfs filesystem resize max` and records
# `result=done`, and every boot after that overwrites the same `.ab/grow` with
# `result=already-full` (initramfs/lib/grow.sh, `wf_grow_finish`). So `result=done` is visible
# for exactly one boot: the one the machine comes back on right after the growth reboot, which
# is the boot flash.sh is already waiting for. A probe run one reboot later cannot see it, and
# this script says so (`status=skip reason=window-missed`) instead of guessing. `grow.log` is
# append-only across boots, so the same line also reports whether the history is still there
# (`phases=complete`) - that is evidence for a person, not a pass for the machine.
#
# What this script does not decide
# --------------------------------
# ac-6 has two halves and this probe covers the first: `packages=aligned` plus an executable
# docker on the machine as it runs now. "Still there after a reboot" is scenarios.sh S3/S4's
# job, because it needs a reboot this probe does not own. ac-2's `slot==committed` and the
# 180 s budget belong to flash.sh; the status fields are printed here as facts, not judged.
#
# The one probe that writes is probe=key: it installs AB_KEY's public key (idempotent, one
# copy, mode 600). Everything else is a read. AB_DRY_RUN=1 writes nothing anywhere.
#
# Primitives come from scripts/device/lib.sh: dev_ssh (key, PreferredAuthentications=publickey,
# BatchMode=yes, IdentitiesOnly=yes
# - which is why a successful `dev_ssh true` proves public-key auth rather than an empty
# password), dev_push, dev_status, status_field, ev and record. The `assert_*` family is not
# used on purpose: it prints a multi-line FAIL block for the matrix's per-case report, and
# this script's contract is one machine-parseable line per probe.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

DRY_RUN=${AB_DRY_RUN:-0}
SELECTED=""
INITRD_SLOT=""
PROBES_ALL="grow network wan22 key platform initrd packages"

# Tunables. The floors are assertions; the ceilings exist to catch "grown onto something
# that is not this disk" and are loose on purpose, because df reports the filesystem size of
# a btrfs device and the measured value on a 128 GB NVMe sits a little under 120 GiB.
AB_PROBE_DATA_MIN_GB=${AB_PROBE_DATA_MIN_GB:-110}
AB_PROBE_DATA_MAX_GB=${AB_PROBE_DATA_MAX_GB:-120}
AB_PROBE_LAN_ADDR=${AB_PROBE_LAN_ADDR:-192.168.100.1/24}
AB_PROBE_WAN_SSH_RULES=${AB_PROBE_WAN_SSH_RULES:-1}
AB_PROBE_PACKAGES=${AB_PROBE_PACKAGES:-aligned}
AB_PROBE_DOCKER=${AB_PROBE_DOCKER:-docker}
AB_PROBE_AUTH_KEYS=${AB_PROBE_AUTH_KEYS:-/etc/dropbear/authorized_keys}
AB_PROBE_PLATFORM_SH=${AB_PROBE_PLATFORM_SH:-/lib/upgrade/platform.sh}
# Optional local TSV of verdicts (PASS/FAIL/GAP rows, lib.sh `record`); unset writes nothing.
AB_PROBE_RESULTS=${AB_PROBE_RESULTS:-}
[ -n "${AB_PROBE_RESULTS}" ] && AB_RESULTS=${AB_PROBE_RESULTS}

usage() {
    cat <<'USAGE'
usage: probes.sh [--probe <name>]... [--initrd-slot <a|b>] [--dry-run]

  --probe <name>     run one probe; repeatable. One of:
                     grow network wan22 key platform initrd packages (default: all)
  --initrd-slot <s>  slot whose /boot/initrd-<s> is checked (default: the slot not running,
                     i.e. the one the next candidate boot would use)
  --dry-run          print the remote scripts and exit; same as AB_DRY_RUN=1

Environment: AB_HOST (root@host), AB_KEY (private key), AB_DRY_RUN.
             AB_PROBE_DATA_MIN_GB/MAX_GB (110/120), AB_PROBE_LAN_ADDR (192.168.100.1/24),
             AB_PROBE_WAN_SSH_RULES (1), AB_PROBE_PACKAGES (aligned),
             AB_PROBE_DOCKER (docker), AB_PROBE_AUTH_KEYS, AB_PROBE_PLATFORM_SH,
             AB_PROBE_PUBKEY (public key file; default <AB_KEY>.pub, else derived),
             AB_PROBE_RESULTS (optional local TSV of verdicts), AB_EVIDENCE_LOG (lib.sh ev).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --probe)
            _want=${2:?--probe needs a probe name}
            case " ${PROBES_ALL} " in
                *" ${_want} "*) SELECTED="${SELECTED} ${_want}" ;;
                *)
                    printf 'probes.sh: unknown probe: %s (want one of: %s)\n' \
                        "${_want}" "${PROBES_ALL}" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --initrd-slot)
            INITRD_SLOT=${2:?--initrd-slot needs a or b}
            case "${INITRD_SLOT}" in
                a | b) : ;;
                *) printf 'probes.sh: --initrd-slot wants a or b, got %s\n' "${INITRD_SLOT}" >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help | help)
            usage
            exit 0
            ;;
        *)
            printf 'probes.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done
[ -n "${SELECTED}" ] || SELECTED=" ${PROBES_ALL} "

# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

PROBE_TOTAL=0
PROBE_PASS=0
PROBE_FAIL=0
PROBE_GAP=0
PROBE_SKIP=0
REASONS=""

_begin() { REASONS=""; }
_bad() { REASONS="${REASONS:+${REASONS},}$1"; }

# _next <command>: the line a red probe owes its reader.
_next() { printf '  next: %s\n' "$1"; }

# _emit <probe> <ac> <status> [token...]: the one line this probe is worth, plus the
# counters the exit status is built from. Every probe prints exactly one of these.
_emit() {
    _em_probe=$1
    _em_ac=$2
    _em_status=$3
    shift 3
    _em_line="probe=${_em_probe} ac=${_em_ac} status=${_em_status}"
    for _em_token in "$@"; do
        [ -n "${_em_token}" ] && _em_line="${_em_line} ${_em_token}"
    done
    printf '%s\n' "${_em_line}"
    PROBE_TOTAL=$((PROBE_TOTAL + 1))
    case "${_em_status}" in
        pass) PROBE_PASS=$((PROBE_PASS + 1)) ;;
        fail) PROBE_FAIL=$((PROBE_FAIL + 1)) ;;
        gap) PROBE_GAP=$((PROBE_GAP + 1)) ;;
        skip) PROBE_SKIP=$((PROBE_SKIP + 1)) ;;
    esac
    ev "${_em_line}"
    if [ -n "${AB_PROBE_RESULTS}" ]; then
        case "${_em_status}" in
            pass) record "${_em_probe}" PASS - "${_em_ac}" ;;
            fail) record "${_em_probe}" FAIL - "${_em_ac}" ;;
            *) record "${_em_probe}" GAP - "${_em_ac}" ;;
        esac
    fi
}

# _field <blob> <key>: one `key=value` out of a block the remote shell printed.
# lib.sh's status_field does the same for the single `ab-slot status` line; this one is for
# the multi-line fact blocks the probes below ask for (power-cut.sh keeps its own copy for
# the same reason).
_field() {
    printf '%s\n' "${1:-}" | sed -n "s/^${2}=//p" | head -n 1
}

# _pos <value>: true when the value is a positive integer. The log counters come back as
# `0` or a count and as nothing at all when the file is unreadable, and `[ -gt ]` on an empty
# string is an error under `set -u` in some shells rather than a false.
_pos() {
    case "${1:-}" in
        "" | *[!0-9]*) return 1 ;;
    esac
    [ "${1}" -gt 0 ]
}

# _dry_plan <probe> <ac> <step> <remote script>: the exact text dev_ssh would send, indented
# so a reader can see where it starts and ends. Not quoted on purpose: the snippet carries its
# own quotes, and wrapping it would break the paste.
_dry_plan() {
    printf 'plan probe=%s ac=%s step=%s\n' "$1" "$2" "$3"
    printf '%s\n' "$4" | sed 's/^/    /'
}

# _dry_note <local command>: a step that runs on this host, not on the machine.
_dry_note() { printf '  local: %s\n' "$1"; }

# _unreachable <probe> <ac>: the machine did not answer, so the question was not asked.
# One line per probe, no second ssh attempt: a machine that is down would otherwise cost six
# timeouts and produce six different-looking reds for one fact.
_unreachable() {
    _emit "$1" "$2" fail reason=unreachable reach="${REACH}"
    _next "sh scripts/device/probes.sh --probe wan22   # this machine did not answer on 22/tcp"
}

# --------------------------------------------------------------------------- #
# Remote scripts (one quoted heredoc each: nothing here is expanded on this host)
# --------------------------------------------------------------------------- #

_remote_grow_facts() {
    cat <<'REMOTE'
kb=$(df -kP /data 2>/dev/null | awk 'NR==2{print $2}')
printf 'df_kb=%s\n' "${kb:-none}"
rec=none
recf=none
for f in /mnt/p4/.ab/grow /data/.ab/grow /mnt/p4/*/.ab/grow; do
    if [ -f "$f" ]; then
        rec=$(sed -n '1p' "$f" 2>/dev/null)
        recf=$f
        break
    fi
done
printf 'record=%s\n' "${rec:-none}"
printf 'record_file=%s\n' "${recf:-none}"
REMOTE
}

# The grow log is the append-only half: `.ab/grow` is rewritten every boot, `.ab/grow.log`
# only ever grows, and ab-boot publishes a copy on the ESP (publish_grow_log).
_remote_grow_log() {
    cat <<'REMOTE'
f=
for c in /boot/ab/log/grow.log /mnt/p4/.ab/grow.log; do
    if [ -f "$c" ]; then
        f=$c
        break
    fi
done
if [ -z "$f" ]; then
    printf 'grow_log=missing\n'
    exit 0
fi
printf 'grow_log=%s\n' "$f"
printf 'log_pending=%s\n' "$(grep -c 'record result=table-write-pending' "$f" 2>/dev/null || true)"
printf 'log_table_written=%s\n' "$(grep -c 'record result=table-written' "$f" 2>/dev/null || true)"
printf 'log_done=%s\n' "$(grep -c 'record result=done' "$f" 2>/dev/null || true)"
printf 'log_already_full=%s\n' "$(grep -c 'record result=already-full' "$f" 2>/dev/null || true)"
printf 'log_resize_ok=%s\n' "$(grep -c 'btrfs filesystem resize max .*: ok' "$f" 2>/dev/null || true)"
printf 'log_reboot=%s\n' "$(grep -c 'rebooting so the kernel re-reads' "$f" 2>/dev/null || true)"
printf 'log_fail=%s\n' "$(grep -c 'record result=fail:' "$f" 2>/dev/null || true)"
REMOTE
}

_remote_network() {
    cat <<'REMOTE'
lan=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\/[0-9]*\).*/\1/p' | head -n 1)
printf 'lan_addr=%s\n' "${lan:-none}"
proto=$(uci -q get network.wan.proto 2>/dev/null)
printf 'wan_proto=%s\n' "${proto:-none}"
dev=$(uci -q get network.wan.device 2>/dev/null)
printf 'wan_dev=%s\n' "${dev:-none}"
addr=none
if [ -n "$dev" ]; then
    addr=$(ip -4 addr show dev "$dev" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\/[0-9]*\).*/\1/p' | head -n 1)
fi
printf 'wan_addr=%s\n' "${addr:-none}"
printf 'wan_ssh=%s\n' "$(nft list ruleset 2>/dev/null | grep -c 'tcp dport 22' || true)"
printf 'dropbear_iface=%s\n' "$(uci show dropbear 2>/dev/null | grep -c 'Interface' || true)"
REMOTE
}

_remote_platform() {
    cat <<REMOTE
f=${AB_PROBE_PLATFORM_SH}
if [ ! -f "\$f" ]; then
    printf 'platform_sh=missing\n'
    exit 0
fi
printf 'platform_sh=present\n'
printf 'upgrade_begin=%s\n' "\$(grep -c platform_upgrade_begin "\$f" 2>/dev/null || true)"
printf 'copy_rootfs=%s\n' "\$(grep -c platform_copy_rootfs "\$f" 2>/dev/null || true)"
rel=/etc/platform-release
if [ -f "\$rel" ]; then
    printf 'platform_stage=%s\n' "\$(sed -n 's/^PLATFORM_STAGE=//p' "\$rel" | head -n 1)"
    printf 'platform_version=%s\n' "\$(sed -n 's/^PLATFORM_VERSION=//p' "\$rel" | head -n 1)"
    printf 'upstream_version=%s\n' "\$(sed -n 's/^UPSTREAM_VERSION=//p' "\$rel" | head -n 1)"
fi
REMOTE
}

# _remote_initrd [slot]: what the target slot's initramfs carries. The slot is a parameter
# because a dry run has not read `ab-slot status` yet and still has to print a script.
_remote_initrd() {
    _slot=${1:-${_slot:-TARGET}}
    cat <<REMOTE
f=/boot/initrd-${_slot}
if [ ! -f "\$f" ]; then
    printf 'initrd=missing\n'
    exit 0
fi
magic=\$(dd if="\$f" bs=2 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
# One fact per line: the reader below takes each line literally, so a line carrying two
# tokens would be read as one value and turn a pass into a GAP.
if [ "\$magic" = "1f8b" ]; then
    if gzip -dc "\$f" 2>/dev/null | grep -qa wf_boot_attempt_guard; then
        printf 'initrd=ok\nmethod=gzip\n'
    else
        printf 'initrd=absent\nmethod=gzip\n'
    fi
else
    printf 'magic=%s\n' "\${magic:-unknown}"
    if grep -qa wf_boot_attempt_guard "\$f" 2>/dev/null; then
        printf 'initrd=ok\nmethod=raw\n'
    else
        printf 'initrd=undecidable\nmethod=raw\n'
    fi
fi
REMOTE
}

_remote_key_install() {
    cat <<REMOTE
src=/tmp/ab-probes-key.pub
f=${AB_PROBE_AUTH_KEYS}
if [ ! -f "\$src" ]; then
    printf 'install=src-missing\n'
    exit 0
fi
id=\$(awk 'NF>=2{print \$1" "\$2; exit}' "\$src")
line=\$(awk 'NF>=2{print; exit}' "\$src")
if [ -z "\$id" ] || [ -z "\$line" ]; then
    printf 'install=src-unparsable\n'
    exit 0
fi
mkdir -p /etc/dropbear 2>/dev/null || :
before=0
if [ -f "\$f" ]; then
    before=\$(grep -c . "\$f" 2>/dev/null || true)
fi
tmp="\$f.abprobes.\$\$"
if [ -f "\$f" ]; then
    awk -v id="\$id" 'NF>=2 { key=\$1" "\$2; if (key==id) { if (seen) next; seen=1 } } { print }' "\$f" >"\$tmp" 2>/dev/null || : >"\$tmp"
else
    : >"\$tmp"
fi
if grep -qF -- "\$id" "\$tmp" 2>/dev/null; then
    state=already-present
else
    printf '%s\n' "\$line" >>"\$tmp"
    state=installed
fi
chmod 600 "\$tmp" 2>/dev/null || :
if ! mv "\$tmp" "\$f" 2>/dev/null; then
    cat "\$tmp" >"\$f" 2>/dev/null || :
    rm -f "\$tmp" 2>/dev/null || :
fi
chmod 600 "\$f" 2>/dev/null || :
after=\$(grep -c . "\$f" 2>/dev/null || true)
printf 'install=%s\n' "\$state"
printf 'keys_before=%s\n' "\${before:-0}"
printf 'keys_after=%s\n' "\${after:-0}"
printf 'key_copies=%s\n' "\$(grep -cF -- "\$id" "\$f" 2>/dev/null || true)"
printf 'key_mode=%s\n' "\$(ls -l "\$f" 2>/dev/null | awk '{print \$1}')"
printf 'key_path=%s\n' "\$f"
rm -f "\$src" 2>/dev/null || :
REMOTE
}

# The fallback ac-5 mentions: an empty root password is what gets a person in when the key is
# not there yet. It is read, printed and never counted as the pass - an empty password proves
# nothing about the key, and dev_ssh's BatchMode=yes/IdentitiesOnly=yes means it cannot be the
# thing that answered either.
_remote_root_password() {
    cat <<'REMOTE'
if [ -r /etc/shadow ]; then
    awk -F: '/^root:/{ if (length($2)==0) print "root_password=empty"; else print "root_password=set"; exit }' /etc/shadow 2>/dev/null
else
    printf 'root_password=unreadable\n'
fi
REMOTE
}

_remote_docker() {
    cat <<REMOTE
for c in ${AB_PROBE_DOCKER} dockerd; do
    p=\$(command -v "\$c" 2>/dev/null)
    if [ -n "\$p" ]; then
        if [ -x "\$p" ]; then
            printf '%s=exec-ok path=%s\n' "\$c" "\$p"
        else
            printf '%s=not-executable path=%s\n' "\$c" "\$p"
        fi
    else
        printf '%s=missing\n' "\$c"
    fi
done
REMOTE
}

# --------------------------------------------------------------------------- #
# Reachability, measured once
# --------------------------------------------------------------------------- #

REACH=unknown
REACH_TCP=unknown
REACH_S=0
STATUS_LINE=""

_preflight() {
    if [ "${DRY_RUN}" = "1" ]; then
        REACH=dry-run
        return 0
    fi
    _t0=$(date +%s)
    if dev_ssh true >/dev/null 2>&1; then
        REACH=ok
        REACH_TCP=open
        REACH_S=$(( $(date +%s) - _t0 ))
        return 0
    fi
    REACH_S=$(( $(date +%s) - _t0 ))
    # Distinguishing "closed port" from "port open, our key refused" is the difference between
    # a firewall/cable problem and the ac-5 bootstrap step: both look like one dead machine
    # from inside `dev_ssh`, which is how a real key problem was once read as a bad flash.
    if command -v nc >/dev/null 2>&1; then
        if nc -z "${AB_HOST#*@}" 22 2>/dev/null; then
            REACH=auth-failed
            REACH_TCP=open
        else
            REACH=port-closed
            REACH_TCP=closed
        fi
    else
        REACH=ssh-failed
    fi
    return 1
}

_status_once() {
    [ -n "${STATUS_LINE}" ] && return 0
    STATUS_LINE=$(dev_status 2>/dev/null) || STATUS_LINE=""
    [ -n "${STATUS_LINE}" ]
}

# --------------------------------------------------------------------------- #
# probe=grow (ac-3)
# --------------------------------------------------------------------------- #

probe_grow() {
    _ac=ac-3
    if [ "${DRY_RUN}" = "1" ]; then
        _emit grow "${_ac}" skip reason=dry-run
        _dry_plan grow "${_ac}" read-facts "$(_remote_grow_facts)"
        _dry_plan grow "${_ac}" read-grow-log "$(_remote_grow_log)"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _unreachable grow "${_ac}"
        return 0
    fi

    _facts=$(dev_ssh "$(_remote_grow_facts)" 2>/dev/null) || _facts=""
    _logs=$(dev_ssh "$(_remote_grow_log)" 2>/dev/null) || _logs=""
    _df_kb=$(_field "${_facts}" df_kb)
    _record=$(_field "${_facts}" record)
    _record_file=$(_field "${_facts}" record_file)
    _grow_log=$(_field "${_logs}" grow_log)
    _done_n=$(_field "${_logs}" log_done)
    _table_n=$(_field "${_logs}" log_table_written)
    _reboot_n=$(_field "${_logs}" log_reboot)
    _resize_n=$(_field "${_logs}" log_resize_ok)
    _fail_n=$(_field "${_logs}" log_fail)

    _begin
    _data_token="data_gb=na"
    case "${_df_kb}" in
        "" | *[!0-9]*)
            _bad data-unmounted
            ;;
        *)
            _data_gb=$((_df_kb / 1048576))
            _data_token="data_gb=${_data_gb}"
            [ "${_data_gb}" -ge "${AB_PROBE_DATA_MIN_GB}" ] || _bad data-short
            [ "${_data_gb}" -le "${AB_PROBE_DATA_MAX_GB}" ] || _bad data-large
            ;;
    esac

    # Stage 1 left two possible breadcrumbs (the record and the reboot it ends with); stage 2
    # is the `done` record and the resize line in front of it. Both are in the append-only log.
    _phase_table=0
    _phase_resize=0
    if _pos "${_table_n}" || _pos "${_reboot_n}"; then _phase_table=1; fi
    if _pos "${_done_n}" || _pos "${_resize_n}"; then _phase_resize=1; fi
    _phases=incomplete
    [ "${_phase_table}" -eq 1 ] && [ "${_phase_resize}" -eq 1 ] && _phases=complete

    _state=${_record#result=}
    _state=${_state%% *}
    [ -n "${_state}" ] || _state=none

    _tokens="${_data_token} record=${_state} record_file=${_record_file:-none} phases=${_phases} grow_log=${_grow_log:-none}"
    _pos "${_fail_n}" && _tokens="${_tokens} log_fail=${_fail_n}"

    if [ -n "${REASONS}" ]; then
        _emit grow "${_ac}" fail "reasons=${REASONS}" ${_tokens}
        _next "df -khP /data   # a grown p4 covers the disk; 128 MiB means the growth never happened"
        _next "sed -n 1p /mnt/p4/.ab/grow; cat /boot/ab/log/grow.log"
        _next "sh scripts/device/probes.sh --probe grow"
        return 0
    fi

    case "${_state}" in
        done)
            if [ "${_phases}" = "complete" ]; then
                _emit grow "${_ac}" pass "${_tokens}"
            else
                _emit grow "${_ac}" gap reason=phases-unproven "${_tokens}"
                _next "cat /boot/ab/log/grow.log   # the two stages belong in here; a truncated log is why this is a GAP"
                _next "ls -l /mnt/p4/.ab/grow.log /boot/ab/log/grow.log"
            fi
            ;;
        already-full)
            # The record was overwritten by a later boot. grow.log keeps the history, but the
            # live record is what ac-3 asks for, so this is not a pass.
            _emit grow "${_ac}" skip reason=window-missed "${_tokens}"
            _next "sh scripts/device/probes.sh --probe grow   # only meaningful on the boot after the growth reboot; a reflash is what reopens the window"
            _next "grep 'record result=done' /boot/ab/log/grow.log   # the append-only history, if a person wants to cite it"
            ;;
        table-written | table-write-pending)
            _emit grow "${_ac}" fail "reasons=grow-incomplete" "${_tokens}"
            _next "cat /mnt/p4/.ab/grow; cat /boot/ab/log/grow.log   # the table was written, the resize never landed"
            _next "ab-slot log"
            ;;
        fail:*)
            _emit grow "${_ac}" fail "reasons=grow-failed" "${_tokens}"
            _next "cat /boot/ab/log/grow.log   # the token names the step that failed"
            _next "cat /mnt/p4/.ab/partitions.before"
            ;;
        none)
            _emit grow "${_ac}" gap reason=record-missing "${_tokens}"
            _next "ls -l /mnt/p4/.ab/ /boot/ab/log/   # no growth record anywhere on p4"
            _next "ab-slot log | grep stage=grow"
            ;;
        *)
            _emit grow "${_ac}" gap reason=record-unrecognised "${_tokens}"
            _next "cat /mnt/p4/.ab/grow"
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# probe=network (ac-4)
# --------------------------------------------------------------------------- #

probe_network() {
    _ac=ac-4
    if [ "${DRY_RUN}" = "1" ]; then
        _emit network "${_ac}" skip reason=dry-run
        _dry_plan network "${_ac}" read-network "$(_remote_network)"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _unreachable network "${_ac}"
        return 0
    fi

    _facts=$(dev_ssh "$(_remote_network)" 2>/dev/null) || _facts=""
    _lan=$(_field "${_facts}" lan_addr)
    _proto=$(_field "${_facts}" wan_proto)
    _wan_dev=$(_field "${_facts}" wan_dev)
    _wan_addr=$(_field "${_facts}" wan_addr)
    _wan_ssh=$(_field "${_facts}" wan_ssh)
    _db_iface=$(_field "${_facts}" dropbear_iface)

    _begin
    _lan_ok=0
    _proto_ok=0
    _lease_ok=0
    _ssh_ok=0
    _db_ok=0
    if [ "${_lan}" = "${AB_PROBE_LAN_ADDR}" ]; then
        _lan_ok=1
    else
        _bad lan-addr
    fi
    case "${_proto}" in
        dhcp) _proto_ok=1 ;;
        *) _bad wan-proto ;;
    esac
    case "${_wan_addr}" in
        "" | none) _bad wan-no-lease ;;
        169.254.*) _bad wan-link-local ;;
        *) _lease_ok=1 ;;
    esac
    case "${_wan_ssh}" in
        "" | *[!0-9]*) _bad wan-ssh-unknown ;;
        *)
            if [ "${_wan_ssh}" -eq "${AB_PROBE_WAN_SSH_RULES}" ]; then
                _ssh_ok=1
            else
                _bad "wan-ssh-rules-${_wan_ssh}"
            fi
            ;;
    esac
    case "${_db_iface}" in
        "" | *[!0-9]*) _bad dropbear-unknown ;;
        0) _db_ok=1 ;;
        *) _bad dropbear-interface-binding ;;
    esac

    _tokens="lan=${_lan:-none} wan_proto=${_proto:-none} wan_dev=${_wan_dev:-none} wan_addr=${_wan_addr:-none} wan_ssh=${_wan_ssh:-none} dropbear_iface=${_db_iface:-none}"
    if [ -z "${REASONS}" ]; then
        _emit network "${_ac}" pass "${_tokens}"
        return 0
    fi
    _emit network "${_ac}" fail "reasons=${REASONS}" "${_tokens}"
    [ "${_lan_ok}" -eq 1 ] || _next "ip -4 addr show br-lan; uci show network.lan; ab-slot log | grep net-seed"
    { [ "${_proto_ok}" -eq 1 ] && [ "${_lease_ok}" -eq 1 ]; } ||
        _next "uci -q get network.wan.proto; ip -4 addr show dev \$(uci -q get network.wan.device); logread | grep -i dhcp"
    [ "${_ssh_ok}" -eq 1 ] || _next "nft list ruleset | grep -B3 -A3 'dport 22'   # want exactly one rule"
    [ "${_db_ok}" -eq 1 ] || _next "uci show dropbear | grep Interface   # delete dropbear.@dropbear[0].Interface and commit"
    _next "sh scripts/device/probes.sh --probe network"
}

# --------------------------------------------------------------------------- #
# probe=wan22 (ac-4, the reachability half, on its own line)
# --------------------------------------------------------------------------- #

probe_wan22() {
    _ac=ac-4
    if [ "${DRY_RUN}" = "1" ]; then
        _emit wan22 "${_ac}" skip reason=dry-run
        _dry_note "ssh -i ${AB_KEY} ${AB_HOST} true   # the transport this script itself uses"
        _dry_note "nc -z ${AB_HOST#*@} 22   # a second opinion when the first one fails"
        return 0
    fi
    if [ "${REACH}" = "ok" ]; then
        _emit wan22 "${_ac}" pass "host=${AB_HOST}" transport=dev_ssh elapsed_s="${REACH_S}"
        return 0
    fi
    _emit wan22 "${_ac}" fail "reason=${REACH}" "host=${AB_HOST}" "tcp=${REACH_TCP}" elapsed_s="${REACH_S}"
    case "${REACH}" in
        auth-failed)
            _next "sh scripts/device/probes.sh --probe key   # 22 is open, this key is not accepted yet"
            _next "ssh -o PreferredAuthentications=password ${AB_HOST}   # empty password, then install the key"
            ;;
        port-closed)
            _next "nc -z ${AB_HOST#*@} 22"
            _next "ip -4 addr show dev \$(uci -q get network.wan.device)   # from the LAN side: did the WAN get a lease?"
            _next "nft list ruleset | grep -A3 'tcp dport 22'   # the allow_ssh_wan rule is what keeps 22 open on the WAN"
            ;;
        *)
            _next "ssh -i ${AB_KEY} ${AB_HOST} true   # see the error: no route, refused, or key refused"
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# probe=key (ac-5)
# --------------------------------------------------------------------------- #

# _pubkey_line: fill PUBKEY_LINE with the one public key line for AB_KEY, and PUBKEY_HOW /
# PUBKEY_SRC with where it came from. Answers through variables instead of stdout, because a
# command substitution would run this in a subshell and lose the two facts that explain a
# failure to a reader.
# `ssh-keygen -y` reads the private key, so a passphrase-protected key would prompt: stdin is
# closed for that reason, and an empty answer is reported as no-pubkey instead of hanging.
_pubkey_line() {
    PUBKEY_HOW=""
    PUBKEY_LINE=""
    PUBKEY_SRC=${AB_PROBE_PUBKEY:-}
    if [ -z "${PUBKEY_SRC}" ] && [ -f "${AB_KEY}.pub" ]; then
        PUBKEY_SRC="${AB_KEY}.pub"
    fi
    if [ -n "${PUBKEY_SRC}" ]; then
        if [ ! -f "${PUBKEY_SRC}" ]; then
            PUBKEY_HOW=file-missing
            return 0
        fi
        PUBKEY_HOW=from-file
        PUBKEY_LINE=$(sed -n '1p' "${PUBKEY_SRC}" 2>/dev/null)
        return 0
    fi
    PUBKEY_HOW=derived
    PUBKEY_SRC=${AB_KEY}
    PUBKEY_LINE=$(ssh-keygen -y -f "${AB_KEY}" </dev/null 2>/dev/null)
}

probe_key() {
    _ac=ac-5
    if [ "${DRY_RUN}" = "1" ]; then
        _emit key "${_ac}" skip reason=dry-run
        _dry_note "ssh-keygen -y -f ${AB_KEY}   # or read ${AB_KEY}.pub when it exists"
        _dry_note "cat ${AB_KEY}.pub | ssh -i ${AB_KEY} ${AB_HOST} 'cat > /tmp/ab-probes-key.pub'"
        _dry_plan key "${_ac}" install-and-dedupe "$(_remote_key_install)"
        _dry_note "ssh -i ${AB_KEY} ${AB_HOST} true   # public-key only: BatchMode + IdentitiesOnly"
        _dry_plan key "${_ac}" fallback-state "$(_remote_root_password)"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _emit key "${_ac}" fail reason=unreachable reach="${REACH}" "keys_path=${AB_PROBE_AUTH_KEYS}"
        _next "cat ${AB_KEY}.pub   # then paste that one line into /etc/dropbear/authorized_keys on the machine"
        _next "ssh -o PreferredAuthentications=password ${AB_HOST}   # empty password gets you in until the key is there"
        _next "sh scripts/device/probes.sh --probe key"
        return 0
    fi

    _pubkey_line
    _pub=${PUBKEY_LINE}
    case "${_pub}" in
        ssh-* | ecdsa-* | sk-ssh-* | sk-ecdsa-*) : ;;
        "")
            _emit key "${_ac}" fail reason=no-pubkey "pubkey=${PUBKEY_HOW}" "pubkey_path=${PUBKEY_SRC:-none}"
            _next "ls -l ${AB_KEY} ${AB_KEY}.pub   # AB_KEY must name the private key, or set AB_PROBE_PUBKEY"
            _next "ssh-keygen -y -f ${AB_KEY}   # an empty answer means the key is passphrase-protected"
            return 0
            ;;
        *)
            _emit key "${_ac}" fail reason=pubkey-unreadable "pubkey=${PUBKEY_HOW}" "pubkey_path=${PUBKEY_SRC:-none}"
            _next "sed -n 1p ${PUBKEY_SRC:-${AB_KEY}.pub}"
            return 0
            ;;
    esac

    _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ab-probes.XXXXXX" 2>/dev/null) || _tmpdir=""
    if [ -z "${_tmpdir}" ]; then
        _emit key "${_ac}" fail reason=no-local-tmpdir "pubkey=${PUBKEY_HOW}"
        _next "TMPDIR=/tmp sh scripts/device/probes.sh --probe key"
        return 0
    fi
    trap 'rm -rf "${_tmpdir:-/nonexistent/ab-probes}"' EXIT INT TERM HUP
    if ! printf '%s\n' "${_pub}" >"${_tmpdir}/key.pub" 2>/dev/null; then
        rm -rf "${_tmpdir}"
        _tmpdir=""
        _emit key "${_ac}" fail reason=local-tmpdir-unwritable "pubkey=${PUBKEY_HOW}"
        _next "TMPDIR=/tmp sh scripts/device/probes.sh --probe key"
        return 0
    fi

    if ! dev_push "${_tmpdir}/key.pub" /tmp/ab-probes-key.pub >/dev/null 2>&1; then
        _emit key "${_ac}" fail reason=push-failed "pubkey=${PUBKEY_HOW}"
        _next "cat ${_tmpdir}/key.pub | ssh -i ${AB_KEY} ${AB_HOST} 'cat > /tmp/ab-probes-key.pub'"
        _next "df -h /tmp   # the guest has no sftp-server, so the file is piped through cat"
        return 0
    fi

    _inst=$(dev_ssh "$(_remote_key_install)" 2>/dev/null) || _inst=""
    _install=$(_field "${_inst}" install)
    _copies=$(_field "${_inst}" key_copies)
    _mode=$(_field "${_inst}" key_mode)
    _after=$(_field "${_inst}" keys_after)
    _keys_path=$(_field "${_inst}" key_path)

    if dev_ssh true >/dev/null 2>&1; then
        _login=ok
    else
        _login=failed
    fi

    _shadow=$(dev_ssh "$(_remote_root_password)" 2>/dev/null) || _shadow=""
    _rootpw=$(_field "${_shadow}" root_password)
    case "${_rootpw}" in
        empty) _fallback=empty-password ;;
        set) _fallback=password-set ;;
        *) _fallback=unknown ;;
    esac

    _begin
    _install_ok=0
    _copies_ok=0
    _mode_ok=0
    case "${_install}" in
        installed | already-present) _install_ok=1 ;;
        "") _bad install-no-output ;;
        *) _bad "${_install}" ;;
    esac
    case "${_copies:-}" in
        1) _copies_ok=1 ;;
        0 | "") _bad key-absent ;;
        *[!0-9]*) _bad key-copies-unknown ;;
        *) _bad "key-duplicated-${_copies}" ;;
    esac
    case "${_mode:-}" in
        -rw------- | -rw-r--r--) _mode_ok=1 ;;
        "") _bad key-mode-unknown ;;
        *) _bad key-mode ;;
    esac
    [ "${_login}" = "ok" ] || _bad key-login

    _tokens="key_state=${_install:-none} key_path=${_keys_path:-${AB_PROBE_AUTH_KEYS}} key_copies=${_copies:-none} key_mode=${_mode:-none} keys_after=${_after:-none} login=${_login} fallback=${_fallback} pubkey=${PUBKEY_HOW}"
    if [ -z "${REASONS}" ]; then
        _emit key "${_ac}" pass "${_tokens}"
    else
        _emit key "${_ac}" fail "reasons=${REASONS}" "${_tokens}"
        [ "${_login}" = "ok" ] ||
            _next "ssh -i ${AB_KEY} ${AB_HOST} true   # read the error: refused, or a passphrase prompt"
        [ "${_login}" = "ok" ] || _next "cat ${AB_PROBE_AUTH_KEYS}; ls -ld /etc/dropbear; logread | grep -i dropbear"
        [ "${_mode_ok}" -eq 1 ] || _next "chmod 600 ${AB_PROBE_AUTH_KEYS}"
        { [ "${_copies_ok}" -eq 1 ] && [ "${_install_ok}" -eq 1 ]; } ||
            _next "cat ${AB_PROBE_AUTH_KEYS}   # exactly one line per key, mode 600"
        _next "sh scripts/device/probes.sh --probe key"
    fi
    rm -rf "${_tmpdir}"
    _tmpdir=""
}

# --------------------------------------------------------------------------- #
# probe=platform (ac-2, the handoff §5.1 hole)
# --------------------------------------------------------------------------- #

probe_platform() {
    _ac=ac-2
    if [ "${DRY_RUN}" = "1" ]; then
        _emit platform "${_ac}" skip reason=dry-run
        _dry_plan platform "${_ac}" read-platform-sh "$(_remote_platform)"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _unreachable platform "${_ac}"
        return 0
    fi

    _facts=$(dev_ssh "$(_remote_platform)" 2>/dev/null) || _facts=""
    _present=$(_field "${_facts}" platform_sh)
    _begin_n=$(_field "${_facts}" upgrade_begin)
    _copy_n=$(_field "${_facts}" copy_rootfs)
    _stage=$(_field "${_facts}" platform_stage)
    _version=$(_field "${_facts}" platform_version)
    _upstream=$(_field "${_facts}" upstream_version)

    _begin
    case "${_present}" in
        present) : ;;
        missing) _bad platform-sh-missing ;;
        *) _bad platform-sh-unreadable ;;
    esac
    if [ "${_present}" = "present" ]; then
        case "${_begin_n:-}" in
            "" | *[!0-9]*) _bad upgrade-begin-unknown ;;
            0) _bad upgrade-begin-missing ;;
        esac
    fi

    # stage= is a fact, not this probe's verdict: ac-2's flash.sh owns it (handoff G4), but a
    # reader of this line should not have to ssh again to find out whether the running system
    # is an image or a payload.
    _tokens="platform_sh=${_present:-unknown} upgrade_begin=${_begin_n:-none} copy_rootfs=${_copy_n:-none} stage=${_stage:-unknown} platform=${_version:-unknown} upstream=${_upstream:-unknown}"
    if [ -z "${REASONS}" ]; then
        _emit platform "${_ac}" pass "${_tokens}"
        return 0
    fi
    _emit platform "${_ac}" fail "reasons=${REASONS}" "${_tokens}"
    _next "grep -c platform_upgrade_begin ${AB_PROBE_PLATFORM_SH}"
    _next "grep -c platform_copy_rootfs ${AB_PROBE_PLATFORM_SH}"
    case "${REASONS}" in
        *platform-sh-missing*) _next "ls -l /lib/upgrade/   # this image does not carry this project's platform layer" ;;
    esac
    _next "ab-upgrade --version   # PLATFORM_STAGE/PLATFORM_VERSION from the same release file"
}

# --------------------------------------------------------------------------- #
# probe=initrd (ac-11, the handoff §5.2 hole)
# --------------------------------------------------------------------------- #

probe_initrd() {
    _ac=ac-11
    _slot=${INITRD_SLOT}
    if [ -z "${_slot}" ] && [ "${REACH}" = "ok" ]; then
        if _status_once; then
            _running=$(status_field "${STATUS_LINE}" slot) || _running=""
            case "${_running}" in
                a) _slot=b ;;
                b) _slot=a ;;
            esac
        fi
    fi
    if [ "${DRY_RUN}" = "1" ]; then
        _emit initrd "${_ac}" skip reason=dry-run "slot=${_slot:-auto}"
        _dry_note "ab-slot status   # the target slot is the one that is not running"
        _dry_plan initrd "${_ac}" inspect-initrd "$(_remote_initrd "${_slot}")"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _unreachable initrd "${_ac}"
        return 0
    fi
    if [ -z "${_slot}" ]; then
        _emit initrd "${_ac}" gap reason=status-unreadable "slot=unknown"
        _next "ab-slot status   # the target slot is derived from the running slot"
        return 0
    fi

    _facts=$(dev_ssh "$(_remote_initrd "${_slot}")" 2>/dev/null) || _facts=""
    _state=$(_field "${_facts}" initrd)
    _method=$(_field "${_facts}" method)
    _magic=$(_field "${_facts}" magic)
    _tokens="slot=${_slot} initrd=${_state:-unknown} method=${_method:-none}"
    [ -n "${_magic}" ] && _tokens="${_tokens} magic=${_magic}"

    case "${_state}" in
        ok)
            _emit initrd "${_ac}" pass "${_tokens}"
            ;;
        absent)
            # Decompression worked and the symbol is genuinely not in there: that is a verdict,
            # not a gap. An initramfs from before the counter exists cannot retry or abandon.
            _emit initrd "${_ac}" fail reasons=guard-absent "${_tokens}"
            _next "gzip -dc /boot/initrd-${_slot} | grep -c wf_boot_attempt_guard"
            _next "ls -l /boot/initrd-*   # the target slot needs an initramfs built from this source"
            ;;
        missing)
            # Nothing to inspect. Per the audit this is a GAP, not a FAIL: the probe cannot
            # tell a missing payload from a slot that was never provisioned.
            _emit initrd "${_ac}" gap reason=initrd-missing "${_tokens}"
            _next "ls -l /boot/initrd-* /boot/vmlinuz-*"
            _next "ab-slot pending ${_slot}   # refuses a slot whose payload is missing; that is the real defect to chase"
            ;;
        *)
            _emit initrd "${_ac}" gap reason=initrd-undecidable "${_tokens}"
            _next "dd if=/boot/initrd-${_slot} bs=2 count=1 2>/dev/null | od -An -tx1   # 1f 8b is gzip; anything else needs its own decompressor"
            ;;
    esac
}

# --------------------------------------------------------------------------- #
# probe=packages (ac-6)
# --------------------------------------------------------------------------- #

probe_packages() {
    _ac=ac-6
    if [ "${DRY_RUN}" = "1" ]; then
        _emit packages "${_ac}" skip reason=dry-run
        _dry_note "ab-slot status"
        _dry_plan packages "${_ac}" find-docker "$(_remote_docker)"
        return 0
    fi
    if [ "${REACH}" != "ok" ]; then
        _unreachable packages "${_ac}"
        return 0
    fi
    if ! _status_once; then
        _emit packages "${_ac}" fail reason=status-unreadable
        _next "ab-slot status"
        _next "cat /boot/ab/state.json   # the status line is built from it"
        return 0
    fi

    _pkg=$(status_field "${STATUS_LINE}" packages) || _pkg=""
    _pkg_reason=$(status_field "${STATUS_LINE}" packages_reason) || _pkg_reason=""
    _run_slot=$(status_field "${STATUS_LINE}" slot) || _run_slot=""
    _committed=$(status_field "${STATUS_LINE}" committed) || _committed=""
    _pending=$(status_field "${STATUS_LINE}" pending) || _pending=""

    _docker_facts=$(dev_ssh "$(_remote_docker)" 2>/dev/null) || _docker_facts=""
    _docker_state=$(printf '%s\n' "${_docker_facts}" | sed -n "s/^${AB_PROBE_DOCKER}=\([^ ]*\).*/\1/p" | head -n 1)
    _docker_path=$(printf '%s\n' "${_docker_facts}" | sed -n "s/^${AB_PROBE_DOCKER}=[^ ]* path=//p" | head -n 1)
    _dockerd_state=$(printf '%s\n' "${_docker_facts}" | sed -n 's/^dockerd=\([^ ]*\).*/\1/p' | head -n 1)

    _begin
    [ "${_pkg}" = "${AB_PROBE_PACKAGES}" ] || _bad packages-mismatch
    case "${_docker_state}" in
        exec-ok) : ;;
        "") _bad docker-unknown ;;
        not-executable) _bad docker-not-executable ;;
        *)
            case "${_dockerd_state}" in
                exec-ok) _bad docker-cli-missing ;;
                *) _bad docker-missing ;;
            esac
            ;;
    esac

    _tokens="packages=${_pkg:-unknown} packages_reason=${_pkg_reason:-unknown} docker=${_docker_state:-unknown} docker_path=${_docker_path:-none} dockerd=${_dockerd_state:-none} slot=${_run_slot:-unknown} committed=${_committed:-unknown} pending=${_pending:-unknown}"
    if [ -z "${REASONS}" ]; then
        _emit packages "${_ac}" pass "${_tokens}"
        return 0
    fi
    _emit packages "${_ac}" fail "reasons=${REASONS}" "${_tokens}"
    case "${REASONS}" in
        *packages*) _next "ab-slot status; uci -q get ab.packages   # packages= is aligned only when the slot's metadata names its kernel" ;;
    esac
    case "${REASONS}" in
        *docker*) _next "apk add docker; command -v docker; docker --version" ;;
    esac
    _next "sh scripts/device/probes.sh --probe packages"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

printf 'probes start host=%s key=%s probes=%s dry_run=%s\n' \
    "${AB_HOST}" "${AB_KEY}" "$(printf '%s' "${SELECTED}" | tr -s ' ' ',' | sed 's/^,//; s/,$//')" "${DRY_RUN}"

_preflight

for _probe in ${SELECTED}; do
    case "${_probe}" in
        grow) probe_grow ;;
        network) probe_network ;;
        wan22) probe_wan22 ;;
        key) probe_key ;;
        platform) probe_platform ;;
        initrd) probe_initrd ;;
        packages) probe_packages ;;
    esac
done

if [ "${DRY_RUN}" = "1" ]; then
    _result=dry-run
elif [ "${PROBE_FAIL}" -gt 0 ]; then
    _result=fail
elif [ $((PROBE_GAP + PROBE_SKIP)) -gt 0 ]; then
    _result=incomplete
else
    _result=pass
fi

printf 'probes summary probes=%s pass=%s fail=%s gap=%s skip=%s result=%s\n' \
    "${PROBE_TOTAL}" "${PROBE_PASS}" "${PROBE_FAIL}" "${PROBE_GAP}" "${PROBE_SKIP}" "${_result}"

case "${_result}" in
    pass | dry-run) exit 0 ;;
    fail) exit 1 ;;
    *) exit 3 ;;
esac
