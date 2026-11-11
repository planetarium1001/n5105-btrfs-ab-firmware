#!/usr/bin/env bash
# Module: boot
# The boot breadcrumbs of initramfs/boot/init: the milestones a boot passes, and where the
# lines they leave are allowed to land. A machine that powers itself off cannot hand a
# serial log to anyone, so both halves of this are evidence.
#   ac-2 eight milestones - device, grow-done, esp-mounted, state, p4-record, overlay,
#        esp-unmounted, switching-root - each write one breadcrumb, in that order, and the
#        ESP is mounted *after* the growth has run (a mount would make `blockdev --rereadpt`
#        fail, and "the mount line comes later" is the mechanical gate that keeps it so)
#   ac-3 a breadcrumb never lands in a path that is not there yet: nothing under
#        ${WF_ESP_MOUNT} before the mount, the p4 side when the ESP is gone, the serial
#        port when neither is available, and never a tmpfs directory that a later mount
#        hides (the defect that once swallowed a whole boot's growth diagnostics)
#
# The order is asserted by line number, on the source: init is PID 1 and cannot be run from
# a fixture, and its sections are what a reviewer reads anyway. The landing zones are
# asserted at run time, through the real initramfs/lib/wf.sh, by walking the same ladder the
# init walks.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

boot_init="$root/initramfs/boot/init"
init_src="$(cat "$boot_init")"

# lines_of <ere>: the line numbers of the code lines matching it. Comment lines are left
# out on purpose - init's header quotes the old defect, and a comment is not a call site.
lines_of() {
  printf '%s\n' "$init_src" | awk -v pat="$1" '!/^[[:space:]]*#/ && $0 ~ pat { print NR }'
}

# first_line <ere>: the first such line number, 0 when there is none.
first_line() { lines_of "$1" | head -n1 | tr -d ' '; }

# count_of <ere>: how many code lines match.
count_of() { lines_of "$1" | wc -l | tr -d ' '; }

# --------------------------------------------------------------------------- #
# ac-2 the eight milestones, once each, in the documented order
# --------------------------------------------------------------------------- #

steps="device grow-done esp-mounted state p4-record overlay esp-unmounted switching-root"
assert_eq "$(count_of '^[[:space:]]*wf_mark [a-z]')" "8" \
  "ac-2 init writes exactly the eight documented milestones and nothing else"

for step in $steps; do
  assert_eq "$(count_of "^[[:space:]]*wf_mark ${step}([[:space:]]|\$)")" "1" \
    "ac-2 the ${step} milestone has exactly one call site"
done

prev=0
for step in $steps; do
  line="$(first_line "^[[:space:]]*wf_mark ${step}([[:space:]]|\$)")"
  assert_eq "$((line > prev))" "1" \
    "ac-2 ${step} comes after the milestone before it (line ${line} > ${prev})"
  prev="$line"
done

# --------------------------------------------------------------------------- #
# ac-2 the ESP is mounted after the growth, and the gate is mechanical
# --------------------------------------------------------------------------- #
# `blockdev --rereadpt` / `partx -u` need the disk to carry no mounted partition, so the
# first landing zone cannot exist before the table has been rewritten. This assertion is
# what a later change that "optimises" the order has to fail.
grow_line="$(first_line 'wf_grow_run')"
mount_line="$(first_line 'mount -t vfat')"
assert_eq "$((grow_line > 0))" "1" "ac-2 the growth has a call site in the boot path"
assert_eq "$((mount_line > 0))" "1" "ac-2 the ESP mount has a call site in the boot path"
assert_eq "$((mount_line > grow_line))" "1" \
  "ac-2 the ESP mount (line ${mount_line}) comes after wf_grow_run (line ${grow_line})"
assert_eq "$(count_of 'mount -t vfat')" "1" \
  "ac-2 there is exactly one ESP mount, so the order above cannot be dodged by a second one"

# --------------------------------------------------------------------------- #
# ac-3 no breadcrumb lands anywhere before the ESP exists
# --------------------------------------------------------------------------- #

# Nothing is mentioned under the mount point before it is mounted - not a log, not a state
# file, not a probe buffer. A directory on the initramfs tmpfs is not the ESP: a line
# written there is covered by the real mount and thrown away with the initramfs.
early_esp="$(lines_of '/esp/' | awk -v m="$mount_line" '$1 <= m' | wc -l | tr -d ' ')"
assert_eq "${early_esp}" "0" \
  "ac-3 no code line touches a path under /esp before the mount (line ${mount_line})"

# The landing zone is resolved from the mount table, never spelled out: wf_mark_zone is what
# makes "this is mounted" and "this is writable" the same question. It is re-resolved once per
# zone, so the log always follows the disk that exists at that moment:
#
#   1. the p4 root subvolume (3c)  - the arm that makes `esp-mount-failed` land on a disk
#   2. the ESP, once it is mounted - the primary zone for the rest of the boot
#   3. the p4 generation layer     - after the ESP has been given back
p4root_mount_line="$(first_line 'mount -o rw,noatime,compress=zstd:6,discard=async,"subvol=/"')"
mark_logs="$(lines_of '^[[:space:]]*WF_MARK_LOG=')"
first_log="$(printf '%s\n' "${mark_logs}" | sed -n 1p)"
second_log="$(printf '%s\n' "${mark_logs}" | sed -n 2p)"
third_log="$(printf '%s\n' "${mark_logs}" | sed -n 3p)"
assert_eq "$(printf '%s\n' "${mark_logs}" | wc -l | tr -d ' ')" "3" \
  "ac-3 the breadcrumb log is armed once per landing zone"
assert_eq "$(count_of '^[[:space:]]*WF_MARK_LOG="[$][(]wf_mark_zone[)]["]$')" "3" \
  "ac-3 ... and every time by wf_mark_zone, never by a path spelled out here"
assert_eq "$((first_log > p4root_mount_line))" "1" \
  "ac-3 the log is armed right after the p4 root subvolume is mounted"
assert_eq "$((first_log < mount_line))" "1" \
  "ac-3 ... before the ESP mount, so a failure there already has a disk to write to"
assert_eq "$((second_log > mount_line))" "1" \
  "ac-3 the log moves to the ESP once it is mounted"
assert_eq "$((second_log < $(first_line 'wf_mark esp-mounted')))" "1" \
  "ac-3 ... before the first milestone that uses it"
assert_eq "$((third_log > $(first_line 'umount /esp')))" "1" \
  "ac-3 the log moves to the p4 layer after the ESP is given back"
assert_eq "$((third_log < $(first_line 'wf_mark esp-unmounted')))" "1" \
  "ac-3 ... before the milestone that reports it"

# The p4 root subvolume is mounted *before* the ESP, so the p4 landing zone already exists on
# the two failure paths the 05:36 poweroff is blamed on (`esp-mount-failed`, `state-missing`):
# until it did, those failures were serial-only, which is the defect this unit fixes.
p4root_zone_line="$(first_line '^[[:space:]]*WF_P4_MOUNT="/mnt/p4root"$')"
assert_eq "$(count_of '^[[:space:]]*WF_P4_MOUNT="/mnt/p4root"$')" "1" \
  "ac-3 the p4 root subvolume is named as a landing zone exactly once"
assert_eq "$((p4root_mount_line > grow_line))" "1" \
  "ac-3 the p4 root mount stays after the growth (a mount would break the table reread)"
assert_eq "$((p4root_mount_line < mount_line))" "1" \
  "ac-3 ... and before the ESP mount, so the p4 side exists when the ESP is already broken"
assert_eq "$((p4root_zone_line <= p4root_mount_line + 3))" "1" \
  "ac-3 the zone is armed together with that mount, not somewhere else in the file"

# Once the root subvolume is given back, nothing may point at /mnt/p4root any more: from then
# on it is a bare tmpfs directory and a line written there disappears with the initramfs.
clear_line="$(first_line '^WF_P4_MOUNT=""$')"
umount_p4root_line="$(first_line 'umount /mnt/p4root')"
gen_mount_line="$(first_line '/mnt/p4; then')"
assert_eq "$((clear_line > umount_p4root_line))" "1" \
  "ac-3 the p4 zone is cleared as soon as the root subvolume is given back"
assert_eq "$((clear_line < gen_mount_line))" "1" \
  "ac-3 ... before the generation mount takes over the zone"

# The generation's writable layer is the zone from the moment it is mounted - armed before
# the compress assertion that can already fail the boot, so that breadcrumb lands on a disk.
unmount_esp_step="$(first_line 'wf_mark esp-unmounted')"
p4_zone_line="$(first_line '^[[:space:]]*WF_P4_MOUNT="/mnt/p4"$')"
assert_eq "$((p4_zone_line > gen_mount_line))" "1" \
  "ac-3 the generation layer becomes the zone after it is mounted"
compress_fail_line="$(lines_of 'wf_fail p4-compress-option-missing' | tail -n1)"
assert_eq "$((compress_fail_line > p4_zone_line))" "1" \
  "ac-3 the compress failure in 5b happens with /mnt/p4 already mounted and armed"
assert_eq "$((p4_zone_line < unmount_esp_step))" "1" \
  "ac-3 ... and before the first milestone that needs it"

# A degraded boot has no writable partition: /mnt/p4 is a tmpfs, so it is not a zone.
# Three branches can leave the p4 side without a disk behind it: the root subvolume that will
# not mount, the moment it is given back, and a degraded boot whose /mnt/p4 is a tmpfs. Each
# one clears the zone instead of letting a breadcrumb land in a file no disk ever held.
assert_eq "$(count_of '^[[:space:]]*WF_P4_MOUNT=""$')" "3" \
  "ac-3 every branch that leaves the p4 side unwritable clears the zone"

# --------------------------------------------------------------------------- #
# ac-3 the ladder itself, run against the real helpers
# --------------------------------------------------------------------------- #
# init goes through four states, and each one has exactly one correct answer to "where
# would a breadcrumb go". Each phase runs in a subshell, because wf_mark's sequence lives in
# the caller's shell, and each one starts from the state init is in at that moment.

esp="$tmp/esp"
p4="$tmp/mnt/p4"
p4root="$tmp/mnt/p4root"
mkdir -p "$esp/ab/log" "$p4" "$p4root" "$tmp/run"
: >"$tmp/ttyS0"
: >"$tmp/consoles"
: >"$tmp/mounts"

# ladder <p4 mount point> <resolve|-> <step>: emit one milestone the way init does.
ladder() {
  (
    WF_SERIAL="$tmp/ttyS0"
    WF_CONSOLES="$tmp/consoles"
    WF_MOUNTS="$tmp/mounts"
    WF_ESP_MOUNT="$esp"
    WF_P4_MOUNT="$1"
    WF_TMP="$tmp/run"
    WF_MARK_LOG=""
    export WF_SERIAL WF_CONSOLES WF_MOUNTS WF_ESP_MOUNT WF_P4_MOUNT WF_TMP WF_MARK_LOG
    # shellcheck source=../../../initramfs/lib/wf.sh
    . "$root/initramfs/lib/wf.sh"
    if [ "$2" = "resolve" ]; then
      WF_MARK_LOG="$(wf_mark_zone)"
      export WF_MARK_LOG
    fi
    wf_mark "$3" >/dev/null
  )
}

# Phase 1: before the growth nothing is mounted and no zone exists, so the milestone is a
# serial line and no file appears anywhere.
ladder "$p4root" - device
assert_eq "$(find "$p4root" -name '*log*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 with nothing mounted the milestone writes no file at all"
assert_contains "$(cat "$tmp/ttyS0")" "stage=mark seq=1 step=device" \
  "ac-3 ... it reaches the serial port, the only channel that exists yet"

# Phase 2: the ESP is mounted, so it is the first landing zone.
printf '/dev/vda1 %s vfat rw,noatime 0 0\n' "$esp" >"$tmp/mounts"
ladder "$p4root" resolve esp-mounted
assert_eq "$(cat "$esp/ab/log/boot-0.log")" "stage=mark seq=1 step=esp-mounted" \
  "ac-3 once the ESP is mounted the milestone lands in its ring log"

# Phase 3: the ESP is unmounted, the generation's writable layer is not.
: >"$tmp/mounts"
ladder "$p4" resolve esp-unmounted
assert_eq "$(cat "$p4/.ab/init-fail.log")" "stage=mark seq=1 step=esp-unmounted" \
  "ac-3 with the ESP gone the milestone lands on the p4 side"
assert_eq "$(find "$p4root" -name 'init-fail.log' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 ... and never in the bare /mnt/p4root directory, which is a tmpfs by then"

# Phase 4: a degraded boot, where p4 is a tmpfs, so there is no zone at all.
ladder "" resolve switching-root
assert_contains "$(cat "$tmp/ttyS0")" "step=switching-root" \
  "ac-3 a boot with no writable partition still reports its last milestone"
assert_eq "$(find "$p4" "$p4root" -name 'init-fail.log' 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "ac-3 ... and writes nothing new on either side"

# --------------------------------------------------------------------------- #
# ac-2 the source stays POSIX sh: init runs under the initramfs busybox
# --------------------------------------------------------------------------- #

assert_command_ok "ac-2 initramfs/boot/init parses as POSIX sh with dash" sh -n "$boot_init"
assert_contains "$(cat "$boot_init")" '. /lib/wf.sh' \
  "ac-2 the init sources the breadcrumb primitive instead of reimplementing it"

finish
