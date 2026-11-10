#!/bin/sh
# Helpers for the first-boot growth of p4 and for recording its outcome.
#
# Sourced by initramfs/boot/init and exercised by tests/modules/boot/, so everything
# here is POSIX sh (no `local`, no arrays) and every command it calls is overridable:
# the test suite drives the whole state machine from fixture partition tables without
# a loop device, a btrfs filesystem, or root.
#
# The image ships p4 with 64 MiB and leaves the rest of the disk unallocated. First
# boot moves p4's end to the last usable LBA and then resizes the filesystem:
#
#   1. `sfdisk -d` dumps the table; the dump is kept as the pre-change backup and, once
#      p4 is mounted, copied to `.ab/partitions.before` on the p4 root subvolume so the
#      old geometry survives a crash instead of dying with the initramfs
#   2. the decision is `already-full` when p4 already ends at the last usable LBA,
#      otherwise the new size is computed so the table can only ever grow
#   3. the dump is copied to a second file and only the p4 `size=` field changes
#   4. `sfdisk --no-reread` writes that file back, so the backup GPT is relocated to
#      the new end of the disk as part of the same write
#   5. `blockdev --rereadpt` (or `partx -u`) makes the kernel see the new size, which
#      is verified in sysfs before the filesystem is touched
#   6. after the p4 mount, `btrfs filesystem resize max` grows the filesystem
#
# Outcomes, written to `<p4 root subvolume>/.ab/grow` as `result=<token> last_lba=<n>`:
#
#   done            table and filesystem grew
#   already-full    p4 already reached the end of the disk; nothing was written
#   missing-sfdisk  no sfdisk in this initramfs; nothing was written
#   fail:<token>    a step failed; the boot continues on the old geometry
#
# Nothing in this file may stop a boot: every failure is returned as a token, and the
# caller records it and carries on. Growth is idempotent because the decision compares
# p4's end with the last usable LBA, and it never shrinks a partition.

WF_SFDISK="${WF_SFDISK:-sfdisk}"
WF_BLOCKDEV="${WF_BLOCKDEV:-blockdev}"
WF_PARTX="${WF_PARTX:-partx}"
WF_BTRFS="${WF_BTRFS:-btrfs}"
WF_SLEEP="${WF_SLEEP:-sleep}"
WF_MOUNT="${WF_MOUNT:-mount}"
WF_UMOUNT="${WF_UMOUNT:-umount}"
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
# Re-reading a partition table is asynchronous on some kernels, so the size check is
# retried instead of trusted on the first read.
WF_GROW_VERIFY_TRIES="${WF_GROW_VERIFY_TRIES:-5}"

# wf_grow_log <line...>: diagnostics go to stderr so callers can capture the single
# result token from stdout without losing the log. When the boot initramfs has loaded
# lib/wf.sh (it does, it sources both), the line is also mirrored to the serial port
# through wf_say_serial — never to stdout, which belongs to the result.
wf_grow_log() {
    printf '[grow] %s\n' "$*" >&2
    # The serial mirror is a side channel, never stdout: wf_grow_run's stdout is the
    # parsed result and must stay exactly one line.
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

# wf_grow_reread <disk>: make the kernel re-read the table. blockdev is the direct
# interface; partx drives the same ioctl and is used when blockdev is not shipped.
wf_grow_reread() {
    if "${WF_BLOCKDEV}" --rereadpt "$1" >/dev/null 2>&1; then
        wf_grow_log "kernel table re-read via ${WF_BLOCKDEV} --rereadpt"
        return 0
    fi
    if command -v "${WF_PARTX}" >/dev/null 2>&1; then
        if "${WF_PARTX}" -u "$1" >/dev/null 2>&1; then
            wf_grow_log "kernel table re-read via ${WF_PARTX} -u"
            return 0
        fi
    fi
    return 1
}

# wf_grow_apply <disk> <p4device> <new size> <dump in>: write the grown table, make the
# kernel see it, and verify the device really became <new size> sectors.
wf_grow_apply() {
    wf_ga_disk="$1"
    wf_ga_p4="$2"
    wf_ga_size="$3"
    wf_ga_in="$4"
    wf_ga_last="${5:-}"
    wf_ga_out="$(dirname "${wf_ga_in}")/partitions.after"
    wf_grow_table "${wf_ga_in}" "${wf_ga_out}" "${wf_ga_p4}" "${wf_ga_size}" "${wf_ga_last}" || {
        printf 'fail:partition-table-rewrite'
        return 0
    }
    wf_ga_before="$(wf_grow_sectors "${wf_ga_p4}")" || wf_ga_before=""
    if ! wf_ga_err="$("${WF_SFDISK}" --no-reread "${wf_ga_disk}" <"${wf_ga_out}" 2>&1)"; then
        wf_grow_log "writing the partition table failed: ${wf_ga_err:-no output}"
        printf 'fail:partition-table-write'
        return 0
    fi
    wf_grow_log "partition table written with p4 size ${wf_ga_size}"
    wf_grow_reread "${wf_ga_disk}" || {
        printf 'fail:partition-table-reread'
        return 0
    }
    wf_ga_try=0
    while [ "${wf_ga_try}" -lt "${WF_GROW_VERIFY_TRIES}" ]; do
        wf_ga_after="$(wf_grow_sectors "${wf_ga_p4}")" || wf_ga_after=""
        if [ "${wf_ga_after}" = "${wf_ga_size}" ]; then
            case "${wf_ga_before}" in
                '' | *[!0-9]*)
                    printf 'done'
                    return 0
                    ;;
            esac
            if [ "${wf_ga_after}" -gt "${wf_ga_before}" ]; then
                printf 'done'
                return 0
            fi
            printf 'fail:size-not-increased'
            return 0
        fi
        wf_ga_try=$((wf_ga_try + 1))
        "${WF_SLEEP}" 1 2>/dev/null || :
    done
    printf 'fail:size-unchanged'
}

# wf_grow_run <disk> <p4device>: the whole pre-mount step. Prints exactly
# "<state> <last_lba>" on stdout, where <state> is done, already-full, missing-sfdisk or
# fail:<token>; <last_lba> is 0 when the table was never readable.
wf_grow_run() {
    wf_gr_disk="$1"
    wf_gr_p4="$2"
    if ! command -v "${WF_SFDISK}" >/dev/null 2>&1; then
        wf_grow_log "${WF_SFDISK} is not in this initramfs, leaving the disk untouched"
        printf 'missing-sfdisk 0'
        return 0
    fi
    wf_gr_dir="${WF_GROW_TMP}/grow"
    wf_gr_dump="${wf_gr_dir}/partitions.before"
    mkdir -p "${wf_gr_dir}" 2>/dev/null || {
        printf 'fail:workdir 0'
        return 0
    }
    if ! "${WF_SFDISK}" -d "${wf_gr_disk}" >"${wf_gr_dump}" 2>/dev/null; then
        wf_grow_log "cannot dump the partition table of ${wf_gr_disk}"
        printf 'fail:partition-table-read 0'
        return 0
    fi
    wf_gr_sectors="$(wf_grow_disk_sectors "${wf_gr_disk}")" || wf_gr_sectors=""
    wf_gr_decision="$(wf_grow_decide "${wf_gr_dump}" "${wf_gr_p4}" "${wf_gr_sectors}")"
    case "${wf_gr_decision}" in
        already-full\ *)
            printf 'already-full %s' "${wf_gr_decision#already-full }"
            return 0
            ;;
        grow\ *)
            wf_gr_rest="${wf_gr_decision#grow }"
            wf_gr_lba="${wf_gr_rest%% *}"
            wf_gr_size="${wf_gr_rest##* }"
            wf_gr_applied="$(wf_grow_apply "${wf_gr_disk}" "${wf_gr_p4}" "${wf_gr_size}" "${wf_gr_dump}" "${wf_gr_lba}")"
            case "${wf_gr_applied}" in
                done) printf 'done %s' "${wf_gr_lba}" ;;
                *) printf '%s %s' "${wf_gr_applied}" "${wf_gr_lba}" ;;
            esac
            return 0
            ;;
        *)
            printf '%s 0' "${wf_gr_decision}"
            return 0
            ;;
    esac
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
    wf_grecord_tmp="${wf_grecord_dir}/.ab/grow.tmp"
    printf 'result=%s last_lba=%s\n' "${wf_grecord_state}" "${wf_grecord_lba}" \
        >"${wf_grecord_tmp}" 2>/dev/null || return 1
    sync
    mv "${wf_grecord_tmp}" "${wf_grecord_dir}/.ab/grow" 2>/dev/null || return 1
    sync
    return 0
}
