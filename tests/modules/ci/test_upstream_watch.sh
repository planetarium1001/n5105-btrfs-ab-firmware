#!/usr/bin/env bash
# Module: ci
# Guards scripts/ci/upstream-watch.sh: the version discovery the daily auto-release run
# starts from, the single write path to the pin, and the two bodies it posts.
#
# The property under test is "only a formal release is a release". The mirror lists
# `25.13.0-rc1`, `25.13.0-beta2` and `SNAPSHOT` next to the real directories, and a
# detector that took the newest name would build an image nobody can reproduce. A 24.x
# release is not a candidate either: the initramfs-tools lock and the kmods layout only
# exist from 25 on.
#
# Everything here runs offline: `CI_UPSTREAM_INDEX` points at a fixture instead of
# `curl`ing the mirror, which is also how the workflow can be rehearsed without network.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$root/scripts/ci/upstream-watch.sh"
FIXTURES="$root/tests/modules/ci/fixtures/upstream-watch"

# The pin file is the tracked one: the write path has to keep the file's comment block,
# so the fixture has to be the real thing rather than a two-line stand-in.
pin_readonly="$tmp/pin-detect.conf"
pin_writable="$tmp/pin-write.conf"
cp "$root/.github/upstream-pin.conf" "$pin_readonly"
cp "$root/.github/upstream-pin.conf" "$pin_writable"
# Kept before any run, so "detect did not touch the pin" is a real comparison and not a
# copy of whatever the run left behind.
cp "$root/.github/upstream-pin.conf" "$tmp/pin-detect.before"

# watch_run <pin-file> <output-env-file> [VAR=value ...] -- <arguments...>
# Runs the script with a scratch CI_TMP_ROOT and the caller's extra environment; the
# combined output lands in $watch_log and the exit status in $watch_status.
watch_run() {
  local pin_file="$1" out_env="$2"
  shift 2
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  watch_log="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_OUTPUT_ENV="$out_env" \
    CI_TMP_ROOT="$tmp/ci" CI_UPSTREAM_PIN_FILE="$pin_file" "${envs[@]+"${envs[@]}"}" \
    bash "$SCRIPT" "$@" 2>&1)"
  watch_status=$?
}

# output_of <output-env-file> <key>: one emitted value, empty when absent.
output_of() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# --------------------------------------------------------------------------- #
# ac-1: discovery accepts formal releases only
# --------------------------------------------------------------------------- #

watch_run "$pin_readonly" "$tmp/o-detect.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index.html" -- detect
assert_eq "$watch_status" "0" "ac-1 detect exits 0 when the index has a newer formal release"
out="$tmp/o-detect.env"
assert_eq "$(output_of "$out" changed)" "true" "ac-1 a newer formal release reads as changed=true"
assert_eq "$(output_of "$out" version)" "25.13.0" "ac-1 the version to build is the newest formal release"
assert_eq "$(output_of "$out" latest_formal)" "25.13.0" "ac-1 latest_formal is the newest formal release"
assert_eq "$(output_of "$out" current_pin)" "25.12.2" "ac-1 current_pin is the tracked pin"
assert_eq "$(output_of "$out" formal_versions)" "25.13.0 25.12.2 25.12.1 25.12.0 25.11.3" \
  "ac-1 formal_versions lists the formal releases newest first"

# The pin file is an input of `detect`; a discovery run that rewrites it would move the
# pin before the build has proven anything.
assert_command_ok "ac-1 detect leaves the pin file untouched" \
  cmp -s "$pin_readonly" "$tmp/pin-detect.before"

assert_eq "$(output_of "$out" formal_versions | grep -c 'rc\|beta' || true)" "0" \
  "ac-1 an rc or beta directory never becomes a candidate"
assert_eq "$(output_of "$out" formal_versions | grep -c 'SNAPSHOT' || true)" "0" \
  "ac-1 SNAPSHOT never becomes a candidate"
assert_contains "$watch_log" "ignored non-formal upstream entry 25.13.0-rc1" \
  "ac-1 the run log names the rc it ignored"
assert_contains "$watch_log" "ignored non-formal upstream entry 25.13.0-beta2" \
  "ac-1 the run log names the beta it ignored"

assert_eq "$(output_of "$out" formal_versions | grep -c '24\.10\.0\|22\.03\.7' || true)" "0" \
  "ac-1 upstream releases below major 25 are excluded (24.10.0, 22.03.7)"
assert_contains "$watch_log" "excluded upstream release 24.10.0" \
  "ac-1 the run log names the 24.x release it excluded"
assert_contains "$watch_log" "excluded upstream release 22.03.7" \
  "ac-1 the run log names the 22.03.7 release it excluded"

# A pin that is already the newest formal release is not an update: the workflow must be
# able to finish successfully without building anything.
watch_run "$pin_readonly" "$tmp/o-atpin.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-at-pin.html" -- detect
assert_eq "$watch_status" "0" "ac-1 detect exits 0 when the pin is current"
assert_eq "$(output_of "$tmp/o-atpin.env" changed)" "false" \
  "ac-1 pin 25.12.2 against an index whose newest formal release is 25.12.2 is changed=false"
assert_eq "$(output_of "$tmp/o-atpin.env" version)" "25.12.2" \
  "ac-1 an unchanged pin still reports the version it names"

# No formal release at all is not a failure: "there is no update" and "the index is
# empty" both have to end green, or the daily cron turns into a red run for no reason.
watch_run "$pin_readonly" "$tmp/o-empty.env" \
  "CI_UPSTREAM_INDEX=$FIXTURES/releases-index-empty.html" -- detect
assert_eq "$watch_status" "0" "ac-1 an index without formal releases still exits 0"
assert_eq "$(output_of "$tmp/o-empty.env" changed)" "false" "ac-1 an empty index reads as changed=false"
assert_eq "$(output_of "$tmp/o-empty.env" latest_formal)" "" "ac-1 an empty index reports no latest_formal"
assert_contains "$watch_log" "WARNING" "ac-1 an empty index is reported as a warning"

watch_run "$pin_readonly" "$tmp/o-missing.env" \
  "CI_UPSTREAM_INDEX=$tmp/no-such-index.html" -- detect
assert_eq "$watch_status" "1" "ac-1 a missing local index fails instead of guessing"

# --------------------------------------------------------------------------- #
# ac-1: the pin moves through ci_write_upstream_pin only
# --------------------------------------------------------------------------- #

comments_before="$(grep -c '^#' "$pin_writable")"

for rejected in latest 24.10.0 25.13; do
  watch_run "$pin_writable" "$tmp/o-reject.env" -- pin "$rejected"
  assert_eq "$watch_status" "1" "ac-1 pin refuses '${rejected}'"
  assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_writable")" "25.12.2" \
    "ac-1 a refused pin '${rejected}' leaves the pin file alone"
done

watch_run "$pin_writable" "$tmp/o-pin.env" -- pin 25.13.0
assert_eq "$watch_status" "0" "ac-1 pin accepts a supported formal release"
assert_eq "$(output_of "$tmp/o-pin.env" previous_pin)" "25.12.2" "ac-1 pin reports the previous pin"
assert_eq "$(output_of "$tmp/o-pin.env" pinned_version)" "25.13.0" "ac-1 pin reports the version it wrote"
assert_eq "$(output_of "$tmp/o-pin.env" pin_file)" "$pin_writable" "ac-1 pin reports the file it wrote"
assert_eq "$(sed -n 's/^UPSTREAM_VERSION=//p' "$pin_writable")" "25.13.0" \
  "ac-1 the pin file carries the new version"
assert_eq "$(grep -c '^UPSTREAM_VERSION=' "$pin_writable")" "1" \
  "ac-1 the pin file still declares exactly one UPSTREAM_VERSION line"
assert_eq "$(grep -c '^#' "$pin_writable")" "$comments_before" \
  "ac-1 the write keeps the explaining comment block"

# The workflow may pass the version as an input instead of an argument.
watch_run "$pin_writable" "$tmp/o-pin-env.env" CI_UPSTREAM_VERSION=25.12.3 -- pin
assert_eq "$watch_status" "0" "ac-1 pin reads CI_UPSTREAM_VERSION when no argument is given"
assert_eq "$(output_of "$tmp/o-pin-env.env" pinned_version)" "25.12.3" \
  "ac-1 the version from the environment is the one that gets pinned"

# One writer, and it is lib.sh: a second write path is how the pin and the three
# derived locks end up describing different releases.
assert_contains "$(cat "$SCRIPT")" 'ci_write_upstream_pin' \
  "ac-1 upstream-watch.sh writes the pin through ci_write_upstream_pin"
assert_eq "$(grep -cE 'sed[[:space:]]+-i' "$SCRIPT")" "0" \
  "ac-1 upstream-watch.sh never edits the pin file with sed -i"
assert_eq "$(grep -cE '>>?[[:space:]]*"[^"]*CI_UPSTREAM_PIN_FILE' "$SCRIPT")" "0" \
  "ac-1 upstream-watch.sh never redirects into the pin file"

# --------------------------------------------------------------------------- #
# ac-1: the two bodies carry what the reviewer and the on-call need
# --------------------------------------------------------------------------- #

watch_run "$pin_readonly" "$tmp/o-none.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_PREVIOUS_PIN=25.12.2 \
  CI_MATRIX_CANDIDATES="25.13.0 25.12.2 25.12.1 25.12.0" CI_MATRIX_GAPS=1 \
  CI_RUN_URL="https://github.com/example/repo/actions/runs/42" -- pr-body --out "$tmp/pr.md"
assert_eq "$watch_status" "0" "ac-1 pr-body renders"
assert_file_exists "$tmp/pr.md" "ac-1 pr-body writes the file named by --out"
pr_body="$(cat "$tmp/pr.md")"
assert_contains "$pr_body" '# Upstream 25.13.0 (pin 25.12.2 -> 25.13.0)' \
  "ac-1 the PR heading carries the version and the pin before/after"
assert_contains "$pr_body" '.github/upstream-pin.conf' "ac-1 the PR body lists the pin change"
for lock in scripts/ci/kmod-closure.json scripts/ci/runtime-closure.json \
  scripts/ci/initramfs-tools.lock.json; do
  assert_contains "$pr_body" "$lock" "ac-1 the PR body lists the derived lock ${lock}"
done
assert_contains "$pr_body" '`25.13.0 25.12.2 25.12.1 25.12.0`' \
  "ac-1 the PR body carries the matrix candidates"
assert_contains "$pr_body" 'Gap: 1' "ac-1 the PR body carries the matrix gap"
assert_contains "$pr_body" 'https://github.com/example/repo/actions/runs/42' \
  "ac-1 the PR body carries the run link"
assert_contains "$pr_body" 'Created by the daily upstream-watch run' \
  "ac-1 the PR body says the daily watch opened it"

watch_run "$pin_readonly" "$tmp/o-nogap.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_PREVIOUS_PIN=25.12.2 \
  CI_MATRIX_CANDIDATES="25.13.0 25.12.2 25.12.1 25.12.0" CI_MATRIX_GAPS=0 \
  -- pr-body --out "$tmp/pr-nogap.md"
assert_contains "$(cat "$tmp/pr-nogap.md")" 'Gap: none' \
  "ac-1 a full matrix renders the gap as none"

watch_run "$pin_readonly" "$tmp/o-issue.env" \
  CI_UPSTREAM_VERSION=25.13.0 CI_AUTO_FAILED_STAGE=s5 \
  CI_AUTO_REASON="S5-RESULT=fail reason=qemu-timeout" \
  CI_RUN_URL="https://github.com/example/repo/actions/runs/42" \
  CI_LOG_ARTIFACT=evidence-s5 -- issue-body --out "$tmp/issue.md"
assert_eq "$watch_status" "0" "ac-1 issue-body renders"
issue_body="$(cat "$tmp/issue.md")"
assert_contains "$issue_body" '25.13.0' "ac-1 the issue names the upstream version"
assert_contains "$issue_body" '`s5`' "ac-1 the issue names the failed job"
assert_contains "$issue_body" 'S5-RESULT=fail reason=qemu-timeout' "ac-1 the issue carries the reason"
assert_contains "$issue_body" 'https://github.com/example/repo/actions/runs/42' \
  "ac-1 the issue carries the run link"
assert_contains "$issue_body" '`evidence-s5`' "ac-1 the issue names the log artifact"
assert_contains "$issue_body" 'Nothing was merged, tagged or published' \
  "ac-1 the issue states that nothing was merged, tagged or published"

# An unknown subcommand has to be a usage error, not a silent no-op: a typo in the
# workflow would otherwise skip the whole release step and still look green.
watch_run "$pin_readonly" "$tmp/o-usage.env" -- publish
assert_eq "$watch_status" "1" "ac-1 an unknown subcommand exits non-zero"
assert_contains "$watch_log" "usage: upstream-watch.sh" "ac-1 an unknown subcommand prints the usage"

# --------------------------------------------------------------------------- #
# ac-1: a pin newer than the index is not a new release
#
# A pruned mirror, a lagging mirror or a pin bumped ahead of it must not turn into a
# downgrade: "the newest formal release is older than the pin" means nothing happened.
# --------------------------------------------------------------------------- #

cat >"$tmp/index-older.html" <<'HTML'
<a href="../">../</a>
<a href="25.12.1/">25.12.1/</a>
<a href="25.12.0/">25.12.0/</a>
<a href="24.10.6/">24.10.6/</a>
HTML
printf 'UPSTREAM_VERSION=25.12.2\n' >"$tmp/pin-newer.conf"
# The pin read-only fixture is not used here: the point is a pin the index cannot reach.
watch_run "$tmp/pin-newer.conf" "$tmp/o-newer.env" \
  CI_UPSTREAM_INDEX="$tmp/index-older.html" -- detect
assert_eq "$watch_status" "0" "ac-1 a pin newer than the index still exits green"
assert_eq "$(output_of "$tmp/o-newer.env" changed)" "false" \
  "ac-1 a pin newer than the index reports no change"
assert_eq "$(output_of "$tmp/o-newer.env" version)" "25.12.2" \
  "ac-1 the pin is kept, not downgraded"
assert_contains "$watch_log" "not downgrading" "ac-1 the log says why nothing happened"

finish
