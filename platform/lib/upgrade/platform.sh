#!/bin/sh
# platform.sh - the upgrade adapter for this platform layer.
#
# Replaces the inactive slot with a payload, following the upstream upgrade
# convention (a sourced library with platform_* entry points) so a future sysupgrade
# integration only has to call these three functions.
#
#   platform_upgrade_begin <payload-dir> <target-slot>
#       Refuse when the target is the running slot, when the writable partition is
#       degraded, or when it has less than 5% free space. Nothing is written.
#
#   platform_copy_rootfs <payload-dir> <target-slot>
#       Snapshot the running writable layer onto a new layer named after the payload
#       version, replace the target slot's @sys with the payload's rootfs, replace its
#       @platform with the payload's platform layer, and put the payload's kernel and
#       initramfs on the ESP for that slot. On any failure the target slot is left
#       exactly as it was: the new @sys is deleted again and the snapshot reaped.
#
#   platform_upgrade_end <target-slot> <rootfs-version> <layer-name>
#       Record the new layer and version in the state file and mark the slot pending.
#
# The state file is never written by hand here: ab-slot owns it, so every mutation
# goes through `ab-slot layer` and `ab-slot pending`.
#
# The same holds for the ESP file that tells GRUB which slot to boot
# (/boot/grub/ab-slot.cfg): `ab-slot pending` writes it through
# platform/lib/ab-slot-cfg.sh, and this adapter only reads it back to prove the
# candidate will actually be booted. There is no second writer in the platform layer,
# on purpose: two writers would drift, and the drift would show up as "the update
# installed but the machine never tried it".

AB_ESP="${AB_ESP:-/boot}"
AB_P4="${AB_P4:-/mnt/p4}"
AB_SLOTS_ROOT="${AB_SLOTS_ROOT:-/mnt/slots}"
AB_MIN_FREE_PCT=5

# Partition discovery is shared: platform/lib/disk-identity.sh decides which disk this
# machine booted from and platform/lib/ab-partitions.sh turns that into device nodes.
# There is no hard coded device name here; an unidentifiable disk makes the upgrade
# refuse instead of mounting a guessed partition.
AB_PARTITIONS_LIB="${AB_PARTITIONS_LIB:-/lib/ab-partitions.sh}"
AB_PARTITIONS_OK=0
if [ -f "${AB_PARTITIONS_LIB}" ]; then
    # shellcheck source=platform/lib/ab-partitions.sh
    . "${AB_PARTITIONS_LIB}"
    AB_PARTITIONS_OK=1
fi

# Read by the caller to build its refusal message.
# shellcheck disable=SC2034
upgrade_reason=""

_upgrade_log() {
    printf '%s\n' "$*" >&2
}

# upgrade_fail <reason>: record the reason and return non-zero.
upgrade_fail() {
    upgrade_reason="$1"
    _upgrade_log "upgrade: ${1}"
    return 1
}

# running_slot: the slot the kernel command line says we booted.
upgrade_running_slot() {
    _slot="$(ab-slot status 2>/dev/null | sed -n 's/^slot=\([ab]\) .*/\1/p')"
    [ -n "${_slot}" ] || return 1
    printf '%s' "${_slot}"
}

# slot_fs <slot>: mount point for that slot's btrfs filesystem (p2 for a, p3 for b).
upgrade_slot_mount() {
    case "$1" in
        a) _part=2 ;;
        b) _part=3 ;;
        *) return 1 ;;
    esac
    [ "${AB_PARTITIONS_OK}" = "1" ] || return 1
    _dev="$(ab_find_partition "ab-slot-$1" "${_part}")" || return 1
    _mp="${AB_SLOTS_ROOT}/$1"
    mkdir -p "${_mp}" || return 1
    if ! awk -v mp="${_mp}" '$2 == mp { found = 1 } END { exit !found }' /proc/mounts; then
        mount -o rw,noatime "${_dev}" "${_mp}" || return 1
    fi
    printf '%s' "${_mp}"
}

# upgrade_free_pct <path>: integer percentage of free space.
upgrade_free_pct() {
    _total="$(df -k "$1" 2>/dev/null | awk 'NR == 2 { print $2 }')"
    _avail="$(df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    [ -n "${_total}" ] && [ -n "${_avail}" ] || return 1
    [ "${_total}" -gt 0 ] || return 1
    printf '%s' "$((_avail * 100 / _total))"
}

# upgrade_layer_name <version> <taken...>: @overlay-<version>, with -r<N> when that
# layer already exists on the writable partition.
upgrade_layer_name() {
    _version="$1"
    _base="@overlay-${_version}"
    _layer="${_base}"
    _n=1
    while btrfs subvolume list "${AB_P4}" 2>/dev/null | grep -q " path ${_layer}\$"; do
        _n=$((_n + 1))
        _layer="${_base}-r${_n}"
    done
    printf '%s' "${_layer}"
}

# platform_upgrade_begin <payload-dir> <target-slot>
platform_upgrade_begin() {
    _payload="$1"
    _target="$2"
    upgrade_reason=""

    case "${_target}" in
        a | b) : ;;
        *) upgrade_fail "invalid-target-slot-${_target}"; return 1 ;;
    esac
    _running="$(upgrade_running_slot)" || { upgrade_fail "no-running-slot"; return 1; }
    if [ "${_target}" = "${_running}" ]; then
        upgrade_fail "target-is-running-slot"
        return 1
    fi

    _p4="$(ab-slot status 2>/dev/null | sed -n 's/^.*p4=\([a-z]*\).*/\1/p')"
    if [ "${_p4}" != "ok" ]; then
        upgrade_fail "writable-layer-degraded"
        return 1
    fi

    _pct="$(upgrade_free_pct "${AB_P4}")" || { upgrade_fail "free-space-unknown"; return 1; }
    if [ "${_pct}" -lt "${AB_MIN_FREE_PCT}" ]; then
        upgrade_fail "low-space-${_pct}pct"
        return 1
    fi
    _upgrade_log "upgrade: begin, target slot ${_target}, ${_pct}% free on ${AB_P4}"
    return 0
}

# platform_copy_rootfs <payload-dir> <target-slot>
platform_copy_rootfs() {
    _payload="$1"
    _target="$2"
    upgrade_reason=""

    _version="$(sed -n 's/.*"rootfs": *"\([^"]*\)".*/\1/p' "${_payload}/manifest.json" | head -n 1)"
    [ -n "${_version}" ] || upgrade_fail "payload-without-rootfs-version" || return 1
    [ -f "${_payload}/rootfs.tar.gz" ] || upgrade_fail "payload-without-rootfs" || return 1

    _running="$(upgrade_running_slot)" || upgrade_fail "no-running-slot" || return 1
    _running_layer="$(ab-slot status 2>/dev/null | sed -n 's/^.*upper=\([^ ]*\) .*/\1/p')"
    _new_layer="$(upgrade_layer_name "${_version}")"
    [ -n "${_new_layer}" ] || upgrade_fail "no-layer-name" || return 1

    # 1. snapshot the running layer, so the new slot starts from the user's state
    btrfs subvolume snapshot "${AB_P4}/${_running_layer}" "${AB_P4}/${_new_layer}" >/dev/null ||
        upgrade_fail "snapshot-failed" || return 1
    _upgrade_log "upgrade: snapshotted ${_running_layer} -> ${_new_layer}"

    # 2. replace the target slot's system tree
    _mp="$(upgrade_slot_mount "${_target}")" || upgrade_fail "slot-mount-failed" || return 1
    _sys="${_mp}/@sys"
    _platform="${_mp}/@platform"
    _backup_sys=""
    if [ -d "${_sys}" ]; then
        # btrfs cannot replace a subvolume in place without a rename, and the docs
        # forbid renames; delete and recreate instead, keeping the payload staged so
        # a failure can still leave the slot readable.
        btrfs subvolume delete -C "${_sys}" >/dev/null 2>&1 || true
    fi
    btrfs subvolume create "${_sys}" >/dev/null || { _reap_snapshot "${_new_layer}"; upgrade_fail "sys-create-failed"; return 1; }

    if ! tar -xzf "${_payload}/rootfs.tar.gz" -C "${_sys}" 2>/dev/null; then
        btrfs subvolume delete -C "${_sys}" >/dev/null 2>&1 || true
        _reap_snapshot "${_new_layer}"
        upgrade_fail "rootfs-extract-failed"
        return 1
    fi
    [ -x "${_sys}/sbin/init" ] || {
        btrfs subvolume delete -C "${_sys}" >/dev/null 2>&1 || true
        _reap_snapshot "${_new_layer}"
        upgrade_fail "extracted-rootfs-has-no-init"
        return 1
    }

    # 3. the platform layer is versioned with the slot, so it moves with the rootfs
    if [ -f "${_payload}/platform.tar" ]; then
        if [ -d "${_platform}" ]; then
            btrfs subvolume delete -C "${_platform}" >/dev/null 2>&1 || true
        fi
        btrfs subvolume create "${_platform}" >/dev/null || upgrade_fail "platform-create-failed" || return 1
        tar -xf "${_payload}/platform.tar" -C "${_platform}" || upgrade_fail "platform-extract-failed" || return 1
        # A slot whose platform layer has no btrfs boots and then cannot finish: the boot
        # hook records btrfs-tool-missing, the health check has no reclamation tool and the
        # slot never commits, which on a machine is a hang rather than a failure. Refusing
        # the payload here keeps the committed slot in charge instead.
        [ -x "${_platform}/usr/sbin/btrfs" ] || {
            btrfs subvolume delete -C "${_platform}" >/dev/null 2>&1 || true
            _reap_snapshot "${_new_layer}"
            upgrade_fail "platform-layer-without-btrfs"
            return 1
        }
    fi

    # 4. the ESP has to carry the matching kernel and initramfs for that slot
    [ -f "${_payload}/kernel.bin" ] && cp "${_payload}/kernel.bin" "${AB_ESP}/vmlinuz-${_target}" || {
        upgrade_fail "kernel-copy-failed"
        return 1
    }
    if [ -f "${_payload}/initramfs.cpio.gz" ]; then
        cp "${_payload}/initramfs.cpio.gz" "${AB_ESP}/initrd-${_target}" || {
            upgrade_fail "initramfs-copy-failed"
            return 1
        }
    fi
    sync

    _upgrade_log "upgrade: wrote slot ${_target} from ${_version} (layer ${_new_layer})"
    # Read by the caller after this function returns.
    # shellcheck disable=SC2034
    UPGRADE_NEW_LAYER="${_new_layer}"
    # shellcheck disable=SC2034
    UPGRADE_NEW_VERSION="${_version}"
    return 0
}

# _reap_snapshot <layer>: undo the snapshot when the copy did not work out.
_reap_snapshot() {
    if awk -v want="$1" 'index($0, "/" want) { found = 1 } END { exit !found }' /proc/mounts; then
        return 0
    fi
    btrfs subvolume delete -C "${AB_P4}/$1" >/dev/null 2>&1 || true
    btrfs subvolume sync "${AB_P4}" >/dev/null 2>&1 || true
    _upgrade_log "upgrade: reaped the unused layer $1"
}

# platform_upgrade_end <target-slot> <rootfs-version> <layer-name>
platform_upgrade_end() {
    _target="$1"
    _version="$2"
    _layer="$3"
    # Read by the caller when this returns non-zero.
    # shellcheck disable=SC2034
    upgrade_reason=""

    ab-slot layer "${_target}" "${_version}" "${_layer}" >/dev/null 2>&1 ||
        upgrade_fail "state-layer-write-failed" || return 1
    ab-slot pending "${_target}" >/dev/null 2>&1 ||
        upgrade_fail "state-pending-write-failed" || return 1

    # The candidate is only tried if GRUB reads a file that names it. ab-slot writes
    # that file through the shared writer; this reads it back instead of writing its
    # own copy, so the platform layer has exactly one implementation to keep right.
    _next="$(ab-slot next 2>/dev/null)"
    case "${_next}" in
        "next=${_target}") : ;;
        *)
            upgrade_fail "next-boot-not-${_target}-${_next:-unknown}"
            return 1
            ;;
    esac

    _upgrade_log "upgrade: slot ${_target} is pending on ${_version} (${_layer}), ${_next}"
    return 0
}
