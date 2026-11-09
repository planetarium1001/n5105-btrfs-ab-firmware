#!/bin/sh
# Post-switch assertion for S3. Runs as the new /init, inside the composed root.
#
# switch_root has already moved /proc /sys /dev and thrown the initramfs away, so
# this script is self-contained: it cannot source the initramfs helpers. It proves
# the things that can only be true after the switch:
#
#   * / is the overlay, with both read-only layers and the generation's upper
#   * files from @wf and @sys are visible in the merged view
#   * probe files written through / end up in <generation>/upper and nowhere else,
#     re-checked by mounting the btrfs subvolumes again read-only
#   * the probe written by the previous boot is still there
#
# Arguments: <slot> <gen> <gen-name> <boot> <shared-dev> <slot-dev>
#
# Judge line, frozen:
#   S3-RESULT=ok slot=<a|b> gen=<N> lower=<wf:sys> upper=<gen> root=<overlay>

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH

slot="${1:-}"
gen="${2:-}"
gen_name="${3:-}"
boot="${4:-1}"
shared_dev="${5:-}"
slot_dev="${6:-}"

fail() {
    printf 'S3-RESULT=fail reason=%s\n' "$1"
    sync
    poweroff -f
    exit 1
}

log() {
    printf '[post] %s\n' "$*"
}

log "inside the composed root, slot=${slot} gen=${gen} boot=${boot}"
# /proc was moved into the new root by the init; only mount it if that did not happen.
[ -d /proc/self ] || mount -t proc proc /proc 2>/dev/null

root_line="$(awk '$2 == "/" { print }' /proc/mounts)"
[ -n "${root_line}" ] || fail root-not-in-mounts
case "${root_line}" in
    overlay*) : ;;
    *) fail "root-not-overlay-${root_line%% *}" ;;
esac
case "${root_line}" in
    *lowerdir=*@wf*@sys*) : ;;
    *) fail root-lowerdir-missing ;;
esac
# The upper is the p4 mount itself, so the generation name does not appear in the
# overlay line; it is proven below by re-opening that generation read-only.
case "${root_line}" in
    *upperdir=/mnt/p4/upper*) : ;;
    *) fail root-upperdir-wrong ;;
esac
log "/ is overlay: ${root_line}"

# Both layers must contribute to the merged view: @wf carries /etc/wf-release and
# @sys carries the upstream init.
[ -f /etc/wf-release ] || fail wf-release-missing
[ -x /sbin/init ] || fail sys-init-missing
[ -x /bin/sh ] || fail sys-shell-missing
log "@wf and @sys are both visible: $(tr '\n' ' ' </etc/wf-release)"

# --------------------------------------------------------------------------- #
# Probe persistence and copy-up
# --------------------------------------------------------------------------- #

probe=/.s3-probe
new_file="/.s3-new-${boot}"

if [ "${boot}" = "2" ]; then
    [ -f "${probe}" ] || fail probe-lost-between-boots
    case "$(cat "${probe}")" in
        *boot=1*) log "probe from the first boot found: $(cat "${probe}")" ;;
        *) fail probe-content-unexpected ;;
    esac
fi

printf 'boot=%s slot=%s gen=%s\n' "${boot}" "${slot}" "${gen}" >"${probe}" \
    || fail probe-write-failed
printf 'created on boot %s\n' "${boot}" >"${new_file}" || fail newfile-write-failed

# Re-open the block devices read-only and prove where the writes landed.
if [ -z "${shared_dev}" ] || [ -z "${slot_dev}" ]; then
    fail missing-device-arguments
fi
mkdir -p /mnt/s3-upper /mnt/s3-wf /mnt/s3-sys
mount -o ro,"subvol=/${gen_name}" "${shared_dev}" /mnt/s3-upper || fail remount-upper-failed
mount -o ro,"subvol=/@wf" "${slot_dev}" /mnt/s3-wf || fail remount-wf-failed
mount -o ro,"subvol=/@sys" "${slot_dev}" /mnt/s3-sys || fail remount-sys-failed

[ -f "/mnt/s3-upper/upper${probe}" ] || fail probe-not-in-upper
[ -f "/mnt/s3-upper/upper${new_file}" ] || fail newfile-not-in-upper
[ ! -e "/mnt/s3-wf${probe}" ] || fail probe-leaked-to-wf
[ ! -e "/mnt/s3-sys${probe}" ] || fail probe-leaked-to-sys
[ ! -e "/mnt/s3-wf${new_file}" ] || fail newfile-leaked-to-wf
[ ! -e "/mnt/s3-sys${new_file}" ] || fail newfile-leaked-to-sys

umount /mnt/s3-upper /mnt/s3-wf /mnt/s3-sys
log "probe writes are in ${gen_name}/upper only"

# --------------------------------------------------------------------------- #
# Verdict, then hand over to the upstream init
# --------------------------------------------------------------------------- #

printf 'S3-RESULT=ok slot=%s gen=%s lower=wf:sys upper=%s root=overlay\n' \
    "${slot}" "${gen}" "${gen_name}"
sync

# S3 stops here: the state machine and health checks are S4's job. Executing the
# upstream init proves the root actually is a working system, and the harness stops
# the machine as soon as the judge line appears.
if [ -x /sbin/init ]; then
    log "handing over to /sbin/init"
    exec /sbin/init
fi
poweroff -f
