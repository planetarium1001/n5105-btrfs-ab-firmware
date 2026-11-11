#!/usr/bin/env bash
# Module: docs
# ac-3: the negative constraint holds - no device-side shrink design has crept back in.
#       `ab/grow-request`, `ab/compact-request` and `shrink-too-tight` are the three
#       spellings such a design would start with (a request file on the ESP, the tool that
#       would answer it, and the failure it would report), and none of them may appear in
#       initramfs/, platform/ or docs/.
#
# The rule exists because the only scenario that asks for shrinking - a smaller disk - is
# unreachable from inside the device: with no partition table there is no GRUB, so no code
# of ours runs. See docs/backup.md section 2.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

# --- the three spellings, per tree ----------------------------------------
for needle in "ab/grow-request" "ab/compact-request" "shrink-too-tight"; do
  for tree in initramfs platform docs; do
    hits="$(grep -rIl --exclude-dir=.git -F "$needle" "$tree" 2>/dev/null)"
    assert_eq "$hits" "" "ac-3 $needle does not appear in $tree/"
  done
done

# --- and the tools the design would have needed are not shipped -----------
for tool in "ab-slot compact" "ab-slot shrink"; do
  hits="$(grep -rIl --exclude-dir=.git -F "$tool" platform docs 2>/dev/null)"
  assert_eq "$hits" "" "ac-3 no device-side command: $tool"
done

# --- the document that replaces the design states the reason --------------
assert_contains "$(cat docs/backup.md)" "GRUB is not loaded" \
  "ac-3 the contract records why a device-side shrink is unreachable"
assert_contains "$(cat docs/backup.zh-CN.md)" "设备端任何代码都不会运行" \
  "ac-3 中文契约同样记录设备端不可达"

finish
