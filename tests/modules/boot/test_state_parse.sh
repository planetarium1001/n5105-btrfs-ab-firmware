#!/usr/bin/env bash
# Module: boot
# Verifies the state parser the boot initramfs depends on. The parser is the only
# place that interprets ab/state.json, and a wrong reading there would silently boot
# the wrong generation, so every shape gets a case:
#   ac-1 compact and pretty printed state files read identically
#   ac-2 the generation is taken from the committed slot, not from the first entry
#   ac-3 missing, null or corrupt values fail instead of falling back to a default
#   ac-4 generation numbers map onto the documented @overlay.genNNNN names
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

cat >"$compact" <<'JSON'
{"generation":2,"committed":"b","pending":null,"slots":{"a":{"rootfs":"25.12.3","upper_gen":3},"b":{"rootfs":"25.12.2","upper_gen":2}}}
JSON
cat >"$pretty" <<'JSON'
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper_gen": 3 },
    "b": { "rootfs": "25.12.2", "upper_gen": 2 }
  }
}
JSON
cat >"$reordered" <<'JSON'
{
  "generation": 4,
  "committed": "a",
  "pending": { "slot": "b", "upper_gen": 5 },
  "slots": {
    "b": { "rootfs": "25.12.2", "upper_gen": 2 },
    "a": { "rootfs": "25.12.3", "upper_gen": 3 }
  }
}
JSON
cat >"$partial" <<'JSON'
{"generation":2,"committed":"b","pending":null,"slots":{"a":{"rootfs":"25.12.3"},"b":{"rootfs":"25.12.2","upper_gen":2}}}
JSON
printf 'not json at all\n' >"$corrupt"
cat >"$nulled" <<'JSON'
{"generation":2,"committed":null,"pending":null,"slots":{"a":{"rootfs":"25.12.2","upper_gen":1}}}
JSON

# ac-1 the same state, two formats
assert_eq "$(wf_committed "$compact")" "b" "ac-1 compact state: committed slot"
assert_eq "$(wf_committed "$pretty")" "b" "ac-1 pretty state: committed slot"
assert_eq "$(wf_upper_gen "$compact" b)" "2" "ac-1 compact state: generation"
assert_eq "$(wf_upper_gen "$pretty" b)" "2" "ac-1 pretty state: generation"

# ac-2 the generation comes from the committed slot, and slot order does not matter
assert_eq "$(wf_upper_gen "$pretty" a)" "3" "ac-2 generation of the other slot"
assert_eq "$(wf_committed "$reordered")" "a" "ac-2 reordered slots: committed slot"
assert_eq "$(wf_upper_gen "$reordered" a)" "3" "ac-2 reordered slots: committed generation"
assert_eq "$(wf_upper_gen "$reordered" b)" "2" "ac-2 reordered slots: other generation"

# a pending update must not be mistaken for the committed slot
assert_contains "$(cat "$reordered")" '"pending"' "ac-2 state carries a pending entry"
assert_eq "$(wf_committed "$reordered")" "a" "ac-2 pending is ignored for the committed slot"

# ac-3 failures stay failures
missing_gen=$(wf_upper_gen "$partial" a)
assert_eq "$?" "1" "ac-3 a slot without upper_gen fails"
assert_eq "$missing_gen" "" "ac-3 a slot without upper_gen yields no value"
corrupt_slot=$(wf_committed "$corrupt")
assert_eq "$corrupt_slot" "" "ac-3 a corrupt state file yields no slot"
null_slot=$(wf_committed "$nulled")
assert_eq "$null_slot" "" "ac-3 a null committed field yields no slot"

# ac-4 generation names
assert_eq "$(wf_gen_name 1)" "@overlay.gen0001" "ac-4 first generation name"
assert_eq "$(wf_gen_name 42)" "@overlay.gen0042" "ac-4 padded generation name"
assert_eq "$(wf_gen_name 1234)" "@overlay.gen1234" "ac-4 four digit generation name"

# ac-5 the boot init must fail on unreadable state instead of booting a default slot
boot_init="$(cat "$root/initramfs/boot/init")"
assert_contains "$boot_init" "wf_fail state-missing" \
  "ac-5 missing state file is a failure"
assert_contains "$boot_init" "state-committed-invalid" \
  "ac-5 an unreadable committed slot is a failure"
assert_contains "$boot_init" "state-upper-gen-invalid" \
  "ac-5 an unreadable generation is a failure"

# the mount order contract: the writable layer is mounted first, then the read-only
# layers, and each command carries the documented options
assert_contains "$boot_init" "compress=zstd:6,discard=async" \
  "ac-5 the writable layer is mounted with compression"
assert_contains "$boot_init" "lowerdir=/mnt/@wf:/mnt/@sys" \
  "ac-5 the overlay lower layers are ordered wf then sys"
assert_contains "$boot_init" "index=off" "ac-5 the overlay is mounted with index=off"
assert_contains "$boot_init" "switch_root" "ac-5 the init switches into the composed root"

finish
