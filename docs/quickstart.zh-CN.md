# 快速上手

[English](quickstart.md) | **简体中文**

本页是这个产品的最短路径：写一次镜像、启动一次、装一个包、从发布 feed 升级一次、再回退一次。
每一步给出命令和判断这一步成功的结果，每一步背后的细节都在 [install.zh-CN.md](install.zh-CN.md)
与 [update.zh-CN.md](update.zh-CN.md)，所以本页保持成一张清单。

五步按顺序执行，机器放在台面上，并且盘里没有你还需要的东西。

## 开始之前

第一步之前需要两样东西：发布文件与机器。下面的清单就是这五步要读的东西，缺项现在就发现，而不是
等到第四步。

- 一个发布目录，含安装镜像、升级载荷、`SHA256SUMS` 与 `release-notes.md`
  （[install.zh-CN.md](install.zh-CN.md#需要准备什么)）。
- 一台走 UEFI 启动的 x86-64 机器，不支持 legacy BIOS 启动
  （[install.zh-CN.md](install.zh-CN.md#写盘之前先核对发布)）。
- 首启用的一台显示器与一把 USB 键盘。这块板子是 HDMI，是否引出 UART 排针尚未确认
  （[install.zh-CN.md](install.zh-CN.md#控制台上的首次启动)）。
- 一根接上游路由器的网线，另一根网线加一台笔记本接机器的 LAN 口。
- 机器上一个 `root` shell，供第 2 到第 5 步使用。第 1 步在写盘的那台 Linux 主机上执行。

## 第一步：写盘

先选资产，再写盘。两个安装镜像带着同一个内核、同一个 rootfs 与同一份升级载荷，唯一不同的值是
WAN 侧的 `22/tcp` 是否被接受（[install.zh-CN.md](install.zh-CN.md#该写哪一个文件)）。

| 资产 | 什么时候取它 |
| --- | --- |
| `n5105-ab-<upstream>-install.img.gz` | 每一台普通机器：完全没有 WAN 规则，与上游镜像的姿势一致 |
| `n5105-ab-<upstream>-install-wan-ssh.img.gz` | 机器从 LAN 侧够不到、又给不了键盘和显示器时：它接受 WAN 侧的 `22/tcp`，直到规则被删掉 |
| `image-probe` | 永远不要写：它找 `/dev/vda`，在真机上会直接关机 |

1. 核对发布。
   ```sh
   sha256sum -c SHA256SUMS
   ```
   预期：每个产物一行 `<file>: OK`。
2. 认出目标盘。
   ```sh
   lsblk -o NAME,SIZE,MODEL
   ```
   预期：出现的就是你要的那块盘，容量与预期一致，主机上没有别的设备占用这个名字。
3. 写入镜像，然后把写入刷下去。
   ```sh
   gunzip -c n5105-ab-<upstream>-install.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
   sudo sync
   ```
   预期：`dd` 以 0 退出并打印字节数，`sync` 在内核的写入真正落到介质之后返回。

`<upstream>` 是这次发布的上游基底（base），例如 `25.12.2`。`of=` 里的设备是参考机器上那块盘的
节点，请把它换成 `lsblk` 为你这块盘打印的节点。

写盘会销毁目标盘上的全部内容。结果是 514 MiB、四个 128 MiB 分区，其余都不用手工创建。用
`-wan-ssh` 镜像时，首启会打印三种关掉 WAN 规则的办法，LAN 侧一能应答就应当把规则关掉
（[install.zh-CN.md](install.zh-CN.md#该写哪一个文件)）。

## 第二步：首次启动

首次启动会自己写出网络配置，并提交它启动的那个槽（slot）。失败也只在控制台上报出来，机器同样是在那里
被认出来的。

- LAN `192.168.100.1/24` 落在 `br-lan` 上，桥口是 `eth1`、`eth2`、`eth3`，并带一个 DHCP 服务。
- WAN 是 `eth0`，`proto dhcp`。
- hostname `ImmortalWrt`，时区 `GMT0`。

1. 在控制台上读网络那一行。
   ```sh
   ab-slot log | grep net-seed
   ```
   预期：`stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24`。
2. 读状态行。
   ```sh
   ab-slot status
   ```
   预期：一行输出里带 `committed=a`、`p4=ok`、`boot=ok` 与 `esp=ok`。这四个值就是本页对「一次
   好的启动」的判据：槽被提交了，这次启动被记录下来了，ESP 读得出来。
3. 从 LAN 侧连上机器。
   ```sh
   ssh root@192.168.100.1
   ```
   预期：出现登录提示。LuCI 在 `http://192.168.100.1` 上应答同一个地址，镜像带的是上游的 root
   账号且口令为空，所以请在机器离开台面之前设一个口令。

新写的盘上 `packages=` 读作 `unknown`，一块从未更新过的盘没有别的答案
（[install.zh-CN.md](install.zh-CN.md#怎么读-packages-与-packages_reason)）。种子失败时，控制台
会留下 `stage=net-seed result=fail reason=<token>`，
[install.zh-CN.md](install.zh-CN.md#控制台上的首次启动) 给了一条不必等修复的进门办法。

## 第三步：装一个包

包用 `apk` 装进可写层（writable layer），这就是这一步需要第二步那份网络的原因。它不切槽：槽字段
一个都不动，因为系统更新与包事务是刻意分开的两件事
（[update.zh-CN.md](update.zh-CN.md#包更新)）。

1. 拉取包索引。
   ```sh
   apk update
   ```
   预期：退出码 0，说明 feed 应答了。从未跑过这一步的机器根本没有索引，那时 `apk add` 只会回答
   `(no such package)`（[update.zh-CN.md](update.zh-CN.md#包更新)）。
2. 装一个不依赖内核的包。
   ```sh
   apk add htop
   ```
   预期：退出码 0，并打印一行，给出 `htop` 的名字与 feed 提供的版本。`htop` 是本项目实测的纯
   用户态对照样本（`tests/fixtures/software-samples.json`）。
3. 确认包已经装上。
   ```sh
   apk list --installed htop
   ```
   预期：一行输出，给出 `htop` 与它的版本。设备探针断言的正是这条「装完之后的事实」
   （`scripts/device/software-probe.sh`）。
4. 写一条配置值，再把它读回来。
   ```sh
   uci set system.@system[0].hostname='bench-n5105'
   uci commit system
   uci get system.@system[0].hostname
   ```
   预期：读回来打印 `bench-n5105`，说明这个值已经落在升级会一起带走的那个文件里
   （[install.zh-CN.md](install.zh-CN.md#控制台上的首次启动)）。

这个包与这条值都住在可写层里。`packages=` 说的是「当前这个槽能不能装内核模块」：`aligned` 是
「能」，`limited` 是「元数据修好之前不能」，`unknown` 是「还没有结论」
（[install.zh-CN.md](install.zh-CN.md#怎么读-packages-与-packages_reason)）。新盘上的 `unknown`
不挡 `apk add`，但会挡住 `ab-slot packages upgrade`
（[update.zh-CN.md](update.zh-CN.md#包更新)）。第四步就是写出结论的那一步。

社区应用走的是同一条路：同样一条 `apk add <name>`，同样看一条装完之后的事实，而这条事实不总是
版本号。本项目实测的样本，以及每个样本看的是哪条事实，在
`tests/fixtures/software-samples.json` 与 `tests/fixtures/follow-samples.json` 里
（[troubleshooting.zh-CN.md](troubleshooting.zh-CN.md)）。

## 第四步：升级一次

升级写入非活动槽，并把它标记为待验证。运行中的槽全程不被碰，所以出问题机器照样能用
（[install.zh-CN.md](install.zh-CN.md#升级运行中的系统)）。那几道提问是唯一的关口，它们会说清
什么在变。

1. 问 feed 那边有什么。
   ```sh
   ab-upgrade --feed-check
   ```
   预期：一行字段输出，以 `status=update` 结尾，退出码 `10`。这条检查不下载载荷、不碰槽，
   `10` 是对那个问题的回答，而不是错误（[update.zh-CN.md](update.zh-CN.md#检查有没有更新)）。
2. 装上它，它提出的问题都答 `y`。
   ```sh
   ab-upgrade --feed
   ```
   预期：一个 `Update` 块，先是 `base`、`kernel`、`platform`，再是 `Change`、`Tested`、`Risk`，
   最后是 `Proceed? [y/N]`。载荷带包计划时，它后面还跟一个 `Packages` 块与
   `Proceed and follow N packages? [y/N]`。只有明确的 `y` 才算同意，回车、`n` 与输入结束都算
   拒绝，且什么都不写（[update.zh-CN.md](update.zh-CN.md#确认提示)）。
3. 读这次安装留下的状态。
   ```sh
   ab-slot status
   ```
   预期：`pending=<另一个槽>`、`next=<另一个槽>`，而 `committed=` 仍是这次启动在跑的那个槽。
   这次重启之前 `pending` 是目标槽，不是 `none`（[update.zh-CN.md](update.zh-CN.md#安装更新)）。
4. 重启，然后再读一次状态。
   ```sh
   reboot
   ```
   预期：启动之后 `committed=<另一个槽>`、`pending=none`、`next=` 与它相等、`p4=ok`。
   `generation=` 在这之前就已经变大了，因为安装会在重启之前就记下新的一层
   （`ab-slot` 的 `cmd_layer`）。健康检查失败的机器会自己回到已提交的槽上
   （[install.zh-CN.md](install.zh-CN.md#升级运行中的系统)）。
5. 读这次跳变留下的包结论。
   ```sh
   ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(packages|packages_reason|follow)='
   ```
   预期：包搬到新基底上时，这里是 `packages=followed` 与 `follow=followed`。若是
   `packages=aligned` 配 `follow=pending reason=network`，说明元数据已经对上、包还没有搬
   （[update.zh-CN.md](update.zh-CN.md#包怎么跟随一个基底)）。

## 第五步：回退一次

回退就是把另一个槽提交掉，那个槽里仍然是上一套文件系统与它自己的可写层。升级之后能启动但跑不
起来时，这是最快的回头路。它不是恢复出厂
（[install.zh-CN.md](install.zh-CN.md#回退)）。下面任一条成立时就回退：

- 新槽启动了也提交了，而你在它上面跑的东西不工作；
- 更新已经备好、你不想让它被试：`ab-slot abandon` 不启动就把它清掉
  （[install.zh-CN.md](install.zh-CN.md#回退)）；
- 变的只是包：`ab-slot packages revert` 重放最新一份快照，系统一点不碰
  （[update.zh-CN.md](update.zh-CN.md#包更新)）。

健康检查失败不需要手工动作，那次启动会自己放弃待验证槽，回到已提交的那个槽上。

1. 把另一个槽提交掉。
   ```sh
   ab-slot rollback
   ```
   预期：`ab-slot: rolled back from slot <a> to slot <b>`。
2. 重启进它。
   ```sh
   reboot
   ```
   预期：启动落在另一个槽上，并把它提交
   （[install.zh-CN.md](install.zh-CN.md#回退)）。
3. 确认机器现在跑的是什么。
   ```sh
   ab-slot status
   ```
   预期：`committed=<上一个槽>`、`pending=none`、`next=` 与它相等、`p4=ok`。`generation=` 停在
   原地，因为回退移动的是指针，而不是造出一个新的代
   （[architecture.zh-CN.md](architecture.zh-CN.md#升级事务)、`scripts/device/recovery-probe.sh`）。
4. 读你回退到的那个槽的包结论。
   ```sh
   ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(packages|packages_reason)='
   ```
   预期：记录描述的是被回退掉的那个槽时，这里是 `packages=unknown` 配
   `packages_reason=no-record`。下一次系统更新会为正在跑的槽写出结论
   （[update.zh-CN.md](update.zh-CN.md#包更新)）。

`/data` 下的文件由两个槽共用，原地不动。更新之后写下的内容留在被向前滚动的那一层里，只要还有槽
引用它，`ab-slot gc` 就不会删（[install.zh-CN.md](install.zh-CN.md#回退)）。

## 读状态行

`ab-slot status` 打印一行，一个字段一个 token，给人看的句子走 stderr。五个步骤要读的字段可以摊开
成一行一个：

```sh
ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(slot|committed|pending|next|p4|generation|boot|esp|packages|packages_reason|follow)='
```

预期：一行一个 `field=value`。下表是这些字段的含义，以及它们在机器上从哪里读。其余字段见
[update.zh-CN.md](update.zh-CN.md#字段表)。

| 字段 | 取值 | 含义 | 验证命令 |
| --- | --- | --- | --- |
| `slot=` | `a` / `b` | 这次启动跑的那个槽，来自内核命令行上的 `ab.slot=` | `grep -o 'ab.slot=[ab]' /proc/cmdline` |
| `committed=` | `a` / `b` | 状态文件里已提交的槽：在稳定的机器上就是下次启动会跑的那个 | `cat /boot/ab/state.json` |
| `pending=` | `none` / `a` / `b` | 下次启动会试的候选槽，由一次安装备好 | `cat /boot/ab/state.json` |
| `next=` | `a` / `b` / `unknown` | GRUB 下次启动的槽，从提示文件（hint file）读回 | `ab-slot next` |
| `p4=` | `ok` / `degraded` | 共享的可写分区是否挂上，其中 `degraded` 表示那次启动把可写层挪到了内存 | `awk '$2=="/mnt/p4"' /proc/mounts` |
| `generation=` | 只增不减的整数 | 给各层排序的编号 | `cat /boot/ab/state.json` |
| `boot=` | `ok` / `degraded` / `unknown` | 这次启动是怎么起来的，取自本次启动的环日志（ring log），其中 `degraded` 表示可写层是 tmpfs | `ab-slot log \| grep stage=boot` |
| `esp=` | `ok` / `dirty` / `unreadable` / `unknown` | initramfs 对它挂载的那个 ESP 的判定 | `ab-slot log \| grep stage=esp-health` |
| `packages=` | `aligned` / `followed` / `limited` / `unknown` | 这个槽的包元数据是否描述了它在跑的那个基底 | `cat /boot/ab/packages` |
| `packages_reason=` | `none` / `other-slot` / `no-record` / 某个对齐器（aligner）token | 那个结论为什么读成现在这样 | `cat /boot/ab/packages` |
| `follow=` | `pending` / `followed` / `failed` / `abandoned` / `never` | 包有没有真的搬到这个基底上 | `ab-packages status` |

`boot=`、`esp=` 与 `packages=` 在没有任何记录时读作 `unknown`，而不是读成一个让人舒服的默认值。
稳定的机器上 `committed=` 与 `next=` 相等，两者不一致就是重启之后第一个要看的东西。

## 三步各动了哪些字段

三步碰的字段不同。装包从不移动槽，升级在重启之前就记下新的一层并抬高 `generation=`，回退把
`committed=` 移回去且不复制任何一层。

```text
  step 3  apk add htop
          |  可写层变大时，槽字段一个都不动
          v  committed=a  pending=none  next=a  generation=N
             packages= 不变（从未更新过的盘上是 unknown）
  step 4  ab-upgrade --feed，然后重启
          |  重启之前：  committed=a  pending=b  next=b  generation=N+1
          v  重启之后：  committed=b  pending=none  next=b  generation=N+1
             packages=followed  follow=followed
  step 5  ab-slot rollback，然后重启
          |  指针移回去，不复制任何一层
          v  committed=a  pending=none  next=a  generation=N+1
             packages=unknown  packages_reason=no-record
```

## 接下来读什么

其余文档在四个方向上深入：模型、feed、备份与边界。每一页都是自己那个主题的唯一来源，本页不重复
它们。

- [update.zh-CN.md](update.zh-CN.md)：字段参考、A/B 状态机，以及包跟随与
  剪枝背后的闸门。
- [update.zh-CN.md](update.zh-CN.md)：发布 feed、三个版本号、五个风险级别，以及每一个
  `reason=` token。
- [backup.zh-CN.md](backup.zh-CN.md)：三种产物，以及各自能恢复到什么介质上。
- [troubleshooting.zh-CN.md](troubleshooting.zh-CN.md)：本项目决定不改的行为，以及那个决定
  背后的证据。
