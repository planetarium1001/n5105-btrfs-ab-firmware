#!/usr/bin/env bash
# Module: docs
# The two-stage first-boot growth has to be documented where a reader looks for the boot
# chain, in both languages and with the same vocabulary the code uses - otherwise the next
# person reads a promise (`blockdev --rereadpt` right after the write) that no longer exists.
#   ac-9 docs/boot-overlay.md and docs/boot-overlay.zh-CN.md describe the two boots, the whole
#        `.ab/grow` token set the initramfs now writes, the reboot as the partition-table
#        re-read, and the write-ahead breadcrumb; neither still lists a re-read tool as a step.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

en="docs/boot-overlay.md"
zh="docs/boot-overlay.zh-CN.md"
en_text="$(cat "$en")"
zh_text="$(cat "$zh")"

# --- the section exists in both, and they have not drifted apart --------------
assert_contains "${en_text}" "## First-boot growth of p4" \
  "ac-9 the English boot chain has a growth section"
assert_contains "${zh_text}" "## p4 首启扩容" \
  "ac-9 the Chinese boot chain has the same section"
assert_eq "$(printf '%s\n' "${en_text}" | grep -c '^## ')" \
  "$(printf '%s\n' "${zh_text}" | grep -c '^## ')" \
  "ac-9 both translations carry the same number of sections"

# --- two boots, not one ------------------------------------------------------
assert_contains "${en_text}" "two boots" \
  "ac-9 the English doc says the growth takes two boots"
assert_contains "${zh_text}" "两次启动" \
  "ac-9 the Chinese doc says the same"
for needle in "the boot that writes the table" "the boot after it" "every boot after that"; do
  assert_contains "${en_text}" "${needle}" "ac-9 the English doc names the stage: ${needle}"
done

# --- the reader is told the extra reboot is by design -----------------------
assert_contains "${en_text}" "reboots once by itself" \
  "ac-9 the English doc says the first boot reboots by itself"
assert_contains "${en_text}" "GRUB will be seen twice" \
  "ac-9 ... and that seeing GRUB twice is the design working"
assert_contains "${zh_text}" "GRUB 会出现两次" \
  "ac-9 the Chinese doc says the same"

# --- the reboot is the re-read, and no tool re-reads a table -----------------
assert_contains "${en_text}" "reboot is the re-read" \
  "ac-9 the English doc says the reboot is what makes the kernel re-read the table"
assert_contains "${en_text}" "asks the kernel to re-read a partition table any more" \
  "ac-9 ... and that the boot path no longer asks for it"
assert_contains "${zh_text}" "重启就是重读" \
  "ac-9 the Chinese doc says the same"
# The retired tools may still be named - explaining why the boot no longer calls them is the
# point - but they may not come back as a numbered step of the procedure.
en_steps="$(printf '%s\n' "${en_text}" | grep -E '^[0-9]+\. ')"
zh_steps="$(printf '%s\n' "${zh_text}" | grep -E '^[0-9]+\. ')"
for steps in "${en_steps}" "${zh_steps}"; do
  assert_eq "$(printf '%s\n' "${steps}" | grep -c 'rereadpt')" "0" \
    "ac-9 no numbered step asks the kernel to re-read the table"
  assert_eq "$(printf '%s\n' "${steps}" | grep -c 'partx')" "0" \
    "ac-9 no numbered step falls back to partx"
done
assert_contains "${en_text}" "used to run here" \
  "ac-9 the English doc still explains what was removed and why"
assert_contains "${zh_text}" "原来这一步" \
  "ac-9 the Chinese doc explains it too"
for text in "${en_text}" "${zh_text}"; do
  assert_eq "$(printf '%s\n' "${text}" | grep -c 'size-unchanged')" "0" \
    "ac-9 a retired failure token is no longer documented as a state"
done

# --- the token set the code writes ------------------------------------------
for token in table-write-pending table-written already-full done missing-sfdisk \
  fail:p4-still-mounted fail:table-write-not-verified fail:table-verify fail:table-write-lost; do
  assert_contains "${en_text}" "\`${token}\`" "ac-9 the English token table has ${token}"
  assert_contains "${zh_text}" "\`${token}\`" "ac-9 the Chinese token table has ${token}"
done

# --- the evidence of the boot that never reaches userspace ------------------
for needle in ".ab/grow.log" "partitions.before" "boot-1.log"; do
  assert_contains "${en_text}" "${needle}" \
    "ac-9 the English doc says where the evidence lands: ${needle}"
  assert_contains "${zh_text}" "${needle}" \
    "ac-9 the Chinese doc says the same: ${needle}"
done
assert_contains "${en_text}" "verify=unsupported" \
  "ac-9 the English doc names the sfdisk-without---verify case"
assert_contains "${zh_text}" "verify=unsupported" \
  "ac-9 the Chinese doc names it too"

finish
