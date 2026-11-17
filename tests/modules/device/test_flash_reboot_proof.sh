#!/usr/bin/env bash
# Module: device
# flash.sh must prove a reboot, not merely that port 22 answers.
#
# What this test exists for (measured 2026-11-17, task 20261117-03): the wait loop polled
# `nc -z host 22` and reported `flash=ok wait=7 boot=ok` on the first poll - while dd was
# still writing the disk and the old system was still answering. The device then came back
# on an older slot and every later measurement described an image that had never been
# written, including a login shell that died in profile.d.
#
# The invariant: the loop compares /proc/sys/kernel/random/boot_id before and after, and dd
# is not allowed to report into /dev/null.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

flash="$root/scripts/device/flash.sh"
assert_file_exists "$flash" "the flash driver exists"

# 1. The boot identity is recorded before the write and compared after it.
assert_matches "$(cat "$flash")" 'old_boot=\$\(dev_ssh .cat /proc/sys/kernel/random/boot_id' \
    "the boot id is read before the write"
assert_matches "$(cat "$flash")" '"\$boot" != "\$old_boot"' "the boot id is compared after it"
assert_matches "$(cat "$flash")" 'die boot-id-unreadable' "an unreadable boot id stops the flash"

# 2. A port answer alone is no longer a verdict: the success line has to carry the new id.
assert_matches "$(cat "$flash")" 'flash=ok wait=\$elapsed boot=ok saw_down=\$saw_down boot_id=\$boot' \
    "the verdict names the new boot id"
stale=$(grep -n 'say "flash=ok wait=\$elapsed boot=ok"' "$flash" || true)
assert_eq "$stale" "" "the port-only success line is gone"

# 3. dd's exit status is not thrown away.
assert_matches "$(cat "$flash")" 'echo dd rc=\\\$rc >/dev/console' "dd reports its status to the console"
