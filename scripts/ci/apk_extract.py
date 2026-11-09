#!/usr/bin/env python3
"""Extract kernel modules from apk-tools v3 (ADB) packages.

Packages published for ImmortalWrt 25.12 are apk-tools v3 containers: the file
starts with the 4-byte magic ``ADBd``, followed by a raw-deflate stream that carries
the package metadata and the file data. ``tar``, ``bsdtar`` and ``ar`` all reject
this format, and the module file names only appear inside the inflated payload, so
this script implements the small part of the container that matters here:

1. inflate the payload (raw deflate, with zlib/gzip accepted as fallbacks)
2. locate every ELF image in the payload
3. derive the exact file length from the ELF's own section header table, which is
   always the last structure in a relocatable object, so no length field has to be
   trusted
4. map each ELF to the module path listed in the file table that precedes it, and
   cross-check that mapping against the ``name=`` entry of the ELF's ``.modinfo``

The result is byte-identical to what the official image installs: extracting
``kmod-lib-crc32c`` yields the same sha256 as the ``libcrc32c.ko`` shipped in
``immortalwrt-25.12.2-x86-64-rootfs.tar.gz``.

Usage:
    apk_extract.py --out DIR [--kver 6.12.103] [--json-out FILE] package.apk ...

Output: files are written to DIR/<path without leading slash>; a JSON inventory is
printed to stdout (or to --json-out).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
import zlib
from pathlib import Path

ADB_MAGIC = b"ADBd"
ELF_MAGIC = b"\x7fELF"
MODULE_PREFIX = "/lib/modules/"
# The file table sits before the first file's data; a few KiB is far more than the
# listing needs, and the window never reaches into another package.
PATH_WINDOW = 8192


PACKAGE_NAME_RE = re.compile(r"^(?P<name>.+)-(?P<version>[0-9][^-]*-r[0-9]+)$")


class PackageError(RuntimeError):
    """Raised when a package cannot be decoded."""


def split_package_name(stem: str) -> tuple[str, str]:
    """Split ``kmod-fs-btrfs-6.12.103-r1`` into name and version."""
    match = PACKAGE_NAME_RE.match(stem)
    if not match:
        return stem, ""
    return match.group("name"), match.group("version")


def inflate_adb(data: bytes) -> bytes:
    """Return the concatenated payload of an ADB container."""
    if data[:4] != ADB_MAGIC:
        raise PackageError(f"not an ADB container, magic={data[:4]!r}")
    payload = bytearray()
    pos = 4
    while pos < len(data):
        for name, wbits in (("deflate", -15), ("zlib", 15), ("gzip", 31)):
            stream = zlib.decompressobj(wbits)
            try:
                chunk = stream.decompress(data[pos:]) + stream.flush()
            except zlib.error:
                continue
            if not stream.eof:
                continue
            consumed = len(data) - pos - len(stream.unused_data)
            if consumed <= 0:
                continue
            payload += chunk
            pos += consumed
            break
        else:
            raise PackageError(f"no readable {name} stream at offset {pos}")
    return bytes(payload)


def elf_length(blob: bytes, offset: int) -> int:
    """Exact length of the relocatable ELF image starting at ``offset``."""
    if blob[offset:offset + 4] != ELF_MAGIC:
        raise PackageError(f"no ELF image at offset {offset}")
    elf_class, elf_data = blob[offset + 4], blob[offset + 5]
    if elf_class != 2 or elf_data != 1:
        raise PackageError(f"unsupported ELF class/encoding {elf_class}/{elf_data} at {offset}")
    e_shoff, = struct.unpack_from("<Q", blob, offset + 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", blob, offset + 0x3A)
    end = e_shoff + e_shentsize * e_shnum
    for index in range(e_shnum):
        header = offset + e_shoff + index * e_shentsize
        sh_offset, = struct.unpack_from("<Q", blob, header + 0x18)
        sh_size, = struct.unpack_from("<Q", blob, header + 0x20)
        end = max(end, sh_offset + sh_size)
    if end <= 0:
        raise PackageError(f"ELF at offset {offset} has no usable section headers")
    return end


def elf_sections(blob: bytes, offset: int) -> list[dict]:
    """Section table of the ELF image starting at ``offset``."""
    e_shoff, = struct.unpack_from("<Q", blob, offset + 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", blob, offset + 0x3A)
    sections = []
    for index in range(e_shnum):
        header = offset + e_shoff + index * e_shentsize
        name_off, sh_type = struct.unpack_from("<II", blob, header)
        _flags, _addr, sh_offset, sh_size = struct.unpack_from("<QQQQ", blob, header + 8)
        sections.append(
            {"name_off": name_off, "type": sh_type, "offset": sh_offset, "size": sh_size}
        )
    if e_shnum:
        table = offset + e_shoff + e_shstrndx * e_shentsize
        str_offset, = struct.unpack_from("<Q", blob, table + 0x18)
        for section in sections:
            start = offset + str_offset + section["name_off"]
            section["name"] = blob[start:blob.index(b"\0", start)].decode("utf-8", "replace")
    return sections


def elf_modinfo(blob: bytes, offset: int) -> dict[str, str]:
    """Parse the ``.modinfo`` section into a dictionary."""
    info: dict[str, str] = {}
    for section in elf_sections(blob, offset):
        if section.get("name") != ".modinfo":
            continue
        start = offset + section["offset"]
        raw = blob[start:start + section["size"]]
        for item in raw.split(b"\0"):
            if b"=" in item:
                key, value = item.split(b"=", 1)
                info[key.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    return info


def listed_module_paths(blob: bytes, first_elf: int) -> list[str]:
    """Module paths from the file table that precedes the first ELF image."""
    window = blob[max(0, first_elf - PATH_WINDOW):first_elf]
    paths: list[str] = []
    for block in window.split(b"\0"):
        for line in block.split(b"\n"):
            candidate = line.strip()
            if candidate.startswith(MODULE_PREFIX.encode()) and candidate.endswith(b".ko"):
                text = candidate.decode("utf-8", "replace")
                if text not in paths:
                    paths.append(text)
    return paths


def canonical(name: str) -> str:
    """Normalise a module name for comparison: lzo-rle and lzo_rle are the same."""
    return name.replace("-", "_")


def payload_strings(payload: bytes) -> list[str]:
    """Printable strings of the inflated payload, used for structural bookkeeping.

    The package record stores strings with a one-byte length prefix, so restricting
    the scan to printable runs drops both the prefixes and the binary padding.
    """
    return [match.decode("utf-8", "replace") for match in re.findall(rb"[\x20-\x7e]{2,}", payload)]


def extract_package(path: Path, kver: str | None = None) -> dict:
    """Return ``{"package", "kind", "modules": [...]}`` for one apk file."""
    payload = inflate_adb(path.read_bytes())
    images = []
    pos = 0
    while True:
        offset = payload.find(ELF_MAGIC, pos)
        if offset < 0:
            break
        length = elf_length(payload, offset)
        images.append({"offset": offset, "length": length, "data": payload[offset:offset + length]})
        pos = offset + length

    if not images:
        # Some closure members are virtual packages: the driver is built into the
        # kernel, so the package only carries /etc/modules.d snippets and an
        # "<name>-any" provide. They are legitimate, but a package that lists a
        # module path and ships no ELF image is not.
        strings = payload_strings(payload)
        if any(item.startswith(MODULE_PREFIX) and item.endswith(".ko") for item in strings):
            raise PackageError(f"{path.name}: file table lists modules but the payload has no ELF image")
        name, version = split_package_name(path.name.removesuffix(".apk"))
        return {
            "package": name,
            "version": version,
            "kind": "virtual",
            "modules": [],
            "module_snippets": [item for item in strings if item.startswith("/etc/modules")],
            "provides": [item for item in strings if item.endswith("-any")],
        }

    paths = listed_module_paths(payload, images[0]["offset"])
    modules = []
    for index, image in enumerate(images):
        info = elf_modinfo(payload, image["offset"])
        name = info.get("name", "")
        if not name:
            raise PackageError(f"{path.name}: ELF image {index} has no name= in .modinfo")
        if index < len(paths):
            module_path = paths[index]
        else:
            module_path = f"{MODULE_PREFIX}{kver or 'unknown'}/{name}.ko"
        listed = module_path.rsplit("/", 1)[-1][: -len(".ko")]
        if canonical(listed) != canonical(name):
            print(
                f"[apk_extract] warning: {path.name}: file table says {listed!r} but "
                f".modinfo says {name!r}; keeping the file table name",
                file=sys.stderr,
            )
        vermagic = info.get("vermagic", "")
        if kver and kver not in vermagic:
            raise PackageError(
                f"{path.name}: {name} vermagic {vermagic!r} does not match kernel {kver}"
            )
        modules.append(
            {
                "path": module_path,
                "size": len(image["data"]),
                "sha256": hashlib.sha256(image["data"]).hexdigest(),
                "name": name,
                "vermagic": vermagic,
                "data": image["data"],
            }
        )
    name, version = split_package_name(path.name.removesuffix(".apk"))
    return {
        "package": name,
        "version": version,
        "kind": "modules",
        "modules": modules,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, help="destination directory")
    parser.add_argument("--kver", default=None, help="expected kernel version, asserted in vermagic")
    parser.add_argument("--json-out", default=None, help="write the inventory here instead of stdout")
    parser.add_argument("apks", nargs="+", help="apk files to unpack")
    args = parser.parse_args(argv[1:])

    out_dir = Path(args.out)
    inventory = []
    failures = 0
    for apk in args.apks:
        path = Path(apk)
        try:
            result = extract_package(path, args.kver)
        except PackageError as exc:
            print(f"[apk_extract] ERROR: {exc}", file=sys.stderr)
            failures += 1
            continue
        for module in result["modules"]:
            target = out_dir / module["path"].lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(module.pop("data"))
        inventory.append(result)
        if result["kind"] == "virtual":
            print(
                f"[apk_extract] {result['package']}: virtual package, driver is built into "
                f"the kernel ({', '.join(result['provides']) or 'no provide recorded'})",
                file=sys.stderr,
            )

    # Drop the payload bytes before serialising.
    text = json.dumps(inventory, indent=2, sort_keys=True)
    if args.json_out:
        Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    else:
        print(text)

    total = sum(len(item["modules"]) for item in inventory)
    print(
        f"[apk_extract] {len(inventory)} package(s), {total} module(s), {failures} failure(s)",
        file=sys.stderr,
    )
    return 1 if failures or not inventory else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
