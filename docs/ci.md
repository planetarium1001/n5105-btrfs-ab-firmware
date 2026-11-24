# CI

**English** | [简体中文](ci.zh-CN.md)

The pipeline builds, boots and grades the firmware on GitHub Actions, and everything it decides
is reproducible on a Linux machine without GitHub. This page is the map: which file to run,
what each stage proves, what a release has to prove, and what the CI is allowed to say to a
human.

Read [`../scripts/ci/README.md`](../scripts/ci/README.md) for the stage scripts themselves and
[device-matrix.md](device-matrix.md) for the driver that exercises a real machine.

## Workflow files and entry points

Seventeen files under `.github/workflows/`. Four can start a run; the other thirteen declare
`workflow_call` only, so they cannot.

| Workflow file | Trigger | Artifacts | Run it when |
|---|---|---|---|
| `ci.yml` | push or pull request to `main`, `workflow_dispatch` (`stage`, `upstream_version`), `workflow_call` | none of its own: it calls the stages | everyday validation, or one stage of a failed run (`-f stage=s3`) |
| `ci-debug.yml` | `workflow_dispatch` only (`stage`, `boot_timeout`) | `debug-session`, `debug-<stage>-logs` | an interactive SSH session on a runner, when a stage needs eyes |
| `release.yml` | push of a `v*` tag | the release assets | releasing this project's own version |
| `upstream-watch.yml` | `schedule` (`0 16 * * *`) and `workflow_dispatch` (`version`, `dry-run`, `base`, `resume`) | a release named after the upstream version, or one `[auto-release]` issue | the daily upstream release, or a rehearsal of it |

The schedule is `0 16 * * *`: UTC 16:00, which is Beijing midnight. The offset is written into
the cron and there is no `timezone:` field, because the actionlint this repository pins is not
guaranteed to know the newer key. GitHub's `schedule` trigger is best-effort and measured delays
were 3.5 to 4.8 hours, so nothing downstream depends on the hour a run starts.

The thirteen reusable files are `ci-resolve.yml`, `ci-fetch.yml`, `ci-assemble.yml`,
`ci-verify.yml`, `ci-s1.yml` through `ci-s5.yml`, `ci-upgrade-cross.yml`, `ci-report.yml`,
`ci-upgrade-gates.yml` and `release-publish.yml`.

- **Concurrency.** Only `ci.yml` and `ci-debug.yml` declare a group, because a called workflow
  runs inside its caller's run and a nested group silently drops the call.
- The group is `ci-<workflow>-<lane>-<ref>`, with the lane from `workflow_dispatch`, and
  `cancel-in-progress` is true only for the automatic lane: two manual dispatches queue instead
  of cancelling each other.
- `ci-debug.yml` cancels in both lanes, because a second session should replace the first
  instead of waiting behind it.
- **Timeouts.** Every job that runs steps carries `timeout-minutes`: resolve 10, fetch 20,
  assemble 35, verify 30, S1 30, S2 40, S3 45, S4 and S5 75, report 20.
- The debug job gets 290 minutes, with a 150-minute keep-alive.
- **Pinning.** Every third-party action is pinned to a 40-character commit sha, never to a
  floating tag: what runs with the runner's credentials is what was reviewed.
- Six composite actions under `.github/actions/` carry the repeated step groups.

## The five stages

Each stage is one reusable workflow, and its job label is the same string in the graph and in
the job list.

| Stage | Label | What it proves | What breaks when it fails |
|---|---|---|---|
| S1 | `S1 Probe - Kernel Mounts Btrfs` | the official kernel loads the official btrfs module closure inside our initramfs and mounts btrfs | no later stage can rely on btrfs before `switch_root` |
| S2 | `S2 Image - Four Partitions` | the four-partition geometry, the ESP contents and the GPT PARTNAMEs, read back inside the guest | nothing can be installed: the layout the installer writes is wrong |
| S3 | `S3 Boot - Layered Root` | the boot initramfs composes the overlay root and reaches `switch_root`, twice in a row | no slot can boot, so the image is not installable |
| S4 | `S4 Slots - A/B State Machine` | commit, abandon and rollback through four boots, including the health check | A/B switching is unproven: an update could stick to a broken slot |
| S5 | `S5 Upgrade - Upgrade and Reclaim` | payload upgrade, the degraded boot and reclamation, four boots | updates are unproven, including the case where the writable partition dies |

Every stage prints one frozen judge line, `S1-RESULT=` through `S5-RESULT=`. The label above is
fixed text and follows rule 4; the token behind it is frozen, so a rename may never reach it.

## The cross-version stage

One stage answers a different question: not "is this release sound" but "does this release
install over the previous one". It runs on the tagged line only; the upstream line does not run
it.

| Stage | Job label | What it proves |
|---|---|---|
| cross | `Cross-Upgrade` | an image built from the previous formal release, upgraded with this release's payload, boots, commits, and carries exactly the kernel and initrd the payload shipped |

It is expensive - it builds a second image from another upstream release - so the pull-request
chain never runs it. The selector (`matrix-select.sh`) names the previous release. When it
cannot (`gaps>0`), the stage reports `cross-upgrade=skipped` and the run is not green: a skipped
proof is not a passed proof.

`scripts/ci/cross-upgrade.sh assert --out <dir>` re-grades a run from five files, without
re-running QEMU: the status lines before, during and after, the ESP digests, the payload digests
and the serial log.

## Upgrade gates

A release has to prove two different upgrades. `ci-upgrade-gates.yml` offers both, so a caller
names a mode instead of a file:

| Mode | Proves | Ceiling |
|---|---|---|
| `cross` | release N installs over release N-1, whatever base each pinned | 35 min on the grading job |
| `same-base` | release N installs over release N-1 with the same base and kernel: the previous release's own published image, this run's payload | 25 min |

The same-base mode keeps the tag and the digest together, because two releases can publish an
asset with the same name. `scripts/ci/release-same-base.sh` is that contract:

- `select` answers which tag, asset and digest.
- `fetch` refuses bytes that do not hash to the digest the tag's own `SHA256SUMS` lists.
- `judge` grades four criteria from files alone.

Where the gates run:

| Caller | Jobs | Publish gate |
|---|---|---|
| `release.yml` (a `v*` tag) | `build`, `cross`, `same-base`, `publish` | `publish: needs: [build, cross, same-base]` |
| `upstream-watch.yml` (the daily watch) | `detect`, `bump`, `build`, `locks`, `merge`, `publish` | `publish: needs: [detect, merge]` |

A skipped gate is not a passed gate. Both modes fail on a missing previous release, a missing
QEMU, a missing `SHA256SUMS` or a `skip` file left by the stage.

An unrecognised `mode` fails in the `guard` job rather than skipping both gates.
`needs: [build, cross]` alone is half of what a release proves: it does not prove the same-base
claim the update prompt makes. That is why the publish gate names both modes.

## Artifacts

| Artifact | Produced by | Contents | Use |
|---|---|---|---|
| `image-install` | S3 | `n5105-ab-<upstream>-install.img.gz` | the image to write to a disk; the release republishes these exact bytes |
| `image-install-wan-ssh` | S3, variant job | the same image with the WAN SSH rule | the convenience image; see [install.md](install.md) |
| `image-probe` | S2 | the same geometry with the probe initramfs | **never write it to a disk**: it looks for `/dev/vda` and powers off on real hardware |
| `payload-upgrade` | assemble | `payload.tar`, its manifest and the check log | what `ab-upgrade` consumes |
| `upstream-files` | fetch | upstream rootfs, kernel and btrfs module | inputs; kept so a run can be audited without the network |
| `evidence-s1` … `evidence-s5`, `evidence-cross` | each stage | serial logs, initramfs, inventories, fixture dumps | the structured evidence a stage was graded on |
| `logs-<stage>` | each stage | the stage's log files and the diagnostics summary | one place to look when a stage failed |

A released file is named `n5105-ab-<upstream>-install.img.gz` or
`n5105-ab-<upstream>-upgrade.tar`: board, product line, upstream base, role.

This project's own release counter is not in the name; the GitHub release it is attached to
carries it. `release-notes.md` is written next to the assets and becomes the release body. That
is why a release has three assets and four files.

## Reading a run page

- Each stage job ends with a **stage summary**: one table with `stage`, `verdict`, `key line`,
  `artifact and sha256` and `next command`. That is the whole answer for that stage; the log is
  for the detail.
- The **report** job renders one table across the pipeline: `stage`, `verdict`, `duration`,
  `artifact`, followed by the judge lines. The duration comes from the Actions API, so it is
  the real job wall-clock time.
- A failing run repeats the important part in its first line: which stage failed and the
  command that shows why.

To work a failure: read the report's first line, open that stage's summary block, follow its
`next command` (either `gh run view <run> --log-failed` or the local reproduction), and only
then open `logs-<stage>`.

## Reproducing a stage locally

The stage scripts read environment variables and write their scratch files under
`$CI_TMP_ROOT`. `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY` are optional, `CI_OUTPUT_ENV` turns a
stage's outputs into a `KEY=VALUE` file the next stage loads, and nothing needs a GitHub client.

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"

# resolve the upstream version, then fetch its files
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh

# assemble a payload; four inputs have no default on purpose
CI_PLATFORM_VERSION="$(tr -d '[:space:]' < VERSION)" \
  CI_INITRAMFS="$(bash scripts/ci/initramfs.sh)" \
  CI_PLATFORM_RUNTIME_DIR="$(bash scripts/ci/platform-runtime.sh)" \
  CI_BOOT_SRC="$(bash scripts/ci/esp-prepare.sh)" \
  bash scripts/ci/assemble.sh
```

`resolve.sh` needs the network: it downloads the release's `sha256sums` and package manifest.
Its cache key covers the resolved digests, the tool versions and the content of every
`scripts/ci/*.sh` and `.github/workflows/*.yml`, so the key changes whenever those files do.

`CI_UPSTREAM_VERSION` names another release, `latest` resolves the newest one on the mirror, and
with neither set the pin decides.

A QEMU stage takes `CI_QEMU_MODE` (`kernel`, `uefi`, `uefi-disk`), `CI_QEMU_TIMEOUT`,
`CI_JUDGE_PREFIX` and the files the earlier stages wrote:

```sh
CI_QEMU_MODE=uefi-disk CI_QEMU_TIMEOUT=900 CI_JUDGE_PREFIX=S3-RESULT \
  CI_KERNEL="$CI_TMP_ROOT/fetch/upstream/kernel.bin" \
  CI_INITRAMFS="$CI_TMP_ROOT/initramfs/initramfs.cpio.gz" \
  CI_QEMU_DISK="$CI_TMP_ROOT/disk/n5105-ab-image.img" \
  bash scripts/ci/qemu-smoke.sh
```

To run one stage on a runner instead:

```sh
gh workflow run ci.yml --ref main -f stage=s3 -f upstream_version=25.12.2
```

`stage` accepts `all`, `fetch`, `assemble`, `s1`, `s2`, `s3`, `s4`, `s5` and `verify`; the other
jobs stay in the graph as skipped, so the stage is graded by the same scripts with the same
inputs as a full run.

| Piece | On a Linux host | On macOS | Why |
|---|---|---|---|
| `resolve.sh`, `fetch.sh` | works | works | shell and `curl`; `lib.sh` falls back to `shasum -a 256` |
| `assemble.sh`, `verify.sh` | works | no | needs the initramfs, the staged btrfs tooling and an ESP tree; the linters are stage failures by design |
| S1 to S5, `disk.sh`, `qemu-smoke.sh` | works | no | needs `qemu-system-x86_64`, `losetup`, `sfdisk`, `mkfs.vfat`, `mkfs.btrfs`, `chattr`, `blkid` and `timeout` |
| `python3 scripts/check_design.py all`, `./tests/run.sh` | works | works | the same checks `verify.sh` runs, without the linters |

Common failures:

| Symptom | Usually means | What to do |
|---|---|---|
| `WARNING: ignoring invalid upstream pin …` | the pin line is not `X.Y.Z`, so the built-in default was used | leave exactly one `UPSTREAM_VERSION=X.Y.Z` line in `.github/upstream-pin.conf` |
| `invalid upstream version: '25.13' does not match ^[0-9]+\.[0-9]+\.[0-9]+$` | an explicit version is not a formal release | name a formal `X.Y.Z` release, pass `latest`, or pass nothing to use the pin |
| scratch files under `/tmp/ci` instead of your directory | `CI_TMP_ROOT` was never exported | `export CI_TMP_ROOT=/tmp/ci` before the first script |
| `no boot source at … and CI_REQUIRE_BOOTLOADER=1` | the payload stage found no ESP tree to take GRUB from | run `bash scripts/ci/esp-prepare.sh` first, or point `CI_BOOT_SRC` at a tree carrying the loader |
| `actionlint: fail` and `shellcheck: fail` next to `design: ok` | the linters are not on `PATH`; a missing linter is a stage failure | install both, or set `CI_ACTIONLINT_BIN`; for documents alone use `python3 scripts/check_design.py all` |
| a real machine powers off at the GRUB menu, serial log ends `S1-RESULT=fail reason=no-device-node` | the disk was written with `image-probe` | write `image-install` or the release asset |

Building a release other than the pin works: the pipeline derives its own copies of the three
lockfiles under `$CI_TMP_ROOT/locks/`, asserts against them and warns on the run page.
`CI_LOCK_STRICT=1` restores the hard failure for every release.

## Release lines

A release leaves this repository along one of two lines. The **tagged line** releases this
project's own version: push a `v0.0.9` tag and a release appears. The **upstream line** releases
a new ImmortalWrt base: the daily watch finds a new formal upstream release, builds it, moves
the pin, merges and publishes under the bare upstream version (`25.13.0`).

| | Tagged line | Upstream line |
|---|---|---|
| Trigger | push of a `v*` tag (`release.yml`) | `schedule` (`0 16 * * *`), or `workflow_dispatch` of `upstream-watch.yml` |
| Tag shape | `v<X.Y.Z>`, or `v<X.Y.Z>-rc.<N>` for a preview | bare `<X.Y.Z>` |
| `VERSION` | the tag must equal it | not edited by the release; it still carries the platform version the image records |
| Which upstream is built | the pin in `.github/upstream-pin.conf` | the release `detect` just found, passed as `upstream_version` |
| Release title | `N5105 AB Firmware <tag>` | `ImmortalWrt N5105 AB Firmware <tag>` |
| Assets | install image, convenience image, payload, `SHA256SUMS` | install image, payload, `SHA256SUMS` |
| Where a failure lands | the run on the tag goes red, nothing is published, the tag stays | one issue titled `[auto-release] <version>`, labelled `auto-release` |

Both lines call `release-publish.yml`, which runs `scripts/ci/release-preflight.sh` before
anything is created. Two callers and one implementation is what keeps the lines from drifting.

A preview is an ordinary release with a pre-release suffix on the tag, `v0.1.0-rc.1`, and
`VERSION` equal to the same string without the `v`. The suffix is the only thing that makes it
a preview: the run publishes it as a GitHub pre-release, so `latest` keeps pointing at the last
full release and an updater reading `latest` never installs a release candidate.

The convenience image differs from the default in one rendered value, `NET_WAN_SSH`. It decides
whether the firewall gets one `allow_ssh_wan` rule (`22/tcp`) on the WAN side. The kernel,
rootfs, platform layer and payload are the same bytes in both.

`scripts/ci/release.sh` appends `-wan-ssh` to the name, so a downloads page can never offer the
open variant under the closed name. The variant job runs `boots: false`: the boot assertions
are proved once, on the shipped default.

`dry-run: true` is the publisher's rehearsal switch: every step runs, the bytes are uploaded
and checked, and the release is created as a **draft**. On the upstream line a rehearsal also
skips the merge and the tag, so it cannot move a branch.

## What a tag has to prove

The preflight mounts the image, proves the initrd inside it is the production one, and runs the
checks below - all before `gh release create`; a refusal is a non-zero exit, not a warning.

Both policies:

- `ab/image.json` says `"kind": "boot"` - a probe image is refused;
- the published initrd prints `S3 boot init` and contains no `S1-RESULT`;
- the payload manifest is `ab-payload/1` and names a `rootfs` version;
- the payload tar carries every member at the recorded sha256;
- the payload carries `boot.tar` with a `grub.cfg` and a GRUB core: an image nothing can
  update is not a release.

`--tag-policy v` additionally asserts the tag matches `^v[0-9]+\.[0-9]+\.[0-9]+$`, that the
platform version equals the tag without its `v`, that `ab/image.json` records that same
platform version, and that its `upstream_version` equals the payload manifest's `rootfs`.

`--tag-policy bare` additionally asserts the tag matches `^[0-9]+\.[0-9]+\.[0-9]+$`, that the
image's `upstream_version` equals the tag, that the manifest's `rootfs` equals the tag, and that
the shipped `VERSION` still carries the platform version. The upstream line swaps the base and
leaves this project's version alone.

Every disagreement is reported in one pass as `release-preflight: <reason>` lines.

## The daily upstream watch

`upstream-watch.yml` is one run graph, because a commit or tag pushed with `GITHUB_TOKEN` starts
no workflow of its own.

The schedule is `0 16 * * *`: UTC 16:00, which is Beijing midnight. GitHub's `schedule` trigger
is best-effort and measured delays were 3.5 to 4.8 hours, so nothing downstream depends on the
hour a run starts.

| Outcome | The graph | How it reads |
|---|---|---|
| a new release | `detect` -> `bump` -> `build` -> `locks` -> `merge` -> `publish` -> `audit` | green run, a bare `<X.Y.Z>` tag and a release exist afterwards |
| nothing new | `detect` + `keepalive` | green run, every other job `skipped`, no branch, tag or release was created |
| failure | any job fails or is cancelled | red run, and one issue titled `[auto-release] <version>` |

Only one shape is a green quiet run: the index offered a formal release and the pin already
names it. A broken mirror that parses to no formal release fails `detect` instead of looking
quiet, and so does a pin newer than the newest formal release.

The jobs:

- `detect` finds the newest formal release and compares it with the pin.
- `keepalive` writes the monthly line described below.
- `bump` edits only `.github/upstream-pin.conf` on `auto/upstream-<version>` and opens or
  updates a pull request.
- `build` calls `ci.yml` with the new version.
- `locks` derives the three lockfiles and asserts them.
- `merge` guards the diff (exactly four files), squash-merges and pushes an annotated bare tag.
- `publish` calls `release-publish.yml` with `tag-policy: bare`.
- `audit` writes the `upstream` and `release` rows of the automation log.

Commands for the three questions:

```sh
gh run list --workflow upstream-watch.yml --limit 5
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
gh issue list --label auto-release --state open
```

A quiet day also answers "is the watch still alive". GitHub disables a scheduled workflow in a
public repository after 60 days without repository activity, so the keepalive is the activity
that keeps the schedule on:

- It appends one line to `.github/keepalive.log`:
  `<UTC ISO8601> keepalive last_commit=<sha> days_since=<n>`.
- The baseline is the last commit on the default branch, so any push already counts as activity.
- A line is written only when that baseline is at least 25 days old
  (`CI_KEEPALIVE_INTERVAL_DAYS`); below that the script answers `action=skipped` and writes
  nothing.
- The job commits the line and pushes it to the default branch, with a bounded rebase-and-retry
  when the branch moved.
- Re-running on the same day, or against the same commit, is a no-op.

That is the strongest in-repo signal, and it is not a guarantee. GitHub has no official
definition of how a bot commit counts against the 60-day rule, and branch protection on `main`
would reject the push and turn the run red. An external cron is what makes the schedule certain;
the keepalive only makes it likely.

Preconditions: the repository is public (or the schedule is disabled after 60 days without
activity); the default `GITHUB_TOKEN` may write; `main` requires no status check that a
token-created pull request could never satisfy, because such a push starts no workflow.

The `keepalive` and both `audit` jobs push to `main` directly, so a branch protection rule that
requires pull requests needs an explicit bypass for them. The alternative is to turn those two
jobs into pull requests, which trades the record's immediacy for a review.

All three can run at once. Each retries a rejected push three times by rebasing, none
coordinates with the others, and no two of them write the same row: the worst case is one red
job, never lost data.

Cost: a quiet run is one `detect` job of seconds plus the `keepalive` job, which adds a commit
about once a month. A new release pays the five-stage build (measured 18 minutes end to end)
plus `locks`, `merge`, `publish` and `audit`. The watch runs neither upgrade gate, so a green
watch proves the build and the merge, not that the release installs over the previous one.

## The automation log

`.github/automation-log.md` records what the automation did, in a form a human reads without
opening a run. It is tracked, and its header is fixed: `| time | event | detail | result | link |`.

Four events:

- `upstream` - the daily watch detected a new upstream release and built it.
- `release` - that build was published as a release.
- `platform` - a push to `main` changed `platform/`, `initramfs/`, `VERSION` or the upstream pin.
- `failure` - a stage of the automatic release failed. The script supports the event, but no
  workflow calls it yet: the row is reserved for the auto-release failure wiring.

Who writes it:

- `scripts/ci/automation-log.sh` owns every write: the header is written once, when the file is
  created, and rows are only appended.
- A `|` inside a cell is escaped to `\|`, and a multi-line cell is folded into one line, because
  a table whose column count drifts is worse than no table.
- In `upstream-watch.yml`, the `audit` job writes the `upstream` row after `publish` returns and
  the `release` row only when the run was not a rehearsal. A rehearsal row says
  `result=rehearsed` and no release row is written.
- In `ci.yml`, the `audit` job writes the `platform` row when a push to `main` touched one of
  the four paths, and writes nothing otherwise.
- The `platform` diff is `HEAD^1..HEAD` from a two-commit checkout: a push that carries several
  commits is judged by its last commit, so the row can be missed, never wrong. That is deliberate.
- A write failure does not change what the build decided: the `audit` job goes red, so a log
  that stopped recording shows up instead of passing quietly.

Local reproduction of one row:

```sh
bash scripts/ci/automation-log.sh append --event platform \
  --sha "$(git rev-parse --short HEAD)" --subject "$(git log -1 --format=%s)" \
  --link https://github.com/example/repo/actions/runs/42
```

Two record files, two writers: `keepalive.log` is one line a month and answers "the schedule is
alive"; `automation-log.md` is the table a reader parses. Neither is written by hand or by any
other script.

## Schedule state

`ci.yml` has a `schedule-state` job. It asks the API for the state of `upstream-watch.yml` and
fails when the schedule is off: a disabled watch is a silent auto-release outage, and no build
stage would notice it.

```sh
gh api repos/{owner}/{repo}/actions/workflows/upstream-watch.yml --jq .state
bash scripts/ci/schedule-health.sh    # the same question, locally
```

`schedule-health.sh` exits 0 for `state=active`, 1 for a disabled schedule (the run goes red and
the step summary carries the `gh workflow enable` command), and 2 when `gh`, its credentials or
the API answered nothing usable.

The job runs on `push`, `pull_request` and `workflow_dispatch` only. A called run sees the
caller's event name, so a `schedule` here would mean "upstream-watch called me"; grading the
caller's schedule is the caller's job.

`ci.yml` has no `schedule` trigger of its own, which is why those three events are the whole
whitelist.

## Pull requests and required checks

`ci.yml` runs on `pull_request` against `main`. A pull request gets the same graph a push gets -
the five stages, the static checks and the report - plus `schedule-state`, which answers whether
the daily watch is still enabled.

- **Read-only token.** `ci.yml` declares `permissions: contents: read`, so a pull request run
  is read-only. The one exception is the `audit` job, which asks for `contents: write` and
  runs only on a push to `main`.
- **Fork pull requests.** A pull request from a fork gets a read-only `GITHUB_TOKEN` and no
  repository secrets. This graph needs neither: it downloads from the public mirror and writes
  only inside the run.
- **No `pull_request_target`.** That event runs in the base repository with a write token and
  with secrets, so checking out a fork's code there hands them the keys.
- This repository does not use it, and a workflow that checks out pull-request code stays on
  `pull_request`.

This repository requires no status checks today. If you add branch protection, name the checks a
run actually produces:

```sh
gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks --jq '.contexts[]'
gh api repos/{owner}/{repo}/commits/main/check-runs \
  --jq '.check_runs[] | "\(.name): \(.conclusion)"'
gh pr checks <number>
```

- `Report` is the single verdict of a run: it needs every stage and fails when one of them
  failed, so requiring it covers the whole pipeline.
- `Static Checks` is the one job worth requiring separately, so a lint failure is named instead
  of summarized.
- `Schedule State` fails when the daily watch is disabled, which is a repository-level fact.
  Requiring it makes a disabled watch visible on every pull request, a documentation one
  included. That is a deliberate choice, not a default.

Two smaller facts matter when you set this up:

- The first command answers 404 while `main` is unprotected. That is the answer "no required
  checks", not an error.
- `gh pr checks <number>` lists what ran on the pull request's head, which is the quickest way
  to see whether a required check name still exists after a rename.

## Interactive debugging

`ci-debug.yml` opens an interactive shell on a runner, for the case where a stage stalls and
the log is not enough. It is not a gate: a green run means the session opened, not that a slot
committed.

```sh
gh workflow run ci-debug.yml --ref main -f stage=s4 -f boot_timeout=1200
gh run list --workflow ci-debug.yml --limit 1
```

| `stage` | What runs before the shell opens |
|---|---|
| `none` | tooling only; the cheapest session |
| `build-disk` | resolve, fetch, kmods, esp-prepare, platform-runtime, initramfs, disk, the GRUB preflight |
| `s4` | `build-disk`, the network fixture and boot 1 (fresh image, commit slot a) |
| `s5` | `build-disk`, the upgrade payload, the s5 fixtures and boot 1 |

`boot_timeout` is `CI_QEMU_TIMEOUT` for that first boot (default 1200 s). Dispatch from `main`:
`workflow_dispatch` runs the workflow file of the selected ref, so a branch dispatch executes
that branch's version of every step.

The session step uses `owenthereal/action-upterm` with `detached: true` and publishes the
connection line to the run's summary page and to the `debug-session` artifact:

```sh
ssh session:<token>@uptermd.upterm.dev
ssh -i ~/.ssh/id_ed25519 session:<token>@uptermd.upterm.dev   # a non-default key
```

`limit-access-to-actor: true` means only the GitHub SSH keys of the user who dispatched the run
can connect; with no key on that profile, nobody can.

The string locates the session, the private key is the credential: treat the line,
`join-command` and `ssh-config` as one secret, and do not paste any of them anywhere.

`full-access: true` is what makes the shell usable, and it is only granted inside a VM that is
destroyed with the job.

Bounds: the session step is capped at 10 minutes, the keep-alive step at 150 (stopping itself
at 140) and the job at 240, well inside GitHub's 6-hour cap. The lifetime comes from
`timeout-minutes` on the step and the job, never from a shell literal. `scripts/check_design.py
debug-ssh` asserts that arrangement.

A dropped SSH connection does not end the session - `exit` in the shell, or cancelling the run,
does. The run's summary, the `debug-session` artifact (one day) and `debug-<stage>-logs` (seven
days) are the residue; delete the run once the logs are no longer needed.

## CI text contract

Everything the CI says to a human is a contract, because a run page is read once, under
pressure. Seven rules, asserted by `tests/modules/ci/test_ci_text_conventions.sh`:

1. **English on the surface.** Every non-comment line in `.github/workflows/*.yml`,
   `.github/actions/*/action.yml` and `scripts/ci/*.sh` is ASCII. Chinese lives only in
   `docs/*.zh-CN.md`.
2. **A label is not a sentence.** No trailing period or exclamation mark, no leading or
   trailing space.
   - A workflow or job label is Title Case: every slot opens and closes on a capitalised word,
     and only the short articles, prepositions and conjunctions (`a an the and of for to in on
     by or`) stay lowercase inside it.
   - Step labels and every sentence stay sentence case.
3. **Length caps.** 40 characters for a workflow or job name, 60 for a step name, 80 for an
   issue, pull request or release title.
4. **One grammatical slot per level.** Entry points are `Firmware CI - <role>`. Reusable files
   are `S<n> <semantic>` or a short role phrase.
   - Stage jobs are `S<n> <semantic> - <what it proves>`; steps are `<Verb phrase>` or
     `<Marker> - <claim>`; the separator is exactly ` - `.
   - Every workflow and job slot is filled in Title Case, while a step keeps its capitalised
     verb and the rest of the sentence in sentence case.
   - A step carries no stage number, and a step that does not gate the stage says ` - advisory`.
5. **Fixed summary tables.** Seven headers and no eighth:
   - `stage | verdict | key line | artifact and sha256 | next command`
   - `stage | verdict | duration | artifact`
   - `field | value`
   - `job | result`
   - `artifact | size | sha256`
   - `file | written this run`
   - `time | event | detail | result | link`
6. **Fixed title templates.** `[auto-release] <version>`, `chore(ci): pin upstream <version>`,
   `# Upstream <version> (pin <old> -> <new>)`, and the two release titles derived from
   `tag-policy`.
7. **Structure is not text.** A text change must not change what runs.
   `tests/fixtures/ci-structure-fingerprint.txt` holds one sorted line per structural token, so
   a wording batch leaves it byte-identical; a moved key prints itself.

Naming in short: one separator ` - `, a stage is `S<n> <semantic>`, every workflow and job
label is Title Case, a step carries no stage number, and a step that does not gate the stage
says ` - advisory`.

## Limits

- A skipped stage or gate is never reported as a pass.
- The pipeline does not compile a kernel: it consumes the official rootfs, kernel and btrfs
  module, so a defect inside upstream's build is outside its reach.
- The automatic line cannot be proved by its own runs: a disabled schedule produces no run, so
  its state has to be checked from outside with
  `gh api repos/:owner/:repo/actions/workflows/<id> --jq .state`.
- The keepalive is the strongest in-repo signal, not a proof: an external cron is the only
  certain way to keep a scheduled workflow enabled.
- Releasing is not reversible in this repository: tags are not moved, so a bad release is
  superseded, not rewritten.
