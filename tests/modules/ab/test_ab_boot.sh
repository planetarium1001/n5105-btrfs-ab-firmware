#!/usr/bin/env bash
# Module: ab
# Verifies platform/etc/init.d/ab-boot: the boot that has to leave the ESP and the
# writable partition consistent with ab/state.json before anything else reads them.
# The hook is run for real, with a fake ESP, a fake mount table and stubs for the
# tools a router has and this test host does not.
#   ac-1 the boot is recorded in the ring log and the state is read from the ESP
#   ac-2 a stale, corrupt or hand-edited runtime slot file is healed from the state
#        file, so the next boot follows the truth instead of the leftover hint
#   ac-3 the first-boot growth result that the initramfs leaves on p4 is appended to
#        the ring log, in both documented layouts, and a missing one is "unrecorded"
#   ac-4 the boot disk is identified through the shared library, and an unidentifiable
#        disk is recorded instead of guessed
#   ac-5 the writable partition is discovered as ab-data, not the retired ab-shared, and
#        no device name is hard coded
#   ac-6 the pending slot is marked as a candidate only when it is the running slot
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_boot="$root/platform/etc/init.d/ab-boot"
ab_slot="$root/platform/usr/sbin/ab-slot"
slot_cfg_lib="$root/platform/lib/ab-slot-cfg.sh"
partitions_lib="$root/platform/lib/ab-partitions.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

esp="$tmp/esp"
p4="$tmp/p4"
bin="$tmp/bin"
stub_di="$tmp/disk-identity.sh"
mkdir -p "$esp/ab/log" "$esp/boot/grub" "$p4/.ab" "$bin"

cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# Both surfaces are already mounted: the hook must not need to mount anything.
mounts="$tmp/mounts"
cat >"$mounts" <<MOUNTS
/dev/vda1 ${esp} vfat rw,noatime 0 0
/dev/vda4 ${p4} btrfs rw,noatime 0 0
MOUNTS

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

# The identity library belongs to the platform layer; this stub answers with the
# documented interface so the hook is tested against the contract it consumes.
cat >"$stub_di" <<'IDENTITY'
#!/bin/sh
di_resolve() {
  printf 'disk=%s method=%s\n' "${STUB_DISK:-/dev/sda}" "${STUB_METHOD:-partuuid}"
}
di_parent_disk() {
  printf '%s\n' "$1"
}
di_lookup_partname() {
  [ "${STUB_NO_PARTNAME:-0}" = "1" ] && return 1
  case "$1" in
    ab-esp) printf '/dev/sda1\n' ;;
    ab-slot-a) printf '/dev/sda2\n' ;;
    ab-slot-b) printf '/dev/sda3\n' ;;
    ab-data) printf '/dev/sda4\n' ;;
    *) return 1 ;;
  esac
}
di_partition_on_disk() {
  case "$1" in
    /dev/sda | /dev/sdb) printf '%s%s\n' "$1" "$2" ;;
    *) return 1 ;;
  esac
}
IDENTITY

# The boot hook calls ab-slot from PATH; the stub points the real tool at this sandbox
# so the heal path is the production one, not a re-implementation in the test.
cat >"$bin/ab-slot" <<STUB
#!/bin/sh
AB_ESP="$esp" AB_P4="$p4" AB_CMD="$cmdline" AB_MOUNTS="$mounts" \\
  AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
  AB_DISK_IDENTITY_LIB="$stub_di" exec sh "$ab_slot" "\$@"
STUB
cat >"$bin/btrfs" <<'STUB'
#!/bin/sh
case "$1" in
  --version) printf 'btrfs-progs v6.12\n' ;;
  subvolume) exit 0 ;;
  filesystem)
    printf '%s\n' "$*" >>"${STUB_BTRFS_LOG:-/dev/null}"
    [ "${STUB_BTRFS_RESIZE_FAIL:-0}" = "1" ] && { printf 'ERROR: resize failed\n' >&2; exit 1; }
    exit 0
    ;;
esac
exit 0
STUB
cat >"$bin/mount" <<'STUB'
#!/bin/sh
printf 'ab-boot test: unexpected mount call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$bin/ab-slot" "$bin/btrfs" "$bin/mount"

# run_boot: execute the hook's start() exactly as rc.common would.
run_boot() {
  : >"$esp/ab/log/boot-0.log"
  PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_MOUNTS="$mounts" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="${BOOT_IDENTITY_LIB:-$stub_di}" \
    sh -c ". '$ab_boot'; start" >"$tmp/boot.out" 2>&1
}

boot_log() { cat "$esp/ab/log/boot-0.log"; }
lines_in_file() {
  [ -f "$1" ] || { printf '0'; return 0; }
  printf '%s' "$(grep -c . "$1" 2>/dev/null | tr -d ' ')"
}
next_slot() { sh -c ". '$slot_cfg_lib'; ab_slot_cfg_get '$esp/boot/grub/ab-slot.cfg'"; }

# --- ac-1 the boot is recorded ---------------------------------------------
write_state a none 1
rm -f "$esp/boot/grub/ab-slot.cfg"
run_boot
assert_eq "$?" "0" "ac-1 the boot hook succeeds"
assert_contains "$(boot_log)" "stage=boot slot=a upper=@overlay-25.12.3" \
  "ac-1 the running slot and its layer are recorded"
assert_contains "$(boot_log)" "stage=btrfs-check slot=a result=ok" \
  "ac-1 the btrfs check is recorded"
assert_contains "$(boot_log)" "stage=gc slot=a result=ok" \
  "ac-1 early reclamation runs and is recorded"

# --- ac-2 the hint is healed from the state file ---------------------------
write_state a b 2
printf 'not a pair of GRUB commands at all\n' >"$esp/boot/grub/ab-slot.cfg"
run_boot
assert_eq "$(next_slot)" "b" "ac-2 a corrupt file is healed to the pending slot"
assert_contains "$(boot_log)" "stage=slot-cfg slot=a result=ok next=b" \
  "ac-2 the heal is recorded with the slot it wrote"
assert_eq "$(grep -c . "$esp/boot/grub/ab-slot.cfg" | tr -d ' ')" "2" \
  "ac-2 the healed file is the documented pair of GRUB commands"

# A hand-edited state file, a power cut between the two writes, or a stale block all
# look the same here: the block is rewritten from the state, never trusted.
write_state a none 3
sh -c ". '$slot_cfg_lib'; ab_slot_cfg_write '$esp/boot/grub/ab-slot.cfg' a b"
assert_eq "$?" "0" "ac-2 the stale file is written through the shared writer"
assert_eq "$(next_slot)" "b" "ac-2 the stale file is in place before the boot"
run_boot
assert_eq "$(next_slot)" "a" "ac-2 a stale file is corrected to the committed slot"
assert_contains "$(boot_log)" "stage=slot-cfg slot=a result=ok next=a" \
  "ac-2 the correction is recorded"

# The heal must not depend on the running slot being the pending one.
printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
write_state a b 4
rm -f "$esp/boot/grub/ab-slot.cfg"
PATH="$bin:$PATH" AB_ESP="$esp" AB_P4="$p4" AB_MOUNTS="$mounts" \
  AB_SLOT_CFG_LIB="$slot_cfg_lib" sh -c ". '$ab_boot'; start" >"$tmp/boot.out" 2>&1
assert_eq "$(next_slot)" "b" "ac-2 booting the candidate keeps the next boot on it"
assert_contains "$(boot_log)" "stage=slot-cfg slot=b result=ok next=b" \
  "ac-2 the heal follows the slot that actually booted"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# --- ac-3 the growth result reaches the ring log ---------------------------
write_state a none 5
printf 'result=done\n' >"$p4/.ab/grow"
run_boot
assert_contains "$(boot_log)" "stage=grow slot=a result=done" \
  "ac-3 the growth result at the subvolume root is recorded"

# The platform layer mounts the partition itself, so the same file can sit under the
# running slot's layer instead.
rm -f "$p4/.ab/grow"
mkdir -p "$p4/@overlay-25.12.3/.ab"
printf 'result=already-full\n' >"$p4/@overlay-25.12.3/.ab/grow"
run_boot
assert_contains "$(boot_log)" "stage=grow slot=a result=already-full" \
  "ac-3 the growth result under the slot layer is recorded"

# A failure token is passed through verbatim, prefix and all.
printf 'result=fail:resize-failed\n' >"$p4/.ab/grow"
run_boot
assert_contains "$(boot_log)" "stage=grow slot=a result=fail:resize-failed" \
  "ac-3 a failure token is recorded as it was written"

# Missing is the documented "not recorded" case and must never be an error.
rm -f "$p4/.ab/grow" "$p4/@overlay-25.12.3/.ab/grow"
run_boot
assert_eq "$?" "0" "ac-3 a missing growth result does not fail the boot"
assert_contains "$(boot_log)" "stage=grow slot=a result=unrecorded" \
  "ac-3 a missing growth result is recorded as unrecorded"

# --- ac-4 the boot disk is identified, not guessed -------------------------
write_state a none 7
run_boot
assert_eq "$?" "0" "ac-4 the boot hook still succeeds"
assert_contains "$(boot_log)" "stage=device slot=a disk=/dev/sda method=partuuid" \
  "ac-4 the disk and how it was found are recorded"
# The console copy is best effort (procd forwards hook stdout to syslog, /dev/console
# is not writable everywhere), so the ring log is what the assertion pins down.

# No identity library: the hook says so and keeps going.
write_state a none 8
BOOT_IDENTITY_LIB=/nonexistent/disk-identity.sh run_boot
assert_eq "$?" "0" "ac-4 a missing identity library does not fail the boot"
assert_contains "$(boot_log)" "stage=device slot=a disk=unknown method=unresolved" \
  "ac-4 an unidentifiable disk is recorded instead of guessed"

# ab_find_partition is the glue the services share: the resolved disk decides, and the
# device name is never assembled from strings. The disk-scoping cases live in
# tests/modules/ab/test_ab_partitions.sh, which drives two fixture disks.
assert_eq "$(AB_DISK_IDENTITY_LIB="$stub_di" sh -c ". '$partitions_lib'; ab_find_partition ab-esp 1")" \
  "/dev/sda1" "ac-4 the resolved disk supplies the partition"
# A different resolved disk gives a different device: the answer follows the disk, not
# a hard coded number.
assert_eq "$(AB_DISK_IDENTITY_LIB="$stub_di" STUB_DISK=/dev/sdb \
  sh -c ". '$partitions_lib'; ab_find_partition ab-esp 1")" \
  "/dev/sdb1" "ac-4 the partition follows the resolved disk"
AB_DISK_IDENTITY_LIB=/nonexistent/disk-identity.sh \
  sh -c ". '$partitions_lib'; ab_find_partition ab-esp 1" >/dev/null 2>&1
assert_eq "$?" "1" "ac-4 without the identity library nothing is guessed"

# The console is what a failed CI run has: the ring log lives on the ESP. Both the
# device identity and the failure to mount the ESP have to be visible there.
ab_boot_src=$(cat "$ab_boot")
assert_contains "$ab_boot_src" 'console_say "ab-boot: stage=device slot=' \
  "ac-4 the device identity is reported on the console, not just in the ring log"
assert_contains "$ab_boot_src" 'stage=boot result=fail reason=esp-unresolved' \
  "ac-4 a boot that cannot mount the ESP says so on the console"
ab_commit_src=$(cat "$root/platform/etc/init.d/ab-commit")
assert_contains "$ab_commit_src" 'stage=healthcheck-done result=fail reason=esp-unresolved' \
  "ac-4 a health check that cannot run says so on the console"
assert_contains "$ab_commit_src" 'stage=healthcheck-done slot=${slot} result=fail reason=${failed} action=stay' \
  "ac-4 a health check that fails on the committed slot prints a decision line"

# --- ac-5 partition discovery uses the current name ------------------------
assert_eq "$(grep -c 'ab-shared' "$ab_boot")" "0" \
  "ac-5 the retired ab-shared label is gone from the boot hook"
assert_contains "$(cat "$ab_boot")" "part_device ab-data 4" \
  "ac-5 the writable partition is discovered as ab-data"
assert_eq "$(grep -c '/dev/vda' "$ab_boot")" "0" \
  "ac-5 no device name is hard coded in the boot hook"
for other in "$root/platform/etc/init.d/ab-commit" "$root/platform/lib/upgrade/platform.sh"; do
  assert_eq "$(grep -c '/dev/vda' "$other")" "0" \
    "ac-5 no device name is hard coded in ${other#"$root"/}"
done

# --- ac-7 a growth the initramfs could not finish is finished at runtime -------
#
# `btrfs filesystem resize` fails with EBUSY while the initramfs has the filesystem
# mounted more than once, and records `result=fail:btrfs-resize`. Here the same
# filesystem is mounted once, so the growth is retried and the record becomes the truth
# again: `result=done`.
export STUB_BTRFS_LOG="$tmp/btrfs.log"
: >"$STUB_BTRFS_LOG"
write_state a none 9
mkdir -p "$p4/.ab"
printf 'result=fail:btrfs-resize last_lba=921566\n' >"$p4/.ab/grow"
run_boot
assert_eq "$?" "0" "ac-7 the boot still succeeds"
assert_contains "$(cat "$STUB_BTRFS_LOG")" "filesystem resize max ${p4}" \
  "ac-7 the resize is run against the single mount point"
assert_contains "$(boot_log)" "stage=resize result=ok source=ab-boot" \
  "ac-7 the rescue is recorded"
assert_eq "$(cat "$p4/.ab/grow")" "result=done last_lba=921566" \
  "ac-7 the record becomes done and keeps its geometry"
assert_contains "$(boot_log)" "stage=grow slot=a result=done" \
  "ac-7 the boot hook then reports what the record says"
assert_file_exists "$esp/ab/log/resize.log" "ac-7 btrfs' own output is kept"

# A second boot must not resize again: the record no longer says it failed.
: >"$STUB_BTRFS_LOG"
run_boot
assert_eq "$(lines_in_file "$STUB_BTRFS_LOG")" "0" \
  "ac-7 a finished growth is not retried"
assert_eq "$(cat "$p4/.ab/grow")" "result=done last_lba=921566" \
  "ac-7 the record stays done"

# A resize that fails again only logs: the boot goes on and the record keeps saying why.
: >"$STUB_BTRFS_LOG"
printf 'result=fail:btrfs-resize last_lba=921566\n' >"$p4/.ab/grow"
STUB_BTRFS_RESIZE_FAIL=1 run_boot
assert_eq "$?" "0" "ac-7 a failing resize does not block the boot"
assert_contains "$(boot_log)" "stage=resize result=fail:btrfs-resize source=ab-boot" \
  "ac-7 the failure is recorded with its reason"
assert_contains "$(cat "$p4/.ab/grow")" "result=fail:btrfs-resize" \
  "ac-7 the record keeps the failure, so the next boot tries again"
unset STUB_BTRFS_LOG

# --- ac-6 the candidate marker ---------------------------------------------
write_state a b 6
printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
run_boot
assert_file_exists "$esp/ab/candidate" "ac-6 the pending slot marks a candidate first boot"
assert_contains "$(cat "$esp/ab/candidate")" "b " "ac-6 the marker names the slot"
assert_contains "$(boot_log)" "candidate=1" "ac-6 the candidate boot is recorded"

printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"
run_boot
assert_eq "$([ -f "$esp/ab/candidate" ] && echo present || echo absent)" "present" \
  "ac-6 booting the committed slot leaves an existing marker alone"
assert_eq "$(grep -c 'candidate=1' "$esp/ab/log/boot-0.log")" "0" \
  "ac-6 a boot of the committed slot is not a candidate"

finish
