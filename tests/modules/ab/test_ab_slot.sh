#!/usr/bin/env bash
# Module: ab
# Verifies the slot state machine in platform/usr/sbin/ab-slot without root and
# without btrfs: the ESP is a temporary directory and btrfs comes from a stub, which
# is enough because every rule that matters here is about the state file and the
# environment block that decides which slot GRUB boots.
#   ac-1 status reports the running slot, the committed slot, the pending slot and
#        the three mount points of the writable partition
#   ac-2 commit and abandon change the state atomically and keep the layer names
#   ac-3 pending refuses a slot whose payload is not on the ESP
#   ac-4 rollback swaps the committed slot
#   ac-5 gc keeps every referenced layer and reaps the rest, honouring --dry-run
#   ac-6 the retired upper_gen field is gone and a stale state file is refused
#   ac-7 the four commands keep the runtime slot file in step with the state file, and
#        a refused command leaves that file untouched
#   ac-8 `next` reads the file back and `--write` heals it from the state file
#   ac-9 status appends the initramfs' ESP verdict as `esp=`, read from this boot's ring log
#        (boot= and esp= are the two fields a machine cannot claim without evidence)
#   (20261116-06) ac-5 a boot-path commit re-judges the package record it publishes for the
#        slot it commits, so `status` never answers `reason=other-slot` for ever after
#   (20261117) ac-9 the lock path tells "another writer holds it" apart from "the ESP cannot
#        create the lock at all", and waits briefly for a live holder instead of refusing
#        on sight
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_slot="$root/platform/usr/sbin/ab-slot"
slot_cfg_lib="$root/platform/lib/ab-slot-cfg.sh"
partitions_lib="$root/platform/lib/ab-partitions.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a fake ESP, a fake mount table and a fake kernel command line ----------
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/boot/grub"
write_state() { # <committed> <pending|none> <gen>
  if [ "$2" = "none" ]; then pending=null; else pending="\"$2\""; fi
  cat >"$esp/ab/state.json" <<JSON
{
  "generation": $3,
  "committed": "$1",
  "pending": $pending,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
}
cmdline="$tmp/cmdline"
# The boot id decides whether a lock left on the ESP can still have a live owner. Fixed
# here so the lock tests describe a machine rather than depend on the test host.
boot_id_file="$tmp/boot_id"
printf 'boot-1111-2222-3333\n' >"$boot_id_file"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# The disk identity the production library would resolve. The stub answers with the
# documented interface (di_resolve -> "disk=<dev> method=<token>"), so status is tested
# against what it is supposed to consume, not against a second resolver.
stub_di="$tmp/disk-identity.sh"
cat >"$stub_di" <<'STUB'
#!/bin/sh
di_resolve() {
  printf 'disk=%s method=%s\n' "${STUB_DISK:-/dev/sda}" "${STUB_METHOD:-partuuid}"
}
di_parent_disk() {
  printf '%s\n' "$1"
}
STUB

# The writable partition mount point this test pretends to have; ab-slot reads it back
# from the mount table, so the table and AB_P4 have to name the same path.
fake_p4="$tmp/p4"
mkdir -p "$fake_p4"

# p4 mounted, the three data mounts not: the state before the platform layer mounts
# @data, @docker and @swap.
mounts_partial="$tmp/mounts-partial"
cat >"$mounts_partial" <<MOUNTS
/dev/vda1 /boot vfat rw,noatime 0 0
/dev/vda4 ${fake_p4} btrfs rw,noatime 0 0
MOUNTS
# everything mounted, in the documented order
mounts_full="$tmp/mounts-full"
cat >"$mounts_full" <<MOUNTS
/dev/vda1 /boot vfat rw,noatime 0 0
/dev/vda4 ${fake_p4} btrfs rw,noatime 0 0
/dev/vda4 /data btrfs rw,noatime 0 0
/dev/vda4 /opt/docker btrfs rw,noatime,nodatacow 0 0
/dev/vda4 /swap btrfs rw,noatime,nodatacow 0 0
MOUNTS

slot_cmd() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" \
    AB_MOUNTS="${mounts_partial}" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" \
    AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" \
    AB_BOOT_ID_FILE="$boot_id_file" \
    AB_LOCK_WAIT_SECS="${AB_LOCK_WAIT_SECS:-1}" \
    AB_LOCK_WAIT_STEP="${AB_LOCK_WAIT_STEP:-0.1}" \
    sh "$ab_slot" "$@"
}

# slot_cmd_full: the same call, with every documented mount point present.
slot_cmd_full() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" \
    AB_MOUNTS="${mounts_full}" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" \
    AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" \
    AB_BOOT_ID_FILE="$boot_id_file" \
    AB_LOCK_WAIT_SECS="${AB_LOCK_WAIT_SECS:-1}" \
    AB_LOCK_WAIT_STEP="${AB_LOCK_WAIT_STEP:-0.1}" \
    sh "$ab_slot" "$@"
}

# next_slot: the slot the boot chain would pick next, read from the runtime file.
next_slot() {
  sh -c ". '$slot_cfg_lib'; ab_slot_cfg_get '$esp/boot/grub/ab-slot.cfg'"
}

# Payload for both slots, so pending checks pass by default.
: >"$esp/vmlinuz-a"; : >"$esp/initrd-a"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

# --- ac-1 status ------------------------------------------------------------
write_state a none 1
# The image ships the runtime file pointing at the committed slot; recreate it.
slot_cmd next --write >/dev/null 2>&1
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$status" \
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown packages=unknown packages_reason=unknown" \
  "ac-1 status line reports the documented fields"

status="$(slot_cmd_full status 2>/dev/null)"
assert_eq "$status" \
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown packages=unknown packages_reason=unknown" \
  "ac-1 status reports the three mount points of the writable partition"

# Without the identity library the status line says so instead of inventing a device.
status="$(AB_DISK_IDENTITY_LIB=/nonexistent/disk-identity.sh \
  AB_PARTITIONS_LIB="$partitions_lib" AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" \
  AB_MOUNTS="$mounts_partial" AB_SLOT_CFG_LIB="$slot_cfg_lib" sh "$ab_slot" status 2>/dev/null)"
assert_contains "$status" "disk=unknown method=unavailable" \
  "ac-1 status says the disk is unknown when the identity library is missing"

printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
write_state a a 2
slot_cmd next --write >/dev/null 2>&1
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$status" \
  "slot=b upper=@overlay-25.12.2 generation=2 committed=a pending=a p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown packages=unknown packages_reason=unknown" \
  "ac-1 status follows ab.slot= on the kernel command line"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# --- ac-9 the ESP verdict the initramfs left for the running system ----------
# The initramfs judges the ESP before it mounts it and records the verdict on p4; ab-boot
# republishes it as one `stage=esp-health` line in the ring log, and this field is that
# line. It is appended after boot= on purpose: platform/lib/upgrade/platform.sh and every
# other reader pick their fields out by pattern, and the human summary stays where it was.
esp_field() { printf '%s' "$1" | sed -n 's/.* esp=\([a-z]*\).*/\1/p'; }

rm -f "$esp/ab/log/boot-0.log"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(esp_field "$status")" "unknown" \
  "ac-9 without a ring log the ESP verdict is unknown, never ok"
assert_matches "$status" 'boot=unknown esp=unknown packages=unknown packages_reason=unknown$' \
  "ac-9 the esp= field is appended after boot=, and the package fields after it"

cat >"$esp/ab/log/boot-0.log" <<'LOG'
stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok
stage=esp-health slot=a esp=dirty boot=1 sig=ok dirty_bit=1 fsinfo=ok mount=rw
LOG
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(esp_field "$status")" "dirty" \
  "ac-9 the verdict ab-boot republished is what status reports"
assert_contains "$status" "boot=ok esp=dirty" \
  "ac-9 both fields are read from this boot's ring log"

# Only the documented tokens are sent on: a boot that could not judge the ESP recorded that
# it could not, and a report that turned that into an "ok" would be the silent healthy
# machine this field exists to catch.
printf 'stage=esp-health slot=a esp=unrecorded\n' >"$esp/ab/log/boot-0.log"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(esp_field "$status")" "unknown" \
  "ac-9 an unrecognised token is reported as unknown"

# --- ac-10 the package alignment verdict ------------------------------------
# Whether the slot can install packages matched to the kernel it runs is a fact the last
# upgrade recorded; status reports it and refuses to claim it without evidence.
pkg_field() { printf '%s' "$1" | sed -n 's/.* packages=\([a-z]*\) .*/\1/p'; }
pkg_reason_field() { printf '%s' "$1" | sed -n 's/.* packages_reason=\([a-z-]*\).*/\1/p'; }
write_state a none 1
rm -f "$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "unknown" \
  "ac-10 without a record the package state is unknown, never aligned"
assert_eq "$(pkg_reason_field "$status")" "unknown" \
  "ac-10 and the reason is unknown too"

printf 'packages=aligned reason=none version=25.12.3 kernel=kernel=6.12.103~abc-r1\n' >"$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "aligned" "ac-10 an aligned record is reported as aligned"
assert_eq "$(pkg_reason_field "$status")" "none" "ac-10 an aligned record has no reason"
assert_contains "$(slot_cmd status 2>&1)" "packages matched to this kernel" \
  "ac-10 the human line says what aligned means"

printf 'packages=limited reason=kernel-unknown version=25.12.3 kernel=unknown\n' >"$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "limited" "ac-10 a limited record is reported as limited"
assert_eq "$(pkg_reason_field "$status")" "kernel-unknown" \
  "ac-10 the reason travels with the state so it can be acted on"
assert_contains "$(slot_cmd status 2>&1)" "package metadata is limited" \
  "ac-10 the human line explains the consequence"

# The record describes the slot an upgrade was aiming at. While the old slot still runs,
# that verdict says nothing about this boot.
printf 'packages=aligned reason=none version=25.12.4 kernel=kernel=6.12.87~abc-r1 slot=b\n' >"$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "unknown" \
  "ac-10 a verdict for the other slot is not reported as this slot's state"
assert_eq "$(pkg_reason_field "$status")" "other-slot" \
  "ac-10 and the reason says why"
printf 'packages=aligned reason=none version=25.12.4 kernel=kernel=6.12.87~abc-r1 slot=a\n' >"$esp/ab/packages"
assert_eq "$(pkg_field "$(slot_cmd status 2>/dev/null)")" "aligned" \
  "ac-10 a verdict for the running slot is reported"

# A record written by something else - or cut short - is not a verdict.
printf 'packages=maybe reason=none\n' >"$esp/ab/packages"
assert_eq "$(pkg_field "$(slot_cmd status 2>/dev/null)")" "unknown" \
  "ac-10 an unrecognised state reads as unknown"

# --- ac-16 the packages verdict after a rollback -----------------------------
# The record names one slot. A rollback changes which slot this machine is committed to,
# so the record has to be re-judged for the target: leaving the old line behind is what
# made `status` answer `unknown reason=other-slot` for ever after a rollback.
write_state a none 1
printf 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.87~abc-r1 slot=b\n' >"$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_reason_field "$status")" "other-slot" \
  "ac-16 before the rollback the record describes the slot that is not running"
slot_cmd rollback >/dev/null 2>&1
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "aligned" \
  "ac-16 after the rollback the verdict for the target slot is what is reported"
assert_eq "$(pkg_reason_field "$status")" "none" "ac-16 the reason is the recorded one, not other-slot"
assert_contains "$(cat "$esp/ab/packages")" "slot=b" \
  "ac-16 the record names the slot it describes after the rollback"
assert_contains "$(cat "$esp/ab/packages")" "kernel=kernel=6.12.87~abc-r1" \
  "ac-16 the rewrite keeps the fields the aligner published"

# A record that only ever described the slot we rolled away from says nothing about the
# target; that is a no-record we can prove, never a placeholder.
write_state a none 1
printf 'packages=limited reason=kernel-unknown version=25.12.2 kernel=unknown slot=a\n' >"$esp/ab/packages"
out="$(slot_cmd rollback 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-16 the rollback itself succeeds"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "unknown" "ac-16 a target with no verdict is unknown"
assert_eq "$(pkg_reason_field "$status")" "no-record" \
  "ac-16 and the reason is a provable no-record, never other-slot"
assert_contains "$out" "packages unknown for slot b" \
  "ac-16 the rewrite is reported"
assert_contains "$(cat "$esp/ab/packages")" "packages=unknown reason=no-record slot=b" \
  "ac-16 the record is rewritten for the target slot"
assert_eq "$(grep -c 'other-slot' "$esp/ab/packages" || true)" "0" \
  "ac-16 nothing in the record says other-slot"

# --- (20261116-06) ac-5: the packages verdict after a boot-path commit -------
# `ab-commit` commits the slot it just booted. The record is written for the slot an upgrade
# was aiming at, so a commit that lands on a slot the record does not name - the candidate's
# own first boot, an upgrade that was abandoned, a record published before the swap - leaves
# the record describing the slot this machine has just left behind. `status` then answers
# `packages=unknown reason=other-slot`, and nothing ever re-judges it: the same defect the
# rollback path had before `cmd_rollback` started calling `packages_record_retarget`.
write_state a b 1
printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
printf 'packages=aligned reason=none version=25.12.3 kernel=kernel=6.12.103~abc-r1 slot=a\n' \
  >"$esp/ab/packages"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_reason_field "$status")" "none" \
  "ac-5 before the commit the record still describes the committed slot"
out="$(slot_cmd commit 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-5 committing the booted candidate succeeds"
assert_contains "$out" "packages unknown for slot b" \
  "ac-5 the commit re-judges the record for the slot it lands on"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "unknown" \
  "ac-5 the old slot's verdict is not reported as the new slot's state"
assert_eq "$(pkg_reason_field "$status")" "no-record" \
  "ac-5 and the reason is a provable no-record, never other-slot"
assert_contains "$(cat "$esp/ab/packages")" "slot=b" \
  "ac-5 the record names the slot the commit landed on"
assert_eq "$(grep -c 'other-slot' "$esp/ab/packages" || true)" "0" \
  "ac-5 nothing in the record says other-slot"

# A commit that lands while another slot is still pending must not destroy that candidate's
# verdict. The record may be describing the candidate (the aligner wrote it while laying the
# candidate down), and the aligner does not run again on boot: rewriting the record here would
# trade one permanent `unknown` for another. The candidate's `other-slot` answer is correct -
# the record does not describe this boot - and stays readable for the boot that follows.
write_state a b 1
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"
printf 'packages=aligned reason=none version=25.12.3 kernel=kernel=6.12.103~abc-r1 slot=b\n' \
  >"$esp/ab/packages"
out="$(slot_cmd commit 2>&1)"
assert_eq "$?" "0" "ac-5 a commit with a candidate still pending succeeds"
assert_contains "$(cat "$esp/ab/packages")" "slot=b" \
  "ac-5 the pending candidate's verdict is left where it is"
assert_contains "$(cat "$esp/ab/packages")" "packages=aligned" \
  "ac-5 and it is not downgraded to no-record"

# A record that already names the target is the aligner's own verdict for exactly that
# layer, so the commit keeps it as it stands: the call re-judges, it does not reset.
write_state a none 1
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"
printf 'packages=limited reason=kernel-unknown version=25.12.3 kernel=unknown slot=a\n' \
  >"$esp/ab/packages"
record_before="$(cat "$esp/ab/packages")"
slot_cmd commit >/dev/null 2>&1
assert_eq "$(cat "$esp/ab/packages")" "$record_before" \
  "ac-5 a record that already describes the committed slot is left as it stands"
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$(pkg_field "$status")" "limited" \
  "ac-5 the verdict for the committed slot is still what is reported"
assert_eq "$(pkg_reason_field "$status")" "kernel-unknown" \
  "ac-5 with the reason the aligner published"

# --- ac-10 the binary can name its own version ------------------------------
# The identity lives in /etc/platform-release (AB_RELEASE_FILE points the test at a copy),
# and the question has to be answerable before any slot state is read, any lock is taken
# or the ESP is touched: a machine whose slots are a mess can still say what it is.
release_file="$tmp/platform-release"
printf 'PLATFORM_VERSION=0.0.9\nUPSTREAM_VERSION=25.12.2\nPLATFORM_STAGE=stable\n' >"$release_file"
identity_expected="PLATFORM_VERSION=0.0.9
UPSTREAM_VERSION=25.12.2
PLATFORM_STAGE=stable"

absent_esp="$tmp/esp-absent"
out="$(AB_RELEASE_FILE="$release_file" AB_ESP="$absent_esp" AB_CMD="$tmp/no-cmdline" \
  sh "$ab_slot" --version 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-10 --version succeeds without any slot state"
assert_eq "$out" "$identity_expected" "ac-10 --version prints the three identity lines"
out="$(AB_RELEASE_FILE="$release_file" AB_ESP="$absent_esp" AB_CMD="$tmp/no-cmdline" \
  sh "$ab_slot" -V 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-10 -V is the same question"
assert_eq "$out" "$identity_expected" "ac-10 -V prints the same identity"
assert_eq "$([ -e "$absent_esp" ] && printf exists || printf absent)" "absent" \
  "ac-10 --version does not create or touch the ESP mount point"

# A machine without a release file still answers, with unknown: not being able to name the
# version is a fact about the machine, not an error of the question.
out="$(AB_RELEASE_FILE="$tmp/no-such-release" AB_ESP="$absent_esp" AB_CMD="$tmp/no-cmdline" \
  sh "$ab_slot" --version 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-10 a missing release file is not an error"
assert_eq "$out" "PLATFORM_VERSION=unknown
UPSTREAM_VERSION=unknown
PLATFORM_STAGE=unknown" "ac-10 a missing release file prints unknown three times"

# Neither an unreadable state file nor a live lock stands between the operator and the
# version: --version is dispatched before the state is touched at all.
locked_esp="$tmp/esp-locked"
mkdir -p "$locked_esp/ab/.lock"
printf 'this is not the state file\n' >"$locked_esp/ab/state.json"
printf '%s %s %s\n' "$(cat "$boot_id_file")" "$$" "2026-01-01T00:00:00Z" \
  >"$locked_esp/ab/.lock/owner"
out="$(AB_RELEASE_FILE="$release_file" AB_ESP="$locked_esp" AB_CMD="$cmdline" \
  AB_BOOT_ID_FILE="$boot_id_file" sh "$ab_slot" --version 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-10 --version answers while the state is unreadable and locked"
assert_eq "$out" "$identity_expected" "ac-10 and it prints the identity, not a state error"
assert_eq "$([ -d "$locked_esp/ab/.lock" ] && printf kept || printf gone)" "kept" \
  "ac-10 --version does not take the state lock"

# Unit 03 renders the same three lines for ab-upgrade through this one helper, so the
# function name and its output shape are a contract.
identity_lib_out="$(AB_RELEASE_FILE="$release_file" sh -c \
  '. "$1"; ab_version_identity' sh "$root/platform/lib/ab-version.sh" 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-10 the shared helper runs on its own"
assert_eq "$identity_lib_out" "$identity_expected" \
  "ac-10 the shared helper prints the same three lines ab-slot prints"

# --- ac-2 commit and abandon ------------------------------------------------
write_state a a 2
slot_cmd commit >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-2 commit sets the committed slot"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' "ac-2 commit clears pending"
# Committing the running slot must not erase a marker for the other slot: that marker
# is a staged upgrade waiting for the next boot.
write_state a b 2
slot_cmd commit >/dev/null 2>&1
assert_eq "$?" "0" "ac-2 committing while the other slot is pending succeeds"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": "b"' \
  "ac-2 commit keeps a pending marker for the other slot"
assert_contains "$(cat "$esp/ab/state.json")" '"upper": "@overlay-25.12.3"' \
  "ac-2 commit keeps the layer names"
assert_contains "$(cat "$esp/ab/state.json")" '"generation": 2' "ac-2 commit keeps the generation"

write_state a b 2
slot_cmd abandon >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' "ac-2 abandon clears pending"
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-2 abandon leaves committed alone"

# A freshly armed candidate is a fresh try. The attempt counter and the interruption record
# belong to the campaign that just ended, so arming a slot clears them; otherwise a slot
# re-armed after an interrupted boot would inherit its count and could be abandoned on its
# first boot.
printf 'b 2026-11-14T21:00:00Z 2\n' >"$esp/ab/candidate"
printf 'slot=b attempt=2 last=2026-11-14T20:00:00Z result=retry\n' >"$esp/ab/interrupted"
write_state a none 2
slot_cmd pending b >/dev/null 2>&1
assert_eq "$([ -f "$esp/ab/candidate" ] && printf kept || printf gone)" "gone" \
  "ac-5 arming a candidate clears the previous attempt counter"
assert_eq "$([ -f "$esp/ab/interrupted" ] && printf kept || printf gone)" "gone" \
  "ac-5 arming a candidate clears the previous interruption record"

# no temporary file is left behind
assert_eq "$(find "$esp/ab" -name 'state.json.tmp.*' | wc -l | tr -d ' ')" "0" \
  "ac-2 the atomic write leaves no temporary file"

# --- ac-3 pending validation ------------------------------------------------
write_state a none 1
slot_cmd pending b >/dev/null 2>&1
assert_eq "$?" "0" "ac-3 pending accepts a slot whose payload is present"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": "b"' "ac-3 pending records the slot"

rm -f "$esp/vmlinuz-b" "$esp/initrd-b"
write_state a none 1
slot_cmd pending b >/dev/null 2>&1
assert_eq "$?" "1" "ac-3 pending refuses a slot without payload"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' \
  "ac-3 a refused pending leaves the state untouched"

slot_cmd pending c >/dev/null 2>&1
assert_eq "$?" "1" "ac-3 pending refuses an invalid slot name"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

# --- ac-4 rollback ----------------------------------------------------------
write_state a none 1
slot_cmd rollback >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "b"' "ac-4 rollback switches to the other slot"
slot_cmd rollback >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-4 rollback is symmetric"

# --- ac-7 the runtime file follows the state ----------------------------------------
write_state a none 1
rm -f "$esp/boot/grub/ab-slot.cfg"
slot_cmd pending b >/dev/null 2>&1
assert_eq "$(next_slot)" "b" "ac-7 pending points the next boot at the candidate"

slot_cmd commit b >/dev/null 2>&1
assert_eq "$(next_slot)" "b" "ac-7 committing the slot we booted keeps the next boot on it"
assert_eq "$(next_slot)" "$(sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "$esp/ab/state.json")" \
  "ac-7 the runtime file and the committed slot agree after commit"

write_state a b 2
next_before="$(next_slot)"
rm -f "$esp/vmlinuz-b" "$esp/initrd-b"
slot_cmd pending b >/dev/null 2>&1
assert_eq "$?" "1" "ac-7 a refused pending is still refused"
assert_eq "$(next_slot)" "$next_before" "ac-7 a refused command does not touch the runtime file"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

write_state a b 2
slot_cmd abandon >/dev/null 2>&1
assert_eq "$(next_slot)" "a" "ac-7 abandon moves the next boot back to the committed slot"

write_state a none 1
slot_cmd rollback >/dev/null 2>&1
assert_eq "$(next_slot)" "b" "ac-7 rollback points the next boot at the other slot"

assert_eq "$(find "$esp/boot/grub" -name 'ab-slot.cfg.tmp.*' | wc -l | tr -d ' ')" "0" \
  "ac-7 no temporary file is left behind"

# --- ac-8 the heal path -----------------------------------------------------
write_state a b 2
printf 'garbage that is not a pair of GRUB commands\n' >"$esp/boot/grub/ab-slot.cfg"
assert_eq "$(slot_cmd next 2>/dev/null)" "next=unknown" \
  "ac-8 a corrupt file reads back as no answer"
slot_cmd next --write >/dev/null 2>&1
assert_eq "$?" "0" "ac-8 --write succeeds"
assert_eq "$(next_slot)" "b" "ac-8 --write restores the pending slot from the state file"
assert_eq "$(grep -c . "$esp/boot/grub/ab-slot.cfg" | tr -d ' ')" "2" \
  "ac-8 the healed file is the documented pair of commands"

write_state a none 1
slot_cmd next --write >/dev/null 2>&1
assert_eq "$(next_slot)" "a" "ac-8 with nothing pending the heal points at the committed slot"
assert_eq "$(slot_cmd next 2>/dev/null)" "next=a" "ac-8 the next boot can be read back"

# --- ac-9 the tool works where the platform layer puts it --------------------
#
# The CI fixtures run the shipped binary against a mounted image and pass only AB_ESP
# and AB_CMD, so the writer has to be found next to the tool inside the layer rather
# than at /lib. The installed path is simply absent on a build host.
write_state a none 1
rm -f "$esp/boot/grub/ab-slot.cfg"
AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$tmp/p4" AB_MOUNTS="$mounts_partial" \
  sh "$ab_slot" pending b >/dev/null 2>&1
assert_eq "$?" "0" "ac-9 pending works without AB_SLOT_CFG_LIB, as the fixtures call it"
assert_eq "$(cat "$esp/boot/grub/ab-slot.cfg")" "$(printf 'set fallback=0\nset default=1')" \
  "ac-9 the writer next to the tool is used"

# A tool with no writer anywhere is still a loud failure: that is a broken layer.
lonely="$tmp/lonely"
mkdir -p "$lonely"
cp "$ab_slot" "$lonely/ab-slot"
write_state a none 1
AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$tmp/p4" AB_MOUNTS="$mounts_partial" \
  sh "$lonely/ab-slot" pending b >/dev/null 2>&1
assert_eq "$?" "1" "ac-9 a tool with no writer at all fails instead of pretending"

# --- ac-5 gc ----------------------------------------------------------------
p4="$fake_p4"
mkdir -p "$p4/@overlay-25.12.2" "$p4/@overlay-25.12.3" "$p4/@overlay-25.12.1" "$p4/@docker"
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/btrfs" <<'STUB'
#!/bin/sh
case "$1" in
  subvolume)
    case "$2" in
      list) printf 'ID 256 gen 10 top level 5 path @overlay-25.12.1\nID 257 gen 10 top level 5 path @overlay-25.12.2\nID 258 gen 10 top level 5 path @overlay-25.12.3\n' ;;
      delete) printf '%s\n' "$4" >>"${GC_LOG:-/dev/null}"; rm -rf "$4" ;;
      sync) : ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$stub_bin/btrfs"

write_state b none 5
export GC_LOG="$tmp/gc-deleted.log"
: >"$GC_LOG"
AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$p4" AB_MOUNTS="$mounts_full" \
  AB_SLOT_CFG_LIB="$slot_cfg_lib" PATH="$stub_bin:$PATH" sh "$ab_slot" gc --dry-run >/dev/null 2>&1
assert_eq "$?" "0" "ac-5 gc --dry-run succeeds"
assert_eq "$(wc -l <"$GC_LOG" | tr -d ' ')" "0" "ac-5 gc --dry-run deletes nothing"
assert_eq "$([ -d "$p4/@overlay-25.12.1" ] && echo present)" "present" \
  "ac-5 gc --dry-run keeps the unreferenced layer"

AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$p4" AB_MOUNTS="$mounts_full" \
  AB_SLOT_CFG_LIB="$slot_cfg_lib" PATH="$stub_bin:$PATH" sh "$ab_slot" gc >/dev/null 2>&1
assert_eq "$?" "0" "ac-5 gc succeeds"
assert_contains "$(cat "$GC_LOG")" "@overlay-25.12.1" "ac-5 gc deletes the unreferenced layer"
assert_eq "$([ -d "$p4/@overlay-25.12.2" ] && echo present)" "present" \
  "ac-5 gc keeps the layer referenced by slot b"
assert_eq "$([ -d "$p4/@overlay-25.12.3" ] && echo present)" "present" \
  "ac-5 gc keeps the layer referenced by slot a"
unset GC_LOG

# --- ac-6 retired schema ----------------------------------------------------
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 2,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper_gen": 1 },
    "b": { "rootfs": "25.12.2", "upper_gen": 1 }
  }
}
JSON
slot_cmd status >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 a state file with the retired upper_gen field is refused"
slot_cmd commit >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 commit refuses to rewrite a state it cannot read"

assert_eq "$(grep -c 'upper_gen' "$ab_slot")" "0" "ac-6 the tool never mentions the retired field"

# --------------------------------------------------------------------------- #
# ac-9 the state lock survives a power cut, a hard kill and a watchdog reset
# --------------------------------------------------------------------------- #
#
# The lock is a directory on the ESP, so it outlives the process that made it. Before the
# owner line it was a dead end: one interrupted write and every later commit refused with
# "state is locked by another process" - an upgrade that can never finish, on a real
# machine just as in CI.

pending_of_state() {
  _pending_now="$(sed -n 's/.*"pending": *"\([ab]\)".*/\1/p' "$esp/ab/state.json" | head -n 1)"
  printf '%s' "${_pending_now:-none}"
}

lock_owner() { # <boot_id> <pid>
  mkdir -p "$esp/ab/.lock"
  printf '%s %s %s\n' "$1" "$2" "2026-01-01T00:00:00Z" >"$esp/ab/.lock/owner"
}

: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

# 1. a lock from a previous boot: the writer died with that boot, so it is taken over.
write_state a none 9
lock_owner "boot-0000-dead-0000" "999999"
out="$(slot_cmd pending b 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 a lock from an earlier boot does not block the write"
assert_contains "$out" "action=stale-lock-taken" "ac-9 taking the lock over is reported"
assert_eq "$(pending_of_state)" "b" "ac-9 the command that was blocked now runs"
assert_eq "$([ -d "$esp/ab/.lock" ] && echo left || echo gone)" "gone" \
  "ac-9 the lock is released when the writer exits"

# 2. a lock of this boot whose writer is still alive: a real concurrent writer, refused.
write_state a none 10
lock_owner "$(cat "$boot_id_file")" "$$"
out="$(slot_cmd pending b 2>&1)"
rc=$?
assert_eq "$rc" "1" "ac-9 a live writer of this boot still excludes another one"
assert_contains "$out" "state is locked by another process" "ac-9 the refusal names the lock"
assert_eq "$(pending_of_state)" "none" "ac-9 nothing was written while the lock was held"
assert_eq "$([ -d "$esp/ab/.lock" ] && echo kept || echo gone)" "kept" \
  "ac-9 the other writer's lock is left alone"

# 3. a writer killed mid-write: same boot, but its pid is gone.
write_state a none 11
lock_owner "$(cat "$boot_id_file")" "4000000"
out="$(slot_cmd pending b 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 a writer killed mid-write does not block the next one"
assert_contains "$out" "action=stale-lock-taken" "ac-9 the takeover is reported here too"
assert_eq "$(pending_of_state)" "b" "ac-9 the next write goes through"

# 4. a lock directory with no owner line at all: an older layout, or the write was cut
#    short before the owner was written.
write_state a none 12
mkdir -p "$esp/ab/.lock"
out="$(slot_cmd pending b 2>&1)"
rc=$?
assert_eq "$rc" "0" "ac-9 a lock without an owner is taken over"
assert_contains "$out" "action=stale-lock-taken" "ac-9 and reported"
assert_eq "$(pending_of_state)" "b" "ac-9 the state is written"
assert_eq "$([ -d "$esp/ab/.lock" ] && echo left || echo gone)" "gone" \
  "ac-9 no lock directory is left behind"

# 5. the lock carries who holds it, so the rules above can be decided at all.
assert_contains "$(cat "$ab_slot")" 'printf '"'"'%s %s %s\n'"'"' "$(boot_id)" "$$"' \
  "ac-9 the owner line is <boot_id> <pid> <started_at>"
assert_contains "$(cat "$ab_slot")" 'kill -0 "${_owner_pid}"' \
  "ac-9 a lock of this boot is judged by the liveness of its pid"
assert_contains "$(cat "$ab_slot")" "AB_BOOT_ID_FILE" \
  "ac-9 the boot id comes from the kernel, not from the ESP"

# 6. the hooks clear a lock that an earlier boot left behind, so the first write of a
#    boot does not have to be the one that discovers it.
for hook in platform/etc/init.d/ab-boot platform/etc/init.d/ab-commit; do
  assert_contains "$(cat "$root/$hook")" "clear_stale_lock" \
    "ac-9 ${hook} clears a lock left by an earlier boot"
done
assert_contains "$(cat "$root/platform/etc/init.d/ab-commit")" "stage=lock action=stale-lock-taken" \
  "ac-9 the sweep is recorded"

# --------------------------------------------------------------------------- #
# (20261117) ac-9 the lock path: a live holder is waited for, and a volume that
# cannot create the lock is not mistaken for one
# --------------------------------------------------------------------------- #
#
# CI run 43918219525, QEMU S5 on base 25.12.1: the harness SIGTERMed the machine one second
# after S5-UPGRADE-DONE, cutting `ab-commit`'s write to the FAT ESP and corrupting its
# cluster chain. The next boot mounted the ESP read-only; mkdir failed with EROFS, and the
# old lock path reported "state is locked by another process" for a holder that did not
# exist. These cases pin the three behaviours that fix it: waiting for a live holder,
# switching that wait off, and naming the real cause when no directory entry can be made.

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
  fi
}

# The bounds below judge the lock wait, not the ESP flush. Several `sync` calls live on the
# commit path, and on a host whose global sync is slow (measured on macOS: ~400ms for one
# commit) they would fail a test whose subject is sleeping. The measured calls run with a
# no-op sync in front of PATH; the lock protocol itself is unchanged.
#
# The "did not wait" bounds are the wait budget, not a tight 200ms, and that is deliberate.
# One `slot_cmd` spawns a dozen subprocesses; measured on macOS an uncontended commit costs
# 225-290ms of that alone, so a 200ms bound failed on a host that was merely slow to start
# processes (three assertions flaked this way while the behaviour was correct). Waiting for
# the default budget costs >= 1000ms, so "under 900ms" distinguishes the two facts without
# mistaking host speed for a defect.
sync_stub_dir="$tmp/sync-stub"
mkdir -p "$sync_stub_dir"
printf '#!/bin/sh\nexit 0\n' >"$sync_stub_dir/sync"
chmod +x "$sync_stub_dir/sync"
slot_cmd_nosync() {
  PATH="$sync_stub_dir:$PATH" slot_cmd "$@"
}

# 1. a live holder that lets go inside the wait budget: the write succeeds, and the wait
#    is not a stale takeover. The holder's pid is the background subshell, which is alive
#    while it sleeps, so the owner line describes a real writer.
write_state a none 20
(
  sleep 0.2
  rm -rf "$esp/ab/.lock"
) &
holder_pid=$!
lock_owner "$(cat "$boot_id_file")" "$holder_pid"
started="$(now_ms)"
out="$(slot_cmd_nosync commit 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
wait "$holder_pid" 2>/dev/null || :
assert_eq "$rc" "0" "ac-9 a live holder that releases inside the wait budget does not fail the write"
assert_eq "$(printf '%s\n' "$out" | grep -c 'action=stale-lock-taken' || true)" "0" \
  "ac-9 waiting for a live holder is not reported as a stale takeover"
assert_eq "$(( elapsed >= 100 ))" "1" \
  "ac-9 the write actually waited for the holder (${elapsed}ms)"

# 2. a live holder that never lets go: bounded wait, then the original refusal. The test's
#    own pid is alive for the whole case, so no stale branch can apply.
write_state a none 21
lock_owner "$(cat "$boot_id_file")" "$$"
started="$(now_ms)"
out="$(AB_LOCK_WAIT_SECS=0.3 slot_cmd pending b 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
assert_eq "$rc" "1" "ac-9 a live holder that never releases still refuses the write"
assert_contains "$out" "state is locked by another process" "ac-9 the refusal keeps its wording"
assert_eq "$(pending_of_state)" "none" "ac-9 nothing is written while the holder stays"
assert_eq "$([ -d "$esp/ab/.lock" ] && echo kept || echo gone)" "kept" \
  "ac-9 the live holder's lock is left alone"
assert_eq "$(( elapsed >= 200 ))" "1" \
  "ac-9 the refusal comes after the wait budget (${elapsed}ms)"

# 3. the escape hatch: AB_LOCK_WAIT_SECS=0 is the old refuse-at-once behaviour, for a caller
#    that would rather fail than wait.
write_state a none 22
lock_owner "$(cat "$boot_id_file")" "$$"
started="$(now_ms)"
out="$(AB_LOCK_WAIT_SECS=0 slot_cmd pending b 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
assert_eq "$rc" "1" "ac-9 AB_LOCK_WAIT_SECS=0 still refuses"
assert_contains "$out" "state is locked by another process" "ac-9 and keeps the original message"
assert_eq "$(pending_of_state)" "none" "ac-9 and writes nothing"
assert_eq "$([ -d "$esp/ab/.lock" ] && echo kept || echo gone)" "kept" \
  "ac-9 and leaves the holder's lock alone"
assert_eq "$(( elapsed < 900 ))" "1" \
  "ac-9 AB_LOCK_WAIT_SECS=0 does not wait (${elapsed}ms, budget is 1000ms)"

# 4. stale locks are taken over without spending the wait budget: a lock from another boot,
#    and one from this boot whose pid is gone.
#
#    The assertion is "the stale branch does not spend the wait budget", and it is written
#    against a budget it makes large enough to dominate this host's own cost: one
#    `slot_cmd_nosync` here pays two `python3` starts for now_ms, a shell start and a dozen
#    state-file reads, which measured 700-930 ms on a loaded authoring machine and made the
#    old "under 900 ms against the 1 s default budget" bound fail one run in three (2026-11-19,
#    three standalone runs: pass, fail, pass). A takeover that really waited would cost the
#    whole budget, so a 5 s budget and a 2 s bound still tells the two apart - and it no longer
#    measures how fast the machine is.
_stale_budget=5
write_state a none 23
lock_owner "boot-0000-dead-0000" "999999"
started="$(now_ms)"
out="$(AB_LOCK_WAIT_SECS="$_stale_budget" slot_cmd_nosync pending b 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
assert_eq "$rc" "0" "ac-9 a lock from another boot is taken over"
assert_contains "$out" "action=stale-lock-taken" "ac-9 and reported as a takeover"
assert_eq "$(( elapsed < 2000 ))" "1" \
  "ac-9 a stale lock is not waited for (${elapsed}ms, budget is ${_stale_budget}000ms)"
assert_eq "$(pending_of_state)" "b" "ac-9 the stale takeover writes the state"

write_state a none 24
lock_owner "$(cat "$boot_id_file")" "4000000"
started="$(now_ms)"
out="$(AB_LOCK_WAIT_SECS="$_stale_budget" slot_cmd_nosync pending b 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
assert_eq "$rc" "0" "ac-9 a lock of this boot whose pid is gone is taken over"
assert_contains "$out" "action=stale-lock-taken" "ac-9 and reported here too"
assert_eq "$(( elapsed < 2000 ))" "1" \
  "ac-9 a dead pid does not make the writer wait (${elapsed}ms, budget is ${_stale_budget}000ms)"

# 5. source-level: the takeover counter only advances in the stale branch, so contention
#    cannot use up the five attempts that are there for a lock that will not clear.
assert_eq "$(grep -c -F '_lock_try=$((_lock_try + 1))' "$ab_slot")" "1" \
  "ac-9 _lock_try is incremented in exactly one place"
assert_contains "$(grep -A1 'if lock_is_stale; then' "$ab_slot")" '_lock_try=$((_lock_try + 1))' \
  "ac-9 and that place is inside the stale branch"
assert_contains "$(cat "$ab_slot")" '[ "${_lock_try}" -lt 5 ]' \
  "ac-9 the stale-takeover cap is still five attempts"

# 6. no contention: the happy path must not acquire a sleep. A regression that waits before
#    the first mkdir would make every commit on a machine pay the lock budget.
write_state a none 25
rm -rf "$esp/ab/.lock"
started="$(now_ms)"
out="$(AB_LOCK_WAIT_SECS="$_stale_budget" slot_cmd_nosync commit 2>&1)"
rc=$?
elapsed=$(( $(now_ms) - started ))
assert_eq "$rc" "0" "ac-9 a commit with no contention succeeds"
assert_eq "$(( elapsed < 2000 ))" "1" \
  "ac-9 the uncontended path does not sleep (${elapsed}ms, budget is ${_stale_budget}000ms)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'action=stale-lock-taken' || true)" "0" \
  "ac-9 and no takeover is reported"

# 7. a volume that cannot create the lock directory at all: the ESP mounted read-only, or
#    full. This is the CI accident's next boot. It must not claim another writer exists.
write_state a none 26
rm -rf "$esp/ab/.lock"
state_before="$(cat "$esp/ab/state.json")"
chmod 0555 "$esp/ab"
# The test may run as root, where a read-only mode bit is not a read-only volume; skip the
# case there rather than assert something the environment cannot express.
if mkdir "$esp/ab/.probe" 2>/dev/null; then
  rmdir "$esp/ab/.probe" 2>/dev/null || :
  chmod 0755 "$esp/ab"
  assert_eq "skipped" "skipped" \
    "ac-9 a read-only ESP cannot be simulated as root, the case is skipped"
else
  out="$(AB_LOCK_WAIT_SECS=0.2 slot_cmd commit 2>&1)"
  rc=$?
  chmod 0755 "$esp/ab"
  assert_eq "$rc" "1" "ac-9 an ESP that cannot create the lock fails the write"
  assert_contains "$out" "cannot create ${esp}/ab/.lock" \
    "ac-9 and names the directory it could not create"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'state is locked by another process' || true)" "0" \
    "ac-9 and does not invent a holder"
  assert_eq "$(cat "$esp/ab/state.json")" "$state_before" \
    "ac-9 the state file is untouched"
fi

finish
