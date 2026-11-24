#!/usr/bin/env bash
# Module: docs
# ac-9: scripts/check_docs_style.py is the executable form of the style rules in
#       docs/style.md. It catches long paragraphs, long sentences, long list items,
#       heading level jumps, missing blank lines, unlabelled fences, broken tables,
#       unresolved links and English/Chinese section drift.
# ac-10: scripts/check_design.py registers the same check as `docs-style`, and the
#        real documents pass it.
#
# The bad-sample section builds throwaway trees; the gate section runs the checker
# over the real documents. Both are required: a checker that never fires is as
# useless as one that always fires.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

checker="$root/scripts/check_docs_style.py"
tmp=$(mktemp -d) || { echo "cannot create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# run_case <dir> <args...>: runs the checker and leaves `out`/`code` behind.
run_case() {
  local base=$1
  shift
  out=$(python3 "$checker" --root "$base" "$@" 2>&1)
  code=$?
}

# --- the checker is a standalone, dependency-free program -----------------
assert_file_exists "$checker" "ac-9 the checker exists"
assert_command_ok "ac-9 the checker shows usage and exits 0" \
  python3 "$checker" --help

# --- long paragraph -------------------------------------------------------
mkdir -p "$tmp/long-paragraph"
cat >"$tmp/long-paragraph/page.md" <<'EOF'
# Page

One sentence padded until the paragraph is longer than the four hundred character limit that a
reader can follow on one screen before the argument needs a break and the page is easier to
scan. A second sentence keeps the paragraph above the character limit while staying under the
word limit so the failure names only the paragraph length and nothing else at all in this
fixture. The third sentence proves that the checker splits sentences by punctuation and not by
line breaks because a wall of text is exactly what the rule forbids in the first place.
EOF
run_case "$tmp/long-paragraph" "$tmp/long-paragraph/page.md"
assert_eq "$code" "1" "ac-9 a long paragraph fails the check"
assert_contains "$out" "paragraph is" "ac-9 the failure names the paragraph length"
assert_matches "$out" '^[A-Za-z0-9_./-]+\.md:[0-9]+: ' "ac-9 output is path:line: message"

# --- long English sentence ----------------------------------------------
mkdir -p "$tmp/long-sentence"
python3 - "$tmp/long-sentence/page.md" <<'PY'
import sys

words = ["word"] * 46
body = "# Page\n\n" + " ".join(words) + ".\n"
open(sys.argv[1], "w", encoding="utf-8").write(body)
PY
run_case "$tmp/long-sentence" "$tmp/long-sentence/page.md"
assert_eq "$code" "1" "ac-9 a 46-word English sentence fails the check"
assert_contains "$out" "words (max 40)" "ac-9 the failure names the word limit"

# --- a period inside an inline code span does not end a sentence --------
mkdir -p "$tmp/code-span"
python3 - "$tmp/code-span/page.md" <<'PY'
import sys

# 46 words, and the only early period sits inside a code span: splitting there would
# hide the real length behind two short "sentences".
body = "# Page\n\n`one. two` " + " ".join(["word"] * 44) + ".\n"
open(sys.argv[1], "w", encoding="utf-8").write(body)
PY
run_case "$tmp/code-span" "$tmp/code-span/page.md"
assert_eq "$code" "1" "ac-9 a period in a code span does not hide a long sentence"
assert_contains "$out" "words (max 40)" "ac-9 the whole sentence is measured"

# --- long Chinese sentence ----------------------------------------------
mkdir -p "$tmp/long-chinese"
python3 - "$tmp/long-chinese/page.md" <<'PY'
import sys

body = "# 页面\n\n" + "中文句子要短" * 16 + "。\n"
open(sys.argv[1], "w", encoding="utf-8").write(body)
PY
run_case "$tmp/long-chinese" "$tmp/long-chinese/page.md"
assert_eq "$code" "1" "ac-9 a 96-character Chinese sentence fails the check"
assert_contains "$out" "characters (max 80)" "ac-9 the failure names the Chinese limit"

# --- long list item ------------------------------------------------------
mkdir -p "$tmp/long-item"
python3 - "$tmp/long-item/page.md" <<'PY'
import sys

body = "# Page\n\n- " + " ".join(["item"] * 60) + "\n"
open(sys.argv[1], "w", encoding="utf-8").write(body)
PY
run_case "$tmp/long-item" "$tmp/long-item/page.md"
assert_eq "$code" "1" "ac-9 a long list item fails the check"
assert_contains "$out" "list item is" "ac-9 the failure names the list item length"

# --- heading level jump --------------------------------------------------
mkdir -p "$tmp/heading-jump"
cat >"$tmp/heading-jump/page.md" <<'EOF'
# Page

## Section

#### Deep

- text
EOF
run_case "$tmp/heading-jump" "$tmp/heading-jump/page.md"
assert_eq "$code" "1" "ac-9 a skipped heading level fails the check"
assert_contains "$out" "heading level jumps" "ac-9 the failure names the heading jump"

# --- exactly one top-level heading --------------------------------------
mkdir -p "$tmp/two-titles"
cat >"$tmp/two-titles/page.md" <<'EOF'
# First

- text

# Second

- text
EOF
run_case "$tmp/two-titles" "$tmp/two-titles/page.md"
assert_eq "$code" "1" "ac-9 a second top-level heading fails the check"
assert_contains "$out" "top-level headings" "ac-9 the failure names the duplicate title"

# --- missing blank line before a heading --------------------------------
mkdir -p "$tmp/tight-heading"
cat >"$tmp/tight-heading/page.md" <<'EOF'
# Page

- text
## Section

- text
EOF
run_case "$tmp/tight-heading" "$tmp/tight-heading/page.md"
assert_eq "$code" "1" "ac-9 a heading glued to the line above fails the check"
assert_contains "$out" "missing blank line before heading" "ac-9 the failure names the gap"

# --- missing blank line around a fence, and no language -----------------
mkdir -p "$tmp/bare-fence"
cat >"$tmp/bare-fence/page.md" <<'EOF'
# Page

```sh
echo ok
```

```
no language here
```
EOF
run_case "$tmp/bare-fence" "$tmp/bare-fence/page.md"
assert_eq "$code" "1" "ac-9 an unlabelled fence fails the check"
assert_contains "$out" "fenced code block has no language" "ac-9 the failure names the fence"

mkdir -p "$tmp/tight-fence"
cat >"$tmp/tight-fence/page.md" <<'EOF'
# Page

- text
```sh
echo ok
```
- text
EOF
run_case "$tmp/tight-fence" "$tmp/tight-fence/page.md"
assert_eq "$code" "1" "ac-9 a fence glued to the surrounding text fails the check"
assert_contains "$out" "missing blank line before fenced code block" \
  "ac-9 the failure names the gap before a fence"

# --- table without a separator row --------------------------------------
mkdir -p "$tmp/bad-table"
cat >"$tmp/bad-table/page.md" <<'EOF'
# Page

| a | b |
| c | d |

- text
EOF
run_case "$tmp/bad-table" "$tmp/bad-table/page.md"
assert_eq "$code" "1" "ac-9 a table without a separator row fails the check"
assert_contains "$out" "table has no separator row" "ac-9 the failure names the table"

# --- unresolved relative link -------------------------------------------
mkdir -p "$tmp/broken-link"
cat >"$tmp/broken-link/page.md" <<'EOF'
# Page

- Read [the missing page](missing.md) for more.
EOF
run_case "$tmp/broken-link" "$tmp/broken-link/page.md"
assert_eq "$code" "1" "ac-9 an unresolved relative link fails the check"
assert_contains "$out" "unresolved relative link" "ac-9 the failure names the link"

# --- English/Chinese section drift --------------------------------------
mkdir -p "$tmp/pair"
cat >"$tmp/pair/page.md" <<'EOF'
# Page

## One

- text

## Two

- text
EOF
cat >"$tmp/pair/page.zh-CN.md" <<'EOF'
# 页面

## 一

- 文本

### 深一层

- 文本
EOF
run_case "$tmp/pair" "$tmp/pair"
assert_eq "$code" "1" "ac-9 a shifted Chinese section fails the check"
assert_contains "$out" "section structure differs" "ac-9 the failure names the drifted pair"

# --- a compliant page is accepted ---------------------------------------
mkdir -p "$tmp/clean"
cat >"$tmp/clean/page.md" <<'EOF'
# Page

One short sentence. Another short sentence.

## Section

| key | value |
|---|---|
| a long cell that is allowed to run past the paragraph limit because tables are excluded | as long as it needs to be to prove the point |
| b | c |

```sh
echo ok
```

- A short item.
EOF
cat >"$tmp/clean/page.zh-CN.md" <<'EOF'
# 页面

一句短话。另一句短话。

## 小节

| 键 | 值 |
|---|---|
| 表格允许长单元格 | 与英文页一致 |
| b | c |

```sh
echo ok
```

- 一条短项。
EOF
run_case "$tmp/clean" "$tmp/clean"
assert_eq "$code" "0" "ac-9 a compliant pair passes"

# --- fenced content, table cells, HTML comments and frontmatter are skipped
mkdir -p "$tmp/skipped"
cat >"$tmp/skipped/page.md" <<'EOF'
# Page

<!-- a long comment that would otherwise look like a paragraph and run far past the limit, repeated until it is unmistakably longer than four hundred characters, which must not be reported because comments are not prose -->

```text
a fence line that is long and would otherwise look like a paragraph, but it is sample output and the checker skips it, so it must not be reported at all, even though it runs long
a second line of output
```

- text
EOF
run_case "$tmp/skipped" "$tmp/skipped/page.md"
assert_eq "$code" "0" "ac-9 fenced blocks and HTML comments are skipped"

# --- thresholds are configurable ---------------------------------------
mkdir -p "$tmp/threshold"
cat >"$tmp/threshold/page.md" <<'EOF'
# Page

A sentence that is short by the default limit but long by the lowered one.
EOF
run_case "$tmp/threshold" --max-paragraph 20 "$tmp/threshold/page.md"
assert_eq "$code" "1" "ac-9 --max-paragraph lowers the paragraph limit"
assert_contains "$out" "(max 20)" "ac-9 the failure reports the configured limit"

run_case "$tmp/threshold" --max-item 10 "$tmp/threshold/page.md"
assert_eq "$code" "0" "ac-9 --max-item does not invent defects in text without items"

# --- --report-only prints but does not fail -----------------------------
run_case "$tmp/long-item" --report-only "$tmp/long-item/page.md"
assert_eq "$code" "0" "ac-9 --report-only always exits 0"
assert_contains "$out" "list item is" "ac-9 --report-only still prints the violations"

# --- the style pages themselves must satisfy every rule ----------------
assert_file_exists "$root/docs/style.md" "ac-9 the English style page exists"
assert_file_exists "$root/docs/style.zh-CN.md" "ac-9 the Chinese style page exists"
run_case "$root" docs/style.md docs/style.zh-CN.md
assert_eq "$code" "0" "ac-9 the style pages obey their own rules"
if [[ $code -ne 0 ]]; then
  printf '%s\n' "$out" >&2
fi

# --- the real documents are the hard gate ------------------------------
# Until the rest of the pages are rewritten this is expected to fail; the point of the
# gate is that it fails loudly instead of passing a page nobody checked.
out=$(python3 "$checker" docs 2>&1)
code=$?
assert_eq "$code" "0" "ac-9 every real document obeys the style rules"
if [[ $code -ne 0 ]]; then
  printf '%s\n' "$out" >&2
fi

# --- the design checker reuses the same rules --------------------------
assert_contains "$(python3 scripts/check_design.py no-such-check 2>&1 || true)" "docs-style" \
  "ac-10 check_design lists the docs-style check"
assert_contains "$(python3 scripts/check_design.py all 2>&1 || true)" "docs-style" \
  "ac-10 check_design all includes the docs-style check"

out=$(python3 scripts/check_design.py docs-style 2>&1)
code=$?
assert_eq "$code" "0" "ac-10 check_design.py docs-style passes"
if [[ $code -ne 0 ]]; then
  printf '%s\n' "$out" >&2
fi

finish
