#!/usr/bin/env bash
# derive-variant.sh - make the convenience image from the one we already built and booted.
#
# The two images are the same system with one line different: `NET_WAN_SSH=` in
# `@platform/etc/net-defaults.conf`, plus the matching field in the ESP's
# `ab/image.json`. Building the whole 514 MiB image a second time to change one line cost
# a second S3 run (about five minutes) and, worse, produced an artifact nothing ever
# booted. Deriving it here keeps one build and one set of boot assertions behind both
# files.
#
#   derive-variant.sh --image <in.img> --out <out.img>
#       copy, rewrite both records, read them back, print `derive-variant=ok net_wan_ssh=open`
#
#   derive-variant.sh --rewrite-slot <slot-root>
#       the platform half on an already mounted slot filesystem (the layout disk.sh
#       builds: @sys next to @platform), used by the image path and by the unit test
#
#   derive-variant.sh --rewrite-tree <dir>
#       the same rewrite on a plain platform tree (a directory with etc/ in it)
#
# Outputs one line on success (`derive-variant=ok net_wan_ssh=open`) or a refusal
# (`derive-variant=fail reason=...`). Exit: 0 ok, 1 refused, 2 usage.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

WANT=open
work=""
loop=""

usage() {
    cat <<'USAGE'
usage: derive-variant.sh --image <in.img> --out <out.img>
       derive-variant.sh --rewrite-slot <slot-root>
       derive-variant.sh --rewrite-tree <dir>
USAGE
}

# place_file <rendered> <destination> [root]
# The image's trees belong to root (`tar -xpf` as root, then ci_platform_modes), so the
# rewrite has to run there as well. tee truncates the file it opened: the inode keeps its
# owner and its mode and only the bytes change, instead of a new runner-owned file
# appearing next to it. A plain directory tree stays a plain redirect.
place_file() {
    local src="$1" dest="$2" as_root="${3:-}"
    if [ "${as_root}" = "root" ]; then
        sudo tee "${dest}" <"${src}" >/dev/null
    else
        cat "${src}" >"${dest}"
    fi
    rm -f "${src}"
}

# find_platform <slot-root>: the @platform layer inside a mounted slot filesystem.
# @sys sits next to it and carries directories a walk cannot read (root's own /root is
# mode 0700), so this never descends into the mount: disk.sh creates @platform at the
# root of the slot, and the single-level glob keeps it working if the layout nests once.
find_platform() {
    local slot="${1:?find_platform needs a directory}" cand
    for cand in "${slot}/@platform" "${slot}"/*/@platform; do
        if [ -d "${cand}/etc" ]; then
            printf '%s\n' "${cand}"
            return 0
        fi
    done
    return 1
}

# rewrite_tree <platform-dir> [root]: set NET_WAN_SSH to $WANT, exactly one line.
# Rewriting by count rather than by sed -i keeps a template that lost its knobs an error
# instead of a silently unchanged file.
rewrite_tree() {
    local dir="${1:?rewrite_tree needs a directory}" as_root="${2:-}"
    local conf="${dir}/etc/net-defaults.conf"
    [ -f "${conf}" ] || { echo "derive-variant=fail reason=net-defaults-missing"; return 1; }
    local hits
    hits=$(grep -c '^NET_WAN_SSH=' "${conf}" || true)
    if [ "${hits}" -ne 1 ]; then
        echo "derive-variant=fail reason=net-defaults-knob-count-${hits}"
        return 1
    fi
    # Render to a temporary file first: a renderer that dies halfway must not leave the
    # image with a truncated net-defaults.conf.
    local tmp
    tmp=$(mktemp)
    sed -e "s|^NET_WAN_SSH=.*|NET_WAN_SSH=${WANT}|" "${conf}" >"${tmp}"
    place_file "${tmp}" "${conf}" "${as_root}"
    local got
    got=$(sed -n 's/^NET_WAN_SSH=//p' "${conf}" | head -n 1)
    if [ "${got}" != "${WANT}" ]; then
        echo "derive-variant=fail reason=readback-${got:-empty}"
        return 1
    fi
}

# rewrite_slot <slot-root> [root]: find the platform layer in a mounted slot and rewrite it.
rewrite_slot() {
    local slot="${1:?rewrite_slot needs a directory}" as_root="${2:-}"
    local stage
    if ! stage=$(find_platform "${slot}"); then
        echo "derive-variant=fail reason=platform-tree-not-found"
        return 1
    fi
    rewrite_tree "${stage}" "${as_root}"
}

# rewrite_record <esp-dir> [root]: the image's own account of itself has to match the file.
rewrite_record() {
    local dir="${1:?rewrite_record needs a directory}" as_root="${2:-}"
    local record="${dir}/ab/image.json"
    [ -f "${record}" ] || { echo "derive-variant=fail reason=image-json-missing"; return 1; }
    local tmp
    tmp=$(mktemp)
    python3 - "${record}" "${WANT}" >"${tmp}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = json.load(fh)
doc["net_wan_ssh"] = want
json.dump(doc, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
    place_file "${tmp}" "${record}" "${as_root}"
    local got
    got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("net_wan_ssh",""))' "${record}")
    if [ "${got}" != "${WANT}" ]; then
        echo "derive-variant=fail reason=record-readback-${got:-empty}"
        return 1
    fi
}

# wait_part <loop> <n>: --partscan exposes ${loop}p<n> a moment after losetup returns,
# and mounting before the node exists fails for a reason that has nothing to do with the image.
wait_part() {
    local dev="$1" n="$2" attempt=0
    while [ ! -b "${dev}p${n}" ] && [ "${attempt}" -lt 40 ]; do
        attempt=$((attempt + 1))
        sleep 0.25
    done
    [ -b "${dev}p${n}" ]
}

mount_part() { # <loop> <partnum> <type> <mountpoint>
    sudo mount -t "${3}" "${1}p${2}" "${4}"
}

cleanup_image() {
    if [ -n "${work}" ]; then
        sudo umount "${work}" 2>/dev/null || true
        rm -rf "${work}"
    fi
    if [ -n "${loop}" ]; then
        sudo losetup -d "${loop}" 2>/dev/null || true
    fi
}

main() {
    local image="" out="" tree="" slot=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --image) image=${2:?--image needs a value}; shift 2 ;;
            --out) out=${2:?--out needs a value}; shift 2 ;;
            --rewrite-slot) slot=${2:?--rewrite-slot needs a value}; shift 2 ;;
            --rewrite-tree) tree=${2:?--rewrite-tree needs a value}; shift 2 ;;
            -h | --help | help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done

    if [ -n "${tree}" ]; then
        rewrite_tree "${tree}"
        echo "derive-variant=ok net_wan_ssh=${WANT}"
        return 0
    fi

    if [ -n "${slot}" ]; then
        rewrite_slot "${slot}"
        echo "derive-variant=ok net_wan_ssh=${WANT}"
        return 0
    fi

    [ -n "${image}" ] && [ -n "${out}" ] || { usage >&2; exit 2; }
    [ -f "${image}" ] || { echo "derive-variant=fail reason=image-missing"; exit 1; }

    cp "${image}" "${out}"
    work=$(mktemp -d)
    loop=$(sudo losetup --find --show --partscan "${out}")
    trap cleanup_image EXIT

    # p2 carries @platform; the knob lives at <layer>/etc/net-defaults.conf inside it.
    wait_part "${loop}" 2 || { echo "derive-variant=fail reason=slot-partition-missing"; exit 1; }
    mount_part "${loop}" 2 btrfs "${work}" \
        || { echo "derive-variant=fail reason=cannot-mount-platform"; exit 1; }
    rewrite_slot "${work}" root || exit 1
    sudo sync
    sudo umount "${work}"

    # p1 carries ab/image.json, which is what the release preflight reads.
    wait_part "${loop}" 1 || { echo "derive-variant=fail reason=esp-partition-missing"; exit 1; }
    mount_part "${loop}" 1 vfat "${work}" \
        || { echo "derive-variant=fail reason=cannot-mount-esp"; exit 1; }
    rewrite_record "${work}" root || exit 1
    sudo sync
    sudo umount "${work}"

    echo "derive-variant=ok net_wan_ssh=${WANT}"
}

main "$@"
