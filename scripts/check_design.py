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
        "| p1 | `ab-esp` | `ESP` | 128 MiB | vfat |",
        "| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs |",
        "| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs |",
        "| p4 | `ab-data` | `data` | 128 MiB | btrfs |",
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
        "the composed root `/` is writable with at least 16 MiB free",
        "probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail> [reason=<token>]",
        "Every probe runs, even after one has failed",
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
        "platform.tar",
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


DEBUG_WORKFLOW = ROOT / ".github" / "workflows" / "ci-debug.yml"
DEBUG_WORKFLOW_REL = ".github/workflows/ci-debug.yml"
SESSION_ACTION = "owenthereal/action-upterm"
# A release tag or a commit sha. A floating major such as `@v3` would let upstream change
# what runs with the runner's credentials without anyone reviewing it.
PINNED_REF_RE = re.compile(r"^(?:v\d+\.\d+\.\d+|[0-9a-f]{40})$")
# The session step is bounded by `timeout-minutes`, and the guest wait by
# `wait-timeout-minutes`; both spellings are accepted so the invariant survives a change of
# action. 360 minutes is the 6-hour job cap, the only ceiling GitHub enforces.
SESSION_DURATION_KEYS = ("max-duration", "timeout-minutes", "wait-timeout-minutes")
MAX_SESSION_MINUTES = 360
ON_LINE_RE = re.compile(r"""^(?:on|"on"|'on'):[ ]*(.*)$""")
TRIGGER_KEY_RE = re.compile(r"^ {2}([A-Za-z_][\w-]*):")


def _trigger_keys(text: str) -> list[str] | None:
    """Top-level keys of the workflow's `on:` block, or None when there is none."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = ON_LINE_RE.match(line)
        if not match:
            continue
        inline = match.group(1).split("#", 1)[0].strip()
        if inline:
            return [part.strip() for part in inline.strip("[]").split(",") if part.strip()]
        keys: list[str] = []
        for follow in lines[index + 1:]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            if not follow.startswith(" "):
                break
            nested = TRIGGER_KEY_RE.match(follow)
            if nested:
                keys.append(nested.group(1))
        return keys
    return None


def _step_lines(lines: list[str], index: int) -> list[str]:
    """Lines of the step holding lines[index]: its `- ` item up to the next sibling."""
    start = index
    while start > 0 and not lines[start].lstrip().startswith("- "):
        start -= 1
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.lstrip().startswith("- ") and len(line) - len(line.lstrip()) <= indent:
            break
        end += 1
    return lines[start:end]

RUNNER_CONTEXT_MESSAGE = (
    "the runner context is only available inside a step, so this expression makes the "
    "whole workflow undispatchable"
)


def _runner_context_problems(text: str) -> list[tuple[int, str]]:
    """(line number, message) for every runner-context expression outside a step.

    GitHub rejects the entire file when the `runner` context appears in a workflow-level
    or job-level key -- dispatch answers "Unrecognized named-value: 'runner'" and the
    workflow is dead while still looking present. That happened to ci-debug.yml: the file
    passed every other check here and nobody could run it.

    Step membership is decided by the item itself, not by a column: a step starts at a
    `- ` list item directly under `steps:` and ends at the next item or at a key that
    belongs to the job again. Anything indented shallower than an item is a job-level or
    workflow-level key.
    """
    found: list[tuple[int, str]] = []
    in_step = False
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            indent = len(line) - len(line.lstrip())
            if indent < 6:
                in_step = False
            elif indent == 6:
                in_step = stripped.startswith("- ")
        if stripped.startswith("#") or "{{" not in line:
            continue
        if re.search(r"\{\{\s*runner[.\[]", line) and not in_step:
            found.append((number, RUNNER_CONTEXT_MESSAGE))
    return found


def check_workflow_expressions(problems: Problems) -> None:
    """No workflow uses a context GitHub does not allow where it is written."""
    workflows = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    if not workflows:
        problems.add(".github/workflows", "no workflows found")
        return
    for path in workflows:
        rel = str(path.relative_to(ROOT))
        for number, message in _runner_context_problems(path.read_text(encoding="utf-8")):
            problems.add(rel, f"line {number}: {message}")


def check_debug_ssh(problems: Problems) -> None:
    """ci-debug.yml stays a manual, bounded, key-gated debugging entry point.

    Three ways this file could quietly stop being safe: a trigger that runs it without
    a human asking, a floating action ref that changes under us, or a session with no
    end. Each is an assertion here rather than a comment in the workflow.
    """
    where = DEBUG_WORKFLOW_REL
    if not DEBUG_WORKFLOW.is_file():
        problems.add(where, "workflow does not exist")
        return
    text = DEBUG_WORKFLOW.read_text(encoding="utf-8")
    lines = text.splitlines()

    triggers = _trigger_keys(text)
    if triggers is None:
        problems.add(where, "missing a top-level on: block")
    elif triggers != ["workflow_dispatch"]:
        problems.add(
            where,
            f"must be triggered by workflow_dispatch only, found {triggers}",
        )

    if not re.search(r"^permissions:\s*$", text, re.MULTILINE):
        problems.add(where, "missing an explicit top-level permissions block")
    if re.search(r":\s*(?:write|write-all)\b", text):
        problems.add(where, "grants a write permission")

    uses_index = next((i for i, line in enumerate(lines) if SESSION_ACTION + "@" in line), None)
    if uses_index is None:
        problems.add(where, f"no step uses {SESSION_ACTION}")
        return
    ref = lines[uses_index].split(SESSION_ACTION + "@", 1)[1].split()[0].strip("'\"")
    if not PINNED_REF_RE.match(ref):
        problems.add(
            where,
            f"{SESSION_ACTION}@{ref} is not pinned to a release tag or a commit sha",
        )

    block = "\n".join(_step_lines(lines, uses_index))
    if not re.search(
        r"^\s*limit-access-to-actor:\s*['\"]?true['\"]?\s*(?:#.*)?$", block, re.MULTILINE
    ):
        problems.add(where, "the session step must set limit-access-to-actor: true")

    bounds = {}
    for key in SESSION_DURATION_KEYS:
        match = re.search(rf"^\s*{re.escape(key)}:\s*(\S+)\s*(?:#.*)?$", block, re.MULTILINE)
        if match:
            bounds[key] = match.group(1).strip("'\"")
    if not re.search(
        r"^\s*full-access:\s*['\"]?true['\"]?\s*(?:#.*)?$", block, re.MULTILINE
    ):
        # Without it the guest can watch and approve nothing; the whole point is to run the
        # tests inside the runner. It is only acceptable because the actor's keys gate it.
        problems.add(where, "the session step must set full-access: true")

    if not bounds:
        problems.add(
            where,
            "the session step has no duration bound (timeout-minutes or wait-timeout-minutes)",
        )
    for key, value in bounds.items():
        if not value.isdigit() or not 0 < int(value) <= MAX_SESSION_MINUTES:
            problems.add(
                where,
                f"{key} must be whole minutes within 1..{MAX_SESSION_MINUTES}, "
                f"found {value!r}",
            )

    # The bound moved: the tmate step is detached and short, and the time the runner is
    # actually held is the keep-alive step. Checking only the tmate block would read
    # "timeout-minutes: 10" and call the file bounded while the real ceiling sat in a shell
    # literal nothing inspected.
    keep = next((i for i, line in enumerate(lines) if "Keep the runner alive" in line), None)
    if keep is None:
        problems.add(where, "no keep-alive step: nothing holds the runner open for the session")
        return
    keep_block = "\n".join(_step_lines(lines, keep))
    bound = re.search(
        rf"^\s*{re.escape('timeout-minutes')}:\s*(\S+)\s*(?:#.*)?$", keep_block, re.MULTILINE
    )
    if bound is None:
        problems.add(where, "the keep-alive step has no timeout-minutes")
    elif not bound.group(1).isdigit() or not 0 < int(bound.group(1)) <= MAX_SESSION_MINUTES:
        problems.add(
            where,
            f"the keep-alive timeout-minutes must be whole minutes within "
            f"1..{MAX_SESSION_MINUTES}, found {bound.group(1)!r}",
        )
    else:
        ceiling = int(bound.group(1)) * 60
        for literal in re.findall(r"-ge\s+(\d+)", keep_block):
            if int(literal) >= ceiling:
                problems.add(
                    where,
                    f"the keep-alive stop condition ({literal}s) is not inside its own "
                    f"timeout-minutes ({ceiling}s)",
                )

    for number, message in _runner_context_problems(text):
        problems.add(where, f"line {number}: {message}")


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
    "debug-ssh": check_debug_ssh,
    "workflow-expressions": check_workflow_expressions,
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
