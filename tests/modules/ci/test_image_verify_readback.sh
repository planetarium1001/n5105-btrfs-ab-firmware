#!/usr/bin/env bash
# Module: ci
# Guards the partition-label read-back that image-verify does right after losetup.
#
# `losetup --find --show --partscan` creates the partition nodes before udev has filled in
# the GPT name, so a read-back taken at that instant sees an empty PARTLABEL. Measured on
# run 43553833091: `- p1: read-back PARTNAME '' != 'ab-esp'` while `sfdisk -J` on the same
# image read `ab-esp` correctly; the same commit passed S2 on a branch run.
#
#   ac-2  a field read is retried until it is there, and gives up after a bounded wait
#         instead of turning a race into a false verdict
#   ac-2  the read falls back from blkid to lsblk, which reads through udev
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/scripts/ci/lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A stub bin directory: `sudo` forwards to its arguments (the stage scripts only use it for
# privilege, which a test does not have and does not need), `blkid` answers empty until the
# counter says the device is ready, and `lsblk` is the udev fallback.
stub="$tmp/bin"
mkdir -p "$stub"
cat >"$stub/sudo" <<'SH'
#!/bin/sh
exec "$@"
SH
cat >"$stub/blkid" <<'SH'
#!/bin/sh
count_file="${STUB_COUNTER:?}"
ready_at="${STUB_READY_AT:-1}"
count=$(cat "${count_file}" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "${count}" >"${count_file}"
[ "${count}" -ge "${ready_at}" ] || exit 0
printf 'ab-esp\n'
SH
cat >"$stub/lsblk" <<'SH'
#!/bin/sh
[ "${STUB_LSBLK_EMPTY:-0}" = "1" ] && exit 0
printf 'ab-esp   \n'
SH
chmod 0755 "$stub/sudo" "$stub/blkid" "$stub/lsblk"

# part_field <ready-at> <counter>: ci_part_field through the stubs.
part_field() {
  local ready_at="$1" counter="$2"
  PATH="$stub:$PATH" STUB_COUNTER="$counter" STUB_READY_AT="$ready_at" \
    bash -c '. "$1" >/dev/null 2>&1; ci_part_field /dev/loop-test PARTLABEL' _ "$lib" 2>/dev/null
}

# wait_field <attempts> <interval> <ready-at> <counter>: ci_wait_part_field through the
# stubs. The lsblk stub stays silent here: these cases are about blkid becoming readable,
# and a chatty fallback would make every one of them pass on the first attempt.
wait_field() {
  local attempts="$1" interval="$2" ready_at="$3" counter="$4"
  PATH="$stub:$PATH" STUB_COUNTER="$counter" STUB_READY_AT="$ready_at" STUB_LSBLK_EMPTY=1 \
    bash -c '. "$1" >/dev/null 2>&1; ci_wait_part_field /dev/loop-test PARTLABEL "$2" "$3"' \
    _ "$lib" "$attempts" "$interval" 2>/dev/null
}

# --- ac-2: a read that is not ready yet is retried, not judged --------------------------
wait_field 40 0.01 3 "$tmp/counter-a"
assert_eq "$?" "0" "ac-2 the wait succeeds once the label shows up"
assert_eq "$(cat "$tmp/counter-a")" "3" "ac-2 it retried exactly until the label appeared"

# A bounded wait has to end: an empty device must fail rather than loop forever.
wait_field 3 0.01 999 "$tmp/counter-b"
assert_eq "$?" "1" "ac-2 the wait gives up after its attempts instead of hanging"
assert_eq "$(cat "$tmp/counter-b")" "3" "ac-2 it stops at the attempt count"

# The first read of a ready device costs one attempt, not a full wait.
wait_field 40 0.01 1 "$tmp/counter-c"
assert_eq "$?" "0" "ac-2 a ready device passes on the first attempt"
assert_eq "$(cat "$tmp/counter-c")" "1" "ac-2 it did not sleep on a ready device"

# --- ac-2: the reader itself -----------------------------------------------------------
assert_eq "$(part_field 1 "$tmp/counter-d")" "ab-esp" "ac-2 the field is read back"
assert_eq "$(PATH="$stub:$PATH" STUB_COUNTER="$tmp/counter-e" STUB_READY_AT=999 STUB_LSBLK_EMPTY=0 \
  bash -c '. "$1" >/dev/null 2>&1; ci_part_field /dev/loop-test PARTLABEL' _ "$lib" 2>/dev/null)" \
  "ab-esp" "ac-2 lsblk covers a blkid that cannot read the label"
assert_eq "$(PATH="$stub:$PATH" STUB_COUNTER="$tmp/counter-f" STUB_READY_AT=999 STUB_LSBLK_EMPTY=1 \
  bash -c '. "$1" >/dev/null 2>&1; ci_part_field /dev/loop-test PARTLABEL' _ "$lib" 2>/dev/null)" \
  "" "ac-2 a field nobody can read is empty, not an error"

# --- ac-2: image-verify waits before it judges -----------------------------------------
verify_script="$(cat scripts/ci/image-verify.sh)"
assert_contains "$verify_script" "ci_wait_part_field" \
  "ac-2 image-verify waits for the partition labels before reading them"
assert_contains "$verify_script" "part-label-timeout" \
  "ac-2 a label that never appears is named as such, not reported as a missing initramfs"

finish
