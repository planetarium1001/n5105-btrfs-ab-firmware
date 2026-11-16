#!/usr/bin/env bash
# Module: upgrade
# Package snapshots and package-level rollback.
#
# A snapshot is text on the writable layer, next to the world it describes:
#
#   <layer>/apk/snapshots/snapshot-<id>.txt      the manifest
#   <layer>/apk/snapshots/snapshot-<id>.d/       the payloads fetched for it
#       payloads/<name>-<version>.apk
#
# The stub apk below answers the way apk-tools 3.0.5 does on the measured machine
# (device 192.168.2.49, 2026-11-14): bare `apk info` prints names only, `apk info -v`
# prints name-version, `apk list --installed` prints name-version followed by the arch and
# the repository, `apk fetch -o DIR` lands <name>-<version>.apk, `apk add name=version`
# pins a package into the world, and a local .apk needs --allow-untrusted. Nothing here
# runs apk for real: the test asserts what the library asked it for.
#
#   ac-1  every installed package is parsed with its version, from `apk info -v`
#         (falling back to the first field of `apk list --installed`), the split is "the
#         last dash followed by a digit", and a line that cannot be split fails the
#         snapshot with `apk-info-unparsed` instead of being dropped
#   ac-2  the snapshot header counts packages/world/payloads and `packages list` agrees
#   ac-3  a revert replays the pinned versions (one apk transaction when the payloads are
#         there), reports changed= and reconciles world=/matched=
#   ac-4  payloads land in snapshot-<id>.d/payloads with a sha256 per package,
#         --no-payloads turns them off, a failed fetch is a recorded gap, and a digest
#         that does not match installs nothing at all
#   ac-7  listing shows the snapshots newest first and says when there are none
#   ac-8  snapshots live on the writable layer only; no slot state is touched
#   (20261116-06) ac-4 the one-line summary of a snapshot reports a count it could not read
#         as `unreadable`, never as a zero the file does not support
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
# shellcheck source=platform/lib/upgrade/packages.sh
. "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a stub apk: the library may ask, never install (unless the test says so) ----
bin="$tmp/bin"
mkdir -p "$bin"

# The installed set the measured machine reports: names that carry dashes and versions
# that carry a dash of their own are the two shapes that broke the old split.
pkglist="$tmp/installed.txt"
cat >"$pkglist" <<'LIST'
kmod-8139cp-6.12.103-r1
libnghttp2-14-1.64.0-r0
libiptext6-0.1-r0
kmod-nls-iso8859-1-6.12.103-r1
htop-3.3.0-r1
kernel-6.12.103-r1
nano-8.2-r1
LIST

export APK_INFO_LIST="$pkglist"
export APK_CALLS="$tmp/apk-calls.log"
: >"$APK_CALLS"

cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
case "${1:-}" in
  --version) printf 'apk-tools 3.0.5\n' ;;
  info)
    if [ "${2:-}" = "-v" ]; then
      [ "${APK_INFO_FAIL:-0}" = "1" ] && exit 1
      cat "${APK_INFO_LIST:-/dev/null}"
    else
      # apk-tools 3 prints the names only, with no version at all.
      sed 's/-[0-9][^-]*\(-r[0-9][^-]*\)\{0,1\}$//' "${APK_INFO_LIST:-/dev/null}"
    fi
    ;;
  list)
    [ "${APK_LIST_FAIL:-0}" = "1" ] && exit 1
    sed 's/$/ x86_64 https:\/\/example.invalid\/base (MIT) [installed]/' "${APK_INFO_LIST:-/dev/null}"
    ;;
  fetch)
    [ "${APK_FETCH_FAIL:-0}" = "1" ] && exit 1
    shift
    dir=""
    pins=""
    recursive=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o) dir="$2"; shift 2 ;;
        --recursive) recursive=1; shift ;;
        *) pins="$pins $1"; shift ;;
      esac
    done
    [ -n "$dir" ] || exit 1
    mkdir -p "$dir" || exit 1
    for pin in $pins; do
      case "$pin" in
        *=*) name=${pin%%=*}; ver=${pin#*=} ;;
        *)
          # Per-package fetch names the package only (apk-tools 3.0.5 rejects version
          # pins); the version the file carries is whatever the feed resolves.
          name=$pin
          ver=$(sed -n "s/^${name}-\([0-9].*\)$/\1/p" "${APK_INFO_LIST:-/dev/null}" | head -n 1)
  ;;
      esac
      # A package the feed no longer resolves: the per-package fetch fails for it, while
      # the recursive one-shot is still allowed to land the set.
      [ "$recursive" = "0" ] && [ "${APK_FETCH_PKG_FAIL:-}" = "$name" ] && exit 1
      # apk exits 0 but the file never lands: the digest check must call that a partial
      # set, not a success.
      [ "${APK_FETCH_OMIT:-}" = "$name" ] && continue
      if [ "$recursive" = "0" ] && [ "${APK_FETCH_DRIFT:-}" = "$name" ]; then
        # The feed has rolled since the machine was installed: apk hands back a newer
        # version than the installed set names, which the record must not accept.
        printf 'APK %s drifted\n' "$name" >"$dir/$name-9.9.9-r9.apk" || exit 1
        continue
      fi
      printf 'APK %s %s\n' "$name" "$ver" >"$dir/$name-$ver.apk" || exit 1
    done
    ;;
  add)
    [ "${APK_ADD_FAIL_ALL:-0}" = "1" ] && exit 1
    case "$*" in
      *--allow-untrusted*) exit "${APK_ADD_FAIL:-0}" ;;
    esac
    for arg in "$@"; do
      case "$arg" in
        nano=*) [ "${APK_FAIL_NANO:-1}" = "0" ] && continue; exit 1 ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"
export PATH="$bin:$PATH"

# --- ac-1: the parse ---------------------------------------------------------
expected_parse="kmod-8139cp 6.12.103-r1
libnghttp2-14 1.64.0-r0
libiptext6 0.1-r0
kmod-nls-iso8859-1 6.12.103-r1
htop 3.3.0-r1
kernel 6.12.103-r1
nano 8.2-r1"

parsed="$(_packages_installed)"
assert_eq "$parsed" "$expected_parse" "ac-1 every installed package is split into name and version"
assert_eq "$(grep -c '^info -v$' "$APK_CALLS")" "1" "ac-1 the source is apk info -v"
assert_eq "$(grep -c '^info$' "$APK_CALLS")" "0" \
  "ac-1 bare apk info is never read (it prints names only)"

# The documented fallback: `apk list --installed`, first field.
: >"$APK_CALLS"
parsed_fallback="$(APK_INFO_FAIL=1 _packages_installed)"
assert_eq "$parsed_fallback" "$expected_parse" \
  "ac-1 apk list --installed is the fallback and its first field is name-version"
assert_eq "$(grep -c '^list --installed$' "$APK_CALLS")" "1" \
  "ac-1 the fallback is asked for the installed set"

# A line that cannot be split is a failure, not something to drop: dropping lines was how
# a 317-package machine produced a snapshot with almost nothing in it.
badlist="$tmp/unparsable.txt"
printf 'htop-3.3.0-r1\nweirdname\nnano-8.2-r1\ntrailing-\n' >"$badlist"
bad_layer="$tmp/overlay-unparsable"
mkdir -p "$bad_layer/upper/etc/apk"
printf 'kernel\n' >"$bad_layer/upper/etc/apk/world"
out="$(APK_INFO_LIST="$badlist" ab_packages_snapshot "$bad_layer" 25.12.2 0.0.8 2>&1)"
rc=$?
assert_eq "$rc" "1" "ac-1 a line that cannot be split fails the snapshot"
assert_contains "$out" "apk-info-unparsed" "ac-1 the failure names the unparsable package list"
assert_contains "$out" "2 of 4" "ac-1 the failure counts the unparsable lines against the input"
assert_contains "$out" "weirdname" "ac-1 the first unparsable line is shown"
assert_contains "$out" "trailing-" "ac-1 every unparsable line is shown (up to three)"
assert_eq "$(ls "$bad_layer/apk/snapshots" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-1 no half snapshot is left behind"

# --- ac-2 / ac-4: the snapshot, its counts and its payloads ------------------
layer="$tmp/overlay-25.12.2"
mkdir -p "$layer/upper/etc/apk"
printf 'kernel\nhtop\nnano\nzlib\n' >"$layer/upper/etc/apk/world"

# The call log starts clean here: the assertions below are about what this snapshot asked
# apk for, not about the parse checks above.
: >"$APK_CALLS"
snap=$(ab_packages_snapshot "$layer" 25.12.2 0.0.8) || snap=""
assert_file_exists "$snap" "ac-1 a snapshot file is written"
contents="$(cat "$snap" 2>/dev/null)"
assert_contains "$contents" "AB-APK-SNAPSHOT 1" "ac-1 the snapshot declares its format"
assert_contains "$contents" "upstream 25.12.2" "ac-1 the snapshot names the base it belongs to"
assert_contains "$contents" "platform 0.0.8" "ac-1 the snapshot names the platform version"
assert_contains "$contents" "world    htop" "ac-1 every world entry is recorded"
assert_contains "$contents" "pkg      htop 3.3.0-r1" "ac-1 every installed package is recorded with its version"
assert_contains "$contents" "pkg      kmod-nls-iso8859-1 6.12.103-r1" \
  "ac-1 a package whose name ends in a dashed number keeps it in the name"
assert_contains "$contents" "pkg      libnghttp2-14 1.64.0-r0" \
  "ac-1 a package whose name ends in a number keeps it in the name"
assert_contains "$contents" "end" "ac-1 the snapshot is terminated"

# The counts live in the header as `packages <N>` / `world <M>`; the entries themselves
# keep their `pkg      ` and `world    ` columns, which is what tells a count line and an
# entry apart and what a reader written before the counts existed already matches.
assert_eq "$(sed -n 's/^packages //p' "$snap")" "7" "ac-2 the header counts the packages"
assert_eq "$(sed -n 's/^world \([0-9][0-9]*\)$/\1/p' "$snap")" "4" \
  "ac-2 the header counts the world entries"
assert_eq "$(sed -n 's/^payloads //p' "$snap")" "yes" "ac-4 the payloads are fetched by default"
assert_eq "$(grep -c '^pkg ' "$snap")" "7" "ac-2 there is one pkg line per package"
assert_eq "$(grep -c '^world    ' "$snap")" "4" "ac-2 there is one world line per entry"
assert_eq "$(sed -n 's/^world \([0-9][0-9]*\)$/\1/p' "$snap")" "$(grep -c '^world    ' "$snap")" \
  "ac-2 the world count equals the number of world entries"

# The three new header lines sit where the format says: after `platform`, before the
# entries, counts first and the payload verdict last.
l_platform=$(grep -n '^platform ' "$snap" | cut -d: -f1)
l_packages=$(grep -n '^packages ' "$snap" | cut -d: -f1)
l_world=$(grep -n '^world ' "$snap" | head -n 1 | cut -d: -f1)
l_payloads=$(grep -n '^payloads ' "$snap" | cut -d: -f1)
assert_eq "$([ "$l_platform" -lt "$l_packages" ] && [ "$l_packages" -lt "$l_world" ] \
  && [ "$l_world" -lt "$l_payloads" ] && printf ordered)" "ordered" \
  "ac-2 packages/world/payloads sit after platform and before the entries"

sid=${snap##*/snapshot-}
sid=${sid%.txt}
pdir="$layer/apk/snapshots/snapshot-$sid.d/payloads"
assert_eq "$([ -d "$pdir" ] && printf present || printf absent)" "present" \
  "ac-4 the payloads land in snapshot-<id>.d/payloads"
assert_file_exists "$pdir/htop-3.3.0-r1.apk" "ac-4 every pinned package has a file"
want_sha=$(shasum -a 256 "$pdir/htop-3.3.0-r1.apk" | cut -d' ' -f1)
assert_contains "$contents" "apkfile  htop $want_sha" \
  "ac-4 the sha256 of each payload is recorded next to its name"
assert_eq "$(grep -c '^apkfile ' "$snap")" "7" "ac-4 there is one apkfile line per package"
assert_eq "$(grep -c '^end$' "$snap")" "1" "ac-4 the apkfile lines come before the end marker"
assert_eq "$(awk '/^apkfile /{ last = NR } /^end$/{ print (last < NR) ? "before" : "after"; exit }' "$snap")" \
  "before" "ac-4 the apkfile lines are inside the record"

# The default route fetches one installed package per call and never passes --recursive:
# `apk fetch --recursive` makes apk solve the pinned set against /etc/apk/world, and on a
# freshly flashed machine that world is older than the feed, so the solve fails on
# world[libopenssl3=...] and the whole snapshot loses its payloads. The installed set is
# already the dependency closure, so no solver is needed.
assert_eq "$(grep -c '^fetch -o ' "$APK_CALLS")" "7" \
  "ac-4 every installed package is fetched on its own"
assert_eq "$(grep -c -- '--recursive' "$APK_CALLS")" "0" \
  "ac-4 the default route never asks apk to solve the world"
assert_eq "$(awk '$1 == "fetch" && $2 == "-o" && NF != 4 { bad = 1 } END { print bad ? "mixed" : "single" }' "$APK_CALLS")" \
  "single" "ac-4 each per-package fetch carries exactly one pinned package"
assert_eq "$(find "$pdir" -maxdepth 1 -name '*.apk' | wc -l | tr -d ' ')" "7" \
  "ac-4 the per-package route lands exactly the installed set"

# --no-payloads: the manifest is the main deliverable, the payloads are optional.
: >"$APK_CALLS"
snap_np=$(ab_packages_snapshot "$layer" 25.12.2 0.0.8 --no-payloads) || snap_np=""
assert_file_exists "$snap_np" "ac-4 --no-payloads still writes the manifest"
assert_eq "$(sed -n 's/^payloads //p' "$snap_np")" "no" "ac-4 --no-payloads records no payloads"
sid_np=${snap_np##*/snapshot-}
sid_np=${sid_np%.txt}
assert_eq "$([ -d "$layer/apk/snapshots/snapshot-$sid_np.d" ] && printf present || printf absent)" \
  "absent" "ac-4 --no-payloads leaves no payload directory"
assert_eq "$(grep -c '^fetch' "$APK_CALLS")" "0" "ac-4 --no-payloads does not ask apk for anything"

# A fetch that fails is a gap in the record, not a broken snapshot: the feed can be
# unreachable while the machine still needs a list of what it has.
: >"$APK_CALLS"
snap_gap=$(APK_FETCH_FAIL=1 ab_packages_snapshot "$layer" 25.12.2 0.0.8 2>/dev/null) || snap_gap=""
assert_file_exists "$snap_gap" "ac-4 a failed fetch still leaves the manifest"
assert_eq "$(sed -n 's/^payloads //p' "$snap_gap")" "no" "ac-4 a failed fetch is recorded as no payloads"
assert_eq "$(sed -n 's/^payload-gap //p' "$snap_gap")" "apk-fetch-failed" \
  "ac-4 the gap names why the payloads are missing"
assert_eq "$(grep -c '^fetch -o ' "$APK_CALLS")" "1" \
  "ac-4 a dead feed stops the per-package pass at its first failure"
assert_eq "$(grep -c '^fetch --recursive' "$APK_CALLS")" "1" \
  "ac-4 when per-package fetch fails the recursive route is still tried"
sid_gap=${snap_gap##*/snapshot-}
sid_gap=${sid_gap%.txt}
assert_eq "$([ -d "$layer/apk/snapshots/snapshot-$sid_gap.d" ] && printf present || printf absent)" \
  "absent" "ac-4 a failed fetch leaves no half-populated payload directory"

# A package the feed cannot answer by its pinned name falls back to the recursive
# one-shot instead of giving up on the payloads: this is the machine where the old route
# still works, and the record must not lose the files it could have.
: >"$APK_CALLS"
snap_fb=$(APK_FETCH_PKG_FAIL=htop ab_packages_snapshot "$layer" 25.12.2 0.0.8 2>"$tmp/fb.err") || snap_fb=""
assert_file_exists "$snap_fb" "ac-4 a per-package failure still writes the manifest"
assert_contains "$(cat "$tmp/fb.err")" "fell back to --recursive" \
  "ac-4 the fallback is logged instead of silently switching routes"
assert_eq "$(sed -n 's/^payloads //p' "$snap_fb")" "yes" \
  "ac-4 the recursive fallback recovers the complete payload set"
assert_eq "$(grep -c '^apkfile ' "$snap_fb")" "7" \
  "ac-4 the recovered set records one digest per package"
assert_eq "$(sed -n 's/^payload-gap //p' "$snap_fb")" "" \
  "ac-4 a recovered set is not recorded as a gap"
assert_eq "$(grep -c '^fetch -o ' "$APK_CALLS")" "5" \
  "ac-4 the per-package pass ran until the package the feed cannot answer"
assert_eq "$(grep -c '^fetch --recursive' "$APK_CALLS")" "1" \
  "ac-4 a partial per-package set falls back to the recursive fetch once"
sid_fb=${snap_fb##*/snapshot-}
sid_fb=${sid_fb%.txt}
assert_eq "$([ -d "$layer/apk/snapshots/snapshot-$sid_fb.d/payloads" ] && printf present || printf absent)" \
  "present" "ac-4 the fallback keeps the payload directory it completed"

# A feed that has rolled since the machine was installed hands back a newer file than the
# installed set names. apk-tools 3.0.5 rejects version pins in `apk fetch`, so the
# per-package pass can only ask by name and must reject the drifted result: the file is
# dropped, the recursive fallback may still land the right one, and no stray archive is
# left for a later revert to install.
: >"$APK_CALLS"
snap_drift=$(APK_FETCH_DRIFT=nano ab_packages_snapshot "$layer" 25.12.2 0.0.8 2>"$tmp/drift.err") || snap_drift=""
assert_file_exists "$snap_drift" "ac-4 a drifted feed still writes the manifest"
assert_eq "$(sed -n 's/^payloads //p' "$snap_drift")" "yes" \
  "ac-4 the recursive fallback recovers a set the per-package pass dropped"
assert_contains "$(cat "$tmp/drift.err")" "fell back to --recursive" \
  "ac-4 the drift fallback is logged"
assert_eq "$(grep -c '^fetch -o ' "$APK_CALLS")" "7" \
  "ac-4 a drifted package does not short-circuit the rest of the per-package pass"
sid_dr=${snap_drift##*/snapshot-}
sid_dr=${sid_dr%.txt}
assert_eq "$([ -e "$layer/apk/snapshots/snapshot-$sid_dr.d/payloads/nano-9.9.9-r9.apk" ] && echo present || echo absent)" \
  "absent" "ac-4 the drifted archive is not left in the payload directory"
assert_eq "$(grep -c '^apkfile ' "$snap_drift")" "7" \
  "ac-4 every package still has a digest after the fallback"

# When both routes answer but a file never lands, the set is incomplete and is named as
# such: a list-only snapshot plus the stable reason, never a payload directory that a later
# revert would refuse. The reason stays in the documented vocabulary.
: >"$APK_CALLS"
snap_inc=$(APK_FETCH_OMIT=nano ab_packages_snapshot "$layer" 25.12.2 0.0.8 2>/dev/null) || snap_inc=""
assert_file_exists "$snap_inc" "ac-4 an incomplete set still writes the manifest"
assert_eq "$(sed -n 's/^payloads //p' "$snap_inc")" "no" \
  "ac-4 a set that does not cover every package is list-only"
assert_eq "$(sed -n 's/^payload-gap //p' "$snap_inc")" "payload-incomplete" \
  "ac-4 the gap keeps the stable reason for a short set"
assert_eq "$(grep -c '^apkfile ' "$snap_inc")" "0" \
  "ac-4 no digest lines are written for a set that is not complete"
assert_eq "$(grep -c '^fetch --recursive' "$APK_CALLS")" "1" \
  "ac-4 the short set tried the recursive fallback too"
sid_inc=${snap_inc##*/snapshot-}
sid_inc=${sid_inc%.txt}
assert_eq "$([ -d "$layer/apk/snapshots/snapshot-$sid_inc.d" ] && printf present || printf absent)" \
  "absent" "ac-4 the short set leaves no payload directory behind"

# --- ac-1: retention keeps the newest three, payloads included --------------
for _ in 1 2 3; do
  sleep 1
  ab_packages_snapshot "$layer" 25.12.2 0.0.8 >/dev/null 2>&1 || true
done
count=$(ab_packages_list "$layer" | grep -c '^snapshot ' || true)
assert_eq "$count" "3" "ac-1 three snapshots are kept, not four"
assert_eq "$(find "$layer/apk/snapshots" -maxdepth 1 -name 'snapshot-*.d' | wc -l | tr -d ' ')" "3" \
  "ac-4 the payload directory is reaped with its manifest"

# --- ac-7: listing ----------------------------------------------------------
listed="$(ab_packages_list "$layer")"
assert_contains "$listed" "base 25.12.2" "ac-7 each line names the base"
assert_contains "$listed" "platform 0.0.8" "ac-7 each line names the platform version"
assert_contains "$listed" "7 packages" "ac-7 each line counts the packages"
first_line=$(printf '%s\n' "$listed" | head -n 1)
assert_contains "$first_line" "3 snapshots kept" "ac-7 the list states how many are retained"
# Newest first: the ids are UTC timestamps, so the first line has the largest id.
ids=$(printf '%s\n' "$listed" | sed -n 's/^snapshot \([0-9TZ-]*\) .*/\1/p')
assert_eq "$(printf '%s\n' "$ids" | sort -r | head -n 1)" "$(printf '%s\n' "$ids" | head -n 1)" \
  "ac-7 the listing is newest first"

empty_layer="$tmp/overlay-empty"
mkdir -p "$empty_layer/upper/etc/apk"
printf 'kernel\n' >"$empty_layer/upper/etc/apk/world"
assert_contains "$(ab_packages_list "$empty_layer" 2>&1)" "no snapshots" \
  "ac-7 a layer without snapshots says so instead of printing nothing"

# --- ac-8: nothing outside the layer is touched ----------------------------
# The decoy file proves nothing; the CLI only ever writes ${AB_ESP}/ab/state.json and the
# GRUB slot file, so those are what is compared, before and after every subcommand.
real_state="$tmp/esp/ab/state.json"
[ -f "$real_state" ] || mkdir -p "$tmp/esp/ab"
printf '{"generation":1,"committed":"a"}\n' >"$real_state"
slot_cfg="$tmp/esp/boot/grub/ab-slot.cfg"
mkdir -p "$(dirname "$slot_cfg")"
printf 'set default="0"\n' >"$slot_cfg"
before_state="$(shasum -a 256 "$real_state" | cut -d' ' -f1)"
before_cfg="$(shasum -a 256 "$slot_cfg" | cut -d' ' -f1)"
ab_packages_snapshot "$layer" 25.12.2 0.0.8 >/dev/null 2>&1 || true
assert_eq "$(shasum -a 256 "$real_state" | cut -d' ' -f1)" "$before_state" \
  "ac-8 a snapshot does not write the slot state"
assert_eq "$(shasum -a 256 "$slot_cfg" | cut -d' ' -f1)" "$before_cfg" \
  "ac-8 a snapshot does not touch the GRUB slot file"
assert_eq "$(ls "$layer" | sort | tr '\n' ' ')" "apk upper " "ac-8 only the apk directory and the upper exist on the layer"

# The ids the newest-first assertion relies on must exist, or the assertion would pass on
# two empty strings.
assert_eq "$(printf '%s\n' "$ids" | grep -c .)" "3" "ac-7 the ids were actually parsed"

# --- ab-slot packages: the CLI ---------------------------------------------
# A whole machine in a temporary directory: one committed slot, a writable layer with a
# world file, the packages record the last upgrade published, and a stub apk.
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/ab"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2-b" }
  }
}
JSON
printf 'packages=aligned reason=none slot=a\n' >"$esp/ab/packages"
cmdline="$tmp/cmdline"
printf 'ab.slot=a\n' >"$cmdline"
release="$tmp/platform-release"
printf 'PLATFORM_VERSION=0.0.8\nUPSTREAM_VERSION=25.12.2\n' >"$release"
p4="$tmp/p4"
mkdir -p "$p4/@overlay-25.12.2/upper/etc/apk"
printf 'kernel\nhtop\nzlib\n' >"$p4/@overlay-25.12.2/upper/etc/apk/world"

slot_run() {
  AB_ESP="$esp" AB_P4="$p4" AB_CMD="$cmdline" AB_PLATFORM_RELEASE="$release" \
    AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" AB_BTRFS=true \
    PATH="$bin:$PATH" sh "$root/platform/usr/sbin/ab-slot" "$@" 2>&1
}

: >"$APK_CALLS"
out="$(slot_run packages snapshot)"
snap_id=$(printf '%s\n' "$out" | sed -n 's/^snapshot \([^ ]*\) written.*/\1/p')
assert_eq "$([ -n "$snap_id" ] && printf named || printf missing)" "named" \
  "ac-1 the CLI writes a snapshot and names it"
assert_contains "$out" "packages=7" "ac-2 the CLI reports the package count"
assert_contains "$out" "world=3" "ac-2 the CLI reports the world count"
assert_contains "$out" "payloads=yes" "ac-4 the CLI reports whether the payloads are there"
assert_contains "$out" "base=25.12.2" "ac-1 the CLI names the base"

out="$(slot_run packages list)"
assert_contains "$out" "snapshots kept" "ac-7 the CLI lists snapshots"
assert_contains "$out" "7 packages" "ac-2 the listing counts the packages"

# The listing is the other reader of the same counts, and it folded the same two answers
# into one: a path it cannot read and a record written before the counts existed both
# printed `0`. It has to say `unreadable` there, exactly like the one-line summary.
list_layer="$tmp/overlay-list"
mkdir -p "$list_layer/apk/snapshots"
printf 'AB-APK-SNAPSHOT 1\nupstream 25.12.2\nplatform 0.0.8\npackages 0\nworld 0\npayloads no\nend\n' \
  >"$list_layer/apk/snapshots/snapshot-20260101T000000Z.txt"
# A path under the snapshots directory whose contents cannot be read as a snapshot.
mkdir -p "$list_layer/apk/snapshots/snapshot-20260101T000001Z.txt"
# A record written before the header carried the counts: the packages can be counted, the
# world cannot.
printf 'AB-APK-SNAPSHOT 1\nupstream 25.12.2\nplatform 0.0.8\npkg      htop 3.3.0-r1\nend\n' \
  >"$list_layer/apk/snapshots/snapshot-20260101T000002Z.txt"
out="$(ab_packages_list "$list_layer")"
assert_eq "$(printf '%s\n' "$out" | grep -c '0 packages  world 0')" "1" \
  "ac-4 the listing still counts a genuinely empty snapshot as 0"
assert_eq "$(printf '%s\n' "$out" | grep -c 'unreadable packages  world unreadable')" "1" \
  "ac-4 a snapshot the listing cannot read is unreadable, not empty"
assert_eq "$(printf '%s\n' "$out" | grep -c '1 packages  world unreadable')" "1" \
  "ac-4 a record without the world count is counted where it can be and unreadable where it cannot"

# ac-2: the numbers the record carries and the numbers a reader counts are the same.
cli_snap="$p4/@overlay-25.12.2/apk/snapshots/snapshot-$snap_id.txt"
assert_eq "$(sed -n 's/^packages //p' "$cli_snap")" "$(grep -c '^pkg ' "$cli_snap")" \
  "ac-2 the packages header equals the pkg lines"
assert_eq "$(sed -n 's/^world \([0-9][0-9]*\)$/\1/p' "$cli_snap")" "$(grep -c '^world    ' "$cli_snap")" \
  "ac-2 the world header equals the world lines"

out="$(slot_run packages upgrade)"
rc=$?
assert_eq "$rc" "0" "ac-3 an aligned layer upgrades"
assert_contains "$out" "packages-upgrade result=ok" "ac-3 the result line is printed"
assert_contains "$(cat "$APK_CALLS")" "update" "ac-3 apk update runs first"
assert_contains "$(cat "$APK_CALLS")" "upgrade" "ac-3 apk upgrade follows"
assert_contains "$(cat "$esp/ab/log/upgrade.log")" "packages-upgrade result=ok" "ac-3 the result is logged"

rm -f "$esp/ab/packages"
out="$(slot_run packages upgrade)"
rc=$?
assert_eq "$rc" "74" "ac-2 an unaligned layer is refused"
assert_contains "$out" "reason=packages-not-aligned" "ac-2 the refusal names the gate"
printf 'packages=aligned reason=none slot=a\n' >"$esp/ab/packages"

# --- ac-3 / ac-4: revert with the payloads ---------------------------------
# The payloads were fetched by the snapshot above, so the replay is one apk transaction
# over local files: the source no longer carries the pinned versions, which is exactly the
# case this exists for.
: >"$APK_CALLS"
out="$(slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "0" "ac-3 a revert from the payloads succeeds"
assert_contains "$out" "revert result=ok changed=7 path=payloads" \
  "ac-3 the summary counts what was replayed and how"
assert_eq "$(grep -c '^add ' "$APK_CALLS")" "1" \
  "ac-3 the payloads are one apk transaction, not one per package"
add_line="$(grep '^add ' "$APK_CALLS")"
assert_contains "$add_line" "--allow-untrusted" \
  "ac-4 a local .apk is installed with --allow-untrusted (the trust chain is our sha256 list)"
assert_contains "$add_line" ".apk" "ac-3 the transaction installs the fetched files"
assert_contains "$out" "revert world=3 matched=2" \
  "ac-3 the revert reconciles the world against the package set"
assert_contains "$out" "world-unmatched  zlib" \
  "ac-3 a world entry with no package in the snapshot is named"
assert_contains "$out" "apkfile verified 7" "ac-4 every payload's digest is verified before installing"
# The install set is the verified set. A fetch (in particular the recursive fallback) can
# drop dependency archives into the directory, and a glob would install the ones the
# snapshot never listed and nothing ever checked.
extra="$p4/@overlay-25.12.2/apk/snapshots/snapshot-$snap_id.d/payloads/extra-not-listed-9.9-r9.apk"
printf 'NOT IN THE SNAPSHOT\n' >"$extra"
: >"$APK_CALLS"
out="$(slot_run packages revert --to "$snap_id")"
assert_eq "$(grep -c 'extra-not-listed' "$APK_CALLS")" "0" \
  "ac-4 a file the snapshot does not list is never installed"
assert_eq "$(grep -c '^add ' "$APK_CALLS")" "1" \
  "ac-4 the transaction still runs once over the verified files"
rm -f "$extra"

# A transaction that fails is a failed transaction. It is not "N packages failed" and it is
# not "0 changed": apk makes no promise about a commit that broke halfway.
: >"$APK_CALLS"
out="$(APK_ADD_FAIL=1 slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "1" "ac-4 a failed payload transaction exits 1"
assert_contains "$out" "revert result=fail changed=unknown failed=transaction" \
  "ac-4 a failed transaction is reported as one, not as per-package failures"
assert_eq "$(printf '%s' "$out" | grep -c 'changed=0')" "0" \
  "ac-4 a broken transaction does not claim that nothing changed"

# A payload that does not match its recorded digest means the record cannot be trusted:
# nothing is installed at all.
corrupt="$p4/@overlay-25.12.2/apk/snapshots/snapshot-$snap_id.d/payloads/htop-3.3.0-r1.apk"
printf 'tampered\n' >"$corrupt"
: >"$APK_CALLS"
out="$(slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "74" "ac-4 a payload whose digest does not match is refused"
assert_contains "$out" "reason=revert-payload-mismatch" "ac-4 the refusal names the mismatch"
assert_contains "$out" "revert result=fail" "ac-4 the accounting says the revert did not happen"
assert_eq "$(grep -c '^add ' "$APK_CALLS")" "0" \
  "ac-4 not one package is installed from a set that does not verify"

# Payloads gone (deleted, or a snapshot taken with --no-payloads) falls back to the
# network replay, which reports per package and still reconciles the world.
rm -rf "$p4/@overlay-25.12.2/apk/snapshots/snapshot-$snap_id.d"
: >"$APK_CALLS"
out="$(APK_FAIL_NANO=0 slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "0" "ac-3 a revert without payloads still succeeds when the feed has the versions"
assert_contains "$out" "revert result=ok changed=7 path=network" \
  "ac-3 the network replay reports its own path"
assert_contains "$out" "revert world=3 matched=2" "ac-3 the network replay reconciles the world too"
assert_eq "$(grep -c '^add ' "$APK_CALLS")" "7" \
  "ac-3 without payloads every pinned version is asked for on its own"

# The network path keeps the per-package report: one package that is gone from the feed
# does not hide the six that came back.
: >"$APK_CALLS"
out="$(slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "0" "ac-3 a partial revert is not a failure exit"
assert_contains "$out" "ok      htop 3.3.0-r1" "ac-3 each successful package is named"
assert_contains "$out" "failed  nano 8.2-r1" "ac-3 each failed package is named"
assert_contains "$out" "revert result=partial" "ac-3 the summary says partial"

# A revert where every package is still in the feed is a success, not a partial one.
out="$(APK_FAIL_NANO=0 slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "0" "ac-4 a complete revert exits 0"
assert_contains "$out" "revert result=ok" "ac-4 the summary says ok"

# --no-payloads on the CLI: the snapshot is written, the payload directory is not.
snap_out="$(slot_run packages snapshot --no-payloads)"
snap_np_id=$(printf '%s\n' "$snap_out" | sed -n 's/^snapshot \([^ ]*\) written.*/\1/p')
assert_contains "$snap_out" "payloads=no" "ac-4 the CLI writes a manifest without payloads"
assert_eq "$([ -d "$p4/@overlay-25.12.2/apk/snapshots/snapshot-$snap_np_id.d" ] && printf present || printf absent)" \
  "absent" "ac-4 the CLI leaves no payload directory for --no-payloads"

# --- ac-5 / ac-6: the base is a hard boundary ------------------------------
# A snapshot from another base must not be replayable: those versions were built for a
# different kernel and libc.
python3 - "$cli_snap" 26.0.0 <<'PYEDIT'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"^upstream .*$", "upstream " + sys.argv[2], path.read_text(), flags=re.M))
PYEDIT
out="$(slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "74" "ac-5 a snapshot from another base is refused"
assert_contains "$out" "reason=revert-across-base" "ac-5 the refusal names the base"

python3 - "$cli_snap" 25.12.2 <<'PYEDIT'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"^upstream .*$", "upstream " + sys.argv[2], path.read_text(), flags=re.M))
PYEDIT

# --- the failure paths the reviewer found unguarded ------------------------

# An apk that cannot list what is installed must not produce a "0 packages" snapshot:
# every later revert would then be a silent no-op.
broken="$tmp/brokenbin"
mkdir -p "$broken"
cat >"$broken/apk" <<'APK'
#!/bin/sh
case "${1:-}" in
  info) exit 1 ;;
  list) exit 1 ;;
  *) exit 0 ;;
esac
APK
chmod +x "$broken/apk"
broken_layer="$tmp/overlay-broken"
mkdir -p "$broken_layer/upper/etc/apk"
printf 'kernel\n' >"$broken_layer/upper/etc/apk/world"
out="$(PATH="$broken:$PATH" ab_packages_snapshot "$broken_layer" 25.12.2 0.0.8 2>&1)"
rc=$?
assert_eq "$rc" "1" "a snapshot refuses to record a package list it could not read"
assert_eq "$(ls "$broken_layer/apk/snapshots" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "no snapshot file is left behind when apk cannot list the packages"
assert_contains "$out" "apk-info" "the refusal names the apk failure"

# A machine without apk cannot revert, and says which reason it is.
noapk="$tmp/noapkbin"
mkdir -p "$noapk"
for tool in sh sed awk grep cut sort tail head wc cat ls rm mv mkdir date basename dirname printf find; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$noapk/$tool" 2>/dev/null
done
out="$(AB_ESP="$esp" AB_P4="$p4" AB_CMD="$cmdline" AB_PLATFORM_RELEASE="$release" \
  AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" AB_BTRFS=true \
  PATH="$noapk" sh "$root/platform/usr/sbin/ab-slot" packages revert 2>&1)"
rc=$?
assert_eq "$rc" "74" "a revert without apk is refused"
assert_contains "$out" "reason=apk-unsupported" "the refusal names the missing apk"

# When every package fails, the verdict is a failure, not a partial success.
out="$(APK_ADD_FAIL_ALL=1 slot_run packages revert --to "$snap_id")"
rc=$?
assert_eq "$rc" "1" "a revert where nothing could be restored fails"
assert_contains "$out" "revert result=fail" "the verdict says fail, not partial"

# The CLI carries the gap into its one-line report: an operator sees that the manifest is
# list-only, and why, without opening the file.
: >"$APK_CALLS"
out="$(APK_FETCH_FAIL=1 slot_run packages snapshot)"
rc=$?
assert_eq "$rc" "0" "ac-4 a failed payload fetch is not a failed snapshot"
assert_contains "$out" "payloads=no" \
  "ac-4 the CLI reports the list-only snapshot"
assert_contains "$out" "payload_gap=apk-fetch-failed" \
  "ac-4 the CLI reports the stable reason the payloads are missing"
assert_contains "$out" "packages=7" "ac-4 the list-only snapshot still counts the packages"

# Files written in the same second are ordered by their -N suffix, which is the later
# write; plain sort would put them first and reap the newer one.
order_layer="$tmp/overlay-order"
mkdir -p "$order_layer/upper/etc/apk" "$order_layer/apk/snapshots"
printf 'kernel\n' >"$order_layer/upper/etc/apk/world"
for name in snapshot-20260101T000000Z.txt snapshot-20260101T000000Z-2.txt snapshot-20260101T000001Z.txt; do
  printf 'AB-APK-SNAPSHOT 1\nupstream 25.12.2\nplatform 0.0.8\nend\n' >"$order_layer/apk/snapshots/$name"
done
ordered="$(_packages_snapshot_files "$order_layer" | tr '\n' ' ')"
assert_eq "$ordered" "snapshot-20260101T000000Z.txt snapshot-20260101T000000Z-2.txt snapshot-20260101T000001Z.txt " \
  "the -N suffix of a same-second snapshot sorts after the bare name"

# --- (20261116-06) ac-4: a snapshot the line could not read is never "0 packages" ---
# `packages snapshot` summarises the file the library has just written with one grep-able
# line. The counts were read with `${_np:-0}`, so "could not read it" and "nothing in it"
# printed the same thing: an empty snapshot, a half-written one and an unreadable one were
# indistinguishable to every reader, and a later revert would trust a number nothing
# counted. `0` has to be earned by reading the file; a count that is not there is
# `unreadable`. The files below are fixtures handed over through the library's documented
# interface (write the snapshot, print its path), because the line has to describe whatever
# the library hands it, not only what a healthy apk produces.
d1_dir="$tmp/ac-4-snapshots"
mkdir -p "$d1_dir"
d1_lib="$tmp/ac-4-packages-lib.sh"
cat >"$d1_lib" <<'STUB'
ab_packages_snapshot() {
  printf '%s\n' "${STUB_SNAPSHOT}"
}
_packages_snapshot_field() {
  sed -n "s/^$2  *//p" "$1" 2>/dev/null | head -n 1
}
STUB
slot_run_snapshot() { # <snapshot path> [packages snapshot args...]
  _snap_fixture=$1
  shift
  STUB_SNAPSHOT="$_snap_fixture" AB_ESP="$esp" AB_P4="$p4" AB_CMD="$cmdline" \
    AB_PLATFORM_RELEASE="$release" AB_PACKAGES_LIB="$d1_lib" AB_BTRFS=true \
    PATH="$bin:$PATH" sh "$root/platform/usr/sbin/ab-slot" packages snapshot "$@" 2>&1
}

# An empty snapshot is a legitimate answer, and zero is what it means.
d1_empty="$d1_dir/snapshot-20260101T000000Z.txt"
cat >"$d1_empty" <<'SNAP'
AB-APK-SNAPSHOT 1
upstream 25.12.2
platform 0.0.8
packages 0
world 0
payloads no
end
SNAP
out="$(slot_run_snapshot "$d1_empty")"
assert_contains "$out" "packages=0" "ac-4 an empty snapshot still reports 0 packages"
assert_contains "$out" "world=0" "ac-4 an empty snapshot still reports 0 world entries"

# The file the library names cannot be read at all: nothing was counted, so nothing is a
# zero. This is the case the silent zero hid, and it keeps every other field.
out="$(slot_run_snapshot "$d1_dir/snapshot-20260101T000001Z.txt")"
assert_contains "$out" "packages=unreadable" \
  "ac-4 an unreadable snapshot reports packages=unreadable"
assert_contains "$out" "world=unreadable" "ac-4 and its world count is unreadable too"
assert_eq "$(printf '%s\n' "$out" | grep -c 'packages=0')" "0" \
  "ac-4 nothing claims the unreadable snapshot holds no packages"
assert_contains "$out" "snapshot 20260101T000001Z written" \
  "ac-4 the line still names the snapshot it describes"
# The shape is unchanged: one line, the same five fields in the same order, so a reader
# that greps `packages=` keeps working. `base=` is empty here for the same honest reason -
# nothing in an unreadable file was read.
assert_matches "$out" \
  '^snapshot 20260101T000001Z written packages=unreadable world=unreadable payloads=no base=$' \
  "ac-4 the unreadable case keeps the line's fields and their order"

# A directory wearing a snapshot's name is the case that made the readable-file check
# necessary: measured on the device 2026-11-16, busybox `grep -c` prints `0` for a directory
# and exits 1, so a counter that only looked at the output would call a corrupt snapshot an
# empty one. The guard is `[ -f ] && [ -r ]`, and this is what proves it is there.
d1_isdir="$d1_dir/snapshot-20260101T000002Z.txt"
mkdir -p "$d1_isdir"
out="$(slot_run_snapshot "$d1_isdir")"
assert_contains "$out" "packages=unreadable" \
  "ac-4 a directory named like a snapshot is unreadable, not empty"
assert_contains "$out" "world=unreadable" "ac-4 and its world count is unreadable too"
assert_eq "$(printf '%s\n' "$out" | grep -c 'packages=0')" "0" \
  "ac-4 nothing claims a directory-named snapshot holds no packages"
rmdir "$d1_isdir"

# A symlink to nothing is the other shape busybox cannot read; it must not read as empty
# either.
d1_dangling="$d1_dir/snapshot-20260101T000003Z.txt"
ln -s "$d1_dir/no-such-target" "$d1_dangling"
out="$(slot_run_snapshot "$d1_dangling")"
assert_contains "$out" "packages=unreadable" \
  "ac-4 a dangling symlink is unreadable, not empty"
rm -f "$d1_dangling"

# A record written before the counts existed carries pkg lines and no `world N` header. The
# packages can be counted; the world cannot, and a zero there would be invented.
d1_old="$d1_dir/snapshot-20260101T000002Z.txt"
cat >"$d1_old" <<'SNAP'
AB-APK-SNAPSHOT 1
upstream 25.12.2
platform 0.0.8
payloads no
pkg      htop 3.3.0-r1
pkg      zlib 1.3.1-r1
end
SNAP
out="$(slot_run_snapshot "$d1_old")"
assert_contains "$out" "packages=2" \
  "ac-4 a record without a world header still counts its packages"
assert_contains "$out" "world=unreadable" \
  "ac-4 a missing world count is unreadable, not zero"
assert_contains "$out" "base=25.12.2" \
  "ac-4 the fields beside the counts are the ones the file carries"

# An `apk` that does not answer like apk-tools is not a version this code can drive.
cat >"$bin/apk" <<'APK'
#!/bin/sh
case "${1:-}" in
  --version) printf 'busybox-apk 1.0\n' ;;
  info) printf 'htop-3.3.0-r1\n' ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"
out="$(slot_run packages upgrade)"
rc=$?
assert_eq "$rc" "74" "an apk that is not apk-tools is refused"
assert_contains "$out" "reason=apk-unsupported" "the refusal names the unsupported tool"

finish
