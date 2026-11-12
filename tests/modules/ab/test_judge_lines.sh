#!/usr/bin/env bash
# Module: ab
# Verifies the contract between the boot stages and the report: the judge lines keep
# their frozen shape, and the slot the stage claims to have booted can no longer be
# smuggled in through the kernel command line.
#   ac-1 no workflow injects ab.slot= any more, and the boots that must follow GRUB ask
#        the harness for a firmware boot
#   ac-2 the judge lines of every stage parse with the documented extractors
#   ac-3 the scripts that print the judge lines still print the frozen format
#   ac-4 the report input names the workflow publishes are unchanged
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

workflows="$root/.github/workflows"

# field <line> <key>: the value of one key=value field, the extractor the stages use.
field() {
  printf '%s' "$1" | sed -n "s/.*[ =]$2=\([^ ]*\).*/\1/p"
}

result_of() { # <line>: the <PREFIX>=<verdict> part
  printf '%s' "$1" | cut -d' ' -f1
}

# --------------------------------------------------------------------------- #
# ac-1: the slot is chosen by GRUB, not injected
# --------------------------------------------------------------------------- #

for workflow in ci-s3 ci-s4 ci-s5; do
  body=$(cat "$workflows/${workflow}.yml")
  assert_eq "$(printf '%s\n' "$body" | grep -c 'CI_QEMU_APPEND_EXTRA: *ab\.slot=')" "0" \
    "ac-1 ${workflow} no longer injects ab.slot="
done

# The stages that have to prove slot selection hand the machine to the firmware.
for workflow in ci-s4 ci-s5; do
  body=$(cat "$workflows/${workflow}.yml")
  assert_eq "$(printf '%s\n' "$body" | grep -c 'mode: uefi-disk')" "4" \
    "ac-1 ${workflow} boots every phase through the ESP"
done
s3_body=$(cat "$workflows/ci-s3.yml")
assert_eq "$(printf '%s\n' "$s3_body" | grep -c 'mode: uefi-disk')" "1" \
  "ac-1 ci-s3 adds one firmware boot through the ESP"

# Each of those stages has to check the ESP before booting it, and the check has to be
# the shared one: the ESP is what the firmware reads, not what the renderer produced.
render_script=$(cat "$root/scripts/ci/grub-render.sh")
assert_contains "$render_script" '--verify-esp' \
  "ac-1 grub-render owns the ESP verification mode"
for workflow in ci-s3 ci-s4 ci-s5; do
  body=$(cat "$workflows/${workflow}.yml")
  assert_contains "$body" 'grub-render.sh --verify-esp' \
    "ac-1 ${workflow} verifies the ESP it boots"
done

# The QEMU knobs below are the qemu-boot composite's inputs, not job env: the composite is
# the one place that starts a guest, so the assertions read its call sites.
#
# A firmware boot runs the *production* initramfs: there is no /s3.sh and no probe
# judge line, so a step that waits for one can only time out. The run has to stop on a
# line our own hooks print, and grade those lines afterwards.
s3_body_for_judge=$(cat "$workflows/ci-s3.yml")
assert_eq "$(printf '%s\n' "$s3_body_for_judge" | grep -c 'judge-prefix: S3-RESULT')" "2" \
  "ac-1 only the two probe boots expect an S3-RESULT line"
assert_contains "$s3_body_for_judge" 'stop-pattern: "^ab-boot: stage="' \
  "ac-1 the GRUB boot stops on our own boot hook's first line"
assert_contains "$s3_body_for_judge" "grep -qE 'ab-boot: stage=device .*disk=/dev/vda'" \
  "ac-1 the GRUB boot has to prove our initramfs ran, from the serial log"
assert_contains "$s3_body_for_judge" "grep -q 'ab-boot: running slot'" \
  "ac-1 the GRUB boot has to reach the boot hook's slot report"

# A failed boot must stop the run with evidence instead of burning the timeout, so the
# phases after it can report a reason.
for workflow in ci-s4 ci-s5; do
  body=$(cat "$workflows/${workflow}.yml")
  assert_contains "$body" 'ab-commit: stage=healthcheck-done .*result=fail' \
    "ac-1 ${workflow} stops the run when the health check never decides"
  assert_contains "$body" 'ab-boot: stage=boot result=fail' \
    "ac-1 ${workflow} stops the run when the boot hook cannot mount the ESP"
done

# ab-phase.sh --expect-log greps with -F (a literal fragment), so the phase
# assertions must be literals that appear in the ring log line - a regex would never
# match and the phase would fail for the wrong reason.
s4_body_for_judge=$(cat "$workflows/ci-s4.yml")
assert_contains "$s4_body_for_judge" "--expect-log 'stage=device'" \
  "ac-1 the s4 phases assert our boot hook ran (literal fragment)"
assert_contains "$s4_body_for_judge" "--expect-log 'disk=/dev/vda'" \
  "ac-1 the s4 phases assert the disk was identified (literal fragment)"
assert_eq "$(printf '%s\n' "$s4_body_for_judge" | grep -c 'stage=device disk=/dev/vda')" "0" \
  "ac-1 no phase passes a fragment that cannot match the ring log line"

# The fixtures drive the *shipped* ab-slot against a mounted image. It reads its writer
# from the platform layer, which is installed at /lib inside the image and nowhere on the
# build host, so the fixture must hand over the repository copy - otherwise `pending`
# refuses to move the hint and the stage fails for a packaging reason.
fixtures_body=$(cat "$root/scripts/ci/ab-fixtures.sh")
assert_contains "$fixtures_body" 'AB_SLOT_CFG_LIB="${CI_REPO_ROOT}/platform/lib/ab-slot-cfg.sh"' \
  "ac-1 the fixtures point ab-slot at the repository writer"
assert_contains "$fixtures_body" 'grep -q "^set default=' \
  "ac-1 the fixtures assert the menu moved when a slot is marked pending"
assert_contains "$fixtures_body" 'grep -q "^set fallback=' \
  "ac-1 the fixtures assert the committed slot stayed the fallback"

# The ESP check has to keep asserting what the menu depends on: the loader commands,
# and the pair invariant that a failed try always has the committed slot as fallback.
assert_contains "$render_script" 'for command in source test serial' \
  "ac-1 the ESP check asserts the loader commands the menu needs"
assert_contains "$render_script" 'ab_slot_cfg_check_pair' \
  "ac-1 the ESP check asserts the runtime file against the committed slot"
assert_contains "$render_script" 'a failed try would have nowhere to go' \
  "ac-1 the ESP check refuses a fallback that points at the pending slot"

# The harness has to refuse a kernel or a command line in that mode, otherwise the
# "real GRUB" boot would quietly become a -kernel boot again.
qemu_smoke=$(cat "$root/scripts/ci/qemu-smoke.sh")
assert_contains "$qemu_smoke" 'uefi-disk needs CI_QEMU_DISK' \
  "ac-1 the harness requires a disk for a firmware boot"
assert_contains "$qemu_smoke" 'uefi-disk takes the kernel command line from grub.cfg' \
  "ac-1 the harness refuses an injected command line in that mode"

# --------------------------------------------------------------------------- #
# ac-2: the judge lines parse
# --------------------------------------------------------------------------- #

parse_ok_re='^(S3|S4|S5)-(RESULT|EVIDENCE)=ok( [a-z][a-z0-9_]*=[^ ]+)+$'

lines=(
  "S3-RESULT=ok slot=a upper=@overlay-25.12.2 lower=platform:sys root=overlay"
  "S4-RESULT=ok phase=commit slot=a"
  "S4-RESULT=ok phase=abandon slot=b"
  "S4-RESULT=ok phase=rollback slot=a"
  "S5-RESULT=ok upgrade=b conflicts=0 reclaimed=1"
  "S5-EVIDENCE=ok phase=upgrade slot=b"
  "S5-EVIDENCE=ok phase=toolchain tool=btrfs-progs-v6.12"
  "S5-EVIDENCE=ok phase=degraded target=p4"
)
for line in "${lines[@]}"; do
  assert_matches "$line" "$parse_ok_re" "ac-2 parses: ${line}"
  assert_eq "$(result_of "$line")" "$(printf '%s' "$line" | cut -d' ' -f1)" \
    "ac-2 the verdict is the first field: ${line}"
done

assert_eq "$(field "S4-RESULT=ok phase=commit slot=a" slot)" "a" \
  "ac-2 the slot is extractable from an S4 line"
assert_eq "$(field "S4-RESULT=ok phase=commit slot=a" phase)" "commit" \
  "ac-2 the phase is extractable from an S4 line"
assert_eq "$(field "S3-RESULT=ok slot=b upper=@overlay-25.12.3 lower=platform:sys root=overlay" upper)" \
  "@overlay-25.12.3" "ac-2 the layer is extractable from an S3 line"
assert_eq "$(field "S5-RESULT=ok upgrade=b conflicts=2 reclaimed=1" conflicts)" "2" \
  "ac-2 the conflict count is extractable from an S5 line"

# A failure line keeps its own shape and must not be mistaken for a pass.
fail_line="S4-RESULT=fail reason=committed-is-b"
assert_eq "$(printf '%s' "$fail_line" | grep -cE "$parse_ok_re")" "0" \
  "ac-2 a failure line is not parsed as a pass"
assert_eq "$(field "$fail_line" reason)" "committed-is-b" \
  "ac-2 the failure reason is extractable"

# --------------------------------------------------------------------------- #
# ac-3: the producers still print the frozen format
# --------------------------------------------------------------------------- #

post=$(cat "$root/initramfs/boot/post.sh")
assert_contains "$post" 'S3-RESULT=ok slot=%s upper=%s lower=platform:sys root=overlay' \
  "ac-3 the S3 judge line shape is unchanged"
ab_phase=$(cat "$root/scripts/ci/ab-phase.sh")
assert_contains "$ab_phase" "S4-RESULT=ok phase=%s slot=%s" \
  "ac-3 the S4 judge line shape is unchanged"
assert_contains "$ab_phase" "S4-RESULT=fail reason=%s" \
  "ac-3 the S4 failure line shape is unchanged"
s5_phase=$(cat "$root/scripts/ci/s5-phase.sh")
assert_contains "$s5_phase" "S5-RESULT=ok upgrade=%s conflicts=%s reclaimed=%s" \
  "ac-3 the S5 judge line shape is unchanged"
assert_contains "$s5_phase" "S5-EVIDENCE=ok phase=upgrade slot=" \
  "ac-3 the S5 upgrade evidence line is unchanged"

# --------------------------------------------------------------------------- #
# ac-4: the report still receives the names the workflows publish
# --------------------------------------------------------------------------- #

report_workflow=$(cat "$workflows/ci-report.yml")
s4_body=$(cat "$workflows/ci-s4.yml")
# The names ci-report consumes, plus the ones the stage publishes for the artifacts.
for output in line_commit_a line_abandon_b line_commit_b committed_final; do
  assert_contains "$s4_body" "${output}:" "ac-4 ci-s4 publishes ${output}"
  assert_contains "$report_workflow" "s4_${output}:" "ac-4 ci-report accepts s4_${output}"
done
for output in line_rollback next_slot_final grub_cfg_sha256; do
  assert_contains "$s4_body" "${output}:" "ac-4 ci-s4 publishes the extra output ${output}"
done
assert_contains "$report_workflow" "s4_result:" "ac-4 ci-report accepts s4_result"

s5_body=$(cat "$workflows/ci-s5.yml")
for output in upgrade_line degraded_line conflicts reclaimed; do
  assert_contains "$s5_body" "${output}:" "ac-5 ci-s5 publishes ${output}"
  assert_contains "$report_workflow" "s5_${output}:" "ac-5 ci-report accepts s5_${output}"
done
assert_contains "$s5_body" "judge_line:" "ac-5 ci-s5 publishes judge_line"
assert_contains "$report_workflow" "s5_line:" "ac-5 ci-report takes the S5 judge line as s5_line"
assert_contains "$s5_body" "toolchain_line:" "ac-5 ci-s5 publishes the toolchain evidence" 

finish
