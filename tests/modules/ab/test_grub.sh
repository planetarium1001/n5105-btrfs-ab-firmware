#!/usr/bin/env bash
# Module: ab
# Verifies the GRUB rendering rules from docs/boot-overlay.md. The renderer refuses a
# bad configuration, so the test drives it in --check mode with one mutant per rule:
#   ac-1 the rendered configuration passes all five rules
#   ac-2 a missing or templated default entry is rejected
#   ac-3 save_env with a value, or writing ab_try=, is rejected
#   ac-4 bash-only operators are rejected
#   ac-5 an unreplaced placeholder is rejected
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

render="$root/scripts/ci/grub-render.sh"
template="$root/scripts/ci/grub.cfg.in"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render_into() { # <output>
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
    CI_GRUB_OUTPUT="$1" CI_GRUB_TEMPLATE="$template" CI_COMMITTED_SLOT=a \
    bash "$render" >"$tmp/render.log" 2>&1
}

check_file() { # <file> -> exit status of the rule check
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
    bash "$render" --check "$1" >"$tmp/check.log" 2>&1
}

good="$tmp/grub.cfg"
render_into "$good"
assert_eq "$?" "0" "ac-1 the template renders"
assert_file_exists "$good" "ac-1 the rendered configuration exists"

check_file "$good"
assert_eq "$?" "0" "ac-1 the rendered configuration passes every rule"

body=$(cat "$good")
assert_contains "$body" "set default=0" "ac-1 the committed slot becomes the default entry"
assert_contains "$body" "save_env -f /boot/grub/grubenv ab_try" "ac-1 save_env gets a variable name"
assert_contains "$body" "ab.slot=a" "ac-1 the slot is passed on the kernel command line"

# ac-2 a concrete default entry is required
mutant_default="$tmp/default.cfg"
sed 's/^set default=0$/set default=/' "$good" >"$mutant_default"
check_file "$mutant_default"
assert_eq "$?" "1" "ac-2 an empty default entry is rejected"

mutant_token="$tmp/default-token.cfg"
sed 's/^set default=0$/set default=@COMMITTED_INDEX@/' "$good" >"$mutant_token"
check_file "$mutant_token"
assert_eq "$?" "1" "ac-2 a templated default entry is rejected"

# ac-3 save_env must not assign
mutant_assign="$tmp/assign.cfg"
sed 's|save_env -f /boot/grub/grubenv ab_try|save_env -f /boot/grub/grubenv ab_try=b|' \
  "$good" >"$mutant_assign"
assert_contains "$(cat "$mutant_assign")" "save_env -f /boot/grub/grubenv ab_try=b" \
  "ac-3 the mutant writes ab_try=b"
check_file "$mutant_assign"
assert_eq "$?" "1" "ac-3 save_env with a value is rejected"

mutant_extra="$tmp/extra.cfg"
printf 'save_env -f /boot/grub/grubenv ab_try=a\n' >>"$mutant_extra"
cat "$good" >>"$mutant_extra"
check_file "$mutant_extra"
assert_eq "$?" "1" "ac-3 an extra save_env assignment is rejected"

# ac-4 GRUB script is not bash
mutant_and="$tmp/and.cfg"
{ cat "$good"; printf 'if [ -n "$ab_try" ] && [ -n "$ab_slot" ]; then\n'; printf 'fi\n'; } >"$mutant_and"
check_file "$mutant_and"
assert_eq "$?" "1" "ac-4 '&&' is rejected"

mutant_or="$tmp/or.cfg"
{ cat "$good"; printf 'if [ -z "$ab_try" ] || [ -z "$ab_slot" ]; then\n'; printf 'fi\n'; } >"$mutant_or"
check_file "$mutant_or"
assert_eq "$?" "1" "ac-4 '||' is rejected"

mutant_expand="$tmp/expand.cfg"
{ cat "$good"; printf 'set ab_slot=${ab_slot:-a}\n'; } >"$mutant_expand"
check_file "$mutant_expand"
assert_eq "$?" "1" "ac-4 '\${x:-y}' is rejected"

# ac-5 placeholders must all be replaced
mutant_placeholder="$tmp/placeholder.cfg"
{ cat "$good"; printf 'set ab_placeholder=@UNREPLACED@\n'; } >"$mutant_placeholder"
check_file "$mutant_placeholder"
assert_eq "$?" "1" "ac-5 an unreplaced placeholder is rejected"

# ac-1 again: comments may mention the forbidden constructs without failing the check
mutant_comment="$tmp/comment.cfg"
{ printf '# never use && or || or ${x:-y} here\n'; cat "$good"; } >"$mutant_comment"
check_file "$mutant_comment"
assert_eq "$?" "0" "ac-1 comments are not treated as code"

finish
