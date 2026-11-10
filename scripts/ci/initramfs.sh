#!/usr/bin/env bash
# Stage "initramfs": build the minimal initramfs used by the module-load probe.
#
# Contents, and nothing else:
#   /bin/busybox         statically linked, so the initramfs needs no libc or loader
#   /init                initramfs/init from this repository
#   /lib/modules/<kver>/ the modules unpacked by the kmods stage
#   an empty /proc /sys /dev /mnt

#
# Inputs (environment):
#   CI_KMODS_OUT       directory produced by the kmods stage (contains modules/)
#   CI_KERNEL_VERSION  kernel version, must match the module directory
#   CI_INITRAMFS_OUT   destination file (default: $CI_TMP_ROOT/initramfs/initramfs.cpio.gz)
#   CI_BUSYBOX         static busybox binary (default: /bin/busybox)
#   CI_EXTRA_FILES     space separated "<source>:<path inside the initramfs>" pairs,
#                      used to stage the guest assertion scripts of later stages
#   CI_TOOL_BINARIES   space separated host binaries to include together with the
#                      shared libraries ldd reports (for example btrfs and blkid)
#   CI_TOOL_BINARIES_OPTIONAL
#                      space separated tool names (resolved on the host) or paths that
#                      are included when present and skipped with a warning when not.
#                      Defaults to "sfdisk blockdev btrfs" for initramfs/boot/init,
#                      which is what the first-boot p4 growth needs; a build host
#                      without them still produces a bootable image, and the init
#                      reports result=missing-sfdisk at run time instead of the build
#                      failing. Set it to an empty string to add nothing.
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
#          initramfs_tools, initramfs_optional_tools, initramfs_libs,
#          initramfs_extra_files

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
busybox="${CI_BUSYBOX:-/bin/busybox}"
init_script="${CI_INIT_SCRIPT:-${CI_REPO_ROOT}/initramfs/init}"

module_dir="${kmods_out}/modules/lib/modules/${kernel_version}"
[ -d "${module_dir}" ] || ci_die "module directory not found: ${module_dir}"
[ -f "${module_dir}/btrfs.ko" ] || ci_die "btrfs.ko not found in ${module_dir}"
[ -x "${busybox}" ] || ci_die "static busybox not found: ${busybox}"

ci_log "busybox: ${busybox}"

stage="${CI_TMP_ROOT}/initramfs/root"
rm -rf "${stage}"
mkdir -p "${stage}/bin" "${stage}/proc" "${stage}/sys" "${stage}/dev" "${stage}/mnt" \
    "${stage}/lib/modules/${kernel_version}"

cp "${busybox}" "${stage}/bin/busybox"
chmod 0755 "${stage}/bin/busybox"

# A static busybox needs nothing else. A dynamically linked one (for example the
# busybox that ships with initramfs-tools) needs its interpreter and libraries, so
# copy exactly the files ldd reports instead of guessing.
copy_runtime_libs() {
    local binary="$1"
    local target="$2"
    local first second third lib
    ldd "${binary}" 2>/dev/null | while read -r first second third _rest; do
        if [ "${second:-}" = "=>" ]; then
            lib="${third:-}"
        else
            # Interpreter line: "<path> (0x...)". Skip pseudo entries like linux-vdso.
            lib="${first:-}"
        fi
        [ -n "${lib}" ] && [ -f "${lib}" ] || continue
        mkdir -p "${target}$(dirname "${lib}")" || continue
        cp -L "${lib}" "${target}${lib}" || continue
        printf '%s ' "${lib}"
    done
}

ldd_out=""
if ci_have ldd; then
    ldd_out="$(ldd "${busybox}" 2>&1 || true)"
fi
if printf '%s\n' "${ldd_out}" | grep -q "=>"; then
    copied="$(copy_runtime_libs "${busybox}" "${stage}")"
    [ -n "${copied}" ] || ci_die "busybox is dynamically linked but ldd reported no libraries"
    ci_log "copied runtime libraries for busybox: ${copied}"
else
    ci_log "busybox is statically linked"
fi

# One symlink per applet keeps /init free of "busybox <applet>" plumbing.
applets=""
if ! applets="$("${stage}/bin/busybox" --list 2>&1)"; then
    ci_die "busybox --list failed: ${applets}"
fi
[ -n "${applets}" ] || ci_die "busybox --list produced no applets"
applet_count=0
for applet in ${applets}; do
    # busybox lists itself on some builds; linking /bin/busybox to /bin/busybox turns
    # every applet and every #!/bin/sh script into an ELOOP, so never touch it.
    [ "${applet}" = busybox ] && continue
    ln -sf /bin/busybox "${stage}/bin/${applet}"
    applet_count=$((applet_count + 1))
done
[ ! -L "${stage}/bin/busybox" ] || ci_die "/bin/busybox was replaced by an applet symlink"
"${stage}/bin/busybox" true || ci_die "staged busybox cannot execute"

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

# Host tools needed by later assertion scripts (btrfs, blkid, sfdisk, ...), copied
# with exactly the libraries ldd reports so they run inside the guest unchanged.
copy_tool() {
    local tool="$1"
    mkdir -p "${stage}$(dirname "${tool}")"
    # A tool name can collide with a busybox applet link; replace the link itself.
    rm -f "${stage}${tool}"
    install -m 0755 "${tool}" "${stage}${tool}"
    local tool_libs=""
    if ci_have ldd; then
        tool_libs="$(copy_runtime_libs "${tool}" "${stage}")"
    fi
    ci_log "tool ${tool}: ${tool_libs:-statically linked}"
}

tool_count=0
for tool in ${CI_TOOL_BINARIES:-}; do
    [ -x "${tool}" ] || ci_die "tool binary is not executable: ${tool}"
    copy_tool "${tool}"
    tool_count=$((tool_count + 1))
done

# Optional tools exist because the boot initramfs grew a dependency it must not fail
# the build over: the first-boot expansion of p4 needs sfdisk and blockdev from
# util-linux, and `btrfs filesystem resize max` needs btrfs-progs. Missing them is a
# runtime state the init reports (missing-sfdisk / fail:btrfs-resize), never a build
# error, because an image that boots with a 64 MiB p4 is still a usable image.
if [ -z "${CI_TOOL_BINARIES_OPTIONAL+set}" ]; then
    case "${init_script}" in
        */initramfs/boot/init) CI_TOOL_BINARIES_OPTIONAL="sfdisk blockdev btrfs" ;;
        *) CI_TOOL_BINARIES_OPTIONAL="" ;;
    esac
fi
optional_tools=""
optional_count=0
for name in ${CI_TOOL_BINARIES_OPTIONAL}; do
    case "${name}" in
        */*) tool_path="${name}" ;;
        *)
            if ci_have "${name}"; then
                tool_path="$(command -v "${name}")"
            else
                tool_path=""
            fi
            ;;
    esac
    if [ -z "${tool_path}" ] || [ ! -x "${tool_path}" ]; then
        ci_warn "optional tool not found in the build host, skipped: ${name}"
        continue
    fi
    copy_tool "${tool_path}"
    optional_tools="${optional_tools}${optional_tools:+ }${name}"
    optional_count=$((optional_count + 1))
done
ci_log "optional tools staged: ${optional_tools:-none}"

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
busybox_version="$("${stage}/bin/busybox" 2>&1 | head -n 1)"

ci_log "initramfs: ${out_file}"
ci_log "  size: ${size_bytes} bytes, ${entries} archive entries"
ci_log "  busybox applets: ${applet_count}, modules: ${module_count}"
ci_log "  tools: ${tool_count} required, ${optional_count} optional, ${lib_count} lib(s)"
ci_log "  shared libraries: ${shared_count}"
ci_log "  extra files: ${extra_count}"
ci_log "  busybox: ${busybox_version}"

ci_emit_output "initramfs_path" "${out_file}"
ci_emit_output "initramfs_size" "${size_bytes}"
ci_emit_output "initramfs_modules" "${module_count}"
ci_emit_output "busybox_version" "${busybox_version}"
ci_emit_output "initramfs_tools" "${tool_count}"
ci_emit_output "initramfs_optional_tools" "${optional_tools}"
ci_emit_output "initramfs_libs" "${lib_count}"
ci_emit_output "initramfs_shared_libs" "${shared_count}"
ci_emit_output "initramfs_extra_files" "${extra_count}"

ci_log "stage initramfs finished"
