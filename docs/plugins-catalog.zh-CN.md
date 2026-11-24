# 我们跑过的插件配方

[English](plugins-catalog.md) | **简体中文**

本页是「在真机上量过的插件配方」的短清单：每节一份声明、跑过的步骤，以及跑出来的结果。机制
——`plugin.conf` 的字段、四个命令、三条护栏——在 [plugins.zh-CN.md](plugins.zh-CN.md)，这里不
重复。这份清单存在的理由，是让第二个人不必从字段表开始猜。

一份配方是一份声明，加上跑它之前一个人需要知道的事。被列在这里，意味着这份配方在参考机上从头
到尾跑过，并且下面写出的结果是在那台机器上看到的。它不意味着别的：既不意味着我们背书那个来源，
也不意味着那个来源明天还会回答。

## 清单

| 配方 | `kind` | 默认 | 装什么 | 源 | 需要 key | 一句话作用 |
| --- | --- | --- | --- | --- | --- | --- |
| [`istore`](#istore) | `packages` | `enabled = no` | `luci-app-store`，以及它自己的依赖在同一次事务里拉进来的 16 个包 | `https://istore.istoreos.com/repo-apk/all/` 下三个 `packages.adb` 索引 | 是，`/etc/apk/keys/istore-apk.pem` | 一个 OpenWrt 的第三方应用商店，没人打开之前一直是关的 |

「装什么」这一列是实测的数量，不是 `package` 的行数：一个点名的包，一次事务 17 个包，之后每
一个都是 world 条目。

## iStore

**不背书，也不开启。** iStore 是 OpenWrt 的第三方应用商店。本项目不测它、不支持它、也不会打开
它。**镜像里不带任何插件声明**：镜像带的是机制，不是源。

这一页把配方留成一个文件，由你复制进去：

- [examples/plugins/istore/plugin.conf](examples/plugins/istore/plugin.conf)

它到手时是 `enabled = no`，一直到机器的主人来把它打开、读完 verdict、再做决定为止。下面写的
是一份跑成功过的配方长什么样，不是推荐。

复制到 `/etc/ab/plugins.d/istore/plugin.conf` 之后，声明长这样：

```text
api = 1
kind = packages
enabled = no
feed = https://istore.istoreos.com/repo-apk/all/store/packages.adb
feed = https://istore.istoreos.com/repo-apk/all/compat/packages.adb
feed = https://istore.istoreos.com/repo-apk/all/meta/packages.adb
package = luci-app-store
key = /etc/apk/keys/istore-apk.pem
```

### 它做什么

商店的树发布三个 apk 索引——`store`、`compat`、`meta`——配方把三个都声明了，所以商店会从中
任何一个里要的名字都能解析到。配方点名的东西就一个包：`luci-app-store`。其余全是 apk 解析出来
的，所以商店需要而基底 feed 里有的包，是从基底 feed 装的。

2026-11-21，在本发布线所带的基底上实测：

* `plugins check istore` 回答 `verdict=ok`，没有任何 shadow（`reason=none`）；
* `plugins apply istore` 一次事务装了 17 个包；
* 之后两次系统更新、每次都换了槽，那 17 个包仍在装好的状态，`/etc/config/istore` 与
  `/opt/docker` 也都在，跟随记录的是 `kept=259 dropped=0`。

### 怎么启用

把文件复制到 `/etc/ab/plugins.d/istore/plugin.conf`。这个目录在可写层，系统更新会把它带过去。
然后三条命令：key、check、install。

```sh
wget -O /etc/apk/keys/istore-apk.pem https://istore.istoreos.com/repo-apk/istore-apk.pem
ab-packages plugins check istore
ab-packages plugins apply istore
```

`check` 是唯一联网的命令；`apply` 先打印 plan 块、问这里每次写入都会问的那一个问题，回答之前
什么都不装。想在事务之前看 apk 会读的那个文件，`ab-packages plugins repos` 会把它打出来。

### 先放 key

`key` 是一次存在性检查，不是导入：那个路径下没有文件时，check 在取任何东西之前就以
`plugin-key-missing` 拒绝。这个文件是商店自己的公钥。它发布在
`https://istore.istoreos.com/repo-apk/istore-apk.pem`。

本项目不管 keyring，也不导入（见 [plugins.zh-CN.md](plugins.zh-CN.md#护栏)）。所以一个 feed
的保证就是一个 `https://` 地址加上 apk 自己做的那些检查——仅此而已。

### 风险与不做的事

* **版本跟着源走。** 这里没有钉任何版本：树今天发布什么，`apply` 就装什么，之后的跟随也维护
  什么。`allow-shadow = no` 是那条边界。如果这棵树开始提供 world 里已有某个包的**更高**版本，
  check 会用 `shadow:<name>` 把它拦下来，而不是让下一次跟随去动一个没人点名的包。
* **它会自己写一个 conffile。** `luci-app-store` 会装下
  `/etc/apk/repositories.d/compat.list`。那是包自己的行为，不是插件的：插件不在 `/etc/apk` 下
  写任何东西，它的三个 feed 也不出现在任何机器自己的 feed 文件里。这件事值得知道，是因为那个
  文件比配方活得久——卸掉商店时把它一并删掉。
* **这份配方只差一个 URL 就会坏。** 一棵重组了路径的树，下一次 check 回答的就不是
  `verdict=ok`；一个不再回答的 feed 是 `feed-unreachable`。那是配方诚实地失败，而不是装到一半
  才失败。
* **它不做什么。** 商店装上、也能访问；它本身没有任何一部分由本项目支持。插件之间没有依赖处
  理，不导入 key，没有界面，也没有卸载。插件不能给启动、安装或升级加一步，`plugins apply` 也
  不写 `/boot/ab/packages`——一个插件的包清单不是跟随的 verdict。

### 怎么关掉

```text
enabled = no
```

或者 `rm -rf /etc/ab/plugins.d/istore`。两种任选一种就够，都不需要重新 check。两种都不会卸
掉那 17 个包：包是 apk 的，删掉其中一个是 `apk del <name>` 的事，不是本项目的事。

关掉的插件也不再贡献它的 feed，所以之后某次跟随的 prune 可能丢掉只有这棵树提供过的 world
条目。包仍然装着、配置也在。把配方重新打开、再 check 一次，feed 就回来了
（见 [plugins.zh-CN.md](plugins.zh-CN.md#关掉一个插件)）。

## 写自己的配方

一份配方就是一份声明。字段表在 [plugins.zh-CN.md](plugins.zh-CN.md#声明文件)。八个键，其中
`api`、`kind` 与 `feed` / `package` 之一是最小集。四个命令与各自回答什么在
[plugins.zh-CN.md](plugins.zh-CN.md#四个命令)。

本页没有任何东西是可以闭眼照抄的模板。字段是契约，护栏对你写的声明和上面那份声明一样生效。

你自己的配方有的、而这份清单给不了的东西，是一次 check。先跑
`ab-packages plugins check <label>`，再跑 `ab-packages plugins apply <label>`。前者是问「这个
来源在这台机器上到底能不能用」，后者才是决定用它。

## 这份清单的边界

* **只列跑过的。** 试了一次没跑完的配方不在这里，check 过但从未 apply 的声明也不在这里。清单
  短是因为它是量出来的，不是因为它完整。
* **源会变。** 上面每个地址都是 2026-11-21 那天回答的。「现在还能不能用」的答案是
  `ab-packages plugins check <label>`，不是这一页。
* **一台机器、一条发布线。** 在参考机上、在某个基底上验证过的配方，不是对另一条发布线、另一个
  架构或另一个镜像站的断言。
* **列出来不是背书。** 被收录只说明跑过、以及跑出来是什么，不说明你该不该跑它。
