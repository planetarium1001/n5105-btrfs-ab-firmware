#!/usr/bin/env bash
# Stage "report": summarise the pipeline for humans and fail the run if a stage
# that was actually scheduled did not succeed.
#
# The verdict logic in this script is frozen: `overall` is derived from the job
# results, published as the `overall` output and turned into the process exit code.
# Everything else here is rendering: the run page gets one table with four columns -
# stage, verdict, duration, artifact - plus a collapsed list of the judge lines, so a
# reader does not have to open a log to see what passed and what to download.
#
# Inputs (environment), all optional so a partially scheduled pipeline still reports:
#   CI_REQUESTED_STAGE       requested stage (all|fetch|assemble|verify|s1..s5)
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
#   CI_S4_LINE_ROLLBACK, CI_S4_COMMITTED_FINAL, CI_S4_NEXT_SLOT_FINAL
#   CI_S5_RESULT, CI_S5_LINE, CI_S5_UPGRADE_LINE, CI_S5_DEGRADED_LINE,
#   CI_S5_CONFLICTS, CI_S5_RECLAIMED
#   CI_JOBS_JSON             optional: `gh api .../actions/runs/<id>/jobs` output used
#                            for the duration column; missing it prints `n/a`
#   GITHUB_RUN_ID            optional: links the "next command" to this run

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
        success) printf 'PASS' ;;
        failure) printf 'FAIL' ;;
        skipped) printf 'SKIPPED' ;;
        cancelled) printf 'CANCELLED' ;;
        timed_out) printf 'TIMEOUT' ;;
        "") printf 'n/a' ;;
        *) printf '%s' "${result}" | tr '[:lower:]' '[:upper:]' ;;
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

# --------------------------------------------------------------------------- #
# Durations
#
# The Actions API is the only place that knows when a job started and finished, and
# the report job already has `actions: read`. The JSON file is optional: a local run
# prints `n/a` instead of pretending to measure anything.
# --------------------------------------------------------------------------- #

d_resolve="n/a"
d_fetch="n/a"
d_assemble="n/a"
d_s1="n/a"
d_s2="n/a"
d_s3="n/a"
d_s4="n/a"
d_s5="n/a"
d_verify="n/a"
d_report="n/a"

if [ -n "${CI_JOBS_JSON:-}" ] && [ -f "${CI_JOBS_JSON}" ]; then
    if command -v python3 >/dev/null 2>&1; then
        while IFS="$(printf '\t')" read -r key value; do
            [ -n "${key}" ] || continue
            [ -n "${value}" ] || continue
            case "${key}" in
                resolve) d_resolve="${value}" ;;
                fetch) d_fetch="${value}" ;;
                assemble) d_assemble="${value}" ;;
                s1) d_s1="${value}" ;;
                s2) d_s2="${value}" ;;
                s3) d_s3="${value}" ;;
                s4) d_s4="${value}" ;;
                s5) d_s5="${value}" ;;
                verify) d_verify="${value}" ;;
                report) d_report="${value}" ;;
            esac
        done <<EOF
$(python3 - "${CI_JOBS_JSON}" <<'PYTHON' 2>/dev/null || true
import json
import sys
from datetime import datetime

PATH = sys.argv[1]
try:
    with open(PATH, encoding="utf-8") as handle:
        jobs = json.load(handle).get("jobs", [])
except Exception:
    sys.exit(0)

ORDER = [
    ("s1", "S1 "),
    ("s2", "S2 "),
    ("s3", "S3 "),
    ("s4", "S4 "),
    ("s5", "S5 "),
    ("resolve", "resolve upstream"),
    ("fetch", "fetch upstream"),
    ("assemble", "assemble payload"),
    ("verify", "static checks"),
    ("report", "report"),
]


def duration(job):
    started, finished = job.get("started_at"), job.get("completed_at")
    if not started or not finished:
        return ""
    try:
        begin = datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ")
        end = datetime.strptime(finished, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return ""
    seconds = int((end - begin).total_seconds())
    if seconds < 0:
        return ""
    if seconds < 60:
        return f"{seconds}s"
    minutes, rest = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{rest:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


for key, prefix in ORDER:
    for job in jobs:
        if str(job.get("name", "")).startswith(prefix):
            span = duration(job)
            if span:
                print(f"{key}\t{span}")
            break
PYTHON
)
EOF
    else
        ci_warn "python3 is missing, the duration column stays n/a"
    fi
fi

# --------------------------------------------------------------------------- #
# Row rendering
# --------------------------------------------------------------------------- #

# report_row <stage label> <result> <duration> <artifact>
report_row() {
    printf '| %s | %s | %s | %s |\n' \
        "$1" "$(result_cell "$2")" "$3" "$4"
}

if [ "${overall}" = "success" ]; then
    headline="all scheduled stages passed"
else
    headline="failed"
    for probe in \
        "S1 probe:${CI_S1_RESULT:-}" \
        "S2 image:${CI_S2_RESULT:-}" \
        "S3 boot:${CI_S3_RESULT:-}" \
        "S4 slots:${CI_S4_RESULT:-}" \
        "S5 upgrade:${CI_S5_RESULT:-}" \
        "resolve upstream:${CI_RESOLVE_RESULT:-}" \
        "fetch upstream:${CI_FETCH_RESULT:-}" \
        "assemble payload:${CI_ASSEMBLE_RESULT:-}" \
        "static checks:${CI_VERIFY_RESULT:-}"; do
        name="${probe%%:*}"
        status="${probe#*:}"
        case "${status}" in
            failure | cancelled | timed_out)
                headline="failed at ${name}"
                break
                ;;
        esac
    done
fi

next_command="gh run view ${GITHUB_RUN_ID:-<run>} --log-failed"
if [ "${overall}" = "success" ]; then
    next_command="gh run download ${GITHUB_RUN_ID:-<run>} -n image-install"
fi

{
    printf '## CI summary\n'
    printf '\n'
    printf '**Verdict: %s** - next: `%s`\n' "${headline}" "${next_command}"
    printf '\n'
    printf '| stage | verdict | duration | artifact |\n'
    printf '| --- | --- | --- | --- |\n'
    report_row "resolve upstream" "${CI_RESOLVE_RESULT:-}" "${d_resolve}" "\`upstream-files\` / \`logs-resolve\`"
    report_row "fetch upstream" "${CI_FETCH_RESULT:-}" "${d_fetch}" "\`upstream-files\` / \`logs-fetch\`"
    report_row "assemble payload" "${CI_ASSEMBLE_RESULT:-}" "${d_assemble}" "\`payload-upgrade\` / \`logs-assemble\`"
    report_row "S1 probe" "${CI_S1_RESULT:-}" "${d_s1}" "\`evidence-s1\` / \`logs-s1\`"
    report_row "S2 image" "${CI_S2_RESULT:-}" "${d_s2}" "\`image-probe\` / \`evidence-s2\` / \`logs-s2\`"
    report_row "S3 boot" "${CI_S3_RESULT:-}" "${d_s3}" "\`image-install\` / \`evidence-s3\` / \`logs-s3\`"
    report_row "S4 slots" "${CI_S4_RESULT:-}" "${d_s4}" "\`evidence-s4\` / \`logs-s4\`"
    report_row "S5 upgrade" "${CI_S5_RESULT:-}" "${d_s5}" "\`payload-upgrade\` / \`evidence-s5\` / \`logs-s5\`"
    report_row "static checks" "${CI_VERIFY_RESULT:-}" "${d_verify}" "\`logs-verify\`"
    printf '\n'
    printf '| field | value |\n'
    printf '| --- | --- |\n'
    printf '| requested stage | `%s` |\n' "${stage}"
    printf '| trigger | `%s` |\n' "${CI_TRIGGER:-unknown}"
    printf '| ref | `%s` |\n' "${CI_REF:-unknown}"
    printf '| commit | `%s` |\n' "${CI_SHA:-unknown}"
    printf '| upstream version | `%s` (%s) |\n' "${CI_UPSTREAM_VERSION:-unresolved}" "${CI_VERSION_SOURCE:-n/a}"
    printf '| kernel package | `%s` |\n' "${CI_KERNEL_PACKAGE:-unknown}"
    printf '| kernel module dir | `%s` |\n' "${CI_KMODS_DIR:-unknown}"
    printf '| cache key | `%s` (hit: %s) |\n' "${CI_CACHE_KEY:-n/a}" "${CI_CACHE_HIT:-n/a}"
    printf '| fetched | %s |\n' "$(human_bytes "${CI_FETCH_TOTAL_BYTES:-0}")"
    printf '| payload | members: %s, %s |\n' "${CI_PAYLOAD_MEMBERS:-none}" \
        "$(human_bytes "${CI_PAYLOAD_TOTAL_BYTES:-0}")"
    printf '| payload manifest sha256 | `%s` |\n' "${CI_PAYLOAD_MANIFEST_SHA256:-not produced}"
    printf '| design checks | %s (%s problem(s)) |\n' \
        "${CI_DESIGN_CHECKS_STATUS:-n/a}" "${CI_DESIGN_PROBLEMS:-0}"
    printf '| shellcheck | %s |\n' "${CI_SHELLCHECK_STATUS:-n/a}"
    printf '| report duration | %s |\n' "${d_report}"
    printf '\n'
    printf '<details><summary>Judge lines</summary>\n'
    printf '\n'
    printf '```\n'
    printf 'S1-RESULT: %s\n' "${CI_S1_LINE:-n/a}"
    printf 'S1 OVMF:   %s\n' "${CI_S1_UEFI_LINE:-n/a}"
    printf 'S1 modules/boot: %s module(s), %ss boot, apk cross-check %s\n' \
        "${CI_S1_MODULES:-n/a}" "${CI_S1_BOOT_SECONDS:-n/a}" "${CI_S1_APK_CROSSCHECK:-n/a}"
    printf 'S2-RESULT: %s\n' "${CI_S2_LINE:-n/a}"
    printf 'S2 image:  %s raw / %s gz, %s file(s) in @sys, %s host check(s)\n' \
        "$(human_bytes "${CI_S2_IMAGE_BYTES:-0}")" "$(human_bytes "${CI_S2_IMAGE_GZ_BYTES:-0}")" \
        "${CI_S2_ROOTFS_FILES:-n/a}" "${CI_S2_HOST_CHECKS:-n/a}"
    printf 'S3-RESULT: %s (boot 1), %s (boot 2), slot %s, layer %s\n' \
        "${CI_S3_LINE:-n/a}" "${CI_S3_LINE_BOOT2:-n/a}" "${CI_S3_SLOT:-n/a}" "${CI_S3_UPPER:-n/a}"
    printf 'S4-RESULT: %s (commit a), %s (abandon b), %s (commit b), %s (rollback)\n' \
        "${CI_S4_LINE_COMMIT_A:-n/a}" "${CI_S4_LINE_ABANDON_B:-n/a}" \
        "${CI_S4_LINE_COMMIT_B:-n/a}" "${CI_S4_LINE_ROLLBACK:-n/a}"
    printf 'S4 final:  committed %s, next boot %s\n' \
        "${CI_S4_COMMITTED_FINAL:-n/a}" "${CI_S4_NEXT_SLOT_FINAL:-n/a}"
    printf 'S5-RESULT: %s (commit boot)\n' "${CI_S5_LINE:-n/a}"
    printf 'S5 boot evidence: %s (upgrade), %s (degraded)\n' \
        "${CI_S5_UPGRADE_LINE:-n/a}" "${CI_S5_DEGRADED_LINE:-n/a}"
    printf 'S5 upgrade: %s conflict(s), %s layer(s) reclaimed\n' \
        "${CI_S5_CONFLICTS:-n/a}" "${CI_S5_RECLAIMED:-n/a}"
    printf '```\n'
    printf '\n'
    printf '</details>\n'
    printf '\n'
    printf 'Artifacts: `upstream-files` (upstream inputs), `payload-upgrade` (update payload), '
    printf '`image-probe` (S2 probe image, never write it to a disk), `image-install` (S3, the image '
    printf 'the release publishes), `evidence-s1..s5` (serial logs and structured evidence), '
    printf '`logs-<stage>` (diagnostics summary).\n'
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
