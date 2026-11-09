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
| `overlay-writable` | `/overlay` 可写且剩余空间大于 5% |
| `fw4-present` | nft ruleset 非空且存在 `inet fw4` 表 |
| `wan-present` | `network.wan` 引用的设备存在 |

全部通过才提交。任一失败则放弃待提交槽，重启回到已提交槽。

`fw4-present` 不找常驻进程：ImmortalWrt 25.12 的 `fw4` 是一次性渲染器，加载 ruleset 后就退出，
可观测的状态就是 ruleset 本身。空 ruleset 正是这个探针要抓的故障。

`wan-present` 需要一个网络配置来指认设备。上游镜像首次启动前没有 `/etc/config/network`，
测试通过用户同样的可写层注入一份。

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
- 每次启动最多 8 次写入，均为整文件写入：临时文件、`sync`、rename
- 写入点：`initramfs-enter`、`lower-mounted`、`overlay-mounted`、`switch-root`、
  `healthcheck-done`、`commit` 或 `abandon`、`done`

记录字段冻结为 `key=value`：

```
stage=<阶段> slot=<a|b> upper=<层名> rootfs=<版本> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed>
action=<commit|reboot-to-committed|degraded-boot>
```

## 命令

| 命令 | 用途 |
|---|---|
| `ab-slot status` | 槽、代号、剩余空间、最近结果 |
| `ab-slot log [--prev\|--upgrade]` | 日志 |
| `ab-slot conflicts` | 冲突报告 |
| `ab-slot gc [--dry-run]` | 回收 |
| `ab-slot rollback` | 切回另一槽 |

## 边界

回退深度为一层。更新会覆盖目标槽的 rootfs，更早的 rootfs 已不在磁盘上。
