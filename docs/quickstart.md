# Quickstart

**English** | [简体中文](quickstart.zh-CN.md)

This page is the shortest path through the product: write one image, boot it once, install one
package, upgrade once from the release feed, and roll back once. Each step gives the command and
the result that says the step worked. The detail behind each step is in [install.md](install.md)
and [update.md](update.md), so this page stays a checklist.

Run the five steps in order, on a machine that is on the bench, with nothing on its disk that you
still need.

## Before you start

Two things are needed before the first step: a release directory and the machine. The list below
is what the five steps read, so a missing item is found now rather than in step 4.

- A release directory carrying the install image, the upgrade payload, `SHA256SUMS` and
  `release-notes.md` ([install.md](install.md#what-you-need)).
- An x86-64 machine that boots UEFI. Legacy BIOS boot is not supported
  ([install.md](install.md#verify-the-release-before-you-write-it)).
- A monitor and a USB keyboard for the first boot. This board carries HDMI, and whether it
  exposes a UART header is unconfirmed ([install.md](install.md#first-boot-at-the-console)).
- One Ethernet cable to the upstream router, one more cable and a laptop for the LAN side.
- A `root` shell on the machine for steps 2 to 5. Step 1 runs on the Linux host that writes the
  disk.

## Step 1: write the image

Choose the asset first, then write it. Both install images carry the same kernel, rootfs and
update payload, and the one value that differs is whether `22/tcp` from the WAN is accepted
([install.md](install.md#which-artifact-to-write)).

| Asset | Take it when |
| --- | --- |
| `n5105-ab-<upstream>-install.img.gz` | every ordinary machine: no WAN rule at all, the same posture as an upstream image |
| `n5105-ab-<upstream>-install-wan-ssh.img.gz` | the machine cannot be reached from the LAN and cannot be given a keyboard and a monitor: it accepts `22/tcp` from the WAN until the rule is deleted |
| `image-probe` | never: it looks for `/dev/vda` and powers off on real hardware |

1. Verify the release.
   ```sh
   sha256sum -c SHA256SUMS
   ```
   Expected: one `<file>: OK` line per artifact.
2. Identify the target disk.
   ```sh
   lsblk -o NAME,SIZE,MODEL
   ```
   Expected: the disk you mean, with the size you expect, and no other device carrying that name.
3. Write the image, then flush it.
   ```sh
   gunzip -c n5105-ab-<upstream>-install.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
   sudo sync
   ```
   Expected: `dd` exits 0 and prints the byte count, and `sync` returns after the writes have left
   the kernel.

`<upstream>` is the release's upstream base, for example `25.12.2`. The device in `of=` is the one
the disk had on the reference machine, so pass the node `lsblk` printed for your disk.

Writing destroys everything on the target disk. The result is 514 MiB in four 128 MiB partitions,
and nothing has to be created by hand. On the `-wan-ssh` image the first boot prints three ways to
close the WAN rule, and the rule is closed as soon as the LAN side answers
([install.md](install.md#which-artifact-to-write)).

## Step 2: first boot

The first boot writes its own network configuration and commits the slot it booted, so the console
is where a failure is reported and where the machine is identified. The generated defaults are:

- LAN `192.168.100.1/24` on `br-lan`, with ports `eth1`, `eth2` and `eth3`, plus a DHCP server.
- WAN `eth0` with `proto dhcp`.
- Hostname `ImmortalWrt`, timezone `GMT0`.

1. Read the network line from the console.
   ```sh
   ab-slot log | grep net-seed
   ```
   Expected: `stage=net-seed result=ok mode=router wan=eth0 lan-ports=eth1 eth2 eth3 addr=192.168.100.1/24`.
2. Read the status line.
   ```sh
   ab-slot status
   ```
   Expected: one line carrying `committed=a`, `p4=ok`, `boot=ok` and `esp=ok`. Those four values
   are this page's test of a good boot: the slot was committed, the boot was recorded, and the ESP
   was readable.
3. Reach the machine from the LAN side.
   ```sh
   ssh root@192.168.100.1
   ```
   Expected: a login prompt. LuCI answers the same address on `http://192.168.100.1`, and the
   image ships the upstream root account with an empty password, so set one before the machine
   leaves the bench.

`packages=` reads `unknown` on this boot, and a disk that has never been updated has no other
answer ([install.md](install.md#reading-packages-and-packages_reason)). A seed that failed leaves
`stage=net-seed result=fail reason=<token>` on the console, and
[install.md](install.md#first-boot-at-the-console) has a way in that does not wait for a fix.

## Step 3: install one package

A package is installed with `apk` into the writable layer, which is why this step needs the network
from step 2. It is not a slot switch: no slot field moves, because the system update and the
package transaction are separate on purpose ([update.md](update.md#package-updates)).

1. Fetch the package index.
   ```sh
   apk update
   ```
   Expected: exit 0, so the feeds answered. A machine that has never run this has no index at all,
   and `apk add` then answers `(no such package)` ([update.md](update.md#package-updates)).
2. Install a package that has no kernel dependency.
   ```sh
   apk add htop
   ```
   Expected: exit 0, and one line naming `htop` with the version the feed served. `htop` is the
   pure user-space control sample this project measures (`tests/fixtures/software-samples.json`).
3. Confirm the package is installed.
   ```sh
   apk list --installed htop
   ```
   Expected: one line naming `htop` and its version. This is the post-install fact the device
   probes assert (`scripts/device/software-probe.sh`).
4. Write one configuration value and read it back.
   ```sh
   uci set system.@system[0].hostname='bench-n5105'
   uci commit system
   uci get system.@system[0].hostname
   ```
   Expected: the read-back prints `bench-n5105`, so the value is in the file that an upgrade
   carries over ([install.md](install.md#first-boot-at-the-console)).

The package and this value live in the writable layer. `packages=` is the field that says whether a
kernel module can be installed for the running slot: `aligned` is "yes", `limited` is "not until
the metadata is fixed", and `unknown` is "no verdict yet"
([install.md](install.md#reading-packages-and-packages_reason)). `unknown` on a fresh disk does not
block `apk add`, and it does block `ab-slot packages upgrade`
([update.md](update.md#package-updates)). Step 4 is what writes a verdict.

A community application installs the same way: the same `apk add <name>` and the same
post-install fact, which is not always a version string. The samples this project measures, with
the fact each one is judged by, are in `tests/fixtures/software-samples.json` and
`tests/fixtures/follow-samples.json` ([known-limitations.md](known-limitations.md#a-package-follows-the-base-only-when-the-follow-can-run)).

## Step 4: upgrade once

An upgrade writes the inactive slot and marks it pending. The running slot is not touched, so the
machine keeps working if anything goes wrong ([install.md](install.md#updating-a-running-system)).
The questions are the only guard, and they name what changes.

1. Ask the feed what is out there.
   ```sh
   ab-upgrade --feed-check
   ```
   Expected: one field line ending `status=update`, and exit status `10`. The check downloads no
   payload, touches no slot, and `10` is the answer to the question rather than an error
   ([update.md](update.md#check-for-an-update)).
2. Install it, and answer its questions with `y`.
   ```sh
   ab-upgrade --feed
   ```
   Expected: an `Update` block with `base`, `kernel`, `platform`, then `Change`, `Tested` and
   `Risk`, then `Proceed? [y/N]`. A payload carrying the package plan follows that with a
   `Packages` block and `Proceed and follow N packages? [y/N]`. Only an explicit `y` accepts.
   Enter, `n` and end-of-input decline and write nothing
   ([update.md](update.md#the-confirmation-prompt)).
3. Read the state the install left behind.
   ```sh
   ab-slot status
   ```
   Expected: `pending=<the other slot>` and `next=<the other slot>`, with `committed=` still the
   slot this boot runs. Before this reboot `pending` is the target slot, not `none`
   ([update.md](update.md#install-an-update)).
4. Reboot, then read the state again.
   ```sh
   reboot
   ```
   Expected: after the boot, `committed=<the other slot>`, `pending=none`, `next=` equal to
   `committed=` and `p4=ok`. `generation=` has already grown, because the install records the new
   layer before the reboot (`ab-slot`, `cmd_layer`). The machine that fails its health check
   returns to the committed slot by itself instead ([install.md](install.md#updating-a-running-system)).
5. Read the package verdict the jump left behind.
   ```sh
   ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(packages|packages_reason|follow)='
   ```
   Expected: `packages=followed` and `follow=followed` when the packages moved onto the new base.
   `packages=aligned` with `follow=pending reason=network` means the metadata matches and the
   packages have not moved yet ([update.md](update.md#how-packages-follow-a-base)).

## Step 5: roll back once

A rollback commits the other slot, which still holds the previous filesystem and its own writable
layer. It is the fast path back after an upgrade that boots but does not work. It is not a factory
reset ([install.md](install.md#rolling-back)). Use it when one of these is true:

- the new slot booted and committed, and something you run on it does not work;
- the update is staged and you do not want it tried: `ab-slot abandon` clears it without booting
  ([install.md](install.md#rolling-back));
- only the packages changed: `ab-slot packages revert` replays the last snapshot and leaves the
  system alone ([update.md](update.md#package-updates)).

A failed health check needs no manual step, because that boot abandons the pending slot and
reboots into the committed one.

1. Commit the other slot.
   ```sh
   ab-slot rollback
   ```
   Expected: `ab-slot: rolled back from slot <a> to slot <b>`.
2. Reboot into it.
   ```sh
   reboot
   ```
   Expected: the boot comes up on the other slot and commits it
   ([install.md](install.md#rolling-back)).
3. Confirm what the machine now runs.
   ```sh
   ab-slot status
   ```
   Expected: `committed=<the previous slot>`, `pending=none`, `next=` equal to it and `p4=ok`.
   `generation=` stays where it was, because a rollback moves the pointer rather than creating a
   generation ([lifecycle.md](lifecycle.md#writable-layer-naming), `scripts/device/recovery-probe.sh`).
4. Read the package verdict of the slot you came back to.
   ```sh
   ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(packages|packages_reason)='
   ```
   Expected: `packages=unknown` with `packages_reason=no-record` when the record described the slot
   rolled away from. The next system update writes a verdict for the slot that runs
   ([update.md](update.md#package-updates)).

Files under `/data` are shared by both slots and stay where they are. Content written after the
update stays in the layer that was rolled forward, and `ab-slot gc` does not delete it while a slot
still references it ([install.md](install.md#rolling-back)).

## Reading the status line

`ab-slot status` prints one line with one token per field, and the human sentences go to stderr. The
fields the five steps read can be pulled out in field-per-line form:

```sh
ab-slot status 2>/dev/null | tr ' ' '\n' | grep -E '^(slot|committed|pending|next|p4|generation|boot|esp|packages|packages_reason|follow)='
```

Expected: one `field=value` per line. The table below is what each of those fields means, and where
its value comes from on the machine. [update-mechanism.md](update-mechanism.md#field-reference) has
the remaining fields.

| Field | Values | Meaning | Verify with |
| --- | --- | --- | --- |
| `slot=` | `a` / `b` | the slot this boot runs, from `ab.slot=` on the kernel command line | `grep -o 'ab.slot=[ab]' /proc/cmdline` |
| `committed=` | `a` / `b` | the slot the state commits: what the next boot runs on a settled machine | `cat /boot/ab/state.json` |
| `pending=` | `none` / `a` / `b` | the candidate the next boot tries, staged by an install | `cat /boot/ab/state.json` |
| `next=` | `a` / `b` / `unknown` | the slot GRUB boots next, read back from the hint file | `ab-slot next` |
| `p4=` | `ok` / `degraded` | the shared writable partition is mounted, where `degraded` means the boot moved the writable layer to memory | `awk '$2=="/mnt/p4"' /proc/mounts` |
| `generation=` | an integer that only grows | the layer ordering number | `cat /boot/ab/state.json` |
| `boot=` | `ok` / `degraded` / `unknown` | how this boot started, from this boot's ring log, where `degraded` means the writable layer is a tmpfs | `ab-slot log \| grep stage=boot` |
| `esp=` | `ok` / `dirty` / `unreadable` / `unknown` | the initramfs' verdict on the ESP it mounted | `ab-slot log \| grep stage=esp-health` |
| `packages=` | `aligned` / `followed` / `limited` / `unknown` | whether the slot's package metadata describes the base it runs | `cat /boot/ab/packages` |
| `packages_reason=` | `none` / `other-slot` / `no-record` / an aligner token | why that verdict is what it is | `cat /boot/ab/packages` |
| `follow=` | `pending` / `followed` / `failed` / `abandoned` / `never` | whether the packages were actually moved onto this base | `ab-packages status` |

`boot=`, `esp=` and `packages=` read `unknown` rather than a comfortable default when nothing
recorded them. `committed=` and `next=` are equal on a settled machine, and a pair that disagrees is
the first thing to read after a reboot.

## What the three steps move

The three steps touch different fields. A package never moves a slot, an upgrade records the new
layer and raises `generation=` before the reboot, and a rollback moves `committed=` back without
copying a layer.

```text
  step 3  apk add htop
          |  no slot field moves as the writable layer grows
          v  committed=a  pending=none  next=a  generation=N
             packages= unchanged (unknown on a disk that was never updated)
  step 4  ab-upgrade --feed, then reboot
          |  before the reboot:  committed=a  pending=b  next=b  generation=N+1
          v  after the reboot:   committed=b  pending=none  next=b  generation=N+1
             packages=followed  follow=followed
  step 5  ab-slot rollback, then reboot
          |  the pointer moves back and no layer is copied
          v  committed=a  pending=none  next=a  generation=N+1
             packages=unknown  packages_reason=no-record
```

## Where to go next

The rest of the documentation goes deeper in four directions: the model, the feed, the backups and
the limits. Each page is the single source for its own subject, and this page does not repeat them.

- [update-mechanism.md](update-mechanism.md): the field reference, the A/B state machine, and the
  gates behind a package follow and a prune.
- [update.md](update.md): the release feed, the three version numbers, the five risk levels and
  every `reason=` token.
- [backup.md](backup.md): the three products and what each one can be restored to.
- [known-limitations.md](known-limitations.md): behaviour this project decided not to change, and
  the evidence behind that decision.
