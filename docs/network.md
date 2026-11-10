# Default Network on First Boot

**English** | [简体中文](network.zh-CN.md)

A freshly flashed disk comes up with a working network and nobody at the console. The
configuration is not baked into the image: the first boot generates it with the same upstream
programs an official ImmortalWrt image runs, and this project's defaults are applied to that
result. Everything you change afterwards lives in the writable layer and is left alone.

## When the seed runs

Two hooks, in this order:

```
S15 ab-boot            A/B bookkeeping, no network
S16 ab-net-seed        board_detect + config_generate + project defaults (first try)
S20 network            netifd brings up br-lan and wan, dnsmasq serves the LAN
S25 ab-net-reconcile   second try, only if S16 could not finish
```

What decides it is a **marker**, `/etc/config/.ab-net-seed`, not the presence of the
configuration file. That distinction is not pedantic: the upstream `99-default-settings`
uci-defaults runs at `S10`, before this hook, and creates a network file that carries
nothing but `config globals`. A seed that trusted "the file exists" skipped itself forever,
which is exactly what a v0.0.7 machine did - it kept the generator default
(`br-lan{eth0}`, `192.168.1.1/24`, `wan eth1`), served no WAN at all, and logged
`result=skip reason=network-present` on every boot.

The decision, in words:

- marker present -> `result=skip reason=seeded`, nothing is read and nothing is written;
- no configuration at all -> `board_detect` + `config_generate`, then the project defaults;
- a configuration that still carries the **untouched upstream fingerprint**
  (`192.168.1.1/24` and exactly one bridge port, `eth0`) -> repaired in place, because that
  is the state a v0.0.7 machine was stuck in;
- any other configuration -> `result=skip reason=foreign-config`; the marker is written so
  later boots stay away, and the file is not touched.

The NICs may not exist yet at `S16` (the igc ports on the N5105 appear around thirteen
seconds in). When `no eth*` is found the seed writes **no marker** and logs
`result=pending reason=no-ethernet`; `S25 ab-net-reconcile` runs again after netifd and
reloads the network once, so the machine heals itself in the same boot. A failure never
blocks the boot: the reason goes to the ring log and `rcS` continues.

Every attempt also writes `ab/net.json` onto the ESP - `result`, `mode`, `wan`,
`lan_ports`, the wired devices it saw, whether the marker exists - so a disk pulled out of
a machine explains its own network without anybody booting it.

## Defaults

| Item | Value | Written by |
|---|---|---|
| WAN device | `eth0` | the project defaults |
| WAN protocol | `dhcp`, plus `wan6` as a `dhcpv6` client on top of it (`@wan`) | the project defaults |
| LAN bridge | `br-lan`, ports `eth1`, `eth2`, `eth3` | the project defaults |
| LAN address | `192.168.100.1/24`, `proto static` | the project defaults |
| LAN DHCP server | dnsmasq on `lan`, upstream's pool | `/etc/config/dhcp`, untouched |
| WAN inbound | one `22/tcp` rule, `allow_ssh_wan` | the project defaults |
| SSH binding | `dropbear.@dropbear[0].Interface` removed, so the daemon listens on every address | the project defaults |

The port set is not a constant. It comes from `/sys/class/net`: every `eth*` with a `device`
link, minus the WAN device, joins the bridge. A two-port machine therefore bridges one port,
and a one-port machine degrades to LAN-only -- `wan` removed, the single port in `br-lan`, and
`stage=net-seed result=ok mode=lan-only` in the ring log. `board_detect` supplies `system` and
the upstream names; it does not decide which port plays which role.

The values themselves come from `/etc/net-defaults.conf`, rendered at build time from
`scripts/ci/net-defaults.conf.in`: `NET_WAN_DEV`, `NET_LAN_DEVS`, `NET_LAN_ADDR`,
`NET_LAN_PREFIX` and `NET_WAN_SSH`. Nothing in the guest invents one. To change a default for
every future install, change the template; to change this machine, use `uci` as below.

## Checking the result

```sh
ip -brief address                          # br-lan carries 192.168.100.1/24, eth0 asked for a lease
uci show network | sed -n '/br-lan/,+3p'   # the bridge and its port list
uci show firewall | grep allow_ssh_wan     # the single WAN exception
uci show dropbear | grep Interface         # no output: the daemon is unbound
nft list ruleset | grep 'dport 22'         # what fw4 actually rendered
```

A fresh install writes one line per run to the ring log on `/boot/ab/log/boot-0.log`:

```
stage=net-seed wan-ssh=open
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

That line is the first thing to read when the address is missing, and
[lifecycle.md](lifecycle.md) documents the log format and the `wan-present` probe that reads
the result.

## Changing the LAN subnet

`192.168.100.1/24` deliberately avoids `192.168.1.0/24`, the subnet nearly every home router
ships with, so the box can sit behind one without a collision. If the network you attach it to
already uses `192.168.100.0/24`, move one of the two. `ipaddr` carries the prefix, which is the
shape the seed writes:

```sh
uci set network.lan.ipaddr='192.168.8.1/24'
uci commit network
/etc/init.d/network reload
```

Clients keep their current lease until it expires, so reconnect at the new address rather than
waiting for the old one to answer. The change lives in the writable layer: it survives an
update, and the seed never runs on top of it again.

## Changing which port is WAN

`ip -br link` names the interfaces; plug a cable into each socket in turn and watch which line
goes `UP` to learn the mapping on your board. To make `eth3` the WAN and hand `eth0` to the
LAN, first ask which `config device` section is the `br-lan` bridge:

```sh
uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='br-lan'$/\1/p"
# prints e.g. @device[0] -- use that in the two port commands below
```

```sh
uci set network.wan.device='eth3'
uci del_list 'network.@device[0].ports=eth3'
uci add_list 'network.@device[0].ports=eth0'
uci commit network
/etc/init.d/network reload
```

Both edits belong together: `wan.device` alone would leave `eth3` bridged into the LAN and
`eth0` unused. A single-port machine has no second port to point `wan` at and already lands in
the LAN-only default above.

## WAN exposure and how to close it

The WAN side accepts `22/tcp` and nothing beyond what upstream's `wan` zone already allows --
DHCP client, ICMP and ICMPv6, IGMP and MLD, IPsec. LuCI's `80/tcp` is not exposed: the
firewall is what keeps it off the WAN, and the `wan` zone keeps `input 'REJECT'`.

The rule is open by default because of how this box is normally deployed: behind the main
router, where the only way in before it has an address of its own is the cable you just
plugged in. A single `22/tcp` exception turns that into `ssh root@<address>`; leaving it
closed would mean an HDMI cable and a keyboard for every change. The trade-off is real -- the
WAN side of a shared network is not necessarily clean, and `dropbear` accepts password
authentication with whatever root password the image carries -- so close it as soon as the box
is reachable from the LAN:

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

In LuCI the same rule is the entry named `allow_ssh_wan` under **Network -> Firewall ->
Traffic Rules** (网络 -> 防火墙 -> 通信规则); delete it and press **Save & Apply**. Then check
that it is gone:

```sh
uci show firewall | grep allow_ssh_wan     # no output
nft list ruleset | grep 'dport 22'         # no output, unless another rule opens 22
```

Closing it leaves the LAN side untouched, and the SSH daemon stays unbound, so SSH from the
LAN keeps working.

## What the seed does not touch

- `/etc/config/dhcp`: the LAN DHCP server is upstream's and stays enabled.
- `/etc/config/firewall` zones: `lan` stays `input 'ACCEPT'` and `wan` stays `input 'REJECT'`.
  Exactly one rule is appended, and only on the boot that generated the network.
- `/etc/config/uhttpd`: LuCI listens where upstream's configuration says; the firewall is what
  keeps it off the WAN.
- `/etc/config/system`: whatever `config_generate` produced is kept -- hostname `ImmortalWrt`,
  timezone `GMT0`. Change those in LuCI if you want others.

## Variants: WAN 22 closed at build time

Whether the `allow_ssh_wan` rule exists is a build-time constant, not a runtime decision.
`scripts/ci/net-defaults.conf.in` carries the `NET_*` lines with `@...@` placeholders; the
build renders them into `/etc/net-defaults.conf` in the platform layer, and a placeholder left
unreplaced fails the build instead of shipping a literal `@NET_...@` to the device.

| `NET_WAN_SSH` | Effect |
|---|---|
| `open` (this release) | the `22/tcp` rule is added and the daemon is unbound |
| `closed` | neither happens; WAN inbound stays exactly as upstream has it |

The closed variant is the same pipeline run with `CI_NET_WAN_SSH=closed`; no code changes.
This release publishes the open variant only, and [install.md](install.md) covers the first
boot on a real device.
