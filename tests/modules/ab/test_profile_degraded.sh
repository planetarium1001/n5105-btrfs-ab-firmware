#!/usr/bin/env bash
# Module: ab
# ac-5: `platform/etc/profile.d/ab-degraded.sh` says it out loud when this boot is
#       degraded - one line on stderr that contains `degraded` and says writes will not
#       survive - and is completely silent, with exit status 0, on a healthy boot and on
#       one it cannot judge. It writes no file: the fact already exists in the ring log.
# ac-1 (task 20261117-02): the same file must survive being *sourced*, which is how it is
#       actually run: `/etc/profile` dots every `/etc/profile.d/*.sh`, so an `exit` in it
#       ends the login shell instead of the file. `sh -c '. <file>; echo ALIVE'` has to
#       print ALIVE - and a degraded boot has to still announce itself from inside that
#       sourced shell.
# ac-3 (task 20261117-02): run as a program it keeps the old contract - status 0, and
#       nothing at all on a healthy boot. The assertions above are that contract, kept
#       as written; the ones below run the file the other way round, the way it is
#       installed.
#
# Why the old assertions missed it: they ran the file with `sh <file>`, one process, so
# `exit 0` left only that process and every healthy boot looked fine. On the device the
# banner closed SSH right after it and kept the console out of a shell, because there the
# caller was the login shell itself.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

profile="$root/platform/etc/profile.d/ab-degraded.sh"
ab_slot="$root/platform/usr/sbin/ab-slot"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

assert_file_exists "$profile" "ac-5 the login banner is installed in profile.d"

esp="$tmp/esp"
mkdir -p "$esp/ab/log"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
cmdline="$tmp/cmdline"
printf 'console=ttyS0 ab.slot=a\n' >"$cmdline"

run_profile() {
  AB_ESP="$esp" AB_CMD="$cmdline" AB_SLOT_BIN="$ab_slot" sh -e "$profile"
}

# run_sourced: the way `/etc/profile` runs it - a `sh` that dots the file and then has to
# be able to run the next command. `$0` inside that shell is `sh`, exactly as a sourced
# snippet sees a login shell's `-sh`, which is what the file keys its exit/return decision
# on.
run_sourced() { # sets: s_out, s_err, s_rc
  s_out=$(AB_ESP="$esp" AB_CMD="$cmdline" AB_SLOT_BIN="$ab_slot" \
    sh -c '. "$1"; echo ALIVE' sh "$profile" 2>"$tmp/err-sourced")
  s_rc=$?
  s_err="$(cat "$tmp/err-sourced")"
}

degraded_log='stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=fail reason=p4-degraded action=degraded-boot'

# --- a degraded boot is announced once, on stderr ------------------------
printf '%s\n' "$degraded_log" >"$esp/ab/log/boot-0.log"
marker="$tmp/marker"
touch "$marker"
stdout=$(run_profile 2>"$tmp/err-degraded")
rc=$?
err="$(cat "$tmp/err-degraded")"
assert_eq "$rc" "0" "ac-5 the banner never fails a login shell"
assert_eq "$stdout" "" "ac-5 the banner keeps stdout clean"
assert_eq "$(printf '%s\n' "$err" | grep -c 'degraded')" "1" \
  "ac-5 the banner prints exactly one line and it names the degraded boot"
assert_contains "$err" "not survive" "ac-5 the banner says what a degraded boot means for writes"
assert_eq "$(find "$esp" -newer "$marker" 2>/dev/null)" "" \
  "ac-5 the banner writes no file: the ring log is the only record"

run_sourced
assert_eq "$s_rc" "0" "ac-1 a sourced degraded boot leaves the caller with status 0"
assert_eq "$s_out" "ALIVE" \
  "ac-1 a sourced degraded boot does not end the shell that sourced it"
assert_eq "$(printf '%s\n' "$s_err" | grep -c 'degraded')" "1" \
  "ac-1 a sourced degraded boot still announces itself, once, on the caller's stderr"
assert_contains "$s_err" "not survive" "ac-1 and the sourced banner says what it means for writes"

# --- a healthy boot says nothing at all ----------------------------------
printf 'stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok\n' >"$esp/ab/log/boot-0.log"
stdout=$(run_profile 2>"$tmp/err-ok")
rc=$?
assert_eq "$rc" "0" "ac-5 a healthy boot exits 0"
assert_eq "$stdout" "" "ac-5 a healthy boot prints nothing on stdout"
assert_eq "$(cat "$tmp/err-ok")" "" "ac-5 a healthy boot prints nothing on stderr"

run_sourced
assert_eq "$s_rc" "0" "ac-3 a sourced healthy boot leaves the caller with status 0"
assert_eq "$s_out" "ALIVE" \
  "ac-3 a sourced healthy boot does not end the shell that sourced it"
assert_eq "$s_err" "" "ac-3 a sourced healthy boot prints nothing at all"

# --- a boot it cannot judge says nothing either --------------------------
rm -f "$esp/ab/log/boot-0.log"
stdout=$(run_profile 2>"$tmp/err-unknown")
rc=$?
assert_eq "$rc" "0" "ac-5 an unknown boot exits 0"
assert_eq "$(cat "$tmp/err-unknown")" "" \
  "ac-5 an unknown boot is not announced as degraded, and not announced as healthy either"

run_sourced
assert_eq "$s_rc" "0" "ac-1 a sourced unknown boot leaves the caller with status 0"
assert_eq "$s_out" "ALIVE" \
  "ac-1 a sourced unknown boot does not end the shell that sourced it"
assert_eq "$s_err" "" "ac-1 a sourced unknown boot prints nothing at all"

# --- the caller's own shell options survive the banner -------------------
# The file turns `set -u` on for its body. Left on, it would make the login shell abort the
# first command that mentions an unset variable: the same breakage, one step later.
s_out=$(AB_ESP="$esp" AB_CMD="$cmdline" AB_SLOT_BIN="$ab_slot" \
  sh -c '. "$1"; echo "${NO_SUCH_VARIABLE_XYZ}"; echo AFTER' sh "$profile" 2>"$tmp/err-opts")
assert_eq "$s_out" $'\nAFTER' \
  "ac-1 the set -u the banner uses does not outlive it in the caller's shell"

finish
