#!/usr/bin/env bash
# Module: boot
# wf_mark is the breadcrumb primitive: "how far did this boot get, and why did it stop".
# A machine that powers itself off cannot hand a serial log to anyone, so the evidence has
# to be a line on a disk. The contract asserted here is the one unit 02 wires into boot:
#   ac-1 one `stage=mark seq=<n> step=<step> [k=v...]` line per call on WF_MARK_LOG, synced
#   ac-2 seq is monotonic and continues from whatever the file already holds, never from 1
#   ac-3 the log is capped at 32 KiB: the newest lines survive and one TRUNCATED=1 line is
#        left behind, written through a temporary file (never truncated in place)
#   ac-4 no landing zone yet (WF_MARK_LOG unset): no file is written, the call returns 0 and
#        the milestone still reaches the serial console
#   ac-5 the landing zone order is ESP (already mounted) -> p4 -> serial only
#   ac-6 the file itself stays POSIX sh: it runs under the initramfs busybox
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/run" "$tmp/esp/ab/log" "$tmp/p4" "$tmp/dev"
cat >"$tmp/bin/sync" <<'STUB'
#!/bin/sh
# The real sync is slow and invisible; the fixture counts the calls instead. A breadcrumb
# that is appended but not synced is exactly the line a power cut eats.
printf 'sync\n' >>"${MARK_FIXTURE}/sync.calls"
STUB
chmod +x "$tmp/bin/sync"
export PATH="$tmp/bin:$PATH"

export MARK_FIXTURE="$tmp"
# Never touch a real serial port or a real mount table from a test.
: >"$tmp/ttyS0"
: >"$tmp/consoles"
: >"$tmp/mounts"

WF_SERIAL="$tmp/ttyS0"
WF_CONSOLES="$tmp/consoles"
WF_MOUNTS="$tmp/mounts"
WF_MOUNT="$tmp/bin/mount"
WF_ESP_MOUNT="$tmp/esp"
WF_ESP_DEV=""
WF_P4_MOUNT="$tmp/p4"
WF_SLOT_CFG_LIB="$root/platform/lib/ab-slot-cfg.sh"
WF_TMP="$tmp/run"
export WF_SERIAL WF_CONSOLES WF_MOUNTS WF_MOUNT WF_ESP_MOUNT WF_ESP_DEV \
  WF_P4_MOUNT WF_SLOT_CFG_LIB WF_TMP

source "$root/initramfs/lib/wf.sh"

mark_log="$tmp/esp/ab/log/boot-0.log"

# --------------------------------------------------------------------------- #
# ac-1 one line per call, in the documented shape, synced
# --------------------------------------------------------------------------- #

WF_MARK_LOG="$mark_log"
export WF_MARK_LOG
assert_eq "$(wf_mark device)" "" \
  "ac-1 wf_mark is silent on stdout when it has a file to write"
assert_file_exists "$mark_log" "ac-1 the first call creates the log"
assert_eq "$(cat "$mark_log")" "stage=mark seq=1 step=device" \
  "ac-1 the line carries the stage, the sequence and the step"

wf_mark state committed=a slot_dev=/dev/vda2 >/dev/null
assert_eq "$(tail -n 1 "$mark_log")" "stage=mark seq=2 step=state committed=a slot_dev=/dev/vda2" \
  "ac-1 extra key=value pairs follow the step verbatim"
assert_eq "$(wc -l <"$mark_log" | tr -d ' ')" "2" \
  "ac-1 one line per call, no blank lines"

assert_eq "$(wc -l <"$tmp/sync.calls" | tr -d ' ')" "4" \
  "ac-1 every call syncs before and after the rename (2 per line)"

# --------------------------------------------------------------------------- #
# ac-2 the sequence survives the process: it is read back from the file
# --------------------------------------------------------------------------- #

WF_MARK_LOG="$tmp/esp/ab/log/continued.log"
export WF_MARK_LOG
printf 'stage=mark seq=41 step=earlier\n' >"$WF_MARK_LOG"
wf_mark esp-mounted >/dev/null
wf_mark state >/dev/null
assert_eq "$(sed -n '2p' "$WF_MARK_LOG")" "stage=mark seq=42 step=esp-mounted" \
  "ac-2 the sequence continues from the last line the file holds"
assert_eq "$(sed -n '3p' "$WF_MARK_LOG")" "stage=mark seq=43 step=state" \
  "ac-2 and keeps counting up across calls"
assert_eq "$(sed -n '1p' "$WF_MARK_LOG")" "stage=mark seq=41 step=earlier" \
  "ac-2 earlier lines are preserved, the log is append-only"

# A file that was written by an older boot after a rotation hole: the highest sequence
# wins, so the number in the log can never go backwards within one file.
WF_MARK_LOG="$tmp/esp/ab/log/continued.log"
export WF_MARK_LOG
printf 'stage=mark seq=7 step=a\nstage=mark seq=3 step=b\n' >"$WF_MARK_LOG"
wf_mark after-hole >/dev/null
assert_eq "$(tail -n 1 "$WF_MARK_LOG")" "stage=mark seq=8 step=after-hole" \
  "ac-2 the sequence is taken from the highest seq in the file"

# --------------------------------------------------------------------------- #
# ac-3 32 KiB cap: newest lines kept, TRUNCATED=1 left behind
# --------------------------------------------------------------------------- #

WF_MARK_LOG="$tmp/esp/ab/log/big.log"
export WF_MARK_LOG
{
  printf 'stage=mark seq=0 step=ancient\n'
  for i in $(seq 1 500); do
    printf 'stage=mark seq=%d step=filler-%03d pad=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i" "$i"
  done
} >"$WF_MARK_LOG"
before_bytes="$(wc -c <"$WF_MARK_LOG" | tr -d ' ')"
assert_eq "$((before_bytes > 32768))" "1" "ac-3 the fixture is over the cap to begin with"
wf_mark newest >/dev/null
after_bytes="$(wc -c <"$WF_MARK_LOG" | tr -d ' ')"
assert_eq "$((after_bytes <= 32768))" "1" \
  "ac-3 the log never grows past 32 KiB (${after_bytes} bytes)"
assert_eq "$(grep -c '^TRUNCATED=1$' "$WF_MARK_LOG")" "1" \
  "ac-3 exactly one TRUNCATED=1 marker is left behind"
assert_eq "$(grep -c 'step=newest' "$WF_MARK_LOG")" "1" \
  "ac-3 the line that triggered the truncation is kept"
assert_eq "$(grep -c 'step=ancient' "$WF_MARK_LOG")" "0" \
  "ac-3 the oldest line is the one that is dropped"
assert_eq "$(tail -n 2 "$WF_MARK_LOG" | head -n 1)" "stage=mark seq=501 step=newest" \
  "ac-3 the newest line keeps its place and its sequence"
assert_eq "$(tail -n 1 "$WF_MARK_LOG")" "TRUNCATED=1" \
  "ac-3 the marker is the last line, so a reader knows the log was rolled over"

# The rewrite goes through a temporary file, so a reader (or a power cut) never sees a
# half-written log. Asserted on the source because the alternative - truncating the log
# in place - is precisely the bug that loses the last boot.
mark_body="$(printf '%s\n' "$(cat "$root/initramfs/lib/wf.sh")" \
  | sed -n '/^wf_mark_append() {/,/^}/p')"
assert_contains "${mark_body}" 'mv "${wf_ma_tmp}" "${wf_ma_file}"' \
  "ac-3 the append renames a temporary file over the log"
assert_eq "$(printf '%s\n' "${mark_body}" | grep -c '^    sync$' || true)" "2" \
  "ac-3 the append syncs before and after the rename"

# --------------------------------------------------------------------------- #
# ac-4 no landing zone: nothing is written, nothing fails
# --------------------------------------------------------------------------- #

rm -rf "$tmp/nowhere"
# Created before the snapshot, so the only files that can appear below are the ones wf_mark
# writes - and the assertion is that there are none.
: >"$tmp/mark.out"
outside_before="$(find "$tmp" -type f | sort)"
WF_MARK_LOG=""
WF_MARK_SEQ=0
export WF_MARK_LOG WF_MARK_SEQ
# Written to a file rather than captured with $( ), because the sequence lives in the
# caller's shell: a subshell would lose the increment the next call has to continue from.
wf_mark device >"$tmp/mark.out"
rc=$?
assert_eq "$rc" "0" "ac-4 a mark without a landing zone still succeeds"
assert_eq "$(cat "$tmp/mark.out")" "[boot] stage=mark seq=1 step=device" \
  "ac-4 the milestone still reaches stdout (and the serial port)"
assert_contains "$(cat "$tmp/ttyS0")" "stage=mark seq=1 step=device" \
  "ac-4 ... and the serial device"
assert_eq "$(find "$tmp" -type f | sort)" "${outside_before}" \
  "ac-4 no file appears anywhere when WF_MARK_LOG is unset"
wf_mark state >/dev/null
assert_contains "$(cat "$tmp/ttyS0")" "stage=mark seq=2 step=state" \
  "ac-4 the serial-only sequence still counts up within one boot"

# --------------------------------------------------------------------------- #
# ac-5 landing zone order: ESP first, then p4, then serial only
# --------------------------------------------------------------------------- #

WF_MARK_LOG=""
export WF_MARK_LOG
printf '/dev/vda1 %s vfat rw,relatime 0 0\n' "$tmp/esp" >"$tmp/mounts"
assert_eq "$(wf_mark_zone)" "$tmp/esp/ab/log/boot-0.log" \
  "ac-5 a mounted ESP is the first landing zone"

: >"$tmp/mounts"
assert_eq "$(wf_mark_zone)" "$tmp/p4/.ab/init-fail.log" \
  "ac-5 without the ESP the p4 side is used"

WF_P4_MOUNT="$tmp/p4-gone"
export WF_P4_MOUNT
assert_eq "$(wf_mark_zone)" "" \
  "ac-5 with neither zone the caller falls back to the serial port"
WF_P4_MOUNT="$tmp/p4"
export WF_P4_MOUNT

# --------------------------------------------------------------------------- #
# ac-6 an unusable target is not a boot failure
# --------------------------------------------------------------------------- #

printf 'not a directory\n' >"$tmp/blocked"
WF_MARK_LOG="$tmp/blocked/boot-0.log"
export WF_MARK_LOG
out="$(wf_mark device)"
rc=$?
assert_matches "${out}" 'stage=mark seq=[0-9]+ step=device' \
  "ac-6 a landing zone that refuses the write falls back to the console"
assert_eq "${rc}" "0" "ac-6 and it still returns 0"
assert_eq "$(cat "$tmp/blocked")" "not a directory" \
  "ac-6 nothing is written through an unusable path"

# --------------------------------------------------------------------------- #
# ac-6 the file stays POSIX sh: it runs under the initramfs busybox
# --------------------------------------------------------------------------- #

assert_command_ok "ac-6 initramfs/lib/wf.sh parses as POSIX sh with dash" \
  sh -n "$root/initramfs/lib/wf.sh"
assert_eq "$(printf '%s\n' "$(cat "$root/initramfs/lib/wf.sh")" | grep -c '^wf_mark() {' || true)" "1" \
  "ac-1 wf_mark lives in initramfs/lib/wf.sh"

finish
