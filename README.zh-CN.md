# N5105 Btrfs A/B 固件

基于 ImmortalWrt 的 N5105 v5 单板固件，在 btrfs 上实现 A/B 双根更新。

[English](README.md) | **简体中文**

本项目只负责系统层：A/B 引导槽与 btrfs 布局。
应用层打包与配置不在范围内。

## 范围

| 项目 | 取值 |
|---|---|
| 目标硬件 | N5105 v5，x86-64，UEFI，4× Intel i226-V |
| 基础系统 | ImmortalWrt，rootfs 与上游逐字节一致 |
| 项目自有内容 | 仅构建层、引导层与 `@platform` 平台层 |
| 引导 | 仅 UEFI；不支持 legacy/BIOS 与多主板 |

## 磁盘布局

| 分区 | PARTNAME | LABEL | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB、槽状态、启动日志 |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | 槽 A：`@sys` + `@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | 槽 B：`@sys` + `@platform` |
| p4 | `ab-data` | `data` | 128 MiB，首启后扩至盘尾 | btrfs | `@overlay-<版本>`、`@docker`、`@swap`、`@data` |

- PARTNAME（`ab-…`）是引导代码与内核块设备比对时用的稳定名；LABEL 是人或 `blkid`
  读的短名。两套名字都是契约，见 [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)。
- `@sys` —— 上游 rootfs，只读
- `@platform` —— 平台工具，随槽版本绑定，只读
- `@overlay-<版本>` —— 全部可写状态，两槽共享

### 盘比镜像大时会发生什么

镜像本身 514 MiB，其中的 p4 是 128 MiB。首启时引导用的 initramfs 会把 **p4 扩到你所写入
那块盘的末尾**，再把文件系统长进去；p1、p2、p3 一个字节不动，四个 PARTUUID 保持不变。因此同一
份镜像能用在任意 NVMe / SATA 盘上，也解释了为什么"把备份恢复到一块更大的盘"之后空间直接可用。

由此有两条，都是有意为之：

- **幂等**：每次启动都会重新判断。p4 到盘尾之后再启动，日志是 `stage=grow … result=already-full`，
  不写任何东西。
- **只扩不缩、不猜**：把大盘的镜像恢复到小盘时，分区表会描述不存在的空间，这时扩容以
  `fail:p4-beyond-disk` 拒绝并保持原表不动。ESP 上的 `ab/log/grow.log` 记录了每次判断。

如果你希望盘尾保留未分配空间（例如装第二个系统，或留一块自用分区），在首次启动前手工把 p4 调大
到想要的位置即可，自动那一步会发现"已满"而不做任何改动。

## 启动链

1. GRUB 从 p1 读取槽状态，选择内核与 initrd。
2. initramfs 先挂载 p4 可写层，再挂载槽内只读层。
3. overlayfs 合成根：`lowerdir=@platform:@sys`，`upperdir=@overlay-<version>/upper`。
4. `switch_root` 进入系统。

## 默认网络

刷完盘第一次启动就会自己通网。首启只在 `/etc/config/network` 不存在时跑 `ab-net-seed`
（start `S16`，早于 `network`）：它调用上游的 `/bin/board_detect` 与 `/bin/config_generate`，
再叠加本项目默认值。已经存在的配置 —— 你自己改的 `uci`、测试夹具、升级带过来的文件 ——
一律不会被改写。细节、检查命令与变体见 [docs/network.zh-CN.md](docs/network.zh-CN.md)。

| 接口 | 设备 | 协议 | 地址 |
|---|---|---|---|
| WAN | `eth0` | `dhcp` 客户端 | 上游网络下发的租约 |
| LAN | `br-lan`，桥接 `eth1`、`eth2`、`eth3` | `static` | `192.168.100.1/24` |
| LAN DHCP | `lan` 上的 dnsmasq | — | 上游的 `lan` 地址池，`/etc/config/dhcp` 不动 |

**已知限制：只有一个以太网口的机器（例如用 QEMU 试跑）会以 LAN-only 启动。** 唯一的口进 `br-lan`，
完全没有 `wan` 段，于是健康检查的 `wan-present` 探针每次启动都失败、槽会报自己不干净；这是本发布
写明的实现口径而不是故障 —— 没有 WAN 接口的槽不可能有 WAN 设备。四口 N5105 走路由器模式，不受影响。

- WAN 侧**什么都不放**。随发布的镜像里没有 `allow_ssh_wan` 规则：`wan` zone 仍是
  `input 'REJECT'`，`dropbear` 保持上游的绑定 `lan`，LuCI 的 `80/tcp` 同样不对 WAN 暴露。
- 有一个镜像是刻意的例外：`n5105-ab-<upstream>-install-wan-ssh.img.gz` 只多一条 `22/tcp` 规则，
  给「从 LAN 够不到、也给不了键盘和显示器」的机器。它的首启会打印三条关闭这条规则的办法，
  默认镜像永远没有这条规则。

改 LAN 网段，然后在新地址重连：

```sh
uci set network.lan.ipaddr='192.168.8.1/24'
uci commit network
/etc/init.d/network reload
```

把 WAN 换到另一个网口。`ip -br link` 告诉你哪个 `eth*` 对应哪个物理口：逐个口插网线，
看哪一行变成 `UP`。

```sh
uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='br-lan'$/\1/p"
# 打印 br-lan 那一段，形如 @device[0]；下面两条端口命令用它
uci set network.wan.device='eth3'
uci del_list 'network.@device[0].ports=eth3'
uci add_list 'network.@device[0].ports=eth0'
uci commit network
/etc/init.d/network reload
```

在 `-wan-ssh` 镜像上关掉 WAN 22，命令行或 LuCI 均可（网络 → 防火墙 → 通信规则，规则名
`allow_ssh_wan`）：

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

## 更新与回退

- 更新写入非活动槽，不修改运行中的系统。
- 可写层按代号推进：快照当前代号，全程不重命名。
- 首次启动失败一次即回退到已提交槽。
- 健康检查通过后才提交新槽。
- 回退深度为一代。

## 构建

- CI 从官方镜像站获取 `rootfs.tar.gz`、`kernel.bin` 与内核模块，组装 initramfs 与整盘镜像。
- 不编译内核；升级载荷约 20 MiB。
- 产物：首次安装用整盘镜像，日常更新用升级载荷。

## 仓库策略

- 只发布源代码与文档。
- 工作流配置、Agent 指令、知识库与任务记录均保留在本地。

## 测试

```
./tests/run.sh                  # 全部模块，默认并行
./tests/run.sh --module design  # 单个模块
./tests/run.sh --jobs 8         # 限定并行度
./tests/run.sh --list           # 列出已发现的用例
```

测试位于 `tests/modules/<module>/test_*.sh`，一个模块一个关注点。
每个测试是独立进程，模块之间并行执行，单个失败不会掩盖其它失败。

## 文档

十篇文档，每篇是它自己主题的唯一来源；索引在 [docs/](docs/README.zh-CN.md)。

使用这套固件：

- [docs/quickstart.zh-CN.md](docs/quickstart.zh-CN.md) —— 最短路径：写镜像、启动、装一个包、
  升一次级、回退一次
- [docs/install.zh-CN.md](docs/install.zh-CN.md) —— 写镜像、首启、验收清单，以及抢救被写坏的
  引导器
- [docs/update.zh-CN.md](docs/update.zh-CN.md) —— 从 release feed 升级：配置、风险级别、
  每个拒绝 token，以及状态字段参考
- [docs/backup.zh-CN.md](docs/backup.zh-CN.md) —— 三种备份产物、各自能恢复到什么介质，以及
  恢复决策树
- [docs/network.zh-CN.md](docs/network.zh-CN.md) —— 首启网络默认值与怎么改
- [docs/troubleshooting.zh-CN.md](docs/troubleshooting.zh-CN.md) —— 先读什么、每种现象意味着
  什么，以及本项目决定不去改变的行为

修改这套固件：

- [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md) —— 分区布局、启动链、槽位状态机、
  升级事务与 payload 契约
- [docs/ci.zh-CN.md](docs/ci.zh-CN.md) —— 流水线、发布线，以及 CI 文本契约
- [docs/device-matrix.zh-CN.md](docs/device-matrix.zh-CN.md) —— 通过 SSH 驱动真机跑版本矩阵

## 状态

设计阶段。分区几何、启动链与更新事务已定稿，实施按 S0–S6 推进。

当前版本：`0.0.13`，上游 base `25.12.2`。这是**测试版**，不是 `0.1.0`：上游 base 没变，也没有新增
任何用户可见功能。它把 `0.0.11` 之后累积的缺陷修复打包，连同覆盖这些缺陷的验收能力。

- **apk 保护规则按前提判定。** `scripts/device/apk-protection-probe.sh` 用
  `apk audit --backup` 问一句：apk 是否把某个受保护路径视作未被改动 —— 这正是
  `/etc/apk/protected_paths.d/` 里 `+` 规则成立的前提 —— 一条注定不会触发的规则会当场被点出来。
  device 脚本统一为 POSIX `sh`，与 CI 静态检查使用的方言一致。
- **A/B 换槽改看槽实际产出的数据。** `scripts/device/lib.sh` 从归档的真机数据里导出三组字段 ——
  stable、identity、monitored —— matrix 与 scenarios 不再把 `committed`、`pending`、`generation`
  混作一类。`ab-slot packages snapshot` 不再对无法解析的记录给出 `packages=0`，commit 路径会把
  包记录指向刚提交的槽。
- **每日 upstream watch 在 discovery 失败时让 job 失败**，坏掉的镜像源或索引不会再以绿灯通过。
- **发布页改为从 payload manifest 取值**，kernel 版本与上游摘要上的 `not recorded` 占位随之消失。
- **验收只需一条命令。** `scripts/device/full-test.sh` 把 S8 的四类坏配置、真实 docker 负载
  D1/D2/D3、版本固定 `--case pin`、包回退 P3/P4 与发布字节校验排进同一个顺序，给出同一个结论。

首启自动生成网络配置（`0.0.7`）、自带引导器的载荷（`0.0.8`）与健康检查（`0.0.6`）都是更早版本
引入的，至今未变。

## 许可证

- 构建工具与项目自有代码：[MIT](LICENSES/MIT.txt)
- 源自上游 OpenWrt 的文件：[GPL-2.0-only](LICENSES/GPL-2.0-only.txt)
