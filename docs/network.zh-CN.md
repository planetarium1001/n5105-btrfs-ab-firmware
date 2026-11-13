# 首启默认网络

[English](network.md) | **简体中文**

刷完盘的机器起来就有网，不需要有人在 console 前操作。配置不是烘进镜像的：首次启动用与官方
ImmortalWrt 镜像相同的上游程序生成，再在这个结果上叠加本项目默认值。之后你的任何改动都在可写层，
不会被再次覆盖。

## 生成时机

两个钩子，顺序固定：

```
S15 ab-boot            A/B 记账，不碰网络
S16 ab-net-seed        board_detect + config_generate + 项目默认（第一次尝试）
S20 network            netifd 拉起 br-lan 与 wan，dnsmasq 在 LAN 发地址
S25 ab-net-reconcile   只在 S16 没能完成时再试一次
```

决定它跑不跑的是**标记文件** `/etc/config/.ab-net-seed`，不是"配置文件存不存在"。这个区别不是吹毛求疵：
上游的 `99-default-settings` 在 `S10`（比本钩子早）就会写出一个只含 `config globals` 的
`/etc/config/network`。信"文件存在"的实现会永久跳过自己——`v0.0.7` 的真机就是这样：它一直保留
生成器的默认值（`br-lan{eth0}`、`192.168.1.1/24`、`wan eth1`），完全没有 WAN，每次启动都只写
`result=skip reason=network-present`。

判定规则：

- 标记在 → `result=skip reason=seeded`，不读也不写；
- 完全没有配置 → `board_detect` + `config_generate`，再叠加项目默认；
- 配置仍带着**未被动过的上游指纹**（`192.168.1.1/24` 且桥只有一个口 `eth0`）→ 原地修复，
  因为 `v0.0.7` 的机器正是卡在这个状态；
- 其它任何配置 → `result=skip reason=foreign-config`，写标记让后续启动不再来碰，文件一个字不改。

`S16` 时网口可能还没出现（N5105 的 igc 口在十三秒左右才注册）。拿不到 `eth*` 时**不写标记**并记
`result=pending reason=no-ethernet`；`S25 ab-net-reconcile` 在 netifd 之后重试并 reload 一次，
于是同一次开机就能自愈。任何失败都不阻塞启动：原因进环形日志，`rcS` 继续。

每次尝试还会把结果写到 ESP 的 `ab/net.json`：`result`、`mode`、`wan`、`lan_ports`、看到的网口、
标记是否存在——拔下盘就能解释这台机器的网络状态，不用开机能进系统。

## 默认值

| 项目 | 取值 | 由谁写 |
|---|---|---|
| WAN 设备 | `eth0` | 项目默认 |
| WAN 协议 | `dhcp`，外加挂在它上面的 `wan6`（`dhcpv6`，`@wan`） | 项目默认 |
| LAN 桥 | `br-lan`，端口 `eth1`、`eth2`、`eth3` | 项目默认 |
| LAN 地址 | `192.168.100.1/24`，`proto static` | 项目默认 |
| LAN DHCP 服务 | `lan` 上的 dnsmasq，用上游地址池 | `/etc/config/dhcp`，不动 |
| WAN 入站 | 没有；只有 `-wan-ssh` 镜像才加一条 `22/tcp` 规则 `allow_ssh_wan` | 项目默认 |
| SSH 绑定 | 上游的绑定 `lan`；`-wan-ssh` 镜像才删除 `dropbear.@dropbear[0].Interface`，让守护进程在所有地址上监听 | 项目默认 |

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
uci show firewall | grep allow_ssh_wan     # 默认镜像无输出；-wan-ssh 镜像上一条规则
uci show dropbear | grep Interface         # -wan-ssh 镜像上无输出：只有那份镜像解绑
nft list ruleset | grep 'dport 22'         # 除非镜像就是被构建成放行，否则什么都没有
```

全新安装每次启动都会往 `/boot/ab/log/boot-0.log` 里的环形日志写一行：

```
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

`-wan-ssh` 镜像会在这行之前多打四行 —— `wan-ssh=open port=22 proto=tcp` 与三条 `wan-ssh-close:`
指引 —— 默认镜像永远没有这几行。它们的有没有，本身就是"这台机器跑的是哪份镜像"的证据。

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

默认镜像的 WAN 侧什么都不接受，只有上游 `wan` zone 本来就放的东西 —— DHCP 客户端、ICMP 与 ICMPv6、IGMP 与
MLD、IPsec。LuCI 的 `80/tcp` 不放行：挡住它的是防火墙，`wan` zone 仍是 `input 'REJECT'`。这里没有
`22/tcp` 规则，所以从 WAN 侧发起的 SSH 在碰到 `dropbear` 之前就被拒了。

有一个镜像不一样。`n5105-ab-<upstream>-install-wan-ssh.img.gz` 只多一条规则 `allow_ssh_wan`（`22/tcp`），
并删除 `dropbear.@dropbear[0].Interface`，让守护进程能接住这条规则放行的连接。它是为这台机器常见的处境准备
的 —— 挂在你看不见的主路由下面，没有键盘也没有显示器 —— 而代价是真实的：共享网络的 WAN 侧并不一定干净，
而 `dropbear` 用的密码认证继承的是镜像里那个 root 口令。

所以这是只有便利镜像才需要、默认镜像根本没有的一步：只要从 LAN 能进机器，就把规则关掉。

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

关掉不影响 LAN 侧，两种镜像下从 LAN 的 SSH 都继续可用。

## 生成过程不动的东西

- `/etc/config/dhcp`：LAN 的 DHCP 服务是上游的，保持开启。
- `/etc/config/firewall` 的 zone：`lan` 仍是 `input 'ACCEPT'`，`wan` 仍是 `input 'REJECT'`。最多追加一条
  规则 —— 只有镜像渲染时 `NET_WAN_SSH=open` 才有 —— 且只在那次真正生成网络的启动里追加。
- `/etc/config/uhttpd`：LuCI 按上游配置监听，把它挡在 WAN 之外的是防火墙。
- `/etc/config/system`：`config_generate` 生成什么就保留什么 —— hostname `ImmortalWrt`、timezone `GMT0`。
  想要别的就在 LuCI 里改。

## 两份构建：WAN 22 默认关闭，需要时才开

`allow_ssh_wan` 这条规则在不在，是构建期常量，不是运行期决定。`scripts/ci/net-defaults.conf.in` 用
`@...@` 占位符承载 `NET_*` 各行；构建时渲染进平台层的 `/etc/net-defaults.conf`，占位符没被替换则构建
失败，而不是把字面量 `@NET_...@` 发到设备上。

| `NET_WAN_SSH` | 效果 | 镜像 |
|---|---|---|
| `closed`（默认） | 不加规则、守护进程保持上游绑定，WAN 入站与上游完全一致 | `n5105-ab-<upstream>-install.img.gz` |
| `open` | 追加 `22/tcp` 规则并解除 SSH 的接口绑定 | `n5105-ab-<upstream>-install-wan-ssh.img.gz` |

两者都不是运行期开关，也没有命令能把一个变成另一个：这个值在构建时就被烤进平台层了。"开"的那份就是同一条
流水线带 `CI_NET_WAN_SSH=open` 跑一次，与默认镜像只差一个渲染值，发布阶段会在它的文件名后加 `-wan-ssh`，
这样下载页上两份文件不可能被看混。它们吃的是同一批上游输入、发的是同一个升级载荷。
怎么在两者之间选、以及真机首启的步骤见 [docs/install.zh-CN.md](install.zh-CN.md)。
