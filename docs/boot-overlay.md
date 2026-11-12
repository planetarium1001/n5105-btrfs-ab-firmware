# Boot Chain and Layered Root

**English** | [简体中文](boot-overlay.zh-CN.md)

## Overview

The running root is an overlayfs composition of two read-only layers from the active slot
and one writable layer on the data partition. Before that composition is built, the
initramfs grows p4 to the end of the disk - in two boots, see
[First-boot growth of p4](#first-boot-growth-of-p4) - and mounts the three user-data
subvolumes, so the first process of the composed root already sees the final geometry and
its data directories.

## Boot sequence

1. GRUB reads slot state and `ab-slot.cfg` from p1, then selects a kernel and initrd.
2. The initramfs resolves which disk carries the four partitions, then locates p1 to p4
   on it and decides whether p4 has to grow. If it does, this boot rewrites the partition
   table, records that, and reboots; the next boot finds the table already at the end of
   the disk.
3. The initramfs resizes the filesystem on a clean mount of p4, then mounts the p4
   writable layer, the read-only slot layers and the p4 user-data subvolumes.
4. overlayfs composes the root.
5. `switch_root` enters the system; p1 is mounted at `/boot`.

The CI guest assertion is not part of that chain. `/s3-post.sh` re-checks the composed
root, writes probe files into the writable layer and prints the frozen `S3-RESULT` line;
it is a test artefact, so it is injected into an initramfs only when the build sets
`AB_CI_HOOKS=1`. Without the flag the archives carry no such member, and the boot init
hands over to `/sbin/init` instead of to a probe: a flashed machine must not run CI
bookkeeping as PID 1, where a probe write ends up in the user's writable layer and a
failure branch powers the machine off. The S3 stage still asserts: it builds a second
initramfs with the flag for its two kernel boots, while the image it publishes is
assembled from the archive without it. `scripts/ci/image-verify.sh` reads the member
table of both initrds back (`cpio -t`, no `s3-` entry) and compares it with the kind
`ab/image.json` records, so the rule is enforced by the build rather than by review.

## Device identity

Nothing on the boot path may assume `/dev/vda`: that name only exists on virtio, while
the target board presents `/dev/sda`, `/dev/nvme0n1` or `/dev/mmcblk0`. The single
implementation of "which disk is ours" is `platform/lib/disk-identity.sh`, shipped both in
the boot initramfs and in the platform layer as the same bytes.

Resolution order, first answer wins, and a level is only used when it has evidence:

| Level | Evidence | Notes |
|---|---|---|
| 1 | `ab.disk=` then `wf.dev=` on the kernel command line | tests and QEMU; accepted only when that disk carries `ab-esp` |
| 2 | PARTUUID from `ab/device.json` on the ESP | written at build time; survives `dd` to another disk |
| 3 | PARTNAME | the `ab-*` GPT names, scanned through `/sys/class/block/*/uevent` |
| 4 | mount reverse lookup | `/boot`, `/mnt/p4` and `/data` in the running system; the ESP the initramfs already mounted |
| 5 | unique candidate | the only non-removable disk whose partitions carry the four filesystem LABELs |

- The parent disk is always derived from sysfs: `/sys/class/block/<part>/partition` says
  the node is a partition, and `DEVNAME` one directory up is the disk. No code trims a
  `p` off a name or appends a digit to one.
- A disk counts only when sysfs reports `DEVTYPE=disk` and `removable=0`, so a USB stick
  or a loop device is never written to.
- The four partitions must resolve to the same disk. A set split over two disks is
  `partitions-split`; a set that exists twice is `ambiguous-disk`. Both leave the
  partition table untouched and both keep the boot going.
- The result is logged as `stage=device disk=<dev> method=<cmdline|partuuid|partname|mount|unique>`
  and `ab-slot status` reports the same `disk=` and `method=` from the shared resolver.
- The initramfs resolves before the ESP is mounted, so level 2 answers there only when
  `ab/device.json` is already readable; `ab-boot` runs the whole ladder again with `/boot`
  mounted. A boot whose disk cannot be identified reports the reason and continues
  without growing or mounting p4 instead of powering off.

## First-boot growth of p4

p4 ships with 128 MiB and the tail of the disk stays unallocated, so the same image fits any
disk size. Growing it takes **two boots**, and that is a design decision rather than an
accident of the code:

1. **the boot that writes the table** decides whether p4 is short of the last usable LBA,
   rewrites the GPT with `sfdisk --no-reread`, records `result=table-written`, and then
   reboots. It never resizes the filesystem;
2. **the boot after it** finds the table already at the end of the disk, so the only step
   left is `btrfs filesystem resize max`, and it records `result=done`;
3. **every boot after that** records `result=already-full`, which is the steady state.

**A first boot therefore reboots once by itself, and GRUB will be seen twice.** That is the
design working, not a failure: the first boot can only finish the partition table, and the
second one finishes the filesystem. Every boot after that is a normal boot.

Why two boots: the step that used to run here was `blockdev --rereadpt` (or `partx -u`)
straight after the table write, on the very disk the boot was still using - and a real
machine panicked inside that window on its first flash, leaving nothing on disk to explain
it. Nothing in the boot path asks the kernel to re-read a partition table any more: **the
reboot is the re-read**, because the next boot's kernel parses the GPT at device probe time
with nothing mounted. The same window is why the reboot is *controlled* (`reboot -f` after
the root subvolume is given back and the writes are flushed): a panic there leaves no
evidence at all, while a reboot leaves the record of the stage that finished.

The initramfs half, in the order it happens:

1. `sfdisk -d` dumps the partition table; the dump is kept as the pre-change copy.
2. The decision compares the end of p4 with the last usable LBA (`last-lba`). Equal means
   `already-full` and nothing is written; short means the new size is
   `last usable LBA - p4 start + 1`, which can only ever be larger than the current one.
   The new size is rounded down to a multiple of the filesystem sectorsize (4096 bytes,
   8 sectors) first: btrfs refuses to grow onto a device whose size is not a multiple of
   it, so `last usable LBA - p4 start + 1` is only the upper bound. If rounding leaves no
   gain the state is `already-full`.
3. **Before the table is touched**, the p4 root subvolume is mounted at its old geometry and
   two things are written next to the growth record: `.ab/partitions.before` and
   `result=table-write-pending`. The mount is given back immediately. This is the write-ahead
   breadcrumb: a boot that dies while the table is being written still leaves, on the disk,
   the fact that a write was in flight and what the geometry was. If that mount cannot be
   given back the table is not written at all and the record says `fail:p4-still-mounted`:
   writing a table under a mounted filesystem is the other half of the incident.
4. Only the `size=` field of the p4 line changes in a copy of the dump. `sfdisk --no-reread`
   writes that copy back, which relocates the backup GPT to the new end of the disk as part
   of the same write. Every other line, including the table UUID and the other three
   partitions, is written back unchanged.
5. The table is read back and compared, and `sfdisk --verify` checks primary and backup GPT:
   a write that did not land is `fail:table-write-not-verified`, a table that does not
   verify is `fail:table-verify`, and neither reboots. An `sfdisk` without `--verify` is
   recorded as `verify=unsupported` and the growth continues.
6. The root subvolume is mounted again, `result=table-written` is recorded (the buffered
   `grow.log` is appended to `.ab/grow.log` first), the mount is given back, the writes are
   flushed, and the machine reboots.
7. On the next boot the resize runs on a clean mount of p4 - no `compress=`, no `discard=`,
   no `subvol=` - and records `result=done`.

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

A record written by the one-phase firmware is still read correctly: `done` and
`already-full` keep their meaning, and a retired `fail:` token such as
`partition-table-reread` reads as "not proven". A machine that was already grown therefore
reports `already-full` on its first boot with this firmware.

**`ab-boot` at run time, authoritative**: it reads `<p4>/.ab/grow`, retries
`btrfs filesystem resize max /mnt/p4` when the initramfs could not do it (p4 mounted
exactly once, btrfs-progs from the platform layer), and records
`stage=resize result=<ok|fail:<token>> source=ab-boot` in the p1 ring log. A machine
whose initramfs resize failed still reaches the end of the disk on that same boot.

Where the evidence of a boot that died ends up: `ab-boot` writes this boot's ring log to
`ab/log/boot-0.log`, and its first act on the next boot is to rotate that file to
`boot-1.log`. A boot that never reached `ab-boot` - and the boot that writes the table is
exactly that, by design - leaves its evidence in `.ab/grow`, in the append-only
`.ab/grow.log`, and in `ab/log/boot-1.log` after the following power-on; read
`ab-slot log --prev` (or `ab/log/boot-1.log`) for a post-mortem, and `boot-0.log` only for
the boot that is running now.

The table from before the write is kept at `<p4 root subvolume>/.ab/partitions.before`
before the write, because a copy that only lived in the initramfs dies with it.

The record lives on the p4 root subvolume, not inside a generation layer, so it outlives
`@overlay-<version>` and is readable after the root switch: `ab-boot` mounts that
subvolume at `/mnt/p4` and appends the line to the p1 boot log. The file is written
through a temporary file and a rename, a missing file means "not recorded" and is never
an error for the reader, and an image ships without one.

Growth only ever enlarges p4 and is idempotent, because the decision depends on nothing
but the table on the disk: a second boot on the same disk reads `already-full` and does
not touch the table. The one thing the record decides is the loop guard: a `table-written`
record for exactly the disk end this boot wants to write, while the table on disk still
reads shorter, means the write was lost below the filesystem - that boot records
`fail:table-write-lost` instead of writing and rebooting again, so a lost write cannot
become a reboot loop. `sfdisk`, `blockdev` and `btrfs` belong to the `boot` toolset of the
initramfs (`scripts/ci/initramfs-tools.lock.json`), so they are always present and always
the same bytes as the rest of the release; if the toolset ever lost them the build would
fail, and the boot-time `missing-sfdisk` / `fail:btrfs-resize` states remain as the
runtime diagnosis of a damaged table rather than of a missing tool.

## Layer responsibilities

| Layer | Subvolume | Mode | Contents | Written by |
|---|---|---|---|---|
| Upstream system | `@sys` | ro | Upstream rootfs, byte-identical | updates only |
| Platform | `@platform` | ro | `ab-slot`, init.d hooks, recovery tooling | updates only |
| User state | `@overlay-<version>` | rw | Configuration, installed packages, user files | runtime |

`@platform` is versioned with the slot: it is written during an update and rolls back with the slot.

## Mount composition

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

## Mount order

1. Mount `@overlay-<version>` from p4 with `rw,compress=zstd:6,discard=async`
2. Run `btrfs filesystem resize max` on that mount point
3. Mount `@platform` with `ro`
4. Mount `@sys` with `ro`
5. Compose the overlay at `/newroot`
6. Mount `@data`, `@docker` and `@swap` under `/newroot`
7. Assert that the `/proc/mounts` entry of the p4 mount contains `compress=`

p4 is mounted first because `compress=` is only applied by the first mount of a filesystem;
mounting a read-only layer first leaves the parameter out of the kernel.

## p4 data subvolumes

The three user-data subvolumes are mounted by the initramfs itself, after the overlay is
composed and through it, so they are present before the first process of the composed root
starts. Their mount points are created under `/newroot` with `mkdir -p` and become
`/data`, `/opt/docker` and `/swap` after `switch_root`.

| Subvolume | Mount point | Options | Why |
|---|---|---|---|
| `@data` | `/data` | `rw,noatime` | user data; compression follows the filesystem |
| `@docker` | `/opt/docker` | `rw,noatime,nodatacow,nodatasum` | matches the upstream dockerd package, `option data_root '/opt/docker/'` |
| `@swap` | `/swap` | `rw,noatime,nodatacow,nodatasum` | swapfiles must not be COW or compressed |

`compress=` is a filesystem-level option: one btrfs has exactly one level, and p4 uses
`zstd:6`. Only the `@overlay` mount carries it; the three child mounts repeat no
compression option at all, and no layer claims a level of its own (the old `zstd:3` claim
for `@data` was wrong). `nodatacow` and `nodatasum` only restate the `chattr +C` the build
applied, so a mount that loses them cannot quietly start COW on a swapfile.

Mounting `@docker` at `/opt/docker` and `@swap` at `/swap` cannot fail a boot: a failed
mount is reported as `p4-partial`, the log line lists which subvolumes are missing, and
the boot continues. `ab-slot status` shows the three marks next to `p4=`.

## How the platform layer takes effect

`@platform` mirrors final filesystem paths:

- `/usr/sbin/ab-slot`, `/usr/sbin/ab-upgrade`
- `/etc/init.d/ab-boot`, `/etc/init.d/ab-commit`
- `/lib/ab-slot-cfg.sh` (the GRUB slot-file writer), `/lib/ab-partitions.sh` (partition lookup)
- `/usr/sbin/btrfs` and the runtime library closure
- `/etc/uci-defaults/`

Because overlayfs merges directories, procd reads `/etc/init.d/*` from the merged view and
the hooks run normally while `@sys` stays untouched.

## Slot selection: who writes the boot hint

`boot/grub/grub.cfg` is rendered once at build time, and no boot, commit or rollback rewrites
it, because a truncated FAT write of a whole menu is a machine that does not boot, while a
damaged hint only costs one boot. The one other writer is an upgrade, and it replaces the
whole file rather than editing it: the payload's `boot.tar` carries a freshly rendered menu,
`ab-upgrade` puts it in place through `<file>.new` + rename, and the menu it replaced stays
behind as `grub.cfg.prev`. The reason above still holds, because nothing ever writes half a
menu into the file that boots the machine.

- the truth is `ab/state.json` on the ESP; `committed` and `pending` change only through
  the atomic rename in `ab-slot`
- the hint is `boot/grub/ab-slot.cfg`, two GRUB commands: **first**
  `set fallback=<committed>`, **then** `set default=<pending slot, or the committed one>`
- its only writers are the four `ab-slot` state commands (`pending`, `commit`, `abandon`,
  `rollback`) and `ab-boot`, which heals it from `ab/state.json` on every boot; both write
  a temporary file in the same directory and rename it, so a reader never sees half a file
- GRUB only reads it: the menu entries are defined first and are followed by
  `if [ -f /boot/grub/ab-slot.cfg ]; then source /boot/grub/ab-slot.cfg; fi`
- because `fallback` is written first, a truncated file leaves `fallback` on the
  committed slot and `default` at the build-time value: the machine boots the committed
  slot, and `fallback` can never end up pointing at the slot being tried
- `source` comes after the menu entries on purpose: an unknown command or a syntax error
  would otherwise abort the whole configuration and drop to the GRUB prompt
- the upstream GRUB in the ESP is a standalone EFI binary without the `env` module, so an
  environment block is not an option; a sourced two-line file needs no module at all
- a pending slot that fails inside the initramfs is abandoned before the machine powers
  off: `wf_fail` remounts the ESP read-write, calls the same writer `ab-slot abandon`
  uses (`ab_slot_cfg_write_committed`), and only then prints the judge line, so a harness
  that stops the machine on that line cannot cut the write in half. If nothing is
  pending, nothing is written

The rendered configuration must satisfy all of the following, otherwise the build fails:

- contains `set default=` and `set fallback=`, both naming the committed slot (the runtime
  file moves `default` to the pending slot; `fallback` stays on the committed one)
- defines the three menu entries before the `source` line
- sources `ab-slot.cfg` only when the file exists
- uses no `&&`, `||`, or `${x:-y}` expansions
- contains no unreplaced template tokens

## Failure handling and degraded boot

| Failure | Behaviour |
|---|---|
| Kernel or initrd fails to load | GRUB retries inline, then `set fallback` returns to the committed slot |
| initramfs stage fails | Before printing the judge line, a pending slot is abandoned on the ESP (fail-safe abandon); the machine then powers off and the next boot takes the committed slot |
| Health check fails | Abandon the pending slot and return to the committed slot |
| p4 growth fails | Record `fail:<token>` in `.ab/grow`; `ab-boot` retries the filesystem resize at run time |
| the initramfs resize fails but the table grew | Boot continues on the grown partition; `ab-boot` sizes the filesystem up (`stage=resize result=ok source=ab-boot`) |
| The boot disk cannot be identified | Record `fail:no-disk`, `fail:ambiguous-disk` or `fail:partitions-split`, never write a table, and continue |
| `sfdisk` missing from the initramfs | Record `missing-sfdisk`, boot unchanged |
| A user-data subvolume fails to mount | Report `p4-partial` and continue; the mount point stays empty |
| p4 fails to mount | Retry, then try `recovery` read-only, then boot degraded with a tmpfs upper |

A degraded boot keeps `upperdir` in tmpfs: the system runs but does not persist writes.
`ab-slot status` remains available because `@platform` lives on p2/p3, not on p4.
