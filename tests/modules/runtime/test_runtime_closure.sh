#!/usr/bin/env bash
# Module: runtime
# Verifies that the btrfs tooling ships in the platform layer and that the tool path
# fails loudly instead of pretending to work when it is missing.
#   ac-1 the extractor recovers an executable from an ADBd container and rejects junk
#   ac-2 the lockfile pins exactly the files the installer writes
#   ac-3 ab-slot gc reports a missing btrfs tool with a reason and a non-zero status
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- ac-1 the extractor ------------------------------------------------------
python3 - "$tmp" <<'PYTHON'
import struct, sys, zlib, pathlib

tmp = pathlib.Path(sys.argv[1])

# A minimal ELF64: one PT_LOAD covering the header, no PT_DYNAMIC. That is all the
# extractor needs to size an image, and it must classify it as an executable.
ehdr = bytearray(64)
ehdr[0:4] = b"\x7fELF"
ehdr[4] = 2      # 64-bit
ehdr[5] = 1      # little-endian
struct.pack_into("<H", ehdr, 16, 2)   # e_type = EXEC
struct.pack_into("<H", ehdr, 18, 62)  # e_machine = x86-64
struct.pack_into("<Q", ehdr, 0x20, 64)  # e_phoff
struct.pack_into("<H", ehdr, 0x36, 56)  # e_phentsize
struct.pack_into("<H", ehdr, 0x38, 1)   # e_phnum
phdr = bytearray(56)
struct.pack_into("<I", phdr, 0, 1)      # PT_LOAD
struct.pack_into("<Q", phdr, 0x08, 0)   # p_offset
struct.pack_into("<Q", phdr, 0x10, 0)   # p_vaddr
struct.pack_into("<Q", phdr, 0x20, 120) # p_filesz
payload = bytes(ehdr) + bytes(phdr) + b"payload\n"
container = b"ADBd" + zlib.compress(payload)[2:-4]  # raw deflate
(tmp / "fake.apk").write_bytes(container)
(tmp / "junk.apk").write_bytes(b"not an apk at all")
PYTHON

out="$tmp/extracted"
python3 scripts/ci/elf_extract.py --out "$out" --manifest "$tmp/m.json" \
  --apk-name fake.apk "$tmp/fake.apk" >/dev/null 2>&1
assert_eq "$?" "0" "ac-1 a synthetic package extracts"
assert_eq "$(python3 -c "import json;d=json.load(open('$tmp/m.json'));print(d['images'][0]['kind'])")" \
  "executable" "ac-1 an image without a soname is classified as an executable"
assert_eq "$(python3 -c "import json;d=json.load(open('$tmp/m.json'));print(d['images'][0]['size'])")" \
  "120" "ac-1 the image extent comes from its program headers"

python3 scripts/ci/elf_extract.py --out "$out" --manifest "$tmp/m2.json" \
  --apk-name junk.apk "$tmp/junk.apk" >/dev/null 2>&1
assert_eq "$?" "1" "ac-1 a file that is not an apk is rejected"

# --- ac-2 the lockfile -------------------------------------------------------
lock="scripts/ci/runtime-closure.json"
assert_file_exists "$lock" "ac-2 the runtime lockfile exists"
python3 - "$lock" <<'PYTHON'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
files = sorted(f for meta in doc["packages"].values() for f in meta["files"])
assert "usr/sbin/btrfs" in files, f"no btrfs binary in the lockfile: {files}"
for path in files:
    assert path.startswith(("usr/sbin/", "usr/lib/")), f"unexpected install path {path}"
for name, meta in doc["packages"].items():
    assert len(meta["sha256"]) == 64, f"{name} has no digest"
    assert meta["files"], f"{name} installs nothing"
PYTHON
assert_eq "$?" "0" "ac-2 every locked package pins a digest and an install path"
assert_eq "$(python3 -c "import json;d=json.load(open('$lock'));print(d['btrfs_image'])")" \
  "usr/lib/btrfs-progs-6.11-r3.exec0" "ac-2 the lockfile names the image that becomes usr/sbin/btrfs"

# The platform layer must refuse to build without the tooling.
assert_contains "$(cat scripts/ci/disk.sh)" 'the platform layer has no runnable usr/sbin/btrfs' \
  "ac-2 disk.sh refuses a platform layer without the btrfs tool"
assert_contains "$(cat scripts/ci/disk.sh)" 'platform_bytes' \
  "ac-2 disk.sh asserts the platform layer budget"

# --- ac-3 gc without the tool ------------------------------------------------
esp="$tmp/esp"
mkdir -p "$esp/ab/log" "$tmp/p4" "$tmp/nobin"
cat >"$esp/ab/state.json" <<'JSON'
{
  "generation": 1,
  "committed": "a",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
JSON
# A PATH with the shell builtins and the core utilities ab-slot needs, but no btrfs.
for tool in sed awk tr mkdir mv rm sync find cat printf sha256sum; do
  [ -x "/usr/bin/$(basename "$tool")" ] && ln -sf "/usr/bin/$(basename "$tool")" "$tmp/nobin/$tool" 2>/dev/null
done

# ab-slot appends the system directories to PATH on purpose (a chroot has to be able to
# supply its own btrfs), so trimming PATH does not hide the tool on a machine that has
# btrfs-progs installed - the case silently stopped testing the missing-tool path there.
# AB_BTRFS is the seam: point it at a path that does not exist.
out="$(AB_BTRFS="$tmp/nobin/btrfs" PATH="$tmp/nobin:/bin:/usr/bin" AB_ESP="$esp" \
  AB_CMD=/dev/null AB_P4="$tmp/p4" /bin/sh platform/usr/sbin/ab-slot gc 2>&1)"
assert_eq "$?" "1" "ac-3 gc exits non-zero without the btrfs tool"
assert_contains "$out" "reason=btrfs-tool-missing" "ac-3 gc names the missing tool"
assert_eq "$(printf '%s' "$out" | grep -c 'deleting')" "0" "ac-3 gc does not claim to have deleted anything"

# ab-boot must also record the failure instead of silently skipping reclamation.
assert_contains "$(cat platform/etc/init.d/ab-boot)" 'reason=btrfs-tool-missing' \
  "ac-3 ab-boot logs the missing tool"
assert_contains "$(cat platform/etc/init.d/ab-boot)" 'btrfs=ok subvolume-list=ok' \
  "ac-3 ab-boot proves the tool works before using it"

finish
