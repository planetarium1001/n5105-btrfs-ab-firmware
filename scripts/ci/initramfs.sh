#!/usr/bin/env bash
# Stage "initramfs": build the minimal initramfs used by the module-load probe.
#
# Contents, and nothing else:
#   /bin/busybox         the upstream busybox package, with its musl loader and applets
#   /init                initramfs/init from this repository
#   /lib/modules/<kver>/ the modules unpacked by the kmods stage
#   an empty /proc /sys /dev /mnt

#
# Inputs (environment):
#   CI_KMODS_OUT       directory produced by the kmods stage (contains modules/)
#   CI_KERNEL_VERSION  kernel version, must match the module directory
#   CI_INITRAMFS_OUT   destination file (default: $CI_TMP_ROOT/initramfs/initramfs.cpio.gz)
#   CI_EXTRA_FILES     space separated "<source>:<path inside the initramfs>" pairs,
#                      used to stage the guest assertion scripts of later stages
#   CI_INITRAMFS_TOOLSET
#                      which locked toolset to stage: probe (busybox, musl, kmod),
#                      boot (probe + sfdisk/blkid/blockdev/btrfs) or assert (same as
#                      boot, for the S2 guest assertion). Defaults to probe for the
#                      module-load probe and boot for initramfs/boot/init.
#                      The programs, their libraries and every digest come from
#                      scripts/ci/initramfs-tools.lock.json; nothing is taken from the
#                      build host, whose libc and program versions drift with the
#                      runner image.
#   CI_INITRAMFS_LIB_DIR
#                      shell libraries staged into /lib (default: <repo>/initramfs/lib,
#                      which carries wf.sh for the state parsing and grow.sh for the
#                      first-boot growth; set it to an empty string to stage none)
#   CI_INITRAMFS_SHARED_LIBS
#                      space separated libraries that also ship in the platform layer
#                      and must run as the same bytes in both places (default:
#                      <repo>/platform/lib/disk-identity.sh, which resolves the boot disk,
#                      and <repo>/platform/lib/ab-slot-cfg.sh, which the initramfs uses
#                      for the fail-safe abandon and ab-slot/ab-boot use to pick a slot).
#                      Each one is copied
#                      unchanged to /lib and verified with cmp, so the initramfs can
#                      never resolve the boot disk with a different implementation than
#                      ab-boot and ab-slot use. Set it to an empty string to stage none.
#   CI_INIT_SCRIPT     which init to install as /init
#                      (default: initramfs/init, the S1 probe)
#
# Outputs: initramfs_path, initramfs_size, initramfs_modules, busybox_version,
#          initramfs_toolset, initramfs_tools_digest, initramfs_tools_versions,
#          initramfs_tools_bytes, initramfs_libs, initramfs_extra_files

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

ci_stage_init initramfs

ci_require_cmd cpio gzip find sort cmp

kmods_out="${CI_KMODS_OUT:-${CI_TMP_ROOT}/kmods}"
kernel_version="${CI_KERNEL_VERSION:?CI_KERNEL_VERSION is required}"
out_file="${CI_INITRAMFS_OUT:-${CI_TMP_ROOT}/initramfs/initramfs.cpio.gz}"
init_script="${CI_INIT_SCRIPT:-${CI_REPO_ROOT}/initramfs/init}"

module_dir="${kmods_out}/modules/lib/modules/${kernel_version}"
[ -d "${module_dir}" ] || ci_die "module directory not found: ${module_dir}"
[ -f "${module_dir}/btrfs.ko" ] || ci_die "btrfs.ko not found in ${module_dir}"

stage="${CI_TMP_ROOT}/initramfs/root"
rm -rf "${stage}"
mkdir -p "${stage}/bin" "${stage}/proc" "${stage}/sys" "${stage}/dev" "${stage}/mnt" \
    "${stage}/lib/modules/${kernel_version}"

# Every foreign program comes from the locked upstream packages: busybox itself, its
# musl loader, the partition tools and their libraries. scripts/ci/initramfs-tools.sh
# verifies each .apk and each extracted file against the lockfile, so a program can
# only enter this initramfs if its digest is the one the release published.
toolset="${CI_INITRAMFS_TOOLSET:-}"
if [ -z "${toolset}" ]; then
    # No leading slash in the pattern: the path may be relative, and a boot init that
    # silently fell back to the probe toolset would build an image that boots and then
    # cannot grow the disk. Both spellings must select boot.
    case "${init_script}" in
        *initramfs/boot/init) toolset="boot" ;;
        *) toolset="probe" ;;
    esac
fi
ci_log "toolset: ${toolset}"

tools_summary="${CI_TMP_ROOT}/initramfs/tools-${toolset}.json"
mkdir -p "$(dirname "${tools_summary}")"
CI_APK_TOOLS_SUMMARY="${tools_summary}" \
    bash "${CI_SCRIPT_DIR}/initramfs-tools.sh" --toolset "${toolset}" --stage "${stage}"

tools_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "${tools_summary}" "$1"
}
tools_digest="$(tools_field digest)"
tools_versions="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["versions"]))' "${tools_summary}")"
tools_bytes="$(tools_field bytes)"
tools_files="$(tools_field files)"
busybox_version="$(printf '%s\n' ${tools_versions} | sed -n 's/^busybox=//p')"

# The toolset is a promise: probe boots and loads modules, boot/assert additionally
# partition and grow the disk. A toolset that lost one of its programs would still boot
# and only fail at the disk, so the build asserts every promised program is there.
require_toolset_programs() {
    local program
    for program in "$@"; do
        [ -e "${stage}${program}" ] || ci_die "the ${toolset} toolset is missing ${program}"
    done
}
require_toolset_programs /bin/busybox /bin/sh /lib/ld-musl-x86_64.so.1 /lib/libc.so \
    /sbin/kmod /sbin/insmod /sbin/modprobe
case "${toolset}" in
    probe) ;;
    boot|assert)
        require_toolset_programs /usr/sbin/sfdisk /usr/sbin/blockdev /usr/sbin/blkid /usr/sbin/btrfs
        ;;
    *) ci_die "unknown toolset: ${toolset} (expected probe, boot or assert)" ;;
esac

# The initramfs must run on the musl loader alone. A glibc interpreter or library in
# here means a host binary slipped back in, which is exactly what this stage exists to
# prevent, so it is a build failure and not a warning.
require_musl_only() {
    local offender
    [ -L "${stage}/lib/ld-musl-x86_64.so.1" ] \
        || ci_die "missing /lib/ld-musl-x86_64.so.1: nothing in this initramfs could start"
    [ "$(readlink "${stage}/lib/ld-musl-x86_64.so.1")" = "libc.so" ] \
        || ci_die "/lib/ld-musl-x86_64.so.1 must point at libc.so"
    [ -f "${stage}/lib/libc.so" ] || ci_die "missing /lib/libc.so"
    offender="$(cd "${stage}" && find . \( -name 'ld-linux*' -o -name 'libc.so.6' \
        -o -name 'libreadline*' -o -name 'libtinfo*' -o -name 'libudev*' \
        -o -path '*x86_64-linux-gnu*' \) -print | head -n 1)"
    [ -z "${offender}" ] || ci_die "glibc artifact in the initramfs: ${offender}"
    ci_log "libc: musl only (/lib/ld-musl-x86_64.so.1 -> libc.so)"
}
require_musl_only

[ -f "${init_script}" ] || ci_die "init script not found: ${init_script}"
install -m 0755 "${init_script}" "${stage}/init"
ci_log "init: ${init_script#"${CI_REPO_ROOT}"/}"

# The shell libraries that belong to this init script travel with it: initramfs/lib
# holds wf.sh (state parsing) and grow.sh (first-boot growth), and staging the directory
# means a new helper is picked up by every stage that installs this init instead of
# being listed again in each workflow's CI_EXTRA_FILES.
lib_dir="${CI_INITRAMFS_LIB_DIR-${CI_REPO_ROOT}/initramfs/lib}"
lib_count=0
if [ -n "${lib_dir}" ] && [ -d "${lib_dir}" ]; then
    for lib in "${lib_dir}"/*.sh; do
        [ -f "${lib}" ] || continue
        mkdir -p "${stage}/lib"
        install -m 0644 "${lib}" "${stage}/lib/$(basename "${lib}")"
        lib_count=$((lib_count + 1))
    done
fi
[ "${lib_count}" -eq 0 ] || ci_log "libraries: ${lib_count} file(s) from ${lib_dir#"${CI_REPO_ROOT}"/}"

# Shared libraries that belong to the platform layer but are needed before it is
# mounted. disk-identity.sh is the only implementation of "which disk carries us", and
# the boot initramfs must not carry a second copy that can drift: the staged file is
# compared with the source and a difference is a build failure.
shared_libs="${CI_INITRAMFS_SHARED_LIBS-${CI_REPO_ROOT}/platform/lib/disk-identity.sh ${CI_REPO_ROOT}/platform/lib/ab-slot-cfg.sh}"
shared_count=0
for shared in ${shared_libs}; do
    if [ ! -f "${shared}" ]; then
        ci_warn "shared library not found, skipped: ${shared}"
        continue
    fi
    mkdir -p "${stage}/lib"
    install -m 0644 "${shared}" "${stage}/lib/$(basename "${shared}")"
    cmp -s "${shared}" "${stage}/lib/$(basename "${shared}")" \
        || ci_die "staged $(basename "${shared}") differs from ${shared}"
    ci_log "shared library $(basename "${shared}"): byte-identical to ${shared#"${CI_REPO_ROOT}"/}"
    shared_count=$((shared_count + 1))
done

# Extra files, for example the S2 guest assertion script staged as /s2.sh.
extra_count=0
for spec in ${CI_EXTRA_FILES:-}; do
    src="${spec%%:*}"
    dest="${spec#*:}"
    [ "${src}" != "${dest}" ] || ci_die "CI_EXTRA_FILES entry needs <source>:<dest>, got ${spec}"
    [ -f "${src}" ] || ci_die "extra file not found: ${src}"
    mkdir -p "${stage}$(dirname "${dest}")"
    install -m 0755 "${src}" "${stage}${dest}"
    extra_count=$((extra_count + 1))
done

cp "${module_dir}"/*.ko "${stage}/lib/modules/${kernel_version}/"
module_count="$(find "${stage}/lib/modules" -name '*.ko' | wc -l | tr -d ' ')"
[ "${module_count}" -gt 0 ] || ci_die "no modules staged"

mkdir -p "$(dirname "${out_file}")"
# GNU cpio is what the runner provides; --null keeps the archive safe for names with
# spaces, but fall back to newline separation where the flag is missing.
# The kernel unpacks the initramfs as-is, so pin ownership to root and keep the modes.
if cpio --help 2>&1 | grep -q -- '--null'; then
    (cd "${stage}" && find . -print0 | cpio --null -o -H newc -R 0:0 2>/dev/null) | gzip -9 >"${out_file}"
else
    (cd "${stage}" && find . -print | cpio -o -H newc -R 0:0 2>/dev/null) | gzip -9 >"${out_file}"
fi

gzip -t "${out_file}" || ci_die "produced initramfs is not valid gzip"
entries="$(gzip -dc "${out_file}" | cpio -t 2>/dev/null | wc -l | tr -d ' ')"
size_bytes="$(ci_file_size "${out_file}")"


ci_log "initramfs: ${out_file}"
ci_log "  size: ${size_bytes} bytes, ${entries} archive entries"
ci_log "  toolset: ${toolset}, ${tools_files} locked file(s), digest ${tools_digest:0:12}"
ci_log "  modules: ${module_count}, ${lib_count} shell lib(s)"
ci_log "  shared libraries: ${shared_count}"
ci_log "  extra files: ${extra_count}"
ci_log "  busybox: ${busybox_version} (upstream apk)"
ci_log "  versions: ${tools_versions}"

ci_emit_output "initramfs_path" "${out_file}"
ci_emit_output "initramfs_size" "${size_bytes}"
ci_emit_output "initramfs_modules" "${module_count}"
ci_emit_output "busybox_version" "${busybox_version}"
ci_emit_output "initramfs_toolset" "${toolset}"
ci_emit_output "initramfs_tools_digest" "${tools_digest}"
ci_emit_output "initramfs_tools_versions" "${tools_versions}"
ci_emit_output "initramfs_tools_bytes" "${tools_bytes}"
ci_emit_output "initramfs_libs" "${lib_count}"
ci_emit_output "initramfs_shared_libs" "${shared_count}"
ci_emit_output "initramfs_extra_files" "${extra_count}"

ci_log "stage initramfs finished"
