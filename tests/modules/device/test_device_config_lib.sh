#!/usr/bin/env bash
# Module: device
# The shared config verifier (tests/lib/device_config.sh) against a device that is a
# directory: a stub `ssh` replays every remote command inside $FAKE_ROOT, so what is
# under test is snapshots, diffs, value assertions and the promise that an injected bad
# config is always put back -- not hardware.
#   ac-1 a snapshot is path, state, sha256 and size, and can also carry the content
#   ac-2 two snapshots diff as added / removed / changed, and that is a non-zero status
#   ac-3 a config value assertion names the option, the expected and the actual value
#   ac-4 an injected bad config can always be undone, including after a half-done write
#   ac-5 a result row is case<TAB>verdict<TAB>evidence<TAB>note, verdict PASS|FAIL|GAP
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

lib="$root/tests/lib/device_config.sh"
# shellcheck source=../../lib/device_config.sh
. "$lib"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the stub machine ------------------------------------------------------ #
# Every remote command the library builds is replayed against a local directory, so a
# snapshot, an injection and its restore really move bytes.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for arg in "$@"; do last=${arg}; done
if [ -n "${STUB_FAIL_MATCH:-}" ]; then
    case "${last}" in
        *"${STUB_FAIL_MATCH}"*) exit 255 ;;
    esac
fi
strip() { printf '%s\n' "$1" | tr -d "'"; }
set -- ${last}
case "${1:-}" in
    cat)
        if [ "${2:-}" = ">" ]; then
            if [ "${STUB_MANGLE_WRITE:-0}" = "1" ]; then
                cat >/dev/null
                printf 'mangled\n' >"${FAKE_ROOT}$(strip "${3:?}")"
            else
                cat >"${FAKE_ROOT}$(strip "${3:?}")"
            fi
            exit 0
        fi
        cat "${FAKE_ROOT}$(strip "${2:?}")"
        ;;
    cp)
        cp -a "${FAKE_ROOT}$(strip "${3:?}")" "${FAKE_ROOT}$(strip "${4:?}")"
        ;;
    rm)
        rm -f "${FAKE_ROOT}$(strip "${3:?}")"
        ;;
    uci)
        key=$(strip "${4:?}")
        [ -f "${FAKE_ROOT}/uci/${key}" ] || exit 1
        cat "${FAKE_ROOT}/uci/${key}"
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$stub_bin/ssh"

FAKE_ROOT="$tmp/device"
STUB_CALLS="$tmp/calls.log"
mkdir -p "$FAKE_ROOT/etc/config" "$FAKE_ROOT/uci"
export FAKE_ROOT STUB_CALLS
export PATH="$stub_bin:$PATH"

# A real-world configuration file: Chinese, a blank line, quotes and shell metacharacters.
cat >"$FAKE_ROOT/etc/config/openclash" <<'CFG'
config openclash 'config'
	option enable '1'

	option name '我的代理 配置'
	option special 'a&b|c$d `e"f'
CFG
printf 'config dummy\n' >"$FAKE_ROOT/etc/config/extra"
printf '1\n' >"$FAKE_ROOT/uci/openclash.config.enable"

DEVCFG_EXEC=ssh
DEVCFG_RESULTS="$tmp/results.tsv"
DEVCFG_STATE_DIR="$tmp/devcfg-state"
export DEVCFG_EXEC DEVCFG_RESULTS DEVCFG_STATE_DIR

gone_or_there() { [ ! -e "$1" ] && echo gone || echo there; }

sha_of() { # <file>
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# --- the library is sh, not bash ------------------------------------------ #
out=$(sh -n "$lib" 2>&1)
assert_eq "$?" "0" "the library parses under the shell the device drivers run with: $out"

# A library that guessed a host by itself would be a second place that knows the device.
out=$(env -u DEVCFG_EXEC sh -c '. "$1"; devcfg_snapshot "$2" /etc/config/openclash' \
    _ "$lib" "$tmp/noexec.tsv" 2>&1)
assert_eq "$?" "2" "a library with no executor refuses to guess a host"
assert_contains "$out" "no executor" "the refusal says what to set"

# --- ac-1: a snapshot ------------------------------------------------------ #
: >"$STUB_CALLS"
devcfg_snapshot "$tmp/snap-a.tsv" /etc/config/openclash; rc=$?
assert_eq "$rc" "0" "a snapshot of a readable file exits zero"
assert_eq "$(cut -f1 "$tmp/snap-a.tsv")" "/etc/config/openclash" "the path is the first column"
assert_eq "$(cut -f2 "$tmp/snap-a.tsv")" "ok" "a file the device has is recorded as ok"
assert_eq "$(cut -f3 "$tmp/snap-a.tsv")" "$(sha_of "$FAKE_ROOT/etc/config/openclash")" \
    "the hash is the sha256 of what the device returned"
assert_eq "$(cut -f4 "$tmp/snap-a.tsv")" "$(wc -c <"$FAKE_ROOT/etc/config/openclash" | tr -d ' ')" \
    "the size is the byte count"
assert_contains "$(cat "$STUB_CALLS")" "cat '/etc/config/openclash'" \
    "the read goes through the caller's executor, not through a socket opened here"

devcfg_snapshot "$tmp/snap-missing.tsv" /etc/config/nothere; rc=$?
assert_eq "$rc" "1" "a path the device does not have is reported as a difference, not hidden"
assert_eq "$(cut -f2 "$tmp/snap-missing.tsv")" "missing" "an absent file is recorded as missing"

# The same read through a command prefix rather than a bare command name.
( DEVCFG_EXEC="ssh -o BatchMode=yes" \
  sh -c '. "$1"; devcfg_snapshot "$2" /etc/config/openclash' _ "$lib" "$tmp/snap-prefix.tsv" )
assert_eq "$?" "0" "an executor given as a command prefix works too"

# The content mode is what makes a difference readable without a second ssh.
devcfg_snapshot --content "$tmp/snap-full.tsv" /etc/config/openclash; rc=$?
assert_eq "$rc" "0" "a snapshot with content exits zero"
rel=$(cut -f5 "$tmp/snap-full.tsv")
assert_file_exists "$tmp/snap-full.tsv.content/$rel" "the content copy lands beside the snapshot"
assert_eq "$(cat "$tmp/snap-full.tsv.content/$rel")" "$(cat "$FAKE_ROOT/etc/config/openclash")" \
    "the copy keeps Chinese, the blank line and shell metacharacters byte for byte"

# --- ac-2: comparing two snapshots ---------------------------------------- #
devcfg_snapshot "$tmp/snap-1.tsv" /etc/config/openclash /etc/config/extra
out=$(devcfg_diff "$tmp/snap-1.tsv" "$tmp/snap-1.tsv"); rc=$?
assert_eq "$rc" "0" "two identical snapshots are not a difference"
assert_eq "$out" "" "an identical pair prints nothing"

printf 'config dummy\n\n' >"$FAKE_ROOT/etc/config/added"
devcfg_snapshot "$tmp/snap-2.tsv" /etc/config/openclash /etc/config/extra /etc/config/added
out=$(devcfg_diff "$tmp/snap-1.tsv" "$tmp/snap-2.tsv"); rc=$?
assert_eq "$rc" "1" "a file only the second snapshot has is a difference"
assert_eq "$out" "$(printf 'added\t/etc/config/added\tok')" \
    "the new file is named with its path and state"

printf "config openclash 'config'\n\toption enable '0'\n" >"$FAKE_ROOT/etc/config/openclash"
rm -f "$FAKE_ROOT/etc/config/extra"
devcfg_snapshot "$tmp/snap-3.tsv" /etc/config/openclash /etc/config/added
out=$(devcfg_diff "$tmp/snap-1.tsv" "$tmp/snap-3.tsv"); rc=$?
assert_eq "$rc" "1" "a changed and a vanished file are differences"
assert_matches "$out" "$(printf 'changed\t/etc/config/openclash\t[0-9a-f]{64}\t[0-9a-f]{64}')" \
    "a changed file carries both hashes"
assert_contains "$out" "$(printf 'removed\t/etc/config/extra\tok')" \
    "a file the second snapshot no longer has is named"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "3" \
    "the new, the changed and the vanished file, and nothing else"

# The same comparison as a verdict row, which is what a driver writes.
: >"$DEVCFG_RESULTS"
devcfg_assert_same C9 "$tmp/snap-1.tsv" "$tmp/snap-1.tsv" "$tmp/C9.log"; rc=$?
assert_eq "$rc" "0" "an unchanged pair passes the assertion"
assert_eq "$(awk -F'\t' 'NR == 1 {print $1" "$2" "$3}' "$DEVCFG_RESULTS")" "C9 PASS $tmp/C9.log" \
    "the assertion writes the row a driver would read"
out=$(devcfg_assert_same C10 "$tmp/snap-1.tsv" "$tmp/snap-3.tsv" 2>&1); rc=$?
assert_eq "$rc" "1" "a changed pair fails the assertion"
assert_contains "$out" "FAIL C10" "the failure names the case"
assert_contains "$out" "changed	/etc/config/openclash" "the failure lists the file that moved"
assert_eq "$(awk -F'\t' 'END {print $2}' "$DEVCFG_RESULTS")" "FAIL" "a changed pair records FAIL"

# --- ac-3: a config value -------------------------------------------------- #
assert_eq "$(devcfg_get openclash.config.enable)" "1" "an option is read as its value"
rc=0
devcfg_get openclash.config.nosuch >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "an option the device does not have is a non-zero read"

: >"$DEVCFG_RESULTS"
out=$(devcfg_assert_config C1 "$tmp/C1.log" openclash.config.enable 1); rc=$?
assert_eq "$rc" "0" "the expected value passes"
assert_eq "$out" "" "a passing assertion prints nothing"
assert_eq "$(awk -F'\t' '{print NF}' "$DEVCFG_RESULTS")" "4" "the row has four TAB separated columns"
assert_eq "$(awk -F'\t' 'NR == 1 {print $1" "$2" "$3}' "$DEVCFG_RESULTS")" "C1 PASS $tmp/C1.log" \
    "a taken value records PASS against the evidence path"

out=$(devcfg_assert_config C2 "$tmp/C2.log" openclash.config.enable 0 2>&1); rc=$?
assert_eq "$rc" "1" "a different value fails"
assert_contains "$out" "openclash.config.enable" "the failure names the option"
assert_contains "$out" "expected=0 got=1" "the failure states both values"
assert_eq "$(awk -F'\t' 'END {print $2}' "$DEVCFG_RESULTS")" "FAIL" "a wrong value records FAIL"
assert_contains "$(awk -F'\t' 'END {print $4}' "$DEVCFG_RESULTS")" "expected=0 got=1" \
    "the note keeps the expected and the actual value"

out=$(devcfg_assert_config C3 - openclash.config.nosuch 1 2>&1); rc=$?
assert_eq "$rc" "1" "an unreadable option is a failure, not a silent pass"
assert_contains "$out" "uci -q get" "the failure says which device command answered nothing"

# No executor is an environment gap (exit 4), not a failed config: a driver must not
# report a device it never reached as a broken setting.
: >"$tmp/gap.tsv"
out=$(env -u DEVCFG_EXEC DEVCFG_RESULTS="$tmp/gap.tsv" bash -c \
    '. "$1"; devcfg_assert_config G1 - openclash.config.enable 1' _ "$lib" 2>&1); rc=$?
assert_eq "$rc" "4" "no executor is the gap status, not a failure"
assert_eq "$(awk -F'\t' 'NR == 1 {print $2}' "$tmp/gap.tsv")" "GAP" "the row says GAP, not FAIL"

# --- ac-5: the row format -------------------------------------------------- #
: >"$DEVCFG_RESULTS"
devcfg_record R1 PASS - "note with	a tab"
devcfg_record R2 GAP - "no third-party feed"
assert_eq "$(awk -F'\t' '{print NF}' "$DEVCFG_RESULTS" | tr '\n' ' ')" "4 4 " \
    "every row stays four columns, even with a tab in the note"
assert_eq "$(awk -F'\t' '{print $2}' "$DEVCFG_RESULTS" | tr '\n' ' ')" "PASS GAP " \
    "PASS and GAP are both accepted"
devcfg_record R3 BROKEN - x 2>/dev/null; rc=$?
assert_eq "$rc" "2" "an unknown verdict is refused instead of written"
assert_eq "$(wc -l <"$DEVCFG_RESULTS" | tr -d ' ')" "2" "the refused row was not written"
assert_eq "$(devcfg_row R4 FAIL - x)" "$(printf 'R4\tFAIL\t-\tx')" "a row can be rendered without writing it"

# --- ac-4: grabbing the target file ---------------------------------------- #
target=/etc/config/openclash
orig=$(cat "$FAKE_ROOT$target")
bad_cfg="config openclash 'config'
	option enable 'yes-but-broken"

: >"$STUB_CALLS"
out=$(devcfg_inject_bad B1 "$target" "$bad_cfg" "$tmp/backups" 2>&1); rc=$?
assert_eq "$rc" "0" "an injection reports success once the bad bytes are on the device"
assert_eq "$(cat "$FAKE_ROOT$target")" "$bad_cfg" "the device now holds the bad content"
assert_file_exists "$FAKE_ROOT$target.devcfg-bak-B1" "the original is kept beside the target"
assert_eq "$(cat "$FAKE_ROOT$target.devcfg-bak-B1")" "$orig" "the backup is the original, byte for byte"
assert_file_exists "$tmp/backups/B1.orig" "a local copy is kept for the defect report"
assert_contains "$out" "restore" "the injection hands back the restore command"
assert_contains "$(cat "$STUB_CALLS")" "cp -a '$target' '$target.devcfg-bak-B1'" \
    "the backup is taken over the caller's executor"
bk_line=$(grep -n "cp -a '$target'" "$STUB_CALLS" | head -n1 | cut -d: -f1)
wr_line=$(grep -n "cat > '$target'" "$STUB_CALLS" | head -n1 | cut -d: -f1)
[ -n "$bk_line" ] && [ -n "$wr_line" ] && [ "$bk_line" -lt "$wr_line" ]
assert_eq "$?" "0" "the backup is taken before anything is overwritten"

out=$(devcfg_restore B1 2>&1); rc=$?
assert_eq "$rc" "0" "the tagged restore puts the original back"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "the file is the original again"
assert_eq "$(gone_or_there "$FAKE_ROOT$target.devcfg-bak-B1")" "gone" \
    "the backup is removed after a verified restore"
assert_eq "$(grep -c 'B1' "$DEVCFG_STATE_DIR/restore.tsv" 2>/dev/null || true)" "0" \
    "a restored injection leaves no live entry"
devcfg_restore B1; rc=$?
assert_eq "$rc" "0" "restoring a tag that is already back is a no-op, not an error"

# A write that fails halfway: the caller still gets the original file back.
export STUB_FAIL_MATCH="cat > '$target'"
out=$(devcfg_inject_bad B2 "$target" "$bad_cfg" 2>&1); rc=$?
unset STUB_FAIL_MATCH
assert_eq "$rc" "1" "an injection whose write fails is a failure"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "a failed write still leaves the original in place"
assert_contains "$(cat "$STUB_CALLS")" "cp -a '$target.devcfg-bak-B2' '$target'" \
    "the half-done injection was rolled back before it reported failure"

# A write that exits zero but did not land as written: verified, then rolled back.
export STUB_MANGLE_WRITE=1
out=$(devcfg_inject_bad B3 "$target" "$bad_cfg" 2>&1); rc=$?
unset STUB_MANGLE_WRITE
assert_eq "$rc" "1" "an injection that did not land as written is a failure, not a pass"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "the original is back even though the write exited zero"

# Two live injections, then one call that puts both back (the trap path).
printf 'config dummy\n' >"$FAKE_ROOT/etc/config/extra"
extra_orig=$(cat "$FAKE_ROOT/etc/config/extra")
: >"$STUB_CALLS"
devcfg_inject_bad B4 "$target" "$bad_cfg" >/dev/null 2>&1
devcfg_inject_bad B5 /etc/config/extra "broken-extra" >/dev/null 2>&1
assert_eq "$(wc -l <"$DEVCFG_STATE_DIR/restore.tsv" | tr -d ' ')" "2" \
    "two live injections are registered"
out=$(devcfg_restore_all 2>&1); rc=$?
assert_eq "$rc" "0" "restore-all returns zero when every backup is back"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "the first file is back"
assert_eq "$(cat "$FAKE_ROOT/etc/config/extra")" "$extra_orig" "the second file is back"
assert_eq "$(wc -l <"$DEVCFG_STATE_DIR/restore.tsv" | tr -d ' ')" "0" "no live entry is left"

# A driver that dies after injecting: the trap is the last line of defence.
out=$(DEVCFG_STATE_DIR="$tmp/trap-state" bash -c '
    . "$1"
    devcfg_install_restore_trap
    devcfg_inject_bad T1 "$2" "trapped" >/dev/null
    exit 7
' _ "$lib" "$target" 2>&1); rc=$?
assert_eq "$rc" "7" "the script exits with the status it chose"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "the trap put the original back even though the script died"
assert_contains "$out" "restored" "the trap says what it put back"

# --- the same three functions under sh, the shell the drivers run with ----- #
out=$(DEVCFG_STATE_DIR="$tmp/sh-state" sh -c '
    . "$1"
    devcfg_snapshot "$2" /etc/config/openclash || exit 1
    devcfg_inject_bad S1 "$3" "bad-from-sh" || exit 1
    devcfg_restore S1 || exit 1
' _ "$lib" "$tmp/snap-sh.tsv" "$target" 2>&1); rc=$?
assert_eq "$rc" "0" "snapshot, injection and restore work under sh, not only under bash: $out"
assert_eq "$(cut -f2 "$tmp/snap-sh.tsv")" "ok" "the sh snapshot recorded the file"
assert_eq "$(cat "$FAKE_ROOT$target")" "$orig" "the sh session restored the original"

finish
