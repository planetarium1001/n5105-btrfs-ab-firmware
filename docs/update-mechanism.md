# Update Mechanism Reference

[English](update-mechanism.md) | [中文](update-mechanism.zh-CN.md)

Every state field the update machinery publishes, with its values, its meaning, its writer
and a command that checks it on the machine. This page is a reference for maintainers and
advanced users; the procedures are in [install.md](install.md) and [update.md](update.md).

## Before you start

The commands here run on the device, as root, from a booted slot. Four surfaces carry every
fact this page talks about, and a field is verified by reading the surface it comes from:

- `/boot/ab/state.json` — slot state, the single source of truth
- `/boot/ab/packages` — the one-line package record the last upgrade published
- `/boot/ab/log/` — the ring log, `ab-slot log` to print it
- `/proc/cmdline` and `/proc/mounts` — the slot this boot came from, and what is mounted

`<slot>` below is `a` or `b`, `<version>` is an upstream release such as `25.12.2`, and
`<layer>` is the writable layer name, `@overlay-<version>` with `-r<N>` appended when that
version is used a second time.

## Layers

Four things carry the tree: two read-only subvolumes per slot, one writable layer on p4, and
the payload those subvolumes are installed from. The three p4 user subvolumes sit beside the
tree and survive a rollback.

```text
 p1  ESP (vfat)     ab/state.json  ab/packages  ab/log/  ab/device.json
                    boot/grub/ab-slot.cfg  vmlinuz-a|b  initrd-a|b

 p2  slot a         @sys        base rootfs, read-only
     (btrfs)        @platform   this project's layer, read-only
 p3  slot b         @sys        the same pair, one update older or newer
     (btrfs)        @platform

 p4  data (btrfs)   @overlay-<version>  upper/ = every write to the running root
                    @data /data   @docker /opt/docker   @swap /swap

 running root = overlay(lowerdir = @platform:@sys of the running slot,
                        upperdir = @overlay-<version>/upper)
```

| Layer | What it carries | Writable | Written by | Moves on rollback |
| --- | --- | --- | --- | --- |
| base (`@sys`) | the upstream rootfs, byte-identical | no | an update only | yes |
| platform (`@platform`) | `ab-slot`, `ab-upgrade`, the init.d hooks | no | an update only | yes |
| payload | the files an update is installed from | no | the publisher | not applicable |
| user layer (`@overlay-<version>/upper`) | `/etc/config`, `/etc/apk/world`, installed packages | yes | the running system | yes |
| `/data`, `/opt/docker`, `/swap` | user files, container state, swap | yes | the user | no |

Source: `docs/boot-overlay.md` layer responsibilities and p4 subvolumes, `docs/partitions.md`.

### What the payload carries

A payload is a tar with a manifest beside its members, and every member is digest-checked
against the manifest before anything is written.

| Member | Required | What an update does with it |
| --- | --- | --- |
| `manifest.json` | yes | `format`, `rootfs`, `platform`, and one `sha256` block per member |
| `rootfs.tar.gz` | yes | extracted over the target slot's `@sys` |
| `kernel.bin` | yes | copied to `/boot/vmlinuz-<slot>` |
| `initramfs.cpio.gz` | yes | copied to `/boot/initrd-<slot>` |
| `platform.tar` | yes | extracted over the target slot's `@platform` |
| `boot.tar` | optional, and required when the run passes `--bootloader` | installed through the ESP staged-write, the replaced menu kept as `grub.cfg.prev` |

Source: `platform/usr/sbin/ab-upgrade` member table and digest loop,
`platform/lib/upgrade/platform.sh` for the slot writes.

### Where user state lives

Three places hold state the user owns, and they differ in what restores them.

- `/etc/config` and every other edit under the composed root live in `upper/`, so they ride
  the layer and roll back with the slot.
- `/etc/apk/world`, the apk database and `/etc/apk/ab/local/` live beside them, for the same
  reason: a kept package body is on the layer, never on `/data`.
- `/data` and `/opt/docker` are separate subvolumes. No update and no rollback writes there.

Source: `platform/lib/upgrade/packages.sh` kept-body store, `docs/boot-overlay.md`.

## Slot state machine

Two slots alternate. `ab/state.json` names the committed slot and the candidate, and every
transition is one atomic rename of that file, followed by a rebuild of the GRUB hint.

```text
 committed=a, pending=none      GRUB: default=a, fallback=a
        |
        |  ab-upgrade <payload>          stages slot b in place
        |  ab-slot layer b <ver> <layer> generation + 1, b's version and layer updated
        |  ab-slot pending b             pending=b, candidate marker cleared
        v
 committed=a, pending=b         GRUB: default=b, fallback=a
        |
        |  reboot; GRUB passes ab.slot=b; ab-boot heals the hint from the state
        v
 candidate b boots              ab-boot logs this boot as a candidate, attempt=<n>
        |
        |  ab-commit, 150 second budget: three probes
        |
        +-- all pass ------> ab-slot commit b    committed=b, pending=none
        |
        +-- one fails -----> ab-slot abandon     committed=a, pending=none, reboot into a
        |
        +-- boot dies -----> initramfs fail-safe abandon, or the attempt counter reaches
                             AB_BOOT_RETRY_MAX (1) and the next boot abandons with
                             result=abandon reason=attempt-limit
```

Source: `platform/usr/sbin/ab-slot` state commands, `platform/etc/init.d/ab-boot`,
`platform/etc/init.d/ab-commit`, `initramfs/lib/wf.sh`.

## The state file

`ab/state.json` is the truth, and `boot/grub/ab-slot.cfg` is the hint GRUB can read. The
hint holds two commands, fallback first, so a write cut short still falls back to the
committed slot. It names menu entry indices rather than slot letters: slot `a` is entry `0`
and slot `b` is entry `1`.

| Field | Values | Meaning |
| --- | --- | --- |
| `generation` | integer, only grows | orders writable layers for reclamation; names none of them |
| `committed` | `a` \| `b` | the slot the machine is committed to run |
| `pending` | `a` \| `b` \| `null` | the candidate the next boot tries, `null` for none |
| `slots.<a\|b>.rootfs` | `<version>` | the upstream release that slot carries |
| `slots.<a\|b>.upper` | `<layer>` | the writable layer that slot boots on |

`generation` moves only in `ab-slot layer`, which is the command an update calls when it
stages a slot. `pending`, `commit`, `abandon` and `rollback` rewrite the file and leave the
number alone.

Source: `platform/usr/sbin/ab-slot` state reading and `write_state`, `cmd_layer`.

## Health check and rollback criteria

Three probes run after `done`, in one boot, within 150 seconds. All three must pass before
the candidate is committed.

| Probe | Passes when |
| --- | --- |
| `overlay-writable` | the composed root `/` is writable with at least 16 MiB free |
| `fw4-present` | the nft ruleset is non-empty and the `inet fw4` table exists |
| `wan-present` | the device named by `network.wan` exists |

A failure is not repaired: the pending slot is abandoned, `pending` is cleared, the hint
points back at the committed slot, and the machine reboots into it.

Source: `docs/lifecycle.md` health check, `platform/etc/init.d/ab-commit`.

## Field reference

`ab-slot status` prints one machine-readable line on stdout and a human summary on stderr,
so `ab-slot status 2>/dev/null` is the line alone. The field order is fixed, and the package
fields at the end appear only when `/boot/ab/packages` exists.

| Field | Values | Meaning | Verify on the machine |
| --- | --- | --- | --- |
| `slot=` | `a` \| `b` | the slot this boot runs, from `ab.slot=` on the kernel command line; the committed slot when that is absent | `grep -o 'ab.slot=[ab]' /proc/cmdline` |
| `upper=` | `<layer>` | the writable layer of the running slot | `cat /boot/ab/state.json` and `btrfs subvolume list /mnt/p4` |
| `generation=` | integer | the layer ordering number | `cat /boot/ab/state.json` |
| `committed=` | `a` \| `b` | the slot the state commits | `cat /boot/ab/state.json` |
| `pending=` | `a` \| `b` \| `none` | the candidate the next boot tries | `cat /boot/ab/state.json` |
| `p4=` | `ok` \| `degraded` | `/mnt/p4` is mounted | `awk '$2=="/mnt/p4"' /proc/mounts` |
| `data=` | `ok` \| `missing` | `/data` is mounted | `awk '$2=="/data"' /proc/mounts` |
| `docker=` | `ok` \| `missing` | `/opt/docker` is mounted | `awk '$2=="/opt/docker"' /proc/mounts` |
| `swap=` | `ok` \| `missing` | `/swap` is mounted | `awk '$2=="/swap"' /proc/mounts` |
| `next=` | `a` \| `b` \| `unknown` | what GRUB will boot, read back from the hint file | `ab-slot next` |
| `disk=` | a device node, or `unknown` | the disk this machine booted from | `ab-slot log \| grep stage=device` |
| `method=` | `cmdline` \| `partuuid` \| `partname` \| `mount` \| `unique` \| `unresolved` \| `unavailable` | how that disk was established | the same `stage=device` line |
| `boot=` | `ok` \| `degraded` \| `unknown` | how this boot started, read from this boot's ring log | `ab-slot log \| grep stage=boot` |
| `esp=` | `ok` \| `dirty` \| `unreadable` \| `unknown` | the initramfs' verdict on the ESP it mounted | `ab-slot log \| grep stage=esp-health` |
| `packages=` | `aligned` \| `limited` \| `followed` \| `unknown` | whether the slot's package metadata describes the base it runs | `cat /boot/ab/packages` |
| `packages_reason=` | an aligner token, `none`, `no-record`, `other-slot`, `unknown` | why that verdict is what it is | `cat /boot/ab/packages` |
| `follow=` | `pending` \| `followed` \| `failed` \| `abandoned` \| `never` \| `unknown` | whether the packages were actually moved onto this base | `ab-packages status` |
| `reason=` | `none`, `network`, `timeout`, `no-evidence`, `apk-<rc>`, `no-world`, `no-apk`, `no-packages`, `feeds-rewritten`, `no-record`, `other-slot`, `unknown` | why the last follow attempt ended the way it did | `ab-packages status` |
| `hint=` | `ab-packages update` \| `none` | the command that retries the follow | `sed -n 's/^.* hint=//p' /boot/ab/packages` |

Three values are claims a machine must not make without evidence, so they read `unknown`
rather than a comfortable default: `boot=`, `esp=` and `packages=`.

Source: `platform/usr/sbin/ab-slot` `cmd_status` and the field readers above it.

### Reading a field in a script

One function reads most of the line. The `^` anchor matters: without it `reason=` also
matches `packages_reason=`.

```sh
ab-field() { ab-slot status 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
ab-field pending
ab-field follow
```

`hint=` holds a space, because its value is a command, so it is the last field of the record
and it has its own reader:

```sh
sed -n 's/^.* hint=//p' /boot/ab/packages
```

A field that names a slot's version has its own command, and it does not read the status
line at all:

```sh
ab-slot rootfs a
ab-slot rootfs b
```

## Package follow

An update replaces the system tree, and the packages installed under it were built for the
old base. Aligning the metadata is offline and mechanical. Moving the packages is a second
transaction, and it needs a network or a prefetch.

Four things start the follow. Three of them read one record field, `follow=pending`; the
upgrade decides from the answer to its own question.

| Trigger | Who starts it | What decides |
| --- | --- | --- |
| the upgrade, before the switch | `ab-upgrade` runs the gate, asks once, then prefetches | the plan block and the answer to its question |
| the first boot of the new base | `ab-boot` detaches a worker | `follow=pending` for this slot in the record |
| an `ifup` | the ifup hotplug hook, one attempt | the same record, and the single-instance lock |
| a person | `ab-packages update` | the same record; the gate and the plan run again |

The boot never waits for the follow and never runs `apk` on the boot path. One worker runs
at a time, under `/var/lock/ab-packages-follow.lock`.

Source: `platform/etc/init.d/ab-boot`, `platform/etc/hotplug.d/iface/90-ab-packages`,
`platform/lib/ab-net-probe.sh`, `platform/usr/sbin/ab-packages`.

## Prefetch and the offline apply

The download happens before the switch, while the machine still runs a slot that works. The
solver says which packages would move, and exactly those are fetched into the new slot's own
cache, `/etc/apk/ab/cache/` in the layer that will be booted.

```sh
apk --cache-dir /etc/apk/ab/cache --cache-max-age 100000 \
    add --virtual .ab-follow --allow-untrusted --force-non-repository \
    /etc/apk/ab/cache/*.apk
apk del .ab-follow
```

That is what the first boot runs when the cache holds bodies, and it needs no network. A
prefetch that fails is not an upgrade that fails: the record falls back to
`follow=pending reason=network` and the retry ladder below picks it up.

| Rung | When the worker retries |
| --- | --- |
| W1 | at 0, 15, 30, 60, 120 and 300 seconds after the worker starts |
| W2 | once per `ifup` |
| W3 | every 1800 seconds until 86400 seconds after the boot, then `follow=abandoned` |

Source: `platform/lib/upgrade/packages.sh` prefetch and offline follow,
`platform/lib/ab-net-probe.sh` ladder.

## The record fields: packages= and follow=

`packages=` describes metadata, and `follow=` describes the packages themselves. Both are
published on one line, so one reading tells "the metadata matches the base" apart from "the
packages moved onto it".

| Event | `packages=` | `follow=` | `reason=` |
| --- | --- | --- | --- |
| the aligner succeeds before the switch | `aligned` | `pending` | `none` or `feeds-rewritten` |
| the user answered `--system-only` | unchanged | `never` | `none` |
| the prefetch landed bodies | `aligned` | `pending`, with `cache=<bytes>` | `none` |
| the prefetch could not run or the feed did not answer | `aligned` | `pending` | `network` |
| the first boot found no usable network | `aligned` | `pending` | `network` |
| the transaction moved packages | `followed` | `followed` | `none` |
| the world was already current | `followed` | `followed`, `upgraded=0` | `none` |
| the transaction failed or skipped everything | unchanged | `failed` | `apk-<rc>`, `timeout`, `no-evidence` |
| 24 hours passed with no usable feed | unchanged | `abandoned` | `network` |

Source: `platform/lib/upgrade/packages.sh` record publishing and follow engine.

## Prune: the two gates

A move between releases can leave a `world` entry the new base's feeds no longer carry, and
one such entry makes every later apk transaction unsolvable. The prune drops that entry and
keeps everything else: the package stays installed, its files stay, and `/etc/config` and
`/data` are never touched.

Before anything is dropped, two independent gates must both answer.

| Gate | Test | Refusal when it fails |
| --- | --- | --- |
| the index was refreshed | the caller reports its `apk update` succeeded | `index-stale`, nothing is dropped |
| the index can answer at all | `apk search` returns a canary name the world does not mention | `index-unusable`, nothing is dropped |

The second gate is what separates "this release has no such package" from "the index could
not be read". An index that answers nothing answers "no" to every name, and dropping the
whole world on that answer would be a mass delete dressed as a diagnosis.

A candidate that survives both gates is still confirmed against the indexes one more time:
a name the feed does offer is a pin whose version is gone, not a package the release lacks,
and that entry is kept.

| Reported where | What it says |
| --- | --- |
| `stage=packages-prune` in the ring log | `dropped=<n>` and the names |
| `world_dropped=` in the record | the count, written by the refresh path |
| `ab-slot status`, human summary | the count, read back from `world_dropped=` |

Source: `platform/lib/upgrade/packages.sh` prune, `platform/lib/ab-net-probe.sh` worker.

## Gates and failure semantics

Three outcomes are easy to confuse: a refused upgrade, a `limited` verdict and a gap. They
happen at different moments and cost different things.

### What refuses an upgrade

A refusal happens before anything is written, exits `74`, and leaves the machine as it was.
Every token is listed in [update.md](update.md); the categories are:

- the machine is not a valid target — `writable-layer-degraded`, `low-space-<n>pct` below 5
  percent, `slot-status-failed`, `platform-layer-shadowed`, `payload-already-installed`
- the payload does not describe itself consistently — `manifest-*`, `member-missing-*`,
  `digest-mismatch-*`, `initramfs-mixed-module-vermagic-<n>`
- the feed answer is unusable — the `feed-*` tokens, from configuration to a digest that does
  not match

A blocked package gate does not refuse the upgrade. It sets the number of packages the
question offers to zero and the system still switches.

Source: `platform/usr/sbin/ab-upgrade` refusal sites, `docs/update.md`.

### What degrades to limited

`packages=limited` means the metadata could not be made to describe the base the slot now
runs. The switch is not blocked: the machine boots and runs, and cannot install a package
built against this kernel until the metadata is fixed.

| Writer | Token in `packages_reason=` |
| --- | --- |
| the aligner's caller, when `packages.sh` is missing from the new layer | `packages-lib-missing` |
| the aligner returned non-zero | the aligner's own token, such as `world-unwritable`, `distfeeds-unwritable`, `world-not-verified` |
| the superseded refresh path, when a library exposes no follow entry | `feeds-stale`, `pruned`, `refresh-failed`, `partial` |

`ab-slot packages upgrade` refuses on anything but `aligned` or `followed`, which is the
gate that keeps a package transaction off a slot whose metadata is stale.

Source: `platform/lib/upgrade/platform.sh` alignment stage, `platform/lib/upgrade/packages.sh`.

### What a gap is

The gate answers with one of three states. `ok` and `blocked` are about whether the follow
can run at all; `gap` says it can run and part of the world cannot move.

| State | Reason | What it means |
| --- | --- | --- |
| `ok` | `none` | every world entry can follow |
| `blocked` | `pin-mismatch`, `unsolvable`, `unreachable` | the follow cannot run; the upgrade still proceeds |
| `gap` | `none`, `no-world`, `no-apk`, `no-tmp`, `no-feeds` | the follow runs, and the named entries stay where they are |

Each entry a gap holds back carries one attribution token, and the plan block and the record
use the same vocabulary: `local` (NO COPY), `stale-abi` (ABI STALE), `gone` (DROPPED),
`pinned` (PINNED), `unreachable` (UNREACHABLE).

Source: `platform/lib/upgrade/packages.sh` gate, `platform/lib/ab-plan.sh` display words.

## Troubleshooting

Each symptom names the command that answers it first. A `reason=` token in a log line is the
same token a report should quote.

| Symptom | First command | What it tells you |
| --- | --- | --- |
| an update exits `74` | the printed `reason=` line, then `ab-slot log --upgrade` when the run was saved there | which check refused, and that nothing was written |
| the machine reboots into the old slot after an update | `ab-slot log --prev` | `stage=abandon result=fail reason=healthcheck-failed detail=<probe>` names the probe |
| the machine never commits a slot it booted | `ab-slot log \| grep -E 'probe=\|stage=commit\|stage=abandon'` | which probe failed, or that the commit itself failed |
| `next=` is not the slot you expect | `ab-slot next` and `ab-slot next --write` | the hint was stale; `stage=slot-cfg` in the log shows what was written |
| `follow=` stays `pending` | `ab-packages status` and `ab-slot log \| grep stage=packages-refresh` | the rung, the probe verdict and the reason of the last attempt |
| `follow=failed` | `ab-packages status`, then `ab-packages update` | the reason token; `apk-<rc>` means the transaction itself failed |
| `packages=limited` | `cat /boot/ab/packages` | the aligner token; the next upgrade rewrites the metadata |
| `packages_reason=` says `other-slot`, or `packages=` or `follow=` says `unknown` | `ab-slot status` and `cat /boot/ab/packages` | the record describes another slot, or no slot; the next upgrade or rollback retargets it |
| the writable partition fills up | `df -h /mnt/p4` and `ab-slot gc --dry-run` | which layers are unreferenced and would be reclaimed |
| `disk=unknown` | `ab-slot log \| grep stage=device` | the resolution level that failed; `ab/device.json` and the GPT names are the inputs |
| `boot=degraded` | `ab-slot log`, then the degraded section of [install.md](install.md) | the writable layer is a tmpfs and nothing written this boot survives |
| `esp=dirty` or `esp=unreadable` | `ab-slot log \| grep stage=esp-health` | the initramfs judged the ESP before mounting it; the boot still continued |

## Further reading

- [update.md](update.md) — the feed, the risk levels, every refusal token and exit status
- [install.md](install.md) — writing an image, the first boot, rescuing a torn bootloader
- [lifecycle.md](lifecycle.md) — the update transaction, reclamation, the ring log format
- [boot-overlay.md](boot-overlay.md) — the boot chain and the layered root
- [partitions.md](partitions.md) — the four partitions and the subvolumes on them
- [conflicts-payload.md](conflicts-payload.md) — conflict detection and the payload contract
