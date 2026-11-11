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

## The red line

An install writes the slot the machine is **not** running. The driver refuses to install
unless the running slot is the committed one and no candidate is queued, and it aborts
the whole run (`exit 3`) at any moment when there is no committed healthy slot to fall
back to. Destructive cases are ordered after the reversible ones, and a case that fails
is recorded and left alone: the recovery path is `ab-slot`, not an edit of
`ab/state.json`.

A machine that does not come back at all has no automatic recovery. That is what the
`image-install` artifact is for: flash it and start over.
