# 交接：N5105 Btrfs A/B 固件（v2）

> 时间：2026-11-09
> 用途：新上下文接手时的唯一入口。先读本文，再读 `docs/`。
> 当前状态：设计定稿、CI 骨架跑通、阶段 S0 完成。下一步是 S1。

## 0. 一句话现状

仓库 `planetarium1001/n5105-btrfs-ab-firmware` 已有双语设计文档、可执行设计断言、
并行的测试框架、以及一条**真实跑绿**的 GitHub Actions 流水线。
`VERSION = 0.0.0`，S1（上游消费 spike）尚未开始。

## 1. 项目定位

- 只做系统层：**A/B 双根 + btrfs**。业务组件与具体使用场景不在范围。
- rootfs 与上游 ImmortalWrt **逐字节一致**；自有内容只在构建层、引导层与 `@wf` 平台层。
- 单板 N5105 v5、x86-64、UEFI-only、EFI-only 四分，不做 legacy 与多主板。
- 仓库公开，**只发布代码与文档**；`.workflow/`、`.dsh/`、`AGENTS.md`、知识库、任务记录一律不入库。

## 2. 已定稿的技术决策（不要再重新论证）

| 决策 | 取值 |
|---|---|
| 构建路线 | **A 上游消费**：CI 下载官方 rootfs/kernel/kmod，自建 initramfs 并装配。不编译内核 |
| 分区 | p1=128 MiB vfat（只放数据）、p2=p3=128 MiB btrfs（各含 `@sys`+`@wf`）、p4=至盘尾 |
| 运行期根 | overlayfs 三层：`lowerdir=@wf:@sys`、`upperdir=@overlay.genN/upper`、`index=off` |
| 写层 | **代号推进** `@overlay.genNNNN`，全程不重命名；快照对象永远是当前 live 代号 |
| 状态 | ESP `ab/state.json`：`generation`/`committed`/`pending`/`slots[*].upper_gen` |
| 回退 | 一次启动失败即回已提交槽；`done` 后三探针健康检查全绿才 commit |
| 回收 | 按引用集合回收，稳态 2 个代号；盘剩余 <5% 拒绝升级（return 74） |
| 日志 | ESP 环形缓冲 `boot-0/1/2.log` + `upgrade.log` + `conflicts.log`，单文件 32 KiB |
| 冲突 | A/B/U 三方比对，内容哈希，**报告不阻断**；uci 走 `uci-defaults` 幂等迁移 |
| 版本 | `MAJOR.MINOR.PATCH`，MAJOR 恒 0；全部验证通过后升 0.1.0 |

## 3. 实测基线（已核对，可直接引用）

| 项 | 值 |
|---|---|
| 上游版本 | ImmortalWrt 25.12.2，kernel 6.12.103 |
| `rootfs.tar.gz` | 10.1 MiB，sha256 `29b6a86c9bc14a10dc1769f0c4afe33092ce669f667a5b7636d25271aff6a3cb` |
| 解压后 rootfs | 26.9 MiB / 1078 文件；`zstd:6` 后 10.3 MiB |
| `generic-kernel.bin` | 7.35 MiB，sha256 `980c16f57a5178abf0ac8fadbac2fcad965d92fbacf70c5334704b4aba420113` |
| btrfs kmod | `kmods/6.12.103-1-0413601b1c3f0490e17f340fe09229ea/kmod-fs-btrfs-6.12.103-r1.apk`，713 KB，sha256 `3eedbe9ab758138395de85496e75fc7d1ff7b71eaff3e0eb83caaaeb9bbe3e55` |
| 官方内核含 btrfs | **否**（`config.buildinfo` 无 `CONFIG_KERNEL_BTRFS_FS`，227 包 manifest 无 btrfs） |
| 升级载荷 | 约 20 MiB |

## 4. 仓库结构

```
.github/workflows/    ci.yml（唯一入口）+ ci-{resolve,fetch,assemble,verify,report}.yml
scripts/ci/           阶段逻辑：lib.sh 为共享函数与固定量，其余每阶段一个脚本
scripts/check_design.py  设计文档的可执行断言（10 项）
tests/run.sh          并行测试入口；tests/modules/<module>/test_*.sh
tests/lib/            assert.sh、run_one.sh
docs/                 四篇设计文档（英文主 + zh-CN 译文）
LICENSES/             MIT.txt、GPL-2.0-only.txt
VERSION               0.0.0
```

## 5. CI 现状与实际约束

- **已验证**：`resolve → fetch → verify → assemble → report` 五阶段全绿，37 秒；产物
  `upstream-files` 18.9 MB、`payload` 18.2 MB、五份 `diag-*`。
- `stage` 输入支持断点重跑：`all` / `fetch` / `assemble` / `verify`。
- 缓存键 = 上游版本 + 工具 epoch + 脚本摘要，实测改脚本即换键。
- **踩过的坑（勿重犯）**：
  1. GitHub **不支持** `.github/workflows/` 子目录，可复用工作流必须在该目录顶层。
  2. `runner` 上下文**不可用于 job 级 `env`**，用了会让整个工作流文件在解析期失败（0 job、
     "workflow file issue"）。路径类变量只能放 step 级 env 或脚本默认值里。
  3. 上游文件名带 `immortalwrt-<ver>-x86-64-` 前缀，目录页显示的是缩写名，真实名见 `sha256sums`。
- `gh` 已认证（token 含 `repo` scope），可读 Actions 日志；沙箱内需
  `export XDG_CACHE_HOME=/tmp/ghcache` 否则 gh 写缓存被拒。

## 6. 本地与环境约束

- 沙箱只允许写工作区：`~/.ssh/sockets` 不可写，git 已在该仓库设置
  `core.sshCommand="ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes"`（本地配置，不入库）。
- 本机为 macOS，无法跑完整 QEMU/镜像验证，**验证以 CI 为准**。
- 提交与推送已获用户授权（2026-11-09），无需逐次确认。

## 7. 工作流（.workflow/）状态

| 任务 | 状态 |
|---|---|
| `20261109-01-design-ab-btrfs-image` | phase=build，6 个单元全部 done，evidence ac-1..ac-10 已记录 |
| `20261109-02-ci-skeleton` | phase=build，单元 01 done，evidence ac-1..ac-6 已记录 |

注意：`.workflow/state/` 与 `task.json` 不许手改，一律走 CLI。

## 8. 下一步（按顺序）

1. **S1 上游消费 spike（当前最该做的）**：在 CI 里用官方 kernel + 官方 `kmod-fs-btrfs`
   构建最小 initramfs，QEMU 启动后确认 `btrfs.ko` 能加载并挂载 btrfs。这一步证伪或证实路线 A。
   - 需要先解决 `ci-owner` 提出的问题：kmod 依赖闭包（`btrfs.ko` 依赖 crc32c/zstd/lzo/raid6/xor/
     blake2b/xxhash 等 kmod）如何解析。建议用 kmods `index.json` 做传递求解，产出 lockfile。
2. S2 四分区装配（`sgdisk`/`mkfs`/拷贝，产出 `.img`）。
3. S3 initramfs + 三层挂载 + 代号推进。
4. S4 A/B 状态机 + GRUB 渲染断言 + 健康检查 + 失败注入。
5. S5 分区级 `platform.sh` + payload 契约 + GC/日志/冲突。
6. S6 真机首刷 + 升级 + 注入（high risk，单独任务）。

## 9. 派发约定（用户明确要求）

- 主对话负责统筹，不承担细碎实现。
- **持久化/需反复迭代**的工作派给 teammate（现有 `ci-owner` 拥有 `.github/**`、`scripts/ci/**`）。
- **一次性校验**（如变异测试、独立审计）派给干净子代理，用完即弃。
- teammate 与子代理**不 commit、不 push**，提交由 Lead 做。

## 10. 已知待办与小瑕疵

- `docs/` 曾把 `generic-kernel.bin` 记为 7.5 MiB，已修正为 7.35 MiB。
- `assemble` 阶段目前是空壳：只有 `rootfs.tar.gz` + `kernel.bin`，`missing_members` 记录
  `initramfs.cpio.gz`、`wf.tar`，下游校验会正确拒绝——这是刻意的，不是缺陷。
- 测试框架目前只有 `design` 与 `ci` 两个模块，后续按模块补齐。
- 设计文档改动后必须同步 `scripts/check_design.py`，否则 `verify` 阶段会红。
