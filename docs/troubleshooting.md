# Troubleshooting

**English** | [简体中文](troubleshooting.zh-CN.md)

What to read first when a machine misbehaves, what each symptom usually means, and the
behaviour this project has decided not to change. Read the log before changing anything: every
stage writes `key=value` lines, and every failure carries a `reason=` token that the build
reports too, so a machine and a build can be compared without guessing.

Prerequisites: a `root` shell on the machine, or the disk attached to another Linux. The
commands below are read-only unless stated otherwise.

## First reads

```sh
ab-slot status                    # one machine-readable line, human sentences on stderr
ab-slot log                       # this boot
ab-slot log --prev                # the previous boot
ab-slot log --upgrade             # an update's own output, if it was saved
cat /boot/ab/state.json           # slot state, the truth
cat /boot/ab/packages             # the package record
```

`ab-slot status` prints one line of `field=value` tokens and a summary on stderr, so
`ab-slot status 2>/dev/null` is the line alone. The fields are documented in
[update.md](update.md#field-reference); `boot=`, `esp=` and `packages=` read `unknown` rather
than a comfortable default when nothing recorded them.

## Boot and slot problems

| Symptom | Usually means | What to do |
|---|---|---|
| no console output at all | wrong boot mode or wrong disk | boot UEFI only; check the disk order |
| `p4=ok` but no `stage=commit` | the health check failed | `ab-slot log` names the failing probe; `ab-slot abandon` clears a pending slot |
| the machine reboots into the old slot after an update | the new slot failed its health check | the log holds `stage=abandon result=fail reason=healthcheck-failed detail=<probe>`; fix the payload and install it again |
| the machine keeps coming back to the committed slot | the candidate failed before userspace | the log holds `action=fail-safe-abandon`; nothing is pending any more, install again once the cause is fixed |
| `next=` is not the slot you expect | the boot hint was stale or was not written | `ab-slot next --write` rewrites it from `ab/state.json`; `stage=slot-cfg` in the log shows what was written |
| `disk=unknown` | the boot disk could not be identified | `stage=device` in the log names the level that failed; check the GPT names and `ab/device.json` |
| `p4=degraded` | the shared partition cannot mount, so the writable layer is a tmpfs | nothing written since the boot survives a reboot; `ab-upgrade` refuses with `writable-layer-degraded`. Treat it as a hardware warning: check the disk with `btrfs check` from a live system and reinstall |
| `state is locked by another process` | a writer died holding the lock, the ESP cannot be written, or a live writer is still working | a dead holder is taken over (`stage=lock action=stale-lock-taken`); a live one is waited for up to `AB_LOCK_WAIT_SECS` (default 1 s) and then refused. If the lock directory cannot be created (`cannot create /boot/ab/.lock`), the ESP is read-only or full: copy the log off, then `fsck.fat -a` on the ESP from another system - never from the running image |
| `stage=resize result=fail:btrfs-resize` | the filesystem could not be extended | `ab/log/resize.log` holds btrfs' own message; the partition keeps its size and the next boot retries |
| `btrfs=ok` missing from the log | the platform layer lost its tooling | reinstall from the image; the tool ships in the platform layer |

First boot after a flash takes two boots when p4 has to grow: the first writes the partition
table and reboots, the second resizes the filesystem. Seeing GRUB twice is the design working,
not a failure. The record is `<p4 root subvolume>/.ab/grow`, and `stage=grow result=done` (or
`stage=resize result=ok`) is the pass condition.

## Network problems

| Symptom | Usually means | What to do |
|---|---|---|
| no address on any port after the first boot | the seed did not run, or it failed | `ab-slot log \| grep net-seed`: `result=fail reason=<token>` names the step that broke; `result=skip reason=seeded` means a configuration already existed |
| `result=skip reason=seeded` on a disk you just wrote | the writable layer was not empty | the file is the truth: read `uci show network` and decide whether that configuration is the one you want |
| the LAN address is not `192.168.100.1` | the network was configured before, or by hand | the defaults are applied only on the boot that generated the file; set the address with `uci` as in [network.md](network.md) |
| the WAN device has no lease | no cable, no DHCP upstream, or the address is already in use | `ip -brief address` for the device `uci get network.wan.device` names, then the upstream router's client list |
| `allow_ssh_wan` is in `uci show firewall` but not in `nft list ruleset` | the ruleset has not been rendered since the rule was added | `/etc/init.d/firewall reload`, then look again |
| WAN-side SSH is refused on the convenience image while the rule exists | `dropbear` is bound to an interface | `uci show dropbear` must show no `Interface`; delete it and commit |
| WAN-side SSH times out on the default image | that image has no WAN rule, by design | use the LAN or the console, or flash the `-wan-ssh` image |
| `stage=net-seed result=lan-only` | the machine has one Ethernet port | expected: there is no second network to route between |

When the seed fails, the boot still finishes and the console carries the reason. To get in
without waiting for a fix, give one port an address by hand - it does not survive a reboot,
which is the point:

```sh
ip link set eth1 up
ip addr add 192.168.100.1/24 dev eth1
```

Plug the laptop into that same socket, set it to `192.168.100.2/24`, and reach
`192.168.100.1`. Writing `/etc/config/network` by hand ends the seed's work for good: the file
then exists, so no later boot touches it.

## Update and package problems

| Symptom | First command | What it tells you |
|---|---|---|
| an update exits `74` | the printed `reason=` line, then `ab-slot log --upgrade` | which check refused, and that nothing was written |
| `follow=` stays `pending` | `ab-packages status` and `ab-slot log \| grep stage=packages-refresh` | the retry rung, the probe verdict and the reason of the last attempt |
| `follow=failed` | `ab-packages status`, then `ab-packages update` | the reason token; `apk-<rc>` means the transaction itself failed |
| `packages=limited` | `cat /boot/ab/packages` | the aligner token; the next upgrade rewrites the metadata |
| `packages_reason=` says `other-slot`, or a package field says `unknown` | `ab-slot status` and `cat /boot/ab/packages` | the record describes another slot, or no slot; the next upgrade or rollback retargets it |
| the writable partition fills up | `df -h /mnt/p4` and `ab-slot gc --dry-run` | which layers are unreferenced and would be reclaimed |

A package transaction is separate from a system update on purpose: `apk` writes into the
writable layer, the system update replaces a slot. Do the system update first and the package
upgrade second. `ab-slot packages upgrade` refuses unless `ab-slot status` reports
`packages=aligned` or `packages=followed`, because upgrading packages behind a stale pin
installs modules for a kernel the machine is not running.

## Interactive SSH on dropbear 2025.89

`ssh -tt <host> '<command>' </dev/null` - an interactive-looking session whose stdin is already
at end of file - fails on a healthy machine. The client is disconnected at once and the server
logs three pty errors:

```
dropbear[31119]: ioctl(TIOCSCTTY): I/O error
dropbear[31119]: /dev/pts/0: No such file or directory
dropbear[31119]: open /dev/tty failed - could not set controlling tty: No such device or address
```

Nothing is wrong with the machine or with `/dev`: a person at a terminal, or any client whose
stdin stays open, logs in and gets a prompt. The image carries dropbear v2025.89, and since
upstream commit `e28ba1b` (2024.85) dropbear closes the pty master as soon as **either**
direction of the channel ends. With stdin already at EOF the write direction ends immediately,
the pty is destroyed, and the child's `setsid()`/`TIOCSCTTY` runs against a tty that no longer
exists. Upstream report: [mkj/dropbear#365](https://github.com/mkj/dropbear/issues/365), still
open.

| Client | stdin | Result |
|---|---|---|
| `ssh -tt host '<cmd>' < /dev/null` | already at EOF | **fails**, three errors |
| `ssh -tt host '<cmd>' < <(sleep 12)` | open, no data | works |
| `printf 'echo X\n' \| ssh -tt host '<cmd>'` | one line, then EOF | works: the shell owns the pty before EOF arrives |
| `ssh -tt host` (login shell) `< <(sleep 25)` | open | works |
| `ssh host '<cmd>'` (no pty) | any | works, and proves nothing about pty |

The trigger is one property of the client: whether stdin has reached EOF when the channel
opens. A probe that asks "can something log in interactively?" must keep stdin open for the
length of the session:

```sh
# a keeper process holds stdin open and writes nothing
ssh -tt -i <key> root@<host> 'readlink /proc/$$/fd/0' < <(sleep 8)

# the same without process substitution, for POSIX sh
sleep 8 | ssh -tt -i <key> root@<host> 'readlink /proc/$$/fd/0'

# a login shell, no remote command; the output must end in a prompt
sleep 8 | ssh -tt -i <key> root@<host>
```

This project does not fix it: patching dropbear means carrying a patch through every dropbear
bump, and replacing it with OpenSSH means a second daemon and a different authentication story
for an image whose point is "upstream plus A/B". The three ways out, if that trade ever
changes, are OpenSSH, a dropbear patch, or waiting for upstream.

## Packages follow the base only when the follow can run

An upgrade replaces the system tree; packages live in the writable layer and keep the version
they were installed at. From 0.0.13 they are moved onto the new base by their own transaction
(one `apk upgrade` over the world) after the base is switched, so a package that cannot move
never rolls back a system update that passed its checks. What that does not cover:

- **No network and no prefetch.** The follow needs package bodies. If the prefetch could not run
  and the machine is offline on its first boot, the record says `follow=pending
  reason=network`; the network fallback retries for a day (`follow=abandoned` afterwards) and
  `ab-packages update` retries on demand. Nothing else moves them.
- **A local package with no kept body.** A package installed from a `.apk` file has no source,
  and apk keeps no copy (`/var` is a tmpfs). It is `NO COPY` in the plan block and
  `skipped=local:<name>` in the record, and it keeps its version until somebody keeps a body
  with `ab-packages replay <file>`.
- **A body built for another kernel.** It cannot be replayed onto a base with a different
  kernel, because the module it carries would not load. It is `ABI STALE` and stays at its old
  version.
- **A package upstream dropped.** It keeps working with the files it has, only its own startup
  will tell, and the `world` entry is removed so the next upgrade stops trying.
- **The prediction can be wrong.** The plan block is rendered from `apk --simulate` against a
  staged copy, and a feed can change between the question and the boot. The record is the fact;
  a block that promised 39 packages and a record that says 37 is a prediction and a
  measurement, not a contradiction.

## apk says the database is locked

Symptom: `apk add`, `apk del` or `apk update`, run in the first minutes after an upgrade, fails:

```
ERROR: Unable to lock database: Resource temporarily unavailable
ERROR: Failed to open apk database: Resource temporarily unavailable
```

Cause: the first boot of a new base moves the installed packages onto it with one `apk upgrade`
over the whole world, in a background worker. That transaction holds the apk database lock for
its whole run - 168 packages on the reference machine - so any other apk transaction started in
that window cannot open the database. No package is broken and nothing is lost: the same command
works once the worker has finished.

Handling:

- Wait for the worker, then run the command again.
- `ab-slot status` reports the state: `packages=aligned` (the packages have not moved yet),
  `packages=followed` (they are on the new base) or `packages=limited` (partial metadata, and
  `packages_reason=` names why). `follow=pending` means the move is still owed,
  `follow=followed` that it is done, `follow=never` that there was nothing to move, and
  `follow=failed` or `follow=abandoned` that it did not run; `ab-packages update` retries it on
  demand.
- `ab-slot log` carries one `stage=packages-refresh slot=<a|b> result=<state> reason=<token>
  version=<base>` line per attempt, and `ps w | grep apk` shows the transaction that holds the
  lock.
- The worker's own output is in `/tmp/ab-packages-follow.log`.

Do not:

- delete `/lib/apk/db/lock` - the lock is what keeps two transactions from rewriting the same
  database, and a database left half-written is worse than a wait;
- kill the apk process that holds it - that leaves the same half-written database, on a machine
  that is otherwise working;
- pass a force flag to push the transaction past the lock.

## Services can be left down by the first boot of a new base

The first boot after an upgrade moves the package set, and procd starts boot scripts inside
that window. A daemon that initialises while kernel modules are being replaced can fail, and
procd starts a service once: `dockerd`'s init script sets no `procd_set_param respawn`, so
nothing retried it in that boot. A longer wait does not help, because the instance is never
respawned.

What the machine does now: after the follow settles, whichever path completed it asks procd
which services it started and lost, and gives each one new start. Both paths do this - the
detached first-boot worker, and an interface event that completes a follow the first boot had
deferred for want of a network. The ring log carries
`stage=services-reconciled slot=<a|b> result=ok started=<n> failed=none down=<names>`;
`result=partial` names the services whose own script refused, and
`result=skipped reason=follow-unsettled|boot-not-settled|no-procd-query` says the repair was
not attempted, and `reason=already-reconciled` says this boot has repaired them once already. The criterion is procd's instance record - an instance that exists, is not
running and exited non-zero - not "enabled and not running": a healthy boot has seven such
services (one-shot scripts, on-demand re-appliers, a disabled daemon) that must not be started.

What it does not cover: a daemon that procd accepted and that then died again, and a daemon
whose own configuration is the reason it is down. If a service is still down after such a boot,
restart the machine once.

## Configuration files: `*.apk-new`

apk protects a configuration file it finds edited: the user's file keeps its bytes and the
package's own copy is written beside it as `<file>.apk-new`. That is not a merge. Nothing in
this project reads, merges or deletes it, and a merge that a machine picked itself is how a
firewall rule or a network interface disappears without anybody editing it.

```sh
find /etc/config -name '*.apk-new'        # what is waiting for a decision
apk audit --backup /etc/config            # what apk's database says differs
```

From 0.0.13 the plan block counts the files it will not overwrite (`Config: N files differ from
their package`), so the size of the decision is visible before the upgrade.

## Historical package feeds and the kernel ABI

An official mirror keeps the release directory of every version it published, so a stepped
upgrade or a downgrade can name an older release. The kernel does not travel with it: the kmod
feed is filed under the kernel segment, and the segment changes with every kernel bump.

| Release | kmods segment | `kmod-usb-storage` | user-space index |
|---|---|---|---|
| 25.12.0 | `6.12.87` | `6.12.87-r1` | same bytes as 25.12.2 |
| 25.12.1 | `6.12.94` | `6.12.94-r1` | same bytes as 25.12.2 |
| 25.12.2 | `6.12.103` | `6.12.103-r1` | same bytes as 25.12.0 |

A feed line taken from an older release therefore offers the user-space packages and none of
the kmods: `htop` is in that release's index, `kmod-usb-storage` is not, and the kmod directory
for the running kernel's segment answers 404. The aligner rewrites every `/releases/<x>/` and
`/kmods/<segment>/` in `distfeeds.list` and `repositories.d/*.list` to the release the slot now
runs, and a feed that still names another release makes the follow record
`packages=limited packages_reason=feeds-stale`.

Workaround: put a historical feed in `/etc/apk/repositories.d/customfeeds.list` - the aligner
and the follow's feed probe both skip that file - take kmods by segment, and when a segment is
no longer served, mirror its index, `.sig` and apks into a local HTTPS feed and point
`customfeeds.list` at it ([update.md](update.md#build-your-own-feed)). `ab-packages sources
<name>` names the source that offers a package, with the full URL.

## Packages the target release does not publish

A move between releases can leave the `world` file naming a package the target release never
built, and one such name makes every later apk transaction fail to solve. The follow drops the
name from `world` before the transaction runs; nothing is uninstalled, no configuration is
touched, and `/data` is not involved.

Two gates hold the prune back: an index that answers nothing for any name is not evidence that
the release offers nothing (`index-unusable`), and a caller whose index refresh failed says so
(`index-stale`). In both cases nothing is dropped. A pin whose version is gone is kept, because
the index still offers the name.

## Known behaviour that is not a fault

- **A single-port machine is not a router.** The seed degrades it to LAN-only: the port joins
  `br-lan`, `wan` is removed, and the `wan-present` probe fails on every boot so the slot does
  not commit. The LAN side works normally.
- **The port names are the kernel's, not the silkscreen's.** `eth0` through `eth3` do not have
  to follow the labels on the case, and nothing in the image guesses hardware. Record the
  mapping once per machine ([install.md](install.md)).
- **The defaults are applied once.** They belong to the boot that generated the network
  configuration; an upgrade carries the writable layer over and never re-applies them, so a
  changed default only reaches a machine written fresh.
- **The convenience image opens `22/tcp` on the WAN and nothing closes it for you.** Only
  `n5105-ab-<upstream>-install-wan-ssh.img.gz` carries `allow_ssh_wan`, and `dropbear` there
  accepts password authentication with whatever root password the image carries.
- **Images written before 0.0.7 have no first-boot network.** They come up with no address on
  any port and the only way in is the console. Reflash instead of patching an older image.
- **A bench machine may run with the whole WAN zone open.** That is a debugging state
  (`scripts/device/wan-open.sh`), not shipped behaviour; the release images keep WAN input
  `REJECT`, and the `-wan-ssh` variant opens `22` only.

## What to collect before reporting

Collect the log on the disk both slots share, then copy it off once the LAN side answers:

```sh
mkdir -p /data/evidence
{
    date
    ab-slot status
    ab-slot log
    ab-slot log --prev
    uci show network
    uci show firewall
    uci show dropbear
    ip -brief address
    ip -brief link
    nft list ruleset
    btrfs subvolume list /mnt/p4
} >/data/evidence/first-boot.log 2>&1
```

When the machine cannot be reached at all, mount the ESP (`PARTNAME ab-esp`, FAT) and read
`ab/net.json` (what the seed decided and which ports it saw), `ab/log/boot-0.log` (the ring log
of the running boot) and `ab/log/resize.log` (the first-boot growth). Those three files need no
boot, no SSH and no console.

A useful report carries: the `sha256sum -c SHA256SUMS` transcript, a photo or serial capture of
the first boot including the `stage=net-seed` lines, `ab-slot status` before and after the
change, the filled-in port mapping table, and every failure verbatim with its `reason=` token.

## Limits

- `ab-slot log` keeps three boots. Older evidence is gone; collect it before rebooting.
- The ring log is truncated at 32 KiB per file with a `TRUNCATED=1` marker.
- Rollback depth is one generation: a rollback returns to the previous slot, not to an older
  release that is no longer on the disk.
- Nothing in the image repairs a FAT filesystem: a damaged ESP needs `fsck.fat` from another
  system.
