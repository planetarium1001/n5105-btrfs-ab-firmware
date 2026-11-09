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
| p1 | `wf-esp` | 262144 (128 MiB) | vfat |
| p2 | `wf-slot-a` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p3 | `wf-slot-b` | 262144 (128 MiB) | btrfs `-m dup -d single` |
| p4 | `wf-shared` | 131072 (64 MiB) | btrfs `-m single -d single` |

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

