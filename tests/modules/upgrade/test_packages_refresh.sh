#!/usr/bin/env bash
# Module: upgrade
# Package follow: the one controlled reinstall a freshly upgraded base gets on its first
# boot. `ab_packages_align` only moves metadata; a machine that crosses a release keeps
# the packages built for the old ABI, so ab-boot asks for this once per base.
#
#   ac-1 offline: one probe and nothing else. No apk is run, the record gains
#        `reason=offline refresh=<version>`, and an `aligned` verdict is never downgraded
#        to a claim the machine cannot keep. A feed that names another release than the
#        record does is `feeds-stale`: installing old-release packages on the new base is
#        worse than doing nothing.
#   ac-2 full: an index refresh plus one `apk add --force-reinstall` over the world minus
#        the kernel the A/B tooling owns, ending in `packages=aligned reason=none`.
#   ac-3 degrade: a failed full transaction falls back to the kernel/ABI subset
#        (kmod-*, libc, docker) and records `reason=partial`; a subset that also fails
#        records the status apk gave, and something to reinstall is never claimed as done.
#   ac-4 idempotent: ab-boot asks for the follow only for the slot an upgrade aligned, and
#        only until `refresh=<version>` is in the record; a second run writes the same line.
#   ac-5 prune: a world entry the target's feeds do not offer is dropped from the world (the
#        package stays installed, its /etc/config untouched) and the record names it;
#        everything offered -> nothing dropped; nothing offered -> the world keeps what this
#        library owns and the follow still completes; a pin whose version is gone is not a
#        missing package and is never dropped; offline drops nothing.
#
# The record `ab_packages_refresh` publishes is also read back with the real `ab-slot
# status`, so a new field cannot quietly make the state unreadable.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/upgrade/packages.sh"
ab_boot="$root/platform/etc/init.d/ab-boot"
ab_slot="$root/platform/usr/sbin/ab-slot"
slot_cfg_lib="$root/platform/lib/ab-slot-cfg.sh"
partitions_lib="$root/platform/lib/ab-partitions.sh"

if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the packages library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the target root the library is asked about ------------------------------
# It is a directory, not the running system, so the test describes a machine instead of
# needing one: the world file, the feed list and platform-release are the only three
# inputs the refresh reads from it.
target="$tmp/target"
mkdir -p "$target/etc/apk/repositories.d"
cat >"$target/etc/platform-release" <<'RELEASE'
PLATFORM_VERSION=0.0.12
UPSTREAM_VERSION=25.12.2
PLATFORM_STAGE=image
RELEASE
# The feed file the measured machine actually uses (device 192.168.2.49, 2026-11-18:
# /etc/apk/repositories.d/distfeeds.list; there is no /etc/apk/distfeeds.list and no
# /etc/apk/repositories on that image).
feed_url="https://mirror.invalid/openwrt/releases/25.12.2/packages/x86_64/base/packages.adb"
printf '%s\n' "$feed_url" >"$target/etc/apk/repositories.d/distfeeds.list"
# The shapes the measured world carries: two pinned entries, the kernel the A/B tooling
# owns, 96 kmods in the real one, and the packages whose reinstall is the fallback.
cat >"$target/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
kmod-usb-storage
kmod-nls-iso8859-1
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
docker
WORLD

# --- stubs: apk and the fetcher, nothing else --------------------------------
bin="$tmp/bin"
mkdir -p "$bin"

# The stub answers the way apk-tools 3.0.5 does on the measured machine: `apk add` names
# what it installs, `--root` and `--timeout` are global options in front of the applet,
# and nothing here installs anything. APK_ADD_FAIL_CALLS names the 1-based add call that
# has to fail, which is how the full-then-subset fall-back is driven.
# The stub answers the way apk-tools 3.0.5 does on the measured machine. Two answers matter
# as much as the transaction itself: `--simulate add` names what it cannot select
# (`  <entry> (no such package):` on stderr, exit 1) and `search -q -e` names what the
# indexes offer. APK_AVAILABLE is the feed's set, one name per line; a name missing from it is
# a package this release does not carry.
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
# Parse the way apk does: global options take a value, the applet decides the rest.
applet=""
simulate=0
skip=0
for arg in "$@"; do
  if [ "$skip" = "1" ]; then
    skip=0
    continue
  fi
  case "$arg" in
    --root|-p|--timeout|--cache-dir|--keys-dir|--repository|-X|--repositories-file | --repository-config)
      skip=1
      continue
      ;;
    --simulate|-s)
      simulate=1
      continue
      ;;
    update|add|fix|info|fetch|upgrade|search)
      applet=$arg
      break
      ;;
  esac
done
available() { grep -qx "$1" "${APK_AVAILABLE:-/dev/null}" 2>/dev/null; }
entries() {
  skip=0
  for arg in "$@"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$arg" in
      --root|-p|--timeout|--cache-dir|--keys-dir) skip=1 ;;
      add|search|--force-reinstall|-q|-e|-x|--*) ;;
      *) printf '%s\n' "$arg" ;;
    esac
  done
}
case "$applet" in
  update) exit "${APK_UPDATE_RC:-0}" ;;
  search)
    # `apk search -q -e <name>...`: the offered names, exit 1 when one is not there.
    rc=0
    for entry in $(entries "$@"); do
      if available "${entry%%[=<>~]*}"; then
        printf '%s\n' "${entry%%[=<>~]*}"
      else
        rc=1
      fi
    done
    exit "$rc"
    ;;
  add)
    if [ "$simulate" = "1" ]; then
      # A pin whose version is gone answers differently from a package the release lacks:
      # the name is in the index, the version is not. Measured 2026-11-18:
      #   htop-3.5.3-r1:\n    breaks: world[htop=3.3.0-r1]
      if [ -n "${APK_PIN_BROKEN:-}" ]; then
        for entry in $(entries "$@"); do
          if [ "$entry" = "${APK_PIN_BROKEN}" ]; then
            printf 'ERROR: unable to select packages:\n  %s:\n    breaks: world[%s]\n' \
              "${APK_PIN_BROKEN%%[=<>~]*}-9.9.9-r9" "${entry}" >&2
            exit 1
          fi
        done
      fi
      missing=""
      for entry in $(entries "$@"); do
        available "${entry%%[=<>~]*}" || missing="$missing $entry"
      done
      if [ -n "$missing" ]; then
        printf 'ERROR: unable to select packages:\n' >&2
        for entry in $missing; do
          printf '  %s (no such package):\n    required by: world[%s]\n' "$entry" "$entry" >&2
        done
        exit 1
      fi
      exit 0
    fi
    calls=$(grep ' add --force-reinstall' "${APK_CALLS:-/dev/null}" 2>/dev/null | grep -v -- '--simulate' | grep -c . || :)
    calls=${calls:-0}
    case ",${APK_ADD_FAIL_CALLS:-}," in
      *",${calls},"*) exit "${APK_ADD_FAIL_RC:-1}" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
APK
# uclient-fetch is the probe's fetcher on the machine; the stub only says whether the
# feed answers, so a case never needs a network.
cat >"$bin/uclient-fetch" <<'FETCH'
#!/bin/sh
printf '%s\n' "$*" >>"${PROBE_CALLS:-/dev/null}"
exit "${PROBE_RC:-0}"
FETCH
chmod +x "$bin/apk" "$bin/uclient-fetch"

: >"$tmp/apk.calls"
: >"$tmp/probe.calls"
# The feed's set: by default everything the world names is offered, so a case that says
# nothing about availability sees the pre-prune behaviour exactly.
available="$tmp/available.txt"
offered_all() {
  {
    awk '{ name = $0; sub(/[=<>~].*/, "", name); if (name != "kernel") print name }' "$target/etc/apk/world"
    # The index itself is readable: a feed that answers these names was read, which is what
    # separates "this release offers none of them" from "the index was never there".
    printf '%s\n' apk-openssl dropbear procd uci ubus
  } >"$available"
}
offered_all
export APK_AVAILABLE="$available"
export APK_CALLS="$tmp/apk.calls"
export PROBE_CALLS="$tmp/probe.calls"

# --- the sandbox ESP the record is published to ------------------------------
esp="$tmp/esp"
mkdir -p "$esp/ab"
record_file="$esp/ab/packages"

# seed_record: what the last upgrade published, in the aligner's own format (version= is
# the payload's rootfs, slot= the slot that was written, kernel= the identity it wrote).
seed_record() { # [extra-field...]
  printf 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b%s\n' \
    "${1:+ $1}" >"$record_file"
}
record() { tail -n 1 "$record_file" 2>/dev/null; }
# The apk log now carries four kinds of call: the index, the solver's --simulate answer, the
# indexes' answer (search), and the transaction. These two read the transaction alone.
txn_calls() { grep ' add --force-reinstall' "$tmp/apk.calls" 2>/dev/null | grep -v -- '--simulate' || true; }
txn_count() { txn_calls | grep -c . || true; }
all_calls() { grep -c . "$tmp/apk.calls" 2>/dev/null || true; }

run_refresh() {
  AB_ESP="$esp" PATH="$bin:$PATH" sh -c '
    . "$1"
    ab_packages_refresh "$2"
    printf "rc=%s state=%s reason=%s version=%s\n" \
      "$?" "${AB_PACKAGES_REFRESH_STATE}" "${AB_PACKAGES_REFRESH_REASON}" "${AB_PACKAGES_REFRESH_VERSION}"
  ' _ "$lib" "$target" 2>"$tmp/refresh.err"
}

reset_calls() { : >"$tmp/apk.calls"; : >"$tmp/probe.calls"; }

# =========================================================================== #
# ac-1: no feed, no apk, and no claim
# =========================================================================== #

seed_record
reset_calls
out="$(PROBE_RC=1 run_refresh)"
assert_eq "$out" "rc=2 state=aligned reason=offline version=25.12.2" \
  "ac-1 an unreachable feed is offline and keeps the aligned verdict it was given"
assert_eq "$(record)" \
  "packages=aligned reason=offline version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b refresh=25.12.2" \
  "ac-1 the aligned record keeps its state and gains reason=offline plus refresh=<version>"
assert_eq "$(grep -c ' add ' "$tmp/apk.calls" || true)" "0" \
  "ac-1 an offline machine runs no apk transaction at all"
assert_eq "$(grep -c ' update' "$tmp/apk.calls" || true)" "0" \
  "ac-1 the probe is not an apk update"
assert_eq "$(grep -c '' "$tmp/probe.calls")" "1" \
  "ac-1 the probe is exactly one request"
assert_eq "$(record | grep -c 'world_dropped=' || true)" "0" \
  "ac-1 an offline machine drops nothing from the world either"

# The record did not claim the refresh happened: a second boot asks again... no - it asks
# once per base, which is what refresh= is for. The state line is the honest half.
assert_contains "$(record)" "refresh=25.12.2" \
  "ac-1 the attempt is recorded even when it could not run (one attempt per base)"

# A feed that names another release than the record does cannot make the packages follow
# this base; installing the old release's packages is the ABI mismatch this exists to fix.
seed_record
reset_calls
printf '%s\n' "https://mirror.invalid/openwrt/releases/25.12.1/packages/x86_64/base/packages.adb" \
  >"$target/etc/apk/repositories.d/distfeeds.list"
out="$(run_refresh)"
assert_eq "$out" "rc=1 state=limited reason=feeds-stale version=25.12.2" \
  "ac-1 a feed that still names the old release is recorded as feeds-stale"
assert_eq "$(record)" \
  "packages=limited reason=feeds-stale version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b refresh=25.12.2" \
  "ac-1 feeds-stale replaces the reason, never the fields the aligner wrote"
assert_eq "$(grep -c ' add ' "$tmp/apk.calls" || true)" "0" \
  "ac-1 a stale feed installs nothing"
printf '%s\n' "$feed_url" >"$target/etc/apk/repositories.d/distfeeds.list"

# =========================================================================== #
# ac-2: the full transaction
# =========================================================================== #

# The file apk reads decides, not the neighbours: the measured machine keeps
# `customfeeds.list` (the user's own, naming no release) and `distfeeds.list.bak` (the
# image's copy, older than the live file) beside the real one. Neither may steer the probe.
printf '%s\n' "# add your custom package feeds here" >"$target/etc/apk/repositories.d/customfeeds.list"
printf '%s\n' "https://mirror.invalid/openwrt/releases/25.12.1/packages/x86_64/base/packages.adb" \
  >"$target/etc/apk/repositories.d/distfeeds.list.bak"
seed_record
reset_calls
out="$(run_refresh)"
assert_eq "$out" "rc=0 state=aligned reason=none version=25.12.2" \
  "ac-2 a reachable feed and a successful reinstall is aligned with no reason"
assert_eq "$(grep -c '' "$tmp/probe.calls")" "1" \
  "ac-2 the probe asks the feed apk reads, and only it"
assert_contains "$(cat "$tmp/probe.calls")" "$feed_url" \
  "ac-2 customfeeds.list and distfeeds.list.bak do not decide whether the base can be followed"
rm -f "$target/etc/apk/repositories.d/customfeeds.list" "$target/etc/apk/repositories.d/distfeeds.list.bak"
assert_eq "$(record)" \
  "packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b refresh=25.12.2" \
  "ac-2 the record is one line, the aligner's fields kept, refresh=<version> appended"
assert_eq "$(sed -n '1p' "$tmp/apk.calls")" \
  "--root $target --timeout 180 update" \
  "ac-2 the index is refreshed first: /var is a tmpfs, so a fresh boot has no apk index"
assert_eq "$(txn_calls)" \
  "--root $target --timeout 180 add --force-reinstall base-files=1950~0c4cd0f9920a kmod-usb-storage kmod-nls-iso8859-1 libc=1.2.5-r5 htop=3.3.0-r1 luci-theme-argon docker" \
  "ac-2 one reinstall of the whole world, constraints verbatim, minus the kernel"
assert_eq "$(txn_count)" "1" "ac-2 the world is reinstalled exactly once"
assert_eq "$(grep -c -- '--simulate' "$tmp/apk.calls" || true)" "1" \
  "ac-2 the prune asks the solver first (one simulated transaction), it does not guess"
assert_eq "$(grep -c ' search ' "$tmp/apk.calls" || true)" "0" \
  "ac-2 and never has to confirm anything: everything the world names is offered"
assert_eq "$(record | grep -c 'world_dropped=' || true)" "0" \
  "ac-2 nothing was dropped, so the record carries no prune field"
assert_eq "$(grep -c 'kernel' "$tmp/apk.calls" || true)" "0" \
  "ac-2 the kernel package ab-slot owns is never reinstalled"

# =========================================================================== #
# ac-3: full fails, the kernel/ABI subset is the fall-back
# =========================================================================== #

seed_record
reset_calls
out="$(APK_ADD_FAIL_CALLS=1 run_refresh)"
assert_eq "$out" "rc=1 state=limited reason=partial version=25.12.2" \
  "ac-3 a failed full transaction degrades and says so"
assert_eq "$(record)" \
  "packages=limited reason=partial version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b refresh=25.12.2" \
  "ac-3 the degraded result is a limited record with reason=partial"
assert_eq "$(txn_calls | sed -n '2p')" \
  "--root $target --timeout 180 add --force-reinstall kmod-usb-storage kmod-nls-iso8859-1 libc=1.2.5-r5 docker" \
  "ac-3 the fall-back reinstalls only kmod-*, libc and docker"
assert_eq "$(txn_count)" "2" \
  "ac-3 the fall-back is one extra transaction, not a loop"

# Both transactions failing is a fact the operator has to be able to read: the status apk
# gave is the reason, and nothing claims the packages followed.
seed_record
reset_calls
out="$(APK_ADD_FAIL_CALLS=1,2 APK_ADD_FAIL_RC=99 run_refresh)"
assert_eq "$out" "rc=1 state=limited reason=apk-99 version=25.12.2" \
  "ac-3 a fall-back that also fails records the status apk gave"
assert_eq "$(record | sed 's/.*packages=\([a-z]*\) reason=\([^ ]*\).*/\1 \2/')" "limited apk-99" \
  "ac-3 and the record says limited"

# A world that holds nothing but the kernel has nothing to follow. It must not be
# reported as aligned on the strength of a transaction that never ran.
printf 'kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\n' >"$target/etc/apk/world"
seed_record
reset_calls
out="$(run_refresh)"
assert_eq "$out" "rc=0 state=aligned reason=no-packages version=25.12.2" \
  "ac-3 an empty world records no-packages instead of pretending"
assert_eq "$(all_calls)" "0" \
  "ac-3 and runs no apk at all"
cat >"$target/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
kmod-usb-storage
kmod-nls-iso8859-1
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
docker
WORLD

# =========================================================================== #
# ac-4: one attempt per base, and ab-boot asks exactly then
# =========================================================================== #

# The decision ab-boot makes is read off the record alone, so it can be asked directly.
boot_gate() { # <slot>
  AB_ESP="$esp" sh -c '. "$1" 2>/dev/null; packages_refresh_due "$2"' _ "$ab_boot" "$1"
}

seed_record
boot_gate b
assert_eq "$?" "0" "ac-4 an aligned record for the running slot with no refresh= is due"
boot_gate a
assert_eq "$?" "1" "ac-4 a record for another slot is not due"
printf 'packages=aligned reason=none version=25.12.2 refresh=25.12.2 slot=b\n' >"$record_file"
boot_gate b
assert_eq "$?" "1" "ac-4 a record that already carries refresh=<version> is not due again"
printf 'packages=unknown reason=no-record slot=b\n' >"$record_file"
boot_gate b
assert_eq "$?" "1" "ac-4 a record with no version= is not a freshly aligned base"
printf 'packages=aligned reason=none version=unknown slot=b\n' >"$record_file"
boot_gate b
assert_eq "$?" "1" "ac-4 an unknown version is never a key for a once-per-base attempt"

# A record this format does not understand is not carried over: the words of an unrelated
# line appended to a verdict would make a record no reader can take apart.
printf 'this is not a package record\n' >"$record_file"
reset_calls
run_refresh >/dev/null
assert_eq "$(record)" "packages=aligned reason=none refresh=25.12.2" \
  "ac-4 a foreign line is dropped, not glued to the verdict"

# A second run writes the same line: the record is a fact, not a counter.
seed_record
reset_calls
run_refresh >/dev/null
first="$(record)"
reset_calls
run_refresh >/dev/null
assert_eq "$(record)" "$first" "ac-4 the second run produces the identical record line"

# The record the refresh writes is read back by the real `ab-slot status`: a new field is
# only useful if the reader on the machine still answers `aligned`/`limited` and the reason.
state_json="$esp/ab/state.json"
cat >"$state_json" <<'JSON'
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
mkdir -p "$esp/boot/grub"
fake_p4="$tmp/p4"
mkdir -p "$fake_p4"
mounts="$tmp/mounts"
cat >"$mounts" <<MOUNTS
/dev/vda1 $esp vfat rw,noatime 0 0
/dev/vda4 $fake_p4 btrfs rw,noatime 0 0
MOUNTS
cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
stub_di="$tmp/disk-identity.sh"
cat >"$stub_di" <<'STUB'
#!/bin/sh
di_resolve() { printf 'disk=%s method=%s\n' "${STUB_DISK:-/dev/sda}" "${STUB_METHOD:-partuuid}"; }
di_parent_disk() { printf '%s\n' "$1"; }
STUB
slot_status() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$fake_p4" AB_MOUNTS="$mounts" \
    AB_SLOT_CFG_LIB="$slot_cfg_lib" AB_PARTITIONS_LIB="$partitions_lib" \
    AB_DISK_IDENTITY_LIB="$stub_di" sh "$ab_slot" status 2>/dev/null
}
pkg_field() { printf '%s' "$1" | sed -n 's/.* packages=\([a-z]*\) .*/\1/p'; }
pkg_reason_field() { printf '%s' "$1" | sed -n 's/.* packages_reason=\([a-z0-9-]*\).*/\1/p'; }

seed_record
reset_calls
run_refresh >/dev/null
status="$(slot_status)"
assert_eq "$(pkg_field "$status")" "aligned" \
  "ac-4 ab-slot status reads the refreshed record as aligned"
assert_eq "$(pkg_reason_field "$status")" "none" \
  "ac-4 and reads reason=none"

seed_record
reset_calls
PROBE_RC=1 run_refresh >/dev/null
status="$(slot_status)"
assert_eq "$(pkg_field "$status")" "aligned" \
  "ac-4 an offline attempt is still not a claim the machine cannot keep"
assert_eq "$(pkg_reason_field "$status")" "offline" \
  "ac-4 and the reason is the offline token ab-slot prints"

# =========================================================================== #
# ac-5: world entries the target release does not offer
# =========================================================================== #
# A move between releases can leave the world naming packages the new base's feeds do not
# carry. Every later apk transaction then fails to solve - including the reinstall above and
# a plain `apk add kmod-x` by hand - so those entries are dropped from the world. The
# packages themselves stay installed, and nothing under /etc/config or /data is touched.

world_default() {
  cat >"$target/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
kmod-usb-storage
kmod-nls-iso8859-1
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
docker
WORLD
  offered_all
}

# (b) one entry is not offered: it leaves the world, the rest is kept and reinstalled, and
#     the user's configuration for the dropped package stays exactly as it was.
world_default
mkdir -p "$target/etc/config"
printf "config openclash\n\toption ab_marker 'keep-me'\n" >"$target/etc/config/openclash"
cfg_before=$(cksum <"$target/etc/config/openclash")
grep -vx 'luci-theme-argon' "$available" >"$available.tmp"
mv "$available.tmp" "$available"
seed_record
reset_calls
out="$(run_refresh)"
assert_eq "$out" "rc=0 state=limited reason=pruned version=25.12.2" \
  "ac-5 a package this release does not offer is dropped, and the verdict says so"
assert_contains "$(record)" "world_dropped=1 dropped=luci-theme-argon" \
  "ac-5 the record names how many entries were dropped, and which"
assert_eq "$(grep -c '^luci-theme-argon$' "$target/etc/apk/world" || true)" "0" \
  "ac-5 the world no longer asks for it"
assert_eq "$(grep -c '^kernel=' "$target/etc/apk/world")" "1" \
  "ac-5 the kernel ab-slot owns is still pinned"
assert_eq "$(txn_count)" "1" "ac-5 the survivors are reinstalled in one transaction"
assert_eq "$(txn_calls | grep -c 'luci-theme-argon' || true)" "0" \
  "ac-5 and the transaction does not name what was dropped"
assert_contains "$(txn_calls)" "kmod-usb-storage" "ac-5 the offered entries are still reinstalled"
assert_eq "$(cksum <"$target/etc/config/openclash")" "$cfg_before" \
  "ac-5 the dropped package's /etc/config file is untouched (an unmanaged package is not a deleted one)"

# (c) nothing is offered: the world keeps what this library owns, the follow completes, and
#     no transaction is attempted with an empty set.
world_default
before_entries=$(grep -vc '^kernel=' "$target/etc/apk/world")
# A readable feed that carries none of the world's names: only the canaries answer.
printf '%s\n' apk-openssl dropbear >"$available"
seed_record
reset_calls
out="$(run_refresh)"
assert_eq "$out" "rc=0 state=limited reason=pruned version=25.12.2" \
  "ac-5 a release that offers none of them still completes the follow"
assert_eq "$(cat "$target/etc/apk/world")" \
  "kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1" \
  "ac-5 and the world keeps the one entry this library must never drop"
assert_contains "$(record)" "world_dropped=${before_entries}" \
  "ac-5 the count says how much was dropped"
assert_eq "$(txn_count)" "0" "ac-5 with nothing left there is no transaction to run"

# (d) a pin whose version is gone is not a missing package: the index still offers the name,
#     so nothing is dropped and the user's constraint stands.
world_default
seed_record
reset_calls
out="$(APK_PIN_BROKEN='htop=3.3.0-r1' run_refresh)"
assert_eq "$(grep -c '^htop=3.3.0-r1$' "$target/etc/apk/world")" "1" \
  "ac-5 an unavailable pin is kept: the package exists, the version does not"
assert_eq "$(record | grep -c 'world_dropped=' || true)" "0" \
  "ac-5 and no prune is recorded for it"
assert_eq "$out" "rc=0 state=aligned reason=none version=25.12.2" \
  "ac-5 the follow itself still reports what it did"

# (e) an index that cannot be read answers "no" to every question. That is the shape of a
#     world where nothing is offered, and the two must never be confused: nothing is dropped.
world_default
: >"$available"
seed_record
reset_calls
out="$(run_refresh)"
assert_eq "$out" "rc=0 state=aligned reason=none version=25.12.2" \
  "ac-5 an unusable index does not change the verdict"
assert_eq "$(grep -c '^luci-theme-argon$' "$target/etc/apk/world")" "1" \
  "ac-5 and not one world entry is dropped on the strength of a feed that answered nothing"
assert_eq "$(record | grep -c 'world_dropped=' || true)" "0" \
  "ac-5 no prune is recorded"

world_default

# =========================================================================== #
# ab-boot asks for it, and only once
# =========================================================================== #

# The boot hook is run for real: a fake ESP, a fake mount table and stubs for the tools
# the hook calls. The refresh library itself is replaced by a stub that only records that
# it was asked, so this case tests the wiring, not the transaction (which ac-2 covers).
boot_bin="$tmp/boot-bin"
mkdir -p "$boot_bin" "$fake_p4/.ab"
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
chmod +x "$boot_bin/ab-slot" "$boot_bin/btrfs" "$boot_bin/mount"

stublib="$tmp/stublib.sh"
cat >"$stublib" <<'LIB'
ab_packages_refresh() {
  printf '%s\n' "$1" >>"${STUB_REFRESH_LOG:?}"
  AB_PACKAGES_REFRESH_STATE=aligned
  AB_PACKAGES_REFRESH_REASON=none
  AB_PACKAGES_REFRESH_VERSION=25.12.2
  return 0
}
LIB
refresh_marker="$tmp/refresh.marker"
: >"$refresh_marker"
route="$tmp/route"
printf 'Iface\tDestination\tGateway\tFlags\neth0\t00000000\t0102A8C0\t0003\n' >"$route"

# The service reconcile the worker makes after its follow is not this unit's subject
# (tests/modules/boot drives it), and the real one would wait for the boot to settle and then
# ask procd, which this host cannot answer. The stub also keeps the detached child from writing
# a second ring log line after the next case has seeded the log.
services_stub="$tmp/services-stub.sh"
cat >"$services_stub" <<'LIB'
services_reconcile() {
  return 0
}
LIB

run_boot() {
  mkdir -p "$esp/ab/log"
  : >"$esp/ab/log/boot-0.log"
  PATH="$boot_bin:$PATH" AB_ESP="$esp" AB_P4="$fake_p4" AB_MOUNTS="$mounts" \
    AB_CMD="$cmdline" AB_SLOT_CFG_LIB="$slot_cfg_lib" \
    AB_PARTITIONS_LIB="$partitions_lib" AB_DISK_IDENTITY_LIB="$stub_di" \
    AB_PACKAGES_LIB="$stublib" AB_PACKAGES_TARGET="$target" \
    AB_PACKAGES_REFRESH_WAIT=0 AB_NET_ROUTE_FILE="$route" \
    AB_PACKAGES_REFRESH_LOG="$tmp/refresh-child.log" \
    AB_SERVICES_LIB="$services_stub" \
    STUB_REFRESH_LOG="$refresh_marker" \
    sh -c ". '$ab_boot'; start" >"$tmp/boot.out" 2>&1
}

wait_for() { # <file> <max-deciseconds>
  _waited=0
  while [ "$_waited" -lt "$2" ]; do
    [ -s "$1" ] && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _waited=$((_waited + 1))
  done
  return 1
}

# The record an upgrade published: this slot, this version, not refreshed yet.
seed_record
: >"$refresh_marker"
run_boot
assert_eq "$?" "0" "ac-4 the boot hook still succeeds with the follow scheduled"
wait_for "$refresh_marker" 50
assert_eq "$(cat "$refresh_marker" 2>/dev/null)" "$target" \
  "ac-4 the boot hook runs the refresh against the system root"
assert_contains "$(cat "$esp/ab/log/boot-0.log")" \
  "stage=packages-refresh slot=b result=scheduled version=25.12.2" \
  "ac-4 the schedule is a milestone in the ring log"
# The child reports its own outcome in the same ring log; wait for it, so the next case
# starts from a log nobody is still writing to.
wait_for_log() { # <needle> <max-deciseconds>
  _waited=0
  while [ "$_waited" -lt "$2" ]; do
    grep -q "$1" "$esp/ab/log/boot-0.log" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    _waited=$((_waited + 1))
  done
  return 1
}
wait_for_log "result=aligned reason=none" 50
assert_contains "$(cat "$esp/ab/log/boot-0.log")" \
  "stage=packages-refresh slot=b result=aligned reason=none version=25.12.2" \
  "ac-4 the detached child reports what the follow did"

# The same boot on the next reset: refresh=<version> is in the record, so nothing is
# scheduled and the library is not asked a second time.
seed_record "refresh=25.12.2"
: >"$refresh_marker"
run_boot
sleep 0.3
assert_eq "$(cat "$refresh_marker" 2>/dev/null)" "" \
  "ac-4 a base that was already refreshed is not asked again"
assert_eq "$(grep -c 'result=scheduled' "$esp/ab/log/boot-0.log" || true)" "0" \
  "ac-4 and the ring log does not carry a second schedule line"

finish
