#!/usr/bin/env bash
# Collect environment facts and file inventories for failure triage.
#
# Called from every stage with `if: always()`, so it must not depend on the stage
# having succeeded and must not fail the job by itself (the calling step is also
# marked continue-on-error).
#
# Usage: bash scripts/ci/diagnostics.sh <stage-name> [directory ...]

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init diagnostics

target_stage="${1:-unknown}"
if [ "$#" -gt 0 ]; then
    shift
fi

diag_dir="${CI_DIAG_DIR:-${CI_TMP_ROOT}/diagnostics}"
mkdir -p "${diag_dir}"

section() {
    printf '\n== %s ==\n' "$1"
}

collect_context() {
    section "context"
    printf 'stage: %s\n' "${target_stage}"
    printf 'time (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo root: %s\n' "${CI_REPO_ROOT}"
    printf 'tmp root: %s\n' "${CI_TMP_ROOT}"
    printf 'log dir: %s\n' "${CI_LOG_DIR}"
    printf 'workflow: %s\n' "${GITHUB_WORKFLOW:-unknown}"
    printf 'job: %s\n' "${GITHUB_JOB:-unknown}"
    printf 'run id: %s\n' "${GITHUB_RUN_ID:-unknown}"
    printf 'event: %s\n' "${GITHUB_EVENT_NAME:-unknown}"
    printf 'ref: %s\n' "${GITHUB_REF:-unknown}"
    printf 'sha: %s\n' "${GITHUB_SHA:-unknown}"

    section "tool versions"
    uname -a || true
    local tool
    for tool in bash curl tar gzip python3 git jq shellcheck zstd; do
        if ci_have "${tool}"; then
            printf '%s: %s\n' "${tool}" "$("${tool}" --version 2>&1 | head -n 1)"
        else
            printf '%s: not installed\n' "${tool}"
        fi
    done
}

collect_disk_usage() {
    section "disk usage"
    df -h "${CI_TMP_ROOT}" 2>/dev/null || true
    if [ -d "${CI_TMP_ROOT}" ]; then
        du -sk "${CI_TMP_ROOT}"/* 2>/dev/null || true
    fi
}

collect_tree() {
    local dir="$1"
    section "tree ${dir}"
    if [ ! -d "${dir}" ]; then
        printf 'missing\n'
        return 0
    fi
    du -sh "${dir}" 2>/dev/null || true
    local path
    while IFS= read -r path; do
        printf '%12s  %s  %s\n' \
            "$(ci_file_size "${path}")" \
            "$(ci_sha256 "${path}" | cut -c1-16)" \
            "${path#"${CI_TMP_ROOT}"/}"
    done < <(find "${dir}" -type f | LC_ALL=C sort | head -n 200)
}

collect_logs() {
    section "logs"
    if [ -d "${CI_LOG_DIR}" ]; then
        local log
        for log in "${CI_LOG_DIR}"/*; do
            [ -f "${log}" ] || continue
            printf 'copied %s\n' "${log##*/}"
            cp -f "${log}" "${diag_dir}/" || true
        done
    fi
}

{
    collect_context
    collect_disk_usage
    for dir in "$@"; do
        collect_tree "${dir}"
    done
    collect_logs
} >"${diag_dir}/summary.txt" 2>&1 || ci_warn "diagnostics collection was incomplete"

ci_log "diagnostics written to ${diag_dir}/summary.txt"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "${diag_dir}/summary.txt" ]; then
    printf 'Diagnostics: `%s` (uploaded as an artifact)\n' "${diag_dir}/summary.txt" \
        >>"${GITHUB_STEP_SUMMARY}"
fi
