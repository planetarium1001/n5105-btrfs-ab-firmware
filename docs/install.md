# Installing and updating the firmware

This page is the operator view: how to put the image on a disk, what to do at the console on
the first boot, what to check before you trust the machine with a network, how to update it
and how to get back. It is written to be followed on a real N5105 with a monitor, a keyboard
and a cable in a socket, so every step says what the command is and what the output has to
say. The design behind it is in [partitions.md](partitions.md), [boot-overlay.md](boot-overlay.md),
[network.md](network.md) and [lifecycle.md](lifecycle.md).

## What you need

A release directory contains four files:

| File | Purpose |
| --- | --- |
| `n5105-ab-<upstream>-install.img.gz` | the complete disk image, written once per machine |
| `n5105-ab-<upstream>-upgrade.tar` | the update payload, used by `ab-upgrade` |
| `SHA256SUMS` | digests of both files |
| `release-notes.md` | versions, upstream inputs and the acceptance lines of the build |

Verify them before writing anything:

```sh
sha256sum -c SHA256SUMS
```

`sha256sum -c` prints one `<file>: OK` line per artifact. Anything else means the download is
broken: write nothing and fetch it again, because a payload that fails this check is refused by
`ab-upgrade` later with `reason=digest-mismatch-<member>` anyway.

For a real device, also have at hand: a monitor and a USB keyboard (HDMI on the N5105 v5
boards), an Ethernet cable to the upstream router, one more cable and a laptop for the LAN
side, and a way to note things down. The port mapping you write down in the checklist is part
of the result.

### Which artifact to write

Only an image built with the *production* boot initramfs can boot a real machine. The CI
publishes exactly one of those, under one of two names:

| Where | Name | Use |
| --- | --- | --- |
| GitHub release | `n5105-ab-<upstream>-install.img.gz` | write this one; it is the only file the release job proved bootable |
| Actions artifact (tag builds) | `image-install` | the same bytes, for testing before a release |
| Actions artifact (every build) | `image-probe` | **never write this**: it is the S1 module probe, it looks for `/dev/vda` and powers off on real hardware |

Which one an image carries is recorded inside it: mount the ESP (`PARTNAME ab-esp`, FAT) and
read `ab/image.json` - `"kind": "boot"` is writable, `"kind": "probe"` is a CI fixture. The
release job refuses to publish anything whose `kind` is not `boot`, and also reads `initrd-a`
out of the image and checks it is the production init.

The image is a plain GPT layout: an EFI system partition, two slot filesystems and a
shared btrfs partition holding the writable layers. It boots on x86-64 UEFI only;
legacy BIOS boot is not supported. The target machine needs the N5105 v5 board with
its four-partition layout, or any x86-64 machine you want to test with, since the
image is self-contained.

## Write the image

Writing the image destroys everything on the target disk. Identify the disk first,
then write:

```sh
lsblk -o NAME,SIZE,MODEL
gunzip -c n5105-ab-<upstream>-install.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo sync
```

Read `lsblk` before the `dd`: the device you pass to `of=` has to be the disk you mean, with
the size you expect, and nothing else on the machine may have that name at the time. `dd`
exits 0 and prints the byte count; `sync` returns after the writes have left the kernel. Do
not cut the power between the two.

The result is 514 MiB with four 128 MiB partitions. Nothing else has to be created by hand:
the ESP carries the kernel and initramfs for both slots, the bootloader configuration
is already rendered for the committed slot, and both slot filesystems contain the
same root filesystem.

To write to a file instead, for a virtual machine test:

```sh
gunzip -c n5105-ab-<upstream>-install.img.gz > test.img
qemu-system-x86_64 -machine q35 -m 1G -bios /usr/share/OVMF/OVMF_CODE.fd \
  -drive file=test.img,if=virtio,format=raw -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0 -nographic
```

## First boot at the console

Boot the machine with the monitor and the keyboard attached. From `0.0.7` the first boot
writes its own network configuration, so the console is no longer the only way into a fresh
disk, but the first boot of a new machine still belongs on the console for three reasons:

* the generator reports a failure only there, as `stage=net-seed result=fail reason=...`, and
  a machine with no address is otherwise silent;
* the port-to-socket mapping and the MAC addresses can only be recorded from the machine
  itself, and they are what makes every later cable move predictable;
* a LAN subnet that collides with the network the machine is about to join has to be changed
  from the console, before anything is reachable.

If the board carries a UART header, a serial line at 115200 8N1 is the better channel because
it survives a blank screen. Whether this N5105 v5 board exposes one is unconfirmed; HDMI plus
a USB keyboard always works.

The machine boots from the ESP, the initramfs composes the root with overlayfs and
switches to the real system. Within a minute the health check runs and the running
slot is committed. On the console, after the login prompt:

```sh
ab-slot status
ab-slot log | grep net-seed
```

On a freshly written disk the second command prints two lines:

```
stage=net-seed wan-ssh=open
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

`ab-slot log | tail` is the quick read of the same boot: the last lines are the health check
and the decision (`stage=healthcheck-done`, then `stage=commit`).

Every later boot prints one line instead: `stage=net-seed result=skip
reason=network-present`. That is the whole idempotence story: the seed runs on the boot that
found no `/etc/config/network` and never again, which is also what keeps your own `uci`
changes and an upgrade's configuration intact.

`ab-slot status` prints exactly one line on a healthy machine:

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid
```

`p4=ok` means the writable partition is mounted; `data`, `docker` and `swap` report the
three subvolumes the platform layer mounts on it. `next=a` is the slot GRUB will boot
next, read back from `boot/grub/ab-slot.cfg`; it is the one line to look at when you
want to know what a reboot would do. If `p4` says `degraded`, read the degraded section
below before you do anything else.

When the seed fails, the boot still finishes and the console carries the reason:
`stage=net-seed result=fail reason=board-detect`, `reason=config-generate`,
`reason=config-generate-empty` or `reason=no-ethernet`. To get into the machine without
waiting for a fix, give one port an address by hand — this does not survive a reboot, which is
the point:

```sh
ip link set eth1 up
ip addr add 192.168.100.1/24 dev eth1
```

Plug the laptop into that same socket, set it to `192.168.100.2/24`, and reach
`192.168.100.1`. Writing `/etc/config/network` by hand ends the seed's work for good: the file
then exists, so no later boot touches it. Fix the configuration from LuCI once you are in, or
reflash if you would rather start from the defaults again.

## Known limitations

* **Images written before `0.0.7` have no first-boot network.** `0.0.6` and earlier replace
  the upstream preinit that generates `/etc/config/network`, so a freshly written disk comes
  up with no address on any port, no DHCP server on the LAN, and `dropbear` bound to an
  interface that does not exist. The only way in is the console and `uci` by hand. On such an
  image the health check also reports `probe=wan-present result=fail`, never writes
  `stage=commit`, and the machine stays up anyway (`action=stay`). `0.0.7` is the first
  release that generates the network itself; reflash instead of patching an older image.
* **The port names are the kernel's, not the silkscreen's.** `eth0` through `eth3` do not have
  to follow the labels on the case, and nothing in the image guesses hardware. Record the
  mapping on every machine, with the checklist step below.
* **A single-port machine is not a router.** The seed degrades it to LAN-only
  (`stage=net-seed result=lan-only`): the single port joins `br-lan`, `wan` is removed. There
  is then no `network.wan` for the `wan-present` probe to find, so that boot does not commit
  the slot (`action=stay`); the LAN side works normally.
* **The defaults are applied once.** They belong to the boot that generated the
  configuration. An upgrade carries the writable layer over and never re-applies them, which
  is deliberate — your changes win — but it also means a changed default only reaches a
  machine that is written fresh.
* **The WAN exception is open in this release.** `22/tcp` from the WAN is accepted until you
  delete the `allow_ssh_wan` rule, and `dropbear` accepts password authentication with
  whatever root password the image carries. Close it as soon as the LAN side answers.

## Network defaults on a real machine

The values below are what this build generates on the boot that finds no `/etc/config/network`:

| Item | Value | Written by |
| --- | --- | --- |
| WAN device | `eth0`, `proto dhcp`, plus `wan6` on `@wan` | project defaults on top of `config_generate` |
| LAN bridge | `br-lan` with ports `eth1`, `eth2`, `eth3` | project defaults |
| LAN address | `192.168.100.1/24`, `proto static` | project defaults |
| LAN DHCP server | dnsmasq on `lan`, upstream's pool | `/etc/config/dhcp`, untouched |
| WAN inbound | one rule, `allow_ssh_wan`, `22/tcp` | project defaults |
| SSH binding | `dropbear.@dropbear[0].Interface` emptied | project defaults |
| Hostname, timezone | `ImmortalWrt`, `GMT0` | `/bin/config_generate` |

The port set comes from `/sys/class/net`: every `eth*` that carries a `device` link, minus the
WAN device, joins the bridge. Nothing is hard coded, so a two-port machine bridges one port.

Change the LAN subnet — this one survives an update and the seed never runs over it again:

```sh
uci set network.lan.ipaddr='192.168.8.1'
uci commit network
/etc/init.d/network reload
```

Clients keep their lease until it expires, so reconnect at the new address rather than waiting
for the old one to answer.

Change which socket is the WAN. `ip -br link` names the interfaces; the mapping section below
tells you which name belongs to which socket. Both edits belong together — `wan.device` alone
would leave the new WAN socket bridged into the LAN and the old one unused:

```sh
uci set network.wan.device='eth3'
uci del_list network.@device[0].ports='eth3'
uci add_list network.@device[0].ports='eth0'
uci commit network
/etc/init.d/network reload
```

Close the WAN exception — one `uci` block on the console or over SSH:

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

In LuCI the same rule is the entry named `allow_ssh_wan` under **Network → Firewall → Traffic
Rules** (网络 → 防火墙 → 通信规则): delete it and press **Save & Apply**. Then confirm it is
gone:

```sh
uci show firewall | grep allow_ssh_wan     # no output
```

Closing it leaves the LAN side untouched, and `dropbear.Interface` stays empty, so SSH from
the LAN keeps working. Every default here is a build-time constant as well:
`/etc/net-defaults.conf` in the platform layer is rendered from `scripts/ci/net-defaults.conf.in`
(`NET_WAN_DEV`, `NET_LAN_DEVS`, `NET_LAN_ADDR`, `NET_LAN_PREFIX`, `NET_WAN_SSH`), and the
release with the WAN exception switched off is the same pipeline run with
`CI_NET_WAN_SSH=closed`. [network.md](network.md) has the long form.

## Acceptance checklist

Run these on the machine before you trust it with anything:

| Check | Command | Expected |
| --- | --- | --- |
| the layout is intact | `ab-slot status` | one line, `p4=ok`, a committed slot |
| the boot was recorded | `ab-slot log` | `stage=boot`, `stage=btrfs-check result=ok`, `stage=commit` |
| the growth finished | `ab-slot log` | `stage=grow result=done` (or `stage=resize result=ok` after a runtime rescue) |
| the network was generated | `ab-slot log` then look for `net-seed` | `result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24` on the first boot, `result=skip reason=network-present` after it |
| the LAN carries its address | `ip -brief address` | a `br-lan` line with `192.168.100.1/24` |
| the WAN has a lease | `ip -brief address` | the device named by `uci get network.wan.device` (`eth0`) with an address inside the upstream router's subnet |
| the interfaces are the ones this build ships | `uci show network` | `network.wan.device='eth0'`, `network.wan.proto='dhcp'`, `network.lan.device='br-lan'`, `network.lan.proto='static'`, `network.lan.ipaddr='192.168.100.1/24'`, and `ports='eth1' 'eth2' 'eth3'` on the `br-lan` device section |
| the WAN exception is one rule and no more | `nft list ruleset` then look for `allow_ssh_wan` | one rule in the `wan` input chain matching `tcp dport 22`, and the zone still rejecting everything else |
| a laptop on a LAN socket gets a lease | plug the laptop into any `eth1`..`eth3` socket, set it to DHCP | an address in `192.168.100.0/24`, gateway `192.168.100.1` |
| the tooling works | `btrfs --version` | a `btrfs-progs` banner |
| the layers are reachable | `btrfs subvolume list /mnt/p4` | the layer named by `ab-slot status` |
| the firewall came up | `nft list table inet fw4` | a table, not an error |
| reclamation is idle | `ab-slot gc --dry-run` | no layer reported for deletion |
| the other slot is intact | `ab-slot pending b` then `ab-slot abandon` | the first succeeds, the second clears it |
| the next boot is what you expect | `ab-slot next` | `next=<the committed slot>` after the abandon |

There is no `wan` interface in `ip -brief address`: the WAN interface is bound to a device
(`option device eth0`), so its address shows on `eth0`. That is why the WAN row reads the
device name out of `uci` first. `nft list ruleset` is the wider, slower command; piping it into
`grep -A3 allow_ssh_wan` gives the one excerpt worth keeping.

The last row proves the inactive slot still has its kernel and initramfs on the ESP:
`ab-slot pending` refuses a slot whose payload is missing, so a failure there is a
warning about the backup slot, not about the running one.

## Mapping the four ports to eth0..eth3

Do this once per machine and write the table into the evidence bundle. It is the only way to
know which socket is the WAN without guessing:

```sh
ip -brief link
for d in /sys/class/net/eth*; do
    printf '%s carrier=%s mac=%s\n' "${d##*/}" "$(cat "$d/carrier")" "$(cat "$d/address")"
done
```

Start with every cable out of the machine: each `eth*` shows `DOWN` and `carrier=0`. Plug one
cable into one socket, note the label on the case, run the two commands again, and read off
which interface turned `UP,LOWER_UP` with `carrier=1`. Repeat for the four sockets, then fill
in this table:

| Socket (label on the case) | Interface | MAC | Role after the seed |
| --- | --- | --- | --- |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |

`eth0` is the WAN by default and every other `eth*` is a `br-lan` port, so the role column is
`WAN` for the interface named `eth0` and `LAN` for the rest. If the socket you want facing the
upstream router is not the one the kernel calls `eth0`, either move the role with the `uci`
block above or change `NET_WAN_DEV` for the next build — and say which you did in the report,
because the two are not the same machine afterwards.

## LuCI and SSH from the LAN

From the laptop plugged into a LAN socket, or any client on `192.168.100.0/24`, open
`http://192.168.100.1`. LuCI listens on `80/tcp` and the firewall keeps it off the WAN; there
is no HTTP exception on the WAN side of this build. The image ships the upstream root account
with an empty password, so log in as `root` and press Enter, then set a password before the
machine leaves the bench — LuCI: **System → Administration**, or `passwd` on the console.

SSH is the same account over `22/tcp`:

```sh
ssh root@192.168.100.1
```

The same login also works from the WAN side for as long as the `allow_ssh_wan` rule exists:
`ssh root@<the address the upstream router gave eth0>`. Prove it once — the point of the rule
is that the machine is reachable when it hangs off a router you cannot see — and then close it
from the LAN session:

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

If the WAN-side login is refused while the rule exists, check the daemon's binding:
`uci show dropbear` must show no `Interface` option (`uci delete
dropbear.@dropbear[0].Interface; uci commit dropbear` if it came back), and `logread | grep
dropbear` says whether the daemon is listening at all.

## Updating a running system

An update writes the inactive slot and marks it pending. It never touches the running
slot, so the machine keeps working if anything goes wrong.

```sh
ab-upgrade --check /root/n5105-ab-<upstream>-upgrade.tar
ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar
ab-slot status
ab-slot conflicts
ab-slot log --upgrade
```

`--check` validates the payload and writes nothing, so a bad download is found before the
inactive slot is touched. `ab-upgrade` validates again while it writes: manifest shape,
per-member digests, that every module inside the initramfs comes from one kernel build, free
space on the writable partition and the conflict report. A refusal exits with status 74 and
writes nothing. On success the state shows the other slot as `pending`, `ab-slot status`
reports the new slot as `next=<slot>`, and the next boot tries it:

* the boot runs the health check on the new slot;
* if every probe passes, the slot is committed and the machine stays on it;
* if any probe fails, the pending slot is abandoned and the machine reboots into the
  committed slot;
* if the new slot fails even earlier, in the boot initramfs, the failure path clears
  `pending` itself before it powers off (`action=fail-safe-abandon` in the log), so the
  next boot comes back to the committed slot instead of retrying the broken one.

On the real device, add these assertions to the first upgrade: `ab-slot status` before the
reboot shows `pending=<the other slot>` and `next=<the other slot>`; after the reboot it shows
that slot as `committed=`, `pending=none`, a higher `generation=` and `p4=ok`. When the payload
carries a different upstream version, `upper=` changes with it, because the layer is named after
the version it was seeded from. Files under `/data` are shared by both slots and stay where
they are.

The upgrade fails with `reason=next-boot-not-<slot>` when the slot is staged but
`boot/grub/ab-slot.cfg` does not point at it: without that file the machine would keep
booting the old slot and the update would never be tried.

Files that both the payload and you changed are listed in `ab-slot conflicts`. They
never block the update: the payload copies the new file, the report tells you which
ones to look at.

## Power-cut drill

The point of two slots is the behaviour when the power goes away, and there are two moments
worth cutting it. Both are done on the bench, with the console attached.

First, with the machine idle on its committed slot, leave something behind in both places and
cut the power — no `reboot`, no `halt`, pull the cable:

```sh
date > /data/powercut-data
date > /root/powercut-layer
sync
```

Power on again and assert:

```sh
ab-slot status
cat /data/powercut-data
cat /root/powercut-layer
ab-slot log
```

The same slot is committed, `p4=ok`, both markers are there, and the log shows a clean boot
(`stage=btrfs-check result=ok`, then `stage=commit`). If a writer died holding the state lock,
the next boot takes it over by itself and logs `stage=lock action=stale-lock-taken`; that line
is the pass condition for this case, not a failure.

Second, cut the power inside the upgrade window: run `ab-upgrade` with the payload, and pull
the cable *before* the reboot that would try the new slot. Power on again and assert with the
same four commands plus `ab-slot pending`:

* the machine boots the slot the boot hint points at, which is the new one;
* if its probes pass, it is committed and `ab-slot status` shows `pending=none`;
* if they fail, the pending slot is abandoned and the machine comes back on the committed slot
  (`action=reboot-to-committed` or `action=fail-safe-abandon` in the log);
* either way `next=` equals `committed=` afterwards, and `/data` still carries the marker —
  the shared partition is the same disk for both slots.

## Rolling back

Rolling back means committing the other slot, which still holds the previous
filesystem and its own writable layer:

```sh
ab-slot rollback
reboot
```

The boot then comes up on the other slot and commits it. This is the fast path back
after a bad update. It is not a factory reset: user data written since the update
stays in the layer that was rolled forward, and `ab-slot gc` will not delete it while
a slot still references it.

To discard a staged update without booting it:

```sh
ab-slot abandon
```

## When the writable partition is degraded

If the shared partition cannot be mounted, the boot does not fail: the upper layer
moves to memory, the system comes up, and both the console and `ab-slot status` say
`p4=degraded`. The machine works, but nothing written since the boot survives a
reboot, and `ab-upgrade` refuses to run:

```
ab-upgrade: refused, reason=writable-layer-degraded
```

Treat this as a hardware warning. Check the disk with `btrfs check` from a live
system, back up anything you still need, and reinstall from the image once the cause is
cleared.

## Evidence to bring back

The machine is on a bench and the report is the log, so collect it in one place on the disk
that both slots share, and copy it off once the LAN side answers:

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

When the machine cannot be reached at all, the disk carries everything needed to explain
why: mount the ESP (`PARTNAME ab-esp`, FAT) and read `ab/net.json` (what the seed decided,
which ports it saw, whether it was a deferral), then `ab/log/boot-0.log` (the ring log of
the running boot) and `ab/log/resize.log` (the first-boot growth). Those three files need
no boot, no SSH and no console; GRUB itself cannot help here - the standalone EFI binary on
the ESP has no `cat` module.

From the laptop:

```sh
scp root@192.168.100.1:/data/evidence/first-boot.log .
```

A session is complete when the bundle carries:

* the transcript of `sha256sum -c SHA256SUMS`, with the two `OK` lines;
* a photo or a serial capture of the console during the first boot, including the
  `stage=net-seed` lines;
* the first-boot log, with `stage=net-seed result=ok ...`, the three `probe=` lines and
  `stage=commit`;
* `ab-slot status` before and after the upgrade, and after each power cut;
* the filled-in port mapping table, with the MAC addresses;
* the `allow_ssh_wan` excerpt from `nft list ruleset`, before and after closing the rule;
* `ab-slot log --upgrade` after the upgrade;
* every failure verbatim, including its `reason=` token — that token is the same one the build
  reports, so a machine and a build can be compared without guessing.

## Troubleshooting

Read the boot log first; it records every stage in `key=value` form:

```sh
ab-slot log
ab-slot log --prev
```

| Symptom | Usually means | What to do |
| --- | --- | --- |
| no console output at all | wrong boot mode or disk | boot UEFI only, check the disk order |
| no address on any port after the first boot | the seed did not run, or it failed | look for `net-seed` in `ab-slot log`: `result=fail reason=...` names the step that broke; `result=skip reason=network-present` means a configuration already existed and was left alone |
| `result=skip reason=network-present` on a disk you just wrote | the writable layer was not empty | the file is the truth: read `uci show network` and decide whether that configuration is the one you want |
| the LAN address is not `192.168.100.1` | the network was configured before, or by hand | the defaults are applied only on the boot that generated the file; set the address with `uci` as above |
| the WAN device has no lease | no cable, no DHCP on the upstream side, or another address already in use | `ip -brief address` for the device `uci get network.wan.device` names, then the upstream router's client list |
| `allow_ssh_wan` is in `uci show firewall` but not in `nft list ruleset` | the ruleset has not been rendered since the rule was added | `/etc/init.d/firewall reload`, then look again |
| WAN-side ssh is refused while the rule exists | `dropbear` is bound to an interface | `uci show dropbear` must show no `Interface`; delete it and commit |
| `p4=degraded` | the shared partition cannot mount | see the section above |
| `p4=ok` but no `stage=commit` | the health check failed | `ab-slot log` names the failing probe; `ab-slot abandon` clears a pending slot |
| `ab-upgrade` exits 74 | the payload or the machine was refused | the reason is printed and logged; nothing was written |
| the machine reboots into the same slot after an update | the new slot failed its health check | the log holds `reason=healthcheck-failed`; fix the payload and install it again |
| `next=` is not the slot you expect | the boot hint was not written, or was written by an older boot | `ab-slot next --write` rewrites it from `ab/state.json`; the log shows `stage=slot-cfg` with the value it wrote |
| the machine keeps coming back to the committed slot after an update | the candidate failed before userspace | the log holds `action=fail-safe-abandon` and `reason=`; nothing is pending any more, so install the payload again once the cause is fixed |
| `disk=unknown` in `ab-slot status` | the boot disk could not be identified | the log names it in `stage=device`; check the GPT names and `ab/device.json` against the disk you actually wrote |
| `state is locked by another process` | a writer died while holding the state lock | it is taken over by itself once the boot that wrote it (or its pid) is gone; the ring log then shows `stage=lock action=stale-lock-taken`. A live writer in this boot is real contention and still refuses |
| `stage=resize result=fail:btrfs-resize` | the filesystem could not be extended, in the initramfs or again at runtime | `ab/log/resize.log` holds btrfs' own message; the partition keeps its size and the next boot retries |
| `btrfs=ok` missing from the log | the platform layer lost its tooling | reinstall from the image; the tool ships in the platform layer |
| `stage=net-seed result=lan-only` | the machine has one Ethernet port | expected: there is no second network to route between, so the box is a LAN-only client |

Every failure carries a `reason=` token in the log, which is the same token the CI
judge lines report, so a machine and a build can be compared without guessing.

## This release: 0.0.7

`VERSION` reads `0.0.7`, and this is the first release whose first boot writes its own network
configuration. The content of the version, in the words of the release notes:

* **First-boot generation, the upstream way.** `ab-net-seed`, at `S16` ahead of `S20network`,
  runs `/bin/board_detect` and `/bin/config_generate` when `/etc/config/network` is absent —
  the same two programs an official ImmortalWrt image runs from preinit, which this image's
  A/B initramfs replaces. `system` therefore carries upstream's hostname and timezone.
* **Four ports, one WAN.** `eth0` is the WAN (`dhcp`, plus `wan6`), `eth1` through `eth3` join
  `br-lan`. The port set is read from `/sys/class/net`, so a machine with fewer ports gets a
  smaller bridge and a single-port machine degrades to LAN-only.
* **`192.168.100.1/24` on the LAN**, with upstream's dnsmasq serving the pool. The subnet is
  deliberately not `192.168.1.0/24`.
* **`22/tcp` from the WAN, on by default.** One `allow_ssh_wan` rule, the `wan` zone still
  `input 'REJECT'`, and `dropbear.Interface` emptied so the rule can reach the daemon. LuCI's
  `80/tcp` stays off the WAN. The rule is a build-time constant: the closed variant is the same
  pipeline with `CI_NET_WAN_SSH=closed`.
* **Nothing generated is overwritten.** The trigger is the absence of `/etc/config/network` and
  nothing else, so a user edit, a fixture and a configuration carried over by an upgrade all
  survive.

Everything else is unchanged from `0.0.6`: the four 128 MiB partitions, the overlay layers,
the health check, the ring log, and the `ab-slot` and `ab-upgrade` behaviour this page
describes. Artifact names are unchanged, and `release-notes.md` in the release directory
records the versions, the input digests and the judge lines of the build.
