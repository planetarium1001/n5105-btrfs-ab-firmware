#!/usr/bin/env bash
# Module: device
# The C4 bad-firewall case must read the *rendered ruleset*, not a warning that names the rule.
#
# What this test exists for (measured on the lab machine 2026-11-17, task 20261117-03): the
# probe captured `fw4 print` with `2>&1`, and fw4 repeats its own
# "Section @rule[N] (ab-badcfg-rule) skipped due to invalid options" warning on stderr. The
# merged stream therefore contained the rule's name in a line that says the rule was *skipped*,
# and the case reported `adopted=yes` - a failure pointing at the firewall while the firewall
# had done exactly the right thing. Adoption is decided by stdout only.
#
#   ac-8 the bad-configuration case reports what fw4 rendered, not what fw4 warned about
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probe="$root/scripts/device/badconfig-probe.sh"
assert_file_exists "$probe" "the bad-configuration probe exists"

# 1. The rendered ruleset is captured from stdout only. A `2>&1` on that call is the bug.
merged=$(grep -n "fw4 print' 2>&1" "$probe" || true)
assert_eq "$merged" "" "fw4 print is not captured with its stderr merged"

rendered=$(grep -n "_c4_print=\$(_rsh 'fw4 print')" "$probe" || true)
assert_matches "$rendered" '^[0-9]+:[[:space:]]*_c4_print=' "fw4 print is captured from stdout"

# 2. The warning is still read from the check, which is where fw4 writes it, so the case can
#    still prove the firewall said why it skipped the section.
assert_matches "$(cat "$probe")" "_c4_chk=\\$\\(_rsh 'fw4 check' 2>&1\\)" "the warning still comes from fw4 check"
