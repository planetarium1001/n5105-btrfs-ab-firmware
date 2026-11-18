# Known limitations

**English** | [简体中文](known-limitations.zh-CN.md)

A limitation here is a behaviour this project has decided **not** to change, together with
the evidence that says who owns it. Each entry states what a user sees, what the root cause
is, when it can and cannot happen, and how an automated probe has to be written so it
measures the machine instead of the measurement.

## Interactive SSH login on dropbear 2025.89

`ssh -tt <host> '<command>' </dev/null` - an interactive-looking session whose stdin is
already at end of file - fails on a healthy machine. The client is disconnected at once, and
the server logs three errors about the pty:

```
dropbear[31119]: ioctl(TIOCSCTTY): I/O error
dropbear[31119]: /dev/pts/0: No such file or directory
dropbear[31119]: open /dev/tty failed - could not set controlling tty: No such device or address
```

Nothing is wrong with the machine, and nothing is wrong with `/dev`. A person at a terminal,
or any client whose stdin stays open, logs in on the same machine and gets
`root@ImmortalWrt:~#`. Both sentences were measured on the reference machine on 2026-11-17,
minutes apart, in the same boot.

This entry exists because the first round of this project read those three lines as a defect
of the device nodes this project builds in its initramfs. That reading was wrong, and it sent
a whole repair round after a cause that does not exist.

## Root cause: the pty master is closed before the child owns the pty

The image carries **dropbear v2025.89** (musl), from ImmortalWrt 25.12.2. Upstream commit
`e28ba1b` ("Don't try to shutdown() a pty", 2023-12-09, first released in 2024.85) changed the
pty channel to `channel->bidir_fd = 0` in `src/svr-chansession.c`. With that flag,
`close_chan_fd()` in `src/common-channel.c` calls `m_close()` as soon as **either** direction
of the channel is finished. Before that commit the same function called `shutdown()`, which
on a pty simply fails with `ENOTSOCK` and leaves the real `close()` to the moment both
directions are done.

So when the client's stdin is already at EOF, the write direction finishes immediately,
dropbear closes the pty master, and the child process then runs `setsid()` and `TIOCSCTTY`
against a tty that no longer exists. The pty pair is destroyed before the login shell could
own it.

Upstream report: [mkj/dropbear#365](https://github.com/mkj/dropbear/issues/365), opened in
May 2025 and still open; the same `bidir_fd = 0` line is in dropbear master. The behaviour has
been noticed before against other tools:
[mosh-devel, 2013](https://mailman.mit.edu/pipermail/mosh-devel/2013-October/000637.html)
("dropbear does not like `ssh -n -tt` / `ssh -tt </dev/null`").

## What the three errors actually say

The three messages come from one function, `pty_make_controlling_tty()` in `src/sshpty.c`,
in this order. Each errno has exactly one producer in Linux 6.12, which is why the three lines
together identify the cause and rule out the alternatives:

| Message | Source | What that errno can mean |
|---|---|---|
| `ioctl(TIOCSCTTY): I/O error` | `sshpty.c:301` | `tiocsctty()` itself returns only `EPERM`. `EIO` comes from `hung_up_tty_ioctl()`: the line discipline is halted or `f_op` was replaced, i.e. **the tty is already hung up** |
| `/dev/pts/0: No such file or directory` | `sshpty.c:327` | `ENOENT` for a devpts slave is produced by `devpts_pty_kill()`, which runs when the **master** is released (or the devpts instance is removed) |
| `open /dev/tty failed - ... No such device or address` | `sshpty.c:333` | `ENXIO` is "this process has no controlling terminal". It is the **consequence** of the two lines above, never the cause |

Two hard readings follow: the last file descriptor of the pty master was closed before the
child could call `TIOCSCTTY`, and the `/dev/tty` node itself is fine.

## When it happens, and when it does not

Measured on the reference machine, one boot, one afternoon:

| Client | stdin | Result |
|---|---|---|
| `ssh -tt host '<cmd>' < /dev/null` | already at EOF | **fails**, three errors |
| `ssh -tt host '<cmd>' < <(sleep 12)` (a pipe that is open and empty) | open, no data | works: `fd0=/dev/pts/0`, `tty_nr=34816` |
| `printf 'echo X\n' \| ssh -tt host '<cmd>'` | one line, then EOF | works: the shell owns the pty before the EOF arrives |
| `ssh -tt host` (a login shell) `< <(sleep 25)` | open | works: MOTD plus `root@ImmortalWrt:~#` |
| `ssh host '<cmd>'` (no pty) | any | works, and proves nothing about pty |
| a person at a terminal, or a serial console | a terminal | works |

The trigger is therefore one property of the **client**: whether stdin has already reached EOF
when the channel opens. The server's `/dev`, `/dev/pts`, devpts options, `/dev/tty`, procd's
session handling and the A/B layout do not enter into it. The `askfirst` console on `ttyS0`
and `tty1` never closes stdin and is not affected.

## What is not the cause

- **Not this project's initramfs `/dev`.** The runtime `/dev` belongs to procd: it mounts a
  fresh `tmpfs` on `/dev`, creates the nodes from `/sys/dev/{char,block}`, and mounts `devpts`
  on `/dev/pts`. Whatever an initramfs stage creates is invisible afterwards.
- **Not the devpts mount options.** Remounting `/dev/pts` as `mode=620,ptmxmode=666` was
  measured: the `</dev/null` form still failed and the open-stdin form still worked. The
  shipped `mode=600,ptmxmode=000` is the kernel default that upstream procd gets by passing no
  options at all.
- **Not `/dev/ptmx`, `/dev/tty` or the devpts instance.** `/dev/ptmx` is the char device 5:2,
  `/dev/tty` exists, the slave node appears in the visible `/dev/pts` and is then unlinked -
  the sampling in the root cause section shows both steps.
- **Not the `gid=5` on the devpts mount, and not the missing `tty` group.** The slave node is
  owned by `root` with mode 0622 in this image; neither value decides success.

## The theme is a bench package, not part of the image

A clean flash of a release image comes up on `bootstrap`: the upstream rootfs carries no
`luci-theme-argon` and nothing installs one. Argon (with `luci-app-argon-config` and its
zh-CN translation) is installed by `scripts/device/bench-setup.sh` on a machine that is
being looked at, and the script reports `theme_source=installed` when it did the work.

Decided 2026-11-18: the image keeps the upstream default. A release that shipped a theme
would be a deliberate deviation from upstream for no functional gain, and it is the kind of
extra that has to be kept in step with every upstream rebase.

## A package follows the base only when the follow can run

An upgrade replaces the system tree; the packages a user installed live in the writable layer and
keep the version they were installed at. That is deliberate - re-resolving the world inside the
upgrade would make the upgrade itself the fragile step - so from 0.0.13 the packages are followed by
their own transaction, after the base is switched (see
[update.md](update.md#how-packages-follow-a-base)). It is one `apk upgrade` over the world, judged
by what it printed, and it can fail without touching the system that just booted.

What this still does not cover:

* **No network and no prefetch.** The follow needs bodies. If the prefetch could not run and the
  machine is offline (or behind a captive portal) on its first boot, the packages stay where they
  are and the record says `follow=pending reason=network`. The network fallback retries for a day
  (`follow=abandoned` afterwards) and `ab-packages update` retries on demand; nothing else moves
  them, and the machine is otherwise completely usable.
* **A local package with no kept body.** A package installed from a `.apk` file has no source, and
  apk keeps no copy (`/var` is a tmpfs; measured 2026-11-18: `find / -name '*.apk'` finds nothing on
  a machine carrying four local packages). Such a package is `NO COPY` in the plan block and
  `skipped=local:<name>` in the record: it keeps the version it has until somebody keeps a body
  (`ab-packages replay <file>`).
* **A body built for another kernel.** A local package that depends on `kernel=<hash>` cannot be
  replayed onto a base with another kernel, and replaying it would install a module that cannot
  load. It is `ABI STALE` and stays installed at its old version.
* **A package upstream dropped.** It keeps working with the files it has, only its own startup will
  tell, and the `world` entry is removed so the next upgrade stops trying. The matrix judges the
  sample set listed in `tests/fixtures/follow-samples.json` after every hop, which is how such a
  package is caught before a user finds it.
* **The prediction can be wrong.** The plan block is rendered from `apk --simulate` against a staged
  copy, and a feed can change between the question and the boot. The record is the fact; a block
  that promised 39 packages and a record that says 37 is not a contradiction, it is a prediction
  and a measurement.

## `*.apk-new` files are not merged for you

apk protects a configuration file it finds edited: the user's file keeps its bytes, and the
package's own copy is written beside it as `<file>.apk-new`. That property is what makes a package
follow safe: `tests/modules/upgrade/test_local_assets.sh` asserts it around a replay, and it was
measured on this board (`apk upgrade dnsmasq-full` kept an edited `/etc/config/dhcp` byte for byte
and wrote `dhcp.apk-new`).

What it is not is a merge. A `*.apk-new` file is evidence that the package changed something the
user also changed, and nothing in this project reads, merges or deletes it: the difference sits
there silently until somebody looks. Two ways to look:

```sh
find /etc/config -name '*.apk-new'                    # what is waiting for a decision
apk audit --backup /etc/config                        # what apk's database says differs
```

Deciding is manual on purpose: a merge that a machine picks itself is how a firewall rule or a
network interface disappears without anybody editing it. From 0.0.13 the plan block counts the files
it will not overwrite (`Config: N files differ from their package`), so the size of the decision is
visible before the upgrade rather than after it.

## The bench opens the whole WAN zone on purpose

A machine being debugged on a lab LAN runs with its WAN zone opened completely
(`wan input ACCEPT`, see `scripts/device/wan-open.sh`). That is a bench state, not shipped
behaviour and not a claim about the product: enumerating the ports that happen to be needed
(22 for the `-wan-ssh` variant, 80 for the web UI, 443 when a theme adds it) turns every
missing rule into a fault that looks like a product defect - the web UI "does not load"
when it is in fact answering `403` with its login page.

The release images keep the upstream default (WAN input `REJECT`); the `-wan-ssh` variant
opens 22 only. `scripts/device/wan-open.sh --restore` puts the firewall back from the backup
the driver wrote to `/root/firewall.before-open-wan.bak` and verifies its sha256.

## Why this project does not fix it

The failure is in dropbear, between a client that closes stdin early and a server that treats
either direction's end as the end of the pty. Neither half is ours, and both plausible fixes
move the image away from upstream:

- Patching dropbear means carrying a patch through every dropbear bump, on a package that
  also carries OpenWrt's own patches (including the blank-root-password one).
- Replacing dropbear with OpenSSH means a second daemon, a second configuration surface, a
  larger image and a different authentication story for an image whose whole point is "upstream
  plus A/B".

This project's rule is to stay with upstream wherever the difference buys nothing for the
device owner. An owner logging in by hand is not affected; only our own probes were.

**Three ways out, if that trade ever changes** (each is a task of its own, none is in scope
here):

1. **Install OpenSSH** (`openssh-server`) for interactive sessions, alone or with dropbear on
   another port. Largest divergence: extra package, extra configuration, two daemons to keep
   in sync.
2. **Patch dropbear**: restore the `shutdown()` path, or keep a duplicate of the master fd
   alive (for example via `TIOCGPTPEER`) until both directions are done. Small divergence, but
   the patch has to be re-validated on every dropbear bump, and it needs an entry in the
   upstream watch.
3. **Wait for upstream** and take the fix with the next rebase. `mkj/dropbear#365` is the
   thing to watch; [daily-upstream-watch.md](daily-upstream-watch.md) and
   `scripts/ci/upstream-watch.sh` are where a fix would surface.

## How a probe must drive an interactive session

An automated probe that asks "can something log in interactively?" has to keep the client
stdin **open** for the length of the session. Two forms are equivalent to a person's terminal,
and only these two:

```sh
# a keeper process holds stdin open and writes nothing: the measured form
ssh -tt -i "$KEY" root@<host> 'readlink /proc/$$/fd/0' < <(sleep 8)

# the same thing without process substitution, for POSIX sh
sleep 8 | ssh -tt -i "$KEY" root@<host> 'readlink /proc/$$/fd/0'

# a login shell, no remote command; the output must end in a prompt
sleep 8 | ssh -tt -i "$KEY" root@<host>
```

In this repository that primitive is `dev_ssh_tty` in `scripts/device/lib.sh`, with
`scripts/device/login-probe.sh` as the probe built on it:

```sh
scripts/device/login-probe.sh --hold 8        # probe=pty and probe=login, one line each
scripts/device/login-probe.sh --dry-run       # print what would be sent
```

**The boundary of the approximation.** The keeper pipe proves that the server can allocate a
pty, set a controlling terminal and start a login shell for a client that does not close stdin
early. It does not prove that a person's keystroke arrives faster than the hold; it says
nothing about terminal size, flow control or job control; and it says nothing about a physical
console, which goes through `askfirst` and `login.sh` and has to be checked by a person in
front of the machine.

Two traps that cost a measurement each:

- A pty is in cooked mode, so the slave side turns `\n` into `\r\n`. A probe that matches
  `^tty_nr=[0-9]+$` against the raw capture of a pty matches nothing; strip `\r` first.
- This image's busybox has no `tty` applet (measured: `command -v tty` prints nothing), so
  `ssh -tt ... tty` answers `ash: tty: not found` on a perfectly healthy machine. Use
  `readlink /proc/$$/fd/0` and field 7 (`tty_nr`) of `/proc/<pid>/stat` instead.

## Reproducing it

Both commands are read-only; the second one is what a probe has to do.

```sh
K="-i .workflow/secrets/n5105-device-ssh-key -o StrictHostKeyChecking=no \
   -o UserKnownHostsFile=/dev/null -o ControlMaster=no -o ControlPath=none"

# the false negative: the client is dropped, the server logs the three errors
ssh -tt $K root@192.168.2.49 'echo probe' </dev/null
ssh $K root@192.168.2.49 'logread | tail -n 5 | grep -i dropbear'

# the same question, asked correctly: a pty, a controlling terminal, a prompt
sleep 8 | ssh -tt $K root@192.168.2.49 'readlink /proc/$$/fd/0; awk "{print \$7}" /proc/$$/stat'
sleep 8 | ssh -tt $K root@192.168.2.49
```

The first pair prints `ioctl(TIOCSCTTY): I/O error`, `/dev/pts/0: No such file or directory`
and the `/dev/tty` line; the second pair prints `/dev/pts/0`, a non-zero `tty_nr` (34816 for
`pts/0`) and `root@ImmortalWrt:~#`.

The `</dev/null` in the first block is the anti-pattern this note is about, written out once so
it is recognisable; it is not a form to copy into a probe. Every interactive check in this
repository goes through `dev_ssh_tty`, which never redirects stdin away from the keeper.

## Historical package feeds and the kernel ABI

An official mirror keeps the release directory of every version it has published, so a stepped
upgrade or a downgrade can still name an older release. The kernel does not travel with it: the
kmod feed is filed under the kernel segment, and the segment changes with every kernel bump.

| Release | kmods segment | `kmod-usb-storage` | user-space index |
|---|---|---|---|
| 25.12.0 | `6.12.87` | `6.12.87-r1` | same bytes as 25.12.2 |
| 25.12.1 | `6.12.94` | `6.12.94-r1` | same bytes as 25.12.2 |
| 25.12.2 | `6.12.103` | `6.12.103-r1` | same bytes as 25.12.0 |

Measured 2026-11-19 against `https://downloads.immortalwrt.org`. The user-space index of the
three releases is the same file, and `targets/x86/64/kmods/<segment>/` exists only in the
release whose kernel it was built against.

- **Symptom.** A feed line taken from an older release offers the user-space packages and none of
  the kmods. `htop` is in that release's index, `kmod-usb-storage` is not, and the kmod directory
  for the running kernel's segment answers 404 under that release.
- **Cause.** kmods are filed by kernel build, not by release. The aligner touches both halves of
  a feed URL:
  - every `/releases/<x>/` and every `/kmods/<segment>/` is rewritten to the values of the
    release the slot now runs (`platform/lib/upgrade/packages.sh:243-270`).
  - the segment is read from the target base's own feed file rather than guessed
    (`platform/lib/upgrade/packages.sh:228-241`).
- **Scope.** Only the kmod feed needs a historical directory, because the user-space index of the
  three releases is byte-identical. A feed that still names another release makes the follow
  record `packages=limited packages_reason=feeds-stale` (`packages.sh:1109-1118`). `distfeeds.list`
  and `repositories.d/*.list` are the files the aligner aligns, so a historical release named
  there is moved to the running release at the next hop.
- **Workaround.**
  - Put a historical feed in `/etc/apk/repositories.d/customfeeds.list`. The aligner and the
    follow's feed probe both skip that file (`packages.sh:442-446`, `packages.sh:701-708`,
    `platform/lib/ab-net-probe.sh:296-305`).
  - Take kmods by segment, and let each package version follow the segment the base runs.
  - When a segment is no longer served, mirror its index, its `.sig` and its apks into a local
    HTTPS feed and keep the signature, then point `customfeeds.list` at it
    ([update.md](update.md#build-your-own-feed)).
  - `ab-packages sources <name>` names the source that offers a package, with the full URL
    ([update.md](update.md#the-package-commands)).

## Packages that the target release does not publish

A move between releases can leave the `world` file naming a package the target release never
built. One such name makes every later apk transaction fail to solve, so the follow drops it from
`world` before the transaction runs. Nothing is uninstalled and no configuration is touched.

- **Symptom.** The follow logs the count and the names it dropped:
  `packages: dropped 1 world entr(y|ies) this base does not offer: <names>`
  (`platform/lib/upgrade/packages.sh:2258-2260`). In the same boot, `ab-slot status` keeps
  printing the `packages=` and `packages_reason=` pair
  ([install.md](install.md#reading-packages-and-packages_reason)). A world left with nothing
  this release publishes is recorded as `packages=limited packages_reason=pruned`
  (`packages.sh:1151-1154`).
- **Cause.** `world` outlives the release that supplied its entries. apk refuses a whole set for
  one name it cannot select, so the follow transaction, `ab-packages update` and a hand
  `apk add kmod-x` all fail on the same entry (`packages.sh:963-983`, `packages.sh:2248-2254`).
- **Scope.** The prune rewrites `/etc/apk/world` and nothing else (`packages.sh:877-921`). It
  does not uninstall the package: its files and its `/etc/config` stay (`packages.sh:972-975`),
  and `/data` is not involved. A pin whose version is gone is kept, because the index still
  offers the name (`packages.sh:856-875`, `packages.sh:1034-1038`). Two gates hold it back:
  - an index that answers nothing for any name is not evidence that the release offers nothing,
    so nothing is dropped (`packages.sh:924-961`, `packages.sh:1026-1031`, reason
    `index-unusable`).
  - a caller whose index refresh failed says so, and nothing is dropped
    (`packages.sh:1018-1025`, reason `index-stale`).
- **Workaround.**
  - Read `packages=` and `packages_reason=` before a downgrade, and again after its first boot
    ([install.md](install.md#reading-packages-and-packages_reason)).
  - Take `ab-slot packages snapshot` before the hop, so the installed version of every package is
    recorded and can be replayed ([update.md](update.md#package-updates)).
  - A package the target does not publish keeps running at its version. Moving it needs a feed
    that carries it, or a body kept from the install
    ([update.md](update.md#keeping-a-local-package-body)).
