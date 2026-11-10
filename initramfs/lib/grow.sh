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
WF_SYS_BLOCK="${WF_SYS_BLOCK:-/sys/class/block}"
WF_GROW_TMP="${WF_GROW_TMP:-/run}"
# sysfs `size` is always in 512-byte units, while sfdisk reports partition sizes in
# logical sectors: on a 4Kn disk those differ by a factor of eight, so every conversion
# goes through the device's logical block size (see wf_grow_sector_size).
WF_SECTOR_BYTES="${WF_SECTOR_BYTES:-512}"
# The end of a GPT disk is unusable: 32 sectors of backup entry array plus one header
# sector. The last usable LBA is therefore total_sectors - 34, which is also what
# sfdisk prints as `last-lba`; the value is only computed when the dump omits it.
WF_GPT_TAIL_SECTORS="${WF_GPT_TAIL_SECTORS:-34}"
# Re-reading a partition table is asynchronous on some kernels, so the size check is
# retried instead of trusted on the first read.
WF_GROW_VERIFY_TRIES="${WF_GROW_VERIFY_TRIES:-5}"

# wf_grow_log <line...>: diagnostics go to stderr so callers can capture the single
# result token from stdout without losing the log. When the boot initramfs has loaded
# lib/wf.sh (it does, it sources both), the line also reaches every console through
# wf_say: a `[grow]` line that only lands on the local screen is not evidence.
wf_grow_log() {
    if command -v wf_say >/dev/null 2>&1; then
        wf_say "[grow] $*"
        return 0
    fi
    printf '[grow] %s\n' "$*" >&2
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
    wf_gl_value="$(sed -n 's/^last-lba:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)"
    case "${wf_gl_value}" in
        '' | *[!0-9]*) : ;;
        *)
            printf '%s' "${wf_gl_value}"
            return 0
            ;;
    esac
    case "${2:-}" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$(($2 - WF_GPT_TAIL_SECTORS))"
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
    printf 'grow %s %s' "${wf_gd_last}" "$((wf_gd_last - wf_gd_start + 1))"
}

# wf_grow_table <dump in> <dump out> <p4device> <new size>: copy the dump, replacing
# the size field of the p4 line and nothing else. Every other line, including the
# table UUID and the other three partitions, must come out byte-identical, which is
# what keeps the ESP and both slots addressable by the same identifiers after growth.
wf_grow_table() {
    awk -v dev="$3" -v size="$4" '
        BEGIN { changed = 0 }
        {
            name = $1
            sub(/:$/, "", name)
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
    wf_ga_out="$(dirname "${wf_ga_in}")/partitions.after"
    wf_grow_table "${wf_ga_in}" "${wf_ga_out}" "${wf_ga_p4}" "${wf_ga_size}" || {
        printf 'fail:partition-table-rewrite'
        return 0
    }
    wf_ga_before="$(wf_grow_sectors "${wf_ga_p4}")" || wf_ga_before=""
    "${WF_SFDISK}" --no-reread "${wf_ga_disk}" <"${wf_ga_out}" >/dev/null 2>&1 || {
        printf 'fail:partition-table-write'
        return 0
    }
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
            wf_gr_applied="$(wf_grow_apply "${wf_gr_disk}" "${wf_gr_p4}" "${wf_gr_size}" "${wf_gr_dump}")"
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

# wf_grow_fs <p4 mount point>: grow the filesystem to the partition it now sits on.
# Prints `done`, `fail:resize-target` or `fail:btrfs-resize`; the caller decides what to
# record.
#
# The argument is a MOUNT POINT, never the device: `btrfs filesystem resize max /dev/vda4`
# has no filesystem to name and fails, and a resize that silently did nothing would leave
# a grown partition with a 64 MiB filesystem. The mount table is checked first so that
# mistake cannot reach btrfs-progs at all.
wf_grow_fs() {
    wf_gf_target="${1:-}"
    [ -n "${wf_gf_target}" ] || {
        printf 'fail:resize-target'
        return 0
    }
    case "${wf_gf_target}" in
        /dev/*)
            printf 'fail:resize-target'
            return 0
            ;;
    esac
    if ! awk -v mp="${wf_gf_target}" '$2 == mp { found = 1 } END { exit !found }' \
        "${WF_MOUNTS:-/proc/mounts}" 2>/dev/null; then
        printf 'fail:resize-target'
        return 0
    fi
    # btrfs-progs output is kept: the reason a resize failed (a busy device, a read-only
    # mount, a filesystem that is already at the end of the partition) is the only thing
    # that makes the failure diagnosable, and swallowing it cost a full CI round.
    if wf_gf_output="$("${WF_BTRFS}" filesystem resize max "${wf_gf_target}" 2>&1)"; then
        wf_grow_log "btrfs filesystem resize max ${wf_gf_target}: ${wf_gf_output:-ok}"
        printf 'done'
        return 0
    fi
    wf_grow_log "btrfs filesystem resize max ${wf_gf_target} failed: ${wf_gf_output:-no output}"
    printf 'fail:btrfs-resize'
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
