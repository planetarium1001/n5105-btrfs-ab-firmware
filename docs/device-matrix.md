# Device matrix runs

`scripts/device/` drives one real machine over SSH and turns an upgrade, a downgrade or a
reboot into a single PASS/FAIL/GAP line. It exists because a slot can boot and still be
broken: only a status field, a breadcrumb and a surviving data marker together answer
"did this jump keep a bootable machine".

## Which releases the matrix may use

One line: the 25.x / apk line. A release older than 25 is refused, and so is anything
built from an opkg-era tree, because the two eras do not share a package manager, a
firewall model or a kernel-module layout - `scripts/ci/upstream-watch.sh` already refuses
to pin anything below major 25, and the matrix is held to the same rule. `matrix.sh`
checks the payload's `platform-release` and refuses a `-` payload with an explicit line
rather than letting it run and fail somewhere that looks like a product bug. The 24.x /
opkg line is out of scope for this project: it is neither tested nor supported here.

## What it is for

The A/B model is only proven by real upstream releases, not by rewriting a version string
in a manifest. The matrix therefore jumps between the releases the CI can actually build
(see [`ci-pipeline.md`](ci-pipeline.md), "Building a release other than the pin") and
asserts the same invariants after every jump:

- `boot=ok` **and** `esp=ok` — a clean boot that could not read the ESP is not a pass;
- `generation` strictly increased, `pending=none`;
- both slot uppers exist and no `@overlay-*` survives without being referenced;
- the user marker on the shared partition and the config marker in `/etc/config` are
  still there;
- the boot log carries `stage=healthcheck-done result=ok` and the commit line.

The last item is the one that reads wrong most easily: the marks of the current boot are
in `boot-1.log` after rotation, so the driver looks in `boot-0.log`, then `boot-1.log`,
then `ab-slot log --prev`, and records which file answered.

## Running it

```sh
scripts/device/matrix.sh --dry-run                    # print the plan, touch nothing
scripts/device/matrix.sh --case M3 --payload-dir <dir>
scripts/device/matrix.sh --payload-dir <dir> --resume  # skip the cases already passing

scripts/device/full-test.sh --dry-run --task <id> --expect 0.0.12   # the whole suite, planned
scripts/device/full-test.sh --yes --task <id> --expect 0.0.12 --payload-dir <dir>
```

`--payload-dir` holds payloads named `payload-<version>.tar`. Results are appended to
`--results` as `case<TAB>verdict<TAB>evidence<TAB>note`, one line per case, so an
interrupted run is resumed by reading the file rather than by remembering anything.

The environment is taken from `AB_HOST` (`root@192.168.2.49` by default) and `AB_KEY`.
The SSH call always uses `ControlMaster=no`, `ControlPath=none` and an ignored
`known_hosts`: a reflashed machine presents a new host key, and the sandbox that runs the
driver has no writable `~/.ssh`.

## User scenarios

`scenarios.sh` answers a different question: the user installed packages, wrote files,
changed settings - does a version jump keep all of that, and does the software still run.

| Case | What it builds | What it judges |
|---|---|---|
| S1 preinstall | luci apps, a CLI tool and a kmod from the release's own apk index | the snapshot of installed versions, which packages the index does not carry, and an install / run / uninstall cycle that leaves no file behind |
| S2 user state | files and a directory tree on `/data`, two fake docker tarballs, an extra `uci` section, hostname, timezone, one firewall rule | every file by sha256, the tree by entry count, each setting by `uci get`, and that ssh still answers after a real `network reload` |
| S3 / S4 jump | low to high and high to low, with the preinstalled software in place | the same data, config, package, mount and service checks after each hop, and that the hop lands on `packages=aligned packages_reason=none` - `limited` names the reason the aligner recorded, it is judged and not reported |
| S5 ledger | the final kernel | which installed packages are still valid, which kmod has to be reinstalled, and what the platform layer reports |
| S6 boot tools | nothing; it only reads | that the ESP's `vmlinuz-<slot>`/`initrd-<slot>` are byte-identical to the payload's `kernel.bin`/`initramfs.cpio.gz`, and that the platform layer's tools match `platform.tar` |
| S7 releasefeeds | one package per version from that release's own feed list, then a jump | that each version installs from its own feeds, that the diff table names what moved, and that a feed which cannot serve a package is reported as a feed problem (GAP), not as a broken machine |
| S8 badconfig | four broken configurations on purpose - a network section naming a device that does not exist, a firewall rule `fw4` cannot translate, a truncated `docker` `daemon.json`, and an apk feed that answers 404 | that each class is **refused or visibly degraded and comes back**, that the class's own backup is on `/data` before anything is written and is restored byte for byte, and that the second `apk update` still tells "a feed is closed" apart from "the machine has no network". The witness per class is the fact that the broken thing was **not adopted**, never the exit code: `fw4 check` skips an invalid section with a warning and still exits 0 (fail-safe, measured), and `procd` restarts `dockerd` after a bad `daemon.json` so a live pid proves nothing - `docker info` with retries is the witness there |

Two rules make those cases honest:

- **Nothing is judged by an old format.** Package names come from the release's own apk
  index and the configuration is written as a minimal change on the shipped files, because
  the 23/24-era snippets in circulation describe opkg and a different firewall model.
- **The machine keeps a way back.** S2 schedules its own revert before it reloads, with
  `setsid` (or `start-stop-daemon -b` on an image without it), confirmed by
  `/tmp/ab-scen-net.ok`; a machine that can schedule neither does not reload at all and the
  skipped half is recorded as a FINDING rather than a pass that did not look.

ABI is reported, not judged: a kmod built against another kernel is normal in the apk
world, so a mismatch is recorded as `FINDING:` with the reinstall list, and never changes
a verdict on its own.

## The whole suite: one order, one verdict

`full-test.sh` runs the drivers above - and two more that only answer a question on their
own (`docker-probe.sh`, `release-verify.sh`) - in one order, and reduces their per-phase
result files to one verdict:

| Phase | Answers | Cases for `--only` |
|---|---|---|
| preflight | key file, ssh reachability, platform identity, free space, payload directory | always runs |
| probes | the baseline of a machine nobody has touched yet | `grow network wan22 key platform adapter initrd packages` |
| feed-install | ac-12 / ac-13 / ac-3: the feed has a candidate and the machine takes it (`--case all` by default: check, pin, install) | `ac-12`/`check`, `ac-13`/`install`, `ac-3`/`pin`, `both`, `all` |
| matrix | M1..M7: does a version jump keep a bootable machine | `M1`..`M7` |
| scenarios | S1..S8: does the user's data and software survive it | `S1`..`S8` |
| docker | D1: the baseline of a real docker payload (two images through a mainland mirror, one container, one named volume, one committed image) | `D1` |
| package-revert | P1..P4: the package snapshot, the offline way back, payload tampering refused, a record from another base refused. `U1` (the package upgrade really moves) is never in the default set - it installs | `P1`..`P4`, `U1` |
| recovery | a bad version rolls itself back | `R1`.., `B1`.. |
| power-cut | an interrupted candidate boot is not retried for ever | `I1`, `I2` |
| docker-after | D2 / D3: the images and the artifacts survived the switches, and `@docker`/`@data` kept their subvolume identity | `D2`, `D3` |
| release | ac-1 on the published release: the tag, the four assets, SHA256SUMS and index.txt | `release`, or one of its clause names `verdict`/`sums`/`index` - any of them selects the whole phase, because release-verify.sh always checks every clause |
| audit | every ac of the PRD is backed by evidence under the name it uses | always runs |

The order is a dependency order, and each step of it has a reason a reader would otherwise
"fix" back:

- **`feed-install` runs before `matrix` and `scenarios`.** ac-12 / ac-13 and the pin case
  need a machine **below** the candidate: the feed has to offer something newer than what is
  running. matrix and scenarios bring the machine up to the newest release, so a feed-install
  after them fails on a perfectly healthy machine by construction.
- **`docker` is two phases around the version jumps, and still one script.** D1 takes the
  baseline *before* matrix and scenarios, because those two are the jumps this baseline
  exists to survive: a machine that is already at the newest release has nothing left to jump
  to, and D2 would have to answer "no jump" instead of "the store survived one" (that answer
  is a GAP with `reason=no-jump`, never a PASS). D2 and D3 judge the same store immediately
  after the jumps. Both windows name the same
  `<results>/docker-snapshots` directory: D1 writes `before.snapshot`, docker-after reads it
  back and writes `after.snapshot`. It stays one driver because the capture and the
  comparator must be the same code on both sides of the hop; only `--case` differs (`D1` in
  the first window, `D2`/`D3` in the second).
- **`release` runs after the machine phases and before `audit`.** It never reaches a machine,
  but its rows are part of the same verdict.
- **`audit` is last because it judges the record every phase above just wrote**, and it is
  told which round that record belongs to (`--task <id>`, or `AB_TASK_ID`). With neither it is
  a GAP row that names what is missing: it never falls back to the previous round's task id,
  because a green table about an older record reads exactly like a green table about this
  one. A task id the record does not answer for (no PRD, or a PRD with no ac bullet) is a GAP
  too, for the same reason: the record is incomplete, and nothing about this machine was
  judged - that is not the same verdict as a broken machine.

`docker`, `docker-after` and `release` are **not** destructive: D1 keeps two images, one
container, one committed image and one named volume in the docker store (`@docker`, under
`/opt/docker`) plus logs under `/tmp`, and writes no slot, no ESP entry and no boot decision;
D2/D3 only read, and `release-verify.sh` never talks to a machine. None of them switches a
slot or reboots, so they run without `--yes`.

`power-cut` is the phase worth reading twice. It writes the two files the boot path reads -
the candidate marker and the interruption record - in exactly the form the boot path writes
them, and then reboots. **That is an injected state, not a pulled plug**, and the evidence
says so; what it proves is the decision logic and the boot wiring, which is where the defect
was.

The verdict has three values, and `GAP` is not a pass: a single `FAIL` row makes the run
`FAIL`; with no `FAIL` but at least one `GAP` it is `GAP`; otherwise `PASS`. A `GAP` from a
dead mirror or an unreachable release (`docker`, `docker-after`, `release`) is **not** turned
into a `FAIL`: PRD risk 3 says a network outage is not a defect of this product.

## The red line

An install writes the slot the machine is **not** running. The driver refuses to install
unless the running slot is the committed one and no candidate is queued, and it aborts
the whole run (`exit 3`) at any moment when there is no committed healthy slot to fall
back to. Destructive cases are ordered after the reversible ones, and a case that fails
is recorded and left alone: the recovery path is `ab-slot`, not an edit of
`ab/state.json`.

A machine that does not come back at all has no automatic recovery. That is what the
`image-install` artifact is for: flash it and start over.
