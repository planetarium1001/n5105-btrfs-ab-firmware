# N5105 Btrfs A/B Firmware

ImmortalWrt-based firmware image for the N5105 v5 board, with A/B dual-root updates on btrfs.

**English** | [简体中文](README.zh-CN.md)

This project covers the system layer only: the A/B boot slots and the btrfs layout.
Application-level packaging and configuration are out of scope.

## Scope

| Item | Value |
|---|---|
| Target hardware | N5105 v5, x86-64, UEFI, 4× Intel i226-V |
| Base system | ImmortalWrt, rootfs kept byte-identical to upstream |
| Project-owned content | Build layer, boot layer, and the `@wf` platform layer only |
| Boot | UEFI only; no legacy/BIOS support, no multi-board support |

## Disk layout

| Partition | Size | Filesystem | Contents |
|---|---|---|---|
| p1 | 128 MiB | vfat | GRUB, slot state, boot logs |
| p2 | 128 MiB | btrfs | Slot A: `@sys` + `@wf` |
| p3 | 128 MiB | btrfs | Slot B: `@sys` + `@wf` |
| p4 | rest of disk | btrfs | `@overlay.genNNNN`, `@docker`, `@swap`, `@data` |

- `@sys` — upstream rootfs, read-only
- `@wf` — platform tooling, versioned with the slot, read-only
- `@overlay.genNNNN` — all writable state, shared by both slots

## Boot chain

1. GRUB reads slot state from p1 and selects kernel and initrd.
2. The initramfs mounts the p4 writable layer, then the read-only slot layers.
3. overlayfs composes the root: `lowerdir=@wf:@sys`, `upperdir=@overlay.genN/upper`.
4. `switch_root` enters the system.

## Update and rollback

- Updates write to the inactive slot; the running system is never modified.
- The writable layer advances by generation: snapshot the live generation, never rename.
- A single failed boot attempt rolls back to the committed slot.
- A new slot is committed only after health checks pass.
- Rollback depth is one generation.

## Build

- CI consumes `rootfs.tar.gz`, `kernel.bin`, and kernel modules from the official mirror,
  then assembles the initramfs and the disk image.
- No kernel compilation; the update payload is about 20 MiB.
- Artifacts: a disk image for first installation and a payload for routine updates.

## Repository policy

- Only source code and documentation are published.
- Workflow configuration, agent instructions, knowledge base, and task records stay local.

## Documentation

- [docs/](docs/README.md) — design documents

## Status

Design stage. Partition geometry, boot chain, and update transaction are finalized.
Implementation proceeds through stages S0–S6.

## License

- Build tooling and project-owned code: [MIT](LICENSES/MIT.txt)
- Files derived from upstream OpenWrt: [GPL-2.0-only](LICENSES/GPL-2.0-only.txt)
