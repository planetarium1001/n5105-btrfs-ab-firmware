#!/usr/bin/env bash
# Module: ci
# The cross-version upgrade verdict, graded from facts alone.
#
# The QEMU half of scripts/ci/cross-upgrade.sh cannot run here, but the half that decides
# whether a run passed is pure file reading, and that is the half that has to be right:
# a stage that reports ok on the wrong facts is worse than one that never runs.
#
#   ac-3  a good upgrade: pending -> committed, generation advanced, packages aligned,
#         ESP kernel/initrd byte-identical to the payload's
#   ac-4  an injected failure: the candidate is abandoned and the machine returns
#   ac-5  no previous release: skipped, with the reason spelled out
#   ac-6  the image a caller hands over may be compressed: a .gz is decompressed, a plain
#         file is copied, and a torn archive says so instead of reaching losetup
#   ac-7  the two boots are handed the old image's own kernel and initrd, an unreadable ESP
#         is a fail verdict, and a failed boot leaves its exit status in the serial log
#   ac-1  the run half appends the guest serial qemu-smoke copies into CI_LOG_DIR, in boot
#         order, and keeps the wrapper's stdout as diagnostics only
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

script="$root/scripts/ci/cross-upgrade.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grade() { bash "$script" assert --out "$1" 2>&1; }

# write_case <dir> <kernel-esp> <kernel-payload> <initrd-esp> <initrd-payload> [serial]
write_case() {
  local dir=$1 kesp=$2 kpay=$3 iesp=$4 ipay=$5 serial=${6:-"stage=commit slot=b result=ok"}
  mkdir -p "$dir"
  printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a\n' >"$dir/status.before"
  printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=b next=b\n' >"$dir/status.after"
  printf 'slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=aligned\n' >"$dir/status.committed"
  printf '%s  vmlinuz-b\n%s  initrd-b\n' "$kesp" "$iesp" >"$dir/esp.sha256"
  printf '%s  kernel.bin\n%s  initramfs.cpio.gz\n' "$kpay" "$ipay" >"$dir/payload.sha256"
  printf '%s\n' "$serial" >"$dir/serial.log"
}

# --- ac-3: the success path ------------------------------------------------
good="$tmp/good"
write_case "$good" aaaa aaaa cccc cccc
assert_contains "$(grade "$good")" "cross-upgrade=ok" "ac-3 a good upgrade is ok"
assert_contains "$(grade "$good")" "slot=b" "ac-3 the verdict names the slot that was committed"

mismatch="$tmp/mismatch"
write_case "$mismatch" aaaa ffff cccc cccc
assert_contains "$(grade "$mismatch")" "kernel-on-esp-is-not-the-payload-kernel" \
  "ac-3 a kernel that is not the payload's kernel is a failure"

initrd="$tmp/initrd"
write_case "$initrd" aaaa aaaa cccc eeee
assert_contains "$(grade "$initrd")" "initrd-on-esp-is-not-the-payload-initrd" \
  "ac-3 an initrd that is not the payload's initrd is a failure"

nocommit="$tmp/nocommit"
write_case "$nocommit" aaaa aaaa cccc cccc "stage=upgrade result=ok"
assert_contains "$(grade "$nocommit")" "commit-not-recorded-in-serial" \
  "ac-3 a boot that never recorded the commit is a failure"

notaligned="$tmp/notaligned"
write_case "$notaligned" aaaa aaaa cccc cccc
printf 'slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=limited\n' \
  >"$notaligned/status.committed"
assert_contains "$(grade "$notaligned")" "packages-not-aligned-after-commit" \
  "ac-3 a slot that cannot install its own kernel's modules is a failure"

stuck="$tmp/stuck"
write_case "$stuck" aaaa aaaa cccc cccc
printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a\n' >"$stuck/status.after"
assert_contains "$(grade "$stuck")" "pending-already-none" \
  "ac-3 an install that left nothing pending is a failure"

# --- ac-4: the injected failure -------------------------------------------
inject="$tmp/inject"
write_case "$inject" aaaa aaaa cccc cccc "stage=abandon slot=b result=fail action=reboot-to-committed"
printf 'unhealthy\n' >"$inject/inject"
# The abandon leaves the previous slot committed and nothing pending.
printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a packages=aligned\n' \
  >"$inject/status.committed"
assert_contains "$(grade "$inject")" "cross-upgrade=ok inject=unhealthy returned=a" \
  "ac-4 an abandoned candidate that returned to the previous slot is a good run"

noabandon="$tmp/noabandon"
write_case "$noabandon" aaaa aaaa cccc cccc "stage=commit slot=b result=ok"
printf 'unhealthy\n' >"$noabandon/inject"
assert_contains "$(grade "$noabandon")" "abandon-not-recorded" \
  "ac-4 an injected failure that was not abandoned is a failure"

# --- ac-5: nothing to upgrade from ---------------------------------------
skip="$tmp/skip"
mkdir -p "$skip"
printf 'no-previous-formal-release gaps=3\n' >"$skip/skip"
assert_contains "$(grade "$skip")" "cross-upgrade=skipped" "ac-5 a missing previous release is skipped"
assert_contains "$(grade "$skip")" "gaps=3" "ac-5 the skip names the gap"

# --- the guest half's parser ------------------------------------------------
# The stage reads three status lines out of one serial log. The parser is what decides
# which line is "before", "pending" and "committed", so it is asserted directly.
serial="$tmp/serial-full.log"
cat >"$serial" <<'SERIAL'
CROSS-STATUS-BEFORE
slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a
CROSS-INSTALL
ab-upgrade: installed 25.12.4 into slot b
CROSS-STATUS-PENDING
slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=b next=b
CROSS-STATUS-DONE
CROSS-STATUS-COMMITTED
slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=aligned
CROSS-STATUS-DONE
SERIAL
parsed="$tmp/parsed"
bash "$script" parse --serial "$serial" --out "$parsed" 2>&1 >/dev/null
assert_file_exists "$parsed/status.before" "the parser finds the status before the install"
assert_file_exists "$parsed/status.after" "the parser finds the pending status"
assert_file_exists "$parsed/status.committed" "the parser finds the status after the commit"
assert_contains "$(cat "$parsed/status.after" 2>/dev/null)" "pending=b" "the pending block is the one with a candidate"
assert_contains "$(cat "$parsed/status.committed" 2>/dev/null)" "packages=aligned" "the committed block is the last boot's"

# --- ac-6: the caller may hand over the compressed artifact -----------------
# The cross stage finds the previous image by `*.img.gz` and handed those gzip bytes to
# losetup, which answered "file does not fit into a 512-byte sector" and then a partition
# that does not exist (run 43570531757). The stage stages a plain image from either shape,
# through a subcommand of its own, so this half is asserted with no loop device and no QEMU.
stage_image() { bash "$script" stage-image --src "$1" --dest "$2" 2>&1; }

printf 'a small disk image, not a gzip stream\n' >"$tmp/plain.img"
gzip -c "$tmp/plain.img" >"$tmp/plain.img.gz"

stage_image "$tmp/plain.img.gz" "$tmp/staged-gz.img" >/dev/null
assert_eq "$?" "0" "ac-6 a gzip image is staged"
assert_eq "$(cmp -s "$tmp/plain.img" "$tmp/staged-gz.img" && echo same)" "same" \
  "ac-6 the staged image is the bytes the archive carries, not the archive"

stage_image "$tmp/plain.img" "$tmp/staged-plain.img" >/dev/null
assert_eq "$?" "0" "ac-6 an uncompressed image is staged"
assert_eq "$(cmp -s "$tmp/plain.img" "$tmp/staged-plain.img" && echo same)" "same" \
  "ac-6 an uncompressed image is copied unchanged"

head -c 20 "$tmp/plain.img.gz" >"$tmp/torn.img.gz"
torn="$(stage_image "$tmp/torn.img.gz" "$tmp/staged-torn.img")"
assert_eq "$?" "1" "ac-6 a torn gzip image is refused"
assert_contains "${torn}" "cannot-decompress" \
  "ac-6 the refusal names the compression, so nobody reads it as a loop-device error"
assert_eq "$([ -e "$tmp/staged-torn.img" ] && echo present || echo absent)" "absent" \
  "ac-6 a torn archive leaves no half-written image behind"

# --- ac-7: the boots are handed the old image's own kernel --------------------
# The two boots run in uefi-disk mode, where OVMF boots the disk through GRUB: the log has to
# describe the system being upgraded, and the payload's kernel is the new one. qemu-smoke
# requires CI_KERNEL and CI_INITRAMFS even in that mode, which is how a boot with neither used
# to die unrecorded. The selection half is reachable without a loop device, so it is asserted
# for real: the mount half needs sudo and is CI's to prove.
stage_boot_files() { bash "$script" stage-boot-files --esp "$1" --dest "$2" 2>&1; }

mkdir -p "$tmp/esp"
printf 'kernel of the old image\n' >"$tmp/esp/vmlinuz-a"
printf 'initrd of the old image\n' >"$tmp/esp/initrd-a"
stage_boot_files "$tmp/esp" "$tmp/boot-staged" >/dev/null
assert_eq "$?" "0" "ac-7 the old image's boot files are staged"
assert_eq "$(cat "$tmp/boot-staged/kernel.bin" 2>/dev/null)" "kernel of the old image" \
  "ac-7 the staged kernel is the one on the ESP"
assert_eq "$(cat "$tmp/boot-staged/initrd.cpio.gz" 2>/dev/null)" "initrd of the old image" \
  "ac-7 the staged initrd is the one on the ESP"

mkdir -p "$tmp/esp-no-kernel"
printf 'initrd only\n' >"$tmp/esp-no-kernel/initrd-a"
assert_eq "$(stage_boot_files "$tmp/esp-no-kernel" "$tmp/boot-missing" >/dev/null; echo "$?")" "1" \
  "ac-7 an ESP without a kernel is refused"
assert_eq "$([ -e "$tmp/boot-missing/kernel.bin" ] && echo present || echo absent)" "absent" \
  "ac-7 a refused ESP stages nothing"

stage_text="$(cat "$script")"
assert_eq "$(grep -c 'CI_KERNEL="${_boot}/kernel.bin"' "$script")" "3" \
  "ac-7 all three boots get the kernel the old image carries"
assert_eq "$(grep -c 'CI_INITRAMFS="${_boot}/initrd.cpio.gz"' "$script")" "3" \
  "ac-7 all three boots get that image's initrd"
assert_contains "${stage_text}" "cannot-read-the-old-esp" \
  "ac-7 an ESP that cannot be read is a fail verdict, not a skip"
assert_contains "${stage_text}" "[cross] boot 1 exited" \
  "ac-7 a failed first boot leaves its exit status in the serial log"
assert_contains "${stage_text}" "[cross] boot 2 exited" \
  "ac-7 a failed second boot leaves its exit status in the serial log"
assert_eq "$(grep -c 'qemu-smoke.sh" .*|| true' "$script")" "0" \
  "ac-7 no boot swallows its own failure"

# A machine without QEMU says so instead of pretending it ran.
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
  assert_eq "qemu" "qemu" "a host with QEMU skips this assertion"
else
  assert_contains "$(bash "$script" run --image /nonexistent.img --payload /nonexistent.tar --out "$tmp/run-out" 2>&1)" \
    "cross-upgrade: skipped reason=qemu-not-available" \
    "a host without QEMU reports the stage as skipped"
fi

# --- ac-6: the graders do not share run_stage's variables -------------------
# esp_digests and payload_digests take the same _out name run_stage owns. Without local,
# the first call rebinds run_stage's _out to <out>/esp.sha256 and the second writes
# inside that file: "cross-out/esp.sha256/payload.sha256: Not a directory" (run
# 43573287849, the first run that got this far).
esp_fn="$(sed -n '/^esp_digests()/,/^}/p' "$script")"
payload_fn="$(sed -n '/^payload_digests()/,/^}/p' "$script")"
assert_contains "$esp_fn" "local _image=\$1 _out=\$2" \
  "ac-6 esp_digests keeps its arguments out of run_stage's variables"
assert_contains "$payload_fn" "local _payload=\$1 _out=\$2" \
  "ac-6 payload_digests keeps its arguments out of run_stage's variables"

# --- ac-7: an empty --inject must not end the script -----------------------
# `[ -n "$x" ] && ...` as the last statement of run_stage returns non-zero when the flag is
# absent, and set -e then kills the script before grade() prints: the run reports "no
# verdict line" instead of the verdict (43584337812).
run_fn="$(sed -n '/^run_stage()/,/^}/p' "$script")"
assert_contains "$run_fn" 'if [ -n "${_inject}" ] && [ "${_inject}" != "none" ]; then' \
  "ac-7 the inject guard is a conditional, so an absent flag cannot exit early"

# --- ac-7: what grade() says, from files alone ------------------------------
# `assert --out` is the stage's own test hook: it prints the verdict for a finished run.
# Both cases below are runs that happened, reduced to the files grade() reads.
grade_dir="$tmp/grade-ok"
mkdir -p "$grade_dir"
# The status blocks keep a leading space: field() matches "<space>name=value".
printf ' slot=b committed=a pending=b next=b generation=3\n' >"$grade_dir/status.after"
printf ' slot=b committed=b pending=none generation=4 packages=aligned\n' >"$grade_dir/status.committed"
printf ' slot=a committed=a pending=none generation=2\n' >"$grade_dir/status.before"
# Same digests, different member names on each side: the ESP names the kernel vmlinuz-*,
# the payload names it kernel.bin.
printf 'a1b2c3  vmlinuz-a\na1b2c3  initrd-a\n' >"$grade_dir/esp.sha256"
printf 'a1b2c3  kernel.bin\na1b2c3  initramfs.cpio.gz\n' >"$grade_dir/payload.sha256"
printf 'ab-commit: stage=commit slot=b result=ok\n' >"$grade_dir/serial.log"
out="$(bash "$script" assert --out "$grade_dir" 2>&1)"
assert_contains "$out" "cross-upgrade=ok slot=b generation=4" \
  "ac-7 a run that installed, committed and shipped the payload grades ok"

# A boot that never printed the pending block: grade() must say which fact is missing
# instead of dying in a command substitution (run 43588155580 printed no verdict at all).
empty_dir="$tmp/grade-empty"
mkdir -p "$empty_dir"
out="$(bash "$script" assert --out "$empty_dir" 2>&1)"
assert_contains "$out" "cross-upgrade=fail reason=status-after-missing" \
  "ac-7 a missing status block is a verdict, not a silent exit"

# --- ac-1: the guest serial, not qemu-smoke's stdout ------------------------
# qemu-smoke keeps the guest console in ${CI_LOG_DIR}/serial-<case>.log; its stdout is
# stage progress for a human. The stage used to redirect the stdout into serial.log, so
# extract_blocks never found a CROSS-STATUS-* line and every graded run ended
# reason=status-after-missing (tag run 43622253559). The run half needs sudo and a loop
# device, so it is exercised against a copy of the script whose qemu-smoke is a stub that
# writes the real serial copy and a decoy on stdout. The copy lives next to a copy of
# lib.sh on purpose: the script resolves both from its own directory, so nothing inside
# the script has to be patched for the test.
fake="$tmp/fake-cross"
mkdir -p "$fake"
cp "$script" "$fake/cross-upgrade.sh"
cp "$root/scripts/ci/lib.sh" "$fake/lib.sh"
cat >"$fake/qemu-smoke.sh" <<'STUB'
#!/usr/bin/env bash
# Stub qemu-smoke: the guest serial goes where qemu-smoke puts it, progress goes to stdout.
set -euo pipefail
case_label="${CI_QEMU_CASE:?CI_QEMU_CASE is required}"
mkdir -p "${CI_LOG_DIR}"
# If the stage grades this stdout, "wrong" is what it grades.
printf 'CROSS-STATUS-BEFORE\nslot=wrong upper=@stdout generation=0 committed=z pending=z next=z\n'
printf 'stage progress for %s\n' "${case_label}"
case "${case_label}" in
  cross-boot1)
    cat >"${CI_LOG_DIR}/serial-${case_label}.log" <<'SERIAL1'
CROSS-STATUS-BEFORE
slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none next=a
CROSS-INSTALL
ab-upgrade: installed 25.12.4 into slot b
CROSS-STATUS-PENDING
slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=b next=b
CROSS-STATUS-DONE
SERIAL1
    ;;
  cross-boot2)
    cat >"${CI_LOG_DIR}/serial-${case_label}.log" <<'SERIAL2'
CROSS-STATUS-COMMITTED
slot=b upper=@overlay-25.12.4 generation=2 committed=b pending=none next=b packages=aligned
stage=commit slot=b result=ok
CROSS-STATUS-DONE
SERIAL2
    ;;
  *)
    printf 'unexpected case label: %s\n' "${case_label}" >&2
    exit 1
    ;;
esac
STUB

# The host side of run_stage, stubbed: a loop device that answers losetup, a mount that
# populates the mount point instead of mounting (p1 is the ESP, p4 carries the writable
# layer), and the two commands run_stage only asks to exist.
stubs="$tmp/bin"
mkdir -p "$stubs"
printf '#!/bin/sh\nexec "$@"\n' >"$stubs/sudo"
printf '#!/bin/sh\ncase "$1" in --find) printf "loop-test\\n" ;; esac\nexit 0\n' >"$stubs/losetup"
printf '#!/bin/sh\nexit 0\n' >"$stubs/umount"
printf '#!/bin/sh\nexit 0\n' >"$stubs/qemu-system-x86_64"
cat >"$stubs/mount" <<'MOUNT'
#!/usr/bin/env bash
# Stub mount: the last argument is the mount point; fill it like the image would.
set -euo pipefail
mnt="${!#}"
dev=""
for arg in "$@"; do
  [ "$arg" = "$mnt" ] && continue
  case "$arg" in -*) continue ;; esac
  dev="$arg"
done
mkdir -p "$mnt"
case "$dev" in
  *p1)
    printf 'kernel of the old image\n' >"$mnt/vmlinuz-a"
    printf 'initrd of the old image\n' >"$mnt/initrd-a"
    ;;
  *p4) mkdir -p "$mnt/@overlay-25.12.2/upper" ;;
esac
MOUNT
chmod +x "$stubs"/*

printf 'a small disk image, not a block device\n' >"$tmp/run-old.img"
mkdir -p "$tmp/run-payload"
printf 'kernel of the old image\n' >"$tmp/run-payload/kernel.bin"
printf 'initrd of the old image\n' >"$tmp/run-payload/initramfs.cpio.gz"
tar -cf "$tmp/run-payload.tar" -C "$tmp/run-payload" kernel.bin initramfs.cpio.gz

run_ci="$tmp/run-ci"
mkdir -p "$run_ci/logs"
run_out="$tmp/run-out"
run_text="$(PATH="$stubs:$PATH" \
  CI_REPO_ROOT="$root" CI_TMP_ROOT="$run_ci" CI_LOG_DIR="$run_ci/logs" \
  bash "$fake/cross-upgrade.sh" run \
  --image "$tmp/run-old.img" --payload "$tmp/run-payload.tar" --out "$run_out" 2>&1)"
run_rc=$?
assert_eq "$run_rc" "0" "ac-1 the run half completes with a stub qemu-smoke"
assert_contains "${run_text}" "cross-upgrade=ok slot=b generation=2" \
  "ac-1 the verdict is graded from the guest serial of both boots"
assert_file_exists "$run_out/status.before" "ac-1 the first boot's serial block is graded"
assert_file_exists "$run_out/status.after" "ac-1 the pending block is graded"
assert_file_exists "$run_out/status.committed" "ac-1 the commit block is graded"
assert_contains "$(cat "$run_out/status.before" 2>/dev/null)" "upper=@overlay-25.12.2" \
  "ac-1 the before block is the guest's, not the decoy on stdout"
assert_eq "$(grep -c 'slot=wrong' "$run_out/status.before" 2>/dev/null || true)" "0" \
  "ac-1 qemu-smoke's stdout never reaches a status block"
assert_eq "$(grep -c '^stage progress' "$run_out/serial.log" 2>/dev/null || true)" "0" \
  "ac-1 the graded serial log carries the guest's words only"
assert_eq "$(grep -c '^CROSS-STATUS-BEFORE$' "$run_out/serial.log" 2>/dev/null || true)" "1" \
  "ac-1 the first boot's serial is appended once"
assert_eq "$(grep -c '^CROSS-STATUS-PENDING$' "$run_out/serial.log" 2>/dev/null || true)" "1" \
  "ac-1 the pending block is appended once"
assert_eq "$(grep -c '^CROSS-STATUS-COMMITTED$' "$run_out/serial.log" 2>/dev/null || true)" "1" \
  "ac-1 the second boot's serial is appended, not dropped"
assert_eq "$(grep -n '^CROSS-STATUS-\(BEFORE\|PENDING\|COMMITTED\)$' "$run_out/serial.log" 2>/dev/null | cut -d: -f2 | tr '\n' ' ')" \
  "CROSS-STATUS-BEFORE CROSS-STATUS-PENDING CROSS-STATUS-COMMITTED " \
  "ac-1 both serials are appended in boot order"
assert_contains "$(cat "$run_out/boot1.stdout.log" 2>/dev/null)" "stage progress for cross-boot1" \
  "ac-1 the wrapper's stdout is kept as a diagnostic file"

finish
