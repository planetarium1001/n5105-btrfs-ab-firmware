# CI pipeline

The pipeline is three separate GitHub workflows, five stages and a fixed set of
artifacts. This page is the map: which workflow runs when, what each stage proves, and
which file is the one to write to a disk. The stage scripts themselves are documented in
[`../scripts/ci/README.md`](../scripts/ci/README.md).

## The three entry points

| Workflow | Trigger | What it does |
|---|---|---|
| `Firmware CI - build and validate` | push to `main`, pull request, manual | Runs the five stages and the static checks, then reports one verdict. Produces `image-install`. |
| `Firmware CI - release` | tag `v*` | Calls the validation workflow, re-opens the image it produced, refuses anything that is not bootable, and publishes the release. Never runs on a branch. |
| `Firmware CI - debug session` | manual only | Prepares the same image and hands the runner to an interactive SSH session. Grades nothing, publishes nothing but a short-lived log artifact. |

The names share a prefix on purpose: in the Actions list the three sort next to each
other, so "which one validates, which one releases, which one is for debugging" is
answered without opening anything.

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
carries it.

## Reading a run page

- Each stage job ends with a **stage summary**: one table with `stage`, `verdict`,
  `key line`, `artifact and sha256` and `next command`. That is the whole answer for
  that stage; the log is for the detail.
- The **report** job renders one table across the pipeline: `stage`, `verdict`,
  `duration`, `artifact`, followed by the judge lines inside a collapsed block. The
  duration is read from the Actions API, so it is the real job wall-clock time.
- A failing run repeats the important part in its first line: which stage failed and
  the command that shows why.

## When a stage fails

1. Read the report's first line: it names the stage.
2. Open that stage's summary block: `key line` is the judge line that decided, and
   `artifact and sha256` says what to download.
3. The `next command` is either `gh run view <run> --log-failed` or the local
   reproduction (`bash scripts/ci/qemu-smoke.sh`, `bash scripts/ci/disk.sh`,
   `bash scripts/ci/s5-phase.sh`). Locally the stages need no GitHub tooling; see
   [`../scripts/ci/README.md`](../scripts/ci/README.md) for the environment they read.
4. Only then open the log, `logs-<stage>` if it went missing.

## Naming rules

- One separator: ` - ` (space hyphen space). No parentheses, colons or middots in a
  workflow, job or step name.
- A stage is `S<n> <semantic>` (`S2 image`); the job adds what it proves
  (`S2 image - four partitions`).
- Step names are imperative and carry no stage number: the job above them already says
  which stage they belong to.
- A step that does not gate the stage says so with ` - advisory`.

## Where the logic lives

`.github/workflows/` only orchestrates: check out, run one script, upload, collect
diagnostics. Every decision lives in `scripts/ci/`, which means a stage can be
reproduced locally with the same inputs the workflow passes. The two rendering helpers -
`stage-summary.sh` and `report.sh` - are the only CI files that may change a label
without changing a verdict.
