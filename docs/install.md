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

Only an image built with the *production* boot initramfs can boot a real machine. Two of those
are built from one pipeline run, and the only difference between them is one rendered value:
whether `22/tcp` from the WAN is accepted.

| Where | Name | Use |
| --- | --- | --- |
| GitHub release | `n5105-ab-<upstream>-install.img.gz` | write this one. No WAN rule at all, which is the same posture as an upstream ImmortalWrt image |
| Convenience build, same tag | `n5105-ab-<upstream>-install-wan-ssh.img.gz` (artifact `image-install-wan-ssh` of the tag's run) | the same image plus one `allow_ssh_wan` rule: `22/tcp` from the WAN is accepted. Take it only when the machine cannot be reached from the LAN and cannot be given a keyboard and a monitor |
| Actions artifact (tag builds) | `image-install`, `image-install-wan-ssh` | the two builds before the release stage names them; the file inside the convenience archive is still `n5105-ab-image.img.gz` |
| Actions artifact (every build) | `image-probe` | **never write this**: it is the S1 module probe, it looks for `/dev/vda` and powers off on real hardware |

Both images come from the same upstream input and share one payload: `NET_WAN_SSH` is the only
value that differs, so the kernel, the rootfs, the platform layer and the update payload are
byte for byte the same. The convenience image is a way in, not a safer default - it opens
`22/tcp` on the WAN side of a machine whose root account may still have no password, and it
says so on its own console.

Take the convenience image only for the machine you cannot otherwise reach, and close the rule
as soon as the LAN side answers. There are three ways out, and the first boot prints all three:

```sh
# 1. on the machine, over the very rule you are using
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

```text
# 2. LuCI: Network -> Firewall -> Traffic Rules -> delete allow_ssh_wan
# 3. reflash the closed image: n5105-ab-<upstream>-install.img.gz
```

The rule is added on the boot that generates the network and never again: an upgrade carries
the writable layer over and does not re-apply the defaults, so a machine flashed with the
closed image does not grow the rule later, and one flashed with the convenience image keeps it
until you delete it.

File names carry the board, the product line, the upstream base and the role - not our own
release counter, which lives on the GitHub release instead. Earlier releases named the
same bytes `n5105-ab-<platform>-<upstream>.img.gz` and `.tar`; if a script of yours still
uses that pattern, it is the same file with `-install` or `-upgrade` in front of the
extension.

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

On a freshly written disk the second command prints the seed's result line:

```
stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24
```

The convenience image prints four more lines ahead of it - what it opened and the three ways to
close it:

```
stage=net-seed wan-ssh=open port=22 proto=tcp
stage=net-seed wan-ssh-close: LuCI -> Network -> Firewall -> Traffic Rules -> delete allow_ssh_wan
stage=net-seed wan-ssh-close: or uci delete firewall.allow_ssh_wan && uci commit firewall && /etc/init.d/firewall reload
stage=net-seed wan-ssh-close: or reflash the closed image (n5105-ab-<upstream>-install.img.gz)
```

`ab-slot log | tail` is the quick read of the same boot: the last lines are the health check
and the decision (`stage=healthcheck-done`, then `stage=commit`).

Every later boot prints one line instead: `stage=net-seed result=skip reason=seeded`.
The mark that decides this is `/etc/config/.ab-net-seed`, not the presence of a
configuration file: a configuration that exists and was not written by this hook is left
alone and reported as `result=skip reason=foreign-config`. That is the whole idempotence
story, and it is also what keeps your own `uci` changes and an upgrade's configuration
intact.

`ab-slot status` prints exactly one line on a healthy machine:

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid boot=ok esp=ok packages=unknown packages_reason=unknown
```

The field order is the order `ab-slot` prints them in, and every field is one token:

| Field | What it says |
| --- | --- |
| `p4=` | `ok` when the writable partition is mounted, `degraded` when it is not |
| `data=`, `docker=`, `swap=` | the three subvolumes the platform layer mounts on p4, each `ok` or `missing` |
| `next=` | the slot GRUB will boot next, read back from `boot/grub/ab-slot.cfg`; it is the one field to look at when you want to know what a reboot would do |
| `disk=`, `method=` | which disk this machine is, and how that was established |
| `boot=` | how this boot started, from this boot's ring log: `degraded` means the writable layer is a tmpfs and writes will not survive a reboot, `unknown` means no ring log was readable |
| `esp=` | the initramfs' verdict on the ESP it mounted: `ok`, `dirty`, `unreadable`, or `unknown` when nothing recorded one |
| `packages=`, `packages_reason=` | the package-metadata verdict the last upgrade left; both read `unknown` on a disk that has never been updated, which is honest rather than good |

If `p4` says `degraded`, read the degraded section below before you do anything else.
`packages=` has a section of its own further down: it is the field that says whether
`apk` can install a module for the kernel this slot runs.

Package upgrades and the package-level rollback that goes with them are a separate
command: `ab-slot packages upgrade` and `ab-slot packages revert`, both documented in
[update.md](update.md).


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
* **The convenience image opens `22/tcp` on the WAN, and nothing closes it for you.** Only
  `n5105-ab-<upstream>-install-wan-ssh.img.gz` carries the `allow_ssh_wan` rule; the default
  image carries no WAN rule at all. On the convenience image the rule and the unbound
  `dropbear` stay until you delete them, and `dropbear` accepts password authentication with
  whatever root password the image carries. Close it as soon as the LAN side answers.

## Network defaults on a real machine

The values below are what this build generates on the boot that finds no `/etc/config/network`:

| Item | Value | Written by |
| --- | --- | --- |
| WAN device | `eth0`, `proto dhcp`, plus `wan6` on `@wan` | project defaults on top of `config_generate` |
| LAN bridge | `br-lan` with ports `eth1`, `eth2`, `eth3` | project defaults |
| LAN address | `192.168.100.1/24`, `proto static` | project defaults |
| LAN DHCP server | dnsmasq on `lan`, upstream's pool | `/etc/config/dhcp`, untouched |
| WAN inbound | nothing, or on the `-wan-ssh` image one rule, `allow_ssh_wan`, `22/tcp` | project defaults |
| SSH binding | upstream's binding to `lan`; emptied only on the `-wan-ssh` image | project defaults |
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

On the `-wan-ssh` image, close the WAN exception — one `uci` block on the console or over SSH:

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

Closing it leaves the LAN side untouched, and SSH from the LAN keeps working because
`dropbear` still listens on the bridge. Every default here is a build-time constant:
`/etc/net-defaults.conf` in the platform layer is rendered from `scripts/ci/net-defaults.conf.in`
(`NET_WAN_DEV`, `NET_LAN_DEVS`, `NET_LAN_ADDR`, `NET_LAN_PREFIX`, `NET_WAN_SSH`). The default
image is the render with `NET_WAN_SSH=closed`; the convenience image is the same pipeline run
with `CI_NET_WAN_SSH=open`, and the release stage appends `-wan-ssh` to its file name.
[network.md](network.md) has the long form.

## Acceptance checklist

Run these on the machine before you trust it with anything:

| Check | Command | Expected |
| --- | --- | --- |
| the layout is intact | `ab-slot status` | one line, `p4=ok`, a committed slot |
| the boot was recorded | `ab-slot log` | `stage=boot`, `stage=btrfs-check result=ok`, `stage=commit` |
| the growth finished | `ab-slot log` | `stage=grow result=done` (or `stage=resize result=ok` after a runtime rescue) |
| the network was generated | `ab-slot log` then look for `net-seed` | `result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24` on the first boot, `result=skip reason=seeded` after it |
| the LAN carries its address | `ip -brief address` | a `br-lan` line with `192.168.100.1/24` |
| the WAN has a lease | `ip -brief address` | the device named by `uci get network.wan.device` (`eth0`) with an address inside the upstream router's subnet |
| the interfaces are the ones this build ships | `uci show network` | `network.wan.device='eth0'`, `network.wan.proto='dhcp'`, `network.lan.device='br-lan'`, `network.lan.proto='static'`, `network.lan.ipaddr='192.168.100.1/24'`, and `ports='eth1' 'eth2' 'eth3'` on the `br-lan` device section |
| the WAN exposes 22/tcp only if you asked for it | `nft list ruleset` then look for `tcp dport 22` | no match at all on the default image; on the `-wan-ssh` image one rule in the `wan` input chain matching `tcp dport 22`, and the zone still rejecting everything else |
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
`grep -A3 'dport 22'` gives the one excerpt worth keeping - empty output on the default image,
and that empty output is the pass.

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

On the convenience image the same login also works from the WAN side for as long as the
`allow_ssh_wan` rule exists: `ssh root@<the address the upstream router gave eth0>`. Prove it
once — the point of that image is that the machine is reachable when it hangs off a router you
cannot see — and then close the rule from the LAN session:

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

On the default image the WAN-side attempt never reaches the daemon: the connection is
refused by the `wan` zone, so there is no password prompt to answer.

If the WAN-side login is refused on the convenience image while the rule exists, check the
daemon's binding:
`uci show dropbear` must show no `Interface` option (`uci delete
dropbear.@dropbear[0].Interface; uci commit dropbear` if it came back), and `logread | grep
dropbear` says whether the daemon is listening at all.

## Updating a running system

An update writes the inactive slot and marks it pending. It never touches the running
slot, so the machine keeps working if anything goes wrong.

A machine that can reach a release feed fetches the payload itself:
`ab-upgrade --feed-check` reports what is out there, and `ab-upgrade --feed` downloads it,
checks it and then installs it through this same path. The configuration file, the three
version numbers, the risk levels and the confirmation each one asks for are in
[update.md](update.md).

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
space on the writable partition, the bootloader the payload carries and the conflict report.
A refusal exits with status 74 and writes nothing. On success the state shows the other slot
as `pending`, `ab-slot status` reports the new slot as `next=<slot>`, and the next boot tries
it:

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

### The options

Flags may appear anywhere on the command line:
`ab-upgrade --no-bootloader /root/n5105-ab-<upstream>-upgrade.tar` and
`ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar --no-bootloader` are the same command. Two
positional arguments, or `--bootloader` together with `--no-bootloader`, is a usage error and
exits 2 before anything is read.

| Option | When to use it | What it costs |
| --- | --- | --- |
| (no flag) | every ordinary update | writes the ESP's loader and menu when the payload carries a bootloader member; when it does not, installs the system and prints `bootloader absent-in-payload` |
| `--bootloader` | the payload is supposed to carry a bootloader and you want that enforced | a payload without one is refused with `74`, reason `payload-without-bootloader`, instead of being installed without it |
| `--no-bootloader` | the ESP is `dirty` or `unreadable` and you need the new system anyway, or you want to look at a system-only change first | the ESP is never touched (`bootloader skipped-by-flag`), so a payload carrying a bad loader installs anyway. The bootloader write is the one operation a machine cannot undo by itself, which is why a way past it has to exist |
| `--force` | repairing a slot by reinstalling the version it already runs | the `74 payload-already-installed` guard is skipped, so a payload left lying on the machine can rewrite the healthy slot from the slot you are testing |
| `--check` | before every install | validates and writes nothing: no slot, no `ab/state.json`, no conflict report on the ESP. The bootloader rules run too (member present, manifest block complete, both digests, ESP headroom, `esp=` health), so a check cannot pass where the install would refuse |

### Exit status

| Exit | Meaning | What is on the disk afterwards |
| --- | --- | --- |
| `0` | installed, or validated with `--check` | the inactive slot is staged and pending, `next=` points at it, the running slot is untouched |
| `1` | an execution step failed after validation passed | the slot may be half written, and a bootloader write this run performed is rolled back from `@boot-backup/<version>` first. When even that rollback fails, the ESP may carry the new loader while the slot is still the old one, which is why this leaves as a failure and not as a refusal |
| `74` | refused before anything was written | nothing in the slot and nothing in `ab/state.json`; the payload, or the state of the machine, was refused |

Every refusal prints one line and mirrors it to the console. The line is
`ab-upgrade: refused, reason=<token>` for `74`, and `ab-upgrade: failed, reason=<token>` for
`1`. `ab-slot log --upgrade` prints the ESP's `ab/log/upgrade.log`, and nothing fills that
file in for you, so keep the run's output if you want it on the disk:

```sh
{ ab-upgrade /root/n5105-ab-<upstream>-upgrade.tar 2>&1; echo "exit=$?"; } | tee /boot/ab/log/upgrade.log
```

The braces are the point: in `ab-upgrade ... | tee`, `$?` is `tee`'s status, not the
upgrade's.

Every `bootloader-*` refusal exits `74`, because the bootloader stage runs before the slot is
touched: the slot and `ab/state.json` are exactly as they were. The reasons worth recognising
on the device:

| Reason | What it means | What to do |
| --- | --- | --- |
| `payload-without-bootloader` | `--bootloader` was given and the payload carries no bootloader member | use the payload the flag describes, or drop the flag |
| `bootloader-digest-mismatch` | the loader inside the member is not the one the manifest describes | the payload is damaged: verify it against `SHA256SUMS` and download it again |
| `bootloader-no-space` | the ESP cannot take the loader plus its staging copy and its `.prev` copy | free space on the ESP, or use `--no-bootloader` |
| `bootloader-esp-dirty` | the initramfs judged the ESP dirty this boot | writing FAT there is how a working machine becomes an untested one; `--no-bootloader` is the documented way past it |
| `bootloader-esp-unreadable` | the initramfs could not read the ESP | check the partition, then `--no-bootloader` |

`74` is a promise about the slot and the state file, not about the ESP. When a write had
already started, `ab-upgrade` restores the ESP from `@boot-backup/<version>` before it
refuses; if that restore also fails, the log says `upgrade: RESTORE ALSO FAILED, the ESP
bootloader may be damaged` and the rescue below is the way out. `bootloader-rollback-failed`
is the one reason in this family that exits `1` rather than `74`, because it means the ESP may
carry the new loader while the slot is still the old one.

The tokens live in two files. From a repository checkout, this lists the whole family:

```sh
grep -rho 'bootloader-[a-z-]*' platform/usr/sbin/ab-upgrade platform/lib/upgrade/platform.sh | sort -u
```

`bootloader-esp-` is a prefix, not a token: the two behind it are `bootloader-esp-dirty` and
`bootloader-esp-unreadable`.

### Rescuing a torn bootloader

Two copies of the bootloader exist by design, in two places for two reasons:

| Where | What it is |
| --- | --- |
| `/boot/EFI/BOOT/BOOTX64.EFI.prev` and `/boot/boot/grub/grub.cfg.prev` | the bytes that were on the ESP just before the last write, kept next to the new file so they are reachable even when the writable partition cannot be mounted |
| `/mnt/p4/@boot-backup/<version>/` with `SHA256SUMS` | both files plus their digests, on the writable partition, complete with what `.prev` may be missing |

`.prev` exists because the write copies the file aside before it renames the new one over it,
which is the only window in which the old copy can still be taken. If the ESP had no room for
that copy, the log says `could not keep ...prev (no room on the ESP?)` and the write goes ahead
without it, which is why the backup on p4 is refreshed at the start of every attempt: it always
describes the state that attempt may have to undo. `ab-upgrade` keeps the two most recent
backups.

Rescue from the machine itself: the GRUB menu's recovery entry boots the committed slot with
a read-only writable layer, and there the ESP is mounted at `/boot`.

```sh
esp=/boot
ls -l "$esp/EFI/BOOT/BOOTX64.EFI.prev" "$esp/boot/grub/grub.cfg.prev"
cp "$esp/EFI/BOOT/BOOTX64.EFI.prev" "$esp/EFI/BOOT/BOOTX64.EFI"
cp "$esp/boot/grub/grub.cfg.prev" "$esp/boot/grub/grub.cfg"
backup="$(ls -1dt /mnt/p4/@boot-backup/*/ | head -n 1)"
cd "$esp" && sha256sum -c "${backup}SHA256SUMS"
sync
```

The `sha256sum -c` line is the check that matters: it compares both files on the ESP with the
digests recorded before they were touched, and prints one `OK` per file. Anything else means
the `.prev` copy is not the one the record describes, so restore from `@boot-backup/<version>/`
instead of from `.prev`.

The same steps from another Linux, with the disk in a USB adapter. The node names below are
this machine's, and an adapter can enumerate the disk under different ones, so confirm them
first: `blkid -L ESP` prints the node of the partition whose filesystem label is `ESP`, and
p4 is the fourth partition of the same disk:

```sh
sudo blkid -L ESP                             # the node to mount on /mnt/esp
sudo mkdir -p /mnt/esp /mnt/p4
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo mount /dev/nvme0n1p4 /mnt/p4
sudo cp /mnt/esp/EFI/BOOT/BOOTX64.EFI.prev /mnt/esp/EFI/BOOT/BOOTX64.EFI
sudo cp /mnt/esp/boot/grub/grub.cfg.prev /mnt/esp/boot/grub/grub.cfg
backup="$(ls -1dt /mnt/p4/@boot-backup/*/ | head -n 1)"
cd /mnt/esp && sudo sha256sum -c "${backup}SHA256SUMS"
sync
sudo umount /mnt/esp /mnt/p4
```

Then boot the machine. Before the next update, keep the bootloader out of the way:
`ab-upgrade --check` validates a payload without writing anything, and `--no-bootloader`
installs the system and leaves the bootloader you just repaired exactly as it is.

## Reading packages= and packages_reason=

`packages=` is one word about the slot's package metadata, and it is produced by the last
upgrade, offline, without running `apk`:

| Value | Meaning |
| --- | --- |
| `aligned` | the writable layer's `world` file pins the kernel this slot runs, and its `distfeeds` name the release this slot runs. `apk add` of a module built for this kernel will work |
| `limited` | it does not. The machine boots and runs; installing a package matched to this kernel fails until the metadata is fixed |
| `unknown` | no record, or a record that describes a different slot, or a record nobody can read. Never reported as `aligned`, because an unverified claim is what this field exists to catch |

`packages_reason=` says why. It is the token the aligner published in `ab/packages` on the
ESP, one line `packages=<state> reason=<token> version=<ver> kernel=<id> slot=<a|b>`. The
tokens worth recognising:

| Token | What it means |
| --- | --- |
| `none` | aligned, nothing to explain |
| `other-slot` | the record describes the slot an upgrade was aiming at, not the slot this boot runs. Normal between `ab-upgrade` and the reboot that tries the candidate |
| `packages-lib-missing` | the new platform layer carries no aligner, so nothing could be aligned |
| `world-unwritable`, `distfeeds-unwritable` | the rewrite of `/etc/apk/world` or of `distfeeds.list` in the writable layer failed |
| `world-not-verified`, `distfeeds-not-verified` | the rewrite landed but did not read back as the intended value, so the original was restored |

`aligned` is a statement about metadata, not about the network. The alignment is offline on
purpose and never runs `apk`, so a machine that upgrades with no cable plugged in is still
`aligned` - and a machine with a perfect network can still be `limited`. `limited` blocks
neither the upgrade nor the boot: the slot comes up, it just cannot install a module matched
to its kernel until `world` and `distfeeds` are fixed.

Read both fields straight off the status line, and read the record itself:

```sh
ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(boot|esp|packages|packages_reason)='
cat /boot/ab/packages
```

`ab-slot` prints one sentence about the same verdict, which is the one to quote in a report:
`ab-slot: packages limited, package metadata is limited (<reason>): installing packages for
this kernel needs it fixed first`.


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
* the `dport 22` excerpt from `nft list ruleset`: empty on the default image, and on the
  convenience image before and after closing the rule;
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
| no address on any port after the first boot | the seed did not run, or it failed | look for `net-seed` in `ab-slot log`: `result=fail reason=...` names the step that broke; `result=skip reason=seeded` means a configuration already existed and was left alone |
| `result=skip reason=seeded` on a disk you just wrote | the writable layer was not empty | the file is the truth: read `uci show network` and decide whether that configuration is the one you want |
| the LAN address is not `192.168.100.1` | the network was configured before, or by hand | the defaults are applied only on the boot that generated the file; set the address with `uci` as above |
| the WAN device has no lease | no cable, no DHCP on the upstream side, or another address already in use | `ip -brief address` for the device `uci get network.wan.device` names, then the upstream router's client list |
| `allow_ssh_wan` is in `uci show firewall` but not in `nft list ruleset` | the ruleset has not been rendered since the rule was added | `/etc/init.d/firewall reload`, then look again |
| WAN-side ssh is refused on the convenience image while the rule exists | `dropbear` is bound to an interface | `uci show dropbear` must show no `Interface`; delete it and commit |
| WAN-side ssh times out on the default image | that image has no WAN rule, by design | nothing to fix; use the LAN, the console, or flash the `-wan-ssh` image |
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

## This release: 0.0.8

`VERSION` reads `0.0.8`. What `0.0.8` changed is in the update path, not in the boot: the
payload now carries its own GRUB and slot menu, so an updated machine boots the loader the
payload brought instead of the one it was flashed with, and `ab-upgrade` gives you
`--bootloader` / `--no-bootloader` to decide whether that write happens. The first-boot
network generation arrived in `0.0.7` and is unchanged. The content of that version, still
current:

* **First-boot generation, the upstream way.** `ab-net-seed`, at `S16` ahead of `S20network`,
  runs `/bin/board_detect` and `/bin/config_generate` when `/etc/config/network` is absent —
  the same two programs an official ImmortalWrt image runs from preinit, which this image's
  A/B initramfs replaces. `system` therefore carries upstream's hostname and timezone.
* **Four ports, one WAN.** `eth0` is the WAN (`dhcp`, plus `wan6`), `eth1` through `eth3` join
  `br-lan`. The port set is read from `/sys/class/net`, so a machine with fewer ports gets a
  smaller bridge and a single-port machine degrades to LAN-only.
* **`192.168.100.1/24` on the LAN**, with upstream's dnsmasq serving the pool. The subnet is
  deliberately not `192.168.1.0/24`.
* **`22/tcp` from the WAN only on the convenience image.** The default image opens nothing:
  the `wan` zone keeps `input 'REJECT'` and `dropbear` keeps upstream's binding to `lan`. The
  `-wan-ssh` image adds one `allow_ssh_wan` rule and empties `dropbear.Interface` so the rule
  can reach the daemon. LuCI's `80/tcp` stays off the WAN in both. The choice is a build-time
  constant: the convenience image is the same pipeline with `CI_NET_WAN_SSH=open`.
* **Nothing generated is overwritten.** The trigger is the absence of `/etc/config/network` and
  nothing else, so a user edit, a fixture and a configuration carried over by an upgrade all
  survive.

Everything else is unchanged from `0.0.6`: the four 128 MiB partitions, the overlay layers,
the health check, the ring log, and the `ab-slot` and `ab-upgrade` behaviour this page
describes. Artifact names are unchanged, and `release-notes.md` in the release directory
records the versions, the input digests and the judge lines of the build.
