#!/usr/bin/env bash
# Module: device
# ac-5: five wrong configurations, three questions each, against a machine made of stubs.
#
# Why this file exists: a bad configuration can be refused, tolerated, restored or adopted,
# and only one of those four leaves the machine in the state its owner meant. The driver
# under test (scripts/device/badconfig-probe.sh) has to tell them apart per class, and the
# two mistakes that would make its verdict useless are exactly the two the exit codes hide:
#
#   * a class that "passed" because a tool exited 0. `fw4 check` warns about an invalid
#     option, skips the section and still exits 0 (measured on the 25.x line), so the
#     rendered ruleset -- not the exit status -- is the witness. C4 below therefore has a
#     replay where fw4 adopts the rule, and the driver must call that a FAIL.
#   * a class that "passed" because a restore was never verified. A failed restore leaves the
#     bad file on the machine; that is a FAIL and it must say where the backup is, never a
#     silent pass. C1 below replays exactly that.
#
# The stub machine is a real directory tree plus stub tools on PATH, and the stub `ssh` runs
# the command string it was given through `sh -c`. So the driver's own logic is under test --
# the quoting, the pipes, the redirections, the parsing of what a tool said -- and nothing
# reaches a device. Every file the driver edits is named by an AB_BADCFG_* variable, which is
# how the same code can be walked against a tree in $tmp.
#
#   C1 openclash   an unterminated quote (libuci refuses to parse it) and a boolean that is
#                  not a boolean (the parser accepts it: uci has no schema), plus the replay
#                  where nothing puts the original back
#   C2 docker      a truncated daemon.json and an option dockerd does not know
#   C3 network     a section naming a device nothing has, and a protocol no handler answers
#   C4 firewall    the warn-and-skip rule (PASS, and the rule is absent) and the adopted rule
#                  (FAIL, because the rendered ruleset carries it)
#   C5 fake source a domain that does not resolve and a URL that answers 404, with the
#                  known-good fetch as the control -- and the replay where the control fails
#                  too, which is a GAP and never a PASS
#
# Also asserted, because they are the contract every device driver in this repository keeps:
# the row shape `case<TAB>verdict<TAB>evidence<TAB>note`, the verdict vocabulary PASS/FAIL/
# GAP, `--dry-run` contacting nothing and writing nothing, `--case` refusing an unknown id,
# and the red line that refuses a 24.x machine before a single byte is written (24.x is the
# opkg line: a conclusion measured there does not transfer).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

probe="$root/scripts/device/badconfig-probe.sh"
assert_file_exists "$probe" "ac-5 the bad-config driver exists"

# --- the machine ----------------------------------------------------------- #
# One directory tree the driver edits, and a PATH of tools that answer about it. The stub
# `ssh` is the whole transport: it records the command line and then runs it with `sh -c`,
# which is what makes the driver's own quoting part of what is tested.
bin="$tmp/bin"
calls="$tmp/calls"
dev="$tmp/device"
results="$tmp/badconfig-results.tsv"
defects="$tmp/badconfig-defects.tsv"
key="$tmp/key"
version="$tmp/version"
status="$tmp/status"
packages="$tmp/packages"
mkdir -p "$bin" "$dev/etc/config" "$dev/etc/docker" "$dev/etc/init.d" "$dev/data"
: >"$key"

export FAKE_ROOT="$dev" STUB_CALLS="$calls" STUB_PACKAGES="$packages"
export AB_HOST=root@stub AB_KEY="$key" AB_DRY_RUN=0
export FAKE_UCI_DIR="$dev/etc/config"
export AB_BADCFG_OPENCLASH="$dev/etc/config/openclash"
export AB_BADCFG_OPENCLASH_INIT="$dev/etc/init.d/openclash"
export AB_BADCFG_DOCKER_JSON="$dev/etc/docker/daemon.json"
export AB_BADCFG_DOCKER_INIT="$dev/etc/init.d/docker"
export AB_BADCFG_NETWORK="$dev/etc/config/network"
export AB_BADCFG_FIREWALL="$dev/etc/config/firewall"
export AB_BADCFG_MARKER="$dev/data/ab-matrix.marker"
export DEVCFG_STATE_DIR="$tmp/devcfg-state"

cat >"$bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
if [ "${STUB_UNREACHABLE:-0}" = "1" ]; then
    printf 'ssh: connect to host stub port 22: No route to host\n' >&2
    exit 255
fi
last=""
for arg in "$@"; do last=${arg}; done
# A broken restore is the one failure this test must never let slide: the bad file stays on
# the machine, so the driver has to report FAIL and name the backup.
if [ "${STUB_FAIL_WRITE:-0}" = "1" ]; then
    case "${last}" in
        "cat > "*)
            cat >/dev/null
            printf 'sh: write error: No space left on device\n' >&2
            exit 1
            ;;
    esac
fi
if [ "${STUB_FAIL_RESTORE:-0}" = "1" ]; then
    case "${last}" in
        "cp -a "*)
            dest=${last##* }
            case "${dest}" in
                # the backup copy writes *to* a .devcfg-bak- path; only the restore writes from one
                *devcfg-bak-*) : ;;
                *)
                    printf 'cp: cannot stat: No such file or directory\n' >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
fi
exec sh -c "${last}"
STUB

cat >"$bin/ab-slot" <<'STUB'
#!/bin/sh
case "${1:-}" in
    rootfs) cat "${STUB_VERSION:-/dev/null}" ;;
    status) cat "${STUB_STATUS:-/dev/null}" ;;
    *) exit 0 ;;
esac
STUB

# uci: `-q export <name>` only. A file whose quotes do not pair is what libuci refuses, so
# the parse error is replayed by counting the quote on each line -- the same rule, not a
# magic marker the driver could accidentally contain.
cat >"$bin/uci" <<'STUB'
#!/bin/sh
cmd=""
opt=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        export | get | show)
            cmd=$1
            shift
            opt=${1:-}
            [ "$#" -gt 0 ] && shift
            ;;
        *) shift ;;
    esac
done
conf="${FAKE_UCI_DIR:-/etc/config}/${opt}"
[ -f "${conf}" ] || exit 1
if [ "${cmd}" = "export" ]; then
    awk_odd() {
        bad=0
        while IFS= read -r line; do
            n=$(printf '%s' "${line}" | tr -cd "'" | wc -c | tr -d ' ')
            [ $((n % 2)) -eq 0 ] || bad=1
        done
        [ "${bad}" -eq 0 ]
    }
    if ! awk_odd <"${conf}"; then
        printf "uci: Parse error (unterminated quote)\n" >&2
        exit 1
    fi
    cat "${conf}"
    exit 0
fi
exit 1
STUB

# dockerd: `--help` announces --validate; `--validate --config-file` is strict JSON without
# ever starting a daemon -- a file that does not end in `}` never finished being written, and
# an option outside the known set is an unknown field.
cat >"$bin/dockerd" <<'STUB'
#!/bin/sh
case "${1:-}" in
    --help | -h)
        printf 'Usage: dockerd [--validate] [--config-file FILE]\n'
        exit 0
        ;;
esac
conf=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-file) conf=${2:-}; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "${conf}" ] || exit 1
[ -f "${conf}" ] || { printf 'open %s: no such file or directory\n' "${conf}" >&2; exit 1; }
[ "$(tr -d ' \t\n\r' <"${conf}" | tail -c 1)" = "}" ] || {
    printf 'unable to configure the Docker daemon with file %s: unexpected end of JSON input\n' "${conf}" >&2
    exit 1
}
for key in $(grep -o '"[a-z-]*":' "${conf}" | tr -d '":'); do
    case "${key}" in
        log-driver | data-root | storage-driver | live-restore) : ;;
        *)
            printf 'unable to configure the Docker daemon with file %s: json: unknown field "%s"\n' \
                "${conf}" "${key}" >&2
            exit 1
            ;;
    esac
done
printf 'configuration OK\n'
STUB

# docker (the client): the API answering is the witness, `docker volume ls` is the data.
cat >"$bin/docker" <<'STUB'
#!/bin/sh
case "${1:-}" in
    info)
        if [ "${STUB_DOCKER_INFO:-ok}" = "bad" ]; then
            printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n' >&2
            exit 1
        fi
        printf 'Server Version: 27.0.0\n'
        ;;
    volume) printf 'probe-vol\n' ;;
    *) exit 0 ;;
esac
STUB

# apk: the installed set, which is what "the package versions were not moved" compares.
cat >"$bin/apk" <<'STUB'
#!/bin/sh
case "${1:-}" in
    info) cat "${STUB_PACKAGES:-/dev/null}" ;;
esac
STUB

# ubus: system/session answer (the rpcd half), `network reload` answers 0 whatever happened,
# and an interface object exists only while its section does.
cat >"$bin/ubus" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        *) break ;;
    esac
done
[ "${1:-}" = "call" ] || { printf 'session\n'; exit 0; }
obj=${2:-}
case "${obj}" in
    system) printf '{ "board_name": "stub" }\n' ;;
    session) printf '{ "sessions": { } }\n' ;;
    network) printf '' ;;
    network.interface.*)
        name=${obj#network.interface.}
        conf="${FAKE_UCI_DIR:-/etc/config}/network"
        if grep -qF "config interface '${name}'" "${conf}" 2>/dev/null; then
            printf '{ "up": false }\n'
            exit 0
        fi
        printf 'Command failed: Not found\n' >&2
        exit 3
        ;;
    *) exit 0 ;;
esac
STUB

# ip: a device that no interface ever created is not there.
cat >"$bin/ip" <<'STUB'
#!/bin/sh
case "$*" in
    "link show "*)
        printf 'Device "%s" does not exist.\n' "${3:-?}" >&2
        exit 1
        ;;
esac
exit 0
STUB

# fw4: the measured fail-safe. `check` warns and exits 0; `print` renders the ruleset, and
# that is where adopted versus dropped is visible. STUB_FW4_ADOPT=1 replays a tool that
# translated the invalid rule anyway.
cat >"$bin/fw4" <<'STUB'
#!/bin/sh
conf="${AB_BADCFG_FIREWALL:-/etc/config/firewall}"
case "${1:-}" in
    check)
        if grep -q 'not-a-port' "${conf}" 2>/dev/null; then
            [ "${STUB_FW4_QUIET:-0}" = "1" ] || {
                printf "Warning: option 'dest_port' specifies invalid value 'not-a-port'\n" >&2
                printf 'Section @rule[-1] skipped due to invalid options\n' >&2
            }
        fi
        printf 'Ruleset passes nftables check.\n'
        exit 0
        ;;
    print)
        printf 'chain inet fw4 input { type filter hook input priority filter; }\n'
        for name in $(grep -o "name '[^']*'" "${conf}" 2>/dev/null | sed "s/^name '//; s/'$//"); do
            if [ "${STUB_FW4_ADOPT:-0}" = "1" ] || [ "${name}" != "ab-badcfg-rule" ]; then
                printf 'rule name=%s\n' "${name}"
            fi
        done
        exit 0
        ;;
esac
exit 0
STUB

# The app's init script: it starts, unless the replay says the app refused the file.
cat >"$dev/etc/init.d/openclash" <<'STUB'
#!/bin/sh
if [ "${STUB_APPEND_PACKAGE:-0}" = "1" ]; then
    printf 'luci-app-openclash-0.48.002.apk\n' >>"${STUB_PACKAGES:?}"
fi
conf=${AB_BADCFG_OPENCLASH:-/etc/config/openclash}
enable=$(sed -n "s/^[[:space:]]*option enable '\([^']*\)'$/\1/p" "${conf}" 2>/dev/null | head -n 1)
if [ "${STUB_INIT_REFUSE:-0}" = "1" ] && [ "${enable}" = "maybe" ]; then
    printf "openclash: invalid value for enable: ${enable}\n" >&2
    exit 1
fi
printf 'openclash: started\n'
STUB
cat >"$dev/etc/init.d/docker" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$bin"/* "$dev/etc/init.d/openclash" "$dev/etc/init.d/docker"

# uclient-fetch: the DNS failure, the 404 and the control, told apart by the URL.
cat >"$bin/uclient-fetch" <<'STUB'
#!/bin/sh
url=""
for arg in "$@"; do url=${arg}; done
if [ "${STUB_FETCH_ALL_FAIL:-0}" = "1" ]; then
    printf 'uclient-fetch: network unreachable\n' >&2
    exit 1
fi
case "${url}" in
    *nonexistent.invalid*)
        printf 'uclient-fetch: Bad address\n' >&2
        exit 1
        ;;
    *0.0.0-ab-badcfg-404*)
        printf 'uclient-fetch: download failed: HTTP error 404\n' >&2
        exit 1
        ;;
esac
printf 'downloaded\n'
STUB
chmod +x "$bin/uclient-fetch"

# --- the state a run starts from ------------------------------------------- #
# A real-world configuration: Chinese, a blank line, quotes and shell metacharacters. The
# restore has to give this back byte for byte.
openclash_orig() {
    cat >"$dev/etc/config/openclash" <<'CFG'
config openclash 'config'
	option enable '1'

	option name '我的代理 配置'
	option special 'a&b|c$d `e"f'
CFG
}

reset_machine() {
    rm -rf "$dev" "$tmp/devcfg-state"
    mkdir -p "$dev/etc/config" "$dev/etc/docker" "$dev/etc/init.d" "$dev/data"
    openclash_orig
    cat >"$dev/etc/config/network" <<'CFG'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.2.49'
	option netmask '255.255.255.0'
CFG
    cat >"$dev/etc/config/firewall" <<'CFG'
config defaults
	option input 'REJECT'
	option forward 'REJECT'
	option output 'ACCEPT'

config rule
	option name 'Allow-DHCP'
	option src 'wan'
	option proto 'udp'
	option dest_port '68'
	option target 'ACCEPT'
CFG
    printf '{\n  "log-driver": "json-file"\n}\n' >"$dev/etc/docker/daemon.json"
    printf 'created-by-ab-matrix-2026-11-17\n' >"$dev/data/ab-matrix.marker"
    cat >"$dev/etc/init.d/openclash" <<'STUB'
#!/bin/sh
if [ "${STUB_APPEND_PACKAGE:-0}" = "1" ]; then
    printf 'luci-app-openclash-0.48.002.apk\n' >>"${STUB_PACKAGES:?}"
fi
conf=${AB_BADCFG_OPENCLASH:-/etc/config/openclash}
enable=$(sed -n "s/^[[:space:]]*option enable '\([^']*\)'$/\1/p" "${conf}" 2>/dev/null | head -n 1)
if [ "${STUB_INIT_REFUSE:-0}" = "1" ] && [ "${enable}" = "maybe" ]; then
    printf "openclash: invalid value for enable: ${enable}\n" >&2
    exit 1
fi
printf 'openclash: started\n'
STUB
    cat >"$dev/etc/init.d/docker" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dev/etc/init.d/openclash" "$dev/etc/init.d/docker"
    printf '25.12.2\n' >"$version"
    printf '%s\n' \
        'slot=a upper=@overlay-25.12.2 generation=6 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=aligned packages_reason=none' \
        >"$status"
    printf 'htop-3.5.3-r1\nmusl-1.2.5-r1\n' >"$packages"
    : >"$calls"
    rm -f "$results" "$defects"
    cp "$dev/etc/config/openclash" "$tmp/openclash.orig"
    cp "$dev/etc/config/network" "$tmp/network.orig"
}

# run_probe [env assignments...] -- <args...>: the driver against the stub machine. The two
# docker budgets are cut to seconds so no replay waits on a real poll interval.
run_probe() {
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    [ "$#" -gt 0 ] && shift
    env \
        PATH="$bin:$PATH" \
        STUB_CALLS="$calls" STUB_PACKAGES="$packages" \
        STUB_VERSION="$version" STUB_STATUS="$status" \
        AB_DRY_RUN=0 AB_KEY="$key" AB_HOST=root@stub \
        AB_BADCFG_RESULTS="$results" AB_BADCFG_DEFECTS="$defects" \
        AB_BADCFG_DOCKER_TRIES=1 AB_BADCFG_DOCKER_PAUSE=0 \
        AB_BADCFG_EVIDENCE_DIR="$tmp/evidence" \
        "${envs[@]}" \
        sh "$probe" "$@"
}

# row_of <case>: the four columns of one case's row.
row_of() {
    awk -F'\t' -v c="$1" '$1 == c { print $0 }' "$results" 2>/dev/null
}

verdict_of() {
    awk -F'\t' -v c="$1" '$1 == c { print $2 }' "$results" 2>/dev/null
}

note_of() {
    awk -F'\t' -v c="$1" '$1 == c { print $4 }' "$results" 2>/dev/null
}

# The class row a healthy run writes, and the adverse row beside it: two rows per class, so
# "the file was refused" and "the machine is fine" cannot be the same verdict.
assert_two_rows() { # <case> <message>
    assert_eq "$(verdict_of "$1")" "PASS" "ac-5 $2: the class row is PASS"
    assert_eq "$(verdict_of "$1-adverse")" "PASS" "ac-5 $2: the adverse-effects row is PASS"
    assert_eq "$(printf '%s' "$(row_of "$1")" | awk -F'\t' '{ print NF }')" "4" \
        "ac-5 $2: the class row is four TAB separated columns"
    assert_eq "$(printf '%s' "$(row_of "$1-adverse")" | awk -F'\t' '{ print NF }')" "4" \
        "ac-5 $2: the adverse row is four TAB separated columns"
}

# --- the contract every device driver keeps -------------------------------- #
reset_machine
out=$(run_probe -- --help)
assert_eq "$?" "0" "ac-5 --help is not an error"
assert_contains "$out" "C1" "ac-5 the usage names the five classes"

out=$(run_probe -- --case C9 2>&1)
rc=$?
assert_eq "$rc" "2" "ac-5 an unknown case is bad usage"
assert_contains "$out" "unknown case" "ac-5 the refusal says which part was wrong"

rm -f "$results"
out=$(run_probe -- --dry-run)
rc=$?
assert_eq "$rc" "0" "ac-5 --dry-run exits zero"
assert_eq "$(cat "$calls" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "ac-5 --dry-run contacts nothing"
assert_eq "$([ -e "$results" ] && echo written || echo absent)" "absent" \
    "ac-5 --dry-run writes no results file"
assert_eq "$([ -e "$tmp/evidence" ] && echo written || echo absent)" "absent" \
    "ac-5 --dry-run creates no evidence directory"
assert_contains "$out" "dry-run" "ac-5 the plan says it is a dry run"

# --- the red line: a 24.x machine is refused before anything is written ---- #
reset_machine
printf '24.10.5\n' >"$version"
out=$(run_probe -- 2>&1)
rc=$?
assert_eq "$rc" "3" "ac-5 a 24.x machine stops the run on the red line"
assert_contains "$out" "below 25" "ac-5 the refusal names the version line rule"
assert_contains "$out" "24.10.5" "ac-5 the refusal names the version it saw"
assert_eq "$(grep -c 'cat > ' "$calls" 2>/dev/null || true)" "0" \
    "ac-5 nothing was written to a 24.x machine"
assert_eq "$([ -e "$results" ] && echo written || echo absent)" "absent" \
    "ac-5 a stopped run writes no verdict row"
assert_eq "$(cat "$dev/etc/config/openclash")" "$(cat "$tmp/openclash.orig")" \
    "ac-5 the configuration is untouched"

# A machine that never answered is an environment fact, not a broken configuration: GAP and
# exit 4, so nobody reads "no adverse effects" off a run that contacted nothing.
reset_machine
out=$(run_probe STUB_UNREACHABLE=1 -- --case C1 2>&1)
rc=$?
assert_eq "$rc" "4" "ac-5 an unreachable machine is a GAP, not a PASS"
assert_eq "$(verdict_of C1)" "GAP" "ac-5 the row says GAP"
assert_contains "$out" "unreachable" "ac-5 the run says the machine did not answer"
assert_eq "$([ -e "$tmp/evidence/C1.log" ] && echo written || echo absent)" "absent" \
    "ac-5 an unreachable machine is never written to"

# --- C1: a bad openclash configuration ------------------------------------- #
# The parser refuses the unterminated quote; the boolean is accepted because uci has no
# schema, so who refuses it is a measurement -- the app says, and a value nobody refuses is
# reported as `tolerated=` plus a finding instead of being dressed up as a refusal.
reset_machine
out=$(run_probe -- --case C1)
rc=$?
assert_eq "$rc" "0" "ac-5 C1: a refused configuration with a verified restore exits zero"
assert_two_rows C1 "C1 openclash"
assert_contains "$(note_of C1)" "refused_by=uci" \
    "ac-5 C1: the row names the parser as the one who refused the syntax"
assert_contains "$out" "Parse error" "ac-5 C1: the parser's own words are quoted"
assert_contains "$(note_of C1)" "restored=yes" "ac-5 C1: the row says the original came back"
assert_contains "$out" "finding [C1]" \
    "ac-5 C1: the value nobody refused is a named finding, not a refusal"
assert_contains "$(cat "$defects")" "finding" \
    "ac-5 C1: the tolerated value lands in the defect candidates"
assert_eq "$(cat "$dev/etc/config/openclash")" "$(cat "$tmp/openclash.orig")" \
    "ac-5 C1: the configuration file is byte identical after the restore"
assert_contains "$(cat "$dev/etc/config/openclash")" "我的代理 配置" \
    "ac-5 C1: the Chinese value survived the round trip"
assert_eq "$(grep -cE "cp -a '[^']*' '[^']*\.devcfg-bak-" "$calls" || true)" "2" \
    "ac-5 C1: both variants took their backup before writing"
assert_contains "$(note_of C1-adverse)" "packages=ok" \
    "ac-5 C1: the adverse row reports the package set"

# The app refusing the wrong-typed value is the other answer to "who refused it".
reset_machine
out=$(run_probe STUB_INIT_REFUSE=1 -- --case C1)
assert_eq "$?" "0" "ac-5 C1: a refusal by the app is still a healthy run"
assert_contains "$(note_of C1)" "refused_by=init" \
    "ac-5 C1: the row names the app's init script when the app is what refused"
assert_eq "$(grep -c 'finding \[C1\]' <<<"$out" || true)" "0" \
    "ac-5 C1: an app that refuses the value is not reported as a tolerance"

# A restore that fails leaves the bad file on the machine: FAIL, and the backup is named.
reset_machine
out=$(run_probe STUB_FAIL_RESTORE=1 -- --case C1 2>&1)
rc=$?
assert_eq "$rc" "1" "ac-5 C1: a restore that fails is a FAIL, not a silent pass"
assert_eq "$(verdict_of C1)" "FAIL" "ac-5 C1: the class row says FAIL"
assert_contains "$out" "restored_by=none" "ac-5 C1: the failure says nobody restored it"
assert_contains "$out" "devcfg-bak-" "ac-5 C1: the failure names where the backup is kept"
assert_contains "$(cat "$defects")" "assert_restored" \
    "ac-5 C1: the failed restore is a defect candidate"

# An injection that dies halfway must not read as a class that passed: the library puts the
# original back before it reports the failure, and with nothing written there was nothing to
# refuse, so the class is a GAP and the file is the one that was there before.
reset_machine
out=$(run_probe STUB_FAIL_WRITE=1 -- --case C1 2>&1)
rc=$?
assert_eq "$rc" "4" "ac-5 C1: an injection that never landed is a GAP, not a PASS"
assert_eq "$(verdict_of C1)" "GAP" "ac-5 C1: the row says GAP"
assert_eq "$(verdict_of C1-adverse)" "PASS" \
    "ac-5 C1: the machine is still measured even when the class could not be put"
assert_eq "$(cat "$dev/etc/config/openclash")" "$(cat "$tmp/openclash.orig")" \
    "ac-5 C1: a half-done injection leaves the original in place"
assert_contains "$out" "nothing was changed" \
    "ac-5 C1: the GAP says the machine was not touched"

# --- C2: a bad /etc/docker/daemon.json ------------------------------------- #
reset_machine
out=$(run_probe -- --case C2)
rc=$?
assert_eq "$rc" "0" "ac-5 C2: dockerd refusing the file is a healthy run"
assert_two_rows C2 "C2 docker"
assert_contains "$(note_of C2)" "refused_by=dockerd" \
    "ac-5 C2: the row names dockerd as the one who refused"
assert_contains "$out" "unexpected end of JSON input" \
    "ac-5 C2: the truncated file's own error is quoted"
assert_contains "$out" "unknown field" \
    "ac-5 C2: the unknown option is quoted too"
assert_contains "$(note_of C2)" "restored=yes" \
    "ac-5 C2: the daemon configuration came back"
assert_contains "$(note_of C2-adverse)" "volumes=ok" \
    "ac-5 C2: the docker volume set is reported unchanged"

# An image without docker has nothing to break: a named GAP, not a PASS.
reset_machine
rm -f "$dev/etc/docker/daemon.json"
out=$(run_probe -- --case C2 2>&1)
rc=$?
assert_eq "$rc" "4" "ac-5 C2: no daemon.json is a GAP, not a PASS"
assert_eq "$(verdict_of C2)" "GAP" "ac-5 C2: the row says GAP"
assert_contains "$(note_of C2)" "precondition" "ac-5 C2: the GAP names the missing precondition"

# --- C3: a bad UCI section ------------------------------------------------ #
reset_machine
out=$(run_probe -- --case C3)
rc=$?
assert_eq "$rc" "0" "ac-5 C3: netifd refusing the section is a healthy run"
assert_two_rows C3 "C3 network"
assert_contains "$(note_of C3)" "refused_by=netifd" \
    "ac-5 C3: the row names netifd as the one who refused"
assert_contains "$out" "does not exist" \
    "ac-5 C3: the missing device is quoted from the machine"
assert_contains "$(note_of C3)" "restored=yes" "ac-5 C3: the network config came back"
assert_contains "$out" "gone after the restore" \
    "ac-5 C3: the bogus interface is asserted gone after the restore"
assert_eq "$(cat "$dev/etc/config/network")" "$(cat "$tmp/network.orig")" \
    "ac-5 C3: the network configuration is byte identical after the restore"
assert_eq "$(grep -c "config interface 'ab_badcfg_probe" "$dev/etc/config/network" || true)" "0" \
    "ac-5 C3: no probe section is left in the live configuration"

# --- C4: a bad firewall rule ---------------------------------------------- #
# fw4 warns, skips and exits 0. The class passes only because the rendered ruleset does not
# carry the rule; the exit status is recorded as the fact it is.
reset_machine
out=$(run_probe -- --case C4)
rc=$?
assert_eq "$rc" "0" "ac-5 C4: a rule fw4 skipped is a healthy run"
assert_two_rows C4 "C4 firewall"
assert_contains "$(note_of C4)" "refused_by=fw4" \
    "ac-5 C4: the row names fw4 as the one who refused"
assert_contains "$(note_of C4)" "warning=yes" \
    "ac-5 C4: the warning that explains the skip is recorded"
assert_contains "$(note_of C4)" "adopted=no" \
    "ac-5 C4: the row says the rule was not adopted"
assert_contains "$out" "skipped due to invalid options" \
    "ac-5 C4: the tool's own warning is quoted"

# The same replay, but the tool translated the rule anyway: that is fail-open and a FAIL.
reset_machine
out=$(run_probe STUB_FW4_ADOPT=1 -- --case C4 2>&1)
rc=$?
assert_eq "$rc" "1" "ac-5 C4: a rendered ruleset that carries the rule is a FAIL"
assert_eq "$(verdict_of C4)" "FAIL" "ac-5 C4: the class row says FAIL"
assert_contains "$out" "adopted=yes" "ac-5 C4: the failure says the rule was adopted"
assert_contains "$(cat "$defects")" "assert_not_adopted" \
    "ac-5 C4: the adopted rule is a defect candidate"

# --- C5: a fake subscription source --------------------------------------- #
reset_machine
out=$(run_probe -- --case C5)
rc=$?
assert_eq "$rc" "0" "ac-5 C5: a fake source that is refused is a healthy run"
assert_two_rows C5 "C5 fake source"
assert_contains "$(note_of C5)" "refused_by=dns" \
    "ac-5 C5: the row names the resolver for the domain that does not exist"
assert_contains "$(note_of C5)" "refused_by=http-404" \
    "ac-5 C5: the row names the 404 for the URL that answers it"
assert_contains "$out" "control=fetch-ok" \
    "ac-5 C5: the known-good fetch is the control that makes the refusal mean something"
assert_contains "$(note_of C5)" "restored=yes" \
    "ac-5 C5: the fake source was taken back out of the app's configuration"

# Both fetches failing means the machine cannot reach anything from here: a GAP, never a PASS.
reset_machine
out=$(run_probe STUB_FETCH_ALL_FAIL=1 -- --case C5 2>&1)
rc=$?
assert_eq "$rc" "4" "ac-5 C5: no working control fetch is a GAP"
assert_eq "$(verdict_of C5)" "GAP" "ac-5 C5: the row says GAP"
assert_contains "$(note_of C5)" "control" \
    "ac-5 C5: the GAP says which fact was missing"

# --- the adverse effects have their own verdict --------------------------- #
# The class itself is fine here; what is damaged is the machine. That must be a FAIL on the
# adverse row, with the class row left as it was found.
reset_machine
out=$(run_probe STUB_APPEND_PACKAGE=1 -- --case C1 2>&1)
rc=$?
assert_eq "$rc" "1" "ac-5 an adverse effect is a FAIL even when the class was refused"
assert_eq "$(verdict_of C1)" "PASS" "ac-5 the class row still reports the refusal"
assert_eq "$(verdict_of C1-adverse)" "FAIL" "ac-5 the adverse row is the FAIL"
assert_contains "$(note_of C1-adverse)" "packages=fail" \
    "ac-5 the adverse row names the package set as what moved"
assert_contains "$out" "apk info -v" \
    "ac-5 the failure says which command answers the question"
assert_contains "$(cat "$defects")" "packages" \
    "ac-5 an adverse effect is a defect candidate"

reset_machine
printf '%s\n' 'slot=a upper=@overlay-25.12.2 generation=6 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=fail esp=ok packages=aligned packages_reason=none' >"$status"
out=$(run_probe -- --case C4 2>&1)
assert_eq "$?" "1" "ac-5 a machine whose next boot is not ok is a FAIL, not a pass"
assert_eq "$(verdict_of C4-adverse)" "FAIL" "ac-5 ab-slot status degraded past boot=ok fails the row"
assert_contains "$out" "boot=fail" "ac-5 the failure quotes the field that moved"

# --- every class in one run ----------------------------------------------- #
reset_machine
out=$(run_probe --)
rc=$?
assert_eq "$rc" "0" "ac-5 all five classes on one healthy machine exit zero"
assert_eq "$(wc -l <"$results" | tr -d ' ')" "10" \
    "ac-5 five classes and their five adverse rows"
assert_eq "$(awk -F'\t' '$2 !~ /^(PASS|FAIL|GAP)$/ { print $1 }' "$results" | wc -l | tr -d ' ')" "0" \
    "ac-5 every verdict is one of PASS, FAIL, GAP"
assert_eq "$(cut -f3 "$results" | sort -u | wc -l | tr -d ' ')" "5" \
    "ac-5 every class has its own evidence log, named by its own rows"
for ev_path in $(cut -f3 "$results" | sort -u); do
    assert_file_exists "$ev_path" "ac-5 the evidence path in a row exists: $(basename "$ev_path")"
done
assert_eq "$(awk -F'\t' '$3 == "-" { print $1 }' "$results" | wc -l | tr -d ' ')" "0" \
    "ac-5 no row leaves the evidence column empty"
assert_contains "$out" "badconfig-probe cases=5" "ac-5 the summary counts the classes"
assert_contains "$(cat "$calls")" "ab-slot rootfs" \
    "ac-5 the version line is read before anything is written"

finish
