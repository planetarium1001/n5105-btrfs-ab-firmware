#!/usr/bin/env bash
# Stage "runtime": fetch btrfs-progs and its library closure for the platform layer.
#
# The upstream root filesystem has no btrfs user space tooling, but the platform needs
# it: snapshot, delete, create and list are what the slot state machine, reclamation
# and the degraded boot rely on. The binary does not belong in @sys (that tree must
# stay byte identical to upstream), so it ships in the platform layer instead:
#
#   @platform/usr/sbin/btrfs
#   @platform/usr/lib/liblzo2.so.2
#
# Resolution works from the binary outwards, not from package metadata: the package
# payloads carry the executables and shared objects as ELF images, so this stage
# extracts them, reads DT_NEEDED off the multicall binary, and only fetches the
# packages that supply a library the root filesystem does not already provide. That
# keeps the addition to what the linker actually asks for.
#
# Drift policy matches the module closure: scripts/ci/runtime-closure.json is the
# contract for the upstream release it pins. If the feed publishes a different version,
# digest or package set for that release, the stage fails instead of silently following.
# Refresh it deliberately with `--write-lock` and review the diff.
#
# A build for another upstream release cannot be asserted against that contract: the
# btrfs-progs package and the library closure are different by construction. Such a build
# derives its own lockfile under $CI_TMP_ROOT from what the feed publishes for that
# release, asserts against that copy and warns about it, so the pinned lockfile stays
# untouched and a green stage never claims the pin was verified. CI_LOCK_STRICT=1 keeps
# the pin contract for every release.
#
# Inputs (environment):
#   CI_UPSTREAM_BASE_URL  release directory URL
#   CI_UPSTREAM_VERSION   upstream release label
#   CI_PLATFORM_RUNTIME_OUT  staging directory (default: $CI_TMP_ROOT/runtime)
#   CI_ROOTFS_TAR         rootfs tarball used to decide what is already provided
#   CI_RUNTIME_LOCKFILE   lockfile path (default: scripts/ci/runtime-closure.json)
#   CI_RUNTIME_LIMIT_MIB  unpacked platform layer budget (default: 8)
#   CI_LOCK_STRICT        1 asserts the lockfile even when CI_UPSTREAM_VERSION differs
#
# Outputs: runtime_bytes, runtime_packages, runtime_sonames, runtime_btrfs,
#          runtime_limit_mib, lockfile (the pinned lockfile, or the derived per-version one)

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

ci_stage_init runtime

ci_require_cmd python3 curl awk grep sort

write_lock="false"
for arg in "$@"; do
    case "${arg}" in
        --write-lock) write_lock="true" ;;
        *) ci_die "unknown argument: ${arg}" ;;
    esac
done

base_url="${CI_UPSTREAM_BASE_URL:?CI_UPSTREAM_BASE_URL is required}"
upstream_version="${CI_UPSTREAM_VERSION:?CI_UPSTREAM_VERSION is required}"
out="${CI_PLATFORM_RUNTIME_OUT:-${CI_TMP_ROOT}/runtime}"
lockfile="${CI_RUNTIME_LOCKFILE:-${CI_REPO_ROOT}/scripts/ci/runtime-closure.json}"
limit_mib="${CI_RUNTIME_LIMIT_MIB:-8}"
rootfs_tar="${CI_ROOTFS_TAR:-${CI_TMP_ROOT}/fetch/upstream/rootfs.tar.gz}"
[ -f "${rootfs_tar}" ] || ci_die "rootfs tarball not found: ${rootfs_tar}"

# --------------------------------------------------------------------------- #
# 0. Which lockfile this build is bound by
#
# The pin is a contract between one upstream release and the committed lockfile: the
# btrfs-progs build and the library set in it belong to that release's feed. A build for
# another release would fail that contract by construction, so it derives its own lockfile
# from what the feed publishes for its release and asserts against that copy.
# CI_LOCK_STRICT=1 keeps the pin contract for every release, which is what a bisect of the
# pin itself needs.
# --------------------------------------------------------------------------- #

lock_is_derived="false"
lock_upstream=""
if [ -f "${lockfile}" ]; then
    lock_upstream="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("upstream_version", ""))' "${lockfile}")" \
        || ci_die "cannot read upstream_version from ${lockfile}"
fi

if [ "${write_lock}" != "true" ] && [ -n "${CI_UPSTREAM_VERSION:-}" ] \
    && [ -n "${lock_upstream}" ] && [ "${lock_upstream}" != "${upstream_version}" ]; then
    if [ "${CI_LOCK_STRICT:-0}" = "1" ]; then
        ci_log "CI_LOCK_STRICT=1: asserting the pinned lockfile (${lock_upstream}) for the ${upstream_version} build"
    else
        # Regenerated on every run: a copy left behind by an earlier build of the same
        # release must not become the contract of this one.
        lockfile="${CI_TMP_ROOT}/locks/runtime-closure-${upstream_version}.json"
        mkdir -p "$(dirname "${lockfile}")"
        lock_is_derived="true"
        write_lock="true"
    fi
fi

# lock_die <message>: a rejection has to say whether the pin or a derived copy made it.
# Without that, a red assemble step for a matrix release reads as "the committed lockfile
# was violated", which is the one thing that must not be inferred here.
lock_die() {
    if [ "${lock_is_derived}" = "true" ]; then
        ci_die "derived lockfile ${lockfile}: $*"
    fi
    ci_die "$*"
}

# warn_derived_lock: the step log and the run page both have to carry the fact that this
# build is not under the pin contract, because a green assemble step otherwise reads as
# "the committed lockfile was verified".
warn_derived_lock() {
    ci_warn "derived per-version lockfile: ${lockfile}"
    ci_warn "  the ${upstream_version} build does not assert the committed lockfile (pinned ${lock_upstream}): package drift is NOT enforced for this release"
    ci_warn "  CI_LOCK_STRICT=1 turns the same drift back into a hard failure"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::warning title=runtime derived lockfile::%s build uses %s; the committed lockfile pins %s, so package drift is not asserted for this release\n' \
            "${upstream_version}" "${lockfile}" "${lock_upstream}"
    fi
}

if [ "${lock_is_derived}" = "true" ]; then
    ci_log "deriving a per-version lockfile for upstream ${upstream_version}: ${lockfile}"
    warn_derived_lock
fi

# The package feed lives next to the target release: packages/<arch>/packages/.
feed="${base_url%/targets/*}/packages/x86_64/packages"

# Candidate packages: the tool itself plus the libraries its binary links against.
# A missing library is a hard error that names the soname, so extending this list is
# a deliberate one-line change.
candidates=(
    "btrfs-progs"
    "liblzo2"
    "libzstd"
    "libattr"
    "libmount1"
    "libblkid1"
    "libuuid1"
    "zlib"
    "libgcc1"
)

work="${CI_TMP_ROOT}/runtime-work"
rm -rf "${work}" "${out}"
mkdir -p "${work}/apk" "${out}"

# feed_index: package file name -> URL, taken from the feed listing once.
listing="${work}/listing.html"
ci_download "${feed}/" "${listing}"
grep -oE 'href="[^"]+\.apk"' "${listing}" | sed 's/href="//; s/"//' | sort -u >"${work}/packages.txt"
[ -s "${work}/packages.txt" ] || ci_die "the package feed listing is empty: ${feed}"
ci_log "package feed: ${feed}, $(wc -l <"${work}/packages.txt" | tr -d ' ') packages"

# resolve_package <name>: newest file for that package name in the feed.
resolve_package() {
    awk -v want="$1" '
        {
            name = $0
            sub(/-[0-9][^-]*-r[0-9]+\.apk$/, "", name)
            if (name == want) { print }
        }
    ' "${work}/packages.txt" | sort -V | tail -n 1
}

# provided_by_rootfs <soname>: the root filesystem already carries this library.
provided_by_rootfs() {
    [ -f "${rootfs_tar}" ] || return 1
    # grep -q closes the pipe on the first match, and pipefail then reports the whole
    # pipeline as failed; grepping without -q reads the listing to the end.
    tar -tzf "${rootfs_tar}" 2>/dev/null | grep -E "(^|/)${1}\$" >/dev/null 2>&1
}

# extract_package <apk-name>: download, unpack every ELF image, print the manifest path.
extract_package() {
    name="$1"
    apk="${work}/apk/${name}"
    if [ ! -f "${apk}" ]; then
        ci_download "${feed}/${name}" "${apk}"
    fi
    python3 "${CI_SCRIPT_DIR}/elf_extract.py" \
        --out "${work}/tree/${name%.apk}" \
        --manifest "${work}/tree/${name%.apk}.json" \
        --apk-name "${name}" "${apk}" 2>&1 | sed 's/^/[runtime]   /'
}

# The tool is the multicall binary: it carries the dispatcher usage string.
find_btrfs_image() {
    python3 - "${work}" <<'PYTHON'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
for manifest in sorted(work.glob("tree/*.json")):
    doc = json.loads(manifest.read_text())
    base = work / "tree" / manifest.stem
    for entry in doc["images"]:
        if entry["kind"] != "executable":
            continue
        blob = (base / entry["installed"]).read_bytes()
        if b"btrfs [global]" in blob and b"btrfs-progs v" in blob:
            print(f'{manifest.stem} {entry["installed"]} {entry["sha256"]} {entry["size"]}')
            sys.exit(0)
sys.exit(1)
PYTHON
}

# --------------------------------------------------------------------------- #
# Resolution
# --------------------------------------------------------------------------- #

runtime_packages=()
installed_sonames=()

# 1. the tool itself
btrfs_pkg="$(resolve_package btrfs-progs)"
[ -n "${btrfs_pkg}" ] || ci_die "the feed publishes no btrfs-progs package"
ci_log "btrfs-progs package: ${btrfs_pkg}"
extract_package "${btrfs_pkg}"
runtime_packages+=("${btrfs_pkg}")

image_line="$(find_btrfs_image)" || ci_die "no executable in ${btrfs_pkg} carries the btrfs multicall dispatcher"
read -r _pkg btrfs_rel btrfs_sha btrfs_size <<<"${image_line}"
ci_log "btrfs binary: ${btrfs_rel} (${btrfs_size} bytes, sha256 ${btrfs_sha})"

# 2. the libraries it needs that the root filesystem does not have
needed="$(python3 - "${work}" "${btrfs_rel}" <<'PYTHON'
import json, pathlib, sys
work, rel = pathlib.Path(sys.argv[1]), sys.argv[2]
for manifest in sorted(work.glob("tree/*.json")):
    base = work / "tree" / manifest.stem
    doc = json.loads(manifest.read_text())
    for entry in doc["images"]:
        if entry["installed"] == rel:
            print("\n".join(entry["needed"]))
PYTHON
)"
[ -n "${needed}" ] || ci_die "the btrfs binary declares no DT_NEEDED"
ci_log "btrfs needs: $(printf '%s' "${needed}" | tr '\n' ' ')"

missing=()
while IFS= read -r soname; do
    [ -n "${soname}" ] || continue
    if provided_by_rootfs "${soname}"; then
        ci_log "${soname}: provided by the root filesystem"
        continue
    fi
    missing+=("${soname}")
done <<<"${needed}"

# 3. find the package behind each missing soname, following their own DT_NEEDED once
pending=("${missing[@]}")
seen=" "
while [ "${#pending[@]}" -gt 0 ]; do
    soname="${pending[0]}"
    pending=("${pending[@]:1}")
    case "${seen}" in
        *" ${soname} "*) continue ;;
    esac
    seen="${seen}${soname} "
    resolved=""
    for candidate in "${candidates[@]}"; do
        file="$(resolve_package "${candidate}")"
        [ -n "${file}" ] || continue
        extract_package "${file}" >/dev/null
        if python3 - "${work}" "${soname}" <<'PYTHON'
import json, pathlib, sys
work, soname = pathlib.Path(sys.argv[1]), sys.argv[2]
for manifest in sorted(work.glob("tree/*.json")):
    for entry in json.loads(manifest.read_text())["images"]:
        if entry["soname"] == soname:
            sys.exit(0)
sys.exit(1)
PYTHON
        then
            resolved="${file}"
            break
        fi
    done
    [ -n "${resolved}" ] || ci_die "no package in the feed provides ${soname}"
    ci_log "${soname}: provided by ${resolved}"
    runtime_packages+=("${resolved}")
    installed_sonames+=("${soname}")
    # libraries pull their own dependencies in
    more="$(python3 - "${work}" "${resolved%.apk}" "${soname}" <<'PYTHON'
import json, pathlib, sys
work, stem, soname = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
doc = json.loads((work / "tree" / f"{stem}.json").read_text())
for entry in doc["images"]:
    if entry["soname"] == soname:
        print("\n".join(entry["needed"]))
PYTHON
)"
    while IFS= read -r sub; do
        [ -n "${sub}" ] || continue
        provided_by_rootfs "${sub}" && continue
        pending+=("${sub}")
    done <<<"${more}"
done

# --------------------------------------------------------------------------- #
# Assembly
# --------------------------------------------------------------------------- #

mktree="${work}/platform-runtime"
rm -rf "${mktree}"
mkdir -p "${mktree}/usr/sbin" "${mktree}/usr/lib"

install -m 0755 "$(find "${work}/tree" -path "*/${btrfs_rel}" | head -n 1)" "${mktree}/usr/sbin/btrfs"
for soname in ${installed_sonames[@]+"${installed_sonames[@]}"}; do
    source_file="$(find "${work}/tree" -path "*/${soname}" | head -n 1)"
    [ -n "${source_file}" ] || ci_die "cannot find ${soname} in the extracted trees"
    install -m 0644 "${source_file}" "${mktree}/usr/lib/${soname}"
done

# Only the multicall binary ships. The historic names (mkfs.btrfs, btrfs-image,
# btrfstune) are separate programs in this version, and a symlink to the multicall
# binary would answer "unknown command": ship what the self-test can prove, nothing
# else. `btrfsck` is dispatched by the multicall binary itself, so it is safe.
ln -sf btrfs "${mktree}/usr/sbin/btrfsck"

cp -a "${mktree}/." "${out}/"
runtime_bytes="$(python3 - "${out}" <<'PYTHON'
import os, sys
total = 0
for root, _dirs, files in os.walk(sys.argv[1]):
    for name in files:
        total += os.lstat(os.path.join(root, name)).st_size
print(total)
PYTHON
)"
limit_bytes=$((limit_mib * 1024 * 1024))
ci_log "runtime tree: ${runtime_bytes} bytes, budget ${limit_bytes} bytes (${limit_mib} MiB)"
[ "${runtime_bytes}" -le "${limit_bytes}" ] ||
    ci_die "the platform runtime tree is ${runtime_bytes} bytes, over the ${limit_mib} MiB budget"

# --------------------------------------------------------------------------- #
# Self-test: the binary must start against the libraries we are about to ship
# --------------------------------------------------------------------------- #

loader_check="skipped"
if [ -f "${rootfs_tar}" ] && command -v uname >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
    testroot="${work}/testroot"
    mkdir -p "${testroot}"
    tar -xzf "${rootfs_tar}" -C "${testroot}" --ignore-failed-read \
        ./lib/ld-musl-x86_64.so.1 ./lib/libgcc_s.so.1 ./usr/lib/libblkid.so.1 \
        ./usr/lib/libuuid.so.1 ./usr/lib/libz.so.1 2>/dev/null || true
    if [ -f "${testroot}/lib/ld-musl-x86_64.so.1" ]; then
        if version_output="$("${testroot}/lib/ld-musl-x86_64.so.1" \
            --library-path "${out}/usr/lib:${testroot}/usr/lib:${testroot}/lib" \
            "${out}/usr/sbin/btrfs" --version 2>&1)"; then
            case "${version_output}" in
                btrfs-progs*)
                    loader_check="ok"
                    ci_log "runtime self-test: ${version_output}"
                    ;;
                *)
                    ci_die "runtime self-test printed something unexpected: ${version_output}"
                    ;;
            esac
        else
            ci_die "runtime self-test failed, the binary does not start: ${version_output}"
        fi
    else
        ci_log "runtime self-test skipped, the root filesystem carries no musl loader"
    fi
else
    ci_log "runtime self-test skipped outside Linux"
fi

# --------------------------------------------------------------------------- #
# Lockfile
# --------------------------------------------------------------------------- #

lock_json="${work}/runtime-closure.json"
python3 - "${work}" "${lock_json}" "${upstream_version}" "${btrfs_rel}" "${installed_sonames[@]+"${installed_sonames[@]}"}" <<'PYTHON'
import hashlib, json, pathlib, sys
work = pathlib.Path(sys.argv[1])
target, version, btrfs_rel = pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
sonames = sys.argv[5:]
packages = {}
for apk in sorted((work / "apk").glob("*.apk")):
    manifest = work / "tree" / f"{apk.stem}.json"
    if not manifest.exists():
        continue
    doc = json.loads(manifest.read_text())
    files = {}
    for entry in doc["images"]:
        if entry["kind"] == "shared" and entry["soname"] in sonames:
            files[f"usr/lib/{entry['soname']}"] = entry["sha256"]
    if btrfs_rel and doc["images"] and any(e["installed"] == btrfs_rel for e in doc["images"]):
        for entry in doc["images"]:
            if entry["installed"] == btrfs_rel:
                files["usr/sbin/btrfs"] = entry["sha256"]
    if files:
        packages[apk.name] = {
            "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
            "files": files,
        }
doc = {
    "generated_by": "scripts/ci/platform-runtime.sh --write-lock",
    "upstream_version": version,
    "feed": "packages/x86_64/packages",
    "notes": [
        "btrfs-progs is needed because the upstream rootfs ships no btrfs tooling",
        "only libraries the rootfs does not already provide are shipped",
        "digests are recorded on first download; the feed publishes no sha256sums",
    ],
    "btrfs_image": btrfs_rel,
    "packages": packages,
}
target.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(json.dumps(packages, indent=2, sort_keys=True))
PYTHON

if [ "${write_lock}" = "true" ]; then
    cp "${lock_json}" "${lockfile}"
    ci_log "lockfile rewritten: ${lockfile}"
fi

# A derived lockfile is asserted exactly like the pin, and through the same code: the copy
# was written from this feed a moment ago, so the assertion proves the copy carries what
# this run resolved rather than that the committed lockfile still holds.
if [ "${write_lock}" != "true" ] || [ "${lock_is_derived}" = "true" ]; then
    [ -f "${lockfile}" ] || lock_die "lockfile missing: ${lockfile}"
    # The drift header names the derived copy when one is in force, so the reader of a red
    # matrix build does not go looking for a change in the committed lockfile.
    drift_label="[runtime] lockfile drift:"
    if [ "${lock_is_derived}" = "true" ]; then
        drift_label="[runtime] derived lockfile ${lockfile} drift:"
    fi
    python3 - "${lockfile}" "${lock_json}" "${drift_label}" <<'PYTHON'
import json, sys
want = json.load(open(sys.argv[1], encoding="utf-8"))
have = json.load(open(sys.argv[2], encoding="utf-8"))
drift = sys.argv[3]
for key in ("upstream_version", "btrfs_image"):
    if want.get(key) != have.get(key):
        print(f"{drift} {key} is {want.get(key)!r}, feed has {have.get(key)!r}", file=sys.stderr)
        sys.exit(1)
for name, meta in sorted(have["packages"].items()):
    if name not in want["packages"]:
        print(f"{drift} {name} is not in the lockfile", file=sys.stderr)
        sys.exit(1)
    if want["packages"][name]["sha256"] != meta["sha256"]:
        print(f"{drift} {name} digest changed", file=sys.stderr)
        sys.exit(1)
for name in sorted(want["packages"]):
    if name not in have["packages"]:
        print(f"{drift} {name} is not published any more", file=sys.stderr)
        sys.exit(1)
print("[runtime] lockfile matches the feed")
PYTHON
fi

ci_emit_output "runtime_bytes" "${runtime_bytes}"
ci_emit_output "runtime_packages" "$(printf '%s\n' "${runtime_packages[@]}" | sort -u | tr '\n' ' ')"
ci_emit_output "runtime_sonames" "${installed_sonames[*]:-none}"
ci_emit_output "runtime_btrfs" "${out}/usr/sbin/btrfs"
ci_emit_output "runtime_limit_mib" "${limit_mib}"
ci_emit_output "runtime_self_test" "${loader_check}"
ci_emit_output "lockfile" "${lockfile}"

ci_log "stage runtime finished"
