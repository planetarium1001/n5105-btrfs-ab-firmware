#!/usr/bin/env python3
"""Documentation style checks.

Turns the style rules of docs/style.md into executable assertions: paragraphs,
sentences, list items and headings have length limits, block syntax has spacing
rules, relative links have to resolve, and every English page keeps the same
section structure as its Chinese translation.

The point is that a rule written in prose decays, while a rule that fails the
build does not. It is also what makes a rewrite reviewable: the reviewer reads
the diff, the checker reads every page.

Usage:
    python3 scripts/check_docs_style.py              # every page under docs/
    python3 scripts/check_docs_style.py docs/style.md
    python3 scripts/check_docs_style.py --report-only docs

Exit codes: 0 clean (or --report-only), 1 violations, 2 bad invocation.

The module is imported by scripts/check_design.py, so both entry points run the
same rules. There is no second implementation to drift.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The defaults are the numbers printed in docs/style.md. Do not raise one to make a
# page pass: shorten the page instead.
MAX_PARAGRAPH = 400
MAX_PARAGRAPH_SENTENCES = 4
MAX_SENTENCE_WORDS = 40
MAX_SENTENCE_CHARS = 80
MAX_ITEM = 240
MAX_HEADING = 80

ZH_SUFFIX = ".zh-CN.md"

# Pages outside docs/ that the same rules cover (ac-11): the two root READMEs and
# the two READMEs that describe scripts/ and tests/.
EXTRA_PAGES = (
    "README.md",
    "README.zh-CN.md",
    "scripts/ci/README.md",
    "tests/README.md",
)

CJK_RE = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff]")
FENCE_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<marker>`{3,}|~{3,})(?P<info>.*)$")
HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(\S.*)$")
ITEM_RE = re.compile(r"^(?P<indent>[ \t]*)(?:[-*+]|\d{1,3}[.)])[ \t]+")
TABLE_SEP_RE = re.compile(r"^\|?[\s:|-]*-[\s:|-]*\|?$")
LINK_RE = re.compile(r"\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)")
CODE_SPAN_RE = re.compile(r"`[^`]*`")
# Sentence ends that never need a following space, because Chinese does not use one.
CJK_ENDERS = "。！？；"
ASCII_ENDERS = ".!?"
# A period after one of these is not the end of a sentence.
ABBREVIATIONS = {"e.g", "i.e", "etc", "vs", "cf", "al", "no", "fig", "approx"}


@dataclass(frozen=True)
class Limits:
    paragraph: int = MAX_PARAGRAPH
    sentence_words: int = MAX_SENTENCE_WORDS
    sentence_chars: int = MAX_SENTENCE_CHARS
    item: int = MAX_ITEM
    heading: int = MAX_HEADING


@dataclass(frozen=True)
class Violation:
    """One style problem, printed as `path:line: message`."""

    path: str
    line: int
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.message}"


@dataclass
class Line:
    """One source line and what the parser decided it is."""

    number: int
    text: str
    kind: str
    indent: int = 0
    level: int = 0
    info: str = ""
    closed: bool = True
    continuation: list[str] = field(default_factory=list)


def _join_lines(parts: list[str]) -> str:
    """Join wrapped lines into one paragraph.

    A space separates English words; two Chinese characters are already separated
    by nothing in the original, so joining them with a space would inflate the
    character count that the rule measures.
    """
    joined = ""
    for part in parts:
        if not joined:
            joined = part
        elif joined[-1] and part and CJK_RE.match(joined[-1]) and CJK_RE.match(part[0]):
            joined += part
        else:
            joined += " " + part
    return joined


def _strip_comments(lines: list[str]) -> list[str]:
    """Blank out HTML comments while keeping every line at its original number."""
    text = "\n".join(lines)
    while True:
        start = text.find("<!--")
        if start < 0:
            break
        end = text.find("-->", start)
        if end < 0:
            end = len(text) - 3
        block = text[start:end + 3]
        text = text[:start] + re.sub(r"[^\n]", " ", block) + text[end + 3:]
    return text.split("\n")


def _is_table_line(line: str) -> bool:
    return line.lstrip().startswith("|")


def _is_quote(line: str) -> bool:
    return line.lstrip().startswith(">")


def parse_lines(text: str) -> list[Line]:
    """Split a page into typed lines: headings, fences, tables, items, prose."""
    raw = _strip_comments(text.splitlines())
    lines: list[Line] = []
    index = 0
    if raw and raw[0].strip() == "---":
        close = next((n for n in range(1, len(raw)) if raw[n].strip() == "---"), None)
        if close is not None:
            for number in range(close + 1):
                lines.append(Line(number + 1, raw[number], "front"))
            index = close + 1

    while index < len(raw):
        line = raw[index]
        number = index + 1
        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group("marker")
            opener = Line(
                number, line, "fence_open",
                indent=len(fence.group("indent")),
                info=fence.group("info").strip(),
            )
            lines.append(opener)
            index += 1
            while index < len(raw):
                body = raw[index]
                lines.append(Line(index + 1, body, "fence_body"))
                close = FENCE_RE.match(body)
                if (close and close.group("marker")[0] == marker[0]
                        and len(close.group("marker")) >= len(marker)
                        and not close.group("info").strip()):
                    lines[-1].kind = "fence_close"
                    index += 1
                    break
                index += 1
            else:
                opener.closed = False
            continue
        if not line.strip():
            lines.append(Line(number, line, "blank"))
            index += 1
            continue
        heading = HEADING_RE.match(line)
        if heading:
            lines.append(Line(number, line, "heading", level=len(heading.group(1))))
            index += 1
            continue
        if _is_table_line(line):
            kind = "table_sep" if TABLE_SEP_RE.match(line.strip()) else "table_row"
            lines.append(Line(
                number, line, kind,
                indent=len(line) - len(line.lstrip()),
            ))
            index += 1
            continue
        item = ITEM_RE.match(line)
        if item:
            block = Line(
                number, line, "item",
                indent=len(item.group("indent")),
                continuation=[line[item.end():].strip()],
            )
            lines.append(block)
            index += 1
            while index < len(raw):
                follow = raw[index]
                if not follow.strip():
                    break
                if (FENCE_RE.match(follow) or HEADING_RE.match(follow)
                        or _is_table_line(follow) or ITEM_RE.match(follow)):
                    break
                if len(follow) - len(follow.lstrip()) <= block.indent:
                    break
                block.continuation.append(follow.strip())
                index += 1
            continue
        kind = "quote" if _is_quote(line) else "text"
        block = Line(number, line, kind, continuation=[line.strip()])
        lines.append(block)
        index += 1
        while index < len(raw):
            follow = raw[index]
            if not follow.strip():
                break
            if (FENCE_RE.match(follow) or HEADING_RE.match(follow)
                    or _is_table_line(follow) or ITEM_RE.match(follow)):
                break
            follow_kind = "quote" if _is_quote(follow) else "text"
            if follow_kind != block.kind:
                break
            block.continuation.append(follow.strip())
            index += 1
    return lines


def split_sentences(text: str) -> list[str]:
    """Split prose into sentences without a full sentence tokenizer.

    Two rules carry every case in these pages: a Chinese ender ends a sentence
    immediately, and an ASCII ender only ends one when a space and a capital (or an
    opening quote, bracket or emphasis mark) follow. Abbreviations and decimals are
    not sentence ends, and neither is a period inside an inline code span: `。` in a
    code span is a character being named, not the end of a thought.
    """
    # Decisions are made on a masked copy so a code span cannot end a sentence, while
    # the slice still returns the original text, code span and all.
    masked = CODE_SPAN_RE.sub(lambda match: "x" * len(match.group(0)), text)
    sentences: list[str] = []
    start = 0
    index = 0
    length = len(text)
    while index < length:
        char = masked[index]
        if char in CJK_ENDERS:
            sentences.append(text[start:index + 1])
            start = index + 1
        elif char in ASCII_ENDERS:
            if masked[index:index + 3] == "...":
                index += 3
                continue
            if masked[:index].endswith(tuple(ASCII_ENDERS)):
                index += 1
                continue
            word = re.search(r"([A-Za-z.]+)$", masked[:index])
            token = word.group(1).rstrip(".").lower() if word else ""
            if token in ABBREVIATIONS:
                index += 1
                continue
            follow = masked[index + 1:index + 3]
            if follow[:1] == " " and len(follow) > 1 and (
                follow[1].isupper() or follow[1] in '"\'`*([{'
            ):
                sentences.append(text[start:index + 1])
                start = index + 1
        index += 1
    tail = text[start:]
    if tail.strip():
        sentences.append(tail)
    return [sentence.strip() for sentence in sentences if sentence.strip()]


def _is_link_only(text: str) -> bool:
    """True for a line or item that carries nothing but a link."""
    stripped = LINK_RE.sub("", text)
    return not re.sub(r"[\s>*+·—–,.:;!?()\[\]|`-]+", "", stripped)


def _heading_levels(lines: list[Line]) -> list[tuple[int, int]]:
    return [(l.number, l.level) for l in lines if l.kind == "heading"]


def check_headings(lines: list[Line], limits: Limits, rel: str) -> list[Violation]:
    problems: list[Violation] = []
    headings = [l for l in lines if l.kind == "heading"]
    titles = [l for l in headings if l.level == 1]
    if len(titles) != 1:
        where = titles[1].number if len(titles) > 1 else (headings[0].number if headings else 1)
        problems.append(Violation(
            rel, where, f"file has {len(titles)} top-level headings, expected one",
        ))
    previous = None
    for line in headings:
        if len(line.text) > limits.heading:
            problems.append(Violation(
                rel, line.number,
                f"heading is {len(line.text)} characters (max {limits.heading})",
            ))
        if previous is not None and line.level > previous + 1:
            problems.append(Violation(
                rel, line.number,
                f"heading level jumps from H{previous} to H{line.level}",
            ))
        previous = line.level
    for index, line in enumerate(lines):
        if line.kind != "heading":
            continue
        if index > 0 and lines[index - 1].kind != "blank":
            problems.append(Violation(rel, line.number, "missing blank line before heading"))
        if index + 1 < len(lines) and lines[index + 1].kind != "blank":
            problems.append(Violation(rel, line.number, "missing blank line after heading"))
    return problems


def check_fences(lines: list[Line], rel: str) -> list[Violation]:
    problems: list[Violation] = []
    for index, line in enumerate(lines):
        if line.kind != "fence_open":
            continue
        if not line.closed:
            problems.append(Violation(rel, line.number, "fenced code block is never closed"))
        if not line.info:
            problems.append(Violation(rel, line.number, "fenced code block has no language"))
        # A fence indented inside a list item may follow the item line directly: that is
        # how a numbered step carries its command block. Only top-level fences need the
        # surrounding blank lines.
        if line.indent:
            continue
        if index > 0 and lines[index - 1].kind != "blank":
            problems.append(Violation(
                rel, line.number, "missing blank line before fenced code block",
            ))
        last = index
        while last + 1 < len(lines) and lines[last + 1].kind in (
            "fence_body", "fence_close"
        ):
            last += 1
        if last + 1 < len(lines) and lines[last + 1].kind != "blank":
            problems.append(Violation(
                rel, lines[last].number, "missing blank line after fenced code block",
            ))
    return problems


def check_tables(lines: list[Line], rel: str) -> list[Violation]:
    problems: list[Violation] = []
    index = 0
    while index < len(lines):
        if lines[index].kind not in ("table_row", "table_sep"):
            index += 1
            continue
        start = index
        while index < len(lines) and lines[index].kind in ("table_row", "table_sep"):
            index += 1
        block = lines[start:index]
        if len(block) < 2 or block[1].kind != "table_sep":
            problems.append(Violation(
                rel, block[0].number, "table has no separator row",
            ))
        if block[0].indent:
            continue
        if start > 0 and lines[start - 1].kind != "blank":
            problems.append(Violation(
                rel, block[0].number, "missing blank line before table",
            ))
        if index < len(lines) and lines[index].kind != "blank":
            problems.append(Violation(
                rel, block[-1].number, "missing blank line after table",
            ))
    return problems


def _sentence_problems(sentence: str, limits: Limits, rel: str, line: int) -> list[Violation]:
    if CJK_RE.search(sentence):
        compact = re.sub(r"\s+", "", sentence)
        if len(compact) > limits.sentence_chars:
            return [Violation(
                rel, line,
                f"sentence is {len(compact)} characters (max {limits.sentence_chars})",
            )]
        return []
    words = len(sentence.split())
    if words > limits.sentence_words:
        return [Violation(
            rel, line, f"sentence is {words} words (max {limits.sentence_words})",
        )]
    return []


def check_prose(lines: list[Line], limits: Limits, rel: str) -> list[Violation]:
    problems: list[Violation] = []
    for line in lines:
        if line.kind == "item":
            text = _join_lines(
                [part for part in line.continuation if part]
            )
            if len(text) > limits.item:
                problems.append(Violation(
                    rel, line.number,
                    f"list item is {len(text)} characters (max {limits.item})",
                ))
            continue
        if line.kind not in ("text", "quote"):
            continue
        parts = line.continuation
        if line.kind == "quote":
            parts = [re.sub(r"^>+[ \t]?", "", part).strip() for part in parts]
        text = _join_lines([part for part in parts if part])
        if not text or _is_link_only(text):
            continue
        if len(text) > limits.paragraph:
            problems.append(Violation(
                rel, line.number,
                f"paragraph is {len(text)} characters (max {limits.paragraph})",
            ))
        sentences = split_sentences(text)
        if len(sentences) > MAX_PARAGRAPH_SENTENCES:
            problems.append(Violation(
                rel, line.number,
                f"paragraph has {len(sentences)} sentences (max {MAX_PARAGRAPH_SENTENCES})",
            ))
        for sentence in sentences:
            problems.extend(_sentence_problems(sentence, limits, rel, line.number))
    return problems


def check_links(lines: list[Line], path: Path, rel: str) -> list[Violation]:
    problems: list[Violation] = []
    for line in lines:
        if line.kind in ("fence_open", "fence_body", "fence_close", "front"):
            continue
        without_code = CODE_SPAN_RE.sub("", line.text)
        for target in LINK_RE.findall(without_code):
            target = target.strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1].strip()
            if target.startswith(("http://", "https://", "mailto:", "tel:", "#")):
                continue
            clean = target.split("#", 1)[0]
            if not clean:
                continue
            if not (path.parent / clean).resolve().exists():
                problems.append(Violation(
                    rel, line.number, f"unresolved relative link {target!r}",
                ))
    return problems


def _root_relative(path: Path, root: Path) -> str:
    """Path as the reader sees it: relative to the root when it is inside it."""
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def check_page(path: Path, root: Path, limits: Limits) -> list[Violation]:
    rel = _root_relative(path, root)
    lines = parse_lines(path.read_text(encoding="utf-8"))
    problems: list[Violation] = []
    problems.extend(check_headings(lines, limits, rel))
    problems.extend(check_fences(lines, rel))
    problems.extend(check_tables(lines, rel))
    problems.extend(check_prose(lines, limits, rel))
    problems.extend(check_links(lines, path, rel))
    return problems


def check_pair(path: Path, root: Path) -> list[Violation]:
    """An English page and its translation must section one to one."""
    translation = path.with_name(path.name[: -len(".md")] + ZH_SUFFIX)
    if not translation.is_file():
        return []
    rel = _root_relative(path, root)
    other = _root_relative(translation, root)
    left = _heading_levels(parse_lines(path.read_text(encoding="utf-8")))
    right = _heading_levels(parse_lines(translation.read_text(encoding="utf-8")))
    if len(left) != len(right):
        return [Violation(
            rel, left[0][0] if left else 1,
            f"section count differs from {other}: {len(left)} here, {len(right)} there",
        )]
    problems: list[Violation] = []
    for position, ((number, level), (_, other_level)) in enumerate(zip(left, right), start=1):
        if level != other_level:
            problems.append(Violation(
                rel, number,
                f"section structure differs from {other}: section {position} is "
                f"H{level} here and H{other_level} there",
            ))
    return problems


def expand_targets(targets: list[Path]) -> list[Path]:
    """Resolve files and directories into a stable, de-duplicated page list."""
    pages: list[Path] = []
    seen: set[Path] = set()
    for target in targets:
        if target.is_dir():
            found = sorted(target.rglob("*.md"))
        elif target.is_file():
            found = [target]
        else:
            raise FileNotFoundError(f"no such path: {target}")
        for page in found:
            resolved = page.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            pages.append(page)
    return pages


def default_targets(root: Path = ROOT) -> list[Path]:
    """Every page the style rules cover: docs/ plus the four READMEs."""
    targets = [root / "docs"]
    targets.extend(root / name for name in EXTRA_PAGES)
    return [target for target in targets if target.exists()]


def collect_violations(
    targets: list[Path] | None = None,
    root: Path = ROOT,
    limits: Limits | None = None,
) -> list[Violation]:
    """Every style violation under the given targets, in page order."""
    limits = limits or Limits()
    pages = expand_targets(targets if targets is not None else default_targets(root))
    problems: list[Violation] = []
    for page in pages:
        problems.extend(check_page(page, root, limits))
    for page in pages:
        if page.name.endswith(ZH_SUFFIX):
            continue
        problems.extend(check_pair(page, root))
    return problems


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="check_docs_style.py",
        description="Check that the documentation obeys docs/style.md.",
        epilog="Exit codes: 0 clean, 1 violations, 2 bad invocation.",
    )
    parser.add_argument(
        "paths", nargs="*", type=Path,
        help="files or directories to check (default: the docs directory)",
    )
    parser.add_argument(
        "--root", type=Path, default=ROOT,
        help="repository root used for relative paths (default: this checkout)",
    )
    parser.add_argument("--max-paragraph", type=int, default=MAX_PARAGRAPH,
                        help=f"characters in one paragraph (default {MAX_PARAGRAPH})")
    parser.add_argument("--max-sentence-words", type=int, default=MAX_SENTENCE_WORDS,
                        help=f"words in one English sentence (default {MAX_SENTENCE_WORDS})")
    parser.add_argument("--max-sentence-chars", type=int, default=MAX_SENTENCE_CHARS,
                        help=f"characters in one Chinese sentence (default {MAX_SENTENCE_CHARS})")
    parser.add_argument("--max-item", type=int, default=MAX_ITEM,
                        help=f"characters in one list item (default {MAX_ITEM})")
    parser.add_argument("--max-heading", type=int, default=MAX_HEADING,
                        help=f"characters in one heading (default {MAX_HEADING})")
    parser.add_argument("--report-only", action="store_true",
                        help="print the violations but exit 0")
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv[1:])
    root = args.root.resolve()
    targets = args.paths or [root / "docs"]
    limits = Limits(
        paragraph=args.max_paragraph,
        sentence_words=args.max_sentence_words,
        sentence_chars=args.max_sentence_chars,
        item=args.max_item,
        heading=args.max_heading,
    )
    try:
        pages = expand_targets(targets)
    except FileNotFoundError as error:
        print(error, file=sys.stderr)
        return 2
    problems = collect_violations(pages, root=root, limits=limits)
    for problem in problems:
        print(problem)
    sys.stdout.flush()
    if problems:
        print(f"{len(problems)} style problem(s) in {len(pages)} page(s)", file=sys.stderr)
        return 0 if args.report_only else 1
    print(f"{len(pages)} page(s) checked, no style problems")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
