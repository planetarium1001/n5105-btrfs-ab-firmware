#!/usr/bin/env bash
# Module: ci
# Guards scripts/ci/matrix-select.sh: the candidate list published with every automatic
# release.
#
# The interesting neighbour of a new release is "the previous formal release", not "the
# previous release of this minor": 26.0.0 opens a minor with no history of its own, so a
# same-minor rule would leave the matrix with one entry. The list is therefore global and
# version-ordered. A 24.x release never fills a slot - it would exercise a different
# initramfs-tools and kmods layout - and a hole is recorded as `gaps` instead of being
# papered over with an older major.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SELECT="$root/scripts/ci/matrix-select.sh"
FIXTURES="$root/tests/modules/ci/fixtures/matrix-select"

# select_run <output-env-file> [arguments...]: run the selector offline and keep the
# combined output in $select_log, the exit status in $select_status.
select_run() {
  local out=$1
  shift
  select_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out" \
    CI_TMP_ROOT="$tmp/ci" bash "$SELECT" "$@" 2>&1)"
  select_status=$?
}

# output_of <output-env-file> <key>
output_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

index="$FIXTURES/releases-index.html"
sparse="$FIXTURES/releases-index-sparse.html"

# --------------------------------------------------------------------------- #
# ac-7: the newest release plus the three formal releases before it
# --------------------------------------------------------------------------- #

select_run "$tmp/o-new.env" --version 25.13.0 --index "$index" --count 3
assert_eq "$select_status" "0" "ac-7 the selector runs offline against a fixture index"
assert_eq "$(output_of "$tmp/o-new.env" candidates)" "25.13.0 25.12.2 25.12.1 25.12.0" \
  "ac-7 25.13.0 gets 25.12.2, 25.12.1 and 25.12.0 as candidates"
assert_eq "$(output_of "$tmp/o-new.env" gaps)" "0" "ac-7 a full candidate set records no gap"
assert_eq "$(output_of "$tmp/o-new.env" gap_note)" "" "ac-7 a full candidate set records no note"
assert_eq "$(output_of "$tmp/o-new.env" count)" "4" "ac-7 four candidates are reported"

# A new minor has no previous release of its own, so the list has to fall back to the
# last Zs of the previous minor rather than shrinking to one entry.
select_run "$tmp/o-minor.env" --version 26.0.0 --index "$index" --count 3
assert_eq "$(output_of "$tmp/o-minor.env" candidates)" "26.0.0 25.12.2 25.12.1 25.12.0" \
  "ac-7 26.0.0 falls back to the last three 25.x releases"
assert_eq "$(output_of "$tmp/o-minor.env" gaps)" "0" \
  "ac-7 a cross-minor candidate set is complete"
assert_eq "$(output_of "$tmp/o-minor.env" count)" "4" \
  "ac-7 a cross-minor candidate set still has four entries"

# --------------------------------------------------------------------------- #
# ac-7: a short index is a recorded gap, never a substituted older major
# --------------------------------------------------------------------------- #

select_run "$tmp/o-sparse.env" --version 25.12.3 --index "$sparse" --count 3
assert_eq "$select_status" "0" "ac-7 a short index still ends green"
assert_eq "$(output_of "$tmp/o-sparse.env" candidates)" "25.12.3 25.12.2" \
  "ac-7 25.12.3 keeps 25.12.2 and drops everything it cannot use"
assert_eq "$(output_of "$tmp/o-sparse.env" count)" "2" "ac-7 the short list reports two candidates"
assert_eq "$(output_of "$tmp/o-sparse.env" gaps)" "2" \
  "ac-7 a candidate slot no release can fill is counted as a gap: 24.x exists but cannot take it"
assert_eq "$(output_of "$tmp/o-sparse.env" gap_note)" \
  "only 1 of 3 candidate slots filled; the index publishes only 2 older formal release(s); 1 older formal release(s) are below major 25 and cannot be candidates" \
  "ac-7 the gap note names both reasons a slot stayed empty"
assert_eq "$(printf '%s' "$(output_of "$tmp/o-sparse.env" candidates)" | grep -c '24\.10\.0' || true)" "0" \
  "ac-7 24.10.0 never takes a candidate slot"
assert_contains "$select_log" "excluded candidate 24.10.0" \
  "ac-7 the run log names the 24.x release it refused to use"

# --------------------------------------------------------------------------- #
# ac-7: the candidate count is min(--count, usable previous) + 1
# --------------------------------------------------------------------------- #

# Four usable previous releases and --count 5: the count is capped by what exists, and
# the four that do exist all fit.
select_run "$tmp/o-over.env" --version 26.0.0 --index "$index" --count 5
assert_eq "$(output_of "$tmp/o-over.env" count)" "5" \
  "ac-7 four usable previous releases plus the new version is five candidates"
assert_eq "$(output_of "$tmp/o-over.env" candidates)" "26.0.0 25.12.2 25.12.1 25.12.0 25.11.3" \
  "ac-7 a larger --count reaches further back, still newest first"

# --count 1 asks for exactly one predecessor.
select_run "$tmp/o-one.env" --version 25.13.0 --index "$index" --count 1
assert_eq "$(output_of "$tmp/o-one.env" count)" "2" \
  "ac-7 --count 1 yields the new version plus one predecessor"
assert_eq "$(output_of "$tmp/o-one.env" candidates)" "25.13.0 25.12.2" \
  "ac-7 --count 1 picks the immediately previous formal release"

# The invariant itself: the reported count is the number of candidates, and the first
# candidate is always the version under build.
check_invariant() {
  local file=$1 version=$2 listed
  listed="$(output_of "$file" candidates)"
  assert_eq "$(output_of "$file" count)" "$(printf '%s\n' "$listed" | awk '{ print NF }')" \
    "ac-7 $version reports the candidate count it printed"
  assert_eq "$(printf '%s' "$listed" | awk '{ print $1 }')" "$version" \
    "ac-7 $version starts its candidate list with the version under build"
}
check_invariant "$tmp/o-new.env" "25.13.0"
check_invariant "$tmp/o-minor.env" "26.0.0"
check_invariant "$tmp/o-sparse.env" "25.12.3"
check_invariant "$tmp/o-over.env" "26.0.0"
check_invariant "$tmp/o-one.env" "25.13.0"
assert_eq "$(output_of "$tmp/o-over.env" candidates | grep -c '24\.\|22\.' || true)" "0" \
  "ac-7 no candidate is ever a release below major 25"

# --------------------------------------------------------------------------- #
# ac-7: an unusable version is refused instead of producing an empty matrix
# --------------------------------------------------------------------------- #

for bad in 24.10.0 latest 25.13 25.13.0-rc1; do
  select_run "$tmp/o-bad.env" --version "$bad" --index "$index"
  assert_eq "$select_status" "1" "ac-7 the selector refuses --version $bad"
done

select_run "$tmp/o-nover.env" --index "$index"
assert_eq "$select_status" "1" "ac-7 a missing --version fails instead of picking one"
assert_contains "$select_log" "usage: matrix-select.sh" "ac-7 a missing --version prints the usage"

select_run "$tmp/o-badcount.env" --version 25.13.0 --index "$index" --count 0
assert_eq "$select_status" "1" "ac-7 --count 0 is refused"

select_run "$tmp/o-unknown.env" --version 25.13.0 --index "$index" --verbose
assert_eq "$select_status" "1" "ac-7 an unknown argument is refused"

select_run "$tmp/o-missing.env" --version 25.13.0 --index "$tmp/no-such-index.html"
assert_eq "$select_status" "1" "ac-7 a missing index file fails instead of guessing"

# --------------------------------------------------------------------------- #
# ac-7: an index that simply has no history left is a gap too, and the note says why
# --------------------------------------------------------------------------- #

cat >"$tmp/index-thin.html" <<'HTML'
<a href="../">../</a>
<a href="25.12.2/">25.12.2/</a>
<a href="SNAPSHOT/">SNAPSHOT/</a>
HTML
select_run "$tmp/o-thin.env" --version 25.12.3 --index "$tmp/index-thin.html" --count 3
assert_eq "$(output_of "$tmp/o-thin.env" candidates)" "25.12.3 25.12.2" \
  "ac-7 a one-release history still yields the new release plus that release"
assert_eq "$(output_of "$tmp/o-thin.env" gaps)" "2" \
  "ac-7 two empty candidate slots are reported as two gaps"
assert_eq "$(output_of "$tmp/o-thin.env" gap_note)" \
  "only 1 of 3 candidate slots filled; the index publishes only 1 older formal release(s)" \
  "ac-7 the gap note blames the index when the index is what is short"

finish
