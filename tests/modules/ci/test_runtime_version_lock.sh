#!/usr/bin/env bash
# Module: ci
#
# A matrix build asks for another upstream release than the pin, and the committed runtime
# lockfile pins one release: the btrfs-progs build and the library closure in it belong to
# that release's feed. scripts/ci/platform-runtime.sh therefore derives a per-version
# lockfile for such a build under $CI_TMP_ROOT and keeps the pin a hard contract. Locked
# here:
#
#   ac-1 a build whose release matches the lockfile keeps the drift check exactly as it is:
#        a feed that publishes other bytes fails the stage, with the message unchanged
#   ac-1 a build for another release derives <CI_TMP_ROOT>/locks/runtime-closure-<v>.json
#        from what the feed publishes, asserts against that copy instead of the committed
#        one, announces the derived path and warns that the drift assertion is not enforced
#        for it, and the committed lockfile stays untouched
#   ac-1 CI_LOCK_STRICT=1 restores the pin contract for such a build: the same hard
#        failure and no derived lockfile
#
# Everything runs offline and without root: the feed is a local directory reached through
# a curl stand-in on PATH, and the packages are apk-tools v3 containers built in this test
# around minimal x86-64 ELF images carrying DT_NEEDED and DT_SONAME, so the real
# scripts/ci/elf_extract.py resolves the closure and the real --write-lock path writes the
# derived lockfile. The root filesystem tarball carries no musl loader, which keeps the
# self-test of the stage skipped.
#
# Usage:
#   bash tests/modules/ci/test_runtime_version_lock.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

if ! command -v python3 >/dev/null 2>&1; then
  printf '# python3 unavailable, skipped\n'
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The release the fake lockfile pins and the one the fake feed is asked for. They differ,
# which is the situation a matrix build is in: same stage script, another package set.
pin_release="25.12.99"
build_release="25.12.94"
pkg_version="6.99-r1"
lzo_version="2.10-r1"
# The runtime image keeps the name elf_extract derives from the package file name.
btrfs_image="usr/lib/btrfs-progs-${pkg_version}.exec0"

hash_file() {
  bash -c '. "$1/scripts/ci/lib.sh" >/dev/null 2>&1; ci_sha256 "$2"' _ "$root" "$1"
}

# --------------------------------------------------------------------------- #
# The feed: what one release publishes, in the shape the stage reads
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/payloads"
python3 - "$tmp/payloads" "$pkg_version" "$lzo_version" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
pkg_version, lzo_version = sys.argv[2], sys.argv[3]

EHDR = 64
PHDR = 56
PT_LOAD, PT_DYNAMIC = 1, 2
DT_NEEDED, DT_STRTAB, DT_SONAME, DT_NULL = 1, 5, 14, 0


def image(e_type, soname=None, needed=(), trailer=b""):
    """A minimal ELF64 with one PT_LOAD over the whole file and one PT_DYNAMIC.

    elf_extract classifies by DT_SONAME and resolves the closure by DT_NEEDED, so those
    are the only tables that have to be real. The PT_LOAD starts at vaddr 0 and spans the
    file, which makes a virtual address an offset into the container, exactly as in the
    upstream packages.
    """
    entries = []
    strtab = bytearray(b"\0")

    def string(text):
        offset = len(strtab)
        strtab.extend(text.encode() + b"\0")
        return offset

    if soname is not None:
        entries.append((DT_SONAME, string(soname)))
    for name in needed:
        entries.append((DT_NEEDED, string(name)))
    entries.append((DT_STRTAB, None))  # filled once the layout is known
    entries.append((DT_NULL, 0))

    dynoff = EHDR + PHDR * 2
    dynsize = 16 * len(entries)
    stroff = dynoff + dynsize
    total = stroff + len(strtab) + len(trailer)
    entries[-2] = (DT_STRTAB, stroff)

    header = bytearray(EHDR)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # ELFDATA2LSB
    header[6] = 1  # EV_CURRENT
    struct.pack_into("<HHI", header, 16, e_type, 62, 1)  # ET_*, EM_X86_64, EV_CURRENT
    struct.pack_into("<Q", header, 0x20, EHDR)  # e_phoff
    struct.pack_into("<H", header, 0x34, EHDR)  # e_ehsize
    struct.pack_into("<H", header, 0x36, PHDR)  # e_phentsize
    struct.pack_into("<H", header, 0x38, 2)  # e_phnum

    def phdr(p_type, flags, offset, size, align):
        return struct.pack("<IIQQQQQQ", p_type, flags, offset, offset, offset, size, size, align)

    body = b"".join(struct.pack("<qQ", tag, value) for tag, value in entries)
    return b"".join(
        (
            bytes(header),
            phdr(PT_LOAD, 5, 0, total, 0x1000),
            phdr(PT_DYNAMIC, 6, dynoff, dynsize, 8),
            body,
            bytes(strtab),
            trailer,
        )
    )


def container(payload):
    """apk-tools v3 container: the ADBd magic plus one raw-deflate stream."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return b"ADBd" + compressor.compress(payload) + compressor.flush()


# The multicall binary is recognised by the usage string it carries.
btrfs = image(
    2,
    needed=("liblzo2.so.2",),
    trailer=b"btrfs [global] options\nbtrfs-progs v6.99\n",
)
(out / f"btrfs-progs-{pkg_version}.apk").write_bytes(container(btrfs))
# The library the binary links against and the root filesystem does not provide.
(out / f"liblzo2-{lzo_version}.apk").write_bytes(container(image(3, soname="liblzo2.so.2")))
PY

mirror="$tmp/mirror"

make_feed() {
  # make_feed <release>: the two packages and the listing the stage resolves them from.
  local release=$1 dir
  dir="$mirror/releases/${release}/packages/x86_64/packages"
  mkdir -p "$dir"
  cp "$tmp/payloads/btrfs-progs-${pkg_version}.apk" "$dir/"
  cp "$tmp/payloads/liblzo2-${lzo_version}.apk" "$dir/"
  cat >"$dir/index.html" <<HTML
<html><body>
<a href="btrfs-progs-${pkg_version}.apk">btrfs-progs-${pkg_version}.apk</a>
<a href="liblzo2-${lzo_version}.apk">liblzo2-${lzo_version}.apk</a>
</body></html>
HTML
}

make_feed "$pin_release"
make_feed "$build_release"

# The root filesystem decides which libraries ship: it provides none of them here, and it
# carries no musl loader, so the stage skips its self-test.
mkdir -p "$tmp/rootfs/etc"
printf 'DISTRIB_ID=ImmortalWrt\n' >"$tmp/rootfs/etc/openwrt_release"
tar -czf "$tmp/rootfs.tar.gz" -C "$tmp/rootfs" .

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
# curl stand-in: the feed of this test is a local directory, so only the URL path matters.
# A URL ending in a slash is the package feed listing. It fails like curl --fail when the
# feed has no such file.
set -uo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -z "$out" ] || [ -z "$url" ]; then
  printf 'stub curl: --output and a URL are required\n' >&2
  exit 2
fi
src="${STUB_MIRROR:?}/${url#*://*/}"
case "$src" in */) src="${src}index.html" ;; esac
if [ ! -f "$src" ]; then
  printf 'stub curl: %s is not in the feed\n' "$url" >&2
  exit 22
fi
cp "$src" "$out"
SH
chmod +x "$tmp/bin/curl"

# --------------------------------------------------------------------------- #
# The committed lockfile of this test: the same package names, pinned to the other release
# --------------------------------------------------------------------------- #
python3 - "$tmp/pin.lock.json" "$pin_release" "$btrfs_image" "$pkg_version" "$lzo_version" <<'PY'
import json
import sys

destination, release, btrfs_image, pkg_version, lzo_version = sys.argv[1:6]
lock = {
    "generated_by": "tests/modules/ci/test_runtime_version_lock.sh (fake pin lockfile)",
    "upstream_version": release,
    "feed": "packages/x86_64/packages",
    "notes": [
        "Fake lockfile: the package names the test feed publishes, pinned to a release whose bytes the feed does not carry.",
        "The digests are only ever compared, so they carry no real package.",
    ],
    "btrfs_image": btrfs_image,
    "packages": {
        f"btrfs-progs-{pkg_version}.apk": {
            "sha256": "1" * 64,
            "files": {btrfs_image: "2" * 64},
        },
        f"liblzo2-{lzo_version}.apk": {
            "sha256": "3" * 64,
            "files": {"usr/lib/liblzo2.so.2": "4" * 64},
        },
    },
}
open(destination, "w", encoding="utf-8").write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
PY

run_stage() {
  # run_stage <tmp-root> <release> [env assignment ...]
  local tmp_root=$1 release=$2
  shift 2
  out=$(env \
    -u CI_LOCK_STRICT -u CI_OUTPUT_ENV -u CI_PLATFORM_RUNTIME_OUT -u CI_RUNTIME_LIMIT_MIB \
    -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_ACTIONS \
    PATH="$tmp/bin:$PATH" \
    STUB_MIRROR="$mirror" \
    CI_TMP_ROOT="$tmp_root" \
    CI_UPSTREAM_VERSION="$release" \
    CI_UPSTREAM_BASE_URL="http://mirror.invalid/releases/${release}/targets/x86/64" \
    CI_RUNTIME_LOCKFILE="$tmp/pin.lock.json" \
    CI_ROOTFS_TAR="$tmp/rootfs.tar.gz" \
    "$@" \
    bash "$root/scripts/ci/platform-runtime.sh" 2>&1)
  code=$?
}

lock_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

locks_present() {
  # locks_present <tmp-root>: present/absent, without relying on ls of a missing directory.
  if [ -e "$1/locks" ]; then printf 'present\n'; else printf 'absent\n'; fi
}

pin_before=$(hash_file "$tmp/pin.lock.json")

# --------------------------------------------------------------------------- #
# 1. Same release as the pin: the drift check is unchanged and still fatal
# --------------------------------------------------------------------------- #
run_stage "$tmp/ci-pin" "$pin_release"
assert_eq "$code" "1" "ac-1 a pin build still fails when the feed publishes other package bytes"
assert_contains "$out" \
  "[runtime] lockfile drift: btrfs-progs-${pkg_version}.apk digest changed" \
  "ac-1 the pin failure keeps its wording and names the package"
assert_eq "$(printf '%s\n' "$out" | grep -c 'derived')" "0" \
  "ac-1 a pin build neither derives nor mentions a derived lockfile"
assert_eq "$(locks_present "$tmp/ci-pin")" "absent" "ac-1 a pin build writes no lockfile under locks/"

# --------------------------------------------------------------------------- #
# 2. Another release: a per-version lockfile is derived, asserted and announced
# --------------------------------------------------------------------------- #
# A copy left behind by an earlier build must not become the contract of this one, so the
# run starts from a stale file at exactly the path it is about to derive.
mkdir -p "$tmp/ci-derive/locks"
printf '{"upstream_version": "stale-0.0.1", "btrfs_image": "usr/lib/stale", "packages": {}}\n' \
  >"$tmp/ci-derive/locks/runtime-closure-${build_release}.json"

run_stage "$tmp/ci-derive" "$build_release"
derived="$tmp/ci-derive/locks/runtime-closure-${build_release}.json"
assert_eq "$code" "0" "ac-1 a build for another release passes with a derived lockfile"
assert_file_exists "$derived" "ac-1 the derived lockfile lands at CI_TMP_ROOT/locks/runtime-closure-<version>.json"
assert_contains "$out" "deriving a per-version lockfile for upstream ${build_release}: ${derived}" \
  "ac-1 the stage announces the release it derives for and the derived path"
assert_contains "$out" "WARNING: derived per-version lockfile: ${derived}" \
  "ac-1 the derive is a warning that names the derived path"
assert_contains "$out" "does not assert the committed lockfile (pinned ${pin_release})" \
  "ac-1 the warning names the release the committed lockfile still pins"
assert_contains "$out" "package drift is NOT enforced for this release" \
  "ac-1 the warning says the drift assertion is not enforced for this release"
assert_contains "$out" "CI_LOCK_STRICT=1 turns the same drift back into a hard failure" \
  "ac-1 the warning names the switch that restores the pin contract"
assert_contains "$out" "lockfile rewritten: ${derived}" \
  "ac-1 the derived lockfile is written by the existing --write-lock path, at the derived path"
assert_contains "$out" "[runtime] lockfile matches the feed" \
  "ac-1 the run asserts the lockfile it is bound by and passes"
assert_contains "$out" "lockfile=${derived}" \
  "ac-1 the stage output publishes the lockfile it asserted, i.e. the derived one"
assert_contains "$out" "runtime_btrfs=$tmp/ci-derive/runtime/usr/sbin/btrfs" \
  "ac-1 the derived build still stages the btrfs binary"
assert_eq "$(printf '%s\n' "$out" | grep -c 'lockfile drift')" "0" \
  "ac-1 a derived build reports no drift against the pin contract"
assert_eq "$(lock_field "$derived" upstream_version)" "$build_release" \
  "ac-1 the derived lockfile replaced the stale copy and records the release of the build"
assert_eq "$(lock_field "$derived" btrfs_image)" "$btrfs_image" \
  "ac-1 the derived lockfile records the runtime image the feed publishes"
assert_eq "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["packages"])))' "$derived")" \
  "btrfs-progs-${pkg_version}.apk liblzo2-${lzo_version}.apk" \
  "ac-1 the derived lockfile pins the packages the feed publishes"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"][sys.argv[2]]["sha256"])' \
  "$derived" "btrfs-progs-${pkg_version}.apk")" \
  "$(hash_file "$mirror/releases/${build_release}/packages/x86_64/packages/btrfs-progs-${pkg_version}.apk")" \
  "ac-1 the derived lockfile records the digest of the package it downloaded"

# The run page carries the same fact as the log when Actions renders it.
run_stage "$tmp/ci-derive-actions" "$build_release" GITHUB_ACTIONS=1
assert_eq "$code" "0" "ac-1 a derived build passes under GITHUB_ACTIONS as well"
assert_contains "$out" "::warning title=runtime derived lockfile::${build_release} build uses $tmp/ci-derive-actions/locks/runtime-closure-${build_release}.json" \
  "ac-1 Actions gets one annotation naming the derived path"

pin_after=$(hash_file "$tmp/pin.lock.json")
assert_eq "$pin_after" "$pin_before" "ac-1 a derived build leaves the committed lockfile byte for byte untouched"

# --------------------------------------------------------------------------- #
# 3. CI_LOCK_STRICT=1: the pin contract applies to every release again
# --------------------------------------------------------------------------- #
run_stage "$tmp/ci-strict" "$build_release" CI_LOCK_STRICT=1
assert_eq "$code" "1" "ac-1 CI_LOCK_STRICT=1 fails a build for another release"
assert_contains "$out" "CI_LOCK_STRICT=1: asserting the pinned lockfile (${pin_release}) for the ${build_release} build" \
  "ac-1 strict mode says which lockfile it keeps asserting"
assert_contains "$out" "[runtime] lockfile drift: upstream_version is '${pin_release}', feed has '${build_release}'" \
  "ac-1 the strict failure is the pin drift message, unchanged"
assert_eq "$(printf '%s\n' "$out" | grep -c 'derived')" "0" \
  "ac-1 strict mode neither derives nor mentions a derived lockfile"
assert_eq "$(locks_present "$tmp/ci-strict")" "absent" "ac-1 CI_LOCK_STRICT=1 derives no lockfile"

finish
