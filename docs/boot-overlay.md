# 引导链与三层挂载

## 引导流程

1. GRUB 从 p1 读取槽状态与 `grubenv`，选择内核与 initrd
2. initramfs 按 PARTLABEL 找到 p2/p3/p4，先挂 p4 写层，再挂槽内只读层
3. 合成 overlayfs 根
4. `switch_root` 进入系统，p1 挂到 `/boot`

## 三层职责

| 层 | 子卷 | 模式 | 内容 | 谁写 |
|---|---|---|---|---|
| 上游系统 | `@sys` | ro | 上游 rootfs，逐字节一致 | 仅升级时 |
| 平台层 | `@wf` | ro | `ab-slot`、init.d 钩子、修复工具 | 仅升级时 |
| 用户写层 | `@overlay.genN` | rw | 配置、安装的包、自建文件 | 运行期 |

`@wf` 与槽版本绑定：升级写槽时一并更新，回滚时随槽一起退回。

## 挂载参数

```
/ = overlay(
      lowerdir=/mnt/wf:/mnt/sys,
      upperdir=/mnt/p4/@overlay.gen0002/upper,
      workdir=/mnt/p4/@overlay.gen0002/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` 顺序固定 `@wf:@sys`，平台层优先
- `index=off` 避免 in-use 排他锁与恢复后 index 项失配
- 不使用 `volatile`

## 挂载顺序

1. `mount -o rw,compress=zstd:6,discard=async` 挂 p4 的 `@overlay.genN`
2. `mount -o ro` 挂 `@wf`
3. `mount -o ro` 挂 `@sys`
4. 断言 `/proc/mounts` 的挂载行包含 `compress=`

先挂 p4 的原因：`compress=` 只对文件系统的首次挂载生效，顺序错了参数不会进内核。

## 平台层如何生效

`@wf` 内按最终路径组织：

- `/usr/sbin/ab-slot`
- `/etc/init.d/ab-boot`
- `/etc/init.d/ab-commit`
- `/etc/uci-defaults/`

目录合并后 procd 从合并视图读取 `/etc/init.d/*`，钩子自然生效，`@sys` 不受改动。

## GRUB 渲染断言

渲染产物必须满足，否则构建失败：

- 包含 `set default=${committed_entry}`
- `save_env` 只传变量名，形式为 `save_env -f <grubenv> ab_try`
- 不出现 `save_env.*ab_try=`
- 不出现 `&&`、`||`、`${x:-y}`
- 占位符全部替换

## 槽启动失败与降级

| 故障 | 行为 |
|---|---|
| 内核/initrd 加载失败 | GRUB 内联重试，失败则 `set fallback` 回已提交槽 |
| initramfs 阶段失败 | 记录日志后重启，`ab_try` 已消费，回到已提交槽 |
| 健康检查失败 | abandon 并回已提交槽 |
| p4 挂载失败 | 重试 → `recovery` ro → tmpfs 降级启动，不判定槽损坏 |

降级启动时 `upperdir` 落在 tmpfs，系统可用但不持久；`ab-slot status` 仍可运行，因为 `@wf` 在 p2/p3 上。
