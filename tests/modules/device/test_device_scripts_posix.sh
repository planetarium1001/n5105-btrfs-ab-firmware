#!/usr/bin/env bash
# Module: device
# ac-1 / ac-4: every scripts/device/*.sh is POSIX sh, not bash wearing a sh spelling.
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
# The patterns are the constructs that made that file unparsable, and nothing else. A scan
# broad enough to catch every bashism would also fire on awk's `function flush()`, the
# `[[:space:]]` character class and the English word "source", and a guard that cries wolf
# gets deleted. Comment lines are skipped: a comment is allowed to name what it warns
# against, which is how the rewritten probe explains why it no longer uses a here-string.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

device_dir="$root/scripts/device"

# One pattern per construct dash rejects at parse time. `[[` is written with a trailing
# space and a preceding non-backslash so that neither the POSIX `[[:space:]]` class nor an
# awk regex matching a literal bracket (`\[[ xX]\]`, which these scripts use to read the
# checklist) matches it; `declare` is word-bounded so the word "declares" does not match
# either. `source` and `function` are deliberately left out: they occur legitimately in
# strings and in awk programs in these scripts, and both are runtime failures rather than
# parse failures, so the importing script's own tests are where they belong.
#
# `${var/pat/repl}` is the one that got through this guard on 2026-11-19: it was written
# inside a heredoc that a *test* hands to `sh` (the stub `ssh` of test_matrix_round2.sh), so
# it was not in scripts/device at all, and on the laptop's bash-as-sh it even worked. The
# second scan below is what covers that shape; the pattern belongs here too because a
# device script can carry it just as easily.
bashism_re='<<<|BASH_SOURCE|pipefail|\bdeclare\b|(^|[^\\])\[\[[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*/[^}]'
# A heredoc whose first line is `#!/bin/sh` is a program, and it runs under dash on the CI
# runner whatever the file carrying it says. Only its body is scanned: the file around it is
# often a bash script that is allowed every bashism.
sh_heredoc_bodies() {
    awk '
        state == 0 && /<<[-]?["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?:?$/ {
            tag = $0
            sub(/.*<<[-]?"?/, "", tag)
            sub(/["'"'"'].*/, "", tag)
            body = 0
            state = 1
            next
        }
        state == 1 {
            if ($0 == tag) { state = 0; next }
            if (body == 0) {
                if ($0 ~ /^#![ \t]*\/bin\/sh/) body = 1
                else { state = 0; next }
                next
            }
            # A comment is allowed to name what it warns against: the rewritten stub in
            # test_matrix_round2.sh explains the construct it no longer uses.
            if ($0 !~ /^[ \t]*#/) print FILENAME ":" FNR ":" $0
            next
        }
    ' "$1"
}


# Non-comment lines carrying one of the above, with file:line numbers.
bashism_hits() {
    grep -nE "$bashism_re" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# --- the detector itself: a guard that stopped matching would pass every script for ever
cat >"$tmp/bashy.sh" <<'BAD'
#!/usr/bin/env bash
set -euo pipefail
here=${BASH_SOURCE[0]}
while read -r line; do :; done <<<"${body}"
if [[ -n "${here}" ]]; then :; fi
declare -r owner=lead
BAD
cat >"$tmp/clean.sh" <<'CLEAN'
#!/bin/sh
# A comment may say <<< and BASH_SOURCE and pipefail without the script doing any of it.
set -eu
case "${x}" in
    [[:space:]]*) : ;;
esac
awk '/^[[:space:]]*-\[[ xX]\].*ac-[0-9]+/ { print }' "${prd}"
CLEAN

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
cat >"$tmp/stub-bad.sh" <<'BADSTUB'
#!/usr/bin/env bash
cat >"$tmp/ssh" <<'STUB'
#!/bin/sh
last=${last/ab-upgrade --yes /ab-upgrade }
STUB
BADSTUB
cat >"$tmp/stub-clean.sh" <<'CLEANSTUB'
#!/usr/bin/env bash
cat >"$tmp/ssh" <<'STUB'
#!/bin/sh
case "${last}" in
    'ab-upgrade --yes '*) last="ab-upgrade ${last#ab-upgrade --yes }" ;;
esac
# A comment may still name ${last/x/y} without the stub doing it.
STUB
# A bash heredoc that is not a sh program may use every bashism it likes.
cat >"$tmp/helper" <<'HELPER'
#!/usr/bin/env bash
name=${1//\//__}
HELPER
CLEANSTUB
assert_eq "$(sh_heredoc_bodies "$tmp/stub-bad.sh" | grep -cE "$bashism_re" || true)" "1" \
  "ac-4 the scan reads the body of a sh heredoc, not only the file carrying it"
assert_eq "$(sh_heredoc_bodies "$tmp/stub-bad.sh" | sed -n '1p' | cut -d: -f2)" "4" \
  "ac-4 and reports the line inside the file where the body sits"
assert_eq "$(sh_heredoc_bodies "$tmp/stub-clean.sh" | grep -cE "$bashism_re" || true)" "0" \
  "ac-4 a POSIX stub, a comment and a bash heredoc are not flagged"

# Every test file is scanned for that shape: the suite is where a stub like this is written.
# This file is excluded from the scan it defines: the fixtures above are *supposed* to carry
# the construct (a detector with no positive example proves nothing), and the fixture is
# unreachable from any `sh` except by this test reading it.
test_files=()
while IFS= read -r path; do
    # `here` is this file's own directory; the file itself is ${here}/$(basename of $0).
    [ "$path" = "${here}/$(basename "${BASH_SOURCE[0]}")" ] && continue
    test_files+=("$path")
done < <(find "$root/tests/modules" -type f -name '*.sh' | LC_ALL=C sort)
assert_eq "$([ "${#test_files[@]}" -gt 0 ] && echo yes || echo no)" "yes" \
  "ac-4 the scan discovers the test files"

for path in "${test_files[@]}"; do
    rel=${path#"$root"/}
    hits=$(sh_heredoc_bodies "$path" | grep -E "$bashism_re" | sed 's/^/line /' || true)
    if [ -z "$hits" ]; then
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-4 ${rel} runs no bash-only construct inside a sh heredoc"
    else
        _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
        _assert_fail "ac-4 ${rel} runs no bash-only construct inside a sh heredoc" \
            "$(printf '%s' "$hits" | tr '\n' ' ')" ""
    fi
done

finish
