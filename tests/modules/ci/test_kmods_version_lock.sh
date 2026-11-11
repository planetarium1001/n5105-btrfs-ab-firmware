#!/usr/bin/env bash
# Module: ci
#
# A matrix build asks for another upstream release than the pin, and the committed kmod
# lockfile pins one release: every module version in it belongs to that release's kernel.
# scripts/ci/kmods.sh therefore derives a per-version lockfile for such a build under
# $CI_TMP_ROOT and keeps the pin a hard contract. Locked here:
#
#   ac-1 a build whose release matches the lockfile keeps the drift check exactly as it
#        is: a mirror that publishes another module version fails the stage, and the
#        error names the package, the published version and the pinned version
#   ac-1 a build for another release derives <CI_TMP_ROOT>/locks/kmod-closure-<v>.json
#        from what the mirror publishes, verifies against that copy, announces the
#        derived path and warns that the drift assertion is not enforced for it, and the
#        committed lockfile stays untouched
#   ac-1 CI_LOCK_STRICT=1 restores the pin contract for such a build: the same hard
#        failure and no derived lockfile
#
# Everything runs offline and without root: the mirror is a local directory reached
# through a curl stand-in on PATH, and the two packages are apk-tools v3 containers built
# in this test around a minimal relocatable ELF, so the real scripts/ci/apk_extract.py
# unpacks real bytes and the real --write-lock path writes the derived lockfile.
#
# Usage:
#   bash tests/modules/ci/test_kmods_version_lock.sh
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

# The release the fake lockfile pins and the one the fake mirror publishes. They differ,
# which is the situation a matrix build is in: same stage scripts, another kernel line.
pin_release="25.12.99"
pin_kernel="6.12.99"
pin_kmods_version="${pin_kernel}-r1"
pin_kmods_dir="${pin_kernel}-1-11111111111111111111111111111111"
build_release="25.12.94"
build_kernel="6.12.94"
mirror_version="${build_kernel}-r1"
build_kmods_dir="${build_kernel}-1-22222222222222222222222222222222"

# Hashing goes through scripts/ci/lib.sh, so the test computes the same digest a stage does.
hash_file() {
  bash -c '. "$1/scripts/ci/lib.sh" >/dev/null 2>&1; ci_sha256 "$2"' _ "$root" "$1"
}

# --------------------------------------------------------------------------- #
# The mirror: two packages a release publishes, in the layout the stage reads
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/payloads"
python3 - "$tmp/payloads" "$build_kernel" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
kernel = sys.argv[2]


def section(name_offset, sh_type, offset, size, align=1):
    """One ELF64 section header; only the fields apk_extract reads are set."""
    return struct.pack("<IIQQQQIIQQ", name_offset, sh_type, 0, 0, offset, size, 0, 0, align, 0)


def relocatable(name, vermagic):
    """A minimal ET_REL image with a .modinfo section, i.e. what apk_extract decodes."""
    info = f"name={name}\0vermagic={vermagic}\0".encode()
    shstrtab = b"\0.shstrtab\0.modinfo\0"
    info_offset = 64
    shstr_offset = info_offset + len(info)
    shdr_offset = shstr_offset + len(shstrtab)
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # ELFDATA2LSB
    header[6] = 1  # EV_CURRENT
    struct.pack_into("<HHI", header, 16, 1, 62, 1)  # ET_REL, EM_X86_64, EV_CURRENT
    struct.pack_into("<Q", header, 0x28, shdr_offset)  # e_shoff
    struct.pack_into("<H", header, 0x34, 64)  # e_ehsize
    struct.pack_into("<H", header, 0x3A, 64)  # e_shentsize
    struct.pack_into("<H", header, 0x3C, 3)  # e_shnum
    struct.pack_into("<H", header, 0x3E, 1)  # e_shstrndx
    return bytes(header) + info + shstrtab + b"".join((
        section(0, 0, 0, 0),  # SHT_NULL
        section(1, 3, shstr_offset, len(shstrtab)),  # .shstrtab
        section(11, 1, info_offset, len(info)),  # .modinfo
    ))


def container(payload):
    """apk-tools v3 container: the ADBd magic plus one raw-deflate stream."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return b"ADBd" + compressor.compress(payload) + compressor.flush()


# The file table that precedes the image is where apk_extract reads the install path.
module_path = f"/lib/modules/{kernel}/btrfs.ko"
module = relocatable("btrfs", f"{kernel} SMP mod_unload ")
(out / "kmod-fs-btrfs.apk").write_bytes(container(module_path.encode() + b"\n\0" + module))
# A virtual member: the driver is built into the kernel, so the package ships no image.
(out / "kmod-lib-crc32c.apk").write_bytes(
    container(b"kmod-lib-crc32c-any\n/etc/modules.d/30-crc32c\n")
)
PY

mirror="$tmp/mirror"
mirror_names="kmod-fs-btrfs kmod-lib-crc32c"

make_mirror() {
  # make_mirror <release> <kmods-dir>: the index, the digest list and the packages of
  # one release, arranged exactly as scripts/ci/kmods.sh reads them.
  local release=$1 kmods_dir=$2 target name apk
  target="$mirror/releases/${release}/targets/x86/64"
  mkdir -p "$target/kmods/${kmods_dir}"
  cat >"$target/kmods/${kmods_dir}/index.json" <<JSON
{"packages": {"kmod-fs-btrfs": "${mirror_version}", "kmod-lib-crc32c": "${mirror_version}"}}
JSON
  : >"$target/sha256sums"
  for name in ${mirror_names}; do
    apk="$target/kmods/${kmods_dir}/${name}-${mirror_version}.apk"
    cp "$tmp/payloads/${name}.apk" "$apk"
    printf '%s *kmods/%s/%s-%s.apk\n' \
      "$(hash_file "$apk")" "${kmods_dir}" "${name}" "${mirror_version}" >>"$target/sha256sums"
  done
}

make_mirror "$pin_release" "$pin_kmods_dir"
make_mirror "$build_release" "$build_kmods_dir"

base_url_for() {
  printf 'http://mirror.invalid/releases/%s/targets/x86/64' "$1"
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
# curl stand-in: the mirror of this test is a local directory, so only the URL path
# matters. It fails like curl --fail when the mirror has no such file.
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
if [ ! -f "$src" ]; then
  printf 'stub curl: %s is not in the mirror\n' "$url" >&2
  exit 22
fi
cp "$src" "$out"
SH
chmod +x "$tmp/bin/curl"

# --------------------------------------------------------------------------- #
# The committed lockfile of this test: two members, pinned to the other release
# --------------------------------------------------------------------------- #
python3 - "$tmp/pin.lock.json" "$pin_release" "$pin_kernel" "$pin_kmods_dir" "$pin_kmods_version" <<'PY'
import json
import sys

destination, release, kernel, kmods_dir, version = sys.argv[1:6]
lock = {
    "generated_by": "tests/modules/ci/test_kmods_version_lock.sh (fake pin lockfile)",
    "upstream_version": release,
    "kernel_version": kernel,
    "kmods_dir": kmods_dir,
    "root": "kmod-fs-btrfs",
    "notes": [
        "Fake lockfile: two members of the real closure, pinned to a release the test mirror does not publish.",
        "The version fields are only ever compared, so they carry no real digest.",
    ],
    "packages": [
        {
            "name": "kmod-fs-btrfs",
            "version": version,
            "kind": "modules",
            "sha256": "1" * 64,
            "provides": [],
            "modules": [
                {
                    "path": f"/lib/modules/{kernel}/btrfs.ko",
                    "size": 1,
                    "sha256": "2" * 64,
                    "vermagic": f"{kernel} SMP mod_unload ",
                }
            ],
        },
        {
            "name": "kmod-lib-crc32c",
            "version": version,
            "kind": "virtual",
            "sha256": "3" * 64,
            "provides": ["kmod-lib-crc32c-any"],
            "modules": [],
        },
    ],
}
open(destination, "w", encoding="utf-8").write(json.dumps(lock, indent=2) + "\n")
PY

run_kmods() {
  # run_kmods <tmp-root> <release> <kmods-dir> [env assignment ...]
  local tmp_root=$1 release=$2 kmods_dir=$3
  shift 3
  out=$(env \
    -u CI_LOCK_STRICT -u CI_KMODS_CLOSURE \
    -u CI_OUTPUT_ENV -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_ACTIONS \
    PATH="$tmp/bin:$PATH" \
    STUB_MIRROR="$mirror" \
    CI_TMP_ROOT="$tmp_root" \
    CI_UPSTREAM_VERSION="$release" \
    CI_KMODS_DIR="$kmods_dir" \
    CI_UPSTREAM_BASE_URL="$(base_url_for "$release")" \
    CI_LOCKFILE="$tmp/pin.lock.json" \
    "$@" \
    bash "$root/scripts/ci/kmods.sh" 2>&1)
  code=$?
}

lock_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

pin_before=$(hash_file "$tmp/pin.lock.json")

# --------------------------------------------------------------------------- #
# 1. Same release as the pin: the drift check is unchanged and still fatal
# --------------------------------------------------------------------------- #
run_kmods "$tmp/ci-pin" "$pin_release" "$pin_kmods_dir"
assert_eq "$code" "1" "ac-1 a pin build still fails when the mirror publishes another module version"
assert_contains "$out" \
  "[kmods] ERROR: kmod-fs-btrfs: mirror publishes ${mirror_version}, lockfile pins ${pin_kmods_version}" \
  "ac-1 the pin failure keeps its wording: package, published version, pinned version"
assert_eq "$(printf '%s\n' "$out" | grep -c 'derived')" "0" \
  "ac-1 a pin build neither derives nor mentions a derived lockfile"
if [ -e "$tmp/ci-pin/locks" ]; then pin_no_derive="present"; else pin_no_derive="absent"; fi
assert_eq "$pin_no_derive" "absent" "ac-1 a pin build writes no lockfile under locks/"

# --------------------------------------------------------------------------- #
# 2. Another release: a per-version lockfile is derived, verified and announced
# --------------------------------------------------------------------------- #
run_kmods "$tmp/ci-derive" "$build_release" "$build_kmods_dir"
derived="$tmp/ci-derive/locks/kmod-closure-${build_release}.json"
assert_eq "$code" "0" "ac-1 a build for another release passes with a derived lockfile"
assert_file_exists "$derived" "ac-1 the derived lockfile lands at CI_TMP_ROOT/locks/kmod-closure-<version>.json"
assert_contains "$out" "deriving a per-version lockfile for upstream ${build_release}: ${derived}" \
  "ac-1 the stage announces the release it derives for and the derived path"
assert_contains "$out" "WARNING: derived per-version lockfile: ${derived}" \
  "ac-1 the derive is a warning that names the derived path"
assert_contains "$out" "does not assert the committed lockfile (pinned ${pin_release})" \
  "ac-1 the warning names the release the committed lockfile still pins"
assert_contains "$out" "module drift is NOT enforced for this release" \
  "ac-1 the warning says the drift assertion is not enforced for this release"
assert_contains "$out" "CI_LOCK_STRICT=1 turns the same drift back into a hard failure" \
  "ac-1 the warning names the switch that restores the pin contract"
assert_contains "$out" "[kmods] wrote ${derived}" \
  "ac-1 the derived lockfile is written by the existing --write-lock path"
assert_contains "$out" "lockfile=${derived}" \
  "ac-1 the stage output publishes the lockfile it verified, i.e. the derived one"
assert_contains "$out" "[kmods] lockfile matches: 2 package(s)" \
  "ac-1 the unpacked modules are verified against the derived lockfile"
assert_contains "$out" "btrfs_module=lib/modules/${build_kernel}/btrfs.ko" \
  "ac-1 the derived build still produces the module the initramfs needs"
assert_file_exists "$tmp/ci-derive/kmods/modules/lib/modules/${build_kernel}/btrfs.ko" \
  "ac-1 the btrfs module was really unpacked for the derived release"

assert_eq "$(lock_field "$derived" upstream_version)" "$build_release" \
  "ac-1 the derived lockfile records the release the build asked for"
assert_eq "$(lock_field "$derived" kernel_version)" "$build_kernel" \
  "ac-1 the derived lockfile records the kernel of that release"
assert_eq "$(lock_field "$derived" kmods_dir)" "$build_kmods_dir" \
  "ac-1 the derived lockfile records the module directory of that release"
assert_eq "$(python3 -c 'import json,sys; print(" ".join(p["version"] for p in json.load(open(sys.argv[1]))["packages"]))' "$derived")" \
  "${mirror_version} ${mirror_version}" \
  "ac-1 the derived lockfile pins the versions the mirror publishes, not the committed ones"

pin_after=$(hash_file "$tmp/pin.lock.json")
assert_eq "$pin_after" "$pin_before" "ac-1 a derived build leaves the committed lockfile byte for byte untouched"

# --------------------------------------------------------------------------- #
# 3. CI_LOCK_STRICT=1: the pin contract applies to every release again
# --------------------------------------------------------------------------- #
run_kmods "$tmp/ci-strict" "$build_release" "$build_kmods_dir" CI_LOCK_STRICT=1
assert_eq "$code" "1" "ac-1 CI_LOCK_STRICT=1 fails a build for another release"
assert_contains "$out" \
  "[kmods] ERROR: kmod-fs-btrfs: mirror publishes ${mirror_version}, lockfile pins ${pin_kmods_version}" \
  "ac-1 the strict failure is the pin drift message, unchanged"
if [ -e "$tmp/ci-strict/locks" ]; then strict_no_derive="present"; else strict_no_derive="absent"; fi
assert_eq "$strict_no_derive" "absent" "ac-1 CI_LOCK_STRICT=1 derives no lockfile"

finish
