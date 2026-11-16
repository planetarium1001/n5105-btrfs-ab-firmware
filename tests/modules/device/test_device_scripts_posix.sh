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
bashism_re='<<<|BASH_SOURCE|pipefail|\bdeclare\b|(^|[^\\])\[\[[[:space:]]'

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

finish
