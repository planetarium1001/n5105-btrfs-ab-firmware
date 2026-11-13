#!/bin/sh
# feed-probe.sh - collect the facts `ac-11` asks for, in one pasteable block.
#
# The device checklist (tasks/20261113-02-.../scratch/real-device-checklist.md) walks a
# person through the same steps by hand. This script exists so the答案 is a block of text
# with a stable shape instead of a transcription exercise: what the machine can fetch
# with, what it is running, what the feed offers, and what the prompt decided.
#
# It writes nothing on the device: no config, no payload, no slot change. `--feed-check`
# is the read-only mode of ab-upgrade by design.
#
#   feed-probe.sh [--conf <path>] [--feed-url <url>]
#
# Output (one line per fact, so a paste into evidence stays diffable):
#
#   feed-probe fetchers=<list|none> https=<yes|no|unknown> ca=<yes|no> conf=<present|missing>
#   feed-probe installed=<platform> base=<base> kernel=<kernel>
#   feed-probe check <the ab-upgrade --feed-check line, or the failure reason>
#   feed-probe exit=<code>
#
# Exit status: 0 when the check ran to a verdict (0 or 10), 1 when it could not, 2 on
# usage. The device's own exit code is printed either way; this script's status is about
# whether the probe itself worked.

set -u

DEVICE_LIB="${AB_DEVICE_LIB:-$(dirname "$0")/lib.sh}"
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_LIB}"

conf=/etc/ab/update.conf
feed_url=""

usage() {
    cat <<'USAGE'
usage: feed-probe.sh [--conf <path>] [--feed-url <url>]

  --conf      the update configuration on the device (default /etc/ab/update.conf)
  --feed-url  ask about this feed for one run, without editing the config
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --conf) conf=${2:?--conf needs a value}; shift 2 ;;
        --feed-url) feed_url=${2:?--feed-url needs a value}; shift 2 ;;
        -h | --help | help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# One remote call for the cheap facts; the check is its own call so a hang there does not
# hide what the machine already told us.
facts=$(dev_ssh 'command -v uclient-fetch >/dev/null 2>&1 && printf "uclient-fetch,"; command -v wget >/dev/null 2>&1 && printf "wget,"; command -v curl >/dev/null 2>&1 && printf "curl,"; printf " "; ls /etc/ssl/certs >/dev/null 2>&1 && printf "ca=yes" || printf "ca=no"' 2>/dev/null) || {
    printf 'feed-probe unreachable\n'
    exit 1
}
fetchers=$(printf '%s\n' "${facts}" | sed 's/ .*//; s/,$//')
[ -n "${fetchers}" ] || fetchers=none
ca=$(printf '%s\n' "${facts}" | sed -n 's/.*ca=\([a-z]*\).*/\1/p')
[ -n "${ca}" ] || ca=unknown

# Whether the fetcher speaks TLS is not something `command -v` can answer: ask the tool.
https=unknown
case "${fetchers}" in
    *uclient-fetch*)
        if dev_ssh 'uclient-fetch --help 2>&1 | grep -qi "https"' >/dev/null 2>&1; then
            https=yes
        else
            https=no
        fi
        ;;
    *wget*)
        if dev_ssh 'wget --help 2>&1 | grep -qi "https"' >/dev/null 2>&1; then
            https=yes
        else
            https=no
        fi
        ;;
    *curl*) https=yes ;;
esac

if dev_ssh "test -f '${conf}'" >/dev/null 2>&1; then
    conf_state=present
else
    conf_state=missing
fi

release=$(dev_ssh 'cat /etc/platform-release 2>/dev/null' 2>/dev/null) || release=""
platform=$(printf '%s\n' "${release}" | sed -n 's/^PLATFORM_VERSION=//p' | head -n 1)
base=$(printf '%s\n' "${release}" | sed -n 's/^UPSTREAM_VERSION=//p' | head -n 1)
kernel=$(dev_ssh 'uname -r' 2>/dev/null | head -n 1) || kernel=""
[ -n "${platform}" ] || platform=unknown
[ -n "${base}" ] || base=unknown
[ -n "${kernel}" ] || kernel=unknown

printf 'feed-probe fetchers=%s https=%s ca=%s conf=%s\n' "${fetchers}" "${https}" "${ca}" "${conf_state}"
printf 'feed-probe installed=%s base=%s kernel=%s\n' "${platform}" "${base}" "${kernel}"

check_cmd="ab-upgrade --feed-check"
[ -n "${feed_url}" ] && check_cmd="${check_cmd} --feed-url '${feed_url}'"
line=$(dev_ssh "${check_cmd}" 2>&1)
rc=$?

# ab-upgrade prints the machine line on stdout and a refusal on the same channel; keep
# whichever appeared, because both are the fact this probe was asked for.
answer=$(printf '%s\n' "${line}" | grep -E '^(platform=|ab-upgrade: refused)' | head -n 1)
[ -n "${answer}" ] || answer=$(printf '%s\n' "${line}" | tail -n 1)
printf 'feed-probe check %s\n' "${answer:-<no output>}"
printf 'feed-probe exit=%s\n' "${rc}"

case "${rc}" in
    0 | 10) exit 0 ;;
    *) exit 1 ;;
esac
