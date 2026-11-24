# Document style

**English** | [简体中文](style.zh-CN.md)

Someone reads a page once, in a hurry, to decide whether to trust it. These rules keep that read
cheap. `scripts/check_docs_style.py` measures every rule below, and
`python3 scripts/check_design.py docs-style` runs it with the rest of the design checks.

## Pages come in pairs

- Every English page has a `*.zh-CN.md` translation beside it.
- Both pages carry the same sections in the same order.
- The checker compares heading levels one to one and fails on a shifted section.
- Only the words differ; a section added on one side is added on the other.

## The limits

| Rule | Limit | What it protects |
|---|---|---|
| Paragraph | 400 characters and 4 sentences | one screen, one argument |
| English sentence | 40 words | a sentence read in one breath |
| Chinese sentence | 80 characters, spaces removed | the same breath, counted in characters |
| List item | 240 characters | one fact per item |
| Heading | 80 characters | a title, not a summary |

- A table is exempt from the paragraph rules; a cell may run long.
- The numbers are the defaults of the checker, not suggestions.

## Prose

- One fact per sentence. Split a sentence that carries two.
- One argument per paragraph. Start another instead of adding a fifth sentence.
- Use `-` lists for parallel facts, commands and options.
- Prefer a table when the page compares three or more things.
- Keep commands, numbers, file names and quoted output exactly as they are.
- A blockquote is prose too: it is measured like a paragraph.

## Block layout

- Put one blank line before and after every heading, every table and every fence.
- Label every fence with a language: `sh`, `text`, `json` or the real one.
- Give every table a header row and a separator row.
- Use exactly one `#` per page, and never skip a heading level.
- A fence inside a list item may sit tight against the item text on both sides.
- Write relative links; every link has to resolve from the page that holds it.

## What the checker skips

The rules measure prose. These blocks are not prose, and the length rules skip them:

- text inside a fenced code block
- text inside a table row
- HTML comments
- frontmatter
- a line that is nothing but a link

One exception: a link inside a table row is still checked, because a broken link is broken wherever it sits.

## Run it locally

```sh
python3 scripts/check_docs_style.py                 # every page under docs/
python3 scripts/check_docs_style.py --report-only docs
python3 scripts/check_docs_style.py docs/style.md
python3 scripts/check_design.py docs-style
```

- A violation prints as `path:line: message`, and the run exits 1.
- `--report-only` prints the same lines and exits 0.
- `check_design.py docs-style` covers `docs/` and the four READMEs outside it.
- A sentence ends at `。！？；` or at `.` `!` `?` followed by a space and a capital.
- The two style pages are the sample: a rule that fails here is a broken rule.

## Options

| Option | Default | Effect |
|---|---|---|
| `--max-paragraph` | 400 | characters in one paragraph |
| `--max-sentence-words` | 40 | words in one English sentence |
| `--max-sentence-chars` | 80 | characters in one Chinese sentence |
| `--max-item` | 240 | characters in one list item |
| `--max-heading` | 80 | characters in one heading |
| `--root` | this checkout | base for relative paths |
| `--report-only` | off | print violations, exit 0 |

## When a page fails

- Fix the page, not the limit.
- Split the paragraph, the sentence or the item at its natural boundary.
- Re-run the same command until it reports the page as clean.
