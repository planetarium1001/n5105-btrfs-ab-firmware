#!/usr/bin/env bash
# Module: upgrade
# Network fallback for the package follow: the three-state probe, the single-instance lock,
# the retry ladder (W1 five minutes / W2 every ifup / W3 half-hourly until 24 h) and the
# two carriers that drive it (ab-boot's detached first-boot worker and the iface hotplug
# hook). Everything here is offline: a response body is replayed through
# AB_NET_PROBE_INPUT and the clock is a file, so a machine that would wait a day is tested
# in a second.
#
#   ac-8 probe: a body that starts with the apk index magic is `ok`; bytes that are not a
#        feed (a captive portal page, a hijacked answer, an error page) are `portal`;
#        nothing at all is `offline`; a machine that cannot ask says `unknown` and the
#        follow is attempted anyway. The check is `head -c 4` + `cmp -s`, because the
#        measured device has neither `od` nor `xxd`, and `--spider` is never used (it
#        judged a captive portal `ok`).
#   ac-8 ladder: six rungs in the first five minutes (immediately, then 15/30/60/120 s),
#        then one rung every 30 minutes until a day has passed, then `follow=abandoned`
#        with `reason=network` in the record. One ring log line per rung.
#   ac-8 lock: one apk transaction at a time. A live owner makes the rung a no-op, a lock
#        left by a dead writer (or by another boot) is taken over, and the lock is released
#        when the attempt ends.
#   ac-8 carriers: an `ifup` is one attempt and never holds up netifd; no other hotplug
#        action is a reason.
#   ac-1 boot: ab-boot's first-boot path calls no apk at all, never waits for the follow,
#        and leaves the record `follow=pending` for a later worker when there is nothing to
#        call yet. Its due gate and the library's agree on the same records.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-net-probe.sh"
ab_boot="$root/platform/etc/init.d/ab-boot"
hook="$root/platform/etc/hotplug.d/iface/90-ab-packages"
slot_cfg_lib="$root/platform/lib/ab-slot-cfg.sh"
partitions_lib="$root/platform/lib/ab-partitions.sh"

if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the network fallback library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi
if [ ! -f "$hook" ]; then
  printf 'not ok 1 - the iface hotplug hook exists\n' >&2
  printf '    missing %s\n' "$hook" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

esp="$tmp/esp"
mkdir -p "$esp/ab/log"
record_file="$esp/ab/packages"
entrylog="$tmp/entry.log"
: >"$entrylog"

# --- the target tree the probe and the transaction act on --------------------
# A directory, not the running system: the feed list, platform-release and the world are
# the only things either of them reads from it.
target="$tmp/target"
mkdir -p "$target/etc/apk/repositories.d"
cat >"$target/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
# the release the aligner moved this base to
https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/base/packages.adb
https://mirror.invalid/openwrt/releases/25.12.2/targets/x86/64/packages.adb
https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/luci/packages.adb
FEEDS
# The user's own list. It is never the file that decides whether this base can be
# followed, and it names a `targets/` URL on purpose: taking it would be the bug.
cat >"$target/etc/apk/repositories.d/customfeeds.list" <<'FEEDS'
https://user.invalid/decoy/targets/x86/64/packages.adb
FEEDS
printf 'PLATFORM_VERSION=0.0.13\nUPSTREAM_VERSION=25.12.2\n' >"$target/etc/platform-release"

# --- the clock and the sleeper ----------------------------------------------
# A day of waiting is 52 sleeps; the test must not wait for any of them. Both are
# commands, so the ladder runs at full speed and the trace of what it asked for is a file.
clock="$tmp/clock"
sleeps="$tmp/sleeps"
printf '1000000\n' >"$clock"
: >"$sleeps"
cat >"$tmp/now" <<EOF
#!/bin/sh
cat "$clock"
EOF
cat >"$tmp/nosleep" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >>"$sleeps"
printf '%s\n' "\$(( \$(cat "$clock") + \$1 ))" >"$clock"
[ -x "$tmp/after-sleep" ] && "$tmp/after-sleep" "\$1"
exit 0
EOF
chmod +x "$tmp/now" "$tmp/nosleep"

reset_clock() {
  printf '1000000\n' >"$clock"
  : >"$sleeps"
  rm -f "$tmp/after-sleep"
}

# --- the entry the fallback layer calls -------------------------------------
# The transaction belongs to platform/lib/upgrade/packages.sh; this unit only decides when
# to call it. The stub publishes `follow=followed` the way that library must, and records
# every call so "exactly one transaction" is a fact rather than an intention.
stub="$tmp/entry.sh"
cat >"$stub" <<'LIB'
ab_packages_follow_if_ready() {
	printf '%s\n' "$1" >>"${ENTRY_LOG:?}"
	# The transaction is inside apk: it has published nothing yet, which is exactly the
	# state a boot must never wait for. The test opens the gate when it wants it to finish.
	if [ -n "${ENTRY_GATE:-}" ]; then
		_w=0
		while [ ! -e "${ENTRY_GATE}" ] && [ "$_w" -lt 100 ]; do
			sleep 0.1 2>/dev/null || sleep 1
			_w=$((_w + 1))
		done
	fi
	AB_PACKAGES_FOLLOW_STATE=followed
	AB_PACKAGES_FOLLOW_REASON=none
	AB_PACKAGES_FOLLOW_VERSION=25.12.2
	ab_net_record_set follow=followed reason=none
	return 0
}
LIB

# An entry library that also answers the offline question: the real packages.sh owns it
# (`ab_packages_follow_can_offline`), and the worker must ask it before the feed.
stub_offline="$tmp/entry_offline.sh"
cat >"$stub_offline" <<'LIB'
ab_packages_follow_can_offline() {
	[ -n "$(ls "$1/etc/apk/ab/cache/"*.apk 2>/dev/null)" ]
}
ab_packages_follow_if_ready() {
	printf '%s\n' "$1" >>"${ENTRY_LOG:?}"
	AB_PACKAGES_FOLLOW_MODE=offline
	AB_PACKAGES_FOLLOW_UPGRADED=39
	AB_PACKAGES_FOLLOW_KEPT=196
	AB_PACKAGES_FOLLOW_STATE=followed
	AB_PACKAGES_FOLLOW_REASON=none
	AB_PACKAGES_FOLLOW_VERSION=25.12.2
	ab_net_record_set follow=followed reason=none
	return 0
}
LIB

# --- the service reconcile the settled follow owes --------------------------
# platform/lib/ab-services.sh owns that repair and tests/modules/boot drives it. Here it is
# replaced by a stub that records the call, for two reasons: this unit is about when the
# follow runs, and the real reconcile waits for the boot to settle and then asks procd -
# neither of which a host without procd can answer, so a real one would only add a ring log
# line at an unpredictable moment.
services_log="$tmp/services.log"
services_stub="$tmp/services.sh"
: >"$services_log"
cat >"$services_stub" <<'LIB'
services_reconcile() {
	printf 'reconcile %s %s\n' "${1:-?}" "${2:-?}" >>"${SERVICES_LOG:?}"
	return 0
}
LIB

# --- response bodies --------------------------------------------------------
# Measured: a real apk v3 index starts with `ADBd`; an authentication page is HTML; a
# blackholed or refused connection writes nothing at all.
fx="$tmp/fx"
mkdir -p "$fx"
printf 'ADBd\001\000\000\000binary index follows' >"$fx/ok"
printf '<html><head><title>Sign in</title></head></html>' >"$fx/portal"
: >"$fx/offline"
printf 'ADB' >"$fx/short"

cat >"$tmp/probe.sh" <<'PS'
. "$AB_NET_PROBE_LIB"
out="$(ab_net_probe "${1:-}")"
rc=$?
printf '%s rc=%s\n' "${out}" "${rc}"
PS
probe_run() { # <fixture> [url] [target]
  AB_NET_PROBE_LIB="$lib" AB_ESP="$esp" AB_NET_PROBE_INPUT="$1" \
    AB_NET_PROBE_URL="${2:-}" AB_PACKAGES_TARGET="${3:-$target}" sh "$tmp/probe.sh"
}

cat >"$tmp/url.sh" <<'US'
. "$AB_NET_PROBE_LIB"
ab_net_probe_url "${1:-}"
US
url_of() {
  AB_NET_PROBE_LIB="$lib" AB_ESP="$esp" sh "$tmp/url.sh" "${1:-}"
}

# =========================================================================== #
# ac-8 the probe: three states, decided on the bytes
# =========================================================================== #

assert_eq "$(probe_run "$fx/ok")" "ok rc=0" \
  "ac-8 a body that starts with the index magic is a feed (ok)"
assert_eq "$(probe_run "$fx/portal")" "portal rc=1" \
  "ac-8 HTTP answering with a page that is not a feed is a portal, not ok"
assert_eq "$(probe_run "$fx/offline")" "offline rc=2" \
  "ac-8 nothing came back at all, so the feed is offline"
assert_eq "$(probe_run "$fx/short")" "portal rc=1" \
  "ac-8 a body shorter than the magic never compares equal, and is not a feed"
assert_eq "$(probe_run "" "" "$tmp/no-feed-target")" "unknown rc=0" \
  "ac-8 with no feed URL to ask the probe says unknown instead of guessing offline"

# `--spider` is what judged a captive portal ok on the measured machine. The probe must not
# use it: the only request made is a plain body fetch, and the decision is on the bytes.
probe_src="$(cat "$lib")"
probe_code="$(printf '%s\n' "$probe_src" | grep -vE '^[[:space:]]*#')"
assert_eq "$(printf '%s\n' "$probe_code" | grep -c -- '--spider' || true)" "0" \
  "ac-8 the probe never uses --spider"
assert_contains "$probe_code" 'head -c 4' \
  "ac-8 the magic is read with head -c 4 (the device has no od and no xxd)"
assert_contains "$probe_code" 'cmp -s' \
  "ac-8 ... and compared with cmp -s"
assert_eq "$(printf '%s\n' "$probe_code" | grep -Ec '(^|[^a-z-])(od|xxd)([^a-z-]|$)' || true)" "0" \
  "ac-8 neither od nor xxd is used anywhere in the fallback"

# The target index is the smallest file a feed publishes (measured 16390 bytes against
# ~1.5 MB for a packages index), so a `targets/` URL wins over the first URL in the file.
assert_eq "$(url_of "$target")" \
  "https://mirror.invalid/openwrt/releases/25.12.2/targets/x86/64/packages.adb" \
  "ac-8 the probe asks for the release's target index"
rm -f "$target/etc/apk/repositories.d/distfeeds.list"
printf 'https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/base/packages.adb\n' \
  >"$target/etc/apk/repositories.d/distfeeds.list"
assert_eq "$(url_of "$target")" \
  "https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/base/packages.adb" \
  "ac-8 without a targets line the first feed URL is asked instead"
assert_eq "$(url_of "$tmp/empty-target")" "" \
  "ac-8 a target with no feed list offers no URL to ask"
cat >"$target/etc/apk/repositories.d/distfeeds.list" <<'FEEDS'
https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/base/packages.adb
https://mirror.invalid/openwrt/releases/25.12.2/targets/x86/64/packages.adb
FEEDS

# The real fetch path: the fetcher writes the body, the probe classifies it. This is the
# branch a device runs, with a stand-in for uclient-fetch so nothing leaves the machine.
fetchbin="$tmp/fetchbin"
mkdir -p "$fetchbin"
cat >"$fetchbin/uclient-fetch" <<'FETCH'
#!/bin/sh
printf '%s\n' "$*" >>"${FETCH_LOG:?}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "${FETCH_BODY:-/dev/null}" "$out"
exit "${FETCH_RC:-0}"
FETCH
chmod +x "$fetchbin/uclient-fetch"
fetch_log="$tmp/fetch.log"
: >"$fetch_log"
real_probe() { # <body-file> [rc]
  PATH="$fetchbin:$PATH" AB_NET_PROBE_LIB="$lib" AB_ESP="$esp" FETCH_LOG="$fetch_log" \
    FETCH_BODY="$1" FETCH_RC="${2:-0}" AB_PACKAGES_TARGET="$target" sh "$tmp/probe.sh"
}
assert_eq "$(real_probe "$fx/ok")" "ok rc=0" \
  "ac-8 a fetcher that delivers an index is ok, judged on the body it wrote"
assert_contains "$(cat "$fetch_log")" "targets/x86/64/packages.adb" \
  "ac-8 ... and the URL it asked for is the target index"
assert_eq "$(real_probe "$fx/offline" 4)" "offline rc=2" \
  "ac-8 a fetcher that fails and writes nothing is offline"

# =========================================================================== #
# ac-8 the ladder: W1 then W3, one ring log line per rung
# =========================================================================== #

record() { tail -n 1 "$record_file" 2>/dev/null; }
seed() { printf '%s\n' "$1" >"$record_file"; }
pending_record() {
  seed "packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b"
}
ring() { cat "$esp/ab/log/boot-0.log" 2>/dev/null; }
reset_ring() { : >"$esp/ab/log/boot-0.log"; }

printf 'boot-1\n' >"$tmp/bootid"
printf 'console=ttyS0 ab.slot=b\n' >"$tmp/cmdline"

cat >"$tmp/worker.sh" <<'WS'
. "$AB_NET_PROBE_LIB"
"ab_net_follow_${1}" "${2:-}"
printf 'rc=%s\n' "$?"
WS
# run_worker <boot|ifup> <slot> [response-body]: one worker run, offline and instant.
# `worker_esp` and `worker_lock` are the two knobs a case changes (an ESP that cannot be
# written, a lock path that cannot be created); everything else is the fixture.
worker_esp="$esp"
worker_lock="$tmp/lock/follow.lock"
worker_gate=""
worker_w3_interval=""
worker_w3_deadline=""
run_worker() { # <boot|ifup> <slot> [fixture]
  AB_NET_PROBE_LIB="$lib" AB_ESP="$worker_esp" AB_PACKAGES_FILE="$record_file" \
    AB_NET_PROBE_INPUT="${3:-$fx/offline}" \
    AB_PACKAGES_LIB="${ENTRY_LIB:-$stub}" AB_PACKAGES_TARGET="$target" \
    AB_NET_FOLLOW_LOCK="$worker_lock" AB_BOOT_ID_FILE="$tmp/bootid" \
    AB_CMD="$tmp/cmdline" AB_NET_NOW_CMD="$tmp/now" AB_NET_SLEEP_CMD="$tmp/nosleep" \
    AB_NET_FOLLOW_W3_INTERVAL="$worker_w3_interval" AB_NET_FOLLOW_W3_DEADLINE="$worker_w3_deadline" \
    ENTRY_LOG="$entrylog" ENTRY_GATE="$worker_gate" AB_NET_SAY=0 \
    AB_SERVICES_LIB="$services_stub" SERVICES_LOG="$services_log" \
    sh "$tmp/worker.sh" "$1" "$2" 2>&1
}

reset_clock
reset_ring
: >"$entrylog"
rm -rf "$tmp/lock"
pending_record
# The window is shortened so the loop can be walked in a test; the shipped defaults are
# asserted on the library itself two cases below.
worker_w3_interval=1800
worker_w3_deadline=3600
out="$(run_worker boot b)"
worker_w3_interval=""
worker_w3_deadline=""
assert_eq "$out" "rc=1" \
  "ac-8 a boot worker that never sees a feed gives up after the window"
assert_eq "$(grep -c 'rung=w1-' <<<"$(ring)")" "6" \
  "ac-8 W1 is six rungs in the first five minutes (immediately, then 15/30/60/120 s)"
assert_eq "$(head -n 5 "$sleeps" | tr '\n' ' ')" "15 15 30 60 180 " \
  "ac-8 the W1 rungs are the offsets 15/30/60/120/300, so the six attempts fit in five minutes"
assert_eq "$(sed -n '6p' "$sleeps")" "1800" \
  "ac-8 W3 waits half an hour between rungs"
assert_eq "$(grep -c 'rung=w3-' <<<"$(ring)")" "2" \
  "ac-8 W3 keeps asking every half hour until the window closes (2 rungs in a 1 h window)"
assert_eq "$(grep -c 'result=pending reason=network' <<<"$(ring)")" "8" \
  "ac-8 every unsuccessful rung says why, and which probe answer it got"
assert_eq "$(grep 'rung=w1-1 ' <<<"$(ring)")" \
  "stage=packages-refresh slot=b rung=w1-1 probe=offline result=pending reason=network" \
  "ac-8 the first rung is immediate, names the probe answer and the reason"
assert_contains "$(ring)" \
  "stage=packages-refresh slot=b result=abandoned reason=network window=3600" \
  "ac-8 a window without a usable feed is a verdict, and the ring log says so"
assert_eq "$(record)" \
  "packages=aligned reason=network follow=abandoned version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b" \
  "ac-8 abandoned is written into the record, every field it did not set kept verbatim"
assert_eq "$(grep -c 'result=abandoned' <<<"$(ring)")" "1" \
  "ac-8 ... exactly once, not once per later rung"
assert_eq "$(cat "$entrylog")" "" \
  "ac-8 no transaction is run while the network is unusable"

# The shipped ladder, as the library defaults it: six rungs inside five minutes, then half an
# hour apart for a day. A shortened window above exercises the loop; these are the numbers a
# machine runs with.
defaults="$(AB_NET_PROBE_LIB="$lib" sh -c '. "$1"; printf "%s|%s|%s\n" "$AB_NET_FOLLOW_W1" "$AB_NET_FOLLOW_W3_INTERVAL" "$AB_NET_FOLLOW_W3_DEADLINE"' _ "$lib")"
assert_eq "$defaults" "0 15 30 60 120 300|1800|86400" \
  "ac-8 the shipped ladder is six rungs in five minutes, then every 30 minutes until 24 h"

# A portal is not an offline machine and neither is a feed: the ladder stops at the first
# rung that works, and the transaction runs exactly once. The sleeper turns the answer into
# a real feed on its third wait (the 30 s rung), so the first two rungs have to fail.
reset_clock
reset_ring
: >"$entrylog"
rm -rf "$tmp/lock"
pending_record
cp "$fx/offline" "$tmp/probe-body"
cat >"$tmp/after-sleep" <<AFTER
#!/bin/sh
[ "\$1" = "30" ] && cp "$fx/ok" "$tmp/probe-body"
exit 0
AFTER
chmod +x "$tmp/after-sleep"
out="$(run_worker boot b "$tmp/probe-body")"
assert_eq "$out" "rc=0" "ac-8 a feed that comes back ends the ladder instead of waiting it out"
assert_eq "$(grep -c '' "$entrylog")" "1" \
  "ac-8 the transaction runs exactly once, on the first rung that can reach a feed"
assert_eq "$(head -n 3 "$sleeps" | tr '\n' ' ')" "15 15 30 " \
  "ac-8 ... and no rung after it is waited for"
assert_eq "$(grep -c '' "$sleeps")" "3" \
  "ac-8 ... the ladder stopped at the rung that worked"
assert_eq "$(grep -c 'result=abandoned' <<<"$(ring)")" "0" \
  "ac-8 a followed base is never abandoned"
assert_contains "$(record)" "follow=followed" \
  "ac-8 the record ends followed"

# =========================================================================== #
# ac-8 the lock: one transaction at a time
# =========================================================================== #

reset_clock
reset_ring
: >"$entrylog"
pending_record
rm -rf "$tmp/lock"
mkdir -p "$tmp/lock/follow.lock"
# A live worker of this boot holds it: the rung must be a no-op, not a second transaction.
printf 'pid=%s boot=boot-1 at=999\n' "$$" >"$tmp/lock/follow.lock/owner"
out="$(run_worker ifup b "$fx/ok")"
assert_eq "$out" "rc=0" "ac-8 an ifup while a worker holds the lock still succeeds"
assert_eq "$(cat "$entrylog")" "" \
  "ac-8 ... but runs no second apk transaction"
assert_contains "$(ring)" "stage=packages-refresh slot=b rung=w2-ifup result=skipped reason=locked" \
  "ac-8 the skipped rung is in the ring log, with the reason"
assert_eq "$(cat "$tmp/lock/follow.lock/owner")" "pid=$$ boot=boot-1 at=999" \
  "ac-8 the live owner's lock is not taken over"

# A lock left by a writer that is gone is taken over: refusing forever after a power cut
# would be the same as never following again.
printf 'pid=999999 boot=boot-1 at=999\n' >"$tmp/lock/follow.lock/owner"
out="$(run_worker ifup b "$fx/ok")"
assert_eq "$out" "rc=0" "ac-8 an ifup with a stale lock succeeds"
assert_eq "$(grep -c '' "$entrylog")" "1" \
  "ac-8 ... and the transaction runs: the lock of a dead writer is taken over"
assert_eq "$(test -d "$tmp/lock/follow.lock" && echo present || echo released)" "released" \
  "ac-8 the lock is released when the attempt ends"

# A lock from another boot cannot have a live owner whatever its pid says.
pending_record
mkdir -p "$tmp/lock/follow.lock"
printf 'pid=%s boot=boot-0 at=1\n' "$$" >"$tmp/lock/follow.lock/owner"
: >"$entrylog"
out="$(run_worker ifup b "$fx/ok")"
assert_eq "$(grep -c '' "$entrylog")" "1" \
  "ac-8 a lock from an earlier boot is taken over even though its pid is now in use"

# Where /var/lock cannot be used at all the ESP carries the same lock - a checkout, a
# chroot and the CI host have no writable /var/lock, and refusing to follow there would be
# a verdict about the host, not about the network.
reset_ring
: >"$entrylog"
pending_record
printf 'not a directory\n' >"$tmp/lock-blocker"
worker_lock="$tmp/lock-blocker/follow.lock"
out="$(run_worker ifup b "$fx/ok")"
assert_eq "$out" "rc=0" "ac-8 an ifup still runs when /var/lock is unusable"
assert_eq "$(grep -c '' "$entrylog")" "1" \
  "ac-8 ... the lock moves to the ESP instead of the follow being skipped"
assert_eq "$(test -d "$esp/ab/.follow.lock" && echo taken || echo absent)" "absent" \
  "ac-8 ... and it is released again"
worker_lock="$tmp/lock/follow.lock"

# No lock anywhere is the one case where nothing may run: two interleaved apk transactions
# are the risk this exists for, so an unlockable machine does not guess.
ro_esp="$tmp/ro-esp"
mkdir -p "$ro_esp"
chmod 0555 "$ro_esp"
: >"$entrylog"
pending_record
worker_esp="$ro_esp"
worker_lock="$tmp/lock-blocker/follow.lock"
out="$(run_worker boot b "$fx/ok")"
assert_eq "$out" "rc=1" "ac-8 a lock that cannot be created anywhere stops the follow"
assert_eq "$(test -f "$entrylog" && cat "$entrylog")" "" \
  "ac-8 ... and no transaction runs without the lock"
worker_esp="$esp"
worker_lock="$tmp/lock/follow.lock"
worker_gate=""
worker_w3_interval=""
worker_w3_deadline=""
chmod 0755 "$ro_esp"
rm -rf "$tmp/lock"

# =========================================================================== #
# ac-8 the carriers: ifup
# =========================================================================== #

ifup_run() { # <fixture> [cmdline]
  AB_ESP="$esp" AB_PACKAGES_FILE="$record_file" AB_CMD="${2:-$tmp/cmdline}" \
    AB_NET_PROBE_LIB="$lib" AB_PACKAGES_LIB="$stub" AB_PACKAGES_TARGET="$target" \
    AB_NET_FOLLOW_LOCK="$tmp/lock/follow.lock" AB_BOOT_ID_FILE="$tmp/bootid" \
    AB_NET_NOW_CMD="$tmp/now" AB_NET_SLEEP_CMD="$tmp/nosleep" ENTRY_LOG="$entrylog" \
    ENTRY_GATE="$worker_gate" AB_NET_PROBE_INPUT="$1" AB_PACKAGES_IFUP_LOG="$tmp/ifup.log" \
    AB_SERVICES_LIB="$services_stub" SERVICES_LOG="$services_log" \
    ACTION=ifup sh "$hook"
}
wait_for() { # <file> <deciseconds>
  _w=0
  while [ "$_w" -lt "$2" ]; do
    [ -s "$1" ] && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  return 1
}
# wait_for_line <needle> <deciseconds>: the hook detaches, so a case has to wait for the
# child's last ring log line before the next case seeds a record the child would still be
# writing to.
wait_for_line() {
  _w=0
  while [ "$_w" -lt "$2" ]; do
    grep -q "$1" "$esp/ab/log/boot-0.log" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  return 1
}

reset_ring
: >"$entrylog"
: >"$services_log"
pending_record
ifup_run "$fx/ok"
assert_eq "$?" "0" "ac-8 the ifup hook succeeds"
wait_for_line "rung=w2-ifup" 100
assert_eq "$(cat "$entrylog")" "$target" \
  "ac-8 an ifup runs one follow against the system root"
assert_contains "$(ring)" "rung=w2-ifup" "ac-8 the rung is named W2 in the ring log"
# The rung that closes the follow window is the rung that repairs what the window cost: the
# first-boot worker gave up on the network and left the follow pending, so no other carrier
# would ever reconcile the daemons procd lost. `reconcile <slot> <follow-status>` is the call.
wait_for "$services_log" 100
assert_eq "$(cat "$services_log")" "reconcile b 0" \
  "ac-8 a follow that settles on an ifup is handed to the service reconcile"

# A rung that followed nothing leaves the window open, so it reconciles nothing: restarting
# daemons while apk is still moving packages is the race that repair exists to avoid.
: >"$entrylog"
: >"$services_log"
reset_ring
pending_record
ifup_run "$fx/offline"
wait_for_line "result=pending reason=network" 100
assert_eq "$(cat "$services_log")" "" \
  "ac-8 an ifup that finds no feed reconciles nothing"

# Only `ifup` is a reason. ifdown is the opposite fact and ifupdate says nothing new about
# reachability; either would multiply transactions for no information.
: >"$entrylog"
reset_ring
pending_record
ACTION=ifdown AB_ESP="$esp" AB_PACKAGES_FILE="$record_file" AB_NET_PROBE_LIB="$lib" \
  AB_PACKAGES_LIB="$stub" AB_PACKAGES_TARGET="$target" ENTRY_LOG="$entrylog" \
  AB_SERVICES_LIB="$services_stub" SERVICES_LOG="$services_log" \
  AB_NET_PROBE_INPUT="$fx/ok" sh "$hook"
sleep 0.3
assert_eq "$(cat "$entrylog")" "" "ac-8 ifdown is not a reason to run a transaction"
assert_eq "$(cat "$services_log")" "" "ac-8 ... and not a reason to reconcile a service"

# A record with nothing outstanding is the same answer: no probe, no transaction.
: >"$entrylog"
reset_ring
seed "packages=aligned reason=none follow=followed version=25.12.2 slot=b"
ifup_run "$fx/ok"
sleep 0.3
assert_eq "$(cat "$entrylog")" "" \
  "ac-8 a followed base is not asked again on ifup"
assert_eq "$(grep -c . <<<"$(ring)" || true)" "0" \
  "ac-8 ... and writes no rung into the ring log at all"

# netifd must never wait for a transaction: the entry is held inside the transaction and the
# hook still returns, with the record untouched.
: >"$entrylog"
pending_record
rm -f "$tmp/gate"
worker_gate="$tmp/gate"
ifup_run "$fx/ok"
assert_eq "$?" "0" "ac-8 the ifup hook succeeds while the transaction is still running"
assert_contains "$(record)" "follow=pending" \
  "ac-8 the ifup hook returns before the transaction it started has finished"
: >"$tmp/gate"
worker_gate=""
wait_for_line "rung=w2-ifup" 200

# A hotplug event during a boot that could not read its slot writes nothing but why.
: >"$entrylog"
reset_ring
pending_record
printf 'console=ttyS0\n' >"$tmp/cmdline"
ifup_run "$fx/ok"
sleep 0.3
assert_eq "$(cat "$entrylog")" "" \
  "ac-8 without ab.slot= on the command line there is no base to follow"
wait_for_line "reason=slot-unknown" 100
assert_contains "$(ring)" "result=skipped reason=slot-unknown" \
  "ac-8 ... and the hook says so instead of guessing a slot"
printf 'console=ttyS0 ab.slot=b\n' >"$tmp/cmdline"

# =========================================================================== #
# ac-1 the boot side: ab-boot decides, a worker does, no apk on the boot path
# =========================================================================== #

# The static half: this file never names apk. It is the one assertion that cannot be
# satisfied by a stub - the shipped file has to keep it true.
boot_src="$(cat "$ab_boot")"
assert_eq "$(printf '%s\n' "$boot_src" | grep -vE '^[[:space:]]*#' \
  | grep -Ec '(^|[^A-Za-z0-9_./-])apk([^A-Za-z0-9_./-]|$)' || true)" "0" \
  "ac-1 ab-boot runs no apk: the word does not appear in one line of code"
assert_eq "$(printf '%s\n' "$boot_src" | grep -c -- '--force-reinstall' || true)" "0" \
  "ac-1 ... and the empty reinstall that was the defect is gone from the boot path"

# The boot hook, run for real. Everything it calls is a stub: ab-slot, btrfs, mount and an
# apk that records every invocation, so "no apk on the boot path" is measured, not read.
boot_bin="$tmp/boot-bin"
fake_p4="$tmp/p4"
mounts="$tmp/mounts"
cmdline="$tmp/cmdline"
stub_di="$tmp/disk-identity.sh"
mkdir -p "$boot_bin" "$fake_p4/.ab" "$esp/ab/log" "$esp/boot/grub"
cat >"$boot_bin/ab-slot" <<STUB
#!/bin/sh
case "\$1" in
  status) printf 'slot=b upper=@overlay-25.12.2 generation=2 committed=b pending=none p4=ok data=ok docker=ok swap=ok next=b disk=/dev/sda method=partuuid boot=ok esp=ok packages=aligned packages_reason=none\n' ;;
  rootfs) printf '25.12.2\n' ;;
  next) printf 'next=b\n' ;;
  gc) printf 'ab-slot: deleting 0\n' ;;
esac
exit 0
STUB
cat >"$boot_bin/btrfs" <<'STUB'
#!/bin/sh
case "$1" in
  --version) printf 'btrfs-progs v6.12\n' ;;
  subvolume) exit 0 ;;
esac
exit 0
STUB
cat >"$boot_bin/mount" <<'STUB'
#!/bin/sh
exit 0
STUB
apk_log="$tmp/apk.calls"
: >"$apk_log"
cat >"$boot_bin/apk" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$apk_log"
exit 0
STUB
chmod +x "$boot_bin/ab-slot" "$boot_bin/btrfs" "$boot_bin/mount" "$boot_bin/apk"

cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
cat >"$mounts" <<MOUNTS
/dev/vda1 $esp vfat rw,noatime 0 0
/dev/vda4 $fake_p4 btrfs rw,noatime 0 0
MOUNTS
cat >"$stub_di" <<'STUB'
#!/bin/sh
di_resolve() { printf 'disk=%s method=%s\n' "${STUB_DISK:-/dev/sda}" "${STUB_METHOD:-partuuid}"; }
di_parent_disk() { printf '%s\n' "$1"; }
STUB

# The three knobs a boot case changes: the probe answer, the follow library, and the library
# that is supposed to be missing. Everything else is the fixture.
boot_probe=""
boot_entry_lib=""
boot_follow_lib=""
run_start() {
  reset_ring
  rm -rf "$tmp/lock"
  PATH="$boot_bin:$PATH" AB_ESP="$esp" AB_P4="$fake_p4" AB_MOUNTS="$mounts" \
    AB_CMD="$cmdline" AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" AB_PACKAGES_FILE="$record_file" \
    AB_PACKAGES_FOLLOW_LIB="${boot_follow_lib:-$lib}" AB_PACKAGES_LIB="${boot_entry_lib:-$stub}" \
    AB_PACKAGES_TARGET="$target" AB_NET_FOLLOW_LOCK="$tmp/lock/follow.lock" \
    AB_BOOT_ID_FILE="$tmp/bootid" AB_NET_NOW_CMD="$tmp/now" AB_NET_SLEEP_CMD="$tmp/nosleep" \
    AB_NET_PROBE_INPUT="${boot_probe:-$fx/portal}" \
    AB_NET_FOLLOW_W1="${W1:-0}" AB_NET_FOLLOW_W3_DEADLINE="${W3_DEADLINE:-0}" \
    AB_PACKAGES_FOLLOW_LOG="$tmp/follow-child.log" ENTRY_LOG="$entrylog" \
    AB_SERVICES_LIB="$services_stub" SERVICES_LOG="$services_log" \
    sh -c ". '$ab_boot'; start" >"$tmp/boot.out" 2>&1
}
wait_for_log() { # <needle> <deciseconds>
  _w=0
  while [ "$_w" -lt "$2" ]; do
    grep -q "$1" "$esp/ab/log/boot-0.log" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _w=$((_w + 1))
  done
  return 1
}

# The record an upgrade publishes for this base: pending, nothing attempted yet.
reset_clock
: >"$entrylog"
: >"$apk_log"
pending_record
run_start
assert_eq "$?" "0" "ac-1 the boot hook succeeds with a follow outstanding"
assert_contains "$(ring)" "stage=packages-refresh slot=b result=scheduled version=25.12.2" \
  "ac-1 the decision is a milestone in the ring log"
wait_for_log "result=abandoned" 100
assert_eq "$(cat "$apk_log")" "" \
  "ac-1 the whole boot runs no apk: a portal is not a reason to start a transaction"
assert_contains "$(grep 'probe=' "$esp/ab/log/boot-0.log" | head -n 1)" "probe=portal" \
  "ac-1 the worker asked the probe and made the portal answer visible"
assert_contains "$(record)" "follow=abandoned" \
  "ac-1 an unreachable network ends in the record, not in a claim the machine cannot keep"

# With a feed, the worker calls the transaction - and it is still not ab-boot that does it.
reset_clock
: >"$entrylog"
: >"$apk_log"
pending_record
rm -f "$tmp/gate"
worker_gate="$tmp/gate"
boot_probe="$fx/ok"
run_start
boot_rc=$?
boot_probe=""
assert_eq "$boot_rc" "0" "ac-1 the boot hook succeeds when a feed is reachable"
assert_contains "$(record)" "follow=pending" \
  "ac-1 the boot path does not wait for the follow: the record is untouched when start returns"
wait_for "$entrylog" 100
assert_eq "$(cat "$entrylog")" "$target" \
  "ac-1 the detached worker runs the follow against the system root"
: >"$tmp/gate"
worker_gate=""
wait_for_line "entry=ab_packages_follow_if_ready" 200
assert_contains "$(record)" "follow=followed" \
  "ac-1 ... and the transaction's own verdict lands afterwards, from the worker"
assert_eq "$(cat "$apk_log")" "" \
  "ac-1 ab-boot itself never runs apk; the transaction belongs to the follow library"
assert_contains "$(ring)" "entry=ab_packages_follow_if_ready" \
  "ac-1 the worker logs which entry it called, so a library skew is visible"
assert_contains "$(ring)" "probe=ok" "ac-1 the rung that ran recorded what the probe answered"

# Prefetched bodies make the network question moot: the offline rung has to run BEFORE the
# probe, otherwise a machine whose bodies are on the disk waits rungs for a feed it does not
# need (measured 2026-11-18 on the device: probe=offline four times, then an ifup applied it).
reset_clock
: >"$entrylog"
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
rm -f "$tmp/gate"
pending_record
boot_probe="$fx/portal"
boot_entry_lib="$stub_offline"
run_start
boot_probe=""
boot_entry_lib=""
assert_eq "$?" "0" "ac-6 the boot hook succeeds with the bodies already prefetched"
wait_for_line "entry=ab_packages_follow_if_ready" 200
assert_eq "$(cat "$entrylog")" "$target" \
  "ac-6 the prefetched bodies are applied on the first rung, without waiting for a feed"
assert_contains "$(ring)" "probe=prefetched" \
  "ac-6 the ring log says the rung did not need the network"
assert_eq "$(grep -c 'probe=portal' "$esp/ab/log/boot-0.log" 2>/dev/null || true)" "0" \
  "ac-6 a captive portal is never even asked about a follow that needs no network"
assert_contains "$(ring)" "mode=offline" \
  "ac-6 and the mechanism the transaction used is in the ring log"
assert_contains "$(ring)" "upgraded=39 kept=196" \
  "ac-6 together with what it moved, so ac-6 reads off the log as well as the record"
rm -rf "$target/etc/apk/ab/cache"

# A base that was already followed is not asked again: the record is the only input.
reset_clock
: >"$entrylog"
reset_ring
seed "packages=aligned reason=none follow=followed version=25.12.2 slot=b"
boot_probe="$fx/ok"
run_start
boot_probe=""
sleep 0.3
assert_eq "$(grep -c 'result=scheduled' <<<"$(ring)")" "0" \
  "ac-1 a followed base is not scheduled again on a later boot"
assert_eq "$(cat "$entrylog")" "" "ac-1 ... and no transaction is run"

# A record for another slot is another base's business.
reset_clock
: >"$entrylog"
reset_ring
seed "packages=aligned reason=none follow=pending version=25.12.2 slot=a"
boot_probe="$fx/ok"
run_start
boot_probe=""
sleep 0.3
assert_eq "$(cat "$entrylog")" "" \
  "ac-1 a follow outstanding for the other slot is not run against this one"

# Nothing to call yet: the record has to stay pending, because nothing was followed.
reset_clock
: >"$entrylog"
reset_ring
pending_record
emptylib="$tmp/empty-lib.sh"
cat >"$emptylib" <<'LIB'
expose_nothing() { :; }
LIB
boot_entry_lib="$emptylib"
boot_probe="$fx/ok"
run_start
boot_entry_lib=""
boot_probe=""
wait_for_log "reason=entry-missing" 100
assert_contains "$(ring)" "result=deferred reason=entry-missing" \
  "ac-1 a library with no follow entry is reported instead of being guessed at"
assert_contains "$(record)" "follow=pending" \
  "ac-1 ... and the record keeps follow=pending for a later worker"
assert_contains "$(record)" "reason=none" \
  "ac-1 ... and claims nothing about the network either"

# The platform layer without the fallback library still follows once, the way it did before
# this unit existed. That path is what a partial install or a chroot has.
reset_clock
: >"$entrylog"
reset_ring
pending_record
legacy="$tmp/legacy-lib.sh"
cat >"$legacy" <<LIB
ab_packages_refresh() {
  printf '%s\n' "\$1" >>"$entrylog"
  AB_PACKAGES_REFRESH_STATE=aligned
  AB_PACKAGES_REFRESH_REASON=none
  AB_PACKAGES_REFRESH_VERSION=25.12.2
  return 0
}
LIB
boot_follow_lib="$tmp/no-such-library.sh"
boot_entry_lib="$legacy"
run_start
boot_rc=$?
boot_follow_lib=""
boot_entry_lib=""
assert_eq "$boot_rc" "0" "ac-1 the boot hook succeeds without the fallback library"
wait_for_log "result=aligned reason=none version=25.12.2" 100
assert_contains "$(ring)" "stage=packages-refresh slot=b result=aligned reason=none version=25.12.2" \
  "ac-1 the one-shot path reports the follow the same way the ring log always has"
assert_eq "$(cat "$entrylog")" "$target" \
  "ac-1 ... and calls the library's oldest entry when it is the only one there is"

# =========================================================================== #
# ac-1/ac-8 one rule, two carriers: the due gate
# =========================================================================== #
#
# ab-boot's `packages_refresh_due` and the library's `ab_net_follow_due` are the same rule
# written in two places (a boot hook cannot be sourced by a hotplug hook). Two copies of a
# rule drift; the assertion that they answer the same on the same records is what keeps
# them one rule.

boot_due() { # <slot>
  AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; packages_refresh_due "$2"' _ "$ab_boot" "$1"
}
lib_due() { # <slot>
  AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_net_follow_due "$2"' _ "$lib" "$1"
}
due_pair() { # <record> <slot> <expected rc>
  seed "$1"
  boot_due "$2"
  b=$?
  lib_due "$2"
  l=$?
  assert_eq "$b/$l" "$3/$3" \
    "ac-1 the boot hook and the fallback library agree on: $1"
}

due_pair "packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~x slot=b" b 0
due_pair "packages=aligned reason=none follow=followed version=25.12.2 slot=b" b 1
due_pair "packages=aligned reason=none follow=abandoned version=25.12.2 slot=b" b 1
due_pair "packages=aligned reason=none follow=failed version=25.12.2 slot=b" b 1
due_pair "packages=aligned reason=none follow=pending version=25.12.2 slot=a" b 1
due_pair "packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b" b 0
due_pair "packages=aligned reason=none version=25.12.2 slot=b refresh=25.12.2" b 1
due_pair "packages=unknown reason=no-record slot=b" b 1
# `follow=pending` is the due flag: a base that owes a follow is due even when the record
# cannot name its version (the ring log then says version=unknown).
due_pair "packages=aligned reason=none follow=pending version=unknown slot=b" b 0
# A record that carries neither `follow=` nor a usable `version=` is the one place the boot
# carrier is stricter than the record's owner: there is no base named to follow, so it starts
# no worker. Both carriers agree on that answer; see the seam cases below for the owner's.
due_pair "packages=aligned reason=none version=unknown slot=b" b 1

# The record writer both carriers use: it touches only the fields it is given, keeps the
# order of the rest (reason= has to stay the second field) and refuses a foreign line.
seed "packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b"
AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_net_record_set reason=network' _ "$lib"
assert_eq "$(record)" "packages=aligned reason=network version=25.12.2 kernel=kernel=6.12.103~x slot=b" \
  "ac-8 reason= is rewritten in place: it stays the second field"
AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_net_record_set follow=pending' _ "$lib"
assert_eq "$(record)" "packages=aligned reason=network version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=pending" \
  "ac-8 a field the record does not carry yet is appended, not inserted"
AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_net_record_set follow=abandoned reason=network' _ "$lib"
assert_eq "$(record)" "packages=aligned reason=network version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=abandoned" \
  "ac-8 a field that is already there keeps its position when it is rewritten"
seed "this is not a package record"
AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_net_record_set follow=abandoned' _ "$lib"
assert_eq "$(record)" "this is not a package record" \
  "ac-8 a line this format does not understand is never rewritten into one"

# =========================================================================== #
# ac-1/ac-8 the seam: the library that owns the record
# =========================================================================== #
#
# This unit decides *when*, platform/lib/upgrade/packages.sh decides *what*: the record's
# fields, its gate and its publisher are that library's. These cases drive the shipped one, so
# the interface is tested instead of assumed.

pkg_lib="$root/platform/lib/upgrade/packages.sh"
seam_run() { # <shell body>
  AB_ESP="$esp" AB_PACKAGES_FILE="$record_file" AB_PACKAGES_LIB="$pkg_lib" \
    sh -c '. "$1"; . "$2"; AB_NET_ENTRY_LOADED=1; '"$1" _ "$lib" "$pkg_lib"
}

pending_record
seam_run 'ab_net_follow_publish_network'
assert_eq "$(record)" \
  "packages=aligned reason=network follow=pending version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=ab-packages update" \
  "ac-8 the network verdict is published by the library that owns the record, hint and all"

seam_run 'ab_net_follow_abandon b'
assert_contains "$(record)" "follow=abandoned" \
  "ac-8 giving up after the window is published the same way"
assert_contains "$(record)" "hint=ab-packages update" \
  "ac-8 ... and keeps the command that retries it"

# Once the owning library is loaded, its gate is the one the worker uses, on every shape.
owner_gate_pair() { # <record> -> "owner/this-library"
  seed "$1"
  AB_ESP="$esp" AB_PACKAGES_FILE="$record_file" AB_PACKAGES_LIB="$pkg_lib" \
    sh -c '. "$1"; . "$2"; AB_NET_ENTRY_LOADED=1; ab_packages_follow_due b; o=$?; ab_net_follow_due b; printf "%s/%s" "$o" "$?"' \
    _ "$lib" "$pkg_lib"
}
assert_eq "$(owner_gate_pair "packages=aligned reason=none follow=pending version=25.12.2 slot=b")" "0/0" \
  "ac-1 a pending base is due, and the loaded library decides"
assert_eq "$(owner_gate_pair "packages=aligned reason=none follow=followed version=25.12.2 slot=b")" "1/1" \
  "ac-1 a followed base is settled for both"
assert_eq "$(owner_gate_pair "packages=aligned reason=none follow=abandoned version=25.12.2 slot=b")" "1/1" \
  "ac-1 an abandoned base is settled for both"
assert_eq "$(owner_gate_pair "packages=aligned reason=none version=25.12.2 slot=b refresh=25.12.2")" "0/0" \
  "ac-1 a record from the previous platform version is due once, as its owner documents"

finish
