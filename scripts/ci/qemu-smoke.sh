#!/usr/bin/env bash
# Stage "qemu": boot the upstream kernel with the probe initramfs and assert the
# frozen S1-RESULT line from initramfs/init.
#
# The hardware model is deliberately minimal: one virtio disk carrying a tiny btrfs
# filesystem with a marker file. If the initramfs can mount it, btrfs works as a
# module on the official kernel, which is the premise of the upstream-consumption
# route.
#
# Inputs (environment):
#   CI_KERNEL         upstream kernel image (kernel.bin)
#   CI_INITRAMFS      initramfs produced by the initramfs stage
#   CI_QEMU_DIR       scratch directory (default: $CI_TMP_ROOT/qemu)
#   CI_QEMU_MODE      "kernel" (default) or "uefi" (boots through OVMF)
#   CI_QEMU_TIMEOUT   wall-clock limit in seconds (default: 900)
#   CI_QEMU_MEM       guest memory in MiB (default: 1024)
#   CI_S1_CASE        label recorded in the guest and in the log
#   CI_QEMU_CASE      preferred label, falls back to CI_S1_CASE
#   CI_QEMU_DISK      use this prepared raw image as the virtio disk instead of
#                     building a throwaway test filesystem (S2 and later)
#   CI_QEMU_INIT      rdinit= path inside the initramfs (default: /init)
#   CI_JUDGE_PREFIX   judge line prefix to assert (default: S1-RESULT)
#   CI_QEMU_APPEND_EXTRA extra kernel parameters, appended verbatim
#
# Outputs: serial_log, judge_line, boot_seconds, qemu_mode, judge_prefix

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init qemu

ci_require_cmd qemu-system-x86_64 mkfs.btrfs timeout grep

kernel="${CI_KERNEL:?CI_KERNEL is required}"
initramfs="${CI_INITRAMFS:?CI_INITRAMFS is required}"
qemu_dir="${CI_QEMU_DIR:-${CI_TMP_ROOT}/qemu}"
mode="${CI_QEMU_MODE:-kernel}"
timeout_s="${CI_QEMU_TIMEOUT:-900}"
mem="${CI_QEMU_MEM:-1024}"
case_label="${CI_QEMU_CASE:-${CI_S1_CASE:-s1}}"
given_disk="${CI_QEMU_DISK:-}"
init_path="${CI_QEMU_INIT:-}"
judge_prefix="${CI_JUDGE_PREFIX:-S1-RESULT}"
append_extra="${CI_QEMU_APPEND_EXTRA:-}"

[ -f "${kernel}" ] || ci_die "kernel image not found: ${kernel}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"
if [ -n "${given_disk}" ]; then
    [ -f "${given_disk}" ] || ci_die "disk image not found: ${given_disk}"
fi
case "${mode}" in
    kernel | uefi) : ;;
    *) ci_die "CI_QEMU_MODE must be kernel or uefi, got ${mode}" ;;
esac

mkdir -p "${qemu_dir}"
image="${qemu_dir}/btrfs-${mode}.img"
payload="${qemu_dir}/image-root"
serial="${qemu_dir}/serial-${mode}.log"
rm -f "${serial}"

# --------------------------------------------------------------------------- #
# Test filesystem
# --------------------------------------------------------------------------- #

if [ -n "${given_disk}" ]; then
    ci_log "using the prepared disk image ${given_disk}"
    image="${given_disk}"
else
    rm -rf "${payload}"
    mkdir -p "${payload}"
    {
        printf 'S1 btrfs test image\n'
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'kernel=%s\n' "$(basename "${kernel}")"
        printf 'case=%s\n' "${case_label}"
    } >"${payload}/S1-IMAGE-MARKER"
    printf 'hello from btrfs\n' >"${payload}/hello.txt"

    truncate -s 64M "${image}"
    if mkfs.btrfs -f -L wf-s1 -m single -d single --rootdir "${payload}" "${image}" >"${qemu_dir}/mkfs.log" 2>&1; then
        ci_log "btrfs image built with mkfs.btrfs --rootdir"
    else
        # --rootdir needs a recent btrfs-progs; the runner has sudo, so fall back to
        # a loop mount when the flag is unavailable.
        ci_warn "mkfs.btrfs --rootdir failed, falling back to loop mount"
        mkfs.btrfs -f -L wf-s1 -m single -d single "${image}" >>"${qemu_dir}/mkfs.log" 2>&1 \
            || ci_die "mkfs.btrfs failed, see ${qemu_dir}/mkfs.log"
        mnt="${qemu_dir}/mnt"
        mkdir -p "${mnt}"
        sudo mount -o loop "${image}" "${mnt}"
        sudo cp "${payload}/S1-IMAGE-MARKER" "${payload}/hello.txt" "${mnt}/"
        sudo sync
        sudo umount "${mnt}"
    fi
fi

# --------------------------------------------------------------------------- #
# Boot
# --------------------------------------------------------------------------- #

append="console=ttyS0 panic=1 loglevel=7 wf.dev=/dev/vda wf.mark=/S1-IMAGE-MARKER wf.case=${case_label}"
if [ -n "${init_path}" ]; then
    # The kernel honours rdinit= for an initramfs; init= only applies to a real root,
    # so the probe would silently fall back to /init and run the wrong stage.
    append="${append} rdinit=${init_path}"
fi
if [ -n "${append_extra}" ]; then
    append="${append} ${append_extra}"
fi

qemu_args=(
    -m "${mem}"
    -smp 2
    -accel tcg
    -display none
    -monitor none
    -no-reboot
    -serial "file:${serial}"
    -kernel "${kernel}"
    -initrd "${initramfs}"
    -append "${append}"
    -drive "file=${image},if=virtio,format=raw,cache=unsafe"
)

if [ "${mode}" = "uefi" ]; then
    ovmf=""
    for candidate in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/ovmf/x64/OVMF.fd; do
        if [ -f "${candidate}" ]; then
            ovmf="${candidate}"
            break
        fi
    done
    [ -n "${ovmf}" ] || ci_die "no OVMF firmware found for the uefi mode"
    ci_log "OVMF firmware: ${ovmf}"
    qemu_args+=(-bios "${ovmf}")
fi

ci_log "booting (${mode}, tcg, ${mem} MiB, limit ${timeout_s}s)"
started="$(date +%s)"
set +e
timeout "${timeout_s}" qemu-system-x86_64 "${qemu_args[@]}" \
    >"${qemu_dir}/qemu-${mode}.out" 2>&1
qemu_rc=$?
set -e
boot_seconds=$(( $(date +%s) - started ))
ci_log "qemu exited with ${qemu_rc} after ${boot_seconds}s (124 means the timeout fired)"

# --------------------------------------------------------------------------- #
# Assertion
# --------------------------------------------------------------------------- #

judge_line="$(grep -m 1 "^${judge_prefix}=" "${serial}" 2>/dev/null || true)"
count="$(grep -c "^${judge_prefix}=" "${serial}" 2>/dev/null || true)"
[ -n "${count}" ] || count=0

ci_emit_output "serial_log" "${serial}"
ci_emit_output "judge_line" "${judge_line}"
ci_emit_output "boot_seconds" "${boot_seconds}"
ci_emit_output "qemu_mode" "${mode}"
ci_emit_output "judge_prefix" "${judge_prefix}"

if [ "${count}" != "1" ]; then
    ci_warn "expected exactly one ${judge_prefix} line, found ${count}"
fi
if [ -z "${judge_line}" ] || [ "${judge_line#"${judge_prefix}"=ok}" = "${judge_line}" ]; then
    ci_warn "serial log tail:"
    tail -n 60 "${serial}" 2>/dev/null | sed 's/^/[qemu]   /' || true
    ci_die "${judge_prefix} failed: '${judge_line:-no ${judge_prefix} line in the serial log}'"
fi

ci_log "judge line: ${judge_line}"
ci_log "stage qemu finished"
