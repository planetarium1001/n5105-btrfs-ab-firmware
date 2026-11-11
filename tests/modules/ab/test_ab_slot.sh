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
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown" \
  "ac-1 status line reports the documented fields"

status="$(slot_cmd_full status 2>/dev/null)"
assert_eq "$status" \
  "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown" \
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
  "slot=b upper=@overlay-25.12.2 generation=2 committed=a pending=a p4=ok data=missing docker=missing swap=missing next=a disk=/dev/sda method=partuuid boot=unknown esp=unknown" \
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
assert_matches "$status" 'boot=unknown esp=unknown$' \
  "ac-9 the esp= field is appended at the end of the status line"

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

finish
