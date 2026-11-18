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
| Project-owned content | Build layer, boot layer, and the `@platform` platform layer only |
| Boot | UEFI only; no legacy/BIOS support, no multi-board support |

## Disk layout

| Partition | PARTNAME | LABEL | Size | Filesystem | Contents |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB, slot state, boot logs |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | Slot A: `@sys` + `@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | Slot B: `@sys` + `@platform` |
| p4 | `ab-data` | `data` | 128 MiB, grown to the disk end on first boot | btrfs | `@overlay-<version>`, `@docker`, `@swap`, `@data` |

- PARTNAME (`ab-…`) is the stable name the boot code matches against the kernel's block
  devices; LABEL is the short name a human or `blkid` reads. [docs/partitions.md](docs/partitions.md)
  states both sets as contracts.
- `@sys` — upstream rootfs, read-only
- `@platform` — platform tooling, versioned with the slot, read-only
- `@overlay-<version>` — all writable state, shared by both slots

### When the disk is bigger than the image

The image is 514 MiB and p4 is 128 MiB inside it. On first boot the boot initramfs grows
**p4 only** to the end of whatever disk the image was written to, then grows the filesystem
into it; p1, p2 and p3 are never touched and every PARTUUID stays the same. That makes the
same image usable on any NVMe or SATA disk, and it is why a backup restored onto a larger
disk simply comes up with the extra space already available.

Two things follow, and both are deliberate:

- **It is idempotent.** The decision is re-evaluated on every boot. Once p4 reaches the end
  of the disk the log says `stage=grow … result=already-full` and nothing is written.
- **It never shrinks and never guesses.** Restoring a large disk's image onto a smaller
  disk leaves the table describing space that does not exist; the growth then refuses with
  `fail:p4-beyond-disk` and leaves the table alone. `ab/log/grow.log` on the ESP records
  every decision.

If you would rather keep unallocated space at the end of the disk (for another system, or a
spare partition of your own), grow p4 by hand before the first boot and the automatic step
will find it already full.

## Boot chain

1. GRUB reads slot state from p1 and selects kernel and initrd.
2. The initramfs mounts the p4 writable layer, then the read-only slot layers.
3. overlayfs composes the root: `lowerdir=@platform:@sys`, `upperdir=@overlay-<version>/upper`.
4. `switch_root` enters the system.

## Default network

A freshly flashed disk reaches the network on its own. The first boot runs `ab-net-seed`
(start `S16`, before `network`) only when `/etc/config/network` is absent: it calls the
upstream `/bin/board_detect` and `/bin/config_generate`, then applies this project's
defaults. A configuration that already exists -- your own `uci` changes, a test fixture, a
file an upgrade carried over -- is never rewritten. Details, checks and variants:
[docs/network.md](docs/network.md).

| Interface | Device | Protocol | Address |
|---|---|---|---|
| WAN | `eth0` | `dhcp` client | lease from the upstream network |
| LAN | `br-lan` over `eth1`, `eth2`, `eth3` | `static` | `192.168.100.1/24` |
| LAN DHCP | dnsmasq on `lan` | — | upstream's `lan` pool, `/etc/config/dhcp` untouched |

**Known limitation: a machine with a single Ethernet port — a QEMU test run, for example — comes
up LAN-only.** The one port joins `br-lan` and there is no `wan` section at all, so the
`wan-present` health probe fails on every boot and the slot reports itself unhealthy; that is
this release's documented behaviour, not a fault, because a slot with no WAN interface cannot
have a WAN device. A four-port N5105 runs in router mode and is unaffected.

- The WAN side accepts **nothing**. The shipped image carries no `allow_ssh_wan` rule: the
  `wan` zone keeps `input 'REJECT'`, `dropbear` keeps upstream's binding to `lan`, and
  LuCI's `80/tcp` is not exposed to the WAN either.
- One image is the deliberate exception. `n5105-ab-<upstream>-install-wan-ssh.img.gz` adds
  exactly one `22/tcp` rule, for a machine you cannot reach from the LAN and cannot give a
  keyboard and a monitor. Its first boot prints the three ways to close the rule, and the
  default image never carries it.

Change the LAN subnet, then reconnect at the new address:

```sh
uci set network.lan.ipaddr='192.168.8.1/24'
uci commit network
/etc/init.d/network reload
```

Move the WAN role to another port. `ip -br link` shows which `eth*` carries which socket:
plug a cable into each socket and watch which line goes `UP`.

```sh
uci show network | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='br-lan'$/\1/p"
# prints the br-lan section, e.g. @device[0]; the two lines below use it
uci set network.wan.device='eth3'
uci del_list 'network.@device[0].ports=eth3'
uci add_list 'network.@device[0].ports=eth0'
uci commit network
/etc/init.d/network reload
```

Close WAN 22 on the `-wan-ssh` image, in the shell or in LuCI under
**Network -> Firewall -> Traffic Rules** (the rule is named `allow_ssh_wan`; 中文界面为
网络 -> 防火墙 -> 通信规则):

```sh
uci delete firewall.allow_ssh_wan
uci commit firewall
/etc/init.d/firewall reload
```

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

## Testing

```
./tests/run.sh                  # every module, parallel by default
./tests/run.sh --module design  # one module
./tests/run.sh --jobs 8         # bound parallelism
./tests/run.sh --list           # list discovered tests
```

Tests live under `tests/modules/<module>/test_*.sh`, one module per concern.
Each test is an independent process, so modules run concurrently and a failure in one
never hides another.

## Documentation

Start with the two pages written for the preview:

- [docs/quickstart.md](docs/quickstart.md) — the shortest path: write, boot, install one
  package, upgrade once, roll back once
- [docs/update-mechanism.md](docs/update-mechanism.md) — every status field, its values, and
  the command that checks it

Then the reference:

- [docs/](docs/README.md) — design documents
- [docs/backup.md](docs/backup.md) — backup and restore contract: the three products, what each one can be restored to, and the restore decision tree
- [docs/known-limitations.md](docs/known-limitations.md) — what does not work, and what to do instead

## Status

Design stage. Partition geometry, boot chain, and update transaction are finalized.
Implementation proceeds through stages S0–S6.

Current version: `0.0.13`, on upstream base `25.12.2`. It is a **test release**, not `0.1.0`:
the upstream base is unchanged and no user-visible feature is added. It packages the defects
found after `0.0.11` together with the acceptance capability that now covers them.

- **An apk protection rule is judged by its premise.** `scripts/device/apk-protection-probe.sh`
  asks `apk audit --backup` whether apk sees a protected path as unmodified — the premise a
  `+` rule in `/etc/apk/protected_paths.d/` depends on — so a rule that cannot fire is named
  on the spot. The device drivers are all POSIX `sh`, the dialect `scripts/ci/verify.sh`
  lints them in.
- **An A/B slot switch is judged by the data it produces.** `scripts/device/lib.sh` exports
  three field groups read from archived real-device runs — stable, identity, monitored — so
  the matrix and scenario drivers no longer fold `committed`, `pending` and `generation` into
  one class. `ab-slot packages snapshot` stops answering `packages=0` for a record it cannot
  parse, and the commit path retargets the package record.
- **The daily upstream watch fails when discovery fails**, so a broken mirror or index is a red
  job instead of a green one that watched nothing.
- **The release page is built from the payload manifest**, which retires the `not recorded`
  placeholders on the kernel version and the upstream digests.
- **The acceptance suite is one command.** `scripts/device/full-test.sh` puts the four broken
  configurations of S8, the real docker load D1/D2/D3, the version pin (`--case pin`), the
  package rollback P3/P4 and the release byte checks in one order, under one verdict.

Earlier releases introduced the first-boot network generation (`0.0.7`), the payload that
carries its own bootloader (`0.0.8`) and the health check (`0.0.6`); all three are unchanged.

## License

- Build tooling and project-owned code: [MIT](LICENSES/MIT.txt)
- Files derived from upstream OpenWrt: [GPL-2.0-only](LICENSES/GPL-2.0-only.txt)
