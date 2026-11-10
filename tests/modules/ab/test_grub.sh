#!/usr/bin/env bash
# Module: ab
# Verifies the GRUB menu that picks the slot, and the runtime file it sources. The
# GRUB in the ESP is a standalone EFI binary with its modules built in and no `env`
# module, so the mechanism is a two-line file that `source` reads; a menu that waits
# for `load_env` boots the committed slot forever, which is the failure this file
# exists to prevent. The renderer refuses a bad configuration, so the test drives it in
# --check mode with one mutant per rule:
#   ac-1 the rendered configuration passes all five rules and sources the runtime file
#   ac-2 a missing, templated or non-committed static default/fallback pair is rejected
#   ac-3 a menu that is not complete before the runtime override is rejected
#   ac-4 environment block machinery is rejected, because this GRUB has no env module
#   ac-5 bash-only operators are rejected, an unreplaced placeholder is rejected
#   ac-6 the committed slot decides the build-time default and the runtime file
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

render="$root/scripts/ci/grub-render.sh"
template="$root/scripts/ci/grub.cfg.in"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render_into() { # <output> [<committed slot>]
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
    CI_GRUB_OUTPUT="$1" CI_GRUB_TEMPLATE="$template" \
    CI_COMMITTED_SLOT="${2:-a}" \
    bash "$render" >"$tmp/render.log" 2>&1
}

check_file() { # <file> [<runtime slot file>] -> exit status of the rule check
  CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
    bash "$render" --check "$@" >"$tmp/check.log" 2>&1
}

good="$tmp/grub/grub.cfg"
render_into "$good"
assert_eq "$?" "0" "ac-1 the template renders"
assert_file_exists "$good" "ac-1 the rendered configuration exists"
assert_file_exists "$tmp/grub/ab-slot.cfg" "ac-1 the runtime slot file is written next to it"

check_file "$good"
assert_eq "$?" "0" "ac-1 the rendered configuration passes every rule"
check_file "$good" "$tmp/grub/ab-slot.cfg"
assert_eq "$?" "0" "ac-1 the rendered configuration and its runtime file pass"

body=$(cat "$good")
assert_contains "$body" "set default=0" "ac-1 the committed slot is the build-time default"
assert_contains "$body" "set fallback=0" \
  "ac-1 the build-time fallback is the committed entry, so a truncated runtime file still boots it"
assert_contains "$body" "if [ -f /boot/grub/ab-slot.cfg ]; then" \
  "ac-1 sourcing the runtime file is guarded"
assert_contains "$body" "source /boot/grub/ab-slot.cfg" "ac-1 the runtime file is sourced"
assert_contains "$body" "ab.slot=a" "ac-1 slot a is passed on the kernel command line"
assert_contains "$body" "ab.slot=b" "ac-1 slot b is passed on the kernel command line"

# The index mapping is a contract with platform/lib/ab-slot-cfg.sh: entry 0 is slot a,
# entry 1 is slot b, and the runtime file writes those numbers.
ids=$(grep -oE -- '--id [A-Za-z0-9_-]+' "$good" | sed 's/--id //' | tr '\n' ',')
assert_eq "$ids" "n5105-a,n5105-b,n5105-recovery," \
  "ac-1 the menu order fixes slot a as entry 0 and slot b as entry 1"

# The override and the serial block both come after the last menuentry: GRUB stops
# reading the file at the first error, and the menu has to be complete by then.
last_entry=$(grep -nE '^menuentry ' "$good" | tail -n 1 | cut -d: -f1)
source_line=$(grep -nE '^[[:space:]]*source ' "$good" | head -n 1 | cut -d: -f1)
serial_line=$(grep -nE '^if serial ' "$good" | head -n 1 | cut -d: -f1)
assert_eq "$([ "${source_line}" -gt "${last_entry}" ] && echo after)" "after" \
  "ac-1 the runtime file is sourced after the menu entries"
assert_eq "$([ "${serial_line}" -gt "${last_entry}" ] && echo after)" "after" \
  "ac-1 the serial console is set up after the menu entries"

# ac-2 a concrete default entry is required
mutant_default="$tmp/default.cfg"
sed 's/^set default=0$/set default=/' "$good" >"$mutant_default"
check_file "$mutant_default"
assert_eq "$?" "1" "ac-2 an empty default entry is rejected"

mutant_token="$tmp/default-token.cfg"
sed 's/^set default=0$/set default=@COMMITTED_INDEX@/' "$good" >"$mutant_token"
check_file "$mutant_token"
assert_eq "$?" "1" "ac-2 a templated default entry is rejected"

# The static fallback has to be the committed entry. Pointing it at the other slot is
# the bug that let a truncated runtime file fall back to the slot that just failed:
# with committed=a the static fallback would say b, the runtime file's first line sets
# default=b, and nothing is left to fall back to.
mutant_otherfallback="$tmp/other-fallback.cfg"
awk '!done && $0 == "set fallback=0" { print "set fallback=1"; done = 1; next } { print }' \
  "$good" >"$mutant_otherfallback"
assert_contains "$(cat "$mutant_otherfallback")" "set default=0" \
  "ac-2 the mutant keeps a concrete default"
check_file "$mutant_otherfallback"
assert_eq "$?" "1" "ac-2 a static fallback on the other entry is rejected"

mutant_nofallback="$tmp/no-fallback.cfg"
sed 's/^set fallback=0$/set fallback=/' "$good" >"$mutant_nofallback"
check_file "$mutant_nofallback"
assert_eq "$?" "1" "ac-2 an empty fallback entry is rejected"

# A swapped menu order would silently move both slots to the wrong index.
mutant_order="$tmp/order.cfg"
python3 - "$good" "$mutant_order" <<'PYTHON'
import re
import sys

source, target = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
pattern = re.compile(
    r'(menuentry "N5105 AB slot a".*?\n\}\n)(\n*)'
    r'(menuentry "N5105 AB slot b".*?\n\}\n)',
    re.S,
)


def swap(match):
    return match.group(3) + match.group(2) + match.group(1)


swapped, count = pattern.subn(swap, text)
assert count == 1, count
open(target, "w", encoding="utf-8").write(swapped)
PYTHON
assert_contains "$(cat "$mutant_order")" 'menuentry "N5105 AB slot b"' \
  "ac-2 the mutant still has both entries"
assert_eq "$(grep -c '^menuentry ' "$mutant_order")" "3" "ac-2 the mutant keeps three entries"
check_file "$mutant_order"
assert_eq "$?" "1" "ac-2 a swapped menu order is rejected"

# ac-3 the menu must be complete before anything that can fail
mutant_sourcefirst="$tmp/source-first.cfg"
{
  printf 'if [ -f /boot/grub/ab-slot.cfg ]; then\n'
  printf '\tsource /boot/grub/ab-slot.cfg\n'
  printf 'fi\n'
  cat "$good"
} >"$mutant_sourcefirst"
check_file "$mutant_sourcefirst"
assert_eq "$?" "1" "ac-3 sourcing the runtime file before the menu is rejected"

mutant_unguarded="$tmp/unguarded.cfg"
sed 's|^if \[ -f /boot/grub/ab-slot.cfg \]; then$||' "$good" >"$mutant_unguarded"
check_file "$mutant_unguarded"
assert_eq "$?" "1" "ac-3 an unguarded source is rejected"

mutant_nosource="$tmp/no-source.cfg"
sed '/^if \[ -f \/boot\/grub\/ab-slot.cfg \]; then$/,/^fi$/d' "$good" >"$mutant_nosource"
check_file "$mutant_nosource"
assert_eq "$?" "1" "ac-3 a menu that never reads the runtime file is rejected"

# ac-4 no environment block machinery: this GRUB does not have it
for forbidden in load_env save_env grubenv; do
  mutant_env="$tmp/env-${forbidden}.cfg"
  { cat "$good"; printf '%s -f /boot/grub/grubenv ab_try\n' "${forbidden}"; } >"$mutant_env"
  check_file "$mutant_env"
  assert_eq "$?" "1" "ac-4 '${forbidden}' is rejected"
done

mutant_modprobe="$tmp/modprobe.cfg"
{ printf 'if [ -f /boot/grub/x86_64-efi/env.mod ]; then\n\ttrue\nfi\n'; cat "$good"; } \
  >"$mutant_modprobe"
check_file "$mutant_modprobe"
assert_eq "$?" "1" "ac-4 probing for a module file is rejected"

# ac-5 GRUB script is not bash, and placeholders must be replaced
mutant_and="$tmp/and.cfg"
{ cat "$good"; printf 'if [ -n "$ab_slot" ] && [ -n "$ab_slot" ]; then\n'; printf 'fi\n'; } \
  >"$mutant_and"
check_file "$mutant_and"
assert_eq "$?" "1" "ac-5 '&&' is rejected"

mutant_or="$tmp/or.cfg"
{ cat "$good"; printf 'if [ -z "$ab_slot" ] || [ -z "$ab_slot" ]; then\n'; printf 'fi\n'; } \
  >"$mutant_or"
check_file "$mutant_or"
assert_eq "$?" "1" "ac-5 '||' is rejected"

mutant_expand="$tmp/expand.cfg"
{ cat "$good"; printf 'set ab_slot=${ab_slot:-a}\n'; } >"$mutant_expand"
check_file "$mutant_expand"
assert_eq "$?" "1" "ac-5 '\${x:-y}' is rejected"

mutant_placeholder="$tmp/placeholder.cfg"
{ cat "$good"; printf 'set ab_placeholder=@UNREPLACED@\n'; } >"$mutant_placeholder"
check_file "$mutant_placeholder"
assert_eq "$?" "1" "ac-5 an unreplaced placeholder is rejected"

# ac-1 again: comments may mention the forbidden constructs without failing the check
mutant_comment="$tmp/comment.cfg"
{ printf '# never use && or || or ${x:-y} or load_env here\n'; cat "$good"; } >"$mutant_comment"
check_file "$mutant_comment"
assert_eq "$?" "0" "ac-1 comments are not treated as code"

# ac-3 the write-order contract, evaluated the way GRUB would: it runs the static
# lines, then sources the runtime file line by line. A file cut short must leave both
# entries on the committed slot.
resolve_menu() { # <cfg> [<runtime file>] -> "<default index> <fallback index>"
  local file="$1" frag="${2:-}"
  local default fallback line
  default="$(sed '/^[[:space:]]*#/d' "$file" | sed -n 's/^set default=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
  fallback="$(sed '/^[[:space:]]*#/d' "$file" | sed -n 's/^set fallback=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
  if [ -n "${frag}" ] && [ -f "${frag}" ]; then
    while IFS= read -r line; do
      case "${line}" in
        'set default='[0-9]*) default="${line#set default=}" ;;
        'set fallback='[0-9]*) fallback="${line#set fallback=}" ;;
      esac
    done <"${frag}"
  fi
  printf '%s %s' "${default}" "${fallback}"
}

full_frag="$tmp/pending-b.cfg"
printf 'set fallback=0\nset default=1\n' >"$full_frag"
assert_eq "$(resolve_menu "$good" "$full_frag")" "1 0" \
  "ac-3 a complete file tries slot b and falls back to the committed slot a"

cut_frag="$tmp/pending-b-truncated.cfg"
sed -n '1p' "$full_frag" >"$cut_frag"
assert_eq "$(resolve_menu "$good" "$cut_frag")" "0 0" \
  "ac-3 a file cut after its first line boots the committed slot and falls back to it"

assert_eq "$(resolve_menu "$good" "$tmp/no-runtime-file.cfg")" "0 0" \
  "ac-3 a missing runtime file boots the committed slot and falls back to it"

# ac-6 the committed slot is a build input, and the runtime file follows it
second="$tmp/grub-b/grub.cfg"
render_into "$second" b
assert_eq "$?" "0" "ac-6 the template renders for slot b"
second_body=$(cat "$second")
assert_contains "$second_body" "set default=1" "ac-6 slot b becomes the build-time default"
assert_contains "$second_body" "$(printf 'set default=1\nset fallback=1')" \
  "ac-6 the build-time fallback is the committed slot b too"
assert_eq "$(cat "$tmp/grub-b/ab-slot.cfg")" "$(printf 'set fallback=1\nset default=1')" \
  "ac-6 the runtime file names slot b as both fallback and default"
check_file "$second" "$tmp/grub-b/ab-slot.cfg"
assert_eq "$?" "0" "ac-6 the runtime file of the slot b image is valid"

assert_contains "$(cat "$tmp/render.log")" "ab_slot_cfg_path=" \
  "ac-6 the renderer reports the runtime file path for the image build"
assert_contains "$(cat "$tmp/render.log")" "ab_slot_cfg_slot=" \
  "ac-6 the renderer reports the slot it wrote"

finish
