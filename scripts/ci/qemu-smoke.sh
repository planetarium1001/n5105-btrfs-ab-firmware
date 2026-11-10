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
#   CI_QEMU_MODE      "kernel" (default), "uefi" (boots through OVMF) or
#                     "uefi-disk" (OVMF boots the ESP on CI_QEMU_DISK, so GRUB --
#                     not QEMU -- supplies the kernel, the initrd and the command
#                     line; that is the only mode that exercises the real boot path)
#   CI_QEMU_TIMEOUT   wall-clock limit in seconds (default: 900)
#   CI_QEMU_MEM       guest memory in MiB (default: 1024)
#   CI_S1_CASE        label recorded in the guest and in the log
#   CI_QEMU_CASE      preferred label, falls back to CI_S1_CASE
#   CI_QEMU_DISK      use this prepared raw image as the virtio disk instead of
#                     building a throwaway test filesystem (S2 and later)
#   CI_QEMU_INIT      rdinit= path inside the initramfs (default: /init)
#   CI_JUDGE_PREFIX   judge line prefix to assert (default: S1-RESULT, empty = the
#                     caller grades the run itself, e.g. by reading the image back)
#   CI_QEMU_STOP_PATTERN  serial pattern that means "the guest is done"
#                     (default: ^<judge prefix>=)
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
judge_prefix="${CI_JUDGE_PREFIX-S1-RESULT}"
stop_pattern="${CI_QEMU_STOP_PATTERN:-}"
if [ -z "${stop_pattern}" ] && [ -n "${judge_prefix}" ]; then
    stop_pattern="^${judge_prefix}="
fi
[ -n "${stop_pattern}" ] || ci_die "either CI_JUDGE_PREFIX or CI_QEMU_STOP_PATTERN is required"
append_extra="${CI_QEMU_APPEND_EXTRA:-}"

[ -f "${kernel}" ] || ci_die "kernel image not found: ${kernel}"
[ -f "${initramfs}" ] || ci_die "initramfs not found: ${initramfs}"
if [ -n "${given_disk}" ]; then
    [ -f "${given_disk}" ] || ci_die "disk image not found: ${given_disk}"
fi
case "${mode}" in
    kernel | uefi) : ;;
    uefi-disk) : ;;
    *) ci_die "CI_QEMU_MODE must be kernel, uefi or uefi-disk, got ${mode}" ;;
esac

if [ "${mode}" = "uefi-disk" ]; then
    # The firmware reads the ESP and runs GRUB, which then loads the kernel and the
    # initrd through its own linux/initrd lines. Passing -kernel/-initrd/-append here
    # would bypass exactly the path this mode exists to prove.
    [ -n "${given_disk}" ] || ci_die "uefi-disk needs CI_QEMU_DISK, the firmware has to boot the ESP from the disk"
    [ -z "${append_extra}" ] ||
        ci_die "uefi-disk takes the kernel command line from grub.cfg, not from CI_QEMU_APPEND_EXTRA (${append_extra})"
fi

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
)
if [ "${mode}" = "uefi-disk" ]; then
    qemu_args+=(-boot "order=c")
else
    qemu_args+=(
        -kernel "${kernel}"
        -initrd "${initramfs}"
        -append "${append}"
    )
fi
qemu_args+=(
    -drive "file=${image},if=virtio,format=raw,cache=unsafe"
    # The health check looks for a wan device; virtio_net is built into this kernel.
    -netdev "user,id=n0"
    -device "virtio-net-pci,netdev=n0"
)

if [ "${mode}" = "uefi" ] || [ "${mode}" = "uefi-disk" ]; then
    # OVMF is two pflash images: a read-only code image and a writable variable store.
    # `-bios <CODE>` looks simpler but does not work with the 4 MiB split images the
    # runner ships -- QEMU exits within a second and the guest never reaches the
    # serial log, which is exactly how the old informational OVMF boot was failing.
    ovmf_code=""
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/ovmf/x64/OVMF.fd; do
        if [ -f "${candidate}" ]; then
            ovmf_code="${candidate}"
            break
        fi
    done
    [ -n "${ovmf_code}" ] || ci_die "no OVMF code image found for the ${mode} mode"
    ovmf_vars=""
    for candidate in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/ovmf/OVMF_VARS.fd \
        /usr/share/ovmf/x64/OVMF_VARS.fd; do
        if [ -f "${candidate}" ]; then
            ovmf_vars="${candidate}"
            break
        fi
    done
    if [ -n "${ovmf_vars}" ]; then
        vars_copy="${qemu_dir}/OVMF_VARS-${mode}.fd"
        cp "${ovmf_vars}" "${vars_copy}"
        ci_log "OVMF code: ${ovmf_code}, writable variables: ${vars_copy} (from ${ovmf_vars})"
        qemu_args+=(
            -drive "if=pflash,format=raw,unit=0,readonly=on,file=${ovmf_code}"
            -drive "if=pflash,format=raw,unit=1,file=${vars_copy}"
        )
    else
        ci_log "OVMF firmware: ${ovmf_code} (-bios, no variable store found)"
        qemu_args+=(-bios "${ovmf_code}")
    fi
fi

ci_log "booting (${mode}, tcg, ${mem} MiB, limit ${timeout_s}s)"
started="$(date +%s)"

# The guest may keep running after printing the judge line (S3 hands control to the
# upstream init), so watch the serial log and stop the machine as soon as the verdict
# appears instead of always waiting for the timeout.
set +e
timeout "${timeout_s}" qemu-system-x86_64 "${qemu_args[@]}" \
    >"${qemu_dir}/qemu-${mode}.out" 2>&1 &
qemu_pid=$!
stopped_on_judge=0
deadline=$((started + timeout_s))
while kill -0 "${qemu_pid}" 2>/dev/null; do
    if grep -Eq "${stop_pattern}" "${serial}" 2>/dev/null; then
        stopped_on_judge=1
        sleep 1
        kill "${qemu_pid}" 2>/dev/null
        break
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        break
    fi
    sleep 0.5
done
wait "${qemu_pid}" 2>/dev/null
qemu_rc=$?
set -e
boot_seconds=$(( $(date +%s) - started ))
if [ "${stopped_on_judge}" = "1" ]; then
    ci_log "qemu stopped on the judge line after ${boot_seconds}s"
else
    ci_log "qemu exited with ${qemu_rc} after ${boot_seconds}s (124 means the timeout fired)"
    if [ "${boot_seconds}" -lt 10 ]; then
        # An early exit is a QEMU or firmware error, not a slow guest: show what QEMU
        # itself said, otherwise the only symptom is "no judge line".
        ci_warn "qemu exited within ${boot_seconds}s, its own output follows:"
        tail -n 20 "${qemu_dir}/qemu-${mode}.out" 2>/dev/null | sed 's/^/[qemu]   /' || true
    fi
fi

# --------------------------------------------------------------------------- #
# Assertion
# --------------------------------------------------------------------------- #

if [ -n "${judge_prefix}" ]; then
    judge_line="$(grep -m 1 "^${judge_prefix}=" "${serial}" 2>/dev/null || true)"
    count="$(grep -c "^${judge_prefix}=" "${serial}" 2>/dev/null || true)"
else
    judge_line=""
    count=0
fi
[ -n "${count}" ] || count=0

ci_emit_output "serial_log" "${serial}"
ci_emit_output "judge_line" "${judge_line}"
ci_emit_output "boot_seconds" "${boot_seconds}"
ci_emit_output "qemu_mode" "${mode}"
ci_emit_output "judge_prefix" "${judge_prefix}"
ci_emit_output "stopped_on_judge" "${stopped_on_judge}"

if [ -n "${judge_prefix}" ]; then
    if [ "${count}" != "1" ]; then
        ci_warn "expected exactly one ${judge_prefix} line, found ${count}"
    fi
    if [ -z "${judge_line}" ] || [ "${judge_line#"${judge_prefix}"=ok}" = "${judge_line}" ]; then
        ci_warn "serial log tail:"
        tail -n 60 "${serial}" 2>/dev/null | sed 's/^/[qemu]   /' || true
        ci_die "${judge_prefix} failed: '${judge_line:-no ${judge_prefix} line in the serial log}'"
    fi
    ci_log "judge line: ${judge_line}"
else
    if [ "${stopped_on_judge}" != "1" ]; then
        ci_warn "serial log tail:"
        tail -n 60 "${serial}" 2>/dev/null | sed 's/^/[qemu]   /' || true
        ci_die "the guest never printed the stop pattern"
    fi
    ci_log "guest stopped on the stop pattern, the caller grades the run"
fi
ci_log "stage qemu finished"
