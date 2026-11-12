# Documentation

**English** | [简体中文](README.zh-CN.md)

Each document covers one topic. Every number is either measured or has an explicit rationale.

| Document | Contents |
|---|---|
| [ci-pipeline.md](ci-pipeline.md) | Every workflow file and when to run it, the five stages (what each proves and what a failure costs), the artifact map, how to read a run page, and how to reproduce a stage locally |
| [ci-release-lines.md](ci-release-lines.md) | The two release lines (`v*` and bare upstream versions), what a tag has to prove, the daily upstream watch, and one worked release |
| [device-matrix.md](device-matrix.md) | Driving a real machine through the version matrix over SSH: what each assertion proves, the resume file, the result states, and the red line that keeps a bootable slot |
| [partitions.md](partitions.md) | Partition geometry, GPT PARTNAME and filesystem LABEL naming, sizing rationale, `mkfs` and mount options, subvolumes, first-boot growth |
| [boot-overlay.md](boot-overlay.md) | Boot sequence, layer responsibilities, mount composition and order, platform-layer injection, GRUB assertions, degraded boot |
| [lifecycle.md](lifecycle.md) | Generation model, state file, update transaction, health checks, reclamation, logging, commands |
| [conflicts-payload.md](conflicts-payload.md) | Three-way comparison, disposition, uci boundary, payload contract, the bootloader member, validation, build inputs |
| [install.md](install.md) | Writing an image, first boot, the console, upgrading a running machine (`ab-upgrade` flags and exit codes, rescuing a torn bootloader), reading `ab-slot status`, troubleshooting |
| [network.md](network.md) | First-boot network generation, the shipped defaults (WAN port, bridge ports, LAN subnet), how to change them, and the WAN SSH exception |
| [debug-ssh.md](debug-ssh.md) | Manual interactive debugging entry point: trigger, connection, prepared artifacts, session bounds, security, why it is not a gate |
| [backup.md](backup.md) | The three products and the capacity each one can be restored to, why a whole-disk image fails on a smaller disk, the restore decision tree (paths A-D), and what `ab-backup` / `ab-restore` put in a package |

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
`retired-names`, `debug-ssh`, `workflow-expressions`.

## See also

- Project overview: [../README.md](../README.md)
- Licenses: [../LICENSES/](../LICENSES/)
