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
    for name in ("README.md", "README.zh-CN.md", "architecture.md"):
        path = DOCS / name if (DOCS / name).is_file() else ROOT / name
        if not path.is_file():
            continue
        problems.forbid(name, path.read_text(encoding="utf-8"), *RETIRED_TOKENS)


def check_partitions(problems: Problems) -> None:
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
            "architecture.md",
            f"slot headroom {ratio:.1f}x is below the {MIN_SLOT_RATIO}x floor",
        )


def check_esp_data_only(problems: Problems) -> None:
    doc = read_doc("architecture.md", problems)
    problems.need("architecture.md", doc, "p1 holds data only, never executable scripts")

    p1_row = next((line for line in doc.splitlines() if line.startswith("| p1 ")), "")
    if not p1_row:
        problems.add("architecture.md", "p1 table row not found")
    else:
        problems.forbid("architecture.md", p1_row, ".sh", "ab-slot", "busybox", "/usr/")
        problems.need("architecture.md", p1_row, "ab/")

    boot = read_doc("architecture.md", problems)
    problems.need("architecture.md", boot, "@platform", "degraded", "tmpfs")


def check_overlay_layers(problems: Problems) -> None:
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
        "architecture.md",
        doc,
        "upperdir=/mnt/p4/@overlay-",
        "workdir=/mnt/p4/@overlay-",
    )


def check_generation_model(problems: Problems) -> None:
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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
    doc = read_doc("architecture.md", problems)
    problems.need(
        "architecture.md",
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


WORKFLOWS_DIR = ROOT / ".github" / "workflows"
WORKFLOW_REF_PREFIX = "./.github/workflows/"
JOB_HEADER_RE = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
LOCAL_USES_RE = re.compile(r"^\s*-?\s*uses:\s*[\"']?\./\.github/workflows/")
PERMISSION_RANK = {"none": 0, "read": 1, "write": 2}
# `permissions: read-all` and `permissions: write-all` are the scalar spellings of "every
# permission at this level". They stay the wildcard key and are compared as one: expanding
# them into a list of names would go stale the next time GitHub adds a permission, and the
# stale copy is the one that either misses a real over-grant or blocks a valid change.
WILDCARD = "*"
# What a job runs with when neither it nor its file declares anything. GitHub's default for a
# public repository is a read-only token. This tree declares a top-level block in every
# workflow, so this only decides how a file that forgot its block is judged: read-only, never
# all-powerful.
DEFAULT_PERMISSIONS = {"contents": "read"}


def _permission_block(lines: list[str], index: int, indent: int) -> dict[str, str]:
    """The permissions declared at `indent`, from the `permissions:` line at `index`.

    Four shapes are accepted, because they are all the ways a YAML author writes this block:
    an indented `key: level` mapping, an empty `{}`, an inline flow mapping, and the scalars
    `read-all` / `write-all`. Comments inside a block are skipped and a block ends at the
    first line indented at or above its own key.
    """
    inline = lines[index].split(":", 1)[1].split("#", 1)[0].strip()
    if inline.startswith("{"):
        declared = {}
        for item in inline.strip("{").rstrip("}").split(","):
            key, separator, value = item.partition(":")
            if separator and key.strip():
                declared[key.strip()] = value.strip()
        return declared
    if inline in ("read-all", "write-all"):
        return {WILDCARD: inline.split("-", 1)[0]}
    if inline:
        # Reported by `_unparsed_problems`; modelled as granting nothing so nothing downstream
        # reads a shape this file does not understand as if it had understood it.
        return {}
    declared = {}
    for line in lines[index + 1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if len(line) - len(line.lstrip()) <= indent:
            break
        key, separator, value = stripped.partition(":")
        value = value.split("#", 1)[0].strip()
        if separator and key.strip() and value:
            declared[key.strip()] = value
    return declared


def _parse_workflow_permissions(text: str) -> tuple[dict[str, str], dict[str, dict]]:
    """(top-level permissions, {job id: {"permissions": map|None, "uses": ref|None}}).

    A job's `permissions` is None when it declares none, which is not the same as `{}`: the
    job then inherits the file's top-level block, and that inheritance is what makes a
    top-level `contents: write` a request in its own right.
    """
    lines = text.splitlines()
    top: dict[str, str] | None = None
    for index, line in enumerate(lines):
        # Only a column-0 key is the workflow-level block: a job's own block is indented, so
        # this cannot pick up the wrong one.
        if line.startswith("permissions:"):
            top = _permission_block(lines, index, 0)
            break

    jobs: dict[str, dict] = {}
    in_jobs = False
    current: str | None = None
    for line in lines:
        if re.match(r"^jobs:\s*(?:#.*)?$", line):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^[A-Za-z_]", line):
            in_jobs = False
            current = None
        if not in_jobs:
            continue
        header = JOB_HEADER_RE.match(line)
        if header:
            current = header.group(1)
            jobs[current] = {"permissions": None, "uses": None, "declared": []}
            continue
        if current is None:
            continue
        jobs[current]["declared"].append(line)

    for job in jobs.values():
        declared: list[str] = job.pop("declared")
        for index, line in enumerate(declared):
            # Every spelling of a job-level block: the indented mapping, `{}`, a flow mapping
            # and `read-all`/`write-all` all start on this line.
            if job["permissions"] is None and re.match(r"^    permissions:", line):
                job["permissions"] = _permission_block(declared, index, 4)
            match = re.match(r"^    uses:\s*(\S+?)\s*(?:#.*)?$", line)
            if match:
                job["uses"] = match.group(1).strip("\"'")
    return (top if top is not None else dict(DEFAULT_PERMISSIONS)), jobs


def _unparsed_problems(text: str, jobs: dict[str, dict]) -> list[str]:
    """Shapes the parser above cannot see, reported instead of silently skipped.

    Silence is the one failure mode that matters here: a call the parser did not see is a
    call whose ceiling nobody checked, and the run it belongs to dies at startup. So a local
    `uses:` that did not become a parsed job is a problem, and so is a `permissions:` value
    this file has no model for.
    """
    problems = []
    lines = text.splitlines()
    declared_local = sum(1 for line in lines if LOCAL_USES_RE.match(line))
    parsed_local = sum(1 for job in jobs.values() if job["uses"])
    if declared_local > parsed_local:
        problems.append(
            f"{declared_local - parsed_local} local `uses:` line(s) were not parsed: "
            "check the indentation and the quoting of the job that carries one"
        )
    if "jobs:" in text and not jobs:
        problems.append("no job could be parsed: job ids are expected to be two-space indented")
    for number, line in enumerate(lines, start=1):
        match = re.match(r"^\s*permissions:\s*(\S.*)$", line)
        if not match:
            continue
        value = match.group(1).split("#", 1)[0].strip()
        if value.startswith("{") or value in ("read-all", "write-all"):
            continue
        problems.append(f"line {number}: unrecognised permissions value {value!r}")
    return problems


def _granted(permissions: dict[str, str], permission: str) -> str:
    """The level `permissions` grants `permission`, wildcard included."""
    if permission in permissions:
        return permissions[permission]
    if permission == WILDCARD:
        return "none"
    return permissions.get(WILDCARD, "none")


def _floor(left: str, right: str) -> str:
    return left if PERMISSION_RANK[left] <= PERMISSION_RANK[right] else right


def _capped(ceiling: dict[str, str], grant: dict[str, str]) -> dict[str, str]:
    """The narrower of two permission maps, key by key and on the wildcard."""
    capped = {}
    for permission in (set(ceiling) | set(grant)) - {WILDCARD}:
        level = _floor(_granted(ceiling, permission), _granted(grant, permission))
        if level != "none":
            capped[permission] = level
    wildcard = _floor(ceiling.get(WILDCARD, "none"), grant.get(WILDCARD, "none"))
    if wildcard != "none":
        capped[WILDCARD] = wildcard
    return capped


def _permission_label(permission: str) -> str:
    return "every permission" if permission == WILDCARD else permission


def _workflow_call_permission_problems(texts: dict[str, str]) -> list[tuple[str, str]]:
    """(workflow, message) for every called workflow that asks for more than it is granted.

    A caller job's `permissions` is a ceiling, not a scope: every job of the called workflow
    has to fit inside it, and one that asks for more makes GitHub reject the whole run at
    startup -- no job list, no log, only "This run likely failed because of a workflow file
    issue". That is how the daily upstream watch and the tag release line went dead at once
    (run 45726019172): ci.yml's `audit` job asked for `contents: write`, and both caller jobs
    granted `contents: read`.

    The ceiling is taken along the whole chain: a workflow called by a workflow called by a
    push still cannot hand out more than the push granted. `uses:` of a published action is
    not this repository's workflow and is left alone; `uses:` of a file that is not here is
    a startup failure of its own.
    """
    problems: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def report(workflow: str, message: str) -> None:
        if (workflow, message) not in seen:
            seen.add((workflow, message))
            problems.append((workflow, message))

    parsed: dict[str, tuple[dict[str, str], dict[str, dict]]] = {}
    for name, text in texts.items():
        top, jobs = _parse_workflow_permissions(text)
        for message in _unparsed_problems(text, jobs):
            report(name, message)
        declared = [("the top-level block", top)]
        declared += [(f"job {job_id!r}", job["permissions"]) for job_id, job in jobs.items() if job["permissions"] is not None]
        for where, permissions in declared:
            for permission, level in list(permissions.items()):
                if level in PERMISSION_RANK:
                    continue
                report(name, f"{where} declares {_permission_label(permission)}: {level}, which is not none/read/write")
                del permissions[permission]
        parsed[name] = (top, jobs)

    # A workflow can be reachable from two callers with two different ceilings, and the second
    # can be the narrower one - so the identity of a visit includes the ceiling it was made
    # under. Ceilings only narrow along a chain, which is what makes a cycle terminate.
    visited: set[tuple[str, str, tuple[tuple[str, str], ...]]] = set()

    def walk(workflow: str, ceiling: dict[str, str]) -> None:
        top, jobs = parsed[workflow]
        for job_id, job in jobs.items():
            uses = job["uses"]
            if not uses or not uses.startswith(WORKFLOW_REF_PREFIX):
                continue
            signature = (workflow, job_id, tuple(sorted(ceiling.items())))
            if signature in visited:
                continue
            visited.add(signature)
            target = uses[len(WORKFLOW_REF_PREFIX):]
            if target not in parsed:
                report(workflow, f"job {job_id!r} calls {uses}, which is not a workflow in .github/workflows/")
                continue
            grant = job["permissions"] if job["permissions"] is not None else top
            granted = _capped(ceiling, grant)
            called_top, called_jobs = parsed[target]
            for called_id, called_job in called_jobs.items():
                asked = called_job["permissions"] if called_job["permissions"] is not None else called_top
                for permission, level in sorted(asked.items()):
                    allowed = _granted(granted, permission)
                    if PERMISSION_RANK[level] > PERMISSION_RANK[allowed]:
                        report(
                            target,
                            f"job {called_id!r} asks for {_permission_label(permission)}: {level}, "
                            f"but {workflow} job {job_id!r} grants {_permission_label(permission)}: {allowed}",
                        )
            walk(target, granted)

    for name in parsed:
        walk(name, {WILDCARD: "write"})
    return problems


def check_reusable_permissions(problems: Problems) -> None:
    """No called workflow asks for a permission its caller does not grant."""
    workflows = sorted(WORKFLOWS_DIR.glob("*.yml"))
    if not workflows:
        problems.add(".github/workflows", "no workflows found")
        return
    texts = {}
    for path in workflows:
        rel = str(path.relative_to(ROOT))
        try:
            texts[path.name] = path.read_text(encoding="utf-8")
        except OSError as exc:  # noqa: BLE001 - report instead of crashing
            problems.add(rel, f"cannot be read: {exc}")
    for name, message in _workflow_call_permission_problems(texts):
        problems.add(f".github/workflows/{name}", message)


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


STYLE_MODULE = None


def _docs_style():
    """Import scripts/check_docs_style.py once, next to this file.

    The page-level command and this check share one implementation on purpose: two copies
    of the style rules would drift, and the copy that nobody runs is the one that rots.
    """
    import importlib.util

    global STYLE_MODULE
    if STYLE_MODULE is None:
        path = SELF.parent / "check_docs_style.py"
        spec = importlib.util.spec_from_file_location("check_docs_style", path)
        module = importlib.util.module_from_spec(spec)
        # dataclasses resolve their string annotations through sys.modules, so the module
        # has to be registered before it is executed.
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        STYLE_MODULE = module
    return STYLE_MODULE


def check_docs_style(problems: Problems) -> None:
    """Every page obeys docs/style.md's limits, spacing, links and section pairs."""
    try:
        style = _docs_style()
    except Exception as exc:  # noqa: BLE001 - report instead of crashing
        problems.add("docs-style", f"cannot load scripts/check_docs_style.py: {exc!r}")
        return
    for violation in style.collect_violations(style.default_targets(ROOT), root=ROOT):
        problems.add(violation.path, f"line {violation.line}: {violation.message}")


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
    "reusable-permissions": check_reusable_permissions,
    "docs-style": check_docs_style,
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
