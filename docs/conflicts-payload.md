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

| Member | Source | Size |
|---|---|---|
| `rootfs.tar.gz` | official mirror | 10.1 MiB |
| `kernel.bin` | official mirror | 7.35 MiB |
| `initramfs.cpio.gz` | this project | about 2 MiB |
| `wf.tar` | this project | under 1 MiB |
| `manifest.json` | this project | under 4 KiB |

The update payload is about 20 MiB. The full disk image is used for first installation only.

`manifest.json` records size and sha256 for every member, together with `format` and the
`rootfs` version.

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
