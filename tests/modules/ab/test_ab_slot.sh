#!/usr/bin/env bash
# Module: ab
# Verifies the slot state machine in platform/usr/sbin/ab-slot without root and
# without btrfs: the ESP is a temporary directory and btrfs comes from a stub, which
# is enough because every rule that matters here is about the state file.
#   ac-1 status reports the running slot, the committed slot and the pending slot
#   ac-2 commit and abandon change the state atomically and keep the layer names
#   ac-3 pending refuses a slot whose payload is not on the ESP
#   ac-4 rollback swaps the committed slot
#   ac-5 gc keeps every referenced layer and reaps the rest, honouring --dry-run
#   ac-6 the retired upper_gen field is gone and a stale state file is refused
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

ab_slot="$root/platform/usr/sbin/ab-slot"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a fake ESP and a fake kernel command line -----------------------------
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/boot/grub"
write_state() { # <committed> <pending|none> <gen>
  if [ "$2" = "none" ]; then pending=null; else pending="\"$2\""; fi
  cat >"$esp/ab/state.json" <<JSON
{
  "generation": $3,
  "committed": "$1",
  "pending": $pending,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
}
cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

slot_cmd() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$tmp/p4" sh "$ab_slot" "$@"
}

# Payload for both slots, so pending checks pass by default.
: >"$esp/vmlinuz-a"; : >"$esp/initrd-a"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

# --- ac-1 status ------------------------------------------------------------
write_state a none 1
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$status" "slot=a upper=@overlay-25.12.3 generation=1 committed=a pending=none p4=degraded" \
  "ac-1 status line reports the documented fields"

printf 'console=ttyS0 ab.slot=b\n' >"$cmdline"
write_state a a 2
status="$(slot_cmd status 2>/dev/null)"
assert_eq "$status" "slot=b upper=@overlay-25.12.2 generation=2 committed=a pending=a p4=degraded" \
  "ac-1 status follows ab.slot= on the kernel command line"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

# --- ac-2 commit and abandon ------------------------------------------------
write_state a a 2
slot_cmd commit >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-2 commit sets the committed slot"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' "ac-2 commit clears pending"
# Committing the running slot must not erase a marker for the other slot: that marker
# is a staged upgrade waiting for the next boot.
write_state a b 2
slot_cmd commit >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"pending": "b"' \
  "ac-2 commit keeps a pending marker for the other slot"
assert_contains "$(cat "$esp/ab/state.json")" '"upper": "@overlay-25.12.3"' \
  "ac-2 commit keeps the layer names"
assert_contains "$(cat "$esp/ab/state.json")" '"generation": 2' "ac-2 commit keeps the generation"

write_state a b 2
slot_cmd abandon >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' "ac-2 abandon clears pending"
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-2 abandon leaves committed alone"

# no temporary file is left behind
assert_eq "$(find "$esp/ab" -name 'state.json.tmp.*' | wc -l | tr -d ' ')" "0" \
  "ac-2 the atomic write leaves no temporary file"

# --- ac-3 pending validation ------------------------------------------------
write_state a none 1
slot_cmd pending b >/dev/null 2>&1
assert_eq "$?" "0" "ac-3 pending accepts a slot whose payload is present"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": "b"' "ac-3 pending records the slot"

rm -f "$esp/vmlinuz-b" "$esp/initrd-b"
write_state a none 1
slot_cmd pending b >/dev/null 2>&1
assert_eq "$?" "1" "ac-3 pending refuses a slot without payload"
assert_contains "$(cat "$esp/ab/state.json")" '"pending": null' \
  "ac-3 a refused pending leaves the state untouched"

slot_cmd pending c >/dev/null 2>&1
assert_eq "$?" "1" "ac-3 pending refuses an invalid slot name"
: >"$esp/vmlinuz-b"; : >"$esp/initrd-b"

# --- ac-4 rollback ----------------------------------------------------------
write_state a none 1
slot_cmd rollback >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "b"' "ac-4 rollback switches to the other slot"
slot_cmd rollback >/dev/null 2>&1
assert_contains "$(cat "$esp/ab/state.json")" '"committed": "a"' "ac-4 rollback is symmetric"

# --- ac-5 gc ----------------------------------------------------------------
p4="$tmp/p4"
mkdir -p "$p4/@overlay-25.12.2" "$p4/@overlay-25.12.3" "$p4/@overlay-25.12.1" "$p4/@docker"
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/btrfs" <<'STUB'
#!/bin/sh
case "$1" in
  subvolume)
    case "$2" in
      list) printf 'ID 256 gen 10 top level 5 path @overlay-25.12.1\nID 257 gen 10 top level 5 path @overlay-25.12.2\nID 258 gen 10 top level 5 path @overlay-25.12.3\n' ;;
      delete) printf '%s\n' "$4" >>"${GC_LOG:-/dev/null}"; rm -rf "$4" ;;
      sync) : ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$stub_bin/btrfs"

write_state b none 5
export GC_LOG="$tmp/gc-deleted.log"
: >"$GC_LOG"
AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$p4" PATH="$stub_bin:$PATH" sh "$ab_slot" gc --dry-run >/dev/null 2>&1
assert_eq "$?" "0" "ac-5 gc --dry-run succeeds"
assert_eq "$(wc -l <"$GC_LOG" | tr -d ' ')" "0" "ac-5 gc --dry-run deletes nothing"
assert_eq "$([ -d "$p4/@overlay-25.12.1" ] && echo present)" "present" \
  "ac-5 gc --dry-run keeps the unreferenced layer"

AB_ESP="$esp" AB_CMD="$cmdline" AB_P4="$p4" PATH="$stub_bin:$PATH" sh "$ab_slot" gc >/dev/null 2>&1
assert_eq "$?" "0" "ac-5 gc succeeds"
assert_contains "$(cat "$GC_LOG")" "@overlay-25.12.1" "ac-5 gc deletes the unreferenced layer"
assert_eq "$([ -d "$p4/@overlay-25.12.2" ] && echo present)" "present" \
  "ac-5 gc keeps the layer referenced by slot b"
assert_eq "$([ -d "$p4/@overlay-25.12.3" ] && echo present)" "present" \
  "ac-5 gc keeps the layer referenced by slot a"
unset GC_LOG

# --- ac-6 retired schema ----------------------------------------------------
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 2,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper_gen": 1 },
    "b": { "rootfs": "25.12.2", "upper_gen": 1 }
  }
}
JSON
slot_cmd status >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 a state file with the retired upper_gen field is refused"
slot_cmd commit >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 commit refuses to rewrite a state it cannot read"

assert_eq "$(grep -c 'upper_gen' "$ab_slot")" "0" "ac-6 the tool never mentions the retired field"

finish
