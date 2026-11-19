#!/usr/bin/env bash
# Module: boot
# Service reconciliation after a first-boot package follow: the daemons procd lost while the
# follow was moving packages get one new start, and the ring log says what happened.
#
# The defect was measured on the reference machine on 2026-11-19, with a controlled hop. The
# first boot of a freshly aligned base moves the whole package set (measured: upgraded=128
# kept=138), procd starts the boot scripts inside that window, and a daemon that starts there
# finds a kernel module missing or being replaced. dockerd's own words from that boot:
#
#   failed to start daemon: Error initializing network controller: ... failed to add jump
#   rules to ipv4 NAT table: ... Warning: Extension addrtype revision 0 not supported,
#   missing kernel module?
#
# It stayed down for the whole boot. A longer wait cannot repair that, because procd starts a
# service once: dockerd's init script sets no `procd_set_param respawn`, so procd never
# retried it and never logged a crash loop. The repair is a new start, asked for after the
# boot has settled and the packages have stopped moving.
#
#   ac-3 the reconcile runs once the follow has settled, and its ring log line says it ran:
#        `stage=services-reconciled result=ok started=<n> failed=<csv> down=<csv>`
#   ac-3 the criterion is procd's instance record - an instance that is not running and that
#        exited non-zero - and not the `running` answer alone: a healthy boot of the reference
#        machine has seven enabled services whose `running` answers non-zero, and a service
#        that finished its job leaves an instance with exit_code=0. Both are skipped, so the
#        repair never re-runs a boot script and never reports `partial` on a good machine.
#   ac-3 one service whose own start refuses is `result=partial` with its name in `failed=`,
#        it does not stop the services after it, and it never makes the follow or the boot
#        fail
#   ac-3 a service that is not enabled is left alone even when procd lost it
#   ac-3 nothing is claimed that was not measured: a follow that never settled, a boot that
#        never settled and a machine that cannot ask procd are `result=skipped` with the
#        reason, never `result=ok started=0`
#   ac-3 the reconcile is detached: the boot hook returns before it runs, so no boot waits
#        for it
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_boot="$root/platform/etc/init.d/ab-boot"
console_lib="$root/platform/lib/ab-console.sh"
# The reconcile itself is platform/lib/ab-services.sh: an `ifup` has to reach the same repair,
# so the code moved out of the init script and the hook only sources it. The path is spelled
# out here for the same reason console_lib is - a hook that is sourced, not executed, cannot
# find its own siblings through $0.
services_lib="$root/platform/lib/ab-services.sh"
if [ ! -f "$ab_boot" ]; then
  printf 'not ok 1 - the boot hook exists\n' >&2
  printf '    missing %s\n' "$ab_boot" >&2
  exit 1
fi
if [ ! -f "$services_lib" ]; then
  printf 'not ok 1 - the service reconcile library exists\n' >&2
  printf '    missing %s\n' "$services_lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the machine this test describes ---------------------------------------
# Everything the reconcile touches is a fixture: the boot log, the consoles, the enabled
# services, their scripts, procd's own answers and the clock. Nothing here reads the host it
# runs on, which is the point - the host has no procd.
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/ab"
console_file="$tmp/console"
: >"$console_file"
rc_dir="$tmp/rc.d"
initd_dir="$tmp/init.d"
bin="$tmp/bin"
trace="$tmp/trace.log"
procd_dir="$tmp/procd"
mkdir -p "$rc_dir" "$initd_dir" "$bin" "$procd_dir"
: >"$trace"

uptime_file="$tmp/uptime"
printf '300.00 900.00\n' >"$uptime_file"

# The service stub. `running` and `start` answers come from files a case writes, so "already
# up", "down and startable" and "down and refusing" are three states of the fixture rather
# than three scripts. Every branch exits explicitly: a trailing "exit 0" would swallow the
# answer and make every service look healthy, which is the one thing this fixture must not do.
cat >"$bin/service" <<STUB
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >>"$trace"
case "\$1" in
    running)
        [ -f "$tmp/up.\$2" ] || exit 1
        exit 0
        ;;
    start)
        [ -f "$tmp/refuse.\$2" ] && exit 1
        : >"$tmp/up.\$2"
        exit 0
        ;;
esac
exit 0
STUB
chmod +x "$bin/service"

# install_service <name> <enabled: yes|no> [procd: yes|no]: a script and, when enabled, the
# S-link procd would walk. `procd` decides whether the script claims procd ownership, which
# is what makes "its not-running means something" true.
install_service() {
  cat >"$initd_dir/$1" <<STUB
#!/bin/sh
exec "$bin/service" "\$1" "$1"
STUB
  chmod +x "$initd_dir/$1"
  [ "${3:-yes}" = "no" ] || printf 'USE_PROCD=1\n' >>"$initd_dir/$1"
  rm -f "$rc_dir"/S??"$1"
  if [ "$2" = "yes" ]; then
    ln -s "../init.d/$1" "$rc_dir/S99$1"
  fi
}

# procd's answer, as the fixture describes it: one file per service holding the two fields
# ubus publishes. A service with no file has no instance record, which is the answer procd
# gives for a script it never instantiated.
procd_state() { # <name> <running: true|false> <exit_code>
  printf '%s %s\n' "$2" "$3" >"$procd_dir/$1"
}

# The query stub. It answers the three states services_procd_state distinguishes: the two
# values, "cannot ask" (exit 1) and "no instance" (exit 2).
cat >"$bin/procd-state" <<STUB
#!/bin/sh
[ -f "$procd_dir/\$1" ] || exit 2
cat "$procd_dir/\$1"
STUB
chmod +x "$bin/procd-state"

ring() { cat "$esp/ab/log/boot-0.log" 2>/dev/null; }
reset_ring() { : >"$esp/ab/log/boot-0.log"; }
console_out() { cat "$console_file" 2>/dev/null; }

# reset_services: a clean machine for the next case. Every service, every procd answer, every
# running/refusing marker and the trace go, so a case can only see the services it installed.
reset_services() {
  rm -rf "$rc_dir" "$initd_dir" "$procd_dir"
  mkdir -p "$rc_dir" "$initd_dir" "$procd_dir"
  rm -f "$tmp"/up.* "$tmp"/refuse.*
  : >"$trace"
  reset_ring
  : >"$console_file"
}

# reconcile <slot> <follow-rc>: one call of the function the detached worker makes.
reconcile() {
  AB_ESP="$esp" AB_CONSOLE_LIB="$console_lib" AB_CONSOLE_DEV="$console_file" \
    AB_CONSOLES=/dev/null AB_CONSOLE_SERIAL=/dev/null AB_CONSOLE_VT=/dev/null \
    AB_BOOT_RC_DIR="$rc_dir" AB_BOOT_INITD_DIR="$initd_dir" \
    AB_BOOT_UPTIME_FILE="$uptime_file" \
    AB_BOOT_PROCD_STATE_CMD="${PROCD_STATE_CMD-$bin/procd-state}" \
    AB_BOOT_SLEEP_CMD="${SLEEP_CMD:-$bin/nosleep}" AB_BOOT_SETTLE_S="${SETTLE_S:-0}" \
    AB_BOOT_SETTLE_WAIT_S="${SETTLE_WAIT_S:-0}" \
    AB_SERVICES_LIB="$services_lib" \
    sh -c ". '$ab_boot'; services_reconcile '$1' '$2'" 2>&1
}

cat >"$bin/nosleep" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$bin/nosleep"

# --- ac-3: the reconcile starts what procd lost ---------------------------
# The measured broken boot: dockerd's instance is not running and exited 1.
reset_services
install_service dockerd yes
procd_state dockerd false 1
reconcile b 0
assert_eq "$?" "0" "ac-3 the reconcile always succeeds: it never decides the boot"
assert_contains "$(ring)" "stage=services-reconciled slot=b result=ok started=1 failed=none down=dockerd" \
  "ac-3 the ring log says the reconcile ran, what procd lost, and what it started"
assert_contains "$(console_out)" "started dockerd, which procd lost during this boot" \
  "ac-3 the console carries the same fact, because a serial log is all a failed boot has"
assert_contains "$(cat "$trace")" "start dockerd" \
  "ac-3 the lost service was started once"
assert_eq "$(grep -c 'start dockerd' "$trace")" "1" \
  "ac-3 exactly one start per lost service"

# --- ac-3: the criterion is the instance record, not `running` -------------
# The measured healthy boot: seven enabled services answer `running` with non-zero and not
# one of them is broken. Starting them would re-run boot scripts out of procd's order.
reset_services
for name in system ucitrack firewall packet_steering cron openclash gpio_switch; do
  install_service "$name" yes
  # No instance record: procd never reached procd_close_instance for them.
done
install_service urandom_seed yes
# A one-shot that finished its job: an instance record, not running, exit_code=0.
procd_state urandom_seed false 0
install_service dockerd yes
procd_state dockerd false 1
reconcile b 0
assert_contains "$(ring)" "result=ok started=1 failed=none down=dockerd" \
  "ac-3 only the service procd actually lost is reconciled, however many others answer not-running"
assert_eq "$(grep -c '^start ' "$trace")" "1" \
  "ac-3 exactly one start in the whole reconcile, on a machine with nine enabled services"
assert_eq "$(grep -c 'start system' "$trace")" "0" \
  "ac-3 a boot script procd never instantiated is not started again"
assert_eq "$(grep -c 'start cron' "$trace")" "0" \
  "ac-3 a service whose start_service returned early is not started"
assert_eq "$(grep -c 'start urandom_seed' "$trace")" "0" \
  "ac-3 a service that finished its job (exit_code=0) is not restarted"
assert_eq "$(grep -c 'result=partial' <<<"$(ring)")" "0" \
  "ac-3 a healthy machine never reports partial, so the line keeps its one signal"

# A service that does not use procd is not procd's to repair, whatever its record says.
reset_services
install_service plainboot yes no
procd_state plainboot false 1
reconcile b 0
assert_contains "$(ring)" "result=ok started=0 failed=none down=none" \
  "ac-3 a script that does not claim procd ownership is not reconciled"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... and its start was never asked for"

# --- ac-3: a start that refuses is partial, and the loop goes on -----------
reset_services
install_service dockerd yes
install_service ttyd yes
procd_state dockerd false 1
procd_state ttyd false 1
: >"$tmp/refuse.dockerd"
reconcile b 0
assert_eq "$?" "0" "ac-3 a refused start does not make the reconcile fail"
assert_contains "$(ring)" "result=partial" \
  "ac-3 a service whose own start refuses makes the verdict partial, not ok"
assert_contains "$(ring)" "started=1" "ac-3 ... the one that did start is still counted"
assert_contains "$(ring)" "failed=dockerd" "ac-3 ... and the one that refused is named"
assert_contains "$(ring)" "down=dockerd,ttyd" "ac-3 both lost services are reported as down"
assert_contains "$(cat "$trace")" "start ttyd" \
  "ac-3 a refused start does not stop the services after it: the repair is best effort"

# The console keeps only the line it wrote last (ab-console writes each milestone to the
# primary channel), so the refused service is asserted on a case where it is the last one.
reset_services
install_service dockerd yes
procd_state dockerd false 1
: >"$tmp/refuse.dockerd"
reconcile b 0
assert_contains "$(console_out)" "dockerd is still down, its own start refused" \
  "ac-3 the console says which service is still down"

# --- ac-3: a service that is not enabled is left alone ---------------------
reset_services
install_service openclash no
procd_state openclash false 1
reconcile b 0
assert_contains "$(ring)" "result=ok started=0 failed=none down=none" \
  "ac-3 a service procd lost but nobody enabled is not started"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... and its start was never even asked for"

# --- ac-3: nothing is claimed that was not measured ------------------------
reset_services
install_service dockerd yes
procd_state dockerd false 1
reconcile b 1
assert_contains "$(ring)" "stage=services-reconciled slot=b result=skipped reason=follow-unsettled" \
  "ac-3 a follow that never settled is not reconciled, and the line says why"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... nothing is started on behalf of a follow that moved nothing"

reset_services
printf '10.00 20.00\n' >"$uptime_file"
SETTLE_S=120 SETTLE_WAIT_S=0 reconcile b 0
assert_contains "$(ring)" "result=skipped reason=boot-not-settled" \
  "ac-3 a boot that has not settled is not reconciled: the boot scripts have not run yet"
assert_contains "$(ring)" "uptime=10" \
  "ac-3 ... and the line carries the uptime it decided on"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... nothing is started out of procd's order"
printf '300.00 900.00\n' >"$uptime_file"

# A machine where the query itself is unavailable. The empty command makes the shipped path
# run, and this host has no ubus, which is exactly the state being described.
reset_services
PROCD_STATE_CMD="" reconcile b 0
assert_contains "$(ring)" "result=skipped reason=no-procd-query" \
  "ac-3 a machine that cannot ask procd says so instead of reporting nothing to do"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... and nothing is started on a guess"

reset_services
: >"$console_file"
reconcile b 0
assert_contains "$(ring)" "result=ok started=0 failed=none down=none" \
  "ac-3 a settled boot procd lost nothing on reconciles to a measured zero"

# --- ac-3 one repair per boot, even when the second carrier is already waiting -----
# The settle wait can be minutes long and the window has two carriers: an `ifup` can be
# waiting for the same boot to settle while the boot worker is. A sleeper that finishes the
# *other* carrier's repair and moves the clock forward turns that race into a fact, and the
# answer must be taken again right before the starts.
reset_services
install_service dockerd yes
procd_state dockerd false 1
cat >"$bin/settle-elsewhere" <<STUB
#!/bin/sh
printf 'stage=services-reconciled slot=b result=ok started=1 failed=none down=dockerd\n' \
  >>"$esp/ab/log/boot-0.log"
printf '300.00 900.00\n' >"$uptime_file"
exit 0
STUB
chmod +x "$bin/settle-elsewhere"
printf '10.00 20.00\n' >"$uptime_file"
SETTLE_S=120 SETTLE_WAIT_S=60 SLEEP_CMD="$bin/settle-elsewhere" reconcile b 0
assert_contains "$(ring)" "result=skipped reason=already-reconciled" \
  "ac-3 a repair that another carrier finished during the settle wait is not run again"
assert_eq "$(grep -c 'result=ok started=1' "$esp/ab/log/boot-0.log")" "1" \
  "ac-3 ... the boot keeps one repair line for the one repair"
assert_eq "$(grep -c '^start ' "$trace")" "0" \
  "ac-3 ... and nothing is started a second time"
printf '300.00 900.00\n' >"$uptime_file"

# --- ac-3: the reconcile is detached, so no boot waits for it -------------
# The call site is the detached worker of packages_follow_schedule. The follow library is a
# stub that records its own call and then returns at once, so this asserts the wiring: the
# boot hook returns with the reconcile not yet run, and the worker runs it afterwards.
record_file="$esp/ab/packages"
printf '%s\n' "packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b" \
  >"$record_file"
stub_follow="$tmp/follow.sh"
cat >"$stub_follow" <<STUB
ab_net_follow_boot() {
    printf 'followed %s\n' "\$1" >>"$trace"
    return 0
}
STUB

reset_services
install_service dockerd yes
procd_state dockerd false 1
AB_ESP="$esp" AB_CONSOLE_LIB="$console_lib" AB_CONSOLE_DEV="$console_file" \
  AB_CONSOLES=/dev/null AB_CONSOLE_SERIAL=/dev/null AB_CONSOLE_VT=/dev/null \
  AB_PACKAGES_FILE="$record_file" AB_PACKAGES_FOLLOW_LIB="$stub_follow" \
  AB_BOOT_RC_DIR="$rc_dir" AB_BOOT_INITD_DIR="$initd_dir" \
  AB_BOOT_UPTIME_FILE="$uptime_file" AB_BOOT_PROCD_STATE_CMD="$bin/procd-state" \
  AB_BOOT_SLEEP_CMD="$bin/nosleep" AB_BOOT_SETTLE_S=0 AB_BOOT_SETTLE_WAIT_S=0 \
  AB_SERVICES_LIB="$services_lib" \
  AB_PACKAGES_FOLLOW_LOG="$tmp/follow-child.log" \
  sh -c ". '$ab_boot'; packages_follow_schedule b" 2>&1
assert_eq "$?" "0" "ac-3 scheduling the follow returns at once"
assert_contains "$(ring)" "stage=packages-refresh slot=b result=scheduled" \
  "ac-3 the decision is in the ring log before the worker runs"
assert_eq "$(grep -c 'start dockerd' "$trace")" "0" \
  "ac-3 the boot hook returned before the worker started anything: the reconcile is detached"

# ... and the worker gets there on its own. The wait is bounded, and it is a wait on a fact
# in the ring log rather than a sleep of a guessed length.
waited=0
while [ "$waited" -lt 100 ]; do
  grep -q 'stage=services-reconciled' "$esp/ab/log/boot-0.log" 2>/dev/null && break
  sleep 0.1 2>/dev/null || sleep 1
  waited=$((waited + 1))
done
assert_contains "$(ring)" "stage=services-reconciled slot=b result=ok started=1" \
  "ac-3 the detached worker reconciles the lost service once the follow has settled"
assert_eq "$(grep -c 'followed b' "$trace")" "1" \
  "ac-3 the follow ran exactly once, before the reconcile"
assert_eq "$(grep -c 'start dockerd' "$trace")" "1" \
  "ac-3 ... and the lost service was started exactly once"

finish
