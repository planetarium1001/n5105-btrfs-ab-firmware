# SSH 交互调试

[English](debug-ssh.md) | **简体中文**

## 这个入口是什么

`ci-debug.yml` 是人工调试入口，不是流水线阶段。它装上引导类阶段需要的工具，跑与它们相同的 `scripts/ci/` 阶段，然后把 runner 交给一个可以 SSH 登录的会话。

- 触发：只有 `workflow_dispatch`。没有 `push`、没有 `pull_request`、没有 `workflow_call`。
- 门禁：没有。它不判定任何东西、不出结论，也没有别的 workflow 调用它。它只产出一份
  诊断产物 `debug-<stage>-logs`，保留 7 天：会话首次启动的构建日志与 guest 控制台。
- 时长：由 `timeout-minutes` 限定（会话步骤 200 分钟，job 240 分钟）。
- 访问：`limit-access-to-actor: true`，只有派发者自己的 SSH 密钥能进入 shell。

上面任何一条不再成立时 `scripts/check_design.py debug-ssh` 会失败，因此"有人把它接到了 `push` 上"是一次红色的设计校验，而不是一条评审意见。

## 为什么需要它（实测）

S1/S2/S3 是绿的，S4/S5 不是，而它们的失败需要从内部观察一次引导，而不是更长的日志。来自 run `42815980945`（2026-11-10）：

| Job | 墙钟 | 引导步骤 |
|---|---|---|
| s4 | 5 分 01 秒 | 四次引导分别 61 / 55 / 57 / 56 秒 |
| s5 | 失败 | 第 3 次引导用满了 900 秒的 `CI_QEMU_TIMEOUT`，然后失败 |

一次 push-and-wait 往返大约十分钟，而一次往返只买到一位信息：过或不过。一个会话拿到的是串口控制台、ESP、loop 设备和"先试一条命令再写代码"的机会。s4 job 从 checkout 到镜像就绪只要 62 秒，这正是"先把环境备好再进会话"的价值：最贵的一段在你连上之前已经跑完。

## 怎么触发

命令行，务必从 `main` 派发：

```sh
gh workflow run ci-debug.yml --ref main -f stage=s4 -f boot_timeout=1200
gh run list --workflow ci-debug.yml --limit 1
```

网页：**Actions** → **ci-debug** → **Run workflow**，分支选 `main`，再选 `stage`。

| `stage` | 进会话之前会跑什么 |
|---|---|
| `none` | 只装工具。最便宜的会话，用于读脚本、探 runner 能力。 |
| `build-disk` | `resolve` → `fetch` → `kmods` → `esp-prepare` → `platform-runtime` → `initramfs` → `disk` → GRUB 预检。不引导。 |
| `s4` | `build-disk`，加网络 fixture 与第 1 次引导（空镜像、提交槽 a）。 |
| `s5` | `build-disk`，加升级载荷、s5 fixture 与第 1 次引导（全新安装是健康的）。 |

`boot_timeout` 就是那次引导的 `CI_QEMU_TIMEOUT`。默认 1200 秒，不是阶段 workflow 用的 900 秒，因为 s5 的第 3 次引导需要超过 900 秒。

从 `main` 派发是硬要求：`workflow_dispatch` 跑的是**所选 ref 上的**工作流文件，所以在某个分支上派发，下面每一步执行的都是那个分支的版本。只在你愿意让它执行任意命令的 ref 上派发。

## 怎么连上

会话步骤每五秒打印一次连接串：

```
SSH: ssh <token>@<region>.tmate.io
```

```sh
ssh <token>@<region>.tmate.io
# 用的不是默认私钥时：
ssh -i ~/.ssh/id_ed25519 <token>@<region>.tmate.io
```

`limit-access-to-actor: true` 的语义是：tmate 只授权**派发这次运行的用户**在 GitHub 账号上登记的公钥。

- 你的 GitHub 账号上必须至少有一把 SSH 公钥（[添加公钥](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)）。一把都没有时该步骤直接失败：`No public SSH keys registered with <login>'s GitHub profile`。
- 日志是公开的，但连接串本身进不去：连接串是"地址"，私钥才是"凭证"。
- 如果日志里还出现了 `Web shell:` 链接，把它当成同等敏感的凭证，不要外贴：那是 bearer 链接，不受密钥校验保护。

## runner 上已经备好了什么

所有东西都在 `$RUNNER_TEMP/ci` 下，checkout 目录不动。

| 路径 | 内容 |
|---|---|
| `${RUNNER_TEMP}/ci/disk/n5105-ab-image.img` | 刚通过预检的 514 MiB GPT 镜像。 |
| `${RUNNER_TEMP}/ci/initramfs/boot.cpio.gz` | boot initramfs，含 `initramfs/boot/init` 与 s3 post 脚本。 |
| `${RUNNER_TEMP}/ci/fetch/upstream/kernel.bin` | GRUB 从 ESP 加载的上游内核。 |
| `${RUNNER_TEMP}/ci/esp`、`${RUNNER_TEMP}/ci/runtime` | 备好的 ESP 与 btrfs 运行时闭包。 |
| `${RUNNER_TEMP}/ci/logs/` | `debug-prepare.log`、`debug-fixtures.log`、`debug-boot1.log`。 |

准备步骤的 step summary 会打印同样的路径，直接复制即可，不用猜。

## 手工驱动一次引导

引导就是 `scripts/ci/qemu-smoke.sh` 加上阶段 workflow 传的那组环境变量，没有任何 CI 专属逻辑：

```sh
export CI_TMP_ROOT="${RUNNER_TEMP}/ci"
export CI_KERNEL="${CI_TMP_ROOT}/fetch/upstream/kernel.bin"
export CI_INITRAMFS="${CI_TMP_ROOT}/initramfs/boot.cpio.gz"
export CI_QEMU_DISK="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
export CI_QEMU_MODE=uefi-disk
export CI_JUDGE_PREFIX=""
export CI_QEMU_CASE=manual
export CI_QEMU_TIMEOUT=1800
export CI_QEMU_STOP_PATTERN='^(ab-commit: committed slot=|ab-commit: stage=healthcheck-done .*result=fail|ab-commit: stage=commit .*result=fail|ab-boot: stage=boot result=fail)'
bash scripts/ci/qemu-smoke.sh
```

`CI_JUDGE_PREFIX=""` 让运行在模式处停下而不是断言判定行：guest 从不给自己打分。随后像阶段那样把镜像读回来：

```sh
export CI_IMAGE="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
bash scripts/ci/grub-render.sh --verify-esp "${CI_IMAGE}"   # 状态文件与运行期槽文件是否一致
bash scripts/ci/ab-phase.sh --phase commit --slot a --expect-committed a --expect-pending none
bash scripts/ci/s5-phase.sh --phase toolchain --serial "${CI_TMP_ROOT}/qemu/serial-uefi-disk.log"
sudo losetup --find --show --partscan "${CI_IMAGE}"          # 手工挂 ESP
```

串口日志是 `CI_QEMU_DIR` 下的 `serial-<mode>.log`，上面那次引导对应 `${CI_TMP_ROOT}/qemu/serial-uefi-disk.log`。探针本该打印什么写在 `docs/lifecycle.md`，每个阶段的输入写在 `scripts/ci/README.md`。

要验证关于出货代码的假设，改 `scripts/` 或 `platform/` 下的文件后重跑引导：guest 内部看到的变化需要重建镜像（同样的环境跑 `bash scripts/ci/disk.sh`），而 `qemu-smoke.sh`、`ab-phase.sh`、`grub-render.sh` 可以对同一个镜像反复跑。

## 会话时长、成本与收尾

- GitHub 托管 job 的**硬上限是 6 小时**。这个 workflow 远早于此收手：会话步骤 200 分钟，job 240 分钟。
- `action-tmate` v3.24 **没有 `max-duration` 这个输入**——它的 `action.yml` 只声明 `sudo`、`install-dependencies`、`limit-access-to-actor`、`detached`、`connect-timeout-seconds`、`tmate-server-*`、`msys2-location` 和 `github-token`。限定时长的是 `timeout-minutes`，这也是设计校验要求存在、workflow 注释里写明的那一项。
- **job 还活着时断线可以重连**：tmate 会话比一次 SSH 断开活得久，同一个连接串还能再用。会话结束、步骤超时或运行被取消之后它才失效。
- **主动结束**：在会话里 `touch "${GITHUB_WORKSPACE}/continue"`，action 就会停止等待并让 job 收尾。会话步骤后面没有任何步骤，所以这就是干净的关闭方式；在界面里 Cancel 同样有效，也正是干脆走开时该点的按钮。
- **合上笔记本不等于关掉会话**：tmate 底层是 tmux，连接掉线后会话仍然活着并且照常计费。真正停掉它的是上面的时长上限，或者 Cancel。
- **成本**：会话打开期间占用计划内的一个并发 job（Free 20、Pro 40、Team 60、Enterprise 500）。忘了关的会话既烧 runner 分钟，也可能在忙时把真正的运行挤掉。
- **残留**：runner 是一次性 VM，job 结束后什么都不留。留下来的是运行日志，连接串会永久保存在里面。一次重要的会话之后把它删掉：`gh run delete <run-id>`（或在界面删除该运行）。
- 每个分支只允许一个会话：`concurrency` 组是 `ci-debug-<ref>` 且 `cancel-in-progress: true`，因此第二次派发会顶掉第一次，而不是排队两个交互式 runner。

## 安全

仓库是**公开**的（`gh repo view --json visibility` 在 2026-11-10 报 `PUBLIC`），本节大部分结论由这一点决定。

| 问题 | 答案 |
|---|---|
| tmate 会话默认是不是谁都能连？ | 是。`limit-access-to-actor` 默认是 `auto`，只有当派发者恰好登记了公钥时才收紧。本 workflow 设为 `true`，无条件收紧。 |
| 谁能派发这个 workflow？ | 只有对该仓库有写权限的用户。其他人无法开启会话。 |
| 谁能连进会话？ | 只有派发者登记的公钥。已合并 PR 的作者、别的维护者都不行，除非是本人派发。 |
| 会话里握着什么？ | 只读的 `GITHUB_TOKEN`（`permissions: contents: read`）、checkout 与构建临时目录。仓库没有 Actions secret，因此 runner 上没有可泄露的 secret。 |
| 那还是会泄露什么？ | 连接串、串口日志、以及会话里敲的每一条命令，全部在公开的运行日志里。默认假设日志是公开的，永远不要把带 secret 的 export 贴进去。 |
| 能被放宽吗？ | 只能靠改 workflow。托管 runner 上 `sudo` 不受限，因此会话里能装任何东西——但那只发生在一个随后被销毁的 VM 内，这也是它只能当调试工具、不能当安全边界的原因。 |

由上表得到两条规矩：

1. 从 `main` 派发，绝不在你不愿让其执行任意代码的分支上派发。
2. 会话结束后，日志不再需要时删掉这次运行。

## 为什么它不能替代 CI 门禁

会话不能证明仓库的任何事情：

- 它没有判定。`ci-debug` 的每一次预备引导都带 `continue-on-error`，最后一步是交互式 shell，所以一次"绿色"运行只意味着"会话开起来了"，不意味着"槽提交了"。
- 它不可复现。同一个提交上的两次会话看到的镜像可能不同，因为第二次是从第一次手工折腾过的镜像继续的。
- 它不跑在真正重要的事件上。`push` 与 `pull_request` 仍然走 `ci.yml` 及其阶段，`release.yml` 仍然由那些阶段构建发布。
- 被判定的路径没有移动：冻结的判定行、ESP 断言、`ci-s4.yml` / `ci-s5.yml` 里那四次带门禁的引导。会话里找到的修复要变成提交，而提交仍然必须让那些阶段变绿。

一个好习惯：用会话弄清"第 3 次引导为什么卡住"，写出让它不再卡住的最小改动，然后让下一次 push 作为证据。
