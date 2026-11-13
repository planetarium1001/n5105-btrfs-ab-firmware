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

finish
