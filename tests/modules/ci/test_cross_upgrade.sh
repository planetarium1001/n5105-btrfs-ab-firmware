#!/usr/bin/env bash
# Module: ci
# The cross-version upgrade verdict, graded from facts alone.
#
# The QEMU half of scripts/ci/cross-upgrade.sh cannot run here, but the half that decides
# whether a run passed is pure file reading, and that is the half that has to be right:
# a stage that reports ok on the wrong facts is worse than one that never runs.
#
#   ac-3  a good upgrade: pending -> committed, generation advanced, packages aligned,
#         ESP kernel/initrd byte-identical to the payload's
#   ac-4  an injected failure: the candidate is abandoned and the machine returns
#   ac-5  no previous release: skipped, with the reason spelled out
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

script="$root/scripts/ci/cross-upgrade.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grade() { bash "$script" assert --out "$1" 2>&1; }

# write_case <dir> <kernel-esp> <kernel-payload> <initrd-esp> <initrd-payload> [serial]
write_case() {
  local dir=$1 kesp=$2 kpay=$3 iesp=$4 ipay=$5 serial=${6:-"stage=commit slot=b result=ok"}
  mkdir -p "$dir"
  printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a\n' >"$dir/status.before"
  printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=b next=b\n' >"$dir/status.after"
  printf 'slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=aligned\n' >"$dir/status.committed"
  printf '%s  vmlinuz-b\n%s  initrd-b\n' "$kesp" "$iesp" >"$dir/esp.sha256"
  printf '%s  kernel.bin\n%s  initramfs.cpio.gz\n' "$kpay" "$ipay" >"$dir/payload.sha256"
  printf '%s\n' "$serial" >"$dir/serial.log"
}

# --- ac-3: the success path ------------------------------------------------
good="$tmp/good"
write_case "$good" aaaa aaaa cccc cccc
assert_contains "$(grade "$good")" "cross-upgrade=ok" "ac-3 a good upgrade is ok"
assert_contains "$(grade "$good")" "slot=b" "ac-3 the verdict names the slot that was committed"

mismatch="$tmp/mismatch"
write_case "$mismatch" aaaa ffff cccc cccc
assert_contains "$(grade "$mismatch")" "kernel-on-esp-is-not-the-payload-kernel" \
  "ac-3 a kernel that is not the payload's kernel is a failure"

initrd="$tmp/initrd"
write_case "$initrd" aaaa aaaa cccc eeee
assert_contains "$(grade "$initrd")" "initrd-on-esp-is-not-the-payload-initrd" \
  "ac-3 an initrd that is not the payload's initrd is a failure"

nocommit="$tmp/nocommit"
write_case "$nocommit" aaaa aaaa cccc cccc "stage=upgrade result=ok"
assert_contains "$(grade "$nocommit")" "commit-not-recorded-in-serial" \
  "ac-3 a boot that never recorded the commit is a failure"

notaligned="$tmp/notaligned"
write_case "$notaligned" aaaa aaaa cccc cccc
printf 'slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=limited\n' \
  >"$notaligned/status.committed"
assert_contains "$(grade "$notaligned")" "packages-not-aligned-after-commit" \
  "ac-3 a slot that cannot install its own kernel's modules is a failure"

stuck="$tmp/stuck"
write_case "$stuck" aaaa aaaa cccc cccc
printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a\n' >"$stuck/status.after"
assert_contains "$(grade "$stuck")" "pending-already-none" \
  "ac-3 an install that left nothing pending is a failure"

# --- ac-4: the injected failure -------------------------------------------
inject="$tmp/inject"
write_case "$inject" aaaa aaaa cccc cccc "stage=abandon slot=b result=fail action=reboot-to-committed"
printf 'unhealthy\n' >"$inject/inject"
# The abandon leaves the previous slot committed and nothing pending.
printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a packages=aligned\n' \
  >"$inject/status.committed"
assert_contains "$(grade "$inject")" "cross-upgrade=ok inject=unhealthy returned=a" \
  "ac-4 an abandoned candidate that returned to the previous slot is a good run"

noabandon="$tmp/noabandon"
write_case "$noabandon" aaaa aaaa cccc cccc "stage=commit slot=b result=ok"
printf 'unhealthy\n' >"$noabandon/inject"
assert_contains "$(grade "$noabandon")" "abandon-not-recorded" \
  "ac-4 an injected failure that was not abandoned is a failure"

# --- ac-5: nothing to upgrade from ---------------------------------------
skip="$tmp/skip"
mkdir -p "$skip"
printf 'no-previous-formal-release gaps=3\n' >"$skip/skip"
assert_contains "$(grade "$skip")" "cross-upgrade=skipped" "ac-5 a missing previous release is skipped"
assert_contains "$(grade "$skip")" "gaps=3" "ac-5 the skip names the gap"

finish
