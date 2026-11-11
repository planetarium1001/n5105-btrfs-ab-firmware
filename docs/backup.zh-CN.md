# 备份与恢复

[English](backup.md) | **简体中文**

本文是**包内装什么**、**包能恢复到多大的盘**、以及**原盘没了怎么办**的契约。
它同时是下面三种产物的唯一来源：工具 `ab-backup` 与 `ab-restore` 实现它，
三个测试保证文档与工具不各说各话。

一句话版本：重装一台机器 = 装镜像 + 把数据灌回去，这条路对**任何**盘都成立；
整盘镜像是逐字节副本，只能在**不小于原盘**的介质上恢复。

## 1. 三种产物

| 产物（概念名） | 物理形态 | 能恢复到多大的盘 | 失败形态 |
|---|---|---|---|
| 安装镜像 | 发布镜像，514 MiB，内含 p4 128 MiB | **任意 ≥ 514 MiB 的盘**；更大的盘由首启扩容补足 | 盘 < 514 MiB：表与载荷都放不下，不支持 |
| data 包 | `ab-backup` 产出的 `tar.gz` 与其 `.sha256` | **与磁盘容量无关**——先装镜像，再灌数据 | 目标 `@data` 非空：除非用 `--force` 明确表示要覆盖，否则拒绝 |
| 整盘镜像 | 整盘设备的逐字节 `dd` 副本 | **只能恢复到不小于原盘的介质**，并受下面 GPT 容差约束 | 更小的介质：写入阶段就失败，机器起不来——见 §2 |

关键的不对称：只有 data 包的价值与"眼前这块盘多大"无关。这就是"换更小的盘"的答案
永远是**安装镜像 + data 包**、而绝不是把镜像缩小的原因。

## 2. 为什么换更小的盘会在写入阶段失败

记在更大盘上的整盘镜像写不进更小的盘，而且失败不是"能开机但后面有问题"，
它发生在写入过程中：

1. `dd` 顺序写：LBA 1 的 primary GPT 先落盘，**盘尾的 backup GPT 永远写不到**——
   目标设备在源偏移之前就结束了。
2. 内核 GPT 解析（`block/partitions/efi.c` 的 `is_gpt_valid()`）把
   `last_usable_lba > lastlba` 判为非法，backup 头也不在该在的位置；随后 MBR 解析器
   看到 `0xEE` 保护分区，不认识它，于是**一个分区节点都没有**。
3. 没有分区节点就没有可引导的东西：GRUB 加载不到，**设备端任何代码都不会运行**。
   机上没有自救路径，`dmesg` 也是静默的——所以这看起来像主板坏了，而不是盘满了。
4. 即使强行读出分区表，btrfs 也会硬拒绝：`device total_bytes > bdev_nr_bytes`
   返回 `-EINVAL`，`open_ctree` 失败，只读也一样。

GPT 容差只有 `lastlba - 33` 个扇区，所以"标称容量相同、来自另一家厂"的盘也可能不够。
复制整盘镜像前，请在两个设备上比 `blockdev --getsz`，不要比包装盒上的字。

## 3. 恢复决策树

**Q1，永远先问第一句：目标盘容量 ≥ 原盘容量吗？**

只有回答"是"，逐字节那几条路才成立。回答"否"时，唯一的路是 B——
原因见 §2：没有任何工具能让整盘镜像变小装进去。

```
Q1  目标盘容量 >= 原盘容量 吗？
 |- 否  -> 路径 B：安装镜像 + data 包
 '- 是  -> Q2 原盘还能开机吗？
            |- 能   -> 路径 A：ab-backup 出包，或直接克隆
            '- 不能 -> Q3 手上剩下的是原盘，还是它的镜像？
                       |- 原盘   -> 路径 C：原盘挂到另一台 Linux 上读
                       '- 镜像   -> 路径 D：在主机上直接读镜像
```

### A. 同尺寸或更大盘，原机还能开机

`可用条件：` 原机仍能开机，且目标盘通过 Q1。

```sh
# 在原机上
ab-backup --with-docker --out /data
sha256sum -c /data/data-*.tar.gz.sha256

# 在装好镜像并已首启过一次的新机上
ab-restore /data/data-<hostname>-<UTC>.tar.gz
```

`期望看到：` 第一条命令打印 `backup=<path>`、`entries data=... etc=... docker=...`
与 `consistency=snapshot`；`sha256sum -c` 打印 `OK`。恢复时每一类打一行 `restored=`，
并把当前槽的 `etc/config` 一起放回去。

`不可用时：` Q1 回答"否"——改用路径 B；原机已经开不了机——那是路径 C 与 D。

### B. 任意盘，包括更小的盘：安装镜像 + data 包

`可用条件：` 永远可用，前提是机器还能运行的时候用 `ab-backup` 出过 data 包。

```sh
# 把安装镜像写到新盘，首启一次让它把 p4 扩到盘尾
# 再把包拷进去（U 盘、ssh 都行），然后：
ab-restore /data/data-<hostname>-<UTC>.tar.gz --data-only
```

`期望看到：` `restored=data path=/data entries=<n>`；`ab-slot status` 仍报 `boot=ok`；
各服务在 `/data` 下看到的是原来的数据。

`不可用时：` 从来没出过 data 包。此时数据的唯一来源是老盘（路径 C）或它的镜像
（路径 D），而把结果写回去需要满足 Q1 的介质。

### C. 原盘起不来：挂到另一台 Linux 上读

`可用条件：` 原盘物理完好，且能挂到另一台 Linux 机器上。

```sh
# 在另一台 Linux 上以 root 操作，挂上老盘
blockdev --getsz /dev/nvme1n1                 # 确认这就是你以为的那块盘
partx -s /dev/nvme1n1                         # p4 是最后一个分区
mount -o ro /dev/nvme1n1p4 /mnt/old
btrfs subvolume list /mnt/old                 # @data、@docker、@overlay-<版本>
# 然后把 @data 拷出来，例如
rsync -aHAX /mnt/old/@data/ /srv/rescue/
```

`期望看到：` `partx -s` 列出四个分区，名字是 `ab-esp`/`ab-slot-a`/`ab-slot-b`/`ab-data`；
`btrfs subvolume list` 显示布局文档里的那些子卷；救出的目录与 `@data` 同构。

`不可用时：` 盘已损坏，或没法挂到任何机器上——那就只剩路径 D，而且要求镜像已经存在。

### D. 只剩整盘镜像：在主机上直接读

`可用条件：` 手上有整盘镜像（或还能从可读的盘做出一个），且有带 loop 设备与 btrfs 的主机。

```sh
# 主机上四条命令，不需要设备
losetup --find --show --partscan image-flashable.img
mount -o ro /dev/loop0p4 /mnt/img
btrfs subvolume list /mnt/img
rsync -aHAX /mnt/img/@data/ /srv/rescue/
```

`期望看到：` `losetup` 打印 loop 设备，`partx`/`blkid` 显示四个分区，
`btrfs subvolume list` 列出 `@data`，救出目录里是数据。

`不可用时：` 想把镜像写回**更小**的盘——双向都不行：这种场景下镜像只是数据来源，
目标盘必须按路径 B 重建。（把镜像写到更大的盘是允许的，那是 Q1 的"是"。）

## 4. `ab-backup` 与 `ab-restore`

一个包，三类固定条目——恢复时永远不需要猜某个文件原来是什么：

| 包内路径 | 来自 | 回到 |
|---|---|---|
| `data/` | `@data` 全量（挂在 `/data`） | `/data` |
| `etc/config/` | 当前槽 overlay 上层的 `etc/config`（只含被改过的文件） | 同一个上层目录 |
| `docker/` | `@docker`（挂在 `/opt/docker`），仅 `--with-docker` 时 | `/opt/docker` |
| `meta/` | ESP 的 `ab/state.json`、`ab/device.json`、`ab/image.json`，p4 的 `.ab/grow`、`.ab/grow.log`，以及生成的清单 | `/data/.ab-restore-meta/` —— **永不写 ESP** |

`meta/` 描述的是出包那台机器：槽状态、设备身份、首启扩容记录。把它写回 ESP
等于把一套旧几何、旧槽配对灌进刚装好的系统，所以它只留在数据旁边给人看，永不施加。

| 命令 | 选项 | 行为 |
|---|---|---|
| `ab-backup` | `--with-docker` | 追加导出 `@docker` |
| | `--out <dir>` | 包写到哪里（默认 `/data`） |
| | `--dry-run` | 只打印清单与归档名，不写任何文件 |
| | `--plain` | 不压缩，出 `.tar` |
| `ab-restore` | `<archive>` | 要恢复的包 |
| | `--data-only` | 只解 `data/`，`etc/config/` 与 `meta/` 不动 |
| | `--force` | 允许恢复进非空的 `@data` |

两个工具都在 stdout 给机器可读的行（`backup=`、`entries`、`consistency=`、`restored=`），
拒绝走 stderr、带 `refuse:` 前缀、退出码 3。拒绝意味着**什么都没写**：
空间检查、摘要检查、成员检查与非空检查都在解包第一个字节之前完成。

一致性：`ab-backup` 先对 `@data` 做只读快照再归档快照，所以包是一个时间点。
拿不到快照时退化为直接 tar 活树，向 stderr 打 `warn:` 并报 `consistency=live`——
那份副本不是时间点一致的，这点是写明的，不是隐含的。

### 降级启动

挂不上可写分区的启动会用 tmpfs 当上层：改动看起来正常，重启就消失。
两处让它可见，都读"本次启动"的环形日志：

- `ab-slot status` 报 `boot=ok`、`boot=degraded`，或读不到日志时的 `boot=unknown`。
  没有证据时它绝不报 `ok`。
- `platform/etc/profile.d/ab-degraded.sh` 在降级启动时登录打一行到 stderr，其余情况完全静默。

不要在一个降级启动的系统上出"必须可信"的备份：`@data` 就在那块没挂上的分区上，
包会是空的，却看起来完全正常。

## 5. 产物命名（映射表）

§1 的概念名是契约。物理名正在与发布流程一起定稿，所以这张表是两者对应的地方——
也**只**是这张表。发布流程冻结之前，文档与脚本里只能用概念名，不能用物理文件名。

| 概念名 | 物理名（暂定） | 由谁产出 |
|---|---|---|
| 安装镜像 | `image-flashable` 产物，`kind=boot` | assemble 阶段 |
| data 包 | `data-<hostname>-<UTC>.tar.gz` + `.sha256` | 设备上的 `ab-backup` |
| 整盘镜像 | 整盘设备的 `dd` 副本 | 操作者手工，不是构建 |

## 相关

- 分区几何与首启扩容：[partitions.zh-CN.md](partitions.zh-CN.md)
- 槽模型、状态文件与命令：[lifecycle.zh-CN.md](lifecycle.zh-CN.md)
- 把镜像写到盘上：[install.zh-CN.md](install.zh-CN.md)
