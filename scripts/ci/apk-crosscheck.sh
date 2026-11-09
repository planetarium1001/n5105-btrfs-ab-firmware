#!/usr/bin/env bash
# Cross-check the module closure with the upstream package manager itself.
#
# The kmods stage unpacks modules straight out of the apk containers, using the
# closure list that was derived from the upstream DEPENDS graph. This script asks the
# upstream package manager the same question: unpack the upstream rootfs, run its own
# apk-tools 3 inside a chroot, install kmod-fs-btrfs from the published kmods
# repository, and compare the modules it lands with the lockfile.
#
# A mismatch means the lockfile is wrong (missing dependency, extra dependency, or a
# different build) and must be reported, not followed silently.
#
# The check is informational: it needs root, network and a working chroot inside the
# musl rootfs, none of which the gating boot depends on.
#
# Inputs (environment):
#   CI_REFERENCE_ROOT   scratch directory for the unpacked rootfs
#   CI_FETCH_DIR        directory holding upstream/rootfs.tar.gz
#   CI_KMODS_DIR        kernel module directory name on the mirror
#   CI_UPSTREAM_BASE_URL release directory URL
#   CI_LOCKFILE         lockfile path (default: scripts/ci/kmod-closure.json)
#
# Outputs: verdict (ok|differ|error), installed_modules, missing_modules

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init apk-crosscheck

reference_root="${CI_REFERENCE_ROOT:-${CI_TMP_ROOT}/rootfs}"
fetch_dir="${CI_FETCH_DIR:-${CI_TMP_ROOT}/fetch}"
kmods_dir="${CI_KMODS_DIR:?CI_KMODS_DIR is required}"
base_url="${CI_UPSTREAM_BASE_URL:?CI_UPSTREAM_BASE_URL is required}"
lockfile="${CI_LOCKFILE:-${CI_REPO_ROOT}/scripts/ci/kmod-closure.json}"
rootfs_tar="${fetch_dir}/upstream/rootfs.tar.gz"
kmods_url="${base_url}/kmods/${kmods_dir}"

verdict="error"
emit() {
    ci_emit_output "verdict" "${verdict}"
    ci_emit_output "installed_modules" "${installed:-0}"
    ci_emit_output "missing_modules" "${missing:-}"
}
trap emit EXIT

ci_require_cmd sudo tar
[ -f "${rootfs_tar}" ] || ci_die "upstream rootfs not found: ${rootfs_tar}"
[ -f "${lockfile}" ] || ci_die "lockfile not found: ${lockfile}"
sudo -n true 2>/dev/null || ci_die "passwordless sudo is required for the chroot cross-check"

# --------------------------------------------------------------------------- #
# 1. Unpack the upstream rootfs
# --------------------------------------------------------------------------- #

sudo rm -rf "${reference_root}"
sudo mkdir -p "${reference_root}"
sudo tar -xzf "${rootfs_tar}" -C "${reference_root}" --numeric-owner
[ -x "${reference_root}/usr/bin/apk" ] || ci_die "the upstream rootfs has no /usr/bin/apk"
apk_version="$(sudo chroot "${reference_root}" /usr/bin/apk --version 2>&1 | head -n 1 || true)"
ci_log "upstream package manager: ${apk_version:-unknown}"

# The extracted rootfs expects a runtime resolv.conf that does not exist in a tarball.
sudo rm -f "${reference_root}/etc/resolv.conf"
sudo cp /etc/resolv.conf "${reference_root}/etc/resolv.conf"

exported=()
cleanup() {
    local path
    for path in ${exported[@]+"${exported[@]}"}; do
        sudo umount "${path}" 2>/dev/null || true
    done
}
trap 'cleanup; emit' EXIT

# apk needs the kernel filesystems; bind them read-write only where it writes.
for fs in proc sys dev; do
    if [ -d "${reference_root}/${fs}" ]; then
        sudo mount --bind "/${fs}" "${reference_root}/${fs}" || true
        exported+=("${reference_root}/${fs}")
    fi
done

# --------------------------------------------------------------------------- #
# 2. Let apk install the btrfs module closure
# --------------------------------------------------------------------------- #

ci_log "installing kmod-fs-btrfs from ${kmods_url}"
if ! sudo chroot "${reference_root}" /usr/bin/apk add --no-cache --allow-untrusted \
    --repository "${kmods_url}" kmod-fs-btrfs 2>&1 | tee "${CI_LOG_DIR}/apk-crosscheck-apk.log"; then
    ci_warn "apk could not install the closure; see apk-crosscheck-apk.log"
    verdict="error"
    exit 1
fi

# --------------------------------------------------------------------------- #
# 3. Compare what apk installed with the lockfile
# --------------------------------------------------------------------------- #

installed=0
missing=""
differ=0
while IFS= read -r line; do
    path="${line%% *}"
    expected="${line##* }"
    [ -n "${path}" ] || continue
    host_path="${reference_root}${path}"
    if [ ! -f "${host_path}" ]; then
        ci_warn "apk did not install ${path}"
        missing="${missing}${path##*/},"
        differ=1
        continue
    fi
    actual="$(ci_sha256 "${host_path}")"
    if [ "${actual}" != "${expected}" ]; then
        ci_warn "digest differs for ${path}: apk ${actual}, lockfile ${expected}"
        differ=1
        continue
    fi
    installed=$((installed + 1))
done < <(python3 - "${lockfile}" <<'PYTHON'
import json, sys
for pkg in json.load(open(sys.argv[1], encoding="utf-8"))["packages"]:
    for module in pkg["modules"]:
        print(module["path"], module["sha256"])
PYTHON
)

missing="${missing%,}"
ci_log "modules matching the lockfile after apk install: ${installed}"
[ -z "${missing}" ] || ci_log "modules apk did not provide: ${missing}"

if [ "${differ}" -eq 0 ]; then
    verdict="ok"
    ci_log "upstream apk agrees with the lockfile"
else
    verdict="differ"
    ci_warn "upstream apk disagrees with the lockfile; review kmod-closure.json"
    exit 1
fi
