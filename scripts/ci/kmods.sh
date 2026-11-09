#!/usr/bin/env bash
# Stage "kmods": fetch, verify and unpack the btrfs kernel-module closure.
#
# The upstream kernel image is built without CONFIG_KERNEL_BTRFS_FS, so btrfs can
# only arrive as a module. This stage resolves the module closure against the
# published kmods repository, verifies every package against the release's
# sha256sums, unpacks the modules out of the apk-tools v3 containers, and asserts
# that the result still matches the committed lockfile.
#
# Drift policy: the lockfile (scripts/ci/kmod-closure.json) is the contract. If the
# mirror publishes a different version, digest or module set for the same upstream
# release, the stage fails instead of silently following. Refresh it deliberately
# with `--write-lock` and review the diff.
#
# Inputs (environment):
#   CI_KMODS_DIR         kernel module directory name, for example 6.12.103-1-<hash>
#   CI_UPSTREAM_BASE_URL release directory URL
#   CI_UPSTREAM_VERSION  upstream release label, recorded in the lockfile
#   CI_KMODS_OUT         output directory (default: $CI_TMP_ROOT/kmods)
#   CI_LOCKFILE          lockfile path (default: scripts/ci/kmod-closure.json)
#
# Modes:
#   (default)      verify the unpacked modules and the mirror metadata against the lockfile
#   --write-lock   rewrite the lockfile from what the mirror currently publishes
#
# Outputs: module_count, module_paths, btrfs_module, btrfs_vermagic, package_count,
#          virtual_packages, lockfile

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init kmods

ci_require_cmd python3 curl awk grep sort

write_lock="false"
for arg in "$@"; do
    case "${arg}" in
        --write-lock) write_lock="true" ;;
        *) ci_die "unknown argument: ${arg}" ;;
    esac
done

kmods_dir="${CI_KMODS_DIR:?CI_KMODS_DIR is required}"
base_url="${CI_UPSTREAM_BASE_URL:?CI_UPSTREAM_BASE_URL is required}"
upstream_version="${CI_UPSTREAM_VERSION:-unknown}"
out_dir="${CI_KMODS_OUT:-${CI_TMP_ROOT}/kmods}"
lockfile="${CI_LOCKFILE:-${CI_REPO_ROOT}/scripts/ci/kmod-closure.json}"
kmods_url="${base_url}/kmods/${kmods_dir}"

kernel_version="$(printf '%s\n' "${kmods_dir}" | sed -E 's/-[0-9]+-[0-9a-f]{32}$//')"
[ -n "${kernel_version}" ] || ci_die "cannot derive the kernel version from ${kmods_dir}"

apk_dir="${out_dir}/apk"
modules_dir="${out_dir}/modules"
mkdir -p "${apk_dir}" "${modules_dir}"
if [ "${write_lock}" != "true" ]; then
    [ -f "${lockfile}" ] || ci_die "lockfile not found: ${lockfile} (run with --write-lock to create it)"
fi

# The closure list is the only hand-maintained input. It comes from the DEPENDS graph
# of package/kernel/linux/modules/*.mk at the pinned upstream tag; the lockfile is
# derived from it, so a first run only needs this list.
closure_default="kmod-crypto-acompress kmod-crypto-blake2b kmod-crypto-crc32c
kmod-crypto-hash kmod-crypto-xxhash kmod-fs-btrfs kmod-lib-crc32c kmod-lib-lzo
kmod-lib-raid6 kmod-lib-xor kmod-lib-xxhash kmod-lib-zlib-deflate
kmod-lib-zlib-inflate kmod-lib-zstd"
closure_list="${CI_KMODS_CLOSURE:-${closure_default}}"

# --------------------------------------------------------------------------- #
# 1. Mirror metadata: the package index and the release digest list
# --------------------------------------------------------------------------- #

index_json="${out_dir}/index.json"
sums_file="${out_dir}/sha256sums"
if [ ! -s "${index_json}" ]; then
    ci_download "${kmods_url}/index.json" "${index_json}"
fi
if [ ! -s "${sums_file}" ]; then
    ci_download "${base_url}/sha256sums" "${sums_file}"
fi

# locked_lines: "<name> <version> <sha256>" per lockfile entry.
locked_lines() {
    python3 - "${lockfile}" <<'PYTHON'
import json, sys
for pkg in json.load(open(sys.argv[1], encoding="utf-8"))["packages"]:
    print(pkg["name"], pkg["version"], pkg["sha256"])
PYTHON
}

# resolved_lines: "<name> <version> <sha256>" per closure member, taken from what the
# mirror publishes right now. Only --write-lock uses this.
resolved_lines() {
    python3 - "${index_json}" "${sums_file}" "${kmods_dir}" "$@" <<'PYTHON'
import json, sys
index = json.load(open(sys.argv[1], encoding="utf-8"))["packages"]
sums_path, kmods_dir, names = sys.argv[2], sys.argv[3], sys.argv[4:]
digests = {}
for line in open(sums_path, encoding="utf-8"):
    digest, _, path = line.strip().partition(" *")
    digests[path] = digest
missing = []
for name in names:
    version = index.get(name)
    if not version:
        missing.append(name)
        continue
    digest = digests.get(f"kmods/{kmods_dir}/{name}-{version}.apk", "")
    if not digest:
        missing.append(name)
        continue
    print(name, version, digest)
if missing:
    print("not published: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PYTHON
}

if [ "${write_lock}" = "true" ]; then
    if [ -f "${lockfile}" ]; then
        locked_names="$(python3 - "${lockfile}" <<'PYTHON'
import json, sys
print(" ".join(pkg["name"] for pkg in json.load(open(sys.argv[1], encoding="utf-8"))["packages"]))
PYTHON
)"
        # shellcheck disable=SC2086  # the name list is intentionally word-split
        package_lines="$(resolved_lines ${locked_names})" || ci_die "could not resolve the closure from the mirror"
    else
        # shellcheck disable=SC2086  # the closure list is intentionally word-split
        package_lines="$(resolved_lines ${closure_list})" || ci_die "could not resolve the closure from the mirror"
    fi
    ci_warn "write-lock mode: pinning what the mirror publishes now"
else
    package_lines="$(locked_lines)"
fi
[ -n "${package_lines}" ] || ci_die "no packages to process"
package_count="$(printf '%s\n' "${package_lines}" | wc -l | tr -d ' ')"
printf '%s\n' "${package_lines}" >"${out_dir}/packages.txt"
ci_log "${package_count} package(s) to process, kernel ${kernel_version}"

# --------------------------------------------------------------------------- #
# 2. Download and verify every package
# --------------------------------------------------------------------------- #

apk_files=()
while read -r name version sha256; do
    [ -n "${name}" ] || continue
    file="${apk_dir}/${name}-${version}.apk"

    published="$(python3 - "${index_json}" "${name}" <<'PYTHON'
import json, sys
index = json.load(open(sys.argv[1], encoding="utf-8"))["packages"]
print(index.get(sys.argv[2], ""))
PYTHON
)"
    [ -n "${published}" ] || ci_die "${name} is no longer published in the kmods index"
    if [ "${published}" != "${version}" ]; then
        ci_die "${name}: mirror publishes ${published}, lockfile pins ${version}"
    fi

    expected="$(ci_lookup_sha256 "${sums_file}" "kmods/${kmods_dir}/${name}-${version}.apk")"
    if [ "${expected}" != "${sha256}" ]; then
        ci_die "${name}: release digest ${expected} differs from lockfile ${sha256}"
    fi

    if [ -s "${file}" ] && [ "$(ci_sha256 "${file}")" = "${sha256}" ]; then
        ci_log "reuse ${name}-${version}.apk"
    else
        ci_download "${kmods_url}/${name}-${version}.apk" "${file}"
        actual="$(ci_sha256 "${file}")"
        [ "${actual}" = "${sha256}" ] || ci_die "${name}: downloaded digest ${actual} != ${sha256}"
    fi
    apk_files+=("${file}")
done <<<"${package_lines}"

# --------------------------------------------------------------------------- #
# 3. Unpack the modules
# --------------------------------------------------------------------------- #

inventory="${out_dir}/inventory.json"
python3 "${CI_SCRIPT_DIR}/apk_extract.py" \
    --out "${modules_dir}" \
    --kver "${kernel_version}" \
    --json-out "${inventory}" \
    "${apk_files[@]}"

# --------------------------------------------------------------------------- #
# 4. Assert the result against the lockfile (or refresh it)
# --------------------------------------------------------------------------- #

if [ "${write_lock}" = "true" ]; then
    python3 - "${lockfile}" "${inventory}" "${upstream_version}" "${kmods_dir}" "${kernel_version}" "${out_dir}/packages.txt" <<'PYTHON'
import json, sys
lockpath, inventory, upstream, kmods_dir, kernel, packages_file = sys.argv[1:7]
packages = json.load(open(inventory, encoding="utf-8"))
apk_digests = {}
for line in open(packages_file, encoding="utf-8"):
    name, _version, digest = line.split()
    apk_digests[name] = digest
doc = {
    "generated_by": "scripts/ci/kmods.sh --write-lock",
    "upstream_version": upstream,
    "kernel_version": kernel,
    "kmods_dir": kmods_dir,
    "root": "kmod-fs-btrfs",
    "notes": [
        "Members with kind=virtual ship no module: the driver is built into the upstream kernel",
        "and the package only provides <name>-any plus /etc/modules.d snippets.",
        "Module digests are the sha256 of the unpacked .ko, not of the apk.",
    ],
    "packages": [
        {
            "name": pkg["package"],
            "version": pkg["version"],
            "kind": pkg["kind"],
            "sha256": apk_digests.get(pkg["package"], ""),
            "provides": pkg.get("provides", []),
            "modules": [
                {k: m[k] for k in ("path", "size", "sha256", "vermagic")}
                for m in pkg["modules"]
            ],
        }
        for pkg in packages
    ],
}
open(lockpath, "w", encoding="utf-8").write(json.dumps(doc, indent=2, sort_keys=False) + "\n")
print(f"[kmods] wrote {lockpath} with {len(doc['packages'])} packages")
PYTHON
    ci_warn "lockfile rewritten; review the diff before committing"
fi

python3 - "${lockfile}" "${inventory}" <<'PYTHON'
import json, sys

lockpath, inventory = sys.argv[1], sys.argv[2]
lock = json.load(open(lockpath, encoding="utf-8"))
found = {pkg["package"]: pkg for pkg in json.load(open(inventory, encoding="utf-8"))}
problems = []

locked = {pkg["name"]: pkg for pkg in lock["packages"]}
for name, pinned in locked.items():
    actual = found.get(name)
    if actual is None:
        problems.append(f"{name}: in the lockfile but not unpacked")
        continue
    if actual["version"] != pinned["version"]:
        problems.append(f"{name}: version {actual['version']} != locked {pinned['version']}")
    if actual["kind"] != pinned["kind"]:
        problems.append(f"{name}: kind {actual['kind']} != locked {pinned['kind']}")
    modules = {m["path"]: m for m in actual["modules"]}
    pinned_modules = {m["path"]: m for m in pinned["modules"]}
    if set(modules) != set(pinned_modules):
        problems.append(
            f"{name}: module set changed, new={sorted(set(modules) - set(pinned_modules))} "
            f"gone={sorted(set(pinned_modules) - set(modules))}"
        )
        continue
    for path, module in modules.items():
        if module["sha256"] != pinned_modules[path]["sha256"]:
            problems.append(f"{name}: {path} digest changed")
        if module["vermagic"] != pinned_modules[path]["vermagic"]:
            problems.append(f"{name}: {path} vermagic changed")

for name in found:
    if name not in locked:
        problems.append(f"{name}: unpacked but not in the lockfile")

if problems:
    print("[kmods] lockfile drift:", file=sys.stderr)
    for item in problems:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
print(f"[kmods] lockfile matches: {len(locked)} package(s)")
PYTHON

# --------------------------------------------------------------------------- #
# 5. Assert the module set that the initramfs needs
# --------------------------------------------------------------------------- #

btrfs_module="${modules_dir}/lib/modules/${kernel_version}/btrfs.ko"
[ -f "${btrfs_module}" ] || ci_die "btrfs.ko was not unpacked from the closure"

module_paths=()
while IFS= read -r path; do
    module_paths+=("${path}")
done < <(find "${modules_dir}" -name '*.ko' | LC_ALL=C sort)
[ "${#module_paths[@]}" -gt 0 ] || ci_die "no modules were unpacked"

btrfs_vermagic="$(python3 - "${inventory}" <<'PYTHON'
import json, sys
for pkg in json.load(open(sys.argv[1], encoding="utf-8")):
    for module in pkg["modules"]:
        if module["path"].endswith("/btrfs.ko"):
            print(module["vermagic"])
            break
PYTHON
)"
[ -n "${btrfs_vermagic}" ] || ci_die "btrfs.ko carries no vermagic"
case "${btrfs_vermagic}" in
    *"${kernel_version}"*) : ;;
    *) ci_die "btrfs.ko vermagic '${btrfs_vermagic}' does not mention kernel ${kernel_version}" ;;
esac

virtual_packages="$(python3 - "${inventory}" <<'PYTHON'
import json, sys
print(",".join(pkg["package"] for pkg in json.load(open(sys.argv[1], encoding="utf-8")) if pkg["kind"] == "virtual"))
PYTHON
)"

ci_log "unpacked ${#module_paths[@]} module(s) from ${package_count} package(s)"
ci_log "btrfs.ko vermagic: ${btrfs_vermagic}"
[ -z "${virtual_packages}" ] || ci_log "virtual packages (driver built in): ${virtual_packages}"

module_list="$(printf '%s\n' "${module_paths[@]}" | sed "s|${modules_dir}/||" | tr '\n' ',' | sed 's/,$//')"

ci_emit_output "kernel_version" "${kernel_version}"
ci_emit_output "module_count" "${#module_paths[@]}"
ci_emit_output "module_paths" "${module_list}"
ci_emit_output "btrfs_module" "lib/modules/${kernel_version}/btrfs.ko"
ci_emit_output "btrfs_vermagic" "${btrfs_vermagic}"
ci_emit_output "package_count" "${package_count}"
ci_emit_output "virtual_packages" "${virtual_packages}"
ci_emit_output "lockfile" "${lockfile}"
ci_emit_output "modules_dir" "${modules_dir}"

ci_log "stage kmods finished"
