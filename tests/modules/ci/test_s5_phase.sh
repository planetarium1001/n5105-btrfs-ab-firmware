#!/usr/bin/env bash
# Module: ci
# The S5 commit phase grades two different things and has to keep them apart: the state
# the product wrote, and the state of the machine it wrote it on.
#
# Run 43918219525 was reported as `S5-RESULT=fail reason=committed-is-a` when the product
# had done nothing wrong: the harness killed QEMU one second after the upgrade fixture's
# S5-UPGRADE-DONE, while ab-commit was still writing the FAT ESP; the next boot found
# `FAT-fs ... invalid cluster chain` and the commit could not be recorded.
#
#   ac-1  the commit record is the successful one: `stage=commit slot=b result=fail
#         reason=commit-failed` must never satisfy the assertion. The old
#         `grep -q "stage=commit slot=b"` matched that line, and the fixture below would
#         have been graded `S5-RESULT=ok`.
#   ac-2  `FAT-fs ... invalid cluster chain` / `Filesystem has been set read-only` in the
#         boot log is `reason=esp-corrupt`, never `committed-is-*`
#   ac-3  an ESP that refuses the write probe is `reason=esp-read-only` before any state
#         assertion, and the reason is printed in the report
#   ac-4  the boot-2 stop pattern waits for ab-commit's own conclusion instead of the
#         upgrade fixture's S5-UPGRADE-DONE, and keeps the failure lines plus a timeout
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

script="$root/scripts/ci/s5-phase.sh"
workflow="$root/.github/workflows/ci-s5.yml"
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# ac-4: the boot-2 stop pattern
#
# The fixture's rc.local prints S5-UPGRADE-DONE after ab-upgrade returns, but ab-commit
# (S99) runs after rc.local and is the one that writes state and the FAT ESP. A pattern
# that matches S5-UPGRADE-DONE ends the boot in the middle of that write.
# --------------------------------------------------------------------------- #

step_block() { # <first line of the `- name:` step> <file>
    awk -v first="$1" '
        index($0, "- name: " first) { inside = 1 }
        inside && /- name: / && !index($0, "- name: " first) { exit }
        inside { print }
    ' "$2"
}

boot2_block="$(step_block 'Boot 2 ' "$workflow")"
[ -n "$boot2_block" ] || echo "no Boot 2 step found in $workflow"
boot2_stop="$(printf '%s\n' "$boot2_block" | grep 'stop-pattern:' | head -n 1)"

# Every alternative has to be a line the guest actually reaches the serial log with. A hook
# writes a milestone through console_say (AB_CONSOLE_DEV and the mirrors); its plain `echo`
# goes to procd and lands in syslog, so a stop pattern naming one of those waits for a line
# that can never come and the boot only ends on the timeout. Each token below is therefore
# required to appear inside a console_say argument of the hook that prints it.
console_say_of() { # <hook path> <literal token> -> yes|no
    if grep -F 'console_say "' "$1" | grep -qF "$2"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

assert_contains "$boot2_stop" 'ab-commit: committed slot=' \
    "ac-4 boot 2 waits for ab-commit's committed line"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-commit" 'ab-commit: committed slot=')" "yes" \
    "ac-4 and that line is one ab-commit writes to the console"
assert_contains "$boot2_stop" 'ab-commit: abandoned slot=' \
    "ac-4 boot 2 stops on the abandon decision"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-commit" 'ab-commit: abandoned slot=')" "yes" \
    "ac-4 and the abandon line reaches the console too"
assert_contains "$boot2_stop" 'ab-commit: stage=commit .*result=fail' \
    "ac-4 boot 2 stops on a failed commit write"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-commit" 'ab-commit: stage=commit slot=${slot} result=fail')" "yes" \
    "ac-4 the failed commit line is printed through console_say"
assert_contains "$boot2_stop" 'ab-commit: stage=preflight .*result=fail' \
    "ac-4 boot 2 stops when the preflight fails"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-commit" 'ab-commit: stage=preflight slot=${slot} result=fail')" "yes" \
    "ac-4 the preflight failure is printed through console_say"
assert_contains "$boot2_stop" 'ab-commit: stage=healthcheck-done .*result=fail' \
    "ac-4 boot 2 stops on a failed health check summary"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-commit" 'ab-commit: stage=healthcheck-done result=fail')" "yes" \
    "ac-4 an unresolvable ESP is reported on the console"
assert_contains "$boot2_stop" 'ab-boot: stage=boot result=fail' \
    "ac-4 boot 2 stops on a boot failure"
assert_eq "$(console_say_of "$root/platform/etc/init.d/ab-boot" 'ab-boot: stage=boot result=fail')" "yes" \
    "ac-4 and the boot failure is a console line"
# The stdout-only line: `echo "ab-commit: health check failed on the committed slot ..."` is
# the same decision the console_say summary above already carries. Asserting it stays out of
# the pattern is what keeps the next edit from adding a line the serial log never sees.
assert_eq "$(printf '%s\n' "$boot2_stop" | grep -c 'health check failed' || true)" "0" \
    "ac-4 no stdout-only echo line is used as a stop pattern"
assert_eq "$(printf '%s\n' "$boot2_stop" | grep -c 'S5-UPGRADE-DONE' || true)" "0" \
    "ac-4 boot 2 no longer stops on S5-UPGRADE-DONE"
assert_contains "$boot2_block" 'timeout: "1200"' \
    "ac-4 boot 2 keeps its wall-clock backstop"

phase3_block="$(step_block 'Phase 3 ' "$workflow")"
assert_contains "$phase3_block" '--serial "${{ steps.boot3.outputs.serial_log }}"' \
    "ac-4 the commit phase is handed the boot-3 serial log"

# --------------------------------------------------------------------------- #
# The commit phase, driven from a directory fixture
#
# There is no loop device on a laptop, so mount, umount, losetup and btrfs are replaced
# with small scripts that map <loop>p1 / <loop>p4 onto prepared directories. Everything
# under test - the corruption scan, the write probe, the state and log assertions - is the
# real code from scripts/ci/s5-phase.sh.
# --------------------------------------------------------------------------- #

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
FAKE
cat >"$tmp/bin/losetup" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
    --find) printf '%s\n' "${S5_FAKE_LOOP}" ;;
    -d | --detach) : ;;
esac
exit 0
FAKE
cat >"$tmp/bin/umount" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat >"$tmp/bin/mount" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
dev=""
dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        -o) shift 2 ;;
        -*) shift ;;
        *)
            if [ -z "${dev}" ]; then dev="$1"; else dir="$1"; fi
            shift
            ;;
    esac
done
[ -n "${dev}" ] && [ -n "${dir}" ] || exit 32
case "${dev}" in
    *p1) src="${S5_FAKE_FIXTURE}/p1" ;;
    *p4) src="${S5_FAKE_FIXTURE}/p4" ;;
    *) exit 32 ;;
esac
[ -d "${src}" ] || exit 32
# The script remounts the same mountpoint read-write after the read-only pass, so the
# directory may still carry the permissions of the previous mount.
chmod -R u+w "${dir}" 2>/dev/null || true
cp -a "${src}/." "${dir}/" || exit 32
# A fixture that carries .__readonly stands for a FAT volume the kernel mounted but
# flipped read-only: the mount succeeds and the writes fail.
if [ -f "${src}/.__readonly" ]; then
    chmod -R a-w "${dir}" || exit 32
fi
exit 0
FAKE
cat >"$tmp/bin/btrfs" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "subvolume" ] && [ "${2:-}" = "list" ]; then
    [ -f "${S5_FAKE_FIXTURE}/subvols" ] || exit 0
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        printf 'ID 256 gen 10 top level 5 path %s\n' "${path}"
    done <"${S5_FAKE_FIXTURE}/subvols"
fi
exit 0
FAKE
chmod +x "$tmp/bin/"*

new_case() { # <name> -> fixture directory
    local dir="$tmp/$1"
    mkdir -p "$dir/p1/ab/log" "$dir/p4" "$dir/tmp" "$dir/logs"
    : >"$dir/image"
    printf '%s\n' "$dir"
}

write_state() { # <dir> <committed> <pending|none>
    local dir=$1 committed=$2 pending=$3 pending_json
    if [ "$pending" = "none" ]; then pending_json='null'; else pending_json="\"$pending\""; fi
    cat >"$dir/p1/ab/state.json" <<JSON
{
  "generation": 2,
  "committed": "${committed}",
  "pending": ${pending_json},
  "slots": {
    "a": { "rootfs": "25.12.1", "upper": "@overlay-25.12.1" },
    "b": { "rootfs": "25.12.4", "upper": "@overlay-25.12.4" }
  }
}
JSON
}

write_boot_log() { # <dir> <line>...
    local dir=$1
    shift
    printf '%s\n' "$@" >"$dir/p1/ab/log/boot-0.log"
}

write_conflicts() {
    printf 'conflicts=1\nbaseline=ok\n' >"$1/p1/ab/conflicts.log"
}

write_layers() { # the layers btrfs reports on p4
    printf '@overlay-25.12.4\n' >"$1/subvols"
}

write_serial() { # <dir> clean|fat
    local dir=$1 kind=${2:-clean}
    if [ "$kind" = "fat" ]; then
        cat >"$dir/serial.log" <<'SERIAL'
[    2.1] FAT-fs (vda1): error, fat_get_cluster: invalid cluster chain (i_pos 13894)
[    2.2] FAT-fs (vda1): Filesystem has been set read-only
SERIAL
    else
        printf 'ab-commit: committed slot=b upper=@overlay-25.12.4\n' >"$dir/serial.log"
    fi
}

# The unreferenced layer the fixture created. The commit phase refuses to grade without it:
# "no unreferenced layer is left" is also true of a run whose fixture created none, and that
# silence is what let the 25.12.1 line report reclaimed=0 and pass (test_s5_orphan_layer.sh
# covers the fixture, gc and the phase against one tree).
orphan_layer='@overlay-25.12.1-gc-orphan'

run_commit() { # <dir> [without-serial|without-orphan]
    local dir=$1 without=${2:-}
    if [ "$without" = "without-serial" ]; then
        CI_IMAGE="$dir/image" CI_TMP_ROOT="$dir/tmp" CI_LOG_DIR="$dir/logs" \
            CI_S5_PART_WAIT_ATTEMPTS=0 S5_FAKE_FIXTURE="$dir" \
            S5_FAKE_LOOP="$dir/loop0" PATH="$tmp/bin:$PATH" \
            bash "$script" --phase commit --slot b --orphan "$orphan_layer" 2>&1
        return 0
    fi
    if [ "$without" = "without-orphan" ]; then
        CI_IMAGE="$dir/image" CI_TMP_ROOT="$dir/tmp" CI_LOG_DIR="$dir/logs" \
            CI_S5_PART_WAIT_ATTEMPTS=0 S5_FAKE_FIXTURE="$dir" \
            S5_FAKE_LOOP="$dir/loop0" PATH="$tmp/bin:$PATH" \
            bash "$script" --phase commit --slot b --serial "$dir/serial.log" 2>&1
        return 0
    fi
    CI_IMAGE="$dir/image" CI_TMP_ROOT="$dir/tmp" CI_LOG_DIR="$dir/logs" \
        CI_S5_PART_WAIT_ATTEMPTS=0 S5_FAKE_FIXTURE="$dir" \
        S5_FAKE_LOOP="$dir/loop0" PATH="$tmp/bin:$PATH" \
        bash "$script" --phase commit --slot b --orphan "$orphan_layer" \
        --serial "$dir/serial.log" 2>&1
}

# --- ac-1: a failed commit record is not a commit --------------------------
# The state says the commit happened, the conflict report and the reclamation are perfect,
# and the only commit line in the boot log is the failure. The old grep accepted this and
# the run would have printed S5-RESULT=ok; the assertion has to go red.
failed=$(new_case ac1-failed-record)
write_state "$failed" b none
write_boot_log "$failed" 'stage=commit slot=b result=fail reason=commit-failed'
write_conflicts "$failed"
write_layers "$failed"
write_serial "$failed" clean
out="$(run_commit "$failed")"
assert_contains "$out" "S5-RESULT=fail reason=no-commit-record" \
    "ac-1 result=fail is not a successful commit record"
assert_eq "$(printf '%s\n' "$out" | grep -c 'S5-RESULT=ok' || true)" "0" \
    "ac-1 the old false green is gone"
assert_contains "$out" 'stage=commit slot=b result=fail reason=commit-failed' \
    "ac-1 the failure record is printed for diagnosis"

# --- ac-1: the success path still passes -----------------------------------
good=$(new_case ac1-good)
write_state "$good" b none
write_boot_log "$good" \
    'stage=healthcheck-done slot=b upper=@overlay-25.12.4 rootfs=25.12.4 result=ok' \
    'stage=commit slot=b upper=@overlay-25.12.4 rootfs=25.12.4 result=ok action=commit' \
    'stage=gc slot=b reclaimed=1'
write_conflicts "$good"
write_layers "$good"
write_serial "$good" clean
out="$(run_commit "$good")"
assert_contains "$out" "S5-RESULT=ok upgrade=b conflicts=1 reclaimed=1" \
    "ac-1 the real commit line still passes"
assert_eq "$(find "$good/tmp/s5-phase/esp" -name '.s5-write-probe*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "ac-1 the write probe is removed again"

# --- ac-2: a damaged FAT chain is esp-corrupt, not committed-is-a ---------
corrupt=$(new_case ac2-corrupt)
write_state "$corrupt" a b
write_boot_log "$corrupt" 'stage=commit slot=b result=fail reason=commit-failed'
write_serial "$corrupt" fat
out="$(run_commit "$corrupt")"
assert_contains "$out" "S5-RESULT=fail reason=esp-corrupt" \
    "ac-2 the FAT error is named esp-corrupt"
assert_eq "$(printf '%s\n' "$out" | grep -c 'committed-is-' || true)" "0" \
    "ac-2 a damaged machine is not reported as the product failing to commit"
assert_contains "$out" 'invalid cluster chain' \
    "ac-2 the FAT evidence is printed"

# --- ac-3: a read-only ESP is the input failure ----------------------------
readonly_case=$(new_case ac3-readonly)
write_state "$readonly_case" b none
write_boot_log "$readonly_case" \
    'stage=commit slot=b upper=@overlay-25.12.4 rootfs=25.12.4 result=ok action=commit'
write_layers "$readonly_case"
write_serial "$readonly_case" clean
: >"$readonly_case/p1/.__readonly"
out="$(run_commit "$readonly_case")"
assert_contains "$out" "S5-RESULT=fail reason=esp-read-only" \
    "ac-3 an ESP that refuses a write is esp-read-only"
assert_contains "$out" "the ESP refuses writes" \
    "ac-3 the report prints why the phase stopped"
assert_eq "$(printf '%s\n' "$out" | grep -c 'committed-is-' || true)" "0" \
    "ac-3 the input is asserted before the state"
assert_eq "$(printf '%s\n' "$out" | grep -c 'no-commit-record' || true)" "0" \
    "ac-3 the input is asserted before the commit record"

# --- ac-3: the serial log is what carries the FAT evidence -----------------
assert_contains "$(run_commit "$good" without-serial)" "commit phase needs --serial" \
    "ac-3 the commit phase refuses to grade without the boot serial"

# --- ac-5: the reclamation assertion needs its subject ---------------------
# Without --orphan the phase could only prove "no unreferenced layer is left", which a run
# whose fixture created none satisfies by accident. The refusal is what makes the phase
# unable to grade a reclamation it cannot name.
assert_contains "$(run_commit "$good" without-orphan)" "commit phase needs --orphan" \
    "ac-5 the commit phase refuses to grade reclamation without the fixture's layer"
assert_eq "$(printf '%s\n' "$(run_commit "$good" without-orphan)" | grep -c 'S5-RESULT=ok' || true)" "0" \
    "ac-5 a nameless reclamation is never reported as ok"
