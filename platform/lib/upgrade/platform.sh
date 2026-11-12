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
#       Snapshots the running writable layer onto a new layer named after the payload
#       version, replaces the target slot's @sys with the payload's rootfs, replaces its
#       @platform with the payload's platform layer, puts the payload's kernel and
#       initramfs on the ESP for that slot, and aligns the target's package metadata with
#       the version it now carries.
#
#       What a failure leaves behind, in the order the steps run: the ESP bootloader is put
#       back (upgrade_bootloader_rollback), the new @sys is deleted again where the step that
#       failed still allows it, and the snapshot is reaped. The target slot's contents can
#       therefore be stale or empty after a failure - what never changes is the slot the
#       machine boots and ab/state.json, because platform_upgrade_end is not reached.
#
#       The bootloader is written first, before anything else is touched: the ESP is
#       shared by both slots, so a half written loader is the one failure `ab-slot` cannot
#       roll back. See upgrade_bootloader_install below.
#
# Environment:
#   AB_UPGRADE_BOOTLOADER  update (default) | skip   what --no-bootloader sets
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

# --------------------------------------------------------------------------- #
# Package metadata: one writer for the state the device reports
# --------------------------------------------------------------------------- #

# Where the alignment verdict lives. It is on the ESP because that is what survives a
# slot switch and what `ab-slot status` can read from any boot, and it is one line so a
# reader never has to parse a format: packages=<state> reason=<token> version=<ver> kernel=<id>.
AB_PACKAGES_FILE="${AB_PACKAGES_FILE:-${AB_ESP}/ab/packages}"
# Read by the caller / by ab-slot after this library returns.
# shellcheck disable=SC2034
AB_PACKAGES_REASON=""

# ab_packages_record <state> <reason> <version> <kernel> <slot>: publish the alignment
# verdict. The slot is part of it because the record describes the *target* slot while the
# machine still runs the old one; a reader that ignored that would report the candidate's
# state as the running slot's.
# A failure to write is reported and never fails an upgrade: the machine boots either way,
# and the next status read reports `unknown` instead of a state nobody could record.
ab_packages_record() {
    _state="$1"
    _reason="${2:-none}"
    _version="${3:-unknown}"
    _kernel="${4:-unknown}"
    _slot="${5:-unknown}"
    _dir="$(dirname "${AB_PACKAGES_FILE}")"
    [ -d "${_dir}" ] || mkdir -p "${_dir}" 2>/dev/null || {
        _upgrade_log "packages: cannot create ${_dir}, the state will read as unknown"
        return 0
    }
    _tmp="${AB_PACKAGES_FILE}.tmp.$$"
    printf 'packages=%s reason=%s version=%s kernel=%s slot=%s\n' \
        "${_state}" "${_reason}" "${_version}" "${_kernel}" "${_slot}" >"${_tmp}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        return 0
    }
    sync
    mv "${_tmp}" "${AB_PACKAGES_FILE}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        _upgrade_log "packages: cannot publish ${AB_PACKAGES_FILE}"
        return 0
    }
    sync
    AB_PACKAGES_REASON="${_reason}"
    return 0
}

# --------------------------------------------------------------------------- #
# Bootloader: measure, back up, stage, write, compare, restore
# --------------------------------------------------------------------------- #
#
# The ESP is shared by both slots, so this is the one write `ab-slot rollback` cannot undo.
# The sequence below is the whole safety story, in order:
#
#   1. measure what the ESP carries now, and what the payload claims (manifest digests);
#   2. refuse outright when the ESP is not in a state worth writing to (`esp=dirty`;
#      `esp=unreadable`), because that is exactly when FAT writes go wrong;
#   3. back the current bytes up on the writable partition (the only place that survives a
#      broken ESP); the backup of a version is rebuilt from what the ESP carries at the start
#      of every attempt, so it always describes the state this run may have to undo;
#   4. stage on the ESP, verify the staged bytes against the manifest *before* replacing
#      anything;
#   5. write through `<file>.new` + rename, keeping the replaced file as `<file>.prev` so a
#      machine whose loader is torn still has a second copy on the ESP itself;
#   6. compare the files that were written, byte for byte;
#   7. on any mismatch restore from the backup and verify the restore.
#
# Everything here runs before the target slot is touched, so a failure leaves the slot and
# ab/state.json exactly as they were. A failure *after* this stage rolls the ESP back from
# the same backup (see platform_copy_rootfs).

# Read by the caller after platform_copy_rootfs returns.
# shellcheck disable=SC2034
UPGRADE_BOOTLOADER_STATE="unchanged"
_upgrade_boot_state="unchanged"
# Set when this stage actually replaced a file, so the rollback path knows there is
# something to roll back.
_upgrade_boot_wrote=0

_upgrade_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# _upgrade_manifest_string <payload-dir> <field>: a string field of the manifest's
# bootloader block; empty when the payload has no block.
_upgrade_manifest_string() {
    _squeezed="$(tr -d ' \t\r\n' <"$1/manifest.json" 2>/dev/null)"
    printf '%s' "${_squeezed}" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
}

# _upgrade_manifest_number <payload-dir> <field>: a numeric field of that block.
_upgrade_manifest_number() {
    _squeezed="$(tr -d ' \t\r\n' <"$1/manifest.json" 2>/dev/null)"
    printf '%s' "${_squeezed}" | sed -n 's/.*"'"$2"'":\([0-9][0-9]*\).*/\1/p'
}

# _upgrade_esp_free_kib: free KiB on the ESP, or nothing when it cannot be established.
# The numeric match matters: a wrapped mount point makes `df` print a second line whose
# fourth field is not a number, and a failed comparison inside `if` used to let the write
# continue.
_upgrade_esp_free_kib() {
    df -k "${AB_ESP}" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { print $4; exit }'
}

# _upgrade_esp_health: the initramfs' verdict on the ESP this boot mounted, through
# `ab-slot status` (which reads this boot's ring log). `unknown` is not an error here: an
# image that never wrote the line simply has nothing to say.
_upgrade_esp_health() {
    _status="$(ab-slot status 2>/dev/null)"
    _health="$(printf '%s' "${_status}" | sed -n 's/.* esp=\([a-z]*\).*/\1/p')"
    printf '%s' "${_health:-unknown}"
}

# _upgrade_boot_backup <backup-dir>: copy the current ESP boot files aside and record their
# digests. The backup lives on the writable partition, never on the ESP: a backup of a
# bootloader that has just been written badly is worth nothing if it shares the device that
# was written badly. The copy is refreshed on every attempt, because the restore path has to
# put back what this attempt replaced - a backup from an earlier run would silently rewind
# the ESP by one release. What survives across attempts is `<file>.prev` on the ESP itself.
_upgrade_boot_backup() {
    _backup="$1"
    rm -rf "${_backup}" 2>/dev/null || true
    mkdir -p "${_backup}" || return 1
    : >"${_backup}/SHA256SUMS" || return 1
    for _rel in EFI/BOOT/BOOTX64.EFI boot/grub/grub.cfg; do
        [ -f "${AB_ESP}/${_rel}" ] || continue
        mkdir -p "${_backup}/$(dirname "${_rel}")" || return 1
        cp "${AB_ESP}/${_rel}" "${_backup}/${_rel}" || return 1
        _want="$(_upgrade_sha "${AB_ESP}/${_rel}")"
        _have="$(_upgrade_sha "${_backup}/${_rel}")"
        [ -n "${_want}" ] && [ "${_want}" = "${_have}" ] || return 1
        printf '%s  %s\n' "${_want}" "${_rel}" >>"${_backup}/SHA256SUMS" || return 1
    done
    sync
    return 0
}

# _upgrade_boot_restore: put the recorded bytes back and verify every one of them.
#
# It restores the backup this run wrote, named by ${_upgrade_boot_backup}, and takes no
# argument: the backup to restore is always the one taken a few lines earlier in the same
# run, so an argument would only be a way to restore some other run's bytes - which nothing
# needs and which ShellCheck flags as a parameter no caller ever passes (SC2120).
#
# It calls _upgrade_boot_file, which is defined further down: POSIX sh resolves functions at
# call time, and both are only ever called after the whole file has been sourced.
_upgrade_boot_restore() {
    _backup="${_upgrade_boot_backup}"
    [ -n "${_backup}" ] || return 1
    [ -f "${_backup}/SHA256SUMS" ] || return 1
    # The restore goes through the same staged write as the install: putting bytes back
    # with an in-place `cp` would open the very window this whole stage exists to close.
    _stage_restore="${_stage}"
    _stage="${_backup}"
    _restored=0
    while read -r _want _rel; do
        [ -n "${_rel}" ] || continue
        [ -f "${_backup}/${_rel}" ] || { _stage="${_stage_restore}"; return 1; }
        _upgrade_boot_file "${_rel}" "${_want}" || { _stage="${_stage_restore}"; return 1; }
        _restored=$((_restored + 1))
    done <"${_backup}/SHA256SUMS"
    _stage="${_stage_restore}"
    # A backup with no entries restores nothing. That happens when the ESP carried neither
    # the loader nor the menu before this run, which is a legal state (a machine whose ESP
    # was wiped), and it used to make this function return success: the caller then logged
    # "the ESP carries <digest> again" and ab-upgrade reported 74, "refused before writing
    # anything", while the ESP was in fact carrying unverified bytes this run wrote. Nothing
    # was restored, so nothing verified: say so and let the caller report a failed rollback.
    [ "${_restored}" -gt 0 ] || return 1
    sync
    return 0
}

# _upgrade_boot_prune: keep the two most recent backups. Ordered by modification time, not
# by name: `<version>` sorts lexicographically, so "-1" and "-10" made a name sort delete the
# backup of the *previous* release and keep the oldest one.
_upgrade_boot_prune() {
    _root="${AB_P4}/@boot-backup"
    [ -d "${_root}" ] || return 0
    ls -1dt "${_root}"/*/ 2>/dev/null | sed 's:/*$::' | tail -n +3 | while IFS= read -r _dir; do
        [ -n "${_dir}" ] || continue
        [ "${_dir}" = "${_root}" ] && continue
        rm -rf "${_dir}" 2>/dev/null || true
    done
    return 0
}

# _upgrade_boot_file <staged-relative-path> <wanted sha256>: replace one file through
# `<file>.new` + rename, keeping what was there as `<file>.prev`. Returns non-zero when the
# bytes on the ESP are not the wanted ones afterwards.
# Every variable here is prefixed with `_bf_`: POSIX sh has no `local`, and an earlier
# version of this helper wrote the ESP file path into `_target`, which is the *slot name* of
# the caller - the slot mount then failed with `/boot/EFI/...` as a slot. A function in this
# library may only use names no caller uses.
_upgrade_boot_file() {
    _bf_rel="$1"
    _bf_want="$2"
    _bf_file="${AB_ESP}/${_bf_rel}"
    _bf_dir="${AB_ESP}/$(dirname "${_bf_rel}")"
    mkdir -p "${_bf_dir}" 2>/dev/null || return 1
    _bf_new="${_bf_file}.new"
    _bf_prev="${_bf_file}.prev"
    rm -f "${_bf_new}" 2>/dev/null || true
    cp "${_stage}/${_bf_rel}" "${_bf_new}" || return 1
    sync
    if [ "$(_upgrade_sha "${_bf_new}")" != "${_bf_want}" ]; then
        rm -f "${_bf_new}" 2>/dev/null || true
        return 1
    fi
    # The copy the machine can be rescued with: on the ESP itself, so it is reachable even
    # when the writable partition cannot be mounted.
    if [ -f "${_bf_file}" ]; then
        cp "${_bf_file}" "${_bf_prev}" 2>/dev/null \
            || _upgrade_log "upgrade: could not keep ${_bf_rel}.prev (no room on the ESP?)"
        # `.prev` is the copy a machine with a torn loader is rescued from, and this is the
        # only window in which it can be lost: the rename below replaces the file it was
        # copied from, so the copy has to be on the medium before that happens.
        sync
    fi
    mv -f "${_bf_new}" "${_bf_file}" || {
        rm -f "${_bf_new}" 2>/dev/null || true
        return 1
    }
    # From here on the ESP carries bytes this run put there, so a failure has something to
    # roll back. Marking it only after the verification below meant a rename that landed the
    # wrong bytes was treated as "nothing was replaced" and left the ESP broken.
    _upgrade_boot_wrote=1
    sync
    [ "$(_upgrade_sha "${_bf_file}")" = "${_bf_want}" ] || return 1
    return 0
}

# upgrade_bootloader_install <payload-dir> <target-slot> <rootfs-version>
upgrade_bootloader_install() {
    _payload="$1"
    _version="${3:-unknown}"
    _upgrade_boot_state="unchanged"
    _upgrade_boot_wrote=0

    if [ "${AB_UPGRADE_BOOTLOADER:-update}" = "skip" ]; then
        _upgrade_boot_state="skipped-by-flag"
        _upgrade_log "upgrade: bootloader left alone (--no-bootloader)"
        return 0
    fi
    if [ ! -f "${_payload}/boot.tar" ]; then
        # Payloads from before the member existed still install: the loader on the machine
        # is what the machine was flashed with, and that is the state this release is
        # leaving behind - said out loud rather than silently.
        _upgrade_boot_state="absent-in-payload"
        _upgrade_log "upgrade: this payload carries no boot.tar, the ESP's bootloader stays as it is"
        return 0
    fi

    _want_loader="$(_upgrade_manifest_string "${_payload}" loader_sha256)"
    _want_bytes="$(_upgrade_manifest_number "${_payload}" loader_bytes)"
    _want_menu="$(_upgrade_manifest_string "${_payload}" menu_sha256)"
    if [ -z "${_want_loader}" ] || [ -z "${_want_bytes}" ] || [ -z "${_want_menu}" ]; then
        upgrade_fail "bootloader-manifest-incomplete"
        return 1
    fi

    # A dirty or unreadable ESP is the state where a FAT write goes wrong, and the state in
    # which `df` cannot be trusted: writing a bootloader there trades a working machine for
    # an untested one. `--no-bootloader` is the documented way past it.
    _esp_health="$(_upgrade_esp_health)"
    case "${_esp_health}" in
        dirty | unreadable)
            upgrade_fail "bootloader-esp-${_esp_health}"
            return 1
            ;;
    esac

    # Which of the two files actually differ from what the ESP carries now. A machine that
    # is up to date is not written to at all: the write is the risk, so it is skipped when
    # it cannot change anything.
    _write=""
    if [ ! -f "${AB_ESP}/EFI/BOOT/BOOTX64.EFI" ] \
        || [ "$(_upgrade_sha "${AB_ESP}/EFI/BOOT/BOOTX64.EFI")" != "${_want_loader}" ]; then
        _write="loader"
    fi
    if [ ! -f "${AB_ESP}/boot/grub/grub.cfg" ] \
        || [ "$(_upgrade_sha "${AB_ESP}/boot/grub/grub.cfg")" != "${_want_menu}" ]; then
        _write="${_write:+${_write} }menu"
    fi
    if [ -z "${_write}" ]; then
        _upgrade_boot_state="unchanged"
        _upgrade_log "upgrade: the ESP's bootloader already is ${_want_loader}, nothing written"
        return 0
    fi

    _avail_k="$(_upgrade_esp_free_kib)"
    if [ -z "${_avail_k}" ]; then
        upgrade_fail "bootloader-space-unknown"
        return 1
    fi
    # The loader and the menu, their staging copies and the `.prev` copies, plus a margin:
    # the ESP also has to take the slot's vmlinuz and initrd right after this.
    _need_k=$(( (_want_bytes / 1024) + 4096 ))
    if [ "${_avail_k}" -lt "${_need_k}" ]; then
        upgrade_fail "bootloader-no-space"
        return 1
    fi

    _backup="${AB_P4}/@boot-backup/${_version}"
    if ! _upgrade_boot_backup "${_backup}"; then
        upgrade_fail "bootloader-backup-failed"
        return 1
    fi
    # Remembered for the rollback path in platform_copy_rootfs.
    _upgrade_boot_backup="${_backup}"
    _upgrade_log "upgrade: ESP bootloader backed up to ${_backup} ($(wc -l <"${_backup}/SHA256SUMS" | tr -d ' ') file(s))"

    # A staging directory that a power cut left behind is cleared first: a `.boot-stage.*`
    # nobody owns is exactly the kind of junk that fills a 128 MiB ESP over a year.
    _stage="${AB_ESP}/.boot-stage.$$"
    rm -rf "${AB_ESP}"/.boot-stage.* 2>/dev/null || true
    if ! mkdir -p "${_stage}" 2>/dev/null || ! tar -xf "${_payload}/boot.tar" -C "${_stage}" 2>/dev/null; then
        rm -rf "${_stage}" 2>/dev/null || true
        upgrade_fail "bootloader-stage-failed"
        return 1
    fi
    if [ ! -f "${_stage}/EFI/BOOT/BOOTX64.EFI" ] || [ ! -f "${_stage}/boot/grub/grub.cfg" ]; then
        rm -rf "${_stage}" 2>/dev/null || true
        upgrade_fail "bootloader-member-incomplete"
        return 1
    fi
    # The staged bytes have to be the ones the manifest describes before anything on the
    # ESP is replaced - loading a payload whose member digest was checked can still carry a
    # boot.tar that holds different bytes inside.
    if [ "$(_upgrade_sha "${_stage}/EFI/BOOT/BOOTX64.EFI")" != "${_want_loader}" ]; then
        rm -rf "${_stage}" 2>/dev/null || true
        upgrade_fail "bootloader-digest-mismatch"
        return 1
    fi
    if [ "$(_upgrade_sha "${_stage}/boot/grub/grub.cfg")" != "${_want_menu}" ]; then
        rm -rf "${_stage}" 2>/dev/null || true
        upgrade_fail "bootloader-menu-mismatch"
        return 1
    fi
    sync

    _failed=""
    case " ${_write} " in
        *" loader "*)
            _upgrade_boot_file "EFI/BOOT/BOOTX64.EFI" "${_want_loader}" || _failed="bootloader-write-not-verified"
            ;;
    esac
    if [ -z "${_failed}" ]; then
        case " ${_write} " in
            *" menu "*)
                _upgrade_boot_file "boot/grub/grub.cfg" "${_want_menu}" || _failed="bootloader-write-not-verified"
                ;;
        esac
    fi
    sync

    if [ -n "${_failed}" ]; then
        rm -rf "${_stage}" 2>/dev/null || true
        if [ "${_upgrade_boot_wrote}" = "1" ] && _upgrade_boot_restore; then
            _upgrade_log "upgrade: bootloader restored from ${_backup}, the ESP carries $(_upgrade_sha "${AB_ESP}/EFI/BOOT/BOOTX64.EFI") again"
        elif [ "${_upgrade_boot_wrote}" = "1" ]; then
            _upgrade_log "upgrade: RESTORE ALSO FAILED, the ESP bootloader may be damaged: ${_backup}"
        else
            _upgrade_log "upgrade: nothing was replaced on the ESP"
        fi
        upgrade_fail "${_failed}"
        return 1
    fi

    rm -rf "${_stage}" 2>/dev/null || true
    _upgrade_boot_prune
    _upgrade_boot_state="written"
    _upgrade_log "upgrade: bootloader written to ${AB_ESP} ($(printf '%s' "${_write}" | tr ' ' '+'), loader ${_want_loader})"
    return 0
}

# upgrade_bootloader_rollback: undo a bootloader write that this run performed, using the
# backup it took. Called when a later step of the same upgrade fails, because the ESP is the
# one thing the slot copy cannot repair. Returns non-zero when the rollback did not verify.
upgrade_bootloader_rollback() {
    [ "${_upgrade_boot_wrote}" = "1" ] || return 0
    if _upgrade_boot_restore; then
        _upgrade_log "upgrade: rolled the ESP bootloader back after the failed slot copy"
        _upgrade_boot_wrote=0
        _upgrade_boot_prune
        return 0
    fi
    _upgrade_log "upgrade: FAILED TO ROLL BACK the ESP bootloader, see ${_upgrade_boot_backup}"
    return 1
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
#
# The bootloader stage runs first (see upgrade_bootloader_install). If anything after it
# fails, the caller rolls the ESP back with upgrade_bootloader_rollback, so "the upgrade
# failed" keeps meaning "the machine is as it was" for the ESP as well.
platform_copy_rootfs() {
    _upgrade_boot_wrote=0
    _upgrade_boot_backup=""

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

    # 0. the bootloader, before the slot is touched at all. The ESP is shared by both
    #    slots, so this is the only step whose failure cannot be undone by ab-slot; doing
    #    it first is what keeps "the upgrade failed" from meaning "the machine changed".
    upgrade_bootloader_install "${_payload}" "${_target}" "${_version}" || return 1
    # Read by ab-upgrade after this function returns, in the same shell.
    # shellcheck disable=SC2034
    UPGRADE_BOOTLOADER_STATE="${_upgrade_boot_state}"

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

    # 3b. the target's package metadata has to describe the version it now carries: a
    #     downgrade otherwise leaves world pinned to the old kernel and the feeds pointing
    #     at the old release, and "install a kmod for this kernel" fails with a message
    #     nobody can act on. The aligner is taken from the *new* platform layer, because
    #     that is the version whose feeds are being written. A limited result never blocks
    #     the switch: the machine boots and runs either way, it just cannot install
    #     matching packages until it is fixed.
    _align_state="limited"
    _align_reason="packages-lib-missing"
    _align_kernel="unknown"
    if [ -f "${_platform}/lib/upgrade/packages.sh" ]; then
        # shellcheck source=platform/lib/upgrade/packages.sh disable=SC1090
        if . "${_platform}/lib/upgrade/packages.sh" 2>/dev/null; then
            _align_state="limited"
            _align_reason="align-not-run"
            if ab_packages_align "${_payload}" "${_target}" "${_sys}" "${AB_P4}/${_new_layer}/upper"; then
                _align_state="aligned"
                _align_reason="none"
            else
                _align_reason="${AB_PACKAGES_REASON:-align-failed}"
            fi
            _align_kernel="${AB_PACKAGES_KERNEL:-unknown}"
        fi
    fi
    ab_packages_record "${_align_state}" "${_align_reason}" "${_version}" "${_align_kernel}" "${_target}"
    _upgrade_log "upgrade: package meta ${_align_state} (${_align_reason})"

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
