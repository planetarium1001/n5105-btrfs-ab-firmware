# 安装与升级

这篇是运维视角：怎么把镜像写到盘上、真机第一次启动在控制台上做什么、把机器接进网络之前要核对什么、运行中怎么升级、出问题怎么退回去。它按"手边有一台带显示器、键盘和网线的 N5105"来写，所以每一步都给出命令和该看到的输出。设计细节见
[partitions.md](partitions.md)、[boot-overlay.md](boot-overlay.md)、
[network.md](network.md) 与 [lifecycle.md](lifecycle.md)。

## 需要准备什么

一个发布目录里有四个文件：

| 文件 | 用途 |
| --- | --- |
| `n5105-ab-<upstream>-install.img.gz` | 完整磁盘镜像，每台机器写一次 |
| `n5105-ab-<upstream>-upgrade.tar` | 升级载荷，供 `ab-upgrade` 使用 |
| `SHA256SUMS` | 上面两个文件的摘要 |
| `release-notes.md` | 版本、上游输入与本次构建的验收判据行 |

写盘之前先校验：

```sh
sha256sum -c SHA256SUMS
```

`sha256sum -c` 会给每个产物打印一行 `<文件>: OK`。出现别的结果就说明下载坏了：什么都别写，重新取一份，因为这种载荷即使写进去，后面的 `ab-upgrade` 也会以
`reason=digest-mismatch-<成员>` 拒绝。

真机测试还要准备：显示器与 USB 键盘（N5105 v5 板子带 HDMI）、一根接上游路由器的网线、另一根网线加一台笔记本用于 LAN 侧、以及记录用的纸笔。验收清单里那张端口对照表就是本次结果的一部分。

### 该写哪一个文件

只有装**生产启动 initramfs** 的镜像才能在真机上启动。同一次流水线会产出**两个**这样的镜像，它们之间只差一个渲染值：WAN 侧的 `22/tcp` 放不放行。

| 位置 | 名称 | 用途 |
| --- | --- | --- |
| GitHub release | `n5105-ab-<upstream>-install.img.gz` | 写这个。完全没有任何 WAN 规则，与上游 ImmortalWrt 镜像同一个姿态 |
| 同一 tag 的便利构建 | `n5105-ab-<upstream>-install-wan-ssh.img.gz`（该次运行里的产物名为 `image-install-wan-ssh`） | 同一份镜像，只多一条 `allow_ssh_wan`：WAN 侧接受 `22/tcp`。只在「从 LAN 够不到、也给不了键鼠」的机器上用 |
| Actions 产物（tag 构建） | `image-install`、`image-install-wan-ssh` | 还没有被发布阶段命名的这两份构建；便利构建压缩包里那个文件名仍是 `n5105-ab-image.img.gz` |
| Actions 产物（每次构建） | `image-probe` | **永远不要写它**：它是 S1 模块探针，找 `/dev/vda`，在真机上会直接关机 |

两个镜像来自同一批上游输入、共用同一个 payload：唯一不同的值是 `NET_WAN_SSH`，所以内核、rootfs、平台层与升级载荷逐字节相同。便利镜像是一条「进得去」的路，不是更安全的默认值 —— 它在一台 root 可能还没有口令的机器上放开 WAN 侧的 `22/tcp`，而且它自己会在控制台上说出来。

只给那台否则进不去的机器用便利镜像，并且一确认 LAN 侧能连就关掉规则。出口有三条，首启会把三条都打出来：

```sh
# 1. 在机器上，就通过你正在用的这条规则
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

```text
# 2. LuCI：网络 → 防火墙 → 通信规则 → 删掉 allow_ssh_wan
# 3. 重新写进「关」的那份镜像：n5105-ab-<upstream>-install.img.gz
```

这条规则只在「生成网络配置」的那次启动上被添加，之后不再叠加：升级带着可写层一起走、不会重新应用默认值，所以刷了「关」镜像的机器之后不会自己长出这条规则，而刷了便利镜像的机器会一直留着它，直到你删掉。

文件名带的是板型、产品线、上游基线与角色，不带我们自己的发版计数器 —— 那个在 GitHub release 上。
更早的发布把同一份字节叫 `n5105-ab-<platform>-<upstream>.img.gz` 与 `.tar`；如果你的脚本还在用
那个模式，它就是同一个文件，只是在扩展名前多了 `-install` 或 `-upgrade`。

镜像自己会说明身份：挂上 ESP（`PARTNAME ab-esp`，FAT），读 `ab/image.json` —— `"kind": "boot"`
才是可写的，`"kind": "probe"` 是 CI 夹具。发布作业会拒绝 `kind` 不是 `boot` 的镜像，并且会把
镜像里的 `initrd-a` 解出来确认它是生产 init。

镜像是普通 GPT 布局：一个 EFI 系统分区、两个槽文件系统、一个存放可写层的共享 btrfs 分区。只支持 x86-64 UEFI
启动，不支持传统 BIOS。目标机器需要 N5105 v5 的板型与四分区布局，或者任何一台你想用来测试的 x86-64 机器，因为镜像本身是自包含的。

## 写入镜像

写镜像会毁掉目标盘上的全部内容。先确认盘符，再写：

```sh
lsblk -o NAME,SIZE,MODEL
gunzip -c n5105-ab-<upstream>-install.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo sync
```

`dd` 之前先读 `lsblk`：给 `of=` 的设备必须就是你要写的盘，容量要对得上，而且在那一刻机器上没有别的东西叫这个名字。`dd` 退出码 0 并打印字节数，`sync` 返回表示写入已经离开内核。这两步之间不要断电。

结果是 514 MiB、四个 128 MiB 分区。其余都不用手工创建：ESP 上带着两个槽各自的内核与 initramfs，引导配置已经按已提交槽渲染好，
两个槽的文件系统也各带一份相同的根文件系统。

想写到文件里做虚拟机测试：

```sh
gunzip -c n5105-ab-<upstream>-install.img.gz > test.img
qemu-system-x86_64 -machine q35 -m 1G -bios /usr/share/OVMF/OVMF_CODE.fd \
  -drive file=test.img,if=virtio,format=raw -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0 -nographic
```

## 控制台上的首次启动

接上显示器和键盘再开机。从 `0.0.7` 起首次启动会自己写出网络配置，所以控制台不再是进新盘的唯一通道；但一台新机器的第一次启动仍然应该接控制台，理由有三条：

* 生成失败只在控制台上报，形式是 `stage=net-seed result=fail reason=...`，没有地址的机器在别处是沉默的；
* 端口与物理口的对应关系、各口的 MAC 地址只能在机器上看，而它们决定了以后每一次挪网线的判断；
* 如果 `192.168.100.0/24` 和机器要接入的网络撞了，必须先在控制台上改掉，否则哪里都连不进去。

板子如果有 UART 排针，串口（115200 8N1）是更好的通道，因为黑屏时它还在。这块 N5105 v5 是否引出了排针尚未确认；HDMI 加 USB 键盘总是可用的。

机器从 ESP 启动，initramfs 用 overlayfs 组合出根，再切到真实系统。一分钟内健康检查跑完，运行中的槽被提交。登录之后在控制台上：

```sh
ab-slot status
ab-slot log | grep net-seed
```

刚写好的盘上，第二条会打印种子的结论行：

```
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

便利镜像会在它前面多打四行 —— 它开了什么，以及三条关闭路径：

```
stage=net-seed wan-ssh=open port=22 proto=tcp
stage=net-seed wan-ssh-close: LuCI -> Network -> Firewall -> Traffic Rules -> delete allow_ssh_wan
stage=net-seed wan-ssh-close: or uci delete firewall.allow_ssh_wan && uci commit firewall && /etc/init.d/firewall reload
stage=net-seed wan-ssh-close: or reflash the closed image (n5105-ab-<upstream>-install.img.gz)
```

`ab-slot log | tail` 是同一次启动的快速读法：最后几行就是健康检查与决定（`stage=healthcheck-done`，然后是 `stage=commit`）。

之后再启动只打印一行：`stage=net-seed result=skip reason=network-present`。幂等就是这件事：只有"发现没有 `/etc/config/network`"的那次启动会跑生成，之后再也不跑——你自己用 `uci` 改的东西、升级带过来的配置也因此不会被覆盖。

健康机器上 `ab-slot status` 只打印一行：

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid boot=ok esp=ok packages=unknown packages_reason=unknown
```

字段顺序就是 `ab-slot` 打印的顺序，每个字段都是一个 token：

| 字段 | 说的是什么 |
| --- | --- |
| `p4=` | `ok` 表示可写分区已挂载，`degraded` 表示没挂上 |
| `data=`、`docker=`、`swap=` | 平台层挂载在 p4 上的三个子卷，各自 `ok` 或 `missing` |
| `next=` | GRUB 下次会启动的槽，从 `boot/grub/ab-slot.cfg` 读回；想知道"重启会发生什么"就看这一个字段 |
| `disk=`、`method=` | 这台机器是哪块盘，以及这个结论是怎么得出的 |
| `boot=` | 这次启动是怎么起来的，取本次启动的环日志：`degraded` 表示可写层是 tmpfs、写下去活不过重启；`unknown` 表示没有可读的环日志 |
| `esp=` | initramfs 对它挂载的那个 ESP 的判定：`ok`、`dirty`、`unreadable`，没有任何记录时是 `unknown` |
| `packages=`、`packages_reason=` | 上一次升级留下的包元数据判定；从没升级过的盘上两者都是 `unknown`，这是诚实的说法，不是好的说法 |

如果 `p4` 显示 `p4=degraded`，先读下面的降级小节，再做别的事。`packages=` 在下面有单独一节：它说的是
`apk` 能不能给这个槽正在跑的内核装模块。

种子失败时启动照样完成，原因留在控制台上：`stage=net-seed result=fail reason=board-detect`、
`reason=config-generate`、`reason=config-generate-empty` 或 `reason=no-ethernet`。要先进机器、不等排障，就手工给一个口配地址——这条不留存，正是它的用处：

```sh
ip link set eth1 up
ip addr add 192.168.100.1/24 dev eth1
```

把笔记本插到同一个口，设成 `192.168.100.2/24`，就能访问 `192.168.100.1`。一旦手工写出 `/etc/config/network`，种子的活儿就永久结束了：文件存在，之后每次启动都不再碰它。进去以后从 LuCI 修配置，或者干脆重刷、从默认值重新开始。

## 已知限制

* **`0.0.7` 之前刷的镜像首启没有网络。** `0.0.6` 及更早的版本替掉了上游负责生成 `/etc/config/network` 的 preinit，所以刚写好的盘在任何口上都没有地址、LAN 上没有 DHCP 服务，`dropbear` 还绑在一个不存在的接口上。唯一进去的路是控制台加手工 `uci`。这类镜像上健康检查还会报 `probe=wan-present result=fail`、永远写不出 `stage=commit`，但机器照样起来（`action=stay`）。`0.0.7` 是第一个自己生成网络的发布：重新刷镜像，不要在老镜像上打补丁。
* **口名是内核给的，不是丝印给的。** `eth0` 到 `eth3` 不一定对应机壳上的标号，镜像里也没有任何猜硬件的地方。每台机器都要做一遍下面的对照，并记下来。
* **单口机不是路由器。** 种子会把它降级成 LAN-only（`stage=net-seed result=lan-only`）：唯一的口进 `br-lan`，`wan` 段被删掉。于是 `wan-present` 探针找不到 WAN 设备，那次启动不会提交该槽（`action=stay`）；LAN 侧照常可用。
* **默认值只叠加一次。** 它们属于"生成配置的那次启动"。升级带着可写层一起走，不会重新叠加——这是有意的（你的改动优先），代价是改过的默认值只对重新写盘的机器生效。
* **便利镜像会在 WAN 侧放开 `22/tcp`，而且没有东西替你关它。** 只有 `n5105-ab-<upstream>-install-wan-ssh.img.gz` 带 `allow_ssh_wan` 规则；默认镜像一条 WAN 规则都没有。在便利镜像上，那条规则与解绑的 `dropbear` 会一直留着，`dropbear` 也会用镜像里带的 root 口令接受密码认证。LAN 侧一旦能连，就把它关掉。

## 真机上的网络默认值

下面是本版在"发现没有 `/etc/config/network`"的那次启动上生成的内容：

| 项 | 值 | 由谁写入 |
| --- | --- | --- |
| WAN 设备 | `eth0`，`proto dhcp`，另有 `@wan` 上的 `wan6` | 项目默认值叠加在 `config_generate` 之上 |
| LAN 桥 | `br-lan`，端口 `eth1`、`eth2`、`eth3` | 项目默认值 |
| LAN 地址 | `192.168.100.1/24`，`proto static` | 项目默认值 |
| LAN DHCP 服务 | dnsmasq 在 `lan` 上，用上游的地址池 | `/etc/config/dhcp`，未改动 |
| WAN 入站 | 没有；只有 `-wan-ssh` 镜像才有一条规则 `allow_ssh_wan`、`22/tcp` | 项目默认值 |
| SSH 绑定 | 上游的绑定 `lan`；只有 `-wan-ssh` 镜像会把它置空 | 项目默认值 |
| 主机名、时区 | `ImmortalWrt`、`GMT0` | `/bin/config_generate` |

端口集合来自 `/sys/class/net`：带 `device` 链接的每个 `eth*` 除去 WAN 设备，全部进桥。没有任何写死的名字，所以双口机就只桥一个口。

改 LAN 网段——这条能跨升级存活，种子也不会再覆盖它：

```sh
uci set network.lan.ipaddr='192.168.8.1'
uci commit network
/etc/init.d/network reload
```

客户端会一直用到手的租约到期，所以直接去新地址连，别等旧地址回应。

改哪个物理口做 WAN。`ip -br link` 给出接口名，下面的对照小节告诉你哪个名字属于哪个口。两处改动必须一起做，只改 `wan.device` 会把新 WAN 口留在 LAN 桥里、旧口空着：

```sh
uci set network.wan.device='eth3'
uci del_list network.@device[0].ports='eth3'
uci add_list network.@device[0].ports='eth0'
uci commit network
/etc/init.d/network reload
```

在 `-wan-ssh` 镜像上，关掉 WAN 例外 —— 在控制台或 SSH 上一条 `uci` 块：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

LuCI 里同一条规则是 **网络 → 防火墙 → 通信规则**（Network → Firewall → Traffic Rules）里名为 `allow_ssh_wan` 的那一条：删掉它，按 **保存并应用**。然后确认它真的没了：

```sh
uci show firewall | grep allow_ssh_wan     # 没有输出
```

关掉它不影响 LAN 侧，从 LAN 的 SSH 照旧能用，因为 `dropbear` 仍在桥上监听。这里的每个默认值同时也是构建期常量：平台层里的 `/etc/net-defaults.conf` 由
`scripts/ci/net-defaults.conf.in` 渲染而来（`NET_WAN_DEV`、`NET_LAN_DEVS`、`NET_LAN_ADDR`、`NET_LAN_PREFIX`、`NET_WAN_SSH`）。默认镜像就是
`NET_WAN_SSH=closed` 那份渲染；便利镜像是同一条流水线带 `CI_NET_WAN_SSH=open` 跑一次，发布阶段会在它的文件名后加 `-wan-ssh`。完整说明见 [network.md](network.md)。

## 验收清单

在把机器交出去之前逐条跑一遍：

| 检查项 | 命令 | 期望 |
| --- | --- | --- |
| 布局完好 | `ab-slot status` | 一行输出，`p4=ok`，有已提交槽 |
| 本次启动被记录 | `ab-slot log` | 有 `stage=boot`、`stage=btrfs-check result=ok`、`stage=commit` |
| 扩容有结论 | `ab-slot log` | `stage=grow result=done`（运行期补做完则是 `stage=resize result=ok`） |
| 网络是生成出来的 | `ab-slot log` 里找 `net-seed` | 首次启动是 `result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24`，之后是 `result=skip reason=network-present` |
| LAN 有地址 | `ip -brief address` | 有一条 `br-lan`，带 `192.168.100.1/24` |
| WAN 拿到租约 | `ip -brief address` | `uci get network.wan.device` 指的设备（`eth0`）上有一个落在上游路由网段里的地址 |
| 接口配置就是本版发的这套 | `uci show network` | `network.wan.device='eth0'`、`network.wan.proto='dhcp'`、`network.lan.device='br-lan'`、`network.lan.proto='static'`、`network.lan.ipaddr='192.168.100.1/24'`，`br-lan` 设备段上有 `ports='eth1' 'eth2' 'eth3'` |
| WAN 只在你要过的时候才暴露 22/tcp | `nft list ruleset` 里找 `tcp dport 22` | 默认镜像上一条都没有；`-wan-ssh` 镜像上是 `wan` 入站链里一条匹配 `tcp dport 22` 的规则，zone 对其它一切仍然拒绝 |
| LAN 口能发地址 | 把笔记本插到 `eth1`..`eth3` 任一口，设成 DHCP | 拿到 `192.168.100.0/24` 里的地址，网关 `192.168.100.1` |
| 工具可用 | `btrfs --version` | 打印 `btrfs-progs` 版本行 |
| 可写层可见 | `btrfs subvolume list /mnt/p4` | 包含 `ab-slot status` 报告的那一层 |
| 防火墙已加载 | `nft list table inet fw4` | 有表，不是报错 |
| 回收无事可做 | `ab-slot gc --dry-run` | 没有层被列为待删 |
| 备槽完好 | `ab-slot pending b` 再 `ab-slot abandon` | 前者成功，后者清空 |
| 下次启动符合预期 | `ab-slot next` | 上面那次 abandon 之后是 `next=<已提交槽>` |

`ip -brief address` 里不会有 `wan` 这个接口：WAN 接口绑在设备上（`option device eth0`），地址就显示在 `eth0` 上。所以 WAN 那一行要先用 `uci` 读出设备名。`nft list ruleset` 更全也更慢，接一个
`grep -A3 'dport 22'` 就够留下值得回传的那一小段 —— 默认镜像上是空输出，而空输出正是通过。

最后一行的意义：`ab-slot pending` 会拒绝内核或 initramfs 不在 ESP 上的槽，所以这一步失败说明的是备份槽的载荷缺失，
而不是当前运行的槽有问题。

## 把四个物理口对上 eth0..eth3

每台机器做一次，把表填进证据包。这是不靠猜就断定哪个口是 WAN 的唯一办法：

```sh
ip -brief link
for d in /sys/class/net/eth*; do
    printf '%s carrier=%s mac=%s\n' "${d##*/}" "$(cat "$d/carrier")" "$(cat "$d/address")"
done
```

先把所有网线拔掉：每个 `eth*` 都显示 `DOWN`、`carrier=0`。插一根线到某一个口，记下机壳上的标号，再跑一遍上面两条命令，看哪个接口变成 `UP,LOWER_UP` 且 `carrier=1`。四个口各来一遍，然后填表：

| 物理口（机壳标号） | 接口 | MAC | 种子给出的角色 |
| --- | --- | --- | --- |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |

默认 `eth0` 是 WAN，其余 `eth*` 都是 `br-lan` 的端口，所以角色列对名叫 `eth0` 的接口写 `WAN`，其余写 `LAN`。如果你希望朝上游路由器的那只口不是内核叫 `eth0` 的那个，要么用上面那段
`uci` 换角色，要么在下次构建时改 `NET_WAN_DEV`——并且在报告里写清用了哪种，因为这两种做法得到的不是同一台机器。

## 从 LAN 侧连 LuCI 与 SSH

从插在 LAN 口的笔记本、或 `192.168.100.0/24` 里任何一台客户端，打开 `http://192.168.100.1`。LuCI 监听 `80/tcp`，全靠防火墙把它挡在 WAN 外面；本版 WAN 侧没有任何 HTTP 例外。镜像沿用上游的 root 账号和空密码：用 `root` 登录、直接回车，然后在机器离台之前设好密码——LuCI 里是 **系统 → 管理权**，或者控制台上 `passwd`。

SSH 是同一个账号，走 `22/tcp`：

```sh
ssh root@192.168.100.1
```

在便利镜像上，只要 `allow_ssh_wan` 规则还在，从 WAN 侧同样能登：`ssh root@<上游路由分给 eth0 的地址>`。只验证一次 —— 那份镜像的意义就在于机器挂在你进不去的那台路由器后面时还能连上 —— 然后从 LAN 侧的会话里关掉它：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

默认镜像上，从 WAN 侧的尝试根本到不了守护进程：连接被 `wan` zone 拒掉，没有口令提示可答。

如果在便利镜像上规则还在、WAN 侧却被拒，就去看守护进程的绑定：`uci show dropbear` 里不该有 `Interface` 选项（要是它又出现了，`uci delete
dropbear.@dropbear[0].Interface; uci commit dropbear`），`logread | grep
dropbear` 会告诉你守护进程到底有没有在监听。

## 升级运行中的系统

升级写入非活动槽并把它标记为待验证，全程不碰运行中的槽，所以出问题机器照样能用。

能访问发布 feed 的机器自己去取 payload：`ab-upgrade --feed-check` 报告上游有什么，
`ab-upgrade --feed` 下载、校验，然后走这条完全相同的路径安装。配置文件、三个版本号、
风险级别以及各自的确认强度见 [update.zh-CN.md](update.zh-CN.md)。

```sh
ab-upgrade --check /root/n5105-ab-<upstream>-upgrade.tar
ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar
ab-slot status
ab-slot conflicts
ab-slot log --upgrade
```

`--check` 只校验、什么都不写，所以坏载荷在动非活动槽之前就被发现。真正写入时 `ab-upgrade` 再校验一遍：manifest 形状、逐成员摘要、initramfs 里所有模块是否来自同一次内核构建、可写分区余量、
载荷带的引导器、以及冲突报告。拒绝时退出状态为 74 且什么都不写。成功后状态里另一个槽变成 `pending`，
`ab-slot status` 的 `next=` 也会指向它，下次启动会试它：

* 启动后对新槽跑健康检查；
* 全部探针通过则提交该槽，机器留在新槽上；
* 任一探针失败则放弃待验证槽，重启回到已提交槽；
* 新槽在 boot initramfs 阶段就失败时，失败路径会自己清掉 `pending` 再关机（日志里
  `action=fail-safe-abandon`），下次启动回到已提交槽，而不是反复重试那个坏槽。

真机上第一次升级请补两条断言：重启前 `ab-slot status` 显示 `pending=<另一个槽>` 与 `next=<另一个槽>`；重启后那个槽是
`committed=`、`pending=none`、`generation=` 变大、`p4=ok`。载荷带的是一版不同的上游版本时，`upper=` 也会跟着变，因为层的名字取自它被种下的那个版本。`/data` 下的文件两个槽共用，原地不动。

如果槽已经暂存好、但 `boot/grub/ab-slot.cfg` 没指向它，升级会以 `reason=next-boot-not-<槽>` 失败：
少了这个文件机器会一直启动旧槽，升级永远试不到。

载荷和你都改动过的文件会列在 `ab-slot conflicts` 里。它们从不阻断升级：载荷照样写入新文件，报告告诉你该看哪几个。

### 选项

选项可以出现在命令行任何位置：`ab-upgrade --no-bootloader /root/n5105-ab-<upstream>-upgrade.tar`
与 `ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar --no-bootloader` 是同一条命令。给两个位置参数，
或者 `--bootloader` 与 `--no-bootloader` 同时给，都是用法错误，退出 2，还没读任何东西就结束。

| 选项 | 什么时候用 | 代价是什么 |
| --- | --- | --- |
| （不带） | 每一次普通升级 | 载荷带引导器成员就写 ESP 的加载器与菜单；没带就只装系统，并打印 `bootloader absent-in-payload` |
| `--bootloader` | 这个载荷本该带引导器，你要把这条要求变成强制 | 载荷没有引导器成员就以 `74` 拒绝，token 是 `payload-without-bootloader`，而不是"不带引导器装上去" |
| `--no-bootloader` | ESP 是 `dirty` 或 `unreadable`，而你需要先把新系统装上去；或者你想先看看纯系统层面的变化 | 完全不碰 ESP（`bootloader skipped-by-flag`），所以带坏加载器的载荷也照样装。写引导器是机器唯一无法自愈的操作，正因如此必须留一条绕过去的路 |
| `--force` | 重装同一个版本，用来修一个槽 | 跳过 `74 payload-already-installed` 这道闸，于是留在机器上的载荷可以拿你正在试的槽去覆盖健康槽 |
| `--check` | 每次安装之前 | 只校验、什么都不写：不写槽、不写 `ab/state.json`、ESP 上也不放冲突报告。引导器的规则同样跑（成员在不在、manifest 块全不全、两个摘要、ESP 余量、`esp=` 健康度），所以校验过了而安装会拒绝的情况不存在 |

### 退出码

| 退出码 | 含义 | 之后盘上是什么状态 |
| --- | --- | --- |
| `0` | 装好了，或 `--check` 校验通过 | 非活动槽已暂存并标记待验证，`next=` 指向它，运行中的槽没被动过 |
| `1` | 校验通过之后某个执行步骤失败 | 槽可能写了一半；这次运行写过的引导器会先从 `@boot-backup/<version>` 回滚。连这次回滚都失败时，ESP 可能已经带着新加载器而槽还是旧的那个，所以它必须以失败而不是拒绝的形式离开 |
| `74` | 写之前就被拒绝 | 槽里什么都没写，`ab/state.json` 也没变；被拒绝的是载荷，或机器的状态 |

每次拒绝都打印一行，并镜像到控制台：`74` 是 `ab-upgrade: refused, reason=<token>`，`1` 是
`ab-upgrade: failed, reason=<token>`。`ab-slot log --upgrade` 打印的是 ESP 上的 `ab/log/upgrade.log`，
而那个文件没有任何东西替你写，想把这次运行留在盘上就自己接住输出：

```sh
{ ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar 2>&1; echo "exit=$?"; } | tee /boot/ab/log/upgrade.log
```

花括号是关键：写成 `ab-upgrade ... | tee` 时，`$?` 是 `tee` 的状态，不是升级的状态。

`bootloader-*` 这一族拒绝**全都退出 74**，因为引导器那一段跑在动槽之前：槽和 `ab/state.json`
与之前一模一样。真机上值得认得的几个：

| token | 含义 | 该怎么办 |
| --- | --- | --- |
| `payload-without-bootloader` | 给了 `--bootloader`，而载荷里没有引导器成员 | 换一个与选项相称的载荷，或者去掉这个选项 |
| `bootloader-digest-mismatch` | 成员里的加载器不是 manifest 描述的那个 | 载荷坏了：用 `SHA256SUMS` 验一遍再重新下载 |
| `bootloader-no-space` | ESP 装不下加载器、它的暂存副本和 `.prev` 副本 | 给 ESP 腾空间，或者用 `--no-bootloader` |
| `bootloader-esp-dirty` | initramfs 判定这次启动时 ESP 是脏的 | 在那上面写 FAT 就是把一台能用的机器换成一台没验证过的机器；`--no-bootloader` 是文档给出的绕法 |
| `bootloader-esp-unreadable` | initramfs 读不了这个 ESP | 先查分区，再用 `--no-bootloader` |

`74` 是对槽和状态文件的承诺，不是对 ESP 的承诺。写入已经开始时，`ab-upgrade` 会先从
`@boot-backup/<version>` 把 ESP 恢复回去再拒绝；如果连恢复都失败，日志里是
`upgrade: RESTORE ALSO FAILED, the ESP bootloader may be damaged`，下面的救援小节就是为这种情况写的。
`bootloader-rollback-failed` 是这一族里唯一退出 `1` 而不是 `74` 的，因为它意味着 ESP 可能已经带着新加载器、
而槽还是旧的那个。

这些 token 住在两个文件里。在仓库检出里，这一条就能把整族列出来：

```sh
grep -rho 'bootloader-[a-z-]*' platform/usr/sbin/ab-upgrade platform/lib/upgrade/platform.sh | sort -u
```

`bootloader-esp-` 是个前缀而不是 token：它后面那两个是 `bootloader-esp-dirty` 与 `bootloader-esp-unreadable`。

### 救援：ESP 上的引导器被写坏

引导器有两份副本，这是设计，放在两个地方各有各的理由：

| 位置 | 是什么 |
| --- | --- |
| `/boot/EFI/BOOT/BOOTX64.EFI.prev` 与 `/boot/boot/grub/grub.cfg.prev` | 上一次写入之前 ESP 上的字节，就放在新文件旁边，因此可写分区挂不上时也够得着 |
| `/mnt/p4/@boot-backup/<version>/` 加 `SHA256SUMS` | 两个文件加它们的摘要，放在可写分区上，补齐 `.prev` 可能缺的那份 |

`.prev` 是这么来的：写入在 rename 覆盖之前先把现有文件复制一份，那是取旧副本唯一还来得及的窗口。ESP 没地方
放这份副本时，日志会说 `could not keep ...prev (no room on the ESP?)`，写入照常进行——这就是 p4 上的备份
在每次尝试开头都重建的原因：它描述的永远是这次尝试可能要撤销的那个状态。`ab-upgrade` 只保留最近两份备份。

在机器上自救：GRUB 菜单里的 recovery 项用已提交槽加只读可写层启动，进去以后 ESP 就挂在 `/boot`。

```sh
esp=/boot
ls -l "$esp/EFI/BOOT/BOOTX64.EFI.prev" "$esp/boot/grub/grub.cfg.prev"
cp "$esp/EFI/BOOT/BOOTX64.EFI.prev" "$esp/EFI/BOOT/BOOTX64.EFI"
cp "$esp/boot/grub/grub.cfg.prev" "$esp/boot/grub/grub.cfg"
backup="$(ls -1dt /mnt/p4/@boot-backup/*/ | head -n 1)"
cd "$esp" && sha256sum -c "${backup}SHA256SUMS"
sync
```

`sha256sum -c` 那一行才是关键：它拿 ESP 上的两个文件与"动它们之前"记下的摘要比对，每个文件打印一个 `OK`。
别的输出都说明 `.prev` 不是记录里描述的那一份，那就改从 `@boot-backup/<version>/` 恢复，而不是从 `.prev`。

同一套步骤也可以把盘接到另一台 Linux 上做。下面这些节点名是这台机器的，USB 适配器可能把盘枚举成
别的名字，所以先确认：`blkid -L ESP` 打印的是文件系统 label 为 `ESP` 的那个分区的节点，p4 则是同一块盘
的第四个分区：

```sh
sudo blkid -L ESP                             # 要挂到 /mnt/esp 的那个节点
sudo mkdir -p /mnt/esp /mnt/p4
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo mount /dev/nvme0n1p4 /mnt/p4
sudo cp /mnt/esp/EFI/BOOT/BOOTX64.EFI.prev /mnt/esp/EFI/BOOT/BOOTX64.EFI
sudo cp /mnt/esp/boot/grub/grub.cfg.prev /mnt/esp/boot/grub/grub.cfg
backup="$(ls -1dt /mnt/p4/@boot-backup/*/ | head -n 1)"
cd /mnt/esp && sudo sha256sum -c "${backup}SHA256SUMS"
sync
sudo umount /mnt/esp /mnt/p4
```

然后开机。下次升级之前，把引导器放在一边：`ab-upgrade --check` 只验载荷、什么都不写，`--no-bootloader`
只换系统，让你刚修好的引导器保持原样。

## 怎么读 packages= 与 packages_reason=

`packages=` 是关于这个槽包元数据的一个词，由上一次升级产出，全程离线，从不运行 `apk`：

| 取值 | 含义 |
| --- | --- |
| `aligned` | 可写层的 `world` 钉的就是这个槽跑的内核，`distfeeds` 指的就是这个槽跑的 release。给这个内核装模块的 `apk add` 能用 |
| `limited` | 不是。机器照样启动、照常运行，但在元数据修好之前，装与本内核匹配的包会失败 |
| `unknown` | 没有记录，或记录讲的是另一个槽，或记录读不出来。绝不报成 `aligned`，因为这个字段存在的意义就是不让没有证据的话被当成结论 |

`packages_reason=` 说的是为什么。它就是对齐器发布在 ESP 的 `ab/packages` 里的那个 token，一行
`packages=<state> reason=<token> version=<ver> kernel=<id> slot=<a|b>`。值得认得的 token：

| token | 含义 |
| --- | --- |
| `none` | 已对齐，没什么可解释的 |
| `other-slot` | 记录讲的是升级瞄准的那个槽，不是这次启动跑的槽。`ab-upgrade` 之后、试新槽的那次重启之前，这是正常状态 |
| `packages-lib-missing` | 新的平台层里没有对齐器，于是没有任何东西被对齐 |
| `world-unwritable`、`distfeeds-unwritable` | 可写层里 `/etc/apk/world` 或 `distfeeds.list` 的重写失败 |
| `world-not-verified`、`distfeeds-not-verified` | 重写写下去了但读回来不是想要的值，于是原件被恢复 |

`aligned` 说的是元数据，不是网络。对齐是有意做成离线、文件级的，从不运行 `apk`，所以一台没插网线就升级的
机器同样可以是 `aligned`，而一台网络完美的机器同样可以是 `limited`。`limited` 既不阻断升级也不阻断启动：
槽照样起来，只是在 `world` 与 `distfeeds` 修好之前装不了与本内核匹配的模块。

把这两个字段直接从状态行里读出来，再读一眼记录本身：

```sh
ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(boot|esp|packages|packages_reason)='
cat /boot/ab/packages
```

`ab-slot` 对同一个判定还会打印一句人话，写报告时引这一句：`ab-slot: packages limited, package metadata is limited (<reason>): installing packages for this kernel needs it fixed first`。

包升级与对应的包级回退是另一组命令：`ab-slot packages upgrade` 与 `ab-slot packages revert`，见
[update.zh-CN.md](update.zh-CN.md)。



## 掉电演练

两个槽的意义全在断电那一刻的表现，而值得拔两次电的时机有两个。两次都在台面上、接控制台做。

第一次，机器安静地跑在已提交槽上，在两边各留一个痕迹，然后直接拔电——不 `reboot`、不 `halt`：

```sh
date > /data/powercut-data
date > /root/powercut-layer
sync
```

再上电，并断言：

```sh
ab-slot status
cat /data/powercut-data
cat /root/powercut-layer
ab-slot log
```

还是同一个槽被提交，`p4=ok`，两个痕迹都在，日志是一次干净启动（`stage=btrfs-check result=ok`，然后 `stage=commit`）。如果有写入者死在锁上，下次启动会自己接管这把锁并记下
`stage=lock action=stale-lock-taken`；这种情况下的通过条件就是这一行，而不是当成失败。

第二次，在升级窗口里拔电：跑 `ab-upgrade` 装上载荷，在"本该试新槽的那次重启"之前拔电。再上电，用上面同样四条命令加上 `ab-slot pending` 断言：

* 机器启动的是引导提示指向的槽，也就是新槽；
* 探针全过则它被提交，`ab-slot status` 显示 `pending=none`；
* 有探针失败则待验证槽被放弃，机器回到已提交槽（日志里是 `action=reboot-to-committed` 或
  `action=fail-safe-abandon`）；
* 无论哪种，之后 `next=` 都等于 `committed=`，而且 `/data` 上的痕迹还在——共享分区对两个槽是同一块盘。

## 回退

回退就是提交另一个槽，它仍然保有旧的文件系统与自己的可写层：

```sh
ab-slot rollback
reboot
```

启动后机器落在另一个槽并提交它。这是升级出问题后最快的回头路。它不是恢复出厂：升级以后写入的用户数据留在被推进的那一层里，
只要还有槽引用它，`ab-slot gc` 就不会删它。

只想丢弃已暂存的升级而不启动它：

```sh
ab-slot abandon
```

## 可写分区降级时

共享分区挂不上时启动不会失败：upper 层移到内存，系统照常起来，控制台与 `ab-slot status` 都会显示 `p4=degraded`。
机器能用，但本次启动之后写入的东西重启就没了，而且 `ab-upgrade` 会拒绝执行：

```
ab-upgrade: refused, reason=writable-layer-degraded
```

把这当成硬件警告处理。用 live 系统跑 `btrfs check` 检查盘，备份还需要的东西，原因排除后重新刷镜像。

## 证据回传

机器在台面上，报告就是日志，所以把它收在两个槽共用的那块盘上，等 LAN 侧能连了再拷走：

```sh
mkdir -p /data/evidence
{
    date
    ab-slot status
    ab-slot log
    ab-slot log --prev
    uci show network
    uci show firewall
    uci show dropbear
    ip -brief address
    ip -brief link
    nft list ruleset
    btrfs subvolume list /mnt/p4
} >/data/evidence/first-boot.log 2>&1
```

如果机器完全连不上，盘上已经带齐解释问题所需的东西：挂上 ESP（`PARTNAME ab-esp`，FAT），读
`ab/net.json`（首启网络的决定：模式、看到的网口、是否只是推迟）、`ab/log/boot-0.log`（本次启动的
环形日志）与 `ab/log/resize.log`（首启扩容）。这三份文件不需要开机、不需要 SSH、不需要 console；
GRUB 也帮不上忙——ESP 上那个 standalone EFI 二进制里没有 `cat` 模块。

在笔记本上：

```sh
scp root@192.168.100.1:/data/evidence/first-boot.log .
```

一次会话算完成，证据包里要有：

* `sha256sum -c SHA256SUMS` 的记录，两行 `OK`；
* 首次启动时控制台的照片或串口抓取，包含 `stage=net-seed` 那几行；
* 首启日志，含 `stage=net-seed result=ok ...`、三条 `probe=` 与 `stage=commit`；
* 升级前后、两次拔电之后的 `ab-slot status`；
* 填好的端口对照表，带 MAC 地址；
* `nft list ruleset` 里 `dport 22` 那一段：默认镜像上是空输出；便利镜像是关掉规则前后的两段；
* 升级后的 `ab-slot log --upgrade`；
* 任何失败都原样带回，包括它的 `reason=` 记号——那个记号与构建用的是同一套，所以机器上的现象与构建结果可以直接对照。

## 排查

先读启动日志，它用 `key=value` 记录了每个阶段：

```sh
ab-slot log
ab-slot log --prev
```

| 现象 | 通常意味着 | 处理 |
| --- | --- | --- |
| 控制台完全没有输出 | 启动方式或盘不对 | 只用 UEFI 启动，检查磁盘顺序 |
| 首次启动后任何口都没有地址 | 种子没跑，或跑了但失败 | 在 `ab-slot log` 里找 `net-seed`：`result=fail reason=...` 指出坏在哪一步；`result=skip reason=network-present` 说明本来就有配置、被原样保留了 |
| 刚写好的盘上出现 `result=skip reason=network-present` | 可写层不是空的 | 文件就是事实：读 `uci show network`，判断那套配置是不是你要的 |
| LAN 地址不是 `192.168.100.1` | 之前配过，或被手工改过 | 默认值只在生成该文件的那次启动叠加；按上面的办法用 `uci` 设置地址 |
| WAN 设备没有租约 | 没插线、上游没有 DHCP，或地址已被占用 | 对 `uci get network.wan.device` 指的设备跑 `ip -brief address`，再看上游路由的客户端列表 |
| `uci show firewall` 里有 `allow_ssh_wan`，`nft list ruleset` 里没有 | 规则加上之后 ruleset 还没渲染 | `/etc/init.d/firewall reload`，再看一次 |
| 便利镜像上规则还在，WAN 侧 ssh 却被拒 | `dropbear` 绑在某个接口上 | `uci show dropbear` 里不该有 `Interface`；删掉并 commit |
| 默认镜像上 WAN 侧 ssh 超时 | 那份镜像按设计就没有 WAN 规则 | 不用修；走 LAN、控制台，或者刷 `-wan-ssh` 镜像 |
| `p4=degraded` | 共享分区挂不上 | 见上一节 |
| `p4=ok` 但没有 `stage=commit` | 健康检查失败 | `ab-slot log` 会指出失败的探针；待验证槽用 `ab-slot abandon` 清掉 |
| `ab-upgrade` 退出 74 | 载荷或机器状态被拒绝 | 原因既打印也进日志；没有写入任何东西 |
| 升级后仍重启回原来的槽 | 新槽健康检查没过 | 日志里有 `reason=healthcheck-failed`；修好载荷再装一次 |
| `next=` 不是预期的槽 | 引导提示没写成功，或被更早的启动留旧了 | `ab-slot next --write` 按 `ab/state.json` 重写它；日志里 `stage=slot-cfg` 记着写入了哪个值 |
| 升级后总回到已提交槽 | 候选槽在进入用户态前就失败了 | 日志里有 `action=fail-safe-abandon` 与 `reason=`；此时已没有 pending，修好原因后重新安装载荷 |
| `ab-slot status` 显示 `disk=unknown` | 引导盘无法被识别 | 日志里 `stage=device` 会写明；对照实际写入的盘检查 GPT 名称与 `ab/device.json` |
| 出现 `state is locked by another process` | 有写入者在持锁时死掉 | 只要写下这把锁的那次启动（或它的进程）已不存在，锁会被自动接管，环形日志里出现 `stage=lock action=stale-lock-taken`；同一次启动内仍然活着的写入者属于真的并发，照旧拒绝 |
| 出现 `stage=resize result=fail:btrfs-resize` | 文件系统没扩成功（initramfs 里或运行期再次失败） | `ab/log/resize.log` 里有 btrfs 自己的报错；分区保持原尺寸，下一次启动重试 |
| 日志里没有 `btrfs=ok` | 平台层丢了工具 | 重新刷镜像，工具随平台层发布 |
| `stage=net-seed result=lan-only` | 机器只有一个以太网口 | 预期行为：没有第二个网络可路由，盒子就是一台 LAN-only 客户端 |

每次失败都会在日志里留一个 `reason=` 记号，和 CI 判据行用的是同一套记号，所以机器上的现象与构建结果可以直接对照，不用猜。

## 本次发布：0.0.8

`VERSION` 是 `0.0.8`。`0.0.8` 改的是更新这条路而不是启动这条路：载荷现在自带 GRUB 与 slot 菜单，
升级后的机器引导的是载荷带来的那个引导器，而不是刷机时那一个；`ab-upgrade` 用
`--bootloader` / `--no-bootloader` 让你决定这次写不写它。下面这段首启自动生成网络配置是 `0.0.7`
引入的，至今未变。`0.0.7` 那一版的内容，仍然是现在这一版的内容：

* **上游同款的首启生成。** `ab-net-seed` 在 `S16`、早于 `S20network`；当 `/etc/config/network` 不存在时，它调用
  `/bin/board_detect` 与 `/bin/config_generate`——就是官方 ImmortalWrt 镜像从 preinit 里跑的那两个程序，而本镜像的 A/B initramfs 替掉了那段 preinit。因此 `system` 里的主机名与时区是上游的。
* **四个口，一个 WAN。** `eth0` 做 WAN（`dhcp`，另有 `wan6`），`eth1` 到 `eth3` 进 `br-lan`。端口集合读自 `/sys/class/net`，所以口少的机器得到更小的桥，单口机降级为 LAN-only。
* **LAN 上是 `192.168.100.1/24`**，由上游的 dnsmasq 发地址。这个网段刻意避开 `192.168.1.0/24`。
* **WAN 侧只有便利镜像才放行 `22/tcp`。** 默认镜像什么都不开：`wan` zone 保持 `input 'REJECT'`，`dropbear` 保持上游的绑定 `lan`。`-wan-ssh` 镜像多一条 `allow_ssh_wan` 规则并把 `dropbear.Interface` 置空，好让规则真的能摸到守护进程。两个镜像里 LuCI 的 `80/tcp` 都不进 WAN。这是构建期常量：便利镜像就是同一条流水线带 `CI_NET_WAN_SSH=open`。
* **生成出来的东西不会被覆盖。** 触发条件只有"`/etc/config/network` 不存在"这一条，所以用户的改动、夹具注入的配置、升级带过来的配置都能活下来。

其余部分与 `0.0.6` 相同：四个 128 MiB 分区、overlay 层、健康检查、环形日志，以及本文描述的 `ab-slot` 与 `ab-upgrade` 行为。产物名没变，
发布目录里的 `release-notes.md` 记录本次构建的版本、输入摘要与判据行。
