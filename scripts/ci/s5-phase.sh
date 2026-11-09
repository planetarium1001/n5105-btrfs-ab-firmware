#!/usr/bin/env bash
# Stage "s5-phase": grade one boot of the upgrade run by reading the image back.
#
# The guest is not asked to grade itself; each phase mounts the ESP (and, where it
# matters, the writable partition) and checks what the system actually wrote.
#
#   --phase upgrade --slot b --version <v> --layer <name>
#       the upgrade recorded the new layer and version and marked the slot pending
#       -> S5-EVIDENCE=ok phase=upgrade slot=<slot>
#
#   --phase commit --slot b
#       the candidate boot committed, reclamation left only referenced layers, and the
#       conflict report is on the ESP
#       -> S5-RESULT=ok upgrade=<slot> conflicts=<n> reclaimed=<n>
#
#   --phase degraded --serial <file>
#       the boot survived a broken writable partition
#       -> S5-EVIDENCE=ok phase=degraded target=p4
#
# Inputs (environment): CI_IMAGE

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init s5-phase

image="${CI_IMAGE:?CI_IMAGE is required}"
work="${CI_TMP_ROOT}/s5-phase"

phase=""
slot=""
version=""
layer=""
serial=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --phase) phase="${2:?}"; shift 2 ;;
        --slot) slot="${2:?}"; shift 2 ;;
        --version) version="${2:?}"; shift 2 ;;
        --layer) layer="${2:?}"; shift 2 ;;
        --serial) serial="${2:?}"; shift 2 ;;
        *) ci_die "unknown argument: $1" ;;
    esac
done
[ -n "${phase}" ] || ci_die "--phase is required"
[ -f "${image}" ] || ci_die "image not found: ${image}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required"

mkdir -p "${work}"
esp="${work}/esp"
p4="${work}/p4"
mkdir -p "${esp}" "${p4}"

fail_phase() {
    printf 'S5-RESULT=fail reason=%s\n' "$1"
    exit 1
}

loopdev=""
mounted=()
cleanup() {
    if [ -n "${loopdev}" ]; then
        for dir in ${mounted[@]+"${mounted[@]}"}; do
            sudo umount "${dir}" 2>/dev/null || true
        done
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --show --partscan "${image}")"
attempt=0
until [ -b "${loopdev}p4" ] || [ "${attempt}" -ge 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
done

mount_esp() {
    sudo mount -t vfat -o ro "${loopdev}p1" "${esp}"
    mounted+=("${esp}")
}

# --------------------------------------------------------------------------- #
# Degraded phase: no image state to read, only the serial log
# --------------------------------------------------------------------------- #

if [ "${phase}" = "degraded" ]; then
    [ -n "${serial}" ] && [ -f "${serial}" ] || ci_die "degraded phase needs --serial"
    if ! grep -q 'p4=degraded' "${serial}"; then
        ci_warn "serial log does not report a degraded boot"
        tail -n 40 "${serial}" | sed 's/^/[s5-phase]   /'
        fail_phase "p4-not-degraded"
    fi
    if ! grep -q 'action=degraded-boot' "${serial}"; then
        ci_warn "the boot initramfs did not take the degraded path"
        fail_phase "no-degraded-boot-record"
    fi
    if ! grep -q 'ab-boot: running slot' "${serial}"; then
        ci_warn "the system did not reach userspace"
        fail_phase "userspace-not-reached"
    fi
    ci_log "degraded boot verified from the serial log"
    printf 'S5-EVIDENCE=ok phase=degraded target=p4\n'
    ci_emit_output "evidence_line" "S5-EVIDENCE=ok phase=degraded target=p4"
    exit 0
fi

# --------------------------------------------------------------------------- #
# Image-side phases
# --------------------------------------------------------------------------- #

mount_esp
state="${esp}/ab/state.json"
[ -f "${state}" ] || fail_phase state-missing
committed="$(sudo sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
if sudo grep -q '"pending": *null' "${state}"; then pending="none"; else
    pending="$(sudo sed -n 's/.*"pending": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
fi
ci_log "committed=${committed:-?} pending=${pending:-?}"

if [ "${phase}" = "upgrade" ]; then
    [ -n "${slot}" ] || ci_die "upgrade phase needs --slot"
    [ -n "${version}" ] || ci_die "upgrade phase needs --version"
    [ -n "${layer}" ] || ci_die "upgrade phase needs --layer"
    [ "${pending}" = "${slot}" ] || fail_phase "pending-is-${pending}"
    if ! sudo grep -q "\"upper\": \"${layer}\"" "${state}"; then
        ci_warn "state does not record the new layer ${layer}"
        sudo sed -e 's/^/[s5-phase]   /' "${state}"
        fail_phase "layer-not-recorded"
    fi
    if ! sudo grep -q "\"rootfs\": \"${version}\"" "${state}"; then
        ci_warn "state does not record the new version ${version}"
        fail_phase "version-not-recorded"
    fi
    line="S5-EVIDENCE=ok phase=upgrade slot=${slot}"
    printf '%s\n' "${line}"
    ci_emit_output "evidence_line" "${line}"
    exit 0
fi

[ "${phase}" = "commit" ] || ci_die "unknown phase: ${phase}"
[ -n "${slot}" ] || ci_die "commit phase needs --slot"
[ "${committed}" = "${slot}" ] || fail_phase "committed-is-${committed}"
[ "${pending}" = "none" ] || fail_phase "pending-is-${pending}"

boot_log="${esp}/ab/log/boot-0.log"
sudo grep -q "stage=commit slot=${slot}" "${boot_log}" 2>/dev/null ||
    fail_phase "no-commit-record"
ci_log "boot log records the commit of slot ${slot}"

# Conflicts: the report exists and its header is well formed.
conflicts=0
if sudo test -f "${esp}/ab/conflicts.log"; then
    conflicts="$(sudo sed -n 's/^conflicts=\([0-9]*\).*/\1/p' "${esp}/ab/conflicts.log" | head -n 1)"
    [ -n "${conflicts}" ] || conflicts=0
else
    fail_phase "conflicts-report-missing"
fi
ci_log "conflict report: ${conflicts} conflict(s)"

# Reclamation: the early gc in ab-boot reports how many layers it removed.
reclaimed="$(sudo sed -n 's/.*stage=gc .*reclaimed=\([0-9]*\).*/\1/p' "${boot_log}" | tail -n 1)"
[ -n "${reclaimed}" ] || reclaimed=0
ci_log "early reclamation removed ${reclaimed} layer(s)"

# Every layer left on the writable partition must be referenced by a slot.
sudo mount -o ro "${loopdev}p4" "${p4}"
mounted+=("${p4}")
layers="$(sudo btrfs subvolume list "${p4}" | sed -n 's/.* path //p' | grep '^@overlay-' | sort)"
referenced="$(sudo grep -o '"upper": "@overlay-[^"]*"' "${state}" | sed 's/.*"\(@overlay-[^"]*\)"/\1/' | sort -u)"
ci_log "layers on p4: $(printf '%s' "${layers}" | tr '\n' ' ')"
ci_log "referenced:   $(printf '%s' "${referenced}" | tr '\n' ' ')"
unreferenced="$(printf '%s\n' "${layers}" | grep -vxF -f <(printf '%s\n' "${referenced}") || true)"
if [ -n "${unreferenced}" ]; then
    ci_warn "unreferenced layers survived reclamation: ${unreferenced}"
    fail_phase "unreferenced-layer-left"
fi

printf 'S5-RESULT=ok upgrade=%s conflicts=%s reclaimed=%s\n' "${slot}" "${conflicts}" "${reclaimed}"
ci_emit_output "judge_line" "S5-RESULT=ok upgrade=${slot} conflicts=${conflicts} reclaimed=${reclaimed}"
ci_emit_output "conflicts" "${conflicts}"
ci_emit_output "reclaimed" "${reclaimed}"
ci_log "commit of slot ${slot} verified"
