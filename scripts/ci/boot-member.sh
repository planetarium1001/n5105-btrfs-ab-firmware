#!/usr/bin/env bash
# The payload's bootloader member, defined once for every builder.
#
# Sourced by scripts/ci/payload-build.sh (the S5 test payload) and scripts/ci/assemble.sh
# (the payload a release actually publishes). It lives in its own file because the member
# only does its job if both builders produce it the same way: when only the test payload
# carried `boot.tar`, the published payload still left an updated machine booting the GRUB
# it was flashed with - the defect looked fixed because CI exercised the other builder.
#
# The member is `boot.tar` with two paths inside: EFI/BOOT/BOOTX64.EFI (the upstream loader,
# byte identical to the one the ESP gets) and boot/grub/grub.cfg (our slot menu, rendered
# from scripts/ci/grub.cfg.in). Next to it goes the identity an updater compares against the
# ESP's current bytes: `loader_sha256` is the fact a device trusts, `grub_version` the
# readable evidence beside it.
#
# Inputs (environment), all optional:
#   CI_BOOT_SRC           ESP tree to take the loader from (default $CI_TMP_ROOT/esp)
#   CI_BOOTLOADER_CFG     the menu to ship instead of rendering one
#   CI_GRUB_OUTPUT        menu produced by an earlier stage, used when CI_BOOTLOADER_CFG
#                         is unset (then $CI_TMP_ROOT/disk/grub.cfg)
#   CI_BOOTLOADER_VERSION GRUB version to record; otherwise read out of the loader
#   CI_BOOT_SOURCE_IMAGE  name of the upstream image the loader came from, recorded
#   CI_BOOT_SOURCE_SHA256 digest of that image, recorded
#   CI_REQUIRE_BOOTLOADER "1" turns "no boot source" into a build failure
#
# Outputs (globals, read by the caller after ci_boot_member_stage returns):
#   CI_BOOT_MEMBER        "boot.tar", or empty when the payload carries no bootloader
#   CI_BOOT_GRUB_VERSION  the recorded GRUB version ("unknown" when there is no member)
#   CI_BOOT_BLOCK         path to the manifest's bootloader block as JSON, or empty
#
# The caller must have sourced scripts/ci/lib.sh first (this fragment uses its helpers but
# does not source it again: lib.sh is idempotent, the ordering is simply the callers').

# ci_boot_member_menu <work-dir>: decide where the shipped menu comes from and make sure it
# is a menu the shipped GRUB can parse. Prints the path.
#
# The render directory is created before either branch, not inside the branch that renders:
# the external-menu path used to inherit a directory that never existed, so the redirect
# into `<work>/render/grub-check.log` failed and the `||` turned "cannot create the log" into
# "the menu violates the rendering rules". CI took that path (the menu comes from
# $CI_TMP_ROOT/disk/grub.cfg) while the unit tests only took the rendering one, which is why
# the message sent everyone looking at the menu instead of the directory.
ci_boot_member_menu() {
    local work_dir="$1"
    local render_dir="${work_dir}/render"
    local menu="${CI_BOOTLOADER_CFG:-}"
    local log

    mkdir -p "${render_dir}" || ci_die "cannot create the menu directory ${render_dir}"

    # A menu the caller named is used or the build stops. Falling back to a rendered one when
    # the path is simply wrong would ship a menu nobody asked for, and CI would only notice
    # by reading the payload - the same shape of silent substitution this fragment exists to
    # remove. CI_BOOTLOADER_CFG has always behaved this way; these two now match it.
    if [ -n "${CI_GRUB_OUTPUT:-}" ]; then
        [ -f "${CI_GRUB_OUTPUT}" ] || ci_die "CI_GRUB_OUTPUT names no menu: ${CI_GRUB_OUTPUT}"
        menu="${CI_GRUB_OUTPUT}"
    fi
    if [ -z "${menu}" ] && [ -f "${CI_TMP_ROOT:-}/disk/grub.cfg" ]; then
        menu="${CI_TMP_ROOT}/disk/grub.cfg"
    fi
    if [ -z "${menu}" ]; then
        # The menu that ships in the payload is ours, rendered from the same template as the
        # image's, never the upstream one: the upstream menu boots /boot/vmlinuz by PARTUUID
        # and knows nothing about slots.
        log="${render_dir}/grub-render.log"
        : >"${log}" || ci_die "cannot write the menu render log ${log}: the directory ${render_dir} is not writable"
        if ! CI_GRUB_OUTPUT="${render_dir}/grub.cfg" \
            bash "${CI_SCRIPT_DIR}/grub-render.sh" >"${log}" 2>&1; then
            ci_die "cannot render the bootloader menu for the payload, see ${log}"
        fi
        menu="${render_dir}/grub.cfg"
    fi
    [ -f "${menu}" ] || ci_die "bootloader menu not found: ${menu}"

    # The member carries our menu, so it has to satisfy the same five rendering rules as
    # the image's: a payload that ships a menu the shipped GRUB cannot parse would boot
    # the committed slot forever. A log this fragment cannot write is reported as such,
    # never as a menu that failed the check.
    log="${render_dir}/grub-check.log"
    : >"${log}" || ci_die "cannot write the menu check log ${log}: the directory ${render_dir} is not writable"
    if ! bash "${CI_SCRIPT_DIR}/grub-render.sh" --check "${menu}" >"${log}" 2>&1; then
        ci_die "the bootloader menu for the payload violates the rendering rules (${menu}), see ${log}"
    fi
    printf '%s\n' "${menu}"
}

# ci_boot_member_version <loader>: the GRUB release string, or "unknown".
#
# Read out of the loader itself rather than assumed: the official 25.12.x images all ship
# the same BOOTX64.EFI, but "the upstream loader never changes" is an observation and not a
# contract, and the manifest has to say what was really shipped.
ci_boot_member_version() {
    python3 - "$1" <<'PYTHON'
import re, sys
MESSAGE = b"GNU GRUB  version"
TOKEN = re.compile(r"[0-9]+\.[0-9]+(\.[0-9]+)?([~-][0-9A-Za-z.~+-]+)?")
data = open(sys.argv[1], "rb").read()
at = data.find(MESSAGE)
if at < 0:
    print("unknown")
    raise SystemExit(0)
end = data.find(b"\0", at)
token = ""
if end >= 0:
    stop = data.find(b"\0", end + 1)
    token = data[end + 1:stop if stop >= 0 else end + 32].decode("ascii", "replace")
print(token if TOKEN.fullmatch(token) else "unknown")
PYTHON
}

# ci_boot_member_stage <stage-dir> <work-dir>: build boot.tar and the manifest block.
#
# <stage-dir> receives boot.tar; <work-dir> is where the tree and the logs live. Sets
# CI_BOOT_MEMBER, CI_BOOT_GRUB_VERSION and CI_BOOT_BLOCK. Returns 0 with an empty
# CI_BOOT_MEMBER when there is no boot source and the caller did not require one.
ci_boot_member_stage() {
    local stage_dir="$1"
    local work_dir="$2"
    local boot_src="${CI_BOOT_SRC:-${CI_TMP_ROOT:-}/esp}"
    local tree="${work_dir}/boot-tree"
    local loader menu version
    local source_image source_sha

    CI_BOOT_MEMBER=""
    CI_BOOT_GRUB_VERSION="${CI_BOOTLOADER_VERSION:-}"
    CI_BOOT_BLOCK=""

    if [ ! -d "${boot_src}" ]; then
        if [ "${CI_REQUIRE_BOOTLOADER:-0}" = "1" ]; then
            ci_die "no boot source at ${boot_src} and CI_REQUIRE_BOOTLOADER=1: a payload without the bootloader cannot bring one forward"
        fi
        ci_warn "no boot source at ${boot_src}: this payload carries no bootloader, an update will leave the ESP's loader alone"
        CI_BOOT_GRUB_VERSION="unknown"
        return 0
    fi

    loader="$(find "${boot_src}" -type f -iname 'bootx64.efi' | sort | head -n 1)"
    if [ -z "${loader}" ]; then
        loader="$(find "${boot_src}" -type f -iname '*.efi' | sort | head -n 1)"
    fi
    [ -n "${loader}" ] || ci_die "the boot source ${boot_src} carries no EFI loader"

    menu="$(ci_boot_member_menu "${work_dir}")"
    version="${CI_BOOT_GRUB_VERSION:-}"
    if [ -z "${version}" ]; then
        version="$(ci_boot_member_version "${loader}")"
    fi

    rm -rf "${tree}"
    mkdir -p "${tree}/EFI/BOOT" "${tree}/boot/grub"
    cp "${loader}" "${tree}/EFI/BOOT/BOOTX64.EFI"
    cp "${menu}" "${tree}/boot/grub/grub.cfg"
    tar --numeric-owner --owner=0 --group=0 -cf "${stage_dir}/boot.tar" -C "${tree}" .

    # Provenance, kept next to the identity: which upstream image these bytes came out of.
    # The name is the one esp-prepare.sh reads when it mounts the image, so it is derived
    # the same way here when the caller did not pass the values through.
    source_image="${CI_BOOT_SOURCE_IMAGE:-immortalwrt-${CI_UPSTREAM_VERSION:-unknown}-x86-64-generic-squashfs-combined-efi.img.gz}"
    source_sha="${CI_BOOT_SOURCE_SHA256:-}"

    CI_BOOT_MEMBER="boot.tar"
    CI_BOOT_GRUB_VERSION="${version}"
    CI_BOOT_BLOCK="${work_dir}/manifest.bootloader.json"
    python3 - "${tree}/EFI/BOOT/BOOTX64.EFI" "${tree}/boot/grub/grub.cfg" \
        "${CI_BOOT_MEMBER}" "${version}" "${source_image}" \
        "${source_sha}" "${CI_BOOT_BLOCK}" <<'PYTHON'
import hashlib, json, pathlib, sys

loader_path, menu_path, member, version, source_image, source_sha, out = sys.argv[1:8]


def digest(path):
    data = pathlib.Path(path).read_bytes()
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


loader = digest(loader_path)
block = {
    "member": member,
    "loader": "EFI/BOOT/BOOTX64.EFI",
    "menu": "boot/grub/grub.cfg",
    "loader_bytes": loader["size"],
    "loader_sha256": loader["sha256"],
    "menu_sha256": digest(menu_path)["sha256"],
    "grub_version": version,
    "source_image": source_image or None,
    "source_sha256": source_sha or None,
}
pathlib.Path(out).write_text(json.dumps(block, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYTHON

    ci_log "payload bootloader: ${loader#"${boot_src}"/} ($(ci_file_size "${loader}") bytes, GRUB ${version}) + ${CI_BOOT_MEMBER} from ${menu}"
    return 0
}
