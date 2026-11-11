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

只有装**生产启动 initramfs** 的镜像才能在真机上启动。CI 会产出两种名字，只有一个能写：

| 位置 | 名称 | 用途 |
| --- | --- | --- |
| GitHub release | `n5105-ab-<upstream>-install.img.gz` | 写这个；发布作业已验证过它能启动 |
| Actions 产物（tag 构建） | `image-install` | 与发布版同一份字节，用于发布前测试 |
| Actions 产物（每次构建） | `image-probe` | **永远不要写它**：它是 S1 模块探针，找 `/dev/vda`，在真机上会直接关机 |

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

刚写好的盘上，第二条会打印两行：

```
stage=net-seed wan-ssh=open
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

`ab-slot log | tail` 是同一次启动的快速读法：最后几行就是健康检查与决定（`stage=healthcheck-done`，然后是 `stage=commit`）。

之后再启动只打印一行：`stage=net-seed result=skip reason=network-present`。幂等就是这件事：只有"发现没有 `/etc/config/network`"的那次启动会跑生成，之后再也不跑——你自己用 `uci` 改的东西、升级带过来的配置也因此不会被覆盖。

健康机器上 `ab-slot status` 只打印一行：

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid
```

`p4=ok` 表示可写分区已挂载，`data`、`docker`、`swap` 是平台层挂载在它上面的三个子卷。`next=a` 是 GRUB
下次会启动的槽，从 `boot/grub/ab-slot.cfg` 读回；想知道"重启会发生什么"就看这一个字段。如果 `p4` 显示
`p4=degraded`，先读下面的降级小节，再做别的事。

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
* **本版 WAN 侧的例外是开着的。** 只要 `allow_ssh_wan` 规则还在，WAN 侧就接受 `22/tcp`，而 `dropbear` 会用镜像里带的 root 密码接受密码认证。LAN 侧一旦能连，就把它关掉。

## 真机上的网络默认值

下面是本版在"发现没有 `/etc/config/network`"的那次启动上生成的内容：

| 项 | 值 | 由谁写入 |
| --- | --- | --- |
| WAN 设备 | `eth0`，`proto dhcp`，另有 `@wan` 上的 `wan6` | 项目默认值叠加在 `config_generate` 之上 |
| LAN 桥 | `br-lan`，端口 `eth1`、`eth2`、`eth3` | 项目默认值 |
| LAN 地址 | `192.168.100.1/24`，`proto static` | 项目默认值 |
| LAN DHCP 服务 | dnsmasq 在 `lan` 上，用上游的地址池 | `/etc/config/dhcp`，未改动 |
| WAN 入站 | 一条规则，`allow_ssh_wan`，`22/tcp` | 项目默认值 |
| SSH 绑定 | `dropbear.@dropbear[0].Interface` 置空 | 项目默认值 |
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

关掉 WAN 例外——在控制台或 SSH 上一条 `uci` 块：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

LuCI 里同一条规则是 **网络 → 防火墙 → 通信规则**（Network → Firewall → Traffic Rules）里名为 `allow_ssh_wan` 的那一条：删掉它，按 **保存并应用**。然后确认它真的没了：

```sh
uci show firewall | grep allow_ssh_wan     # 没有输出
```

关掉它不影响 LAN 侧，`dropbear.Interface` 仍是空的，所以从 LAN 的 SSH 照旧能用。这里的每个默认值同时也是构建期常量：平台层里的 `/etc/net-defaults.conf` 由
`scripts/ci/net-defaults.conf.in` 渲染而来（`NET_WAN_DEV`、`NET_LAN_DEVS`、`NET_LAN_ADDR`、`NET_LAN_PREFIX`、`NET_WAN_SSH`），"WAN 22 关"的发布就是同一条流水线带
`CI_NET_WAN_SSH=closed` 跑一次。完整说明见 [network.md](network.md)。

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
| WAN 上只有一条例外 | `nft list ruleset` 里找 `allow_ssh_wan` | `wan` 入站链里一条匹配 `tcp dport 22` 的规则，zone 对其它一切仍然拒绝 |
| LAN 口能发地址 | 把笔记本插到 `eth1`..`eth3` 任一口，设成 DHCP | 拿到 `192.168.100.0/24` 里的地址，网关 `192.168.100.1` |
| 工具可用 | `btrfs --version` | 打印 `btrfs-progs` 版本行 |
| 可写层可见 | `btrfs subvolume list /mnt/p4` | 包含 `ab-slot status` 报告的那一层 |
| 防火墙已加载 | `nft list table inet fw4` | 有表，不是报错 |
| 回收无事可做 | `ab-slot gc --dry-run` | 没有层被列为待删 |
| 备槽完好 | `ab-slot pending b` 再 `ab-slot abandon` | 前者成功，后者清空 |
| 下次启动符合预期 | `ab-slot next` | 上面那次 abandon 之后是 `next=<已提交槽>` |

`ip -brief address` 里不会有 `wan` 这个接口：WAN 接口绑在设备上（`option device eth0`），地址就显示在 `eth0` 上。所以 WAN 那一行要先用 `uci` 读出设备名。`nft list ruleset` 更全也更慢，接一个
`grep -A3 allow_ssh_wan` 就够留下值得回传的那一小段。

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

只要 `allow_ssh_wan` 规则还在，从 WAN 侧同样能登：`ssh root@<上游路由分给 eth0 的地址>`。只验证一次——这条规则的意义就在于机器挂在你进不去的那台路由器后面时还能连上——然后从 LAN 侧的会话里关掉它：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

如果规则还在、WAN 侧却被拒，就去看守护进程的绑定：`uci show dropbear` 里不该有 `Interface` 选项（要是它又出现了，`uci delete
dropbear.@dropbear[0].Interface; uci commit dropbear`），`logread | grep
dropbear` 会告诉你守护进程到底有没有在监听。

## 升级运行中的系统

升级写入非活动槽并把它标记为待验证，全程不碰运行中的槽，所以出问题机器照样能用。

```sh
ab-upgrade --check /root/n5105-ab-<upstream>-upgrade.tar
ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar
ab-slot status
ab-slot conflicts
ab-slot log --upgrade
```

`--check` 只校验、什么都不写，所以坏载荷在动非活动槽之前就被发现。真正写入时 `ab-upgrade` 再校验一遍：manifest 形状、逐成员摘要、initramfs 里所有模块是否来自同一次内核构建、可写分区余量、
以及冲突报告。拒绝时退出状态为 74 且什么都不写。成功后状态里另一个槽变成 `pending`，`ab-slot status` 的
`next=` 也会指向它，下次启动会试它：

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
* 关掉规则前后，`nft list ruleset` 里 `allow_ssh_wan` 那一段；
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
| 规则还在，WAN 侧 ssh 却被拒 | `dropbear` 绑在某个接口上 | `uci show dropbear` 里不该有 `Interface`；删掉并 commit |
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

## 本次发布：0.0.7

`VERSION` 是 `0.0.7`，也是第一个首次启动会自己写出网络配置的发布。按发布说明的口径，这一版的内容是：

* **上游同款的首启生成。** `ab-net-seed` 在 `S16`、早于 `S20network`；当 `/etc/config/network` 不存在时，它调用
  `/bin/board_detect` 与 `/bin/config_generate`——就是官方 ImmortalWrt 镜像从 preinit 里跑的那两个程序，而本镜像的 A/B initramfs 替掉了那段 preinit。因此 `system` 里的主机名与时区是上游的。
* **四个口，一个 WAN。** `eth0` 做 WAN（`dhcp`，另有 `wan6`），`eth1` 到 `eth3` 进 `br-lan`。端口集合读自 `/sys/class/net`，所以口少的机器得到更小的桥，单口机降级为 LAN-only。
* **LAN 上是 `192.168.100.1/24`**，由上游的 dnsmasq 发地址。这个网段刻意避开 `192.168.1.0/24`。
* **WAN 侧放行 `22/tcp`，默认开。** 一条 `allow_ssh_wan` 规则，`wan` zone 仍是 `input 'REJECT'`，`dropbear.Interface` 置空好让规则真的能摸到守护进程。LuCI 的 `80/tcp` 不进 WAN。这条规则是构建期常量：关掉的变体就是同一条流水线带 `CI_NET_WAN_SSH=closed`。
* **生成出来的东西不会被覆盖。** 触发条件只有"`/etc/config/network` 不存在"这一条，所以用户的改动、夹具注入的配置、升级带过来的配置都能活下来。

其余部分与 `0.0.6` 相同：四个 128 MiB 分区、overlay 层、健康检查、环形日志，以及本文描述的 `ab-slot` 与 `ab-upgrade` 行为。产物名没变，
发布目录里的 `release-notes.md` 记录本次构建的版本、输入摘要与判据行。
