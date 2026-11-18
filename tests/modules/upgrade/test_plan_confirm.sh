#!/usr/bin/env bash
# Module: upgrade
# The question after the plan: platform/lib/ab-plan.sh, design.md §7, ac-4.
#
# The question guards a firmware write, so the contract is narrow on purpose:
#
#   ac-4  `Proceed and follow N packages? [y/N] ` on stderr, the block on stdout
#   ac-4  exactly y Y yes YES Yes go ahead
#   ac-4  exactly n N no NO No decline
#   ac-4  any other answer, including a bare Enter, reprints the same line and does not move
#   ac-4  EOF is a refusal: `declined, nothing was written reason=declined`
#   ac-4  no terminal and no --yes: refused with reason=noninteractive, exit 74, zero writes
#   ac-4  --yes / --system-only / --no-follow ask nothing
#   ac-4  nothing is written before a yes
#
# Both paths are driven through a pipe - a terminal is not needed and not emulated with a
# pty, because the only difference between the two paths is whether `[ -t 0 ]` answers yes.
# AB_PLAN_ASSUME_TTY=1 is the documented stand-in for "a terminal is attached", the same way
# ab-upgrade already does it (AB_UPGRADE_ASSUME_TTY), and it is deliberately the only thing
# that variable does: it does not widen the accepted answers.
#
# "Nothing was written" is asserted at the call site, which is where the rule lives: the
# driver writes a marker file after a yes and only after a yes, the way ab-upgrade writes a
# slot. Every refusal and every decline must leave that directory empty.
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
mixed="$root/tests/fixtures/ab-plan/plan-mixed.plan"
clean="$root/tests/fixtures/ab-plan/plan-clean.plan"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# run_present <plan> <mode> <stdin-text> [<terminal: 1|0>]
#
# <stdin-text> is what the person would type, with \n between the lines (`printf %b`).
# Leaves behind: RC, MARKER (yes|no), WROTE (files the caller wrote), PROMPTS (how many times
# the question reached stderr), OUT and ERR (the two streams, read back separately).
run_present() {
  _rp_term=${4:-0}
  _rp_dir="$tmp/writes"
  rm -rf "$_rp_dir"
  mkdir -p "$_rp_dir"
  if [ "$_rp_term" = "1" ]; then
    export AB_PLAN_ASSUME_TTY=1
  else
    unset AB_PLAN_ASSUME_TTY
  fi
  printf '%b' "$3" | /bin/sh "$driver" "$root" present "$1" "$2" "$_rp_dir/marker" \
    >"$tmp/out" 2>"$tmp/err"
  RC=$?
  unset AB_PLAN_ASSUME_TTY
  MARKER=no
  [ -f "$_rp_dir/marker" ] && MARKER=yes
  WROTE=$(find "$_rp_dir" -type f ! -name marker | wc -l | tr -d ' ')
  # The prompt has no trailing newline - the answer is typed on the same line - so the
  # occurrences are counted, not the lines: grep -c would report 1 however many times it was
  # printed.
  PROMPTS=$(grep -o 'Proceed and follow' "$tmp/err" | wc -l | tr -d ' ')
  OUT=$(cat "$tmp/out")
  ERR=$(cat "$tmp/err")
}

# run_ask <n> <mode> <stdin-text> [<terminal>]: the question without a block.
run_ask() {
  _ra_term=${4:-0}
  if [ "$_ra_term" = "1" ]; then
    export AB_PLAN_ASSUME_TTY=1
  else
    unset AB_PLAN_ASSUME_TTY
  fi
  printf '%b' "$3" | /bin/sh "$driver" "$root" ask "$1" "$2" >"$tmp/out" 2>"$tmp/err"
  RC=$?
  unset AB_PLAN_ASSUME_TTY
  PROMPTS=$(grep -o 'Proceed and follow' "$tmp/err" | wc -l | tr -d ' ')
  OUT=$(cat "$tmp/out")
  ERR=$(cat "$tmp/err")
}

# --- ac-4: the accepted set is exactly five answers ------------------------
# `yesterday` and `yess` start with a y and must not count: the old prompt in ab-upgrade
# matched on the first character, and that is the bug this set exists to keep out.
for answer in y Y yes YES Yes; do
  run_present "$mixed" follow "$answer\n" 1
  assert_eq "$RC" "0" "the answer [$answer] goes ahead"
  assert_eq "$MARKER" "yes" "the answer [$answer] is what lets the caller write"
  assert_eq "$PROMPTS" "1" "the answer [$answer] is accepted on the first question"
  assert_eq "$(printf '%s' "$OUT" | grep -c 'declined' || true)" "0" \
    "the answer [$answer] is not also a refusal"
done

# --- ac-4: the refused set is exactly five answers ------------------------
for answer in n N no NO No; do
  run_present "$mixed" follow "$answer\n" 1
  assert_eq "$RC" "10" "the answer [$answer] declines"
  assert_eq "$MARKER" "no" "the answer [$answer] writes nothing"
  assert_eq "$WROTE" "0" "the answer [$answer] leaves the caller with nothing written"
  assert_eq "$PROMPTS" "1" "the answer [$answer] is accepted as a refusal at once"
  assert_eq "$(printf '%s' "$OUT" | grep -c 'ab-plan: declined, nothing was written reason=declined')" "1" \
    "the answer [$answer] is reported as reason=declined on stdout"
done

# --- ac-4: anything else reprints the line and does not move -------------
# A bare Enter is at the top of this list on purpose: design.md §7 rejects "Enter means yes",
# and docs/update.md has promised the same since ac-15.
for answer in "" "yesterday" "yess" "1" "0" "ok" "True" "Y E S" " y"; do
  run_present "$mixed" follow "$answer\ny\n" 1
  assert_eq "$RC" "0" "[$answer] does not move the question on, and the next y does"
  assert_eq "$PROMPTS" "2" "[$answer] is answered by printing the same line again"
  assert_eq "$MARKER" "yes" "after [$answer] the y is what lets the caller write"
done
run_present "$mixed" follow "nope\nalso nope\ny\n" 1
assert_eq "$RC" "0" "two unrecognised answers then a y still goes ahead"
assert_eq "$PROMPTS" "3" "every unrecognised answer reprints the line, none of them is skipped"

# --- ac-4: EOF is a refusal ---------------------------------------------
for answer in "" "nope\n" "\n" "yesterday\n"; do
  run_present "$mixed" follow "$answer" 1
  assert_eq "$RC" "10" "stdin closing after [$answer] is a refusal, not an error"
  assert_eq "$MARKER" "no" "EOF after [$answer] writes nothing"
  assert_eq "$WROTE" "0" "EOF after [$answer] leaves the caller with nothing written"
  assert_eq "$(printf '%s' "$OUT" | grep -c 'reason=declined')" "1" \
    "EOF after [$answer] says reason=declined"
done
run_present "$mixed" follow "" 1
assert_eq "$PROMPTS" "1" "EOF straight away asks exactly once"
# An answer that arrives without its newline is still an answer: `printf y` from a script,
# or a terminal closed right after the key, is a person who said yes.
run_present "$mixed" follow "y" 1
assert_eq "$RC" "0" "an unterminated y is a yes, not an EOF refusal"
assert_eq "$MARKER" "yes" "an unterminated y lets the caller write"

# --- ac-4: no terminal and no --yes is a refusal, before anything is shown ---
run_present "$mixed" follow "y\n" 0
assert_eq "$RC" "74" "a piped stdin without --yes is refused with 74"
assert_eq "$MARKER" "no" "the refusal writes nothing"
assert_eq "$WROTE" "0" "the refusal leaves the caller with nothing written"
assert_eq "$(printf '%s' "$OUT" | grep -c 'refused, reason=noninteractive')" "1" \
  "the refusal names the reason on stdout"
assert_eq "$(printf '%s' "$OUT" | grep -c '^Update$' || true)" "0" \
  "the refusal comes before the block: a plan nobody can accept is not printed"
assert_eq "$ERR" "" "nothing is asked, so nothing is prompted"

# Only 1 stands in for a terminal. A variable that happens to be set must not be able to
# turn a script into an interactive session.
AB_PLAN_ASSUME_TTY=0 /bin/sh "$driver" "$root" present "$mixed" follow "$tmp/none" \
  </dev/null >"$tmp/out" 2>"$tmp/err"
assert_eq "$?" "74" "AB_PLAN_ASSUME_TTY=0 is not a terminal"

# --- ac-4: the three escapes ask nothing --------------------------------
for mode in yes system-only no-follow; do
  run_present "$mixed" "$mode" "" 0
  assert_eq "$RC" "0" "--$mode on a pipe goes ahead without asking"
  assert_eq "$MARKER" "yes" "--$mode is a decision, so the caller writes"
  assert_eq "$ERR" "" "--$mode prints no question"
  assert_eq "$(printf '%s' "$OUT" | grep -c '^WARNING: ')" "1" \
    "--$mode still shows the block it decided about"
done
run_present "$mixed" yes "" 1
assert_eq "$ERR" "" "--yes asks even when a terminal is attached"

# --- ac-4: both streams are separate ------------------------------------
run_present "$mixed" follow "y\n" 1
assert_eq "$ERR" "Proceed and follow 232 packages? [y/N] " \
  "the whole of stderr is the question, and the question is all of it"
assert_eq "$(printf '%s' "$OUT" | grep -c 'Proceed' || true)" "0" \
  "the question is not on stdout, so a redirected report stays a report"
assert_eq "$(printf '%s' "$OUT" | grep -c '^Update$')" "1" \
  "the block is on stdout"
run_present "$mixed" follow "n\n" 1
assert_eq "$(printf '%s' "$OUT" | grep -c 'reason=declined')" "1" \
  "the decline is part of the report on stdout"

# --- ac-4: the number in the question is the plan's own count ----------
run_present "$clean" follow "y\n" 1
assert_eq "$ERR" "Proceed and follow 8 packages? [y/N] " \
  "the question asks about the count the plan printed, not a number passed beside it"
assert_eq "$RC" "0" "a plan that follows 8 packages is accepted like any other"

# --- a plan the question cannot describe is refused, not asked ----------
printf 'section Update\nrow base 25.12.2 -> 25.12.0\n' >"$tmp/nocount.plan"
run_present "$tmp/nocount.plan" follow "y\n" 1
assert_eq "$RC" "1" "a plan without a count is refused instead of asking about 0 packages"
assert_eq "$MARKER" "no" "the refusal writes nothing"
run_present "$tmp/nocount.plan" yes "" 0
assert_eq "$RC" "0" "--yes does not need the count: nothing is asked"

# --- the answer sets on their own -------------------------------------
# The question is also asked outside a block (ab-packages replay), so ask() is driven alone.
for answer in y Y yes YES Yes; do
  run_ask 3 follow "$answer\n" 1
  assert_eq "$RC" "0" "ask: [$answer] goes ahead"
done
for answer in n N no NO No; do
  run_ask 3 follow "$answer\n" 1
  assert_eq "$RC" "10" "ask: [$answer] declines"
done
run_ask 3 follow "maybe\nyes\n" 1
assert_eq "$RC" "0" "ask: an unrecognised answer then yes goes ahead"
assert_eq "$PROMPTS" "2" "ask: the unrecognised answer reprints the line"
run_ask 3 follow "" 1
assert_eq "$RC" "10" "ask: EOF declines"
assert_eq "$(printf '%s' "$OUT" | grep -c 'reason=declined')" "1" "ask: EOF says reason=declined"

# An unknown mode is not an escape: it asks, because asking is never the unsafe choice.
run_ask 3 something-else "y\n" 1
assert_eq "$RC" "0" "ask: an unknown mode still asks and honours the answer"
assert_eq "$PROMPTS" "1" "ask: an unknown mode is not treated as --yes"

finish
