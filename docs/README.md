# Documentation

**English** | [简体中文](README.zh-CN.md)

Each document covers one topic. Every number is either measured or has an explicit rationale.

| Document | Contents |
|---|---|
| [ci-pipeline.md](ci-pipeline.md) | The three CI workflows, the five stages (what each proves and what a failure costs), the artifact map, and how to read a run page |
| [partitions.md](partitions.md) | Partition geometry, GPT PARTNAME and filesystem LABEL naming, sizing rationale, `mkfs` and mount options, subvolumes, first-boot growth |
| [boot-overlay.md](boot-overlay.md) | Boot sequence, layer responsibilities, mount composition and order, platform-layer injection, GRUB assertions, degraded boot |
| [lifecycle.md](lifecycle.md) | Generation model, state file, update transaction, health checks, reclamation, logging, commands |
| [conflicts-payload.md](conflicts-payload.md) | Three-way comparison, disposition, uci boundary, payload contract, validation, build inputs |
| [network.md](network.md) | First-boot network generation, the shipped defaults (WAN port, bridge ports, LAN subnet), how to change them, and the WAN SSH exception |
| [debug-ssh.md](debug-ssh.md) | Manual interactive debugging entry point: trigger, connection, prepared artifacts, session bounds, security, why it is not a gate |

## Conventions

- Thresholds and log fields are contracts. Changing one requires updating `scripts/check_design.py`.
- Documents describe constraints and criteria, not implementation details.
- Links are relative and must resolve. `python3 scripts/check_design.py links` verifies this.
- English is the primary language; a `*.zh-CN.md` translation sits next to every document.

## Checks

```
python3 scripts/check_design.py all
```

Individual checks: `partitions`, `esp-data-only`, `overlay-layers`, `generation-model`,
`gc-policy`, `log-ring`, `conflict-model`, `payload-contract`, `links`, `text`,
`debug-ssh`.

## See also

- Project overview: [../README.md](../README.md)
- Licenses: [../LICENSES/](../LICENSES/)
