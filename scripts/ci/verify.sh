#!/usr/bin/env bash
# Stage "verify": static checks that do not need any upstream artifact.
#
# Checks, in order:
#   1. `bash -n` on every scripts/ci/*.sh, `sh -n` on the initramfs and guest
#      assertion scripts (they run in the guest's busybox shell)
#   2. `shellcheck` on the same files, when the runner provides it
#   3. `python3 scripts/check_design.py all`, the executable form of the thresholds
#      and contracts written down in docs/
#
# The script keeps going after a failing check so one run reports every finding, and
# only then fails the stage.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init verify

ci_require_cmd bash

python_bin="${CI_PYTHON:-python3}"
ci_require_cmd "${python_bin}"

syntax_status="ok"
shellcheck_status="skipped"
design_status="ok"
design_problem_count="0"
design_failed_checks=""

script_files=()
while IFS= read -r path; do
    script_files+=("${path}")
done < <(find "${CI_REPO_ROOT}/scripts/ci" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
if [ "${#script_files[@]}" -eq 0 ]; then
    ci_die "no shell scripts found under ${CI_REPO_ROOT}/scripts/ci"
fi

# The initramfs and the in-guest assertions run a POSIX shell (busybox ash), so they
# are linted with sh rather than bash.
init_scripts=()
if [ -d "${CI_REPO_ROOT}/initramfs" ]; then
    while IFS= read -r path; do
        init_scripts+=("${path}")
    done < <(find "${CI_REPO_ROOT}/initramfs" -maxdepth 1 -type f ! -name '*.md' | LC_ALL=C sort)
fi
# Test scripts under tests/modules/image run in either dialect, so the shebang
# decides; only that module is linted here, the rest of tests/ is owned elsewhere.
bash_test_scripts=()
if [ -d "${CI_REPO_ROOT}/tests/modules/image" ]; then
    while IFS= read -r path; do
        case "$(head -n 1 "${path}")" in
            *bash*) bash_test_scripts+=("${path}") ;;
            *) init_scripts+=("${path}") ;;
        esac
    done < <(find "${CI_REPO_ROOT}/tests/modules/image" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi
ci_log "checking ${#script_files[@]} stage script(s) and ${#init_scripts[@]} initramfs script(s)"

# --------------------------------------------------------------------------- #
# 1. Syntax
# --------------------------------------------------------------------------- #

for path in "${script_files[@]}"; do
    if bash -n "${path}"; then
        ci_log "syntax ok: ${path#"${CI_REPO_ROOT}"/}"
    else
        ci_warn "syntax error: ${path}"
        syntax_status="fail"
    fi
done
for path in ${bash_test_scripts[@]+"${bash_test_scripts[@]}"}; do
    if bash -n "${path}"; then
        ci_log "syntax ok: ${path#"${CI_REPO_ROOT}"/}"
    else
        ci_warn "syntax error: ${path}"
        syntax_status="fail"
    fi
done
for path in ${init_scripts[@]+"${init_scripts[@]}"}; do
    if sh -n "${path}"; then
        ci_log "syntax ok (sh): ${path#"${CI_REPO_ROOT}"/}"
    else
        ci_warn "syntax error: ${path}"
        syntax_status="fail"
    fi
done

# --------------------------------------------------------------------------- #
# 2. ShellCheck
# --------------------------------------------------------------------------- #

if ci_have shellcheck; then
    shellcheck_version="$(shellcheck --version | awk '/^version:/ { print $2 }')"
    ci_log "shellcheck ${shellcheck_version} (severity warning and above)"
    if shellcheck -x --severity=warning "${script_files[@]}"; then
        shellcheck_status="ok"
    else
        shellcheck_status="fail"
    fi
    if [ "${#init_scripts[@]}" -gt 0 ] && ! shellcheck -s sh --severity=warning "${init_scripts[@]}"; then
        shellcheck_status="fail"
    fi
    if [ "${#bash_test_scripts[@]}" -gt 0 ] \
        && ! shellcheck -x --severity=warning "${bash_test_scripts[@]}"; then
        shellcheck_status="fail"
    fi
else
    ci_warn "shellcheck is not installed, static lint skipped"
fi

# --------------------------------------------------------------------------- #
# 3. Design checks
# --------------------------------------------------------------------------- #

ci_log "design checks: ${python_bin} scripts/check_design.py all"
set +e
design_output="$(cd "${CI_REPO_ROOT}" && "${python_bin}" scripts/check_design.py all 2>&1)"
design_rc=$?
set -e
printf '%s\n' "${design_output}"
if [ "${design_rc}" -ne 0 ]; then
    design_status="fail"
    design_failed_checks="$(printf '%s\n' "${design_output}" | sed -n 's/^\[fail\] //p' | tr '\n' ',' | sed 's/,$//')"
    design_problem_count="$(printf '%s\n' "${design_output}" | sed -n 's/^\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    [ -n "${design_problem_count}" ] || design_problem_count="0"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

verify_status="ok"
if [ "${syntax_status}" = "fail" ] || [ "${shellcheck_status}" = "fail" ] || [ "${design_status}" = "fail" ]; then
    verify_status="fail"
fi

summary="${CI_LOG_DIR}/verify-summary.txt"
{
    printf 'verify: %s\n' "${verify_status}"
    printf '  bash -n:    %s\n' "${syntax_status}"
    printf '  shellcheck: %s\n' "${shellcheck_status}"
    printf '  design:     %s (%s problem(s))\n' "${design_status}" "${design_problem_count}"
    if [ -n "${design_failed_checks}" ]; then
        printf '  failing design checks: %s\n' "${design_failed_checks}"
    fi
} | tee "${summary}"

ci_emit_output "verify_status" "${verify_status}"
ci_emit_output "syntax_status" "${syntax_status}"
ci_emit_output "shellcheck_status" "${shellcheck_status}"
ci_emit_output "design_checks_status" "${design_status}"
ci_emit_output "design_checks_problems" "${design_problem_count}"
ci_emit_output "design_checks_failed" "${design_failed_checks}"

if [ "${verify_status}" = "fail" ]; then
    ci_die "stage verify failed"
fi
ci_log "stage verify finished"
