# Conflict Detection and Payload Contract

**English** | [简体中文](conflicts-payload.zh-CN.md)

## Overview

An update replaces the whole `@sys` tree, while the writable layer may contain files the
user modified. This document defines how those overlaps are detected and how the update
payload is validated.

## Three-way comparison

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

## Disposition

| Case | Action |
|---|---|
| `U` absent, `B` changed | take `B` |
| `U` present, `B` unchanged | keep `U` |
| `U` present, `B` also changed | keep `U` and record a conflict |
| `U` present, `B` deleted | flag as high risk and require manual review |

Conflicts never block the update and never block boot.

## Scope for uci

Files under `/etc/config/*` are never merged line by line: uci has its own grammar and a
textual merge produces configurations that cannot be loaded.

New upstream defaults are introduced through idempotent `/etc/uci-defaults/` scripts that
only fill missing options and delete themselves after running.

File-level conflict detection therefore covers non-uci user files only.

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
(22.41 MiB), and the difference is tar's block padding. An update payload is therefore just
over 20 MiB, and the full disk image is used for first installation only.

Those sizes are measured, not estimated: they are the members of the published `v0.0.8`
payload, and `tar -tvf n5105-ab-<upstream>-upgrade.tar` on your own copy prints the same
list. Sizes change from release to release, the shape does not.

`manifest.json` records size and sha256 for every member, together with `format`, the
`rootfs` version, the `platform` version and the `kernel` package id. Its `bootloader`
block is described in the next section.

## The bootloader member

`boot.tar` is what lets an update bring its own bootloader forward. It carries two files
and no other content:

| Path in `boot.tar` | What it is |
|---|---|
| `EFI/BOOT/BOOTX64.EFI` | the upstream standalone GRUB EFI binary, byte identical to the one the ESP gets |
| `boot/grub/grub.cfg` | this project's slot menu, rendered from `scripts/ci/grub.cfg.in` by `scripts/ci/grub-render.sh` and shipped only when it passes the five rendering rules |

The manifest describes those bytes in a `bootloader` block, so an updater never has to
guess what it is about to write:

| Field | Meaning | Who acts on it |
|---|---|---|
| `member` | the tar member that carries them, `boot.tar` | `ab-upgrade` |
| `loader` | the loader's path inside that member | `ab-upgrade`, which looks for exactly that file |
| `menu` | the menu's path inside that member | `ab-upgrade`, the same way |
| `loader_bytes` | the loader's size in bytes | the ESP headroom rule: `loader_bytes / 1024 + 4096` KiB has to be free, and `--check` uses the same number as the write |
| `loader_sha256` | digest of the loader | the fact the device trusts: compared with the bytes on the ESP before anything is replaced, and again afterwards |
| `menu_sha256` | digest of the menu | the same, for `boot/grub/grub.cfg` |
| `grub_version` | the GRUB release string, read out of the loader binary itself (the token after `GNU GRUB  version`), `unknown` when it cannot be read | nobody: it is the readable evidence beside the digest, never the decision |
| `source_image` | the upstream image the loader came out of | nobody at run time; it is the provenance a release records |
| `source_sha256` | digest of that image | the same |

A build with no boot source produces no `boot.tar` and writes `"bootloader": null`. That is
a legal payload - a machine whose ESP is fine keeps the loader it runs - and `ab-upgrade`
says so on the console (`bootloader absent-in-payload`) instead of installing silently.
Marking a build as one that has to carry a bootloader is `CI_REQUIRE_BOOTLOADER=1`, which
turns a missing boot source into a build failure.

**The member is defined once, in `scripts/ci/boot-member.sh`.** That fragment is sourced by
`scripts/ci/payload-build.sh`, which builds the payload the S5 test installs, and by
`scripts/ci/assemble.sh`, which builds the payload a release publishes. Both call
`ci_boot_member_stage`, and both take the manifest block from it.

Sharing is not tidiness, it is the fix for a defect that happened: when only the test
payload carried `boot.tar`, the published payload still left an updated machine booting the
GRUB it was flashed with. The defect looked fixed because CI exercised the other builder. A
member fixed in one builder and not in the other is a member that is still broken where it
matters, so there is one definition instead of two. The release assembly also fails the
build when the fragment returns no member, and that check has no opt-out.

To check the identity of a payload by hand, without a device in the loop, run this from
the repository root:

```sh
mkdir -p /tmp/payload
tar -xf n5105-ab-<upstream>-upgrade.tar -C /tmp/payload boot.tar manifest.json
tar -xf /tmp/payload/boot.tar -C /tmp/payload
bash scripts/ci/grub-render.sh --check-loader /tmp/payload/EFI/BOOT/BOOTX64.EFI /tmp/payload/manifest.json
```

## Validation order

Any failure aborts the update:

1. `manifest.json` parses and `format` matches
2. every member exists and its sha256 matches the manifest
3. the vermagic of `btrfs.ko` inside `initramfs.cpio.gz` matches `kernel.bin`
4. p4 has at least 5% free space
5. the conflict report has been produced

On failure `platform_check_image` returns 74, so even `sysupgrade -F` refuses to write.

## Build inputs and adapter

CI does not compile a kernel. It consumes official artifacts:

- `immortalwrt-<ver>-x86-64-rootfs.tar.gz`
- `immortalwrt-<ver>-x86-64-generic-kernel.bin`
- `kmods/<kernel-ver>-<hash>/kmod-fs-btrfs.apk` and its dependencies

Preflight: the hash in the kmods directory name must equal the hash embedded in the
`kernel` package version, otherwise the build fails.

The payload source is an adapter:

| Adapter | Behaviour |
|---|---|
| `upstream` | download official rootfs and kernel (default) |
| `selfbuild` | use locally built rootfs and kernel (seam kept, not implemented) |

Switching adapters does not change the assembly layer or the initramfs.

## Why btrfs arrives as a module

`config.buildinfo` for 25.12.2 contains no `CONFIG_KERNEL_BTRFS_FS`, and the default image
manifest lists 227 packages with no btrfs. btrfs can therefore only be provided by
`kmod-fs-btrfs` loaded from the initramfs. This is the premise of the upstream-consumption
route.
