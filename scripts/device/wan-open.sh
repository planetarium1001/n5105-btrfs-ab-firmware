#!/bin/sh
# wan-open.sh - open (or restore) the whole WAN zone on the bench machine.
#
#   wan-open.sh                # open the WAN zone, one verdict line
#   wan-open.sh --restore      # put the firewall back exactly as it was
#   wan-open.sh --status       # what the zone says now, and whether a backup exists
#   wan-open.sh --dry-run      # the plan, nothing sent
#
# Why this exists as a driver and not as a paragraph of instructions: while a machine is
# being debugged on a lab LAN, the WAN zone's `input REJECT` is the difference between
# "the web UI does not load" and "the web UI answered 403 with the login page". Enumerating
# the ports that happen to be needed (22 for the -wan-ssh variant, 80 for the UI, 443 when
# a theme adds it) turns every missing rule into a fault that looks like a product defect,
# and it is the same class of mistake as reading a status code without its body.
#
# This is a *bench* action. It is not shipped behaviour: the release images keep the
# upstream default (wan input REJECT) and the -wan-ssh variant opens 22 only. The backup
# is written once, to /root/, which no upgrade or rollback of this project touches.
#
# Verdict line: wan-open=ok zone=<index> input=<old>-><new> backup=<path>
#               wan-restore=ok input=<new> sha256=<verified>
#               wan=unchanged input=<state> backup=<path|none>
set -u

DEVICE_DIR=$(cd "$(dirname "$0")" && pwd)
: "${AB_REPO_ROOT:=$(cd "${DEVICE_DIR}/../.." && pwd)}"
export AB_REPO_ROOT
# shellcheck source=scripts/device/lib.sh
. "${DEVICE_DIR}/lib.sh"

MODE=open
DRY_RUN=${AB_DRY_RUN:-0}
BACKUP=/root/firewall.before-open-wan.bak
BACKUP_SUM=/root/firewall.before-open-wan.sha256

usage() {
    printf 'usage: wan-open.sh [--open|--restore|--status] [--dry-run]\n' >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --open) MODE=open ;;
        --restore) MODE=restore ;;
        --status) MODE=status ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

# The WAN zone is found by name, not by index: a config that grew a zone would otherwise
# open the wrong one, and that is a firewall change nobody asked for.
_remote_open() {
    cat <<REMOTE
set -u
file=/etc/config/firewall
backup=${BACKUP}
backup_sum=${BACKUP_SUM}
zone=\$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -n 1)
[ -n "\${zone}" ] || { printf 'wan-open=fail reason=no-wan-zone\n'; exit 0; }
old=\$(uci -q get "firewall.\${zone}.input")
if [ ! -f "\${backup}" ]; then
    cp "\${file}" "\${backup}" || { printf 'wan-open=fail reason=backup-failed\n'; exit 0; }
    sha256sum "\${backup}" >"\${backup_sum}" 2>/dev/null || :
fi
if [ "\${old}" = "ACCEPT" ]; then
    printf 'wan=unchanged input=ACCEPT zone=%s backup=%s\n' "\${zone}" "\${backup}"
    exit 0
fi
uci set "firewall.\${zone}.input=ACCEPT" && uci commit firewall || {
    printf 'wan-open=fail reason=uci-commit-failed\n'; exit 0; }
fw4 reload >/dev/null 2>&1 || { printf 'wan-open=fail reason=fw4-reload-failed\n'; exit 0; }
now=\$(uci -q get "firewall.\${zone}.input")
printf 'wan-open=%s zone=%s input=%s->%s backup=%s\n' \
    "\$([ "\${now}" = "ACCEPT" ] && printf ok || printf fail)" \
    "\${zone}" "\${old}" "\${now}" "\${backup}"
REMOTE
}

_remote_restore() {
    cat <<REMOTE
set -u
backup=${BACKUP}
backup_sum=${BACKUP_SUM}
zone=\$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -n 1)
if [ ! -f "\${backup}" ]; then
    printf 'wan-restore=fail reason=no-backup path=%s\n' "\${backup}"; exit 0
fi
want=\$(sha256sum "\${backup}" 2>/dev/null | cut -d' ' -f1)
have=\$(cut -d' ' -f1 "\${backup_sum}" 2>/dev/null)
if [ -n "\${have}" ] && [ "\${want}" != "\${have}" ]; then
    printf 'wan-restore=fail reason=backup-sha256-mismatch want=%s have=%s\n' "\${want}" "\${have}"; exit 0
fi
cp "\${backup}" /etc/config/firewall || { printf 'wan-restore=fail reason=copy-failed\n'; exit 0; }
uci commit firewall || { printf 'wan-restore=fail reason=uci-commit-failed\n'; exit 0; }
fw4 reload >/dev/null 2>&1 || { printf 'wan-restore=fail reason=fw4-reload-failed\n'; exit 0; }
now=\$(uci -q get "firewall.\${zone}.input")
printf 'wan-restore=ok input=%s sha256=%s\n' "\${now:-unknown}" "\$([ -n "\${have}" ] && printf verified || printf unrecorded)"
REMOTE
}

_remote_status() {
    cat <<REMOTE
set -u
zone=\$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p" | head -n 1)
input=\$(uci -q get "firewall.\${zone}.input")
if [ -f ${BACKUP} ]; then b=${BACKUP}; else b=none; fi
printf 'wan=input=%s zone=%s backup=%s\n' "\${input:-unknown}" "\${zone:-none}" "\${b}"
REMOTE
}

case "${MODE}" in
    open) script=$(_remote_open) ;;
    restore) script=$(_remote_restore) ;;
    status) script=$(_remote_status) ;;
esac

if [ "${DRY_RUN}" = "1" ]; then
    printf 'dry-run: ssh %s (mode=%s)\n' "${AB_HOST}" "${MODE}"
    printf '%s\n' "${script}"
    exit 0
fi

out=$(dev_ssh "${script}") || {
    printf 'wan-open=fail reason=unreachable host=%s\n' "${AB_HOST}"
    exit 1
}
printf '%s\n' "${out}"
case "${out}" in
    *"=fail"*|*"=fail "*) exit 1 ;;
esac
exit 0
