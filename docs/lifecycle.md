# Update Transaction, Reclamation and Observability

**English** | [简体中文](lifecycle.zh-CN.md)

## Generation model

The writable layer is not a single fixed name but a generation: `@overlay.genNNNN`.
Every update creates a new generation, and no subvolume is ever renamed.

Consequences:

- there is no temporary name to be occupied, so a new generation can be created even if the
  system has never rebooted
- rollback only moves a pointer; no data is copied
- steady state needs exactly two generations, one per slot

## State file

`ab/state.json` on p1, written atomically (temp file, `sync`, rename):

```json
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper_gen": 3 },
    "b": { "rootfs": "25.12.2", "upper_gen": 2 }
  }
}
```

## Transaction sequence

| Event | p4 | p1 state |
|---|---|---|
| Installation | create `gen0001`, `@docker`, `@swap`, `@data` | `a` and `b` to gen1, `committed=a` |
| Update slot B | `snapshot gen1 -> gen2`, write p3 | `pending=b`, `b` to gen2 |
| B boots healthy | — | `committed=b`, clear pending, reclaim |
| Update slot A | `snapshot gen2 -> gen3`, write p2 | `pending=a`, `a` to gen3 |
| A boots healthy | delete gen1 | `committed=a`, clear pending |
| Rollback | — | switch `committed` to the other slot |

The snapshot target is always the live generation. Run `sync` and stop writers first;
consistency is crash-consistent, not application-consistent.

## Health check

Runs after `done` completes, with a 150 second timeout:

| Probe | Passes when |
|---|---|
| `overlay-writable` | `/overlay` is writable with more than 5% free |
| `fw4-present` | the firewall process exists and the nft ruleset is non-empty |
| `wan-present` | the WAN device exists |

All probes must pass before commit. Any failure abandons the pending slot and reboots into
the committed slot.

## Reclamation

The reference set is `slots.a.upper_gen` ∪ `slots.b.upper_gen` ∪ `pending.upper_gen`.
Any `@overlay.gen*` outside that set is deleted.

Four safety rules:

1. never delete a generation that is currently mounted (check `/proc/mounts`)
2. never delete the generation referenced by `pending`
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
stage=<stage> slot=<a|b> upper_gen=<N> rootfs=<version> result=<ok|fail>
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

Rollback depth is one generation. An update overwrites the target slot's rootfs, so older
rootfs images no longer exist on disk.
