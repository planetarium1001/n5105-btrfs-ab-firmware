#!/usr/bin/env python3
"""设计一致性检查。

把 docs/ 里写下的阈值、几何与契约变成可执行断言，避免"文档说一套、实现另一套"。
每个子命令对应 PRD 的一条验收；不带参数时全部运行。

用法：
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


class Problems(list):
    def add(self, where: str, message: str) -> None:
        self.append(f"{where}: {message}")

    def need(self, where: str, text: str, *needles: str) -> None:
        for needle in needles:
            if needle not in text:
                self.add(where, f"缺少必需内容 {needle!r}")

    def forbid(self, where: str, text: str, *needles: str) -> None:
        for needle in needles:
            if needle in text:
                self.add(where, f"出现禁止内容 {needle!r}")


def read_doc(name: str, problems: Problems) -> str:
    path = DOCS / name
    if not path.is_file():
        problems.add(name, "文档不存在")
        return ""
    return path.read_text(encoding="utf-8")


def check_partitions(problems: Problems) -> None:
    doc = read_doc("partitions.md", problems)
    problems.need(
        "partitions.md",
        doc,
        "| p1 | `wf-esp` | 128 MiB | vfat |",
        "| p2 | `wf-slot-a` | 128 MiB | btrfs |",
        "| p3 | `wf-slot-b` | 128 MiB | btrfs |",
        "| p4 | `wf-shared` | 至盘尾 | btrfs |",
        str(MEASURED_ROOTFS_MIB),
        "zstd:6",
        "mkfs.btrfs -m dup -d single",
        "mkfs.btrfs -m single -d single",
        "@sys",
        "@wf",
        "@overlay.genNNNN",
        "@docker",
        "@swap",
        "@data",
        "全部为顶级子卷",
        "sfdisk",
        "btrfs filesystem resize max",
    )

    ratio = SLOT_MIB / MEASURED_ROOTFS_MIB
    if ratio < MIN_SLOT_RATIO:
        problems.add(
            "partitions.md",
            f"槽容量余量 {ratio:.1f}x 低于下限 {MIN_SLOT_RATIO}x",
        )


def check_esp_data_only(problems: Problems) -> None:
    doc = read_doc("partitions.md", problems)
    problems.need("partitions.md", doc, "p1 只放数据，不放可执行脚本")

    p1_row = next(
        (line for line in doc.splitlines() if line.startswith("| p1 ")),
        "",
    )
    if not p1_row:
        problems.add("partitions.md", "找不到 p1 表格行")
        return
    problems.forbid("partitions.md", p1_row, ".sh", "ab-slot", "busybox", "/usr/")
    problems.need("partitions.md", p1_row, "ab/")

    boot = read_doc("boot-overlay.md", problems)
    problems.need("boot-overlay.md", boot, "@wf", "降级", "tmpfs")


def check_overlay_layers(problems: Problems) -> None:
    doc = read_doc("boot-overlay.md", problems)
    problems.need(
        "boot-overlay.md",
        doc,
        "lowerdir=/mnt/wf:/mnt/sys",
        "upperdir=/mnt/p4/@overlay.gen",
        "workdir=/mnt/p4/@overlay.gen",
        "index=off",
        "先挂 p4",
        "平台层优先",
        "/etc/init.d/ab-commit",
        "/usr/sbin/ab-slot",
        "compress=",
    )
    problems.need("boot-overlay.md", doc, "不使用 `volatile`")


def check_generation_model(problems: Problems) -> None:
    doc = read_doc("lifecycle.md", problems)
    problems.need(
        "lifecycle.md",
        doc,
        "@overlay.genNNNN",
        "全程不做重命名",
        '"generation"',
        '"committed"',
        '"pending"',
        '"upper_gen"',
        "snapshot gen2 → gen3",
        "一直不重启",
    )


def check_gc_policy(problems: Problems) -> None:
    doc = read_doc("lifecycle.md", problems)
    problems.need(
        "lifecycle.md",
        doc,
        "引用集合",
        "挂载中的代号不删",
        "`pending` 引用的代号不删",
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
        "stage=",
        "probe=",
        "reason=",
        "action=",
        "超过 8 次",
    )


def check_conflict_model(problems: Problems) -> None:
    doc = read_doc("conflicts-payload.md", problems)
    problems.need(
        "conflicts-payload.md",
        doc,
        "UpstreamChanged",
        "UserChanged",
        "Conflicts",
        "内容哈希",
        "whiteout",
        "不阻断",
        "uci-defaults",
        "保留 `U`",
        "采用 `B`",
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


def _md_files() -> list[Path]:
    files = [ROOT / "README.md"]
    files.extend(sorted(DOCS.glob("*.md")))
    return [path for path in files if path.is_file()]


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
            resolved = (path.parent / clean).resolve()
            if not resolved.exists():
                problems.add(rel, f"链接无法解析 {target!r}")


PLACEHOLDERS = ("TODO", "TBD", "FIXME", "XXX", "待填")
SELF = Path(__file__).resolve()


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
            problems.add(rel, "文件为空")
            continue
        for marker in PLACEHOLDERS:
            if marker in text:
                problems.add(rel, f"残留占位标记 {marker!r}")
        if path.suffix == ".md" and "\t" in text:
            problems.add(rel, "含制表符")


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
        except Exception as exc:  # noqa: BLE001 - 报告而非崩溃
            problems.add(key, f"检查抛出异常 {exc!r}")
        status = "ok" if len(problems) == before else "fail"
        print(f"[{status}] {key}")

    if problems:
        print()
        for item in problems:
            print(f"  - {item}")
        print(f"\n{len(problems)} 个问题")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
