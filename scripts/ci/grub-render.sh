#!/usr/bin/env bash
# Stage "grub": render the ESP bootloader configuration and assert its shape.
#
# GRUB configuration is generated, never hand-edited, so this script renders the
# template and then refuses to produce an image unless all five documented rules hold:
#
#   1. it sets `set default=` to a concrete entry, never to a template token
#   2. every save_env call passes a variable name only, never name=value
#   3. no line ever writes `ab_try=` through save_env
#   4. GRUB script is not bash: no `&&`, `||` or `${x:-y}` expansions
#   5. every @TOKEN@ placeholder has been replaced
#
# `--check FILE` runs the assertions alone, which is what tests/modules/ab uses to
# prove each rule actually rejects a broken file.
#
# Inputs (environment):
#   CI_GRUB_TEMPLATE  template path (default: scripts/ci/grub.cfg.in)
#   CI_GRUB_OUTPUT    rendered path (default: $CI_TMP_ROOT/grub/grub.cfg)
#   CI_COMMITTED_SLOT committed slot, a or b (default: a)
#   CI_GRUBENV_PATH   grubenv path as GRUB sees it (default: /boot/grub/grubenv)
#   CI_GRUB_TIMEOUT   menu timeout in seconds (default: 3)
#
# Outputs: grub_cfg, grub_cfg_sha256, committed_slot, committed_index

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init grub

# check_grub <file>: the five rendering rules, in the documented order.
#
# Rules 1-4 are about code, so comment lines are dropped first: the header of the
# template explains what is forbidden and would otherwise trip its own check.
check_grub() {
    local file="$1"
    local problems=0
    local line
    local code
    code="$(mktemp)"
    # shellcheck disable=SC2064  # expand now, the trap fires after the function returns
    trap "rm -f '${code}'" RETURN

    sed '/^[[:space:]]*#/d' "${file}" >"${code}"

    # 1. a concrete default entry
    if ! grep -Eq '^set default=[^@[:space:]]+$' "${code}"; then
        ci_warn "rule 1: no concrete 'set default=<entry>' line in ${file}"
        problems=$((problems + 1))
    fi

    # 2. save_env gets a variable name, never an assignment
    while IFS= read -r line; do
        if ! printf '%s\n' "${line}" | grep -Eq '^[[:space:]]*save_env[[:space:]]+-f[[:space:]]+[^[:space:]]+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$'; then
            ci_warn "rule 2: save_env must take '-f <grubenv> <name>', got: ${line}"
            problems=$((problems + 1))
        fi
    done < <(grep -E '^[[:space:]]*save_env' "${code}" || true)
    if ! grep -q '^[[:space:]]*save_env' "${code}"; then
        ci_warn "rule 2: the configuration never calls save_env"
        problems=$((problems + 1))
    fi

    # 3. never write ab_try= through save_env
    if grep -Eq 'save_env.*=[^[:space:]]*$' "${code}"; then
        ci_warn "rule 3: save_env writes a value, which GRUB does not accept: $(grep -E 'save_env.*=' "${code}" | head -n 1)"
        problems=$((problems + 1))
    fi

    # 4. no bash-isms
    if grep -q '&&' "${code}"; then
        ci_warn "rule 4: '&&' is not GRUB script"
        problems=$((problems + 1))
    fi
    if grep -q '||' "${code}"; then
        ci_warn "rule 4: '||' is not GRUB script"
        problems=$((problems + 1))
    fi
    if grep -Eq '\$\{[^}]*:-' "${code}"; then
        ci_warn "rule 4: '\${x:-y}' is not GRUB script"
        problems=$((problems + 1))
    fi

    # 5. no unreplaced placeholder
    if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${file}"; then
        ci_warn "rule 5: unreplaced placeholder(s): $(grep -Eo '@[A-Z_][A-Z0-9_]*@' "${file}" | sort -u | tr '\n' ' ')"
        problems=$((problems + 1))
    fi

    if [ "${problems}" -ne 0 ]; then
        ci_die "rendered GRUB configuration violates ${problems} rule(s): ${file}"
    fi
    ci_log "grub configuration satisfies all five rendering rules: ${file}"
}

# --check mode: assertions only, used by the test suite.
if [ "${1:-}" = "--check" ]; then
    [ -f "${2:-}" ] || ci_die "--check needs a file"
    check_grub "$2"
    ci_log "stage grub (check) finished"
    exit 0
fi

template="${CI_GRUB_TEMPLATE:-${CI_REPO_ROOT}/scripts/ci/grub.cfg.in}"
output="${CI_GRUB_OUTPUT:-${CI_TMP_ROOT}/grub/grub.cfg}"
committed="${CI_COMMITTED_SLOT:-a}"
grubenv_path="${CI_GRUBENV_PATH:-/boot/grub/grubenv}"
timeout_s="${CI_GRUB_TIMEOUT:-3}"

[ -f "${template}" ] || ci_die "template not found: ${template}"
case "${committed}" in
    a) committed_index=0 ;;
    b) committed_index=1 ;;
    *) ci_die "committed slot must be a or b, got ${committed}" ;;
esac

mkdir -p "$(dirname "${output}")"
sed -e "s|@GRUB_TIMEOUT@|${timeout_s}|g" \
    -e "s|@COMMITTED_INDEX@|${committed_index}|g" \
    -e "s|@COMMITTED_SLOT@|${committed}|g" \
    -e "s|@GRUBENV_PATH@|${grubenv_path}|g" \
    "${template}" >"${output}"

check_grub "${output}"

sha="$(ci_sha256 "${output}")"
ci_log "rendered ${output} (committed slot ${committed}, entry ${committed_index}, sha256 ${sha})"

ci_emit_output "grub_cfg" "${output}"
ci_emit_output "grub_cfg_sha256" "${sha}"
ci_emit_output "committed_slot" "${committed}"
ci_emit_output "committed_index" "${committed_index}"

ci_log "stage grub finished"
