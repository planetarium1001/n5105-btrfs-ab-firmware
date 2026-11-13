# Updating a machine from a feed

**English** | [简体中文](update.zh-CN.md)

This page is the contract for the two things a machine needs in order to update itself
from somewhere other than a USB stick: **a feed it can read**, and **a rule for how far
one update may jump**. It covers the configuration file, the two commands, the prompt you
are asked to confirm, every exit status and every `reason=` token, and how a publisher
builds a feed of their own.

For installing a payload you already have on disk, or for rescuing a machine whose
bootloader write was interrupted, see [install.md](install.md). This page only adds the
part that fetches.

## Before you start

You need a machine that booted a committed slot and passed its health checks: check with
`ab-slot status`, which must report `p4=ok` and a committed slot. You also need a working
network path to the feed.

The device carries no update state of its own. Nothing in this page adds a file to
`ab/state.json`, and nothing here changes how a slot is written: `ab-upgrade --feed`
downloads a payload, checks it, and then hands it to the same validation and installation
code that `ab-upgrade <payload>` runs.

Two things the machine must be able to do, and neither is guaranteed:

* fetch a file over HTTPS. `uclient-fetch` is preferred, then busybox `wget`; if neither
  exists the command refuses with `feed-no-fetcher` instead of failing halfway. On a
  machine without either, a transport can be supplied per run through
  `UPDATE_FETCH_CMD` (see [Configure a feed](#configure-a-feed)).
* write the payload into a directory with room for it. The default is `/tmp/ab-feed`,
  which on this board is memory; `AB_FEED_DIR` points it at a directory on p4 instead.

## The three version numbers

An update is described by three numbers. They are shown side by side because they answer
different questions, and none of them may be guessed from another.

| Number | Where it comes from | What it means | Does it decide the risk level? |
| --- | --- | --- | --- |
| `base` | the release's upstream version, e.g. `25.12.2`; recorded in the slot's `/etc/platform-release` as `UPSTREAM_VERSION` | the ImmortalWrt release underneath: the rootfs, the kernel and the package base all follow it | yes, and only this one |
| `kernel` | the kernel package version of the build, e.g. `6.12.103` | which kernel the payload installs. It usually moves with `base` and sometimes does not | no, it is shown |
| `platform` | this project's own layer, `PLATFORM_VERSION`, e.g. `0.0.8` | how many times we published this project on top of one `base`. It counts our releases, not the system's | no, it is shown |

A `platform` bump with an unchanged `base` is an ordinary, low-risk update: the platform
layer (the scripts, the defaults, the menu) changes and the system underneath does not.
That is why the number that decides the risk is `base`, and why a prompt that only said
`0.0.8` would be hiding the thing the user needs to know.

The risk level always takes the most severe of the three comparisons: a jump that crosses
both a minor and several patches is a minor jump, not a patch jump.

## Configure a feed

The configuration is one file, `/etc/ab/update.conf`, in the same `key=value` style as
`/etc/net-defaults.conf`. `#` starts a comment. A missing file is not a default: it is a
refusal.

```
UPDATE_FEED_URL=https://example.org/n5105/feed/v1
UPDATE_CHANNEL=stable
UPDATE_VERIFY=sha256
```

| Key | Required | What it does |
| --- | --- | --- |
| `UPDATE_FEED_URL` | yes | the directory the feed lives in. The device fetches `<url>/index.txt`, and an entry without a `url` of its own is fetched from `<url>/<payload>`. It must start with `https://`; anything else is refused with `feed-conf-url` |
| `UPDATE_CHANNEL` | no, default `stable` | which line of releases this machine follows. The index declares its own `channel` and a mismatch is refused with `feed-index-channel`, so a machine cannot silently take an `edge` release |
| `UPDATE_VERIFY` | no, default `sha256` | how the downloaded file is checked. `sha256` is the only value this release implements; anything else is `feed-verify-unsupported`, reserved for signature checking later |
| `UPDATE_PIN` | no | the newest `platform` version this machine will move to on its own. Written by `ab-upgrade --pin`, removed by `ab-upgrade --unpin`; see [Holding a machine on one release](#holding-a-machine-on-one-release) |

`ab-upgrade --feed-url <url>` overrides `UPDATE_FEED_URL` for a single run, so one command
can try a mirror without editing the file. The file itself must still exist.

`UPDATE_FETCH_CMD` is an escape hatch for a machine whose fetchers cannot do what the feed
needs: if it is set, its value is run as `sh -c "<cmd>" ab-fetch <url> <output>`. It is
what the tests use; it is also how a machine behind an unusual transport is served.

## Check for an update

```sh
ab-upgrade --feed-check
```

This command reads the configuration, fetches the index, and prints what it found. It
writes nothing, downloads no payload, and touches no slot. When there is an update it
prints one machine-readable line whose field order is fixed:

```
platform=0.0.6 platform_available=0.0.8 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=patch 2 level=Z1 status=update
```

`platform` and `base` are what the running slot carries, `kernel` is the running kernel
(`uname -r`); the `_available` fields are what the newest entry in the index offers. `span`
is the `base` difference as `patch N`, `minor N`, `major N` or `none`; a downgrade reports
the same word with a negative count (`minor -1`) and `level=downgrade`. `level` is the risk
level from [Risk levels](#risk-levels-and-what-each-one-asks-of-you).

`status` says what the machine may do, and it is the field to branch on:

| Output | Exit | Meaning |
| --- | --- | --- |
| `status=update`, `level=Z1` … `X1` | `10` | there is a newer release. The level says how much of the jump is covered by tests |
| `0.0.8 is the newest release (base 25.12.2)` and `status=current` on the next line | `0` | nothing to do. The feed's newest release is the one running |
| the field line with `pin=<version> status=pinned` | `0` | a newer release exists but `UPDATE_PIN` holds this machine |
| the field line with `level=downgrade status=downgrade` | `0` | every entry in the feed is older than what runs here. A check that finds a downgrade is still a successful check; `--feed` is the command that refuses it |

Any refusal (no configuration, an unreachable feed, an index that does not parse) exits
`74` with a `reason=` token and no field line, because there is nothing true to report.

## Install an update

```sh
ab-upgrade --feed
```

The command repeats the check, prints the same field line, then shows the update block and
asks for confirmation. On confirmation it downloads the payload into
`${AB_FEED_DIR:-/tmp/ab-feed}`, checks the file's size and sha256 against the index, and
enters the ordinary installation path: the same manifest, member, kernel-module, free
space, bootloader and conflict checks that `ab-upgrade <payload>` runs. From there the
machine behaves exactly like a local update: the inactive slot is staged, the next boot
tries it, and a failed health check sends the machine back to the slot it came from.

| Flag | Use it when |
| --- | --- |
| `--yes` | the command has no terminal to ask on (a script, a job, an SSH one-liner with no TTY). Without it, a non-interactive run is refused with `feed-noninteractive` instead of waiting for input that will never come |
| `--direct` | a jump that crosses a major line, and you want the newest release in one step |
| `--stepwise` | a jump that crosses a major line, and you want one release per command. The smallest release above the running one is installed; nothing is queued, so every hop gets its own reboot, health check and commit |
| `--force` | the feed's newest release is older than what runs here and you want it anyway. Downgrades are refused with `feed-would-downgrade` without it |
| `--feed-url <url>` | try a mirror for this run only |

`--direct` and `--stepwise` are part of `--feed`; given on their own they are a usage error
and exit `2`. Both flags may appear anywhere on the command line.

The same lines that a local install writes are what this command writes: capture them the
way [install.md](install.md) shows, with the command piped through `tee` into
`/boot/ab/log/upgrade.log`. Refusals are additionally mirrored to the serial console, so a
machine whose only output is a serial line still says why it stopped.

After a successful install the machine has not changed yet: run `ab-slot status` to see the
other slot as `pending` and `next=<slot>`, then reboot. Packages installed with `apk` are
**not** updated by this path. Aligning them with a new base is a separate operation with
its own commands, because a package that fails to resolve must not roll back a system
update that already passed its checks.

## What the update prompt says

The prompt is three lines of identity followed by three judgement lines. All of it is
written to stdout, so a log capture keeps it, except the `Proceed?` question itself, which
goes to stderr so that it stays visible when stdout is redirected to a file.

```
Update  base     25.12.2 -> 25.12.5
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×3   · the entries above are what this update brings
  Tested  YES        · patch range covered in CI
  Risk    LOW        · running system replaced; previous slot is the way back
Proceed? [y/N]
```

The three identity lines are the only place that says *what changes*: each is written
`current -> candidate`, and one that does not move repeats the same number on both sides.
None of the three is inferred from the level.

The three judgement lines answer three different questions, always in this order:

* `Change` describes the **size** of the jump only: `NONE`, `PATCH ×N`, `MINOR +N` or
  `MAJOR +N`. It never claims which members moved; the identity lines above say that.
* `Tested` states **what CI covers**, as a fact and without hedging: `YES`, `PARTLY` or
  `NO`.
* `Risk` states what the coverage gap means here: `LOW`, `REAL`, `HIGHER` or `UNKNOWN`.

The judgement words are a closed vocabulary, always upper case, always separated from the
explanation by `·`. A bracketed note in parentheses is an aside; a bracketed note in square
brackets is a recommendation, such as `[recommended]`. A `Backup` line appears after `Risk`
for the levels that recommend one, and a `Route` line appears only when the update cannot
proceed without a route.

## Risk levels and what each one asks of you

The level is a statement about **test coverage**, not about the size of the change, and it
is computed from `base` alone. It changes what you are asked, never what the machine does:
every level ends in the same validation and the same write.

| Level | Condition | `Tested` | `Risk` | What you must do |
| --- | --- | --- | --- | --- |
| Z1 | same `base`, patch difference of 3 or less, including none at all | yes, covered | low | confirm with `y` or pass `--yes` |
| Z2 | same `base`, patch difference above 3 | no, outside the covered range | low but uncovered | confirm with `y` or pass `--yes`; a backup is recommended |
| Y1 | same major, minor difference of exactly 1 | partly | real | confirm with `y` or pass `--yes` |
| Y2 | same major, minor difference above 1 | no | higher | confirm with `y` or pass `--yes`; a backup is recommended |
| X1 | a different major | no | unknown | **choose** `--direct` or `--stepwise`; a backup is recommended |

Z1, the platform-only update: `base` and `kernel` do not move and only our layer changes.

```
Update  base     25.12.2 -> 25.12.2
        kernel   6.12.103 -> 6.12.103
        platform 0.0.7 -> 0.0.8
  Change  NONE       · platform layer only; base and kernel left as they are
  Tested  YES        · same-base update covered in CI
  Risk    LOW        · no kernel or package base change
Proceed? [y/N]
```

Z1, a short patch jump:

```
Update  base     25.12.2 -> 25.12.5
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×3   · the entries above are what this update brings
  Tested  YES        · patch range covered in CI
  Risk    LOW        · running system replaced; previous slot is the way back
Proceed? [y/N]
```

Z2, a patch jump longer than the covered range:

```
Update  base     25.12.2 -> 25.12.9
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×7   · the entries above are what this update brings
  Tested  NO         · span outside the covered range
  Risk    LOW        · patches rarely change behaviour, but uncovered
Backup    ab-backup --help   (recommended)
Proceed? [y/N]
```

Y1, one release line forward:

```
Update  base     25.12.2 -> 25.18.0
        kernel   6.12.103 -> 6.12.140
        platform 0.0.8 -> 0.1.2
  Change  MINOR +1   · a new release line; the entries above are what this update brings
  Tested  PARTLY     · neighbouring lines built together; one cross-line upgrade in CI
  Risk    REAL       · installed packages may need rebuilding for the new base
Proceed? [y/N]
```

Y2, several release lines forward:

```
Update  base     25.12.2 -> 25.19.0
        kernel   6.12.103 -> 6.12.150
        platform 0.0.8 -> 0.3.0
  Change  MINOR +2   · the entries above are what this update brings
  Tested  NO         · lines this far apart are not built together
  Risk    HIGHER     · compatibility is less certain than a neighbouring line
Backup    ab-backup --help   (recommended)
Proceed? [y/N]
```

X1, a new major line. There is no `y` here: the command refuses until a route is chosen,
and prints both routes and the reason.

```
Update  base     25.12.2 -> 26.0.0
        kernel   6.12.103 -> 6.18.2
        platform 0.0.8 -> 1.0.0
  Change  MAJOR +1   · a new major line; the entries above are what this update brings
  Tested  NO         · nothing here crosses a major line
  Risk    UNKNOWN    · the package base may not be compatible
Backup    ab-backup --help   (recommended)
Route     --stepwise   install the next release, one at a time   [recommended]
          --direct     install the newest release in one step
ab-upgrade: refused, reason=feed-route-required
```

`--stepwise` walks the index: it installs the smallest release above the running one, so a
machine several release lines behind makes the same familiar jump repeatedly. If the index
no longer carries a release in between, the command refuses with `feed-no-such-release`
instead of jumping over the gap.

## Holding a machine on one release

`UPDATE_PIN` is an upper bound for the automatic path, not a lock:

```sh
ab-upgrade --pin 0.0.8      # ab-upgrade: pinned to 0.0.8
ab-upgrade --unpin          # ab-upgrade: pin removed
```

Both commands edit exactly one line of `/etc/ab/update.conf`, need no network, and leave
everything else in the file alone. A pin that is not a `MAJOR.MINOR.PATCH` version is
refused with `pin-invalid-version`.

What the pin does:

* `--feed-check` keeps working and reports `status=pinned` with the candidate and the pin,
  exiting `0`: a held machine is not nagged.
* `--feed` refuses with `feed-pinned` when the candidate is above the pin. A candidate
  equal to the pin installs normally.
* `--stepwise` stops at the pin.
* a pin below the running version is not an error: the check adds
  `warning pin-below-installed (UPDATE_PIN=0.0.5, running 0.0.7)`, because the usual cause
  is an operator who upgraded and forgot to move the pin.
* `ab-upgrade <payload>` ignores the pin entirely. The pin exists to stop a machine from
  moving on its own; it cannot stop a person who names a file.

Deleting the line, or `--unpin`, releases the machine. The pin is not written into
`ab/state.json` and does not affect `apk`.

## Package updates

A system update replaces a slot; packages are a separate transaction with a separate way
back. Both live on the writable layer, and nothing here is automatic: you ask for it.

```sh
ab-slot packages list            # snapshots on this layer, newest first
ab-slot packages snapshot        # record the world and every installed version now
ab-slot packages upgrade         # snapshot, then apk update && apk upgrade
ab-slot packages revert          # replay the newest snapshot's versions
```

`upgrade` refuses to run unless `ab-slot status` reports `packages=aligned`: that field
means the writable layer's `world` pins the kernel this slot runs and `distfeeds` name the
release it runs. Upgrading packages behind a stale pin installs modules for a kernel the
machine is not running.

A snapshot is text in `<layer>/apk/snapshots/` - the base and platform versions, every
world entry, every installed package with its version. The newest three are kept. `revert`
replays them with `apk add <name>=<version>` and is only allowed on the same base: across
a base those versions were built against a different kernel and libc, which is what
`ab-slot rollback` is for. A package that cannot be restored is reported and the rest
still go through: `revert result=partial` names each one and exits 0. When nothing could be
restored the verdict is `revert result=fail` and the exit status is 1; a snapshot with no
packages is `revert result=empty`. A `failed` line names a package, not a cause: what apk
said is in `upgrade.log`.

The two ways back, side by side:

| You want to undo | Use | What it restores |
| --- | --- | --- |
| the last system update | `ab-slot rollback` | the other slot: its base, its platform layer and its packages |
| a package change on this base | `ab-slot packages revert` | the versions in the snapshot, nothing else |

Both write `upgrade.log`; neither runs by itself.

## Exit status

| Exit | Meaning |
| --- | --- |
| `0` | nothing to do, or nothing done: `--feed-check` found the running release or a pin, the check found only a downgrade, or `--pin` / `--unpin` succeeded. An answered `n` at the prompt also exits `0`, having written nothing |
| `1` | a step failed after the checks passed, for example a full download directory or a missing library. The payload, or the machine, got past validation and something then broke |
| `2` | usage error: an unknown option, `--direct` or `--stepwise` without `--feed`, or a second payload argument |
| `10` | `--feed-check` found a newer release. This is not an error and not a success: it is the answer to the question, so a script can branch on it |
| `74` | refused before anything was written. The line is `ab-upgrade: refused, reason=<token>` and the token is in the table below |

The exit codes of the local install path (`0`, `1`, `74`, and what a refusal leaves on the
disk) are in [install.md](install.md).

## Reasons

Every refusal names one token, and the token is stable across releases, so a script or a
runbook can match on it. The line is always
`ab-upgrade: refused, reason=<token>`, and a `1` prints `ab-upgrade: failed, reason=<token>`.

| Reason | Exit | What it means and what to do |
| --- | --- | --- |
| `no-feed-config` | 74 | `/etc/ab/update.conf` does not exist. Create it with `UPDATE_FEED_URL` set; the command will not guess an address |
| `feed-conf-missing-url` | 74 | the file exists but has no `UPDATE_FEED_URL` |
| `feed-conf-url` | 74 | `UPDATE_FEED_URL` is not an `https://` address. An unencrypted feed is refused: the digest in the index only protects the payload if the index itself cannot be swapped in transit |
| `feed-conf-channel` | 74 | `UPDATE_CHANNEL` is neither `stable` nor `edge` |
| `feed-verify-unsupported` | 74 | `UPDATE_VERIFY` names a mode this release does not implement. `sha256` is the only one |
| `feed-unreachable` | 74 | the index or the payload could not be fetched: no route, no DNS, a `404`, or a transport that exited non-zero |
| `feed-no-fetcher` | 74 | the machine has neither `uclient-fetch` nor `wget`, and `UPDATE_FETCH_CMD` is unset |
| `feed-index-version` | 74 | the index's first line is not `AB-FEED 1`, or `platform` / `base` / `kernel` is not a `MAJOR.MINOR.PATCH` version |
| `feed-index-field` | 74 | a required field is missing, a field is outside an `entry` block, an unknown key appears, or `size` / `sha256` is malformed |
| `feed-index-order` | 74 | entries are not in strictly newest-first order. The publisher broke the ordering rule; the device refuses the whole index rather than sorting it, because a sorted view would hide a feed that stopped being maintained |
| `feed-index-channel` | 74 | the index declares a different `channel` than this machine follows |
| `feed-payload-missing` | 74 | the download finished but the file is not there |
| `feed-size-mismatch` | 74 | the downloaded file is not the size the index promises, so nothing is installed and the partial file is deleted before the refusal is printed |
| `feed-digest-mismatch` | 74 | the downloaded file's sha256 is not the index's. This is a failed download or a tampered file, never a warning, and nothing is installed |
| `feed-download-space` | 74 | the download directory has less than 110% of the payload free. Point `AB_FEED_DIR` at p4 instead of `/tmp` |
| `feed-pinned` | 74 | `UPDATE_PIN` holds this machine below the candidate. `ab-upgrade --unpin`, or `ab-upgrade --pin <newer version>` |
| `feed-would-downgrade` | 74 | the feed's newest release is older than the running one. Pass `--force` if that is really what you want |
| `feed-route-required` | 74 | the jump crosses a major line. Choose `--stepwise` (one release at a time) or `--direct` (straight to the newest) |
| `feed-no-such-release` | 74 | `--stepwise` found no release between the running one and the newest: the feed's index has been trimmed. Ask the publisher for the missing release, or use `--direct` |
| `feed-noninteractive` | 74 | there was no terminal to ask on. Add `--yes` to accept the prompt, or run the command from a terminal |
| `platform-release-missing` | 74 | the running slot's `/etc/platform-release` has no `PLATFORM_VERSION` or no `UPSTREAM_VERSION`, so the machine cannot say what it runs. Reinstall the platform layer |
| `feed-library-missing` | 1 | `ab-version.sh` or `ab-feed.sh` is not on the machine: the platform layer is incomplete |
| `pin-invalid-version` | 74 | `--pin` was given something that is not `MAJOR.MINOR.PATCH` |
| `pin-write-failed` | 74 | `/etc/ab/update.conf` could not be rewritten. Check that `/etc` is writable and has room |
| `cannot-create-workdir` | 1 | the scratch directory under `/tmp` could not be created |
| `cannot-create-feed-dir` | 1 | the download directory could not be created. Check `AB_FEED_DIR` |

The reasons a payload can be refused after it is downloaded are the installer's, and they
are listed in [install.md](install.md): from that point the feed path is the local path.

## Back up before a long jump

Z2, Y2 and X1 print `Backup    ab-backup --help   (recommended)`. That line is advice and
a command to run yourself; nothing calls `ab-backup` for you. It is printed rather than
executed because it needs a target medium and the space to hold the package, and a backup
that silently failed would be worse than none.

What a backup buys you here: this update path can always return to the **previous slot**,
because the slot that runs today is not touched. It cannot return you to the **previous
release** once the older release is gone from the feed, and it cannot bring back files you
changed under `/data`. The three products, which medium each one restores to, and the
restore decision tree are in [backup.md](backup.md).

The recovery paths after a bad update are in [lifecycle.md](lifecycle.md) (the transaction
and the automatic revert) and in [install.md](install.md) (a bootloader write that was
interrupted).

## Build your own feed

A feed is a directory served over HTTPS with two kinds of file in it: `index.txt` and the
payloads it names. Any static host works. GitHub Releases works. Our CI is only the first
publisher, not a requirement.

`index.txt` is line oriented on purpose: a publisher can produce it with `sha256sum` and a
`printf`, and the device can read it with `awk` and nothing else.

```
AB-FEED 1
channel   stable
generated 2026-11-13T00:00:00Z
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  n5105-ab-25.12.2-upgrade.tar
  size     20480000
  sha256   3f2a7c1d4e5b8091a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182
  url      https://example.org/n5105/feed/v1/n5105-ab-25.12.2-upgrade.tar
end
```

Rules a publisher has to keep:

| Rule | Why |
| --- | --- |
| the first line is `AB-FEED 1` | it is the format version. An unknown one is refused rather than guessed |
| `channel` is declared once, in the header | a machine follows one channel; a mismatch is refused |
| `entry` … `end` wraps each release | fields outside a block are refused, so a truncated file cannot be read as a shorter feed |
| `platform`, `base`, `kernel`, `payload`, `size`, `sha256` are all present | six facts, three of them identities. None is inferred from another |
| `platform`, `base` and `kernel` are `MAJOR.MINOR.PATCH` | the comparison is numeric per segment; a suffix such as `-r1` belongs to a package, not to these fields |
| `size` is the payload's size in bytes and `sha256` is its digest | the device checks both before anything is installed, and treats a mismatch as a failed download |
| entries are ordered newest `platform` first, strictly | the device checks the order and refuses the index otherwise |
| `url` is optional and, when present, absolute | without it the device resolves `payload` against its own `UPDATE_FEED_URL`, which is how one feed can be mirrored |
| `notes` is optional | an entry may carry a link for a human, such as the release page. The device parses it and does nothing else with it |

The `kernel` field is the kernel **version** (`6.12.103`), not the kernel package
(`6.12.103~<source hash>-r1`): the package suffix changes on every rebuild and says nothing
about which kernel runs.

Producing one from the release directories the pipeline already writes:

```sh
scripts/ci/feed-index.sh --out /srv/feed/v1/index.txt \
  --channel stable \
  --base-url https://example.org/n5105/feed/v1 \
  --release /srv/releases/v0.0.8 \
  --release /srv/releases/v0.0.7
```

Each `--release` directory is one published release and must contain `release-notes.md`
(which records the platform, upstream and kernel versions), `SHA256SUMS` and the payload
tar it lists. The stage sorts the entries itself, so the directories may be given in any
order. It re-hashes every payload and refuses a directory whose `SHA256SUMS` disagrees with
the file beside it, because a published index that does not match its payload is worse than
no index at all.

`scripts/ci/release.sh` runs this stage for you and adds `index.txt` to the artifacts of
every release for which it knows the kernel version, so a release is a feed entry without
anyone maintaining a list by hand. Passing earlier release directories through
`CI_FEED_HISTORY` puts them in the same index and gives `--stepwise` somewhere to step.

Two things a feed cannot do yet: it is not signed (`UPDATE_VERIFY` has room for a signature
mode and nothing implements one), and the digest it carries is only as trustworthy as the
HTTPS connection it arrived over. That is the same trust a browser download from a release
page gives you, and it is why the feed address must be `https://`.
