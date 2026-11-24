#!/usr/bin/env bash
# Module: ci
# ac-7: the POSIX guard catches what the authoring Mac accepts and the Ubuntu runner does
# not - a `<<<`, a ${var/pat/repl}, a bash 4 case conversion - and it does so locally,
# before a push. `dash -n` and the bash 3.2 parse are run for real when this host has the
# shell; when it does not, the guard prints a skip: line instead of pretending it checked.
#
# Why this file exists: the 2026-11-19 incident was a here-string in a device script that
# `sh -n` on a laptop (bash-as-sh) accepted and the runner's dash refused - the red appeared
# only after the push. The device test covers that shape where it lives
# (tests/modules/device/test_device_scripts_posix.sh); this one covers the whole repository
# and the parts of the guard that only a bad sample can prove:
#   * the detector really matches each construct it claims to (a guard that stopped
#     matching would pass every script for ever),
#   * a violation under scripts/ or tests/ fails the run while one under initramfs/ or
#     platform/ is only reported,
#   * `dash -n` and the bash 3.2 parse are wired to the graded result, and both say skip:
#     with their version line when the host has no such shell,
#   * this file is discovered by tests/run.sh --module ci.
#
# The fixtures are printf-built rather than here-documents: a literal `#!/bin/sh` heredoc
# carrying a bashism inside this file would be a real finding for the very scan it tests.
# The expectation for a bad sample is an exit status, not a grep: a test that asserts text
# only would stay green if the guard ever stopped returning non-zero.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
source "$root/tests/lib/shell_portability.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# make_script <path> <line>...: write a fixture and create its parent directory.
make_script() {
    local target="$1" line
    shift
    mkdir -p "$(dirname "${target}")"
    : >"${target}"
    for line in "$@"; do
        printf '%s\n' "${line}" >>"${target}"
    done
}

# run_check <tree> [VAR=value]...: run the guard with a controlled host, capture the exit
# status in CHECK_RC and the output in CHECK_OUT. Env assignments go through `env` so a
# skipped shell can be simulated on a machine that has it installed.
CHECK_RC=0
CHECK_OUT=""
run_check() {
    local tree="$1"
    shift
    CHECK_OUT="$(env "$@" bash -c '. "$1"; shift; shell_portability_check "$@"' _ \
        "$root/tests/lib/shell_portability.sh" "${tree}" 2>&1)" && CHECK_RC=0 || CHECK_RC=$?
}

# --------------------------------------------------------------------------- #
# 1. The detector: each construct, a comment, and the false positives it must not take
# --------------------------------------------------------------------------- #
make_script "$tmp/detect/herestring.sh" '#!/bin/sh' 'read -r line <<<"${body}"'
make_script "$tmp/detect/subst.sh" '#!/bin/sh' 'last=${last/ab-upgrade --yes /ab-upgrade }'
make_script "$tmp/detect/caseconv.sh" '#!/bin/sh' 'name=${owner^^}'
make_script "$tmp/detect/declare.sh" '#!/bin/sh' 'declare -r owner=lead'
make_script "$tmp/detect/brackets.sh" '#!/bin/sh' 'if [[ -n "${x}" ]]; then :; fi'
make_script "$tmp/detect/bashsource.sh" '#!/bin/sh' 'here=${BASH_SOURCE[0]}'
make_script "$tmp/detect/pipefail.sh" '#!/bin/sh' 'set -o pipefail'
make_script "$tmp/detect/clean.sh" \
    '#!/bin/sh' \
    '# A comment may say <<< and BASH_SOURCE and pipefail and ${x/y} without doing it.' \
    'set -eu' \
    'case "${x}" in' \
    '    [[:space:]]*) : ;;' \
    'esac' \
    "awk '/^[[:space:]]*-\[[ xX]\].*ac-[0-9]+/ { print }' \"\${prd}\"" \
    'printf "%s\n" "${last#ab-upgrade }"'

for fixture in herestring subst caseconv declare brackets bashsource pipefail; do
    assert_eq "$(bashism_hits "$tmp/detect/${fixture}.sh" | cut -d: -f1 | tr '\n' ' ')" "2 " \
        "ac-7 the detector flags ${fixture}.sh on its code line, not only on the file"
done
assert_contains "$(bashism_hits "$tmp/detect/herestring.sh")" '<<<' \
    "ac-7 a here-string is a bashism"
assert_contains "$(bashism_hits "$tmp/detect/subst.sh")" '${last/ab-upgrade' \
    "ac-7 \${var/pat/repl} is a bashism, also inside a sh heredoc elsewhere"
assert_contains "$(bashism_hits "$tmp/detect/caseconv.sh")" '${owner^^}' \
    "ac-7 bash 4 case conversion is a bashism dash only refuses at run time"
assert_contains "$(bashism_hits "$tmp/detect/brackets.sh")" '[[' \
    "ac-7 [[ is a bashism"
assert_eq "$(bashism_hits "$tmp/detect/clean.sh" | wc -l | tr -d ' ')" "0" \
    "ac-7 a comment, a POSIX character class, an awk bracket and a POSIX expansion are not"

# --------------------------------------------------------------------------- #
# 2. The bash 4 parse sample: dash rejects it, the textual patterns do not catch it
# --------------------------------------------------------------------------- #
make_script "$tmp/parse/scripts/bad-parse.sh" '#!/bin/sh' 'arr=(one two)' 'printf "%s\n" "${arr}"'
assert_eq "$(bashism_hits "$tmp/parse/scripts/bad-parse.sh" | wc -l | tr -d ' ')" "0" \
    "ac-7 an array assignment is invisible to the textual scan"
if command -v dash >/dev/null 2>&1; then
    run_check "$tmp/parse" SHELL_PORTABILITY_BASH=none
    assert_eq "${CHECK_RC}" "1" \
        "ac-7 a file dash cannot parse fails the guard even without a pattern hit"
    assert_contains "${CHECK_OUT}" 'fail: scripts/bad-parse.sh:1: dash -n rejected this file' \
        "ac-7 and the failure names the file and the dash verdict"
else
    printf '# dash is not installed here; the dash parse assertions are enforced by CI\n'
fi

# --------------------------------------------------------------------------- #
# 3. Grading: scripts/ and tests/ fail, initramfs/ and platform/ report
# --------------------------------------------------------------------------- #
tree="$tmp/tree"
make_script "$tree/scripts/bad-herestring.sh" '#!/bin/sh' 'read -r line <<<"${body}"'
make_script "$tree/scripts/good.sh" '#!/bin/sh' 'set -eu' 'printf "%s\n" ok'
make_script "$tree/tests/modules/x/bad-case.sh" '#!/bin/sh' 'name=${owner^^}'
make_script "$tree/tests/modules/x/stub-bad.sh" \
    '#!/usr/bin/env bash' \
    "cat >\"\$tmp/ssh\" <<'STUB'" \
    '#!/bin/sh' \
    'last=${last/ab-upgrade --yes /ab-upgrade }' \
    'STUB'
make_script "$tree/scripts/device/bad-shebang.sh" '#!/usr/bin/env bash' 'printf "%s\n" ok'
make_script "$tree/initramfs/init" '#!/bin/sh' 'read -r line <<<"${body}"'
make_script "$tree/platform/lib/ab-x.sh" '#!/bin/sh' 'if [[ -n "${x}" ]]; then :; fi'

run_check "${tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "1" \
    "ac-7 one bad file under scripts/ or tests/ fails the whole guard"
assert_contains "${CHECK_OUT}" 'fail: scripts/bad-herestring.sh:2: bash-only construct: read -r line <<<' \
    "ac-7 a here-string under scripts/ is a failure, with its line and the code"
assert_contains "${CHECK_OUT}" 'fail: tests/modules/x/bad-case.sh:2:' \
    "ac-7 a bash 4 construct under tests/ is a failure"
assert_contains "${CHECK_OUT}" 'fail: tests/modules/x/stub-bad.sh:4: bash-only construct in a sh heredoc' \
    "ac-7 a bashism inside a sh heredoc is a failure of the file that carries it"
assert_contains "${CHECK_OUT}" 'fail: scripts/device/bad-shebang.sh:1:' \
    "ac-7 a file the verify stage lints as sh must say #!/bin/sh"
assert_contains "${CHECK_OUT}" 'report: initramfs/init:2:' \
    "ac-7 a here-string under initramfs/ is reported"
assert_contains "${CHECK_OUT}" 'report: platform/lib/ab-x.sh:2:' \
    "ac-7 a [[ under platform/ is reported"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^fail: initramfs/\|^fail: platform/' || true)" "0" \
    "ac-7 the shipped layers are never graded as failures"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^fail: scripts/good.sh' || true)" "0" \
    "ac-7 a clean script is not named"
assert_contains "${CHECK_OUT}" 'shell portability: fail' \
    "ac-7 the summary line carries the verdict"

# The same bad files in a tree with nothing graded: report: lines, exit 0.
report_tree="$tmp/report-tree"
make_script "$report_tree/initramfs/init" '#!/bin/sh' 'read -r line <<<"${body}"'
make_script "$report_tree/platform/lib/ab-x.sh" '#!/bin/sh' 'name=${owner^^}'
make_script "$report_tree/scripts/good.sh" '#!/bin/sh' 'set -eu'
run_check "${report_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "0" \
    "ac-7 a tree whose only violations are shipped layers passes"
assert_contains "${CHECK_OUT}" 'report: initramfs/init:2:' \
    "ac-7 ... and still prints what it found"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^fail:' || true)" "0" \
    "ac-7 ... without inventing a failure"
assert_contains "${CHECK_OUT}" 'shell portability: ok' \
    "ac-7 the summary line says ok when nothing graded is wrong"

# A wrong root must not read as a clean tree: that is how a guard silently stops running.
mkdir -p "$tmp/empty-root"
run_check "$tmp/empty-root" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "1" \
    "ac-7 a root with no scripts/, tests/, initramfs/ or platform/ is a failure"
assert_contains "${CHECK_OUT}" 'no scripts/, tests/, initramfs/ or platform/ under this root' \
    "ac-7 ... and says why"

# --------------------------------------------------------------------------- #
# 4. The host shells: used when present, skip: when not, never silently
# --------------------------------------------------------------------------- #
# A strict stub for dash: succeeds except on a file carrying the marker. That makes the
# wiring (dash verdict -> graded failure) testable on macOS and Ubuntu alike, independent
# of what the host's own dash happens to accept.
make_script "$tmp/fake-dash" \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '    --version) printf "%s\n" "dash 0.5.12 (fake)"; exit 0 ;;' \
    'esac' \
    'if [ "${1:-}" = "-n" ] && grep -q "FAKE_DASH_REJECT" "${2:-/dev/null}" 2>/dev/null; then' \
    '    printf "%s: Syntax error: redirection unexpected\n" "${2:-}" >&2' \
    '    exit 2' \
    'fi' \
    'exit 0'
chmod +x "$tmp/fake-dash"
strict_tree="$tmp/strict-tree"
make_script "$strict_tree/scripts/bad-wired.sh" '#!/bin/sh' 'echo FAKE_DASH_REJECT'
make_script "$strict_tree/scripts/good.sh" '#!/bin/sh' 'set -eu'
run_check "${strict_tree}" SHELL_PORTABILITY_DASH="$tmp/fake-dash" SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "1" \
    "ac-7 a non-zero dash -n on a graded file fails the guard"
assert_contains "${CHECK_OUT}" "sh: $tmp/fake-dash (dash 0.5.12 (fake))" \
    "ac-7 the guard prints which dash it used and its version"
assert_contains "${CHECK_OUT}" 'fail: scripts/bad-wired.sh:1: dash -n rejected this file' \
    "ac-7 the dash verdict is attributed to the file"

run_check "${strict_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "0" \
    "ac-7 with no dash available the parse check does not fail the tree"
assert_contains "${CHECK_OUT}" 'skip: ' \
    "ac-7 ... it prints an explicit skip: line instead"
assert_contains "${CHECK_OUT}" 'SHELL_PORTABILITY_DASH=none; dash -n did not run' \
    "ac-7 ... naming the switch that turned it off"

run_check "$tmp/parse" SHELL_PORTABILITY_BASH=none
if command -v dash >/dev/null 2>&1; then
    assert_contains "${CHECK_OUT}" "sh: $(command -v dash) (" \
        "ac-7 the real dash from PATH is used, named with its version"
else
    assert_contains "${CHECK_OUT}" 'skip: dash not found' \
        "ac-7 without dash on PATH the skip names the missing shell"
fi

# A fake 3.2 bash: the branch must actually invoke `-n` on every bash file, and a 3.2
# refusal is a gate, graded like a pattern hit - a fail under scripts/ or tests/, a report
# under the shipped layers. CI's own bash is 5.x, so the runner never sees this branch: it
# is the half of the guard that runs on the authoring Mac, and a test that let it be a
# report: would be the soft-check failure this whole unit exists to remove.
make_script "$tmp/fake-bash-32" \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '    --version) printf "%s\n" "GNU bash, version 3.2.57(1)-release (fake)"; exit 0 ;;' \
    'esac' \
    'if [ -n "${FAKE_BASH_LOG:-}" ]; then printf "%s\n" "$*" >>"${FAKE_BASH_LOG}"; fi' \
    'if [ "${1:-}" = "-n" ] && grep -q "FAKE_BASH_REJECT" "${2:-/dev/null}" 2>/dev/null; then' \
    '    printf "%s: fake bash 3.2 refused\n" "${2:-}" >&2' \
    '    exit 2' \
    'fi' \
    'exit 0'
chmod +x "$tmp/fake-bash-32"
bash_tree="$tmp/bash-tree"
make_script "$bash_tree/scripts/a.sh" '#!/usr/bin/env bash' 'set -uo pipefail'
make_script "$bash_tree/scripts/b.sh" '#!/usr/bin/env bash' 'set -uo pipefail'
make_script "$bash_tree/scripts/bad.sh" '#!/usr/bin/env bash' 'echo FAKE_BASH_REJECT'
make_script "$bash_tree/initramfs/tools.sh" '#!/usr/bin/env bash' 'echo FAKE_BASH_REJECT'
make_script "$bash_tree/platform/lib.sh" '#!/usr/bin/env bash' 'echo FAKE_BASH_REJECT'
export FAKE_BASH_LOG="$tmp/fake-bash-calls.log"
: >"${FAKE_BASH_LOG}"
run_check "${bash_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH="$tmp/fake-bash-32"
unset FAKE_BASH_LOG
assert_eq "${CHECK_RC}" "1" \
    "ac-7 a bash 3.2 refusal on a file this repository owns fails the guard"
assert_contains "${CHECK_OUT}" "bash: $tmp/fake-bash-32 (3.2.57)" \
    "ac-7 the guard prints which system bash it parsed with and its version"
assert_contains "${CHECK_OUT}" 'fail: scripts/bad.sh:1: bash 3.2 cannot parse this file' \
    "ac-7 ... and the refusal is a failure naming the file, not a report on it"
assert_contains "${CHECK_OUT}" 'report: initramfs/tools.sh:1: bash 3.2 cannot parse this file' \
    "ac-7 a refusal on the initramfs is only reported: that code is shipped as is"
assert_contains "${CHECK_OUT}" 'report: platform/lib.sh:1: bash 3.2 cannot parse this file' \
    "ac-7 a refusal on the platform layer is only reported too"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^fail:' || true)" "1" \
    "ac-7 the two shipped layers do not add a failure of their own"
assert_eq "$(grep -c '^-n ' "$tmp/fake-bash-calls.log" || true)" "5" \
    "ac-7 every bash file was handed to bash 3.2 -n, report-only ones included"

# A host bash newer than 3.2 cannot answer the question, and says so.
make_script "$tmp/fake-bash-50" \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '    --version) printf "%s\n" "GNU bash, version 5.1.16(1)-release (fake)"; exit 0 ;;' \
    'esac' \
    'exit 0'
chmod +x "$tmp/fake-bash-50"
run_check "${bash_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH="$tmp/fake-bash-50"
assert_eq "${CHECK_RC}" "0" \
    "ac-7 a host bash newer than 3.2 does not fail a tree only bash 3.2 would refuse"
assert_contains "${CHECK_OUT}" 'skip: system bash is GNU bash, version 5.1.16(1)-release (fake), not 3.2' \
    "ac-7 a bash newer than 3.2 is an explicit skip, never a silent pass"
run_check "${bash_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH=none
assert_eq "${CHECK_RC}" "0" \
    "ac-7 turning the bash parse off does not fail the guard"
assert_contains "${CHECK_OUT}" 'skip: SHELL_PORTABILITY_BASH=none; bash -n did not run' \
    "ac-7 the bash parse can be turned off, and says that it was"

# A named binary that cannot run was asked for and did not run: that is a failure, not a
# skip. Otherwise a typo in the probe path would silently drop the gate.
: >"$tmp/not-executable-bash"
run_check "${bash_tree}" SHELL_PORTABILITY_DASH=none SHELL_PORTABILITY_BASH="$tmp/not-executable-bash"
assert_eq "${CHECK_RC}" "1" \
    "ac-7 a bash probe that is present but not executable fails the guard"
assert_contains "${CHECK_OUT}" "fail: $tmp/not-executable-bash: the bash binary is not executable" \
    "ac-7 ... instead of dropping the check without a word"

# --------------------------------------------------------------------------- #
# 5. The repository itself: the real sh scripts pass, with the sampled shells named
# --------------------------------------------------------------------------- #
sh_count="$(sh_files "$root/scripts" | wc -l | tr -d ' ')"
assert_eq "$([ "${sh_count}" -gt 20 ] && echo yes || echo no)" "yes" \
    "ac-7 the scan discovers the repository's sh scripts (${sh_count} under scripts/)"
assert_contains "$(sh_files "$root/scripts")" 'scripts/device/apk-protection-probe.sh' \
    "ac-7 the probe whose here-string broke the gate is inside the scan"

run_check "$root"
assert_eq "${CHECK_RC}" "0" \
    "ac-7 the repository's own sh and bash scripts pass the guard"
assert_contains "${CHECK_OUT}" 'shell portability: ok' \
    "ac-7 ... with an ok summary"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^fail:' || true)" "0" \
    "ac-7 ... and no failure line at all"
assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c 'no scripts/, tests/, initramfs/ or platform/' || true)" "0" \
    "ac-7 ... over the real root, not over an empty one"
if command -v dash >/dev/null 2>&1; then
    assert_contains "${CHECK_OUT}" "sh: $(command -v dash) (" \
        "ac-7 the repository run names the dash it parsed with"
else
    assert_contains "${CHECK_OUT}" 'skip: dash not found' \
        "ac-7 the repository run says dash is missing here instead of claiming a parse"
fi
# The bash 3.2 half on the real tree: on a host whose /bin/bash is 3.2 (macOS) this run is
# a real gate, so a clean ok means every one of the repository's bash files parses there.
# The assertion is skipped rather than faked elsewhere: a host without bash 3.2 cannot
# answer the question, and the guard says so itself.
if [ -x /bin/bash ] && /bin/bash -c 'case "${BASH_VERSION:-}" in 3.2*) exit 0 ;; *) exit 1 ;; esac' 2>/dev/null; then
    assert_contains "${CHECK_OUT}" 'bash: /bin/bash (3.2' \
        "ac-7 the repository run is parsed by the host's bash 3.2, not skipped"
    assert_eq "$(printf '%s\n' "${CHECK_OUT}" | grep -c '^report:' || true)" "0" \
        "ac-7 ... and no bash file needs a report: exemption any more"
else
    printf '# /bin/bash is not 3.2 here; the bash 3.2 gate over the real tree runs on macOS\n'
fi

# The library mirrors the sh-linted set of scripts/ci/verify.sh; if that section ever
# changes shape, the mirror is stale and the guard checks the wrong files.
verify="$(cat "$root/scripts/ci/verify.sh")"
for token in 'initramfs' 'platform' 'scripts/device' 'for module in image ab upgrade runtime release'; do
    assert_contains "${verify}" "${token}" \
        "ac-7 verify.sh still lints '${token}' as sh, so the guard's mirror is current"
done

# --------------------------------------------------------------------------- #
# 6. Discoverable the way the suite runs it (no tests/.out is touched: --list stops early)
# --------------------------------------------------------------------------- #
assert_eq "$(cd "$root" && ./tests/run.sh --list | grep -c '/tests/modules/ci/test_shell_portability.sh')" "1" \
    "ac-7 tests/run.sh --module ci discovers this file"

finish
