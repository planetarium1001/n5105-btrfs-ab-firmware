#!/usr/bin/env bash
# Module: device
# The round-2 chain driver (scripts/device/matrix-round2.sh): ac-6 and ac-7 against a
# machine that is a directory.
#
# What is under test is the *chain*, not the hardware: one continuous run over one
# machine, no reflash in the middle, every hop judged on committed / generation / pending
# / boot / esp / packages, and the direction of a hop (up or down) decided from the
# versions themselves rather than from the name of the case.
#
# The stub `ssh` below is the machine: it keeps slot state in files, answers
# `ab-slot status`, arms a payload on `ab-upgrade` and commits it on `sync; reboot`. Two
# knobs replay the two releases this chain can meet:
#   STUB_BASE_ONLY_GUARD=1   the v0.0.10 image: a same-base payload is refused with exit 74
#                            `payload-already-installed`, which is what the round records
#                            as a regression and what --force is for
#   (unset)                  a release that carries the platform-only guard: the same-base
#                            platform hop goes through, and the driver records that instead
#
#   ac-6 the chain is one continuous run: base down 25.12.2 -> 25.12.1 -> 25.12.0, then up
#        again, every hop judged on the six fields, config and package drift recorded
#   ac-7 the platform layer rises on one base: 0.0.11 payload, then 25.12.2 @ p0.0.12, and
#        the payload-already-installed behaviour is asserted as the machine reports it
#   plus the release-byte case (v0.0.12 assets against index.txt), which is offline
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

driver="$root/scripts/device/matrix-round2.sh"
assert_file_exists "$driver" "ac-6 the round-2 chain driver exists"
out=$(sh -n "$driver" 2>&1)
assert_eq "$?" "0" "ac-6 the driver parses under sh, the shell the drivers run with: $out"
assert_matches "$(cat "$driver")" "tests/lib/device_config\.sh" \
    "ac-6 the driver reuses the shared config verifier instead of its own comparison"
assert_eq "$(grep -c 'software-samples.json' "$driver" || true)" "0" \
    "ac-6 the driver keeps no second sample list of its own"

# --- the machine ------------------------------------------------------------- #
bin="$tmp/bin"
calls="$tmp/calls.log"
actions="$tmp/actions.log"
state="$tmp/state"
fake="$tmp/device"
payloads="$tmp/payloads"
mkdir -p "$bin" "$state" "$fake/etc/config" "$payloads"
: >"$tmp/key"
for p in payload-0.0.11.tar payload-0.0.12.tar payload-25.12.0.tar \
    payload-25.12.1.tar payload-25.12.2.tar; do
    : >"$payloads/$p"
done

cat >"$bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
last=""
for a in "$@"; do last=$a; done
printf '%s\n' "$last" >>"${STUB_ACTIONS:?stub needs STUB_ACTIONS}"
state=${STUB_STATE:?stub needs STUB_STATE}
root=${STUB_ROOT:?stub needs STUB_ROOT}
get() { cat "$state/$1" 2>/dev/null || printf '%s' "${2-}"; }
put() { printf '%s\n' "$2" >"$state/$1"; }
bump() { put "$1" "$(( $(get "$1" 0) + 1 ))"; }
payload_rootfs() {
    case "$1" in
        *0.0.11.tar | *0.0.12.tar) printf '25.12.2\n' ;;
        *25.12.0.tar) printf '25.12.0\n' ;;
        *25.12.1.tar) printf '25.12.1\n' ;;
        *25.12.2.tar) printf '25.12.2\n' ;;
        *) printf '?\n' ;;
    esac
}
payload_platform() {
    case "$1" in
        *0.0.11.tar) printf '0.0.11\n' ;;
        *0.0.12.tar) printf '0.0.12\n' ;;
        *25.12.*.tar) printf '0.0.12\n' ;;
        *) printf '?\n' ;;
    esac
}
packages_field() {
    # A knob, not a default: unset means the machine realigns packages as it should, any
    # number means "from that hop on, report the packages of the other slot".
    if [ -n "${STUB_BAD_PACKAGES_AFTER_HOP:-}" ] &&
        [ "$(get hops 0)" -gt "${STUB_BAD_PACKAGES_AFTER_HOP}" ]; then
        printf 'other-slot\n'
    else
        printf 'aligned\n'
    fi
}
status_line() {
    printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=%s esp=%s packages=%s packages_reason=none\n' \
        "$(get slot a)" "$(get upper @overlay-25.12.2)" "$(get generation 1)" "$(get committed a)" \
        "$(get pending none)" "$(get committed a)" "$(get boot ok)" "$(get esp ok)" "$(packages_field)"
}
install_payload() {
    new=$(payload_rootfs "$1")
    [ "${new}" = "?" ] && exit 1
    put generation "$(( $(get generation 1) + 1 ))"
    put next_rootfs "${new}"
    put next_platform "$(payload_platform "$1")"
    if [ "$(get slot a)" = "a" ]; then put pending b; else put pending a; fi
    bump hops
    drift=${STUB_DRIFT_AFTER_HOP:-0}
    if [ "${drift}" -gt 0 ] && [ "$(get hops 0)" -gt "${drift}" ]; then
        printf "option drifted '%s'\n" "$(get hops 0)" >>"$root/etc/config/dockerd"
    fi
    printf 'ab-upgrade: installed %s into slot %s\n' "${new}" "$(get pending a)"
}
case "${last}" in
    'ab-slot status')
        if [ "${STUB_NO_COMMITTED:-0}" = "1" ]; then
            printf 'slot=a upper=@overlay-25.12.2 generation=1 committed=- pending=none boot=ok esp=ok\n'
            exit 0
        fi
        status_line
        ;;
    'ab-slot rootfs') printf '%s\n' "$(get rootfs 25.12.2)" ;;
    'true' | 'ab-slot gc') exit 0 ;;
    'cat > '* | "cat > "*) cat >/dev/null ;;
    'ab-upgrade --check '*)
        payload=${last##* }
        same_base=0
        [ "$(payload_rootfs "${payload}")" = "$(get rootfs 25.12.2)" ] && same_base=1
        same_platform=0
        [ "$(payload_platform "${payload}")" = "$(get platform 0.0.12)" ] && same_platform=1
        guard=0
        if [ "${same_base}" = "1" ]; then
            case "${STUB_BASE_ONLY_GUARD:-0}" in
                1) guard=1 ;;
                *) [ "${same_platform}" = "1" ] && guard=1 ;;
            esac
        fi
        if [ "${guard}" = "1" ]; then
            printf 'ab-upgrade: slot %s already runs %s (platform %s)\n' \
                "$(get slot a)" "$(get rootfs 25.12.2)" "$(get platform 0.0.12)"
            printf 'Next: ab-upgrade --force to reinstall the version this slot already runs\n'
            printf 'ab-upgrade: refused, reason=payload-already-installed\n'
            exit 74
        fi
        exit 0
        ;;
    'ab-upgrade --force '*) install_payload "${last##* }" ;;
    'ab-upgrade '*) install_payload "${last##* }" ;;
    'sync; reboot')
        target=$(get pending "$(get slot a)")
        put slot "${target}"
        put committed "${target}"
        put pending none
        new=$(get next_rootfs "$(get rootfs)")
        put rootfs "${new}"
        put platform "$(get next_platform "$(get platform 0.0.12)")"
        bump "layer-${new}"
        if [ "$(get "layer-${new}" 1)" -eq 1 ]; then
            put upper "@overlay-${new}"
        else
            put upper "@overlay-${new}-r$(get "layer-${new}")"
        fi
        ;;
    'cat '*)
        p=$(printf '%s' "${last#cat }" | tr -d "'")
        [ -f "$root${p}" ] || exit 1
        cat "$root${p}"
        ;;
    'apk list --installed'*)
        [ -f "$root/apk-list.txt" ] || exit 0
        cat "$root/apk-list.txt"
        ;;
    *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$bin/ssh"

results="$tmp/results.tsv"
evidence="$tmp/evidence"

reset_machine() { # [<running rootfs>] [<running platform>]
    rm -rf "$state" "$fake/etc/config" "$evidence"
    mkdir -p "$state" "$fake/etc/config"
    printf '%s\n' "${1:-25.12.2}" >"$state/rootfs"
    printf '%s\n' "${2:-0.0.12}" >"$state/platform"
    printf 'a\n' >"$state/slot"
    printf 'a\n' >"$state/committed"
    printf 'none\n' >"$state/pending"
    printf '1\n' >"$state/generation"
    printf 'ok\n' >"$state/boot"
    printf 'ok\n' >"$state/esp"
    printf 'aligned\n' >"$state/packages"
    printf '1\n' >"$state/layer-25.12.2"
    printf '@overlay-25.12.2\n' >"$state/upper"
    printf '0\n' >"$state/hops"
    printf "config system 'system'\n" >"$fake/etc/config/system"
    printf "config dockerd 'dockerd'\n" >"$fake/etc/config/dockerd"
    : >"$root_apk_list"
    printf 'htop-3.5.3-r1 x86_64\nluci-app-openclash-0.48.002 x86_64\n' >"$fake/apk-list.txt"
    : >"$calls"
    : >"$actions"
    rm -f "$results"
}
root_apk_list="$fake/apk-list.txt"

# drv [driver args...]: the driver against the stub machine, budgets cut to seconds.
drv() {
    PATH="$bin:$PATH" STUB_CALLS="$calls" STUB_ACTIONS="$actions" \
        STUB_STATE="$state" STUB_ROOT="$fake" AB_KEY="$tmp/key" AB_HOST=root@stub \
        AB_RESULTS="${RESULTS:-$results}" AB_POLL_INTERVAL=1 AB_WAIT_UP=1 \
        AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
        AB_RELEASE_DIR="${RELEASE_DIR:-$tmp/release}" \
        AB_R2_CONFIG_PATHS="/etc/config/system /etc/config/dockerd" \
        sh "$driver" "$@" 2>&1
}

sha_of() { # <file>
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# make_release_dir <dir>: the four assets v0.0.12 publishes, with an index that declares
# the payload digest and a SHA256SUMS beside it - the shape release-verify reads.
make_release_dir() {
    local d=$1
    mkdir -p "$d"
    printf 'image bytes\n' >"$d/n5105-ab-25.12.2-install-wan-ssh.img.gz"
    printf 'payload bytes\n' >"$d/n5105-ab-25.12.2-upgrade.tar"
    local size sha_img sha_tar sha_index
    size=$(wc -c <"$d/n5105-ab-25.12.2-upgrade.tar" | tr -d ' ')
    sha_img=$(sha_of "$d/n5105-ab-25.12.2-install-wan-ssh.img.gz")
    sha_tar=$(sha_of "$d/n5105-ab-25.12.2-upgrade.tar")
    cat >"$d/index.txt" <<EOF
AB-FEED 1
channel stable
entry
platform 0.0.12
base 25.12.2
kernel 6.12.103
payload n5105-ab-25.12.2-upgrade.tar
size ${size}
sha256 ${sha_tar}
end
EOF
    sha_index=$(sha_of "$d/index.txt")
    cat >"$d/SHA256SUMS" <<EOF
${sha_img}  n5105-ab-25.12.2-install-wan-ssh.img.gz
${sha_tar}  n5105-ab-25.12.2-upgrade.tar
${sha_index}  index.txt
EOF
}
make_release_dir "$tmp/release"

rows() { cut -f1 "$results" 2>/dev/null | tr '\n' ' '; }
verdicts() { cut -f2 "$results" 2>/dev/null | tr '\n' ' '; }
note_of() { awk -F'\t' -v c="$1" '$1 == c { print $4 }' "$results" 2>/dev/null; }
installs() { grep -oE 'ab-upgrade( --force)? /tmp/payload-[^ ]+\.tar' "$actions" 2>/dev/null | sed 's#.*/##' | tr '\n' ' '; }

# --- ac-6/ac-7: the plan, and it touches nothing ----------------------------- #
# A dry run is read by an operator standing in front of one machine; it has to say what
# each hop expects, and it may not open a socket to find out.
reset_machine
out=$(drv --dry-run)
rc=$?
assert_eq "$rc" "0" "ac-6 --dry-run exits zero"
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (P1|P2|D1|D2|U1|U2|REL) ' | awk '{print $2}' | tr '\n' ' ')" \
    "P1 P2 D1 D2 U1 U2 REL " "ac-6 the chain is planned in one order, platform first"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" "ac-6 --dry-run sends no ssh, not one"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-6 --dry-run writes no result row"
assert_eq "$([ -d "$evidence" ] && echo created || echo absent)" "absent" \
    "ac-6 --dry-run creates no result directory"

p1_line=$(printf '%s\n' "$out" | grep '^# P1 ')
d1_line=$(printf '%s\n' "$out" | grep '^# D1 ')
u1_line=$(printf '%s\n' "$out" | grep '^# U1 ')
rel_line=$(printf '%s\n' "$out" | grep '^# REL ')
assert_contains "$p1_line" "kind=platform" "ac-7 the first hop is the platform layer"
assert_contains "$p1_line" "from-platform=0.0.10 to-platform=0.0.11" \
    "ac-7 the platform hop names both releases"
assert_contains "$p1_line" "direction=same-base" \
    "ac-7 a platform-only hop does not change the base, and says so"
assert_contains "$p1_line" "from-rootfs=25.12.2 to-rootfs=25.12.2" \
    "ac-7 the platform hop keeps the base: both sides name 25.12.2"
assert_contains "$p1_line" "force=on-refusal" "ac-7 the same-base hop is the one that may need --force"
assert_contains "$p1_line" "regression=payload-already-installed" \
    "ac-7 the refund the v0.0.10 image gave is stated before the hop, not after"
assert_contains "$p1_line" "to-platform=0.0.11" "ac-7 the hop names the platform it installs"
assert_contains "$(printf '%s\n' "$out" | grep '^# P2 ')" "regression=none" \
    "ac-7 the second platform hop is not expected to be refused: only the v0.0.10 image was"

# The two directions land on the same version and must not be described the same way.
assert_contains "$d1_line" "direction=down" "ac-6 the downgrade says which way it goes"
assert_contains "$d1_line" "to-rootfs=25.12.1" "ac-6 the downgrade names the base it lands on"
assert_contains "$d1_line" "rollback=newer" \
    "ac-6 after a downgrade the slot left behind is the newer one"
assert_contains "$u1_line" "direction=up" "ac-6 the upgrade says which way it goes"
assert_contains "$u1_line" "to-rootfs=25.12.1" "ac-6 both directions land on the same version"
assert_contains "$u1_line" "rollback=older" \
    "ac-6 after an upgrade the slot left behind is the older one"
assert_eq "$([ "$d1_line" = "$u1_line" ] && echo same || echo differ)" "differ" \
    "ac-6 a downgrade and an upgrade to the same base are not described the same way"
assert_contains "$rel_line" "kind=release" "ac-7 the release-byte case is in the chain"
assert_contains "$rel_line" "tag=v0.0.12" "ac-7 the release case names the tag it reads"

out=$(drv --dry-run --from 3)
assert_eq "$(printf '%s\n' "$out" | grep -oE '^# (P1|P2|D1|D2|U1|U2|REL) ' | awk '{print $2}' | tr '\n' ' ')" \
    "D1 D2 U1 U2 REL " "ac-6 --from <step> plans only that step and what follows"

# --- ac-6: one continuous chain, every hop judged ---------------------------- #
reset_machine 25.12.2 0.0.10
out=$(drv)
rc=$?
assert_eq "$rc" "0" "ac-6 the chain on a healthy machine exits zero"
assert_eq "$(rows)" "P1 P2 D1 D2 U1 U2 REL " "ac-6 one row per hop, in chain order"
assert_eq "$(verdicts)" "PASS PASS PASS PASS PASS PASS PASS " "ac-6 every hop passes"
assert_eq "$(installs)" \
    "payload-0.0.11.tar payload-0.0.12.tar payload-25.12.1.tar payload-25.12.0.tar payload-25.12.1.tar payload-25.12.2.tar " \
    "ac-6 each hop installs its own payload, in order: down to 25.12.0 and back up"
assert_contains "$(grep -c 'ab-upgrade --check' "$actions" || true)" "6" \
    "ac-6 every hop is validated before it is written"
assert_eq "$(grep -c 'ab-upgrade --force' "$actions" || true)" "0" \
    "ac-6 a hop that was not refused is never forced: --force is not the default"
p1_note=$(note_of P1)
assert_contains "$p1_note" "regression=not-refused" \
    "ac-7 a release that carries the platform-only guard is recorded as such, not as a failure"
assert_contains "$p1_note" "0.0.10->0.0.11" "ac-7 the note names the platform move"
assert_contains "$p1_note" "config-drift=none" "ac-6 the note states the config drift it measured"
assert_contains "$p1_note" "packages=aligned" "ac-6 packages are aligned after every hop"
assert_contains "$(note_of D2)" "base 25.12.1->25.12.0 (down)" \
    "ac-6 the downgrade note carries the base it landed on and the direction it took"
assert_contains "$(note_of REL)" "index.txt" "ac-7 the release row names what it compared the bytes against"

# --- ac-7: the same-base refusal the v0.0.10 image gave ---------------------- #
# The round recorded exit 74 payload-already-installed and got through with --force. The
# driver has to keep making that judgement: an unexpected refusal is a failure, this one
# is the documented behaviour and is walked.
reset_machine 25.12.2 0.0.10
rm -f "$results"
out=$(STUB_BASE_ONLY_GUARD=1 drv --only P1)
rc=$?
assert_eq "$rc" "0" "ac-7 a machine that refuses the same-base payload still finishes the hop"
assert_contains "$(note_of P1)" "regression=refused-payload-already-installed" \
    "ac-7 the refusal is recorded as the regression it is"
assert_contains "$(note_of P1)" "force" "ac-7 the note says the hop went through with --force"
assert_contains "$(cat "$actions")" "ab-upgrade --force /tmp/payload-0.0.11.tar" \
    "ac-7 the second attempt is the flag the refusal names"
assert_eq "$(grep -c 'ab-upgrade --force' "$actions" || true)" "1" \
    "ac-7 --force is spent on the refusal and on nothing else"

# --- ac-6: a broken hop stops the chain instead of walking on ---------------- #
reset_machine
out=$(STUB_BAD_PACKAGES_AFTER_HOP=0 drv)
rc=$?
assert_eq "$rc" "1" "ac-6 a hop whose assertion fails makes the run fail"
assert_eq "$(rows)" "P1 REL " \
    "ac-6 the hops stop on the failed one; the release case reads a directory, not the machine"
assert_eq "$(verdicts)" "FAIL PASS " "ac-6 the hop that was red is the FAIL row"
assert_contains "$(note_of P1)" "packages" \
    "ac-6 the row names the field that was red, not just that something was"
assert_eq "$(grep -c 'payload-0.0.12.tar' "$actions" || true)" "0" \
    "ac-6 the hop after the failure was never pushed to the machine"

# --- ac-6: --from resumes without repeating what already happened ------------ #
# The device phase is hours long; a run that stopped at a hop is resumed at that hop, and
# the earlier hops are not walked again on a machine that already committed them.
reset_machine
: >"$calls"
: >"$actions"
out=$(drv --from 3)
rc=$?
assert_eq "$rc" "0" "ac-6 --from <step> resumes and finishes"
assert_eq "$(rows)" "D1 D2 U1 U2 REL " "ac-6 the resumed run records only the hops it walked"
assert_eq "$(grep -c 'payload-0.0.11.tar' "$actions" || true)" "0" \
    "ac-6 a resumed run does not push the platform payload again"
assert_eq "$(grep -c 'payload-0.0.12.tar' "$actions" || true)" "0" \
    "ac-6 a resumed run does not push the second platform payload again"

# --- ac-6: one hop on its own ------------------------------------------------ #
reset_machine
out=$(drv --only D1)
rc=$?
assert_eq "$rc" "0" "ac-6 --only runs a single hop"
assert_eq "$(rows)" "D1 " "ac-6 --only records that hop and nothing else"

# --- ac-7: the release bytes against index.txt, offline ---------------------- #
reset_machine
rm -f "$results"
out=$(drv --only REL)
rc=$?
assert_eq "$rc" "0" "ac-7 the release case passes on assets that match their index"
assert_eq "$(verdicts)" "PASS " "ac-7 the release case records PASS"
assert_contains "$(note_of REL)" "index.txt" "ac-7 the row says the bytes were compared with the index"
assert_eq "$(grep -c 'payload-0.0.11.tar' "$actions" || true)" "0" \
    "ac-7 the release case does not touch the machine"

cp -a "$tmp/release" "$tmp/release-bad"
printf 'one byte too many\n' >>"$tmp/release-bad/n5105-ab-25.12.2-upgrade.tar"
rm -f "$results"
out=$(RELEASE_DIR="$tmp/release-bad" drv --only REL)
rc=$?
assert_eq "$rc" "1" "ac-7 an asset whose bytes do not match fails the case"
assert_eq "$(verdicts)" "FAIL " "ac-7 a byte mismatch is a FAIL, not a GAP"
assert_contains "$(note_of REL)" "sums-entry" \
    "ac-7 the row names the comparison that failed"

rm -f "$results"
out=$(RELEASE_DIR="$tmp/no-such-dir" drv --only REL)
rc=$?
assert_eq "$rc" "4" "ac-7 a missing asset directory is an environment gap"
assert_eq "$(verdicts)" "GAP " "ac-7 no assets means GAP, never PASS"
assert_contains "$(note_of REL)" "gh release download" \
    "ac-7 the gap names the command that fetches the assets"

# --- the line this project may be tested against ---------------------------- #
# 24.x is opkg-era: a verdict from it says nothing about this product, so the driver
# refuses it before anything is written, and says which line it refuses.
mkdir -p "$tmp/old"
: >"$tmp/old/payload-24.10.1.tar"
reset_machine
out=$(drv --only D1 --payload "D1=$tmp/old/payload-24.10.1.tar")
rc=$?
assert_eq "$rc" "1" "ac-6 a 24.x payload is refused, not walked"
assert_eq "$(verdicts)" "FAIL " "ac-6 the refusal is a FAIL row"
assert_contains "$(note_of D1)" "below 25" "ac-6 the row says the line is out of scope"
assert_contains "$(note_of D1)" "opkg" "ac-6 the row says why: 24.x is the opkg line"
assert_eq "$(wc -l <"$calls" | tr -d ' ')" "0" \
    "ac-6 the refused payload never reached a machine"

reset_machine
out=$(drv --only D1 --payload "D1=$payloads/payload-0.0.11.tar")
rc=$?
assert_eq "$rc" "1" "ac-6 a platform payload on a base hop is refused"
assert_contains "$(note_of D1)" "platform payload" \
    "ac-6 the row says a platform payload cannot be walked as a base hop"

# --- environment and red line ----------------------------------------------- #
reset_machine
mkdir -p "$tmp/empty"
out=$(RESULTS="$tmp/gap.tsv" drv --only D1 --payload-dir "$tmp/empty")
rc=$?
assert_eq "$rc" "4" "ac-6 a payload that is not there is an environment gap"
assert_eq "$(cut -f2 "$tmp/gap.tsv")" "GAP" "ac-6 the row is GAP when the payload is missing"

reset_machine
out=$(STUB_NO_COMMITTED=1 drv --only D1)
rc=$?
assert_eq "$rc" "3" "ac-6 a machine with no committed slot stops the run at the red line"
assert_contains "$out" "red-line" "ac-6 the red line says what it refused to do"
assert_eq "$([ -f "$results" ] && echo written || echo absent)" "absent" \
    "ac-6 the red line writes no verdict row for a hop it never walked"

# --- usage ------------------------------------------------------------------ #
reset_machine
out=$(drv --nonsense)
assert_eq "$?" "2" "ac-6 an unknown argument is a usage error"
out=$(drv --only XX)
assert_eq "$?" "2" "ac-6 an unknown case is a usage error"
out=$(drv --only D1 --from 2)
assert_eq "$?" "2" "ac-6 --only and --from are exclusive"
out=$(drv --from 99)
assert_eq "$?" "2" "ac-6 --from needs a step that exists"

finish
