#!/usr/bin/env bash
# Stage "assemble": build the update payload and validate it with the product's own
# checker.
#
# The payload is the real thing: the upstream root filesystem and kernel, the boot
# initramfs this project builds, and the platform layer including the btrfs tooling.
# Nothing is faked and nothing is left out, so a payload that fails validation here
# would also fail on the target.
#
# There is exactly one definition of "a valid payload": platform/usr/sbin/ab-upgrade
# --check. This stage produces the tar and then hands it to that checker, so the build
# cannot drift away from what the device accepts.
#
# Inputs (environment):
#   CI_FETCH_DIR             directory produced by the fetch stage
#   CI_UPSTREAM_VERSION      upstream release label
#   CI_KERNEL_PACKAGE        kernel package version, recorded in the manifest
#   CI_PLATFORM_VERSION      platform version, recorded in the release file (required;
#                            VERSION is the only source, there is no fallback)
#   CI_INITRAMFS             boot initramfs to ship as the payload's initrd
#   CI_PLATFORM_RUNTIME_DIR  btrfs tooling staged by the runtime stage
#   CI_PLATFORM_SRC          platform layer source tree (default: platform/)
#   CI_ASSEMBLE_DIR          destination directory (default: $CI_TMP_ROOT/assemble)
#   CI_BOOT_SRC              ESP tree the bootloader member comes from (default:
#                            $CI_TMP_ROOT/esp, what the esp stage produces). A payload
#                            without it leaves an updated machine on the GRUB it was
#                            flashed with, so this stage fails without one; the check below
#                            has no opt-out, and CI_REQUIRE_BOOTLOADER is exported to 1
#                            rather than left to the caller.
#   CI_BOOTLOADER_CFG        menu to ship; default: ${CI_GRUB_OUTPUT}, else
#                            $CI_TMP_ROOT/disk/grub.cfg (what the image stage renders),
#                            else rendered from scripts/ci/grub.cfg.in
#
# Outputs: payload_path, payload_dir, manifest_path, payload_manifest_sha256,
#          payload_members, payload_total_bytes, payload_check

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"
# The bootloader member comes from the fragment scripts/ci/payload-build.sh uses as well:
# the published payload and the test payload are built by different scripts, and this
# stage is the one users actually receive, so the two must not drift.
# shellcheck source=scripts/ci/boot-member.sh
. "${CI_SCRIPT_DIR}/boot-member.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init assemble

ci_require_cmd tar gzip python3

upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
kernel_package="${CI_KERNEL_PACKAGE:?CI_KERNEL_PACKAGE is required}"
# No default on purpose: a fallback here used to record 0.0.5 in the release file of a
# payload whose image said something else, and nothing noticed. VERSION is read by the
# versions job in ci.yml and passed down; a local run has to name it too.
platform_version="${CI_PLATFORM_VERSION:?CI_PLATFORM_VERSION is required, it is recorded in the payload release file}"
# A release payload always carries the bootloader. The value is exported as 1 unless the
# caller already set the variable, and the member check further down has no opt-out, so
# CI_REQUIRE_BOOTLOADER=0 does not switch the requirement off here - it only changes what
# the fragment reports before that check fails the build.
export CI_REQUIRE_BOOTLOADER="${CI_REQUIRE_BOOTLOADER:-1}"
initramfs="${CI_INITRAMFS:?CI_INITRAMFS is required, the payload needs the boot initramfs}"
runtime_tree="${CI_PLATFORM_RUNTIME_DIR:?CI_PLATFORM_RUNTIME_DIR is required, the payload needs the btrfs tooling}"
platform_src="${CI_PLATFORM_SRC:-${CI_REPO_ROOT}/platform}"
fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
upstream_dir="${fetch_dir}/upstream"
assemble_dir="${CI_ASSEMBLE_DIR:-${CI_TMP_ROOT}/assemble}"
payload_dir="${assemble_dir}/payload"
payload_tar="${assemble_dir}/payload.tar"

[ -d "${upstream_dir}" ] || ci_die "fetch output not found: ${upstream_dir}"
[ -d "${platform_src}" ] || ci_die "platform tree not found: ${platform_src}"
[ -d "${runtime_tree}" ] || ci_die "runtime tree not found: ${runtime_tree}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"

rm -rf "${payload_dir}"
mkdir -p "${payload_dir}"

# --------------------------------------------------------------------------- #
# 1. Upstream members, digest re-checked so the payload never carries an
#    unverified file
# --------------------------------------------------------------------------- #

# assemble_member <name> <expected-sha256>
assemble_member() {
    local name="$1" expected="$2"
    local source="${upstream_dir}/${name}"
    local dest="${payload_dir}/${name}"
    [ -f "${source}" ] || ci_die "fetch output is missing ${name}"
    cp "${source}" "${dest}"
    local actual
    actual="$(ci_sha256 "${dest}")"
    if [ "${actual}" != "${expected}" ]; then
        ci_die "payload member ${name} changed during assembly: expected ${expected}, got ${actual}"
    fi
    ci_log "staged ${name} (${actual})"
}

rootfs_sha256="$(ci_sha256 "${upstream_dir}/rootfs.tar.gz")"
kernel_sha256="$(ci_sha256 "${upstream_dir}/kernel.bin")"
assemble_member "rootfs.tar.gz" "${rootfs_sha256}"
assemble_member "kernel.bin" "${kernel_sha256}"

cp "${initramfs}" "${payload_dir}/initramfs.cpio.gz"
ci_log "staged initramfs.cpio.gz ($(ci_sha256 "${payload_dir}/initramfs.cpio.gz"))"

# --------------------------------------------------------------------------- #
# 2. Platform layer: the source tree plus the btrfs tooling, with the modes and
#    the rcS start links every platform layer needs
# --------------------------------------------------------------------------- #

platform_stage="${assemble_dir}/platform-stage"
rm -rf "${platform_stage}"
mkdir -p "${platform_stage}"
cp -a "${platform_src}/." "${platform_stage}/"
cp -a "${runtime_tree}/." "${platform_stage}/"

ci_render_release "${platform_stage}/etc/platform-release" \
    "${platform_version}" "${upstream_version}" "payload"
ci_render_net_defaults "${platform_stage}"
ci_render_update_conf "${platform_stage}"

# --------------------------------------------------------------------------- #
# 2a. The protected-path list for the payload's own layer files
#
# A leading `+` rule in /etc/apk/protected_paths.d/*.list stops `apk upgrade` from
# writing a package's copy of a path over the one the platform layer provides. It works
# by comparing the visible file with the one recorded in the apk database, so it only
# applies to a path the database knows: a file this project ships but no package owns
# (/etc/platform-release is one, measured on the device) never reaches the rule, and
# listing it would protect nothing while reading as if it had been handled.
#
# The list is therefore derived, never hand-written: the layer's own regular files
# intersect the path set of the root filesystem's apk database. Every entry is a path a
# package owns *and* this payload ships, which is exactly the set whose upper copy would
# shadow the layer.
#
# Ownership is read from the database itself (lib/apk/db/installed), which is what
# `apk info -W` answers from: one record per package, `F:<dir>` followed by `R:<name>`
# entries relative to it, both including directories. scripts/ci/apk_tools.py has no
# ownership query, so no new parser is invented for the package format: this reads the
# two record types that carry a path, in the same way platform/lib/upgrade/packages.sh
# already reads the same file for the kernel package.
#
# An unreadable database writes no list at all. A missing list only loses this
# prevention layer, and the install-time cleanup in platform_copy_rootfs still repairs a
# snapshot that carries a shadow; a list this stage guessed at could protect the wrong
# paths, which is the one outcome worse than having none.
# --------------------------------------------------------------------------- #

protected_list="${platform_stage}/etc/apk/protected_paths.d/ab-platform-shadow.list"
rm -f "${protected_list}"
rootfs_installed="${assemble_dir}/rootfs-installed.txt"
if tar -xzOf "${upstream_dir}/rootfs.tar.gz" ./lib/apk/db/installed \
    >"${rootfs_installed}" 2>"${assemble_dir}/rootfs-installed.err"; then
    # Path set of the installed database: every file and directory any package owns.
    awk '
        /^F:/ { dir = substr($0, 3); next }
        /^R:/ {
            rel = substr($0, 3)
            if (dir == "") print rel
            else print dir "/" rel
            next
        }
    ' "${rootfs_installed}" | sort -u >"${assemble_dir}/apk-owned.txt"
    # The layer's own regular files, as the tar below will carry them.
    ( cd "${platform_stage}" && find . -type f | sed 's|^\./||' ) | sort -u \
        >"${assemble_dir}/platform-files.txt"
    if [ -s "${assemble_dir}/apk-owned.txt" ]; then
        grep -F -x -f "${assemble_dir}/apk-owned.txt" "${assemble_dir}/platform-files.txt" \
            >"${assemble_dir}/platform-owned.txt" || true
    else
        : >"${assemble_dir}/platform-owned.txt"
    fi
    owned_count="$(grep -c . "${assemble_dir}/platform-owned.txt" || true)"
    mkdir -p "$(dirname "${protected_list}")"
    {
        printf '# Do not edit: generated at build time by scripts/ci/assemble.sh.\n'
        printf '#\n'
        printf '# The platform layer files that an apk package also owns. A leading + keeps\n'
        printf '# `apk upgrade` from writing its copy of one of these over the layer, so the\n'
        printf '# layer stays what the merged root resolves the path to.\n'
        printf '#\n'
        printf '# Derived as: the files in this payload platform.tar intersect the paths in\n'
        printf '# the root filesystem apk database. A path this project ships but no package\n'
        printf '# owns is not listed: the + rule compares against that database and would\n'
        printf '# never apply to it.\n'
        sed 's/^/+/' "${assemble_dir}/platform-owned.txt"
    } >"${protected_list}"
    ci_log "protected paths: ${owned_count} of $(grep -c . "${assemble_dir}/platform-files.txt" || true) platform layer file(s) are owned by an apk package"
else
    ci_warn "root filesystem apk database is unreadable, shipping no derived protected-path list: $(tr '\n' ' ' <"${assemble_dir}/rootfs-installed.err" 2>/dev/null || true)"
fi

ci_platform_modes "${platform_stage}"
ci_platform_startlinks "${platform_stage}"
[ -x "${platform_stage}/usr/sbin/btrfs" ] ||
    ci_die "the platform layer in the payload has no runnable btrfs tool"

tar --numeric-owner --owner=0 --group=0 -cf "${payload_dir}/platform.tar" -C "${platform_stage}" .
ci_log "staged platform.tar ($(ci_sha256 "${payload_dir}/platform.tar"), $(ci_file_size "${payload_dir}/platform.tar") bytes)"

# --------------------------------------------------------------------------- #
# 2b. Bootloader member: the ESP's EFI loader plus our slot menu
#
# This is the member this stage used to be missing. The payload replaced kernel, initramfs,
# platform layer and rootfs but never the bootloader, so a machine that was only ever
# updated kept the GRUB it was flashed with - and because the S5 test payload carried one,
# CI looked like it covered the path while the payload people download did not.
# --------------------------------------------------------------------------- #

ci_boot_member_stage "${payload_dir}" "${assemble_dir}"
boot_member="${CI_BOOT_MEMBER}"
boot_block="${CI_BOOT_BLOCK}"
# The fragment only returns without a member when CI_REQUIRE_BOOTLOADER is off, and that is
# not a choice this stage offers: it exports 1 above. The check stays because a future
# caller could unset it, and the message names the boot source, which is the input to look
# at first (an empty or mistyped CI_BOOT_SRC is the common cause, and a bare "no bootloader
# member" sends the reader to the wrong place).
[ -n "${boot_member}" ] ||
    ci_die "the payload carries no bootloader member (boot source: ${CI_BOOT_SRC:-<unset, default ${CI_TMP_ROOT:-}/esp>}); a release payload must bring one forward"

# --------------------------------------------------------------------------- #
# 3. Manifest
# --------------------------------------------------------------------------- #

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The bootloader block is written by the shared fragment, never here: the manifest has to
# name the same loader identity the S5 test payload names, and `ab-upgrade --check` below
# validates it with the same rules the device uses.
python3 - "${payload_dir}" "${upstream_version}" "${kernel_package}" \
    "${platform_version}" "${created_at}" "${boot_block}" <<'PYTHON'
import hashlib, json, pathlib, sys

payload_dir = pathlib.Path(sys.argv[1])
version, kernel_package, platform_version, created = sys.argv[2:6]
boot_block = sys.argv[6]
members = {}
for name in ("initramfs.cpio.gz", "kernel.bin", "platform.tar", "rootfs.tar.gz"):
    data = (payload_dir / name).read_bytes()
    members[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
doc = {
    "format": "ab-payload/1",
    "rootfs": version,
    "kernel": kernel_package,
    "platform": platform_version,
    "created": created,
    "members": members,
    "bootloader": None,
}
if boot_block:
    doc["bootloader"] = json.loads(pathlib.Path(boot_block).read_text(encoding="utf-8"))
    member = doc["bootloader"]["member"]
    data = (payload_dir / member).read_bytes()
    members[member] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
(payload_dir / "manifest.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(json.dumps(members, indent=2, sort_keys=True))
PYTHON

# The member list is read back out of the manifest instead of being written a second time:
# two hand-maintained lists of the same set is how the bootloader got left out of one of
# them in the first place.
payload_members="manifest.json $(python3 - "${payload_dir}/manifest.json" <<'PYTHON'
import json, sys
print(" ".join(sorted(json.load(open(sys.argv[1]))["members"])))
PYTHON
)"
# shellcheck disable=SC2086  # the member list is space separated by construction
tar -cf "${payload_tar}" -C "${payload_dir}" ${payload_members}
payload_total_bytes="$(ci_file_size "${payload_tar}")"
manifest_sha256="$(ci_sha256 "${payload_dir}/manifest.json")"
ci_log "payload ${payload_tar} (${payload_total_bytes} bytes, sha256 $(ci_sha256 "${payload_tar}"))"

# --------------------------------------------------------------------------- #
# 4. Validation by the product's own checker, taken from the payload
#
# ab-upgrade --check is the definition of a valid payload. It runs in the same shell
# dialect it uses on the target, against a scratch ESP and a scratch writable
# partition, so a payload that fails here would fail on the device too.
#
# The copy that runs is the one inside platform.tar, unpacked into a scratch tree: the
# bytes a device will unpack are the bytes that accepted the payload. Running the working
# tree's copy instead proved that the two agree at build time, not that the shipped copy
# ever passed - and it needed the checkout to be chmodded, which left the repository dirty
# for anyone reproducing this stage locally.
# --------------------------------------------------------------------------- #

check_dir="${assemble_dir}/check"
rm -rf "${check_dir}"
mkdir -p "${check_dir}/esp/ab/log" "${check_dir}/p4" "${check_dir}/slots"
cat >"${check_dir}/esp/ab/state.json" <<JSON
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "0.0.0-scratch", "upper": "@overlay-${upstream_version}" },
    "b": { "rootfs": "0.0.0-scratch", "upper": "@overlay-${upstream_version}" }
  }
}
JSON

# ab-slot derives p4's health from /proc/mounts and from asking btrfs about the mount, so
# the scratch partition has to be a real btrfs, not a tmpfs that merely has free space.
p4_mounted="false"
cleanup_p4() {
    if [ "${p4_mounted}" = "true" ]; then
        sudo umount "${check_dir}/p4" 2>/dev/null || true
    fi
}
trap cleanup_p4 EXIT
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # btrfs refuses to format anything much below 114 MiB, so the scratch image is
    # generous; it is sparse, so it costs almost nothing on disk.
    if truncate -s 256M "${check_dir}/p4.img" 2>/dev/null \
        && sudo mkfs.btrfs -q -f "${check_dir}/p4.img" 2>"${check_dir}/mkfs.p4.err" \
        && sudo mount -o loop "${check_dir}/p4.img" "${check_dir}/p4" 2>>"${check_dir}/mkfs.p4.err"; then
        # The state names the writable layer, and the health check verifies that the layer
        # really exists on the partition, so the scratch filesystem has to carry it.
        sudo btrfs subvolume create "${check_dir}/p4/@overlay-${upstream_version}" >/dev/null 2>&1 || true
        sudo mkdir -p "${check_dir}/p4/@overlay-${upstream_version}/upper" \
            "${check_dir}/p4/@overlay-${upstream_version}/work" 2>/dev/null || true
        p4_mounted="true"
    else
        ci_log "mkfs/mount of the scratch partition failed: $(tr '\n' ' ' <"${check_dir}/mkfs.p4.err" 2>/dev/null)" || true
    fi
fi
[ "${p4_mounted}" = "true" ] ||
    ci_die "cannot mount a scratch writable partition, the payload check needs one"

check_platform="${check_dir}/platform"
rm -rf "${check_platform}"
mkdir -p "${check_platform}"
tar -xf "${payload_dir}/platform.tar" -C "${check_platform}"
[ -f "${check_platform}/usr/sbin/ab-upgrade" ] ||
    ci_die "the platform layer in the payload carries no ab-upgrade, so the shipped bytes cannot be validated"
ci_log "checker: payload platform.tar usr/sbin/ab-upgrade, not the working tree"

check_output="${assemble_dir}/payload-check.log"
if ! PATH="${check_platform}/usr/sbin:${PATH}" \
    AB_ESP="${check_dir}/esp" AB_P4="${check_dir}/p4" \
    AB_SLOTS_ROOT="${check_dir}/slots" \
    AB_LIB="${check_platform}/lib/upgrade/platform.sh" \
    sh "${check_platform}/usr/sbin/ab-upgrade" --check "${payload_tar}" \
    >"${check_output}" 2>&1; then
    sed 's/^/[assemble]   /' "${check_output}" >&2 || true
    ci_die "the payload does not pass ab-upgrade --check, see ${check_output}"
fi
sed 's/^/[assemble]   /' "${check_output}"

ci_emit_output "payload_path" "${payload_tar}"
ci_emit_output "payload_dir" "${payload_dir}"
ci_emit_output "manifest_path" "${payload_dir}/manifest.json"
ci_emit_output "payload_manifest_sha256" "${manifest_sha256}"
# The manifest is not a member of itself: the list names what a device unpacks.
member_list="${payload_members#manifest.json }"
ci_emit_output "payload_members" "${member_list// /,}"
ci_emit_output "payload_total_bytes" "${payload_total_bytes}"
ci_emit_output "payload_check" "ok"

ci_log "stage assemble finished"
