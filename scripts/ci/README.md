# CI stage scripts

Every stage of the pipeline is a shell script in this directory. The workflows in
`.github/workflows/` only orchestrate: they check out the repository, run one script,
upload the results and collect diagnostics. Keeping the logic here means a stage can be
reproduced locally with the same inputs the workflow passes.

## Stage map

Five stages, in the order they run. The name is what the job is called on the run page;
the last two columns say what the stage buys you and what you lose when it fails.

| Stage | Name | What it proves | What breaks when it fails |
|---|---|---|---|
| S1 | probe | kernel loads the official btrfs module closure and mounts btrfs | no later stage can rely on btrfs in initramfs |
| S2 | image | four-partition geometry, ESP, GPT PARTNAME | nothing can be installed |
| S3 | boot | overlay root composed and switch_root reached, twice | no slot can boot |
| S4 | slots | commit, abandon, rollback and the health check, four boots | A/B switching is unproven |
| S5 | upgrade | payload upgrade, degraded boot and reclamation, four boots | updates are unproven |

## Workflows

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
| `.github/workflows/release.yml` | tag-triggered publisher, calls `ci.yml` and `release-publish.yml` |
| `.github/workflows/release-publish.yml` | reusable publisher: preflight, artifacts, `gh release`; both release lines call it |
| `.github/workflows/upstream-watch.yml` | daily watch: discover, build, move the pin and the lockfiles, merge, tag, publish |
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
| `upstream-watch.sh` | watch | decide whether a new upstream formal release exists, move the pin through `ci_write_upstream_pin`, render the automatic PR and failure-issue bodies |
| `matrix-select.sh` | watch | the candidate list of an automatic release: the new version plus the previous three formal releases, with the gap recorded |
| `heartbeat-tag.sh` | watch | keep the scheduled workflow alive with a `heartbeat-YYYYMM` tag every ≥50 days |
| `release-preflight.sh` | publish | refuse to publish unless the image record, the payload manifest, the tag and the bootloader agree |
| `verify.sh` | verify | `bash -n`/`sh -n`, ShellCheck, `python3 scripts/check_design.py all` |
| `kmods.sh` | s1 | fetch, verify and unpack the btrfs module closure against the lockfile |
| `apk_extract.py` | s1 | unpack `.ko` files out of apk-tools v3 (ADB) containers |
| `initramfs.sh` | s1, s2, s3, s4, s5 | build the initramfs for one toolset (`probe`/`boot`/`assert`) |
| `initramfs-tools.sh` | via `initramfs.sh` | stage the locked upstream programs and libraries into the initramfs |
| `apk_tools.py` | via `initramfs-tools.sh` | verify `.apk` digests, extract files, write the lockfile (`lock`) |
| `qemu-smoke.sh` | s1, s2, s3, s4, s5 | boot it under QEMU and assert the frozen judge line; `CI_QEMU_MODE=uefi-disk` boots the ESP through OVMF so GRUB, not QEMU, supplies kernel/initrd/cmdline |
| `apk-crosscheck.sh` | s1 | optional: compare the closure with what upstream `apk` installs |
| `esp-prepare.sh` | s2 | take the ESP tree (GRUB) from the upstream combined-EFI image |
| `disk.sh` | s2, s3, s4, s5 | assemble and compress the four-partition image; refuses the probe initramfs unless `CI_ALLOW_PROBE_INIT=1` |
| `image-identity.sh` | via `disk.sh` | which initramfs an image carries (`probe`/`boot`) and whether it may be built; writes `ab/image.json` onto the ESP |
| `image-verify.sh` | s2 | host-side geometry assertions and the guest expectation file |
| `grub-render.sh` | s2/s4 | render `boot/grub/grub.cfg` and assert the five GRUB rules |
| `ab-fixtures.sh` | s4 | shape the test image between boots (network, broken slot, pending) |
| `ab-phase.sh` | s4 | read the ESP back after a boot and print the frozen S4 judge line |
| `platform-runtime.sh` | s5 | resolve and stage the btrfs tooling for the platform layer |
| `elf_extract.py` | s5 (via platform-runtime.sh) | pull executables and shared objects out of apk v3 packages |
| `payload-build.sh` | s5 | build the test upgrade payload (rootfs, kernel, initramfs, platform layer, manifest) |
| `release.sh` | release | name, compress, checksum and describe the published artifacts; also renders `index.txt` when the release knows its kernel package |
| `feed-index.sh` | via `release.sh` | render the `AB-FEED 1` index a machine reads to find this release (`ab-upgrade --feed-check`) |
| `cross-upgrade.sh` | cross | boot the previous release's image, install this release's payload, grade the commit from the facts it collected |
| `s5-phase.sh` | s5 | grade an upgrade / commit / degraded boot by reading the image back |
| `stage-summary.sh` | s1, s2, s3, s4, s5 | render one stage's verdict as a fixed five-column block for the run page |
| `report.sh` | report | render the verdict and fail the run when a scheduled stage failed |
| `diagnostics.sh` | all | environment facts, disk usage and file inventories for failure triage |

## Image artifact names

An image carries one of two initramfs trees, and only one of them boots real hardware.
The names say which, so nobody has to remember:

| Artifact | Built by | Initramfs | Write it to a disk? |
| --- | --- | --- | --- |
| `image-probe` | s2 | S1 module-load probe (`initramfs/init`) | **never** - it looks for `/dev/vda` and powers off on anything else |
| `image-install` | s3 | production boot init (`initramfs/boot/init`) | yes - this is the image the release publishes |
| release `*.img.gz` | release (from `image-install`) | production boot init | yes |

The image records its own identity in `ab/image.json` on the ESP (`"kind": "boot"|"probe"`).
Three gates depend on it: `disk.sh` refuses to build a probe image without
`CI_ALLOW_PROBE_INIT=1`, `image-verify.sh` cross-checks the record against what the build
installed, and the release job re-opens the ESP, reads `ab/image.json` and greps `initrd-a`
for the production init before publishing anything.

Why this exists: v0.0.6 and v0.0.7 published s2's probe image. Every QEMU stage was green
because s3/s4/s5 each rebuild the image for themselves - no stage ever booted the published
artifact - and the first real machine shut down at the GRUB menu with
`S1-RESULT=fail reason=no-device-node`.

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

## Building a release other than the pin

`workflow_dispatch` takes an `upstream_version` input, and the same value reaches
`resolve`, `fetch`, `assemble` and S1–S5 as `CI_UPSTREAM_VERSION`. That is enough for the
pipeline to fetch a different release, but not for the three lockfiles to stay honest:
`kmod-closure.json`, `initramfs-tools.lock.json` and `runtime-closure.json` each pin the
programs of one release, and a different release ships different kernels, modules and
`btrfs-progs` by construction.

A build that names another release therefore **derives its own lockfile** under
`$CI_TMP_ROOT/locks/`, asserts against that copy and warns in the step log and on the run
page. The committed lockfiles are untouched, so a green stage for another release never
claims the pin was verified, and the pin keeps its drift contract. `CI_LOCK_STRICT=1`
turns the drift back into a hard failure for every release, which is what a bisect of the
pin itself needs.

```sh
gh workflow run ci.yml --ref main -f stage=assemble -f upstream_version=25.12.1
```

Two dispatches on the same ref cancel each other: the `concurrency` group is built from
workflow and ref only, not from `upstream_version`. A matrix of releases is therefore a
**sequential** set of runs, not a parallel one.

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

`disk.sh` builds a 514 MiB GPT image (1 MiB alignment, four 128 MiB partitions, 1 MiB
tail for the backup table) with the geometry frozen in `docs/partitions.md`:

| Partition | PARTNAME | LABEL | Sectors | Filesystem |
|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 262144 (128 MiB) | vfat |
| p2 | `ab-slot-a` | `slot-a` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p3 | `ab-slot-b` | `slot-b` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p4 | `ab-data` | `data` | 262144 (128 MiB) | btrfs `-m single -d single` |

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

`/s3-post.sh` is a CI artefact, not part of the product: it enters an initramfs only when
the build sets `AB_CI_HOOKS=1` (`vars.AB_CI_HOOKS` in `ci-assemble.yml`, and set by
`ci-s3.yml` on its assertion build alone). A production build - `kind=boot`, the flag
unset - carries an `initrd-a`/`initrd-b` without it, and `scripts/ci/image-verify.sh`
asserts that mechanically: `assert_no_ci_hooks` reads the member table of both initrds
back with `cpio -t` and fails the build on any `s3-` entry. The test and debug pipelines
(`ci-debug.yml`, `ci-s4.yml`, `ci-s5.yml`) keep injecting it unconditionally on purpose:
their images are supposed to carry the probe, and none of them publishes an install image.

```
S3-RESULT=ok slot=<a|b> upper=<@overlay-version> lower=<platform:sys> root=<overlay>
S3-RESULT=fail reason=<token>
```

The stage boots the same disk image twice (`wf.boot=1`, then `wf.boot=2`) and both
boots must pass. Those two boots load a second initramfs built with `AB_CI_HOOKS=1`
(`ci-hooks.cpio.gz`), because the image's own `initrd-a`/`initrd-b` are the production
archive and stay free of CI members; the firmware boot (the third one) runs the image's
own initrd, so the production archive is still exercised end to end. Probe markers
(`.s3-probe`, `.s3-new-<n>`, `.s3-post`) stay in the generation's upper directory, which
is what makes the second boot meaningful.

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

### The programs in the initramfs

The initramfs runs before the platform layer is mounted, so it carries its own copy of
busybox, the partition tools and their libraries. Those programs are **not** taken from
the build host: a `ubuntu-latest` runner supplies glibc binaries whose versions drift
with the runner image, and a boot path that changes because a runner was upgraded is not
reproducible. They come from the same ImmortalWrt release as the rest of the image, and
`scripts/ci/initramfs-tools.lock.json` is the contract.

| Program | Package (feed) | Why it is in the initramfs |
|---|---|---|
| `/bin/busybox` + 119 applets | `busybox-1.37.0-r6` (base) | shell, mount, sed/awk/grep, tar, switch_root — the init is a busybox shell script |
| `/lib/libc.so`, `/lib/ld-musl-x86_64.so.1` | `libc-1.2.5-r5` (target) | the one libc in here; every program below links against it |
| `/lib/libgcc_s.so.1` | `libgcc1-14.3.0-r5` (target) | busybox's DT_NEEDED |
| `/sbin/kmod` + `/sbin/insmod` | `kmod-32-r1` (packages) | the upstream busybox has no `insmod` applet; module loading needs it |
| `/usr/sbin/sfdisk` | `sfdisk-2.41.5-r1` (base) | first-boot growth: dump, rewrite, `--no-reread` |
| `/usr/sbin/blockdev` | `blockdev-2.41.5-r1` (base) | `--rereadpt` after the table is rewritten |
| `/usr/sbin/blkid` | `blkid-2.41.5-r1` (base) | label-based identity fallback on kernels without PARTNAME |
| `/usr/sbin/btrfs` | `btrfs-progs-6.11-r3` (packages) | `btrfs filesystem resize max` for the grown p4 |
| `libfdisk1`, `libblkid1`, `libuuid1`, `libsmartcols1` | `*-2.41.5-r1` (base) | the closure of the util-linux tools above |
| `libncursesw.so.6` | `libncurses6-6.4-r3` (base) | sfdisk's DT_NEEDED, measured rather than guessed |
| `libz.so.1`, `liblzo2.so.2` | `zlib-1.3.1-r1`, `liblzo2-2.10-r5` | btrfs-progs/kmod closure |

Two consequences are worth knowing before touching this:

- **busybox cannot be run on the build host.** It is a musl binary, so `busybox --list`
  would need `/lib/ld-musl-x86_64.so.1` on the runner. The applet list is therefore read
  from the applet table inside the package image (`apk_tools.py lock`) and stored in the
  lockfile; the build links exactly those names and never executes the host busybox.
- **there is no `mdev`.** The upstream busybox does not compile that applet in, so the
  initramfs takes `/dev` from devtmpfs alone (every kernel this image ships has it) and
  prints `/proc/filesystems` plus the `/dev` listing when the block device never appears.

`initramfs.sh` also refuses to finish when a glibc artifact (`ld-linux*`, `libc.so.6`,
`x86_64-linux-gnu`, `libreadline`, `libtinfo`, `libudev`) is anywhere in the tree, and
when `/lib/ld-musl-x86_64.so.1` is not the expected symlink to `libc.so`.

#### Bumping the upstream pin

The tool versions follow `CI_UPSTREAM_VERSION_PIN` in `lib.sh`; they never move on their
own. A pin bump is one deliberate step, and the lockfile diff is the record of it:

```bash
# 1. bump the pin
$EDITOR scripts/ci/lib.sh                     # CI_UPSTREAM_VERSION_PIN=25.12.3

# 2. regenerate the lockfile from the new release (network, a few MiB)
bash scripts/ci/initramfs-tools.sh --write-lock

# 3. review the diff: versions, apk digests, file digests, applet list
git diff scripts/ci/initramfs-tools.lock.json

# 4. commit both files together - a lockfile that disagrees with the pin fails the build
```

Every build then downloads exactly the packages the lockfile names, verifies the `.apk`
sha256 and the sha256 of every extracted file, and installs them at the recorded paths.
Any mismatch names the offending file and stops the stage; there is no fallback to a host
program and no "warn and continue".

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
frozen format (`probe=<name> result=<pass|fail> [reason=<token>]`). Every probe runs even
after one has failed, so a single boot names every fault; the writable layer is the root
itself, because the initramfs mounts `@overlay-<version>` as the upper and `switch_root`s
into it, and there is no separate `/overlay` mount:

| Probe | Passes when |
|---|---|
| `overlay-writable` | the composed root `/` is writable with at least 16 MiB free (an absolute floor, not a percentage) |
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

## The btrfs tooling in the platform layer

The upstream root filesystem ships no btrfs user space tooling, yet snapshot, delete,
create and list are what the slot state machine, reclamation and the degraded boot all
depend on. The tool therefore travels in the platform layer:

```
@platform/usr/sbin/btrfs            (plus a btrfsck symlink, which the multicall binary handles)
@platform/usr/lib/liblzo2.so.2
```

Putting it in `@sys` is not an option: that tree has to stay byte identical to
upstream.

`platform-runtime.sh` resolves the closure *from the binary outwards*, not from package
metadata:

1. take the newest `btrfs-progs` in `packages/x86_64/packages` of the same release,
2. unpack its ELF images (`elf_extract.py`) and pick the multicall binary — the one
   carrying the dispatcher usage string — as `usr/sbin/btrfs`,
3. read its `DT_NEEDED` and drop every soname the root filesystem already provides
   (`libblkid.so.1`, `libuuid.so.1`, `libz.so.1`, `libc.so`, `libgcc_s.so.1` are all
   there already),
4. fetch the package that supplies each remaining soname (`liblzo2.so.2` today) and
   follow its own dependencies too,
5. fail with the soname in the message when nothing in the feed provides it.

On Linux the stage then runs the result: the musl loader from the rootfs starts the
extracted `btrfs --version` against the staged libraries. A binary that cannot start
never reaches an image.

`scripts/ci/runtime-closure.json` is the contract, like the module lockfile: it pins
the package files, their digests and the exact files installed. The feed publishes no
`sha256sums` for the package repository, so the digests are recorded on first download
— that is the one place where the project trusts the mirror once and then holds it to
that. Refresh deliberately with `platform-runtime.sh --write-lock`.

Two budget assertions protect the slot space: the runtime tree must stay under
`CI_RUNTIME_LIMIT_MIB` (8 MiB) in the runtime stage, and `disk.sh` re-measures the
*unpacked* `@platform` layer and refuses the build above `CI_PLATFORM_LIMIT_BYTES`
(8 MiB). Both print the measured value.

### When the tool is missing

`ab-slot gc` prints `reason=btrfs-tool-missing` and exits non-zero instead of reporting
an empty, successful pass. `ab-boot` runs `btrfs --version` and `btrfs subvolume list /`
first, prints `ab-boot: btrfs=ok subvolume-list=ok` to `/dev/console`, and only then
starts the early reclamation; if the tool is broken the log records
`stage=btrfs-check result=fail reason=...` and reclamation is skipped with the same
reason. The S5 run gates on that console line (`s5-phase.sh --phase toolchain`), so a
platform layer without a working tool cannot pass.

## S6: payload production, conflicts and releases

### One validator

`assemble` used to publish a manifest that admitted which members were missing. It now
builds the real payload — upstream rootfs and kernel, the boot initramfs, and the
platform layer with the btrfs tooling — then unpacks the payload's own `platform.tar` and
hands the tar to *that* `usr/sbin/ab-upgrade --check`. The shipped copy is the one that
decides, so the bytes a device will unpack are the bytes that were accepted. The checker is
the only definition of a valid payload: manifest shape, member digests, one kernel build
across the initramfs modules, free space, conflict report. A payload that passes here is one the device would accept,
and there is no second copy of the rules to drift.

The stage needs a mounted writable partition because the checker asks btrfs about `p4` and
the scratch state names the writable layer it must find; it creates a 256 MiB sparse image,
formats it btrfs, mounts it and unmounts it afterwards. A tmpfs is not enough: it has no
subvolumes to name.

### Conflicts: what was wrong

The report always said `conflicts=0`. The comparison itself was right, but its baseline
was not: it looked for the running slot at `/mnt/slots/<slot>/@sys`, a path the boot
initramfs never leaves behind — it mounts the slot subvolumes for itself and those
mounts vanish at `switch_root`. The loop was therefore skipped and the count stayed
zero. `ab-upgrade` now mounts the running slot's filesystem when that path is absent,
and records `baseline=ok` or `baseline=unreadable` in the report header so a skipped
comparison can never again look like a clean one. Three directions are tested: changed
on both sides (reported, upgrade proceeds), payload only (silent), user only (silent).

`S5` now fails with `reason=conflicts-not-detected` or `reason=conflict-baseline-unreadable`
if the fixture's deliberate conflict does not show up, so the path stays covered.

### Releases

`release.sh` turns a verified build into `n5105-ab-<upstream>-install.img.gz`, the
matching `-upgrade.tar`, `SHA256SUMS`, `release-notes.md` and - when the kernel package
version is known - `index.txt`, the update feed the release page also serves. The index
is built by `feed-index.sh` from `SHA256SUMS` and the payload next to it, so the digest a
machine reads can never drift from the digest the release publishes. The firmware version is a
release counter, not part of the file name: the release page's tag already names it. The
compressed image is
decompressed again and compared with the raw image digest before it is published.

`.github/workflows/release.yml` runs on `v*` tags only, calls the ordinary pipeline
(`ci.yml` gained `workflow_call`) and grants `contents: write` to the publishing job
alone. Pushing to `main` validates and never publishes. The upstream version and the
input digests come from the payload manifest, so the notes describe exactly what CI
built.

### Why a leftover payload cannot re-run

The first S6 run reported `conflicts=0` with `payload-same=215`: every file in the
payload's `etc` was byte identical to the baseline. The baseline was right — the
*payload was already installed*. The update fixture installs `ab-upgrade` through
`/etc/rc.local`, the update snapshots the running layer, and the snapshot inherited
that `rc.local`, so the next boot ran the upgrade again from the new slot. In that run
the running slot is the slot the payload just created, so the baseline and the payload
are the same tree and the comparison is meaningless.

Two changes close it from both sides:

* `ab-upgrade` refuses a payload whose rootfs version equals the running slot's
  (`payload-already-installed`, exit 74) *before* it extracts anything or touches the
  conflict report, so a stale payload can never rewrite the healthy slot;
* the fixture's `rc.local` deletes itself before upgrading, so the snapshot cannot
  carry it forward.

The conflict report header now names the running slot and the baseline path
(`running=<slot> baseline=ok|unreadable baseline-path=<path>`) next to the existing
`scan checked=... payload-same=... upper=...` line, so a zero count always comes with
the numbers that explain it. The upgrade test suite asserts that the diagnostic line is
present.

