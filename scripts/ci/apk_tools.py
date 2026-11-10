#!/usr/bin/env python3
"""Resolve, lock and install the foreign programs an initramfs carries.

The initramfs runs before the platform layer is mounted, so it needs its own copy of
busybox, the partition tools and their libraries. Those programs come from the same
ImmortalWrt release as the rest of the image, and this tool is the only place that
decides which package supplies which file:

  lock     resolve the packages of one upstream release, extract them, resolve the
           DT_NEEDED closure of the required programs, and write the lockfile
           (package version, .apk sha256, per-file path/mode/sha256, symlinks).
           A maintenance command: run it when CI_UPSTREAM_VERSION_PIN is bumped.
  install  verify every .apk and every extracted file against the lockfile and
           install them into a staging tree. Any drift is a hard error that names the
           offending file; there is no fallback to host programs.

Extraction reuses elf_extract.py, so the same ADBd container reader and the same ELF
walker serve the runtime closure and the initramfs toolset.

Usage:
    apk_tools.py lock    --lock FILE [--base-url URL] [--upstream-version V] [--work DIR]
    apk_tools.py install --lock FILE --stage DIR --toolset NAME --apk-dir DIR [--dry-run]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import elf_extract  # noqa: E402  (kept next to this tool for exactly this reuse)

SCHEMA = 1
DEFAULT_BASE_URL = "https://downloads.immortalwrt.org"

# Feed directories, relative to the release root. "base" and "packages" are the
# architecture feeds; "target" carries the libc, which ImmortalWrt ships with the
# target rather than as a normal package.
FEEDS = {
    "base": "packages/x86_64/base",
    "packages": "packages/x86_64/packages",
    "target": "targets/x86/64/packages",
}

# Candidate packages: everything `lock` is allowed to pull, so extending the closure
# is a one-line change here instead of a guess at build time.
CANDIDATES = (
    ("busybox", "base"),
    ("libc", "target"),
    ("libgcc1", "target"),
    ("kmod", "packages"),
    ("sfdisk", "base"),
    ("blkid", "base"),
    ("blockdev", "base"),
    ("btrfs-progs", "packages"),
    ("libfdisk1", "base"),
    ("libblkid1", "base"),
    ("libuuid1", "base"),
    ("libsmartcols1", "base"),
    ("libncurses6", "base"),
    ("zlib", "base"),
    ("liblzo2", "packages"),
    ("libzstd", "packages"),
    ("libmount1", "base"),
)

# Programs the initramfs executes. `marker` picks the right image out of a package
# that ships several (btrfs-progs publishes three), and `provides` names a DT_NEEDED
# soname for an image that carries no DT_SONAME of its own - musl's libc.so is that
# case, and every dynamically linked program in the toolset asks for "libc.so".
REQUIRED = (
    {"package": "busybox", "path": "/bin/busybox", "marker": b"BusyBox", "provides": ()},
    {"package": "libc", "path": "/lib/libc.so", "marker": b"musl", "provides": ("libc.so",)},
    {"package": "kmod", "path": "/sbin/kmod", "marker": b"modprobe", "provides": ()},
    {"package": "sfdisk", "path": "/usr/sbin/sfdisk", "marker": b"sfdisk", "provides": ()},
    {"package": "blkid", "path": "/usr/sbin/blkid", "marker": b"blkid", "provides": ()},
    {"package": "blockdev", "path": "/usr/sbin/blockdev", "marker": b"blockdev", "provides": ()},
    {"package": "btrfs-progs", "path": "/usr/sbin/btrfs", "marker": b"filesystem resize", "provides": ()},
)

# Which programs each initramfs flavour carries: "probe" is the S1 module-load probe
# (no partition work), "boot" is the production init, and "assert" is the S2 guest
# assertion, which inspects the produced image and therefore needs the same tools.
TOOLSETS = {
    "probe": ("busybox", "libc", "kmod"),
    "boot": ("busybox", "libc", "kmod", "sfdisk", "blkid", "blockdev", "btrfs-progs"),
}
TOOLSETS["assert"] = TOOLSETS["boot"]

# Symlinks the packages do not carry but the runtime needs: the musl loader is a
# symlink to libc.so in the upstream root filesystem, and the kmod applets are
# published upstream as `alternatives` of the /sbin/kmod multicall binary.
EXTRA_LINKS = (
    {"package": "libc", "path": "/lib/ld-musl-x86_64.so.1", "target": "/lib/libc.so"},
    {"package": "kmod", "path": "/sbin/insmod", "target": "/sbin/kmod"},
    {"package": "kmod", "path": "/sbin/modprobe", "target": "/sbin/kmod"},
    {"package": "kmod", "path": "/sbin/lsmod", "target": "/sbin/kmod"},
    {"package": "kmod", "path": "/sbin/rmmod", "target": "/sbin/kmod"},
)

# Applets the initramfs scripts and the guest assertions call by name. `lock` fails
# when the busybox package stops providing one of them, and the initramfs links
# exactly the applets the package advertises, so a new applet needs no shell change.
REQUIRED_APPLETS = (
    "[", "ash", "awk", "basename", "cat", "chmod", "cmp", "cp", "cut", "date", "dd",
    "dmesg", "dirname", "echo", "egrep", "env", "expr", "false", "fgrep", "find",
    "flock", "free", "grep", "gunzip", "gzip", "head", "hexdump", "id", "kill",
    "killall", "less", "ln", "ls", "md5sum", "mkdir", "mkfifo", "mknod", "mktemp",
    "mount", "mv", "pidof", "pivot_root", "poweroff", "printf", "ps", "pwd",
    "readlink", "reboot", "rm", "rmdir", "sed", "seq", "sh", "sha256sum", "sleep",
    "sort", "strings", "switch_root", "sync", "sysctl", "tail", "tar", "tee", "test",
    "top", "touch", "tr", "true", "umount", "uname", "uniq", "uptime", "wc", "which",
    "xargs", "yes",
)

INSTALL_PATH_RE = re.compile(r"^/(bin|sbin|usr/bin|usr/sbin|usr/lib|lib)/[A-Za-z0-9._+-]+$")


class ToolError(RuntimeError):
    """The lockfile, a package or an installed file does not match the contract."""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version_key(file_name: str) -> tuple:
    """Sort key for package file names: numeric parts compare numerically."""
    return tuple(
        (0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in re.split(r"[._~+-]", file_name)
    )


def split_apk_name(file_name: str) -> tuple[str, str]:
    """``sfdisk-2.41.5-r1.apk`` -> ``("sfdisk", "2.41.5-r1")``.

    A feed also publishes packages whose names do not carry an ``-rN`` revision
    (``464xlat-13.apk``, ``adb-5.0.2~6fe92d1a-r3.apk``); those are not part of any
    candidate and are skipped by the caller, so they never reach this function.
    """
    stem = file_name.removesuffix(".apk")
    match = re.match(r"^(?P<name>.+?)-(?P<version>[0-9][^-]*-r[0-9]+)$", stem)
    if not match:
        raise ToolError(f"cannot split package name and version: {file_name}")
    return match.group("name"), match.group("version")


def candidate_files(listing: list[str], name: str) -> list[str]:
    """File names of one package, newest last; unparseable names are skipped."""
    found: list[str] = []
    for file_name in listing:
        try:
            package, _version = split_apk_name(file_name)
        except ToolError:
            continue
        if package == name:
            found.append(file_name)
    return found


def feed_listing(url: str) -> list[str]:
    """The package file names one feed directory publishes."""
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            html = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ToolError(f"cannot read the feed listing {url}: {exc}") from exc
    names = sorted(set(re.findall(r'href="([^"]+\.apk)"', html)))
    if not names:
        raise ToolError(f"the feed listing is empty: {url}")
    return names


def fetch(url: str, dest: Path) -> None:
    """Download the package, always: `lock` records what the feed publishes now, so a
    file left in the work directory from an older release must not become the digest."""

    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    print(f"[apk_tools] download {url}", file=sys.stderr)
    try:
        with urllib.request.urlopen(url, timeout=300) as response, part.open("wb") as handle:
            handle.write(response.read())
    except (urllib.error.URLError, TimeoutError) as exc:
        part.unlink(missing_ok=True)
        raise ToolError(f"download failed: {url}: {exc}") from exc
    part.replace(dest)


def package_images(apk: Path) -> list[dict]:
    """ELF images of one package: soname, DT_NEEDED, sha256 and the bytes."""
    try:
        return elf_extract.images(elf_extract.inflate_adb(apk.read_bytes()))
    except elf_extract.ExtractError as exc:
        raise ToolError(f"{apk.name}: {exc}") from exc


def busybox_applets(apk: Path) -> list[str]:
    """Applet names, read from the sorted applet table inside the busybox image.

    ``busybox --list`` is not an option: the upstream busybox links against musl and
    the build host has no /lib/ld-musl-x86_64.so.1. The applet table is a contiguous
    run of NUL separated names in bytewise order, so the longest sorted run of
    name-like tokens is the table; a stray prefix such as "/proc/self/exe" is dropped
    by taking the longest sorted suffix of that run.
    """
    images = package_images(apk)
    if not images:
        raise ToolError(f"{apk.name}: no ELF image to read the applet table from")
    data = images[0]["data"]
    pattern = re.compile(rb"(?:[A-Za-z0-9_.+\-\[\]]{1,24}\x00){40,}")
    best: list[str] = []
    for match in pattern.finditer(data):
        tokens = [token.decode() for token in match.group(0).split(b"\x00")[:-1]]
        for start in range(len(tokens) - 40):
            suffix = tokens[start:]
            if suffix == sorted(suffix) and len(suffix) > len(best):
                best = suffix
    if not best:
        raise ToolError(f"{apk.name}: cannot locate the applet name table")
    missing = sorted(set(REQUIRED_APPLETS) - set(best))
    if missing:
        raise ToolError(
            f"{apk.name}: the applet table lost {', '.join(missing)}; "
            "the initramfs scripts call them by name"
        )
    return best


def exec_image(images: list[dict], spec: dict) -> dict:
    """The image of a package that the marker string identifies, which must be one."""
    matches = [image for image in images if spec["marker"] in image["data"]]
    if len(matches) != 1:
        raise ToolError(
            f"{spec['package']}: {len(matches)} image(s) contain {spec['marker']!r}, "
            f"expected exactly one for {spec['path']}"
        )
    return matches[0]


def resolve_closure(metadata: dict, members) -> dict[tuple[str, str], dict]:
    """Follow DT_NEEDED from one toolset's programs to a fixed point.

    The result is every image that toolset can possibly need, keyed by package and
    sha256; a soname nothing in CANDIDATES provides is a hard error rather than a
    missing library discovered inside the guest. Resolving per toolset keeps the S1
    probe from carrying the partition tools it never runs.
    """
    providers: dict[str, tuple[str, dict]] = {}
    for package, entry in metadata.items():
        for image in entry["images"]:
            if image["soname"]:
                providers.setdefault(image["soname"], (package, image))
    specs = [spec for spec in REQUIRED if spec["package"] in members]
    for spec in specs:
        if spec["provides"]:
            image = exec_image(metadata[spec["package"]]["images"], spec)
            for soname in spec["provides"]:
                providers.setdefault(soname, (spec["package"], image))

    resolved: dict[tuple[str, str], dict] = {}
    queue = [(spec["package"], exec_image(metadata[spec["package"]]["images"], spec))
             for spec in specs]
    while queue:
        package, image = queue.pop()
        key = (package, image["sha256"])
        if key in resolved:
            continue
        resolved[key] = image
        for soname in image["needed"]:
            if soname not in providers:
                raise ToolError(
                    f"{package}: nothing in CANDIDATES provides {soname}; "
                    "add the package that ships it"
                )
            queue.append(providers[soname])
    return resolved


def install_path(package: str, image: dict) -> tuple[str, str]:
    """(install path, mode): shared objects by soname, programs by REQUIRED."""
    if image["soname"]:
        return f"/lib/{image['soname']}", "0644"
    for spec in REQUIRED:
        if spec["package"] == package and spec["marker"] in image["data"]:
            return spec["path"], "0755"
    raise ToolError(f"{package}: no install path for image {image['sha256'][:12]}")


def cmd_lock(args) -> int:
    base_url = args.base_url.rstrip("/")
    release = f"{base_url}/releases/{args.upstream_version}"
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)

    listings = {feed: feed_listing(f"{release}/{path}/") for feed, path in FEEDS.items()}
    metadata: dict[str, dict] = {}
    for name, feed in CANDIDATES:
        published = candidate_files(listings[feed], name)
        if not published:
            raise ToolError(f"the {feed} feed publishes no {name} package")
        file_name = max(published, key=version_key)
        apk = work / file_name
        fetch(f"{release}/{FEEDS[feed]}/{file_name}", apk)
        images = package_images(apk)
        if not images:
            raise ToolError(f"{file_name}: no ELF image in the payload")
        metadata[name] = {
            "feed": feed,
            "file": file_name,
            "version": split_apk_name(file_name)[1],
            "apk_sha256": sha256_file(apk),
            "images": images,
        }

    applets = busybox_applets(work / metadata["busybox"]["file"])

    # One closure per toolset, merged into a package record that remembers which
    # toolset needs which file: the probe must not ship sfdisk's 1.2 MiB of libraries.
    packages: dict[str, dict] = {}
    for toolset, members in TOOLSETS.items():
        for (package, _sha), image in resolve_closure(metadata, members).items():
            entry = metadata[package]
            record = packages.setdefault(package, {
                "name": package,
                "feed": entry["feed"],
                "file": entry["file"],
                "version": entry["version"],
                "apk_sha256": entry["apk_sha256"],
                "toolsets": [],
                "files": [],
                "links": [],
            })
            path, mode = install_path(package, image)
            file_record = next(
                (item for item in record["files"] if item["path"] == path), None
            )
            if file_record is None:
                file_record = {
                    "kind": "shared" if image["soname"] else "exec",
                    "path": path,
                    "mode": mode,
                    "size": image["length"],
                    "sha256": image["sha256"],
                    "toolsets": [],
                }
                record["files"].append(file_record)
            if toolset not in file_record["toolsets"]:
                file_record["toolsets"].append(toolset)

    for record in packages.values():
        record["files"].sort(key=lambda item: item["path"])
        record["toolsets"] = sorted({
            toolset for item in record["files"] for toolset in item["toolsets"]
        })
        for item in record["files"]:
            item["toolsets"] = sorted(item["toolsets"])
    for link in EXTRA_LINKS:
        if link["package"] in packages:
            packages[link["package"]]["links"].append(
                {"path": link["path"], "target": link["target"]}
            )
    if "busybox" in packages:
        packages["busybox"]["links"].extend(
            {"path": f"/bin/{applet}", "target": "/bin/busybox"} for applet in applets
        )
    for record in packages.values():
        record["links"].sort(key=lambda item: item["path"])

    lock = {
        "schema": SCHEMA,
        "generated_by": "scripts/ci/apk_tools.py lock",
        "upstream_version": args.upstream_version,
        "feeds": FEEDS,
        "toolsets": {name: sorted(members) for name, members in TOOLSETS.items()},
        "required_applets": sorted(REQUIRED_APPLETS),
        "applets": applets,
        "notes": [
            "Every program and library the initramfs carries comes from this release's feeds.",
            "Digests are recorded from what the feed publishes; a drift is a build failure.",
            "The applet table is read from the busybox image, not from the build host.",
        ],
        "packages": [packages[name] for name in sorted(packages)],
    }
    lock_path = Path(args.lock)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    total = sum(item["size"] for record in lock["packages"] for item in record["files"])
    print(
        f"[apk_tools] wrote {lock_path}: {len(lock['packages'])} package(s), "
        f"{sum(len(record['files']) for record in lock['packages'])} file(s), "
        f"{total} bytes, {len(applets)} applet(s)",
        file=sys.stderr,
    )
    for record in lock["packages"]:
        print(
            f"[apk_tools]   {record['name']} {record['version']} ({record['feed']}) "
            f"{len(record['files'])} file(s) toolsets={'/'.join(record['toolsets'])}",
            file=sys.stderr,
        )
    return 0


def load_lock(path: Path) -> dict:
    try:
        lock = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ToolError(f"cannot read the lockfile {path}: {exc}") from exc
    if lock.get("schema") != SCHEMA:
        raise ToolError(f"{path}: unsupported lockfile schema {lock.get('schema')!r}")
    return lock


def selected_packages(lock: dict, toolset: str) -> list[dict]:
    if toolset not in lock["toolsets"]:
        raise ToolError(
            f"unknown toolset {toolset!r}; "
            f"the lockfile knows {', '.join(sorted(lock['toolsets']))}"
        )
    # Selection is per file, not per program: the libraries a toolset needs are
    # recorded on the file entry, and they belong to packages the program list never
    # names (libfdisk1, libncurses6, ...).
    chosen = [record for record in lock["packages"] if toolset in record.get("toolsets", [])]
    missing = sorted(set(lock["toolsets"][toolset]) - {record["name"] for record in chosen})
    if missing:
        raise ToolError(f"the lockfile has no entry for: {', '.join(missing)}")
    return chosen


def cmd_install(args) -> int:
    lock = load_lock(Path(args.lock))
    if args.upstream_version and args.upstream_version != lock["upstream_version"]:
        raise ToolError(
            f"the lockfile is pinned to {lock['upstream_version']} but the build asks for "
            f"{args.upstream_version}; regenerate it with `apk_tools.py lock`"
        )
    stage = Path(args.stage)
    apk_dir = Path(args.apk_dir)
    if not args.dry_run:
        stage.mkdir(parents=True, exist_ok=True)

    installed: list[tuple[str, str]] = []
    report: list[dict] = []
    for record in selected_packages(lock, args.toolset):
        apk = apk_dir / record["file"]
        if not apk.is_file():
            raise ToolError(f"missing package file: {apk}")
        digest = sha256_file(apk)
        if digest != record["apk_sha256"]:
            raise ToolError(
                f"{record['file']}: sha256 {digest} does not match the lockfile "
                f"({record['apk_sha256']}); the feed moved or the lockfile is stale"
            )
        images = {image["sha256"]: image for image in package_images(apk)}
        for item in record["files"]:
            if args.toolset not in item["toolsets"]:
                continue
            if not INSTALL_PATH_RE.match(item["path"]):
                raise ToolError(f"{record['file']}: refusing to install at {item['path']}")
            image = images.get(item["sha256"])
            if image is None:
                raise ToolError(
                    f"{record['file']}: no image matches {item['path']} "
                    f"(sha256 {item['sha256'][:12]}); the lockfile is stale"
                )
            if not args.dry_run:
                target = stage / item["path"].lstrip("/")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(image["data"])
                target.chmod(int(item["mode"], 8))
                after = sha256_file(target)
                if after != item["sha256"]:
                    raise ToolError(f"{item['path']}: installed sha256 {after} drifted")
            installed.append((item["path"], item["sha256"]))
            report.append({
                "package": record["name"],
                "version": record["version"],
                "path": item["path"],
                "sha256": item["sha256"],
                "size": item["size"],
            })
        for link in record["links"]:
            if args.dry_run:
                continue
            link_path = stage / link["path"].lstrip("/")
            link_path.parent.mkdir(parents=True, exist_ok=True)
            link_path.unlink(missing_ok=True)
            same_dir = Path(link["path"]).parent == Path(link["target"]).parent
            link_path.symlink_to(
                Path(link["target"]).name if same_dir else link["target"]
            )

    digest = hashlib.sha256(
        "\n".join(f"{path} {sha}" for path, sha in sorted(installed)).encode()
    ).hexdigest()
    for item in report:
        print(
            f"[apk_tools] tool {item['path']}: {item['version']} "
            f"sha256={item['sha256'][:12]} ({item['package']})",
            file=sys.stderr,
        )
    print(
        f"[apk_tools] toolset {args.toolset}: {len(report)} file(s), "
        f"digest {digest[:12]}{' (dry run)' if args.dry_run else ''}",
        file=sys.stderr,
    )
    print(json.dumps({
        "toolset": args.toolset,
        "digest": digest,
        "files": len(report),
        "bytes": sum(item["size"] for item in report),
        "versions": sorted({f"{item['package']}={item['version']}" for item in report}),
    }, sort_keys=True))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    lock = sub.add_parser("lock", help="write the lockfile for one upstream release")
    lock.add_argument("--lock", required=True)
    lock.add_argument("--base-url", default=DEFAULT_BASE_URL)
    # No default: the release comes from CI_UPSTREAM_VERSION_PIN via initramfs-tools.sh,
    # and a second copy of that pin is a second source of truth waiting to drift.
    lock.add_argument("--upstream-version", required=True)
    lock.add_argument("--work", default="/tmp/apk-tools")
    lock.set_defaults(func=cmd_lock)

    install = sub.add_parser("install", help="verify and install one toolset")
    install.add_argument("--lock", required=True)
    install.add_argument("--stage", required=True)
    install.add_argument("--toolset", required=True)
    install.add_argument("--apk-dir", required=True)
    install.add_argument("--upstream-version", default="")
    install.add_argument("--dry-run", action="store_true")
    install.set_defaults(func=cmd_install)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ToolError as exc:
        print(f"[apk_tools] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
