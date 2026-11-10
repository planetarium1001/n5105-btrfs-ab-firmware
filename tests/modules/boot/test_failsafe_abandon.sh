#!/usr/bin/env bash
# Module: boot
# The fail-safe abandon on the initramfs failure path: a pending slot that could not
# finish the initramfs must not be selected again by GRUB, or the machine reboots into
# the same failing menu entry forever.
#   ac-1 wf_fail abandons the pending slot before printing the judge line
#   ac-2 the ESP is written through platform/lib/ab-slot-cfg.sh: pending cleared in
#        ab/state.json, ab-slot.cfg set to fallback=default=committed
#   ac-3 nothing is written when no slot is pending, so a failing committed slot leaves
#        the FAT alone
#   ac-4 the path is best effort: a missing library, an unmounted ESP or an unreadable
#        state never stops the poweroff, and it can mount the ESP itself when needed
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

esp="$tmp/esp"
mkdir -p "$esp/ab" "$esp/boot/grub" "$tmp/bin" "$tmp/run"

# A mount command that records its arguments instead of touching the machine.
cat >"$tmp/bin/mount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${ABANDON_FIXTURE}/mount.calls"
[ "${STUB_MOUNT_FAIL:-0}" = "0" ] || exit 1
# A real `mount -t vfat <dev> <mp>` makes the ESP visible on <mp>; the fixture does the
# same by copying the pristine ESP tree there.
case "$*" in
  *"-t vfat"*)
    for last in "$@"; do :; done
    mkdir -p "${last}" 2>/dev/null
    cp -a "${ABANDON_FIXTURE}/esp-src/." "${last}/" 2>/dev/null
    ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/mount"

export ABANDON_FIXTURE="$tmp"
# Never touch a real serial port from a test: the console mirroring writes to whatever
# WF_SERIAL points at.
: >"$tmp/ttyS0"
: >"$tmp/consoles"
WF_SERIAL="$tmp/ttyS0"
WF_CONSOLES="$tmp/consoles"
WF_ESP_MOUNT="$esp"
WF_ESP_DEV=""
WF_SLOT_CFG_LIB="$root/platform/lib/ab-slot-cfg.sh"
WF_MOUNTS="$tmp/mounts"
WF_MOUNT="$tmp/bin/mount"
WF_TMP="$tmp/run"
export WF_ESP_MOUNT WF_ESP_DEV WF_SLOT_CFG_LIB WF_MOUNTS WF_MOUNT WF_TMP \
  WF_SERIAL WF_CONSOLES

source "$root/initramfs/lib/wf.sh"

write_state() { # <committed> <pending>
  if [ "$2" = "none" ]; then
    cat >"$esp/ab/state.json" <<JSON
{
  "generation": 3,
  "committed": "$1",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
  else
    cat >"$esp/ab/state.json" <<JSON
{
  "generation": 3,
  "committed": "$1",
  "pending": "$2",
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
  fi
}

write_cfg() { # <fallback index> <default index>
  printf 'set fallback=%s\nset default=%s\n' "$1" "$2" >"$esp/boot/grub/ab-slot.cfg"
}

esp_src="$tmp/esp-src"
mkdir -p "$esp_src/ab" "$esp_src/boot/grub"

reset_fixture() {
  rm -f "$tmp/mount.calls" "$esp/ab/state.json"
  write_state a b
  write_cfg 0 1
  rm -rf "$esp_src"
  mkdir -p "$esp_src"
  cp -a "$esp/." "$esp_src/"
  printf '/dev/vda1 %s vfat ro,relatime 0 0\n' "$esp" >"$tmp/mounts"
}

# --------------------------------------------------------------------------- #
# ac-2 the pending slot is abandoned through the shared writer
# --------------------------------------------------------------------------- #

reset_fixture
out="$(wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-2 the abandon path always succeeds"
assert_contains "${out}" "[boot] action=fail-safe-abandon slot=a" \
  "ac-2 the abandon reports the slot the machine will boot"
assert_contains "$(cat "$tmp/ttyS0")" "[boot] action=fail-safe-abandon slot=a" \
  "ac-2 the abandon marker also reaches the serial port"
assert_eq "$(source "$WF_SLOT_CFG_LIB"; ab_slot_state_pending "$esp/ab/state.json")" "none" \
  "ac-2 pending is cleared in ab/state.json"
assert_matches "$(cat "$esp/ab/state.json")" '"generation": 3' \
  "ac-2 the rest of the state file survives"
assert_matches "$(cat "$esp/ab/state.json")" '"upper": "@overlay-25.12.2"' \
  "ac-2 the slot table is untouched"
assert_eq "$(source "$WF_SLOT_CFG_LIB"; ab_slot_cfg_get "$esp/boot/grub/ab-slot.cfg")" "a" \
  "ac-2 the menu default becomes the committed slot"
assert_eq "$(source "$WF_SLOT_CFG_LIB"; ab_slot_cfg_fallback "$esp/boot/grub/ab-slot.cfg")" "a" \
  "ac-2 the fallback is the same committed slot"
assert_contains "$(cat "$tmp/mount.calls")" "-o remount,rw $esp" \
  "ac-2 the read-only ESP is remounted read-write first"

# --------------------------------------------------------------------------- #
# ac-3 a failing committed slot does not touch the write-once surfaces
# --------------------------------------------------------------------------- #

reset_fixture
write_state b none
write_cfg 1 1
before_state="$(cat "$esp/ab/state.json")"
before_cfg="$(cat "$esp/boot/grub/ab-slot.cfg")"
out="$(wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-3 no pending slot is still a successful no-op"
assert_eq "$(cat "$esp/ab/state.json")" "${before_state}" "ac-3 the state file is not rewritten"
assert_eq "$(cat "$esp/boot/grub/ab-slot.cfg")" "${before_cfg}" "ac-3 ab-slot.cfg is not rewritten"
remounts="$(cat "$tmp/mount.calls" 2>/dev/null | grep -c remount || true)"
assert_eq "${remounts}" "0" "ac-3 the CLI does not even remount the ESP"
assert_contains "${out}" "no pending slot to clear" "ac-3 the no-op says why"

# --------------------------------------------------------------------------- #
# ac-4 best effort: never a reason to stay powered on
# --------------------------------------------------------------------------- #

# Library missing from this initramfs (an older image, or a stripped build).
out="$(WF_SLOT_CFG_LIB=/nonexistent/ab-slot-cfg.sh wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 a missing writer library still succeeds"
assert_contains "${out}" "fail-safe abandon skipped" "ac-4 a missing library is reported"

# ESP not mounted and no device to mount: nothing can be written, nothing explodes.
reset_fixture
before_state="$(cat "$esp/ab/state.json")"
: >"$tmp/mounts"
out="$(WF_ESP_MOUNT="$tmp/esp-gone" WF_ESP_DEV="" wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 an unmounted ESP still succeeds"
assert_contains "${out}" "the ESP is not mounted" "ac-4 an unmounted ESP is reported"
assert_eq "$(cat "$esp/ab/state.json")" "${before_state}" "ac-4 an unmounted ESP writes nothing"
assert_eq "$([ -e "$tmp/esp-gone" ] && echo created || echo absent)" "absent" \
  "ac-4 no mount point is invented without a device"

# The ESP is not mounted yet, but the initramfs knows its device: mount it and abandon.
reset_fixture
: >"$tmp/mounts"
esp_by_dev="$tmp/esp-by-dev"
out="$(WF_ESP_MOUNT="${esp_by_dev}" WF_ESP_DEV=/dev/vda1 wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 mounting the ESP itself succeeds"
assert_contains "$(cat "$tmp/mount.calls")" "-t vfat -o rw,noatime /dev/vda1 ${esp_by_dev}" \
  "ac-4 the ESP device is mounted read-write for the write"
assert_contains "${out}" "slot=a" "ac-4 the abandon still lands after mounting"
assert_eq "$(source "$WF_SLOT_CFG_LIB"; ab_slot_state_pending "${esp_by_dev}/ab/state.json")" "none" \
  "ac-4 the pending slot is cleared after the mount"

# An unreadable state file is reported and never blocks the caller.
reset_fixture
rm -f "$esp/ab/state.json"
out="$(wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 a missing state file still succeeds"
assert_contains "${out}" "skipped" "ac-4 a missing state file is reported"

# A failed remount is reported and does not stop the attempt.
reset_fixture
out="$(STUB_MOUNT_FAIL=1 wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 a failed remount still succeeds"
assert_contains "${out}" "cannot remount" "ac-4 a failed remount is reported"

# The writer's own failure is reported with its reason instead of a traceback.
cat >"$tmp/bin/failing-slot-cfg.sh" <<'STUB'
AB_SLOT_CFG_REASON=''
ab_slot_state_pending() { printf '%s' "${STUB_PENDING:-b}"; }
ab_slot_cfg_write_committed() { AB_SLOT_CFG_REASON='cannot-write'; return 1; }
STUB
reset_fixture
out="$(WF_SLOT_CFG_LIB="$tmp/bin/failing-slot-cfg.sh" wf_failsafe_abandon)"
assert_eq "$?" "0" "ac-4 a failing writer still succeeds"
assert_contains "${out}" "action=fail-safe-abandon result=fail reason=cannot-write" \
  "ac-4 a failed abandon reports the writer's reason"

# --------------------------------------------------------------------------- #
# ac-1 the failure path itself
# --------------------------------------------------------------------------- #

wf_lib="$(cat "$root/initramfs/lib/wf.sh")"
fail_body="$(printf '%s' "${wf_lib}" | sed -n '/^wf_fail() {/,/^}/p')"
assert_contains "${fail_body}" "wf_failsafe_abandon || :" \
  "ac-1 wf_fail takes the fail-safe path"
abandon_line=$(printf '%s\n' "${fail_body}" | grep -n 'wf_failsafe_abandon' | cut -d: -f1 | head -n1)
judge_line=$(printf '%s\n' "${fail_body}" | grep -n 'S3-RESULT=fail' | cut -d: -f1 | head -n1)
poweroff_line=$(printf '%s\n' "${fail_body}" | grep -n 'poweroff' | cut -d: -f1 | head -n1)
assert_eq "$((abandon_line < judge_line))" "1" \
  "ac-1 the abandon happens before the judge line, so a harness cannot cut it short"
assert_eq "$((judge_line < poweroff_line))" "1" \
  "ac-1 the judge line and the poweroff keep their order"
assert_eq "$(printf '%s\n' "${fail_body}" | grep -c 'exit 1')" "1" \
  "ac-1 the failure exit is still there"

boot_init="$(cat "$root/initramfs/boot/init")"
assert_contains "${boot_init}" 'WF_ESP_DEV="${esp}"' \
  "ac-4 the init tells the failure path which ESP device to mount"
assert_contains "$boot_init" '[ -n "${esp}" ] || wf_fail no-block-device' \
  "ac-1 a boot without any ESP partition still fails, through the new path"

# The builder has to carry the writer into the initramfs, byte for byte.
builder="$(cat "$root/scripts/ci/initramfs.sh")"
assert_contains "${builder}" 'platform/lib/ab-slot-cfg.sh' \
  "ac-2 the builder stages the shared slot-config writer"
assert_contains "${builder}" 'cmp -s "${shared}" "${stage}/lib/$(basename "${shared}")"' \
  "ac-2 the staged copy is compared with the source"

finish
