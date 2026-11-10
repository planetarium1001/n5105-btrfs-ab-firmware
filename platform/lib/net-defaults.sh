#!/bin/sh
# net-defaults - first-boot network generation, then this project's own defaults.
#
# Why this file exists: the image consumes the upstream ImmortalWrt rootfs, which does
# not ship /etc/config/network. Upstream generates it on first boot from a *preinit*
# hook (lib/preinit/82_config_generate -> /bin/board_detect -> /bin/config_generate).
# Our A/B initramfs replaces preinit entirely, so that hook never runs and a freshly
# written disk comes up without an address. This file puts the same generation back,
# once, and then applies the defaults this project ships on top of it:
#
#   * eth0 is the WAN (dhcp), every other physical eth* joins the br-lan bridge
#   * br-lan is 192.168.100.1/24 (deliberately not 192.168.1.1: most home routers
#     already own that subnet, and the box usually hangs off one of them)
#   * one firewall rule lets tcp/22 in from the WAN, and dropbear is unbound so that
#     rule can actually reach it - the only exposure this project adds, and the README
#     tells the operator how to remove it
#
# The trigger is exactly one condition: /etc/config/network does not exist. Nothing
# else. A configuration written by the user, injected by a CI fixture, or carried over
# by an upgrade is left untouched - that is what keeps "your changes survive updates"
# true without a single line of conflict logic.
#
# Sourced by platform/etc/init.d/ab-net-seed. POSIX sh, no `local`, variables are
# prefixed nd_. Everything is overridable through ND_* so tests can drive the whole
# decision from a fixture tree instead of a real system.

# Paths. ND_ROOT prefixes every path the library writes, so a test can point the whole
# thing at a scratch directory; ND_NET_DIR is where interface names are read from.
ND_ROOT="${ND_ROOT:-}"
ND_CONF="${ND_CONF:-${ND_ROOT}/etc/net-defaults.conf}"
ND_NET_DIR="${ND_NET_DIR:-/sys/class/net}"
ND_BIN_DIR="${ND_BIN_DIR:-/bin}"
ND_UCI="${ND_UCI:-uci}"
# Where the generated board file is staged. Under ND_ROOT so a test never touches /tmp.
ND_BOARD_TMP="${ND_BOARD_TMP:-${ND_ROOT}/tmp/board.json}"

# Defaults, used when the rendered configuration file is missing a key. They match
# scripts/ci/net-defaults.conf.in; the file is what the build renders.
ND_WAN_DEV="${ND_WAN_DEV:-eth0}"
ND_LAN_DEVS="${ND_LAN_DEVS:-auto}"
ND_LAN_ADDR="${ND_LAN_ADDR:-192.168.100.1}"
ND_LAN_PREFIX="${ND_LAN_PREFIX:-24}"
ND_WAN_SSH="${ND_WAN_SSH:-open}"

# nd_say: one line of progress. The init script forwards these to the ring log and to
# syslog; a test just reads stdout.
nd_say() {
    printf 'stage=net-seed %s\n' "$*"
}

# nd_conf_get <key> <fallback>: one value out of the rendered configuration file.
nd_conf_get() {
    nd_key="$1"
    nd_fallback="$2"
    if [ -r "${ND_CONF}" ]; then
        nd_value="$(sed -n "s/^${nd_key}=//p" "${ND_CONF}" | tail -n 1)"
        if [ -n "${nd_value}" ]; then
            printf '%s' "${nd_value}"
            return 0
        fi
    fi
    printf '%s' "${nd_fallback}"
}

# nd_load_conf: the four knobs this project ships, from the file the build rendered into
# the platform layer. Read once, so a half-written file cannot change behaviour midway.
nd_load_conf() {
    ND_WAN_DEV="$(nd_conf_get NET_WAN_DEV "${ND_WAN_DEV}")"
    ND_LAN_DEVS="$(nd_conf_get NET_LAN_DEVS "${ND_LAN_DEVS}")"
    ND_LAN_ADDR="$(nd_conf_get NET_LAN_ADDR "${ND_LAN_ADDR}")"
    ND_LAN_PREFIX="$(nd_conf_get NET_LAN_PREFIX "${ND_LAN_PREFIX}")"
    ND_WAN_SSH="$(nd_conf_get NET_WAN_SSH "${ND_WAN_SSH}")"
}

# nd_eth_devices: the physical ethernet ports this machine actually has, one per line,
# sorted so eth2 never comes before eth10. Only interfaces that carry a `device` link
# are listed: br-lan, wan, lo and every other synthetic device are not hardware.
# This is the whole reason the four ports are not hard coded - the same image has to
# behave on a four-port N5105 and on a single virtio NIC in the CI smoke test.
nd_eth_devices() {
    for nd_dev_path in "${ND_NET_DIR}"/*; do
        [ -e "${nd_dev_path}/device" ] || continue
        nd_dev_name="${nd_dev_path##*/}"
        case "${nd_dev_name}" in
            eth*|en*) printf '%s\n' "${nd_dev_name}" ;;
        esac
    done | LC_ALL=C sort
}

# nd_br_lan_section: the anonymous `config device` section that names br-lan, as uci
# indexes it. config_generate creates it; when it is missing (a board whose lan is not
# a bridge) a named one is created instead, so the ports still have a home.
nd_br_lan_section() {
    "${ND_UCI}" -q show network 2>/dev/null |
        sed -n "s/^network\.@device\[\([0-9][0-9]*\)\]\.name='br-lan'\$/\1/p" |
        tail -n 1
}

nd_uci() {
    "${ND_UCI}" -q "$@"
}

# nd_apply_defaults: the project's own layer on top of the generated configuration.
# Everything here is plain uci on the sections config_generate just created, so a later
# `uci set` by the operator wins and nothing of this runs again.
nd_apply_defaults() {
    nd_wan="$(nd_conf_get NET_WAN_DEV "${ND_WAN_DEV}")"
    nd_addr="$(nd_conf_get NET_LAN_ADDR "${ND_LAN_ADDR}")"
    nd_prefix="$(nd_conf_get NET_LAN_PREFIX "${ND_LAN_PREFIX}")"
    nd_ssh="$(nd_conf_get NET_WAN_SSH "${ND_WAN_SSH}")"
    nd_wanted="$(nd_conf_get NET_LAN_DEVS "${ND_LAN_DEVS}")"

    nd_all="$(nd_eth_devices | tr '\n' ' ')"
    nd_all="${nd_all% }"
    if [ -z "${nd_all}" ]; then
        nd_say "result=fail reason=no-ethernet"
        return 1
    fi
    nd_count=0
    for nd_dev in ${nd_all}; do
        nd_count=$((nd_count + 1))
    done

    # Port roles. A machine with a single port cannot be a router between two networks:
    # it degrades to "LAN only" (one port, static address, dnsmasq serving it), which is
    # exactly what the QEMU smoke test and a one-cable house need.
    nd_lan_ports=""
    nd_wan_dev=""
    if [ "${nd_count}" -eq 1 ]; then
        nd_mode="lan-only"
        nd_lan_ports="${nd_all}"
    else
        nd_mode="router"
        case "${nd_wanted}" in
            auto|"")
                for nd_dev in ${nd_all}; do
                    if [ "${nd_dev}" = "${nd_wan}" ]; then
                        nd_wan_dev="${nd_dev}"
                    else
                        nd_lan_ports="${nd_lan_ports} ${nd_dev}"
                    fi
                done
                # The configured WAN name is not on this machine (renamed port, VM):
                # take the first port instead of silently leaving no WAN at all.
                if [ -z "${nd_wan_dev}" ]; then
                    nd_wan_dev="$(nd_eth_devices | head -n 1)"
                    nd_lan_ports=""
                    for nd_dev in ${nd_all}; do
                        [ "${nd_dev}" = "${nd_wan_dev}" ] || nd_lan_ports="${nd_lan_ports} ${nd_dev}"
                    done
                    nd_say "note=wan-device-missing wanted=${nd_wan} using=${nd_wan_dev}"
                fi
                ;;
            *)
                for nd_dev in ${nd_wanted}; do
                    if [ "${nd_dev}" = "${nd_wan}" ]; then
                        nd_wan_dev="${nd_dev}"
                    else
                        nd_lan_ports="${nd_lan_ports} ${nd_dev}"
                    fi
                done
                ;;
        esac
        nd_lan_ports="${nd_lan_ports# }"
    fi

    # The bridge: reuse config_generate's br-lan device section when it exists, create a
    # named one otherwise. Ports are replaced wholesale, so a stale eth2 left behind by
    # an older default cannot survive.
    nd_section="$(nd_br_lan_section)"
    if [ -z "${nd_section}" ]; then
        nd_uci set network.brlan=device
        nd_uci set network.brlan.name=br-lan
        nd_uci set network.brlan.type=bridge
        nd_section="brlan"
    else
        nd_section="@device[${nd_section}]"
    fi
    nd_uci -q delete "network.${nd_section}.ports" || :
    for nd_port in ${nd_lan_ports}; do
        nd_uci add_list "network.${nd_section}.ports=${nd_port}"
    done

    # The LAN interface: static, on the bridge, with the address this project ships.
    nd_uci set network.lan=interface
    nd_uci set network.lan.device=br-lan
    nd_uci set network.lan.proto=static
    nd_uci -q delete network.lan.netmask || :
    nd_uci -q delete network.lan.ipaddr || :
    nd_uci add_list "network.lan.ipaddr=${nd_addr}/${nd_prefix}"

    if [ "${nd_mode}" = "router" ]; then
        nd_uci set network.wan=interface
        nd_uci set "network.wan.device=${nd_wan_dev}"
        nd_uci set network.wan.proto=dhcp
        nd_uci set network.wan6=interface
        nd_uci set network.wan6.device=@wan
        nd_uci set network.wan6.proto=dhcpv6
    else
        nd_uci -q delete network.wan || :
        nd_uci -q delete network.wan6 || :
    fi
    nd_uci commit network

    # The one exposure this project adds, and only when asked for: tcp/22 in from the
    # WAN. The wan zone keeps input REJECT - a zone set to ACCEPT would open LuCI and
    # every other service too, which is what the community images do and we do not.
    if [ "${nd_ssh}" = "open" ] && [ "${nd_mode}" = "router" ]; then
        if ! nd_uci get firewall.allow_ssh_wan >/dev/null 2>&1; then
            nd_uci add firewall rule
            nd_uci set firewall.@rule[-1].name=allow_ssh_wan
            nd_uci set firewall.@rule[-1].src=wan
            nd_uci set firewall.@rule[-1].proto=tcp
            nd_uci set firewall.@rule[-1].dest_port=22
            nd_uci set firewall.@rule[-1].target=ACCEPT
            nd_uci commit firewall
        fi
        # dropbear binds to `lan` in the upstream default; a bound daemon cannot accept
        # the connection the rule above allows, so the binding has to go.
        nd_uci -q delete dropbear.@dropbear[0].Interface || :
        nd_uci commit dropbear
        nd_say "wan-ssh=open"
    fi

    nd_say "result=ok mode=${nd_mode} wan=${nd_wan_dev:-none} lan-ports=${nd_lan_ports} addr=${nd_addr}/${nd_prefix}"
    return 0
}

# wf_net_seed: the entry point. Returns non-zero when the configuration could not be
# produced; the caller logs it and lets the boot continue, because a machine without a
# network still has a console and a reboot loop would only hide the reason.
wf_net_seed() {
    nd_load_conf

    if [ -s "${ND_ROOT}/etc/config/network" ]; then
        nd_say "result=skip reason=network-present"
        return 0
    fi

    if [ ! -s "${ND_ROOT}/etc/board.json" ]; then
        mkdir -p "${ND_ROOT}/etc" "$(dirname "${ND_BOARD_TMP}")" || :
        if ! "${ND_BIN_DIR}/board_detect" "${ND_BOARD_TMP}" >/dev/null 2>&1; then
            nd_say "result=fail reason=board-detect"
            return 1
        fi
        mv "${ND_BOARD_TMP}" "${ND_ROOT}/etc/board.json" || {
            nd_say "result=fail reason=board-json"
            return 1
        }
    fi

    # The same generator upstream runs from preinit. It refuses to do anything when both
    # network and system already exist, which is why the absence of network above is the
    # only state that reaches this line.
    if ! "${ND_BIN_DIR}/config_generate" >/dev/null 2>&1; then
        nd_say "result=fail reason=config-generate"
        return 1
    fi
    if [ ! -s "${ND_ROOT}/etc/config/network" ]; then
        nd_say "result=fail reason=config-generate-empty"
        return 1
    fi

    nd_apply_defaults || return 1
    return 0
}
