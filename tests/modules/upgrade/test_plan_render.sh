#!/usr/bin/env bash
# Module: upgrade
# The plan block: platform/lib/ab-plan.sh renders it, tests/fixtures/ab-plan/*.plan feed it.
#
# One block describes a base switch, its package follow and the configuration it will touch
# (design.md §6). It is the last thing a person reads before a firmware write, on a console
# whose width nobody chose, so the layout is a contract and not a preference:
#
#   ac-3  Update / Packages / Config sections, one blank line apart
#   ac-3  field rows `  - label   value`, the label column as wide as the longest label
#   ac-3  a value that does not fit moves under its label at 6 spaces
#   ac-3  gaps grouped `  STATE  (n)   cause`, members `    - name version`, effect at 6
#   ac-3  order ABI STALE, UNREACHABLE, NO COPY, DROPPED, PINNED - whatever the input order
#   ac-3  `(n)` counted from the members printed under it
#   ac-3  60, 80 and 100 columns: no line wider than the terminal, no name cut
#   ac-3  a feed URL too long for the line keeps both ends (`...`), it does not overflow
#   ac-3  ASCII only
#
# The renderer is driven through tests/fixtures/ab-plan/driver.sh under /bin/sh, because the
# device's shell is busybox ash: a bash-only `${var:offset}` or `local` would pass here and
# fail on the machine.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-plan.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the plan library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi
driver="$root/tests/fixtures/ab-plan/driver.sh"
fixtures="$root/tests/fixtures/ab-plan"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() { # render <plan-file> <columns>: stdout in $OUT, exit code in $RC
  OUT=$(COLUMNS=$2 /bin/sh "$driver" "$root" render "$1" 2>"$tmp/err")
  RC=$?
}

# widest: the length of the longest line in $1 (a file), 0 for an empty file.
widest() {
  awk '{ if (length($0) > m) m = length($0) } END { printf "%d", m + 0 }' "$1"
}

# over <file> <columns>: how many lines are wider than <columns>.
over() {
  awk -v w="$2" 'length($0) > w { n++ } END { printf "%d", n + 0 }' "$1"
}

# gaps <file>: the state header of every gap group, in the order printed.
gaps() {
  sed -n 's/^  \([A-Z][A-Z ]*[A-Z]\)  ([0-9][0-9]*)\(   .*\)\{0,1\}$/\1/p' "$1"
}

# members <file>: every `    - name version` line, without its indent.
members() {
  sed -n 's/^    - //p' "$1"
}

# value_columns <file>: the 1-based column where a row's value starts, one number per row
# that carries its value on the same line. One distinct number means the column is a column.
value_columns() {
  awk '
    /^  - / {
      rest = substr($0, 5)
      label = rest
      sub(/ .*/, "", label)
      if (label == rest) next                     # a label alone: its value was wrapped
      after = substr(rest, length(label) + 1)
      body = after
      sub(/^ +/, "", body)
      pad = length(after) - length(body)
      if (pad < 2) next                           # one space is prose, not a column
      print 5 + length(label) + pad
    }' "$1" | sort -u
}

# group_counts_match <file>: 0 when every `(n)` equals the number of members under it.
group_counts_match() {
  awk '
    function close_group() {
      if (head != "" && got != want) {
        printf "%s says %d, %d members\n", head, want, got
        bad = 1
      }
      head = ""
    }
    /^  [A-Z]/ {
      close_group()
      line = $0
      if (match(line, /\([0-9]+\)/) == 0) next
      head = line
      want = substr(line, RSTART + 1, RLENGTH - 2) + 0
      got = 0
      next
    }
    /^    - / { if (head != "") got++ }
    END { close_group(); exit bad }' "$1"
}

# --- the width the block is rendered at -------------------------------------
# design.md §6: clamp(${COLUMNS:-80}, 60, 100), falling back COLUMNS -> tput cols -> 80.
# Both fallbacks are given a fake tput so the test does not depend on the terminal it runs
# in: a suite that reads the real terminal fails on CI and passes on a laptop.
mkdir -p "$tmp/bin90" "$tmp/empty"
printf '#!/bin/sh\nprintf "90\\n"\n' >"$tmp/bin90/tput"
chmod +x "$tmp/bin90/tput"

assert_eq "$(COLUMNS=60 /bin/sh "$driver" "$root" width)" "60" "60 columns is taken as is"
assert_eq "$(COLUMNS=80 /bin/sh "$driver" "$root" width)" "80" "80 columns is taken as is"
assert_eq "$(COLUMNS=100 /bin/sh "$driver" "$root" width)" "100" "100 columns is taken as is"
assert_eq "$(COLUMNS=40 /bin/sh "$driver" "$root" width)" "60" "below 60 the block keeps 60 and wraps"
assert_eq "$(COLUMNS=8 /bin/sh "$driver" "$root" width)" "60" "a silly narrow terminal still gets 60"
assert_eq "$(COLUMNS=200 /bin/sh "$driver" "$root" width)" "100" "above 100 the block keeps 100"
assert_eq "$(COLUMNS=080 /bin/sh "$driver" "$root" width)" "80" "a leading zero is not read as octal"
assert_eq "$(env -u COLUMNS PATH="$tmp/bin90" /bin/sh "$driver" "$root" width)" "90" \
  "without COLUMNS the width comes from tput"
assert_eq "$(env -u COLUMNS PATH="$tmp/empty" /bin/sh "$driver" "$root" width)" "80" \
  "with neither COLUMNS nor tput it is 80"
assert_eq "$(COLUMNS=70 PATH="$tmp/bin90" /bin/sh "$driver" "$root" width)" "70" \
  "COLUMNS wins over tput"
assert_eq "$(COLUMNS=wide PATH="$tmp/bin90" /bin/sh "$driver" "$root" width)" "90" \
  "a non-numeric COLUMNS falls through to tput"

# --- ac-3: nothing overflows, at any width, for any plan --------------------
for plan in plan-mixed plan-clean plan-long; do
  for cols in 60 80 100; do
    render "$fixtures/$plan.plan" "$cols"
    printf '%s\n' "$OUT" >"$tmp/$plan.$cols"
    assert_eq "$RC" "0" "the $plan plan renders at $cols columns"
    assert_eq "$(over "$tmp/$plan.$cols" "$cols")" "0" \
      "no line of $plan is wider than $cols columns (widest $(widest "$tmp/$plan.$cols"))"
    assert_eq "$(LC_ALL=C grep -c '[^ -~]' "$tmp/$plan.$cols" || true)" "0" \
      "$plan at $cols columns is ASCII only"
    assert_eq "$(group_counts_match "$tmp/$plan.$cols" && echo ok)" "ok" \
      "$plan at $cols columns: every group count matches the members printed under it"
  done
done

# --- ac-3: the three sections, in order, one blank line apart ----------------
render "$fixtures/plan-mixed.plan" 80
printf '%s\n' "$OUT" >"$tmp/mixed.80"
assert_eq "$(head -n 1 "$tmp/mixed.80")" "Update" "the block opens with Update"
assert_eq "$(sed -n '2p' "$tmp/mixed.80")" "  - base       25.12.2 -> 25.12.0" \
  "the first field row is a base change, label column aligned"
assert_eq "$(grep -n '^Packages$' "$tmp/mixed.80" | cut -d: -f1 | head -n 1)" "9" \
  "Update's five rows, then the blank line, then Packages"
assert_eq "$(sed -n '8p' "$tmp/mixed.80")" "" "Packages is preceded by exactly one blank line"
assert_eq "$(grep -c '^Config$' "$tmp/mixed.80")" "1" "Config appears once"
assert_eq "$(grep -c '^Update$' "$tmp/mixed.80")" "1" "Update appears once"
assert_eq "$(grep -c '^Packages$' "$tmp/mixed.80")" "1" "Packages appears once"
assert_eq "$(awk '/^Packages$/{p=NR} /^Config$/{c=NR} END{print (c > p)}' "$tmp/mixed.80")" "1" \
  "Packages comes before Config"

# --- ac-3: the label column is one column ----------------------------------
assert_eq "$(value_columns "$tmp/mixed.80")" "16" \
  "every row that carries its value inline starts it at the same column"
assert_eq "$(value_columns "$tmp/plan-clean.100")" "16" \
  "the column is the longest label (platform, 8) plus the 3 spaces of gap"
assert_eq "$(grep -c '^  - ' "$tmp/mixed.80")" "9" \
  "nine field rows are printed as rows (5 Update, 2 Packages, 2 Config)"
assert_eq "$(grep -c '^   [^ ]' "$tmp/mixed.80" || true)" "0" \
  "nothing is indented by a single space: rows are 2, members 4, wrapped text 6"

# --- ac-3: gaps, their order, their counts ---------------------------------
assert_eq "$(gaps "$tmp/mixed.80" | tr '\n' '|')" \
  "ABI STALE|UNREACHABLE|NO COPY|DROPPED|PINNED|" \
  "the five states print in the one documented order, whatever order the plan lists them in"
assert_eq "$(gaps "$tmp/plan-long.100" | tr '\n' '|')" "ABI STALE|NO COPY|SUPERSEDED SIDEWAYS|" \
  "an unknown state still prints, after the known ones"
assert_eq "$(gaps "$tmp/plan-clean.100" | wc -l | tr -d ' ')" "0" \
  "a follow with no gap prints no group at all"

# The count line and the entries under it are written by two different hands: the caller
# counts what it is holding back, the renderer counts what it printed. They agree in the
# fixture, and this is the assertion that keeps them agreeing.
for plan in plan-mixed plan-long plan-clean; do
  render "$fixtures/$plan.plan" 100
  printf '%s\n' "$OUT" >"$tmp/$plan.counts"
  held=$(sed -n 's/^  - follow  .* \([0-9][0-9]*\) held back,.*/\1/p' "$tmp/$plan.counts")
  assert_eq "$(members "$tmp/$plan.counts" | grep -c . || true)" "$held" \
    "$plan: the $held packages counted as held back are the ones listed"
  count=$(sed -n 's/^count //p' "$fixtures/$plan.plan")
  assert_eq "$(sed -n 's/^  - follow  *\([0-9][0-9]*\) to follow,.*/\1/p' "$tmp/$plan.counts")" "$count" \
    "$plan: the count line follows what the plan says it will follow"
done

# --- ac-3: package names are never cut, versions never lost ----------------
for plan in plan-mixed plan-long; do
  render "$fixtures/$plan.plan" 60
  printf '%s\n' "$OUT" >"$tmp/$plan.names"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_eq "$(grep -c -- "- $name" "$tmp/$plan.names")" "1" \
      "$plan at 60 columns keeps the name $name whole"
  done < <(sed -n 's/^member \([^ ]*\).*/\1/p' "$fixtures/$plan.plan")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    version=${line##* }
    assert_eq "$(grep -c -- "$version" "$tmp/$plan.names" | awk '{print ($1 > 0)}')" "1" \
      "$plan at 60 columns still shows the version $version"
  done < <(sed -n 's/^member [^ ]* \(.*\)/\1/p' "$fixtures/$plan.plan")
done

# --- ac-3: a URL too wide for the line keeps both ends --------------------
for cols in 60 80 100; do
  render "$fixtures/plan-mixed.plan" "$cols"
  printf '%s\n' "$OUT" >"$tmp/url.$cols"
  url=$(sed -n 's/^gap unreachable .*\(https:\/\/[^ ]*\).*/\1/p' "$fixtures/plan-mixed.plan")
  assert_eq "$(grep -c -F -- "$url" "$tmp/url.$cols" || true)" "0" \
    "at $cols columns the whole URL is not printed inside a line that must fit"
  assert_eq "$(grep -c 'https://' "$tmp/url.$cols")" "1" "at $cols columns the URL is still named"
  assert_eq "$(grep -c '\.\.\.' "$tmp/url.$cols")" "1" "at $cols columns the missing middle is marked"
done
assert_eq "$(sed -n 's/.*\(https:\/\/[^ ]*\)$/\1/p' "$tmp/url.80" | head -n 1)" \
  "https://mirror.some-long-domain-name...argets/x86/64/packages/packages.adb" \
  "the elided URL keeps its scheme and its file name"
assert_eq "$(grep -c 'did not answer' "$tmp/url.80")" "1" \
  "the rest of the cause survives the elision"

# --- ac-3: the tail of the block -----------------------------------------
assert_eq "$(grep -c '^NOTE: ' "$tmp/mixed.80")" "1" "the configuration note is printed"
assert_eq "$(grep -c '^WARNING: ' "$tmp/mixed.80")" "1" \
  "the warning about held back packages is printed"
assert_eq "$(awk '/^NOTE: /{n=NR} /^WARNING: /{w=NR} END{print (w > n)}' "$tmp/mixed.80")" "1" \
  "NOTE comes before WARNING, the order the plan writes them in"
assert_eq "$(awk '/^Config$/{c=NR} /^  [A-Z][A-Z ]*  \(/{s=NR} END{print (s < c)}' "$tmp/mixed.80")" "1" \
  "the gap groups belong to Packages: they all print before Config"
assert_eq "$(grep -c 'Proceed' "$tmp/mixed.80" || true)" "0" \
  "the question is not part of the block on stdout"
assert_eq "$(grep -c '^WARNING: ' "$tmp/plan-clean.100" || true)" "0" \
  "a follow with nothing held back prints no warning"
assert_eq "$(grep -c '^NOTE: ' "$tmp/plan-clean.100")" "1" \
  "a follow with nothing held back still gets its note"

# --- ac-3: wrapped text goes to 6 spaces --------------------------------
render "$fixtures/plan-mixed.plan" 60
printf '%s\n' "$OUT" >"$tmp/wrap.60"
assert_eq "$(grep -c '^      ' "$tmp/wrap.60" | awk '{print ($1 > 0)}')" "1" \
  "at 60 columns long values and causes are folded under a 6 space indent"
assert_eq "$(grep -c '^  - Risk$' "$tmp/wrap.60")" "1" \
  "a row that cannot fit leaves its label on its own line"

# --- the question text ---------------------------------------------------
assert_eq "$(/bin/sh "$driver" "$root" prompttext 232)" "Proceed and follow 232 packages? [y/N] " \
  "the question names how many packages it is about"
assert_eq "$(/bin/sh "$driver" "$root" prompttext 0)" "Proceed and follow 0 packages? [y/N] " \
  "the question keeps one shape for every count"

# --- ac-3: data this renderer cannot trust is refused, not printed ------
printf 'section Update\nbogus record here\n' >"$tmp/bogus.plan"
render "$tmp/bogus.plan" 80
assert_eq "$RC" "1" "an unknown record is refused"
assert_eq "$(grep -c 'unknown plan record' "$tmp/err")" "1" "and the refusal names the record"
render "$tmp/does-not-exist.plan" 80
assert_eq "$RC" "1" "a missing plan file is refused"
printf 'section Update\ncount many\n' >"$tmp/badcount.plan"
render "$tmp/badcount.plan" 80
assert_eq "$RC" "1" "a count that is not a number is refused"
printf 'section Packages\nmember orphan 1.0\n' >"$tmp/orphan.plan"
render "$tmp/orphan.plan" 80
assert_eq "$RC" "1" "a member outside a gap is refused"
printf 'section Packages\neffect orphan consequence\n' >"$tmp/orphan2.plan"
render "$tmp/orphan2.plan" 80
assert_eq "$RC" "1" "an effect outside a gap is refused"
printf 'section Packages\ngap pinned\n' >"$tmp/nocause.plan"
render "$tmp/nocause.plan" 80
assert_eq "$RC" "1" "a gap with no cause is refused: a group that cannot say why is not shown"

# The record writes `skipped=local:<name>` for what design.md §3 calls no-copy. Both spellings
# are the same gap, and neither may be lost or shown as an unknown state.
printf 'section Packages\nrow follow 2 to follow, 1 held back, 0 replay from local copies\ngap local local package, no .apk kept\nmember luci-app-openclash 0.46.077\ncount 2\n' >"$tmp/local.plan"
render "$tmp/local.plan" 100
printf '%s\n' "$OUT" >"$tmp/local.100"
assert_eq "$(gaps "$tmp/local.100" | tr '\n' '|')" "NO COPY|" \
  "the record's own token (local) is the NO COPY gap, not an unknown state"

# --- the device shell ----------------------------------------------------
# The suite runs under bash; the device runs busybox ash. The block is rendered again by any
# other POSIX shell on this machine - dash rejects the same bashisms ash does, and busybox is
# ash - so a `${var:1}` or a `local` fails here instead of on the machine.
posix_shells=""
for candidate in dash busybox; do
  command -v "$candidate" >/dev/null 2>&1 && posix_shells="$posix_shells $candidate"
done
if [ -n "$posix_shells" ]; then
  for shell in $posix_shells; do
    case "$shell" in
      busybox) set -- busybox sh ;;
      *) set -- "$shell" ;;
    esac
    "$@" "$driver" "$root" render "$fixtures/plan-mixed.plan" >"$tmp/other.80" 2>"$tmp/other.err"
    assert_eq "$?" "0" "$shell renders the block"
    assert_eq "$(diff -u "$tmp/mixed.80" "$tmp/other.80" | wc -l | tr -d ' ')" "0" \
      "$shell renders the block exactly as /bin/sh did"
  done
else
  printf '# neither dash nor busybox is installed here: the POSIX shell run is not covered\n'
fi

finish
