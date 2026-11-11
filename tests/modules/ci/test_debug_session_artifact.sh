#!/usr/bin/env bash
# Module: ci
# ac-1: the debug session publishes its connection string in a way a script can read.
#       That means the step creates the directory it writes into (a `stage=none` session
#       has built nothing, so nothing has created it yet), and the upload keeps failing
#       loudly instead of silently producing no artifact.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

workflow=".github/workflows/ci-debug.yml"
text="$(cat "$workflow")"

assert_contains "$text" 'mkdir -p "${CI_TMP_ROOT:?}"' \
  "ac-1 the step creates the directory before writing the connection string"
assert_contains "$text" 'session-ssh.txt' "ac-1 the connection string is still published as a file"
assert_contains "$text" 'if-no-files-found: error' \
  "ac-1 a missing artifact still fails the job instead of passing silently"
assert_contains "$text" 'limit-access-to-actor' \
  "ac-1 the session stays limited to the dispatcher's own keys"

# The order matters: creating the directory has to happen before the write, or the step
# fails exactly as it did in run 43025093316.
create_line=$(grep -n 'mkdir -p "${CI_TMP_ROOT:?}"' "$workflow" | head -n 1 | cut -d: -f1)
write_line=$(grep -n 'session-ssh.txt' "$workflow" | head -n 1 | cut -d: -f1)
assert_eq "$([ -n "$create_line" ] && [ -n "$write_line" ] && [ "$create_line" -lt "$write_line" ] && echo ordered || echo unordered)" \
  "ordered" "ac-1 the directory is created before the file is written"

finish
