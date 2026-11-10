#!/bin/sh
# ab-partitions - the device nodes the boot path mounts.
#
# The identity of the disk and the lookup of its partitions are not decided here.
# platform/lib/disk-identity.sh is the only implementation of that question, and this
# file is the thin glue the platform services share so none of them repeats the lookup:
#
#   ab_disk_identity                    -> "disk=<dev> method=<token>"   (di_resolve)
#   ab_disk_device                      -> /dev/sda
#   ab_partition_by_name <name> [<disk>]-> the partition with that GPT name
#   ab_partition_by_number <disk> <n>   -> the partition with PARTN=<n> on that disk
#   ab_find_partition <name> <n>        -> the partition of the disk we booted from
#
# The disk comes first, always. A partition is only ours when it sits on the disk
# `di_resolve` identified, so a second disk that happens to carry the same `ab-*` GPT
# names -- another installed disk, or a USB stick holding a copy of our image -- can
# never be mounted by accident. PARTNAME is only a name: two disks can both have an
# `ab-esp`, and picking the first match is exactly the wrong answer.
#
# The name lookup is therefore scoped: it is asked with the resolved disk when the
# library supports that argument, and its answer is checked against `di_parent_disk`
# anyway. Only when no disk can be identified at all does the name stand alone, and
# then only an unambiguous name on exactly one usable (non-removable) disk is accepted.
# Anything else returns non-zero and the caller degrades: no mount, a logged
# `disk=unknown`, never a guessed device.
#
# POSIX sh with no `local`; every variable is prefixed abp_.

AB_DISK_IDENTITY_LIB="${AB_DISK_IDENTITY_LIB:-/lib/disk-identity.sh}"

# Loaded once, when the platform layer ships it. The functions below check for the
# helpers they need instead of assuming a version.
AB_DISK_IDENTITY_OK=0
if [ -f "${AB_DISK_IDENTITY_LIB}" ]; then
    # shellcheck source=platform/lib/disk-identity.sh
    . "${AB_DISK_IDENTITY_LIB}"
    AB_DISK_IDENTITY_OK=1
fi

# ab_have <function>: is this helper exported by the identity library.
ab_have() {
    [ "${AB_DISK_IDENTITY_OK}" = "1" ] || return 1
    command -v "$1" >/dev/null 2>&1
}

# ab_disk_identity: the disk and how it was found, one line, or non-zero.
ab_disk_identity() {
    ab_have di_resolve || return 1
    abp_resolved="$(di_resolve 2>/dev/null)" || return 1
    case "${abp_resolved}" in
        disk=*) printf '%s' "${abp_resolved}" ;;
        *) return 1 ;;
    esac
}

# ab_disk_device: just the device node of the disk, or non-zero.
ab_disk_device() {
    abp_identity="$(ab_disk_identity)" || return 1
    abp_device="${abp_identity#disk=}"
    abp_device="${abp_device%% *}"
    [ -n "${abp_device}" ] || return 1
    printf '%s' "${abp_device}"
}

# ab_disk_usable <disk-dev>: a real, non-removable disk, when the library can say so.
ab_disk_usable() {
    if ! ab_have di_disk_ok; then
        # Older library: no filter available, so no claim to make.
        return 1
    fi
    di_disk_ok "$1" 2>/dev/null
}

# ab_partition_by_name <partname> [<disk>]: the partition whose GPT name matches.
#
# With a disk the answer has to sit on that disk: the scope is passed to the library
# and then re-checked here through the parent, so a library that does not filter yet
# cannot hand back a partition of the other disk.
ab_partition_by_name() {
    abp_name="$1"
    abp_scope="${2:-}"
    ab_have di_lookup_partname || return 1
    if [ -n "${abp_scope}" ]; then
        abp_found="$(di_lookup_partname "${abp_name}" "${abp_scope}" 2>/dev/null)" || return 1
    else
        abp_found="$(di_lookup_partname "${abp_name}" 2>/dev/null)" || return 1
    fi
    [ -n "${abp_found}" ] || return 1
    if [ -n "${abp_scope}" ]; then
        ab_have di_parent_disk || return 1
        abp_parent="$(di_parent_disk "${abp_found}" 2>/dev/null)" || return 1
        [ "${abp_parent}" = "${abp_scope}" ] || return 1
    fi
    printf '%s' "${abp_found}"
}

# ab_partition_by_number <disk> <number>: the partition with that PARTN on that disk.
ab_partition_by_number() {
    ab_have di_partition_on_disk || return 1
    abp_found="$(di_partition_on_disk "$1" "$2" 2>/dev/null)" || return 1
    [ -n "${abp_found}" ] || return 1
    printf '%s' "${abp_found}"
}

# ab_partition_by_unique_name <partname>: the name on exactly one usable disk.
#
# The last resort, used only when no disk could be identified. Every partition carrying
# the name is collected, removable and non-disk parents are dropped, and the answer is
# accepted only when one disk is left. Two disks carrying the same names is the case
# that must be reported, not resolved by "first one wins".
ab_partition_by_unique_name() {
    ab_have di_find_partitions_by_name || return 1
    ab_have di_parent_disk || return 1
    abp_candidate=""
    abp_disk=""
    abp_disks=0
    # `set -u` callers must not trip over an unset accumulator.
    abp_seen=""
    for abp_part in $(di_find_partitions_by_name "$1" 2>/dev/null); do
        abp_parent="$(di_parent_disk "${abp_part}" 2>/dev/null)" || continue
        ab_disk_usable "${abp_parent}" || continue
        case " ${abp_seen} " in
            *" ${abp_parent} "*)
                # The same disk again: keep the first partition of it.
                continue
                ;;
        esac
        abp_seen="${abp_seen}${abp_seen:+ }${abp_parent}"
        abp_disks=$((abp_disks + 1))
        abp_disk="${abp_parent}"
        abp_candidate="${abp_part}"
    done
    [ "${abp_disks}" = "1" ] || return 1
    [ -n "${abp_candidate}" ] || return 1
    printf '%s' "${abp_candidate}"
}

# ab_find_partition <partname> <number>: the partition the callers should mount.
ab_find_partition() {
    # 1. the disk we booted from decides. Nothing below this line may return a
    #    partition that is not on it.
    if abp_boot_disk="$(ab_disk_device)"; then
        ab_partition_by_number "${abp_boot_disk}" "$2" && return 0
        ab_partition_by_name "$1" "${abp_boot_disk}" && return 0
        return 1
    fi
    # 2. no disk: the name alone, and only when it is unambiguous.
    ab_partition_by_unique_name "$1"
}
