#!/usr/bin/env bash
# Module: upgrade
# The follow record: what a first boot is allowed to say about the packages it moved.
#
# The subject is the measured defect (device 192.168.2.49, 2026-11-18): `apk add
# --force-reinstall` prints `[APK unavailable, skipped]` and exits 0 when the installed version
# is not in the index, so the previous implementation published `packages=aligned` for a
# transaction that never ran. Everything here drives the engine with apk's *output* rather than
# its status, because that is the only thing that tells the two apart.
#
#   ac-1 no lie: a transaction that printed no upgrade and skipped what it was asked for ends
#        in `follow=failed reason=no-evidence`, never in `packages=followed`. `packages=aligned`
#        is only ever the aligner's verdict, and the align line says `follow=pending` with the
#        command that finishes the job.
#   ac-2 the record's shape: `reason=` is the second field (one regex each for state and reason),
#        `hint=` is last (its value is a command with a space), and every field this engine did
#        not establish - version=, kernel=, slot= - is carried from the line before it.
#   ac-3 prefetch: bodies land in <target>/etc/apk/ab/cache, the byte count is the sum of the
#        files themselves, and a prefetch that failed leaves `follow=pending reason=network`
#        instead of failing the upgrade.
#   ac-4 offline apply: with bodies in the cache the transaction runs `apk --network=0
#        --cache-dir <cache> upgrade <world minus kernel>`; the counters are read off the output
#        and the cache is emptied afterwards.
#   ac-5 the due flag: `follow=pending` is what makes a boot worker run, and followed/failed/
#        abandoned/never are answers a worker must not overrule.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/upgrade/packages.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the packages library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the machine the engine is asked about -----------------------------------
target="$tmp/target"
mkdir -p "$target/etc/apk" "$target/lib/apk/db"
cat >"$target/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
kmod-usb-storage
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
WORLD
: >"$target/lib/apk/db/installed"
record_file="$tmp/packages"

# --- stubs -------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"

# The stub answers the way apk-tools 3.0.5 does on the measured machine, and its *output* is
# the input of every judgement below: APK_UPGRADE_OUT is the file whose bytes apk would print.
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
applet=""
simulate=0
fetch_out=""
positional=""
while [ $# -gt 0 ]; do
  arg=$1
  shift
  case "$arg" in
    --root|--timeout|--cache-dir|--repositories-file|-p|--cache-max-age|--virtual) shift ;;
    -o) fetch_out=${1:-}; shift ;;
    --simulate) simulate=1 ;;
    -*) ;;
    update|upgrade|add|fetch|policy|search|info|del)
      if [ -n "$applet" ]; then positional="$positional $arg"; else applet=$arg; fi
      ;;
    *) positional="$positional $arg" ;;
  esac
done
case "$applet" in
  update) exit "${APK_UPDATE_RC:-0}" ;;
  fetch)
    # `apk fetch` that selects nothing exits 0 and leaves the directory alone: the body count
    # is the evidence, not the status. One body per package named on the command line.
    rc=${APK_FETCH_RC:-0}
    if [ "$rc" != "0" ]; then exit "$rc"; fi
    if [ "${APK_FETCH_NONE:-0}" = "1" ]; then exit 0; fi
    for body in ${positional}; do
      name=${body%%[=<>~]*}
      dd if=/dev/zero of="${fetch_out}/${name}-1.0-r1.apk" bs=1 count="${APK_FETCH_BYTES:-0}" 2>/dev/null
    done
    exit 0
    ;;
  upgrade)
    if [ "$simulate" = "1" ]; then
      [ -n "${APK_SIM_OUT:-}" ] && cat "${APK_SIM_OUT}"
      exit "${APK_SIM_RC:-0}"
    fi
    [ -n "${APK_UPGRADE_OUT:-}" ] && cat "${APK_UPGRADE_OUT}"
    exit "${APK_UPGRADE_RC:-0}"
    ;;
  add)
    # The offline apply is `add --virtual <name> --allow-untrusted --force-non-repository
    # <bodies>`; the prune's question is `--simulate add --force-reinstall <world lines>`.
    if [ "$simulate" = "1" ]; then exit "${APK_PRUNE_RC:-0}"; fi
    [ -n "${APK_UPGRADE_OUT:-}" ] && cat "${APK_UPGRADE_OUT}"
    exit "${APK_UPGRADE_RC:-0}"
    ;;
  del) exit 0 ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"

export PATH="$bin:$PATH"
export APK_CALLS="$tmp/apk.calls"
: >"$tmp/apk.calls"

# The aligner's record: what an upgrade published before any follow ran.
seed_record() { # [extra-field...]
  {
    printf 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b'
    [ -n "${1:-}" ] && printf ' %s' "$1"
    printf '\n'
  } >"$record_file"
}
record() { tail -n 1 "$record_file" 2>/dev/null; }
field() { printf '%s' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"; }
reset_calls() { : >"$tmp/apk.calls"; }

# run <function> [args...]: the library in its own shell, so no variable leaks between cases.
run() {
  _fn=$1
  shift
  AB_PACKAGES_FILE="$record_file" APK_CALLS="$tmp/apk.calls" sh -c '
    . "$1"
    shift
    fn=$1
    shift
    "$fn" "$@"
    printf "rc=%s follow=%s reason=%s upgraded=%s kept=%s cache=%s prefetch=%s/%s\n" \
      "$?" "${AB_PACKAGES_FOLLOW_STATE:-}" "${AB_PACKAGES_FOLLOW_REASON:-}" \
      "${AB_PACKAGES_FOLLOW_UPGRADED:-}" "${AB_PACKAGES_FOLLOW_KEPT:-}" \
      "${AB_PACKAGES_PREFETCH_CACHE:-}" "${AB_PACKAGES_PREFETCH_STATE:-}" "${AB_PACKAGES_PREFETCH_REASON:-}"
  ' _ "$lib" "$_fn" "$@"
}

# =========================================================================== #
# ac-1/ac-2: the aligner's half of the promise
# =========================================================================== #

seed_record
out="$(AB_PACKAGES_FILE="$record_file" sh -c '
  . "$1"
  rm -f "$2"
  mkdir -p "$3"
  printf "{\"rootfs\":\"25.12.2\"}\n" >"$3/manifest.json"
  mkdir -p "$4/etc/apk" "$5/etc/apk"
  printf "kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\n" >"$4/etc/apk/world"
  printf "kernel=6.12.87~bd81971a8c-r1\n" >"$5/etc/apk/world"
  ab_packages_align "$3" b "$4" "$5"
  printf "rc=%s fields=[%s]\n" "$?" "$(ab_packages_record_follow_fields)"
' _ "$lib" "$record_file" "$tmp/payload" "$tmp/base" "$tmp/upper" 2>/dev/null)"
assert_contains "$out" "fields=[follow=pending hint=ab-packages update]" \
  "ac-1 a successful alignment hands the caller the follow state and the command"
# The same alignment that failed must hand over nothing: a record that promises a follow the
# next boot cannot deliver is the kind of claim this task exists to remove.
out="$(AB_PACKAGES_FILE="$record_file" sh -c '
  . "$1"
  mkdir -p "$2/etc/apk" "$3/etc/apk"
  printf "busybox\n" >"$2/etc/apk/world"
  printf "kernel=6.12.87~bd81971a8c-r1\n" >"$3/etc/apk/world"
  ab_packages_align "$4" b "$2" "$3"
  printf "rc=%s fields=[%s]\n" "$?" "$(ab_packages_record_follow_fields)"
' _ "$lib" "$tmp/bare-base" "$tmp/bare-upper" "$tmp/payload" 2>/dev/null)"
assert_contains "$out" "fields=[]" "ac-1 a failed alignment promises no follow"

# The align-time record line: reason= second, hint= last, the aligner's facts carried.
seed_record
out="$(run ab_packages_follow_pending)"
assert_eq "$(record)" \
  "packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=ab-packages update" \
  "ac-2 the align-time line says a follow is pending and gives the command"
assert_contains "$out" "follow=pending reason=none" "ac-2 the published state is reported to the caller"
# The one property a reader depends on: state and reason are the first two fields.
assert_eq "$(record | sed -n 's/^packages=\([a-z]*\) reason=\([a-z0-9-]*\).*/\1 \2/p')" "aligned none" \
  "ac-2 ab-slot can read the state and the reason with one regex each"
assert_eq "$(record | sed -n 's/.* hint=\(.*\)$/\1/p')" "ab-packages update" \
  "ac-2 the hint is the rest of the line, because the command has a space in it"

# An align note survives: `feeds-rewritten` is a fact about the user's own file, not a verdict
# about this attempt, so nothing this engine does may drop it.
seed_record
printf 'packages=aligned reason=feeds-rewritten version=25.12.2 kernel=kernel=6.12.103~x slot=b\n' >"$record_file"
run ab_packages_follow_pending >/dev/null
assert_contains "$(record)" "reason=feeds-rewritten" \
  "ac-2 the alignment note is carried, not replaced by a bare none"
# A transient reason from a previous attempt is not carried: it describes a run that is over.
printf 'packages=aligned reason=network version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=pending hint=ab-packages update\n' >"$record_file"
run ab_packages_follow_pending >/dev/null
assert_eq "$(field "$(record)" reason)" "none" \
  "ac-2 a transient reason does not survive into the next line"

# The two states the user's own choices produce.
seed_record
run ab_packages_follow_never >/dev/null
assert_eq "$(record)" \
  "packages=aligned reason=none follow=never version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=none" \
  "ac-2 a system-only choice is follow=never with nothing left to run"
seed_record
run ab_packages_follow_abandoned >/dev/null
assert_contains "$(record)" "reason=network follow=abandoned" \
  "ac-2 an exhausted network fallback says abandoned and keeps the reason"
assert_contains "$(record)" "hint=ab-packages update" \
  "ac-2 and still tells the operator how to finish it by hand"

# =========================================================================== #
# ac-3: prefetch
# =========================================================================== #

cat >"$tmp/moving" <<'OUT'
( 1/3) Upgrading htop (3.3.0-r1 -> 3.5.3-r1)
( 2/3) Upgrading libc (1.2.5-r4 -> 1.2.5-r5)
( 3/3) Installing kmod-usb-storage (6.12.103-1)
OK: 282.0 MiB in 316 packages
OUT
seed_record
reset_calls
out="$(APK_SIM_OUT="$tmp/moving" APK_FETCH_BYTES=1000 run ab_packages_prefetch "$target" "local:luci-theme-argon")"
assert_contains "$out" "rc=0" "ac-3 a prefetch that landed bodies succeeds"
assert_contains "$out" "prefetch=ok/none" "ac-3 and says so"
assert_contains "$out" "cache=3000" "ac-3 the byte count is the sum of the bodies themselves"
assert_contains "$(sed -n '1p' "$tmp/apk.calls")" "--cache-dir $target/etc/apk/ab/cache --timeout 300 update" \
  "ac-3 the index is fetched into the cache first: a first boot has none"
# Measured 2026-11-18: `apk upgrade base-files=1950~...` fails with "not found" - a version
# qualified spec is not accepted by upgrade at all - so the transaction names packages. The
# pins are not lost: apk reads them from the world file the target tree carries.
assert_eq "$(sed -n '2p' "$tmp/apk.calls")" \
  "--root $target --cache-dir $target/etc/apk/ab/cache --timeout 300 upgrade --simulate base-files kmod-usb-storage libc htop luci-theme-argon" \
  "ac-3 the solver is asked which packages would move, by name, minus the kernel"
assert_contains "$(sed -n '3p' "$tmp/apk.calls")" \
  "fetch -o $target/etc/apk/ab/cache htop kmod-usb-storage libc" \
  "ac-3 and only the moving set is downloaded, not the 316-package world"
assert_eq "$(sed -n '3p' "$tmp/apk.calls" | grep -c 'kernel')" "0" \
  "ac-3 the kernel package ab-slot owns is never fetched"
assert_eq "$(record)" \
  "packages=aligned reason=none follow=pending skipped=local:luci-theme-argon cache=3000 version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=ab-packages update" \
  "ac-3 the record carries what the gate and the fetch established, and still says pending"
assert_eq "$(ls "$target/etc/apk/ab/cache"/*.apk 2>/dev/null | wc -l | tr -d ' ')" "3" \
  "ac-3 the bodies are on the target tree, where the first boot reads them"

# A prefetch that fetched nothing is not a prefetch: `apk fetch` exits 0 and leaves the
# directory alone, which is exactly the shape of the defect this task is about.
seed_record
reset_calls
out="$(APK_SIM_OUT="$tmp/moving" APK_FETCH_NONE=1 run ab_packages_prefetch "$target")"
assert_contains "$out" "rc=1" "ac-3 a fetch that landed nothing is not a success"
assert_contains "$out" "prefetch=failed/no-evidence" "ac-3 and the precise reason is for the ring log"
assert_contains "$(record)" "packages=aligned reason=network follow=pending" \
  "ac-3 the record falls back to reason=network, the design's one word for it"
assert_eq "$(record | grep -c 'cache=' || true)" "0" \
  "ac-3 and no cache size is claimed for a download that did not happen"
assert_eq "$(record | grep -c 'skipped=' || true)" "0" \
  "ac-3 nor an attribution list from a prefetch that failed"

# The same for an index that did not answer: the upgrade is not failed, the follow stays due.
seed_record
reset_calls
out="$(APK_UPDATE_RC=1 run ab_packages_prefetch "$target")"
assert_contains "$out" "rc=1" "ac-3 an unreachable index is a failed prefetch"
assert_contains "$out" "prefetch=failed/network" "ac-3 named as a network problem"
assert_contains "$(record)" "follow=pending" "ac-3 and the first boot still owes the follow"

# Nothing to prefetch is not a failure, and it does not touch the record.
seed_record
before="$(record)"
printf 'kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1\n' >"$tmp/kernel-only"
out="$(AB_PACKAGES_FILE="$record_file" sh -c '
  . "$1"
  mkdir -p "$2/etc/apk"
  cp "$3" "$2/etc/apk/world"
  ab_packages_prefetch "$2"
  printf "rc=%s\n" "$?"
' _ "$lib" "$tmp/kernel-target" "$tmp/kernel-only" 2>/dev/null)"
assert_contains "$out" "rc=3" "ac-3 a world with nothing to fetch is not a failure"
assert_eq "$(record)" "$before" "ac-3 and the record is left exactly as it was"

# =========================================================================== #
# ac-4: the offline apply
# =========================================================================== #

cat >"$tmp/upgraded" <<'OUT'
(1/3) Upgrading htop (3.3.0-r1 -> 3.5.3-r1)
(2/3) Upgrading libc (1.2.5-r4 -> 1.2.5-r5)
OK: 281.9 MiB in 316 packages
OUT
seed_record
# The prefetch left its bodies and its record facts behind.
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
: >"$target/etc/apk/ab/cache/libc-1.2.5-r5.apk"
printf 'packages=aligned reason=none follow=pending skipped=local:luci-theme-argon cache=3000 version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=ab-packages update\n' \
  >"$record_file"
reset_calls
out="$(APK_UPGRADE_OUT="$tmp/upgraded" run ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-4 the offline apply succeeds on the prefetched bodies"
assert_contains "$out" "follow=followed reason=none" "ac-4 and the record says the packages followed"
# Measured 2026-11-18 on apk-tools 3.0.5: `--network=0` is not an option at all (the boolean
# parser rejects it), and `--network=no` disables the repositories and reports "nothing to do",
# so the offline transaction is the prefetched *files* installed as a virtual package. With
# blackholed routes that moved 39 packages with zero network attempts.
assert_contains "$(sed -n '1p' "$tmp/apk.calls")" \
  "--cache-dir $target/etc/apk/ab/cache --cache-max-age 100000 add --virtual .ab-follow --allow-untrusted --force-non-repository" \
  "ac-4 one transaction over the prefetched bodies: the cache the prefetch filled, no repository"
assert_contains "$(sed -n '1p' "$tmp/apk.calls")" \
  "$target/etc/apk/ab/cache/htop-3.5.3-r1.apk" \
  "ac-4 the bodies themselves are what is installed"
assert_eq "$(sed -n '2p' "$tmp/apk.calls")" "--root $target --timeout 300 del .ab-follow" \
  "ac-4 the virtual entry is removed again, so the world keeps only what the user asked for"
assert_eq "$(grep -c ' update' "$tmp/apk.calls" || true)" "0" \
  "ac-4 an offline apply does not touch the network to refresh an index"
assert_eq "$(record)" \
  "packages=followed reason=none follow=followed upgraded=2 kept=3 skipped=local:luci-theme-argon cache=3000 version=25.12.2 kernel=kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 slot=b hint=none" \
  "ac-4 the record carries the transaction's counters, the gate's attribution and the cache size"
assert_eq "$(ls "$target/etc/apk/ab/cache" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-4 the cache is a consumable: its bodies and indexes are gone once it has run"

# The predicate the first boot asks before it asks the network: bodies on the disk mean the
# follow needs no feed at all. Measured 2026-11-18: without it the worker waited four rungs.
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
out="$(AB_PACKAGES_TARGET="$target" sh -c '. "$1"; ab_packages_follow_can_offline "$2"; echo "rc=$?"' _ "$lib" "$target" 2>/dev/null)"
assert_contains "$out" "rc=0" "ac-6 prefetched bodies say the follow can run offline"
rm -rf "$target/etc/apk/ab/cache"
out="$(AB_PACKAGES_TARGET="$target" sh -c '. "$1"; ab_packages_follow_can_offline "$2"; echo "rc=$?"' _ "$lib" "$target" 2>/dev/null)"
assert_contains "$out" "rc=1" "ac-6 no bodies leaves the offline question false, so the network fallback runs"

# A downgrade is a move: apk prints `Downgrading` for it, and the counter that reports
# `upgraded=` used to read only `Upgrading`. Measured 2026-11-18: a 25.12.2 slot crossing to
# 25.12.1 reported `upgraded=0` for a follow that really moved base-files and the kmods.
cat >"$tmp/downgraded" <<'OUT'
(1/2) Downgrading base-files (1950~0c4cd0f9920a -> 1942~cd0a06bfd3fd)
(2/2) Downgrading kmod-usb-storage (6.12.103-1 -> 6.12.94-1)
OK: 281.9 MiB in 316 packages
OUT
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/base-files-1942~cd0a06bfd3fd.apk"
: >"$target/etc/apk/ab/cache/kmod-usb-storage-6.12.94-1.apk"
seed_record
printf 'packages=aligned reason=none follow=pending cache=9 version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=ab-packages update\n' >"$record_file"
out="$(APK_UPGRADE_OUT="$tmp/downgraded" run ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-6 a follow that only has to downgrade still succeeds"
assert_contains "$(record)" "upgraded=2" "ac-6 a downgraded package counts as a package that moved"

# Reinstalling the version that is already there is evidence the transaction ran, but it is not
# a package that followed: `upgraded=0` with the other world entries kept is the honest answer.
cat >"$tmp/replaced" <<'OUT'
(1/2) Replacing libc (1.2.5-r5 -> 1.2.5-r5)
(2/2) Installing .ab-follow (20261118.154128)
OK: 282.0 MiB in 317 packages
OUT
: >"$target/etc/apk/ab/cache/libc-1.2.5-r5.apk"
seed_record
printf 'packages=aligned reason=none follow=pending cache=9 version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=ab-packages update\n' >"$record_file"
out="$(APK_UPGRADE_OUT="$tmp/replaced" run ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-6 a transaction that only replaced same-version bodies ran"
assert_contains "$(record)" "follow=followed" "ac-6 and is not reported as the silent no-op"
assert_contains "$(record)" "upgraded=0 kept=5" \
  "ac-6 nor does a replacement inflate the count of packages that followed"
rm -rf "$target/etc/apk/ab/cache"

# A failed attempt keeps what the prefetch established: the record is the only place the first
# boot can read "how much was downloaded" and "which entries are held back", and a failed run
# that published an empty fact list used to erase them (measured 2026-11-18 on the device: the
# record that ended `follow=followed` carried no cache= at all).
seed_record
printf 'packages=aligned reason=network follow=pending skipped=local:luci-theme-argon cache=4321 version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=ab-packages update\n' >"$record_file"
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
out="$(APK_UPGRADE_OUT="$tmp/noop" APK_UPGRADE_RC=99 run ab_packages_follow "$target")"
assert_contains "$out" "rc=1" "ac-6 a failed attempt is still a failure"
assert_contains "$(record)" "cache=4321" \
  "ac-6 but the cache size the prefetch established survives the failure"
assert_contains "$(record)" "skipped=local:luci-theme-argon" \
  "ac-6 and so does the attribution list"
rm -rf "$target/etc/apk/ab/cache"

# =========================================================================== #
# ac-1: the measured no-op
# =========================================================================== #

cat >"$tmp/noop" <<'OUT'
(1/2) [APK unavailable, skipped] Upgrading htop (3.3.0-r1)
(2/2) [APK unavailable, skipped] Upgrading luci-theme-argon (26.249.1-r1)
OK: 281.9 MiB in 316 packages
OUT
seed_record
mkdir -p "$target/etc/apk/ab/cache"
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
out="$(APK_UPGRADE_OUT="$tmp/noop" run ab_packages_follow "$target")"
assert_contains "$out" "rc=1" "ac-1 a transaction that skipped everything is not a success"
assert_contains "$(record)" "reason=no-evidence follow=failed" \
  "ac-1 the record names the silent no-op instead of publishing a verdict"
assert_eq "$(record | sed -n 's/^packages=\([a-z]*\).*/\1/p')" "aligned" \
  "ac-1 packages= keeps the aligner's verdict: nothing new was established"
assert_eq "$(record | grep -c 'upgraded=' || true)" "0" \
  "ac-1 and no counter is invented for a transaction that moved nothing"

# A transaction that failed says which status it failed with.
seed_record
: >"$target/etc/apk/ab/cache/htop-3.5.3-r1.apk"
out="$(APK_UPGRADE_OUT="$tmp/noop" APK_UPGRADE_RC=99 run ab_packages_follow "$target")"
assert_contains "$out" "rc=1" "ac-1 a failed transaction is a failed follow"
assert_contains "$(record)" "reason=apk-99 follow=failed" \
  "ac-1 and the record carries the status apk gave"

# Nothing to move is a real outcome, but it is decided by the solver, not by a silence: apk
# prints OK: with no upgrade, and the record says upgraded=0 with every entry kept.
printf 'OK: 281.9 MiB in 316 packages\n' >"$tmp/current"
seed_record
rm -rf "$target/etc/apk/ab/cache"
out="$(APK_SIM_OUT="$tmp/current" APK_UPGRADE_OUT="$tmp/current" run ab_packages_follow "$target" 2>&1)"
assert_contains "$out" "rc=0" "ac-4 a world that is already current follows trivially"
assert_contains "$out" "the world is current" "ac-4 and says which question answered it"
assert_contains "$(record)" "follow=followed" "ac-4 and the record says so"
assert_contains "$(record)" "upgraded=0 kept=5" \
  "ac-4 with every world entry reported as kept"
assert_eq "$(grep -c ' upgrade base-files' "$tmp/apk.calls" || true)" "0" \
  "ac-4 and no transaction runs when the solver says there is nothing to move"

# =========================================================================== #
# ac-4: no prefetch means the online route, and the probe gets a say
# =========================================================================== #

seed_record
rm -rf "$target/etc/apk/ab/cache"
reset_calls
out="$(APK_SIM_OUT="$tmp/upgraded" APK_UPGRADE_OUT="$tmp/upgraded" run ab_packages_follow "$target")"
assert_contains "$out" "rc=0" "ac-4 without bodies the follow uses the network"
assert_eq "$(sed -n '1p' "$tmp/apk.calls")" "--root $target --timeout 300 update" \
  "ac-4 and refreshes the index first: /var is a tmpfs on the measured machine"
# The prune asks apk between the index and the transaction - it has to, because one world
# entry this base no longer offers makes apk refuse the whole set - so the transaction is
# the line after that question, not the second line of the log.
assert_contains "$(sed -n '2p' "$tmp/apk.calls")" " --simulate add --force-reinstall " \
  "ac-4 and asks whether the world still names anything this base does not offer"
assert_contains "$(sed -n '3p' "$tmp/apk.calls")" \
  "--timeout 300 upgrade --simulate base-files kmod-usb-storage libc htop luci-theme-argon" \
  "ac-4 then asks the solver what the transaction would move, by name"
assert_contains "$(sed -n '4p' "$tmp/apk.calls")" \
  "--timeout 300 upgrade base-files kmod-usb-storage libc htop luci-theme-argon" \
  "ac-4 and runs one transaction over the world"

# A probe that says there is no usable network keeps the follow pending and runs no apk at all:
# a captive portal must not turn into a failed transaction in the record.
seed_record
reset_calls
printf 'packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=ab-packages update\n' >"$record_file"
out="$(AB_PACKAGES_FILE="$record_file" APK_UPGRADE_OUT="$tmp/upgraded" sh -c '
  . "$1"
  ab_net_probe() { return 1; }
  shift
  ab_packages_follow "$1"
  printf "rc=%s follow=%s reason=%s\n" "$?" "${AB_PACKAGES_FOLLOW_STATE}" "${AB_PACKAGES_FOLLOW_REASON}"
' _ "$lib" "$target" 2>/dev/null)"
assert_contains "$out" "rc=1" "ac-4 a probe that reports no network blocks the attempt"
assert_contains "$out" "follow=pending reason=network" \
  "ac-4 and the follow stays pending with the network reason"
assert_eq "$(grep -c '' "$tmp/apk.calls")" "0" \
  "ac-4 and no apk transaction is attempted at all"

# =========================================================================== #
# ac-5: the due flag
# =========================================================================== #

# due <record-line> [slot]: the read-only question a boot hook asks, as an exit status.
due() {
  : >"$record_file"
  if [ -n "${1:-}" ]; then printf '%s\n' "$1" >"$record_file"; fi
  AB_PACKAGES_FILE="$record_file" sh -c '. "$1"; ab_packages_follow_due "$2"' _ "$lib" "${2:-}" 2>/dev/null
  echo $?
}
assert_eq "$(due 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=pending hint=ab-packages update' b)" "0" \
  "ac-5 follow=pending for this slot is due"
assert_eq "$(due 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=pending hint=ab-packages update' a)" "1" \
  "ac-5 a record for another slot is not due"
for state in followed failed abandoned never; do
  assert_eq "$(due "packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b follow=${state} hint=ab-packages update" b)" "1" \
    "ac-5 follow=${state} is an answer a boot worker must not overrule"
done
# A record written before the field existed (an upgrade by the previous platform version) has
# never been followed, so it is due exactly once.
assert_eq "$(due 'packages=aligned reason=none version=25.12.2 kernel=kernel=6.12.103~x slot=b' b)" "0" \
  "ac-5 a record with no follow= field has never been followed"
assert_eq "$(due 'packages=unknown reason=no-record slot=b' b)" "1" \
  "ac-5 a record with no verdict is not a base to follow"
assert_eq "$(due '' b)" "1" "ac-5 no record at all is not a base to follow"

# The worker entry point: nothing due means nothing runs.
printf 'packages=followed reason=none follow=followed upgraded=2 kept=2 version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=none\n' >"$record_file"
reset_calls
out="$(run ab_packages_follow_if_ready "$target" b)"
assert_contains "$out" "rc=0" "ac-5 a base that already followed is left alone"
assert_eq "$(grep -c '' "$tmp/apk.calls")" "0" "ac-5 and no apk runs for it"

printf 'packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~x slot=b hint=ab-packages update\n' >"$record_file"
reset_calls
out="$(APK_UPGRADE_OUT="$tmp/upgraded" run ab_packages_follow_if_ready "$target" b)"
assert_contains "$out" "rc=0" "ac-5 a due base is followed by the worker entry point"
assert_contains "$(record)" "follow=followed" "ac-5 and the record is published from the output"

finish
