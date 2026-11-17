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
