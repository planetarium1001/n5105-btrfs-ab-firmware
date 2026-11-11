#!/usr/bin/env bash
# Stage helper "initramfs-tools": stage the foreign programs an initramfs carries.
#
# The boot initramfs runs before the platform layer is mounted, so it needs its own
# busybox, partition tools and libraries. They come from the same ImmortalWrt release
# as the rest of the image - never from the build host, whose libc and program
# versions drift with the runner image.
#
# scripts/ci/initramfs-tools.lock.json is the contract: package versions, .apk
# sha256, the install path/mode/sha256 of every extracted file and the symlinks the
# runtime needs. Every build verifies all of it; a drift fails the stage instead of
# producing an image with a different program in it.
#
# A build for another upstream release cannot be verified against that contract - the
# release publishes different programs by construction - so it derives its own lockfile
# under $CI_TMP_ROOT, verifies against that copy and warns. The committed lockfile stays
# the contract for the pin; CI_LOCK_STRICT=1 keeps it in force for every release.
#
# Inputs (environment):
#   CI_UPSTREAM_BASE       mirror root (default: https://downloads.immortalwrt.org)
#   CI_UPSTREAM_VERSION    upstream release; defaults to CI_UPSTREAM_VERSION_PIN and
#                          must match the lockfile, so a half-done pin bump fails here
#   CI_UPSTREAM_BASE_URL   release target directory; optional, used to derive the
#                          release root when the resolve stage already knows it
#   CI_INITRAMFS_TOOLSET   probe | boot | assert
#   CI_INITRAMFS_STAGE     staging directory (the initramfs root)
#   CI_APK_DIR             apk cache (default: $CI_TMP_ROOT/apks)
#   CI_APK_TOOLS_LOCK      lockfile (default: scripts/ci/initramfs-tools.lock.json)
#   CI_APK_TOOLS_SUMMARY   where to write the JSON summary (default: <tmp>/tools.json)
#   CI_APK_TOOLS           lock generator and installer (default: scripts/ci/apk_tools.py)
#   CI_LOCK_STRICT         1 asserts the lockfile even when CI_UPSTREAM_VERSION differs
#
# Outputs: tools_digest, tools_versions, tools_bytes, tools_files
#
# Usage:
#   initramfs-tools.sh --toolset boot --stage <dir>     stage one toolset
#   initramfs-tools.sh --write-lock                    regenerate the lockfile (network)

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

toolset=""
stage=""
write_lock="false"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --toolset) toolset="${2:-}"; shift 2 ;;
        --toolset=*) toolset="${1#--toolset=}"; shift ;;
        --stage) stage="${2:-}"; shift 2 ;;
        --stage=*) stage="${1#--stage=}"; shift ;;
        --write-lock) write_lock="true"; shift ;;
        *) ci_die "unknown argument: $1" ;;
    esac
done

lockfile="${CI_APK_TOOLS_LOCK:-${CI_SCRIPT_DIR}/initramfs-tools.lock.json}"
apk_tools="${CI_APK_TOOLS:-${CI_SCRIPT_DIR}/apk_tools.py}"
apk_dir="${CI_APK_DIR:-${CI_TMP_ROOT:-/tmp/ci}/apks}"
release_root="${CI_UPSTREAM_BASE%/}/releases"
if [ -n "${CI_UPSTREAM_BASE_URL:-}" ]; then
    # The resolve stage publishes the target directory (.../targets/x86/64).
    release_root="${CI_UPSTREAM_BASE_URL%/targets/*}"
    release_root="${release_root%/}"
else
    release_root="${release_root}/${CI_UPSTREAM_VERSION:-${CI_UPSTREAM_VERSION_PIN}}"
fi

ci_require_cmd python3 curl

# warn_derived_lock: the step log and the run page both have to carry the fact that this
# build is not under the pin contract, because a green stage otherwise reads as "the
# committed lockfile was verified".
warn_derived_lock() {
    ci_warn "derived per-version lockfile: ${lockfile}"
    ci_warn "  the ${build_version} build does not assert the committed lockfile (pinned ${pin_lock_version}): program drift is NOT enforced for this release"
    ci_warn "  CI_LOCK_STRICT=1 turns the same drift back into a hard failure"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::warning title=initramfs-tools derived lockfile::%s build uses %s; the committed lockfile pins %s, so program drift is not asserted for this release\n' \
            "${build_version}" "${lockfile}" "${pin_lock_version}"
    fi
}

if [ "${write_lock}" = "true" ]; then
    version="${CI_UPSTREAM_VERSION:-${CI_UPSTREAM_VERSION_PIN}}"
    ci_log "regenerating ${lockfile#"${CI_REPO_ROOT}"/} for upstream ${version}"
    python3 "${apk_tools}" lock \
        --lock "${lockfile}" \
        --base-url "${CI_UPSTREAM_BASE}" \
        --upstream-version "${version}" \
        --work "${apk_dir}"
    ci_log "lockfile written; review the diff and commit it with the pin bump"
    exit 0
fi

[ -n "${toolset}" ] || ci_die "--toolset is required (probe, boot or assert)"
[ -n "${stage}" ] || ci_die "--stage is required"
[ -f "${lockfile}" ] || ci_die "lockfile not found: ${lockfile}"

# The lockfile and the build's release must agree. A pin bump without the matching lock
# update would silently keep building the previous release's programs, so a build that
# names no release at all always dies here. A build that names another release derives
# its own lockfile instead: the pin cannot be asserted against programs it never pinned,
# and the derived copy is what the rest of this script verifies and stages.
build_version="${CI_UPSTREAM_VERSION:-${CI_UPSTREAM_VERSION_PIN}}"
lock_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream_version"])' "${lockfile}")"
pin_lock_version="${lock_version}"
if [ "${lock_version}" != "${build_version}" ]; then
    if [ -z "${CI_UPSTREAM_VERSION:-}" ] || [ "${CI_LOCK_STRICT:-0}" = "1" ]; then
        ci_die "lockfile pins upstream ${lock_version} but this build uses ${build_version}; run initramfs-tools.sh --write-lock and commit the result"
    fi
    lockfile="${CI_TMP_ROOT:-/tmp/ci}/locks/initramfs-tools-${build_version}.lock.json"
    mkdir -p "$(dirname "${lockfile}")"
    if [ -f "${lockfile}" ]; then
        # One derived lockfile serves every toolset of the same build: it lives in the
        # build's scratch root, and every staging run verifies the packages it names, so
        # a second toolset does not pay for another feed resolution.
        ci_log "reusing the derived lockfile ${lockfile}"
    else
        ci_log "deriving a per-version lockfile for upstream ${build_version}: ${lockfile}"
        python3 "${apk_tools}" lock \
            --lock "${lockfile}" \
            --base-url "${CI_UPSTREAM_BASE}" \
            --upstream-version "${build_version}" \
            --work "${apk_dir}" \
            || ci_die "could not derive ${lockfile} from ${CI_UPSTREAM_BASE} for upstream ${build_version}"
        [ -f "${lockfile}" ] || ci_die "deriving ${lockfile} produced no lockfile"
    fi
    lock_version="${build_version}"
    warn_derived_lock
fi

# Download exactly the packages the lockfile names, into a cache shared by all stages.
# A cached file is reused only when its sha256 still matches the lockfile, so a stale
# or tampered cache entry re-downloads instead of being trusted.
while IFS=$'\t' read -r feed file want; do
    [ -n "${file}" ] || continue
    if [ -f "${apk_dir}/${file}" ] && [ "$(ci_sha256 "${apk_dir}/${file}")" = "${want}" ]; then
        ci_log "cached ${file}"
        continue
    fi
    ci_download "${release_root}/${feed}/${file}" "${apk_dir}/${file}"
done < <(python3 - "${lockfile}" <<'PYTHON'
import json, sys

lock = json.load(open(sys.argv[1]))
for record in lock["packages"]:
    print(f"{lock['feeds'][record['feed']]}\t{record['file']}\t{record['apk_sha256']}")
PYTHON
)

summary="${CI_APK_TOOLS_SUMMARY:-${CI_TMP_ROOT:-/tmp/ci}/initramfs-tools-${toolset}.json}"
mkdir -p "$(dirname "${summary}")"
python3 "${apk_tools}" install \
    --lock "${lockfile}" \
    --stage "${stage}" \
    --toolset "${toolset}" \
    --apk-dir "${apk_dir}" \
    --upstream-version "${build_version}" \
    | tee "${summary}"

digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "${summary}")"
versions="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["versions"]))' "${summary}")"
bytes_total="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bytes"])' "${summary}")"
files_total="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"])' "${summary}")"

# One line per program, so a build log answers "which sfdisk booted this image?"
python3 - "${lockfile}" "${toolset}" <<'PYTHON' | while IFS= read -r line; do ci_log "  ${line}"; done
import json, sys

lock = json.load(open(sys.argv[1]))
toolset = sys.argv[2]
for record in lock["packages"]:
    for item in record["files"]:
        if toolset in item["toolsets"]:
            print(f"{item['path']} {record['version']} sha256={item['sha256'][:12]} ({record['file']})")
PYTHON

ci_log "toolset ${toolset}: ${files_total} file(s), ${bytes_total} bytes, digest ${digest:0:12}"
ci_log "  upstream release ${lock_version}, ${versions}"

ci_emit_output "tools_digest" "${digest}"
ci_emit_output "tools_versions" "${versions}"
ci_emit_output "tools_bytes" "${bytes_total}"
ci_emit_output "tools_files" "${files_total}"
