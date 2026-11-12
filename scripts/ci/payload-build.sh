#!/usr/bin/env bash
# Stage "payload": build the upgrade payload the S5 test installs.
#
# The payload follows docs/conflicts-payload.md: a tar with a manifest, the rootfs
# tree, the kernel, the boot initramfs and the platform layer. For the test the rootfs
# is the upstream tree with one visible change (/etc/banner) plus a marker file, so
# "the slot really is running the payload" is observable from inside the guest.
#
# Inputs (environment):
#   CI_FETCH_DIR        directory holding upstream/rootfs.tar.gz and upstream/kernel.bin
#   CI_INITRAMFS        boot initramfs to ship as the target slot's initrd
#   CI_BOOT_SRC         ESP tree the bootloader comes from (default: $CI_TMP_ROOT/esp,
#                       which is what the esp stage produces). The payload carries
#                       EFI/BOOT/BOOTX64.EFI and the rendered boot/grub/grub.cfg, so an
#                       update can bring the bootloader forward instead of leaving the
#                       machine on the version it was flashed with. Without a boot tree
#                       the payload ships without one and says so; CI_REQUIRE_BOOTLOADER=1
#                       turns that into a hard failure.
#   CI_BOOTLOADER_CFG   rendered grub.cfg (default: ${CI_GRUB_OUTPUT}, else
#                       $CI_TMP_ROOT/disk/grub.cfg - what the image stage renders, which is
#                       the path CI takes - else rendered here)
#   CI_BOOTLOADER_VERSION  GRUB version for the manifest (default: from the esp stage,
#                       else parsed from the loader, else unknown)
#   CI_BOOT_SOURCE_IMAGE / CI_BOOT_SOURCE_SHA256  provenance of the boot tree (esp stage)
#   CI_PLATFORM_SRC     platform layer source tree (default: platform/)
#   CI_PLATFORM_RUNTIME_DIR  btrfs tooling staged by the runtime stage (default:
#                       $CI_TMP_ROOT/runtime). It is merged into the payload's platform
#                       layer: an upgraded slot has to run ab-boot, ab-commit and the
#                       reclamation, and all of them call btrfs. A payload without the
#                       tooling boots and then cannot commit - which is exactly the
#                       failure this input exists to prevent.
#   CI_PLATFORM_VERSION platform version recorded in the rendered release file (required;
#                       VERSION is the only source, there is no fallback)
#   CI_PAYLOAD_VERSION  rootfs version the payload claims (default: upstream + test tag)
#   CI_PAYLOAD_OUT      output tar path (default: $CI_TMP_ROOT/payload/payload.tar)
#
# Outputs: payload_path, payload_size, payload_sha256, payload_version, payload_layer,
#          payload_platform_bytes, payload_bootloader, payload_bootloader_sha256,
#          payload_grub_version

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"
# The bootloader member is built by a fragment shared with scripts/ci/assemble.sh: the
# published payload and this test payload have to carry it the same way.
# shellcheck source=scripts/ci/boot-member.sh
. "${CI_SCRIPT_DIR}/boot-member.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init payload

ci_require_cmd tar gzip python3

fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
initramfs="${CI_INITRAMFS:?CI_INITRAMFS is required}"
platform_src="${CI_PLATFORM_SRC:-${CI_REPO_ROOT}/platform}"
runtime_tree="${CI_PLATFORM_RUNTIME_DIR:-${CI_TMP_ROOT}/runtime}"
# No default on purpose: a fallback here recorded a version the image never had, and the
# release check that compares image, payload and tag could never match. assemble.sh and
# disk.sh lost theirs first; this one is the third writer of the same number.
platform_version="${CI_PLATFORM_VERSION:?CI_PLATFORM_VERSION is required, it is recorded in the payload release file}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
payload_version="${CI_PAYLOAD_VERSION:-${upstream_version}-test1}"
payload_out="${CI_PAYLOAD_OUT:-${CI_TMP_ROOT}/payload/payload.tar}"

rootfs_tar="${fetch_dir}/upstream/rootfs.tar.gz"
kernel="${fetch_dir}/upstream/kernel.bin"
[ -f "${rootfs_tar}" ] || ci_die "upstream rootfs not found: ${rootfs_tar}"
[ -f "${kernel}" ] || ci_die "upstream kernel not found: ${kernel}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"
[ -d "${platform_src}" ] || ci_die "platform tree not found: ${platform_src}"
[ -d "${runtime_tree}" ] || ci_die "runtime tree not found: ${runtime_tree}; a payload needs the btrfs tooling, see scripts/ci/platform-runtime.sh"

work="${CI_TMP_ROOT}/payload/work"
rm -rf "${work}"
mkdir -p "${work}/content/rootfs" "${work}/content/platform" "${work}/stage"
mkdir -p "$(dirname "${payload_out}")"

# --------------------------------------------------------------------------- #
# 1. Root filesystem with an observable change
# --------------------------------------------------------------------------- #

ci_log "extracting the upstream rootfs"
tar -xzf "${rootfs_tar}" -C "${work}/content/rootfs" --numeric-owner

cat >"${work}/content/rootfs/etc/banner" <<BANNER
   N5105 AB firmware ${payload_version}
   upgraded root, installed by ab-upgrade
BANNER
printf 'payload=%s\n' "${payload_version}" >"${work}/content/rootfs/etc/ab-payload-marker"
ci_log "payload rootfs carries /etc/banner and /etc/ab-payload-marker"

tar -czf "${work}/stage/rootfs.tar.gz" -C "${work}/content/rootfs" .

# --------------------------------------------------------------------------- #
# 2. Kernel, initramfs and platform layer
# --------------------------------------------------------------------------- #

cp "${kernel}" "${work}/stage/kernel.bin"
cp "${initramfs}" "${work}/stage/initramfs.cpio.gz"

cp -a "${platform_src}/." "${work}/content/platform/"
# The runtime closure is part of the layer, exactly like the one baked into the image:
# without it the upgraded slot has no btrfs, its boot hook records btrfs-tool-missing,
# the health check cannot run and the slot never commits (S5 boot3 hung on this).
cp -a "${runtime_tree}/." "${work}/content/platform/"
sed -i -e "s|@PLATFORM_VERSION@|${platform_version}|g" \
    -e "s|@UPSTREAM_VERSION@|${payload_version}|g" \
    -e "s|@PLATFORM_STAGE@|upgrade|g" \
    "${work}/content/platform/etc/platform-release"
if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${work}/content/platform/etc/platform-release"; then
    ci_die "platform-release still carries unreplaced placeholders"
fi
ci_render_net_defaults "${work}/content/platform"
# The layer that ships in a payload must be as runnable as the one baked into the image,
# including the rcS start links, otherwise an upgraded slot never starts the hooks.
# The platform layer is the first lower layer of the merged root, so any file in it hides
# the same path in @sys. scripts/ci/platform-runtime.sh already skips libraries the root
# filesystem provides, and this verifies the result: a payload is the one place where the
# layer and the rootfs are staged separately, and a shadowed musl, libz or libgcc would
# come up as a system whose tools do not run - which from the outside is "the upgrade
# broke everything". Files the rootfs already has are dropped from the layer; the btrfs
# tool itself is never dropped, because the layer is where it is meant to live.
tar -tzf "${work}/stage/rootfs.tar.gz" | sed 's|^\./||' | sort -u >"${work}/rootfs-members.txt"
( cd "${runtime_tree}" && find . \( -type f -o -type l \) | sed 's|^\./||' ) | sort -u \
    >"${work}/runtime-members.txt"
: >"${work}/shadowed-platform.txt"
while IFS= read -r member; do
    [ -n "${member}" ] || continue
    [ "${member}" = "usr/sbin/btrfs" ] && continue
    grep -qxF "${member}" "${work}/rootfs-members.txt" || continue
    printf '%s\n' "${member}" >>"${work}/shadowed-platform.txt"
    rm -f "${work}/content/platform/${member}"
done <"${work}/runtime-members.txt"
shadowed="$(tr '\n' ' ' <"${work}/shadowed-platform.txt")"
if [ -n "${shadowed}" ]; then
    ci_log "payload platform layer: dropped the runtime files the root filesystem already provides: ${shadowed}"
fi
ci_platform_modes "${work}/content/platform"
ci_platform_startlinks "${work}/content/platform"
# The one file that has to be there for an upgraded slot to be usable at all.
[ -x "${work}/content/platform/usr/sbin/btrfs" ] \
    || ci_die "the payload platform layer has no executable usr/sbin/btrfs; check CI_PLATFORM_RUNTIME_DIR (${runtime_tree})"
ci_log "payload platform layer carries usr/sbin/btrfs ($(ci_file_size "${work}/content/platform/usr/sbin/btrfs") bytes)"
( cd "${work}/content/platform" && tar --numeric-owner --owner=0 --group=0 -cf "${work}/stage/platform.tar" . )

# --------------------------------------------------------------------------- #
# 2b. Bootloader member: the ESP's EFI loader plus our rendered menu
# --------------------------------------------------------------------------- #
#
# Until this member existed, an update replaced kernel, initramfs, platform layer and
# rootfs but never the bootloader, so a machine that was only ever updated kept the GRUB
# it was flashed with. Measured on the official releases: 25.12.0 and 25.12.2 ship the
# same 638,976 byte EFI/BOOT/BOOTX64.EFI (GRUB 2.12), so the member is cheap - but "the
# bootloader never changes" is an observation, not a contract, and only a payload member can
# carry a future change to a machine without a reflash.

ci_boot_member_stage "${work}/stage" "${work}"
boot_member="${CI_BOOT_MEMBER}"
bootloader_version="${CI_BOOT_GRUB_VERSION}"
boot_block="${CI_BOOT_BLOCK}"

# --------------------------------------------------------------------------- #
# 3. Manifest
# --------------------------------------------------------------------------- #

ci_log "writing the manifest"
# The manifest carries two kinds of fact: the member table (size and sha256 of every
# file the payload ships) and, for the bootloader, the identity an updater compares
# against the ESP's current bytes. `loader_sha256` is what a device trusts;
# `grub_version` is the readable evidence next to it.
# The bootloader block is built by the shared fragment, not here: scripts/ci/assemble.sh
# writes the published payload's manifest from the same bytes, and two definitions of
# "which loader is this" is how the two payloads would drift apart again.
python3 - "${work}/stage" "${payload_version}" "${boot_block}" <<'PYTHON'
import hashlib, json, pathlib, sys

stage = pathlib.Path(sys.argv[1])
version, boot_block = sys.argv[2], sys.argv[3]


def digest(path):
    data = pathlib.Path(path).read_bytes()
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


members = {name: digest(stage / name)
           for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz")}

doc = {"format": "ab-payload/1", "rootfs": version, "members": members, "bootloader": None}
if boot_block:
    doc["bootloader"] = json.loads(pathlib.Path(boot_block).read_text(encoding="utf-8"))
    members[doc["bootloader"]["member"]] = digest(stage / doc["bootloader"]["member"])
(stage / "manifest.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(doc, sort_keys=True))
PYTHON

members="manifest.json rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar"
[ -n "${boot_member}" ] && members="${members} ${boot_member}"
# shellcheck disable=SC2086  # the member list is built above, one word per member
tar -cf "${payload_out}" -C "${work}/stage" ${members}

size="$(ci_file_size "${payload_out}")"
platform_bytes="$(ci_file_size "${work}/stage/platform.tar")"
sha="$(ci_sha256 "${payload_out}")"
ci_log "payload: ${payload_out} (${size} bytes, sha256 ${sha})"

boot_sha=""
boot_bytes="0"
if [ -n "${boot_member}" ]; then
    boot_sha="$(ci_sha256 "${work}/stage/boot.tar")"
    boot_bytes="$(ci_file_size "${work}/stage/boot.tar")"
    # Read back out of the block the manifest was written from, so the log line cannot
    # disagree with the manifest about which loader is in the payload.
    loader_sha="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["loader_sha256"])' "${boot_block}")"
    menu_sha="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["menu_sha256"])' "${boot_block}")"
    ci_log "payload bootloader member: ${boot_member} (${boot_bytes} bytes, sha256 ${boot_sha}), loader sha256 ${loader_sha}, menu sha256 ${menu_sha}"
    ci_emit_output "payload_bootloader" "${boot_member}"
    ci_emit_output "payload_bootloader_sha256" "${loader_sha}"
    ci_emit_output "payload_grub_version" "${bootloader_version}"
else
    ci_emit_output "payload_bootloader" "absent"
    ci_emit_output "payload_bootloader_sha256" ""
    ci_emit_output "payload_grub_version" "unknown"
fi

ci_emit_output "payload_path" "${payload_out}"
ci_emit_output "payload_size" "${size}"
ci_emit_output "payload_sha256" "${sha}"
ci_emit_output "payload_version" "${payload_version}"
ci_emit_output "payload_layer" "@overlay-${payload_version}"
ci_emit_output "payload_platform_bytes" "${platform_bytes}"
ci_emit_output "payload_platform_shadowed" "${shadowed}"

ci_log "stage payload finished"
