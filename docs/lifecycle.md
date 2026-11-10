# Update Transaction, Reclamation and Observability

**English** | [简体中文](lifecycle.zh-CN.md)

## Writable layer naming

The writable layer is named after the upstream release it belongs to, `@overlay-<version>`,
for example `@overlay-25.12.2`.
Every update creates a new layer, and no subvolume is ever renamed.

Reusing the version number keeps the name self-describing: the layer, the slot's rootfs
and the upstream release all read as the same thing. Because an upstream version can be
rebuilt with a different platform layer, a repeat of the same version takes an ordinal
suffix, `@overlay-25.12.2-r2`.

The name is for humans; ordering is not derived from it. `ab/state.json` still carries an
integer `generation` that only ever increases, and reclamation sorts by that number.

Consequences:

- there is no temporary name to be occupied, so a new layer can be created even if the
  system has never rebooted
- rollback only moves a pointer; no data is copied
- steady state needs exactly two layers, one per slot

## State file

`ab/state.json` on p1, written atomically (temp file, `sync`, rename):

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

## Slot selection

`ab/state.json` is the truth. GRUB cannot read it, so the bootloader gets one derived
value in a file of its own:

| Artefact | Written by | Read by | Role |
|---|---|---|---|
| `ab/state.json` | `ab-slot` (temp file, `sync`, rename) | initramfs, `ab-boot`, `ab-commit`, `ab-upgrade`, `ab-slot` | the truth: `committed`, `pending`, layers |
| `boot/grub/ab-slot.cfg` | `ab-slot` in `pending`/`commit`/`abandon`/`rollback`, `ab-boot` on every boot, and the boot initramfs on its failure path | GRUB, through `source` | the hint: which entry the next boot runs, and where a failed try falls back to |
| `boot/grub/grub.cfg` | the image build, once | GRUB | the menu and the build-time default; never rewritten at runtime |

`boot/grub/ab-slot.cfg` holds exactly two GRUB commands, in this order:

```
set fallback=<the committed slot>
set default=<the pending slot, or the committed slot when nothing is pending>
```

Every writer derives both values from the state file through one implementation
(`platform/lib/ab-slot-cfg.sh`), so the build, the state commands, the boot hook and the
boot failure path cannot disagree. There is no environment block: the GRUB in the ESP is
a standalone EFI binary with its modules built in and no `env` module, so `load_env` and
`save_env` do not exist there. A two-line file that `source` reads works on that binary,
and `scripts/ci/grub-render.sh --verify-esp` asserts that the loader really carries
`source`, `test` and `serial` before an image is allowed to boot.

The menu defines the three entries, sets the committed slot as the *build-time default
and fallback*, and only then sources the hint file. GRUB stops reading a script at the
first error, so ordering it this way means a missing, truncated or malformed hint file
cannot cost the machine its menu: it boots the committed slot, which is what the
build-time pair already says.

Entry indices are part of the contract: slot `a` is entry 0, slot `b` is entry 1. The
renderer refuses a configuration whose menu order does not match, because a swapped
order would silently boot the wrong slot.

### Power loss between the two writes

The state file and the hint are written one after the other, each atomically. A power
cut in the gap leaves the state advanced and the hint stale, and the machine boots the
slot the hint names.

- `ab-boot` rewrites the hint from the state file on every boot, before anything reads
  it, so the stale hint costs one boot and never a wrong slot: the boot after the
  interrupted one runs what the state file says.
- The file writes its fallback line first for that reason. A write cut short after the
  first line has therefore written only `set fallback=<committed>`, which is the value
  the menu already had: the default stays on the committed slot and the machine boots
  it. A complete file moves the default to the slot being tried and leaves the fallback
  where it is, which is exactly the pair a failed try needs. No truncation can leave the
  fallback pointing at the slot that is being tried.

### When a new slot does not work

Two fallbacks, in this order:

1. the kernel of the pending slot does not start: GRUB moves to the `fallback` entry,
   which is the committed slot, and the machine boots the old system;
2. the kernel starts and the health check fails: `ab-commit` abandons the pending slot,
   which clears `pending` in the state file and points the hint back at the committed
   slot, then reboots into it;
3. the kernel starts but the boot initramfs fails before userspace: `wf_fail` runs the
   same fail-safe abandon (clear `pending`, point the hint at the committed slot, log
   `action=fail-safe-abandon`) and only then powers off, so the next boot does not retry
   the slot that just failed.

`ab-slot rollback` is the manual path: it commits the other slot and moves the hint with
it. `ab-slot status` reports the resulting hint as `next=<a|b|unknown>`, and
`ab-slot next` prints it alone, which is the fastest way to see what the next boot will
do from a running system.

## Transaction sequence

| Event | p4 | p1 state |
|---|---|---|
| Installation | create `@overlay-25.12.2`, `@docker`, `@swap`, `@data` | `a` and `b` both point at it, `committed=a` |
| Update slot B to 25.12.3 | `snapshot @overlay-25.12.2 -> @overlay-25.12.3`, write p3 | `pending=b`, `b.upper` updated |
| B boots healthy | — | `committed=b`, clear pending, reclaim |
| Update slot A to 25.12.4 | `snapshot @overlay-25.12.3 -> @overlay-25.12.4`, write p2 | `pending=a`, `a.upper` updated |
| A boots healthy | delete `@overlay-25.12.2` | `committed=a`, clear pending |
| Rollback | — | switch `committed` to the other slot |

The snapshot source is always the live layer. Run `sync` and stop writers first;
consistency is crash-consistent, not application-consistent.

## Health check

Runs after `done` completes, with a 150 second timeout:

| Probe | Passes when |
|---|---|
| `overlay-writable` | the composed root `/` is writable with at least 16 MiB free (an absolute floor, not a percentage: the same rule has to mean the same thing on a 128 MiB test image and on a disk measured in hundreds of GiB) |
| `fw4-present` | the nft ruleset is non-empty and the `inet fw4` table is present |
| `wan-present` | a device referenced by `network.wan` exists |

All probes must pass before commit. Any failure abandons the pending slot and reboots into
the committed slot.

The writable layer is the root itself: the boot initramfs mounts `@overlay-<version>` as the
upper directory and `switch_root`s into the composed tree, so there is no separate `/overlay`
mount to measure.

Every probe runs, even after one has failed: the decision only needs the first failure, but
the log has to name all three in one boot, otherwise a slot with two faults costs two boots
to explain itself.

`fw4-present` does not look for a daemon: in ImmortalWrt 25.12 `fw4` is a one-shot renderer
that loads the ruleset and exits, so the observable state is the ruleset itself. A slot with
an empty ruleset is the failure this probe exists to catch.

`wan-present` needs a network configuration to name a device, and the platform layer produces
one: `ab-net-seed` runs at `S16`, before `S20network`, and on a system whose
`/etc/config/network` is absent it calls upstream `board_detect` and `config_generate` and then
applies the project defaults ([network.md](network.md)). A fresh install therefore has a device
for this probe to read, and a seed that fails only logs `stage=net-seed result=fail` and lets
the boot continue.

A configuration that already exists is left untouched, which is also how a test supplies its
own: a fixture injected through the same writable layer the user would wins over the generated
one, so the probe can be exercised against a device name the test chose.

## Reclamation

The reference set is `slots.a.upper` ∪ `slots.b.upper` plus the pending slot's layer.
Any `@overlay-*` outside that set is deleted, oldest `generation` first.

Four safety rules:

1. never delete a layer that is currently mounted (check `/proc/mounts`)
2. never delete the layer referenced by the pending slot
3. run `btrfs subvolume delete -C` followed by `btrfs subvolume sync`; deletion alone
   does not free space immediately
4. never run a full balance under disk pressure; balance itself needs free space

Triggers: after a successful commit, early in each boot, after a failed update, and on
demand through `ab-slot gc`.

Space thresholds:

| Free space | Action |
|---|---|
| above 15% | normal |
| below 15% | warn and reclaim automatically |
| below 5% | `platform_check_image` returns 74 and the update is refused |

No qgroup quota is used; exclusive space is measured on demand with `btrfs filesystem du -s`.

Before any probe runs, the tree has to be a tree: `/proc/cmdline`, `/proc/mounts` and
`/sys/class/net` are read first. An upgraded slot that comes up without `/proc` fails all
three probes for one reason, so that reason gets its own line
(`stage=preflight … reason=proc-cmdline-unreadable`) instead of three anonymous failures -
the difference between "the health check is wrong" and "this slot did not boot properly".

### Finishing a growth the initramfs could not

`btrfs filesystem resize` refuses to open the device while the filesystem is mounted
more than once, which is what the initramfs has to do to write the record and the
pre-change table. When it fails there it writes `result=fail:btrfs-resize` into
`.ab/grow` and continues.

`ab-boot` then finishes the job once the system is up: `/mnt/p4` is the only mount of
that filesystem there, which is the state btrfs-progs needs, so it runs
`btrfs filesystem resize max /mnt/p4`, appends btrfs' own output to `ab/log/resize.log`,
adds one `stage=resize result=… source=ab-boot` line to the ring log, and rewrites
`.ab/grow` to `result=done` so the record stays the single truth. A failure there only
logs; the next boot tries again.

## Logging

Directory `/boot/ab/log/`, total budget about 350 KiB.

| File | Contents | Rotation |
|---|---|---|
| `boot-0.log` | current boot | rotated on each boot |
| `boot-1.log` | previous boot | — |
| `boot-2.log` | boot before that | removed when exceeded |
| `upgrade.log` | most recent update | overwritten by the next update |
| `conflicts.log` | most recent conflict report | overwritten by the next update |

- 32 KiB per file; overflow is truncated with a `TRUNCATED=1` marker
- the boot hook makes at most 8 writes per boot, each a full-file write: temp, `sync`,
  rename; the health check appends its own probe lines afterwards
- the state lock is a directory on the ESP carrying `<boot_id> <pid> <started_at>`; a lock
  whose boot or process is gone is taken over (logged as `stage=lock action=stale-lock-taken`),
  so a power cut or a hard kill cannot leave the machine unable to commit
- write points: `initramfs-enter`, `lower-mounted`, `overlay-mounted`, `switch-root`,
  `slot-cfg` (the hint GRUB will read), `grow` (the first-boot growth result),
  `resize` (a growth finished at runtime, see below), `healthcheck-done`, `commit` or
  `abandon`, `done`

Record fields are frozen as `key=value`:

```
stage=<stage> slot=<a|b> upper=<layer> rootfs=<version> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail> [reason=<token>]
stage=preflight slot=<a|b> result=fail reason=<proc-cmdline-unreadable|proc-mounts-unreadable|sysfs-missing>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed|slot-cfg-not-written|btrfs-resize>
action=<commit|reboot-to-committed|degraded-boot>
next=<a|b>
```

## Commands

| Command | Purpose |
|---|---|
| `ab-slot status` | slot, generation, mount points, next boot, last result |
| `ab-slot log [--prev\|--upgrade]` | logs |
| `ab-slot conflicts` | conflict report |
| `ab-slot gc [--dry-run]` | reclamation |
| `ab-slot rollback` | switch back to the other slot |
| `ab-slot next [--write]` | which slot GRUB will boot, and the heal that rewrites it |

## Boundary

Rollback depth is one layer. An update overwrites the target slot's rootfs, so older
rootfs images no longer exist on disk.
