# Device matrix runs

**English** | [简体中文](device-matrix.zh-CN.md)

`scripts/device/` drives one real machine over SSH and turns an upgrade, a downgrade or a
reboot into a single PASS/FAIL/GAP line. It exists because a slot can boot and still be
broken: only a status field, a breadcrumb and a surviving data marker together answer "did
this jump keep a bootable machine".

Prerequisites: a machine reachable over SSH as `root`, its SSH key at hand, and a directory
holding the payloads to jump between.

## Which releases the matrix may use

One line: the 25.x / apk line. A release older than 25 is refused, and so is anything built
from an opkg-era tree, because the two eras do not share a package manager, a firewall model or
a kernel-module layout.

`scripts/ci/upstream-watch.sh` already refuses to pin anything below major 25, and the matrix is
held to the same rule. `matrix.sh` checks the payload's `platform-release`. It refuses a `-`
payload with an explicit line rather than letting it run and fail somewhere that looks like a
product bug.

## What it asserts after every jump

The A/B model is only proven by real upstream releases, not by rewriting a version string in a
manifest. The matrix jumps between the releases the pipeline can build and asserts the same
invariants after each jump:

- `boot=ok` **and** `esp=ok` - a clean boot that could not read the ESP is not a pass;
- `generation` strictly increased, `pending=none`;
- both slot uppers exist and no `@overlay-*` survives without being referenced;
- the user marker on the shared partition and the config marker in `/etc/config` are still
  there;
- the boot log carries `stage=healthcheck-done result=ok` and the commit line.

The last item is the one that reads wrong most easily: the marks of the current boot are in
`boot-1.log` after rotation, so the driver looks in `boot-0.log`, then `boot-1.log`, then
`ab-slot log --prev`, and records which file answered.

## Running it

```sh
scripts/device/matrix.sh --dry-run                      # print the plan, touch nothing
scripts/device/matrix.sh --case M3 --payload-dir <dir>
scripts/device/matrix.sh --payload-dir <dir> --resume    # skip the cases already passing

scripts/device/full-test.sh --dry-run --expect <version>              # the whole suite, planned
scripts/device/full-test.sh --yes --expect <version> --payload-dir <dir>
```

`--payload-dir` holds payloads named `payload-<version>.tar`. Results are appended to
`--results` as `case<TAB>verdict<TAB>evidence<TAB>note`, one line per case, so an interrupted
run is resumed by reading the file rather than by remembering anything.

The environment comes from `AB_HOST` and `AB_KEY`. The SSH call always uses `ControlMaster=no`,
`ControlPath=none` and an ignored `known_hosts`: a reflashed machine presents a new host key,
and the sandbox that runs the driver has no writable `~/.ssh`.

An interactive login is a separate question from these non-interactive calls. It has its own
driver: `scripts/device/login-probe.sh` keeps the client stdin open for the whole session,
because a probe that redirects `/dev/null` into `ssh -tt` reports a false failure on this image
(dropbear 2025.89; see [troubleshooting.md](troubleshooting.md)).

## User scenarios

`scenarios.sh` answers a different question: the user installed packages, wrote files, changed
settings - does a version jump keep all of that, and does the software still run?

| Case | What it builds | What it judges |
|---|---|---|
| S1 preinstall | LuCI apps, a CLI tool and a kmod from the release's own apk index | the snapshot of installed versions, which packages the index does not carry, and an install / run / uninstall cycle that leaves no file behind |
| S2 user state | files and a directory tree on `/data`, two fake docker tarballs, an extra `uci` section, hostname, timezone, one firewall rule | every file by sha256, the tree by entry count, each setting by `uci get`, and that SSH still answers after a real `network reload` |
| S3 / S4 jump | low to high and high to low, with the preinstalled software in place | the same data, config, package, mount and service checks after each hop, and that the hop lands on `packages=aligned packages_reason=none` |
| S5 ledger | the final kernel | which installed packages are still valid, which kmod has to be reinstalled, and what the platform layer reports |
| S6 boot tools | nothing; it only reads | that the ESP's `vmlinuz-<slot>`/`initrd-<slot>` are byte-identical to the payload's `kernel.bin`/`initramfs.cpio.gz`, and that the platform layer's tools match `platform.tar` |
| S7 releasefeeds | one package per version from that release's own feed list, then a jump | that each version installs from its own feeds, that the diff table names what moved, and that a feed which cannot serve a package is reported as a feed problem (GAP), not as a broken machine |
| S8 badconfig | four broken configurations on purpose: a network section naming a device that does not exist, a firewall rule `fw4` cannot translate, a truncated docker `daemon.json`, and an apk feed that answers 404 | that each class is refused or visibly degraded and comes back, that the class's own backup is on `/data` before anything is written and is restored byte for byte, and that the second `apk update` still tells "a feed is closed" apart from "the machine has no network" |

Two rules make those cases honest:

- **Nothing is judged by an old format.** Package names come from the release's own apk index.
- **The configuration is a minimal change on the shipped files.** The 23/24-era snippets in
  circulation describe opkg and a different firewall model.
- **The machine keeps a way back.** S2 schedules its own revert before it reloads, with
  `setsid` (or `start-stop-daemon -b` on an image without it), confirmed by `/tmp/ab-scen-net.ok`.
- **A machine that can schedule neither does not reload at all.** The skipped half is recorded
  as a FINDING rather than as a pass that did not look.

ABI is reported, not judged: a kmod built against another kernel is normal in the apk world, so
a mismatch is recorded as `FINDING:` with the reinstall list and never changes a verdict on its
own.

## Community software samples

The A/B transaction was first proved on a machine whose only extra software was the five
packages the suite itself installs. A real machine is not that machine: people install a LuCI
theme, a software store, a proxy app, and edit those apps' own `/etc/config` files.

This round puts that layer on the machine and jumps it, to answer one question: does the
transaction still commit, and do the samples keep their own configuration?

- `scripts/device/software-probe.sh` installs the samples listed in
  `tests/fixtures/software-samples.json` (`--manifest` overrides the list, `--sample` narrows
  it).
- Each sample row is PASS with the version it landed on, or GAP with the reason and the command
  to retry. A third-party source that is down, or a kernel module whose ABI does not match this
  kernel, is a GAP and never a pass.
- `--baseline <tag>` before a hop and `--compare <tag>` after it record and compare the
  samples' own configuration (values, not just file hashes) through the same snapshot helper
  the other drivers use.
- `--cleanup` removes the samples, their config and the source it added, so the machine goes
  back to the product baseline.
- The third-party source is written only to the device's `/etc/apk/repositories.d/`, never to
  the image, the payload or `scripts/ci/net-defaults.conf.in`.
- `scripts/device/badconfig-probe.sh` writes broken configurations of the kind a person can
  produce: a bad `daemon.json`, a bad UCI section, a firewall rule fw4 warns about, a fake
  subscription URL.
- It judges two things separately: who refused or restored it, and whether anything else
  reacted.

Two limits, stated up front. The sample list is 25.x only, and the samples are test fixtures,
not product contents. Nothing in this repository depends on them, and the release assets are
byte-identical whether or not the samples were installed.

## The whole suite: one order, one verdict

`full-test.sh` runs the drivers above - and two that only answer a question on their own
(`docker-probe.sh`, `release-verify.sh`) - in one order, and reduces their per-phase result
files to one verdict:

| Phase | Answers | Cases for `--only` |
|---|---|---|
| preflight | key file, SSH reachability, platform identity, free space, payload directory | always runs |
| probes | the baseline of a machine nobody has touched yet | `grow network wan22 key platform adapter initrd packages` |
| feed-install | the feed offers a candidate and the machine takes it (`--case all` by default: check, pin, install) | `check`, `install`, `pin`, `both`, `all` |
| matrix | M1..M7: does a version jump keep a bootable machine | `M1`..`M7` |
| scenarios | S1..S8: does the user's data and software survive it | `S1`..`S8` |
| docker | D1: the baseline of a real docker payload (two images through a mainland mirror, one container, one named volume, one committed image) | `D1` |
| package-revert | P1..P4: the package snapshot, the offline way back, payload tampering refused, a record from another base refused. `U1` (the package upgrade really moves) is never in the default set - it installs | `P1`..`P4`, `U1` |
| recovery | a bad version rolls itself back | `R1`.., `B1`.. |
| power-cut | an interrupted candidate boot is not retried for ever | `I1`, `I2` |
| docker-after | D2 / D3: the images and the artifacts survived the switches, and `@docker`/`@data` kept their subvolume identity | `D2`, `D3` |
| release | the published release: the tag, the four assets, `SHA256SUMS` and `index.txt` | `release`, or one of its clause names `verdict`/`sums`/`index` - any of them selects the whole phase, because `release-verify.sh` always checks every clause |

The order is a dependency order:

- **`feed-install` runs before `matrix` and `scenarios`.** The feed has to offer something
  newer than what runs.
- **Matrix and scenarios bring the machine up to the newest release.** A feed-install after
  them fails on a perfectly healthy machine by construction.
- **`docker` is two phases around the version jumps, and still one script.** D1 takes the
  baseline before matrix and scenarios, because those are the jumps the baseline exists to
  survive.
- **D2 and D3 judge the same store immediately after them.** Both windows name the same
  `<results>/docker-snapshots` directory: D1 writes `before.snapshot`, docker-after reads it
  back and writes `after.snapshot`.
- **It stays one driver.** The capture and the comparator must be the same code on both sides
  of the hop.
- **`release` runs after the machine phases.** It never reaches a machine, but its rows are
  part of the same verdict.
- **`docker`, `docker-after` and `release` are not destructive.** D1 keeps two images, one
  container, one committed image and one named volume in the docker store (`@docker`, under
  `/opt/docker`) plus logs under `/tmp`.
- **D1 writes no slot, no ESP entry and no boot decision.**
- **None of them switches a slot or reboots**, so they run without `--yes`.

`power-cut` writes the two files the boot path reads - the candidate marker and the interruption
record - in exactly the form the boot path writes them, and then reboots. That is an injected
state, not a pulled plug, and the evidence says so; what it proves is the decision logic and
the boot wiring, which is where the defect was.

The verdict has three values, and `GAP` is not a pass: a single `FAIL` row makes the run `FAIL`;
with no `FAIL` but at least one `GAP` it is `GAP`; otherwise `PASS`. A `GAP` from a dead mirror
or an unreachable release is not turned into a `FAIL`: a network outage is not a defect of this
product.

## The red line

An install writes the slot the machine is **not** running. The driver refuses to install unless
the running slot is the committed one and no candidate is queued, and it aborts the whole run
(`exit 3`) at any moment when there is no committed healthy slot to fall back to.

Destructive cases are ordered after the reversible ones, and a case that fails is recorded and
left alone: the recovery path is `ab-slot`, not an edit of `ab/state.json`.

A machine that does not come back at all has no automatic recovery. That is what the
`image-install` artifact is for: flash it and start over.
