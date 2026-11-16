#!/usr/bin/env bash
# Module: upgrade
# ac-3 / ac-6: the protected-path list says what apk actually does, and the probe that
# asks apk about it stays runnable and judges correctly.
#
# Why this file exists: the prevention of the "platform layer shadowed by an apk upgrade"
# defect is a `+` rule in /etc/apk/protected_paths.d/*.list, and `+` is conditional by
# definition - it protects a path only when the visible file differs from the apk
# database's record. A comment that calls it unconditional, or rules rewritten as `!`,
# would read as stronger protection while changing what the boot does. Both are cheap to
# get wrong and invisible until a device is upgraded, so the shape is asserted here.
#
# The second half is the probe. Its judgement is exercised by replaying recorded device
# reports through the real script (AB_PROBE_INPUT), not by a copy of its logic: a test that
# re-implements the parser would keep passing after the parser broke.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

protected="$root/platform/etc/apk/protected_paths.d/ab-upgrade-adapter.list"
probe="$root/scripts/device/apk-protection-probe.sh"

# --------------------------------------------------------------------------- #
# ac-3 / ac-6: the rule file keeps its four `+` rules and describes `+` correctly
# --------------------------------------------------------------------------- #

assert_file_exists "$protected" "ac-3 the platform layer carries the protected-path list"
protected_src="$(cat "$protected" 2>/dev/null)"

for rel in lib/upgrade/platform.sh lib/upgrade/fwtool.sh lib/upgrade/stage2 lib/upgrade/tar.sh; do
  assert_contains "$protected_src" "+${rel}" "ac-3 ${rel} is listed with a + rule"
done
assert_eq "$(grep -c '^+' "$protected")" "4" \
  "ac-3 the list carries exactly the four upstream sysupgrade paths"

# `!` is the unconditional form. The three paths nothing shadows have to stay upgradeable,
# so none of them may be written that way.
assert_eq "$(grep -c '^!' "$protected" || true)" "0" \
  "ac-3 no rule is the unconditional '!' form"

# The condition is the whole contract, and the comment has to state it as apk defines it.
assert_contains "$protected_src" "checksum does not match the one in the apk database" \
  "ac-3 the comment states the '+' condition as apk-protected_paths(5) defines it"
assert_contains "$protected_src" "apk-protected_paths(5)" \
  "ac-3 the comment names the manual the semantics come from"
assert_contains "$protected_src" "unconditional" \
  "ac-3 the comment says which symbol is the unconditional form"
# Only platform.sh is both shipped by this layer and owned by a package, so only that one
# can fire. The words to assert on are the sentences that say so, not the bare nouns: the
# nouns `only`/`upstream`/`shadow`/`platform.sh` all appear in the old comment too, so
# asserting on them would have passed the very text this rewrite replaced.
assert_contains "$protected_src" "and only"$'\n'"# \`platform.sh\` satisfies it here" \
  "ac-3 the comment says which rule fires and which three do not"
assert_contains "$protected_src" "one rule that will fire and three that will not" \
  "ac-3 the comment states the one-of-four asymmetry in words"
assert_contains "$protected_src" "apk-protection-probe.sh" \
  "ac-3 the comment points at the device probe that checks the premise"
assert_contains "$protected_src" "that would freeze upstream fixes out" \
  "ac-3 the comment says why the three rules must not become '!'"
assert_contains "$protected_src" "apk should keep those three in step with upstream" \
  "ac-3 the comment says upgrading those three IS the intent"

# The derived list is still the general case; the four entries stay the exception.
# The layer ships exactly one file under lib/upgrade that a package also owns, which is what
# makes 'only platform.sh satisfies the premise' a fact and not a hope.
assert_eq "$(ls "$root/platform/lib/upgrade" | LC_ALL=C sort | tr '\n' ' ')" "packages.sh platform.sh " \
  "ac-3 the layer ships exactly two files under lib/upgrade"
assert_contains "$protected_src" "ab-platform-shadow.list" \
  "ac-3 the comment names the derived list that covers every other layer file"
assert_contains "$protected_src" "scripts/ci/assemble.sh" \
  "ac-3 the comment says where the derivation lives"

# --------------------------------------------------------------------------- #
# ac-1 / ac-2: the probe exists, is executable, and asks the right questions
# --------------------------------------------------------------------------- #

assert_file_exists "$probe" "ac-1 the device probe that asks apk about the premise exists"
if [ -x "$probe" ]; then
  _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
  printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-1 the probe is executable"
else
  _assert_fail "ac-1 the probe is executable" "not executable: ${probe}" ""
fi

probe_src="$(cat "$probe")"
assert_contains "$probe_src" "apk audit --backup" \
  "ac-1 the probe asks apk which protected paths differ from its database"
assert_contains "$probe_src" "sed -n 's/^U //p'" \
  "ac-1 the probe reads apk's U verdict, not a guess about file contents"
assert_contains "$probe_src" "upper" \
  "ac-2 the probe looks for a shadow in the writable layer"
# busybox on the device has no stat(1); ls -i is what identifies the live upper.
assert_contains "$probe_src" "ls -i" \
  "ac-2 the probe resolves the live upper without stat(1)"
assert_contains "$probe_src" "ab-slot status" \
  "ac-2 the probe takes the live overlay name from ab-slot, not from /proc/mounts"
assert_contains "$probe_src" "StrictHostKeyChecking=no" \
  "ac-2 the probe connects the way docs/device-matrix.md prescribes"

# --------------------------------------------------------------------------- #
# ac-1 / ac-2: the judgement, replayed through the real script
#
# A recorded device report is the plain lines the remote pass prints. Feeding one in with
# AB_PROBE_INPUT runs the same parser and the same exit-status decision that a device run
# uses, so a regression in either shows up here.
# --------------------------------------------------------------------------- #

probe_run() {
  AB_PROBE_INPUT="$1" bash "$probe" >"$tmp/out.txt" 2>&1
  probe_status=$?
}

# The healthy device: the one rule whose premise holds is seen as modified, no shadow.
# The shape is the one the remote pass prints - including the `upper` line, which the
# judgement now requires: without it the probe cannot claim there is no shadow.
cat >"$tmp/healthy.txt" <<'EOF'
adapter-rules 4
shadow-rules 1
rules lib/upgrade/fwtool.sh lib/upgrade/platform.sh lib/upgrade/stage2 lib/upgrade/tar.sh
rule lib/upgrade/fwtool.sh unmodified required=no
rule lib/upgrade/platform.sh modified required=yes
rule lib/upgrade/stage2 unmodified required=no
rule lib/upgrade/tar.sh unmodified required=no
upper /mnt/p4/@overlay-25.12.2-r3/upper
shadow lib/upgrade/fwtool.sh absent
shadow lib/upgrade/platform.sh absent
shadow lib/upgrade/stage2 absent
shadow lib/upgrade/tar.sh absent
apk-new 1
version apk-tools 3.0.5, compiled for x86_64.
EOF
probe_run "$tmp/healthy.txt"
assert_eq "$probe_status" "0" "ac-1 a modified layer path with no shadow passes"
assert_contains "$(cat "$tmp/out.txt")" "premise holds" \
  "ac-1 the passing report says the premise holds"
assert_contains "$(cat "$tmp/out.txt")" "apk-new" \
  "ac-1 the report carries the *.apk-new count the next real upgrade is judged by"

# The three conditional rules are reported but never required: they are unmodified here and
# that must not fail the run, because this layer does not replace them.
assert_contains "$(cat "$tmp/out.txt")" "lib/upgrade/tar.sh" \
  "ac-3 a path the layer does not replace is still reported"
case "$(cat "$tmp/out.txt")" in
  *"premise broken"*tar.sh* | *"tar.sh"*"premise broken"*)
    _assert_fail "ac-3 an unmodified non-layer path does not fail the run" "tar.sh was treated as required" ""
    ;;
  *)
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-3 an unmodified non-layer path does not fail the run"
    ;;
esac

# apk stopped seeing the layer's path as modified: the rule cannot fire, so this has to fail
# even though nothing shadows the layer yet. That is the whole point - the defect is silent.
sed 's/^rule lib\/upgrade\/platform.sh modified/rule lib\/upgrade\/platform.sh unmodified/' \
  "$tmp/healthy.txt" >"$tmp/unmodified.txt"
probe_run "$tmp/unmodified.txt"
assert_eq "$probe_status" "1" "ac-1 an unmodified layer path fails"
assert_contains "$(cat "$tmp/out.txt")" "premise broken" \
  "ac-1 the failing report says the premise is broken"
assert_contains "$(cat "$tmp/out.txt")" "platform.sh" \
  "ac-1 the failing report names the path that would not be protected"

# A shadow is already there: the rule did not hold at some earlier upgrade.
sed 's/^shadow lib\/upgrade\/platform.sh absent/shadow lib\/upgrade\/platform.sh present/' \
  "$tmp/healthy.txt" >"$tmp/shadowed.txt"
probe_run "$tmp/shadowed.txt"
assert_eq "$probe_status" "1" "ac-2 a shadow in the upper fails"
assert_contains "$(cat "$tmp/out.txt")" "shadow present" \
  "ac-2 the failing report says a shadow is already in front of the layer"

# No rule names a layer path: that is an unreadable premise, not a pass.
grep -v '^rule .* required=yes' "$tmp/healthy.txt" >"$tmp/norule.txt"
probe_run "$tmp/norule.txt"
assert_eq "$probe_status" "1" "ac-1 an empty premise fails"
assert_contains "$(cat "$tmp/out.txt")" "premise unknown" \
  "ac-1 the report distinguishes an unreadable premise from a broken one"

# The writable layer could not be resolved: that is not "no shadow", it is "could not look".
# This is the fail-closed case. Before the review it passed, which made the one failure
# ac-2 exists to catch - an unreadable upper - look like a healthy device.
sed 's|^upper .*|upper unresolved|' "$tmp/healthy.txt" >"$tmp/upper-unresolved.txt"
probe_run "$tmp/upper-unresolved.txt"
assert_eq "$probe_status" "1" "ac-2 an unresolved upper fails instead of passing"
assert_contains "$(cat "$tmp/out.txt")" "premise unknown" \
  "ac-2 the report says the writable layer could not be resolved"

# Same when the line is missing entirely: silence must not read as "no shadow".
grep -v '^upper ' "$tmp/healthy.txt" >"$tmp/upper-missing.txt"
probe_run "$tmp/upper-missing.txt"
assert_eq "$probe_status" "1" "ac-2 a missing upper line fails instead of passing"

# A shadow is only reported when the upper is known, so the two cannot disagree.
sed 's|^upper .*|upper /mnt/p4/@overlay-test/upper|' "$tmp/shadowed.txt" >"$tmp/shadowed-real.txt"
probe_run "$tmp/shadowed-real.txt"
assert_eq "$probe_status" "1" "ac-2 a shadow in a resolved upper still fails"

# A replay file that does not exist is an error, not a pass: the probe must not report a
# healthy device because it failed to read one.
AB_PROBE_INPUT="$tmp/healthy.txt" bash "$probe" --json >"$tmp/json.txt" 2>&1
assert_eq "$?" "0" "ac-1 the json form of a healthy report passes"
assert_contains "$(cat "$tmp/json.txt")" '"kind":"rule"' \
  "ac-1 the json form carries the parsed entries"
assert_eq "$(grep -c 'premise holds' "$tmp/json.txt" || true)" "0" \
  "ac-1 the json form carries no summary sentence, so it can be replayed"

# The documented loop has to close: what --json prints is what AB_PROBE_INPUT accepts.
AB_PROBE_INPUT="$tmp/json.txt" bash "$probe" >"$tmp/json-replay.txt" 2>&1
assert_eq "$?" "0" "ac-1 a --json report replays, as the header comment promises"

AB_PROBE_INPUT="$tmp/no-such-report.txt" bash "$probe" >"$tmp/out-missing.txt" 2>&1
assert_eq "$?" "2" "ac-1 a missing replay file exits 2 instead of passing"
assert_contains "$(cat "$tmp/out-missing.txt")" "replay input not found" \
  "ac-1 the missing replay file is named"

finish
