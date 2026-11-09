#!/bin/sh
# Post-switch assertion for S3. Runs as the new /init, inside the composed root.
#
# switch_root has already moved /proc /sys /dev and thrown the initramfs away, so
# this script is self-contained: it cannot source the initramfs helpers. It proves
# the things that can only be true after the switch:
#
#   * / is the overlay, with both read-only layers and the generation's upper
#   * files from @platform and @sys are visible in the merged view
#   * probe files written through / end up in the writable layer's upper directory
#     and nowhere else, re-checked by mounting the btrfs subvolumes again read-only
#   * the probe written by the previous boot is still there
#
# Arguments: <slot> <upper> <boot> <shared-dev> <slot-dev>
#   <upper> is the writable layer name from ab/state.json, for example
#   @overlay-25.12.2.
#
# Judge line, frozen:
#   S3-RESULT=ok slot=<a|b> upper=<@overlay-version> lower=<platform:sys> root=overlay

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH

slot="${1:-}"
upper="${2:-}"
boot="${3:-1}"
shared_dev="${4:-}"
slot_dev="${5:-}"

fail() {
    printf 'S3-RESULT=fail reason=%s\n' "$1"
    sync
    poweroff -f
    exit 1
}

log() {
    printf '[post] %s\n' "$*"
}

log "inside the composed root, slot=${slot} upper=${upper} boot=${boot}"
# /proc was moved into the new root by the init; only mount it if that did not happen.
[ -d /proc/self ] || mount -t proc proc /proc 2>/dev/null

root_line="$(awk '$2 == "/" { print }' /proc/mounts)"
[ -n "${root_line}" ] || fail root-not-in-mounts
case "${root_line}" in
    overlay*) : ;;
    *) fail "root-not-overlay-${root_line%% *}" ;;
esac
case "${root_line}" in
    *lowerdir=*@platform*@sys*) : ;;
    *) fail root-lowerdir-missing ;;
esac
# The upper is the p4 mount itself, so the layer name does not appear in the overlay
# line; it is proven below by re-opening that layer read-only.
case "${root_line}" in
    *upperdir=/mnt/p4/upper*) : ;;
    *) fail root-upperdir-wrong ;;
esac
log "/ is overlay: ${root_line}"

# Both layers must contribute to the merged view: @platform carries
# /etc/platform-release and @sys carries the upstream init.
[ -f /etc/platform-release ] || fail platform-release-missing
[ -x /sbin/init ] || fail sys-init-missing
[ -x /bin/sh ] || fail sys-shell-missing
log "@platform and @sys are both visible: $(tr '\n' ' ' </etc/platform-release)"

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

printf 'boot=%s slot=%s upper=%s\n' "${boot}" "${slot}" "${upper}" >"${probe}" \
    || fail probe-write-failed
printf 'created on boot %s\n' "${boot}" >"${new_file}" || fail newfile-write-failed

# Re-open the block devices read-only and prove where the writes landed.
if [ -z "${shared_dev}" ] || [ -z "${slot_dev}" ]; then
    fail missing-device-arguments
fi
# Mount points live at the root we own: the upstream /mnt carries its own meaning and
# may be a symlink or absent before rcS runs.
upper_mnt=/.s3-upper
platform_mnt=/.s3-platform
sys_mnt=/.s3-sys
mkdir -p "${upper_mnt}" "${platform_mnt}" "${sys_mnt}" || fail mountpoint-create-failed
mount -o ro,"subvol=/${upper}" "${shared_dev}" "${upper_mnt}" || fail remount-upper-failed
mount -o ro,"subvol=/@platform" "${slot_dev}" "${platform_mnt}" || fail remount-platform-failed
mount -o ro,"subvol=/@sys" "${slot_dev}" "${sys_mnt}" || fail remount-sys-failed

[ -f "${upper_mnt}/upper${probe}" ] || fail probe-not-in-upper
[ -f "${upper_mnt}/upper${new_file}" ] || fail newfile-not-in-upper
[ ! -e "${platform_mnt}${probe}" ] || fail probe-leaked-to-platform
[ ! -e "${sys_mnt}${probe}" ] || fail probe-leaked-to-sys
[ ! -e "${platform_mnt}${new_file}" ] || fail newfile-leaked-to-platform
[ ! -e "${sys_mnt}${new_file}" ] || fail newfile-leaked-to-sys

umount "${upper_mnt}" "${platform_mnt}" "${sys_mnt}"
rmdir "${upper_mnt}" "${platform_mnt}" "${sys_mnt}" 2>/dev/null || true
log "probe writes are in ${upper}/upper only"

# --------------------------------------------------------------------------- #
# Verdict, then hand over to the upstream init
# --------------------------------------------------------------------------- #

printf 'S3-RESULT=ok slot=%s upper=%s lower=platform:sys root=overlay\n' \
    "${slot}" "${upper}"
sync

# S3 stops here: the state machine and health checks are S4's job. Executing the
# upstream init proves the root actually is a working system, and the harness stops
# the machine as soon as the judge line appears.
if [ -x /sbin/init ]; then
    log "handing over to /sbin/init"
    exec /sbin/init
fi
poweroff -f
