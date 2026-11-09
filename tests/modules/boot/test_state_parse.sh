#!/usr/bin/env bash
# Module: boot
# Verifies the state parser the boot initramfs depends on. The parser is the only
# place that interprets ab/state.json, and a wrong reading there would silently boot
# the wrong layer, so every shape gets a case:
#   ac-1 compact and pretty printed state files read identically
#   ac-2 the layer name is taken from the committed slot, not from the first entry
#   ac-3 missing, null or corrupt values fail instead of falling back to a default
#   ac-4 layer names carry the @overlay- prefix; generation stays a separate integer
#   ac-5 the boot init treats an unreadable state as a failure
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
source "$root/initramfs/lib/wf.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

compact="$tmp/compact.json"
pretty="$tmp/pretty.json"
reordered="$tmp/reordered.json"
partial="$tmp/partial.json"
corrupt="$tmp/corrupt.json"
nulled="$tmp/nulled.json"
numeric="$tmp/numeric.json"

cat >"$compact" <<'JSON'
{"generation":2,"committed":"b","pending":null,"slots":{"a":{"rootfs":"25.12.3","upper":"@overlay-25.12.3"},"b":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}
JSON
cat >"$pretty" <<'JSON'
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
# A re-release of the same upstream version carries the -r<N> suffix.
cat >"$reordered" <<'JSON'
{
  "generation": 4,
  "committed": "a",
  "pending": { "slot": "b", "upper": "@overlay-25.12.2-r2" },
  "slots": {
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2-r2" },
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" }
  }
}
JSON
cat >"$partial" <<'JSON'
{"generation":2,"committed":"b","pending":null,"slots":{"a":{"rootfs":"25.12.3"},"b":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}
JSON
printf 'not json at all\n' >"$corrupt"
cat >"$nulled" <<'JSON'
{"generation":2,"committed":null,"pending":null,"slots":{"a":{"rootfs":"25.12.2","upper":"@overlay-25.12.2"}}}
JSON
# The retired schema used a number; a stale file must not be mounted.
cat >"$numeric" <<'JSON'
{"generation":2,"committed":"a","pending":null,"slots":{"a":{"rootfs":"25.12.2","upper":3}}}
JSON

# ac-1 the same state, two formats
assert_eq "$(wf_committed "$compact")" "b" "ac-1 compact state: committed slot"
assert_eq "$(wf_committed "$pretty")" "b" "ac-1 pretty state: committed slot"
assert_eq "$(wf_upper "$compact" b)" "@overlay-25.12.2" "ac-1 compact state: layer name"
assert_eq "$(wf_upper "$pretty" b)" "@overlay-25.12.2" "ac-1 pretty state: layer name"
assert_eq "$(wf_generation "$compact")" "2" "ac-1 compact state: generation"
assert_eq "$(wf_generation "$pretty")" "2" "ac-1 pretty state: generation"

# ac-2 the layer comes from the committed slot, and slot order does not matter
assert_eq "$(wf_upper "$pretty" a)" "@overlay-25.12.3" "ac-2 layer of the other slot"
assert_eq "$(wf_committed "$reordered")" "a" "ac-2 reordered slots: committed slot"
assert_eq "$(wf_upper "$reordered" a)" "@overlay-25.12.3" "ac-2 reordered slots: committed layer"
assert_eq "$(wf_upper "$reordered" b)" "@overlay-25.12.2-r2" "ac-2 reordered slots: re-release name"

# a pending update must not be mistaken for the committed slot
assert_contains "$(cat "$reordered")" '"pending"' "ac-2 state carries a pending entry"
assert_eq "$(wf_committed "$reordered")" "a" "ac-2 pending is ignored for the committed slot"
assert_eq "$(wf_upper "$reordered" a)" "@overlay-25.12.3" \
  "ac-2 the pending layer name does not leak into the committed slot"

# ac-3 failures stay failures
missing_upper=$(wf_upper "$partial" a)
assert_eq "$?" "1" "ac-3 a slot without a layer name fails"
assert_eq "$missing_upper" "" "ac-3 a slot without a layer name yields no value"
corrupt_slot=$(wf_committed "$corrupt")
assert_eq "$corrupt_slot" "" "ac-3 a corrupt state file yields no slot"
null_slot=$(wf_committed "$nulled")
assert_eq "$null_slot" "" "ac-3 a null committed field yields no slot"
numeric_upper=$(wf_upper "$numeric" a)
assert_eq "$?" "1" "ac-3 a numeric upper from the retired schema is rejected"
assert_eq "$numeric_upper" "" "ac-3 a numeric upper yields no layer name"
no_generation=$(wf_generation "$corrupt")
assert_eq "$no_generation" "" "ac-3 a corrupt state file yields no generation"

# ac-4 the name is the version, the number is separate
assert_eq "$(wf_upper "$pretty" b)" "@overlay-25.12.2" "ac-4 the layer name is the upstream version"
case "$(wf_upper "$pretty" b)" in
    @overlay-*) : ;;
    *) assert_eq "prefix" "@overlay-" "ac-4 the layer name carries the @overlay- prefix" ;;
esac
assert_eq "$(wf_generation "$reordered")" "4" "ac-4 the generation is an independent integer"
assert_matches "$(wf_generation "$reordered")" '^[0-9]+$' "ac-4 the generation stays numeric"

# ac-5 the boot init must fail on unreadable state instead of booting a default slot
boot_init="$(cat "$root/initramfs/boot/init")"
assert_contains "$boot_init" "wf_fail state-missing" \
  "ac-5 missing state file is a failure"
assert_contains "$boot_init" "state-committed-invalid" \
  "ac-5 an unreadable committed slot is a failure"
assert_contains "$boot_init" "wf_upper" \
  "ac-5 the init reads the layer name from the state file"
assert_eq "$(printf '%s' "$boot_init" | grep -c 'upper_gen')" "0" \
  "ac-5 the retired field is gone from the boot path"

# the mount order contract: the writable layer is mounted first, then the read-only
# layers, and each command carries the documented options
assert_contains "$boot_init" "compress=zstd:6,discard=async" \
  "ac-5 the writable layer is mounted with compression"
assert_contains "$boot_init" "lowerdir=/mnt/@platform:/mnt/@sys" \
  "ac-5 the overlay lower layers are ordered platform then sys"
assert_contains "$boot_init" "index=off" "ac-5 the overlay is mounted with index=off"
assert_contains "$boot_init" "switch_root" "ac-5 the init switches into the composed root"

# the judge line is frozen
assert_contains "$boot_init" "lower=<platform:sys>" \
  "ac-5 the judge line reports platform:sys as the lower layers"
assert_contains "$(cat "$root/initramfs/boot/post.sh")" \
  'S3-RESULT=ok slot=%s upper=%s lower=platform:sys root=overlay' \
  "ac-5 the judge line shape is unchanged"

finish
