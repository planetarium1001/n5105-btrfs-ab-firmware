#!/usr/bin/env bash
# Module: ci
# An image carries either the production boot initramfs or the S1 probe, and only one of
# the two can boot a real machine. v0.0.6 and v0.0.7 published the probe: S2 built it
# (S2's job is to test assembly), S3 rebuilt a bootable one and kept it to itself, and the
# release published S2's artifact. Every QEMU test stayed green because no stage ever
# booted what was published; the first real machine powered off at the GRUB menu.
#
# So two things are locked here, statically and behaviourally:
#   ac-1 the release takes image-install (S3's booted image), never image-probe
#   ac-2 the build refuses a probe initramfs unless it is allowed on purpose
#   ac-3 the release refuses bytes whose initrd is not the production init
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

s2="$root/.github/workflows/ci-s2.yml"
s3="$root/.github/workflows/ci-s3.yml"
# Publishing - including the image kind gate - lives in the shared reusable workflow.
rel="$root/.github/workflows/release-publish.yml"
disk="$root/scripts/ci/disk.sh"

# --------------------------------------------------------------------------- #
# ac-1: artifact names say what they are, and the release takes the bootable one
# --------------------------------------------------------------------------- #

assert_contains "$(cat "$rel")" 'name: ${{ inputs.image-artifact }}' \
    "ac-1 the release downloads the artifact the caller names"
assert_contains "$(cat "$rel")" "default: image-install" \
    "ac-1 the install image stays the default artifact of the release"
assert_contains "$(cat "$s3")" "name: image-install" \
    "ac-1 S3 uploads the image it actually booted"
assert_contains "$(cat "$s2")" "name: image-probe" \
    "ac-1 S2's artifact is named as the probe it is"

# The old name must be gone everywhere: it described neither of the two.
leftovers="$(grep -rn "disk-image" "$root/.github/workflows" 2>/dev/null || true)"
assert_eq "${leftovers}" "" "ac-1 no workflow refers to the ambiguous 'disk-image' name"

# --------------------------------------------------------------------------- #
# ac-2: the build refuses a probe image unless the caller says so
# --------------------------------------------------------------------------- #

assert_contains "$(cat "$s2")" "CI_INITRAMFS_KIND: probe" \
    "ac-2 S2 declares that it installs the probe"
assert_contains "$(cat "$s2")" 'CI_ALLOW_PROBE_INIT: "1"' \
    "ac-2 S2 allows the probe explicitly"
assert_contains "$(cat "$disk")" "ii_refuse_probe" \
    "ac-2 disk.sh goes through the identity guard"
assert_contains "$(cat "$disk")" 'ab/image.json' \
    "ac-2 the image records which initramfs it carries"

# shellcheck source=scripts/ci/image-identity.sh
source "$root/scripts/ci/image-identity.sh"

ii_refuse_probe boot 0 && assert_eq "ok" "ok" "ac-2 a boot image builds" \
    || assert_eq "refused" "ok" "ac-2 a boot image builds"
ii_refuse_probe probe 1 && assert_eq "ok" "ok" "ac-2 an allowed probe image builds" \
    || assert_eq "refused" "ok" "ac-2 an allowed probe image builds"
if refusal="$(ii_refuse_probe probe 0)"; then
    assert_eq "accepted" "refused" "ac-2 a probe image without permission is refused"
else
    assert_contains "${refusal}" "not bootable on real hardware" \
        "ac-2 the refusal explains why, not just that"
fi
if ii_refuse_probe "" 1; then
    assert_eq "accepted" "refused" "ac-2 an unknown kind is refused"
fi
assert_contains "$(ii_image_json boot initrd-a 0.0.8 25.12.2 2026-11-11T00:00:00Z closed)" '"kind": "boot"' \
    "ac-2 the recorded identity names the kind"

# --------------------------------------------------------------------------- #
# ac-3: the release checks the bytes, not the label
# --------------------------------------------------------------------------- #

rel_text="$(cat "$rel")"
assert_contains "$rel_text" "Verify the image is bootable" \
    "ac-3 the release has a byte-level gate"
assert_contains "$rel_text" "S3 boot init" \
    "ac-3 the gate looks for the production init"
assert_contains "$rel_text" "S1-RESULT" \
    "ac-3 the gate rejects the probe init"
assert_contains "$rel_text" '"kind"' \
    "ac-3 the gate reads ab/image.json"

# The build-time half of the same contract: image-verify checks the record against what
# the build said it installed, so a caller cannot quietly swap the initramfs.
iv_text="$(cat "$root/scripts/ci/image-verify.sh")"
assert_contains "$iv_text" "ab/image.json" \
    "ac-2 image-verify reads the recorded identity"
assert_contains "$iv_text" 'CI_INITRAMFS_KIND:-boot' \
    "ac-2 image-verify compares it with what the build installed"

# --------------------------------------------------------------------------- #
# ac-5: the growth path is actually executed somewhere
# --------------------------------------------------------------------------- #
# A shipped image fills its own disk, so `grow` used to be a code path no test ever ran -
# which is how a broken last-lba field reached a machine. The S4 fixture now appends a
# tail and the first boot has to grow into it.
s4_text="$(cat "$root/.github/workflows/ci-s4.yml")"
assert_contains "$s4_text" "--grow-tail 2048" \
    "ac-5 the S4 fixture gives the image a tail to grow into"
assert_contains "$s4_text" "stage=grow slot=a result=done" \
    "ac-5 the first boot is gated on a completed growth"
assert_contains "$(cat "$root/scripts/ci/ab-fixtures.sh")" "--grow-tail" \
    "ac-5 the fixture implements --grow-tail"

# The reason has to survive on the ESP, not only in the ring log: a machine without a UART
# has no other place to read it.
assert_contains "$s4_text" 'ab-fixtures.sh --cat ab/log/grow.log "${out}"' \
    "ac-5 the run gates on the grow log reaching the ESP"
assert_contains "$s4_text" 'grep -q '\''\[grow\]'\'' "${out}"' \
    "ac-5 and on it carrying actual [grow] lines"
assert_contains "$(cat "$root/scripts/ci/ab-fixtures.sh")" "mount_one_ro" \
    "ac-5 the ESP reader mounts read-only"
assert_contains "$(cat "$root/scripts/ci/ab-fixtures.sh")" "unmount_part() { # <mountpoint>" \
    "ac-5 the ESP reader unmounts without disk.sh's helper"

# The image records which WAN SSH default it carries, so the release preflight can refuse
# an open image published under the default name without mounting a btrfs filesystem.
assert_contains "$(ii_image_json boot initrd-a 0.0.8 25.12.2 2026-11-11T00:00:00Z closed)" \
  '"net_wan_ssh": "closed"' "the image record states the WAN SSH default"
assert_contains "$(ii_image_json boot initrd-a 0.0.8 25.12.2 2026-11-11T00:00:00Z open)" \
  '"net_wan_ssh": "open"' "the convenience image records open"

finish
