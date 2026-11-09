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
#   --network          write a minimal /etc/config/network into the writable layer so
#                      the wan probe has a subject (S5 owns the production config)
#   --break-slot <s>   replace the slot's nft binary with a broken stub, which leaves
#                      the system bootable but fails the firewall probe
#   --repair-slot <s>  restore that binary from the other slot
#   --pending <slot>   mark a slot pending through ab-slot itself
#   --abandon          clear pending through ab-slot
#   --show STATE       print the state file, the boot log and the candidate marker
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
        for dir in "${work}/esp" "${work}/p4" "${work}/slot-a" "${work}/slot-b"; do
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
    # shellcheck disable=SC2086  # arguments are simple words
    sudo AB_ESP="${work}/esp" AB_CMD=/dev/null sh "${platform_slot_bin}" $1 ${2:-} 2>&1 |
        sed 's/^/[ab-slot]   /'
    sudo sync
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

while [ "$#" -gt 0 ]; do
    action="$1"
    shift
    case "${action}" in
        --network) write_network_config ;;
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
        --show)
            show_state "${1:-state}"
            [ "$#" -ge 1 ] && shift
            ;;
        *) ci_die "unknown action: ${action}" ;;
    esac
done

ci_log "stage ab-fixtures finished"
