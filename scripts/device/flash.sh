#!/bin/sh
# flash.sh - write a whole-disk image to a headless machine over SSH, then prove it booted.
#
# One question, one verdict: does the machine come back from a full-disk rewrite with no
# console, no keyboard and nobody at the power switch? The path a person would take is
# "pull the disk and dd it on a laptop"; this is the same operation from inside the running
# system, which is the only route when the machine is unreachable except over the WAN.
#
#   flash.sh --image <file.img.gz> --sha256 <hex> --i-know
#   flash.sh --image <file.img.gz> --sha256 <hex> --i-know --dry-run
#
# Environment: AB_HOST (root@host), AB_KEY (private key), AB_DISK (/dev/nvme0n1).
#
# Why the write and the reboot are one command: the image covers p1-p4, so the running
# system sits inside the region being overwritten. The image is staged in tmpfs (RAM) and
# consumed by busybox gunzip|dd, so nothing is read from the disk that is being destroyed;
# the moment dd returns, the kernel has nothing left to boot from, hence reboot -f
# immediately after it, in the same detached shell.
#
# The write is detached (setsid) on purpose: an ssh drop must not kill dd halfway.
#
# Verdict line: flash=ok wait=<s> boot=ok | flash=fail reason=<token>
#   reason=image-missing | sha-mismatch | stage-failed | no-space | no-setsid
#          | write-failed | no-boot-after-<s>
#
# A machine that does not come back has no automatic recovery: that is the documented
# cost of this route (docs/install.md, "the image is written from the running system").

set -u

AB_HOST=${AB_HOST:-root@192.168.2.49}
AB_KEY=${AB_KEY:-}
AB_DISK=${AB_DISK:-/dev/nvme0n1}
AB_STAGE=${AB_STAGE:-/tmp/ab-install.img.gz}
AB_WAIT=${AB_WAIT:-300}

image=""
sha=""
know=0
dry=0

say() { printf '%s\n' "$*"; }
die() { say "flash=fail reason=$1"; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) image=${2:-}; shift 2 ;;
        --sha256) sha=${2:-}; shift 2 ;;
        --i-know) know=1; shift ;;
        --dry-run) dry=1; shift ;;
        -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
        *) say "flash.sh: unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$image" ] || die usage-image
[ -n "$sha" ] || die usage-sha
[ "$know" -eq 1 ] || die needs-i-know

[ -f "$image" ] || die image-missing
local_sha=$(sha256sum "$image" 2>/dev/null | cut -d' ' -f1)
[ -n "$local_sha" ] || local_sha=$(shasum -a 256 "$image" | cut -d' ' -f1)
[ "$local_sha" = "$sha" ] || die sha-mismatch

ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10"
[ -n "$AB_KEY" ] && ssh_opts="-i $AB_KEY $ssh_opts"

dev_ssh() { ssh $ssh_opts "$AB_HOST" "$@" 2>/dev/null; }

if [ "$dry" -eq 1 ]; then
    say "dry-run: scp $image -> $AB_HOST:$AB_STAGE then gunzip -c | dd of=$AB_DISK bs=4M conv=fsync; reboot -f"
    say "flash=ok dry-run=1"
    exit 0
fi

dev_ssh 'command -v setsid >/dev/null' || die no-setsid

# Space: the compressed image on tmpfs, nothing else.
avail=$(dev_ssh "df -k $AB_STAGE 2>/dev/null | awk 'NR==2{print $4}'")
[ -n "$avail" ] || avail=$(dev_ssh "df -k /tmp | awk 'NR==2{print $4}'")
size_kb=$(( $(wc -c < "$image") / 1024 ))
[ -n "$avail" ] && [ "$avail" -lt $(( size_kb + 8192 )) ] && die no-space

# Stage the image. scp is not always available (no sftp-server on OpenWrt), so stream it.
gzip -dc "$image" >/dev/null 2>&1 || true
if ! cat "$image" | ssh $ssh_opts "$AB_HOST" "cat > $AB_STAGE" 2>/dev/null; then
    die stage-failed
fi
stage_sha=$(dev_ssh "sha256sum $AB_STAGE | cut -d' ' -f1")
[ "$stage_sha" = "$sha" ] || die sha-mismatch

start=$(date +%s)
dev_ssh "printf '%s\n' '#!/bin/sh' 'sync' 'killall -q syslogd logd crond 2>/dev/null' \
    'gunzip -c $AB_STAGE | dd of=$AB_DISK bs=4M conv=fsync' 'rc=\$?' 'sync' 'echo dd rc=\$rc' 'reboot -f' \
    > /tmp/ab-flash.sh; chmod +x /tmp/ab-flash.sh; setsid sh /tmp/ab-flash.sh </dev/null >/dev/null 2>&1 & sleep 1; echo launched"

# Wait for the machine to answer again: dd plus one boot.
elapsed=0
while [ "$elapsed" -lt "$AB_WAIT" ]; do
    sleep 5
    elapsed=$(( $(date +%s) - start ))
    if nc -z "${AB_HOST#*@}" 22 2>/dev/null; then
        say "flash=ok wait=$elapsed boot=ok"
        exit 0
    fi
done
say "flash=fail reason=no-boot-after-$AB_WAIT"
say "next: connect a monitor and keyboard, or pull the disk and write $image with dd (docs/install.md)"
exit 1
