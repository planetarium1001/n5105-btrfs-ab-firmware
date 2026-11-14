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
#   derive-variant.sh --rewrite-tree <dir>
#       the same rewrite on a plain directory tree (used by the unit test, no loop device)
#
# Outputs one line on success (`derive-variant=ok net_wan_ssh=open`) or a refusal
# (`derive-variant=fail reason=...`). Exit: 0 ok, 1 refused, 2 usage.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

WANT=open

usage() {
    cat <<'USAGE'
usage: derive-variant.sh --image <in.img> --out <out.img>
       derive-variant.sh --rewrite-tree <dir>
USAGE
}

# rewrite_tree <platform-stage-dir>: set NET_WAN_SSH to $WANT, exactly one line.
# Rewriting by count rather than by sed -i keeps a template that lost its knobs an error
# instead of a silently unchanged file.
rewrite_tree() {
    local dir="${1:?rewrite_tree needs a directory}"
    local conf="${dir}/etc/net-defaults.conf"
    [ -f "${conf}" ] || { echo "derive-variant=fail reason=net-defaults-missing"; return 1; }
    local hits
    hits=$(grep -c '^NET_WAN_SSH=' "${conf}" || true)
    if [ "${hits}" -ne 1 ]; then
        echo "derive-variant=fail reason=net-defaults-knob-count-${hits}"
        return 1
    fi
    local tmp="${conf}.new"
    sed -e "s|^NET_WAN_SSH=.*|NET_WAN_SSH=${WANT}|" "${conf}" >"${tmp}"
    mv "${tmp}" "${conf}"
    local got
    got=$(sed -n 's/^NET_WAN_SSH=//p' "${conf}" | head -n 1)
    if [ "${got}" != "${WANT}" ]; then
        echo "derive-variant=fail reason=readback-${got:-empty}"
        return 1
    fi
}

# rewrite_record <esp-dir>: the image's own account of itself has to match the file.
rewrite_record() {
    local dir="${1:?rewrite_record needs a directory}"
    local record="${dir}/ab/image.json"
    [ -f "${record}" ] || { echo "derive-variant=fail reason=image-json-missing"; return 1; }
    python3 - "${record}" "${WANT}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = json.load(fh)
doc["net_wan_ssh"] = want
with open(path, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
    local got
    got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("net_wan_ssh",""))' "${record}")
    if [ "${got}" != "${WANT}" ]; then
        echo "derive-variant=fail reason=record-readback-${got:-empty}"
        return 1
    fi
}

mount_part() { # <loop> <partnum> <mountpoint>
    sudo mount "${1}p${2}" "${3}"
}

main() {
    local image="" out="" tree=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --image) image=${2:?--image needs a value}; shift 2 ;;
            --out) out=${2:?--out needs a value}; shift 2 ;;
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

    [ -n "${image}" ] && [ -n "${out}" ] || { usage >&2; exit 2; }
    [ -f "${image}" ] || { echo "derive-variant=fail reason=image-missing"; exit 1; }

    cp "${image}" "${out}"
    local loop work
    work=$(mktemp -d)
    loop=$(sudo losetup --find --show --partscan "${out}")

    # p2 carries @platform; the knob lives at <layer>/etc/net-defaults.conf inside it.
    mount_part "${loop}" 2 "${work}" || {
        sudo losetup -d "${loop}"; rm -rf "${work}"
        echo "derive-variant=fail reason=cannot-mount-platform"; exit 1
    }
    local stage
    stage=$(find "${work}" -maxdepth 3 -type d -name etc -path '*/@platform/*' | head -n 1)
    stage=${stage%/etc}
    if [ -z "${stage}" ]; then
        sudo umount "${work}"; sudo losetup -d "${loop}"; rm -rf "${work}"
        echo "derive-variant=fail reason=platform-tree-not-found"; exit 1
    fi
    if ! rewrite_tree "${stage}"; then
        sudo umount "${work}"; sudo losetup -d "${loop}"; rm -rf "${work}"
        exit 1
    fi
    sudo sync
    sudo umount "${work}"

    # p1 carries ab/image.json, which is what the release preflight reads.
    mount_part "${loop}" 1 "${work}" || {
        sudo losetup -d "${loop}"; rm -rf "${work}"
        echo "derive-variant=fail reason=cannot-mount-esp"; exit 1
    }
    if ! rewrite_record "${work}"; then
        sudo umount "${work}"; sudo losetup -d "${loop}"; rm -rf "${work}"
        exit 1
    fi
    sudo sync
    sudo umount "${work}"
    sudo losetup -d "${loop}"
    rm -rf "${work}"

    echo "derive-variant=ok net_wan_ssh=${WANT}"
}

main "$@"
