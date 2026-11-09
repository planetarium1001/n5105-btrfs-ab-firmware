# Boot Chain and Layered Root

**English** | [简体中文](boot-overlay.zh-CN.md)

## Overview

The running root is an overlayfs composition of two read-only layers from the active slot
and one writable layer on the shared partition.

## Boot sequence

1. GRUB reads slot state and `grubenv` from p1, then selects a kernel and initrd.
2. The initramfs locates p2, p3, and p4 by PARTLABEL, mounts the p4 writable layer first,
   then the read-only slot layers.
3. overlayfs composes the root.
4. `switch_root` enters the system; p1 is mounted at `/boot`.

## Layer responsibilities

| Layer | Subvolume | Mode | Contents | Written by |
|---|---|---|---|---|
| Upstream system | `@sys` | ro | Upstream rootfs, byte-identical | updates only |
| Platform | `@wf` | ro | `ab-slot`, init.d hooks, recovery tooling | updates only |
| User state | `@overlay.genN` | rw | Configuration, installed packages, user files | runtime |

`@wf` is versioned with the slot: it is written during an update and rolls back with the slot.

## Mount composition

```
/ = overlay(
      lowerdir=/mnt/wf:/mnt/sys,
      upperdir=/mnt/p4/@overlay.gen0002/upper,
      workdir=/mnt/p4/@overlay.gen0002/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` order is fixed as `@wf:@sys`; the platform layer takes precedence
- `index=off` avoids the in-use exclusion lock and stale index entries after rollback
- the `volatile` option is never used

## Mount order

1. Mount `@overlay.genN` from p4 with `rw,compress=zstd:6,discard=async`
2. Mount `@wf` with `ro`
3. Mount `@sys` with `ro`
4. Assert that the `/proc/mounts` entry contains `compress=`

p4 is mounted first because `compress=` is only applied by the first mount of a filesystem;
mounting a read-only layer first leaves the parameter out of the kernel.

## How the platform layer takes effect

`@wf` mirrors final filesystem paths:

- `/usr/sbin/ab-slot`
- `/etc/init.d/ab-boot`
- `/etc/init.d/ab-commit`
- `/etc/uci-defaults/`

Because overlayfs merges directories, procd reads `/etc/init.d/*` from the merged view and
the hooks run normally while `@sys` stays untouched.

## GRUB render assertions

The rendered configuration must satisfy all of the following, otherwise the build fails:

- contains `set default=${committed_entry}`
- calls `save_env` with a variable name only, as `save_env -f <grubenv> ab_try`
- never emits `save_env.*ab_try=`
- uses no `&&`, `||`, or `${x:-y}` expansions
- contains no unreplaced template tokens

## Failure handling and degraded boot

| Failure | Behaviour |
|---|---|
| Kernel or initrd fails to load | GRUB retries inline, then `set fallback` returns to the committed slot |
| initramfs stage fails | Log and reboot; `ab_try` was already consumed, so the committed slot is used |
| Health check fails | Abandon the pending slot and return to the committed slot |
| p4 fails to mount | Retry, then try `recovery` read-only, then boot degraded with a tmpfs upper |

A degraded boot keeps `upperdir` in tmpfs: the system runs but does not persist writes.
`ab-slot status` remains available because `@wf` lives on p2/p3, not on p4.
