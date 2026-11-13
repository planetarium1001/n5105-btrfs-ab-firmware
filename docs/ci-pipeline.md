# CI pipeline

Sixteen workflow files, four entry points, five stages on every run plus a cross-version
stage that only runs on tags, and a fixed set of artifacts. Twelve of the sixteen files are
reusable (`workflow_call` only) and can never start a run; the four that can are `ci.yml`,
`ci-debug.yml`, `release.yml` and `upstream-watch.yml`. Every decision
lives in `scripts/ci/`, so a stage can be reproduced without GitHub. This page is the map:
which workflow to run, what each stage proves, which file is the one to write to a disk, and
how to run a stage on your own machine. The stage scripts are documented in
[`../scripts/ci/README.md`](../scripts/ci/README.md); the two release lines are described in
[`ci-release-lines.md`](ci-release-lines.md).

## Workflow matrix

| Workflow file | Trigger | Publishes | Artifacts | Run it when |
|---|---|---|---|---|
| `ci.yml` | push to `main`, pull request to `main`, `workflow_dispatch` (`stage`, `upstream_version`), `workflow_call` | no | none of its own: it calls the stages, which upload theirs | everyday validation, or one stage of a failed run (`-f stage=s3`) |
| `ci-resolve.yml` | `workflow_call` only | no | `logs-resolve` | never by hand: `ci.yml` calls it |
| `ci-fetch.yml` | `workflow_call` only | no | `upstream-files`, `logs-fetch` | never by hand: `ci.yml` calls it |
| `ci-assemble.yml` | `workflow_call` only | no | `payload-upgrade`, `logs-assemble` | never by hand: `ci.yml` calls it |
| `ci-verify.yml` | `workflow_call` only | no | `logs-verify` | never by hand: `ci.yml` calls it |
| `ci-s1.yml` | `workflow_call` only | no | `evidence-s1`, `logs-s1` | never by hand: `ci.yml` calls it |
| `ci-s2.yml` | `workflow_call` only | no | `evidence-s2`, `logs-s2`, `image-probe` (never write it to a disk) | never by hand: `ci.yml` calls it |
| `ci-s3.yml` | `workflow_call` only | no | `evidence-s3`, `logs-s3`, `image-install` | never by hand: `ci.yml` calls it |
| `ci-s4.yml` | `workflow_call` only | no | `evidence-s4`, `logs-s4` | never by hand: `ci.yml` calls it |
| `ci-s5.yml` | `workflow_call` only | no | `evidence-s5`, `logs-s5` | never by hand: `ci.yml` calls it |
| `ci-upgrade-cross.yml` | `workflow_call` only | no | `evidence-cross` | never by hand: `release.yml` calls it on a tag |
| `ci-report.yml` | `workflow_call` only | no | `logs-report`; the run page table and the verdict | never by hand: `ci.yml` calls it |
| `ci-debug.yml` | `workflow_dispatch` only (`stage`, `boot_timeout`) | no | `debug-session`, `debug-<stage>-logs` | an interactive upterm session on a runner, when a stage needs eyes |
| `release.yml` | push of a `v*` tag | yes, through `release-publish.yml` | the three release assets | releasing our own version: push a `v*` tag ([the tagged line](ci-release-lines.md)) |
| `release-publish.yml` | `workflow_call` only (`tag`, `tag-policy`, `title`, `dry-run`, ...) | yes, as a draft with `dry-run: true` | `n5105-ab-<upstream>-install.img.gz`, `n5105-ab-<upstream>-upgrade.tar`, `SHA256SUMS` | never by hand: `release.yml` and `upstream-watch.yml` call it |
| `upstream-watch.yml` | `schedule` (`0 20 * * *`) and `workflow_dispatch` (`version`, `dry-run`, `base`) | yes, with a bare-version tag | a release named `<upstream version>`, or one `[auto-release]` issue | the daily upstream release, or a rehearsal of it |

- **Reusable and entry point.** Twelve files declare `workflow_call` and nothing else, so
  they cannot start a run, and they declare no `concurrency` at all: a called workflow runs
  inside its caller's run, and a nested `concurrency` group silently drops the call (the job
  never appears in the graph). Two of the four entry points declare a group, `ci.yml` and
  `ci-debug.yml`; `release.yml` and `upstream-watch.yml` declare none, because both call
  `ci.yml` and would lose that call to the rule above.
- **Lanes.** Those two groups are `ci-<workflow>-<lane>-<ref>`, with the lane taken from
  `github.event_name == 'workflow_dispatch' && 'manual' || 'auto'` and `cancel-in-progress`
  true only for the automatic lane. Two manual dispatches on the same ref therefore queue
  instead of cancelling each other, and a push never cancels a dispatch. `ci-debug.yml`
  differs on purpose: it keeps the lane in its group but sets `cancel-in-progress: true` for
  both, because a second session should replace the first instead of waiting behind a
  290-minute one.
- **Timeouts.** Every job that runs steps carries `timeout-minutes`: `resolve` 10, `fetch`
  20, `assemble` 35, `verify` 30, S1 30, S2 40, S3 45, S4 and S5 75, `report` 20, the
  `versions` job in `ci.yml` 5, the debug job 290 with a 150-minute keepalive. A job that
  only calls a reusable workflow cannot set one, so `release.yml` and the `build` and
  `publish` jobs of `upstream-watch.yml` take their budget from the workflow they call.
- **Third-party actions** are pinned to a 40-character commit sha, never to a floating tag:
  what runs with the runner's credentials is what was reviewed. The step groups that repeat
  (runner setup, stage script, evidence upload, summary, QEMU boot, actionlint) are six
  composites under `.github/actions/`.

## The five stages

Each stage is one reusable workflow, and its job label is the same string in the graph
and in the job list.

| Stage | Label | What it proves | What breaks when it fails |
|---|---|---|---|
| S1 | `S1 probe - kernel mounts btrfs` | The official kernel loads the official btrfs module closure inside our initramfs and mounts btrfs | No later stage can rely on btrfs before `switch_root` |
| S2 | `S2 image - four partitions` | The four-partition geometry, the ESP contents and the GPT PARTNAMEs, read back from inside the guest | Nothing can be installed: the layout the installer writes is wrong |
| S3 | `S3 boot - layered root` | The boot initramfs composes the overlay root and reaches `switch_root`, twice in a row | No slot can boot, so the image is not installable |
| S4 | `S4 slots - A/B state machine` | Commit, abandon and rollback through four boots, including the health check | A/B switching is unproven: an update could stick to a broken slot |
| S5 | `S5 upgrade - upgrade and reclaim` | Payload upgrade, the degraded boot and reclamation, four boots | Updates are unproven, including the case where the writable partition dies |

Every stage prints one frozen judge line, and the shape of that line is a contract:
`S1-RESULT=…` through `S5-RESULT=…`. The display names may change; the tokens may not.

## Artifacts: what each one is for

| Artifact | Produced by | Contents | Use |
|---|---|---|---|
| `image-install` | S3 | `n5105-ab-<upstream>-install.img.gz` | The image to write to a disk. The release republishes these exact bytes. |
| `image-probe` | S2 | the same geometry with the S1 probe initramfs | **Never write it to a disk**: it looks for `/dev/vda` and powers off on real hardware |
| `payload-upgrade` | assemble | `payload.tar`, its manifest and the check log | What `ab-upgrade` consumes on a running machine |
| `upstream-files` | fetch | upstream rootfs, kernel and btrfs module | Inputs; kept so a run can be audited without the network |
| `evidence-s1` … `evidence-s5` | each stage | serial logs, initramfs, inventories, fixture dumps | The structured evidence a stage was graded on |
| `logs-<stage>` | each stage | the stage's own log files and the diagnostics summary | One place to look when a stage failed |
| `debug-session`, `debug-<stage>-logs` | the debug workflow | the SSH command and the boot logs of a manual session | Manual debugging only |

A released file is named `n5105-ab-<upstream>-install.img.gz` or
`n5105-ab-<upstream>-upgrade.tar`: board, product line, upstream base, role. Our own
release counter is not in the name - the GitHub release it is attached to already
carries it. `release-notes.md` is written next to the assets and becomes the release body,
which is why the release has three assets and four files.

## Reading a run page

- Each stage job ends with a **stage summary**: one table with `stage`, `verdict`,
  `key line`, `artifact and sha256` and `next command`. That is the whole answer for
  that stage; the log is for the detail.
- The **report** job renders one table across the pipeline: `stage`, `verdict`,
  `duration`, `artifact`, followed by the judge lines inside a collapsed block. The
  duration is read from the Actions API, so it is the real job wall-clock time.
- A failing run repeats the important part in its first line: which stage failed and
  the command that shows why.

## Reproducing a CI run locally

The stage scripts read environment variables and write their scratch files under
`$CI_TMP_ROOT`. `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY` are optional, `CI_OUTPUT_ENV`
turns a stage's outputs into a `KEY=VALUE` file the next stage loads, and nothing needs a
GitHub client. That is why part of the pipeline runs on a laptop and the rest needs Linux.

### Resolve the version only

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
```

It prints `[resolve] upstream version 25.12.2 (source: pin)` and
`[resolve] cache key upstream-25.12.2-<hash>`, and writes the fourteen
`KEY=VALUE` lines every later stage needs into `$CI_TMP_ROOT/resolve.env`. It needs the
network: it downloads the release's `sha256sums` and its package manifest. The hash is not a
constant to quote: it covers the resolved digests, the tool versions and the content of every
`scripts/ci/*.sh` and `.github/workflows/*.yml`, so it changes whenever those do.

`CI_UPSTREAM_VERSION` names another release, `latest` resolves the newest one on the mirror,
and `CI_UPSTREAM_VERSION_PIN` bypasses the pin file; with none of them set, the pin decides.

### Resolve, then download the upstream files

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh
```

`fetch.sh` loads the resolve outputs itself, verifies every file against its digest and
leaves `rootfs.tar.gz`, `kernel.bin` and the btrfs module in `$CI_TMP_ROOT/fetch/upstream`.

Assembling the payload needs four inputs that resolve and fetch do not produce, and it
stops at the first one that is missing:

| Variable | Comes from |
|---|---|
| `CI_PLATFORM_VERSION` | `tr -d '[:space:]' < VERSION`; there is no default on purpose |
| `CI_INITRAMFS` | `bash scripts/ci/initramfs.sh` |
| `CI_PLATFORM_RUNTIME_DIR` | `bash scripts/ci/platform-runtime.sh` |
| `CI_BOOT_SRC` | `bash scripts/ci/esp-prepare.sh` (default `$CI_TMP_ROOT/esp`) |

`assemble.sh` also exports `CI_REQUIRE_BOOTLOADER=1` itself: a payload that cannot bring the
bootloader forward is a failed build, not a warning. It reads `CI_UPSTREAM_VERSION` and
`CI_KERNEL_PACKAGE` as well, and unlike `fetch.sh` it does not load `resolve.env` on its own,
so a local run passes them in:

```sh
CI_UPSTREAM_VERSION="$(sed -n 's/^upstream_version=//p' "$CI_TMP_ROOT/resolve.env")" \
  CI_KERNEL_PACKAGE="$(sed -n 's/^kernel_package=//p' "$CI_TMP_ROOT/resolve.env")" \
  bash scripts/ci/assemble.sh
```

### Reproduce a QEMU stage

The QEMU stages read `CI_QEMU_MODE` (`kernel`, `uefi` or `uefi-disk`), `CI_QEMU_TIMEOUT` and
`CI_JUDGE_PREFIX`, plus the files the earlier stages wrote with their default names:

```sh
export CI_TMP_ROOT=/tmp/ci
CI_QEMU_MODE=uefi-disk CI_QEMU_TIMEOUT=900 CI_JUDGE_PREFIX=S3-RESULT \
  CI_KERNEL="$CI_TMP_ROOT/fetch/upstream/kernel.bin" \
  CI_INITRAMFS="$CI_TMP_ROOT/initramfs/initramfs.cpio.gz" \
  CI_QEMU_DISK="$CI_TMP_ROOT/disk/n5105-ab-image.img" \
  bash scripts/ci/qemu-smoke.sh
```

Every stage script opens with an `Inputs (environment)` comment listing what it reads and an
`Outputs` line naming what it publishes, and
[`../scripts/ci/README.md`](../scripts/ci/README.md) has the same list one level up. Read the
header of the script you are about to run; that is the authoritative list for that stage.

### One stage on the runner instead

```sh
gh workflow run ci.yml --ref main -f stage=s3 -f upstream_version=25.12.2
```

`stage` accepts `all`, `fetch`, `assemble`, `s1`, `s2`, `s3`, `s4`, `s5` and `verify`, and
`upstream_version` may be left out to use the pin. The run keeps the other jobs in the graph
as skipped, so the stage is graded by the same scripts with the same inputs as a full run,
on a machine that has QEMU.

### What a laptop can and cannot run

| Piece | On macOS | Why |
|---|---|---|
| `bash scripts/ci/resolve.sh` | works | `curl` and the shell; `lib.sh` falls back to `shasum -a 256` when `sha256sum` is absent |
| `bash scripts/ci/fetch.sh` | works | same tools, plus network |
| `bash scripts/ci/assemble.sh` | no | needs the initramfs, the staged btrfs tooling and an ESP tree, i.e. the Linux stages below |
| `bash scripts/ci/verify.sh` | no | reports `actionlint: fail` and `shellcheck: fail`, because a missing linter is a stage failure by design |
| `python3 scripts/check_design.py all` | works | the same checks `verify.sh` runs, without the linters |
| `./tests/run.sh --module ci` | works | the CI test module |
| S1 to S5, `disk.sh`, `qemu-smoke.sh` | no | `ci_require_cmd` wants `qemu-system-x86_64`, `losetup`, `sfdisk`, `mkfs.vfat`, `mkfs.btrfs`, `chattr`, `blkid` and `timeout`; none of them exist on macOS |

### Common failures

| Symptom | Usually means | What to do |
|---|---|---|
| `[ci] WARNING: ignoring invalid upstream pin in .github/upstream-pin.conf: …`, then `upstream version 25.12.2 (source: pin)` | the pin line is not `X.Y.Z`, so `ci_upstream_pin_read` fell back to the built-in `CI_UPSTREAM_PIN_DEFAULT` and the run builds a release nobody pinned | leave exactly one `UPSTREAM_VERSION=X.Y.Z` line in `.github/upstream-pin.conf`; that is also the only form `ci_write_upstream_pin` writes |
| `[resolve] ERROR: invalid upstream version: '25.13' does not match ^[0-9]+\.[0-9]+\.[0-9]+$` | an explicit `CI_UPSTREAM_VERSION` (or `-f upstream_version=`) is not a formal release | name a formal `X.Y.Z` release, or pass `latest`, or pass nothing to use the pin |
| no error, but the scratch files appeared under `/tmp/ci` instead of your directory | `CI_TMP_ROOT` was never exported; `ci_stage_init` falls back to `${RUNNER_TEMP:-/tmp}/ci` | `export CI_TMP_ROOT=/tmp/ci` before the first script, so every stage shares one tree |
| `no boot source at … and CI_REQUIRE_BOOTLOADER=1: a payload without the bootloader cannot bring one forward` | the payload stage found no ESP tree to take GRUB from, and `assemble.sh` exports `CI_REQUIRE_BOOTLOADER=1` for exactly that case | run `bash scripts/ci/esp-prepare.sh` first (it writes `$CI_TMP_ROOT/esp`), or point `CI_BOOT_SRC` at a tree that carries the GRUB EFI loader |
| `CI_LOCK_STRICT=1: asserting the pinned lockfile (25.12.2) for the 25.13.0 build`, then a `mirror publishes …, lockfile pins …` failure | you asked for a release the committed lockfiles do not describe with the pin contract switched on | drop `CI_LOCK_STRICT` for a one-off build (it derives its own lockfile under `$CI_TMP_ROOT/locks/`), or refresh the lockfiles with `--write-lock` and review the diff |
| `actionlint: fail` and `shellcheck: fail` next to `design: ok` and `python: ok` | the two linters are not on `PATH`; the stage treats that as a failure, never as a skip | `brew install shellcheck actionlint`, or set `CI_ACTIONLINT_BIN` to an actionlint binary; for documents alone use `python3 scripts/check_design.py all` |
| a real machine powers off at the GRUB menu and the serial log ends with `S1-RESULT=fail reason=no-device-node` | the image written to the disk was `image-probe`, S2's fixture, which looks for `/dev/vda` | write `image-install` (S3) or the release asset `n5105-ab-<upstream>-install.img.gz` |

## Building a release other than the pin

The manual entry point takes an `upstream_version` input, and the pipeline fetches that
release end to end. The three lockfiles (`kmod-closure.json`,
`initramfs-tools.lock.json`, `runtime-closure.json`) pin one release's programs, so a
build for another release derives its own copy under `$CI_TMP_ROOT/locks/`, asserts
against it and warns on the run page. The committed lockfiles stay the contract for the
pin; `CI_LOCK_STRICT=1` restores the hard failure for every release.

Two dispatches on the same ref do not cancel each other: the concurrency group carries a
lane segment, so manual runs queue and only an automatic run cancels the automatic run it
replaces. A matrix of releases is a sequential set of runs.

The driver that uses those builds on a real machine is described in
[`device-matrix.md`](device-matrix.md). How a release is actually published - the tagged
line and the automatic upstream line - is in [`ci-release-lines.md`](ci-release-lines.md).

## When a stage fails

1. Read the report's first line: it names the stage.
2. Open that stage's summary block: `key line` is the judge line that decided, and
   `artifact and sha256` says what to download.
3. The `next command` is either `gh run view <run> --log-failed` or the local
   reproduction (`bash scripts/ci/qemu-smoke.sh`, `bash scripts/ci/disk.sh`,
   `bash scripts/ci/s5-phase.sh`). Locally the stages need no GitHub tooling; the
   variables they read and the parts a laptop cannot run are listed above, under
   Reproducing a CI run locally.
4. Only then open the log, `logs-<stage>` if it went missing.

## Naming rules

- One separator: ` - ` (space hyphen space). No parentheses, colons or middots in a
  workflow, job or step name.
- A stage is `S<n> <semantic>` (`S2 image`); the job adds what it proves
  (`S2 image - four partitions`).
- Step names are imperative and carry no stage number: the job above them already says
  which stage they belong to.
- A step that does not gate the stage says so with ` - advisory`.

Those rules are the short form of [`ci-text-contract.md`](ci-text-contract.md), which is also
where the length caps, the fixed table headers, the title templates and the structure
fingerprint live. That page is asserted by `tests/modules/ci/test_ci_text_conventions.sh`;
this one is the map.

## The cross-version stage

One stage answers a different question from the five above: not "is this release sound"
but "does this release install over the previous one". It runs on tags only.

| Stage | Job label | What it proves |
| --- | --- | --- |
| cross | `cross-upgrade` | An image built from the previous formal release, upgraded with this release's payload, boots, commits, and carries exactly the kernel and initrd the payload shipped |

It is expensive - it builds a second image from another upstream release - so the PR
chain never runs it. The selector (`matrix-select.sh`) names the previous release; when it
cannot (`gaps>0`), the stage reports `cross-upgrade=skipped` and the run is not green:
a skipped proof is not a passed proof.

`scripts/ci/cross-upgrade.sh assert --out <dir>` grades a run from five files - the status
lines before, during and after, the ESP digests, the payload digests and the serial log -
so the verdict can be re-checked without re-running QEMU.

## Where the logic lives

`.github/workflows/` only orchestrates: check out, run one script, upload, collect
diagnostics. Every decision lives in `scripts/ci/`, which means a stage can be
reproduced locally with the same inputs the workflow passes. The two rendering helpers -
`stage-summary.sh` and `report.sh` - are the only CI files that may change a label
without changing a verdict.
