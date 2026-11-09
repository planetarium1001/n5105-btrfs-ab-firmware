# CI stage scripts

Every stage of the pipeline is a shell script in this directory. The workflows in
`.github/workflows/` only orchestrate: they check out the repository, run one script,
upload the results and collect diagnostics. Keeping the logic here means a stage can be
reproduced locally with the same inputs the workflow passes.

| Workflow | Stage |
|---|---|
| `.github/workflows/ci.yml` | entry point: triggers, stage selection, final verdict |
| `.github/workflows/ci-resolve.yml` | resolve |
| `.github/workflows/ci-fetch.yml` | fetch |
| `.github/workflows/ci-assemble.yml` | assemble |
| `.github/workflows/ci-s1.yml` | s1 (module-load probe) |
| `.github/workflows/ci-s2.yml` | s2 (disk image assembly) |
| `.github/workflows/ci-s3.yml` | s3 (layered boot) |
| `.github/workflows/ci-s4.yml` | s4 (slot state machine, three boots) |
| `.github/workflows/ci-s5.yml` | s5 (upgrade payload, reclamation, degraded boot) |
| `.github/workflows/ci-verify.yml` | verify |
| `.github/workflows/ci-report.yml` | report |

The stage workflows sit at the root of `.github/workflows/` and not in a subdirectory:
GitHub does not support reusable workflows in subdirectories of that directory, so the
`ci-<stage>.yml` naming keeps the grouping visible while staying callable.

## Files

| Script | Stage | Purpose |
|---|---|---|
| `lib.sh` | — | shared helpers, pinned upstream version, cache key inputs; sourced by the others |
| `resolve.sh` | resolve | pick the upstream release, cross-check the kernel module directory, derive the cache key |
| `fetch.sh` | fetch | download rootfs, kernel and btrfs module, verify every sha256, write a receipt |
| `assemble.sh` | assemble | build the payload directory and `manifest.json` (S0 skeleton) |
| `verify.sh` | verify | `bash -n`/`sh -n`, ShellCheck, `python3 scripts/check_design.py all` |
| `kmods.sh` | s1 | fetch, verify and unpack the btrfs module closure against the lockfile |
| `apk_extract.py` | s1 | unpack `.ko` files out of apk-tools v3 (ADB) containers |
| `initramfs.sh` | s1 | build the minimal probe initramfs |
| `qemu-smoke.sh` | s1 | boot it under QEMU and assert the frozen judge line |
| `apk-crosscheck.sh` | s1 | optional: compare the closure with what upstream `apk` installs |
| `esp-prepare.sh` | s2 | take the ESP tree (GRUB) from the upstream combined-EFI image |
| `disk.sh` | s2 | assemble and compress the four-partition image |
| `image-verify.sh` | s2 | host-side geometry assertions and the guest expectation file |
| `grub-render.sh` | s2/s4 | render `boot/grub/grub.cfg` and assert the five GRUB rules |
| `ab-fixtures.sh` | s4 | shape the test image between boots (network, broken slot, pending) |
| `ab-phase.sh` | s4 | read the ESP back after a boot and print the frozen S4 judge line |
| `payload-build.sh` | s5 | build the test upgrade payload (rootfs, kernel, initramfs, platform layer, manifest) |
| `s5-phase.sh` | s5 | grade an upgrade / commit / degraded boot by reading the image back |
| `report.sh` | report | render the verdict and fail the run when a scheduled stage failed |
| `diagnostics.sh` | all | environment facts, disk usage and file inventories for failure triage |

## Stage graph

```
resolve ──┬── fetch ── assemble ──┐
          └── verify ─────────────┴── report
```

`workflow_dispatch` selects how much of the graph runs, so a failed run resumes instead
of restarting:

| `stage` | Stages executed |
|---|---|
| `all` (default) | resolve, fetch, assemble, verify, report |
| `fetch` | resolve, fetch, report |
| `assemble` | resolve, fetch, assemble, report |
| `verify` | resolve, verify, report |

`resolve` always runs: it is a handful of small downloads and it publishes the upstream
version and cache key that the report needs.

## Cache key

```
cache_key = upstream-<version>-<sha256(key material)[0..16]>
key material = upstream_version, kmods_dir, kernel_package,
               rootfs/kernel/btrfs-module sha256,
               CI_TOOLS_VERSION, CI_TOOLS,
               sha256 of every scripts/ci/*.sh and .github/workflows/**/*.yml
```

Consequences:

- an unchanged upstream release, tool set and CI script set hits the cache and skips
  the network
- bumping `CI_UPSTREAM_VERSION_PIN` or `CI_TOOLS_VERSION` in `lib.sh`, or editing any CI
  script or workflow, produces a different key, so stale downloads are never reused
- `restore-keys: upstream-<version>-` still allows a partial reuse after a script edit;
  every restored file is re-verified against the pinned sha256, so a stale cache entry
  can only ever be discarded, never silently trusted

## Running a stage locally

The scripts need no GitHub-specific tooling; `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY`
are optional, and `CI_OUTPUT_ENV` turns stage outputs into a `KEY=VALUE` file that the
next stage can load.

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"

CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh
CI_UPSTREAM_VERSION="$(sed -n 's/^upstream_version=//p' "$CI_TMP_ROOT/resolve.env")" \
  CI_KERNEL_PACKAGE="$(sed -n 's/^kernel_package=//p' "$CI_TMP_ROOT/resolve.env")" \
  bash scripts/ci/assemble.sh
bash scripts/ci/verify.sh
bash scripts/ci/report.sh
```

`lib.sh` falls back to `shasum -a 256` when `sha256sum` is absent, so the scripts also run
on macOS.

## S1: the module-load probe

The upstream kernel is built without `CONFIG_KERNEL_BTRFS_FS`, so btrfs only exists as
`kmod-fs-btrfs`. S1 proves that the official kernel loads the official module set inside
our own initramfs and mounts a btrfs filesystem.

```
kmods.sh ──> initramfs.sh ──> qemu-smoke.sh ──> judge line
```

1. `kmods.sh` resolves the closure, verifies every package against the release
   `sha256sums`, unpacks the `.ko` files and asserts the result against
   `scripts/ci/kmod-closure.json`. Drift fails the stage; refresh deliberately with
   `bash scripts/ci/kmods.sh --write-lock`.
2. `initramfs.sh` stages a static (or library-carrying) busybox, `initramfs/init` and
   the modules, then packs a `newc` cpio archive.
3. `qemu-smoke.sh` builds a 64 MiB btrfs image with a marker file, boots the kernel
   under TCG with the initramfs, and asserts the frozen judge line.

### Frozen judge line

`initramfs/init` prints exactly one of these and powers off:

```
S1-RESULT=ok kernel=<vermagic> modules=<n> btrfs=mounted
S1-RESULT=fail reason=<token>
```

Everything downstream matches `^S1-RESULT=` only. Treat the shape as frozen: adding a
field means versioning the line, not editing it.

### apk-tools v3 packaging

The kmods are apk-tools v3 containers: 4-byte magic `ADBd`, then a raw-deflate stream
holding the metadata and the file data. `tar`, `bsdtar` and `ar` all reject them, so
`apk_extract.py` inflates the payload, locates each ELF image, derives its exact length
from its own section header table, and maps it to the module path in the file table.
The result is byte-identical to what the official image installs: extracting
`kmod-lib-crc32c` reproduces the `libcrc32c.ko` shipped in the upstream rootfs.

Four of the fourteen closure members (`kmod-crypto-crc32c`, `kmod-crypto-hash`,
`kmod-lib-zlib-deflate`, `kmod-lib-zlib-inflate`) are virtual packages: the drivers are
built into the kernel and the package only provides `<name>-any` plus `/etc/modules.d`
snippets. They are recorded as `kind: virtual` in the lockfile, so the ten real
packages and sixteen real modules are visible at a glance.

## S2: the four-partition image

`disk.sh` builds a 450 MiB GPT image (1 MiB alignment, 448 MiB of partitions, 1 MiB
tail for the backup table) with the geometry frozen in `docs/partitions.md`:

| Partition | PARTLABEL | Sectors | Filesystem |
|---|---|---|---|
| p1 | `ab-esp` | 262144 (128 MiB) | vfat |
| p2 | `ab-slot-a` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p3 | `ab-slot-b` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p4 | `ab-shared` | 131072 (64 MiB) | btrfs `-m single -d single` |

The image is verified twice:

1. `image-verify.sh` inspects the raw image on the host (`sfdisk -J`, mounted
   subvolume listings, a full `diff -r` of `@sys` against the upstream tree) and
   writes `s2-expect.txt`, the expectations the guest has to reproduce.
2. the guest assertion (`tests/modules/image/guest-assert.sh`, run as `/s2.sh` in a
   second initramfs) reads the same image through the kernel and prints the frozen
   judge line:

```
S2-RESULT=ok parts=4 images=<bytes>
S2-RESULT=fail reason=<token>
```

Both slots currently carry the S1 probe initramfs as `initrd-a`/`initrd-b` so the ESP
is complete; S3 replaces them with the real initramfs mount chain. The ESP itself
comes from the upstream combined-EFI image, which is why the stage needs no GRUB
build dependency: upstream types that ESP as a plain Linux filesystem, so the
partition is found by probing for a FAT signature rather than by trusting the GUID.

## S3: the layered boot initramfs

`initramfs/boot/init` replaces the S1 probe as the image's `initrd-a`/`initrd-b`. It
reads `ab/state.json` from the ESP, then composes the running root in the order
`docs/boot-overlay.md` requires:

| Step | Command (abridged) | Why this order |
|---|---|---|
| 1 | `mount -o rw,noatime,compress=zstd:6,discard=async,subvol=/@overlay-<version> p4 /mnt/p4` | `compress=` is fixed by the first mount of a filesystem |
| 2 | `mount -o ro,noatime,subvol=/@platform p2 /mnt/@platform` | platform layer, mounted read-only |
| 3 | `mount -o ro,noatime,subvol=/@sys p2 /mnt/@sys` | upstream layer, mounted read-only |
| 4 | `mount -t overlay -o lowerdir=/mnt/@platform:/mnt/@sys,upperdir=/mnt/p4/upper,workdir=/mnt/p4/work,index=off overlay /newroot` | platform layer wins the lower merge |

The read-only layers are mounted under `@`-names so the overlay command line carries
both layer names verbatim, which is what the judge line reports as `lower=platform:sys`.

`switch_root` then hands control to `/s3-post.sh`, which re-checks everything from
inside the composed root: `/` is the overlay, `@platform` and `@sys` both contribute files,
probe writes appear in `<generation>/upper` and in neither read-only layer, and the
probe written by the previous boot is still there. It ends by executing `/sbin/init`,
so the boot proves the root is a working system; the harness stops the machine as soon
as the judge line appears.

```
S3-RESULT=ok slot=<a|b> upper=<@overlay-version> lower=<platform:sys> root=<overlay>
S3-RESULT=fail reason=<token>
```

The stage boots the same image twice (`wf.boot=1`, then `wf.boot=2`) and both boots
must pass. Probe markers (`.s3-probe`, `.s3-new-<n>`, `.s3-post`) stay in the
generation's upper directory, which is what makes the second boot meaningful.

Two consequences worth knowing:

- the ESP needs `vfat`, which the upstream kernel does not build in, so the module
  closure carries `kmod-fs-vfat` (fat.ko, vfat.ko) plus `kmod-nls-cp437` and
  `kmod-nls-iso8859-1`; `kmod-nls-base` is virtual. `scripts/ci/kmod-closure.json`
  therefore pins 18 packages / 20 modules.
- `ab/state.json` ships in the image with the installation state (both slots on
  `@overlay-<version>`, generation 1, slot `a` committed). S4 starts updating it; the
  parser in `initramfs/lib/wf.sh` fails on an unreadable state rather than falling back
  to a default slot. The writable layer is named after the upstream release
  (`@overlay-25.12.2`, or `@overlay-25.12.2-r2` for a re-release); `generation` stays
  an integer because version strings do not sort correctly.

## S4: the slot state machine

The A/B logic lives in `platform/`, which is the source tree of the `@platform` layer
and is mirrored onto the final filesystem paths:

| Path | Role |
|---|---|
| `platform/usr/sbin/ab-slot` | status, commit, pending, abandon, rollback, gc, rootfs, log |
| `platform/etc/init.d/ab-boot` | `START=15`: mounts `/boot` and `/mnt/p4`, rotates the boot log, marks a candidate first boot |
| `platform/etc/init.d/ab-commit` | `START=99`: runs the three probes, then commits or abandons |
| `platform/etc/platform-release` | template rendered with the build's versions |

`ab-slot` reads `ab/state.json` from the ESP (`/boot` by default, `AB_ESP` overrides
it for tests) and writes it atomically: temporary file in the same directory, `sync`,
rename, `sync`. Concurrent writers are excluded by a directory lock, because `mkdir`
is atomic on vfat. The running slot comes from `ab.slot=<a|b>` on the kernel command
line, which is what GRUB sets per menu entry; without it the committed slot is
assumed.

### Health check

`ab-commit` runs after `done` with a 150 second budget and logs every probe in the
frozen format (`probe=<name> result=<pass|fail>`):

| Probe | Passes when |
|---|---|
| `overlay-writable` | `/overlay` is writable and more than 5% of it is free |
| `fw4-present` | `nft list ruleset` is non-empty and the firewall is loaded |
| `wan-present` | the device named by `network.wan` exists in `/sys/class/net` |

Two notes on `fw4-present`: on this upstream `fw4` is a one-shot renderer — `fw4
start` pipes the rendered ruleset into `nft` and exits — so there is normally no
`fw4` process to find. The probe therefore passes when either the `inet fw4` table
exists or an `fw4` process is running, and it logs which one it saw. `wan-present`
also needs a `network.wan` interface, and the upstream rootfs ships no
`/etc/config/network` at all: S5 owns the production config, so the S4 harness writes
a documented fixture into the writable layer instead of the probe silently passing on
nothing.

### GRUB

`disk.sh` renders `scripts/ci/grub.cfg.in` into the ESP and refuses to build unless
all five rules from `docs/boot-overlay.md` hold. `grub-render.sh --check FILE` runs
the rules alone, which is what `tests/modules/ab/test_grub.sh` uses to prove each rule
rejects its own mutant. Rule 4 checks the code lines only: the template's header
comments mention `&&`, `||` and `${x:-y}` on purpose.

### Three boots

The stage boots one image file three times and never wipes it:

| Boot | Setup | Expected |
|---|---|---|
| 1 | fresh image, `ab.slot=a` | probes pass, `committed=a`, `pending=none` |
| 2 | slot b's `nft` broken, `pending=b`, `ab.slot=b` | probes fail, `abandon`, `committed=a`, log has `reason=healthcheck-failed` |
| 3 | slot b repaired, `pending=b`, `ab.slot=b` | probes pass, `committed=b` |

Breaking `/sbin/init` — the example in the task — would stop the kernel before `rcS`,
so `ab-commit` would never run and the abandon path would never be exercised; a broken
`nft` keeps the system bootable and fails exactly one probe. The guest never grades
itself: each boot stops on the `ab-commit` decision line and `ab-phase.sh` then reads
the ESP back and prints the frozen line:

```
S4-RESULT=ok phase=<commit|abandon> slot=<a|b>
S4-RESULT=fail reason=<token>
```

## S5: the upgrade payload and reclamation

`platform/lib/upgrade/platform.sh` implements the upstream upgrade convention for this
platform, and `platform/usr/sbin/ab-upgrade` is the user facing entry point.

| Step | What it does | What it refuses |
|---|---|---|
| `platform_upgrade_begin <payload> <slot>` | checks the target is the inactive slot, the writable layer is healthy and has 5% free | `target-is-running-slot`, `writable-layer-degraded`, `low-space-<n>pct` |
| `platform_copy_rootfs <payload> <slot>` | snapshots the running layer to `@overlay-<new version>` (or `-r<N>`), recreates the slot's `@sys` from the payload rootfs, replaces its `@platform`, copies kernel and initramfs onto the ESP | `snapshot-failed`, `rootfs-extract-failed`, `extracted-rootfs-has-no-init` |
| `platform_upgrade_end <slot> <version> <layer>` | records the layer and version through `ab-slot layer`, then marks the slot with `ab-slot pending` | `state-layer-write-failed` |

A failed copy deletes the new `@sys` and reaps the snapshot, so the target slot is left
exactly as it was. The state file is never written by this code: every mutation goes
through `ab-slot`.

`ab-upgrade <payload.tar>` validates in the documented order — manifest shape, member
digests, the btrfs module's vermagic against the payload kernel, free space, then the
conflict report — and only then touches the slot. Refusals exit **74** (the status the
update tooling treats as "refuse to write"); execution failures exit 1.

### Conflicts

`/etc` files that the payload changes *and* the user changed in the writable layer are
reported into `ab/conflicts.log` (with the documented 32 KiB truncation and
`TRUNCATED=1` marker) and never block the update. `/etc/config` is excluded: uci has
its own grammar, and the payload's uci changes arrive as idempotent
`/etc/uci-defaults/` scripts, which are counted and reported instead. `ab-slot
conflicts` reads the report back.

### Reclamation and the log ring

`ab-slot gc` keeps the layers referenced by both slots and by `pending`, never deletes
a mounted layer, deletes with `btrfs subvolume delete -C` followed by a sync, and never
balances. It runs after a successful upgrade and again early in `ab-boot` (best
effort: a failure is logged and the boot continues). Log files keep the documented
budget: `boot-0/1/2.log` rotate on every boot, `upgrade.log` and `conflicts.log` are
overwritten by the next update, and every writer truncates at 32 KiB with
`TRUNCATED=1`.

### Degraded boot

When the writable partition cannot be mounted the boot initramfs composes the root with
a tmpfs upper instead of failing: the system comes up read-only in practice, the serial
log carries `action=degraded-boot p4=degraded`, `ab-slot status` reports `p4=degraded`,
and `ab-upgrade` refuses to run.

### Four boots

| Boot | Setup | Expected |
|---|---|---|
| 1 | fresh image | `p4=ok`, probes pass, `committed=a` |
| 2 | payload in the writable layer, `/etc/rc.local` runs `ab-upgrade` | slot b gets the new layer and version, `pending=b`, conflicts reported |
| 3 | `ab.slot=b` | probes pass, `committed=b`, the orphan layer is reclaimed, only referenced layers remain |
| 4 | writable partition destroyed | degraded boot, userspace still reached |

```
S5-RESULT=ok upgrade=<slot> conflicts=<n> reclaimed=<n>
S5-RESULT=fail reason=<token>
```

Boots 1, 2 and 4 are graded on the host as well; they print
`S5-EVIDENCE=ok phase=<upgrade|degraded> ...` so the frozen judge line keeps its shape
and is only emitted once, after the commit boot has actually reclaimed.

