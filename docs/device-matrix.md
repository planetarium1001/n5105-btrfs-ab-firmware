# Device matrix runs

`scripts/device/` drives one real machine over SSH and turns an upgrade, a downgrade or a
reboot into a single PASS/FAIL/GAP line. It exists because a slot can boot and still be
broken: only a status field, a breadcrumb and a surviving data marker together answer
"did this jump keep a bootable machine".

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
| S1 preinstall | luci apps, a CLI tool and a kmod from the release's own apk index | the snapshot of installed versions, and which packages the index does not carry |
| S2 user state | files and a directory tree on `/data`, two fake docker tarballs, an extra `uci` section, hostname, timezone, one firewall rule | every file by sha256, the tree by entry count, each setting by `uci get`, and that ssh still answers after a real `network reload` |
| S3 / S4 jump | low to high and high to low, with the preinstalled software in place | the same data, config, package, mount and service checks after each hop |
| S5 ledger | the final kernel | which installed packages are still valid, which kmod has to be reinstalled, and what the platform layer reports |
| S6 boot tools | nothing; it only reads | that the ESP's `vmlinuz-<slot>`/`initrd-<slot>` are byte-identical to the payload's `kernel.bin`/`initramfs.cpio.gz`, and that the platform layer's tools match `platform.tar` |

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

## The red line

An install writes the slot the machine is **not** running. The driver refuses to install
unless the running slot is the committed one and no candidate is queued, and it aborts
the whole run (`exit 3`) at any moment when there is no committed healthy slot to fall
back to. Destructive cases are ordered after the reversible ones, and a case that fails
is recorded and left alone: the recovery path is `ab-slot`, not an edit of
`ab/state.json`.

A machine that does not come back at all has no automatic recovery. That is what the
`image-install` artifact is for: flash it and start over.
