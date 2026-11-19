# Documentation

**English** | [简体中文](README.zh-CN.md)

Ten pages, each the single source for one subject. Every number in them is measured or has an
explicit rationale, and every threshold, log field and contract is asserted by
`python3 scripts/check_design.py all`.

Start with [quickstart.md](quickstart.md) if you want to use the firmware. Read
[architecture.md](architecture.md) and [ci.md](ci.md) if you are changing it.

## Using it

| Document | Contents |
|---|---|
| [quickstart.md](quickstart.md) | the shortest path: write an image, boot it, install one package, upgrade once, roll back once - five steps with the command and the output each one has to produce |
| [install.md](install.md) | writing an image, the first boot at the console, the network defaults, the acceptance checklist, updating a running system, rescuing a torn bootloader |
| [update.md](update.md) | updating from a release feed: the configuration file, the three version numbers, the risk levels, every `reason=` token, the status field reference, package follow and rollback |
| [backup.md](backup.md) | the three products and the media each one restores to, why a whole-disk image fails on a smaller disk, and the restore decision tree |
| [network.md](network.md) | the first-boot network generation, the shipped defaults, how to change them, and the WAN SSH exception |
| [troubleshooting.md](troubleshooting.md) | what to read first, what each symptom means, and the behaviour this project decided not to change |

## Changing it

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | partition geometry, filesystems and subvolumes, the boot chain, first-boot growth of p4, the slot state machine, the update transaction, health checks, reclamation, logging, conflict detection and the payload contract |
| [ci.md](ci.md) | every workflow file and when to run it, the five stages, the cross-version stage and upgrade gates, artifacts, local reproduction, the two release lines, the daily upstream watch, interactive debugging, and the CI text contract |
| [device-matrix.md](device-matrix.md) | driving a real machine through the version matrix over SSH: what each assertion proves, the resume file, the result states, and the red line that keeps a bootable slot |

## Conventions

- Thresholds, log fields and payload members are contracts. Changing one means changing
  `scripts/check_design.py` and the test that asserts it, in the same commit.
- Links are relative and must resolve; `python3 scripts/check_design.py links` verifies this.
- English is the primary language, and every page has a `*.zh-CN.md` translation beside it with
  the same section structure.
- Commands are copy-pasteable; placeholders are written as `<angle-brackets>`.

## Checks

```sh
python3 scripts/check_design.py all
./tests/run.sh --module docs
```

Individual design checks: `partitions`, `esp-data-only`, `overlay-layers`, `generation-model`,
`gc-policy`, `log-ring`, `conflict-model`, `payload-contract`, `links`, `text`,
`retired-names`, `debug-ssh`, `workflow-expressions`.

## See also

- Project overview: [../README.md](../README.md)
- Licenses: [../LICENSES/](../LICENSES/)
