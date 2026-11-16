#!/usr/bin/env bash
# Module: device
# ac-1 / ac-2 / ac-3: the switch criterion is defined once, covers the whole status line,
# and is what a plan line is rendered from.
#
# Why this file exists: one round of device acceptance asserted "every status field equal"
# around a slot switch and therefore failed on every switch, while another asserted nothing
# at all. The judgement needs one home. That home is scripts/device/lib.sh, and this test
# keeps it honest in three ways: the two groups must cover every field `ab-slot status`
# prints, a switch that moves a stable field must fail, and a switch that does not move the
# fields that carry the slot identity must fail too - "nothing changed" is the failure mode
# that looks like a pass.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The library prints through the driver's own failure path; capture that instead of letting
# it write to the test's stdout, which assert.sh owns. A script file rather than `bash -c`
# with nested quotes: the group strings are expanded inside the library's own shell, and a
# nested `bash -c` would start a shell that never sourced it.
cat >"$tmp/with-lib.sh" <<'WITHLIB'
set -uo pipefail
. "$1" >/dev/null 2>&1 || exit 90
shift
case "${1:-}" in
    --groups)    printf '%s\n' ${AB_STATUS_FIELDS_STABLE} ${AB_STATUS_FIELDS_IDENTITY} ${AB_STATUS_FIELDS_MONITORED} | LC_ALL=C sort ;;
    --stable)   printf '%s\n' ${AB_STATUS_FIELDS_STABLE} ;;
    --identity) printf '%s\n' ${AB_STATUS_FIELDS_IDENTITY} ;;
    --monitored) printf '%s\n' ${AB_STATUS_FIELDS_MONITORED} ;;
    --check)    shift; ab_status_switch_check "$@" ;;
    --expect)   shift; ab_status_switch_expect "$@" ;;
    *) echo "with-lib: unknown mode ${1:-}" >&2; exit 2 ;;
esac
WITHLIB
# AB_EVIDENCE_LOG is a *path* the library appends to, not a label: setting it to the string
# "none" made `ev` create a file called `none` in the repository root. Point it at the
# scratch dir so a failing assertion inside the library writes there instead.
run_lib() {
  AB_ASSERT_FAILURES=0 AB_STATUS_LINE= AB_EVIDENCE_LOG="$tmp/evidence.log" AB_MATRIX_CMD=none \
    bash "$tmp/with-lib.sh" "$root/scripts/device/lib.sh" "$@" 2>&1
}

# --------------------------------------------------------------------------- #
# ac-1: the three groups are disjoint and together are the whole status line
# --------------------------------------------------------------------------- #

grouped="$(run_lib --groups)"
assert_contains "${grouped}" "generation" "ac-1 generation is classified"
assert_contains "$(run_lib --monitored)" "generation" \
  "ac-1 generation is monitored, not judged: a real switch leaves it unchanged"
assert_contains "${grouped}" "packages_reason" "ac-1 packages_reason is classified"

# No field twice: a field in both groups would be judged by two contradictory rules.
dup="$(printf '%s\n' "${grouped}" | LC_ALL=C sort | uniq -d)"
assert_eq "${dup}" "" "ac-1 no field is in both groups"

# Every field the status line actually prints is classified. The list is taken from
# ab-slot's own printf, so a field added there and not here fails this test rather than
# being silently excluded from every future acceptance run.
# Two sources, because the status line is printed in two pieces: the format string carries
# most fields, and `disk=`/`method=` arrive through the %s that expands `_identity`. Reading
# only the format would silently drop them from coverage - which is the failure mode this
# assertion exists to catch, so the extraction has to match how ab-slot actually prints.
status_printf="$(grep -n "printf 'slot=" "$root/platform/usr/sbin/ab-slot" | head -n 1 | sed 's/^[0-9]*://')"
printed="$(
  printf '%s\n' "${status_printf}" | sed -e 's/%s/X/g' -e "s/^.*printf '//" -e "s/\\\\n'.*//" |
    tr ' ' '\n' | sed -n 's/^\([a-z_][a-z0-9_]*\)=.*/\1/p'
  grep -o '_identity="disk=[^"]*"' "$root/platform/usr/sbin/ab-slot" |
    sed -e 's/^_identity="//' -e 's/"$//' | tr ' ' '\n' | sed -n 's/^\([a-z_][a-z0-9_]*\)=.*/\1/p'
) "
printed="$(printf '%s\n' ${printed} | LC_ALL=C sort -u)"
assert_contains "${printed}" "packages_reason" "ac-1 the status field list was read from ab-slot"
assert_contains "${printed}" "disk" "ac-1 the identity fields are read from the expansion, not the format"
assert_contains "${printed}" "slot" "ac-1 the first field of the line is read too"
missing=""
while IFS= read -r field; do
  [ -n "${field}" ] || continue
  printf '%s\n' "${grouped}" | grep -qx "${field}" || missing="${missing} ${field}"
done <<<"${printed}"
assert_eq "${missing}" "" "ac-1 every field ab-slot status prints is in one of the two groups"

# And nothing invented: a group entry the status line does not print is a typo that would
# make the check silently skip a field it thinks it covers.
extra=""
while IFS= read -r field; do
  [ -n "${field}" ] || continue
  printf '%s\n' "${printed}" | grep -qx "${field}" || extra="${extra} ${field}"
done <<<"${grouped}"
assert_eq "${extra}" "" "ac-1 no group entry is absent from the status line"

# generation and the slot identity are the fields a switch exists to move; the health
# fields are what the acceptance is proving. Getting that split backwards would make every
# real switch fail, which is the defect this task is about.
identity_fields="$(run_lib --identity)"
monitored_fields="$(run_lib --monitored)"
stable_fields="$(run_lib --stable)"
for f in committed upper slot; do
  assert_match() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
  if assert_match "${identity_fields}" "${f}"; then
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-1 ${f} is a field a switch must move"
  else
    _assert_fail "ac-1 ${f} is a field a switch must move" "${f} is not in IDENTITY" ""
  fi
done
for f in boot esp data docker swap; do
  if assert_match "${stable_fields}" "${f}"; then
    _ASSERT_COUNT=$((_ASSERT_COUNT + 1))
    printf 'ok %d - %s\n' "$_ASSERT_COUNT" "ac-1 ${f} is a field a switch must not move"
  else
    _assert_fail "ac-1 ${f} is a field a switch must not move" "${f} is not in STABLE" ""
  fi
done

# --------------------------------------------------------------------------- #
# ac-2 / ac-3: the comparison itself, against the archived device lines
#
# These four lines are the state a real machine reported during 20261116-01
# (evidence/results/s34/), not something written to make the code look right. The first
# version of the criterion was reasoned instead, and would have failed every one of these
# switches: `generation` advances when the payload is laid down (6 before the reboot, 6
# after), and a real upgrade moves packages from unknown/other-slot to aligned/none.
# --------------------------------------------------------------------------- #

guard_h1='slot=b upper=@overlay-25.12.2-r2 generation=5 committed=b pending=none p4=ok data=ok docker=ok swap=ok next=b disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=unknown packages_reason=other-slot'
pre_h1='slot=b upper=@overlay-25.12.2-r2 generation=6 committed=b pending=a p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=unknown packages_reason=other-slot'
post_h1='slot=a upper=@overlay-25.12.2 generation=6 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=aligned packages_reason=none'
pre_h2='slot=a upper=@overlay-25.12.2 generation=7 committed=a pending=b p4=ok data=ok docker=ok swap=ok next=b disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=unknown packages_reason=other-slot'
post_h2='slot=b upper=@overlay-25.12.2-r3 generation=7 committed=b pending=none p4=ok data=ok docker=ok swap=ok next=b disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=aligned packages_reason=none'

checks() { run_lib --check "$1" "$2" M1; }

# The pair matrix.sh compares: the line captured before the payload is pushed, and the line
# the rebooted machine reports. A correct switch has to pass this.
out="$(checks "${guard_h1}" "${post_h1}")"
assert_eq "$?" "0" "ac-2 a real switch (before install -> after reboot) passes"
assert_eq "${out}" "" "ac-2 a real switch reports nothing"

# The pair an acceptance reader is tempted to use: before the reboot, after it. This is the
# one that produced the false FAILs, because generation does not move and pending does.
out="$(checks "${pre_h1}" "${post_h1}")"
assert_eq "$?" "0" "ac-2 a switch compared across the reboot passes too"
out="$(checks "${pre_h2}" "${post_h2}")"
assert_eq "$?" "0" "ac-2 the second hop's across-reboot pair passes"

# The repair this task exists for: a harness that also requires the identity fields to be
# equal fails a real switch. The check must NOT do that, and must still catch a health field
# that moved.
switched_health="$(printf '%s\n' "${post_h1}" | sed 's/ boot=ok/ boot=bad/')"
out="$(checks "${guard_h1}" "${switched_health}")"
assert_eq "$?" "1" "ac-2 a health field that moved fails"

# Nothing changed at all: the switch did not land. A check that only looked for health
# fields moving would call this a pass, which is how a half-done switch ships.
out="$(checks "${guard_h1}" "${guard_h1}")"
assert_eq "$?" "1" "ac-3 a switch that did not move the slot identity fails"
assert_contains "${out}" "unchanged_on_switch slot" "ac-3 the failure names the field that should have moved"

# The monitored fields are reported but never judged: this switch moves generation, pending,
# next, packages and packages_reason, and none of that is a failure.
assert_eq "$(checks "${guard_h1}" "${post_h1}" >/dev/null; echo $?)" "0" \
  "ac-2 monitored fields moving is not a failure"

# A field that is missing on one side is reported, not skipped: a status line that cannot be
# parsed must not read as "equal".
truncated="$(printf '%s\n' "${post_h1}" | sed 's/ boot=ok esp=ok//')"
out="$(checks "${guard_h1}" "${truncated}")"
assert_eq "$?" "1" "ac-2 a truncated status line fails"
assert_contains "${out}" "changed_stable boot" "ac-2 a missing field is named"

# An empty line is a failure of the harness, not a pass: this is the case that used to be
# written as `[ "${a}" = "${b}" ] && return 0` with both sides empty.
out="$(checks "" "${post_h1}")"
assert_eq "$?" "1" "ac-2 an empty status line fails"

# --------------------------------------------------------------------------- #
# ac-2: the plan line is rendered from the same groups
# --------------------------------------------------------------------------- #

plan="$(run_lib --expect M1 3 b)"
assert_contains "${plan}" "M1 assert boot=ok esp=ok committed=3" "ac-2 the plan names the target slot"
assert_contains "${plan}" "generation>=+1" "ac-2 the plan requires the generation to advance"
assert_contains "${plan}" "pending=none" "ac-2 the plan requires pending to clear"
assert_contains "${plan}" "upper=@overlay-b" "ac-2 the plan requires the layer to belong to the target"
# The promise about the stable half comes from the group, not from a second hand-written
# list: editing a group has to change the plan.
for f in $(run_lib --stable); do
  assert_contains "${plan}" "${f}" "ac-2 the plan promises ${f} stays equal"
done
# And the plan must say which fields it does NOT judge, so a reader cannot think they were
# asserted. That distinction is the difference between this criterion and the one that failed.
for f in $(run_lib --monitored); do
  assert_contains "${plan}" "${f}" "ac-2 the plan says ${f} is reported, not judged"
done

# --------------------------------------------------------------------------- #
# ac-2: calling the helpers must not rewrite the caller's step state
#
# The library's convention is `_`-prefixed globals reused across a step, so a helper that
# assigns `_case`/`_f` silently changes what the caller prints next. The first version of
# ab_status_switch_expect did exactly that and every plan line after the assertion grew an
# extra hop label; the dry-run skeleton test caught it, and this keeps it caught closer to
# the cause.
# --------------------------------------------------------------------------- #

cat >"$tmp/clobber.sh" <<'CLOBBER'
set -uo pipefail
. "$1" >/dev/null 2>&1 || exit 90
_case="M1"
_f="boot"
_sw_before="slot=a upper=@ov-a generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=d method=partname boot=ok esp=ok packages=aligned packages_reason=none"
_sw_after="slot=b upper=@ov-b generation=2 committed=b pending=none p4=ok data=ok docker=ok swap=ok next=b disk=d method=partname boot=ok esp=ok packages=aligned packages_reason=none"
ab_status_switch_expect "M1" "<other>" v "1/2" >/dev/null
ab_status_switch_check "${_sw_before}" "${_sw_after}" M1 >/dev/null 2>&1
printf 'case=%s f=%s\n' "${_case}" "${_f}"
CLOBBER
out="$(bash "$tmp/clobber.sh" "$root/scripts/device/lib.sh" 2>&1)"
assert_eq "${out}" "case=M1 f=boot" "ac-2 the helpers leave the caller's step variables alone"

finish
