# 更新事务、回收与可观测性

[English](lifecycle.md) | **简体中文**

## 可写层命名

可写层按它所属的上游版本命名，形如 `@overlay-<版本>`，例如 `@overlay-25.12.2`。
每次更新创建新层，任何子卷都不重命名。

复用版本号让名字自解释：可写层、槽内 rootfs 与上游发行版读作同一件事。
由于同一个上游版本可能配不同的平台层重出一次，重复的版本号追加序号，
形如 `@overlay-25.12.2-r2`。

名字给人看，顺序不从名字推导。`ab/state.json` 仍带一个只增不减的整数 `generation`，
回收按它排序。

由此得到：

- 不存在被占用的临时名，即使系统从未重启也能创建下一层
- 回退只移动指针，不复制数据
- 稳态恰好两层，每槽一个

## 状态文件

p1 上的 `ab/state.json`，原子写入（临时文件、`sync`、rename）：

```json
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
```

## 选槽

`ab/state.json` 是真相。GRUB 读不了它，所以引导器另拿一个派生值：

| 产物 | 谁写 | 谁读 | 角色 |
|---|---|---|---|
| `ab/state.json` | `ab-slot`（临时文件、`sync`、rename） | initramfs、`ab-boot`、`ab-commit`、`ab-upgrade`、`ab-slot` | 真相：`committed`、`pending`、各槽可写层 |
| `boot/grub/ab-slot.cfg` | `ab-slot` 的 `pending`/`commit`/`abandon`/`rollback`、每次启动的 `ab-boot`、以及 boot initramfs 的失败路径 | GRUB，经 `source` | 提示：下一次启动跑哪个菜单项，以及失败的尝试回退到哪 |
| `boot/grub/grub.cfg` | 镜像构建时一次 | GRUB | 菜单与构建期默认项；运行期永不改写 |

`boot/grub/ab-slot.cfg` 只有两条 GRUB 命令，顺序固定：

```
set fallback=<已提交槽>
set default=<pending 槽，没有 pending 时就是已提交槽>
```

两个值都由同一份实现（`platform/lib/ab-slot-cfg.sh`）从状态文件派生，所以构建期、状态命令、
启动钩子与启动失败路径不可能各说各话。这里没有环境块：ESP 里那个 GRUB 是模块编进核心里
的独立 EFI，没有 `env` 模块，`load_env` 与 `save_env` 都不存在。用 `source` 读一个两行文件在这个
二进制上可用，而且 `scripts/ci/grub-render.sh --verify-esp` 会在镜像启动之前断言加载器里确实有
`source`、`test` 与 `serial`。

菜单先定义三个菜单项、把构建期的 committed 槽同时设为**默认与回退**，最后才 `source` 提示文件。GRUB
遇到第一个错误就停止读脚本，所以这个顺序意味着提示文件缺失、被截断或格式错误都不会让机器失去菜单：
它会启动 committed 槽，也就是构建期那一对值本来就写着的东西。

菜单项下标属于契约：槽 `a` 是第 0 项，槽 `b` 是第 1 项。菜单顺序对不上的配置会被渲染器拒绝，
因为顺序一换就会静默启动错槽。

### 两次写入之间掉电

状态文件与提示文件先后写入，各自原子。中间掉电会留下"状态已推进、提示还是旧的"，机器会启动提示
指向的槽。

- `ab-boot` 每次启动都会在被任何人读之前按状态文件重写提示，所以旧提示最多多花一次启动、不会跑错
  槽：被打断的那次启动之后的那次启动，跑的就是状态文件说的槽。
- 正因如此，文件先写 fallback 行。只写进第一行的文件等于只写了 `set fallback=<已提交槽>`，与菜单里
  原有的值相同：默认项仍是 committed 槽，机器启动它。两行都写进时才把默认项切到正在试的槽、fallback
  留在原地，正好是"试新槽、失败回旧槽"需要的一对。任何截断都不会让 fallback 指向正在试的槽。

### 新槽起不来时

两级兜底，按顺序：

1. pending 槽的内核根本没起来：GRUB 转到 `fallback` 项，也就是 committed 槽，机器启动旧系统；
2. 内核起来了但健康检查失败：`ab-commit` 放弃 pending 槽，状态文件里清掉 `pending`、提示指回
   committed 槽，然后重启回到它；
3. 内核起来了但 boot initramfs 在进入用户态之前失败：`wf_fail` 走同一条 fail-safe abandon（清掉
   `pending`、把提示指回 committed 槽、日志记 `action=fail-safe-abandon`），然后才关机，下一次启动
   不会再去试那个刚失败的槽。

`ab-slot rollback` 是手动路径：它提交另一个槽并连带移动提示。`ab-slot status` 把结果报成
`next=<a|b|unknown>`，`ab-slot next` 单独打印它，是在运行中的系统上最快看清"下次启动会做什么"的办法。

## 事务时序

| 事件 | p4 | p1 状态 |
|---|---|---|
| 安装 | 创建 `@overlay-25.12.2`、`@docker`、`@swap`、`@data` | `a`、`b` 同指该层，`committed=a` |
| 更新槽 B 到 25.12.3 | `snapshot @overlay-25.12.2 -> @overlay-25.12.3`，写 p3 | `pending=b`，更新 `b.upper` |
| B 健康启动 | — | `committed=b`，清除 pending，回收 |
| 更新槽 A 到 25.12.4 | `snapshot @overlay-25.12.3 -> @overlay-25.12.4`，写 p2 | `pending=a`，更新 `a.upper` |
| A 健康启动 | 删除 `@overlay-25.12.2` | `committed=a`，清除 pending |
| 回退 | — | 把 `committed` 切到另一槽 |

快照源永远是当前活动层。快照前先 `sync` 并停止写入方；
一致性口径为崩溃一致，而非应用一致。

## 健康检查

在 `done` 之后执行，超时 150 秒：

| 探针 | 通过条件 |
|---|---|
| `overlay-writable` | 合成根 `/` 可写且剩余空间至少 16 MiB（绝对下限而非百分比：同一条规则在 128 MiB 的测试镜像和几百 GiB 的真机盘上必须表示同一件事） |
| `fw4-present` | nft ruleset 非空且存在 `inet fw4` 表 |
| `wan-present` | `network.wan` 引用的设备存在 |

全部通过才提交。任一失败则放弃待提交槽，重启回到已提交槽。

可写层就是根本身：引导 initramfs 把 `@overlay-<version>` 挂成 upper 并 `switch_root` 进合成树，
所以镜像里并没有单独的 `/overlay` 挂载点。

即使某个探针已经失败，三个探针仍会全部跑完：决定只需要第一个失败，但日志要在一次启动里
把三个都说清楚，否则一个有两处故障的槽需要两次启动才能解释完。

`fw4-present` 不找常驻进程：ImmortalWrt 25.12 的 `fw4` 是一次性渲染器，加载 ruleset 后就退出，
可观测的状态就是 ruleset 本身。空 ruleset 正是这个探针要抓的故障。

`wan-present` 需要一个网络配置来指认设备，而这份配置由平台层产出：`ab-net-seed` 以 `S16` 启动，
早于 `S20network`；`/etc/config/network` 不存在时它调用上游 `board_detect` 与 `config_generate`，
再叠加项目默认值（见 [network.zh-CN.md](network.zh-CN.md)）。所以全新安装上这个探针有设备可读；
生成失败只写 `stage=net-seed result=fail`，启动照常继续。

已经存在的配置一律不动，测试也正是这样注入自己的配置：经用户同样的可写层注入的夹具优先于生成结果，
于是探针可以针对测试自己选定的设备名来验证。

## 回收

引用集合为 `slots.a.upper` ∪ `slots.b.upper` 加上待提交槽的层。
集合之外的 `@overlay-*` 全部删除，按 `generation` 从小到大。

四条安全规则：

1. 不删除当前挂载中的层（检查 `/proc/mounts`）
2. 不删除待提交槽引用的层
3. 执行 `btrfs subvolume delete -C` 后再执行 `btrfs subvolume sync`，仅删除不会立即释放空间
4. 盘空间紧张时不执行全量 balance，balance 自身需要空闲空间

触发点：提交成功后、每次启动早期、更新失败后，以及按需执行 `ab-slot gc`。

空间阈值：

| 剩余空间 | 动作 |
|---|---|
| 高于 15% | 正常 |
| 低于 15% | 告警并自动回收 |
| 低于 5% | `platform_check_image` 返回 74，拒绝更新 |

不使用 qgroup 配额；独占空间按需用 `btrfs filesystem du -s` 测量。

探针开跑之前，先确认这棵树是一棵树：依次读 `/proc/cmdline`、`/proc/mounts`、`/sys/class/net`。
升级后的槽若没挂上 `/proc`，三个探针会因为同一个原因全红，所以这个原因单独成行
（`stage=preflight … reason=proc-cmdline-unreadable`），而不是三条无名的 `result=fail` ——
这正是"探针写错了"和"这个槽没正常起来"的区别。

### 运行期补做完扩容

`btrfs filesystem resize` 在同一文件系统被多次挂载时打不开设备，而 initramfs 为了写记录和扩容前的
分区表恰好要挂两次。它在那边失败时会往 `.ab/grow` 写 `result=fail:btrfs-resize` 并继续启动。

系统起来后由 `ab-boot` 补做：运行期 `/mnt/p4` 是该文件系统的唯一挂载，正是 btrfs-progs 需要的独占
状态，于是它执行 `btrfs filesystem resize max /mnt/p4`，把 btrfs 自己的输出追加到
`ab/log/resize.log`，在环形日志里加一行 `stage=resize result=… source=ab-boot`，并把 `.ab/grow`
改回 `result=done`，让记录继续是唯一真相。这里失败只记日志，下一次启动再试。

## 日志

目录 `/boot/ab/log/`，总预算约 350 KiB。

| 文件 | 内容 | 轮转 |
|---|---|---|
| `boot-0.log` | 本次启动 | 每次启动轮转 |
| `boot-1.log` | 上次启动 | — |
| `boot-2.log` | 上上次启动 | 超出即删除 |
| `upgrade.log` | 最近一次更新 | 被下次更新覆盖 |
| `conflicts.log` | 最近一次冲突报告 | 被下次更新覆盖 |

- 单文件 32 KiB，超出截断并写入 `TRUNCATED=1` 标记
- 启动钩子每次启动最多 8 次写入，均为整文件写入：临时文件、`sync`、rename；健康检查随后追加自己的探针行
- 状态锁是 ESP 上的目录，里面写着 `<boot_id> <pid> <started_at>`；写下它的那次启动或进程若已不存在，
  锁会被自动接管（记 `stage=lock action=stale-lock-taken`），所以掉电或硬杀不会让机器再也提交不了
- 写入点：`initramfs-enter`、`lower-mounted`、`overlay-mounted`、`switch-root`、
  `slot-cfg`（GRUB 下次要读的提示）、`grow`（首启扩容结果）、`resize`（运行期补做的扩容，见下）、
  `healthcheck-done`、`commit` 或 `abandon`、`done`

记录字段冻结为 `key=value`：

```
stage=<阶段> slot=<a|b> upper=<层名> rootfs=<版本> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail> [reason=<token>]
stage=preflight slot=<a|b> result=fail reason=<proc-cmdline-unreadable|proc-mounts-unreadable|sysfs-missing>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed|slot-cfg-not-written|btrfs-resize>
action=<commit|reboot-to-committed|degraded-boot>
next=<a|b>
```

## 命令

| 命令 | 用途 |
|---|---|
| `ab-slot status` | 槽、代号、挂载点、下次启动、最近结果 |
| `ab-slot log [--prev\|--upgrade]` | 日志 |
| `ab-slot conflicts` | 冲突报告 |
| `ab-slot gc [--dry-run]` | 回收 |
| `ab-slot rollback` | 切回另一槽 |
| `ab-slot next [--write]` | GRUB 下次会启动哪个槽，以及重写它的自愈 |

## 边界

回退深度为一层。更新会覆盖目标槽的 rootfs，更早的 rootfs 已不在磁盘上。
