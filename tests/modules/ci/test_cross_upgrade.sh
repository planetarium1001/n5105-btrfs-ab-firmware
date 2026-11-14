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
assert_eq "$(grep -c 'CI_KERNEL="${_boot}/kernel.bin"' "$script")" "2" \
  "ac-7 both boots get the kernel the old image carries"
assert_eq "$(grep -c 'CI_INITRAMFS="${_boot}/initrd.cpio.gz"' "$script")" "2" \
  "ac-7 both boots get that image's initrd"
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

finish
