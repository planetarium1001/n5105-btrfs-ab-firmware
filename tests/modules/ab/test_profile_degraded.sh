#!/usr/bin/env bash
# Module: ab
# ac-5: `platform/etc/profile.d/ab-degraded.sh` says it out loud when this boot is
#       degraded - one line on stderr that contains `degraded` and says writes will not
#       survive - and is completely silent, with exit status 0, on a healthy boot and on
#       one it cannot judge. It writes no file: the fact already exists in the ring log.
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

# --- a healthy boot says nothing at all ----------------------------------
printf 'stage=boot slot=a upper=@overlay-25.12.3 rootfs=25.12.3 result=ok\n' >"$esp/ab/log/boot-0.log"
stdout=$(run_profile 2>"$tmp/err-ok")
rc=$?
assert_eq "$rc" "0" "ac-5 a healthy boot exits 0"
assert_eq "$stdout" "" "ac-5 a healthy boot prints nothing on stdout"
assert_eq "$(cat "$tmp/err-ok")" "" "ac-5 a healthy boot prints nothing on stderr"

# --- a boot it cannot judge says nothing either --------------------------
rm -f "$esp/ab/log/boot-0.log"
stdout=$(run_profile 2>"$tmp/err-unknown")
rc=$?
assert_eq "$rc" "0" "ac-5 an unknown boot exits 0"
assert_eq "$(cat "$tmp/err-unknown")" "" \
  "ac-5 an unknown boot is not announced as degraded, and not announced as healthy either"

finish
