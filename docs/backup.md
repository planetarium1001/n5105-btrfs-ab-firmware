# Backup and restore

**English** | [简体中文](backup.zh-CN.md)

This document is the contract for **what a package contains**, **which media a package can
be restored to**, and **what to do when the original disk is gone**. It is the single
source for the three products below; the tools `ab-backup` and `ab-restore` implement it,
and three tests keep the document and the tools in step.

The short version: a machine is rebuilt by installing an image and pouring the data back
in. That path works on **any** disk. A whole-disk image is a byte-for-byte copy and works
only on media **at least as large as the disk it came from**.

## 1. The three products

| Product (concept name) | Physical form | Smallest medium it can be restored to | Failure shape |
|---|---|---|---|
| Install image | the released image, 514 MiB, with p4 at 128 MiB inside it | **any disk of 514 MiB or more**; a larger disk is grown on first boot | a disk below 514 MiB: the table and the payload do not fit, unsupported |
| Data package | `tar.gz` plus its `.sha256`, produced by `ab-backup` | **independent of the disk size** - install an image first, then pour the data in | the target `@data` is not empty: refused unless `--force` says the overwrite was meant |
| Whole-disk image | a byte-for-byte `dd` copy of the whole device | **only media at least as large as the original disk**, including the GPT tolerance below | smaller media: the write itself fails, and the machine does not boot - see §2 |

The important asymmetry: the data package is the only product whose usefulness does not
depend on the size of the disk in front of you. That is why "move to a smaller disk" is
answered with **install image + data package**, and never with shrinking the image.

## 2. Why a smaller disk fails while writing

A whole-disk image recorded on a larger disk cannot be written to a smaller one, and the
failure is not "it boots and then something is wrong later". It happens during the write:

1. `dd` writes sequentially. The primary GPT at LBA 1 lands first; the **backup GPT at the
   end of the disk** can never be written, because the target device ends before the source
   offsets do.
2. The kernel's GPT parser (`block/partitions/efi.c`, `is_gpt_valid()`) treats
   `last_usable_lba > lastlba` as invalid, and the backup header is not where it should be.
   The MBR parser then sees the `0xEE` protective partition, which it does not understand,
   and yields no partitions at all.
3. With no partition nodes there is nothing to boot: GRUB is not loaded, so **no code on
   the device runs**. There is no rescue path from inside the machine, and `dmesg` stays
   silent, which is why this looks like a dead board rather than a full disk.
4. Even if a table could be forced out, btrfs refuses: `device total_bytes > bdev_nr_bytes`
   returns `-EINVAL` and `open_ctree` fails, read-only included.

The GPT tolerance is `lastlba - 33` sectors, so "the same nominal capacity, from another
vendor" can also be too small. Compare `blockdev --getsz` on both devices before copying a
whole-disk image; do not compare the labels on the boxes.

## 3. The restore decision tree

**Q1, always the first question: is the target disk at least as large as the original?**

Only when the answer is "yes" do the byte-for-byte paths apply. When it is "no", path B is
the only path, for the reason in §2 - there is no tool that makes a whole-disk image fit.

```
Q1  target disk capacity >= original disk capacity?
 |- no  -> path B: install image + data package
 '- yes -> Q2 the original disk still boots?
            |- yes -> path A: ab-backup, or clone it directly
            '- no  -> Q3 what is left: the disk, or an image of it?
                       |- the disk  -> path C: read p4 from another Linux
                       '- an image  -> path D: read the image on the host
```

### A. Same-size or larger disk, the original still boots

`Available when:` the original machine still boots, and the target disk passes Q1.

```sh
# on the original machine
ab-backup --with-docker --out /data
sha256sum -c /data/data-*.tar.gz.sha256

# on the freshly installed machine, after the install image has booted once
ab-restore /data/data-<hostname>-<UTC>.tar.gz
```

`Expected:` the first command prints `backup=<path>`, `entries data=... etc=... docker=...`
and `consistency=snapshot`; `sha256sum -c` prints `OK`. The restore prints one
`restored=` line per category and then restores the slot's `etc/config` too.

`Not available when:` Q1 answers "no" - use path B. Also not available for a machine that
no longer boots, which is paths C and D.

### B. Any disk, including a smaller one: install image + data package

`Available when:` always, provided a data package was taken with `ab-backup` while the machine still ran.

```sh
# write the install image to the new disk, boot it once, let it grow p4
# then copy the package over (usb, ssh, whatever) and:
ab-restore /data/data-<hostname>-<UTC>.tar.gz --data-only
```

`Expected:` `restored=data path=/data entries=<n>`; `ab-slot status` still reports
`boot=ok`; the services see their old data under `/data`.

`Not available when:` no data package was ever taken. In that case the only remaining
source of the data is the old disk (path C) or an image of it (path D), and both need media
that satisfies Q1 to write the result back.

### C. The original disk will not boot: read it from another Linux

`Available when:` the original disk is physically intact and can be attached to another
Linux machine.

```sh
# as root on another Linux machine, with the old disk attached
blockdev --getsz /dev/nvme1n1                 # confirm it is the disk you think it is
partx -s /dev/nvme1n1                         # p4 is the last partition
mount -o ro /dev/nvme1n1p4 /mnt/old
btrfs subvolume list /mnt/old                 # @data, @docker, @overlay-<version>
# then copy @data out, e.g.
rsync -aHAX /mnt/old/@data/ /srv/rescue/
```

`Expected:` `partx -s` lists four partitions with `ab-esp`/`ab-slot-a`/`ab-slot-b`/`ab-data`
as names, and `btrfs subvolume list` shows the subvolumes the layout documents. The rescue
copy contains the same tree as `@data`.

`Not available when:` the disk is dead, or it cannot be attached anywhere - then only path
D remains, and it needs an image that already exists.

### D. Only a whole-disk image left: read the image on the host

`Available when:` you hold a whole-disk image (or can still make one from a readable disk)
and you have a host with loop devices and btrfs.

```sh
# 4 commands on the host, no device needed
losetup --find --show --partscan image-flashable.img
mount -o ro /dev/loop0p4 /mnt/img
btrfs subvolume list /mnt/img
rsync -aHAX /mnt/img/@data/ /srv/rescue/
```

`Expected:` `losetup` prints the loop device, `partx`/`blkid` show the four partitions,
`btrfs subvolume list` lists `@data`, and the rescue directory ends up with the data.

`Not available when:` the image is smaller than the disk you want to write it back to
(that direction works) **or** you want to write it to a *smaller* disk: for that, the image
is only a source of data, and the target must be rebuilt with path B.

## 4. `ab-backup` and `ab-restore`

One package, three fixed categories - a restore never has to guess what a file was:

| In the package | Comes from | Goes back to |
|---|---|---|
| `data/` | the whole of `@data` (mounted at `/data`) | `/data` |
| `etc/config/` | the running slot's overlay upper `etc/config` (only files that were changed) | the same upper directory |
| `docker/` | `@docker` (mounted at `/opt/docker`), only with `--with-docker` | `/opt/docker` |
| `meta/` | `ab/state.json`, `ab/device.json`, `ab/image.json` from the ESP, `.ab/grow` and `.ab/grow.log` from p4, plus a generated manifest | `/data/.ab-restore-meta/` - **never the ESP** |

`meta/` describes the machine the package came from: its slot state, its device identity,
its first-boot growth record. Writing it back onto the ESP would copy an old geometry and an
old slot pairing into a freshly installed system, so it is kept beside the data for a human
to read and never applied.

| Command | Options | Behaviour |
|---|---|---|
| `ab-backup` | `--with-docker` | also export `@docker` |
| | `--out <dir>` | where to write the package (default `/data`) |
| | `--dry-run` | print the list and the archive name, write nothing |
| | `--plain` | uncompressed `.tar` instead of `.tar.gz` |
| `ab-restore` | `<archive>` | the package to restore |
| | `--data-only` | restore `data/` only: `docker/`, `etc/config/` and `meta/` are left alone |
| | `--force` | allow the restore into a non-empty `@data` |

Both tools answer on stdout with machine readable lines (`backup=`, `entries`,
`consistency=`, `restored=`) and put refusals on stderr with the `refuse:` prefix and exit
status 3. A refusal means **nothing was written**: the space check, the digest check, the
member check and the non-empty check all run before the first byte is unpacked.

Consistency: `ab-backup` snapshots `@data` read-only and archives the snapshot, so the
package is a point in time. When no snapshot can be taken the export falls back to tarring
the live tree, prints `warn:` on stderr and reports `consistency=live` - that copy is not
point in time, and the difference is visible rather than implied.

### Degraded boots

A boot that could not mount the writable partition runs with a tmpfs as its upper: changes
look normal and disappear on reboot. Two things make that visible, both read from the ring
log of the boot that is running:

- `ab-slot status` reports `boot=ok`, `boot=degraded`, or `boot=unknown` when no ring log
  is readable. It never reports `ok` without evidence.
- `platform/etc/profile.d/ab-degraded.sh` prints one line to stderr at login on a degraded
  boot, and nothing at all otherwise.

Do not take a backup that has to count on a degraded boot: `@data` is on the partition that
failed to mount, so the package would be empty and still look valid.

## 5. Artifact names (mapping table)

The concept names in §1 are the contract. The physical names are being finalised together
with the release workflow, so this table is the place where the two are matched - and the
only place. Until the release workflow is frozen, a document or a script must use the
concept name, not a physical file name.

| Concept name | Physical name (provisional) | Produced by |
|---|---|---|
| Install image | `image-flashable` artifact, `kind=boot` | the assemble stage |
| Data package | `data-<hostname>-<UTC>.tar.gz` + `.sha256` | `ab-backup` on the device |
| Whole-disk image | a `dd` copy of the whole device | an operator, not a build |

## See also

- Partition geometry and first-boot growth: [partitions.md](partitions.md)
- Slot model, state file and commands: [lifecycle.md](lifecycle.md)
- Writing an image to a disk: [install.md](install.md)
