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
#   CI_PLATFORM_SRC     platform layer source tree (default: platform/)
#   CI_PLATFORM_RUNTIME_DIR  btrfs tooling staged by the runtime stage (default:
#                       $CI_TMP_ROOT/runtime). It is merged into the payload's platform
#                       layer: an upgraded slot has to run ab-boot, ab-commit and the
#                       reclamation, and all of them call btrfs. A payload without the
#                       tooling boots and then cannot commit - which is exactly the
#                       failure this input exists to prevent.
#   CI_PLATFORM_VERSION platform version recorded in the rendered release file
#   CI_PAYLOAD_VERSION  rootfs version the payload claims (default: upstream + test tag)
#   CI_PAYLOAD_OUT      output tar path (default: $CI_TMP_ROOT/payload/payload.tar)
#
# Outputs: payload_path, payload_size, payload_sha256, payload_version, payload_layer,
#          payload_platform_bytes

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

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
platform_version="${CI_PLATFORM_VERSION:-0.0.3}"
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
# 3. Manifest
# --------------------------------------------------------------------------- #

ci_log "writing the manifest"
python3 - "${work}/stage" "${payload_version}" <<'PYTHON'
import hashlib, json, pathlib, sys

stage = pathlib.Path(sys.argv[1])
version = sys.argv[2]
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    path = stage / name
    data = path.read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
doc = {"format": "ab-payload/1", "rootfs": version, "members": members}
(stage / "manifest.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(members, indent=2, sort_keys=True))
PYTHON

tar -cf "${payload_out}" -C "${work}/stage" manifest.json rootfs.tar.gz kernel.bin \
    initramfs.cpio.gz platform.tar

size="$(ci_file_size "${payload_out}")"
platform_bytes="$(ci_file_size "${work}/stage/platform.tar")"
sha="$(ci_sha256 "${payload_out}")"
ci_log "payload: ${payload_out} (${size} bytes, sha256 ${sha})"

ci_emit_output "payload_path" "${payload_out}"
ci_emit_output "payload_size" "${size}"
ci_emit_output "payload_sha256" "${sha}"
ci_emit_output "payload_version" "${payload_version}"
ci_emit_output "payload_layer" "@overlay-${payload_version}"
ci_emit_output "payload_platform_bytes" "${platform_bytes}"
ci_emit_output "payload_platform_shadowed" "${shadowed}"

ci_log "stage payload finished"
