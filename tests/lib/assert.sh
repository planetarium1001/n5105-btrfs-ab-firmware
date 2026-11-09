#!/usr/bin/env bash
# Assertion helpers. Source this file from a test.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../../lib/assert.sh"
#   assert_eq "actual" "expected" "message"
#   assert_file_exists path
#   assert_contains "haystack" "needle"
#
# Every failure prints a line and marks the test as failed.
# The test exits with the accumulated status at the end via `finish`.
set -uo pipefail

_ASSERT_FAILURES=0
_ASSERT_COUNT=0

_assert_fail() {
  _ASSERT_FAILURES=$((_ASSERT_FAILURES + 1))
  printf 'not ok %d - %s\n' "$_ASSERT_COUNT" "$1"
  printf '    %s\n' "${2:-}" >&2
}

assert_eq() {
  local actual=$1 expected=$2 message=${3:-values differ}
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "expected [$expected] got [$actual]"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 message=${3:-contains expected value}
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "missing [$needle]"
  fi
}

assert_file_exists() {
  local path=$1 message=${2:-file exists: $1}
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [[ -f "$path" ]]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "no such file: $path"
  fi
}

assert_matches() {
  local value=$1 pattern=$2 message=${3:-value matches pattern}
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if [[ "$value" =~ $pattern ]]; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "[$value] does not match [$pattern]"
  fi
}

assert_command_ok() {
  local message=$1
  shift
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "$message"
  else
    _assert_fail "$message" "command failed: $*"
  fi
}

finish() {
  printf '# assertions: %d, failures: %d\n' "$_ASSERT_COUNT" "$_ASSERT_FAILURES"
  [[ $_ASSERT_FAILURES -eq 0 ]]
}
