#!/usr/bin/env bash
# Module: ab
# Verifies the runtime file that decides which slot GRUB boots. It is written at build
# time (scripts/ci/grub-render.sh), at runtime (ab-slot, ab-boot) and on the boot
# failure path (the initramfs fail-safe abandon) by one shared implementation,
# platform/lib/ab-slot-cfg.sh. Getting it wrong does not fail loudly on the device:
# GRUB sources whatever is there, so the menu would keep booting the committed slot and
# an update would never be tried.
#   ac-1 the file is a fallback line followed by a default line, and the menu sources it
#        after the entries so a broken file cannot cost a machine its boot
#   ac-2 the build-time and the runtime writer produce the same bytes, in that order
#   ac-3 the file is replaced atomically, and a write cut short is harmless: both lines
#        stay on the committed slot or the pair is complete
#   ac-4 verification rejects a missing, empty, one-line, swapped, foreign or
#        wrong-fallback file
#   ac-5 the entry indices match the menu order the renderer asserts
#   ac-6 the fail-safe abandon clears pending and points the menu at the committed slot,
#        and leaves a readable state alone when it cannot read it
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"
# The boot initramfs parser is the reference for reading ab/state.json; the fail-safe
# path must agree with it, so both are loaded here.
source "$root/initramfs/lib/wf.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-slot-cfg.sh"
render="$root/scripts/ci/grub-render.sh"
ab_slot="$root/platform/usr/sbin/ab-slot"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=platform/lib/ab-slot-cfg.sh
. "$lib"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --------------------------------------------------------------------------- #
# ac-1: the build-time file
# --------------------------------------------------------------------------- #

built="$tmp/build"
mkdir -p "$built"
CI_TMP_ROOT="$tmp/ci" CI_LOG_DIR="$tmp/ci/logs" \
  CI_GRUB_OUTPUT="$built/grub.cfg" CI_GRUB_TEMPLATE="$root/scripts/ci/grub.cfg.in" \
  CI_COMMITTED_SLOT=a bash "$render" >"$tmp/render.log" 2>&1
assert_eq "$?" "0" "ac-1 the renderer produces the file"

cfg="$built/ab-slot.cfg"
assert_file_exists "$cfg" "ac-1 the file exists next to the menu"
assert_eq "$(cat "$cfg")" "$(printf 'set fallback=0\nset default=0')" \
  "ac-1 the file is the fallback line, then the default line"
assert_eq "$(sed -n '1p' "$cfg")" "set fallback=0" "ac-1 the fallback comes first"
assert_eq "$(sed -n '2p' "$cfg")" "set default=0" "ac-1 the default comes second"
ab_slot_cfg_verify "$cfg"
assert_eq "$?" "0" "ac-1 the shared verifier accepts it"
assert_eq "$(ab_slot_cfg_get "$cfg")" "a" "ac-1 the file points the menu at the committed slot"
assert_eq "$(ab_slot_cfg_fallback "$cfg")" "a" "ac-1 the fallback is the committed slot too"

menu=$(cat "$built/grub.cfg")
assert_contains "$menu" "source /boot/grub/ab-slot.cfg" "ac-1 the menu sources the file"
assert_contains "$menu" "if [ -f /boot/grub/ab-slot.cfg ]; then" \
  "ac-1 the source is guarded by a file test"
assert_contains "$menu" "$(printf 'set default=0\nset fallback=0')" \
  "ac-1 the static menu keeps both entries on the committed slot"

# The override has to come after the last menuentry: GRUB stops reading the file at
# the first error, so a broken override must not be able to remove the menu.
last_entry=$(printf '%s\n' "$menu" | grep -nE '^menuentry ' | tail -n 1 | cut -d: -f1)
source_line=$(printf '%s\n' "$menu" | grep -nE '^[[:space:]]*source ' | head -n 1 | cut -d: -f1)
assert_eq "$([ "$source_line" -gt "$last_entry" ] && echo after)" "after" \
  "ac-1 the file is sourced after every menuentry is defined"

# --------------------------------------------------------------------------- #
# ac-2: one implementation, three callers
# --------------------------------------------------------------------------- #

esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$esp/boot/grub"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
: >"$esp/vmlinuz-b"
: >"$esp/initrd-b"
printf 'console=ttyS0 ab.slot=a\n' >"$tmp/cmdline"
printf '/dev/vda4 /mnt/p4 btrfs rw 0 0\n' >"$tmp/mounts"

slot_cmd() {
  AB_ESP="$esp" AB_P4="$tmp/p4" AB_CMD="$tmp/cmdline" AB_MOUNTS="$tmp/mounts" \
    AB_SLOT_CFG_LIB="$lib" sh "$ab_slot" "$@"
}

ab_slot_cfg_write "$tmp/runtime/ab-slot.cfg" a a
assert_eq "$?" "0" "ac-2 the runtime writer succeeds"
assert_eq "$(sha256_of "$tmp/runtime/ab-slot.cfg")" "$(sha256_of "$cfg")" \
  "ac-2 the runtime file is byte identical to the build-time file"

# A pending slot: the fallback stays on the committed slot, the default moves.
slot_cmd pending b >/dev/null 2>&1
ab_slot_cfg_write "$tmp/b.cfg" a b
assert_eq "$(sha256_of "$esp/boot/grub/ab-slot.cfg")" "$(sha256_of "$tmp/b.cfg")" \
  "ac-2 ab-slot writes the same bytes as the shared writer"
assert_eq "$(cat "$esp/boot/grub/ab-slot.cfg")" "$(printf 'set fallback=0\nset default=1')" \
  "ac-2 a pending slot moves the default and leaves the fallback committed"
assert_eq "$(ab_slot_cfg_check_pair "$esp/boot/grub/ab-slot.cfg" a)" "b a" \
  "ac-2 the pair names the candidate and the committed fallback"

# --------------------------------------------------------------------------- #
# ac-3: atomic replacement, and what a power cut leaves behind
# --------------------------------------------------------------------------- #

assert_eq "$(find "$esp/boot/grub" "$tmp/runtime" -name 'ab-slot.cfg.tmp.*' | wc -l | tr -d ' ')" "0" \
  "ac-3 no temporary file is left behind"
ab_slot_cfg_write "$tmp/runtime/ab-slot.cfg" b a
assert_eq "$(ab_slot_cfg_get "$tmp/runtime/ab-slot.cfg")" "a" "ac-3 an existing file is replaced"
assert_eq "$(grep -c . "$tmp/runtime/ab-slot.cfg" | tr -d ' ')" "2" \
  "ac-3 the replacement keeps exactly two lines"

# A file holding only the first line is what a write cut short produces. That line is
# the fallback, so the menu keeps the committed default from grub.cfg and the fallback
# stays where it was: the machine boots the committed slot.
truncated="$tmp/truncated.cfg"
sed -n '1p' "$tmp/b.cfg" >"$truncated"
assert_eq "$(cat "$truncated")" "set fallback=0" "ac-3 a truncated write leaves the fallback"
assert_eq "$(ab_slot_cfg_fallback "$truncated")" "a" \
  "ac-3 the truncated line names the committed slot"
ab_slot_cfg_get "$truncated"
assert_eq "$?" "1" "ac-3 a truncated file names no default, so the static one stands"
ab_slot_cfg_verify "$truncated"
assert_eq "$?" "1" "ac-3 a truncated file is not accepted as complete"
assert_eq "$AB_SLOT_CFG_REASON" "lines-1" "ac-3 the reason names the missing line"

# --------------------------------------------------------------------------- #
# ac-4: the verifier refuses everything else
# --------------------------------------------------------------------------- #

missing="$tmp/does-not-exist"
ab_slot_cfg_verify "$missing"
assert_eq "$?" "1" "ac-4 a missing file is refused"
assert_eq "$AB_SLOT_CFG_REASON" "missing" "ac-4 the reason names the absence"

empty="$tmp/empty.cfg"
: >"$empty"
ab_slot_cfg_verify "$empty"
assert_eq "$?" "1" "ac-4 an empty file is refused"
assert_eq "$AB_SLOT_CFG_REASON" "empty" "ac-4 the reason names the empty file"

swapped="$tmp/swapped.cfg"
printf 'set default=1\nset fallback=0\n' >"$swapped"
ab_slot_cfg_verify "$swapped"
assert_eq "$?" "1" "ac-4 a file with the lines swapped is refused"
assert_eq "$AB_SLOT_CFG_REASON" "fallback-not-first" \
  "ac-4 the reason names the write-order contract"

no_default="$tmp/no-default.cfg"
printf 'set fallback=0\nset timeout=0\n' >"$no_default"
ab_slot_cfg_verify "$no_default"
assert_eq "$?" "1" "ac-4 a file without a default command is refused"
assert_eq "$AB_SLOT_CFG_REASON" "default-not-second" "ac-4 the reason names the second line"

notaslot="$tmp/not-a-slot.cfg"
printf 'set fallback=0\nset default=7\n' >"$notaslot"
ab_slot_cfg_verify "$notaslot"
assert_eq "$?" "1" "ac-4 an index that is not a slot is refused"
assert_eq "$AB_SLOT_CFG_REASON" "default-not-a-slot-7" "ac-4 the reason names the index"

extra="$tmp/extra.cfg"
printf 'set fallback=0\nset default=1\nset timeout=0\n' >"$extra"
ab_slot_cfg_verify "$extra"
assert_eq "$?" "1" "ac-4 a file with a third command is refused"
assert_eq "$AB_SLOT_CFG_REASON" "lines-3" "ac-4 the reason names the extra line"

comment="$tmp/comment.cfg"
printf '# generated\nset fallback=0\nset default=1\n' >"$comment"
ab_slot_cfg_verify "$comment"
assert_eq "$?" "1" "ac-4 a commented file is refused, because something else wrote it"

# The pair check is where the fallback contract lives: whatever the default says, the
# fallback has to be the committed slot.
wrong_fallback="$tmp/wrong-fallback.cfg"
printf 'set fallback=1\nset default=0\n' >"$wrong_fallback"
ab_slot_cfg_check_pair "$wrong_fallback" a
assert_eq "$?" "1" "ac-4 a fallback that is not the committed slot is refused"
assert_eq "$AB_SLOT_CFG_REASON" "fallback-is-b-not-committed-a" \
  "ac-4 the reason names both slots"
# Idle state: both lines name the committed slot, which is correct, not a contradiction.
printf 'set fallback=0\nset default=0\n' >"$tmp/idle.cfg"
ab_slot_cfg_check_pair "$tmp/idle.cfg" a
assert_eq "$?" "0" "ac-4 an idle pair on the committed slot is accepted"

ab_slot_cfg_write "$tmp/bad-slot.cfg" c a
assert_eq "$?" "1" "ac-4 the writer refuses a fallback that is not a slot"
assert_eq "$AB_SLOT_CFG_REASON" "not-a-slot-c" "ac-4 the writer says which name it refused"
ab_slot_cfg_write "$tmp/bad-slot.cfg" a c
assert_eq "$?" "1" "ac-4 the writer refuses a default that is not a slot"

# --------------------------------------------------------------------------- #
# ac-5: the indices match the menu order
# --------------------------------------------------------------------------- #

assert_eq "$(ab_slot_cfg_index a)" "0" "ac-5 slot a is menu entry 0"
assert_eq "$(ab_slot_cfg_index b)" "1" "ac-5 slot b is menu entry 1"
assert_eq "$(ab_slot_cfg_slot 0)" "a" "ac-5 entry 0 is slot a"
assert_eq "$(ab_slot_cfg_slot 1)" "b" "ac-5 entry 1 is slot b"
assert_eq "$(ab_slot_cfg_other a)" "b" "ac-5 the other slot of a is b"
assert_eq "$(ab_slot_cfg_other b)" "a" "ac-5 the other slot of b is a"
assert_eq "$(printf '%s\n' "$menu" | grep -oE -- '--id [A-Za-z0-9_-]+' | sed 's/--id //' | head -n 2 | tr '\n' ',')" \
  "n5105-a,n5105-b," "ac-5 the menu defines slot a first, then slot b"

# --------------------------------------------------------------------------- #
# ac-6: the fail-safe abandon the boot initramfs runs before it powers off
# --------------------------------------------------------------------------- #

fail_esp="$tmp/fail-esp"
mkdir -p "$fail_esp/ab" "$fail_esp/boot/grub"
fail_state="$fail_esp/ab/state.json"
cat >"$fail_state" <<'JSON'
{
  "generation": 4,
  "committed": "a",
  "pending": "b",
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
ab_slot_cfg_write "$fail_esp/boot/grub/ab-slot.cfg" a b

slot="$(ab_slot_cfg_write_committed "$fail_esp")"
assert_eq "$?" "0" "ac-6 the fail-safe abandon succeeds"
assert_eq "$slot" "a" "ac-6 it reports the slot it moved to"
assert_contains "$(cat "$fail_state")" '"pending": null' \
  "ac-6 the pending marker is cleared"
assert_contains "$(cat "$fail_state")" '"committed": "a"' \
  "ac-6 the committed slot is untouched"
assert_contains "$(cat "$fail_state")" '"upper": "@overlay-25.12.2"' \
  "ac-6 the slot records survive the text patch"
assert_contains "$(cat "$fail_state")" '"generation": 4' \
  "ac-6 the generation survives the text patch"
assert_eq "$(cat "$fail_esp/boot/grub/ab-slot.cfg")" "$(printf 'set fallback=0\nset default=0')" \
  "ac-6 the menu is pointed back at the committed slot"
ab_slot_cfg_check_pair "$fail_esp/boot/grub/ab-slot.cfg" a
assert_eq "$?" "0" "ac-6 the resulting pair is consistent"
assert_eq "$(find "$fail_esp" -name '*.tmp.*' | wc -l | tr -d ' ')" "0" \
  "ac-6 the abandon leaves no temporary file behind"

# Idempotent: a second run on an already cleaned state still rewrites the same pair.
slot="$(ab_slot_cfg_write_committed "$fail_esp")"
assert_eq "$slot" "a" "ac-6 the abandon is idempotent"
assert_eq "$(ab_slot_cfg_get "$fail_esp/boot/grub/ab-slot.cfg")" "a" \
  "ac-6 the second run keeps the committed slot"

# An unreadable state file must not make the failure path write a wrong pair.
broken_esp="$tmp/broken-esp"
mkdir -p "$broken_esp/ab" "$broken_esp/boot/grub"
printf 'not json\n' >"$broken_esp/ab/state.json"
ab_slot_cfg_write_committed "$broken_esp" >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 an unreadable state file is reported, not guessed"
assert_eq "$AB_SLOT_CFG_REASON" "state-unreadable" "ac-6 the reason names the state file"
assert_eq "$([ -f "$broken_esp/boot/grub/ab-slot.cfg" ] && echo present || echo absent)" "absent" \
  "ac-6 nothing is written when the state cannot be read"

missing_state="$tmp/no-state"
mkdir -p "$missing_state/ab" "$missing_state/boot/grub"
ab_slot_cfg_write_committed "$missing_state" >/dev/null 2>&1
assert_eq "$?" "1" "ac-6 a missing state file is reported too"

# The two readers of ab/state.json must agree: the initramfs parses it with its own
# helper on the success path, this library parses it on the failure path, and a drift
# between them would be a failure path that abandons the wrong slot.
for fixture in compact pretty; do
  case "${fixture}" in
    compact) printf '{"generation":2,"committed":"b","pending":null,"slots":{"a":{"rootfs":"1","upper":"@overlay-1"},"b":{"rootfs":"2","upper":"@overlay-2"}}}' >"$tmp/${fixture}.json" ;;
    pretty) printf '{\n  "generation": 2,\n  "committed": "b",\n  "pending": "a",\n  "slots": {\n    "a": { "rootfs": "1", "upper": "@overlay-1" },\n    "b": { "rootfs": "2", "upper": "@overlay-2" }\n  }\n}\n' >"$tmp/${fixture}.json" ;;
  esac
  assert_eq "$(ab_slot_state_committed "$tmp/${fixture}.json")" "$(wf_committed "$tmp/${fixture}.json")" \
    "ac-6 the committed slot reads the same as the initramfs parser (${fixture})"
done
assert_eq "$(ab_slot_state_pending "$tmp/compact.json")" "none" \
  "ac-6 no pending marker reads as none"
assert_eq "$(ab_slot_state_pending "$tmp/pretty.json")" "a" \
  "ac-6 a pending marker reads as its slot"

# --------------------------------------------------------------------------- #
# ac-7: the boot initramfs calls this library, by these names
#
# The fail-safe abandon is a cross-unit interface: the initramfs owns the failure path,
# this library owns the write. The names and the order are asserted here so a rename on
# either side fails a test instead of leaving a machine that retries a broken slot.
# --------------------------------------------------------------------------- #

wf_sh=$(cat "$root/initramfs/lib/wf.sh")
assert_contains "$wf_sh" "ab_slot_cfg_write_committed" \
  "ac-7 the initramfs calls this library's fail-safe writer"
assert_contains "$wf_sh" "ab_slot_state_pending" \
  "ac-7 the initramfs asks this library whether anything is pending"
pending_line=$(printf '%s\n' "$wf_sh" | grep -n 'ab_slot_state_pending' | head -n 1 | cut -d: -f1)
# The invocation, not the `command -v` guard above it.
write_line=$(printf '%s\n' "$wf_sh" | grep -n 'ab_slot_cfg_write_committed "' | head -n 1 | cut -d: -f1)
assert_eq "$([ "${pending_line}" -lt "${write_line}" ] && echo checked)" "checked" \
  "ac-7 nothing is written unless a slot is pending"
abandon_line=$(printf '%s\n' "$wf_sh" | grep -n 'wf_failsafe_abandon || :' | head -n 1 | cut -d: -f1)
judge_line=$(printf '%s\n' "$wf_sh" | grep -n "S3-RESULT=fail" | head -n 1 | cut -d: -f1)
assert_eq "$([ "${abandon_line}" -lt "${judge_line}" ] && echo ordered)" "ordered" \
  "ac-7 the abandon runs before the judge line that stops the harness"

# The builder ships this file into the initramfs, byte for byte.
assert_contains "$(cat "$root/scripts/ci/initramfs.sh")" "platform/lib/ab-slot-cfg.sh" \
  "ac-7 the initramfs builder installs this library"

finish
