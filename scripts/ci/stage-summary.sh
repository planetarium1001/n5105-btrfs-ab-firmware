#!/usr/bin/env bash
# Render the fixed per-stage summary block that GitHub shows on the run page.
#
# This is a renderer, not a gate: it never changes a verdict and never fails the job.
# Every stage workflow calls it as its last step, so a reader of the run page sees the
# same five columns for S1..S5 - stage, verdict, key line, artifact and sha256, and the
# next command to run - without opening a single log.
#
# Usage:
#   bash scripts/ci/stage-summary.sh --stage s2 --result success \
#     --judge-line 'S2-RESULT=ok parts=4 images=538968064' \
#     --artifact image-probe --artifact-file "$RUNNER_TEMP/ci/disk/n5105-ab-image.img.gz" \
#     [--judge-log <file>] [--next-ok <cmd>] [--next-fail <cmd>] [--note <text>]
#
# --stage only accepts s1..s5: the display name, the judge prefix and the local
# reproduction command come from the table below, so a caller cannot invent a sixth
# spelling or drift away from the vocabulary the judge lines already use.
#
# Exit code: always 0. A missing input renders as `n/a`; a broken input renders a
# warning and still prints the row, because a run page that loses its summary must not
# also lose the run.

set -uo pipefail

stage=""
result=""
judge_line=""
judge_log=""
artifact=""
next_ok=""
next_fail=""
note=""
artifact_files=()

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stage) stage="${2:-}"; shift 2 ;;
        --result) result="${2:-}"; shift 2 ;;
        --judge-line) judge_line="${2:-}"; shift 2 ;;
        --judge-log) judge_log="${2:-}"; shift 2 ;;
        --artifact) artifact="${2:-}"; shift 2 ;;
        --artifact-file) artifact_files+=("${2:-}"); shift 2 ;;
        --next-ok) next_ok="${2:-}"; shift 2 ;;
        --next-fail) next_fail="${2:-}"; shift 2 ;;
        --note) note="${2:-}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) printf '[summary] WARNING: ignoring unknown argument %s\n' "$1" >&2; shift ;;
    esac
done

# stage_job <stage>: the display name, shared with the workflow and job names.
stage_job() {
    case "${1:-}" in
        s1) printf 'S1 probe' ;;
        s2) printf 'S2 image' ;;
        s3) printf 'S3 boot' ;;
        s4) printf 'S4 slots' ;;
        s5) printf 'S5 upgrade' ;;
        *) printf '' ;;
    esac
}

# stage_prefix <stage>: the frozen judge token prefix printed by the stage.
stage_prefix() {
    case "${1:-}" in
        s1 | s2 | s3 | s4 | s5) printf 'S%s-RESULT' "${1#s}" ;;
        *) printf '' ;;
    esac
}

# stage_repro <stage>: the local command that reproduces the stage.
stage_repro() {
    case "${1:-}" in
        s1) printf 'bash scripts/ci/qemu-smoke.sh' ;;
        s2) printf 'bash scripts/ci/disk.sh' ;;
        s3 | s4) printf 'bash scripts/ci/qemu-smoke.sh' ;;
        s5) printf 'bash scripts/ci/s5-phase.sh' ;;
        *) printf '' ;;
    esac
}

# verdict_word <job status>: the word shown in the table.
verdict_word() {
    case "${1:-}" in
        success) printf 'PASS' ;;
        failure) printf 'FAIL' ;;
        cancelled) printf 'CANCELLED' ;;
        skipped) printf 'SKIPPED' ;;
        "") printf 'n/a' ;;
        *) printf '%s' "$1" | tr '[:lower:]' '[:upper:]' ;;
    esac
}

sha256_prefix() {
    local file="$1" digest=""
    [ -f "${file}" ] || { printf 'n/a'; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        digest="$(shasum -a 256 "${file}" 2>/dev/null | cut -d' ' -f1)"
    fi
    if [ -n "${digest}" ]; then printf '%s' "${digest}" | cut -c1-12; else printf 'n/a'; fi
}

run_url() {
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        printf '%s/%s/actions/runs/%s' \
            "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-unknown}" "${GITHUB_RUN_ID}"
    fi
}

# judge_from_log <prefix> <log>: the first failing judge line, else the first one.
judge_from_log() {
    local prefix="$1" log="$2" line=""
    [ -n "${prefix}" ] || return 0
    [ -n "${log}" ] && [ -f "${log}" ] || return 0
    line="$(grep -m1 "^${prefix}=fail" "${log}" 2>/dev/null)" || line=""
    if [ -z "${line}" ]; then
        line="$(grep -m1 "^${prefix}=" "${log}" 2>/dev/null)" || line=""
    fi
    printf '%s' "${line}"
}

job="$(stage_job "${stage}")"
prefix="$(stage_prefix "${stage}")"
repro="$(stage_repro "${stage}")"
verdict="$(verdict_word "${result}")"

if [ -z "${job}" ]; then
    printf '[summary] WARNING: unknown stage %q, rendering a placeholder row\n' "${stage}" >&2
    job="${stage:-unknown}"
fi

key_line="${judge_line}"
if [ -z "${key_line}" ]; then
    key_line="$(judge_from_log "${prefix}" "${judge_log}")"
fi
[ -n "${key_line}" ] || key_line="n/a"

if [ -n "${artifact}" ]; then
    artifact_cell="\`${artifact}\`"
    for file in ${artifact_files[@]+"${artifact_files[@]}"}; do
        artifact_cell="${artifact_cell} / \`$(basename "${file}")\` / \`$(sha256_prefix "${file}")\`"
    done
else
    artifact_cell="n/a"
    for file in ${artifact_files[@]+"${artifact_files[@]}"}; do
        artifact_cell="${artifact_cell} / \`$(basename "${file}")\` / \`$(sha256_prefix "${file}")\`"
    done
fi

url="$(run_url)"
if [ "${verdict}" = "PASS" ]; then
    if [ -n "${next_ok}" ]; then
        next_cell="${next_ok}"
    elif [ -n "${artifact}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
        next_cell="gh run download ${GITHUB_RUN_ID} -n ${artifact}"
    elif [ -n "${url}" ]; then
        next_cell="gh run view ${GITHUB_RUN_ID}"
    else
        next_cell="n/a"
    fi
else
    parts=""
    if [ -n "${next_fail}" ]; then
        parts="${next_fail}"
    elif [ -n "${GITHUB_RUN_ID:-}" ]; then
        parts="gh run view ${GITHUB_RUN_ID} --log-failed"
    fi
    if [ -n "${repro}" ]; then
        if [ -n "${parts}" ]; then parts="${parts} + ${repro}"; else parts="${repro}"; fi
    fi
    next_cell="${parts:-n/a}"
fi

block="$(
    printf '## %s - %s\n' "${job}" "${verdict}"
    printf '| stage | verdict | key line | artifact and sha256 | next command |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| %s | %s | `%s` | %s | `%s` |\n' "${job}" "${verdict}" "${key_line}" "${artifact_cell}" "${next_cell}"
    if [ -n "${note}" ]; then
        printf '\n%s\n' "${note}"
    fi
)"

printf '%s\n' "${block}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "${block}" >>"${GITHUB_STEP_SUMMARY}" ||
        printf '[summary] WARNING: could not append to %s\n' "${GITHUB_STEP_SUMMARY}" >&2
fi

exit 0
