#!/usr/bin/env bash
# Module: device
# The interactive-SSH form is the whole point of this contract, so it is asserted in the
# tree rather than remembered in a review comment.
#
# What this test exists for (measured 2026-11-17, task 20261117-03): every earlier probe that
# judged "can a person log in" ran `ssh -tt host '<cmd>' </dev/null`. dropbear 2025.89 closes
# the pty master as soon as the client's stdin reaches EOF (commit e28ba1b, `bidir_fd = 0` in
# src/svr-chansession.c plus close_chan_fd() in src/common-channel.c, upstream issue
# mkj/dropbear#365), so the child never reaches setsid()/TIOCSCTTY and the machine reports
# "interactive login is broken" while a human terminal works. A probe that writes </dev/null
# next to -tt therefore measures the client, not the machine.
#
#   ac-1 the device drivers judge interactive SSH with a held-open stdin, never with </dev/null
#
# Offline only: --dry-run prints what would be sent.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

lib="$root/scripts/device/lib.sh"
assert_file_exists "$lib" "the device driver library exists"

# 1. The primitive exists, and it is the only place the interactive form is written down.
assert_matches "$(cat "$lib")" 'dev_ssh_tty\(\)' "lib.sh defines dev_ssh_tty"

# 2. No driver may combine -tt with a /dev/null redirect. Comment lines are allowed to talk
#    about the wrong form (the docs and the probe header deliberately show it as the counter
#    example), so only lines that would run are judged.
offenders=$(
    grep -rn -- '^\s*[^#].*-tt' "$root/scripts/device" 2>/dev/null \
        | grep -- '/dev/null' || true
)
assert_eq "$offenders" "" "no driver pipes /dev/null into ssh -tt"

# 3. The held-open form is what the library actually builds: a stdin that stays open for the
#    duration of the session, not one that ends when the command line is read.
assert_matches "$(cat "$lib")" 'sleep|fifo|AB_SSH_TTY_HOLD' "dev_ssh_tty holds stdin open"

# 4. The probe that answers "can a person log in" runs, in dry-run, and would ask the machine
#    for a controlling terminal instead of assuming one.
probe="$root/scripts/device/login-probe.sh"
assert_file_exists "$probe" "the login probe exists"
out=$(AB_DRY_RUN=1 sh "$probe" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "login-probe --dry-run exits 0"
assert_contains "$out" "dry-run" "login-probe --dry-run prints the plan"
assert_matches "$out" 'pty|login' "login-probe plans the pty and login probes"

# 5. With no reachable machine it must say "skip", not "pass": a probe that cannot answer is
#    not evidence of health.
out=$(AB_HOST="root@192.0.2.1" AB_SSH_CONNECT_TIMEOUT=1 sh "$probe" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "3" "an unreachable machine is a skip, not a pass"
assert_contains "$out" "status=skip" "the skip is stated in the output"
