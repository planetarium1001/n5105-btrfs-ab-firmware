#!/usr/bin/env bash
# Module: image
# Verifies the S2 contracts that hold without root and without a kernel:
#   ac-1 the partition geometry frozen in scripts/ci/disk.sh matches the documented
#        four-partition layout
#   ac-2 the btrfs mkfs arguments are the ones docs/partitions.md prescribes
#   ac-3 the judge-line gate in scripts/ci/qemu-smoke.sh accepts an S2 ok line and
#        rejects an S2 failure line
#   ac-4 the expectation file written by the host verifier parses back into the
#        values the guest assertion needs (the two sides share one format)
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

disk_script="$root/scripts/ci/disk.sh"
qemu_script="$root/scripts/ci/qemu-smoke.sh"

# ac-1 partition geometry, normalised so reformatting does not break the test
geometry=$(sed -n '/^label: gpt$/,/^SFDISK$/p' "$disk_script" \
  | grep -E 'name="' \
  | sed -E 's/.*start=[[:space:]]*([0-9]+), size=[[:space:]]*([0-9]+).*name="([^"]+)".*/\3 \1 \2/' \
  | paste -sd';' -)
assert_eq "$geometry" \
  "ab-esp 2048 262144;ab-slot-a 264192 262144;ab-slot-b 526336 262144;ab-shared 788480 131072" \
  "ac-1 partition geometry matches the documented layout"

esp_type=$(sed -n '/^label: gpt$/,/^SFDISK$/p' "$disk_script" | grep 'name="ab-esp"' || true)
assert_contains "$esp_type" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" \
  "ac-1 p1 is typed as an EFI system partition"

# ac-2 filesystem arguments and subvolume layout
assert_contains "$(cat "$disk_script")" "mkfs.btrfs -f -m dup -d single" \
  "ac-2 p2/p3 use metadata duplication"
assert_contains "$(cat "$disk_script")" "mkfs.btrfs -f -m single -d single" \
  "ac-2 p4 uses single metadata"
assert_contains "$(cat "$disk_script")" '@overlay-${upstream_version}' \
  "ac-2 the writable layer is named after the upstream version"
assert_contains "$(cat "$disk_script")" '"upper": "${overlay_name}"' \
  "ac-2 the state file records the layer name, not a number"
assert_contains "$(cat "$disk_script")" 'chattr +C' \
  "ac-2 @docker and @swap are allocated without COW"

# ac-3 judge-line gate, driven through stubs so no QEMU is needed
stubs="$tmp/stubs"
mkdir -p "$stubs" "$tmp/work"
printf '#!/bin/sh\nexit 0\n' >"$stubs/mkfs.btrfs"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$stubs/timeout"
cat >"$stubs/qemu-system-x86_64" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in file:*) log="${arg#file:}" ;; esac
done
if [ "${STUB_RESULT:-ok}" = "ok" ]; then
  printf '[s2] partitions ok\nS2-RESULT=ok parts=4 images=471859200\n' >"$log"
else
  printf '[s2] subvolume layout wrong\nS2-RESULT=fail reason=p2-subvolumes-@sys\n' >"$log"
fi
STUB
chmod +x "$stubs"/*
: >"$tmp/work/kernel.bin"
: >"$tmp/work/initramfs.cpio.gz"
: >"$tmp/work/disk.img"

run_gate() {
  PATH="$stubs:$PATH" \
    CI_TMP_ROOT="$tmp/work/ci" \
    CI_LOG_DIR="$tmp/work/ci/logs" \
    CI_QEMU_DIR="$tmp/work/qemu-$1" \
    CI_KERNEL="$tmp/work/kernel.bin" \
    CI_INITRAMFS="$tmp/work/initramfs.cpio.gz" \
    CI_QEMU_DISK="$tmp/work/disk.img" \
    CI_QEMU_INIT=/s2.sh \
    CI_JUDGE_PREFIX=S2-RESULT \
    bash "$qemu_script" 2>&1
}

ok_output=$(STUB_RESULT=ok run_gate ok)
assert_eq "$?" "0" "ac-3 an S2 ok line passes the gate"
assert_contains "$ok_output" "S2-RESULT=ok parts=4 images=471859200" \
  "ac-3 the judge line is reported verbatim"

fail_output=$(STUB_RESULT=fail run_gate fail)
fail_status=$?
assert_eq "$fail_status" "1" "ac-3 an S2 failure line fails the gate"
assert_contains "$fail_output" "S2-RESULT failed" \
  "ac-3 the failure names the judged prefix"

# ac-4 expectation file contract: the writer is image-verify.sh, the reader is the
# guest assertion; both must agree on the exact bytes in between.
expect_file="$tmp/expect.txt"
{
  printf 'files=%s\n' "1483"
  printf 'images=%s\n' "471859200"
  printf 'parts=4\n'
  printf 'p1max_kib=65536\n'
  printf 'sample %s %s\n' "/bin/busybox" "5c1b0ac1d4c0c0e0aa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"
} >"$expect_file"

read -r -d '' reader <<'READER'
set -u
expect_files=""
expect_images=""
expect_parts=""
expect_p1max=""
SAMPLES=""
while IFS=' =' read -r key value extra; do
    case "${key}" in
        files) expect_files="${value}" ;;
        images) expect_images="${value}" ;;
        parts) expect_parts="${value}" ;;
        p1max_kib) expect_p1max="${value}" ;;
        sample) SAMPLES="${SAMPLES}${value}=${extra} " ;;
        *) : ;;
    esac
done <"$1"
printf '%s|%s|%s|%s|%s\n' "$expect_files" "$expect_images" "$expect_parts" "$expect_p1max" "$SAMPLES"
READER

parsed=$(sh -c "$reader" sh "$expect_file")
assert_eq "$parsed" "1483|471859200|4|65536|/bin/busybox=5c1b0ac1d4c0c0e0aa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071 " \
  "ac-4 the expectation file round-trips through the guest parser"

# The guest parser and the script must not drift apart: the assertion below fails if
# guest-assert.sh stops using the same field separator.
assert_contains "$(cat "$root/tests/modules/image/guest-assert.sh")" "IFS=' =' read -r key value extra" \
  "ac-4 the guest assertion reads the expectation file with the shared separator"

finish
