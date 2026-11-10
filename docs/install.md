# Installing and updating the firmware

This page is the operator view: how to put the image on a disk, what to check on the
first boot, how to update a running system and how to get back. The design behind it
is in [partitions.md](partitions.md), [boot-overlay.md](boot-overlay.md) and
[lifecycle.md](lifecycle.md).

## What you need

A release directory contains four files:

| File | Purpose |
| --- | --- |
| `n5105-ab-<platform>-<upstream>.img.gz` | the complete disk image, written once per machine |
| `n5105-ab-<platform>-<upstream>.tar` | the update payload, used by `ab-upgrade` |
| `SHA256SUMS` | digests of both files |
| `release-notes.md` | versions, upstream inputs and the acceptance lines of the build |

Verify them before writing anything:

```sh
sha256sum -c SHA256SUMS
```

The image is a plain GPT layout: an EFI system partition, two slot filesystems and a
shared btrfs partition holding the writable layers. It boots on x86-64 UEFI only;
legacy BIOS boot is not supported. The target machine needs the N5105 v5 board with
its four-partition layout, or any x86-64 machine you want to test with, since the
image is self-contained.

## Write the image

Writing the image destroys everything on the target disk. Identify the disk first,
then write:

```sh
lsblk -o NAME,SIZE,MODEL
gunzip -c n5105-ab-<platform>-<upstream>.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo sync
```

The result is 514 MiB with four 128 MiB partitions. Nothing else has to be created by hand:
the ESP carries the kernel and initramfs for both slots, the bootloader configuration
is already rendered for the committed slot, and both slot filesystems contain the
same root filesystem.

To write to a file instead, for a virtual machine test:

```sh
gunzip -c n5105-ab-<platform>-<upstream>.img.gz > test.img
qemu-system-x86_64 -machine q35 -m 1G -bios /usr/share/OVMF/OVMF_CODE.fd \
  -drive file=test.img,if=virtio,format=raw -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0 -nographic
```

## First boot

The machine boots from the ESP, the initramfs composes the root with overlayfs and
switches to the real system. Within a minute the health check runs and the running
slot is committed. Watch the console, then confirm the state:

```sh
ab-slot status
```

A healthy machine prints exactly one line:

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid
```

`p4=ok` means the writable partition is mounted; `data`, `docker` and `swap` report the
three subvolumes the platform layer mounts on it. `next=a` is the slot GRUB will boot
next, read back from `boot/grub/ab-slot.cfg`; it is the one line to look at when you
want to know what a reboot would do. If `p4` says `degraded`, read the degraded section
below before you do anything else.

## Acceptance checklist

Run these on the machine before you trust it with anything:

| Check | Command | Expected |
| --- | --- | --- |
| the layout is intact | `ab-slot status` | one line, `p4=ok`, a committed slot |
| the boot was recorded | `ab-slot log` | `stage=boot`, `stage=btrfs-check result=ok`, `stage=commit` |
| the growth finished | `ab-slot log` | `stage=grow result=done` (or `stage=resize result=ok` after a runtime rescue) |
| the tooling works | `btrfs --version` | a `btrfs-progs` banner |
| the layers are reachable | `btrfs subvolume list /mnt/p4` | the layer named by `ab-slot status` |
| the firewall came up | `nft list table inet fw4` | a table, not an error |
| the network is up | `ip -brief address` | the device named in `network.wan` |
| reclamation is idle | `ab-slot gc --dry-run` | no layer reported for deletion |
| the other slot is intact | `ab-slot pending b` then `ab-slot abandon` | the first succeeds, the second clears it |
| the next boot is what you expect | `ab-slot next` | `next=<the committed slot>` after the abandon |

The last row proves the inactive slot still has its kernel and initramfs on the ESP:
`ab-slot pending` refuses a slot whose payload is missing, so a failure there is a
warning about the backup slot, not about the running one.

## Updating a running system

An update writes the inactive slot and marks it pending. It never touches the running
slot, so the machine keeps working if anything goes wrong.

```sh
ab-upgrade /root/n5105-ab-<platform>-<upstream>.tar
ab-slot status
ab-slot conflicts
```

`ab-upgrade` validates the payload before writing: manifest shape, per-member digests,
that every module inside the initramfs comes from one kernel build, free space on the
writable partition and the conflict report. A refusal exits with status 74 and writes
nothing. On success the state shows the other slot as `pending`, `ab-slot status`
reports the new slot as `next=<slot>`, and the next boot tries it:

* the boot runs the health check on the new slot;
* if every probe passes, the slot is committed and the machine stays on it;
* if any probe fails, the pending slot is abandoned and the machine reboots into the
  committed slot;
* if the new slot fails even earlier, in the boot initramfs, the failure path clears
  `pending` itself before it powers off (`action=fail-safe-abandon` in the log), so the
  next boot comes back to the committed slot instead of retrying the broken one.

The upgrade fails with `reason=next-boot-not-<slot>` when the slot is staged but
`boot/grub/ab-slot.cfg` does not point at it: without that file the machine would keep
booting the old slot and the update would never be tried.

Files that both the payload and you changed are listed in `ab-slot conflicts`. They
never block the update: the payload copies the new file, the report tells you which
ones to look at.

## Rolling back

Rolling back means committing the other slot, which still holds the previous
filesystem and its own writable layer:

```sh
ab-slot rollback
reboot
```

The boot then comes up on the other slot and commits it. This is the fast path back
after a bad update. It is not a factory reset: user data written since the update
stays in the layer that was rolled forward, and `ab-slot gc` will not delete it while
a slot still references it.

To discard a staged update without booting it:

```sh
ab-slot abandon
```

## When the writable partition is degraded

If the shared partition cannot be mounted, the boot does not fail: the upper layer
moves to memory, the system comes up, and both the console and `ab-slot status` say
`p4=degraded`. The machine works, but nothing written since the boot survives a
reboot, and `ab-upgrade` refuses to run:

```
ab-upgrade: refused, reason=writable-layer-degraded
```

Treat this as a hardware warning. Check the disk with `btrfs check` from a live
system, back up anything you still need, and reinstall from the image once the cause is
cleared.

## Troubleshooting

Read the boot log first; it records every stage in `key=value` form:

```sh
ab-slot log
ab-slot log --prev
```

| Symptom | Usually means | What to do |
| --- | --- | --- |
| no console output at all | wrong boot mode or disk | boot UEFI only, check the disk order |
| `p4=degraded` | the shared partition cannot mount | see the section above |
| `p4=ok` but no `stage=commit` | the health check failed | `ab-slot log` names the failing probe; `ab-slot abandon` clears a pending slot |
| `ab-upgrade` exits 74 | the payload or the machine was refused | the reason is printed and logged; nothing was written |
| the machine reboots into the same slot after an update | the new slot failed its health check | the log holds `reason=healthcheck-failed`; fix the payload and install it again |
| `next=` is not the slot you expect | the boot hint was not written, or was written by an older boot | `ab-slot next --write` rewrites it from `ab/state.json`; the log shows `stage=slot-cfg` with the value it wrote |
| the machine keeps coming back to the committed slot after an update | the candidate failed before userspace | the log holds `action=fail-safe-abandon` and `reason=`; nothing is pending any more, so install the payload again once the cause is fixed |
| `disk=unknown` in `ab-slot status` | the boot disk could not be identified | the log names it in `stage=device`; check the GPT names and `ab/device.json` against the disk you actually wrote |
| `stage=resize result=fail:btrfs-resize` | the filesystem could not be extended, in the initramfs or again at runtime | `ab/log/resize.log` holds btrfs' own message; the partition keeps its size and the next boot retries |
| `btrfs=ok` missing from the log | the platform layer lost its tooling | reinstall from the image; the tool ships in the platform layer |

Every failure carries a `reason=` token in the log, which is the same token the CI
judge lines report, so a machine and a build can be compared without guessing.
