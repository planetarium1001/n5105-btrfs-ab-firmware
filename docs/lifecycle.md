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
| `overlay-writable` | `/overlay` is writable with more than 5% free |
| `fw4-present` | the nft ruleset is non-empty and the `inet fw4` table is present |
| `wan-present` | a device referenced by `network.wan` exists |

All probes must pass before commit. Any failure abandons the pending slot and reboots into
the committed slot.

`fw4-present` does not look for a daemon: in ImmortalWrt 25.12 `fw4` is a one-shot renderer
that loads the ruleset and exits, so the observable state is the ruleset itself. A slot with
an empty ruleset is the failure this probe exists to catch.

`wan-present` needs a network configuration to name a device. The upstream image has no
`/etc/config/network` before first boot, so tests supply one through the same writable layer
the user would.

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
- at most 8 writes per boot, each a full-file write: temp, `sync`, rename
- write points: `initramfs-enter`, `lower-mounted`, `overlay-mounted`, `switch-root`,
  `healthcheck-done`, `commit` or `abandon`, `done`

Record fields are frozen as `key=value`:

```
stage=<stage> slot=<a|b> upper=<layer> rootfs=<version> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed>
action=<commit|reboot-to-committed|degraded-boot>
```

## Commands

| Command | Purpose |
|---|---|
| `ab-slot status` | slot, generation, free space, last result |
| `ab-slot log [--prev\|--upgrade]` | logs |
| `ab-slot conflicts` | conflict report |
| `ab-slot gc [--dry-run]` | reclamation |
| `ab-slot rollback` | switch back to the other slot |

## Boundary

Rollback depth is one layer. An update overwrites the target slot's rootfs, so older
rootfs images no longer exist on disk.
