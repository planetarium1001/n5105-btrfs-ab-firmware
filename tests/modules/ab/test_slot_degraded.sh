#!/usr/bin/env bash
# Module: ab
# ac-4: `ab-slot status` reports how this boot started as `boot=ok|degraded|unknown`.
#       The evidence is the ring log of the boot that is running: a `stage=boot` line
#       carrying `action=degraded-boot` means the writable partition did not come up and
#       every write lands in a tmpfs. A missing or unreadable log is `unknown` - never
#       `ok`, because a machine must not claim a healthy boot it has no evidence for.
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

esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/boot/grub"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"
mounts="$tmp/mounts"
printf '/dev/vda1 /boot vfat rw 0 0\n' >"$mounts"
fake_p4="$tmp/p4"
mkdir -p "$fake_p4"

status_line() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$fake_p4" AB_MOUNTS="$mounts" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    sh "$ab_slot" status 2>/dev/null
}

boot_field() { # the boot= token of one status line
  printf '%s' "$1" | sed -n 's/.* boot=\([a-z]*\).*/\1/p'
}

# --- a healthy boot -------------------------------------------------------
cat >"$esp/ab/log/boot-0.log" <<'LOG'
stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok
stage=grow slot=a result=already-full last_lba=250069646
stage=btrfs-check slot=a result=ok
LOG
line="$(status_line)"
assert_eq "$(boot_field "$line")" "ok" "ac-4 a boot with a result=ok line reports boot=ok"
assert_contains "$line" "slot=a" "ac-4 the existing fields are still reported"
assert_contains "$line" "upper=@overlay-25.12.3" "ac-4 the layer is still reported"
assert_contains "$line" "p4=" "ac-4 the writable partition state is still reported"
assert_eq "$(printf '%s' "$line" | grep -o 'boot=' | wc -l | tr -d ' ')" "1" \
  "ac-4 boot= appears exactly once"

# --- a degraded boot ------------------------------------------------------
cat >"$esp/ab/log/boot-0.log" <<'LOG'
stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok
stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=fail reason=p4-degraded action=degraded-boot
stage=btrfs-check slot=a result=ok
LOG
line="$(status_line)"
assert_eq "$(boot_field "$line")" "degraded" "ac-4 action=degraded-boot in this boot's log reports boot=degraded"

# --- the growth line alone is not the answer -----------------------------
cat >"$esp/ab/log/boot-0.log" <<'LOG'
stage=grow slot=a result=fail:size-not-increased last_lba=250069646
LOG
assert_eq "$(boot_field "$(status_line)")" "ok" \
  "ac-4 a grow failure that the boot survived is not a degraded boot"

# --- no log at all: unknown, never ok ------------------------------------
rm -f "$esp/ab/log/boot-0.log"
line="$(status_line)"
assert_eq "$(boot_field "$line")" "unknown" "ac-4 a missing ring log reports boot=unknown"
assert_eq "$(printf '%s' "$line" | grep -c 'boot=ok')" "0" \
  "ac-4 a machine with no evidence never claims boot=ok"

# The previous boot's log is not this boot's evidence: boot-1.log is history, and the
# file the field reads has to be the one the running boot writes.
cat >"$esp/ab/log/boot-1.log" <<'LOG'
stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok
LOG
assert_eq "$(boot_field "$(status_line)")" "unknown" \
  "ac-4 the previous boot's log does not answer for this boot"
rm -f "$esp/ab/log/boot-1.log"

# --- an unreadable log is unknown too ------------------------------------
mkdir -p "$esp/ab/log/boot-0.log"
assert_eq "$(boot_field "$(status_line)")" "unknown" \
  "ac-4 an unreadable ring log reports boot=unknown"
rmdir "$esp/ab/log/boot-0.log"

finish
