# 真机矩阵执行

`scripts/device/` 通过 SSH 驱动一台真机，把一次升级、降级或重启变成一行 PASS/FAIL/GAP。
它存在的原因是：一个槽「能启动」不等于「没坏」——只有状态字段、breadcrumb 与存活的数据
标记三者同时成立，才能回答「这次跳变之后机器还能用」。

## 用途

A/B 模型只能由**真实上游版本**证明，改 manifest 里的版本号证明不了。矩阵因此在 CI
真实能构建的版本之间跳变（见 [`ci-pipeline.zh-CN.md`](ci-pipeline.zh-CN.md) 的
「构建非 pin 版本」），并在每次跳变后断言同一组不变量：

- `boot=ok` **且** `esp=ok` —— ESP 读不干净的启动不算通过；
- `generation` 严格递增、`pending=none`；
- 两个槽的 upper 都存在，且没有被引用的 `@overlay-*` 残留；
- 共享分区上的用户标记与 `/etc/config` 里的配置标记仍在；
- 启动日志里有 `stage=healthcheck-done result=ok` 与 commit 行。

最后一项最容易读错：本次启动的 mark 在轮转后位于 `boot-1.log`，所以驱动先看
`boot-0.log`，再看 `boot-1.log`，最后看 `ab-slot log --prev`，并记录是哪一份文件命中的。

## 怎么跑

```sh
scripts/device/matrix.sh --dry-run                    # 只打印计划，不动设备
scripts/device/matrix.sh --case M3 --payload-dir <dir>
scripts/device/matrix.sh --payload-dir <dir> --resume  # 跳过已 PASS 的用例
```

`--payload-dir` 里放 `payload-<version>.tar`。结果按
`case<TAB>verdict<TAB>evidence<TAB>note` 追加到 `--results`，一条用例一行；中断后的续跑
靠读这个文件，不靠记忆。

环境取自 `AB_HOST`（默认 `root@192.168.2.49`）与 `AB_KEY`。ssh 固定带
`ControlMaster=no`、`ControlPath=none` 与忽略 `known_hosts`：重刷过的机器会换主机密钥，
而跑驱动的沙箱没有可写的 `~/.ssh`。

## 用户场景

`scenarios.sh` 回答的是另一个问题：用户装过软件、写过数据、改过设置之后，跨版本跳变还能不能保住这些，
装过的软件还能不能用。

| 用例 | 造什么 | 判什么 |
|---|---|---|
| S1 预装 | 从该版本自己的 apk 索引里装 luci 应用、一个 CLI 工具、一个 kmod | 已装版本快照，以及索引里没有的包 |
| S2 用户态 | `/data` 下的文件与目录树、两个假 docker tar、自定义 `uci` 段、hostname、时区、一条防火墙规则 | 每个文件的 sha256、目录条目数、每项设置的 `uci get`，以及真实 `network reload` 之后 ssh 仍应答 |
| S3 / S4 跳变 | 低→高、高→低，带着预装软件 | 每跳之后同一组数据/配置/软件/挂载/服务判定 |
| S5 账本 | 最终内核 | 哪些包仍有效、哪个 kmod 需重装、平台层自报什么 |
| S6 引导工具 | 不造，只读 | ESP 上 `vmlinuz-<slot>`/`initrd-<slot>` 与 payload 的 `kernel.bin`/`initramfs.cpio.gz` 逐字节一致；平台层工具与 `platform.tar` 一致 |

两条让这些用例可信的规则：

- **不用旧格式判定**：包名取自该版本自己的 apk 索引，配置只在出厂文件上做最小追加——市面上流传的
  23/24 时代片段描述的是 opkg 与另一套防火墙模型。
- **机器自己留退路**：S2 在 reload 之前用 `setsid`（镜像没有时用 `start-stop-daemon -b`）排好自还原，
  以 `/tmp/ab-scen-net.ok` 取消；两者都排不上的机器根本不 reload，被跳过的那半段记 FINDING，
  而不是记一条"没看就通过"。

ABI 只报告不判定：换了内核后 kmod 不匹配在 apk 世界是正常行为，因此记成 `FINDING:` 并附重装清单，
不单独改变任何 verdict。

## 红线

安装写的是机器**没有在跑**的那个槽。驱动只在「运行槽 = committed 槽且没有排队候选」时
才允许安装；任何时刻发现「没有可回退的 committed 健康槽」就中止整轮（`exit 3`）。
破坏性用例排在可逆用例之后；失败的用例只记录、不夹带修——恢复路径是 `ab-slot`，不是手改
`ab/state.json`。

机器彻底起不来时没有自动恢复。这正是 `image-install` 产物存在的意义：刷回去，重来一次。
