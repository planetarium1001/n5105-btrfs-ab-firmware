#!/bin/sh
# login-probe.sh - does an interactive login work on this machine?
#
#   scripts/device/login-probe.sh                    # both probes, one line each
#   scripts/device/login-probe.sh --probe pty        # pty + controlling terminal only
#   scripts/device/login-probe.sh --probe login      # login shell reaching a prompt only
#   AB_DRY_RUN=1 scripts/device/login-probe.sh       # print the ssh calls, touch nothing
#   scripts/device/login-probe.sh --hold 15          # a slower machine, longer session
#
# Output shape, one line per probe:
#
#   probe=<pty|login> ac=ac-3 status=<pass|fail|skip> <fact=value...>
#
#   probe=pty    ac-3  the session shell's stdin is a /dev/pts/N and its tty_nr in
#                      /proc/<pid>/stat is non-zero - the pty was allocated and TIOCSCTTY
#                      succeeded, whatever the client did with stdin
#   probe=login  ac-3  a pty session with no command reaches the login shell: the output
#                      ends with a prompt (`root@<host>:<dir>#`)
#
# Exit status: 0 both probes passed, 1 at least one failed, 3 nothing failed but at least
# one probe was not answered (skip), 2 bad usage.
#
# Why the stdin of every session here stays open
# ----------------------------------------------
# dropbear 2025.89 closes the pty master as soon as one direction of the channel finishes
# (upstream e28ba1b / mkj/dropbear#365), so `ssh -tt host cmd </dev/null` cannot get a pty
# on this image and will report three errors that look like device-node faults. They are
# not: see docs/known-limitations.md. Every session below therefore goes through
# `dev_ssh_tty`, which holds the client stdin open for the length of the session. A probe
# that redirects /dev/null into an interactive ssh is measuring the client, not the machine.
#
# What this probe does not decide
# -------------------------------
# - A real console (serial or HDMI) is a different path through the same login scripts and
#   is not reachable over ssh; ac-4 is a person at the machine.
# - The approximation boundary: a keeper pipe proves that the server can allocate a pty and
#   set a controlling terminal for a client that does not close stdin early. It does not
#   prove that a human typing at a terminal gets a prompt faster than the hold, and it does
#   not prove anything about terminal size, flow control or job control.
# - `tty` is not probed: this image's busybox has no `tty` applet (measured 2026-11-17,
#   `command -v tty` prints nothing), so `ssh -tt ... tty` answers `ash: tty: not found` on
#   a perfectly healthy machine. That message is a property of the userland, not of the pty,
#   and it is exactly the kind of false signal this script must not produce. readlink and
#   /proc/<pid>/stat are present on both the reference image and any OpenWrt the project
#   supports.

set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
AB_REPO_ROOT=$(cd "${DEVICE_DIR}/../.." && pwd)
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

DRY_RUN=${AB_DRY_RUN:-0}
SELECTED=""
HOLD=${AB_SSH_TTY_HOLD:-8}
# The prompt a login shell prints. The user name is the assumption that holds on this
# image (`root` with an empty password, `PermitRootLogin` unchanged); the host and the
# directory are not, so only the `@` and the trailing `#` are asserted.
AB_LOGIN_USER_PATTERN=${AB_LOGIN_USER_PATTERN:-root@}

usage() {
    cat <<'USAGE'
usage: login-probe.sh [--probe <pty|login>]... [--hold <seconds>] [--dry-run]

  --probe <name>  run one probe; repeatable. One of: pty login (default: both)
  --hold <n>      how long the client stdin stays open, in seconds (default 8)
  --dry-run       print the ssh calls and exit; same as AB_DRY_RUN=1

Environment: AB_HOST (root@host), AB_KEY (private key), AB_SSH_TTY_HOLD (8),
             AB_LOGIN_USER_PATTERN (root@), AB_EVIDENCE_LOG (lib.sh ev), AB_DRY_RUN.
USAGE
}

# _emit <probe> <status> <facts...>: one machine-parseable verdict line, and the same
# verdict in the evidence log when one is open.
_emit() {
    _e_probe=$1
    _e_status=$2
    shift 2
    printf 'probe=%s ac=ac-3 status=%s' "${_e_probe}" "${_e_status}"
    if [ $# -gt 0 ]; then
        printf ' %s' "$*"
    fi
    printf '\n'
    ev "login-probe probe=${_e_probe} status=${_e_status} $*"
}

# _reachable: one non-interactive question first, so an offline machine is a skip with a
# reason instead of a pty failure that reads like a dropbear regression.
_reachable() {
    dev_ssh true >/dev/null 2>&1
}

# probe_pty: the pty exists, it is the session's stdin, and the shell has a controlling
# terminal. tty_nr is field 7 of /proc/<pid>/stat: 136<<8 = 34816 for /dev/pts/0, and 0
# would mean "no controlling terminal", which is what the broken measurement produced.
probe_pty() {
    if [ "${DRY_RUN}" = "1" ]; then
        _emit pty skip reason=dry-run
        return 0
    fi
    if ! _reachable; then
        _emit pty skip reason=no-ssh host="${AB_HOST}"
        return 3
    fi
    _out=$(dev_ssh_tty "${HOLD}" \
        'readlink /proc/$$/fd/0; echo "tty_nr=$(awk "{print \$7}" "/proc/$$/stat")"') || :
    # A pty is in cooked mode, so the slave side turns every newline into CRLF on the way
    # back. Nothing below would match a line that still carries the CR (measured: the first
    # version of this probe reported tty_nr=none on a healthy machine).
    _out=$(printf '%s\n' "${_out}" | tr -d '\r')
    _fd0=$(printf '%s\n' "${_out}" | sed -n '1p')
    _tty_nr=$(printf '%s\n' "${_out}" | sed -n 's/^tty_nr=\([0-9][0-9]*\)$/\1/p' | head -n 1)
    if [ "${_fd0#/dev/pts/}" != "${_fd0}" ] \
        && [ -n "${_tty_nr}" ] && [ "${_tty_nr}" -gt 0 ]; then
        _emit pty pass fd0="${_fd0}" tty_nr="${_tty_nr}"
        return 0
    fi
    _emit pty fail fd0="${_fd0:-none}" tty_nr="${_tty_nr:-none}" hold_s="${HOLD}"
    printf '  next: scripts/device/login-probe.sh --probe pty --hold 20\n'
    printf '  next: ssh %s logread | grep -i dropbear\n' "${AB_HOST}"
    return 1
}

# probe_login: no remote command, so dropbear starts the login shell; the output has to
# end in a prompt. The MOTD comes first, the prompt is the last thing on the pty.
probe_login() {
    if [ "${DRY_RUN}" = "1" ]; then
        _emit login skip reason=dry-run
        return 0
    fi
    if ! _reachable; then
        _emit login skip reason=no-ssh host="${AB_HOST}"
        return 3
    fi
    _out=$(dev_ssh_tty "${HOLD}") || :
    _last=$(printf '%s\n' "${_out}" | sed -n '/[^[:space:]]/p' | tail -n 1)
    # The prompt is unterminated on the pty, so the last non-empty line is usually
    # `root@ImmortalWrt:~#` with the cursor after it. Trailing control bytes are dropped
    # for the verdict line only; the byte count keeps the raw size visible.
    _prompt=$(printf '%s' "${_last}" | tr -d '\r' | sed 's/[[:space:]]*$//')
    _bytes=$(printf '%s' "${_out}" | wc -c | tr -d ' ')
    case "${_prompt}" in
        *"${AB_LOGIN_USER_PATTERN}"*"#"*)
            _emit login pass prompt="${_prompt}" bytes="${_bytes}" hold_s="${HOLD}"
            return 0
            ;;
    esac
    _emit login fail prompt="${_prompt:-none}" bytes="${_bytes}" hold_s="${HOLD}"
    printf '  next: scripts/device/login-probe.sh --probe login --hold 20\n'
    printf '  next: ssh %s cat /etc/profile /etc/profile.d/*.sh\n' "${AB_HOST}"
    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --probe)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            case "$2" in
                pty | login) SELECTED="${SELECTED} $2" ;;
                *) printf 'unknown probe: %s\n' "$2" >&2; usage >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --hold)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            case "$2" in
                '' | *[!0-9]*) printf 'hold must be a whole number of seconds\n' >&2; exit 2 ;;
            esac
            HOLD=$2
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "${DRY_RUN}" = "1" ] && export AB_DRY_RUN=1
[ -n "${SELECTED}" ] || SELECTED=" pty login"

failed=0
skipped=0
for _probe in ${SELECTED}; do
    case "${_probe}" in
        pty)
            probe_pty
            _rc=$?
            ;;
        login)
            probe_login
            _rc=$?
            ;;
        *) _rc=2 ;;
    esac
    case "${_rc}" in
        0) : ;;
        3) skipped=$((skipped + 1)) ;;
        *) failed=$((failed + 1)) ;;
    esac
done

if [ "${DRY_RUN}" = "1" ] && [ "${failed}" -eq 0 ]; then
    printf 'result=dry-run\n'
    exit 0
fi
if [ "${failed}" -gt 0 ]; then
    printf 'result=fail\n'
    exit 1
fi
if [ "${skipped}" -gt 0 ]; then
    printf 'result=skip\n'
    exit 3
fi
printf 'result=pass\n'
exit 0
