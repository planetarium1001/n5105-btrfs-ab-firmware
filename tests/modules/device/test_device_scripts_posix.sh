#!/usr/bin/env bash
# Module: device
# ac-1 / ac-4: every scripts/device/*.sh is POSIX sh, not bash wearing a sh spelling.
# ac-8: the gate that lints them (scripts/ci/verify.sh) uses the CI dialect, dash, and the
# shebang of every file it lints as sh declares that dialect.
#
# Why this file exists: scripts/ci/verify.sh lints the device scripts with `sh -n`, and
# `sh` is not the same shell on the machine that writes a script and the machine that runs
# the gate. On macOS /bin/sh is bash in POSIX mode - it parses `<<<`, ${BASH_SOURCE[0]} and
# `set -o pipefail` without a word - so `sh -n` on a laptop blesses a file that the Ubuntu
# runner's /bin/sh (dash) then refuses:
#
#   scripts/device/apk-protection-probe.sh: 191: Syntax error: redirection unexpected
#
# That gate was green where it was written and red where it ran, and the red only appeared
# after a push. This test is the local half of it: it reads the scripts instead of running
# them through whatever shell happens to be /bin/sh, so the same mistake fails on the
# authoring machine, before the push.
#
# The patterns and the heredoc scan live in tests/lib/shell_portability.sh now, because
# tests/modules/ci/test_shell_portability.sh runs the same guard over the whole tree. One
# definition, two entry points: a pattern added for the ci scan is enforced here too, and
# the device scripts cannot drift to a weaker rule than the rest of the repository.
#
# The fixtures below are assembled with printf instead of a here-document on purpose: this
# file is inside the scan as well now, and a literal `#!/bin/sh` heredoc carrying a bashism
# would be reported as a real violation of the rule this file tests. A fixture is allowed to
# be bad; the file it lives in is not.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
source "$root/tests/lib/shell_portability.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

device_dir="$root/scripts/device"

# --- the detector itself: a guard that stopped matching would pass every script for ever
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'here=${BASH_SOURCE[0]}'
    printf '%s\n' 'while read -r line; do :; done <<<"${body}"'
    printf '%s\n' 'if [[ -n "${here}" ]]; then :; fi'
    printf '%s\n' 'declare -r owner=lead'
} >"$tmp/bashy.sh"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# A comment may say <<< and BASH_SOURCE and pipefail without the script doing any of it.'
    printf '%s\n' 'set -eu'
    printf '%s\n' 'case "${x}" in'
    printf '%s\n' '    [[:space:]]*) : ;;'
    printf '%s\n' 'esac'
    printf '%s\n' "awk '/^[[:space:]]*-\[[ xX]\].*ac-[0-9]+/ { print }' \"\${prd}\""
} >"$tmp/clean.sh"

assert_eq "$(bashism_hits "$tmp/bashy.sh" | wc -l | tr -d ' ')" "5" \
  "ac-4 the detector flags each construct it claims to, one line at a time"
assert_eq "$(bashism_hits "$tmp/bashy.sh" | cut -d: -f1 | tr '\n' ' ')" "2 3 4 5 6 " \
  "ac-4 the detector reports the lines of a bash script, not only the file"
assert_eq "$(bashism_hits "$tmp/clean.sh" | wc -l | tr -d ' ')" "0" \
  "ac-4 a comment, a POSIX character class and an awk bracket are not bashisms"

# --- every device script
files=()
while IFS= read -r path; do
    files+=("$path")
done < <(find "$device_dir" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)

assert_eq "$([ "${#files[@]}" -gt 0 ] && echo yes || echo no)" "yes" \
  "ac-4 the scan discovers the device scripts"

for path in "${files[@]}"; do
    rel=${path#"$root"/}
    # The shebang is what verify.sh's `sh -n` and shellcheck's dialect both read, so it
    # has to say sh; a `#!/usr/bin/env bash` file would be linted as sh while running as
    # bash, which is exactly the split that let the probe stay broken.
    assert_eq "$(sed -n '1p' "$path")" '#!/bin/sh' \
      "ac-1 ${rel} declares the POSIX sh interpreter the CI lint assumes"
done

for path in "${files[@]}"; do
    rel=${path#"$root"/}
    hits=$(bashism_hits "$path")
    if [ -z "$hits" ]; then
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-4 ${rel} carries no bash-only construct"
    else
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        _assert_fail "ac-4 ${rel} carries no bash-only construct" \
            "$(printf '%s' "$hits" | tr '\n' ' ')" ""
    fi
done

# The probe under test is one of the scanned files, and it is the one the regression
# happened to: naming it keeps this file honest if the scan above ever stops discovering it.
assert_contains "${files[*]}" "apk-protection-probe.sh" \
  "ac-1 the probe whose here-string broke the CI gate is inside the scan"

# --- `#!/bin/sh` heredoc bodies, wherever they live ------------------------- #
# The 2026-11-19 regression was a bash parameter substitution inside the stub `ssh` that
# tests/modules/device/test_matrix_round2.sh hands to `sh`: nothing in scripts/device was
# touched, the laptop's bash-as-sh ran it fine, and the runner's dash answered
# "Bad substitution" for the whole stub - 24 assertions red on facts the file had just
# asserted green at home. So the scan covers the bodies too, not only the device scripts.
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "cat >\"\$tmp/ssh\" <<'STUB'"
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'last=${last/ab-upgrade --yes /ab-upgrade }'
    printf '%s\n' 'STUB'
} >"$tmp/stub-bad.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "cat >\"\$tmp/ssh\" <<'STUB'"
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'case "${last}" in'
    printf '%s\n' "    'ab-upgrade --yes '*) last=\"ab-upgrade \${last#ab-upgrade --yes }\" ;;"
    printf '%s\n' 'esac'
    printf '%s\n' '# A comment may still name ${last/x/y} without the stub doing it.'
    printf '%s\n' 'STUB'
    printf '%s\n' '# A bash heredoc that is not a sh program may use every bashism it likes.'
    printf '%s\n' "cat >\"\$tmp/helper\" <<'HELPER'"
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'name=${1//\//__}'
    printf '%s\n' 'HELPER'
} >"$tmp/stub-clean.sh"
assert_eq "$(sh_heredoc_bodies "$tmp/stub-bad.sh" | grep -cE "$sp_bashism_re" || true)" "1" \
  "ac-4 the scan reads the body of a sh heredoc, not only the file carrying it"
assert_eq "$(sh_heredoc_bodies "$tmp/stub-bad.sh" | sed -n '1p' | cut -d: -f2)" "4" \
  "ac-4 and reports the line inside the file where the body sits"
assert_eq "$(sh_heredoc_bodies "$tmp/stub-clean.sh" | grep -cE "$sp_bashism_re" || true)" "0" \
  "ac-4 a POSIX stub, a comment and a bash heredoc are not flagged"

# Every test file is scanned for that shape: the suite is where a stub like this is written.
# This file is not excluded from its own scan any more (the fixtures are printf-built, so
# there is nothing here for the scanner to find), and the assertion below pins that: an
# exclusion creeping back in would make the scan quietly weaker than the ci scan.
test_files=()
while IFS= read -r path; do
    test_files+=("$path")
done < <(find "$root/tests/modules" -type f -name '*.sh' | LC_ALL=C sort)
assert_eq "$([ "${#test_files[@]}" -gt 0 ] && echo yes || echo no)" "yes" \
  "ac-4 the scan discovers the test files"
assert_contains "${test_files[*]}" "tests/modules/device/test_device_scripts_posix.sh" \
  "ac-4 the scan covers this file too, not only the tests it does not define"

for path in "${test_files[@]}"; do
    rel=${path#"$root"/}
    hits=$(sh_heredoc_bodies "$path" | grep -E "$sp_bashism_re" | sed 's/^/line /' || true)
    if [ -z "$hits" ]; then
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-4 ${rel} runs no bash-only construct inside a sh heredoc"
    else
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        _assert_fail "ac-4 ${rel} runs no bash-only construct inside a sh heredoc" \
            "$(printf '%s' "$hits" | tr '\n' ' ')" ""
    fi
done

# --- ac-8: the gate lints with the CI dialect -------------------------------------- #
# verify.sh's sh -n used to run whatever /bin/sh was, which is the whole failure mode this
# file exists for: on the authoring Mac that is bash 3.2, on the runner it is dash. The
# script now resolves a real dash first (CI_SH_BIN, then PATH) and prints what it used; the
# version line is what makes a green run explainable later.
verify="$root/scripts/ci/verify.sh"
assert_file_exists "$verify" "ac-8 the verify stage script exists"
assert_eq "$(sed -n '1p' "$verify")" '#!/usr/bin/env bash' \
  "ac-8 verify.sh declares the bash it is written in, so its dialect matches its shebang"
assert_contains "$(cat "$verify")" 'CI_SH_BIN' \
  "ac-8 the sh lint can be pointed at a dash explicitly"
assert_contains "$(cat "$verify")" 'ci_have dash' \
  "ac-8 the sh lint prefers a real dash over /bin/sh when one is installed"
assert_contains "$(cat "$verify")" 'sh syntax check: ' \
  "ac-8 the sh lint prints the shell it used, version included"
assert_contains "$(cat "$verify")" '"${sh_bin}" -n' \
  "ac-8 the sh syntax loop runs with the resolved shell, not with the bare name sh"
assert_contains "$(cat "$verify")" 'syntax ok (sh): ' \
  "ac-8 the per-file verdict still names the sh dialect"
assert_eq "$(grep -cE '^[[:space:]]*(if )?sh -n ' "$verify")" "0" \
  "ac-8 no sh syntax check is left on the bare name sh"

# The selection is executed, not only grepped: strip the block out of verify.sh, give it the
# stage helpers it calls as stubs, and see which shell it picks and what it prints. A static
# assertion would stay green if the default silently went back to /bin/sh.
# The stub dash answers both probes (macOS dash prints no version at all), so the assertion
# is about the plumbing - which binary, which version string reaches the log - and not about
# this host's dash.
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '    --version) printf "%s\n" "dash 0.5.12"; exit 0 ;;'
    printf '%s\n' '    -c) printf "%s\n" "0.5.12"; exit 0 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exit 0'
} >"$tmp/fake-dash"
chmod +x "$tmp/fake-dash"
selection=$(awk '
    /^sh_bin="\$\{CI_SH_BIN:-\}"/ { capture = 1 }
    capture { print }
    capture && /^ci_log "sh syntax check:/ { exit }
' "$verify")
assert_contains "${selection}" 'CI_SH_BIN' \
  "ac-8 the selection block was found in verify.sh (an empty block proves nothing)"
run_selection() {
    (
        ci_have() { command -v "$1" >/dev/null 2>&1; }
        ci_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
        ci_log() { printf '%s\n' "$*"; }
        cd "$root" || exit 1
        eval "${selection}"
    )
}
selected=$(run_selection 2>&1)
if command -v dash >/dev/null 2>&1; then
    assert_contains "${selected}" "sh syntax check: $(command -v dash) (" \
      "ac-8 verify.sh picks the installed dash by default"
else
    assert_contains "${selected}" 'sh syntax check: ' \
      "ac-8 verify.sh falls back to sh when no dash is installed"
fi
selected=$(CI_SH_BIN="$tmp/fake-dash" run_selection 2>&1)
assert_contains "${selected}" "sh syntax check: $tmp/fake-dash (0.5.12)" \
  "ac-8 CI_SH_BIN is honoured, and its version reaches the log line"
selected=$(CI_SH_BIN="$tmp/does-not-exist" run_selection 2>&1)
assert_contains "${selected}" 'ERROR: sh not found (set CI_SH_BIN): ' \
  "ac-8 a bad CI_SH_BIN fails the stage instead of silently falling back to /bin/sh"

finish
