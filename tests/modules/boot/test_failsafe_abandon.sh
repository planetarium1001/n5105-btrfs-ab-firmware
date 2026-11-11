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
mkdir -p "$esp/ab" "$esp/boot/grub" "$tmp/bin" "$tmp/run" "$tmp/p4"

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
# The p4 side is the second landing zone: when the ESP is the thing that is broken, the
# evidence has to go somewhere else on the same disk.
WF_P4_MOUNT="$tmp/p4"
export WF_ESP_MOUNT WF_ESP_DEV WF_SLOT_CFG_LIB WF_MOUNTS WF_MOUNT WF_TMP \
  WF_SERIAL WF_CONSOLES WF_P4_MOUNT

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

# --------------------------------------------------------------------------- #
# ac-4 the evidence order on the failure path: breadcrumb -> judge line -> poweroff
#
# Asserted at run time, not in the source: the three writers land in one trace file (the
# breadcrumb log, the serial mirror and the poweroff stub), so the line numbers are the
# order the machine actually produces. A poweroff that runs before the breadcrumb leaves
# nothing on the disk to read afterwards - which is exactly the defect this fixes.
# --------------------------------------------------------------------------- #

trace="$tmp/order.log"
: >"$trace"
cat >"$tmp/bin/poweroff" <<STUB
#!/bin/sh
printf 'poweroff %s\n' "\$*" >>"${trace}"
STUB
cat >"$tmp/bin/sync" <<'STUB'
#!/bin/sh
printf 'sync\n' >>"${SYNC_TRACE:-/dev/null}"
STUB
chmod +x "$tmp/bin/poweroff" "$tmp/bin/sync"
export PATH="$tmp/bin:$PATH" SYNC_TRACE="$trace"

rm -f "$tmp/p4/.ab/init-fail.log"
out="$(WF_MARK_LOG="$trace" WF_SERIAL="$trace" WF_CONSOLES="$tmp/consoles" \
  WF_ESP_MOUNT="$tmp/esp-absent" WF_ESP_DEV="" wf_fail order-test 2>&1)"
rc=$?
assert_eq "${rc}" "1" "ac-4 wf_fail still exits 1 after the poweroff"
assert_contains "${out}" "S3-RESULT=fail reason=order-test" \
  "ac-4 the judge line still names the reason"

mark_line=$(grep -n 'step=fail reason=order-test' "$trace" | head -n 1 | cut -d: -f1)
judge_line=$(grep -n 'S3-RESULT=fail reason=order-test' "$trace" | head -n 1 | cut -d: -f1)
poweroff_line=$(grep -n '^poweroff' "$trace" | head -n 1 | cut -d: -f1)
mark_line=${mark_line:-0}
judge_line=${judge_line:-0}
poweroff_line=${poweroff_line:-0}
assert_eq "$([ "${mark_line}" -gt 0 ] && echo written)" "written" \
  "ac-4 the breadcrumb is written to the log at all"
assert_eq "$([ "${mark_line}" -lt "${judge_line}" ] && echo ordered)" "ordered" \
  "ac-4 the breadcrumb is written before the judge line (${mark_line} < ${judge_line})"
assert_eq "$([ "${judge_line}" -lt "${poweroff_line}" ] && echo ordered)" "ordered" \
  "ac-4 the judge line is written before the poweroff (${judge_line} < ${poweroff_line})"
synced_between="$(sed -n "$((judge_line + 1)),$((poweroff_line - 1))p" "$trace" \
  | grep -c '^sync$' || true)"
assert_eq "$([ "${synced_between}" -ge 1 ] && echo synced)" "synced" \
  "ac-4 the judge line is synced before the machine powers off"
assert_contains "$(cat "$tmp/p4/.ab/init-fail.log" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=esp-not-mounted" \
  "ac-4 the abandon evidence of the same failure is on disk, on the p4 side"

# --------------------------------------------------------------------------- #
# ac-5 every abandon branch leaves exactly one evidence line, on ESP or on p4
# --------------------------------------------------------------------------- #

p4_evidence="$tmp/p4/.ab/init-fail.log"
esp_evidence="$esp/ab/log/boot-0.log"

# (1) writer library missing from this initramfs: skip, and the line survives the ESP
# being unusable. The serial port is pointed at a path that does not exist on purpose:
# "evidence" that only ever reached a UART is what this acceptance is fixing.
reset_fixture
: >"$tmp/mounts"
rm -f "$p4_evidence"
out="$(WF_SLOT_CFG_LIB=/nonexistent/ab-slot-cfg.sh WF_ESP_MOUNT="$tmp/esp-absent" \
  WF_ESP_DEV="" WF_SERIAL="$tmp/absent-ttyS0" wf_failsafe_abandon)"
rc=$?
assert_eq "${rc}" "0" "ac-5 a missing library still returns 0"
assert_contains "$(cat "$p4_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=lib-missing" \
  "ac-5 a missing library leaves its line on p4 without a serial port"

# (2) the ESP cannot be reached at all: skip, with the reason that says so.
reset_fixture
: >"$tmp/mounts"
rm -f "$p4_evidence"
out="$(WF_ESP_MOUNT="$tmp/esp-absent" WF_ESP_DEV="" wf_failsafe_abandon)"
rc=$?
assert_eq "${rc}" "0" "ac-5 an unreachable ESP still returns 0"
assert_contains "$(cat "$p4_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=esp-not-mounted" \
  "ac-5 an unmounted ESP is recorded as esp-not-mounted"

# (3) the ESP is there but the mount itself fails: same branch, its own reason.
reset_fixture
: >"$tmp/mounts"
rm -f "$p4_evidence"
out="$(STUB_MOUNT_FAIL=1 WF_ESP_MOUNT="$tmp/esp-absent" WF_ESP_DEV=/dev/vda1 \
  wf_failsafe_abandon)"
rc=$?
assert_eq "${rc}" "0" "ac-5 a failed mount still returns 0"
assert_contains "$(cat "$p4_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=esp-not-writable" \
  "ac-5 a mount that fails is recorded as esp-not-writable"

# (4) the writer itself fails: the line cannot go to the ESP, so it goes to p4.
reset_fixture
rm -f "$p4_evidence"
out="$(WF_SLOT_CFG_LIB="$tmp/bin/failing-slot-cfg.sh" wf_failsafe_abandon)"
rc=$?
assert_eq "${rc}" "0" "ac-5 a failing writer still returns 0"
assert_contains "$(cat "$p4_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=fail reason=cannot-write" \
  "ac-5 a failed write is recorded as result=fail on the p4 side"
assert_eq "$(cat "$esp/ab/state.json" | grep -c '"pending": "b"' || true)" "1" \
  "ac-5 ... and the ESP really was not rewritten"

# (5) success: the line lands next to the state file it just rewrote.
reset_fixture
rm -f "$esp_evidence"
out="$(wf_failsafe_abandon)"
rc=$?
assert_eq "${rc}" "0" "ac-5 a successful abandon still returns 0"
assert_contains "$(cat "$esp_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=ok reason=none slot=a" \
  "ac-5 a successful abandon is recorded on the ESP with the slot it picked"
assert_eq "$(grep -c 'action=fail-safe-abandon' "$esp_evidence")" "1" \
  "ac-5 exactly one evidence line per branch"

# --------------------------------------------------------------------------- #
# ac-6 the already-mounted ESP is never mounted a second time
#
# The read-only mount at boot time is the normal case. When ab/state.json is not readable
# from it, the old code re-mounted the same device on the same mount point, which cannot
# succeed ("already mounted or mount point busy") and buried the real reason.
# --------------------------------------------------------------------------- #

reset_fixture
rm -f "$esp/ab/state.json" "$p4_evidence"
: >"$tmp/mount.calls"
# WF_ESP_DEV is set on purpose: that is the case the old code turned into a second
# `mount -t vfat` of a device that was already mounted there.
out="$(WF_ESP_DEV=/dev/vda1 wf_failsafe_abandon)"
rc=$?
mount_calls=$(wc -l <"$tmp/mount.calls" | tr -d ' ')
assert_eq "${rc}" "0" "ac-6 an unreadable state file still returns 0"
assert_eq "$([ "${mount_calls}" -le 1 ] && echo "at-most-one(${mount_calls})")" \
  "at-most-one(${mount_calls})" \
  "ac-6 the abandon makes at most one mount call, and here it makes ${mount_calls}"
assert_eq "$(grep -c -- '-t vfat' "$tmp/mount.calls" || true)" "0" \
  "ac-6 the already-mounted ESP is not mounted a second time"
assert_contains "${out}" "state-unreadable" \
  "ac-6 the reported reason names the unreadable state"
assert_contains "$(cat "$p4_evidence" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=state-unreadable" \
  "ac-6 the unreadable state is recorded on the p4 side"
assert_eq "$([ -e "$esp/ab/state.json" ] && echo written || echo absent)" "absent" \
  "ac-6 no half-write is left behind on the ESP"


# --------------------------------------------------------------------------- #
# the p4 side on the two failure paths the 05:36 poweroff is blamed on
#
# `esp-mount-failed` and `state-missing` are the leading candidates for a boot that died
# early, and they are exactly the cases in which the ESP cannot hold the evidence. Until the
# p4 root subvolume was mounted *before* the ESP (init 3c) the p4 fallback had nowhere to go
# either - `wf_mark_zone_p4` tests a directory that was only created much later - so those
# failures were serial-only, and a machine that powers itself off hands its serial log to
# nobody. These cases run the init's own order from a p4 directory that does not exist yet.
# --------------------------------------------------------------------------- #

order_bin="$tmp/bin-order"
mkdir -p "$order_bin"
cat >"$order_bin/mount" <<'STUB'
#!/bin/sh
# A mount that behaves like the kernel in the one way that matters: the mount point is
# created, the mount table gains a line, and the call either succeeds or fails.
for _order_arg in "$@"; do :; done
printf '%s\n' "$*" >>"${ORDER_FIXTURE}/order-mount.calls"
case " $* " in
    *" -t vfat "*) [ "${STUB_VFAT_FAIL:-0}" = "0" ] || exit 1 ;;
esac
mkdir -p "${_order_arg}" 2>/dev/null || :
printf '/dev/x %s %s rw 0 0\n' "${_order_arg}" "${STUB_FSTYPE:-btrfs}" \
    >>"${ORDER_FIXTURE}/order-mounts"
exit 0
STUB
chmod +x "$order_bin/mount"
export ORDER_FIXTURE="$tmp"

p4_fresh="$tmp/p4-fresh"
esp_fresh="$tmp/esp-fresh"

# order_fixture <state|no-state>: an ESP tree, an empty mount table and a p4 directory that is
# deliberately *not* created here - the mount in the case below is what brings it into being.
# The mount table starts empty because nothing is mounted yet at that point in the boot; the
# mount stub adds a line only for a mount that really succeeded.
order_fixture() {
    rm -rf "$p4_fresh" "$esp_fresh"
    mkdir -p "$esp_fresh/ab/log"
    : >"$tmp/order-mounts"
    cat >"$esp_fresh/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": "b",
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
    [ "${1:-state}" = "state" ] || rm -f "$esp_fresh/ab/state.json"
    : >"$tmp/order-mount.calls"
    : >"$tmp/order-ttyS0"
}

# order_boot <p4|esp-only> [<vfat-fails>]: the boot-side lines of init, in init's order.
#   p4        3c: the p4 root subvolume is mounted, and the breadcrumb log armed on it
#   esp-only  the order this unit replaced: the ESP is attempted with no p4 mount at all
# It then attempts the ESP mount and takes the failure path when that or the state fails,
# which is where `esp-mount-failed` and `state-missing` come from.
order_boot() {
    (
        PATH="$order_bin:$PATH"
        export PATH
        WF_SERIAL="$tmp/order-ttyS0"
        WF_CONSOLES="$tmp/consoles"
        WF_MOUNTS="$tmp/order-mounts"
        WF_MOUNT="$order_bin/mount"
        WF_ESP_MOUNT="$esp_fresh"
        WF_ESP_DEV=""
        WF_P4_MOUNT="$p4_fresh"
        WF_SLOT_CFG_LIB="$root/platform/lib/ab-slot-cfg.sh"
        WF_TMP="$tmp/run"
        WF_MARK_LOG=""
        export WF_SERIAL WF_CONSOLES WF_MOUNTS WF_MOUNT WF_ESP_MOUNT WF_ESP_DEV \
            WF_P4_MOUNT WF_SLOT_CFG_LIB WF_TMP WF_MARK_LOG
        # Exported, not just set: the mount stub is a separate process and reads it from its
        # own environment.
        STUB_VFAT_FAIL="${2:-0}"
        export STUB_VFAT_FAIL
        # shellcheck source=../../../initramfs/lib/wf.sh
        . "$root/initramfs/lib/wf.sh"

        if [ "${1}" != "esp-only" ]; then
            mkdir -p "${WF_P4_MOUNT}" 2>/dev/null || :
            "${WF_MOUNT}" -o rw,noatime,compress=zstd:6,discard=async,"subvol=/" \
                /dev/vda4 "${WF_P4_MOUNT}" >/dev/null 2>&1 || :
            WF_MARK_LOG="$(wf_mark_zone)"
            export WF_MARK_LOG
        fi
        if ! "${WF_MOUNT}" -t vfat -o rw,noatime /dev/vda1 "${WF_ESP_MOUNT}" >/dev/null 2>&1; then
            esp_mount="fail"
        else
            esp_mount="rw"
            WF_MARK_LOG="$(wf_mark_zone)"
            export WF_MARK_LOG
        fi
        wf_mark esp-mounted "mount=${esp_mount}"
        [ "${esp_mount}" = "rw" ] || wf_fail esp-mount-failed
        STATE="${WF_ESP_MOUNT}/ab/state.json"
        [ -f "${STATE}" ] || wf_fail state-missing
    ) >/dev/null 2>&1
}

# (1) esp-mount-failed, with the p4 side mounted first: the evidence is on that disk.
# The ESP cannot be mounted, so nothing on it can be reached either - not even the state file.
order_fixture no-state
order_boot p4 1
p4_evidence="$p4_fresh/.ab/init-fail.log"
assert_contains "$(cat "${p4_evidence}" 2>/dev/null)" \
  "step=fail reason=esp-mount-failed" \
  "A a failed ESP mount leaves its breadcrumb on the p4 disk, not only on the serial port"
assert_contains "$(cat "${p4_evidence}" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=esp-not-mounted" \
  "A ... and the fail-safe abandon of the same failure is next to it"
assert_eq "$([ -e "$esp_fresh/ab/log/boot-0.log" ] && echo wrote || echo none)" "none" \
  "A nothing was written into the ESP that could not be mounted"

# (2) the same failure with the ESP attempted first (the order this unit replaced): nothing
#     lands on disk at all. The check is what makes (1) evidence of the fix rather than of a
#     fixture that happened to pre-create the directory.
order_fixture state
order_boot esp-only 1
assert_eq "$([ -e "${p4_fresh}/.ab/init-fail.log" ] && echo wrote || echo none)" "none" \
  "A without the early p4 mount the same failure is serial-only, which is the defect"

# (3) state-missing: the ESP mounts, has no ab/state.json, and the breadcrumb has to be on it.
order_fixture no-state
order_boot p4 0
esp_evidence="$esp_fresh/ab/log/boot-0.log"
assert_contains "$(cat "${esp_evidence}" 2>/dev/null)" \
  "step=fail reason=state-missing" \
  "A a missing state file leaves its breadcrumb in the ESP ring log"
# The state file is unreadable, so the abandon evidence is deliberately sent to the *other*
# surface (p4), not to the ESP whose state is the thing that cannot be read.
assert_contains "$(cat "$p4_fresh/.ab/init-fail.log" 2>/dev/null)" \
  "action=fail-safe-abandon result=skip reason=state-unreadable" \
  "A ... with the abandon evidence on the other surface, which is the readable one"
assert_contains "$(cat "$tmp/order-ttyS0")" \
  "S3-RESULT=fail reason=state-missing" \
  "A the serial mirror still carries the judge line, but it is no longer the only copy"

finish
