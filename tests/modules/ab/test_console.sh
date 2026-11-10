#!/usr/bin/env bash
# Module: ab
# Verifies platform/lib/ab-console.sh: every milestone line our hooks print has to reach
# the serial log, because that log is all a failed CI run has, and it must not be written
# twice to the console /dev/console already uses.
#   ac-1 with the image's menu (serial console last) /dev/console *is* the serial port,
#        and the line is mirrored to the VT so a machine with a monitor shows it too
#   ac-2 an older menu that ends in console=tty0 still gets the line on the serial port
#   ac-3 no console receives the same line twice
#   ac-4 a missing console is skipped and console output never fails the caller
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-console.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dev="$tmp/dev"
mkdir -p "$dev"
consoles="$tmp/consoles"

reset_devices() {
  rm -rf "$dev"
  mkdir -p "$dev"
  : >"$dev/console"
  : >"$dev/ttyS0"
  : >"$dev/tty0"
}

# say <line>: run one console_say against the fixture.
say() {
  AB_CONSOLE_DEV="$dev/console" AB_CONSOLE_SERIAL="$dev/ttyS0" AB_CONSOLE_VT="$dev/tty0" \
    AB_CONSOLES="$consoles" \
    sh -c ". '${lib}'; console_say \"\$1\"" sh "$1"
}

lines_in() { # <file>
  if [ ! -f "$1" ]; then
    printf '0'
    return 0
  fi
  grep -c . "$1" 2>/dev/null | tr -d ' '
}

# --------------------------------------------------------------------------- #
# ac-1: the image's menu, serial last
# --------------------------------------------------------------------------- #

reset_devices
cat >"$consoles" <<'CONSOLES'
tty0                 -WU (E  p  )    4:7
ttyS0                -W- (EC p a)    4:64
CONSOLES
say "ab-boot: stage=device disk=/dev/vda"
assert_eq "$?" "0" "ac-1 console_say succeeds"
assert_eq "$(lines_in "$dev/console")" "1" "ac-1 the primary console gets the line"
assert_eq "$(cat "$dev/console")" "ab-boot: stage=device disk=/dev/vda" \
  "ac-1 the line is what the caller printed"
assert_eq "$(lines_in "$dev/tty0")" "1" "ac-1 a monitor gets the same line"
assert_eq "$(lines_in "$dev/ttyS0")" "0" \
  "ac-1 the serial port is not written twice: it already is /dev/console"

# --------------------------------------------------------------------------- #
# ac-2: an older menu that ends in console=tty0
# --------------------------------------------------------------------------- #

reset_devices
cat >"$consoles" <<'CONSOLES'
tty0                 -WU (EC p  )    4:7
ttyS0                -W- (E  p a)    4:64
CONSOLES
say "ab-commit: committed slot=a upper=@overlay-25.12.3"
assert_eq "$(lines_in "$dev/console")" "1" "ac-2 the VT console gets the line"
assert_eq "$(lines_in "$dev/ttyS0")" "1" \
  "ac-2 the serial port still gets it, which is what made the old images debuggable"
assert_eq "$(cat "$dev/ttyS0")" "ab-commit: committed slot=a upper=@overlay-25.12.3" \
  "ac-2 the mirrored line is identical"

# --------------------------------------------------------------------------- #
# ac-3: never twice on the same device
# --------------------------------------------------------------------------- #

reset_devices
cat >"$consoles" <<'CONSOLES'
tty0                 -WU (E  p  )    4:7
ttyS0                -W- (EC p a)    4:64
CONSOLES
say "only-once"
assert_eq "$(lines_in "$dev/console")" "1" "ac-3 the primary console gets it once"
assert_eq "$(lines_in "$dev/tty0")" "1" "ac-3 the monitor gets it once"
assert_eq "$(lines_in "$dev/ttyS0")" "0" "ac-3 the console /dev/console uses is skipped"
total=$(($(lines_in "$dev/console") + $(lines_in "$dev/tty0") + $(lines_in "$dev/ttyS0")))
assert_eq "$total" "2" "ac-3 exactly one copy per console, never two on one"

# --------------------------------------------------------------------------- #
# ac-4: missing consoles are skipped, output never fails
# --------------------------------------------------------------------------- #

# No kernel console table at all: the write console cannot be identified, so every
# console that exists is written. Losing the line is worse than printing it twice.
reset_devices
rm -f "$consoles"
say "no-table"
total=$(($(lines_in "$dev/console") + $(lines_in "$dev/tty0") + $(lines_in "$dev/ttyS0")))
assert_eq "$total" "3" "ac-4 without the console table every writable console gets the line"

reset_devices
rm -f "$dev/ttyS0" "$dev/tty0"
say "headless"
assert_eq "$?" "0" "ac-4 console_say succeeds without a serial port or a VT"
assert_eq "$(lines_in "$dev/console")" "1" "ac-4 the primary console still gets the line"

# A primary console that cannot be written is not fatal either: the mirrors still try.
reset_devices
AB_CONSOLE_DEV="$tmp/no-such-console" AB_CONSOLE_SERIAL="$dev/ttyS0" \
  AB_CONSOLE_VT="$dev/tty0" AB_CONSOLES="$consoles" \
  sh -c ". '${lib}'; console_say 'still-said'"
assert_eq "$?" "0" "ac-4 an unwritable primary console does not fail the caller"
assert_eq "$(cat "$dev/ttyS0")" "still-said" "ac-4 the serial copy is still attempted"

# --------------------------------------------------------------------------- #
# ac-5: the platform tools share this implementation
# --------------------------------------------------------------------------- #

for tool in platform/etc/init.d/ab-boot platform/etc/init.d/ab-commit platform/usr/sbin/ab-upgrade; do
  assert_contains "$(cat "$root/$tool")" "ab-console.sh" \
    "ac-5 ${tool} sources the shared console helper"
  assert_eq "$(grep -c 'printf .%s..n. .\$\\*. >/dev/console' "$root/$tool")" "0" \
    "ac-5 ${tool} no longer writes /dev/console itself"
done

finish
