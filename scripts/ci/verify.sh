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
    done < <(find "${CI_REPO_ROOT}/initramfs" -type f ! -name '*.md' | LC_ALL=C sort)
fi
# Test scripts under tests/modules/{image,ab,upgrade,runtime,release} run in either dialect, so the shebang
# decides; only those modules are linted here, the rest of tests/ is owned elsewhere.
bash_test_scripts=()
# The platform layer ships shell that runs on the target, so it is linted as POSIX sh
# together with the initramfs: it must run under busybox.
if [ -d "${CI_REPO_ROOT}/platform" ]; then
    while IFS= read -r path; do
        init_scripts+=("${path}")
    done < <(find "${CI_REPO_ROOT}/platform" -type f ! -name '*.md' ! -name 'platform-release' | LC_ALL=C sort)
fi
# The device driver scripts in scripts/device run on a workstation, but they are written
# in the same POSIX shell as the target, and they are the ones that decide whether the
# machine on the bench keeps a bootable slot. Linting them as sh keeps a quoting bug from
# reaching the run that flashes a board.
if [ -d "${CI_REPO_ROOT}/scripts/device" ]; then
    while IFS= read -r path; do
        init_scripts+=("${path}")
    done < <(find "${CI_REPO_ROOT}/scripts/device" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi
for module in image ab upgrade runtime release; do
    [ -d "${CI_REPO_ROOT}/tests/modules/${module}" ] || continue
    while IFS= read -r path; do
        case "$(head -n 1 "${path}")" in
            *bash*) bash_test_scripts+=("${path}") ;;
            *) init_scripts+=("${path}") ;;
        esac
    done < <(find "${CI_REPO_ROOT}/tests/modules/${module}" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
done
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
# 2b. Python syntax: the extractors run inside the pipeline, so a typo must not
#     wait for the stage that needs them.
# --------------------------------------------------------------------------- #

python_status="ok"
python_files=()
while IFS= read -r path; do
    python_files+=("${path}")
done < <(find "${CI_REPO_ROOT}/scripts/ci" -maxdepth 1 -name '*.py' | LC_ALL=C sort)
if [ "${#python_files[@]}" -gt 0 ]; then
    # The log goes next to the other stage logs: CI_LOG_DIR is the directory ci_stage_init
    # guarantees, CI_TMP_ROOT is only its parent when nobody overrode them separately.
    if "${python_bin}" -m py_compile "${python_files[@]}" 2>"${CI_LOG_DIR}/py_compile.log"; then
        ci_log "python syntax: ok (${#python_files[@]} file(s))"
    else
        ci_warn "python syntax check failed:"
        sed 's/^/  /' "${CI_LOG_DIR}/py_compile.log" >&2
        python_status="fail"
    fi
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
# 4. The test suite
#
# Every behavioural claim in this repository - the naming contracts, the growth state
# machine, the slot selection, the health check, the payload validation - is asserted by
# tests/modules/**. This stage is the only place they run in CI, and they did not run
# here at all until now: three of them failed on an ubuntu-latest runner while passing on
# a developer laptop, because they inherit the step's GITHUB_OUTPUT/GITHUB_ENV channels,
# and nothing noticed. tests/run.sh clears those channels now and writes only to
# tests/.out, which is not tracked.
# --------------------------------------------------------------------------- #

tests_status="ok"
set +e
test_output="$(cd "${CI_REPO_ROOT}" && ./tests/run.sh 2>&1)"
test_rc=$?
set -e
printf '%s\n' "${test_output}" | tail -n 30
if [ "${test_rc}" -ne 0 ]; then
    tests_status="fail"
    printf '%s\n' "${test_output}" >"${CI_LOG_DIR}/verify-tests.log"
    ci_warn "test suite failed; the full output is logs/verify-tests.log"
    printf '%s\n' "${test_output}" | grep -E '^(FAIL|not ok)' | head -n 20 >&2 || true
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

verify_status="ok"
if [ "${syntax_status}" = "fail" ] || [ "${shellcheck_status}" = "fail" ] \
    || [ "${python_status}" = "fail" ] || [ "${design_status}" = "fail" ] \
    || [ "${tests_status}" = "fail" ]; then
    verify_status="fail"
fi

summary="${CI_LOG_DIR}/verify-summary.txt"
{
    printf 'verify: %s\n' "${verify_status}"
    printf '  bash -n:    %s\n' "${syntax_status}"
    printf '  shellcheck: %s\n' "${shellcheck_status}"
    printf '  python:     %s\n' "${python_status}"
    printf '  design:     %s (%s problem(s))\n' "${design_status}" "${design_problem_count}"
    printf '  tests:      %s\n' "${tests_status}"
    if [ -n "${design_failed_checks}" ]; then
        printf '  failing design checks: %s\n' "${design_failed_checks}"
    fi
} | tee "${summary}"

ci_emit_output "verify_status" "${verify_status}"
ci_emit_output "syntax_status" "${syntax_status}"
ci_emit_output "shellcheck_status" "${shellcheck_status}"
ci_emit_output "python_status" "${python_status}"
ci_emit_output "design_checks_status" "${design_status}"
ci_emit_output "design_checks_problems" "${design_problem_count}"
ci_emit_output "design_checks_failed" "${design_failed_checks}"
ci_emit_output "tests_status" "${tests_status}"

if [ "${verify_status}" = "fail" ]; then
    ci_die "stage verify failed"
fi
ci_log "stage verify finished"
