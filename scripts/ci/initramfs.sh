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
#
# Outputs: initramfs_path, initramfs_size, initramfs_modules, busybox_version

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

trap 'rc=$?; ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"; exit ${rc}' ERR

ci_stage_init initramfs

ci_require_cmd cpio gzip find sort

kmods_out="${CI_KMODS_OUT:-${CI_TMP_ROOT}/kmods}"
kernel_version="${CI_KERNEL_VERSION:?CI_KERNEL_VERSION is required}"
out_file="${CI_INITRAMFS_OUT:-${CI_TMP_ROOT}/initramfs/initramfs.cpio.gz}"
busybox="${CI_BUSYBOX:-/bin/busybox}"

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
    ln -sf /bin/busybox "${stage}/bin/${applet}"
    applet_count=$((applet_count + 1))
done

install -m 0755 "${CI_REPO_ROOT}/initramfs/init" "${stage}/init"

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
ci_log "  busybox: ${busybox_version}"

ci_emit_output "initramfs_path" "${out_file}"
ci_emit_output "initramfs_size" "${size_bytes}"
ci_emit_output "initramfs_modules" "${module_count}"
ci_emit_output "busybox_version" "${busybox_version}"

ci_log "stage initramfs finished"
