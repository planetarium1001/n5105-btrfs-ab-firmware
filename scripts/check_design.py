#!/usr/bin/env python3
"""Design consistency checks.

Turns the thresholds, geometry and contracts written in docs/ into executable
assertions, so documentation and intent cannot drift apart.

Each subcommand maps to one acceptance criterion in the PRD. Running without an
argument executes every check.

Usage:
    python3 scripts/check_design.py partitions
    python3 scripts/check_design.py all
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"

P1_MIB = 128
SLOT_MIB = 128
MEASURED_ROOTFS_MIB = 26.9
MIN_SLOT_RATIO = 4.0
ZH_SUFFIX = ".zh-CN.md"

SELF = Path(__file__).resolve()


TOKEN_CHARS = r"\w\-"


def token_pattern(needle: str) -> re.Pattern:
    """Match a needle at token boundaries.

    Plain substring matching is too weak: "20 MiB" would match inside "120 MiB"
    and "btrfs subvolume sync" would match inside "btrfs subvolume syncx".
    Boundaries are only applied where the needle starts or ends with a token
    character, so literals such as markdown table rows keep working.
    """
    left = f"(?<![{TOKEN_CHARS}])" if re.match(r"[\w\-]", needle[0]) else ""
    right = f"(?![{TOKEN_CHARS}])" if re.match(r"[\w\-]", needle[-1]) else ""
    return re.compile(left + re.escape(needle) + right)


class Problems(list):
    def add(self, where: str, message: str) -> None:
        self.append(f"{where}: {message}")

    def need(self, where: str, text: str, *needles: str) -> None:
        for needle in needles:
            if not token_pattern(needle).search(text):
                self.add(where, f"missing required content {needle!r}")

    def need_prefix(self, where: str, text: str, *needles: str) -> None:
        """Prefix match for values with a variable tail, such as @overlay-25.12.2."""
        for needle in needles:
            if needle not in text:
                self.add(where, f"missing required content prefix {needle!r}")

    def forbid(self, where: str, text: str, *needles: str) -> None:
        for needle in needles:
            if token_pattern(needle).search(text):
                self.add(where, f"contains forbidden content {needle!r}")


def read_doc(name: str, problems: Problems) -> str:
    path = DOCS / name
    if not path.is_file():
        problems.add(name, "document does not exist")
        return ""
    return path.read_text(encoding="utf-8")


RETIRED_TOKENS = ("@wf", "genNNNN", "upper_gen", "wf-esp", "wf-slot", "wf-shared",
                  "@overlay.<version>", "@overlay.")


def check_retired_tokens(problems: Problems) -> None:
    """Names retired in favour of @platform and version-named layers."""
    for name in ("README.md", "README.zh-CN.md", "partitions.md", "boot-overlay.md",
                 "lifecycle.md", "conflicts-payload.md"):
        path = DOCS / name if (DOCS / name).is_file() else ROOT / name
        if not path.is_file():
            continue
        problems.forbid(name, path.read_text(encoding="utf-8"), *RETIRED_TOKENS)


def check_partitions(problems: Problems) -> None:
    doc = read_doc("partitions.md", problems)
    problems.need(
        "partitions.md",
        doc,
        "| p1 | `ab-esp` | 128 MiB | vfat |",
        "| p2 | `ab-slot-a` | 128 MiB | btrfs |",
        "| p3 | `ab-slot-b` | 128 MiB | btrfs |",
        "| p4 | `ab-shared` | rest of disk | btrfs |",
        "26.9 MiB",
        "zstd:6",
        "mkfs.btrfs -m dup -d single",
        "mkfs.btrfs -m single -d single",
        "@sys",
        "@platform",
        "@overlay-<version>",
        "@docker",
        "@swap",
        "@data",
        "All subvolumes are top-level",
        "sfdisk",
        "btrfs filesystem resize max",
    )

    ratio = SLOT_MIB / MEASURED_ROOTFS_MIB
    if ratio < MIN_SLOT_RATIO:
        problems.add(
            "partitions.md",
            f"slot headroom {ratio:.1f}x is below the {MIN_SLOT_RATIO}x floor",
        )


def check_esp_data_only(problems: Problems) -> None:
    doc = read_doc("partitions.md", problems)
    problems.need("partitions.md", doc, "p1 holds data only, never executable scripts")

    p1_row = next((line for line in doc.splitlines() if line.startswith("| p1 ")), "")
    if not p1_row:
        problems.add("partitions.md", "p1 table row not found")
    else:
        problems.forbid("partitions.md", p1_row, ".sh", "ab-slot", "busybox", "/usr/")
        problems.need("partitions.md", p1_row, "ab/")

    boot = read_doc("boot-overlay.md", problems)
    problems.need("boot-overlay.md", boot, "@platform", "degraded", "tmpfs")


def check_overlay_layers(problems: Problems) -> None:
    doc = read_doc("boot-overlay.md", problems)
    problems.need(
        "boot-overlay.md",
        doc,
        "lowerdir=/mnt/@platform:/mnt/@sys",
        "index=off",
        "the platform layer takes precedence",
        "p4 is mounted first",
        "compress=",
        "/usr/sbin/ab-slot",
        "/etc/init.d/ab-commit",
        "the `volatile` option is never used",
    )
    problems.need_prefix(
        "boot-overlay.md",
        doc,
        "upperdir=/mnt/p4/@overlay-",
        "workdir=/mnt/p4/@overlay-",
    )


def check_generation_model(problems: Problems) -> None:
    doc = read_doc("lifecycle.md", problems)
    problems.need(
        "lifecycle.md",
        doc,
        "@overlay-<version>",
        "no subvolume is ever renamed",
        '"generation"',
        '"committed"',
        '"pending"',
        '"upper"',
        "snapshot @overlay-25.12.2 -> @overlay-25.12.3",
        "has never rebooted",
    )


def check_gc_policy(problems: Problems) -> None:
    doc = read_doc("lifecycle.md", problems)
    problems.need(
        "lifecycle.md",
        doc,
        "The reference set",
        "never delete a layer that is currently mounted",
        "never delete the layer referenced by the pending slot",
        "btrfs subvolume delete -C",
        "btrfs subvolume sync",
        "balance",
        "15%",
        "5%",
        "74",
        "ab-slot gc",
    )


def check_log_ring(problems: Problems) -> None:
    doc = read_doc("lifecycle.md", problems)
    problems.need(
        "lifecycle.md",
        doc,
        "boot-0.log",
        "boot-1.log",
        "boot-2.log",
        "upgrade.log",
        "conflicts.log",
        "32 KiB",
        "350 KiB",
        "rename",
        "at most 8 writes per boot",
        "stage=",
        "probe=",
        "reason=",
        "action=",
    )


def check_conflict_model(problems: Problems) -> None:
    doc = read_doc("conflicts-payload.md", problems)
    problems.need(
        "conflicts-payload.md",
        doc,
        "UpstreamChanged",
        "UserChanged",
        "Conflicts",
        "content hashes",
        "whiteout",
        "never block",
        "uci-defaults",
        "keep `U`",
        "take `B`",
    )


def check_payload_contract(problems: Problems) -> None:
    doc = read_doc("conflicts-payload.md", problems)
    problems.need(
        "conflicts-payload.md",
        doc,
        "rootfs.tar.gz",
        "kernel.bin",
        "initramfs.cpio.gz",
        "wf.tar",
        "manifest.json",
        "kmod-fs-btrfs",
        "20 MiB",
        "adapter",
        "selfbuild",
        "74",
        "CONFIG_KERNEL_BTRFS_FS",
        "vermagic",
    )


LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^## ", re.MULTILINE)


def _md_files() -> list[Path]:
    files = [ROOT / "README.md", ROOT / "README.zh-CN.md"]
    files.extend(sorted(DOCS.glob("*.md")))
    return [path for path in files if path.is_file()]


def _primary_docs() -> list[Path]:
    return [
        path
        for path in sorted(DOCS.glob("*.md"))
        if not path.name.endswith(ZH_SUFFIX)
    ]


def check_links(problems: Problems) -> None:
    for path in _md_files():
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT).as_posix()
        for target in LINK_RE.findall(text):
            target = target.strip()
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            clean = target.split("#", 1)[0]
            if not clean:
                continue
            if not (path.parent / clean).resolve().exists():
                problems.add(rel, f"unresolved link {target!r}")

    for primary in _primary_docs():
        translation = primary.with_name(primary.name[: -len(".md")] + ZH_SUFFIX)
        if not translation.is_file():
            problems.add(primary.name, "missing Chinese translation")
            continue
        left = len(HEADING_RE.findall(primary.read_text(encoding="utf-8")))
        right = len(HEADING_RE.findall(translation.read_text(encoding="utf-8")))
        if left != right:
            problems.add(
                translation.name,
                f"section count differs from {primary.name}: {right} vs {left}",
            )


PLACEHOLDERS = ("TODO", "TBD", "FIXME", "XXX", "待填")


def check_text(problems: Problems) -> None:
    targets = _md_files()
    targets.extend(sorted((ROOT / "LICENSES").glob("*")))
    targets.extend(sorted((ROOT / "scripts").glob("*.py")))
    for path in targets:
        if not path.is_file() or path.resolve() == SELF:
            continue
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        if not text.strip():
            problems.add(rel, "file is empty")
            continue
        for marker in PLACEHOLDERS:
            if marker in text:
                problems.add(rel, f"placeholder marker {marker!r} left behind")
        if path.suffix == ".md" and "\t" in text:
            problems.add(rel, "contains tab characters")


CHECKS = {
    "partitions": check_partitions,
    "esp-data-only": check_esp_data_only,
    "overlay-layers": check_overlay_layers,
    "generation-model": check_generation_model,
    "gc-policy": check_gc_policy,
    "log-ring": check_log_ring,
    "conflict-model": check_conflict_model,
    "payload-contract": check_payload_contract,
    "links": check_links,
    "text": check_text,
    "retired-names": check_retired_tokens,
}


def main(argv: list[str]) -> int:
    name = argv[1] if len(argv) > 1 else "all"
    if name in ("-h", "--help"):
        print(__doc__)
        return 0
    if name != "all" and name not in CHECKS:
        print(f"unknown check: {name}", file=sys.stderr)
        print("available: all, " + ", ".join(CHECKS), file=sys.stderr)
        return 2

    problems = Problems()
    selected = CHECKS if name == "all" else {name: CHECKS[name]}
    for key, func in selected.items():
        before = len(problems)
        try:
            func(problems)
        except Exception as exc:  # noqa: BLE001 - report instead of crashing
            problems.add(key, f"check raised {exc!r}")
        print(f"[{'ok' if len(problems) == before else 'fail'}] {key}")

    if problems:
        print()
        for item in problems:
            print(f"  - {item}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
