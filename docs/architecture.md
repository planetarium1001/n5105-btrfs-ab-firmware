# Architecture

**English** | [简体中文](architecture.zh-CN.md)

One disk, four partitions, two bootable slots and one shared writable partition. This page
describes that structure: the partition geometry, the filesystems and subvolumes on it, the
boot chain that composes the running root, the slot state machine behind A/B switching, and
the payload an update is installed from.

Read it before changing the boot path, the partition layout, the state file or the payload
format. Every threshold, log field and contract named here is asserted by
`scripts/check_design.py`; changing one means changing the check in the same commit.

## Partition layout

Single disk, GPT, UEFI only. Two independent system slots and one partition for all writable
state:

| Partition | GPT PARTNAME | LABEL | Size | Filesystem | Contents |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB, boot menu, `vmlinuz-a/b`, `initrd-a/b`, `ab/` state, `ab/log/`, `ab/device.json` |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | `@sys`, `@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | `@sys`, `@platform` |
| p4 | `ab-data` | `data` | 128 MiB | btrfs | `@overlay-<version>`, `@docker`, `@swap`, `@data` |

There is no p128 (EF02) and no legacy boot path. p4 ships at 128 MiB and is grown to
the end of the disk on first boot; p1 to p3 never move.

### Two names per partition

| Set | Values | What depends on it |
|---|---|---|
| GPT PARTNAME | `ab-esp`, `ab-slot-a`, `ab-slot-b`, `ab-data` | the boot code, which matches it against `/sys/class/block/*/uevent` |
| Filesystem LABEL | `ESP`, `slot-a`, `slot-b`, `data` | humans, and the `blkid` / `lsblk` assertions in the image stages |

PARTNAME keeps the `ab-` prefix because discovery walks every block device on the machine: a
bare `data` or `esp` would eventually match an unrelated disk and mount the wrong partition.
Four code paths resolve these names (`initramfs/boot/init`, `/etc/init.d/ab-boot`,
`/etc/init.d/ab-commit`, `lib/upgrade/platform.sh`), and each falls back to the 1/2/3/4 order
when no PARTNAME matches, so a missed rename hides behind the fallback instead of failing at
boot. LABEL carries no version: `@overlay-<version>`, `/etc/platform-release` and
`ab/state.json` already hold it, and relabelling on every release would add a superblock write
that power loss can interrupt.

p1 holds data only, never executable scripts: FAT32 has no permission bits or symlinks, no
journal, and scripts stored on the ESP do not roll back with a slot.

### Sizing

Measured baseline, ImmortalWrt 25.12.2 on x86-64:

| Item | Value |
|---|---|
| `rootfs.tar.gz` | 10.1 MiB |
| Extracted rootfs | 26.9 MiB, 1078 files |
| 4K block usage | 31 MiB |
| After `zstd:6` | 10.3 MiB |
| `generic-kernel.bin` | 7.35 MiB |

- **p1 = 128 MiB.** Peak content is about 27 MiB (loader 3–6 MiB, two kernels 15 MiB, two
  initrds 4–6 MiB, state and logs under 1 MiB), so headroom is about 4×. The build fails if p1
  content reaches 64 MiB.
- **p2 = p3 = 128 MiB.** 4.7× the extracted rootfs and 12× its `zstd:6` size; power-of-two
  aligned so ratios are easy to audit; read-only at run time and written only during updates.
- **p4 = 128 MiB in the image, the rest of the disk after first boot.** The image is 514 MiB:
  1 MiB alignment, four 128 MiB partitions, 1 MiB tail for the backup GPT. 128 MiB is the floor
  that keeps the writable layer usable: a 20 MiB payload pushed into `upper` left a 64 MiB
  filesystem at `used 63/64 MiB`, and overlayfs could not create its `work/` directory.

## Filesystems and subvolumes

| Partition | `mkfs` arguments | Rationale |
|---|---|---|
| p1 | `mkfs.vfat -F 32 -n ESP` | the FAT32 label field is 11 characters wide; `ESP` fits and says what the partition is |
| p2 / p3 | `mkfs.btrfs -m dup -d single -L slot-a` (`-L slot-b` for p3) | metadata is 4–8 MiB; duplication recovers silent corruption inside a slot |
| p4 | `mkfs.btrfs -m single -d single -L data` | container layers inflate metadata; duplication is not worth the cost |

| Mount point | Options |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@platform` | `ro,noatime` |
| `@overlay-<version>` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime` |

`compress=` is fixed by the first mount of a filesystem, so p4 is mounted before the read-only
slot layers. One btrfs carries one level: p4 mounts `zstd:6` and every subvolume on it inherits
that level, so `@data` names no level of its own. `@docker` and `@swap` are `nodatacow` and stay
uncompressed regardless.

Subvolumes:

- p2 / p3: `@sys`, `@platform`
- p4: `@overlay-<version>` (containing plain directories `upper/` and `work/`), `@docker`,
  `@swap`, `@data`

All subvolumes are top-level. No second-level or nested subvolumes exist. `@docker` and
`@swap` must stay independent: snapshots do not recurse into nested subvolumes, and an active
swapfile prevents snapshotting.

Image assertions: GPT PARTNAME and filesystem LABEL match the table above when read back from
the image; p1 carries `boot/grub/ab-slot.cfg` with one `set default=` and one `set fallback=`
line and no `load_env`/`save_env` call; p1 carries `ab/device.json` with the GPT disk GUID and
four distinct PARTUUIDs that match the table; p2/p3 usage stays under 50%; every entry in
`btrfs subvolume list` shares the same top level; the `mkfs` arguments match this page exactly.

## First-boot growth of p4

p4 ships 128 MiB and the tail of the disk stays unallocated, so one image fits any disk size.
Growing it takes **two boots**:

1. **the boot that writes the table** decides whether p4 is short of the last usable LBA,
   rewrites the GPT with `sfdisk --no-reread`, records `result=table-written`, and reboots. It
   never resizes the filesystem;
2. **the boot after it** finds the table already at the end of the disk, so the only step left
   is `btrfs filesystem resize max`, and it records `result=done`;
3. **every boot after that** records `result=already-full`, which is the steady state.

**A first boot therefore reboots once by itself, and GRUB will be seen twice.** That is the
design working: the first boot can only finish the partition table, the second finishes the
filesystem, and every boot after that is a normal boot.

The step that used to run here was `blockdev --rereadpt` (or `partx -u`) straight after the
table write, on the disk the boot was still using, and a real machine panicked inside that
window on its first flash. Nothing in the boot path asks the kernel to re-read a partition table any more: **the reboot is the re-read**, because the next boot's kernel parses the GPT at
device probe time with nothing mounted. The same window is why the reboot is controlled
(`reboot -f` after the root subvolume is given back and the writes are flushed): a panic there
leaves no evidence, while a reboot leaves the record of the stage that finished.

The initramfs half, in order:

1. `sfdisk -d` dumps the partition table; the dump is kept as the pre-change copy.
2. The decision compares the end of p4 with the last usable LBA (`last-lba`). Equal means
   `already-full` and nothing is written; short means the new size is
   `last usable LBA - p4 start + 1`, rounded down to a multiple of the filesystem sectorsize
   (4096 bytes, 8 sectors). If rounding leaves no gain the state is `already-full`.
3. Before the table is touched, the p4 root subvolume is mounted at its old geometry and
   `.ab/partitions.before` plus `result=table-write-pending` are written. The mount is given
   back immediately. If it cannot be given back the table is not written and the record says
   `fail:p4-still-mounted`.
4. Only the `size=` field of the p4 line changes in a copy of the dump; `sfdisk --no-reread`
   writes it back, relocating the backup GPT as part of the same write. Every other line,
   including the table UUID and the other three partitions, is written back unchanged.
5. The table is read back and compared, and `sfdisk --verify` checks both GPT copies. A write
   that did not land is `fail:table-write-not-verified`; a table that does not verify is
   `fail:table-verify`; neither reboots. An `sfdisk` without `--verify` is recorded as
   `verify=unsupported` and the growth continues.
6. The root subvolume is mounted again, `result=table-written` is recorded (the buffered
   `.ab/grow.log` is appended first), the mount is given back, writes are flushed, and the
   machine reboots.
7. On the next boot the resize runs on a clean mount of p4 - no `compress=`, no `discard=`, no
   `subvol=` - and records `result=done`.

The outcome is one line in `<p4 root subvolume>/.ab/grow`:

```
result=<token> last_lba=<n>
```

| State | Meaning |
|---|---|
| `table-write-pending` | a table write is in flight; a boot that dies in the write window leaves this behind |
| `table-written` | the table was written and verified; the reboot is the next step |
| `done` | this boot resized the filesystem onto the new geometry |
| `already-full` | the previous boot already recorded `done`/`already-full` at this disk end; nothing was written |
| `missing-sfdisk` | `sfdisk` is not in this initramfs; nothing was written |
| `fail:<token>` | a step failed: `partition-table-read`, `partition-table-write`, `p4-still-mounted`, `table-write-not-verified`, `table-verify`, `table-write-lost`, `resize-mount`, `btrfs-resize` |

A record written by the one-phase firmware is still read correctly: `done` and `already-full`
keep their meaning, and a retired `fail:` token reads as "not proven". A machine that was
already grown reports `already-full` on its first boot with this firmware.

`ab-boot` finishes the job at run time: it reads `<p4>/.ab/grow`, retries
`btrfs filesystem resize max /mnt/p4` when the initramfs could not (p4 mounted exactly once,
btrfs-progs from the platform layer), and records
`stage=resize result=<ok|fail:<token>> source=ab-boot` in the p1 ring log. A machine whose
initramfs resize failed still reaches the end of the disk on that same boot.

Evidence from a boot that died: `ab-boot` writes this boot's ring log to `ab/log/boot-0.log`
and rotates it to `boot-1.log` on the next boot. The boot that writes the table never reaches
`ab-boot`, so its evidence is in `.ab/grow`, the append-only `.ab/grow.log`, and `boot-1.log`
after the following power-on; read `ab-slot log --prev` for a post-mortem and `boot-0.log` only
for the running boot. The pre-change table is kept at `.ab/partitions.before`, because a copy
that lived only in the initramfs dies with it. The record lives on the p4 root subvolume, not
inside a generation layer, so it outlives `@overlay-<version>`.

Growth only enlarges p4 and is idempotent. The one thing the record decides is the loop guard:
a `table-written` record for exactly the disk end this boot wants to write, while the table on
disk still reads shorter, means the write was lost below the filesystem - that boot records
`fail:table-write-lost` instead of writing and rebooting again.

## Boot chain and layered root

1. GRUB reads slot state and `ab-slot.cfg` from p1, then selects a kernel and initrd.
2. The initramfs resolves which disk carries the four partitions, locates p1 to p4 on it, and
   decides whether p4 has to grow. If it does, this boot rewrites the partition table, records
   that, and reboots.
3. The initramfs resizes the filesystem on a clean mount of p4, then mounts the p4 writable
   layer, the read-only slot layers and the p4 user-data subvolumes.
4. overlayfs composes the root.
5. `switch_root` enters the system; p1 is mounted at `/boot`.

The CI guest assertion is not part of that chain. `/s3-post.sh` re-checks the composed root and
prints the frozen `S3-RESULT` line; it is injected only when the build sets `AB_CI_HOOKS=1`, so
a flashed machine never runs CI bookkeeping as PID 1. `scripts/ci/image-verify.sh` reads the
member table of both initrds back and compares it with the kind `ab/image.json` records.

### Device identity

Nothing on the boot path may assume `/dev/vda`: that name only exists on virtio, while the
target board presents `/dev/sda`, `/dev/nvme0n1` or `/dev/mmcblk0`. The single implementation of
"which disk is ours" is `platform/lib/disk-identity.sh`, shipped both in the boot initramfs and
in the platform layer as the same bytes.

Resolution order, first answer wins, and a level is used only when it has evidence:

| Level | Evidence | Notes |
|---|---|---|
| 1 | `ab.disk=` then `wf.dev=` on the kernel command line | tests and QEMU; accepted only when that disk carries `ab-esp` |
| 2 | PARTUUID from `ab/device.json` on the ESP | written at build time; survives `dd` to another disk |
| 3 | PARTNAME | the `ab-*` GPT names, scanned through `/sys/class/block/*/uevent` |
| 4 | mount reverse lookup | `/boot`, `/mnt/p4` and `/data` in the running system; the ESP the initramfs already mounted |
| 5 | unique candidate | the only non-removable disk whose partitions carry the four filesystem LABELs |

The parent disk is always derived from sysfs: `/sys/class/block/<part>/partition` says the node
is a partition and `DEVNAME` one directory up is the disk; no code trims a `p` off a name or
appends a digit. A disk counts only when sysfs reports `DEVTYPE=disk` and `removable=0`. The
four partitions must resolve to the same disk: a set split over two disks is
`partitions-split`, a set that exists twice is `ambiguous-disk`, and both leave the partition
table untouched and keep the boot going. The result is logged as
`stage=device disk=<dev> method=<cmdline|partuuid|partname|mount|unique>`, and a boot whose disk
cannot be identified reports the reason and continues without growing or mounting p4 instead of
powering off.

### Layers and mount composition

| Layer | Subvolume | Mode | Contents | Written by |
|---|---|---|---|---|
| Upstream system | `@sys` | ro | upstream rootfs, byte-identical | updates only |
| Platform | `@platform` | ro | `ab-slot`, init.d hooks, recovery tooling | updates only |
| User state | `@overlay-<version>` | rw | configuration, installed packages, user files | runtime |

`@platform` is versioned with the slot: it is written during an update and rolls back with the
slot.

```
/ = overlay(
      lowerdir=/mnt/@platform:/mnt/@sys,
      upperdir=/mnt/p4/@overlay-25.12.2/upper,
      workdir=/mnt/p4/@overlay-25.12.2/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` order is fixed as `@platform:@sys`; the platform layer takes precedence
- `index=off` avoids the in-use exclusion lock and stale index entries after rollback
- the `volatile` option is never used

Mount order:

1. Mount `@overlay-<version>` from p4 with `rw,compress=zstd:6,discard=async`
2. Run `btrfs filesystem resize max` on that mount point
3. Mount `@platform` with `ro`
4. Mount `@sys` with `ro`
5. Compose the overlay at `/newroot`
6. Mount `@data`, `@docker` and `@swap` under `/newroot`
7. Assert that the `/proc/mounts` entry of the p4 mount contains `compress=`

p4 is mounted first because `compress=` is only applied by the first mount of a filesystem;
mounting a read-only layer first leaves the parameter out of the kernel.

The three user-data subvolumes are mounted by the initramfs itself, through the composed root,
so they exist before the first process starts:

| Subvolume | Mount point | Options | Why |
|---|---|---|---|
| `@data` | `/data` | `rw,noatime` | user data; compression follows the filesystem |
| `@docker` | `/opt/docker` | `rw,noatime,nodatacow,nodatasum` | matches the upstream dockerd package, `option data_root '/opt/docker/'` |
| `@swap` | `/swap` | `rw,noatime,nodatacow,nodatasum` | swapfiles must not be COW or compressed |

A failed mount there is reported as `p4-partial` and the boot continues; `ab-slot status` shows
the three marks next to `p4=`.

`@platform` mirrors final filesystem paths: `/usr/sbin/ab-slot`, `/usr/sbin/ab-upgrade`,
`/etc/init.d/ab-boot`, `/etc/init.d/ab-commit`, `/lib/ab-slot-cfg.sh`,
`/lib/ab-partitions.sh`, `/usr/sbin/btrfs` with its runtime library closure, and
`/etc/uci-defaults/`. Because overlayfs merges directories, procd reads `/etc/init.d/*` from the
merged view and the hooks run while `@sys` stays untouched.

## Slot state and the boot hint

`ab/state.json` on p1 is the truth, written atomically (temp file, `sync`, rename):

```json
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
```

GRUB cannot read it, so the bootloader gets one derived value in a file of its own:

| Artefact | Written by | Read by | Role |
|---|---|---|---|
| `ab/state.json` | `ab-slot` (temp file, `sync`, rename) | initramfs, `ab-boot`, `ab-commit`, `ab-upgrade`, `ab-slot` | the truth: `committed`, `pending`, layers |
| `boot/grub/ab-slot.cfg` | `ab-slot` in `pending`/`commit`/`abandon`/`rollback`, `ab-boot` on every boot, and the boot initramfs on its failure path | GRUB, through `source` | the hint: which entry the next boot runs, and where a failed try falls back to |
| `boot/grub/grub.cfg` | the image build once; an upgrade, from the payload's `boot.tar` | GRUB | the menu and the build-time default; no boot, commit or rollback rewrites it, while an upgrade replaces the whole file and keeps the old one as `grub.cfg.prev` |
| `ab/candidate` | the boot initramfs before the root switch (`<slot> <start-ts> <attempt>`), and `ab-boot` only when it is missing | the next boot's initramfs, `ab-boot` | the candidate marker: still present means the last candidate boot never reached `ab-commit` |
| `ab/interrupted` | the boot initramfs, when it finds a leftover marker | `ab-boot`, once per boot | one line about an interrupted candidate boot, published as `stage=interrupted` and then removed |

`boot/grub/ab-slot.cfg` holds exactly two GRUB commands, in this order:

```
set fallback=<the committed slot>
set default=<the pending slot, or the committed slot when nothing is pending>
```

Every writer derives both values from the state file through one implementation
(`platform/lib/ab-slot-cfg.sh`), so the build, the state commands, the boot hook and the boot
failure path cannot disagree. There is no environment block: the GRUB in the ESP is a standalone
EFI binary with its modules built in and no `env` module. A two-line file that `source` reads
works on that binary, and `scripts/ci/grub-render.sh --verify-esp` asserts that the loader
really carries `source`, `test` and `serial` before an image is allowed to boot.

The menu defines the three entries, sets the committed slot as the build-time default and
fallback, and only then sources the hint file. GRUB stops reading a script at the first error,
so a missing, truncated or malformed hint cannot cost the machine its menu. Entry indices are
part of the contract: slot `a` is entry 0, slot `b` is entry 1.

### Power loss between the two writes

The state file and the hint are written one after the other, each atomically. A power cut in
the gap leaves the state advanced and the hint stale, and the machine boots the slot the hint
names.

- `ab-boot` rewrites the hint from the state file on every boot, before anything reads it, so a
  stale hint costs one boot and never a wrong slot.
- The hint file writes its fallback line first: a write cut short after the first line has
  written only `set fallback=<committed>`, which is the value the menu already had. No
  truncation can leave the fallback pointing at the slot being tried.

### When a new slot does not work

1. the kernel of the pending slot does not start: GRUB moves to the `fallback` entry, which is
   the committed slot;
2. the kernel starts and the health check fails: `ab-commit` abandons the pending slot, clears
   `pending`, points the hint back at the committed slot and reboots into it;
3. the kernel starts but the boot initramfs fails before userspace: the failure path runs the
   same fail-safe abandon (`action=fail-safe-abandon`) and only then powers off;
4. the kernel starts and the boot ends before `ab-commit` decides (power cut, hang): the next
   boot finds the candidate marker, counts the attempt, logs
   `stage=interrupted … result=retry` and retries. `AB_BOOT_RETRY_MAX` (default 1) bounds the
   retries, so the boot after the limit clears `pending` and logs
   `stage=interrupted … result=abandon reason=attempt-limit`.

`ab-slot rollback` is the manual path: it commits the other slot and moves the hint with it.
`ab-slot status` reports the hint as `next=<a|b|unknown>`, and `ab-slot next` prints it alone.

## Update transaction

The writable layer is named after the upstream release it belongs to, `@overlay-<version>`,
for example `@overlay-25.12.2`. Every update creates a new layer, and no subvolume is ever renamed. A repeat of the same upstream version takes an ordinal suffix,
`@overlay-25.12.2-r2`, because the platform layer can be rebuilt without the base moving. The
name is for humans; ordering comes from the integer `generation` in `ab/state.json`, which only
grows, and reclamation sorts by that number. Consequences: a new layer can be created even if
the system has never rebooted, rollback only moves a pointer, and steady state needs exactly
two layers, one per slot.

| Event | p4 | p1 state |
|---|---|---|
| Installation | create `@overlay-25.12.2`, `@docker`, `@swap`, `@data` | `a` and `b` both point at it, `committed=a` |
| Update slot B to 25.12.3 | `snapshot @overlay-25.12.2 -> @overlay-25.12.3`, write p3 | `pending=b`, `b.upper` updated |
| B boots healthy | — | `committed=b`, clear pending, reclaim |
| Update slot A to 25.12.4 | `snapshot @overlay-25.12.3 -> @overlay-25.12.4`, write p2 | `pending=a`, `a.upper` updated |
| A boots healthy | delete `@overlay-25.12.2` | `committed=a`, clear pending |
| Rollback | — | switch `committed` to the other slot |

The snapshot source is always the live layer. Run `sync` and stop writers first; consistency is
crash-consistent, not application-consistent.

## Health check

Runs after `done` completes, with a 150 second timeout:

| Probe | Passes when |
|---|---|
| `overlay-writable` | the composed root `/` is writable with at least 16 MiB free (an absolute floor, not a percentage: the same rule has to mean the same thing on a 128 MiB test image and on a disk measured in hundreds of GiB) |
| `fw4-present` | the nft ruleset is non-empty and the `inet fw4` table is present |
| `wan-present` | a device referenced by `network.wan` exists |

All probes must pass before commit. Any failure abandons the pending slot and reboots into the
committed slot. The writable layer is the root itself, so there is no separate `/overlay` mount
to measure. Every probe runs, even after one has failed: the log has to name all three in one
boot, otherwise a slot with two faults costs two boots to explain itself.

`fw4-present` does not look for a daemon: in ImmortalWrt 25.12 `fw4` is a one-shot renderer that
loads the ruleset and exits, so the observable state is the ruleset itself. `wan-present` needs
a network configuration to name a device; a seed that fails only logs
`stage=net-seed result=fail` and lets the boot continue. A configuration that already exists is
left untouched, which is also how a test supplies its own.

Before any probe runs, `/proc/cmdline`, `/proc/mounts` and `/sys/class/net` are read. A slot
that comes up without `/proc` fails all three probes for one reason, so that reason gets its own
line (`stage=preflight … reason=proc-cmdline-unreadable`) instead of three anonymous failures.

## Reclamation

The reference set is `slots.a.upper` ∪ `slots.b.upper` plus the pending slot's layer. Any
`@overlay-*` outside that set is deleted, oldest `generation` first.

Four safety rules:

1. never delete a layer that is currently mounted (check `/proc/mounts`)
2. never delete the layer referenced by the pending slot
3. run `btrfs subvolume delete -C` followed by `btrfs subvolume sync`; deletion alone does not
   free space immediately
4. never run a full balance under disk pressure; balance itself needs free space

Triggers: after a successful commit, early in each boot, after a failed update, and on demand
through `ab-slot gc`.

| Free space | Action |
|---|---|
| above 15% | normal |
| below 15% | warn and reclaim automatically |
| below 5% | `platform_check_image` returns 74 and the update is refused |

No qgroup quota is used; exclusive space is measured on demand with `btrfs filesystem du -s`.

## Logging

Directory `/boot/ab/log/`, total budget about 350 KiB.

| File | Contents | Rotation |
|---|---|---|
| `boot-0.log` | current boot | rotated on each boot |
| `boot-1.log` | previous boot | — |
| `boot-2.log` | boot before that | removed when exceeded |
| `upgrade.log` | an update's own output, if the run was saved into it; `ab-upgrade` writes nothing there itself | the next saved update overwrites it |
| `conflicts.log` | most recent conflict report | overwritten by the next update |

- 32 KiB per file; overflow is truncated with a `TRUNCATED=1` marker
- the boot hook makes at most 8 writes per boot, each a full-file write: temp, `sync`, rename;
  the health check appends its own probe lines afterwards
- the state lock is a directory on the ESP carrying `<boot_id> <pid> <started_at>`; a lock
  whose boot or process is gone is taken over (logged as
  `stage=lock action=stale-lock-taken`), so a power cut cannot leave the machine unable to
  commit
- write points: `initramfs-enter`, `lower-mounted`, `overlay-mounted`, `switch-root`,
  `slot-cfg`, `grow`, `resize`, `healthcheck-done`, `commit` or `abandon`, `done`

Record fields are frozen as `key=value`:

```
stage=<stage> slot=<a|b> upper=<layer> rootfs=<version> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail> [reason=<token>]
stage=preflight slot=<a|b> result=fail reason=<proc-cmdline-unreadable|proc-mounts-unreadable|sysfs-missing>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed|slot-cfg-not-written|btrfs-resize>
action=<commit|reboot-to-committed|degraded-boot>
next=<a|b>
```

Commands: `ab-slot status`, `ab-slot log [--prev|--upgrade]`, `ab-slot conflicts`,
`ab-slot gc [--dry-run]`, `ab-slot rollback`, `ab-slot next [--write]`.

## Conflicts and disposition

An update replaces the whole `@sys` tree, while the writable layer may contain files the user
modified. The overlap is computed three ways:

| Symbol | Meaning |
|---|---|
| `A` | file in the old slot's `@sys` (baseline) |
| `B` | file in the new slot's `@sys` (new default) |
| `U` | same path in the writable layer (user version) |

```
UpstreamChanged = { f : A[f] != B[f] }
UserChanged     = { f : U exists and U[f] != A[f] }
Conflicts       = UpstreamChanged ∩ UserChanged
```

- comparison uses content hashes, never mtime or size
- the baseline comes from the real old `@sys` content, not from a version number
- whiteout entries (`0:0` character devices) and directory `opaque` markers must be recognised,
  otherwise "the user deleted this file" disappears from the report

| Case | Action |
|---|---|
| `U` absent, `B` changed | take `B` |
| `U` present, `B` unchanged | keep `U` |
| `U` present, `B` also changed | keep `U` and record a conflict |
| `U` present, `B` deleted | flag as high risk and require manual review |

Conflicts never block the update and never block boot. Files under `/etc/config/*` are never
merged line by line: uci has its own grammar and a textual merge produces configurations that
cannot be loaded. New upstream defaults are introduced through idempotent `/etc/uci-defaults/`
scripts that only fill missing options and delete themselves after running, so file-level
conflict detection covers non-uci user files only.

## Payload contract

| Member | Source | Measured size |
|---|---|---|
| `rootfs.tar.gz` | official mirror | 10 587 455 B (10.1 MiB) |
| `kernel.bin` | official mirror | 7 709 696 B (7.35 MiB) |
| `initramfs.cpio.gz` | this project | 3 056 055 B (2.9 MiB) |
| `platform.tar` | this project | 1 484 800 B (1.42 MiB) |
| `boot.tar` | this project | 655 360 B (640 KiB) |
| `manifest.json` | this project | 1 396 B (1.4 KiB) |

The six members add up to 23 494 762 B; the payload tar that carries them is 23 500 800 B
(22.41 MiB), the difference being tar's block padding. An update payload is therefore just over
20 MiB, and the full disk image is used for first installation only. Those sizes are measured,
not estimated: they are the members of the published `v0.0.8` payload, and
`tar -tvf n5105-ab-<upstream>-upgrade.tar` on your own copy prints the same list. Sizes change
from release to release, the shape does not.

`manifest.json` records size and sha256 for every member, together with `format`, the `rootfs`
version, the `platform` version and the `kernel` package id.

### The bootloader member

`boot.tar` lets an update bring its own bootloader forward. It carries two files:

| Path in `boot.tar` | What it is |
|---|---|
| `EFI/BOOT/BOOTX64.EFI` | the upstream standalone GRUB EFI binary, byte identical to the one the ESP gets |
| `boot/grub/grub.cfg` | this project's slot menu, rendered from `scripts/ci/grub.cfg.in` by `scripts/ci/grub-render.sh` |

The manifest describes those bytes in a `bootloader` block: `member`, `loader`, `menu`,
`loader_bytes` (the ESP headroom rule is `loader_bytes / 1024 + 4096` KiB free), `loader_sha256`
and `menu_sha256` (the digests the device compares before and after the write), `grub_version`
(readable evidence beside the digest, never the decision), and `source_image` / `source_sha256`
(provenance). A build with no boot source produces no `boot.tar` and writes
`"bootloader": null`; that is a legal payload, and `ab-upgrade` says
`bootloader absent-in-payload` instead of installing silently. `CI_REQUIRE_BOOTLOADER=1` turns a
missing boot source into a build failure.

The member is defined once, in `scripts/ci/boot-member.sh`, sourced by both
`scripts/ci/payload-build.sh` and `scripts/ci/assemble.sh`, so the test payload and the
published payload cannot disagree.

Check a payload's identity without a device:

```sh
mkdir -p /tmp/payload
tar -xf n5105-ab-<upstream>-upgrade.tar -C /tmp/payload boot.tar manifest.json
tar -xf /tmp/payload/boot.tar -C /tmp/payload
bash scripts/ci/grub-render.sh --check-loader /tmp/payload/EFI/BOOT/BOOTX64.EFI /tmp/payload/manifest.json
```

### Validation order

Any failure aborts the update:

1. `manifest.json` parses and `format` matches
2. every member exists and its sha256 matches the manifest
3. the vermagic of `btrfs.ko` inside `initramfs.cpio.gz` matches `kernel.bin`
4. p4 has at least 5% free space
5. the conflict report has been produced

On failure `platform_check_image` returns 74, so even `sysupgrade -F` refuses to write.

### Build inputs and adapter

The pipeline does not compile a kernel; it consumes official artifacts:
`immortalwrt-<ver>-x86-64-rootfs.tar.gz`, `immortalwrt-<ver>-x86-64-generic-kernel.bin`, and
`kmods/<kernel-ver>-<hash>/kmod-fs-btrfs.apk` with its dependencies. Preflight: the hash in the
kmods directory name must equal the hash embedded in the `kernel` package version.

| Adapter | Behaviour |
|---|---|
| `upstream` | download official rootfs and kernel (default) |
| `selfbuild` | use locally built rootfs and kernel (seam kept, not implemented) |

Switching adapters does not change the assembly layer or the initramfs.

### Why btrfs arrives as a module

`config.buildinfo` for 25.12.2 contains no `CONFIG_KERNEL_BTRFS_FS`, and the default image
manifest lists 227 packages with no btrfs. btrfs can therefore only be provided by
`kmod-fs-btrfs` loaded from the initramfs. This is the premise of the upstream-consumption
route.

## Limits

- Rollback depth is one layer: an update overwrites the target slot's rootfs, so older rootfs
  images no longer exist on disk.
- Growth never shrinks p4. A disk smaller than the image leaves the table describing space that
  does not exist, and the growth refuses with `fail:p4-beyond-disk`.
- A degraded boot keeps `upperdir` in tmpfs: the system runs but does not persist writes.
  `ab-slot status` reports `boot=degraded`, and `ab-upgrade` refuses with
  `writable-layer-degraded`.
- The payload format is not signed. `UPDATE_VERIFY` has room for a signature mode and nothing
  implements one; the digest is only as trustworthy as the HTTPS connection it arrived over.
