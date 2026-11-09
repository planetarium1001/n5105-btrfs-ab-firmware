# 升级事务、回收与可观测性

## 代号模型

写层不叫 `@overlay`，叫 `@overlay.genNNNN`。每次升级创建新代号，**全程不做重命名**。

由此：

- 不存在"临时名被占用"，一直不重启也能直接快照当前状态成下一个代号
- 回滚只改指针，不搬运数据
- 稳态只需 2 个代号，一个槽一个

## 状态文件

ESP `ab/state.json`，原子写（temp → `sync` → rename）：

```json
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper_gen": 3 },
    "b": { "rootfs": "25.12.2", "upper_gen": 2 }
  }
}
```

## 时序

| 事件 | p4 | ESP |
|---|---|---|
| 装机 | 建 `gen0001`、`@docker`、`@swap`、`@data` | `a`/`b` → gen1，`committed=a` |
| 升级槽 B | `snapshot gen1 → gen2`，写 p3 | `pending=b`，`b` → gen2 |
| B 首启成功 | — | `committed=b`，清 pending，GC |
| 升级槽 A | `snapshot gen2 → gen3`，写 p2 | `pending=a`，`a` → gen3 |
| A 首启成功 | 删 gen1 | `committed=a`，清 pending |
| 回滚 | — | `committed` 切回另一槽 |

快照对象永远是当前 live 的代号。快照前 `sync` 并停止写服务；一致性口径是崩溃一致。

## 健康检查

在 `done` 之后执行，超时 150 s：

| 探针 | 通过条件 |
|---|---|
| `overlay-writable` | `/overlay` 可写且余量 > 5% |
| `fw4-present` | `fw4` 进程存在且 nft ruleset 非空 |
| `wan-present` | WAN 设备存在 |

全绿才 commit；任一失败即 abandon 并重启回已提交槽。

## 回收

引用集合 = `slots.a.upper_gen` ∪ `slots.b.upper_gen` ∪ `pending.upper_gen`。
不在集合内的 `@overlay.gen*` 全部删除。

四条安全约束：

1. 挂载中的代号不删（查 `/proc/mounts`）
2. `pending` 引用的代号不删
3. `btrfs subvolume delete -C` 后必须 `btrfs subvolume sync`，否则空间未真正释放
4. 盘满时不跑全量 balance（它自身需要 workspace）

触发点：commit 成功后、每次启动早期、升级失败后、手动 `ab-slot gc`。

空间阈值：

| 剩余 | 动作 |
|---|---|
| > 15% | 正常 |
| < 15% | 告警并自动 GC |
| < 5% | `platform_check_image` 返回 74，拒绝升级 |

不使用 qgroup 配额；按需 `btrfs filesystem du -s` 计算独占空间。

## 日志

目录 `/boot/ab/log/`，总预算约 350 KiB。

| 文件 | 内容 | 轮转 |
|---|---|---|
| `boot-0.log` | 本次启动 | 每次启动轮转 |
| `boot-1.log` | 上次启动 | — |
| `boot-2.log` | 上上次 | 超出即删 |
| `upgrade.log` | 最近一次升级 | 下次升级覆盖 |
| `conflicts.log` | 最近一次冲突报告 | 下次升级覆盖 |

- 单文件上限 32 KiB，超出截断并写 `TRUNCATED=1`
- 每次启动写盘不超过 8 次，整文件写出：temp → `sync` → rename
- 写入时机：`initramfs-enter`、`lower-mounted`、`overlay-mounted`、`switch-root`、
  `healthcheck-done`、`commit`/`abandon`、`done`

判读串冻结为 `key=value`：

```
stage=<阶段> slot=<a|b> upper_gen=<N> rootfs=<版本> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed>
action=<commit|reboot-to-committed|degraded-boot>
```

## 命令

| 命令 | 用途 |
|---|---|
| `ab-slot status` | 槽、代号、空间、最近结果 |
| `ab-slot log [--prev\|--upgrade]` | 日志 |
| `ab-slot conflicts` | 冲突清单 |
| `ab-slot gc [--dry-run]` | 回收 |
| `ab-slot rollback` | 切回另一槽 |

## 边界

只能回滚**一代**。升级会覆盖目标槽的 rootfs，更早的 rootfs 已不存在。
