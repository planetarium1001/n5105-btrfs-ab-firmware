#!/usr/bin/env bash
# Stage "preflight": refuse to publish unless the image, the payload and the tag agree.
#
# A release is identified by its system version, and three independent things carry
# that version - plus a fourth decides whether the payload can be installed at all:
#
#   * the image's own record       <image-dir>/ab/image.json  (kind, versions)
#   * the payload's manifest       manifest.json inside the payload tar
#   * the tag being published
#   * the bootloader member        boot.tar, carrying grub.cfg and the GRUB core
#
# Publishing with any of them disagreeing ships a release that looks fine and cannot be
# installed, or - the case this file exists for - an image nothing can update because the
# payload carries no bootloader. `release-publish.yml` runs this script before
# `gh release create`, and a non-zero exit is the refusal (ac-17).
#
# The script only reads paths: mounting the image, gunzipping it and downloading the
# artifact stay in the workflow steps. Every input is therefore a file a fixture can
# produce, which is how tests/modules/ci/test_release_preflight.sh exercises it offline.
#
# Usage:
#   release-preflight.sh --image-dir DIR --payload-manifest FILE --payload-tar FILE --tag TAG
#                        [--tag-policy bare|v] [--platform-version VER] [--version-file PATH]
#
#   --tag-policy bare   the automatic line publishes the bare system version (X.Y.Z);
#                       a 'v' prefix belongs to the other release line and is refused
#   --tag-policy v      the v* line; the platform version is the tag without its 'v'
#   --platform-version  explicit platform version (default: read --version-file)
#   --version-file      the shipped platform version file (default: ./VERSION)
#
# Outputs: tag, upstream_version, platform_version, payload_manifest_sha256,
#          bootloader_member
#
# Every disagreement is reported, not just the first one: a release that fails the
# preflight has to be fixable in one pass, and each reason is one
# `release-preflight: <reason>` line on stderr, meant to be pasted into the failure Issue
# as it is. Only an input that cannot be read at all stops the run immediately - that is
# a broken invocation, not a verdict about the release.

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

usage() {
    cat <<'USAGE'
usage: release-preflight.sh --image-dir DIR --payload-manifest FILE --payload-tar FILE --tag TAG
                            [--tag-policy bare|v] [--platform-version VER] [--version-file PATH]
USAGE
}

# fatal <reason>: an unreadable input ends the run here. Joining the list of version
# disagreements would suggest the release is one edit away from passing, which it is not.
fatal() {
    printf 'release-preflight: %s\n' "$1" >&2
    exit 1
}

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #

image_dir=""
payload_manifest=""
payload_tar=""
tag=""
tag_policy="bare"
platform_version=""
version_file=""

while [ "$#" -gt 0 ]; do
    opt="$1"
    case "${opt}" in
        -h | --help)
            usage
            exit 0
            ;;
        --image-dir | --payload-manifest | --payload-tar | --tag | --tag-policy | \
            --platform-version | --version-file)
            [ "$#" -ge 2 ] || fatal "${opt} needs a value"
            case "${opt}" in
                --image-dir) image_dir="$2" ;;
                --payload-manifest) payload_manifest="$2" ;;
                --payload-tar) payload_tar="$2" ;;
                --tag) tag="$2" ;;
                --tag-policy) tag_policy="$2" ;;
                --platform-version) platform_version="$2" ;;
                --version-file) version_file="$2" ;;
            esac
            shift 2
            ;;
        *)
            usage >&2
            fatal "unknown argument: ${opt}"
            ;;
    esac
done

case "${tag_policy}" in
    bare | v) : ;;
    *)
        usage >&2
        fatal "--tag-policy must be bare or v, got '${tag_policy}'"
        ;;
esac

[ -n "${image_dir}" ] || fatal "--image-dir is required"
[ -n "${payload_manifest}" ] || fatal "--payload-manifest is required"
[ -n "${payload_tar}" ] || fatal "--payload-tar is required"
[ -n "${tag}" ] || fatal "--tag is required"

ci_stage_init preflight

ci_require_cmd python3 tar

image_json="${image_dir%/}/ab/image.json"
[ -f "${image_json}" ] || fatal "image identity not found: ${image_json} (the release needs the mounted partition 1)"
[ -f "${payload_manifest}" ] || fatal "payload manifest not found: ${payload_manifest}"
[ -f "${payload_tar}" ] || fatal "payload tar not found: ${payload_tar}"

work="$(mktemp -d "${CI_TMP_ROOT}/preflight.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

# The reasons, in report order. Nothing exits early once the inputs are readable, so one
# run tells the whole story.
failures=()
record() {
    failures+=("$1")
}

# --------------------------------------------------------------------------- #
# JSON readers
#
# python3 is already a pipeline dependency (payload-build.sh writes the manifest with it),
# so it is the one JSON parser this script needs: a `grep` on a JSON file accepts a
# document no consumer could load, and the point of the preflight is to read what the
# release actually carries.
# --------------------------------------------------------------------------- #

# json_record <file> <key...>: one KEY<TAB>VALUE line per scalar field. A document that
# does not parse is reported by the caller as a fatal input error, not as a verdict.
json_record() {
    python3 - "$@" <<'PYTHON'
import json
import sys

path, keys = sys.argv[1], sys.argv[2:]
try:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError) as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
if not isinstance(doc, dict):
    print("the document is not a JSON object", file=sys.stderr)
    raise SystemExit(1)
for key in keys:
    value = doc.get(key, "")
    if not isinstance(value, str):
        value = ""
    print("%s\t%s" % (key, value))
PYTHON
}

# manifest_record <file>: the manifest's own fields plus one NAME<TAB>SHA256 line per
# member, sorted so the report order does not depend on the JSON key order.
manifest_record() {
    python3 - "$1" <<'PYTHON'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError) as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
if not isinstance(doc, dict):
    print("the manifest is not a JSON object", file=sys.stderr)
    raise SystemExit(1)
for key in ("format", "rootfs"):
    value = doc.get(key, "")
    if not isinstance(value, str):
        value = ""
    print("%s\t%s" % (key, value))
members = doc.get("members")
if not isinstance(members, dict):
    raise SystemExit(0)
for name in sorted(members):
    entry = members[name]
    digest = entry.get("sha256", "") if isinstance(entry, dict) else ""
    if not isinstance(digest, str):
        digest = ""
    print("member\t%s\t%s" % (name, digest))
PYTHON
}

# record_field <record> <key>: one field of a json_record result.
record_field() {
    printf '%s\n' "$1" | awk -F'\t' -v want="$2" '$1 == want { print $2; exit }'
}

# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #

# The payload's member names, as the tar really stores them. One listing serves the
# bootloader extraction and the digest comparison, so both read the same archive.
tar -tf "${payload_tar}" >"${work}/payload-members.txt" 2>"${work}/payload-tar.err" \
    || fatal "payload tar ${payload_tar} is not readable: $(head -n 1 "${work}/payload-tar.err")"

# payload_member <name>: the name the tar uses for <name>, or nothing. Archives built with
# `-C dir .` store "./member", and the manifest never does.
payload_member() {
    awk -v want="$1" '{
        name = $0
        sub(/^\.\//, "", name)
        sub(/\/$/, "", name)
        if (name == want) { print; exit }
    }' "${work}/payload-members.txt"
}

# Platform version: explicit flag first, then the version file the release ships, and the
# bare line additionally needs that file to still hold the published version. That last
# comparison is the mechanical form of "the release does not change VERSION": a release
# whose shipped file says something else rewrites the system version on an upgrade.
version_file="${version_file:-./VERSION}"
version_file_content=""
# Command substitution drops the trailing newline: the file is compared as a value, not
# as bytes, and every other tool in this repository reads it with $(cat VERSION) too.
if [ -f "${version_file}" ]; then
    version_file_content="$(cat "${version_file}")"
fi
if [ -n "${platform_version}" ]; then
    platform_version_source="--platform-version"
    if [ ! -f "${version_file}" ] && [ "${tag_policy}" = "bare" ]; then
        fatal "VERSION file not found: ${version_file}; the bare-version line cannot prove the shipped version file is unchanged"
    fi
else
    if [ ! -f "${version_file}" ] || [ -z "${version_file_content}" ]; then
        fatal "no platform version: --platform-version was not given and ${version_file} is missing or empty"
    fi
    platform_version="${version_file_content}"
    platform_version_source="${version_file}"
fi
ci_log "platform version ${platform_version} (source: ${platform_version_source})"

# --------------------------------------------------------------------------- #
# 1/7 image identity
# --------------------------------------------------------------------------- #

image_record="$(json_record "${image_json}" kind upstream_version platform_version 2>"${work}/image.err")" \
    || fatal "image identity ${image_json} is not parsable JSON: $(head -n 1 "${work}/image.err")"
image_kind="$(record_field "${image_record}" kind)"
image_upstream="$(record_field "${image_record}" upstream_version)"
image_platform="$(record_field "${image_record}" platform_version)"

if [ "${image_kind}" = "boot" ]; then
    ci_log "1/7 image kind is boot (${image_json})"
else
    record "image kind is '${image_kind:-missing}', not 'boot': the release would ship an image that is not the production boot initramfs"
fi
if [ -n "${image_upstream}" ]; then
    ci_log "1/7 image upstream version is ${image_upstream}"
else
    record "image identity ${image_json} carries no upstream_version"
fi

# --------------------------------------------------------------------------- #
# 2/7 tag shape
# --------------------------------------------------------------------------- #

tag_regex="${CI_VERSION_RE}"
tag_policy_note="bare system version"
if [ "${tag_policy}" = "v" ]; then
    tag_regex='^v[0-9]+\.[0-9]+\.[0-9]+$'
    tag_policy_note="v* release tag"
fi
if printf '%s\n' "${tag}" | grep -Eq "${tag_regex}"; then
    ci_log "2/7 tag ${tag} matches --tag-policy ${tag_policy} (${tag_regex})"
else
    record "tag '${tag}' does not match ${tag_regex} (--tag-policy ${tag_policy}): the ${tag_policy_note} is what this line publishes"
fi

# --------------------------------------------------------------------------- #
# 3/7 payload manifest shape
# --------------------------------------------------------------------------- #

manifest_record_out="$(manifest_record "${payload_manifest}" 2>"${work}/manifest.err")" \
    || fatal "payload manifest ${payload_manifest} is not parsable JSON: $(head -n 1 "${work}/manifest.err")"
manifest_format="$(record_field "${manifest_record_out}" format)"
manifest_rootfs="$(record_field "${manifest_record_out}" rootfs)"
printf '%s\n' "${manifest_record_out}" | awk -F'\t' '$1 == "member" { print $2 "\t" $3 }' \
    >"${work}/members.tsv"

# manifest_has_member <name>: 0 when the manifest lists that member.
manifest_has_member() {
    awk -F'\t' -v want="$1" '$1 == want { found = 1 } END { exit !found }' "${work}/members.tsv"
}

if [ "${manifest_format}" = "ab-payload/1" ]; then
    ci_log "3/7 payload manifest format is ab-payload/1"
else
    record "payload manifest format is '${manifest_format:-missing}', expected 'ab-payload/1'"
fi
if [ -n "${manifest_rootfs}" ]; then
    ci_log "3/7 payload manifest rootfs version is ${manifest_rootfs}"
else
    record "payload manifest carries no rootfs version"
fi

# The four members the payload is made of. boot.tar is checked on its own right below:
# its absence is a different failure - an image nothing can update - and has to be named
# as such in the Issue.
for member in rootfs.tar.gz kernel.bin initramfs.cpio.gz platform.tar; do
    if manifest_has_member "${member}"; then
        ci_log "3/7 payload manifest lists ${member}"
    else
        record "payload manifest has no '${member}' member: the payload would not be a complete update"
    fi
done

# --------------------------------------------------------------------------- #
# 4/7 bootloader gate
#
# A payload without a bootloader installs a system whose GRUB still comes from the slot
# it replaced. The first upstream release shipped this way would look published and be
# unpatchable, so this is a hard gate with its own wording (ac-17).
# --------------------------------------------------------------------------- #

bootloader_member="boot.tar"
if manifest_has_member "${bootloader_member}"; then
    ci_log "4/7 payload manifest carries the bootloader member (${bootloader_member})"
    has_bootloader=1
else
    has_bootloader=0
    record "manifest carries no bootloader member (boot.tar): the release would ship an image nothing can update"
fi

# --------------------------------------------------------------------------- #
# 5/7 bootloader content
#
# The manifest entry is a promise; this opens the archive and reads what the promise is
# about: a GRUB menu and a GRUB core. Case is ignored on purpose - FAT is case
# insensitive and the loader the ESP really carries is EFI/BOOT/BOOTX64.EFI, as
# esp-prepare.sh records it.
# --------------------------------------------------------------------------- #

if [ "${has_bootloader}" -eq 1 ]; then
    boot_member="$(payload_member "${bootloader_member}")"
    if [ -z "${boot_member}" ]; then
        record "manifest lists ${bootloader_member} but the payload tar does not carry it: the bootloader the manifest promises is missing"
    elif ! tar -xOf "${payload_tar}" "${boot_member}" >"${work}/boot.tar" 2>"${work}/boot-extract.err"; then
        record "the bootloader member ${bootloader_member} cannot be extracted from the payload tar: $(head -n 1 "${work}/boot-extract.err")"
    elif ! tar -tf "${work}/boot.tar" >"${work}/boot-members.txt" 2>"${work}/boot-list.err"; then
        record "the bootloader member ${bootloader_member} is not a readable tar: $(head -n 1 "${work}/boot-list.err")"
    else
        if grep -Eq '(^|/)grub\.cfg$' "${work}/boot-members.txt"; then
            ci_log "5/7 boot.tar carries grub.cfg"
        else
            record "boot.tar carries no grub.cfg: GRUB would come up with no menu and the machine would not boot"
        fi
        # grub.cfg alone is not a bootloader: a menu without the GRUB core behind it
        # cannot start anything, so the core is checked separately.
        grub_core_re='(^|/)(grubx64\.efi|grub\.efi|bootx64\.efi)$|(^|/)grub/core\.img$|(^|/)boot/grub/.+\.(mod|img|lst)$'
        if grep -Eqi "${grub_core_re}" "${work}/boot-members.txt"; then
            ci_log "5/7 boot.tar carries the GRUB core"
        else
            record "boot.tar carries no GRUB core (grubx64.efi, grub.efi, bootx64.efi, grub/core.img or a boot/grub/ module): there would be nothing to start the menu"
        fi
    fi
fi

# --------------------------------------------------------------------------- #
# 6/7 digests
#
# The manifest is the only description of the payload anybody reads later, so every
# digest in it has to be the digest of the bytes actually in the tar. A member the
# manifest promises and the tar does not carry is the same failure from the other side.
# --------------------------------------------------------------------------- #

while IFS=$'\t' read -r member expected; do
    [ -n "${member}" ] || continue
    actual_member="$(payload_member "${member}")"
    if [ -z "${actual_member}" ]; then
        record "payload manifest member '${member}' is not in the payload tar"
        continue
    fi
    if ! actual="$(tar -xOf "${payload_tar}" "${actual_member}" | ci_sha256_text)"; then
        record "payload manifest member '${member}' cannot be read back from the payload tar"
        continue
    fi
    if [ "${actual}" = "${expected}" ]; then
        ci_log "6/7 ${member} sha256 matches the manifest (${actual})"
    else
        record "payload manifest member '${member}' records sha256 ${expected:-<missing>} but the payload tar carries ${actual}"
    fi
done <"${work}/members.tsv"

# --------------------------------------------------------------------------- #
# 7/7 version agreement
# --------------------------------------------------------------------------- #

if [ "${tag_policy}" = "v" ]; then
    # The v* line names the platform version in the tag itself: release.yml derives
    # `platform_version` from the same `${GITHUB_REF_NAME#v}`, so the tag is the source
    # of truth and the shipped VERSION file is not compared a second time.
    tag_version="${tag#v}"
    if [ "${image_upstream}" = "${manifest_rootfs}" ]; then
        ci_log "7/7 image upstream_version and payload manifest rootfs agree (${image_upstream})"
    else
        record "image upstream_version '${image_upstream}' differs from the payload manifest rootfs '${manifest_rootfs}'"
    fi
    if [ "${platform_version}" = "${tag_version}" ]; then
        ci_log "7/7 platform version equals the tag version (${tag_version})"
    else
        record "platform version '${platform_version}' (${platform_version_source}) differs from '${tag_version}', the tag ${tag} without its 'v' prefix"
    fi
    # The image record has to name the version being published on this line too: a build
    # that shipped an older ab/image.json is exactly the v0.0.6 mistake one layer deeper.
    if [ "${image_platform}" = "${platform_version}" ]; then
        ci_log "7/7 image platform_version equals the platform version (${platform_version})"
    else
        record "image platform_version '${image_platform}' differs from the platform version '${platform_version}' (${platform_version_source})"
    fi
else
    if [ "${image_upstream}" = "${tag}" ]; then
        ci_log "7/7 image upstream_version equals the tag (${tag})"
    else
        record "image upstream_version '${image_upstream}' differs from the tag '${tag}'"
    fi
    if [ "${manifest_rootfs}" = "${tag}" ]; then
        ci_log "7/7 payload manifest rootfs equals the tag (${tag})"
    else
        record "payload manifest rootfs '${manifest_rootfs}' differs from the tag '${tag}'"
    fi
    if [ "${image_platform}" = "${platform_version}" ]; then
        ci_log "7/7 image platform_version equals the platform version (${platform_version})"
    else
        record "image platform_version '${image_platform}' differs from the platform version '${platform_version}' (${platform_version_source})"
    fi
    if [ "${version_file_content}" = "${platform_version}" ]; then
        ci_log "7/7 ${version_file} still carries the platform version being published (${platform_version})"
    else
        record "${version_file} carries '${version_file_content}', the release publishes '${platform_version}': the shipped version file and the release would disagree"
    fi
fi

# --------------------------------------------------------------------------- #
# Verdict
# --------------------------------------------------------------------------- #

if [ "${#failures[@]}" -gt 0 ]; then
    for reason in "${failures[@]}"; do
        printf 'release-preflight: %s\n' "${reason}" >&2
    done
    ci_log "preflight refused the release: ${#failures[@]} problem(s) above"
    exit 1
fi

manifest_sha256="$(ci_sha256 "${payload_manifest}")"
ci_log "preflight passed: image, payload manifest and tag agree on ${tag}"

ci_emit_output "tag" "${tag}"
ci_emit_output "upstream_version" "${image_upstream}"
ci_emit_output "platform_version" "${platform_version}"
ci_emit_output "payload_manifest_sha256" "${manifest_sha256}"
ci_emit_output "bootloader_member" "${bootloader_member}"

ci_log "stage preflight finished"
