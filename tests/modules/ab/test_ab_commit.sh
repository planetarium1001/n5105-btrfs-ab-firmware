#!/usr/bin/env bash
# Module: ab
# Verifies the health check in platform/etc/init.d/ab-commit: what each probe requires,
# and that a failure says *why* it failed.
#   ac-1 the writable-layer probe needs a writable composed root with an absolute
#        free-space floor, not a percentage of whatever the partition happens to be
#   ac-2 the firewall and wan probes name the thing they could not find
#   ac-3 preflight: a slot that came up without /proc is reported as that, not as three
#        anonymous probe failures
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

hook="$root/platform/etc/init.d/ab-commit"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The hook is a plain shell script with function definitions; sourcing it only sets
# variables, so its probes can be driven directly.
# shellcheck source=platform/etc/init.d/ab-commit
. "$hook"

overlay="$tmp/overlay"
proc_dir="$tmp/proc"
sysfs="$tmp/sys"
mkdir -p "$overlay" "$proc_dir" "$sysfs/class/net"

# PROBE_REASON is the probe's own variable: probe() sets it to a sentinel before the call
# and each probe overwrites it on the way out. Driving a probe directly from here means
# doing the same first, so the variable the assertions read always exists (`set -u`).
PROBE_REASON=""

# --------------------------------------------------------------------------- #
# ac-1: writable layer, absolute floor
# --------------------------------------------------------------------------- #

AB_OVERLAY="$overlay" AB_FREE_FLOOR_KB=0
export AB_OVERLAY AB_FREE_FLOOR_KB
probe_overlay_writable
assert_eq "$?" "0" "ac-1 a writable overlay passes"
assert_eq "$PROBE_REASON" "" "ac-1 a pass carries no reason"
assert_eq "$(ls -A "$overlay" | wc -l | tr -d ' ')" "0" \
  "ac-1 the probe file is removed again"

# A floor the filesystem cannot meet: the same probe now fails, and says by how much.
AB_FREE_FLOOR_KB=999999999
export AB_FREE_FLOOR_KB
probe_overlay_writable
assert_eq "$?" "1" "ac-1 a full filesystem fails the probe"
assert_contains "$PROBE_REASON" "free-" "ac-1 the reason names the free space"
assert_contains "$PROBE_REASON" "-below-999999999k" "ac-1 and the floor it missed"
AB_FREE_FLOOR_KB=16384
export AB_FREE_FLOOR_KB

# The floor is an absolute number of KiB, not a percentage: the same 128 MiB test image
# and a disk of hundreds of GiB get the same rule.
assert_contains "$(cat "$hook")" 'AB_FREE_FLOOR_KB="${AB_FREE_FLOOR_KB:-16384}"' \
  "ac-1 the floor is 16 MiB by default"
assert_eq "$(grep -c 'avail \* 100 / ' "$hook")" "0" \
  "ac-1 no percentage of the partition size is used any more"

# The default has to be the composed root, not the /overlay mount point that never
# existed: the image that shipped measured a path nobody created and called every slot
# unhealthy. Two assertions, because either one alone is weak: the default is pinned in
# the source, and the tree it names is exercised (a test host's root may not be writable
# to an ordinary user, but it must never be reported as a missing mount point).
assert_contains "$(cat "$hook")" 'AB_OVERLAY="${AB_OVERLAY:-/}"' \
  "ac-1 the writable layer defaults to the composed root"
AB_FREE_FLOOR_KB=0
AB_OVERLAY="/"
export AB_FREE_FLOOR_KB AB_OVERLAY
if probe_overlay_writable; then
  assert_eq "0" "0" "ac-1 the composed root is a usable writable layer on this host"
else
  assert_contains "$PROBE_REASON" "not-writable:/" \
    "ac-1 and otherwise it says the probe file could not be created at the root"
fi
AB_FREE_FLOOR_KB=16384
AB_OVERLAY="$overlay"
export AB_FREE_FLOOR_KB AB_OVERLAY

AB_OVERLAY="$tmp/nothing-here"
export AB_OVERLAY
probe_overlay_writable
assert_eq "$?" "1" "ac-1 a missing overlay fails the probe"
assert_eq "$PROBE_REASON" "no-overlay" "ac-1 and says the mount point is missing"

mkdir -p "$tmp/readonly"
chmod 500 "$tmp/readonly"
AB_OVERLAY="$tmp/readonly"
export AB_OVERLAY
probe_overlay_writable
if [ "$(id -u)" = "0" ]; then
  # root writes to a 0500 directory; the case is not observable as root.
  assert_eq "0" "0" "ac-1 skipped as root: 0500 is still writable"
else
  assert_eq "$?" "1" "ac-1 an unwritable overlay fails the probe"
  assert_contains "$PROBE_REASON" "not-writable" "ac-1 and says it cannot write"
fi
chmod 700 "$tmp/readonly"
AB_OVERLAY="$overlay"
export AB_OVERLAY

# --------------------------------------------------------------------------- #
# ac-2: firewall and wan probes name what is missing
# --------------------------------------------------------------------------- #

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
PATH="/usr/bin:/bin"
export PATH

probe_fw4
assert_eq "$?" "1" "ac-2 without nft the firewall probe fails"
assert_eq "$PROBE_REASON" "no-nft" "ac-2 and names the missing tool"

cat >"$stub_bin/nft" <<'STUB'
#!/bin/sh
case "$*" in
  "list ruleset") printf '%s\n' "${STUB_RULESET:-}" ;;
  # The loaded fw4 table is the second shape the firewall probe accepts; unset means
  # "fw4 was never loaded", which is what the failing cases describe.
  "list table inet fw4") [ -n "${STUB_FW4_TABLE:-}" ] || exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/nft"
PATH="$stub_bin:/usr/bin:/bin"
export PATH

STUB_RULESET=""
export STUB_RULESET
probe_fw4
assert_eq "$?" "1" "ac-2 an empty ruleset fails the probe"
assert_eq "$PROBE_REASON" "nft-ruleset-empty" "ac-2 and says the ruleset is empty"

STUB_RULESET="table inet filter {}"
export STUB_RULESET
probe_fw4
assert_eq "$?" "1" "ac-2 a ruleset without fw4 fails the probe"
assert_eq "$PROBE_REASON" "no-fw4-table-or-process" "ac-2 and says fw4 is not loaded"

probe_wan
assert_eq "$?" "1" "ac-2 without uci the wan probe fails"
assert_eq "$PROBE_REASON" "no-uci" "ac-2 and names the missing tool"

cat >"$stub_bin/uci" <<'STUB'
#!/bin/sh
[ -n "${STUB_WAN_DEVICE:-}" ] || exit 1
printf '%s\n' "${STUB_WAN_DEVICE}"
STUB
chmod +x "$stub_bin/uci"
STUB_WAN_DEVICE=""
export STUB_WAN_DEVICE
AB_SYSFS="$sysfs"
export AB_SYSFS
probe_wan
assert_eq "$?" "1" "ac-2 a wan without a device fails the probe"
assert_eq "$PROBE_REASON" "no-wan-device-in-uci" "ac-2 and says uci has no device"

STUB_WAN_DEVICE="eth1"
export STUB_WAN_DEVICE
probe_wan
assert_eq "$?" "1" "ac-2 a wan device that does not exist fails the probe"
assert_eq "$PROBE_REASON" "no-interface:eth1" "ac-2 and names the interface"

mkdir -p "$sysfs/class/net/eth1"
probe_wan
assert_eq "$?" "0" "ac-2 a wan device that exists passes the probe"

# --------------------------------------------------------------------------- #
# ac-3: preflight, so a broken tree is not reported as three broken probes
# --------------------------------------------------------------------------- #

AB_PROC="$proc_dir"
export AB_PROC
preflight
assert_eq "$?" "1" "ac-3 a tree without /proc fails preflight"
assert_eq "$PREFLIGHT_REASON" "proc-cmdline-unreadable" \
  "ac-3 and names the first thing it could not read"

: >"$proc_dir/cmdline"
preflight
assert_eq "$?" "1" "ac-3 a read-only /proc/cmdline is not enough"
assert_eq "$PREFLIGHT_REASON" "proc-mounts-unreadable" "ac-3 preflight walks the list"

: >"$proc_dir/mounts"
AB_SYSFS="$tmp/no-sys"
export AB_SYSFS
preflight
assert_eq "$?" "1" "ac-3 a tree without sysfs fails preflight"
assert_eq "$PREFLIGHT_REASON" "sysfs-missing" "ac-3 and says so"

AB_SYSFS="$sysfs"
export AB_SYSFS
preflight
assert_eq "$?" "0" "ac-3 a complete tree passes preflight"

# The preflight result has to reach the decision, with its own reason: this is the line
# that tells a broken slot apart from a failing probe.
assert_contains "$(cat "$hook")" 'failed="preflight-${PREFLIGHT_REASON}"' \
  "ac-3 a preflight failure is carried as the health check reason"
assert_contains "$(cat "$hook")" 'console_say "ab-commit: stage=preflight slot=${slot} result=fail reason=${PREFLIGHT_REASON}"' \
  "ac-3 and printed on the console"
assert_contains "$(cat "$hook")" 'result=fail reason=${PROBE_REASON:-unknown}' \
  "ac-3 every failed probe prints its reason"

# --------------------------------------------------------------------------- #
# ac-4: start() reaches the probes through a function that exists
#
# The regression this covers: the loop called `run_probe`, which no file defines, so
# every probe exited 127. A healthy machine reported
# `probe=overlay-writable result=fail reason=unknown` and the running slot was never
# committed - the failure looked like a broken probe instead of a broken call site.
# Nothing above calls start(), so nothing above could see it. This drives a fake
# machine through start() instead of asserting on strings in the source.
# --------------------------------------------------------------------------- #

machine="$tmp/machine"
esp="$machine/esp"
mkdir -p "$esp/ab/log" "$esp/ab"
mounts_file="$machine/mounts"
printf '/dev/fake %s vfat rw,noatime 0 0\n' "$esp" >"$mounts_file"

calls="$machine/ab-slot.calls"
reboot_calls="$machine/reboot.calls"
console_log="$machine/console.log"
# One file holding both the ab-slot calls and the console lines, in the order they
# happened: the abandon branch has to write the state before it announces it, and two
# separate logs cannot show that.
seq="$machine/sequence.log"
: >"$calls"
: >"$reboot_calls"
: >"$console_log"
: >"$seq"

# start() mounts the ESP, writes the ring log and reads the slot through ab-slot: all
# three are pointed at the fake machine so nothing here touches the host.
AB_ESP="$esp"
AB_MOUNTS="$mounts_file"
AB_OVERLAY="$overlay"
AB_PROC="$proc_dir"
AB_SYSFS="$sysfs"
AB_FREE_FLOOR_KB=0
export AB_ESP AB_MOUNTS AB_OVERLAY AB_PROC AB_SYSFS AB_FREE_FLOOR_KB

STUB_AB_SLOT_CALLS="$calls"
STUB_SEQ="$seq"
STUB_SLOT=a
STUB_PENDING=none
export STUB_AB_SLOT_CALLS STUB_SEQ STUB_SLOT STUB_PENDING

cat >"$stub_bin/ab-slot" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_AB_SLOT_CALLS}"
printf 'ab-slot %s\n' "$*" >>"${STUB_SEQ}"
case "$1" in
  status) printf 'slot=%s pending=%s upper=@overlay-25.12.2\n' "${STUB_SLOT}" "${STUB_PENDING}" ;;
  rootfs) printf '25.12.2\n' ;;
  *) : ;;
esac
STUB
chmod +x "$stub_bin/ab-slot"

# pidof/pgrep must not find a firewall on the host: the probe is being asked about the
# fake ruleset, not about whatever is running this test.
printf '#!/bin/sh\nexit 1\n' >"$stub_bin/pidof"
printf '#!/bin/sh\nexit 1\n' >"$stub_bin/pgrep"
chmod +x "$stub_bin/pidof" "$stub_bin/pgrep"

# console_say and reboot have to stop at the test: one would write to the real console,
# the other would restart the machine under the runner.
# shellcheck disable=SC2317  # called by start() in the subshells below
console_say() {
  printf '%s\n' "$*" >>"$console_log"
  printf 'console %s\n' "$*" >>"$seq"
}
# shellcheck disable=SC2317  # called by start() in the subshells below
reboot() { printf 'reboot\n' >>"$reboot_calls"; }

# A healthy machine: three probes pass, the running slot is committed.
STUB_RULESET="table inet fw4 {}"
STUB_FW4_TABLE=1
AB_FREE_FLOOR_KB=0
export AB_FREE_FLOOR_KB
STUB_WAN_DEVICE=eth1
export STUB_RULESET STUB_FW4_TABLE STUB_WAN_DEVICE
( start ) >/dev/null 2>&1
assert_eq "$?" "0" "ac-4 a healthy machine finishes the health check"
assert_contains "$(cat "$console_log")" "probe=overlay-writable result=pass" \
  "ac-4 the writable layer probe is called and passes"
assert_contains "$(cat "$console_log")" "probe=fw4-present result=pass" \
  "ac-4 the firewall probe is called and passes"
assert_contains "$(cat "$console_log")" "probe=wan-present result=pass" \
  "ac-4 the wan probe is called and passes"
assert_contains "$(cat "$console_log")" "ab-commit: committed slot=a" \
  "ac-4 and the running slot is committed"
assert_contains "$(cat "$calls")" "commit a" "ac-4 through ab-slot commit"
assert_eq "$(grep -c '^abandon' "$calls")" "0" "ac-4 nothing is abandoned"

# One probe fails: the decision stays, and the two other probes still report. A
# short-circuit would name one probe per boot, so a slot with two faults would need two
# boots to explain itself.
: >"$console_log"
: >"$calls"
: >"$esp/ab/log/boot-0.log"
STUB_FW4_TABLE=""
AB_FREE_FLOOR_KB=0
export STUB_FW4_TABLE AB_FREE_FLOOR_KB
( start ) >/dev/null 2>&1
assert_eq "$?" "0" "ac-4 a failing probe still ends the health check cleanly"
assert_contains "$(cat "$console_log")" "probe=overlay-writable result=pass" \
  "ac-4 the probe before the failure runs"
assert_contains "$(cat "$console_log")" "probe=fw4-present result=fail reason=no-fw4-table-or-process" \
  "ac-4 the failure names the probe and the reason"
assert_contains "$(cat "$console_log")" "probe=wan-present result=pass" \
  "ac-4 the probe after the failure runs too"
assert_contains "$(cat "$console_log")" \
  "ab-commit: stage=healthcheck-done slot=a result=fail reason=healthcheck-failed action=stay" \
  "ac-4 and a committed slot with failing probes stays up"
assert_eq "$(grep -c '^commit' "$calls")" "0" "ac-4 nothing is committed"
assert_contains "$(cat "$esp/ab/log/boot-0.log")" "probe=fw4-present result=fail reason=no-fw4-table-or-process" \
  "ac-4 the ring log names the probe that failed"
assert_contains "$(cat "$esp/ab/log/boot-0.log")" "result=fail reason=healthcheck-failed detail=no-fw4-table-or-process" \
  "ac-4 and the summary line carries the first failure"

# A pending slot that fails its probes: abandoned, never committed, and the machine goes
# back to the committed slot.
: >"$console_log"
: >"$calls"
: >"$reboot_calls"
: >"$esp/ab/log/boot-0.log"
STUB_SLOT=b
STUB_PENDING=b
STUB_FW4_TABLE=""
AB_FREE_FLOOR_KB=0
export STUB_SLOT STUB_PENDING STUB_FW4_TABLE AB_FREE_FLOOR_KB
( start ) >/dev/null 2>&1
assert_eq "$?" "0" "ac-4 a failing pending slot ends the health check cleanly"
assert_contains "$(cat "$calls")" "abandon" "ac-4 the pending slot is abandoned"
assert_eq "$(grep -c '^commit' "$calls")" "0" "ac-4 and never committed"
assert_contains "$(cat "$reboot_calls")" "reboot" "ac-4 the machine reboots into the committed slot"
assert_contains "$(cat "$console_log")" "ab-commit: abandoned slot=b reason=healthcheck-failed" \
  "ac-4 and says so on the console"
assert_eq "$(awk '/^ab-slot abandon$/ {a = NR} /^console ab-commit: abandoned/ {c = NR} END {print (a && c && a < c) ? "state-then-console" : "out-of-order"}' "$seq")" \
  "state-then-console" \
  "ac-4 the abandon is written to the ESP before it is announced"

# Two probes fail: the summary line quotes the FIRST one. With every probe running to the
# end, the live PROBE_REASON holds the last failure, so a slot with two faults is exactly
# the case where "report the first" and "report the last" disagree.
: >"$console_log"
: >"$calls"
: >"$esp/ab/log/boot-0.log"
STUB_SLOT=a
STUB_PENDING=none
STUB_FW4_TABLE=""
AB_FREE_FLOOR_KB=999999999
export STUB_SLOT STUB_PENDING STUB_FW4_TABLE AB_FREE_FLOOR_KB
( start ) >/dev/null 2>&1
assert_eq "$?" "0" "ac-4 two failing probes still end the health check cleanly"
assert_contains "$(cat "$console_log")" "probe=overlay-writable result=fail reason=free-" \
  "ac-4 the writable layer probe fails first"
assert_contains "$(cat "$console_log")" "probe=fw4-present result=fail reason=no-fw4-table-or-process" \
  "ac-4 the firewall probe fails second"
assert_contains "$(cat "$esp/ab/log/boot-0.log")" "detail=free-" \
  "ac-4 the summary quotes the first failure"
assert_eq "$(grep -c 'detail=no-fw4' "$esp/ab/log/boot-0.log")" "0" \
  "ac-4 and not the last one"

finish
