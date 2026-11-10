# Partitions and Filesystems

**English** | [简体中文](partitions.zh-CN.md)

## Overview

Single disk, GPT, UEFI only. The layout provides two independent system slots and one
shared partition for all writable state.

## Layout

| Partition | GPT PARTNAME | Filesystem LABEL | Size | Filesystem | Contents |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB, boot menu, `vmlinuz-a/b`, `initrd-a/b`, `ab/` state, `ab/log/`, `ab/device.json` |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | `@sys`, `@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | `@sys`, `@platform` |
| p4 | `ab-data` | `data` | 128 MiB | btrfs | `@overlay-<version>`, `@docker`, `@swap`, `@data` |

There is no p128 (EF02) and no legacy boot path.

## Naming

Every partition carries two names, and the two are not interchangeable:

| Set | Values | What depends on it |
|---|---|---|
| GPT PARTNAME | `ab-esp`, `ab-slot-a`, `ab-slot-b`, `ab-data` | the boot code, which matches it against `/sys/class/block/*/uevent` |
| Filesystem LABEL | `ESP`, `slot-a`, `slot-b`, `data` | humans, and the `blkid` / `lsblk` assertions in the image stages |

PARTNAME keeps the `ab-` prefix. Discovery walks every block device on the machine, so
a bare `data` or `esp` would eventually match an unrelated disk and mount the wrong
partition. Four code paths resolve these names — `initramfs/boot/init`,
`/etc/init.d/ab-boot`, `/etc/init.d/ab-commit` and `lib/upgrade/platform.sh` — and each
falls back to the 1/2/3/4 order when no PARTNAME matches, so a missed rename would hide
behind the fallback instead of failing at boot.

LABEL carries no version. The version already has three authoritative homes:
`@overlay-<version>`, `/etc/platform-release` and `ab/state.json`. Relabelling a
filesystem on every release would add a superblock write that power loss can interrupt,
and a half-written label reads back as a different partition.

The p4 name `ab-shared` is retired: the partition holds the writable overlay, `@data`,
`@docker` and `@swap`, which is more than shared state.

p1 holds data only, never executable scripts: FAT32 has no permission bits or symlinks,
no journal, and scripts stored on the ESP do not roll back together with a slot.

## Sizing

Measured baseline, ImmortalWrt 25.12.2 on x86-64:

| Item | Value |
|---|---|
| `rootfs.tar.gz` | 10.1 MiB |
| Extracted rootfs | 26.9 MiB, 1078 files |
| 4K block usage | 31 MiB |
| After `zstd:6` | 10.3 MiB |
| `generic-kernel.bin` | 7.35 MiB |

**p1 = 128 MiB**

| Item | Estimate |
|---|---|
| `BOOTX64.EFI` and GRUB modules | 3–6 MiB |
| `vmlinuz-a/b` (about 7.4 MiB each) | 15 MiB |
| `initrd-a/b` (2–3 MiB each) | 4–6 MiB |
| `ab-slot.cfg`, slot state, logs | under 1 MiB |
| Peak total | about 27 MiB |

Headroom is about 4×. The build asserts that p1 content stays under 64 MiB and fails otherwise.

**p2 = p3 = 128 MiB**

- 4.7× the extracted rootfs, 12× the `zstd:6` size
- Power-of-two aligned, so ratios are easy to audit
- Read-only at runtime; written only during updates

**p4 = 128 MiB in the image, rest of disk after first boot**

The image is 514 MiB: 1 MiB of alignment, four 128 MiB partitions and 1 MiB of tail for
the backup GPT. p4 ships 128 MiB and first boot grows it to the end of the disk, then runs
`btrfs filesystem resize max`.

128 MiB is the floor that keeps the writable layer usable: the update fixture pushes a
20 MiB payload into `upper`, which at 64 MiB left the filesystem at `used 63/64 MiB` and
overlayfs could not create its `work/` directory.

## Filesystem parameters

| Partition | `mkfs` arguments | Rationale |
|---|---|---|
| p1 | `mkfs.vfat -F 32 -n ESP` | the FAT32 label field is 11 characters wide; `ESP` fits and says what the partition is |
| p2 / p3 | `mkfs.btrfs -m dup -d single -L slot-a` (`-L slot-b` for p3) | Metadata is 4–8 MiB; duplication recovers silent corruption inside a slot |
| p4 | `mkfs.btrfs -m single -d single -L data` | Container layers inflate metadata; duplication is not worth the cost |

## Mount options

| Mount point | Options |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@platform` | `ro,noatime` |
| `@overlay-<version>` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime` |

`compress=` is fixed by the first mount of the filesystem, so p4 is mounted before the
read-only slot layers. One btrfs carries one level: p4 mounts `zstd:6` and every
subvolume on it inherits that level, so `@data` names no level of its own. `@docker` and
`@swap` are `nodatacow` and stay uncompressed regardless.

## Subvolumes

- p2 / p3: `@sys`, `@platform`
- p4: `@overlay-<version>` (containing plain directories `upper/` and `work/`), `@docker`, `@swap`, `@data`

All subvolumes are top-level. No second-level or nested subvolumes exist.
`@docker` and `@swap` must stay independent: snapshots do not recurse into nested
subvolumes, and an active swapfile prevents snapshotting.

## First-boot growth

1. `sfdisk` reads the partition table.
2. The whole table is written back with the p4 end moved to the end of the disk.
3. `partx -u` re-reads it.
4. `btrfs filesystem resize max` grows p4.

The new p4 size is rounded **down** to a multiple of the filesystem sectorsize (4096 bytes,
8 sectors): btrfs answers `Invalid argument` for a device whose size is not a multiple of
it, and one sector of lost tail costs nothing while an unaligned size costs the whole
growth. If rounding leaves no gain, the state is `already-full` and the table is not
written.

The outcome is recorded in the p1 log as `done`, `already-full`, `missing-sfdisk`, or `fail`.

## Assertions

- GPT PARTNAME and filesystem LABEL both match the layout table, read back from the image
- p1 carries `boot/grub/ab-slot.cfg` with one `set default=` and one `set fallback=` line,
  default on the committed slot, and no `load_env`/`save_env` call: the shipped GRUB has
  no environment block to load or save
- p1 carries `ab/device.json` with the GPT disk GUID, four distinct PARTUUIDs that
  match the partition table and the labels the filesystems actually hold
- p1 content peak under 64 MiB
- p2 / p3 usage under 50%
- every entry in `btrfs subvolume list` shares the same top level
- `mkfs` arguments match the table above exactly
