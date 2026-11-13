#!/usr/bin/env bash
# Module: upgrade
# Package snapshots: the record that makes a package-level rollback possible.
#
# A snapshot is text on the writable layer, next to the world it describes:
#
#   <layer>/apk/snapshots/snapshot-<UTC>.txt
#
# It records the base and platform versions the machine was on, every world entry, and
# every installed package with its version. Nothing here runs apk for real: the test
# puts a stub on PATH and asserts what the library asked it for.
#
#   ac-1  a snapshot names the release it belongs to and every installed package
#   ac-7  listing shows the snapshots newest first and says when there are none
#   ac-8  snapshots live on the writable layer only; no slot state is touched
#   ac-1  the newest three are kept, older ones are reaped by the snapshot itself
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

# --- a stub apk: the library may ask, never install --------------------------
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/apk" <<'STUB'
#!/bin/sh
case "${1:-}" in
  --version) printf 'apk-tools 3.0.0\n' ;;
  info)
    printf 'htop-3.3.0-r1\n'
    printf 'kernel-6.12.103-r1\n'
    printf 'nano-8.2-r1\n'
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$bin/apk"
export PATH="$bin:$PATH"

layer="$tmp/overlay-25.12.2"
mkdir -p "$layer/upper/etc/apk"
printf 'kernel\nhtop\nnano\n' >"$layer/upper/etc/apk/world"

# --- ac-1: a snapshot records the release and the packages ------------------
snap=$(ab_packages_snapshot "$layer" 25.12.2 0.0.8) || snap=""
assert_file_exists "$snap" "ac-1 a snapshot file is written"
contents="$(cat "$snap" 2>/dev/null)"
assert_contains "$contents" "AB-APK-SNAPSHOT 1" "ac-1 the snapshot declares its format"
assert_contains "$contents" "upstream 25.12.2" "ac-1 the snapshot names the base it belongs to"
assert_contains "$contents" "platform 0.0.8" "ac-1 the snapshot names the platform version"
assert_contains "$contents" "world    htop" "ac-1 every world entry is recorded"
assert_contains "$contents" "pkg      htop 3.3.0-r1" "ac-1 every installed package is recorded with its version"
assert_contains "$contents" "end" "ac-1 the snapshot is terminated"

# --- ac-1: retention keeps the newest three --------------------------------
for _ in 1 2 3; do
  sleep 1
  ab_packages_snapshot "$layer" 25.12.2 0.0.8 >/dev/null 2>&1 || true
done
count=$(ab_packages_list "$layer" | grep -c '^snapshot ' || true)
assert_eq "$count" "3" "ac-1 three snapshots are kept, not four"

# --- ac-7: listing ----------------------------------------------------------
listed="$(ab_packages_list "$layer")"
assert_contains "$listed" "base 25.12.2" "ac-7 each line names the base"
assert_contains "$listed" "platform 0.0.8" "ac-7 each line names the platform version"
assert_contains "$listed" "3 packages" "ac-7 each line counts the packages"
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
state="$tmp/ab-state.json"
printf '{"slot":"a","generation":1}\n' >"$state"
before="$(shasum -a 256 "$state" | cut -d' ' -f1)"
ab_packages_snapshot "$layer" 25.12.2 0.0.8 >/dev/null 2>&1 || true
after="$(shasum -a 256 "$state" | cut -d' ' -f1)"
assert_eq "$after" "$before" "ac-8 a snapshot does not write the slot state"
assert_eq "$(ls "$layer" | sort | tr '\n' ' ')" "apk upper " "ac-8 only the apk directory and the upper exist on the layer"

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
printf 'kernel\nhtop\n' >"$p4/@overlay-25.12.2/upper/etc/apk/world"

# The stub records what it was asked to do and fails only for nano, which is how a
# package that is no longer in the feed behaves.
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"$APK_CALLS"
case "${1:-}" in
  --version) printf 'apk-tools 3.0.0\n' ;;
  info) printf 'htop-3.3.0-r1\nkernel-6.12.103-r1\nnano-8.2-r1\n' ;;
  add)
    case "${2:-}" in
      nano=*) [ "${APK_FAIL_NANO:-1}" = "0" ] && exit 0; exit 1 ;;
    esac
    exit 0
    ;;
  update|upgrade) exit 0 ;;
  *) exit 0 ;;
esac
APK
chmod +x "$bin/apk"
export APK_CALLS="$tmp/apk-calls.log"
: >"$APK_CALLS"

slot_run() {
  AB_ESP="$esp" AB_P4="$p4" AB_CMD="$cmdline" AB_PLATFORM_RELEASE="$release" \
    AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" AB_BTRFS=true \
    PATH="$bin:$PATH" sh "$root/platform/usr/sbin/ab-slot" "$@" 2>&1
}

out="$(slot_run packages snapshot)"
assert_contains "$out" "snapshot " "ac-1 the CLI writes a snapshot"
assert_contains "$out" "base 25.12.2" "ac-1 the CLI names the base"

out="$(slot_run packages list)"
assert_contains "$out" "snapshots kept" "ac-7 the CLI lists snapshots"

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

# --- ac-5 / ac-6: revert ---------------------------------------------------
printf 'packages=aligned reason=none slot=a\n' >"$esp/ab/packages"
# The newest snapshot is the default `--to`, so that is the one to rewrite.
snapfile="$(ls -1 "$p4/@overlay-25.12.2/apk/snapshots"/snapshot-*.txt | sort | tail -n 1)"
# A snapshot from another base must not be replayable: those versions were built for a
# different kernel and libc.
python3 - "$snapfile" 26.0.0 <<'PYEDIT'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"^upstream .*$", "upstream " + sys.argv[2], path.read_text(), flags=re.M))
PYEDIT
out="$(slot_run packages revert)"
rc=$?
assert_eq "$rc" "74" "ac-5 a snapshot from another base is refused"
assert_contains "$out" "reason=revert-across-base" "ac-5 the refusal names the base"

python3 - "$snapfile" 25.12.2 <<'PYEDIT'
import sys, pathlib, re
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"^upstream .*$", "upstream " + sys.argv[2], path.read_text(), flags=re.M))
PYEDIT
out="$(slot_run packages revert)"
rc=$?
assert_eq "$rc" "0" "ac-6 a partial revert is not a failure exit"
assert_contains "$out" "ok      htop 3.3.0-r1" "ac-6 each successful package is named"
assert_contains "$out" "failed  nano 8.2-r1 (not in the feed)" "ac-6 each failed package is named with its reason"
assert_contains "$out" "revert result=partial" "ac-6 the summary says partial"

# A revert where every package is still in the feed is a success, not a partial one.
out="$(APK_FAIL_NANO=0 slot_run packages revert)"
rc=$?
assert_eq "$rc" "0" "ac-4 a complete revert exits 0"
assert_contains "$out" "revert result=ok" "ac-4 the summary says ok"

finish
