#!/usr/bin/env bash
# Module: boot
# The cross-boot probe assertion in S3 must read the *previous* boot's file, not its own.
#
# What this test exists for (CI run 44114636248, 2026-11-17): the initramfs writes the probe
# file before the root switch, so with a single shared name (`/.s3-probe`) it overwrites the
# previous boot's evidence before post.sh can look at it. post.sh then compared this boot's
# content against "boot=1" and failed. The reason it had never failed before was worse: the
# boot label was pinned to 1 by a /proc/cmdline read that ran before /proc was mounted, so
# both boots wrote "boot=1" and the check compared a value against itself.
#
# The invariant: one probe file per boot, and the boot=2 assertion opens the boot=1 file.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

init="$root/initramfs/boot/init"
post="$root/initramfs/boot/post.sh"
assert_file_exists "$init" "the boot init exists"
assert_file_exists "$post" "the post-switch assertion exists"

# 1. The probe name carries the boot label, so a boot cannot overwrite the previous one.
assert_matches "$(cat "$init")" 'probe="/\.s3-probe-\$\{BOOT\}"' "boot/init names the probe per boot"
assert_matches "$(cat "$post")" 'probe="/\.s3-probe-\$\{boot\}"' "post.sh names the probe per boot"

# 2. The boot=2 check reads the previous boot's file, in both scripts.
assert_matches "$(cat "$init")" 'previous="/\.s3-probe-\$\(\(BOOT - 1\)\)"' "boot/init derives the previous probe"
assert_matches "$(cat "$init")" '\[ -f "/newroot\$\{previous\}" \]' "boot/init checks the previous probe exists"
assert_matches "$(cat "$post")" 'previous="/\.s3-probe-\$\(\(boot - 1\)\)"' "post.sh derives the previous probe"
assert_matches "$(cat "$post")" '\[ -f "\$\{previous\}" \]' "post.sh checks the previous probe exists"

# 3. Nothing may go back to the bare name for the cross-boot check: a `/.s3-probe` literal
#    without a boot suffix in either script is the shape that made the assertion vacuous.
bare=$(grep -n '/\.s3-probe"' "$init" "$post" 2>/dev/null || true)
assert_eq "$bare" "" "neither script uses the unsuffixed probe name"

# 4. The command line is read after /proc is mounted, in the boot init. Reading it earlier
#    returns nothing and pins every boot to label 1 (this is what hid the bug).
proc_mount=$(grep -n 'mount -t proc proc /proc' "$init" | head -n 1 | cut -d: -f1)
cmdline=$(grep -n 'for arg in \$(cat /proc/cmdline)' "$init" | head -n 1 | cut -d: -f1)
assert_matches "$proc_mount" '^[0-9]+$' "boot/init mounts /proc"
assert_matches "$cmdline" '^[0-9]+$' "boot/init reads the command line"
[ "$cmdline" -gt "$proc_mount" ] && verdict=after || verdict=before
assert_eq "$verdict" "after" "the command line is read after /proc is mounted"
