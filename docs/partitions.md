# Partitions and Filesystems

**English** | [简体中文](partitions.zh-CN.md)

## Overview

Single disk, GPT, UEFI only. The layout provides two independent system slots and one
shared partition for all writable state.

## Layout

| Partition | PARTLABEL | Size | Filesystem | Contents |
|---|---|---|---|---|
| p1 | `wf-esp` | 128 MiB | vfat | GRUB, `grubenv`, `vmlinuz-a/b`, `initrd-a/b`, `ab/` state, `ab/log/` |
| p2 | `wf-slot-a` | 128 MiB | btrfs | `@sys`, `@wf` |
| p3 | `wf-slot-b` | 128 MiB | btrfs | `@sys`, `@wf` |
| p4 | `wf-shared` | rest of disk | btrfs | `@overlay.genNNNN`, `@docker`, `@swap`, `@data` |

There is no p128 (EF02) and no legacy boot path.

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
| `grubenv`, slot state, logs | under 1 MiB |
| Peak total | about 27 MiB |

Headroom is about 4×. The build asserts that p1 content stays under 64 MiB and fails otherwise.

**p2 = p3 = 128 MiB**

- 4.7× the extracted rootfs, 12× the `zstd:6` size
- Power-of-two aligned, so ratios are easy to audit
- Read-only at runtime; written only during updates

**p4 = rest of disk**

The image ships 64 MiB. First boot grows it to the end of the disk and runs
`btrfs filesystem resize max`.

## Filesystem parameters

| Partition | `mkfs` arguments | Rationale |
|---|---|---|
| p2 / p3 | `mkfs.btrfs -m dup -d single` | Metadata is 4–8 MiB; duplication recovers silent corruption inside a slot |
| p4 | `mkfs.btrfs -m single -d single` | Container layers inflate metadata; duplication is not worth the cost |

## Mount options

| Mount point | Options |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@wf` | `ro,noatime` |
| `@overlay.genN` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime,compress=zstd:3` |

`compress=` is fixed by the first mount of the filesystem, so p4 is mounted before the
read-only slot layers.

## Subvolumes

- p2 / p3: `@sys`, `@wf`
- p4: `@overlay.genNNNN` (containing plain directories `upper/` and `work/`), `@docker`, `@swap`, `@data`

All subvolumes are top-level. No second-level or nested subvolumes exist.
`@docker` and `@swap` must stay independent: snapshots do not recurse into nested
subvolumes, and an active swapfile prevents snapshotting.

## First-boot growth

1. `sfdisk` reads the partition table.
2. The whole table is written back with the p4 end moved to the end of the disk.
3. `partx -u` re-reads it.
4. `btrfs filesystem resize max` grows p4.

The outcome is recorded in the p1 log as `done`, `already-full`, `missing-sfdisk`, or `fail`.

## Assertions

- p1 content peak under 64 MiB
- p2 / p3 usage under 50%
- every entry in `btrfs subvolume list` shares the same top level
- `mkfs` arguments match the table above exactly
