#!/bin/sh
# disk-identity - which disk carries this system's four partitions.
#
# This is the only implementation of that question in the project. The boot initramfs,
# ab-boot, ab-slot and the upgrade tooling all ask it instead of hard-coding /dev/vda
# or concatenating a partition number onto a device name: `sda` + `1`, `nvme0n1` + `p1`
# and `mmcblk0` + `p1` are three naming styles, and guessing one of them on a real
# N5105 means the machine powers off before it ever reaches userspace.
#
# Public interface (stable; other units call these names and parse this output):
#
#   di_parent_disk <partition-dev>     -> /dev/sda | /dev/nvme0n1 | /dev/mmcblk0
#   di_sector_size <dev>               -> logical block size, 512 or 4096
#   di_lookup_partname <PARTNAME>      -> the partition device with that GPT name
#   di_lookup_partuuid <PARTUUID>      -> the partition device with that PARTUUID
#   di_resolve [esp-dir]               -> "disk=<dev> method=<token>", exit 0
#                                         "reason=<token>", exit 1 on failure
#   di_partition_on_disk <disk> <n>    -> the partition with PARTN=n on that disk
#
# The parent disk is always derived from sysfs, never from the device name:
# /sys/class/block/<part>/partition says the node is a partition, and the DEVNAME in the
# uevent one directory up (which follows the sysfs symlink to the real parent) is the
# disk. Nothing here needs to know whether the kernel spells it sda1, nvme0n1p1 or
# mmcblk0p1.
#
# Resolution order, first hit wins, and nothing below the first hit is consulted:
#
#   1. kernel parameters   ab.disk= then wf.dev=, accepted only when the reverse lookup
#                          confirms that disk carries ab-esp (tests and QEMU)
#   2. PARTUUID            <esp>/ab/device.json, four PARTUUIDs written at build time;
#                          a GPT is copied byte for byte by dd, so they survive flashing
#   3. PARTNAME            the ab-* GPT names, scanned through /sys/class/block/*/uevent
#   4. mount reverse       /proc/mounts entries for /boot, /mnt/p4 and /data, or the ESP
#                          partition the initramfs already mounted (DI_ESP_DEV)
#   5. unique candidate    exactly one non-removable disk whose partitions carry the
#                          four expected filesystem LABELs; zero or several is a failure
#
# A disk is only ever accepted when sysfs reports DEVTYPE=disk and removable=0, and the
# four partitions must all resolve to the same one: a split set is `partitions-split`
# and an undecidable set is `ambiguous-disk`. Both stop the partition table from being
# written; neither stops the boot.
#
# POSIX sh with no `local`: this runs under the busybox in the image. Every path and
# external command is overridable so tests can drive the whole state machine from a
# fixture sysfs tree (DI_SYS_BLOCK, DI_DEV_DIR, DI_CMDLINE, DI_MOUNTS, DI_BLKID, DI_ESP,
# DI_ESP_DEV), and the warnings go to stderr so stdout carries the one result line.

DI_SYS_BLOCK="${DI_SYS_BLOCK:-/sys/class/block}"
DI_DEV_DIR="${DI_DEV_DIR:-/dev}"
DI_CMDLINE="${DI_CMDLINE:-/proc/cmdline}"
DI_MOUNTS="${DI_MOUNTS:-/proc/mounts}"
DI_BLKID="${DI_BLKID:-blkid}"
# The ESP mount point: /boot in the running system, /esp in the initramfs (passed in).
DI_ESP="${DI_ESP:-/boot}"
# Set by the initramfs to the ESP partition it has already mounted, which is the
# mount reverse lookup for a system whose /proc/mounts has no /boot yet.
DI_ESP_DEV="${DI_ESP_DEV:-}"
# The filesystem LABELs the image sets, in partition order. Only the last resolution
# step uses them, and only on a disk that already looks like a whole disk.
DI_PART_LABELS="${DI_PART_LABELS:-ESP slot-a slot-b data}"

di_warn() {
    printf '[disk] %s\n' "$*" >&2
}

# di_devname <path-or-name>: the kernel name of a device.
di_devname() {
    case "$1" in
        '') return 1 ;;
        */*) printf '%s' "${1##*/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# di_dev_path <name>: the device node path in this environment.
di_dev_path() {
    printf '%s/%s' "${DI_DEV_DIR%/}" "$1"
}

# di_uevent_field <uevent> <field>: one value out of a sysfs uevent file.
di_uevent_field() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null
}

# di_known <dev>: does sysfs know this block device at all.
di_known() {
    di_k_name="$(di_devname "$1")" || return 1
    [ -n "${di_k_name}" ] || return 1
    [ -d "${DI_SYS_BLOCK}/${di_k_name}" ]
}

# di_is_partition <dev>: true when the node is a partition, which is the only case in
# which a parent disk exists.
di_is_partition() {
    di_ip_name="$(di_devname "$1")" || return 1
    [ -f "${DI_SYS_BLOCK}/${di_ip_name}/partition" ]
}

# di_disk_ok <disk>: a real disk, not a partition, not removable. This is the filter
# that keeps a USB stick or a loop device from ever being written to.
di_disk_ok() {
    di_dok_name="$(di_devname "$1")" || return 1
    [ -n "${di_dok_name}" ] || return 1
    di_dok_dir="${DI_SYS_BLOCK}/${di_dok_name}"
    [ -d "${di_dok_dir}" ] || return 1
    [ -f "${di_dok_dir}/partition" ] && return 1
    if [ -f "${di_dok_dir}/uevent" ]; then
        di_dok_type="$(di_uevent_field "${di_dok_dir}/uevent" DEVTYPE)"
        case "${di_dok_type}" in
            '' | disk) : ;;
            *) return 1 ;;
        esac
    fi
    if [ -r "${di_dok_dir}/removable" ]; then
        di_dok_rem="$(cat "${di_dok_dir}/removable" 2>/dev/null)"
        case "${di_dok_rem}" in
            0 | '') : ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# di_parent_disk <partition-dev>: the disk a partition belongs to, through sysfs.
#
# /sys/class/block/<part> is a symlink into the device tree, so <part>/.. resolves to
# the disk directory itself: the DEVNAME there is the disk, whatever its spelling.
di_parent_disk() {
    di_pp_name="$(di_devname "$1")" || return 1
    [ -n "${di_pp_name}" ] || return 1
    di_pp_dir="${DI_SYS_BLOCK}/${di_pp_name}"
    [ -d "${di_pp_dir}" ] || return 1
    [ -f "${di_pp_dir}/partition" ] || return 1
    di_pp_disk="$(di_uevent_field "${di_pp_dir}/../uevent" DEVNAME)"
    [ -n "${di_pp_disk}" ] || return 1
    di_dev_path "${di_pp_disk}"
}

# di_sector_size <dev>: the logical block size, which is the unit sfdisk reports
# partition sizes in. sysfs `size` is always in 512-byte units, so a 4Kn disk needs this
# conversion or every comparison is off by a factor of eight.
di_sector_size() {
    di_ss_name="$(di_devname "$1")" || {
        printf '512'
        return 0
    }
    di_ss_value=""
    for di_ss_file in \
        "${DI_SYS_BLOCK}/${di_ss_name}/queue/logical_block_size" \
        "${DI_SYS_BLOCK}/${di_ss_name}/../queue/logical_block_size"
    do
        [ -r "${di_ss_file}" ] || continue
        di_ss_value="$(cat "${di_ss_file}" 2>/dev/null)"
        case "${di_ss_value}" in
            '' | *[!0-9]* | 0) di_ss_value="" ;;
            *) break ;;
        esac
    done
    case "${di_ss_value}" in
        '' | *[!0-9]*) di_ss_value=512 ;;
    esac
    printf '%s' "${di_ss_value}"
}

# di_find_partition_by <uevent field> <value>: the first partition whose sysfs uevent
# carries that field with that value.
di_find_partition_by() {
    for di_fp_event in "${DI_SYS_BLOCK}"/*/uevent; do
        [ -f "${di_fp_event}" ] || continue
        di_fp_dir="$(dirname "${di_fp_event}")"
        [ -f "${di_fp_dir}/partition" ] || continue
        [ "$(di_uevent_field "${di_fp_event}" "$1")" = "$2" ] || continue
        di_fp_name="$(di_uevent_field "${di_fp_event}" DEVNAME)"
        [ -n "${di_fp_name}" ] || continue
        di_dev_path "${di_fp_name}"
        return 0
    done
    return 1
}

# di_find_partitions_by_name <PARTNAME>: every partition carrying that GPT name, one
# per line. Two disks with the same names is exactly the case that must be reported
# rather than resolved by "first one wins".
di_find_partitions_by_name() {
    for di_fa_event in "${DI_SYS_BLOCK}"/*/uevent; do
        [ -f "${di_fa_event}" ] || continue
        di_fa_dir="$(dirname "${di_fa_event}")"
        [ -f "${di_fa_dir}/partition" ] || continue
        [ "$(di_uevent_field "${di_fa_event}" PARTNAME)" = "$1" ] || continue
        di_fa_name="$(di_uevent_field "${di_fa_event}" DEVNAME)"
        [ -n "${di_fa_name}" ] || continue
        printf '%s\n' "$(di_dev_path "${di_fa_name}")"
    done
    return 0
}

# di_disk_has_partname <disk> <PARTNAME>: does that one disk carry the partition.
di_disk_has_partname() {
    di_hp_disk="$(di_dev_path "$(di_devname "$1")")" || return 1
    for di_hp_part in $(di_find_partitions_by_name "$2"); do
        di_hp_parent="$(di_parent_disk "${di_hp_part}")" || continue
        [ "${di_hp_parent}" = "${di_hp_disk}" ] || continue
        return 0
    done
    return 1
}

# di_lookup_partname <PARTNAME> [<disk>]: the partition with that GPT name.
#
# Two filters, both mandatory:
#
#   * a candidate whose parent disk is not a DEVTYPE=disk, removable=0 disk is never
#     returned, so a USB stick carrying a copy of the image can never be mounted as the
#     writable layer;
#   * when <disk> is given, only partitions on that disk are considered at all.
#
# Without the second filter the answer is "the first match in sysfs glob order", which on
# a machine with two copies of the image is the wrong disk; it is kept only for the case
# where no disk could be resolved.
di_lookup_partname() {
    [ -n "${1:-}" ] || return 1
    di_lp_want=""
    if [ -n "${2:-}" ]; then
        di_lp_want="$(di_dev_path "$(di_devname "$2")")" || return 1
        di_disk_ok "${di_lp_want}" || return 1
    fi
    for di_lp_part in $(di_find_partitions_by_name "$1"); do
        di_lp_parent="$(di_parent_disk "${di_lp_part}")" || continue
        di_disk_ok "${di_lp_parent}" || continue
        if [ -n "${di_lp_want}" ] && [ "${di_lp_parent}" != "${di_lp_want}" ]; then
            continue
        fi
        printf '%s' "${di_lp_part}"
        return 0
    done
    return 1
}

# di_lookup_partuuid <PARTUUID>: the partition with that UUID. blkid owns the table of
# GPT identifiers; there is no second parser of the on-disk GPT here.
di_lookup_partuuid() {
    [ -n "${1:-}" ] || return 1
    command -v "${DI_BLKID}" >/dev/null 2>&1 || return 1
    di_lu_want="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    for di_lu_tag in "$1" "$(printf '%s' "$1" | tr 'a-f' 'A-F')"; do
        di_lu_dev="$("${DI_BLKID}" -t "PARTUUID=${di_lu_tag}" -o device 2>/dev/null | head -n 1)"
        if [ -n "${di_lu_dev}" ] && di_known "${di_lu_dev}"; then
            printf '%s' "${di_lu_dev}"
            return 0
        fi
    done
    # An initramfs has no udev cache, so `blkid -t` can come back empty even though the
    # identifier is on the disk. Probe the partitions sysfs already shows instead.
    for di_lu_event in "${DI_SYS_BLOCK}"/*/uevent; do
        [ -f "${di_lu_event}" ] || continue
        di_lu_dir="$(dirname "${di_lu_event}")"
        [ -f "${di_lu_dir}/partition" ] || continue
        di_lu_name="$(di_uevent_field "${di_lu_event}" DEVNAME)"
        [ -n "${di_lu_name}" ] || continue
        di_lu_part="$(di_dev_path "${di_lu_name}")"
        di_lu_value="$("${DI_BLKID}" -p -o value -s PARTUUID "${di_lu_part}" 2>/dev/null | head -n 1)"
        di_lu_value="$(printf '%s' "${di_lu_value}" | tr 'A-F' 'a-f')"
        [ "${di_lu_value}" = "${di_lu_want}" ] || continue
        printf '%s' "${di_lu_part}"
        return 0
    done
    return 1
}

# di_partition_on_disk <disk> <PARTN>: the partition with that number on that disk.
# Used as the fallback when PARTNAME is not exposed, without ever gluing a digit (or a
# `p`) onto a device name.
di_partition_on_disk() {
    [ -n "${1:-}" ] || return 1
    di_pod_want="$(di_dev_path "$(di_devname "$1")")" || return 1
    # Only a real, non-removable disk is ever walked for a partition.
    di_disk_ok "${di_pod_want}" || return 1
    for di_pod_event in "${DI_SYS_BLOCK}"/*/uevent; do
        [ -f "${di_pod_event}" ] || continue
        di_pod_dir="$(dirname "${di_pod_event}")"
        [ -f "${di_pod_dir}/partition" ] || continue
        [ "$(di_uevent_field "${di_pod_event}" PARTN)" = "$2" ] || continue
        di_pod_name="$(di_uevent_field "${di_pod_event}" DEVNAME)"
        [ -n "${di_pod_name}" ] || continue
        di_pod_parent="$(di_parent_disk "$(di_dev_path "${di_pod_name}")")" || continue
        [ "${di_pod_parent}" = "${di_pod_want}" ] || continue
        di_dev_path "${di_pod_name}"
        return 0
    done
    return 1
}

# di_device_json <esp-dir>: the build-time identity file. It belongs at ab/device.json
# next to ab/state.json, which is where the runtime reads it from; the second candidate
# is the boot/ab/ layout an older build produced, kept so a machine flashed with such an
# image still resolves, with a warning instead of a silent difference.
di_device_json() {
    for di_dj_file in "$1/ab/device.json" "$1/boot/ab/device.json"; do
        [ -f "${di_dj_file}" ] || continue
        case "${di_dj_file}" in
            */boot/ab/device.json)
                di_warn "device identity file is at boot/ab/device.json, expected ab/device.json"
                ;;
        esac
        printf '%s' "${di_dj_file}"
        return 0
    done
    return 1
}

# di_find_partition <PARTNAME> <PARTN> [<disk>]: the partition the boot path should mount.
#
# This is the entry point for mounting, and it carries both filters so no caller has to
# remember them:
#
#   1. with a resolved disk, the partition number on that disk is tried first, and it is
#      only accepted when the kernel either does not expose PARTNAME at all or confirms
#      the same name at that number (a disk whose partition order differs is not trusted);
#   2. then the GPT name, still restricted to the resolved disk;
#   3. only when no disk could be resolved does the name alone answer, and even then a
#      partition on a removable disk is refused.
#
# A second disk with a copy of the image, or a USB stick, therefore cannot be mounted as
# the writable layer: the answer is either on the resolved disk or nothing.
di_find_partition() {
    di_fp_name="$1"
    di_fp_number="${2:-}"
    di_fp_disk="${3:-}"
    [ -n "${di_fp_name}" ] || return 1
    if [ -z "${di_fp_disk}" ]; then
        di_lookup_partname "${di_fp_name}"
        return $?
    fi
    if [ -n "${di_fp_number}" ]; then
        di_fp_by_number="$(di_partition_on_disk "${di_fp_disk}" "${di_fp_number}")" || di_fp_by_number=""
        if [ -n "${di_fp_by_number}" ]; then
            di_fp_by_name="$(di_lookup_partname "${di_fp_name}" "${di_fp_disk}")" || di_fp_by_name=""
            if [ -z "${di_fp_by_name}" ] || [ "${di_fp_by_name}" = "${di_fp_by_number}" ]; then
                printf '%s' "${di_fp_by_number}"
                return 0
            fi
            di_warn "${di_fp_disk} partition ${di_fp_number} is not ${di_fp_name}, using ${di_fp_by_name}"
        fi
    fi
    di_lookup_partname "${di_fp_name}" "${di_fp_disk}"
}

# di_partuuid_of_name <esp-dir> <PARTNAME>: the PARTUUID recorded for that partition at
# build time. The file is JSON with one "partuuid" per partition name; it is squeezed
# first so indentation and line breaks cannot matter, and no JSON library is needed.
di_partuuid_of_name() {
    di_pn_file="$(di_device_json "$1")" || return 1
    tr -d ' \t\r\n' <"${di_pn_file}" 2>/dev/null \
        | sed -n "s/.*\"$2\":{\"partuuid\":\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

# di_mount_disk: the disk behind a mount point the running system already has.
di_mount_disk() {
    for di_md_point in /boot /mnt/p4 /data; do
        di_md_dev="$(awk -v mp="${di_md_point}" '$2 == mp { print $1; exit }' "${DI_MOUNTS}" 2>/dev/null)"
        case "${di_md_dev}" in
            /dev/*) : ;;
            *) continue ;;
        esac
        if di_is_partition "${di_md_dev}"; then
            di_md_disk="$(di_parent_disk "${di_md_dev}")" || continue
        else
            di_md_disk="${di_md_dev}"
        fi
        di_disk_ok "${di_md_disk}" || continue
        printf '%s' "${di_md_disk}"
        return 0
    done
    if [ -n "${DI_ESP_DEV}" ] && di_is_partition "${DI_ESP_DEV}"; then
        di_md_disk="$(di_parent_disk "${DI_ESP_DEV}")" || return 1
        di_disk_ok "${di_md_disk}" || return 1
        printf '%s' "${di_md_disk}"
        return 0
    fi
    return 1
}

# di_label_of <dev>: the filesystem LABEL, for the last resolution step only.
di_label_of() {
    command -v "${DI_BLKID}" >/dev/null 2>&1 || return 1
    di_lo_value="$("${DI_BLKID}" -p -o value -s LABEL "$1" 2>/dev/null | head -n 1)"
    [ -n "${di_lo_value}" ] || return 1
    printf '%s' "${di_lo_value}"
}

# di_disk_has_our_labels <disk>: does this disk carry every expected filesystem LABEL.
di_disk_has_our_labels() {
    di_dl_disk="$(di_dev_path "$(di_devname "$1")")"
    for di_dl_want in ${DI_PART_LABELS}; do
        di_dl_hit=0
        for di_dl_event in "${DI_SYS_BLOCK}"/*/uevent; do
            [ -f "${di_dl_event}" ] || continue
            di_dl_dir="$(dirname "${di_dl_event}")"
            [ -f "${di_dl_dir}/partition" ] || continue
            di_dl_name="$(di_uevent_field "${di_dl_event}" DEVNAME)"
            [ -n "${di_dl_name}" ] || continue
            di_dl_dev="$(di_dev_path "${di_dl_name}")"
            di_dl_parent="$(di_parent_disk "${di_dl_dev}")" || continue
            [ "${di_dl_parent}" = "${di_dl_disk}" ] || continue
            [ "$(di_label_of "${di_dl_dev}")" = "${di_dl_want}" ] || continue
            di_dl_hit=1
            break
        done
        [ "${di_dl_hit}" = "1" ] || return 1
    done
    return 0
}

# di_cmdline_hints: the disks named on the kernel command line, strongest first.
di_cmdline_hints() {
    [ -r "${DI_CMDLINE}" ] || return 0
    for di_ch_arg in $(cat "${DI_CMDLINE}" 2>/dev/null); do
        case "${di_ch_arg}" in
            ab.disk=*) printf '%s\n' "${di_ch_arg#ab.disk=}" ;;
        esac
    done
    for di_ch_arg in $(cat "${DI_CMDLINE}" 2>/dev/null); do
        case "${di_ch_arg}" in
            wf.dev=*) printf '%s\n' "${di_ch_arg#wf.dev=}" ;;
        esac
    done
    return 0
}

# di_scan_parents <PARTNAME>: the parent disks that carry that name, space separated.
di_scan_parents() {
    for di_sp_entry in ${di_scan_map}; do
        case "${di_sp_entry}" in
            "$1="*)
                printf '%s' "${di_sp_entry#*=}" | tr ',' ' '
                return 0
                ;;
        esac
    done
    return 1
}

# di_resolve [esp-dir]: decide which disk this system lives on.
#
#   disk=<dev> method=<cmdline|partuuid|partname|mount|unique>   exit 0
#   reason=<partitions-split|ambiguous-disk|no-disk>            exit 1
di_resolve() {
    di_r_esp="${1:-${DI_ESP}}"
    # One scan decides two things at once: whether our own partition set is consistent
    # (every name on one disk) and whether another disk carries a stale copy of it.
    di_scan_map=""
    for di_sc_name in ab-esp ab-slot-a ab-slot-b ab-data; do
        di_sc_parents=""
        for di_sc_part in $(di_find_partitions_by_name "${di_sc_name}"); do
            di_sc_parent="$(di_parent_disk "${di_sc_part}")" || continue
            case " ${di_sc_parents} " in
                *" ${di_sc_parent} "*) : ;;
                *) di_sc_parents="${di_sc_parents}${di_sc_parents:+ }${di_sc_parent}" ;;
            esac
        done
        [ -n "${di_sc_parents}" ] || continue
        di_scan_map="${di_scan_map}${di_scan_map:+ }${di_sc_name}=$(printf '%s' "${di_sc_parents}" | tr ' ' ',')"
    done

    di_r_common=""
    di_r_split=0
    di_r_duplicate=0
    di_r_esp_count=0
    for di_r_parent in $(di_scan_parents ab-esp); do
        di_r_common="${di_r_parent}"
        di_r_esp_count=$((di_r_esp_count + 1))
    done
    if [ "${di_r_esp_count}" -gt 1 ]; then
        di_r_duplicate=1
        di_warn "ab-esp exists on more than one disk, the partition set is a copy"
    fi
    for di_sc_entry in ${di_scan_map}; do
        di_sc_name="${di_sc_entry%%=*}"
        di_sc_parents="$(printf '%s' "${di_sc_entry#*=}" | tr ',' ' ')"
        di_sc_count=0
        for di_sc_parent in ${di_sc_parents}; do
            di_sc_count=$((di_sc_count + 1))
        done
        if [ "${di_sc_count}" -gt 1 ]; then
            di_r_duplicate=1
            di_warn "${di_sc_name} exists on more than one disk"
        fi
        if [ "${di_r_esp_count}" -eq 1 ] && [ -n "${di_r_common}" ]; then
            case " ${di_sc_parents} " in
                *" ${di_r_common} "*) : ;;
                *)
                    di_r_split=1
                    di_warn "${di_sc_name} is not on ${di_r_common}"
                    ;;
            esac
        fi
    done

    # 1. kernel parameters. A hint is evidence only when that disk carries ab-esp, which
    # is also what settles a disk that carries a stale copy of our partition set: the
    # operator, or the test harness, names the live one.
    for di_r_hint in $(di_cmdline_hints); do
        di_r_hint_dev="$(di_dev_path "$(di_devname "${di_r_hint}")")" || continue
        if di_disk_ok "${di_r_hint_dev}" && di_disk_has_partname "${di_r_hint_dev}" ab-esp; then
            printf 'disk=%s method=cmdline\n' "${di_r_hint_dev}"
            return 0
        fi
        di_warn "ignoring kernel parameter disk ${di_r_hint_dev}: it does not carry ab-esp"
    done

    # 2. PARTUUID recorded on the ESP at build time.
    di_r_uuid="$(di_partuuid_of_name "${di_r_esp}" ab-esp)" || di_r_uuid=""
    if [ -n "${di_r_uuid}" ]; then
        di_r_part="$(di_lookup_partuuid "${di_r_uuid}")" || di_r_part=""
        if [ -n "${di_r_part}" ]; then
            di_r_disk="$(di_parent_disk "${di_r_part}")" || di_r_disk=""
            if [ -n "${di_r_disk}" ] && di_disk_ok "${di_r_disk}"; then
                if [ -n "${di_r_common}" ] && [ "${di_r_disk}" != "${di_r_common}" ]; then
                    di_warn "device.json says ${di_r_disk}, the ab-* names were found on ${di_r_common}"
                fi
                printf 'disk=%s method=partuuid\n' "${di_r_disk}"
                return 0
            fi
        fi
    fi

    # Refusals come before anything answers "first match wins": our own set spread over
    # two disks, or our set existing twice, is not something to guess about. Both stop
    # the partition table from being written and both keep the boot going.
    if [ "${di_r_split}" = "1" ]; then
        printf 'reason=partitions-split'
        return 1
    fi
    if [ "${di_r_duplicate}" = "1" ]; then
        di_warn "more than one disk carries the ab-* names, refusing to choose"
        printf 'reason=ambiguous-disk'
        return 1
    fi

    # 3. PARTNAME.
    if [ -n "${di_r_common}" ] && di_disk_ok "${di_r_common}"; then
        printf 'disk=%s method=partname\n' "${di_r_common}"
        return 0
    fi

    # 4. mount reverse lookup.
    di_r_mount="$(di_mount_disk)" || di_r_mount=""
    if [ -n "${di_r_mount}" ]; then
        printf 'disk=%s method=mount\n' "${di_r_mount}"
        return 0
    fi

    # 5. the only disk that can be ours, or nothing.
    di_r_candidates=""
    di_r_count=0
    for di_r_event in "${DI_SYS_BLOCK}"/*/uevent; do
        [ -f "${di_r_event}" ] || continue
        di_r_dir="$(dirname "${di_r_event}")"
        [ -f "${di_r_dir}/partition" ] && continue
        di_r_name="$(di_uevent_field "${di_r_event}" DEVNAME)"
        [ -n "${di_r_name}" ] || di_r_name="$(basename "${di_r_dir}")"
        di_r_dev="$(di_dev_path "${di_r_name}")"
        di_disk_ok "${di_r_dev}" || continue
        di_disk_has_our_labels "${di_r_dev}" || continue
        di_r_candidates="${di_r_candidates} ${di_r_dev}"
        di_r_count=$((di_r_count + 1))
    done
    case "${di_r_count}" in
        0)
            di_warn "no non-removable disk carries the four partitions"
            printf 'reason=no-disk'
            return 1
            ;;
        1)
            printf 'disk=%s method=unique\n' "${di_r_candidates# }"
            return 0
            ;;
        *)
            di_warn "several disks could be ours:${di_r_candidates}"
            printf 'reason=ambiguous-disk'
            return 1
            ;;
    esac
}
