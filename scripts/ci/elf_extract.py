#!/usr/bin/env python3
"""Extract ELF images from apk-tools v3 packages and classify them.

The apk v3 container used by this feed is a raw-deflate stream behind an "ADBd"
magic. Inside, file contents are stored uncompressed, so every executable and
shared object can be recovered by scanning for the ELF magic and walking the
program headers.

This tool is the runtime-package counterpart of apk_extract.py (which handles
kernel modules): kernel modules are identified by their .modinfo name, while
runtime files are identified by what the dynamic linker uses:

  * shared objects carry DT_SONAME  -> install as /usr/lib/<soname>
  * executables carry no soname     -> identified by the name the caller expects

Usage:
  elf_extract.py --out DIR --manifest JSON [--expect NAME=PATH] apk...

The manifest records, per package, every image with its soname, DT_NEEDED
list, size and sha256, so the caller can resolve the library closure without
guessing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

ADB_MAGIC = b"ADBd"
ELF_MAGIC = b"\x7fELF"

DT_NULL = 0
DT_NEEDED = 1
DT_SONAME = 14


class ExtractError(Exception):
    """A package could not be unpacked."""


def inflate_adb(data: bytes) -> bytes:
    """Body of an apk v3 container: raw deflate after the four magic bytes."""
    if not data.startswith(ADB_MAGIC):
        raise ExtractError("not an ADBd container")
    try:
        return zlib.decompress(data[len(ADB_MAGIC):], -15)
    except zlib.error as exc:  # pragma: no cover - defensive
        raise ExtractError(f"cannot inflate the container: {exc}") from exc


def elf_length(blob: bytes, offset: int) -> int:
    """Total size of the ELF image at offset.

    Runtime images in this feed are shipped without a section table, so the extent
    comes from the program headers: the file ends where the last segment ends.
    """
    if blob[offset:offset + 6] != b"\x7fELF\x02\x01":
        raise ExtractError(f"not a 64-bit little-endian ELF image at {offset}")
    e_phoff = struct.unpack_from("<Q", blob, offset + 0x20)[0]
    e_phentsize = struct.unpack_from("<H", blob, offset + 0x36)[0]
    e_phnum = struct.unpack_from("<H", blob, offset + 0x38)[0]
    e_shoff = struct.unpack_from("<Q", blob, offset + 0x28)[0]
    e_shentsize = struct.unpack_from("<H", blob, offset + 0x3A)[0]
    e_shnum = struct.unpack_from("<H", blob, offset + 0x3C)[0]

    ends = []
    if e_shoff and e_shnum:
        ends.append(e_shoff + e_shentsize * e_shnum)
    for index in range(e_phnum):
        base = offset + e_phoff + index * e_phentsize
        p_offset = struct.unpack_from("<Q", blob, base + 0x08)[0]
        p_filesz = struct.unpack_from("<Q", blob, base + 0x20)[0]
        ends.append(p_offset + p_filesz)
    if not ends or max(ends) == 0:
        raise ExtractError(f"ELF image at {offset} has neither sections nor segments")
    return max(ends)


def dynamic_strings(blob: bytes, offset: int) -> tuple[list[str], list[str]]:
    """(soname, sorted DT_NEEDED) for the ELF image at offset."""
    e_phoff = struct.unpack_from("<Q", blob, offset + 0x20)[0]
    e_phentsize = struct.unpack_from("<H", blob, offset + 0x36)[0]
    e_phnum = struct.unpack_from("<H", blob, offset + 0x38)[0]

    dynamic = None
    loads = []
    for index in range(e_phnum):
        base = offset + e_phoff + index * e_phentsize
        p_type = struct.unpack_from("<I", blob, base)[0]
        p_offset = struct.unpack_from("<Q", blob, base + 0x08)[0]
        p_vaddr = struct.unpack_from("<Q", blob, base + 0x10)[0]
        p_filesz = struct.unpack_from("<Q", blob, base + 0x20)[0]
        if p_type == 2:  # PT_DYNAMIC
            dynamic = (offset + p_offset, p_filesz)
        elif p_type == 1:  # PT_LOAD
            loads.append((p_vaddr, p_offset, p_filesz))
    if dynamic is None:
        return [], []

    def file_offset(vaddr: int) -> int | None:
        """Translate a virtual address into an offset inside the container."""
        for seg_vaddr, seg_offset, seg_filesz in loads:
            if seg_vaddr <= vaddr < seg_vaddr + seg_filesz:
                return offset + seg_offset + (vaddr - seg_vaddr)
        return None

    entries = []
    start, size = dynamic
    for pos in range(start, start + size, 16):
        tag, value = struct.unpack_from("<qQ", blob, pos)
        if tag == DT_NULL:
            break
        entries.append((tag, value))

    # The string table lives in the image, located through DT_STRTAB; for a
    # position-independent file the value is the virtual address, which equals
    # the file offset for these packages because PT_LOAD starts at 0.
    strtab = None
    for tag, value in entries:
        if tag == 5:  # DT_STRTAB
            strtab = file_offset(value)
    if strtab is None:
        return [], []

    def read_str(at: int) -> str:
        end = blob.find(b"\0", at)
        return blob[at:end].decode("utf-8", "replace")

    soname = ""
    needed: list[str] = []
    for tag, value in entries:
        if tag == DT_SONAME:
            soname = read_str(strtab + value)
        elif tag == DT_NEEDED:
            needed.append(read_str(strtab + value))
    return soname, sorted(needed)


def images(payload: bytes) -> list[dict]:
    found = []
    position = 0
    while True:
        offset = payload.find(ELF_MAGIC, position)
        if offset < 0:
            return found
        try:
            length = elf_length(payload, offset)
        except ExtractError:
            position = offset + 4
            continue
        data = payload[offset:offset + length]
        soname, needed = dynamic_strings(payload, offset)
        found.append(
            {
                "offset": offset,
                "length": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "soname": soname,
                "needed": needed,
                "kind": "shared" if soname else "executable",
                "data": data,
            }
        )
        position = offset + length


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, help="directory that receives the images")
    parser.add_argument("--manifest", required=True, help="JSON inventory of what was extracted")
    parser.add_argument("--apk-name", required=True, help="package file name, recorded in the manifest")
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        metavar="NAME=IMAGE",
        help="install the image at that index as /usr/sbin/NAME (repeatable)",
    )
    parser.add_argument("apk", help="the .apk to unpack")
    args = parser.parse_args(argv)

    apk = Path(args.apk)
    payload = inflate_adb(apk.read_bytes())
    found = images(payload)
    if not found:
        raise ExtractError(f"{apk.name}: no ELF image in the payload")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "usr" / "lib").mkdir(parents=True, exist_ok=True)

    record = []
    for index, image in enumerate(found):
        if image["kind"] == "shared":
            target = out / "usr" / "lib" / image["soname"]
        else:
            target = out / "usr" / "lib" / f"{apk.stem}.exec{index}"
        target.write_bytes(image["data"])
        target.chmod(0o755 if image["kind"] == "executable" else 0o644)
        record.append(
            {
                "index": index,
                "kind": image["kind"],
                "soname": image["soname"],
                "needed": image["needed"],
                "size": image["length"],
                "sha256": image["sha256"],
                "installed": str(target.relative_to(out)),
            }
        )

    manifest = {
        "package": apk.name,
        "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
        "images": record,
    }
    Path(args.manifest).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    for entry in record:
        print(
            f"[elf_extract] {apk.name}: {entry['kind']:10s} {entry['soname'] or '-':24s} "
            f"{entry['size']:8d} -> {entry['installed']}",
            file=sys.stderr,
        )
        if entry["needed"]:
            print(f"[elf_extract]   needs {', '.join(entry['needed'])}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ExtractError as exc:
        print(f"[elf_extract] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
