#!/usr/bin/env bash
# Module: device
# The feed probe: the ac-11 checklist as one block of text, without a device.
#
#   ac-11  the probe reports the fetchers, the CA store, the running versions and the
#          `--feed-check` verdict, in a shape that can be pasted into evidence
#   ac-11  a machine it cannot reach says so instead of printing empty fields
#   ac-11  the probe itself never writes: the only remote commands are reads
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
last=""
for arg in "$@"; do last="$arg"; done
case "${last}" in
    *"ab-slot status"*) printf '%s\n' "${STUB_STATUS:-slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none}" ;;
    *"uclient-fetch >/dev/null"*)
        # The real remote command prints the fetchers it found and the CA verdict.
        printf 'uclient-fetch, ca=no\n'
        ;;
    *"uname -r"*) printf '6.12.103\n' ;;
    *"/etc/platform-release"*) printf 'PLATFORM_VERSION=0.0.8\nUPSTREAM_VERSION=25.12.2\n' ;;
    *"test -f"*) exit "${STUB_CONF_EXIT:-0}" ;;
    *"uclient-fetch --help"*)
        [ "${STUB_HTTPS:-yes}" = "yes" ] && printf 'https support\n'
        exit 0
        ;;
    *"--feed-check"*)
        printf '%s\n' "${STUB_CHECK:-platform=0.0.8 platform_available=0.0.8 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=current}"
        exit "${STUB_CHECK_EXIT:-0}"
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$stub_bin/ssh"

probe="$root/scripts/device/feed-probe.sh"
run_probe() { PATH="$stub_bin:$PATH" STUB_CALLS="$tmp/calls" AB_KEY="$tmp/key" "$@" 2>&1; }

# --- ac-11: the happy path --------------------------------------------------
: >"$tmp/calls"
out="$(run_probe sh "$probe")"
rc=$?
assert_eq "$rc" "0" "ac-11 a reachable machine with a feed returns a verdict"
assert_contains "$out" "feed-probe fetchers=uclient-fetch https=yes ca=no conf=present" \
  "ac-11 the probe reports the fetcher, TLS capability, CA store and config"
assert_contains "$out" "feed-probe installed=0.0.8 base=25.12.2 kernel=6.12.103" \
  "ac-11 the probe reports what the machine runs"
assert_contains "$out" "feed-probe check platform=0.0.8 platform_available=0.0.8" \
  "ac-11 the probe carries the machine line verbatim"
assert_contains "$out" "feed-probe exit=0" "ac-11 the device's own exit code is printed"

# --- ac-11: an update available is still a successful probe -----------------
out="$(run_probe env STUB_CHECK_EXIT=10 sh "$probe")"
assert_eq "$?" "0" "ac-11 exit=10 (update available) is a successful probe"
assert_contains "$out" "feed-probe exit=10" "ac-11 the update verdict keeps its code"

# --- ac-11: refusals are facts, not probe failures -------------------------
out="$(run_probe env STUB_CHECK_EXIT=74 STUB_CHECK='ab-upgrade: refused, reason=no-feed-config' sh "$probe")"
assert_eq "$?" "1" "ac-11 a refusal makes the probe report a failure"
assert_contains "$out" "ab-upgrade: refused, reason=no-feed-config" "ac-11 the refusal is quoted"

# --- ac-11: missing config is reported, not inferred -----------------------
out="$(run_probe env STUB_CONF_EXIT=1 sh "$probe")"
assert_contains "$out" "conf=missing" "ac-11 a missing config is named as missing"

# --- ac-11: the probe only reads -------------------------------------------
assert_contains "$(cat "$tmp/calls")" "ab-upgrade --feed-check" "ac-11 the check is the read-only mode"
case "$(cat "$tmp/calls")" in
  *"ab-upgrade --feed "*) assert_eq "writes" "reads" "ac-11 the probe never runs an install" ;;
  *"uci set"*) assert_eq "writes" "reads" "ac-11 the probe never writes uci" ;;
  *) assert_eq "reads" "reads" "ac-11 the probe never writes the device" ;;
esac

# --- ac-11: an unreachable machine -----------------------------------------
cat >"$stub_bin/ssh-dead" <<'STUB'
#!/bin/sh
exit 255
STUB
chmod +x "$stub_bin/ssh-dead"
out="$(PATH="$stub_bin:$PATH" STUB_CALLS="$tmp/calls" AB_KEY="$tmp/key" \
  sh -c "mv '$stub_bin/ssh' '$stub_bin/ssh.real' && cp '$stub_bin/ssh-dead' '$stub_bin/ssh' && sh '$probe' 2>&1; rc=\$?; mv '$stub_bin/ssh.real' '$stub_bin/ssh'; exit \$rc")"
assert_contains "$out" "feed-probe unreachable" "ac-11 a machine that does not answer says so"

finish
