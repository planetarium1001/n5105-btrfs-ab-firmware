# 首启默认网络

[English](network.md) | **简体中文**

刷完盘的机器起来就有网，不需要有人在 console 前操作。配置不是烘进镜像的：首次启动用与官方
ImmortalWrt 镜像相同的上游程序生成，再在这个结果上叠加本项目默认值。之后你的任何改动都在可写层，
不会被再次覆盖。

## 生成时机

`platform/etc/init.d/ab-net-seed` 以 `S16` 启动，早于拉起 netifd 的 `S20network`：

```
S15 ab-boot        A/B 记账，不碰网络
S16 ab-net-seed    board_detect + config_generate + 项目默认叠加
S20 network        netifd 拉起 br-lan 与 wan，dnsmasq 在 LAN 发地址
```

整个生成由一个条件决定，而且这个条件就是文件本身：

```sh
[ -s /etc/config/network ] && return 0      # 已存在：一律不动
/bin/board_detect /tmp/board.json           # 不存在：补回上游 preinit 做的事
/bin/config_generate                        # 写 network 与 system
# 然后只做一次项目默认：端口角色、地址、wan、那条 22/tcp 规则
```

- 没有 marker、没有版本号判断：幂等由"文件存在"表达。同一镜像第二次启动只写一行
  `stage=net-seed result=skip reason=network-present`，别的不做。
- 用户自己改过的 `uci`、经可写层注入的夹具、升级带过来的配置，都等于"文件存在"，一个都不会被重写。
- 失败不阻塞启动：`ab-net-seed` 往环形日志写 `stage=net-seed result=fail reason=<token>` 后 `rcS`
  继续。没网的机器 console 仍然可用，而且回滚也变不出一个网络来。

## 默认值

| 项目 | 取值 | 由谁写 |
|---|---|---|
| WAN 设备 | `eth0` | 项目默认 |
| WAN 协议 | `dhcp`，外加挂在它上面的 `wan6`（`dhcpv6`，`@wan`） | 项目默认 |
| LAN 桥 | `br-lan`，端口 `eth1`、`eth2`、`eth3` | 项目默认 |
| LAN 地址 | `192.168.100.1/24`，`proto static` | 项目默认 |
| LAN DHCP 服务 | `lan` 上的 dnsmasq，用上游地址池 | `/etc/config/dhcp`，不动 |
| WAN 入站 | 一条 `22/tcp` 规则，`allow_ssh_wan` | 项目默认 |
| SSH 绑定 | 删除 `dropbear.@dropbear[0].Interface`，守护进程在所有地址上监听 | 项目默认 |

端口集合不是常量，而是从 `/sys/class/net` 读出来的：每个带 `device` 链接的 `eth*` 去掉 WAN 设备后
全部入桥。所以两口机桥一个口，单口机降级为 LAN-only —— `wan` 段删除、唯一的口进 `br-lan`、环形日志写
`stage=net-seed result=ok mode=lan-only`。`board_detect` 提供 `system` 与上游那套命名，它不决定哪个口
是什么角色。

这些值本身来自 `/etc/net-defaults.conf`，构建期由 `scripts/ci/net-defaults.conf.in` 渲染：
`NET_WAN_DEV`、`NET_LAN_DEVS`、`NET_LAN_ADDR`、`NET_LAN_PREFIX`、`NET_WAN_SSH`。guest 里没有任何
地方自己发明一个值。要改"以后所有安装"的默认，改模板；要改"这一台"，用下面的 `uci`。

## 核对结果

```sh
ip -brief address                          # br-lan 上有 192.168.100.1/24，eth0 要去租约
uci show network | sed -n '/br-lan/,+3p'   # 桥与端口列表
uci show firewall | grep allow_ssh_wan     # 唯一的 WAN 例外
uci show dropbear | grep Interface         # 无输出：守护进程未绑定接口
nft list ruleset | grep 'dport 22'         # fw4 实际渲染出的东西
```

全新安装每次启动都会往 `/boot/ab/log/boot-0.log` 里的环形日志写一行：

```
stage=net-seed wan-ssh=open
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

地址没出现时先读这一行；日志格式与读取它的 `wan-present` 探针见
[lifecycle.zh-CN.md](lifecycle.zh-CN.md)。

## 改 LAN 网段

`192.168.100.1/24` 刻意避开 `192.168.1.0/24` —— 几乎所有家用路由出厂就是这个网段，避开之后设备挂在
后面才不会撞。若你要接入的网络自己就占用了 `192.168.100.0/24`，改其中一边。`ipaddr` 带前缀长度，
也就是生成逻辑写下的形式：

```sh
uci set network.lan.ipaddr='192.168.8.1/24'
uci commit network
/etc/init.d/network reload
```

客户端会继续用旧租约直到过期，所以直接去新地址重连，不必等旧地址回应。改动落在可写层：升级不覆盖，
生成逻辑也不会再在它上面跑一次。

## 改 WAN 网口

`ip -br link` 给出接口名；逐个网口插网线，看哪一行变成 `UP`，就能在自己板子上确定对应关系。要把 WAN
换成 `eth3`、把 `eth0` 交给 LAN，先问清楚哪一段 `config device` 是 `br-lan` 桥：

```sh
uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='br-lan'$/\1/p"
# 打印形如 @device[0] —— 下面两条端口命令用它
```

```sh
uci set network.wan.device='eth3'
uci del_list 'network.@device[0].ports=eth3'
uci add_list 'network.@device[0].ports=eth0'
uci commit network
/etc/init.d/network reload
```

两处必须一起改：只改 `wan.device` 会把 `eth3` 留在 LAN 桥里、同时让 `eth0` 闲着。单口机没有第二个口可以
指给 `wan`，它本来就落在上面说的 LAN-only 默认上。

## WAN 暴露面与关法

WAN 侧只接受 `22/tcp`，此外只有上游 `wan` zone 本来就放的东西 —— DHCP 客户端、ICMP 与 ICMPv6、IGMP 与
MLD、IPsec。LuCI 的 `80/tcp` 不放行：挡住它的是防火墙，`wan` zone 仍是 `input 'REJECT'`。

这条规则默认开，是因为这台机器的典型部署位置：挂在主路由下面，在它自己有地址之前，唯一入口就是你刚插上
的那根网线。一条 `22/tcp` 的定向例外把这件事变成 `ssh root@<地址>`；关着就意味着每次改动都要搬来 HDMI 线
和键盘。代价是真实的 —— 共享网络的 WAN 侧并不一定干净，而 `dropbear` 用的密码认证继承的是镜像里那个 root
密码 —— 所以只要从 LAN 能进机器，就把它关掉：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

LuCI 里同一条规则就是 **网络 → 防火墙 → 通信规则** 下名为 `allow_ssh_wan` 的那一项，删掉后点
**保存并应用**。然后确认它真的没了：

```sh
uci show firewall | grep allow_ssh_wan     # 无输出
nft list ruleset | grep 'dport 22'         # 无输出，除非另有规则开了 22
```

关掉不影响 LAN 侧，SSH 守护进程仍未绑定接口，所以从 LAN 的 SSH 继续可用。

## 生成过程不动的东西

- `/etc/config/dhcp`：LAN 的 DHCP 服务是上游的，保持开启。
- `/etc/config/firewall` 的 zone：`lan` 仍是 `input 'ACCEPT'`，`wan` 仍是 `input 'REJECT'`。只追加一条
  规则，且只在那次真正生成网络的启动里追加。
- `/etc/config/uhttpd`：LuCI 按上游配置监听，把它挡在 WAN 之外的是防火墙。
- `/etc/config/system`：`config_generate` 生成什么就保留什么 —— hostname `ImmortalWrt`、timezone `GMT0`。
  想要别的就在 LuCI 里改。

## 变体：构建期关闭 WAN 22

`allow_ssh_wan` 这条规则在不在，是构建期常量，不是运行期决定。`scripts/ci/net-defaults.conf.in` 用
`@...@` 占位符承载 `NET_*` 各行；构建时渲染进平台层的 `/etc/net-defaults.conf`，占位符没被替换则构建
失败，而不是把字面量 `@NET_...@` 发到设备上。

| `NET_WAN_SSH` | 效果 |
|---|---|
| `open`（本次发布） | 追加 `22/tcp` 规则并解除 SSH 的接口绑定 |
| `closed` | 两件事都不做，WAN 入站与上游完全一致 |

"关"的变体就是同一条流水线带 `CI_NET_WAN_SSH=closed` 跑一次，不改代码。本次发布只出"开"的变体；
真机首启的操作步骤见 [docs/install.zh-CN.md](install.zh-CN.md)。
