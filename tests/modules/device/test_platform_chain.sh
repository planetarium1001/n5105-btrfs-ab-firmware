#!/usr/bin/env bash
# Module: device
# The platform-only chain driver (scripts/device/platform-chain.sh): ac-10 against a machine
# that is a directory.
#
# What is under test is the claim ac-10 makes: on one base, a payload that only carries a
# new platform layer moves the platform and *nothing else*. Three groups are checked on
# every hop, and each one has a negative case here, because a group that cannot go red is
# not being judged:
#
#   A PLATFORM must move   generation, /etc/platform-release, the three CLIs
#   B BASE must not move   DISTRIB_RELEASE, the kernel, the kernel/base-files/libc pins
#   C USER must not move   /etc/config/*, the /data marker, the world's user lines, packages
#
# The stub `ssh` below is the machine: it keeps slot state in files, answers
# `ab-slot status`, arms a payload on `ab-upgrade --yes` and commits it on `sync; reboot`.
# It is POSIX sh on purpose: it runs as `sh`, which is bash on the laptop this suite is
# written on and dash on the CI runner, and a bashism in here would fail only on the runner
# (measured 2026-11-19 on the stub of test_matrix_round2.sh).
#
#   ac-10 a full chain 0.0.10 -> 0.0.13 passes, in order, one row per hop
#   plus the negative cases: a base that moved, a pin that moved, a config file that moved,
#   a package that vanished, a platform that did not move, a tool that lied, a payload that
#   is missing (GAP), a payload this machine refuses (GAP with the reason), and a refusal
#   without a reason (FAIL)
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

driver="$root/scripts/device/platform-chain.sh"
assert_file_exists "$driver" "ac-10 the platform-chain driver exists"
out=$(sh -n "$driver" 2>&1)
assert_eq "$?" "0" "ac-10 the driver parses under sh, the shell the drivers run with: $out"
assert_matches "$(cat "$driver")" "tests/lib/device_config\.sh" \
    "ac-10 the driver reuses the shared config verifier instead of its own comparison"
# The STABLE/IDENTITY groups belong to lib.sh; a second definition here would change what
# matrix-round2 judges, and the PLATFORM group belongs to this stage only.
assert_eq "$(grep -c '^AB_STATUS_FIELDS_STABLE=' "$driver" || true)" "0" \
    "ac-10 the driver does not redefine lib.sh's STABLE group"
assert_eq "$(grep -c '^PLATFORM_STATUS_FIELDS=' "$driver" || true)" "1" \
    "ac-10 the PLATFORM group this stage needs lives in the driver, not in lib.sh"
assert_eq "$(grep -c 'software-samples.json' "$driver" || true)" "0" \
    "ac-10 the driver keeps no sample list of its own"

# --- the machine ------------------------------------------------------------- #
bin="$tmp/bin"
calls="$tmp/calls.log"
state="$tmp/state"
fake="$tmp/device"
payloads="$tmp/payloads"
evidence="$tmp/evidence"
mkdir -p "$bin" "$payloads" "$fake"
: >"$tmp/key"
# The fixtures are placeholders, not archives, and they must look like placeholders on both
# platforms: bsdtar (macOS) reads an empty file as a valid empty archive, while GNU tar (CI)
# fails the read, so one byte that is not a tar header reads as "not a tar" everywhere. The
# driver reads the payload's own platform.tar only when it is a real tar, so a placeholder
# also exercises the "which tools does this payload carry is unknown" branch.
# payload-0.0.10.tar is the chain start's own platform, which is the payload the positioning
# move installs when the machine was left somewhere else. It is not a hop payload: no case of
# this chain installs it, and a chain that never needs positioning never touches it.
for p in payload-0.0.10.tar payload-0.0.11.tar payload-0.0.12.tar payload-0.0.13.tar payload-25.12.2.tar; do
    printf 'placeholder, not a tar\n' >"$payloads/$p"
done

cat >"$bin/ssh" <<'STUB'
#!/bin/sh
# The machine. dev_ssh always ends with the remote command as one argument, so a simple
# command is the *last* argument; the compound probes this driver sends (`for t in ...; do
# ... done`) are matched on the whole line, because a stub that looked only at the last word
# would fall through to its catch-all and hide a broken probe.
cmd=$*
last=
for a in "$@"; do last=$a; done
printf '%s\n' "$cmd" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
state=${STUB_STATE:?stub needs STUB_STATE}
root=${STUB_ROOT:?stub needs STUB_ROOT}
get() { cat "$state/$1" 2>/dev/null || printf '%s' "${2-}"; }
put() { printf '%s\n' "$2" >"$state/$1"; }
bump() { put "$1" "$(( $(get "$1" 0) + 1 ))"; }
hops() { get hops 0; }

payload_platform() {
    case "$1" in
        *0.0.10.tar) printf '0.0.10\n' ;;
        *0.0.11.tar) printf '0.0.11\n' ;;
        *0.0.12.tar) printf '0.0.12\n' ;;
        *0.0.13.tar) printf '0.0.13\n' ;;
        *) printf '?\n' ;;
    esac
}

status_line() {
    printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=%s esp=%s packages=%s packages_reason=none\n' \
        "$(get slot a)" "$(get upper @overlay-25.12.2)" "$(get generation 1)" \
        "$(get committed a)" "$(get pending none)" "$(get committed a)" \
        "$(get boot ok)" "$(get esp ok)" "$(get packages aligned)"
}

install_payload() { # <remote payload path>
    _new=$(payload_platform "$1")
    if [ "${_new}" = "?" ]; then
        printf 'ab-upgrade: refused, reason=payload-unreadable\n'
        exit 74
    fi
    put next-platform "${_new}"
    case "${STUB_NO_GENERATION:-0}" in
        1) : ;;
        *) put generation "$(( $(get generation 1) + 1 ))" ;;
    esac
    if [ "$(get slot a)" = "a" ]; then put pending b; else put pending a; fi
    bump hops
    printf 'ab-upgrade: base unchanged, platform %s -> %s\n' "$(get platform)" "${_new}"
}

commit_boot() {
    _target=$(get pending)
    put slot "${_target}"
    put committed "${_target}"
    put pending none
    put platform "$(get next-platform "$(get platform)")"
    bump layer
    if [ "$(get layer 1)" -gt 1 ]; then
        put upper "@overlay-$(get rootfs)-r$(get layer)"
    else
        put upper "@overlay-$(get rootfs)"
    fi
    # The release file an installed slot carries is the payload's, rendered for that layer.
    case "${STUB_STALE_PLATFORM:-0}" in
        1) : ;;
        *)
            {
                printf 'PLATFORM_VERSION=%s\n' "$(get platform)"
                printf 'UPSTREAM_VERSION=%s\n' "$(get rootfs)"
                printf 'PLATFORM_STAGE=payload\n'
            } >"$root/etc/platform-release"
            ;;
    esac
    # The drift knobs: each one is a measured way ac-10 can fail, keyed on the hop number so
    # a test can say "from this hop on the base moved".
    _n=$(hops)
    if [ "${STUB_DRIFT_DISTRIB_AFTER_HOP:-0}" -gt 0 ] && [ "${_n}" -ge "${STUB_DRIFT_DISTRIB_AFTER_HOP}" ]; then
        put distrib 25.12.1
    fi
    if [ "${STUB_DRIFT_PIN_AFTER_HOP:-0}" -gt 0 ] && [ "${_n}" -ge "${STUB_DRIFT_PIN_AFTER_HOP}" ]; then
        sed -i.bak 's/^kernel=.*/kernel=6.12.94~0413601b1c3f0490e17f340fe09229ea-r1/' \
            "$root/etc/apk/world"
    fi
    if [ "${STUB_DRIFT_CONFIG_AFTER_HOP:-0}" -gt 0 ] && [ "${_n}" -ge "${STUB_DRIFT_CONFIG_AFTER_HOP}" ]; then
        printf "option drifted 'hop %s'\n" "${_n}" >>"$root/etc/config/dockerd"
    fi
    if [ "${STUB_DROP_PKG_AFTER_HOP:-0}" -gt 0 ] && [ "${_n}" -ge "${STUB_DROP_PKG_AFTER_HOP}" ]; then
        grep -v '^htop-' "$root/apk-list.txt" >"$root/apk-list.tmp"
        mv "$root/apk-list.tmp" "$root/apk-list.txt"
    fi
}

# The compound probes first: their last word is `done`, not the thing they ask about.
case "${cmd}" in
    *'for t in ab-slot'*)
        if [ "${STUB_STALE_TOOLS:-0}" = "1" ]; then _tp=0.0.9; else _tp=$(get platform); fi
        for t in ab-slot ab-upgrade ab-packages; do
            if [ "$(get "tool-$t" present)" = "present" ]; then
                printf 'tool=%s state=present platform=%s upstream=%s stage=%s\n' \
                    "$t" "${_tp}" "$(get rootfs 25.12.2)" payload
            else
                printf 'tool=%s state=absent\n' "$t"
            fi
        done
        exit 0
        ;;
    *'for f in /etc/config'*)
        for f in "$root"/etc/config/*; do
            [ -f "$f" ] || continue
            printf '/etc/config/%s\n' "${f##*/}"
        done
        exit 0
        ;;
    *'uname -r'*)
        # Quoted the way /etc/os-release quotes it, so the driver has to strip the quotes.
        printf "distrib='%s'\n" "$(get distrib 25.12.2)"
        printf 'kernel=%s\n' "$(get kernel 6.12.103)"
        exit 0
        ;;
esac

case "${last}" in
    'ab-slot status')
        if [ "${STUB_NO_COMMITTED:-0}" = "1" ]; then
            printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=- pending=none boot=ok esp=ok\n'
            exit 0
        fi
        status_line
        ;;
    'ab-slot rootfs') get rootfs 25.12.2 ;;
    'ab-slot gc' | 'true') exit 0 ;;
    'cat /etc/platform-release') cat "$root/etc/platform-release" ;;
    'cat /etc/apk/world') cat "$root/etc/apk/world" ;;
    'apk list --installed'*) cat "$root/apk-list.txt" ;;
    'ab-upgrade --check '*)
        # The positioning payload is the base the machine already runs, so a release whose
        # platform-only guard compares the base alone refuses it with exit 74
        # payload-already-installed. STUB_POSITION_74 names the reason that refusal carries:
        # payload-already-installed is the one the driver may spend --force on, and any other
        # reason is an unexplained refusal the driver must not force past.
        case "${last}" in
            *payload-0.0.10.tar)
                if [ -n "${STUB_POSITION_74:-}" ]; then
                    printf 'ab-upgrade: refused, reason=%s\n' "${STUB_POSITION_74}"
                    printf 'Next: install the platform layer the payload carries\n'
                    exit 74
                fi
                ;;
        esac
        if [ -n "${STUB_CHECK_REFUSE:-}" ]; then
            printf 'ab-upgrade: refused, reason=%s\n' "${STUB_CHECK_REFUSE}"
            printf 'Next: install the platform layer the payload carries\n'
            exit 74
        fi
        if [ "${STUB_CHECK_BROKEN:-0}" = "1" ]; then
            printf 'ab-upgrade: the payload could not be read\n'
            exit 1
        fi
        exit 0
        ;;
    'ab-upgrade --yes '*)
        # A positioning install that does not write the slot: the chain must stop and say so
        # instead of walking its first hop on a machine that never reached the chain's line.
        case "${last}" in
            *payload-0.0.10.tar)
                if [ "${STUB_POSITION_INSTALL_FAIL:-0}" = "1" ]; then
                    printf 'ab-upgrade: the platform layer could not be written\n'
                    exit 1
                fi
                ;;
        esac
        install_payload "${last##* }"
        ;;
    'sync; reboot') commit_boot ;;
    'cat > '*) cat >/dev/null ;;
    'cat '*)
        # devcfg_snapshot hands the path over single-quoted (devcfg_sq), so the quote is
        # stripped here rather than the path being flattened by the caller.
        p=${last#cat }
        p=$(printf '%s' "$p" | tr -d "'")
        [ -f "$root$p" ] || exit 1
        cat "$root$p"
        ;;
    *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$bin/ssh"

results="$tmp/results.tsv"

# reset_machine [platform] [rootfs]: one freshly flashed machine, before any hop.
reset_machine() {
    rm -rf "$state" "$fake" "$evidence"
    mkdir -p "$state" "$fake/etc/config" "$fake/etc/apk" "$fake/data"
    printf '%s\n' "${1:-0.0.10}" >"$state/platform"
    printf '%s\n' "${2:-25.12.2}" >"$state/rootfs"
    printf 'a\n' >"$state/slot"
    printf 'a\n' >"$state/committed"
    printf 'none\n' >"$state/pending"
    printf '1\n' >"$state/generation"
    printf 'ok\n' >"$state/boot"
    printf 'ok\n' >"$state/esp"
    printf 'aligned\n' >"$state/packages"
    printf '1\n' >"$state/layer"
    printf '0\n' >"$state/hops"
    printf '@overlay-25.12.2\n' >"$state/upper"
    printf '25.12.2\n' >"$state/distrib"
    printf '6.12.103\n' >"$state/kernel"
    printf 'present\n' >"$state/tool-ab-slot"
    printf 'present\n' >"$state/tool-ab-upgrade"
    printf 'present\n' >"$state/tool-ab-packages"
    {
        printf 'PLATFORM_VERSION=%s\n' "${1:-0.0.10}"
        printf 'UPSTREAM_VERSION=25.12.2\n'
        printf 'PLATFORM_STAGE=image\n'
    } >"$fake/etc/platform-release"
    cat >"$fake/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
busybox
htop
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
luci
luci-app-openclash
WORLD
    printf "config system 'system'\n" >"$fake/etc/config/system"
    printf "config network 'network'\n" >"$fake/etc/config/network"
    printf "config dockerd 'dockerd'\n" >"$fake/etc/config/dockerd"
    printf 'created-by-platform-chain-test\n' >"$fake/data/ab-matrix.marker"
    cat >"$fake/apk-list.txt" <<'PKGS'
base-files-1950~0c4cd0f9920a x86_64
busybox-1.37.0-r1 x86_64
htop-3.5.3-r1 x86_64
kernel-6.12.103~0413601b1c3f0490e17f340fe09229ea-r1 x86_64
libc-1.2.5-r5 x86_64
luci-26.298.29275~c84adb9 x86_64
luci-app-openclash-0.48.002 x86_64
PKGS
    : >"$calls"
    rm -f "$results"
}

# drv [driver args...]: the driver against the stub machine, budgets cut to seconds.
drv() {
    PATH="$bin:$PATH" STUB_CALLS="$calls" STUB_STATE="$state" STUB_ROOT="$fake" \
        AB_KEY="$tmp/key" AB_HOST=root@stub AB_RESULTS="${RESULTS:-$results}" \
        AB_POLL_INTERVAL=1 AB_WAIT_UP=1 AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
        sh "$driver" "$@" 2>&1
}

rows() { cut -f1 "$results" 2>/dev/null | tr '\n' ' '; }
verdicts() { cut -f2 "$results" 2>/dev/null | tr '\n' ' '; }
note_of() { awk -F'\t' -v c="$1" '$1 == c { print $4 }' "$results" 2>/dev/null; }
installs() { grep -oE 'ab-upgrade --yes /tmp/payload-[0-9.]+\.tar' "$calls" 2>/dev/null | sed 's#.*/##' | tr '\n' ' '; }
# A forced install is a different fact from an ordinary one, so it is counted apart: the
# driver may spend --force only on the refusal that names payload-already-installed.
forced_installs() { grep -oE 'ab-upgrade --yes --force /tmp/payload-[0-9.]+\.tar' "$calls" 2>/dev/null | sed 's#.*/##' | tr '\n' ' '; }
checks() { grep -c 'ab-upgrade --check' "$calls" 2>/dev/null || true; }
ssh_calls() { wc -l <"$calls" | tr -d ' '; }

# --- ac-10: the plan, and it touches nothing -------------------------------- #
# A dry run is what an operator reads while standing in front of one machine: it has to say
# what each hop expects, including the three groups, and it may not open a socket.
reset_machine
out=$(drv --dry-run --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 --dry-run exits zero"
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (P11|P12|P13) ' | awk '{print $2}' | tr '\n' ' ')" \
    "P11 P12 P13 " "ac-10 the chain is planned in order, three hops"
assert_eq "$(ssh_calls)" "0" "ac-10 --dry-run sends no ssh, not one"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-10 --dry-run writes no result row"
assert_eq "$([ -d "$evidence" ] && echo created || echo absent)" "absent" \
    "ac-10 --dry-run creates no evidence directory"

p11=$(printf '%s\n' "$out" | grep '^# P11 ')
p13=$(printf '%s\n' "$out" | grep '^# P13 ')
assert_contains "$p11" "kind=platform" "ac-10 the hop is a platform-only hop"
assert_contains "$p11" "platform=0.0.10->0.0.11" "ac-10 the hop names both platform releases"
assert_contains "$p11" "platform-direction=up" "ac-10 the platform move is described as an ascent"
assert_contains "$p11" "base=25.12.2->25.12.2" "ac-10 the base on both sides is the same"
assert_contains "$p11" "base-direction=same" "ac-10 a platform-only hop does not change the base, and says so"
assert_contains "$p11" "payload=payload-0.0.11.tar" "ac-10 the hop names the payload it carries"
assert_contains "$p13" "platform=0.0.12->0.0.13" "ac-10 the last hop lands on 0.0.13"
assert_contains "$out" "A platform must move" "ac-10 the plan states group A"
assert_contains "$out" "B base must not move" "ac-10 the plan states group B"
assert_contains "$out" "C user must not move" "ac-10 the plan states group C"
assert_contains "$out" "never a forced install" \
    "ac-10 the plan says a refusal is a GAP, not something to force past"
assert_contains "$out" "the stable fields did not move" \
    "ac-10 the plan reuses lib.sh's STABLE group"
# The positioning move is part of the plan even though the plan cannot know the running
# platform without an ssh call: the operator has to see that the chain may move the machine
# before it walks any hop.
assert_contains "$out" "# position start: if the machine is not on platform 0.0.10" \
    "ac-10 the plan says the chain may position the machine before its first hop"
assert_contains "$out" "payloads/payload-0.0.10.tar" \
    "ac-10 the plan names the payload the positioning move would install"

# --- ac-10: one continuous chain on one base -------------------------------- #
reset_machine 0.0.10 25.12.2
out=$(drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 the chain on a healthy machine exits zero"
assert_eq "$(rows)" "P11 P12 P13 " "ac-10 one row per hop, in chain order"
assert_eq "$(verdicts)" "PASS PASS PASS " "ac-10 every hop passes"
assert_eq "$(installs)" "payload-0.0.11.tar payload-0.0.12.tar payload-0.0.13.tar " \
    "ac-10 each hop installs its own payload, in order"
assert_eq "$(checks)" "3" "ac-10 every hop is validated before it is written"
assert_contains "$(note_of P11)" "platform 0.0.10->0.0.11" "ac-10 the note names the platform move"
assert_contains "$(note_of P11)" "base 25.12.2 unchanged" "ac-10 the note says the base did not move"
assert_contains "$(note_of P11)" "config-drift=none" "ac-10 the note states the config it compared"
assert_contains "$(note_of P11)" "pkg-drift=none" "ac-10 the note states the package set it compared"
assert_contains "$(note_of P11)" "ab-slot=0.0.11" "ac-10 the note names the version each CLI reports"
assert_contains "$(note_of P13)" "platform 0.0.12->0.0.13" "ac-10 the last hop is judged like the first"
assert_contains "$(note_of P13)" "ab-packages=0.0.13" "ac-10 the tool that arrives with 0.0.13 is judged"
assert_contains "$(cat "$state/platform")" "0.0.13" "ac-10 the machine ends on 0.0.13"
assert_eq "$(grep -c 'ab-upgrade --yes /tmp/payload' "$calls" || true)" "3" \
    "ac-10 an install answers the plan block, because there is no terminal"

# --- ac-10 group B: the base moved ----------------------------------------- #
# The base is the one thing a platform-only payload may not touch. Each of the three ways
# it can move is its own case, because each one is a different defect.
reset_machine 0.0.10 25.12.2
out=$(STUB_DRIFT_DISTRIB_AFTER_HOP=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a base whose DISTRIB_RELEASE moved fails the hop"
assert_eq "$(rows)" "P11 " "ac-10 the chain stops on the hop that moved the base"
assert_eq "$(verdicts)" "FAIL " "ac-10 that hop is a FAIL, not a GAP"
assert_contains "$(note_of P11)" "base-distrib-release" \
    "ac-10 the row names DISTRIB_RELEASE as the field that moved"
assert_contains "$(cat "$state/platform")" "0.0.11" \
    "ac-10 the hop did install: the failure is the base, not the platform"
assert_eq "$(grep -c 'payload-0.0.12.tar' "$calls" || true)" "0" \
    "ac-10 the hop after the failure was never pushed"

reset_machine 0.0.10 25.12.2
out=$(STUB_DRIFT_PIN_AFTER_HOP=1 drv --payload-dir "$payloads")
assert_eq "$?" "1" "ac-10 a base whose /etc/apk/world pin moved fails the hop"
assert_contains "$(note_of P11)" "base pin kernel" \
    "ac-10 the row names the pin that moved, not just 'the base'"

reset_machine 0.0.10 25.12.2
out=$(STUB_STALE_PLATFORM=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a hop whose platform did not move fails: A is judged, not assumed"
assert_contains "$(note_of P11)" "platform-version" \
    "ac-10 the row names the identity file as the field that stayed behind"

# --- ac-10 group A: the platform moved but a tool lied ---------------------- #
reset_machine 0.0.10 25.12.2
out=$(STUB_STALE_TOOLS=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a CLI that reports another release fails the hop"
assert_contains "$(note_of P11)" "tool-ab-slot-platform" \
    "ac-10 the row names the tool that disagreed with the payload"

# ab-packages arrives with 0.0.13 and is not in the 0.0.10..0.0.12 payloads (measured with
# tar -tf). Its absence on those hops is a fact about the payload, not a failure.
reset_machine 0.0.10 25.12.2
printf 'absent\n' >"$state/tool-ab-packages"
out=$(drv --only P11 --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 an absent tool the payload does not carry is not a failure"
assert_contains "$(note_of P11)" "ab-packages=absent" \
    "ac-10 the row still says the tool is absent, so it is never silently green"

# A payload that *does* carry ab-packages whose layer did not install it is a failure: the
# layer dropped a file the payload shipped.
mkdir -p "$tmp/build/platform/usr/sbin"
printf 'tool bytes, not a real command\n' >"$tmp/build/platform/usr/sbin/ab-packages"
( cd "$tmp/build/platform" && tar -cf "$tmp/build/platform.tar" . ) || exit 1
( cd "$tmp/build" && tar -cf "$payloads/payload-0.0.13.tar" platform.tar ) || exit 1
reset_machine 0.0.12 25.12.2
printf 'absent\n' >"$state/tool-ab-packages"
out=$(drv --only P13 --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a tool the payload carries but the layer did not install fails"
assert_contains "$(note_of P13)" "the payload carries it" \
    "ac-10 the row says the layer dropped what the payload shipped"
# Put the placeholder back: the rest of the file assumes a payload that is not a tar.
printf 'placeholder, not a tar\n' >"$payloads/payload-0.0.13.tar"

# --- ac-10 group C: the user layer moved ----------------------------------- #
reset_machine 0.0.10 25.12.2
out=$(STUB_DRIFT_CONFIG_AFTER_HOP=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a hop that edits /etc/config fails"
assert_contains "$(note_of P11)" "user-config" "ac-10 the row names the config group"
assert_contains "$(note_of P11)" "dockerd" "ac-10 the row names the file that moved"

reset_machine 0.0.10 25.12.2
out=$(STUB_DROP_PKG_AFTER_HOP=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a hop that loses an installed sample fails"
assert_contains "$(note_of P11)" "user-packages" "ac-10 the row names the package group"
assert_contains "$(note_of P11)" "removed" "ac-10 the row says the package is gone, not that it changed"
# The same fact by name: "the installed set is equal" only proves "the samples are still
# there" while both snapshots are readable, so the samples are also checked by name.
grep -q 'user-samples: htop' "$evidence/platform-chain/P11.log" 2>/dev/null \
    && _samples_named=yes || _samples_named=no
assert_eq "$_samples_named" "yes" \
    "ac-10 the row names the sample that is no longer installed"

# --- ac-10: generations ----------------------------------------------------- #
reset_machine 0.0.10 25.12.2
out=$(STUB_NO_GENERATION=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 an install that does not advance the generation fails"
assert_contains "$(note_of P11)" "generation" "ac-10 the row names the field that did not move"

# --- ac-10: a payload this round cannot walk ------------------------------- #
# Missing payload: a state of the run, recorded as the named GAP it is, and no machine is
# touched - the run does not walk two hops to discover the third payload is not there.
mkdir -p "$tmp/partial"
cp "$payloads/payload-0.0.11.tar" "$payloads/payload-0.0.12.tar" "$tmp/partial/"
reset_machine
out=$(RESULTS="$tmp/gap.tsv" drv --payload-dir "$tmp/partial")
rc=$?
assert_eq "$rc" "4" "ac-10 a payload that is not there is an environment gap"
assert_eq "$(cut -f1 "$tmp/gap.tsv")" "P13" "ac-10 the gap is recorded on the hop that needs it"
assert_eq "$(cut -f2 "$tmp/gap.tsv")" "GAP" "ac-10 no payload means GAP, never PASS"
assert_contains "$(cut -f4 "$tmp/gap.tsv")" "no payload at" "ac-10 the gap names the path it wanted"
assert_eq "$(ssh_calls)" "0" "ac-10 the missing payload is found before any machine is touched"

# A payload the machine refuses, with a readable reason: incompatible with this machine,
# so GAP with the reason named - and nothing forced into a slot.
reset_machine
out=$(STUB_CHECK_REFUSE=platform-incompatible drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "4" "ac-10 a payload this machine refuses is a GAP"
assert_eq "$(verdicts)" "GAP " "ac-10 the refused hop is a GAP row"
assert_contains "$(note_of P11)" "reason=platform-incompatible" \
    "ac-10 the row names the reason the machine gave"
assert_eq "$(installs)" "" "ac-10 a refused payload is never installed, forced or otherwise"

# A refusal with no readable reason is a different fact: the machine failed, it did not
# decline, and that is a FAIL.
reset_machine
out=$(STUB_CHECK_BROKEN=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a check that fails without a reason is a FAIL"
assert_contains "$(note_of P11)" "exited 1" "ac-10 the row names the exit status"
assert_eq "$(installs)" "" "ac-10 a payload that failed validation is never installed"

# A base payload is not this chain's payload, whatever its version line says.
reset_machine
out=$(drv --only P11 --payload "P11=$payloads/payload-25.12.2.tar")
rc=$?
assert_eq "$rc" "1" "ac-10 a base payload on a platform hop is refused"
assert_contains "$(note_of P11)" "base payload" \
    "ac-10 the row says a base payload cannot be walked as a platform hop"
assert_eq "$(ssh_calls)" "0" "ac-10 the refused payload never reached a machine"

# --- ac-10: starting somewhere else, resuming, one hop --------------------- #
# --from-version names the platform the machine already runs; the hops it has already
# walked are not walked again.
reset_machine 0.0.12 25.12.2
out=$(drv --from-version 0.0.12 --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 --from-version starts the chain where the machine already is"
assert_eq "$(rows)" "P13 " "ac-10 only the hops after that version are walked"
reset_machine 0.0.13 25.12.2
out=$(drv --from-version 0.0.13 --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 a chain that already ended exits zero instead of walking backwards"
assert_eq "$(ssh_calls)" "0" "ac-10 nothing to walk touches nothing"

# --- ac-10: the chain start's positioning move ----------------------------- #
# full-test runs matrix, matrix-rise and scenarios before this chain, so the machine is
# wherever their last hop left it: round 3 measured this chain starting at platform 0.0.13
# while P11 declares 0.0.10, and the row said "chain broken" instead of naming the missing
# step. A chain that declares its starting platform now gets onto it first, and the run has
# to say so: the move rides on the first row and on the baseline evidence, never silent.
reset_machine 0.0.12 25.12.2
out=$(drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 a machine on another platform is positioned, then the chain walks"
assert_eq "$(verdicts)" "PASS PASS PASS " "ac-10 every hop passes after the positioning move"
assert_contains "$(note_of P11)" "positioned=0.0.12->0.0.10" \
    "ac-10 the first row carries the platform the machine was moved from and to"
# The row may not claim --force on a move that did not need it: a suffix that always appears
# is the same as no suffix, and a reader could no longer tell an ordinary positioning move
# from one the running release refused. The evidence line is judged as well as the row,
# because the two are written from different expressions and only one of them is in the row.
assert_eq "$(printf '%s' "$(note_of P11)" | grep -c 'force=used' || true)" "0" \
    "ac-10 a positioning move that was not refused does not claim --force"
assert_eq "$(grep -c 'positioned: 0.0.12 -> 0.0.10.*force=used' \
    "$evidence/platform-chain/00-baseline.log" 2>/dev/null || true)" "0" \
    "ac-10 the evidence line does not claim --force either"
assert_eq "$(installs)" \
    "payload-0.0.10.tar payload-0.0.11.tar payload-0.0.12.tar payload-0.0.13.tar " \
    "ac-10 the positioning payload is installed once, before the chain's own payloads"
assert_contains "$(cat "$evidence/platform-chain/00-baseline.log")" \
    "positioning: 0.0.12 -> 0.0.10" \
    "ac-10 the baseline evidence names the positioning move, so it is never silent"

# The shape round 3 measured: the machine was left on platform 0.0.13, which is above the
# platform the chain starts from, so the positioning move is a downgrade. A move that only
# worked upwards would leave the measured case failing.
reset_machine 0.0.13 25.12.2
out=$(drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 a machine left above the chain start is positioned down to it"
assert_eq "$(verdicts)" "PASS PASS PASS " "ac-10 every hop passes after a positioning downgrade"
assert_contains "$(note_of P11)" "positioned=0.0.13->0.0.10" \
    "ac-10 the row names the measured round-3 starting platform and the chain's own"

# The same move on a release whose platform-only guard compares the base alone: the payload
# carries the base the machine already runs, so --check answers exit 74
# payload-already-installed. That is the one refusal the driver may spend --force on, and
# the row says the flag was spent rather than hiding it behind the positioning move.
reset_machine 0.0.12 25.12.2
out=$(STUB_POSITION_74=payload-already-installed drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 payload-already-installed is the refusal the positioning move forces past"
assert_contains "$(note_of P11)" "positioned=0.0.12->0.0.10 force=used" \
    "ac-10 the row says --force was spent on the positioning payload"
assert_eq "$(forced_installs)" "payload-0.0.10.tar " \
    "ac-10 --force is spent on the positioning payload and on nothing else"

# The counter-example that keeps the force honest: a refusal for another reason is not
# something to walk past. Forcing an unexplained refusal would hide the disagreement between
# the payload and this machine, which is the one thing the chain exists to find.
reset_machine 0.0.12 25.12.2
out=$(STUB_POSITION_74=payload-incompatible drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a positioning refusal for another reason is a FAIL"
assert_contains "$(note_of P11)" "positioning to platform 0.0.10 failed" \
    "ac-10 the row says the chain never started"
assert_eq "$(forced_installs)" "" "ac-10 an unexplained refusal is never forced past"

# A positioning payload that is not there is a state of the run, named as such: the chain
# must not walk a single hop from a line the machine never reached.
mkdir -p "$tmp/no-position"
cp "$payloads"/payload-0.0.1[123].tar "$tmp/no-position/"
reset_machine 0.0.12 25.12.2
out=$(drv --payload-dir "$tmp/no-position")
rc=$?
assert_eq "$rc" "4" "ac-10 a missing positioning payload is an environment gap"
assert_eq "$(verdicts)" "GAP " "ac-10 the run records the gap on the hop it could not start"
assert_contains "$(note_of P11)" "no positioning payload at" \
    "ac-10 the gap says what kind of step was missing"
assert_contains "$(note_of P11)" "payload-0.0.10.tar" \
    "ac-10 the gap names the file it wanted"
assert_eq "$(installs)" "" "ac-10 nothing is installed when the positioning payload is absent"

# An install that does not write the slot is a FAIL too: the machine is not on the chain's
# line, and every row after it would describe a machine that never existed.
reset_machine 0.0.12 25.12.2
out=$(STUB_POSITION_INSTALL_FAIL=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "1" "ac-10 a positioning install that does not land fails the run"
assert_contains "$(note_of P11)" "positioning to platform 0.0.10 failed" \
    "ac-10 the row says the chain never started"
assert_eq "$(rows)" "P11 " "ac-10 no hop is walked after a failed positioning move"

# --resume skips what already passed, and only that.
reset_machine 0.0.11 25.12.2
printf 'P11\tPASS\t-\tseeded by an earlier run\n' >"$results"
out=$(drv --resume --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 --resume finishes the chain"
assert_eq "$(rows)" "P11 P12 P13 " "ac-10 the resumed run keeps the earlier row and adds the rest"
assert_eq "$(grep -c 'payload-0.0.11.tar' "$calls" || true)" "0" \
    "ac-10 a resumed run does not push the payload it already walked"

# A hole is not resumed over: a PASS row on P13 with nothing before it means the chain was
# never walked to P13 on this machine, so the earlier hops are walked first.
reset_machine 0.0.10 25.12.2
printf 'P13\tPASS\t-\tseeded by a run of another chain\n' >"$results"
out=$(drv --resume --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 a hole before a PASS row is not resumed over"
assert_eq "$(rows)" "P13 P11 P12 P13 " \
    "ac-10 the hops before the seeded PASS row are walked again, in order"

reset_machine 0.0.11 25.12.2
out=$(drv --only P12 --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "0" "ac-10 --only walks a single hop"
assert_eq "$(rows)" "P12 " "ac-10 --only records that hop and nothing else"

# --- red line and usage ---------------------------------------------------- #
reset_machine
out=$(STUB_NO_COMMITTED=1 drv --payload-dir "$payloads")
rc=$?
assert_eq "$rc" "3" "ac-10 a machine with no committed slot stops the run at the red line"
assert_contains "$out" "red-line" "ac-10 the red line says what it refused to do"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-10 the red line writes no verdict row for a hop it never walked"

reset_machine
out=$(drv --nonsense)
assert_eq "$?" "2" "ac-10 an unknown argument is a usage error"
out=$(drv --only XX)
assert_eq "$?" "2" "ac-10 an unknown case is a usage error"
out=$(drv --from-version 9.9.9)
assert_eq "$?" "2" "ac-10 --from-version needs a platform this chain leaves"
out=$(drv --only P12 --from-version 0.0.11)
assert_eq "$?" "2" "ac-10 --only and --from-version are exclusive"

finish
