#!/usr/bin/env bash
# Module: net
# The first-boot network seed is the difference between "flash the disk and reach the
# box" and "flash the disk and drive to the machine with a keyboard". It is also the one
# place where a mistake rewrites a user's configuration, so every branch gets a case:
#   ac-1 a fresh image generates board.json + network + system through the upstream tools
#   ac-2 the generated configuration then carries this project's defaults
#   ac-3 an existing /etc/config/network is never touched (fixtures and users)
#   ac-5 one physical port degrades to LAN-only instead of building an empty bridge
#   ac-4  NET_WAN_SSH=closed adds no firewall rule and leaves dropbear bound
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

lib="$root/platform/lib/net-defaults.sh"
assert_file_exists "$lib" "the net-defaults library exists"

# --------------------------------------------------------------------------- #
# Fixtures: a fake system root, fake upstream generators and a recording uci.
# --------------------------------------------------------------------------- #

# mksystem <dir> <ports...>: etc/, a bin/ with stubs, one sysfs entry per port.
mksystem() {
    local dir=$1
    shift
    mkdir -p "$dir/etc/config" "$dir/tmp" "$dir/net" "$dir/bin"

    cat >"$dir/etc/net-defaults.conf" <<'CONF'
NET_WAN_DEV=eth0
NET_LAN_DEVS=auto
NET_LAN_ADDR=192.168.100.1
NET_LAN_PREFIX=24
NET_WAN_SSH=open
CONF

    # `uci show network` as it looks right after config_generate: br-lan is an anonymous
    # device section, which is the section the seed has to reuse.
    cat >"$dir/uci-show-network.txt" <<'SHOW'
network.loopback=interface
network.loopback.device='lo'
network.@device[0]=device
network.@device[0].name='br-lan'
network.@device[0].type='bridge'
network.@device[0].ports='eth0'
network.lan=interface
network.lan.device='br-lan'
network.wan=interface
network.wan.device='eth1'
SHOW

    cat >"$dir/bin/board_detect" <<'STUB'
#!/usr/bin/env bash
printf 'board_detect %s\n' "$*" >>"${ND_STUB_LOG}"
printf '{"model":{"name":"test"}}\n' >"$1"
STUB
    # config_generate is upstream's generator: it writes network and system and refuses
    # to run when both are already there.
    cat >"$dir/bin/config_generate" <<'STUB'
#!/usr/bin/env bash
printf 'config_generate\n' >>"${ND_STUB_LOG}"
if [ -s "${ND_ROOT}/etc/config/network" ] && [ -s "${ND_ROOT}/etc/config/system" ]; then
    exit 0
fi
if [ -n "${ND_STUB_GENERATE_FAILS:-}" ]; then
    exit 1
fi
mkdir -p "${ND_ROOT}/etc/config"
cat >"${ND_ROOT}/etc/config/network" <<'NET'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	list ipaddr '127.0.0.1/8'

config globals 'globals'
	option packet_steering '1'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	list ipaddr '192.168.1.1/24'

config interface 'wan'
	option device 'eth1'
	option proto 'dhcp'

config interface 'wan6'
	option device '@wan'
	option proto 'dhcpv6'
NET
    cat >"${ND_ROOT}/etc/config/system" <<'SYS'
config system
	option hostname 'ImmortalWrt'
	option timezone 'GMT0'
SYS
STUB
    # uci: records every invocation, answers `show network` from a fixture, and treats
    # `get` as "not set" so the firewall rule is created.
    cat >"$dir/bin/uci" <<'STUB'
#!/usr/bin/env bash
printf 'uci %s\n' "$*" >>"${ND_STUB_LOG}"
args=()
for a in "$@"; do
    [ "$a" = "-q" ] || args+=("$a")
done
case "${args[0]:-}" in
    show)
        [ -n "${ND_STUB_UCI_SHOW:-}" ] && cat "${ND_STUB_UCI_SHOW}"
        exit 0
        ;;
    get) exit "${ND_STUB_UCI_GET_STATUS:-1}" ;;
esac
exit 0
STUB
    chmod +x "$dir/bin/board_detect" "$dir/bin/config_generate" "$dir/bin/uci"

    local port
    for port in "$@"; do
        mkdir -p "$dir/net/$port"
        : >"$dir/net/$port/device"
    done
}

# run_seed <dir>: source the library against that root and call the entry point.
run_seed() {
    local dir=$1
    (
        export ND_ROOT="$dir"
        export ND_NET_DIR="$dir/net"
        export ND_BIN_DIR="$dir/bin"
        export ND_UCI="$dir/bin/uci"
        export ND_BOARD_TMP="$dir/tmp/board.json"
        export ND_STUB_LOG="$dir/stub.log"
        export ND_STUB_UCI_SHOW="$dir/uci-show-network.txt"
        export ND_CONF="$dir/etc/net-defaults.conf"
        export ND_MARKER="$dir/etc/config/.ab-net-seed"
        export ND_ESP="$dir/esp"
        # shellcheck source=platform/lib/net-defaults.sh
        . "$lib"
        wf_net_seed
    )
}

# --------------------------------------------------------------------------- #
# ac-1 / ac-2: fresh system - generates, then applies the project defaults
# --------------------------------------------------------------------------- #

fresh="$tmp/fresh"
mksystem "$fresh" eth0 eth1 eth2 eth3
out="$(run_seed "$fresh" 2>&1)"
status=$?

assert_eq "$status" "0" "ac-1 a fresh system seeds successfully"
assert_contains "$out" "result=ok mode=router" "ac-2 four ports come up in router mode"
assert_file_exists "$fresh/etc/board.json" "ac-1 board.json is generated by board_detect"
assert_contains "$(cat "$fresh/stub.log")" "board_detect" "ac-1 the upstream board tool runs"
assert_contains "$(cat "$fresh/stub.log")" "config_generate" "ac-1 the upstream generator runs"
assert_file_exists "$fresh/etc/config/network" "ac-1 config_generate produced the network file"

uci_log="$(cat "$fresh/stub.log")"
assert_contains "$uci_log" "add_list network.@device[0].ports=eth1" "ac-2 eth1 joins br-lan"
assert_contains "$uci_log" "add_list network.@device[0].ports=eth2" "ac-2 eth2 joins br-lan"
assert_contains "$uci_log" "add_list network.@device[0].ports=eth3" "ac-2 eth3 joins br-lan"
assert_contains "$uci_log" "delete network.@device[0].ports" "ac-2 stale ports are cleared first"
assert_contains "$uci_log" "add_list network.lan.ipaddr=192.168.100.1/24" "ac-2 the LAN address is the project default"
assert_contains "$uci_log" "network.wan.device=eth0" "ac-2 eth0 is the WAN"
assert_contains "$uci_log" "network.wan.proto=dhcp" "ac-2 the WAN is a dhcp client"
assert_contains "$uci_log" "network.wan6.device=@wan" "ac-2 wan6 follows the WAN"
assert_contains "$uci_log" "firewall.@rule[-1].name=allow_ssh_wan" "ac-2 one WAN SSH rule is added"
assert_contains "$uci_log" "firewall.@rule[-1].dest_port=22" "ac-4 the rule is tcp/22 only"
assert_contains "$uci_log" "firewall.@rule[-1].src=wan" "ac-4 the rule is scoped to the WAN zone"
assert_contains "$uci_log" "delete dropbear.@dropbear[0].Interface" "ac-4 dropbear is unbound"
case "$uci_log" in
    *"input=ACCEPT"*) assert_eq "found" "absent" "ac-4 no zone input is opened" ;;
    *) assert_eq "absent" "absent" "ac-4 no zone input is opened" ;;
esac

# --------------------------------------------------------------------------- #
# ac-3: an existing configuration is the user's, not ours
# --------------------------------------------------------------------------- #

# 1. A configuration somebody edited is never rewritten: no marker, but also no uci.
keep="$tmp/keep"
mksystem "$keep" eth0 eth1 eth2 eth3
mkdir -p "$keep/etc/config"
printf "config interface 'lan'\n\toption device 'br-lan'\n\tlist ipaddr '10.10.10.1/24'\n" >"$keep/etc/config/network"
out="$(run_seed "$keep" 2>&1)"
status=$?

assert_eq "$status" "0" "ac-3 a foreign configuration is left alone"
assert_contains "$out" "result=skip reason=foreign-config" "ac-3 the skip reason is the foreign one"
assert_eq "$(cat "$keep/stub.log" 2>/dev/null)" "" "ac-3 neither the generators nor uci are called"
assert_eq "$(cat "$keep/etc/config/network")" "config interface 'lan'
	option device 'br-lan'
	list ipaddr '10.10.10.1/24'" "ac-3 the file is byte-identical afterwards"
assert_file_exists "$keep/etc/config/.ab-net-seed" "ac-3 the marker is written so later boots stay away"

# 2. The untouched upstream default (what a v0.0.7 machine carried) is repaired instead
#    of skipped: that box had no WAN at all and would never have healed itself.
heal="$tmp/heal"
mksystem "$heal" eth0 eth1 eth2 eth3
mkdir -p "$heal/etc/config"
cat >"$heal/etc/config/network" <<'NET'
config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	list ipaddr '192.168.1.1/24'
NET
out="$(run_seed "$heal" 2>&1)"
assert_contains "$out" "note=unseeded-upstream-default-repair" "ac-3 the upstream default is recognised"
assert_contains "$out" "result=ok mode=router" "ac-3 and repaired into router mode"
assert_contains "$(cat "$heal/stub.log")" "add_list network.lan.ipaddr=192.168.100.1/24" \
  "ac-3 the LAN address becomes the project default"
assert_file_exists "$heal/etc/config/.ab-net-seed" "ac-3 the repair writes the marker"

# --------------------------------------------------------------------------- #
# ac-5: one port cannot be a router
# --------------------------------------------------------------------------- #

single="$tmp/single"
mksystem "$single" eth0
out="$(run_seed "$single" 2>&1)"
assert_contains "$out" "result=ok mode=lan-only" "ac-5 a single port degrades to LAN-only"
case "$(cat "$single/stub.log")" in
    *"delete network.wan"*) assert_eq "deleted" "deleted" "ac-5 the WAN interface is removed" ;;
    *) assert_eq "kept" "deleted" "ac-5 the WAN interface is removed" ;;
esac
assert_contains "$(cat "$single/stub.log")" "add_list network.@device[0].ports=eth0" "ac-5 the only port stays in the bridge"

# --------------------------------------------------------------------------- #
# ac-4 (second half): closed means closed
# --------------------------------------------------------------------------- #

closed="$tmp/closed"
mksystem "$closed" eth0 eth1 eth2 eth3
python3 - "$closed/etc/net-defaults.conf" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("NET_WAN_SSH=open", "NET_WAN_SSH=closed"))
PY
out="$(run_seed "$closed" 2>&1)"
assert_contains "$out" "result=ok mode=router" "ac-4 closed still comes up in router mode"
case "$(cat "$closed/stub.log")" in
    *"allow_ssh_wan"*) assert_eq "found" "absent" "ac-4 closed adds no WAN rule" ;;
    *) assert_eq "absent" "absent" "ac-4 closed adds no WAN rule" ;;
esac
case "$(cat "$closed/stub.log")" in
    *"dropbear"*) assert_eq "touched" "untouched" "ac-4 closed leaves dropbear alone" ;;
    *) assert_eq "untouched" "untouched" "ac-4 closed leaves dropbear alone" ;;
esac

# --------------------------------------------------------------------------- #
# A board whose lan is not a bridge: the seed creates br-lan instead of giving up
# --------------------------------------------------------------------------- #

nobridge="$tmp/nobridge"
mksystem "$nobridge" eth0 eth1 eth2 eth3
cat >"$nobridge/uci-show-network.txt" <<'SHOW'
network.loopback=interface
network.loopback.device='lo'
network.lan=interface
network.lan.device='eth0'
SHOW
out="$(run_seed "$nobridge" 2>&1)"
assert_contains "$out" "result=ok mode=router" "a missing br-lan section still seeds"
assert_contains "$(cat "$nobridge/stub.log")" "set network.brlan.name=br-lan" "the bridge is created when upstream has none"
assert_contains "$(cat "$nobridge/stub.log")" "add_list network.brlan.ports=eth1" "ports land on the created bridge"

# --------------------------------------------------------------------------- #
# Deferral: no NICs yet (igc probes after S16) - log it, write no marker, retry later
# --------------------------------------------------------------------------- #

late="$tmp/late"
mksystem "$late"            # no eth* at all, and no pre-existing network file
out="$(run_seed "$late" 2>&1)"
status=$?
assert_eq "$status" "0" "a boot without ethernet is not a failure"
assert_contains "$out" "result=pending reason=no-ethernet" "the deferral is reported"
[ -f "$late/etc/config/.ab-net-seed" ] &&
    assert_eq "marker" "no-marker" "the deferral writes no marker" ||
    assert_eq "no-marker" "no-marker" "the deferral writes no marker"

# The evidence file exists even then, so a pulled disk explains why nothing was configured.
assert_file_exists "$late/esp/ab/net.json" "the ESP carries ab/net.json on a deferral"

# --------------------------------------------------------------------------- #
# Evidence: ab/net.json says what was decided
# --------------------------------------------------------------------------- #

assert_file_exists "$fresh/esp/ab/net.json" "a seeded machine leaves ab/net.json on the ESP"
net_json="$(cat "$fresh/esp/ab/net.json" 2>/dev/null)"
assert_contains "$net_json" '"result": "ok"' "the evidence records the result"
assert_contains "$net_json" '"mode": "router"' "the evidence records the mode"
assert_contains "$net_json" '"wan": "eth0"' "the evidence records the WAN port"
assert_contains "$net_json" '"marker": "present"' "the evidence records the marker"

# --------------------------------------------------------------------------- #
# Failure paths: reported, never fatal to the caller
# --------------------------------------------------------------------------- #

broken="$tmp/broken"
mksystem "$broken" eth0 eth1
ND_STUB_GENERATE_FAILS=1
out="$(ND_STUB_GENERATE_FAILS=1 run_seed "$broken" 2>&1)"
status=$?
assert_eq "$status" "1" "a failing generator is reported as non-zero"
assert_contains "$out" "result=fail reason=config-generate" "the failing stage is named"

# A second run over a seeded system does nothing, which is the whole idempotence story.
out="$(run_seed "$fresh" 2>&1)"
assert_contains "$out" "result=skip reason=seeded" "a second boot is a no-op"

finish
