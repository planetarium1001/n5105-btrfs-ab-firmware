#!/usr/bin/env bash
# Module: boot
# Every boot milestone has to be readable from the serial port and from HDMI. Linux binds
# /dev/console to the LAST console= parameter, so `console=ttyS0,115200 console=tty0`
# sends PID1's entire stdout to the local screen and leaves an empty serial log — which
# is exactly how a boot nobody can debug happens.
#   ac-1 wf_log writes the line to stdout and, when /dev/console is not the serial port,
#        to the serial device as well
#   ac-2 the copy is skipped when the serial port already carries /dev/console, so the
#        judge line stays exactly one line for the harness that parses it
#   ac-3 a missing or unwritable serial device never breaks the caller
#   ac-4 the judge line and the machine-readable markers go through the same helper
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

serial="$tmp/ttyS0"
consoles="$tmp/consoles"
: >"$serial"
: >"$consoles"

WF_SERIAL="$serial"
WF_CONSOLES="$consoles"
export WF_SERIAL WF_CONSOLES

source "$root/initramfs/lib/wf.sh"

reset_fixture() {
  : >"$serial"
  : >"$consoles"
}

# --------------------------------------------------------------------------- #
# ac-1 stdout plus the serial device
# --------------------------------------------------------------------------- #

reset_fixture
# Nothing in the console table: we cannot tell where /dev/console points, so the copy is
# written. A double line is better than no line.
stdout_line="$(wf_log "milestone reached")"
assert_eq "${stdout_line}" "[boot] milestone reached" "ac-1 the line still goes to stdout"
assert_eq "$(cat "$serial")" "[boot] milestone reached" \
  "ac-1 the line is written to the serial device"

# `console=ttyS0,115200 console=tty0`: tty0 is the last one, so it is the console bound
# to /dev/console (no U flag) and ttyS0 is registered but unbound (U).
reset_fixture
printf 'ttyS0                -WU (EC p a)    4:64\ntty0                 -W- (E     )    4:7\n' \
  >"$consoles"
no_console="${WF_SERIAL}"
wf_log "console on tty0" >/dev/null
assert_eq "$(cat "$serial")" "[boot] console on tty0" \
  "ac-1 with tty0 as /dev/console the serial gets its own copy"
assert_eq "${no_console}" "${WF_SERIAL}" "ac-1 the serial path is not modified"

# --------------------------------------------------------------------------- #
# ac-2 no duplicate when the serial port already carries /dev/console
# --------------------------------------------------------------------------- #

reset_fixture
# `console=tty0 console=ttyS0,115200`: now ttyS0 is the last one and carries no U flag,
# so /dev/console already writes to the serial port and a copy would double the judge line.
printf 'ttyS0                -W- (EC p a)    4:64\ntty0                 -WU (E     )    4:7\n' \
  >"$consoles"
dup="$(wf_log "console already serial")"
assert_eq "${dup}" "[boot] console already serial" "ac-2 stdout is unchanged"
assert_eq "$(cat "$serial")" "" "ac-2 no duplicate is written when ttyS0 is /dev/console"

# The serial port is not registered as a console at all: copy anyway.
reset_fixture
printf 'tty0                 -W- (E     )    4:7\n' >"$consoles"
wf_log "only tty0 registered" >/dev/null
assert_eq "$(cat "$serial")" "[boot] only tty0 registered" \
  "ac-2 a table without ttyS0 still gets the serial copy"

# --------------------------------------------------------------------------- #
# ac-3 a serial device that is missing or refuses writes is not fatal
# --------------------------------------------------------------------------- #

reset_fixture
missing_stdout="$(WF_SERIAL="$tmp/absent-ttyS0" wf_log "no serial node")"
assert_eq "$?" "0" "ac-3 a missing serial node is not an error"
assert_eq "${missing_stdout}" "[boot] no serial node" \
  "ac-3 stdout still receives the line without a serial node"

mkdir -p "$tmp/not-a-device"
assert_eq "$(WF_SERIAL="$tmp/not-a-device" wf_log "unwritable")" "[boot] unwritable" \
  "ac-3 an unwritable serial path still prints to stdout"
assert_eq "$?" "0" "ac-3 an unwritable serial path is not an error"

# --------------------------------------------------------------------------- #
# ac-4 the judge line and the markers use the same helper
# --------------------------------------------------------------------------- #

wf_lib="$(cat "$root/initramfs/lib/wf.sh")"
fail_body="$(printf '%s' "${wf_lib}" | sed -n '/^wf_fail() {/,/^}/p')"
assert_contains "${fail_body}" 'wf_say "S3-RESULT=fail reason=$1"' \
  "ac-4 the failure judge line is written to every console"
assert_eq "$(printf '%s' "${fail_body}" | grep -c 'printf' || true)" "0" \
  "ac-4 no raw printf is left in the failure path"
abandon_body="$(printf '%s' "${wf_lib}" | sed -n '/^wf_failsafe_abandon() {/,/^}/p')"
assert_contains "${abandon_body}" 'wf_say "[boot] action=fail-safe-abandon slot=' \
  "ac-4 the abandon marker goes to the serial port too"

boot_init="$(cat "$root/initramfs/boot/init")"
assert_contains "${boot_init}" 'wf_say "[boot] stage=device disk=' \
  "ac-4 the device identity line reaches the serial port"
assert_eq "$(printf '%s' "${boot_init}" | grep -c "printf '\[boot\]" || true)" "0" \
  "ac-4 the init keeps no raw printf for boot markers"

# grow.sh diagnostics have to reach the serial port too: a [grow] line that only lands on
# the local screen is not evidence for the machine that has no screen.
grow_lib="$(cat "$root/initramfs/lib/grow.sh")"
assert_contains "${grow_lib}" 'command -v wf_say >/dev/null 2>&1' \
  "ac-4 the growth helper uses wf_say when the boot initramfs has it"
assert_contains "${grow_lib}" 'wf_say "[grow] $*"' \
  "ac-4 growth diagnostics are mirrored to every console"

# The judge-line shape itself is frozen and must survive the change.
assert_contains "${fail_body}" 'S3-RESULT=fail reason=' "ac-4 the judge line shape is unchanged"
assert_contains "$(cat "$root/initramfs/boot/post.sh")" \
  'S3-RESULT=ok slot=%s upper=%s lower=platform:sys root=overlay' \
  "ac-4 the success judge line is untouched"

finish
