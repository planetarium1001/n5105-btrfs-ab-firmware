#!/usr/bin/env bash
# Module: ab
# Verifies the health check in platform/etc/init.d/ab-commit: what each probe requires,
# and that a failure says *why* it failed.
#   ac-1 the writable-layer probe needs a writable /overlay with an absolute free-space
#        floor, not a percentage of whatever the partition happens to be
#   ac-2 the firewall and wan probes name the thing they could not find
#   ac-3 preflight: a slot that came up without /proc is reported as that, not as three
#        anonymous probe failures
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

hook="$root/platform/etc/init.d/ab-commit"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The hook is a plain shell script with function definitions; sourcing it only sets
# variables, so its probes can be driven directly.
# shellcheck source=platform/etc/init.d/ab-commit
. "$hook"

overlay="$tmp/overlay"
proc_dir="$tmp/proc"
sysfs="$tmp/sys"
mkdir -p "$overlay" "$proc_dir" "$sysfs/class/net"

# run_probe_fn <function>: the function's exit status, with PROBE_REASON printed.
probe_reason=""

# --------------------------------------------------------------------------- #
# ac-1: writable layer, absolute floor
# --------------------------------------------------------------------------- #

AB_OVERLAY="$overlay" AB_FREE_FLOOR_KB=0
export AB_OVERLAY AB_FREE_FLOOR_KB
probe_overlay_writable
assert_eq "$?" "0" "ac-1 a writable overlay passes"
assert_eq "$PROBE_REASON" "" "ac-1 a pass carries no reason"
assert_eq "$(ls -A "$overlay" | wc -l | tr -d ' ')" "0" \
  "ac-1 the probe file is removed again"

# A floor the filesystem cannot meet: the same probe now fails, and says by how much.
AB_FREE_FLOOR_KB=999999999
export AB_FREE_FLOOR_KB
probe_overlay_writable
assert_eq "$?" "1" "ac-1 a full filesystem fails the probe"
assert_contains "$PROBE_REASON" "free-" "ac-1 the reason names the free space"
assert_contains "$PROBE_REASON" "-below-999999999k" "ac-1 and the floor it missed"
AB_FREE_FLOOR_KB=16384
export AB_FREE_FLOOR_KB

# The floor is an absolute number of KiB, not a percentage: the same 128 MiB test image
# and a disk of hundreds of GiB get the same rule.
assert_contains "$(cat "$hook")" 'AB_FREE_FLOOR_KB="${AB_FREE_FLOOR_KB:-16384}"' \
  "ac-1 the floor is 16 MiB by default"
assert_eq "$(grep -c 'avail \* 100 / ' "$hook")" "0" \
  "ac-1 no percentage of the partition size is used any more"

AB_OVERLAY="$tmp/nothing-here"
export AB_OVERLAY
probe_overlay_writable
assert_eq "$?" "1" "ac-1 a missing overlay fails the probe"
assert_eq "$PROBE_REASON" "no-overlay" "ac-1 and says the mount point is missing"

mkdir -p "$tmp/readonly"
chmod 500 "$tmp/readonly"
AB_OVERLAY="$tmp/readonly"
export AB_OVERLAY
probe_overlay_writable
if [ "$(id -u)" = "0" ]; then
  # root writes to a 0500 directory; the case is not observable as root.
  assert_eq "0" "0" "ac-1 skipped as root: 0500 is still writable"
else
  assert_eq "$?" "1" "ac-1 an unwritable overlay fails the probe"
  assert_contains "$PROBE_REASON" "not-writable" "ac-1 and says it cannot write"
fi
chmod 700 "$tmp/readonly"
AB_OVERLAY="$overlay"
export AB_OVERLAY

# --------------------------------------------------------------------------- #
# ac-2: firewall and wan probes name what is missing
# --------------------------------------------------------------------------- #

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
PATH="/usr/bin:/bin"
export PATH

probe_fw4
assert_eq "$?" "1" "ac-2 without nft the firewall probe fails"
assert_eq "$PROBE_REASON" "no-nft" "ac-2 and names the missing tool"

cat >"$stub_bin/nft" <<'STUB'
#!/bin/sh
case "$*" in
  "list ruleset") printf '%s\n' "${STUB_RULESET:-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/nft"
PATH="$stub_bin:/usr/bin:/bin"
export PATH

STUB_RULESET=""
export STUB_RULESET
probe_fw4
assert_eq "$?" "1" "ac-2 an empty ruleset fails the probe"
assert_eq "$PROBE_REASON" "nft-ruleset-empty" "ac-2 and says the ruleset is empty"

STUB_RULESET="table inet filter {}"
export STUB_RULESET
probe_fw4
assert_eq "$?" "1" "ac-2 a ruleset without fw4 fails the probe"
assert_eq "$PROBE_REASON" "no-fw4-table-or-process" "ac-2 and says fw4 is not loaded"

probe_wan
assert_eq "$?" "1" "ac-2 without uci the wan probe fails"
assert_eq "$PROBE_REASON" "no-uci" "ac-2 and names the missing tool"

cat >"$stub_bin/uci" <<'STUB'
#!/bin/sh
[ -n "${STUB_WAN_DEVICE:-}" ] || exit 1
printf '%s\n' "${STUB_WAN_DEVICE}"
STUB
chmod +x "$stub_bin/uci"
STUB_WAN_DEVICE=""
export STUB_WAN_DEVICE
AB_SYSFS="$sysfs"
export AB_SYSFS
probe_wan
assert_eq "$?" "1" "ac-2 a wan without a device fails the probe"
assert_eq "$PROBE_REASON" "no-wan-device-in-uci" "ac-2 and says uci has no device"

STUB_WAN_DEVICE="eth1"
export STUB_WAN_DEVICE
probe_wan
assert_eq "$?" "1" "ac-2 a wan device that does not exist fails the probe"
assert_eq "$PROBE_REASON" "no-interface:eth1" "ac-2 and names the interface"

mkdir -p "$sysfs/class/net/eth1"
probe_wan
assert_eq "$?" "0" "ac-2 a wan device that exists passes the probe"

# --------------------------------------------------------------------------- #
# ac-3: preflight, so a broken tree is not reported as three broken probes
# --------------------------------------------------------------------------- #

AB_PROC="$proc_dir"
export AB_PROC
preflight
assert_eq "$?" "1" "ac-3 a tree without /proc fails preflight"
assert_eq "$PREFLIGHT_REASON" "proc-cmdline-unreadable" \
  "ac-3 and names the first thing it could not read"

: >"$proc_dir/cmdline"
preflight
assert_eq "$?" "1" "ac-3 a read-only /proc/cmdline is not enough"
assert_eq "$PREFLIGHT_REASON" "proc-mounts-unreadable" "ac-3 preflight walks the list"

: >"$proc_dir/mounts"
AB_SYSFS="$tmp/no-sys"
export AB_SYSFS
preflight
assert_eq "$?" "1" "ac-3 a tree without sysfs fails preflight"
assert_eq "$PREFLIGHT_REASON" "sysfs-missing" "ac-3 and says so"

AB_SYSFS="$sysfs"
export AB_SYSFS
preflight
assert_eq "$?" "0" "ac-3 a complete tree passes preflight"

# The preflight result has to reach the decision, with its own reason: this is the line
# that tells a broken slot apart from a failing probe.
assert_contains "$(cat "$hook")" 'failed="preflight-${PREFLIGHT_REASON}"' \
  "ac-3 a preflight failure is carried as the health check reason"
assert_contains "$(cat "$hook")" 'console_say "ab-commit: stage=preflight slot=${slot} result=fail reason=${PREFLIGHT_REASON}"' \
  "ac-3 and printed on the console"
assert_contains "$(cat "$hook")" 'console_say "probe=${probe} result=fail reason=${PROBE_REASON:-unknown}"' \
  "ac-3 every failed probe prints its reason"

finish
