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
#   --phase commit --slot b --orphan <layer> --serial <file>
#       the candidate boot committed, reclamation removed the fixture's unreferenced layer
#       and left only referenced subvolumes, and the conflict report is on the ESP
#       -> S5-RESULT=ok upgrade=<slot> conflicts=<n> reclaimed=<n>
#       --orphan is the layer the fixture created (scripts/ci/ab-fixtures.sh publishes it
#       as the `orphan_layer` output). It is required: without it the phase can only say
#       "no unreferenced layer is left", which is also true of a run whose fixture never
#       created one - and that silence is how the 25.12.1 line reported reclaimed=0 while
#       proving nothing.
#       The input is asserted before the output: a FAT chain the driver already declared
#       broken (reason=esp-corrupt) or an ESP that refuses a write probe
#       (reason=esp-read-only) is named as the machine fault it is, never as the product
#       failing to commit.
#
#   --phase toolchain --serial <file>
#       the guest proved the btrfs tool runs and can list subvolumes
#       -> S5-EVIDENCE=ok phase=toolchain
#
#   --phase degraded --serial <file>
#       the boot survived a broken writable partition
#       -> S5-EVIDENCE=ok phase=degraded target=p4
#
# Inputs (environment): CI_IMAGE
#   CI_S5_PART_WAIT_ATTEMPTS  quarter-second polls for the p4 node after losetup
#                             --partscan (default 40; tests set 0 because they drive the
#                             grader from a directory fixture with no loop device)

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
orphan=""
serial=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --phase) phase="${2:?}"; shift 2 ;;
        --slot) slot="${2:?}"; shift 2 ;;
        --version) version="${2:?}"; shift 2 ;;
        --layer) layer="${2:?}"; shift 2 ;;
        --orphan) orphan="${2:?}"; shift 2 ;;
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

# fat_damage_evidence: the FAT driver says a chain is broken before any state assertion
# can mean anything. "FAT-fs ... invalid cluster chain" and "Filesystem has been set
# read-only" are the two lines the kernel prints on the image that produced the false
# "committed-is-a" red: the harness cut QEMU off mid-write, the next boot found the
# damage, and the commit could never be recorded. The evidence is printed once and the
# phase fails as esp-corrupt, so a damaged machine is not reported as the product.
fat_damage_evidence() {
    _fat_re='FAT-fs .*invalid cluster chain|Filesystem has been set read-only'
    _files=("${boot_log}")
    if [ -n "${serial}" ]; then
        _files=("${serial}" "${boot_log}")
    fi
    for _file in "${_files[@]}"; do
        [ -f "${_file}" ] || continue
        _hits="$(sudo grep -E "${_fat_re}" "${_file}" 2>/dev/null || true)"
        if [ -n "${_hits}" ]; then
            printf '%s\n' "${_hits}"
            return 0
        fi
    done
    return 1
}

# esp_write_probe: the commit phase asserts its input, not only its output. A read-only
# ESP cannot record a commit, so the phase must not read that as "the product did not
# commit". The ESP is remounted read-write in place rather than mounted a second time: the
# kernel shares one superblock per block device and refuses to change its read-only state
# through a second mount, so a second `-o rw` mount would report every ESP as read-only.
# A tiny file is written at the ESP root and removed; it does not depend on the ab/ tree a
# half-initialised ESP may not have. The mount stays read-write for the rest of the phase,
# which only reads.
ESP_WRITE_REASON=""
esp_write_probe() {
    if ! sudo umount "${esp}"; then
        ESP_WRITE_REASON="unmount-failed"
        return 1
    fi
    if ! sudo mount -t vfat -o rw "${loopdev}p1" "${esp}"; then
        ESP_WRITE_REASON="rw-mount-failed"
        return 1
    fi
    _probe="${esp}/.s5-write-probe.$$"
    if ! printf 's5-phase write probe\n' | sudo tee "${_probe}" >/dev/null 2>&1; then
        ESP_WRITE_REASON="write-failed:${_probe}"
        return 1
    fi
    if ! sudo rm -f "${_probe}" 2>/dev/null; then
        ESP_WRITE_REASON="remove-failed:${_probe}"
        return 1
    fi
    return 0
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
# losetup --partscan returns before the kernel names the nodes. Forty quarter-second
# attempts is the budget a real image needs; the tests drive the grader from a directory
# fixture with no loop device behind it, so they set this to 0 instead of burning ten
# seconds per case.
part_attempts="${CI_S5_PART_WAIT_ATTEMPTS:-40}"
case "${part_attempts}" in
    '' | *[!0-9]*) part_attempts=40 ;;
esac
until [ -b "${loopdev}p4" ] || [ "${attempt}" -ge "${part_attempts}" ]; do
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

if [ "${phase}" = "toolchain" ]; then
    [ -n "${serial}" ] && [ -f "${serial}" ] || ci_die "toolchain phase needs --serial"
    if ! grep -q 'btrfs=ok subvolume-list=ok' "${serial}"; then
        ci_warn "the guest did not report a working btrfs tool"
        grep -E 'ab-boot: btrfs|stage=btrfs-check' "${serial}" | sed 's/^/[s5-phase]   /' || true
        fail_phase "btrfs-toolchain-not-ok"
    fi
    usage_line="$(grep -m 1 'ab-boot: btrfs-tool' "${serial}" | sed 's/.*btrfs-tool //')"
    ci_log "guest btrfs: ${usage_line}"
    line="S5-EVIDENCE=ok phase=toolchain tool=${usage_line:-unknown}"
    printf '%s\n' "${line}"
    ci_emit_output "evidence_line" "${line}"
    exit 0
fi

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
boot_log="${esp}/ab/log/boot-0.log"

# The commit phase is the one graded on state the product wrote, so its *input* has to be
# proven before the state is read: an ESP the kernel already declared broken must not be
# recorded as the product failing to commit. The corruption scan comes first because it is
# the more specific evidence; the write probe then catches a read-only ESP that left no
# FAT line behind.
if [ "${phase}" = "commit" ]; then
    [ -n "${serial}" ] && [ -f "${serial}" ] || ci_die "commit phase needs --serial"
    if fat_hits="$(fat_damage_evidence)"; then
        ci_log "the FAT ESP was already damaged before this phase ran, so no commit could have been recorded:"
        printf '%s\n' "${fat_hits}" | sed 's/^/[s5-phase]   /'
        fail_phase esp-corrupt
    fi
    if ! esp_write_probe; then
        ci_log "the ESP refuses writes (${ESP_WRITE_REASON}); the commit could not have been recorded"
        ci_log "reason=esp-read-only names a harness/machine fault, not a product verdict"
        fail_phase esp-read-only
    fi
    ci_log "the ESP accepts writes: the write probe was removed again"
fi

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
# The layer the fixture created is the subject of the reclamation assertion. Required,
# because "no unreferenced layer is left" is also true of a run whose fixture created
# none - the exact silence that let the 25.12.1 line report reclaimed=0 and pass.
[ -n "${orphan}" ] || ci_die "commit phase needs --orphan <layer>: the unreferenced layer the fixture created"
case "${orphan}" in
    @overlay-?*) : ;;
    *) ci_die "--orphan must be a layer in the @overlay-* namespace gc reclaims: ${orphan}" ;;
esac
[ "${committed}" = "${slot}" ] || fail_phase "committed-is-${committed}"
[ "${pending}" = "none" ] || fail_phase "pending-is-${pending}"

# The record has to be the one line that says the commit succeeded. `grep -q "stage=commit
# slot=b"` also matched the failure record "stage=commit slot=b result=fail
# reason=commit-failed", so a boot whose commit failed could be graded ok - the exact line
# this image prints when the FAT ESP is cut off mid-write. Both fields are required on the
# same line now.
if ! sudo grep -Eq "stage=commit slot=${slot}( |\$).*result=ok( |\$)" "${boot_log}" 2>/dev/null; then
    ci_warn "the boot log has no successful commit record for slot ${slot}"
    sudo grep -E "stage=commit slot=${slot}( |\$)" "${boot_log}" 2>/dev/null |
        sed 's/^/[s5-phase]   /' || true
    fail_phase "no-commit-record"
fi
ci_log "boot log records the commit of slot ${slot}"

# Conflicts: the report exists, its baseline was readable, and the fixture's conflict
# was actually detected (the fixture edits /etc/banner on both sides on purpose).
conflicts=0
if sudo test -f "${esp}/ab/conflicts.log"; then
    conflicts="$(sudo sed -n 's/^conflicts=\([0-9]*\).*/\1/p' "${esp}/ab/conflicts.log" | head -n 1)"
    [ -n "${conflicts}" ] || conflicts=0
    if ! sudo grep -q 'baseline=ok' "${esp}/ab/conflicts.log"; then
        ci_warn "the conflict report has no readable baseline, so no comparison happened"
        sudo sed -e 's/^/[s5-phase]   /' "${esp}/ab/conflicts.log"
        fail_phase "conflict-baseline-unreadable"
    fi
else
    fail_phase "conflicts-report-missing"
fi
ci_log "conflict report: ${conflicts} conflict(s)"
if [ "${conflicts}" -lt 1 ]; then
    ci_warn "the fixture changes /etc/banner on both sides, so at least one conflict is expected"
    sudo sed -e 's/^/[s5-phase]   /' "${esp}/ab/conflicts.log"
    fail_phase "conflicts-not-detected"
fi

# Reclamation: the early gc in ab-boot reports how many layers it removed, and the fixture
# created exactly one unreferenced layer for it to remove. Both halves are asserted: the
# count says something was removed, the leftover scan below says what is left.
#
# The count is read from the whole log ring (boot-0/1/2), not from boot-0.log alone. The
# ring is rotated on every boot, so the boot that removed the fixture's layer is not
# necessarily the boot this phase grades - and a fixture layer whose name gc's @overlay-*
# filter never matched removed nothing in *any* boot. Reading one file printed 0 for both,
# which is the number that let the 25.12.1 line look like a run with nothing to reclaim.
reclaimed=0
reclaimed_ring=""
for ring_log in "${esp}/ab/log/boot-0.log" "${esp}/ab/log/boot-1.log" "${esp}/ab/log/boot-2.log"; do
    sudo test -f "${ring_log}" || continue
    ring_count="$(sudo sed -n 's/.*stage=gc .*reclaimed=\([0-9]*\).*/\1/p' "${ring_log}" | tail -n 1)"
    [ -n "${ring_count}" ] || ring_count=0
    reclaimed=$((reclaimed + ring_count))
    reclaimed_ring="${reclaimed_ring} ${ring_log##*/}=${ring_count}"
done
ci_log "early reclamation removed ${reclaimed} layer(s) across the log ring (${reclaimed_ring# })"
ci_log "the fixture created the unreferenced layer ${orphan}"
if [ "${reclaimed}" -lt 1 ]; then
    ci_warn "no boot in the log ring reclaimed a layer, but the fixture created ${orphan} for reclamation to remove"
    for ring_log in "${esp}/ab/log/boot-0.log" "${esp}/ab/log/boot-1.log" "${esp}/ab/log/boot-2.log"; do
        sudo test -f "${ring_log}" || continue
        sudo grep -E 'stage=gc|early reclamation|btrfs-check' "${ring_log}" 2>/dev/null |
            sed "s/^/[s5-phase]   ${ring_log##*/}: /" || true
    done
    fail_phase "reclaim-not-exercised"
fi

# Every subvolume left on the writable partition must be referenced by a slot, and the
# unreferenced layer the fixture created must be gone. The scan lists *every* subvolume
# rather than only the @overlay-* ones: gc deletes whatever its reference set does not name,
# whatever the name looks like, so a leftover outside the prefix has to be visible here.
# The 25.12.1 line shipped a fallback layer named orphan-<pid>-<stamp>, this scan filtered
# on ^@overlay- and gc's own listing filtered on `path @overlay-`, and between the two of
# them nothing could ever report that layer again.
sudo mount -o ro "${loopdev}p4" "${p4}"
mounted+=("${p4}")
subvols="$(sudo btrfs subvolume list "${p4}" | sed -n 's/.* path //p' | sort)"
referenced="$(sudo sed -n 's/.*"upper": *"\([^"]*\)".*/\1/p' "${state}" | sort -u)"
# The subvolumes the image ships for its own purposes (disk.sh creates them next to the
# layers), so they are neither a slot's layer nor a leak.
p4_reserved="@docker @swap @data"
ci_log "subvolumes on p4: $(printf '%s' "${subvols}" | tr '\n' ' ')"
ci_log "referenced:       $(printf '%s' "${referenced}" | tr '\n' ' ')"
if printf '%s\n' "${referenced}" | grep -qxF "${orphan}"; then
    ci_warn "the state file references ${orphan}; the fixture did not create an unreferenced layer"
    fail_phase "orphan-layer-referenced"
fi
if printf '%s\n' "${subvols}" | grep -qxF "${orphan}"; then
    ci_warn "the unreferenced layer ${orphan} is still on p4 after reclamation"
    fail_phase "orphan-layer-left"
fi
kept="$(printf '%s\n%s\n' "${referenced}" "${p4_reserved}" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
unreferenced="$(printf '%s\n' "${subvols}" | grep -vxF -f <(printf '%s\n' "${kept}") || true)"
if [ -n "${unreferenced}" ]; then
    ci_warn "unreferenced subvolumes survived reclamation: ${unreferenced}"
    fail_phase "unreferenced-layer-left"
fi

printf 'S5-RESULT=ok upgrade=%s conflicts=%s reclaimed=%s\n' "${slot}" "${conflicts}" "${reclaimed}"
ci_emit_output "judge_line" "S5-RESULT=ok upgrade=${slot} conflicts=${conflicts} reclaimed=${reclaimed}"
ci_emit_output "conflicts" "${conflicts}"
ci_emit_output "reclaimed" "${reclaimed}"
ci_log "commit of slot ${slot} verified"
