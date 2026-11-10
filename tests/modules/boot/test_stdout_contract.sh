#!/usr/bin/env bash
# Module: boot
# Several helpers in the boot path are used as `value="$(helper ...)"`: their stdout is the
# answer, not a log. A single leaked log line turns `done 921566` into `[grow]` and turns
# a successful growth into `fail:grow-crashed` — which is exactly what happened when the
# console mirroring was routed through stdout.
#   ac-1 wf_grow_run prints exactly one line, `^(done|already-full|missing-sfdisk|fail:<token>) <n>$`
#   ac-2 every other captured helper (decide, apply, fs, sectors, di_resolve) prints one token
#   ac-3 diagnostics still exist, on stderr, and are mirrored to the serial device only
#   ac-4 the mirror never reaches stdout, even when the serial path is writable
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sys="$tmp/sys/block"
mkdir -p "$sys/vda" "$sys/vda/vda4" "$tmp/work" "$tmp/bin" "$tmp/table" "$tmp/mnt/p4"
mkdir -p "$sys/vda/queue"
printf '512\n' >"$sys/vda/queue/logical_block_size"
printf '921600\n' >"$sys/vda/size"
printf 'DEVTYPE=disk\nDEVNAME=vda\n' >"$sys/vda/uevent"
printf '0\n' >"$sys/vda/removable"
printf '4\n' >"$sys/vda/vda4/partition"
printf 'DEVTYPE=partition\nDEVNAME=vda4\nPARTN=4\nPARTNAME=ab-data\n' >"$sys/vda/vda4/uevent"
ln -sfn "vda/vda4" "$sys/vda4"
printf '131072\n' >"$sys/vda4/size"

# The serial side channel is a regular file so the test can see what was mirrored.
serial="$tmp/ttyS0"
consoles="$tmp/consoles"
: >"$serial"
# Empty console table: "cannot tell where /dev/console points", so the mirror is written.
: >"$consoles"

export GROW_FIXTURE="$tmp"
DI_SYS_BLOCK="$sys"
DI_DEV_DIR="/dev"
DI_CMDLINE="$tmp/cmdline"
DI_MOUNTS="$tmp/mounts"
DI_BLKID="$tmp/bin/blkid"
WF_SERIAL="$serial"
WF_CONSOLES="$consoles"
WF_SYS_BLOCK="$sys"
WF_GROW_TMP="$tmp/work"
WF_GROW_VERIFY_TRIES=2
WF_MOUNTS="$tmp/mounts"
export DI_SYS_BLOCK DI_DEV_DIR DI_CMDLINE DI_MOUNTS DI_BLKID \
  WF_SERIAL WF_CONSOLES WF_SYS_BLOCK WF_GROW_TMP WF_GROW_VERIFY_TRIES WF_MOUNTS

source "$root/initramfs/lib/wf.sh"
source "$root/initramfs/lib/grow.sh"
source "$root/platform/lib/disk-identity.sh"

WF_SFDISK="$tmp/bin/sfdisk"
WF_BLOCKDEV="$tmp/bin/blockdev"
WF_PARTX="$tmp/bin/partx"
WF_BTRFS="$tmp/bin/btrfs"
WF_SLEEP="$tmp/bin/sleep"
export WF_SFDISK WF_BLOCKDEV WF_PARTX WF_BTRFS WF_SLEEP

cat >"$tmp/bin/sfdisk" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${GROW_FIXTURE}/sfdisk.calls"
case "$1" in
  -d)
    [ "${STUB_DUMP_FAIL:-0}" = "1" ] && exit 1
    cat "${GROW_FIXTURE}/table/current"
    ;;
  --no-reread)
    [ "${STUB_WRITE_FAIL:-0}" = "1" ] && exit 1
    cat >"${GROW_FIXTURE}/table/written"
    cp "${GROW_FIXTURE}/table/written" "${GROW_FIXTURE}/table/current"
    size="$(sed -n 's|^/dev/vda4 : start= *[0-9]*, size= *\([0-9]*\).*|\1|p' \
      "${GROW_FIXTURE}/table/written")"
    printf '%s\n' "${size}" >"${GROW_FIXTURE}/sys/block/vda4/size"
    ;;
  *) exit 2 ;;
esac
STUB
cat >"$tmp/bin/blockdev" <<'STUB'
#!/bin/sh
case "$1" in
  --rereadpt) exit 0 ;;
  --getsize64) printf '%s\n' 471859200 ;;
  *) exit 2 ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/partx"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/btrfs"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*

table() { # <p4 size>
  cat <<TABLE
label: gpt
device: /dev/vda
unit: sectors
first-lba: 34
last-lba: 921566
sector-size: 512

/dev/vda1 : start=        2048, size=      262144, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=11111111-0000-0000-0000-000000000001, name="ab-esp"
/dev/vda2 : start=      264192, size=      262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000002, name="ab-slot-a"
/dev/vda3 : start=      526336, size=      262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000003, name="ab-slot-b"
/dev/vda4 : start=      788480, size=      $1, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-0000-0000-0000-000000000004, name="ab-data"
TABLE
}

reset_fixture() {
  table 131072 >"$tmp/table/current"
  printf '131072\n' >"$sys/vda4/size"
  : >"$serial"
  : >"$tmp/sfdisk.calls"
  printf '/dev/vda4 %s btrfs rw,noatime 0 0\n' "$tmp/mnt/p4" >"$WF_MOUNTS"
  : >"$tmp/cmdline"
}

# run_captured <command...>: stdout and stderr of a captured helper, separated
run_captured() {
  captured_out="$("$@" 2>"$tmp/stderr.txt")"
  captured_err="$(cat "$tmp/stderr.txt")"
}

# run_captured_env <VAR> <value> <command...>: same, with one variable exported for the
# call (a stub reads it from its own environment).
run_captured_env() {
  run_captured_var="$1"
  run_captured_value="$2"
  shift 2
  captured_out="$( export "${run_captured_var}=${run_captured_value}"; "$@" 2>"$tmp/stderr.txt" )"
  captured_err="$(cat "$tmp/stderr.txt")"
}

RESULT_RE='^(done|already-full|missing-sfdisk|fail:[a-z-]+) [0-9]+$'

# --------------------------------------------------------------------------- #
# ac-1 wf_grow_run: exactly one result line, whatever the outcome
# --------------------------------------------------------------------------- #

reset_fixture
run_captured wf_grow_run /dev/vda /dev/vda4
assert_eq "$(printf '%s\n' "${captured_out}" | wc -l | tr -d ' ')" "1" \
  "ac-1 a successful run prints exactly one line"
assert_matches "${captured_out}" "${RESULT_RE}" "ac-1 the line is <state> <last_lba>"
assert_eq "${captured_out}" "done 921566" "ac-1 the state is done on a first boot"
assert_contains "${captured_err}" "[grow]" "ac-1 the diagnostics went to stderr"

run_captured wf_grow_run /dev/vda /dev/vda4
assert_eq "${captured_out}" "already-full 921566" \
  "ac-1 the second boot is a single already-full line"

reset_fixture
run_captured_env WF_SFDISK "$tmp/bin/absent-sfdisk" wf_grow_run /dev/vda /dev/vda4
assert_eq "${captured_out}" "missing-sfdisk 0" "ac-1 missing-sfdisk stays a single line"

reset_fixture
run_captured_env STUB_WRITE_FAIL 1 wf_grow_run /dev/vda /dev/vda4
assert_eq "${captured_out}" "fail:partition-table-write 921566" \
  "ac-1 a failed write is one fail:<token> line"
assert_matches "${captured_out}" "${RESULT_RE}" "ac-1 a failure line matches the frozen shape"
assert_contains "${captured_err}" "[grow]" "ac-1 failure diagnostics stay on stderr"

reset_fixture
run_captured_env STUB_DUMP_FAIL 1 wf_grow_run /dev/vda /dev/vda4
assert_eq "${captured_out}" "fail:partition-table-read 0" \
  "ac-1 an unreadable table is one line"
assert_matches "${captured_out}" "${RESULT_RE}" "ac-1 the read failure matches the frozen shape"

# The mirror is a serial side channel: the captured stdout above must never contain it.
assert_contains "$(cat "$serial")" "[grow]" \
  "ac-3 the same diagnostics are mirrored to the serial device"

# --------------------------------------------------------------------------- #
# ac-2 the other captured helpers
# --------------------------------------------------------------------------- #

reset_fixture
run_captured wf_grow_decide "$tmp/table/current" /dev/vda4 921600
assert_eq "${captured_out}" "grow 921566 133080" "ac-2 decide answers one line"
assert_eq "$(printf '%s\n' "${captured_out}" | wc -l | tr -d ' ')" "1" \
  "ac-2 decide never prints a second line"

table 133087 >"$tmp/table/grown"
run_captured wf_grow_decide "$tmp/table/grown" /dev/vda4 921600
assert_eq "${captured_out}" "already-full 921566" "ac-2 decide reports already-full alone"

reset_fixture
run_captured wf_grow_fs "$tmp/mnt/p4"
assert_eq "${captured_out}" "done" "ac-2 the resize reports one token"
assert_contains "${captured_err}" "[grow] btrfs filesystem resize max" \
  "ac-2 the resize log went to stderr"
assert_eq "$(printf '%s\n' "${captured_out}" | wc -l | tr -d ' ')" "1" \
  "ac-2 the resize never prints a second line"

run_captured wf_grow_fs /dev/vda4
assert_eq "${captured_out}" "fail:resize-target" "ac-2 a refused target is one token"

reset_fixture
run_captured wf_grow_log "a diagnostic line"
assert_eq "${captured_out}" "" "ac-3 a bare log line prints nothing on stdout"
assert_eq "${captured_err}" "[grow] a diagnostic line" "ac-3 it prints on stderr"
assert_contains "$(cat "$serial")" "[grow] a diagnostic line" \
  "ac-3 and it is mirrored to the serial device"

# --------------------------------------------------------------------------- #
# ac-2 di_resolve keeps its stdout a single line too
# --------------------------------------------------------------------------- #

reset_fixture
mkdir -p "$tmp/esp/ab"
cat >"$tmp/esp/ab/device.json" <<'JSON'
{ "partitions": { "ab-esp": { "partuuid": "dead0000-0000-0000-0000-000000000000" } } }
JSON
cat >"$tmp/bin/blkid" <<'STUB'
#!/bin/sh
exit 2
STUB
chmod +x "$tmp/bin/blkid"
fixture_part() { # <dev> <n> <partname>
  mkdir -p "$sys/vda/$1"
  printf '%s\n' "$2" >"$sys/vda/$1/partition"
  printf 'DEVTYPE=partition\nDEVNAME=%s\nPARTN=%s\nPARTNAME=%s\n' "$1" "$2" "$3" \
    >"$sys/vda/$1/uevent"
  ln -sfn "vda/$1" "$sys/$1"
}
fixture_part vda1 1 ab-esp
fixture_part vda2 2 ab-slot-a
fixture_part vda3 3 ab-slot-b
# A kernel parameter naming a disk that carries no ab-esp makes the resolver warn; the
# warning must go to stderr while stdout stays the single answer line.
printf 'ab.disk=/dev/sdq\n' >"$tmp/cmdline"
run_captured di_resolve "$tmp/esp"
assert_eq "${captured_out}" "disk=/dev/vda method=partname" \
  "ac-2 the resolver answers one line even with an unusable device.json"
assert_eq "$(printf '%s\n' "${captured_out}" | wc -l | tr -d ' ')" "1" \
  "ac-2 the resolver never prints a second line"
assert_contains "${captured_err}" "[disk]" \
  "ac-2 the resolver's warnings went to stderr"

# --------------------------------------------------------------------------- #
# ac-4 static: the mirror helpers cannot write to stdout
# --------------------------------------------------------------------------- #

wf_lib="$(cat "$root/initramfs/lib/wf.sh")"
serial_body="$(printf '%s' "${wf_lib}" | sed -n '/^wf_say_serial() {/,/^}/p')"
assert_contains "${serial_body}" 'printf' "ac-4 the serial mirror writes the line"
assert_eq "$(printf '%s' "${serial_body}" | grep -c '>>"${WF_SERIAL}"')" "1" \
  "ac-4 the mirror appends to the serial device"
assert_eq "$(printf '%s' "${serial_body}" | grep -cE '^ *printf .*[^>]>"?$/')" "0" \
  "ac-4 the mirror has no stdout write of its own"

grow_lib="$(cat "$root/initramfs/lib/grow.sh")"
log_body="$(printf '%s' "${grow_lib}" | sed -n '/^wf_grow_log() {/,/^}/p')"
assert_contains "${log_body}" ">&2" "ac-4 wf_grow_log prints on stderr"
assert_contains "${log_body}" "wf_say_serial" "ac-4 wf_grow_log mirrors through the serial helper"
assert_eq "$(printf '%s' "${log_body}" | grep -c 'wf_say \"')" "0" \
  "ac-4 wf_grow_log never calls the stdout helper"

finish
