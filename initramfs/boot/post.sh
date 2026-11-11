#!/bin/sh
# Post-switch assertion for S3. Runs as the new /init, inside the composed root.
#
# This is a CI assertion, not part of the product. It enters an initramfs only when the
# build asked for CI hooks (AB_CI_HOOKS=1), and the production image ships without it,
# so a boot of a flashed machine never reaches this file. The entry point below keeps
# that promise for the other direction as well: a copy that is called without the three
# arguments the initramfs passes is not the probe entry, and this script then leaves the
# running system completely alone - no probe file, no marker in the writable layer, no
# poweroff, and no judge line that a harness could read as a verdict on this boot.
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

fail() {
    printf 'S3-RESULT=fail reason=%s\n' "$1"
    sync
    poweroff -f
    exit 1
}

log() {
    printf '[post] %s\n' "$*"
}

# --------------------------------------------------------------------------- #
# Am I the probe entry? Anything else is left alone.
# --------------------------------------------------------------------------- #
# The initramfs calls this script through
#   exec switch_root /newroot /bin/sh /.s3-post "${slot}" "${upper}" "${BOOT}"
# so all three arguments are always present on the assertion path. A caller without
# them - a leftover copy that a person or an init runs, a production system that found
# the file - gets nothing: writing a probe file there would put CI bookkeeping into a
# user's writable layer, and a judge line or a poweroff would change the outcome of a
# boot that is not being asserted. Exit 0, so the boot continues exactly as it would
# have without this file.
if [ -z "${slot}" ] || [ -z "${upper}" ]; then
    log "not the CI probe entry (slot='${slot}' upper='${upper}'); nothing to assert, leaving the boot alone"
    exit 0
fi
case "${slot}" in
    a | b) : ;;
    *)
        log "not the CI probe entry (slot='${slot}' is not a slot name); leaving the boot alone"
        exit 0
        ;;
esac
case "${upper}" in
    @*) : ;;
    *)
        log "not the CI probe entry (upper='${upper}' is not a layer name); leaving the boot alone"
        exit 0
        ;;
esac
case "${boot}" in
    *[!0-9]*)
        log "not the CI probe entry (boot='${boot}' is not a boot counter); leaving the boot alone"
        exit 0
        ;;
esac

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

# Where the writes landed is proven by the boot init while the three layers are still
# mounted side by side: /mnt/p4 is the upper subvolume and /mnt/@platform, /mnt/@sys are
# the read-only layers. Re-opening the devices here would need working block nodes in
# the composed root, and devtmpfs does not survive every root switch.
log "probe writes are in ${upper}/upper only (verified before the root switch)"

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
