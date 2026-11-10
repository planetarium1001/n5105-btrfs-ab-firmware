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
    sh "$ab_slot" "$@"
}

# slot_cmd_full: the same call, with every documented mount point present.
slot_cmd_full() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="${fake_p4}" \
    AB_MOUNTS="${mounts_full}" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" \
    AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" \
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
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid" \
  "ac-1 status line reports the documented fields"

status="$(slot_cmd_full status 2>/dev/null)"
assert_eq "$status" \
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=partuuid" \
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
  "slot=b upper=@overlay-25.12.2 generation=2 committed=a pending=a p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid" \
  "ac-1 status follows ab.slot= on the kernel command line"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

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

finish
