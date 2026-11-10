#!/usr/bin/env bash
# Stage "ab-fixtures": shape the test image between boots.
#
# The A/B paths need states a fresh image does not have: a network interface for the
# wan probe, a deliberately broken slot for the abandoned-update case, and a pending
# slot for the candidate boots. This script produces those states on the image file
# itself, with the same tooling the running system uses, so the boot chain is tested
# against real ESP content.
#
# Actions (in the order given):
#   --grow-tail <MiB>  append unused MiB to the image file, which is what a real disk
#                      larger than the image looks like: the first boot then has to grow
#                      p4 to the new end. Without this the image already fills its disk and
#                      the growth path is never executed in CI at all - which is how a
#                      broken last-lba field reached a machine.
#   --network          write a minimal /etc/config/network into the writable layer so
#                      the wan probe has a subject (S5 owns the production config)
#   --payload <tar>    place an upgrade payload where the guest can reach it
#   --user-banner <s>  modify /etc/banner in the writable layer, creating a conflict
#                      against a payload that changes the same file
#   --auto-upgrade     install /etc/rc.local that runs ab-upgrade on the payload
#   --orphan-layer <n> create an unreferenced writable layer, so reclamation has work
#   --break-p4         corrupt the writable partition's superblock so it cannot mount
#   --break-slot <s>   replace the slot's nft binary with a broken stub, which leaves
#                      the system bootable but fails the firewall probe
#   --repair-slot <s>  restore that binary from the other slot
#   --pending <slot>   mark a slot pending through ab-slot itself
#   --abandon          clear pending through ab-slot
#   --show STATE       print the state file, the boot log and the candidate marker
#   --cat <path> <out> copy one file from the ESP (read-only) to <out>, for gating on evidence the
#                      initramfs wrote there; exits non-zero when it is missing or empty
#
# Inputs (environment):
#   CI_IMAGE          raw image to modify
#   CI_OVERLAY_NAME   writable layer name (default: @overlay-${CI_UPSTREAM_VERSION})
#
# The script mounts the image, changes it, unmounts it and syncs, so a QEMU boot that
# follows sees the change as if it had been made by the running system.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init ab-fixtures

ci_require_cmd sudo losetup

image="${CI_IMAGE:?CI_IMAGE is required}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
overlay_name="${CI_OVERLAY_NAME:-@overlay-${upstream_version}}"
work="${CI_TMP_ROOT}/ab-fixtures"

[ -f "${image}" ] || ci_die "image not found: ${image}"
[ "$#" -gt 0 ] || ci_die "no action given"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required"

mkdir -p "${work}"
loopdev=""
cleanup() {
    if [ -n "${loopdev}" ]; then
        for dir in "${work}/esp" "${work}/p4" "${work}/slot-a" "${work}/slot-b" "${work}/p1-ro"; do
            sudo umount "${dir}" 2>/dev/null || true
        done
        sudo losetup -d "${loopdev}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --show --partscan "${image}")"
attempt=0
until [ -b "${loopdev}p4" ] || [ "${attempt}" -ge 40 ]; do
    attempt=$((attempt + 1))
    sleep 0.25
done
for part in 1 2 3 4; do
    [ -b "${loopdev}p${part}" ] || ci_die "partition ${part} did not appear"
done

mount_one() { # <device> <name>
    mkdir -p "${work}/$2"
    sudo mount "$1" "${work}/$2"
}

# Read-only variant, and the matching unmount: --cat must not be able to write to the ESP,
# and this script does not source disk.sh (whose unmount_part is not in lib.sh).
mount_one_ro() { # <device> <name>
    mkdir -p "${work}/$2"
    sudo mount -o ro "$1" "${work}/$2"
}

unmount_part() { # <mountpoint>
    sudo sync 2>/dev/null || :
    sudo umount "$1" 2>/dev/null || :
}

# The platform layer lives on p2/p3, not on the ESP: use the copy from slot a. The
# partition is mounted at its top level, so the layer is reached through @platform.
platform_slot_bin="${work}/slot-a/@platform/usr/sbin/ab-slot"
ensure_platform_bin() {
    if [ ! -f "${platform_slot_bin}" ]; then
        mount_one "${loopdev}p2" slot-a
        if [ ! -f "${platform_slot_bin}" ]; then
            ci_die "slot a has no /usr/sbin/ab-slot; the platform layer was not installed"
        fi
        sudo cp "${platform_slot_bin}" "${work}/ab-slot"
        sudo chmod 0755 "${work}/ab-slot"
        sudo umount "${work}/slot-a"
        platform_slot_bin="${work}/ab-slot"
    fi
}

state_ab_slot() {
    ensure_platform_bin
    mount_one "${loopdev}p1" esp
    # The shipped ab-slot reads the writer of boot/grub/ab-slot.cfg from the platform
    # layer. That layer is installed at /lib inside the image, not on this build host, so
    # the repository copy is handed over explicitly: it is the same file the layer ships,
    # and without it ab-slot refuses to move the hint (a packaging detail, not an image
    # problem).
    # shellcheck disable=SC2086  # arguments are simple words
    sudo AB_ESP="${work}/esp" AB_CMD=/dev/null \
        AB_SLOT_CFG_LIB="${CI_REPO_ROOT}/platform/lib/ab-slot-cfg.sh" \
        AB_PARTITIONS_LIB="${CI_REPO_ROOT}/platform/lib/ab-partitions.sh" \
        sh "${platform_slot_bin}" $1 ${2:-} 2>&1 |
        sed 's/^/[ab-slot]   /'
    sudo sync
    # Marking a slot pending has to move the menu the next boot reads, on the ESP, before
    # the machine ever gets a chance to boot. Asserted here so a state file that moved
    # without its hint cannot pass as a staged upgrade.
    if [ "$1" = "pending" ] && [ -f "${work}/esp/boot/grub/ab-slot.cfg" ]; then
        want_default=""
        want_fallback=""
        case "${2:-}" in
            a) want_default=0 ;;
            b) want_default=1 ;;
        esac
        case "$(sudo sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "${work}/esp/ab/state.json" | head -n 1)" in
            a) want_fallback=0 ;;
            b) want_fallback=1 ;;
        esac
        if [ -n "${want_default}" ] && [ -n "${want_fallback}" ]; then
            if ! sudo grep -q "^set default=${want_default}$" "${work}/esp/boot/grub/ab-slot.cfg"; then
                ci_die "pending ${2:-?} did not point the menu at it: $(sudo cat "${work}/esp/boot/grub/ab-slot.cfg" | tr '\n' ' ')"
            fi
            if ! sudo grep -q "^set fallback=${want_fallback}$" "${work}/esp/boot/grub/ab-slot.cfg"; then
                ci_die "pending ${2:-?} lost the committed slot as the fallback: $(sudo cat "${work}/esp/boot/grub/ab-slot.cfg" | tr '\n' ' ')"
            fi
            ci_log "menu now tries slot ${2:-?} and falls back to the committed slot"
        fi
    fi
    sudo umount "${work}/esp"
}

write_network_config() {
    mount_one "${loopdev}p4" p4
    target="${work}/p4/${overlay_name}/upper"
    [ -d "${target}" ] || ci_die "writable layer ${overlay_name} not found on p4"
    sudo mkdir -p "${target}/etc/config"
    sudo tee "${target}/etc/config/network" >/dev/null <<'CONFIG'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
CONFIG
    sudo sync
    sudo umount "${work}/p4"
    ci_log "wrote a test network configuration into ${overlay_name}/upper/etc/config/network"
}

slot_tree() { # <slot> -> 2|3
    case "$1" in
        a) printf '2' ;;
        b) printf '3' ;;
        *) ci_die "invalid slot: $1" ;;
    esac
}

break_slot() {
    number="$(slot_tree "$1")"
    mount_one "${loopdev}p${number}" "slot-$1"
    target="${work}/slot-$1/@sys/usr/sbin/nft"
    [ -f "${target}" ] || ci_die "no /usr/sbin/nft in slot $1"
    sudo cp "${target}" "${work}/nft.$1.orig"
    printf '#!/bin/sh\nexit 1\n' | sudo tee "${target}" >/dev/null
    sudo chmod 0755 "${target}"
    sudo sync
    sudo umount "${work}/slot-$1"
    ci_log "slot $1: replaced /usr/sbin/nft with a failing stub (firewall probe will fail)"
}

repair_slot() {
    number="$(slot_tree "$1")"
    mount_one "${loopdev}p${number}" "slot-$1"
    target="${work}/slot-$1/@sys/usr/sbin/nft"
    [ -f "${work}/nft.$1.orig" ] || ci_die "no saved nft binary for slot $1"
    sudo cp "${work}/nft.$1.orig" "${target}"
    sudo chmod 0755 "${target}"
    sudo sync
    sudo umount "${work}/slot-$1"
    ci_log "slot $1: restored /usr/sbin/nft"
}

show_state() {
    mount_one "${loopdev}p1" esp
    case "${1:-}" in
        "" | state) sudo cat "${work}/esp/ab/state.json" ;;
        log) sudo cat "${work}/esp/ab/log/boot-0.log" 2>/dev/null || echo "no boot-0.log" ;;
        candidate) sudo cat "${work}/esp/ab/candidate" 2>/dev/null || echo "no candidate marker" ;;
        *) ci_die "unknown show target: $1" ;;
    esac
    sudo umount "${work}/esp"
}

write_payload() {
    mount_one "${loopdev}p4" p4
    target="${work}/p4/${overlay_name}/upper"
    [ -d "${target}" ] || ci_die "writable layer ${overlay_name} not found on p4"
    sudo cp "$1" "${target}/payload.tar"
    sudo sync
    sudo umount "${work}/p4"
    ci_log "payload placed at /payload.tar in the writable layer"
}

write_user_banner() {
    mount_one "${loopdev}p4" p4
    target="${work}/p4/${overlay_name}/upper"
    [ -d "${target}" ] || ci_die "writable layer ${overlay_name} not found on p4"
    sudo mkdir -p "${target}/etc"
    printf '%s\n' "$1" | sudo tee "${target}/etc/banner" >/dev/null
    sudo sync
    sudo umount "${work}/p4"
    ci_log "wrote a user banner, which the payload will conflict with"
}

install_auto_upgrade() {
    mount_one "${loopdev}p4" p4
    target="${work}/p4/${overlay_name}/upper"
    sudo mkdir -p "${target}/etc"
    sudo tee "${target}/etc/rc.local" >/dev/null <<'RCLOCAL'
#!/bin/sh
# Test fixture: run the upgrade once the system finished booting.
#
# The script removes itself *before* upgrading: the upgrade snapshots the running
# layer, and a copy of this script inside that snapshot would run the upgrade again on
# the next boot, this time with the payload already installed.
rm -f /etc/rc.local
echo "ab-upgrade-test: starting" >/dev/console
ab-upgrade /payload.tar
echo "ab-upgrade: exit=$?" >/dev/console
ab-slot status >/dev/console 2>&1
echo "S5-UPGRADE-DONE" >/dev/console
# Run once: the file lives in the writable layer, so removing it keeps later boots clean.
rm -f /etc/rc.local
exit 0
RCLOCAL
    sudo chmod 0755 "${target}/etc/rc.local"
    sudo sync
    sudo umount "${work}/p4"
    ci_log "installed /etc/rc.local that runs ab-upgrade"
}

orphan_layer() {
    mount_one "${loopdev}p4" p4
    sudo btrfs subvolume create "${work}/p4/$1" >/dev/null
    sudo mkdir -p "${work}/p4/$1/upper"
    printf 'orphan\n' | sudo tee "${work}/p4/$1/upper/marker" >/dev/null
    sudo sync
    sudo umount "${work}/p4"
    ci_log "created unreferenced writable layer $1"
}

break_p4() {
    sudo dd if=/dev/zero of="${loopdev}p4" bs=1M count=4 conv=notrunc status=none \
        || ci_die "cannot corrupt the writable partition"
    sudo sync
    ci_log "corrupted the writable partition, its mount must fail"
}

grow_tail() {
    want="${1:?--grow-tail needs MiB}"
    case "${want}" in
        '' | *[!0-9]*) ci_die "--grow-tail needs a whole number of MiB" ;;
    esac
    before="$(ci_file_size "${CI_IMAGE}")"
    truncate -s "+${want}M" "${CI_IMAGE}" || ci_die "cannot grow ${CI_IMAGE} by ${want} MiB"
    after="$(ci_file_size "${CI_IMAGE}")"
    ci_log "grew ${CI_IMAGE} from ${before} to ${after} bytes (+${want} MiB of unpartitioned tail)"
}

# cat_esp_file <path> <out>: copy one file off the ESP, read-only. The content goes to
# <out> rather than stdout because this stage logs its progress to stdout, and a caller
# that captures stdout (`$(...)`) would otherwise get "stage=..." lines mixed into the
# file it is about to grep.
cat_esp_file() {
    want="${1:?--cat needs a path inside the ESP}"
    out="${2:?--cat needs an output file}"
    mount_one_ro "${loopdev}p1" p1-ro
    target="${work}/p1-ro/${want}"
    if [ ! -s "${target}" ]; then
        unmount_part "${work}/p1-ro"
        ci_die "no non-empty ${want} on the ESP"
    fi
    cp "${target}" "${out}" || ci_die "cannot copy ${want} off the ESP"
    unmount_part "${work}/p1-ro"
    ci_log "read ${want} from the ESP into ${out} ($(ci_file_size "${out}") bytes)"
}

while [ "$#" -gt 0 ]; do
    action="$1"
    shift
    case "${action}" in
        --network) write_network_config ;;
        --cat)
            [ "$#" -ge 2 ] || ci_die "--cat needs <path-in-esp> <output-file>"
            cat_esp_file "$1" "$2"
            shift 2
            ;;
        --grow-tail)
            [ "$#" -ge 1 ] || ci_die "--grow-tail needs MiB"
            grow_tail "$1"
            shift
            ;;
        --break-slot)
            [ "$#" -ge 1 ] || ci_die "--break-slot needs a slot"
            break_slot "$1"
            shift
            ;;
        --repair-slot)
            [ "$#" -ge 1 ] || ci_die "--repair-slot needs a slot"
            repair_slot "$1"
            shift
            ;;
        --pending)
            [ "$#" -ge 1 ] || ci_die "--pending needs a slot"
            state_ab_slot pending "$1"
            shift
            ;;
        --abandon) state_ab_slot abandon ;;
        --payload)
            [ "$#" -ge 1 ] || ci_die "--payload needs a tar"
            write_payload "$1"
            shift
            ;;
        --user-banner)
            [ "$#" -ge 1 ] || ci_die "--user-banner needs text"
            write_user_banner "$1"
            shift
            ;;
        --auto-upgrade) install_auto_upgrade ;;
        --orphan-layer)
            [ "$#" -ge 1 ] || ci_die "--orphan-layer needs a name"
            orphan_layer "$1"
            shift
            ;;
        --break-p4) break_p4 ;;
        --show)
            show_state "${1:-state}"
            [ "$#" -ge 1 ] && shift
            ;;
        *) ci_die "unknown action: ${action}" ;;
    esac
done

ci_log "stage ab-fixtures finished"
