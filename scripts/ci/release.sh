#!/usr/bin/env bash
# Stage "release": turn a verified build into named, checksummed release artifacts.
#
# A release is only worth publishing if it can be checked after the fact, so this
# stage produces three things and nothing else:
#
#   n5105-ab-<upstream>-install.img.gz      the disk image, compressed
#   n5105-ab-<upstream>-install-wan-ssh.img.gz
#                                          the same image with the WAN SSH exception on
#                                          (CI_RELEASE_VARIANT=wan-ssh)
#   n5105-ab-<upstream>-upgrade.tar         the update payload
#   SHA256SUMS                              digests of both
#   release-notes.md                        versions, inputs, verification steps
#   index.txt                               the AB-FEED 1 index (feed-index.sh), when the
#                                           kernel version of this release is known
#
# `index.txt` is what a machine reads to find this release (`ab-upgrade --feed-check`
# fetches `<UPDATE_FEED_URL>/index.txt`). It is generated here rather than published by
# hand so the payload digest in the index cannot drift from the payload in SHA256SUMS:
# feed-index.sh reads that file and re-hashes the payload next to it. It is deliberately
# not a line of SHA256SUMS - the index describes the release, and a checksum file that
# covered it would have to describe itself.
#
# The compressed image is round-tripped and compared against the raw image's digest,
# so a truncated or corrupted compression cannot be published.
#
# Inputs (environment):
#   CI_PLATFORM_VERSION   platform version, recorded in the notes only
#   CI_UPSTREAM_VERSION   upstream release label, used in the file names
#   CI_IMAGE              raw image to compress      (one of the two is required)
#   CI_IMAGE_GZ           already compressed image
#   CI_PAYLOAD            payload tar to publish     (optional)
#   CI_RELEASE_DIR        output directory (default: $CI_TMP_ROOT/release)
#   CI_RELEASE_TAG        tag or run identifier recorded in the notes
#   CI_UPSTREAM_ROOTFS_SHA256, CI_UPSTREAM_KERNEL_SHA256
#                         upstream digests; when unset they are read from the payload
#                         manifest's rootfs.tar.gz / kernel.bin members, and disagreement
#                         between the two statements fails the release
#   CI_S5_LINE            judge line of the last verified firmware run; when unset the
#                         notes say where that verdict is recorded instead of inventing one
#   CI_KERNEL_PACKAGE     kernel package version of the build, recorded in the notes and
#                         used as the index's `kernel` field; when unset it is read from
#                         the payload manifest's `kernel` field, so a caller that forgets
#                         it no longer publishes a release whose page denies the kernel the
#                         payload names (neither variable nor manifest: no index)
#   CI_FEED_BASE_URL      directory index.txt will be served from; turns the index's
#                         `payload` into an absolute `url` (optional)
#   CI_FEED_HISTORY       space-separated directories of earlier releases to carry in the
#                         index so `--stepwise` has somewhere to step (optional; this
#                         release is always first, the helper sorts the rest)
#
# Outputs: release_dir, image_gz, image_gz_sha256, image_sha256, payload_copy,
#          sums_path, notes_path, artifact_list, feed_index

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

ci_stage_init release

ci_require_cmd gzip sha256sum

platform_version="${CI_PLATFORM_VERSION:?CI_PLATFORM_VERSION is required}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
release_dir="${CI_RELEASE_DIR:-${CI_TMP_ROOT}/release}"
tag="${CI_RELEASE_TAG:-local}"
base="n5105-ab-${upstream_version}"
# A variant is a second build of the same release for a different default, not a second
# release: same tag, same payload, same digests, one extra name. Only the WAN SSH
# exception has a variant today (docs/install.md), and its name has to say so, because
# "the image without the open port" and "the image with it" must never be confusable.
release_variant="${CI_RELEASE_VARIANT:-}"
case "${release_variant}" in
    ''|default) release_variant="" ;;
    wan-ssh) : ;;
    *) ci_die "unknown release variant: ${release_variant}" ;;
esac

image="${CI_IMAGE:-}"
image_gz_in="${CI_IMAGE_GZ:-}"
payload_in="${CI_PAYLOAD:-}"
[ -n "${image}" ] || [ -n "${image_gz_in}" ] || ci_die "either CI_IMAGE or CI_IMAGE_GZ is required"

mkdir -p "${release_dir}"
rm -f "${release_dir}"/*.img.gz "${release_dir}"/*.tar \
    "${release_dir}"/SHA256SUMS "${release_dir}"/release-notes.md "${release_dir}"/index.txt

# --------------------------------------------------------------------------- #
# 1. Image
# --------------------------------------------------------------------------- #

image_gz="${release_dir}/${base}-install${release_variant:+-${release_variant}}.img.gz"
if [ -n "${image_gz_in}" ]; then
    [ -f "${image_gz_in}" ] || ci_die "compressed image not found: ${image_gz_in}"
    cp "${image_gz_in}" "${image_gz}"
    ci_log "reusing the compressed image from the build"
else
    [ -f "${image}" ] || ci_die "image not found: ${image}"
    ci_log "compressing ${image} ($(ci_file_size "${image}") bytes)"
    # -n: no timestamp and no original file name in the gzip header. Without it the header
    # carries the build time and the source name, so the same image compressed twice
    # produces different bytes and the published digest changes for no reason - which makes
    # "did this release change?" unanswerable from SHA256SUMS. -c is what sends the stream
    # to stdout; without it gzip writes <image>.gz and deletes the input image.
    gzip -9 -nc "${image}" >"${image_gz}"
fi

# Round trip: the published artefact must decompress to exactly the built image.
image_sha256="$(gzip -dc "${image_gz}" | sha256sum | cut -d' ' -f1)"
image_gz_sha256="$(ci_sha256 "${image_gz}")"
if [ -n "${image}" ]; then
    built_sha256="$(ci_sha256 "${image}")"
    [ "${image_sha256}" = "${built_sha256}" ] ||
        ci_die "the compressed image decompresses to ${image_sha256}, not ${built_sha256}"
    ci_log "round trip verified: ${image_gz} -> ${image_sha256}"
else
    ci_log "decompressed image digest: ${image_sha256}"
fi
ci_log "image artefact: ${image_gz} ($(ci_file_size "${image_gz}") bytes, sha256 ${image_gz_sha256})"

# --------------------------------------------------------------------------- #
# 1b. The convenience image (optional)
#
# Same release, same tag, same payload - one rendered value different: the WAN SSH
# exception is on. It is a separate file so nobody has to read a README to know which
# image they are writing, and it is compressed and round-tripped exactly like the
# default one.
# --------------------------------------------------------------------------- #

variant_gz=""
variant_in="${CI_VARIANT_IMAGE:-}"
if [ -n "${variant_in}" ]; then
    [ -f "${variant_in}" ] || ci_die "variant image not found: ${variant_in}"
    if [ "${release_variant}" = "wan-ssh" ]; then
        ci_warn "this run already is the wan-ssh variant; CI_VARIANT_IMAGE is ignored"
    else
        variant_gz="${release_dir}/${base}-install-wan-ssh.img.gz"
        ci_log "compressing the wan-ssh variant (${variant_in})"
        # -n for the same reason as the default image: a header timestamp would make the
        # variant's digest depend on when it was built. -c keeps the stream on stdout.
        gzip -9 -nc "${variant_in}" >"${variant_gz}"
        _variant_sha="$(gzip -dc "${variant_gz}" | sha256sum | cut -d' ' -f1)"
        [ "${_variant_sha}" = "$(ci_sha256 "${variant_in}")" ] ||
            ci_die "the compressed variant decompresses to ${_variant_sha}"
        # Two names for the same bytes would be a lie told by the file list: the variant
        # exists because it differs, so identical digests mean the wrong image was passed.
        # Compare the images themselves, not the gzip streams: two compressions of the
        # same bytes differ in their header, and the question here is whether the two
        # *systems* are the same.
        [ "${_variant_sha}" != "${image_sha256}" ] ||
            ci_die "the variant image is byte-identical to the default one"
        ci_log "variant artefact: ${variant_gz} ($(ci_file_size "${variant_gz}") bytes)"
    fi
fi

# --------------------------------------------------------------------------- #
# 2. Payload
# --------------------------------------------------------------------------- #

payload_copy=""
if [ -n "${payload_in}" ]; then
    [ -f "${payload_in}" ] || ci_die "payload not found: ${payload_in}"
    payload_copy="${release_dir}/${base}-upgrade.tar"
    cp "${payload_in}" "${payload_copy}"
    ci_log "payload artefact: ${payload_copy} ($(ci_file_size "${payload_copy}") bytes, sha256 $(ci_sha256 "${payload_copy}"))"
else
    ci_warn "no payload given, the release carries the image only"
fi

# --------------------------------------------------------------------------- #
# 3. SHA256SUMS
# --------------------------------------------------------------------------- #

sums="${release_dir}/SHA256SUMS"
(
    cd "${release_dir}"
    sha256sum "$(basename "${image_gz}")" >"${sums}"
    if [ -n "${payload_copy}" ]; then
        sha256sum "${base}-upgrade.tar" >>"${sums}"
    fi
    if [ -n "${variant_gz}" ]; then
        sha256sum "$(basename "${variant_gz}")" >>"${sums}"
    fi
)
ci_log "checksums:"
sed 's/^/[release]   /' "${sums}"

# --------------------------------------------------------------------------- #
# 4. Release notes
# --------------------------------------------------------------------------- #

notes="${release_dir}/release-notes.md"

# The payload manifest is the build's own record of what went into the release, and the
# payload tar is the one artifact this stage is handed anyway. Reading the Inputs table out
# of it means a value the build recorded cannot become a placeholder on the page because a
# caller forgot to pass a variable: the v0.0.11 page printed a placeholder for a kernel that
# its own index and payload named. An explicit variable still wins, but only when it agrees
# with the manifest - two answers to the same question are a reason to stop, not to pick
# the quieter one.
payload_manifest=""
if [ -n "${payload_in}" ] && [ -f "${payload_in}" ] && ci_have tar; then
    case "${payload_in}" in
        *.tar)
            # assemble.sh writes manifest.json at the tar's root; a payload that is not a
            # tar, or has no manifest, is a caller we still serve (image-only releases).
            payload_manifest="$(tar -xOf "${payload_in}" manifest.json 2>/dev/null || true)"
            ;;
    esac
fi
manifest_kernel=""
manifest_rootfs_sha=""
manifest_kernel_sha=""
if [ -n "${payload_manifest}" ]; then
    manifest_kernel="$(printf '%s\n' "${payload_manifest}" |
        sed -n 's/^[[:space:]]*"kernel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1)"
    # The member block is bounded by its own braces, so the bootloader's sha256 fields
    # (same key, different member) cannot be mistaken for a member digest.
    manifest_rootfs_sha="$(printf '%s\n' "${payload_manifest}" |
        sed -n '/^[[:space:]]*"rootfs\.tar\.gz"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/ {
            s/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p
        }' |
        head -n 1)"
    manifest_kernel_sha="$(printf '%s\n' "${payload_manifest}" |
        sed -n '/^[[:space:]]*"kernel\.bin"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/ {
            s/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p
        }' |
        head -n 1)"
fi
if [ -n "${CI_UPSTREAM_ROOTFS_SHA256:-}" ] && [ -n "${manifest_rootfs_sha}" ] &&
    [ "${CI_UPSTREAM_ROOTFS_SHA256}" != "${manifest_rootfs_sha}" ]; then
    ci_die "the caller says upstream rootfs sha256 ${CI_UPSTREAM_ROOTFS_SHA256}, the payload manifest says ${manifest_rootfs_sha}"
fi
if [ -n "${CI_UPSTREAM_KERNEL_SHA256:-}" ] && [ -n "${manifest_kernel_sha}" ] &&
    [ "${CI_UPSTREAM_KERNEL_SHA256}" != "${manifest_kernel_sha}" ]; then
    ci_die "the caller says upstream kernel sha256 ${CI_UPSTREAM_KERNEL_SHA256}, the payload manifest says ${manifest_kernel_sha}"
fi
if [ -n "${CI_KERNEL_PACKAGE:-}" ] && [ -n "${manifest_kernel}" ] &&
    [ "${CI_KERNEL_PACKAGE}" != "${manifest_kernel}" ]; then
    ci_die "the caller says kernel package ${CI_KERNEL_PACKAGE}, the payload manifest says ${manifest_kernel}"
fi
# Why a value is absent, in one phrase the table can carry: an empty cell would read as
# "nobody looked", and a made-up placeholder reads as a fact. Neither is true.
if [ -n "${payload_manifest}" ]; then
    missing_note="the payload manifest does not carry it"
elif [ -n "${payload_in}" ]; then
    missing_note="the payload carries no readable manifest"
else
    missing_note="this release carries no payload manifest"
fi
upstream_rootfs="${CI_UPSTREAM_ROOTFS_SHA256:-${manifest_rootfs_sha}}"
upstream_kernel="${CI_UPSTREAM_KERNEL_SHA256:-${manifest_kernel_sha}}"
[ -n "${upstream_rootfs}" ] || upstream_rootfs="${missing_note}"
[ -n "${upstream_kernel}" ] || upstream_kernel="${missing_note}"
# The kernel package version is what the index calls `kernel`. It is optional here on
# purpose: a caller that only has an image still gets a release, it just gets no index.
kernel_package="${CI_KERNEL_PACKAGE:-${manifest_kernel}}"
# The S5 verdict belongs to the run that proved the build, not to this stage's inputs:
# the build workflow exposes no stage output to its caller, so the publish job has no
# route to the line. The notes say where it lives instead of printing a placeholder.
judge_line="${CI_S5_LINE:-}"

{
    printf '# N5105 AB firmware %s (upstream %s)\n' "${platform_version}" "${upstream_version}"
    printf '\n'
    printf 'Built by CI for the N5105 v5, x86-64, UEFI only, btrfs A/B slots.\n'
    printf 'Tag: `%s`\n' "${tag}"
    printf '\n'
    printf '## Artifacts\n'
    printf '\n'
    printf '| artifact | size | sha256 |\n'
    printf '| --- | --- | --- |\n'
    printf '| `%s` | %s bytes | `%s` |\n' "$(basename "${image_gz}")" "$(ci_file_size "${image_gz}")" "${image_gz_sha256}"
    if [ -n "${payload_copy}" ]; then
        printf '| `%s-upgrade.tar` | %s bytes | `%s` |\n' "${base}" "$(ci_file_size "${payload_copy}")" \
            "$(ci_sha256 "${payload_copy}")"
    fi
    if [ -n "${variant_gz}" ]; then
        printf '| `%s` | %s bytes | `%s` |\n' "$(basename "${variant_gz}")" "$(ci_file_size "${variant_gz}")" \
            "$(ci_sha256 "${variant_gz}")"
    fi
    printf '\n'
    if [ -n "${variant_gz}" ]; then
        printf '## Two images\n'
        printf '\n'
        printf 'The default image opens nothing on the WAN side. The `-install-wan-ssh` image is\n'
        printf 'the same system with one `22/tcp` rule from the WAN (the `allow_ssh_wan` rule),\n'
        printf 'for a machine that cannot be reached from the LAN and has no keyboard. It prints\n'
        printf 'how to close that rule on its first boot; `docs/install.md` explains the choice.\n'
        printf '\n'
    fi
    printf '`SHA256SUMS` covers both files:\n'
    printf '\n'
    printf '```\n'
    cat "${sums}"
    printf '```\n'
    printf '\n'
    printf '## File names\n'
    printf '\n'
    printf '`%s.img.gz` / `%s.tar`: board, product line, upstream base, role. Releases\n' "${base}" "${base}"
    printf 'before this naming carry `n5105-ab-<platform>-<upstream>.<ext>` instead, where the\n'
    printf 'second field was our own release version.\n'
    printf '\n'
    printf '## Inputs\n'
    printf '\n'
    printf '| field | value |\n'
    printf '| --- | --- |\n'
    printf '| Upstream version | `%s` |\n' "${upstream_version}"
    printf '| Upstream rootfs sha256 | `%s` |\n' "${upstream_rootfs}"
    printf '| Upstream kernel sha256 | `%s` |\n' "${upstream_kernel}"
    # No row at all when the kernel package is unknown: feed-index.sh treats a missing
    # `Kernel package` row as "ask the payload", which is the same answer, while a row with
    # a sentence in it would be read as a kernel version and stop the index. The omission is
    # explained below the table so the page is still complete.
    if [ -n "${kernel_package}" ]; then
        printf '| Kernel package | `%s` |\n' "${kernel_package}"
    fi
    printf '| Platform version | `%s` |\n' "${platform_version}"
    printf '| Uncompressed image sha256 | `%s` |\n' "${image_sha256}"
    printf '\n'
    if [ -z "${kernel_package}" ]; then
        printf 'Kernel package: %s.\n' "${missing_note}"
        printf 'The Inputs table omits it, and this release publishes without a feed index:\n'
        printf 'an index without a kernel would point a machine at a payload it cannot match.\n'
        printf '\n'
    fi
    printf '## Verification\n'
    printf '\n'
    printf 'The build is accepted when these lines appear in the corresponding runs:\n'
    printf '\n'
    printf '```\n'
    printf 'S2-RESULT=ok\n'
    printf 'S3-RESULT=ok slot=a\n'
    printf 'S4-RESULT=ok phase=commit slot=b\n'
    printf 'S5-RESULT=ok upgrade=b\n'
    printf '```\n'
    printf '\n'
    if [ -n "${judge_line}" ]; then
        printf 'Last recorded S5 line: `%s`\n' "${judge_line}"
    else
        # A placeholder here would be read as "the upgrade was never graded". The line has
        # a home - the S5 stage of the build that produced this release prints it and the
        # run report shows it - so the page points there instead of pretending it is lost.
        printf 'The S5 upgrade verdict was recorded by the build run, in its S5 stage and in\n'
        printf 'that run'"'"'s report; the publishing workflow receives no stage output, so the\n'
        printf 'line is not repeated here.\n'
    fi
    printf '\n'
    printf '## Installation\n'
    printf '\n'
    printf 'See `docs/install.md` for writing the image, the first boot, the acceptance\n'
    printf 'checklist and the rollback procedure. The short version:\n'
    printf '\n'
    printf '```\n'
    printf 'gunzip -c %s | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync\n' "$(basename "${image_gz}")"
    printf '```\n'
    printf '\n'
    printf 'After the first boot run `ab-slot status`; it must report `p4=ok` and a\n'
    printf 'committed slot. Updates use `ab-upgrade` with the payload tar above.\n'
} >"${notes}"
ci_log "release notes: ${notes}"

# --------------------------------------------------------------------------- #
# 5. Update feed index
#
# The notes and SHA256SUMS are the index's two inputs, so this runs after both. An
# earlier release is carried along only when the caller names its directory: an index
# that guessed at history would point machines at payloads nobody published.
# --------------------------------------------------------------------------- #

index="${release_dir}/index.txt"
index_state="not generated"
if [ -n "${payload_copy}" ]; then
    index_releases=("${release_dir}")
    # shellcheck disable=SC2206  # CI_FEED_HISTORY is a plain path list, by contract
    index_history=(${CI_FEED_HISTORY:-})
    if [ "${#index_history[@]}" -gt 0 ]; then
        for earlier in "${index_history[@]}"; do
            index_releases+=("${earlier}")
        done
    fi
    index_args=()
    for release_path in "${index_releases[@]}"; do
        index_args+=(--release "${release_path}")
    done
    # The helper is a stage of its own and publishes its own outputs; both file-command
    # channels are therefore pointed away from this stage's, so its keys cannot land in
    # the same output file twice.
    index_status=0
    (
        unset GITHUB_OUTPUT
        CI_OUTPUT_ENV=/dev/null bash "${CI_SCRIPT_DIR}/feed-index.sh" --out "${index}" "${index_args[@]}"
    ) || index_status=$?
    case "${index_status}" in
        0) index_state="generated" ;;
        3)
            # Exit 3 is the one shortfall that is not a failure: nothing here knows the
            # kernel version. Publishing without an index keeps the release installable
            # by hand and leaves the feed one release behind - visible, and repairable
            # by passing CI_KERNEL_PACKAGE. Any other status fails the release, because
            # a published index that disagrees with its payload is worse than none.
            rm -f "${index}"
            ci_warn "no kernel version for this release, index.txt not generated: the release publishes without a feed entry"
            index_state="skipped, kernel version unknown"
            ;;
        *) ci_die "the feed index could not be generated (feed-index.sh exited ${index_status})" ;;
    esac
else
    ci_warn "no payload given, the release carries no feed entry"
fi

if [ "${index_state}" = "generated" ]; then
    # The index carries the kernel *version*; the notes carry the kernel *package*. Both
    # are shown so a reader can match either against what a machine prints.
    kernel_index="$(printf '%s' "${kernel_package}" |
        sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    {
        printf '\n'
        printf '## Update feed\n'
        printf '\n'
        printf '`index.txt` is the `AB-FEED 1` index for this release. A machine with a feed\n'
        printf 'configured fetches `<UPDATE_FEED_URL>/index.txt`, reads the entry for\n'
        printf '`platform %s` / `base %s` / `kernel %s`, and compares it with what it runs.\n' \
            "${platform_version}" "${upstream_version}" "${kernel_index:-${kernel_package}}"
        printf '\n'
        printf 'The same three identities are what an update prompt shows side by side; the\n'
        printf 'risk it reports comes from the `base` difference alone. See `docs/update.md`.\n'
        printf '\n'
        printf '`index.txt` is not covered by `SHA256SUMS`: it describes the release, and the\n'
        printf 'digest it publishes for the payload is the one in `SHA256SUMS`.\n'
        printf '\n'
        printf '```\n'
        cat "${index}"
        printf '```\n'
    } >>"${notes}"
    ci_log "feed index: ${index}"
fi

artifacts="$(basename "${image_gz}")"
[ -n "${variant_gz}" ] && artifacts="${artifacts} $(basename "${variant_gz}")"
[ -n "${payload_copy}" ] && artifacts="${artifacts} ${base}-upgrade.tar"
artifacts="${artifacts} SHA256SUMS release-notes.md"
if [ "${index_state}" = "generated" ]; then
    artifacts="${artifacts} index.txt"
fi

ci_emit_output "release_dir" "${release_dir}"
ci_emit_output "image_gz" "${image_gz}"
ci_emit_output "variant_image_gz" "${variant_gz}"
ci_emit_output "image_gz_sha256" "${image_gz_sha256}"
ci_emit_output "image_sha256" "${image_sha256}"
ci_emit_output "payload_copy" "${payload_copy}"
ci_emit_output "sums_path" "${sums}"
ci_emit_output "notes_path" "${notes}"
ci_emit_output "artifact_list" "${artifacts}"
ci_emit_output "feed_index" "$([ "${index_state}" = "generated" ] && printf '%s' "${index}")"

ci_log "stage release finished"
