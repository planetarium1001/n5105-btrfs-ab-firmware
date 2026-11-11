#!/bin/sh
# Helpers for the first-boot growth of p4, in two boots, and for recording its outcome.
#
# Sourced by initramfs/boot/init and exercised by tests/modules/boot/, so everything here
# is POSIX sh (no `local`, no arrays) and every command it calls is overridable: the test
# suite drives the whole state machine from fixture partition tables without a loop
# device, a btrfs filesystem, or root.
#
# The image ships p4 with 128 MiB and leaves the rest of the disk unallocated. Growing it
# takes TWO boots, because the step that killed this machine was doing both halves in one:
# rewriting the table and then asking the kernel to re-read it while the same boot was
# still using that disk.
#
#   boot 1  plan: dump the table and compare p4's end with the last usable LBA
#           stage 1a: mount the root subvolume, keep `.ab/partitions.before` and record
#                     `table-write-pending`, give the mount back - and if that release
#                     fails, do not write at all (`fail:p4-still-mounted`)
#           stage 1b: `sfdisk --no-reread` writes the table; the table is then dumped again
#                     and verified - NOT re-read: no BLKRRPART, no partx, no coldplug
#           stage 1c: mount again, record `table-written` (wf_grow_record_stage1, which
#                     records and nothing else), give the mount back through the caller's
#                     release, and only then reboot (wf_grow_reboot). The reboot IS the
#                     re-read: the kernel parses the GPT at device probe time, with nothing
#                     mounted and no ioctl involved.
#   boot 2  plan: the table is full, so the only thing left is
#                     `btrfs filesystem resize max` -> record `done`
#   boot 3  the record already says `done` at this disk end -> record `already-full`
#
# Stage identity is derived from the disk, never from a flag: "the table already ends at the
# last usable LBA" means the only remaining action is the idempotent filesystem resize. The
# record is evidence plus the `done`/`already-full` label; the one place it decides anything
# is wf_grow_guard, which refuses to rewrite a table a previous boot verified and that is
# still short on disk (the write was lost) - so a lost write cannot become a reboot loop.
#
# Outcomes, written to `<p4 root subvolume>/.ab/grow` as `result=<token> last_lba=<n>`:
#
#   table-write-pending  a table write is in flight (the write-ahead breadcrumb: a boot that
#                        dies in the write window leaves this behind)
#   table-written        the table was written and verified; the reboot is the next step
#   done                 this boot resized the filesystem onto the new geometry
#   already-full         the previous boot already recorded done/already-full at this disk
#                        end, so nothing was written (the steady state)
#   missing-sfdisk       no sfdisk in this initramfs; nothing was written
#   fail:<token>         a step failed; the boot continues on the old geometry. `fail:p4-still-mounted`
#                        means the root subvolume could not be given back, so the table was not
#                        written at all; `fail:table-write-lost` means an earlier boot verified
#                        this table and the disk does not have it - that one is never retried
#
# Tokens from the one-phase firmware are still understood: `done` and `already-full` keep
# their meaning, and any `fail:<token>` (including the retired `partition-table-reread`,
# `size-unchanged` and `size-not-increased`) reads as "not proven" and is re-derived.
#
# Which failures touched the disk:
#   table byte-identical: missing-sfdisk, fail:p4-not-last (a partition starts after p4, so
#     growing it would overwrite that one), fail:p4-beyond-disk (the table describes more
#     disk than there is), fail:partition-table-write, fail:table-write-not-verified,
#     fail:table-verify (written, but the read-back disagreed), fail:table-write-lost (a
#     previous boot verified a table that is not on the disk)
#   table written, the filesystem did not follow: fail:resize-mount, fail:btrfs-resize. These
#     need a look at `.ab/grow` and `ab/log/grow.log` before assuming the geometry is old.
#
# Nothing in this file may stop a boot: every failure is returned as a token, and the caller
# records it and carries on. The one exception is the deliberate reboot after a verified
# table write, which is the point of the two stages rather than a failure.

WF_SFDISK="${WF_SFDISK:-sfdisk}"
WF_BLOCKDEV="${WF_BLOCKDEV:-blockdev}"
WF_BTRFS="${WF_BTRFS:-btrfs}"
WF_SLEEP="${WF_SLEEP:-sleep}"
WF_MOUNT="${WF_MOUNT:-mount}"
WF_UMOUNT="${WF_UMOUNT:-umount}"
# The controlled reboot that ends stage 1, and the flush in front of it. Both overridable:
# the test suite turns the reboot into "the kernel reads the table again", which is exactly
# what a reboot means for this state machine.
WF_REBOOT="${WF_REBOOT:-reboot}"
WF_SYNC_CMD="${WF_SYNC_CMD:-sync}"
WF_SYS_BLOCK="${WF_SYS_BLOCK:-/sys/class/block}"
WF_GROW_TMP="${WF_GROW_TMP:-/run}"
# sysfs `size` is always in 512-byte units, while sfdisk reports partition sizes in
# logical sectors: on a 4Kn disk those differ by a factor of eight, so every conversion
# goes through the device's logical block size (see wf_grow_sector_size).
WF_SECTOR_BYTES="${WF_SECTOR_BYTES:-512}"
# The filesystem sectorsize the grown partition has to be a multiple of. btrfs uses 4096
# whatever the disk reports, and `btrfs filesystem resize` answers `Invalid argument` for
# a device whose size is not a multiple of it; override for tests and for a filesystem
# created with 512-byte sectors.
WF_GROW_SECTORSIZE="${WF_GROW_SECTORSIZE:-4096}"
# The end of a GPT disk is unusable: 32 sectors of backup entry array plus one header
# sector. The last usable LBA is therefore total_sectors - 34.
#
# Measured on real hardware: `sfdisk -d` reports `last-lba` from the table's own header,
# not from the device. An image written for a 514 MiB disk keeps reporting 1052638 after
# it lands on a 128 GB NVMe, the decision below then concludes "already at the end of the
# disk", nothing grows, and `btrfs resize max` is handed a target of zero
# (`ERROR: unable to resize: Invalid argument`). So the device capacity is the primary
# source and the dump is the cross-check, which is the other way round from before.
WF_GPT_TAIL_SECTORS="${WF_GPT_TAIL_SECTORS:-34}"

# wf_grow_log <line...>: diagnostics go to stderr so callers can capture the single
# result token from stdout without losing the log. When the boot initramfs has loaded
# lib/wf.sh (it does, it sources both), the line is also mirrored to the serial port
# through wf_say_serial — never to stdout, which belongs to the result.
wf_grow_log() {
    printf '[grow] %s\n' "$*" >&2
    # The serial mirror is a side channel, never stdout: every wf_grow_* function below
    # answers with one token on stdout and must stay exactly one line.
    if command -v wf_say_serial >/dev/null 2>&1; then
        wf_say_serial "[grow] $*"
    fi
    # Measured on real hardware: the one line that mattered ("writing the partition table
    # failed: ...") only ever existed on the serial console, and a machine without a UART
    # therefore reported `fail:partition-table-write` with no reason at all. Keep the log
    # on the ESP, where pulling the disk is enough to read it.
    if [ -n "${WF_GROW_LOG_FILE:-}" ]; then
        printf '[grow] %s\n' "$*" >>"${WF_GROW_LOG_FILE}" 2>/dev/null || :
    fi
    return 0
}

# wf_grow_sysfs_units <device>: the kernel's size for a block device as sysfs reports
# it, i.e. in 512-byte units whatever the disk's real sector size is. Returns 1 when the
# node is not there yet.
wf_grow_sysfs_units() {
    wf_gs_name="$(basename "$1")"
    wf_gs_file="${WF_SYS_BLOCK}/${wf_gs_name}/size"
    [ -r "${wf_gs_file}" ] || return 1
    wf_gs_value="$(cat "${wf_gs_file}" 2>/dev/null)"
    case "${wf_gs_value}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "${wf_gs_value}"
}

# wf_grow_sector_size <device>: the logical block size sfdisk counts in. disk-identity.sh
# owns the sysfs lookup; a build that ships grow.sh without it still works on 512-byte
# sectors, which is why the fallback is silent rather than fatal.
wf_grow_sector_size() {
    if command -v di_sector_size >/dev/null 2>&1; then
        di_sector_size "$1"
        return 0
    fi
    wf_gss_name="$(basename "$1")"
    for wf_gss_file in "${WF_SYS_BLOCK}/${wf_gss_name}/queue/logical_block_size" \
        "${WF_SYS_BLOCK}/${wf_gss_name}/../queue/logical_block_size"; do
        [ -r "${wf_gss_file}" ] || continue
        wf_gss_value="$(cat "${wf_gss_file}" 2>/dev/null)"
        case "${wf_gss_value}" in
            '' | *[!0-9] | 0) : ;;
            *)
                printf '%s' "${wf_gss_value}"
                return 0
                ;;
        esac
    done
    printf '%s' "${WF_SECTOR_BYTES}"
}

# wf_grow_sectors <device>: the device size in logical sectors, which is the unit
# `sfdisk -d` prints and therefore the unit everything below compares in.
wf_grow_sectors() {
    wf_gse_units="$(wf_grow_sysfs_units "$1")" || return 1
    wf_gse_size="$(wf_grow_sector_size "$1")"
    case "${wf_gse_size}" in
        '' | *[!0-9] | 0) wf_gse_size="${WF_SECTOR_BYTES}" ;;
    esac
    printf '%s' "$((wf_gse_units * WF_SECTOR_BYTES / wf_gse_size))"
}

# wf_grow_alignment <device>: how many sfdisk sectors the filesystem sectorsize spans.
#
# 4096 / 512 = 8 on an ordinary disk, and 1 on a 4Kn disk whose logical sectors already
# are 4096 bytes — in both cases a partition size that is a multiple of it is a byte size
# that btrfs will accept.
wf_grow_alignment() {
    wf_ga_sectorsize="${WF_GROW_SECTORSIZE:-4096}"
    case "${wf_ga_sectorsize}" in
        '' | *[!0-9]* | 0) wf_ga_sectorsize=4096 ;;
    esac
    wf_ga_unit="$(wf_grow_sector_size "${1:-}")"
    case "${wf_ga_unit}" in
        '' | *[!0-9]* | 0) wf_ga_unit="${WF_SECTOR_BYTES}" ;;
    esac
    wf_ga_align=$((wf_ga_sectorsize / wf_ga_unit))
    if [ "${wf_ga_align}" -lt 1 ]; then
        wf_ga_align=1
    fi
    printf '%s' "${wf_ga_align}"
}

# wf_grow_disk_sectors <disk>: sysfs first, `blockdev --getsize64` as the fallback for
# kernels that hide the size file from the initramfs. Both are converted to logical
# sectors so the arithmetic against `last-lba` stays in one unit.
wf_grow_disk_sectors() {
    wf_gds_value="$(wf_grow_sectors "$1")" && {
        printf '%s' "${wf_gds_value}"
        return 0
    }
    wf_gds_bytes="$("${WF_BLOCKDEV}" --getsize64 "$1" 2>/dev/null)" || return 1
    case "${wf_gds_bytes}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    wf_gds_size="$(wf_grow_sector_size "$1")"
    case "${wf_gds_size}" in
        '' | *[!0-9] | 0) wf_gds_size="${WF_SECTOR_BYTES}" ;;
    esac
    printf '%s' "$((wf_gds_bytes / wf_gds_size))"
}

# wf_grow_part_line <dump> <device>: the sfdisk dump line of one partition, or nothing.
wf_grow_part_line() {
    awk -v dev="$2" '
        {
            name = $1
            sub(/:$/, "", name)
            if (name == dev) {
                print
                exit
            }
        }
    ' "$1"
}

# wf_grow_part_field <line> <key>: the numeric value of start=, size= or a similar key.
wf_grow_part_field() {
    printf '%s\n' "$1" \
        | sed -n "s/.*$2[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        | head -n 1
}

# wf_grow_last_lba <dump> <sectors>: the last LBA the table may use. sfdisk's own
# `last-lba` wins because it already accounts for the backup GPT; the arithmetic
# fallback keeps the helper usable on dumps that only carry partition lines.
wf_grow_last_lba() {
    wf_gl_table="$(sed -n 's/^last-lba:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)"
    case "${2:-}" in
        '' | *[!0-9]* | 0) : ;;
        *)
            wf_gl_device=$(($2 - WF_GPT_TAIL_SECTORS))
            case "${wf_gl_table}" in
                '' | *[!0-9]*) : ;;
                *)
                    if [ "${wf_gl_table}" -ne "${wf_gl_device}" ]; then
                        wf_grow_log "table last-lba=${wf_gl_table} device last-lba=${wf_gl_device} (using the device)"
                    fi
                    ;;
            esac
            printf '%s' "${wf_gl_device}"
            return 0
            ;;
    esac
    # No capacity from sysfs or blockdev: the table's own value is all there is.
    case "${wf_gl_table}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "${wf_gl_table}"
}

# wf_grow_decide <dump> <p4device> <disk sectors>
#
#   already-full <last_lba>             p4 already ends at the last usable LBA
#   grow <last_lba> <new_size>          p4 has to grow to <new_size> sectors
#   fail:<token>                        the table cannot be grown from this input
#
# This is the whole idempotency rule: the decision only depends on the table that is
# on the disk, so running it again after a successful growth yields `already-full`.
wf_grow_decide() {
    wf_gd_dump="$1"
    wf_gd_dev="$2"
    wf_gd_sectors="${3:-}"
    wf_gd_line="$(wf_grow_part_line "${wf_gd_dump}" "${wf_gd_dev}")"
    if [ -z "${wf_gd_line}" ]; then
        printf 'fail:partition-table-unreadable'
        return 0
    fi
    wf_gd_start="$(wf_grow_part_field "${wf_gd_line}" start)"
    wf_gd_size="$(wf_grow_part_field "${wf_gd_line}" size)"
    case "${wf_gd_start}" in
        '' | *[!0-9]*)
            printf 'fail:p4-start-invalid'
            return 0
            ;;
    esac
    case "${wf_gd_size}" in
        '' | *[!0-9]*)
            printf 'fail:p4-size-invalid'
            return 0
            ;;
    esac
    wf_gd_last="$(wf_grow_last_lba "${wf_gd_dump}" "${wf_gd_sectors}")"
    case "${wf_gd_last}" in
        '' | *[!0-9]*)
            printf 'fail:disk-size-unknown'
            return 0
            ;;
    esac
    # Growing p4 to the end of the disk is only safe when p4 *is* the last partition.
    # A layout with something after it (a user partition, a vendor partition) would be
    # overwritten, and nothing in the table would warn about it.
    wf_gd_next="$(awk -v p4start="${wf_gd_start}" '
        match($0, /start=[ \t]*[0-9]+/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/start=[ \t]*/, "", s)
            s += 0
            if (s > p4start && (min == "" || s < min)) min = s
        }
        END { if (min != "") print min }
    ' "${wf_gd_dump}" 2>/dev/null)"
    case "${wf_gd_next}" in
        '' | *[!0-9]*) : ;;
        *)
            wf_grow_log "another partition starts at ${wf_gd_next}, after p4's start ${wf_gd_start}: refusing to grow"
            printf 'fail:p4-not-last'
            return 0
            ;;
    esac
    wf_gd_end=$((wf_gd_start + wf_gd_size - 1))
    if [ "${wf_gd_end}" -eq "${wf_gd_last}" ]; then
        printf 'already-full %s' "${wf_gd_last}"
        return 0
    fi
    if [ "${wf_gd_end}" -gt "${wf_gd_last}" ]; then
        # A p4 that reaches past the usable area means the table was written by
        # something else; growing it further is exactly what must not happen.
        printf 'fail:p4-beyond-disk'
        return 0
    fi
    # The new size is rounded DOWN to a multiple of the filesystem sectorsize: btrfs
    # answers `Invalid argument` for a device size that is not, and a partition that
    # ends a few sectors short of the tail costs nothing but is the difference between a
    # grown filesystem and a 64 MiB one. The last usable LBA is still what gets reported.
    wf_gd_want=$((wf_gd_last - wf_gd_start + 1))
    wf_gd_align="$(wf_grow_alignment "${wf_gd_dev}")"
    case "${wf_gd_align}" in
        '' | *[!0-9]* | 0) wf_gd_align=1 ;;
    esac
    wf_gd_new=$((wf_gd_want / wf_gd_align * wf_gd_align))
    wf_gd_lbs="$(wf_grow_sector_size "${wf_gd_dev}")"
    case "${wf_gd_lbs}" in
        '' | *[!0-9]* | 0) wf_gd_lbs="${WF_SECTOR_BYTES}" ;;
    esac
    wf_grow_log "aligned size=${wf_gd_new} bytes=$((wf_gd_new * wf_gd_lbs)) sectorsize=$((wf_gd_align * wf_gd_lbs)) alignment=${wf_gd_align} (unaligned ${wf_gd_want})"
    if [ "${wf_gd_new}" -le "${wf_gd_size}" ]; then
        # Rounding took away the whole gain (a few sectors of slack): growing would be a
        # no-op write of the table, so nothing is written at all.
        wf_grow_log "aligned size ${wf_gd_new} does not beat the current ${wf_gd_size} sectors"
        printf 'already-full %s' "${wf_gd_last}"
        return 0
    fi
    printf 'grow %s %s' "${wf_gd_last}" "${wf_gd_new}"
}

# wf_grow_table <dump in> <dump out> <p4device> <new size>: copy the dump, replacing
# the size field of the p4 line and nothing else. Every other line, including the
# table UUID and the other three partitions, must come out byte-identical, which is
# what keeps the ESP and both slots addressable by the same identifiers after growth.
wf_grow_table() {
    awk -v dev="$3" -v size="$4" -v last="$5" '
        BEGIN { changed = 0 }
        {
            name = $1
            sub(/:$/, "", name)
            # The header line first: `last-lba` is what sfdisk validates the partition
            # lines against. A dump taken from a 514 MiB image says 1052638, so growing p4
            # to the end of a 128 GB disk without rewriting this line makes sfdisk refuse
            # the table ("partition ends beyond last usable LBA") - measured on hardware.
            if (last != "" && $1 == "last-lba:") {
                print "last-lba: " last
                next
            }
            if (changed == 0 && name == dev && match($0, /size=[ \t]*[0-9]+/)) {
                $0 = substr($0, 1, RSTART - 1) "size= " size substr($0, RSTART + RLENGTH)
                changed = 1
            }
            print
        }
        END { exit changed == 1 ? 0 : 1 }
    ' "$1" >"$2"
}

# wf_grow_plan <disk> <p4device>: dump the table and decide, without touching the device.
# Prints exactly one line:
#
#   grow <last_lba> <new_size>   p4 has to grow to <new_size> sectors
#   already-full <last_lba>      p4 already ends at the last usable LBA
#   missing-sfdisk 0             no sfdisk in this initramfs
#   fail:<token> 0|<last_lba>    the table cannot be grown from this input
#
# The dump is kept at <WF_GROW_TMP>/grow/partitions.before: it is the pre-change copy that
# wf_grow_backup puts on p4 and the input wf_grow_write_table rewrites.
wf_grow_plan() {
    wf_gp_disk="$1"
    wf_gp_p4="$2"
    if ! command -v "${WF_SFDISK}" >/dev/null 2>&1; then
        wf_grow_log "${WF_SFDISK} is not in this initramfs, leaving the disk untouched"
        printf 'missing-sfdisk 0'
        return 0
    fi
    wf_gp_dir="${WF_GROW_TMP}/grow"
    wf_gp_dump="${wf_gp_dir}/partitions.before"
    mkdir -p "${wf_gp_dir}" 2>/dev/null || {
        printf 'fail:workdir 0'
        return 0
    }
    if ! "${WF_SFDISK}" -d "${wf_gp_disk}" >"${wf_gp_dump}" 2>/dev/null; then
        wf_grow_log "cannot dump the partition table of ${wf_gp_disk}"
        printf 'fail:partition-table-read 0'
        return 0
    fi
    wf_gp_sectors="$(wf_grow_disk_sectors "${wf_gp_disk}")" || wf_gp_sectors=""
    wf_gp_decision="$(wf_grow_decide "${wf_gp_dump}" "${wf_gp_p4}" "${wf_gp_sectors}")"
    case "${wf_gp_decision}" in
        grow\ * | already-full\ *)
            printf '%s' "${wf_gp_decision}"
            ;;
        *)
            # A decision the table cannot satisfy is reported with last_lba=0: nothing about
            # the disk end is proven, so nothing may be recorded as if it were.
            printf '%s 0' "${wf_gp_decision}"
            ;;
    esac
}

# wf_grow_mountpoint_active <mount point>: is something mounted there right now? The mount
# table is the only honest answer - a directory that exists is not a mount.
wf_grow_mountpoint_active() {
    [ -n "${1:-}" ] || return 1
    awk -v mp="$1" '$2 == mp { found = 1 } END { exit !found }' \
        "${WF_MOUNTS:-/proc/mounts}" 2>/dev/null
}

# wf_grow_write_table <disk> <p4device> <new size> <dump in> [<last lba>] [<mount point>]:
# write the grown table and prove it landed. Prints `written` or `fail:<token>`.
#
# <mount point> is the filesystem that has to be free for this write: the p4 root subvolume,
# which stage 1a mounted for the write-ahead breadcrumb. It is checked against the mount
# table, so a release that failed cannot be followed by `sfdisk` even if the caller ignored
# its return code - writing a table under a mounted filesystem is the other half of what
# killed the machine.
#
# This is the step that used to be followed by `blockdev --rereadpt`. It is not any more:
# the kernel's view of the disk is left exactly as it is, and the reboot of stage 1c is
# what makes it re-read the table. Two things are checked before the caller may reboot:
#
#   * the table read back from the device really names the new p4 size (a write that did
#     not reach the medium is `fail:table-write-not-verified`, not a success)
#   * `sfdisk --verify` accepts primary and backup GPT - the reboot would otherwise boot a
#     machine with half a table. An sfdisk without that option is not a reason to stop
#     growing: it is logged as `verify=unsupported`.
wf_grow_write_table() {
    wf_gw_disk="$1"
    wf_gw_p4="$2"
    wf_gw_size="$3"
    wf_gw_in="$4"
    wf_gw_last="${5:-}"
    wf_gw_free="${6:-}"
    if wf_grow_mountpoint_active "${wf_gw_free}"; then
        wf_grow_log "refusing to write the table: ${wf_gw_free} is still mounted"
        printf 'fail:p4-still-mounted'
        return 0
    fi
    wf_gw_dir="$(dirname "${wf_gw_in}")"
    wf_gw_out="${wf_gw_dir}/partitions.after"
    wf_grow_table "${wf_gw_in}" "${wf_gw_out}" "${wf_gw_p4}" "${wf_gw_size}" "${wf_gw_last}" || {
        printf 'fail:partition-table-rewrite'
        return 0
    }
    if ! wf_gw_err="$("${WF_SFDISK}" --no-reread "${wf_gw_disk}" <"${wf_gw_out}" 2>&1)"; then
        wf_grow_log "writing the partition table failed: ${wf_gw_err:-no output}"
        printf 'fail:partition-table-write'
        return 0
    fi
    wf_grow_log "partition table written with p4 size=${wf_gw_size} (no re-read: the next boot's kernel does that)"
    wf_gw_dump="${wf_gw_dir}/partitions.written"
    if ! "${WF_SFDISK}" -d "${wf_gw_disk}" >"${wf_gw_dump}" 2>/dev/null; then
        wf_grow_log "the table could not be read back after the write"
        printf 'fail:table-write-not-verified'
        return 0
    fi
    wf_gw_seen="$(wf_grow_part_field "$(wf_grow_part_line "${wf_gw_dump}" "${wf_gw_p4}")" size)"
    if [ "${wf_gw_seen}" != "${wf_gw_size}" ]; then
        wf_grow_log "the table on the disk still says p4 size=${wf_gw_seen:-unknown} instead of ${wf_gw_size}"
        printf 'fail:table-write-not-verified'
        return 0
    fi
    wf_gw_vrc=0
    wf_gw_verr="$("${WF_SFDISK}" --verify "${wf_gw_disk}" 2>&1)" || wf_gw_vrc=$?
    if [ "${wf_gw_vrc}" -eq 0 ]; then
        wf_grow_log "verify=ok primary and backup GPT agree after the write"
    else
        case "${wf_gw_verr}" in
            *nrecognized* | *nvalid*option* | *sage:* | *"unknown option"*)
                wf_grow_log "verify=unsupported this sfdisk has no --verify: ${wf_gw_verr}"
                ;;
            *)
                wf_grow_log "verify=failed ${wf_gw_verr:-no output}"
                printf 'fail:table-verify'
                return 0
                ;;
        esac
    fi
    printf 'written'
}

# wf_grow_record_state <file>: the state and disk end a `.ab/grow` file names, as
# `<state> <last_lba>`. A missing or unreadable file answers `missing 0`, and so does a
# record without a `result=`: "no proof" is a state, never an error.
wf_grow_record_state() {
    wf_grs_file="${1:-}"
    if [ -z "${wf_grs_file}" ] || [ ! -f "${wf_grs_file}" ]; then
        printf 'missing 0'
        return 0
    fi
    wf_grs_line="$(head -n 1 "${wf_grs_file}" 2>/dev/null)"
    wf_grs_state="$(printf '%s' "${wf_grs_line}" \
        | sed -n 's/.*result=\([a-z][a-z:-]*\).*/\1/p')"
    if [ -z "${wf_grs_state}" ]; then
        printf 'missing 0'
        return 0
    fi
    wf_grs_lba="$(printf '%s' "${wf_grs_line}" \
        | sed -n 's/.*last_lba=\([0-9][0-9]*\).*/\1/p')"
    case "${wf_grs_lba}" in
        '' | *[!0-9]*) wf_grs_lba=0 ;;
    esac
    printf '%s %s' "${wf_grs_state}" "${wf_grs_lba}"
}

# wf_grow_steady <state> <recorded lba> <lba now>: does the record prove the filesystem is
# already at the end of the disk? Only `done`/`already-full` at the same disk end do, which
# is what makes a record written by the one-phase firmware (and by an older build) usable:
# the same tokens mean the same thing on both sides of the change.
wf_grow_steady() {
    wf_gst_state="${1:-}"
    wf_gst_recorded="${2:-}"
    wf_gst_now="${3:-}"
    case "${wf_gst_recorded}" in
        '' | *[!0-9]* | 0) return 1 ;;
    esac
    case "${wf_gst_now}" in
        '' | *[!0-9]* | 0) return 1 ;;
    esac
    [ "${wf_gst_recorded}" = "${wf_gst_now}" ] || return 1
    case "${wf_gst_state}" in
        done | already-full) return 0 ;;
    esac
    return 1
}

# wf_grow_guard <recorded state> <recorded lba> <lba to write>: may this boot write the
# table? Prints `write` or `refuse`.
#
# The contradictory states are `table-written` and the `fail:table-write-lost` the refusing
# boot writes itself, both for exactly the disk end this boot is about to write: a previous
# boot verified that table and it is still not on the disk, so writing and rebooting again
# would be the same boot over and over. Refusing on the refusal's own token is what makes the
# stop hold across boots: the record is overwritten every time, so a guard that only knew
# `table-written` would be talked out of it by the second boot and write every other boot.
# A pending write is the opposite - that is precisely what a retry is for - and everything
# else is retried.
wf_grow_guard() {
    wf_gg_state="${1:-}"
    wf_gg_recorded="${2:-}"
    wf_gg_lba="${3:-}"
    case "${wf_gg_recorded}" in
        '' | *[!0-9]*) wf_gg_recorded=0 ;;
    esac
    case "${wf_gg_lba}" in
        '' | *[!0-9]*) wf_gg_lba=0 ;;
    esac
    case "${wf_gg_state}" in
        table-written | fail:table-write-lost) : ;;
        *)
            printf 'write'
            return 0
            ;;
    esac
    if [ "${wf_gg_recorded}" != "0" ] && [ "${wf_gg_recorded}" = "${wf_gg_lba}" ]; then
        wf_grow_log "a previous boot verified a table ending at ${wf_gg_recorded} (or gave up on it), and this boot still reads a shorter p4: the write was lost, not retried"
        printf 'refuse'
        return 0
    fi
    printf 'write'
}

# wf_grow_finalize <plan> <lba> <resize result> <recorded state> <recorded lba>: the token
# this boot records.
#
#   done          this boot resized the filesystem
#   already-full  the previous boot already recorded done/already-full at this disk end
#   fail:<token>  the resize (or an earlier step) failed; its token is kept verbatim
wf_grow_finalize() {
    wf_gfin_plan="${1:-}"
    wf_gfin_lba="${2:-}"
    wf_gfin_resize="${3:-}"
    wf_gfin_state="${4:-missing}"
    wf_gfin_recorded="${5:-0}"
    case "${wf_gfin_plan}" in
        already-full)
            case "${wf_gfin_resize}" in
                done | '')
                    if wf_grow_steady "${wf_gfin_state}" "${wf_gfin_recorded}" "${wf_gfin_lba}"; then
                        printf 'already-full'
                    else
                        printf 'done'
                    fi
                    ;;
                *)
                    printf '%s' "${wf_gfin_resize}"
                    ;;
            esac
            return 0
            ;;
    esac
    # missing-sfdisk, a fail:<token>, or `table-written` when a reboot came back: all of
    # them are already the answer.
    printf '%s' "${wf_gfin_plan}"
}

# wf_grow_flush_log <mount point>: append the buffered grow log to `<mount point>/.ab/grow.log`
# and empty the buffer, so the next mount of the same subvolume cannot duplicate the lines.
# The log is append-only across boots by design: a boot that dies leaves its tail there.
wf_grow_flush_log() {
    wf_gfl_dir="${1:-}"
    [ -n "${wf_gfl_dir}" ] || return 1
    [ -n "${WF_GROW_LOG_FILE:-}" ] || return 0
    [ -s "${WF_GROW_LOG_FILE}" ] || return 0
    mkdir -p "${wf_gfl_dir}/.ab" 2>/dev/null || return 1
    cat "${WF_GROW_LOG_FILE}" >>"${wf_gfl_dir}/.ab/grow.log" 2>/dev/null || return 1
    sync
    : >"${WF_GROW_LOG_FILE}" 2>/dev/null || :
    return 0
}

# wf_grow_stage1_prepare <mount point> <last lba>: the write-ahead breadcrumb of stage 1.
# The caller has the root subvolume mounted; this keeps `.ab/partitions.before` and records
# `table-write-pending` before anything writes the table, so a boot that dies in the write
# window still says what it was about to do and what the geometry was.
wf_grow_stage1_prepare() {
    wf_gsp_dir="${1:-}"
    wf_gsp_lba="${2:-0}"
    case "${wf_gsp_lba}" in
        '' | *[!0-9]*) wf_gsp_lba=0 ;;
    esac
    if [ -z "${wf_gsp_dir}" ]; then
        wf_grow_log "no p4 mount point for the write-ahead breadcrumb"
        return 1
    fi
    # The pre-change table first: if the record cannot be written, the old geometry is at
    # least next to where the record would have been.
    if wf_grow_backup "${wf_gsp_dir}"; then
        wf_grow_log "pre-growth partition table kept in .ab/partitions.before"
    else
        wf_grow_log "warning: could not keep the pre-growth partition table"
    fi
    if ! wf_grow_record "${wf_gsp_dir}" table-write-pending "${wf_gsp_lba}"; then
        wf_grow_log "warning: could not write the write-ahead breadcrumb on the p4 root subvolume"
        wf_grow_flush_log "${wf_gsp_dir}"
        return 1
    fi
    wf_grow_flush_log "${wf_gsp_dir}"
    return 0
}

# wf_grow_reboot: the end of stage 1. The writes are flushed, then the machine is reset
# without a userspace in between, so the next boot's kernel reads the new table at probe
# time. Prints nothing; non-zero means the command returned and this boot is still running.
wf_grow_reboot() {
    wf_grow_log "rebooting so the kernel re-reads the partition table at probe time"
    "${WF_SYNC_CMD}" 2>/dev/null || sync
    "${WF_SYNC_CMD}" 2>/dev/null || sync
    "${WF_REBOOT}" -f
    wf_grb_rc=$?
    wf_grow_log "the reboot command returned ${wf_grb_rc}; this boot continues on the old geometry"
    return "${wf_grb_rc}"
}

# wf_grow_record_stage1 <mount point> <last lba> <write result>: record what the table write
# did and print the token this boot stands on. It does not unmount anything and it does not
# reboot: giving the mount back is the caller's one release path (init's wf_p4root_release),
# and the reboot only happens after it succeeded - `wf_grow_should_reboot` says whether the
# token is one that ends the boot at all.
wf_grow_record_stage1() {
    wf_grs1_dir="${1:-}"
    wf_grs1_lba="${2:-0}"
    wf_grs1_write="${3:-}"
    case "${wf_grs1_lba}" in
        '' | *[!0-9]*) wf_grs1_lba=0 ;;
    esac
    if [ -z "${wf_grs1_dir}" ]; then
        wf_grow_log "no p4 mount point to record the outcome on"
        return 1
    fi
    case "${wf_grs1_write}" in
        written | table-written) wf_grs1_state="table-written" ;;
        '') wf_grs1_state="fail:grow-crashed" ;;
        *) wf_grs1_state="${wf_grs1_write}" ;;
    esac
    # The write's own lines first, then the record, then the record's line: the tail of
    # grow.log then reads in the order the boot did things.
    wf_grow_flush_log "${wf_grs1_dir}"
    if ! wf_grow_record "${wf_grs1_dir}" "${wf_grs1_state}" "${wf_grs1_lba}"; then
        wf_grow_log "warning: could not write the growth record on the p4 root subvolume"
    fi
    wf_grow_flush_log "${wf_grs1_dir}"
    printf '%s' "${wf_grs1_state}"
}

# wf_grow_should_reboot <recorded token>: 0 only for a verified table, which is the state
# whose next step is the re-read. Every other token leaves the machine running on the old
# geometry with the reason on p4.
wf_grow_should_reboot() {
    [ "${1:-}" = "table-written" ]
}

# wf_grow_fs <target> [<disk>]: grow the filesystem onto the partition it sits on.
# Prints `done`, `fail:resize-target` or `fail:btrfs-resize`.
#
# <target> is either a mount point or, better, the unmounted device:
#
#   * the device while nothing of that filesystem is mounted — btrfs-progs opens the
#     device directly, with no mount point to resolve. This is the resize a growpart-style
#     tool does: partition table first, filesystem second, mounts last;
#   * a mount point when the filesystem is already mounted, for a resize that has to
#     happen later in the boot.
#
# Anything else is refused before btrfs-progs runs: an unmounted directory names no
# filesystem, and a DEVICE THAT IS CURRENTLY MOUNTED is exactly the race that produced
# both EBUSY (`Can't open blockdev`) and EINVAL (`unable to resize ...: Invalid
# argument`) on the real machine.
#
# <disk> is only used for the failure diagnostics.
wf_grow_fs() {
    wf_gf_target="${1:-}"
    wf_gf_disk="${2:-}"
    wf_gf_mounts="${WF_MOUNTS:-/proc/mounts}"
    [ -n "${wf_gf_target}" ] || {
        printf 'fail:resize-target'
        return 0
    }
    # A mount point appears in column 2; a device in use appears in column 1. Both facts
    # are needed: `/dev/sda4` as a target is only legal while it is in neither.
    wf_gf_is_mountpoint=0
    if awk -v mp="${wf_gf_target}" '$2 == mp { found = 1 } END { exit !found }' \
        "${wf_gf_mounts}" 2>/dev/null; then
        wf_gf_is_mountpoint=1
    fi
    wf_gf_is_mountsource=0
    if awk -v dev="${wf_gf_target}" '$1 == dev { found = 1 } END { exit !found }' \
        "${wf_gf_mounts}" 2>/dev/null; then
        wf_gf_is_mountsource=1
    fi
    case "${wf_gf_target}" in
        /dev/*)
            if [ "${wf_gf_is_mountsource}" = "1" ]; then
                wf_grow_log "refusing to resize ${wf_gf_target}: the device is mounted"
                printf 'fail:resize-target'
                return 0
            fi
            ;;
        *)
            if [ "${wf_gf_is_mountpoint}" != "1" ]; then
                wf_grow_log "refusing to resize ${wf_gf_target}: not a mount point"
                printf 'fail:resize-target'
                return 0
            fi
            ;;
    esac
    # btrfs-progs output is kept: the reason a resize failed (a busy device, a read-only
    # mount, a filesystem that is already at the end of the partition) is the only thing
    # that makes the failure diagnosable, and swallowing it cost a full CI round.
    if wf_gf_output="$("${WF_BTRFS}" filesystem resize max "${wf_gf_target}" 2>&1)"; then
        wf_grow_log "btrfs filesystem resize max ${wf_gf_target}: ${wf_gf_output:-ok}"
        printf 'done'
        return 0
    fi
    wf_grow_log "btrfs filesystem resize max ${wf_gf_target} failed: ${wf_gf_output:-no output}"
    wf_grow_diag "${wf_gf_target}" "${wf_gf_disk}"
    # Two fallbacks, both logged: the btrfs-progs in the image is old enough that some
    # forms behave differently, so the version, the explicit `1:max` form and the usage
    # table all go into the same log line set before giving up.
    wf_gf_version="$("${WF_BTRFS}" --version 2>&1 | head -n 1)" || wf_gf_version=""
    wf_grow_log "diag btrfs --version: ${wf_gf_version:-unknown}"
    if wf_gf_retry="$("${WF_BTRFS}" filesystem resize 1:max "${wf_gf_target}" 2>&1)"; then
        wf_grow_log "btrfs filesystem resize 1:max ${wf_gf_target} succeeded: ${wf_gf_retry:-ok}"
        printf 'done'
        return 0
    fi
    wf_grow_log "btrfs filesystem resize 1:max ${wf_gf_target} failed: ${wf_gf_retry:-no output}"
    "${WF_BTRFS}" filesystem usage "${wf_gf_target}" 2>&1 | while IFS= read -r wf_gf_line; do
        wf_grow_log "diag usage: ${wf_gf_line}"
    done
    printf 'fail:btrfs-resize'
}

# wf_grow_resize_mounted <device> <mount point> [<disk>]: the boot path's resize.
#
# The btrfs-progs in the image refuses an unmounted device ("not a directory: /dev/vda4"),
# so the filesystem is mounted for the resize — with the plainest possible options: no
# compress=, no discard=, no subvol=. A resize must not depend on the options a later
# mount happens to carry, and those are exactly what a failing resize has to be
# distinguished from. The mount is given back immediately; the caller then does the real
# option-carrying mount for the growth record.
#
# Prints `done`, `fail:resize-target`, `fail:resize-mount` or a token from wf_grow_fs.
wf_grow_resize_mounted() {
    wf_grm_dev="${1:-}"
    wf_grm_mp="${2:-}"
    wf_grm_disk="${3:-}"
    if [ -z "${wf_grm_dev}" ] || [ -z "${wf_grm_mp}" ]; then
        printf 'fail:resize-target'
        return 0
    fi
    mkdir -p "${wf_grm_mp}" 2>/dev/null || {
        printf 'fail:resize-mount'
        return 0
    }
    if ! wf_grm_err="$("${WF_MOUNT}" -t btrfs -o rw,noatime "${wf_grm_dev}" "${wf_grm_mp}" 2>&1)"; then
        wf_grow_log "clean mount of ${wf_grm_dev} on ${wf_grm_mp} failed: ${wf_grm_err:-no output}"
        printf 'fail:resize-mount'
        return 0
    fi
    wf_grow_log "resize pass: ${wf_grm_dev} on ${wf_grm_mp} without compress/discard/subvol"
    wf_grm_result="$(wf_grow_fs "${wf_grm_mp}" "${wf_grm_disk}")"
    if ! wf_grm_umount_err="$("${WF_UMOUNT}" "${wf_grm_mp}" 2>&1)"; then
        wf_grow_log "umount ${wf_grm_mp} after the resize failed: ${wf_grm_umount_err:-no output}"
        "${WF_UMOUNT}" "${wf_grm_mp}" >/dev/null 2>&1 || :
    fi
    printf '%s' "${wf_grm_result}"
}

# wf_grow_diag <target> [<disk>]: the three numbers that explain a failed resize — what
# the kernel thinks the device is, what btrfs-progs thinks the filesystem is, and the
# partition entry that claims the size. All of it goes to stderr (and the serial port),
# never to stdout.
wf_grow_diag() {
    wf_gd_target="${1:-}"
    wf_gd_disk="${2:-}"
    wf_gd_dev="${wf_gd_target}"
    wf_gd_parent=""
    if command -v di_parent_disk >/dev/null 2>&1; then
        wf_gd_parent="$(di_parent_disk "${wf_gd_target}" 2>/dev/null)" || wf_gd_parent=""
        if [ -n "${wf_gd_parent}" ]; then
            wf_gd_dev="${wf_gd_parent}"
        fi
    fi
    [ -n "${wf_gd_disk}" ] || wf_gd_disk="${wf_gd_dev}"
    "${WF_BTRFS}" filesystem show "${wf_gd_target}" 2>&1 | while IFS= read -r wf_gd_line; do
        wf_grow_log "diag btrfs: ${wf_gd_line}"
    done
    wf_gd_bytes="$("${WF_BLOCKDEV}" --getsize64 "${wf_gd_target}" 2>/dev/null)" || wf_gd_bytes=""
    if [ -n "${wf_gd_bytes}" ]; then
        wf_grow_log "diag device ${wf_gd_target}: ${wf_gd_bytes} bytes"
    fi
    if [ -n "${wf_gd_disk}" ]; then
        wf_gd_dir="${WF_GROW_TMP}/grow"
        mkdir -p "${wf_gd_dir}" 2>/dev/null
        if "${WF_SFDISK}" -d "${wf_gd_disk}" >"${wf_gd_dir}/partitions.diag" 2>/dev/null; then
            wf_gd_line="$(sed -n "s|^\(${wf_gd_target}[[:space:]]*:.*\)$|\1|p" \
                "${wf_gd_dir}/partitions.diag" 2>/dev/null | head -n 1)"
            if [ -n "${wf_gd_line}" ]; then
                wf_grow_log "diag table: ${wf_gd_line}"
            fi
        fi
    fi
    return 0
}

# wf_grow_backup <directory>: copy the pre-change partition table into
# `<directory>/.ab/partitions.before`. The dump is taken before the write and lives in
# the initramfs until p4 is mounted; this is what puts it on disk, through a rename so a
# reader never sees a half-written table. Non-zero only means "nothing to keep".
wf_grow_backup() {
    wf_gb_dir="$1"
    wf_gb_src="${WF_GROW_TMP}/grow/partitions.before"
    [ -n "${wf_gb_dir}" ] || return 1
    [ -f "${wf_gb_src}" ] || return 1
    mkdir -p "${wf_gb_dir}/.ab" 2>/dev/null || return 1
    wf_gb_tmp="${wf_gb_dir}/.ab/partitions.before.tmp"
    cat "${wf_gb_src}" >"${wf_gb_tmp}" 2>/dev/null || return 1
    sync
    mv "${wf_gb_tmp}" "${wf_gb_dir}/.ab/partitions.before" 2>/dev/null || return 1
    sync
    return 0
}

# wf_grow_record <directory> <state> <last_lba>: write the outcome as
# `result=<state> last_lba=<n>` through a temporary file and a rename, so a reader
# never sees a half-written line. <directory> is the p4 root subvolume mount point,
# which ab-boot mounts at /mnt/p4 at runtime.
wf_grow_record() {
    wf_grecord_dir="$1"
    wf_grecord_state="$2"
    wf_grecord_lba="${3:-0}"
    case "${wf_grecord_lba}" in
        '' | *[!0-9]*) wf_grecord_lba=0 ;;
    esac
    case "${wf_grecord_state}" in
        '') return 1 ;;
    esac
    mkdir -p "${wf_grecord_dir}/.ab" 2>/dev/null || return 1
    # Logged before the rename: the log is the part of the evidence that is append-only
    # across boots, so a reader of grow.log sees every record this disk ever held.
    wf_grow_log "record result=${wf_grecord_state} last_lba=${wf_grecord_lba} at ${wf_grecord_dir}/.ab/grow"
    wf_grecord_tmp="${wf_grecord_dir}/.ab/grow.tmp"
    printf 'result=%s last_lba=%s\n' "${wf_grecord_state}" "${wf_grecord_lba}" \
        >"${wf_grecord_tmp}" 2>/dev/null || return 1
    sync
    mv "${wf_grecord_tmp}" "${wf_grecord_dir}/.ab/grow" 2>/dev/null || return 1
    sync
    return 0
}
