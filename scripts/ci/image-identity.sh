#!/usr/bin/env bash
# Image identity: which initramfs an image carries, and whether it may be published.
#
# Why this file exists: an image is assembled by four different stages (S2, S3, S4, S5)
# and only some of them install the *production* boot initramfs. S2 deliberately installs
# the S1 module-load probe, because S2's job is to test image assembly before the boot
# chain exists - and the probe finds /dev/vda, so on any non-virtio machine it reports
# `S1-RESULT=fail reason=no-device-node` and powers the machine off.
#
# That produced v0.0.6 and v0.0.7: the released image carried the probe, every QEMU test
# was green (no stage ever booted the published artifact), and the first real machine shut
# itself down at the GRUB menu.
#
# So an image now says which initramfs it has, in two places:
#   * the build refuses to put the probe in unless CI_ALLOW_PROBE_INIT=1 is explicit
#   * the image carries ab/image.json on its ESP, and the release refuses anything whose
#     kind is not `boot`
#
# Sourced by scripts/ci/disk.sh; exercised by tests/modules/ci/test_image_identity.sh.

II_KINDS="probe boot"

# ii_kind_known <kind>: is this a kind we understand.
ii_kind_known() {
    case " ${II_KINDS} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# ii_refuse_probe <kind> <allow>: 0 when the build may continue; otherwise 1 and the
# reason on stdout, so the caller can put it straight into its own fatal message.
ii_refuse_probe() {
    local kind="${1:-}" allow="${2:-}"
    if ! ii_kind_known "${kind}"; then
        printf '%s\n' "unknown initramfs kind '${kind}' (expected one of: ${II_KINDS})"
        return 1
    fi
    if [ "${kind}" = "probe" ] && [ "${allow}" != "1" ]; then
        printf '%s\n' "this image would carry the S1 probe initramfs, which is not bootable on real hardware; set CI_INITRAMFS_KIND=boot or CI_ALLOW_PROBE_INIT=1 on purpose"
        return 1
    fi
    return 0
}

# ii_image_json <kind> <init_script> <platform_version> <upstream_version> <created_at>
#                <net_wan_ssh>
# The record the image carries about itself. Kept one line per key so a human can read it
# from the ESP, and so `grep kind= boot` is a valid check in a workflow.
ii_image_json() {
    local kind="$1" init_script="$2" platform="$3" upstream="$4" created="$5"
    # Which WAN SSH default this image carries. It is recorded here, on the ESP, because
    # the release preflight already mounts the ESP: a check that can be made without a
    # btrfs mount is a check that will actually run on every publish.
    local net_wan_ssh="${6:-closed}"
    cat <<JSON
{
  "kind": "${kind}",
  "init_script": "${init_script}",
  "platform_version": "${platform}",
  "upstream_version": "${upstream}",
  "created_at": "${created}",
  "net_wan_ssh": "${net_wan_ssh}"
}
JSON
}
