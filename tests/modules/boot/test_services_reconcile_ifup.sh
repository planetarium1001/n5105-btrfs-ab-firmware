#!/usr/bin/env bash
# Module: boot
# The service reconcile from the carrier that can still reach it after the first boot gave up:
# an `ifup` (platform/etc/hotplug.d/iface/90-ab-packages -> platform/lib/ab-net-probe.sh ->
# platform/lib/ab-services.sh).
#
# The defect this covers was measured in round 8 (2026-11-19, slot b, `D1 follow: usable
# before the hop and not after: docker(fail)`): the first boot of the hop had no usable feed,
# so the detached worker ended at `result=pending reason=network` without ever reconciling,
# and the follow only completed ten minutes later on an `ifup` (`result=followed`). That
# boot's ring log carries not one `stage=services-reconciled` line, and dockerd stayed down
# for the rest of the boot: the repair existed, but only the boot worker could reach it.
#
#   ac-3 an `ifup` whose follow settles reconciles the services procd lost, once, and the ring
#        log carries the same line the boot worker writes
#   ac-3 an `ifup` that finds no feed reconciles nothing: the window is still open there
#   ac-3 a boot that has already reconciled is not reconciled again - and one whose reconcile
#        was skipped still is
#   ac-3 the repair never decides the hook: an `ifup` stays a success whatever the services do
#   ac-3 the hotplug carrier keeps its console policy: the repair adds no console line there
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-net-probe.sh"
services_lib="$root/platform/lib/ab-services.sh"
hook="$root/platform/etc/hotplug.d/iface/90-ab-packages"
for path in "$lib" "$services_lib" "$hook"; do
  if [ ! -f "$path" ]; then
    printf 'not ok 1 - the carriers exist\n' >&2
    printf '    missing %s\n' "$path" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the machine this test describes ---------------------------------------
# Everything the two libraries touch is a fixture: the ring log, the console, the record, the
# enabled services, their scripts and procd's own answers. The host has no procd and no
# /etc/rc.d, which is exactly why none of it may be read from there.
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/ab"
record_file="$esp/ab/packages"
rc_dir="$tmp/rc.d"
initd_dir="$tmp/init.d"
bin="$tmp/bin"
trace="$tmp/trace.log"
procd_dir="$tmp/procd"
services_trace="$tmp/services.log"
console_file="$tmp/console"
mkdir -p "$rc_dir" "$initd_dir" "$bin" "$procd_dir"
: >"$trace"
: >"$services_trace"
: >"$console_file"

echoes="$tmp/entry.log"
: >"$echoes"

# The service stub: `start` records the call and can be made to refuse, so "the repair ran"
# and "the repair was refused" are two states of the fixture rather than two scripts.
cat >"$bin/service" <<STUB
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >>"$trace"
case "\$1" in
    start)
        [ -f "$tmp/refuse.\$2" ] && exit 1
        : >"$tmp/up.\$2"
        exit 0
        ;;
esac
exit 0
STUB
chmod +x "$bin/service"

# One enabled procd service whose init script is the stub above.
install_service() { # <name>
  cat >"$initd_dir/$1" <<STUB
#!/bin/sh
exec "$bin/service" "\$1" "$1"
STUB
  chmod +x "$initd_dir/$1"
  printf 'USE_PROCD=1\n' >>"$initd_dir/$1"
  ln -sf "../init.d/$1" "$rc_dir/S99$1"
}

# procd's answer for one service: an instance that is not running and that exited 1, which is
# the measured state of dockerd on the boot this covers.
procd_state() { # <name> <running> <exit_code>
  printf '%s %s\n' "$2" "$3" >"$procd_dir/$1"
}

cat >"$bin/procd-state" <<STUB
#!/bin/sh
[ -f "$procd_dir/\$1" ] || exit 2
cat "$procd_dir/\$1"
STUB
chmod +x "$bin/procd-state"

cat >"$bin/nosleep" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$bin/nosleep"

# The follow entry the fallback library calls. It publishes the verdict the transaction would
# have published (that library has its own tests); all this file needs is a follow that really
# settles, so the carrier has something to reconcile after.
cat >"$tmp/entry.sh" <<'LIB'
ab_packages_follow_if_ready() {
	printf 'follow %s\n' "$2" >>"${ENTRY_LOG:?}"
	case "${ENTRY_VERDICT:-followed}" in
		followed)
			AB_PACKAGES_FOLLOW_STATE=followed
			AB_PACKAGES_FOLLOW_REASON=none
			AB_PACKAGES_FOLLOW_VERSION=25.12.2
			ab_net_record_set follow=followed reason=none
			;;
	esac
	return 0
}
LIB

# --- the network, as bytes --------------------------------------------------
fx="$tmp/fx"
mkdir -p "$fx"
printf 'ADBd\001\000\000\000binary index follows' >"$fx/ok"
: >"$fx/offline"

printf 'boot-1\n' >"$tmp/bootid"
printf 'console=ttyS0 ab.slot=b\n' >"$tmp/cmdline"

ring() { cat "$esp/ab/log/boot-0.log" 2>/dev/null; }
console_out() { cat "$console_file" 2>/dev/null; }

# reset_ring <extra-line>: a boot whose ring log carries nothing but what the case seeds. The
# extra line is how "this boot already tried" is described to the code under test.
reset_ring() {
  : >"$esp/ab/log/boot-0.log"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >"$esp/ab/log/boot-0.log"
}

# pending_record: the record an upgrade publishes - a follow is owed, nothing has run yet.
pending_record() {
  printf '%s\n' "packages=aligned reason=none follow=pending version=25.12.2 slot=b" >"$record_file"
}

# ifup <fixture>: one `ifup` through the shipped hotplug hook, exactly as netifd runs it.
ifup() { # <probe-body>
  AB_ESP="$esp" AB_PACKAGES_FILE="$record_file" AB_CMD="$tmp/cmdline" \
    AB_NET_PROBE_LIB="$lib" AB_SERVICES_LIB="$services_lib" \
    AB_PACKAGES_LIB="$tmp/entry.sh" AB_PACKAGES_TARGET="$tmp/target" \
    AB_NET_PROBE_INPUT="$1" AB_NET_PROBE_URL=https://mirror.invalid/packages.adb \
    AB_NET_FOLLOW_LOCK="$tmp/lock/follow.lock" AB_BOOT_ID_FILE="$tmp/bootid" \
    AB_NET_NOW_CMD="$tmp/now" AB_NET_SLEEP_CMD="$bin/nosleep" \
    AB_PACKAGES_IFUP_LOG="$tmp/ifup.log" ENTRY_LOG="$echoes" ENTRY_VERDICT="${ENTRY_VERDICT:-followed}" \
    AB_BOOT_RC_DIR="$rc_dir" AB_BOOT_INITD_DIR="$initd_dir" \
    AB_BOOT_PROCD_STATE_CMD="$bin/procd-state" AB_BOOT_SLEEP_CMD="$bin/nosleep" \
    AB_BOOT_SETTLE_S=0 AB_BOOT_SETTLE_WAIT_S=0 \
    AB_BOOT_UPTIME_FILE="$tmp/uptime" AB_CONSOLE_DEV="$console_file" \
    ACTION=ifup sh "$hook"
}

# The clock the ladder reads. It never moves here: every rung this file drives is W2, which
# runs immediately and only needs a number.
printf '1000000\n' >"$tmp/now"
chmod +x "$tmp/now"
printf '300.00 900.00\n' >"$tmp/uptime"

# wait_for_ring <needle> <deciseconds>: the hook detaches its attempt, so a case has to wait
# for the child's line rather than assume it. Every wait here names the line the child writes
# last, so no case starts seeding a log the previous child is still writing to.
wait_for_ring() {
  _w=0
  while [ "$_w" -lt "$2" ]; do
    grep -q "$1" "$esp/ab/log/boot-0.log" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  return 1
}

install_service dockerd
procd_state dockerd false 1

# =========================================================================== #
# ac-3 the follow settles on an ifup, so the repair runs there
# =========================================================================== #

reset_ring
pending_record
: >"$trace"
: >"$echoes"
ifup "$fx/ok"
assert_eq "$?" "0" "ac-3 the ifup hook succeeds"
wait_for_ring "stage=services-reconciled" 200
assert_contains "$(ring)" "rung=w2-ifup" \
  "ac-3 the rung ran on the ifup"
assert_contains "$(ring)" "result=followed" \
  "ac-3 ... and the follow it ran is the one that settled"
assert_contains "$(ring)" \
  "stage=services-reconciled slot=b result=ok started=1 failed=none down=dockerd" \
  "ac-3 a follow that settles on an ifup reconciles the daemon procd lost, in the ring log the boot reads"
assert_eq "$(grep -c 'start dockerd' "$trace")" "1" \
  "ac-3 ... and that daemon is started exactly once"
assert_eq "$(cat "$console_file")" "" \
  "ac-3 the repair writes no console line from the hotplug carrier: an ifup is not a milestone"

# The same ifup on a machine whose daemon refuses to come back: the hook still succeeds and the
# line says what happened. A repair that could fail a network event would turn a service
# question into a network verdict.
reset_ring
pending_record
: >"$trace"
: >"$services_trace"
: >"$tmp/refuse.dockerd"
ifup "$fx/ok"
assert_eq "$?" "0" "ac-3 a refused start does not fail the ifup hook"
wait_for_ring "stage=services-reconciled" 200
assert_contains "$(ring)" "result=partial" \
  "ac-3 ... the ring log reports the refusal instead of a repair nobody made"
assert_contains "$(ring)" "failed=dockerd" "ac-3 ... and names the service"
rm -f "$tmp/refuse.dockerd"

# =========================================================================== #
# ac-3 an ifup that follows nothing reconciles nothing
# =========================================================================== #

reset_ring
pending_record
: >"$trace"
: >"$echoes"
ifup "$fx/offline"
assert_eq "$?" "0" "ac-3 an ifup with no usable feed still succeeds"
wait_for_ring "result=pending reason=network" 200
assert_eq "$(grep -c 'stage=services-reconciled' "$esp/ab/log/boot-0.log" || true)" "0" \
  "ac-3 a rung that could not follow writes no reconcile: the window is still open"
assert_eq "$(grep -c '^start ' "$trace" || true)" "0" \
  "ac-3 ... and no daemon is restarted while the packages are still owed"

# A follow that ran and failed is not a settled follow either.
reset_ring
pending_record
: >"$trace"
ENTRY_VERDICT=pending ifup "$fx/ok"
wait_for_ring "result=pending" 200
assert_eq "$(grep -c 'stage=services-reconciled' "$esp/ab/log/boot-0.log" || true)" "0" \
  "ac-3 a follow that ended pending is not reconciled, even on a reachable feed"
assert_eq "$(grep -c '^start ' "$trace" || true)" "0" \
  "ac-3 ... nothing is started on behalf of a follow that did not move"

# =========================================================================== #
# ac-3 one repair per boot, and a skipped one does not count as done
# =========================================================================== #

reset_ring "stage=services-reconciled slot=b result=ok started=1 failed=none down=dockerd"
pending_record
: >"$trace"
ifup "$fx/ok"
assert_eq "$?" "0" "ac-3 an ifup after a repaired boot still succeeds"
wait_for_ring "reason=already-reconciled" 200
assert_contains "$(ring)" "result=skipped reason=already-reconciled" \
  "ac-3 a boot that has already reconciled says so instead of repairing twice"
assert_eq "$(grep -c 'result=ok started=1' "$esp/ab/log/boot-0.log" || true)" "1" \
  "ac-3 ... the ring log keeps one repair line for the one boot"
assert_eq "$(grep -c 'start dockerd' "$trace" || true)" "0" \
  "ac-3 ... and no daemon is started a second time"

# The reconcile that the first carrier had to skip left the window open: a follow that only
# settled later has to be able to repair the machine. `skipped` is not "done".
reset_ring "stage=services-reconciled slot=b result=skipped reason=boot-not-settled uptime=10"
pending_record
: >"$trace"
ifup "$fx/ok"
assert_eq "$?" "0" "ac-3 an ifup after a skipped reconcile succeeds"
wait_for_ring "result=ok" 200
assert_contains "$(ring)" "stage=services-reconciled slot=b result=ok started=1 failed=none down=dockerd" \
  "ac-3 a reconcile that was skipped earlier does not close the boot: this rung repairs it"
assert_eq "$(grep -c 'start dockerd' "$trace" || true)" "1" \
  "ac-3 ... and the daemon procd lost is started once"

# The ring log is read, so a machine with no log at all answers "not reconciled yet" instead of
# failing: the ESP can be unreadable, and the follow itself may still be worth running.
rm -rf "$esp/ab/log"
pending_record
: >"$trace"
ifup "$fx/ok"
assert_eq "$?" "0" "ac-3 an ifup succeeds on a machine whose ring log is gone"
wait_for_ring "stage=services-reconciled" 200
assert_eq "$(grep -c 'start dockerd' "$trace" || true)" "1" \
  "ac-3 ... and the repair still runs, because a missing log is not a repair already done"

finish
