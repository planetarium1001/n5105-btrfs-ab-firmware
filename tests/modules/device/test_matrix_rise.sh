#!/usr/bin/env bash
# Module: device
# The rise chain driver (scripts/device/matrix-rise.sh): ac-8 against a machine that is a
# directory.
#
# What is under test is the claim ac-8 makes: a machine climbs 25.12.0 -> 25.12.1 ->
# 25.12.2 with the community sample set installed BEFORE the climb, and every hop ends in
# a committed slot whose samples are still usable and whose /etc/config and /data markers
# are byte-identical. Four things are judged per hop, and each has a negative case here,
# because a group that cannot go red is not being judged:
#
#   the six fields   committed=<the other slot>, boot=ok, esp=ok, pending=none,
#                    packages=aligned, generation >= before+1
#   the base         rootfs=<the base the payload carries>, direction=up (computed),
#                    upper=@overlay-<base>(-rN)?
#   the user state   the /data marker and the uci value did not move
#   the samples      follow-probe.sh --verify says usable, config and data unchanged
#
# The stub `ssh` below is the machine: it keeps slot state in files, answers
# `ab-slot status`, arms a payload on `ab-upgrade --yes` and commits it on `sync; reboot`.
# It also runs the feed block writer this driver sends over stdin (`sh -s -- ...`), which
# is how the test reads back the URLs that were pointed at without a device.
#
# The two sample drivers and feed-history.sh are stubs in the interface they publish (one
# program each, called with the flags this driver passes), and the assertions below are on
# the *arguments* this driver hands them: whether follow-probe.sh judges a sample by the
# right criterion is its own contract test's question, not this file's.
#
#   ac-8 a full chain 25.12.0 -> 25.12.1 -> 25.12.2 passes, one row per hop, in order
#   plus the negative cases: a hop that booted degraded, a payload that is not there (GAP),
#        a feed this release does not have (FAIL), a feed nobody could measure (GAP), a
#        sample that stopped being usable (FAIL), a missing baseline (GAP), a red-line
#        machine, --from-version, --only, --resume, and a --dry-run that touches nothing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

driver="$root/scripts/device/matrix-rise.sh"
assert_file_exists "$driver" "ac-8 the rise chain driver exists"
out=$(sh -n "$driver" 2>&1)
assert_eq "$?" "0" "ac-8 the driver parses under sh, the shell the drivers run with: $out"
assert_matches "$(cat "$driver")" "tests/lib/device_config\.sh" \
    "ac-8 the driver reuses the shared config verifier instead of its own comparison"
assert_matches "$(cat "$driver")" "platform/lib/ab-version\.sh" \
    "ac-8 the driver computes the direction of a hop from the versions, not from a name"
# The STABLE/IDENTITY groups belong to lib.sh, and the samples to follow-probe.sh: a second
# definition of either here is how two drivers start judging the same hop differently.
assert_eq "$(grep -c '^AB_STATUS_FIELDS_STABLE=' "$driver" || true)" "0" \
    "ac-8 the driver does not redefine lib.sh's STABLE group"
assert_eq "$(grep -c 'software-samples.json' "$driver" || true)" "0" \
    "ac-8 the driver keeps no sample list of its own"
assert_eq "$(grep -c 'follow-samples.json' "$driver" || true)" "0" \
    "ac-8 the sample set stays follow-probe.sh's business"
# The one file the aligner never rewrites: a rise chain that wrote its historical feed
# anywhere else would have it rewritten on the next hop.
assert_matches "$(cat "$driver")" "customfeeds\.list" \
    "ac-8 the release-specific feed goes to customfeeds.list, the file the aligner leaves alone"

# --- the machine ------------------------------------------------------------- #
bin="$tmp/bin"
calls="$tmp/calls.log"
state="$tmp/state"
fake="$tmp/device"
payloads="$tmp/payloads"
customfeeds="$tmp/device/etc/apk/repositories.d/customfeeds.list"
mkdir -p "$bin" "$state" "$payloads" "$fake/etc/config" "$(dirname "$customfeeds")"
: >"$tmp/key"
# Placeholders, not archives: one byte that is not a tar header reads as "not a tar" on both
# GNU tar and bsdtar, so lib.sh's shape check (which only speaks for a real tar) stays out.
for p in payload-25.12.1.tar payload-25.12.2.tar; do
    printf 'placeholder, not a tar\n' >"$payloads/$p"
done

# The three programs this driver calls, as stubs in their published interface. Each one
# logs the arguments it was given, which is what the assertions below read.
cat >"$tmp/tools-follow-probe.sh" <<'PROBE'
#!/bin/sh
# follow-probe.sh, as far as matrix-rise.sh can tell: --verify reads --state and prints the
# rows and the summary line. STUB_FOLLOW_RC decides the verdict (0 pass, 4 gap, 1 fail).
action=""
state=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verify | --mark | --install | --unmark) action=${1#--}; shift ;;
        --state) state=${2:-}; shift 2 ;;
        --sample) shift 2 ;;
        *) shift ;;
    esac
done
printf 'probe action=%s state=%s\n' "${action}" "${state}" >>"${STUB_TOOL_LOG:?}"
rc=${STUB_FOLLOW_RC:-0}
[ "${action}" = "verify" ] || rc=0
case "${rc}" in
    0)
        printf 'probe=htop status=pass ac-2 usable=yes version=3.5.3 config=unchanged data=unchanged\n'
        printf 'follow-probe summary action=%s rows=1 pass=1 fail=0 gap=0 skip=0\n' "${action}"
        ;;
    4)
        printf 'probe=istore status=gap ac=3 reason=install-gap rerun="sh scripts/device/follow-probe.sh --install --sample istore"\n'
        printf 'follow-probe summary action=%s rows=1 pass=0 fail=0 gap=1 skip=0\n' "${action}"
        ;;
    3)
        printf 'probe=htop status=skip ac=2 reason=no-machine\n'
        printf 'follow-probe summary action=%s rows=1 pass=0 fail=0 gap=0 skip=1\n' "${action}"
        ;;
    baseline)
        # The machine already could not use this sample when the baseline was taken, so this
        # hop did not break it. follow-probe.sh says so with reason=baseline-unusable.
        printf 'probe=ttyd status=fail ac=2 reason=baseline-unusable expect="^bin=yes" check="bin=no" baseline_check="bin=no"\n'
        printf 'follow-probe summary action=%s rows=1 pass=0 fail=1 gap=0 skip=0\n' "${action}"
        exit 1
        ;;
    *)
        printf 'probe=htop status=fail ac=2 reason=unusable expect="^3[.]" check="htop: not found"\n'
        printf 'follow-probe summary action=%s rows=1 pass=0 fail=1 gap=0 skip=0\n' "${action}"
        ;;
esac
exit "${rc}"
PROBE

cat >"$tmp/tools-follow-baseline.sh" <<'BASELINE'
#!/bin/sh
# follow-baseline.sh, as far as matrix-rise.sh can tell: --state is the file it writes.
state=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --state) state=${2:-}; shift 2 ;;
        --results) shift 2 ;;
        *) shift ;;
    esac
done
printf 'baseline state=%s\n' "${state}" >>"${STUB_TOOL_LOG:?}"
[ -n "${state}" ] || exit 2
printf '# follow-probe state schema=1\nhtop\tpass\t3.5.3\t/etc/config/htop\tabc\t/data/ab-follow/htop.marker\tdef\tmarked\n' >"${state}"
printf 'follow-baseline: installed=1 gap=0 state=%s\n' "${state}"
exit "${STUB_BASELINE_RC:-0}"
BASELINE

cat >"$tmp/tools-feed-history.sh" <<'FEEDHISTORY'
#!/bin/sh
# feed-history.sh, as far as matrix-rise.sh can tell: the release asked for, the three
# verdict lines it publishes, and the block between the two markers.
release=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) release=${2:-}; shift 2 ;;
        *) shift ;;
    esac
done
printf 'feed-history release=%s\n' "${release}" >>"${STUB_TOOL_LOG:?}"
case "${STUB_FEED_RC:-0}" in
    1)
        printf 'feed-history release=%s mirror=https://downloads.immortalwrt.org target=x86/64 arch=x86_64\n' "${release}"
        printf 'feed-history verdict=FAIL release=%s kernel=? kmod=unknown feeds=0/7\n' "${release}"
        exit 1
        ;;
    4)
        printf 'feed-history release=%s mirror=https://downloads.immortalwrt.org target=x86/64 arch=x86_64\n' "${release}"
        printf 'feed-history verdict=GAP release=%s kernel=? kmod=unknown feeds=0/7 reason=no-network\n' "${release}"
        exit 4
        ;;
esac
printf 'feed-history release=%s mirror=https://downloads.immortalwrt.org target=x86/64 arch=x86_64\n' "${release}"
printf 'feed-history feed=base http=200 index=ok url=https://downloads.immortalwrt.org/releases/%s/packages/x86_64/base/packages.adb\n' "${release}"
printf 'feed-history feed=kmods http=200 index=ok url=https://downloads.immortalwrt.org/releases/%s/targets/x86/64/kmods/6.12.87-1-bd81971a/packages.adb\n' "${release}"
printf 'feed-history kmods-segment=6.12.87-1-bd81971a source=listing\n'
printf 'feed-history verdict=PASS release=%s kernel=6.12.87 kmod=6.12.87-1-bd81971a feeds=2/2\n' "${release}"
printf 'feed-history repositories begin\n'
printf 'https://downloads.immortalwrt.org/releases/%s/packages/x86_64/base/packages.adb\n' "${release}"
printf 'https://downloads.immortalwrt.org/releases/%s/targets/x86/64/kmods/6.12.87-1-bd81971a/packages.adb\n' "${release}"
printf 'feed-history repositories end\n'
exit 0
FEEDHISTORY

cat >"$bin/ssh" <<'STUB'
#!/bin/sh
# The machine. dev_ssh hands the whole remote command over as one argument, so the last
# argument is what the machine would run - including the `sh -s -- ...` form the feed block
# writer arrives in, whose program comes over stdin instead.
#
# POSIX sh on purpose: it runs as `sh`, which is bash on the laptop this suite is written
# on and dash on the CI runner, and a bashism in here would fail only on the runner
# (measured 2026-11-19 on the stub of test_matrix_round2.sh).
cmd=""
for a in "$@"; do cmd=$a; done
printf '%s\n' "$cmd" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
state=${STUB_STATE:?stub needs STUB_STATE}
root=${STUB_ROOT:?stub needs STUB_ROOT}
get() { cat "$state/$1" 2>/dev/null || printf '%s' "${2-}"; }
put() { printf '%s\n' "$2" >"$state/$1"; }
bump() { put "$1" "$(( $(get "$1" 0) + 1 ))"; }
hops() { get hops 0; }

payload_rootfs() {
    case "$1" in
        *25.12.1.tar) printf '25.12.1\n' ;;
        *25.12.2.tar) printf '25.12.2\n' ;;
        *) printf '?\n' ;;
    esac
}

# The two knobs a broken machine is replayed with: a boot that stops reporting healthy
# after a given hop, and a machine with no committed slot.
boot_value() {
    if [ -n "${STUB_BOOT_DEGRADED_AFTER_HOP:-}" ] && [ "$(hops)" -gt "${STUB_BOOT_DEGRADED_AFTER_HOP}" ]; then
        printf 'degraded\n'
    else
        printf '%s\n' "$(get boot ok)"
    fi
}

status_line() {
    printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=%s esp=%s packages=%s packages_reason=none\n' \
        "$(get slot a)" "$(get upper @overlay-25.12.0)" "$(get generation 1)" \
        "$(get committed a)" "$(get pending none)" "$(get committed a)" \
        "$(boot_value)" "$(get esp ok)" "$(get packages aligned)"
}

install_payload() {
    new=$(payload_rootfs "$1")
    [ "${new}" = "?" ] && exit 1
    put generation "$(( $(get generation 1) + 1 ))"
    put next_rootfs "${new}"
    if [ "$(get slot a)" = "a" ]; then put pending b; else put pending a; fi
    bump hops
    printf 'ab-upgrade: installed %s into slot %s\n' "${new}" "$(get pending a)"
}

# Device paths, answered out of the fake root: the markers and the config files the driver
# snapshots live under it, so a run cannot touch the host.
device_file() {
    p=$1
    case "${p}" in
        /data/* | /etc/config/*) printf '%s%s\n' "${root}" "${p}" ;;
        *) printf '%s\n' '' ;;
    esac
}

case "${cmd}" in
    'ab-slot status')
        if [ "${STUB_NO_COMMITTED:-0}" = "1" ]; then
            printf 'slot=a upper=@overlay-25.12.0 generation=1 committed=- pending=none boot=ok esp=ok\n'
            exit 0
        fi
        status_line
        ;;
    'ab-slot rootfs') printf '%s\n' "$(get rootfs 25.12.0)" ;;
    'true' | 'ab-slot gc') exit 0 ;;
    'cat > '* | "cat > "*) cat >/dev/null ;;
    'ab-upgrade --check '*)
        payload=${cmd##* }
        if [ "$(payload_rootfs "${payload}")" = "?" ]; then
            printf 'ab-upgrade: refused, reason=payload-version-unknown\n'
            exit 74
        fi
        exit 0
        ;;
    'ab-upgrade --yes '*)
        install_payload "${cmd##* }"
        ;;
    'sync; reboot')
        target=$(get pending "$(get slot a)")
        put slot "${target}"
        put committed "${target}"
        put pending none
        new=$(get next_rootfs "$(get rootfs)")
        put rootfs "${new}"
        bump "layer-${new}"
        if [ "$(get "layer-${new}" 1)" -eq 1 ]; then
            put upper "@overlay-${new}"
        else
            put upper "@overlay-${new}-r$(get "layer-${new}")"
        fi
        ;;
    'sh -s -- '*)
        # The feed block writer: the program arrives on stdin, the arguments on the command
        # line, exactly as ssh would hand both to the machine's shell.
        sh -c "${cmd}"
        ;;
    'apk update') exit "${STUB_APK_UPDATE_RC:-0}" ;;
    'uci get system.@system[0].hostname') cat "$root/etc/config/hostname" 2>/dev/null || printf 'ImmortalWrt\n' ;;
    'for d in /mnt/slots/'*) exit 0 ;;
    'printf'*'/data/ab-matrix.marker')
        mkdir -p "$root/data" 2>/dev/null
        shift_marker=$(printf '%s' "${cmd}" | sed "s#.*> ##")
        printf '%s\n' "created-by-ab-matrix-test" >"$root${shift_marker}"
        ;;
    'cat '*)
        p=$(printf '%s' "${cmd#cat }" | tr -d "'")
        f=${root}${p}
        [ -f "${f}" ] || exit 1
        cat "${f}"
        ;;
    *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$bin/ssh" "$tmp"/tools-*.sh

results="$tmp/results.tsv"
evidence="$tmp/evidence"
follow_state="$tmp/follow-state.tsv"
tool_log="$tmp/tools.log"

reset_machine() { # [<running rootfs>]
    rm -rf "$state" "$evidence" "$follow_state" "$customfeeds"
    mkdir -p "$state" "$fake/etc/config" "$(dirname "$customfeeds")"
    printf '%s\n' "${1:-25.12.0}" >"$state/rootfs"
    printf 'a\n' >"$state/slot"
    printf 'a\n' >"$state/committed"
    printf 'none\n' >"$state/pending"
    printf '1\n' >"$state/generation"
    printf 'ok\n' >"$state/boot"
    printf 'ok\n' >"$state/esp"
    printf 'aligned\n' >"$state/packages"
    printf '1\n' >"$state/layer-${1:-25.12.0}"
    printf '@overlay-%s\n' "${1:-25.12.0}" >"$state/upper"
    printf '0\n' >"$state/hops"
    printf "config system 'system'\n" >"$fake/etc/config/system"
    printf "config dockerd 'dockerd'\n" >"$fake/etc/config/dockerd"
    printf 'ImmortalWrt\n' >"$fake/etc/config/hostname"
    # The /data marker the hop has to carry across. Written once and read after every hop:
    # dev_marker_init would create it, but a marker this run created moments before the
    # assertion proves nothing about the hop.
    mkdir -p "$fake/data"
    printf 'created-by-an-earlier-run\n' >"$fake/data/ab-matrix.marker"
    # The feed list the operator owns: the block this driver writes is added beside it and
    # must be removed again without touching these lines.
    printf 'https://example.invalid/operator-own.list\n' >"$customfeeds"
    : >"$calls"
    : >"$tool_log"
    rm -f "$results"
}

# drv [args...]: the driver against the stub machine, budgets cut to seconds.
drv() {
    PATH="$bin:$PATH" STUB_CALLS="$calls" STUB_STATE="$state" STUB_ROOT="$fake" \
        STUB_TOOL_LOG="$tool_log" AB_KEY="$tmp/key" AB_HOST=root@stub \
        AB_RESULTS="${RESULTS:-$results}" AB_POLL_INTERVAL=1 AB_WAIT_UP=1 \
        AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
        AB_FOLLOW_STATE="${FOLLOW_STATE:-$follow_state}" \
        AB_FOLLOW_PROBE="$tmp/tools-follow-probe.sh" \
        AB_FOLLOW_BASELINE="$tmp/tools-follow-baseline.sh" \
        AB_FEED_HISTORY="$tmp/tools-feed-history.sh" \
        AB_RISE_CUSTOMFEEDS="$customfeeds" \
        AB_RISE_CONFIG_PATHS="/etc/config/system /etc/config/dockerd" \
        sh "$driver" "$@" 2>&1
}

rows() { cut -f1 "$results" 2>/dev/null | tr '\n' ' '; }
verdicts() { cut -f2 "$results" 2>/dev/null | tr '\n' ' '; }
note_of() { awk -F'\t' -v c="$1" '$1 == c { print $4 }' "$results" 2>/dev/null; }
installs() { grep -oE 'ab-upgrade( --yes)? /tmp/payload-[^ ]+\.tar' "$calls" 2>/dev/null | sed 's#.*/##' | tr '\n' ' '; }

# --- the plan, and it touches nothing ---------------------------------------- #
# A dry run is read by an operator standing in front of one machine; it has to say what
# each hop expects, and it may not open a socket to find out.
reset_machine
out=$(drv --dry-run)
rc=$?
assert_eq "$rc" "0" "ac-8 --dry-run exits zero"
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (R1|R2) ' | awk '{print $2}' | tr '\n' ' ')" \
    "R1 R2 " "ac-8 the chain is planned in one order, climbing"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" "ac-8 --dry-run sends no ssh, not one"
assert_eq "$(wc -l <"$tool_log" | tr -d ' ')" "0" \
    "ac-8 --dry-run runs neither the sample drivers nor the feed probe"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-8 --dry-run writes no result row"
assert_eq "$([ -d "$evidence" ] && echo created || echo absent)" "absent" \
    "ac-8 --dry-run creates no result directory"

r1_line=$(printf '%s\n' "$out" | grep '^# R1 ')
r2_line=$(printf '%s\n' "$out" | grep '^# R2 ')
assert_contains "$r1_line" "kind=base" "ac-8 every hop of this chain carries a base"
assert_contains "$r1_line" "from-rootfs=25.12.0 to-rootfs=25.12.1" \
    "ac-8 the first hop names the base it starts from and the one it installs"
assert_contains "$r1_line" "direction=up" "ac-8 the hop says which way it goes"
assert_contains "$r1_line" "rollback=older" \
    "ac-8 after a rise the slot left behind is the older base"
assert_contains "$r1_line" "samples=install-if-absent" \
    "ac-8 the plan says the samples are installed only when no baseline is there"
assert_contains "$r2_line" "to-rootfs=25.12.2" "ac-8 the chain ends on 25.12.2"
out=$(drv --dry-run --feed off)
assert_contains "$out" "feed off (requested)" "ac-8 --feed off is stated in the plan it produces"
assert_contains "$out" "feed=off" "ac-8 and in every hop's expectation"

# --from-version cuts the hops the machine is already past, and says which start it used.
out=$(drv --dry-run --from-version 25.12.1)
assert_eq "$?" "0" "ac-8 --from-version 25.12.1 is a start the chain can be walked from"
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (R1|R2) ' | awk '{print $2}' | tr '\n' ' ')" \
    "R2 " "ac-8 --from-version 25.12.1 plans only the hops still ahead of the machine"
assert_contains "$(printf '%s\n' "$out" | sed -n '1p')" "from-version=25.12.1" \
    "ac-8 the run states the start version it was given"
out=$(drv --dry-run --from 2)
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (R1|R2) ' | awk '{print $2}' | tr '\n' ' ')" \
    "R2 " "ac-8 --from <step> plans only that step and what follows"
out=$(drv --dry-run --only R1)
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (R1|R2) ' | awk '{print $2}' | tr '\n' ' ')" \
    "R1 " "ac-8 --only plans a single hop"

# --- ac-8: the whole chain --------------------------------------------------- #
reset_machine
out=$(drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-8 the chain on a healthy machine exits zero"
assert_eq "$(rows)" "R1 R2 " "ac-8 one row per hop, in chain order"
assert_eq "$(verdicts)" "PASS PASS " "ac-8 every hop passes"
assert_eq "$(installs)" "payload-25.12.1.tar payload-25.12.2.tar " \
    "ac-8 each hop installs its own payload, one base at a time"
assert_eq "$(grep -c 'ab-upgrade --check' "$calls" || true)" "2" \
    "ac-8 every hop is validated before it is written"
assert_eq "$(grep -cE 'ab-upgrade( --yes)? --force' "$calls" || true)" "0" \
    "ac-8 no hop of this chain is same-base, so --force is never spent"

# The samples are installed and marked ONCE, before the first hop, and never re-marked:
# re-running the baseline after a hop would record the post-hop config as the truth.
assert_eq "$(grep -c '^baseline ' "$tool_log" || true)" "1" \
    "ac-8 the sample baseline is recorded once for the whole chain"
assert_eq "$(grep -c '^probe action=verify' "$tool_log" || true)" "2" \
    "ac-8 the samples are judged after every hop"
assert_contains "$(grep '^probe action=verify' "$tool_log" | sed -n '1p')" "state=$follow_state" \
    "ac-8 the sample judgement reads the baseline the install recorded"
assert_contains "$(note_of R1)" "samples=pass" "ac-8 the first row carries the sample verdict"
assert_contains "$(note_of R1)" "start=25.12.0" \
    "ac-8 the first row records the start version the run actually used"
assert_contains "$(note_of R1)" "base 25.12.0->25.12.1 (up)" \
    "ac-8 the row names the base it climbed and the direction it took"
assert_contains "$(note_of R1)" "packages=aligned" "ac-8 packages are aligned after every hop"
assert_contains "$(note_of R1)" "config-drift=none" \
    "ac-8 the config drift the hop measured is stated, not assumed"
assert_contains "$(note_of R2)" "base 25.12.1->25.12.2 (up)" \
    "ac-8 the second hop climbs the second base"
assert_contains "$(note_of R2)" "generation 2->3" \
    "ac-8 the row carries the generation it moved, not just that it moved"

# The historical feed: each hop asks for the feed of the release it starts from and of the
# release it lands on, and the block it writes names that release in customfeeds.list - the
# one file the aligner never rewrites.
assert_contains "$(grep '^feed-history release=' "$tool_log" | sed 's/^feed-history release=//' | tr '\n' ' ')" \
    "25.12.0 25.12.1 25.12.2 " \
    "ac-8 every release the chain installs from and lands on is probed for its own feed"
assert_contains "$(note_of R1)" "feed=upstream" "ac-8 the row names where the feed came from"
assert_contains "$(note_of R1)" "kmods=6.12.87-1-bd81971a" \
    "ac-8 the row carries the kernel segment the release's index names"
assert_contains "$(note_of R1)" "index=2/2" "ac-8 the row carries how many indexes were judged"
# The block is gone again: a custom feed naming a release the machine no longer runs is a
# second source for packages of that release, and the file the operator owns is untouched.
assert_eq "$(cat "$customfeeds")" "https://example.invalid/operator-own.list" \
    "ac-8 the feed block is removed at the end of the run and the operator's own list stays"
assert_eq "$(grep -c 'sh -s -- ' "$calls" || true)" "4" \
    "ac-8 the block is written once per release and removed once at the end"

# --- ac-8: a hop that does not end healthy stops the chain ------------------- #
# The same chain with a machine whose first boot after the first hop comes up degraded: the
# hop is red on boot=, the row says which field, and the hop after it is never walked.
reset_machine
out=$(STUB_BOOT_DEGRADED_AFTER_HOP=0 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-8 a hop that booted degraded makes the run fail"
assert_eq "$(rows)" "R1 " "ac-8 the chain stops on the failed hop"
assert_eq "$(verdicts)" "FAIL " "ac-8 the hop that was red is the FAIL row"
assert_contains "$(note_of R1)" "boot" "ac-8 the row names the field that was red"
assert_eq "$(grep -c 'payload-25.12.2.tar' "$calls" || true)" "0" \
    "ac-8 the hop after the failure was never pushed to the machine"

# A sample that stopped being usable is a FAIL of the hop, and the row says so. It is not
# silently a gap: the A/B machinery committed, the package did not survive it.
reset_machine
out=$(STUB_FOLLOW_RC=1 drv --payload-dir "$payloads")
assert_eq "$?" "1" "ac-8 a sample that is no longer usable fails the hop"
assert_eq "$(verdicts)" "FAIL " "ac-8 and stops the chain there"
assert_contains "$(note_of R1)" "did not survive" "ac-8 the row says the samples did not survive"

# A sample that was ALREADY unusable when the baseline was taken is not a regression of this
# hop. The first full round lost six cases to a criterion that named a binary path the machine
# never had: the sample could never pass, so every hop that asked about it looked broken. The
# hop is not green - the sample is still unusable - but the record has to say "unusable before
# this hop" rather than "this hop broke it".
reset_machine
out=$(STUB_FOLLOW_RC=baseline drv --payload-dir "$payloads")
assert_eq "$?" "0" "ac-8 a sample unusable before the hop does not fail it"
assert_contains "$(note_of R1)" "samples=gap" "ac-8 and the row records a gap, not a pass"
assert_contains "$(note_of R1)" "not a regression" "ac-8 the row says the sample was already unusable"

# A machine that does not answer is a gap too: "we did not ask" and "the answer is bad" must
# not look the same in the record.
reset_machine
out=$(STUB_FOLLOW_RC=3 drv --payload-dir "$payloads")
assert_eq "$?" "0" "ac-8 a machine that did not answer does not fail the hop"
assert_contains "$(note_of R1)" "did not answer" "ac-8 the row says the machine did not answer"

# A sample the feed does not offer is a GAP and not a failure: it is a finding about the
# feed, and PRD risk 3 says it may never be reported as a red hop.
reset_machine
out=$(STUB_FOLLOW_RC=4 drv --payload-dir "$payloads")
assert_eq "$?" "0" "ac-8 a sample the feed does not offer does not fail a committed hop"
assert_contains "$(note_of R1)" "samples=gap" "ac-8 the row records the gap"
assert_contains "$(note_of R1)" "gap=1" "ac-8 and how many samples it covers"

# --- ac-8 with a baseline already there -------------------------------------- #
# full-test.sh's `follow` phase exports AB_FOLLOW_STATE, so the chain usually starts with a
# baseline it did not write. Re-marking it would re-baseline exactly what the hop measures.
reset_machine
printf '# follow-probe state schema=1\nhtop\tpass\t3.5.3\t/etc/config/htop\tabc\t/data/ab-follow/htop.marker\tdef\tmarked\n' >"$follow_state"
out=$(drv --payload-dir "$payloads")
assert_eq "$?" "0" "ac-8 a chain started from an existing baseline passes"
assert_eq "$(grep -c '^baseline ' "$tool_log" || true)" "0" \
    "ac-8 an existing baseline is not recorded again"
assert_eq "$(grep -c '^probe action=verify' "$tool_log" || true)" "2" \
    "ac-8 and it is the baseline every hop is judged against"
assert_contains "$(cat "$evidence/rise/R1.log" 2>/dev/null)" "baseline-existing" \
    "ac-8 the evidence says the baseline was found, not created"

# --- ac-8: the feed leg, three ways it can go wrong -------------------------- #
# A release whose feed the probe measured as absent is a FAIL of that hop: the machine
# landed, but ac-9's fact for it is answered, and the answer is no.
reset_machine
out=$(STUB_FEED_RC=1 drv --payload-dir "$payloads")
assert_eq "$?" "1" "ac-8 a release with no usable feed fails before the machine is touched"
assert_eq "$(verdicts)" "FAIL " "ac-8 the refusal is a FAIL row"
assert_contains "$(note_of R1)" "no usable feed" "ac-8 the row says the feed was measured absent"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" \
    "ac-8 a feed that is known to be missing is not discovered after a reboot"

# A feed nobody could measure is a GAP: the mirror was unreachable, which says nothing
# about the release or about this machine.
reset_machine
out=$(STUB_FEED_RC=4 drv --payload-dir "$payloads")
assert_eq "$?" "4" "ac-8 a feed that could not be measured is a gap"
assert_eq "$(verdicts)" "GAP " "ac-8 the row is GAP, never PASS"
assert_contains "$(note_of R1)" "could not answer" "ac-8 the row says why it was not measured"

# --feed off walks the chain without the leg, and every row says the leg was off, so a run
# that skipped it cannot be read as one that measured it.
reset_machine
out=$(drv --payload-dir "$payloads" --feed off)
assert_eq "$?" "0" "ac-8 --feed off walks the chain"
assert_eq "$(grep -c '^feed-history' "$tool_log" || true)" "0" \
    "ac-8 --feed off does not probe a release's feed"
assert_contains "$(note_of R1)" "feed=off" "ac-8 the row records that the feed leg was off"
assert_eq "$(grep -c 'customfeeds' "$calls" || true)" "0" \
    "ac-8 --feed off writes nothing into the machine's feed list"

# --- ac-8: --from-version, --only and --resume ------------------------------- #
# The chain is entered where the machine is, and the row records the start it actually used
# rather than the one the chain would have started from.
reset_machine 25.12.1
out=$(drv --payload-dir "$payloads" --from-version 25.12.1)
assert_eq "$?" "0" "ac-8 a machine that already runs 25.12.1 climbs from there"
assert_eq "$(rows)" "R2 " "ac-8 only the hop the machine still has to walk is recorded"
assert_eq "$(installs)" "payload-25.12.2.tar " "ac-8 and only its payload is installed"
assert_contains "$(note_of R2)" "start=25.12.1" \
    "ac-8 the row records the start version the run was given"

# A machine that is already further up the chain, walked without --from-version, is refused
# at the hop's own chain-position assertion - and the row names the flag that fixes it,
# because "the machine runs 25.12.1" is the answer to why the hop did not land.
reset_machine 25.12.1
out=$(drv --payload-dir "$payloads")
assert_eq "$?" "1" "ac-8 a machine already past the start of the chain fails the first hop"
assert_contains "$(note_of R1)" "chain broken" \
    "ac-8 the row says the machine is not where the hop starts"
assert_contains "$(note_of R1)" "--from-version 25.12.1" \
    "ac-8 the row names the flag that starts the chain where the machine is"
assert_contains "$out" "the machine runs 25.12.1 but this run was told to start at 25.12.0" \
    "ac-8 the mismatch is stated before the first boot, not only in the row"

reset_machine
out=$(drv --payload-dir "$payloads" --only R1)
assert_eq "$?" "0" "ac-8 --only runs a single hop"
assert_eq "$(rows)" "R1 " "ac-8 --only records that hop and nothing else"

# A resumed run skips what already passed, and only while everything before it passed: a
# hole in the chain is not resumed over.
reset_machine 25.12.1
printf 'R1\tPASS\t-\tfrom an earlier run\n' >"$results"
out=$(drv --payload-dir "$payloads" --resume)
assert_eq "$?" "0" "ac-8 --resume finishes a chain an earlier run started"
assert_eq "$(rows)" "R1 R2 " "ac-8 the resumed run walks the hop that was left"
assert_eq "$(grep -c 'payload-25.12.1.tar' "$calls" || true)" "0" \
    "ac-8 a hop that already passed is not walked again"
reset_machine
printf 'R1\tFAIL\t-\tfrom an earlier run\n' >"$results"
out=$(drv --payload-dir "$payloads" --resume)
assert_eq "$(installs)" "payload-25.12.1.tar payload-25.12.2.tar " \
    "ac-8 a hole before a PASS row is not resumed over: the failed hop is walked again"

# --- environment, red line and usage ----------------------------------------- #
reset_machine
mkdir -p "$tmp/empty"
out=$(RESULTS="$tmp/gap.tsv" drv --only R1 --payload-dir "$tmp/empty")
assert_eq "$?" "4" "ac-8 a payload that is not there is an environment gap"
assert_eq "$(cut -f2 "$tmp/gap.tsv")" "GAP" "ac-8 the row is GAP when the payload is missing"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" \
    "ac-8 a missing payload is reported before the machine is touched"

reset_machine
printf 'placeholder, not a tar\n' >"$tmp/old-24.10.1.tar"
out=$(RESULTS="$tmp/old.tsv" drv --only R1 --payload "R1=$tmp/old-24.10.1.tar")
assert_eq "$?" "1" "ac-8 a 24.x payload is refused, not walked"
assert_contains "$(cut -f4 "$tmp/old.tsv")" "below 25" "ac-8 the row says the line is out of scope"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" \
    "ac-8 the refused payload never reached a machine"

reset_machine
out=$(STUB_NO_COMMITTED=1 drv --only R1 --payload-dir "$payloads")
assert_eq "$?" "3" "ac-8 a machine with no committed slot stops the run at the red line"
assert_contains "$out" "red-line" "ac-8 the red line says what it refused to do"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-8 the red line writes no verdict row for a hop it never walked"

reset_machine
out=$(drv --nonsense)
assert_eq "$?" "2" "ac-8 an unknown argument is a usage error"
out=$(drv --only XX)
assert_eq "$?" "2" "ac-8 an unknown case is a usage error"
out=$(drv --only R1 --from 2)
assert_eq "$?" "2" "ac-8 --only and --from are exclusive"
out=$(drv --from 99)
assert_eq "$?" "2" "ac-8 --from needs a step that exists"
out=$(drv --from-version 24.10.0)
assert_eq "$?" "2" "ac-8 a start version the chain does not cover is a usage error"
assert_contains "$out" "25.12.0 25.12.1" \
    "ac-8 the usage error names the starts the chain does cover"
out=$(drv --from-version 25.12.2)
assert_eq "$?" "2" "ac-8 a start at the top of the chain has nothing to walk"
out=$(drv --only R1 --from-version 25.12.1)
assert_eq "$?" "2" "ac-8 --only cannot pick a hop the given start is already past"

finish
