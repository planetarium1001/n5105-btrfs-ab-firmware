#!/usr/bin/env bash
# Stage "report": summarise the pipeline for humans and fail the run if a stage
# that was actually scheduled did not succeed.
#
# Inputs (environment), all optional so a partially scheduled pipeline still reports:
#   CI_REQUESTED_STAGE       requested stage (all|fetch|assemble|verify)
#   CI_TRIGGER, CI_REF, CI_SHA
#   CI_RESOLVE_RESULT        needs.<job>.result: success|failure|cancelled|skipped
#   CI_FETCH_RESULT
#   CI_ASSEMBLE_RESULT
#   CI_VERIFY_RESULT
#   CI_UPSTREAM_VERSION, CI_VERSION_SOURCE, CI_KERNEL_PACKAGE, CI_KMODS_DIR
#   CI_CACHE_KEY, CI_CACHE_HIT, CI_FETCH_TOTAL_BYTES
#   CI_PAYLOAD_MEMBERS, CI_PAYLOAD_TOTAL_BYTES, CI_PAYLOAD_MANIFEST_SHA256
#   CI_VERIFY_STATUS, CI_DESIGN_CHECKS_STATUS, CI_DESIGN_PROBLEMS, CI_SHELLCHECK_STATUS
#   CI_S1_RESULT, CI_S1_LINE, CI_S1_MODULES, CI_S1_BOOT_SECONDS,
#   CI_S1_UEFI_LINE, CI_S1_APK_CROSSCHECK
#   CI_S2_RESULT, CI_S2_LINE, CI_S2_IMAGE_BYTES, CI_S2_IMAGE_GZ_BYTES,
#   CI_S2_ROOTFS_FILES, CI_S2_HOST_CHECKS
#   CI_S3_RESULT, CI_S3_LINE, CI_S3_LINE_BOOT2, CI_S3_SLOT, CI_S3_UPPER
#   CI_S4_RESULT, CI_S4_LINE_COMMIT_A, CI_S4_LINE_ABANDON_B, CI_S4_LINE_COMMIT_B,
#   CI_S4_COMMITTED_FINAL
#   CI_S5_RESULT, CI_S5_LINE, CI_S5_UPGRADE_LINE, CI_S5_DEGRADED_LINE,
#   CI_S5_CONFLICTS, CI_S5_RECLAIMED

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init report

# human_bytes <bytes>: decimal MiB rendering with one fractional digit.
human_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN { printf "%.1f MiB", bytes / 1048576 }'
}

# result_cell <result>: mark a job result so a skipped stage is visibly different
# from a successful one.
result_cell() {
    local result="${1-}"
    case "${result}" in
        success) printf 'pass' ;;
        skipped) printf 'skipped' ;;
        cancelled) printf 'cancelled' ;;
        "") printf 'n/a' ;;
        *) printf '%s' "${result}" ;;
    esac
}

overall="success"
for result in \
    "${CI_RESOLVE_RESULT:-}" \
    "${CI_FETCH_RESULT:-}" \
    "${CI_ASSEMBLE_RESULT:-}" \
    "${CI_S1_RESULT:-}" \
    "${CI_S2_RESULT:-}" \
    "${CI_S3_RESULT:-}" \
    "${CI_S4_RESULT:-}" \
    "${CI_S5_RESULT:-}" \
    "${CI_VERIFY_RESULT:-}"; do
    case "${result}" in
        failure | cancelled | timed_out) overall="failure" ;;
    esac
done

stage="${CI_REQUESTED_STAGE:-all}"
[ -n "${stage}" ] || stage="all"

if [ "${overall}" = "success" ]; then
    verdict="all scheduled stages passed"
else
    verdict="at least one stage failed"
fi

# The summary is written to the Actions job summary and echoed so the same content
# is visible in the raw log.
{
    printf '## CI summary — %s\n' "${verdict}"
    printf '\n'
    printf '| Field | Value |\n'
    printf '|---|---|\n'
    printf '| Requested stage | `%s` |\n' "${stage}"
    printf '| Trigger | `%s` |\n' "${CI_TRIGGER:-unknown}"
    printf '| Ref | `%s` |\n' "${CI_REF:-unknown}"
    printf '| Commit | `%s` |\n' "${CI_SHA:-unknown}"
    printf '| Upstream version | `%s` (%s) |\n' "${CI_UPSTREAM_VERSION:-unresolved}" "${CI_VERSION_SOURCE:-n/a}"
    printf '| Kernel package | `%s` |\n' "${CI_KERNEL_PACKAGE:-unknown}"
    printf '| Kernel module dir | `%s` |\n' "${CI_KMODS_DIR:-unknown}"
    printf '| Cache key | `%s` (hit: %s) |\n' "${CI_CACHE_KEY:-n/a}" "${CI_CACHE_HIT:-n/a}"
    printf '\n'
    printf '| Stage | Result | Detail |\n'
    printf '|---|---|---|\n'
    printf '| resolve | %s | %s |\n' "$(result_cell "${CI_RESOLVE_RESULT:-}")" \
        "${CI_UPSTREAM_VERSION:-no upstream version resolved}"
    printf '| fetch | %s | %s verified |\n' "$(result_cell "${CI_FETCH_RESULT:-}")" \
        "$(human_bytes "${CI_FETCH_TOTAL_BYTES:-0}")"
    printf '| assemble | %s | members: %s, %s |\n' "$(result_cell "${CI_ASSEMBLE_RESULT:-}")" \
        "${CI_PAYLOAD_MEMBERS:-none}" "$(human_bytes "${CI_PAYLOAD_TOTAL_BYTES:-0}")"
    printf '| verify | %s | design checks: %s (%s problem(s)), shellcheck: %s |\n' \
        "$(result_cell "${CI_VERIFY_RESULT:-}")" \
        "${CI_DESIGN_CHECKS_STATUS:-n/a}" "${CI_DESIGN_PROBLEMS:-0}" "${CI_SHELLCHECK_STATUS:-n/a}"
    printf '| s1 | %s | %s module(s), %ss boot, apk cross-check: %s |\n' \
        "$(result_cell "${CI_S1_RESULT:-}")" \
        "${CI_S1_MODULES:-n/a}" "${CI_S1_BOOT_SECONDS:-n/a}" "${CI_S1_APK_CROSSCHECK:-n/a}"
    printf '| s2 | %s | %s raw / %s gz, %s file(s) in @sys, %s host check(s) |\n' \
        "$(result_cell "${CI_S2_RESULT:-}")" \
        "$(human_bytes "${CI_S2_IMAGE_BYTES:-0}")" "$(human_bytes "${CI_S2_IMAGE_GZ_BYTES:-0}")" \
        "${CI_S2_ROOTFS_FILES:-n/a}" "${CI_S2_HOST_CHECKS:-n/a}"
    printf '| s3 | %s | slot %s, layer %s, two boots |\n' \
        "$(result_cell "${CI_S3_RESULT:-}")" "${CI_S3_SLOT:-n/a}" "${CI_S3_UPPER:-n/a}"
    printf '| s4 | %s | three boots, committed %s at the end |\n' \
        "$(result_cell "${CI_S4_RESULT:-}")" "${CI_S4_COMMITTED_FINAL:-n/a}"
    printf '| s5 | %s | %s conflict(s), %s layer(s) reclaimed, degraded boot checked |\n' \
        "$(result_cell "${CI_S5_RESULT:-}")" "${CI_S5_CONFLICTS:-n/a}" "${CI_S5_RECLAIMED:-n/a}"
    printf '\n'
    printf 'Payload manifest sha256: `%s`\n' "${CI_PAYLOAD_MANIFEST_SHA256:-not produced}"
    if [ -n "${CI_S1_LINE:-}" ]; then
        printf '\nS1 judge line: `%s`\n' "${CI_S1_LINE}"
    fi
    if [ -n "${CI_S1_UEFI_LINE:-}" ]; then
        printf 'OVMF judge line: `%s`\n' "${CI_S1_UEFI_LINE}"
    fi
    if [ -n "${CI_S2_LINE:-}" ]; then
        printf '\nS2 judge line: `%s`\n' "${CI_S2_LINE}"
    fi
    if [ -n "${CI_S3_LINE:-}" ]; then
        printf '\nS3 judge line (boot 1): `%s`\n' "${CI_S3_LINE}"
    fi
    if [ -n "${CI_S3_LINE_BOOT2:-}" ]; then
        printf 'S3 judge line (boot 2): `%s`\n' "${CI_S3_LINE_BOOT2}"
    fi
    if [ -n "${CI_S4_LINE_COMMIT_A:-}" ]; then
        printf '\nS4 judge line (boot 1): `%s`\n' "${CI_S4_LINE_COMMIT_A}"
    fi
    if [ -n "${CI_S4_LINE_ABANDON_B:-}" ]; then
        printf 'S4 judge line (boot 2): `%s`\n' "${CI_S4_LINE_ABANDON_B}"
    fi
    if [ -n "${CI_S4_LINE_COMMIT_B:-}" ]; then
        printf 'S4 judge line (boot 3): `%s`\n' "${CI_S4_LINE_COMMIT_B}"
    fi
    if [ -n "${CI_S5_UPGRADE_LINE:-}" ]; then
        printf '\nS5 evidence (upgrade boot): `%s`\n' "${CI_S5_UPGRADE_LINE}"
    fi
    if [ -n "${CI_S5_LINE:-}" ]; then
        printf 'S5 judge line (commit boot): `%s`\n' "${CI_S5_LINE}"
    fi
    if [ -n "${CI_S5_DEGRADED_LINE:-}" ]; then
        printf 'S5 evidence (degraded boot): `%s`\n' "${CI_S5_DEGRADED_LINE}"
    fi
    printf '\n'
    printf 'Artifacts: `upstream-files` (fetch), `payload` (assemble), '
    printf '`s1-probe` (serial logs, initramfs, module inventory), '
    printf '`disk-image` and `s1..s5-probe` (image, serial logs, payload, dumps), '
    printf '`diag-<stage>` (logs and inventories from every stage).\n'
} >"${CI_TMP_ROOT}/report.md"

cat "${CI_TMP_ROOT}/report.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "${CI_TMP_ROOT}/report.md" >>"${GITHUB_STEP_SUMMARY}"
fi

ci_emit_output "overall" "${overall}"

if [ "${overall}" != "success" ]; then
    ci_die "pipeline failed: ${verdict}"
fi
ci_log "stage report finished"
