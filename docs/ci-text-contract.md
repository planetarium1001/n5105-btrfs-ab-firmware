# CI text contract

**English** | [简体中文](ci-text-contract.zh-CN.md)

The pipeline talks to people in four places: the run page, the log block a stage leaves
behind, the issue and pull request the upstream watch opens, and the release page. Every
one of them is read under time pressure - by whoever's run just went red, or by whoever is
deciding whether to trust a release. A label that states its claim the same way every time
is faster to read than one that states it well once and differently the second time.

This page is that contract: seven rules, and six of them are asserted by
`tests/modules/ci/test_ci_text_conventions.sh`. The seventh - does the sentence read well -
needs a person, so it has its own section with the questions to ask.

## Scope

The surface is everything a CI reader sees, plus the files that render it:

| Path | What it carries |
|---|---|
| `.github/workflows/*.yml` | workflow, job and step labels; input descriptions |
| `.github/actions/*/action.yml` | the same for the six composites |
| `scripts/ci/*.sh` | the strings they print: stage summary, report, diagnostics, issue body, pull request body, release notes |
| `docs/*.zh-CN.md` | the Chinese translation of each page. This is the only place Chinese is allowed |

Code comments are outside the contract: they are read by whoever edits the file, not by
whoever reads the run. Non-English is also correct in the fixtures under `tests/modules/`
that prove the pipeline still handles non-English data.

## Rule 1 - English on the CI surface

Every non-comment line on the surface is ASCII. A run page that mixes two languages is
slower to scan and impossible to grep, and the pipeline is a tool, not a document: its
audience is whoever is on shift, not whoever shares a first language.

Machine-checked. The assertion walks the three file families above, skips comment lines,
and counts characters above `U+007F`.

## Rule 2 - A label is not a sentence

A name is a label: no trailing period, no exclamation mark, no trailing space, no leading
space. Sentence case - first word capitalised, the rest lowercase except proper nouns
(`GRUB`, `ESP`, `A/B`, `S3`). The same holds for the issue title, the pull request title
and the release title.

Machine-checked for every `name:` on the surface and for the three rendered titles.

## Rule 3 - Length caps

| Level | Cap | Why |
|---|---|---|
| workflow `name:` | 40 | the Actions sidebar truncates it |
| job `name:` | 40 | the job list is one line per job |
| step `name:` | 60 | the step list is the narrowest column on the page |
| issue, pull request, release title | 80 | the title is cut in list views |

A name that needs more than its cap is describing two things; split the step instead.

Machine-checked.

## Rule 4 - One grammatical slot per level

Each level has one shape, so a reader learns the vocabulary once.

- **Workflow.** A file that can start a run by itself is an entry point and is named
  `Firmware CI - <role>`. A file that declares `workflow_call` and nothing else cannot
  start a run, and is named for what it covers: `S<n> <semantic>` for the five stages,
  a short role phrase otherwise (`resolve upstream`, `static checks`, `release publish`).
- **Job.** A stage job is `S<n> <semantic> - <what it proves>`; every other job is a verb
  phrase (`open the pin pull request`, `merge and tag`).
- **Step.** Two shapes only. A step that acts is `<Verb phrase>`, first word an imperative
  verb from the pipeline's own vocabulary. A step that opens a phase is
  `<Marker> - <claim>`, marker one of `Boot <n>`, `Phase <n>`, `Phase <n><letter>`,
  `Fixture`, `Preflight`. A step carries no stage number: the job above it already names
  the stage.
- **Separator.** Exactly one: ` - `, space hyphen space. No parentheses, no colons, no
  middots, no em dash inside a name.

Machine-checked: the shape of every workflow name against its trigger, and the first token
of every job and step name against the two allowed shapes.

## Rule 5 - Fixed summary tables

A summary is a table, and the table has the same header wherever it appears. Headers are
lowercase, and there are five of them - no sixth is needed, so a table that wants one is
describing something the reader cannot act on:

| Header | Where |
|---|---|
| `stage \| verdict \| key line \| artifact and sha256 \| next command` | the stage summary block, one per stage |
| `stage \| verdict \| duration \| artifact` | the report's table across the pipeline |
| `field \| value` | every key-value block: report facts, pre-publish check, release inputs, issue facts |
| `job \| result` | the upstream watch's failure issue |
| `artifact \| size \| sha256` | an asset listing: release hooks and release notes |

Machine-checked: every header row on the surface must be one of the five, compared for
both content and case.

## Rule 6 - Fixed title templates

| What | Template | Example |
|---|---|---|
| Issue, automatic release failure | `[auto-release] <version>` | `[auto-release] 25.13.0` |
| Pull request, pin bump | `chore(ci): pin upstream <version>` | `chore(ci): pin upstream 25.13.0` |
| Commit on the automatic branch | `chore(ci): pin upstream <version>` | `chore(ci): pin upstream 25.13.0` |
| Pull request body heading | `# Upstream <version> (pin <old> -> <new>)` | `# Upstream 25.13.0 (pin 25.12.2 -> 25.13.0)` |
| Release, both lines | `N5105 AB firmware <version>` | `N5105 AB firmware 0.0.8` |

The issue title carries the version and nothing else, because it is also the deduplication
key: the same failure updates the same issue instead of opening a second one every day.

One release template, in one place: `release-publish.yml` owns the default, and a caller
passes `title` only when the release is not this product - which no caller does. The
upstream line publishes a new base of the same firmware, so its title names the product and
the version the tag names; a second template spelled at the call site is the same decision
made twice, and the two drift.

The release notes name the run that proved the release and the conclusion that run reached.
The conclusion is read from the run, never written as a fixed sentence: a release page that
claims five stages passed when the pipeline was asked for one stage is a false statement in
the one place a reader cannot re-derive it.

Machine-checked: both bodies are rendered by their real code path and compared line for
line, and the renderers are grepped for a hardcoded stage claim.

## Rule 7 - Structure is not text

A text change must never change what runs. The guard is
`tests/fixtures/ci-structure-fingerprint.txt`: one sorted line per structural token - the
job keys, `needs`, `uses` pins, `with` and `env` keys, `outputs` keys, input names, artifact
names, the identifiers and flags of `scripts/ci/*.sh`, and every `S1-RESULT=` … `S5-RESULT=`
token. Labels, descriptions, printed prose and comments are absent from it on purpose.

The rule for a text batch is therefore mechanical: rewrite the words, and the fingerprint
stays byte-identical. If it moves, the batch changed structure, and the difference names
exactly which key moved.

- Baseline: `ac5d65a`, taken before the first text change of the cleanup, so the file
  describes the pipeline as it was proven by CI, not as it was hoped to be.
- Regenerate with `CI_TEXT_FINGERPRINT_WRITE=1 bash tests/modules/ci/test_ci_text_conventions.sh`.
- Re-baselining is its own commit, with `# reason: <why the structure changed>` filled in
  and the fingerprint diff reviewed. A re-baseline mixed into a text batch hides the one
  thing the file exists to show.

Machine-checked: fingerprint equal to the baseline, and a non-empty `reason:` in its header.

## What a test cannot check

Six rules are cheap to assert. This one is not, so it is a review checklist for whoever
reads the diff:

- Does the label state the claim, or the action that produced it? `S2 image - four
  partitions` is a claim; `Run the image step now` is not.
- Does it survive one reading, without re-parsing? Short is not enough: `Verify the abandon
  moved the next boot to slot a` is long and still one pass.
- Is the number next to its unit - `638,976 bytes`, `53.7 MB` - and the time zone named
  when a time appears?
- Is anything said twice? A step summary that repeats the job name is a line to delete.
- Does a reader who just saw a failure know where to go next? That is what `next command`
  is for, and why it is never empty.

## Changing this contract

A rule is changed in three places in one batch: this page, its translation, and the
assertion that enforces it. A rule that is not asserted is a preference, and the honest
place for a preference is this section, not the list above. When a rename makes a rule
impractical, change the rule and say why here - the contract is meant to be read, not
defended.
