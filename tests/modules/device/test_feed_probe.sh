#!/usr/bin/env bash
# Module: device
# The feed probe: the ac-11 checklist as one block of text, without a device.
#
#   ac-11  the probe reports the fetchers, the CA store, the running versions and the
#          `--feed-check` verdict, in a shape that can be pasted into evidence
#   ac-11  a machine it cannot reach says so instead of printing empty fields
#   ac-11  the probe itself never writes: the only remote commands are reads
#
# The same stub-ssh style drives `feed-install.sh --case pin` below: the pin case is five
# judgements about what ab-upgrade prints plus one about what the machine is left holding,
# and all of it can be replayed without a device (ac-3).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
last=""
for arg in "$@"; do last="$arg"; done
case "${last}" in
    *"ab-slot status"*) printf '%s\n' "${STUB_STATUS:-slot=a upper=@overlay-25.12.2 generation=1 committed=a pending=none}" ;;
    *"uclient-fetch >/dev/null"*)
        # The real remote command prints the fetchers it found and the CA verdict.
        printf 'uclient-fetch, ca=no\n'
        ;;
    *"uname -r"*) printf '6.12.103\n' ;;
    *"/etc/platform-release"*) printf 'PLATFORM_VERSION=0.0.8\nUPSTREAM_VERSION=25.12.2\n' ;;
    *"test -f"*) exit "${STUB_CONF_EXIT:-0}" ;;
    *"uclient-fetch --help"*)
        [ "${STUB_HTTPS:-yes}" = "yes" ] && printf 'https support\n'
        exit 0
        ;;
    *"--feed-check"*)
        printf '%s\n' "${STUB_CHECK:-platform=0.0.8 platform_available=0.0.8 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=current}"
        exit "${STUB_CHECK_EXIT:-0}"
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$stub_bin/ssh"

probe="$root/scripts/device/feed-probe.sh"
run_probe() { PATH="$stub_bin:$PATH" STUB_CALLS="$tmp/calls" AB_KEY="$tmp/key" "$@" 2>&1; }

# --- ac-11: the happy path --------------------------------------------------
: >"$tmp/calls"
out="$(run_probe sh "$probe")"
rc=$?
assert_eq "$rc" "0" "ac-11 a reachable machine with a feed returns a verdict"
assert_contains "$out" "feed-probe fetchers=uclient-fetch https=yes ca=no conf=present" \
  "ac-11 the probe reports the fetcher, TLS capability, CA store and config"
assert_contains "$out" "feed-probe installed=0.0.8 base=25.12.2 kernel=6.12.103" \
  "ac-11 the probe reports what the machine runs"
assert_contains "$out" "feed-probe check platform=0.0.8 platform_available=0.0.8" \
  "ac-11 the probe carries the machine line verbatim"
assert_contains "$out" "feed-probe exit=0" "ac-11 the device's own exit code is printed"

# --- ac-11: an update available is still a successful probe -----------------
out="$(run_probe env STUB_CHECK_EXIT=10 sh "$probe")"
assert_eq "$?" "0" "ac-11 exit=10 (update available) is a successful probe"
assert_contains "$out" "feed-probe exit=10" "ac-11 the update verdict keeps its code"

# --- ac-11: refusals are facts, not probe failures -------------------------
out="$(run_probe env STUB_CHECK_EXIT=74 STUB_CHECK='ab-upgrade: refused, reason=no-feed-config' sh "$probe")"
assert_eq "$?" "1" "ac-11 a refusal makes the probe report a failure"
assert_contains "$out" "ab-upgrade: refused, reason=no-feed-config" "ac-11 the refusal is quoted"

# --- ac-11: missing config is reported, not inferred -----------------------
out="$(run_probe env STUB_CONF_EXIT=1 sh "$probe")"
assert_contains "$out" "conf=missing" "ac-11 a missing config is named as missing"

# --- ac-11: the probe only reads -------------------------------------------
assert_contains "$(cat "$tmp/calls")" "ab-upgrade --feed-check" "ac-11 the check is the read-only mode"
case "$(cat "$tmp/calls")" in
  *"ab-upgrade --feed "*) assert_eq "writes" "reads" "ac-11 the probe never runs an install" ;;
  *"uci set"*) assert_eq "writes" "reads" "ac-11 the probe never writes uci" ;;
  *) assert_eq "reads" "reads" "ac-11 the probe never writes the device" ;;
esac

# --- ac-11: an unreachable machine -----------------------------------------
cat >"$stub_bin/ssh-dead" <<'STUB'
#!/bin/sh
exit 255
STUB
chmod +x "$stub_bin/ssh-dead"
out="$(PATH="$stub_bin:$PATH" STUB_CALLS="$tmp/calls" AB_KEY="$tmp/key" \
  sh -c "mv '$stub_bin/ssh' '$stub_bin/ssh.real' && cp '$stub_bin/ssh-dead' '$stub_bin/ssh' && sh '$probe' 2>&1; rc=\$?; mv '$stub_bin/ssh.real' '$stub_bin/ssh'; exit \$rc")"
assert_contains "$out" "feed-probe unreachable" "ac-11 a machine that does not answer says so"

# --------------------------------------------------------------------------- #
# ac-3: feed-install.sh --case pin, replayed on a stub machine
#
# The stub keeps the three things the case measures - UPDATE_PIN, the pending slot and the
# generation - and answers with the shapes the real ab-upgrade prints (the `platform=` line,
# `refused, reason=...`, `installed ... into slot b`). Nothing here reaches a device, so the
# five judgements and the restore path are testable on a laptop.
# --------------------------------------------------------------------------- #
install="$root/scripts/device/feed-install.sh"
pin_bin="$tmp/pin-bin"
pin_state="$tmp/pin-state"
pin_calls="$tmp/pin-calls"
mkdir -p "$pin_bin" "$tmp/payloads"
: >"$tmp/payloads/payload-0.0.12.tar"

cat >"$pin_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
last=""
for arg in "$@"; do last=$arg; done
state=${STUB_STATE:?}
pin=""
[ -f "$state/pin" ] && pin=$(cat "$state/pin")
pending="none"
[ -f "$state/pending" ] && pending=$(cat "$state/pending")
gen=1
[ -f "$state/generation" ] && gen=$(cat "$state/generation")
running=${STUB_INSTALLED:-0.0.11}
cand=0.0.12
case "$last" in
    *"ab-upgrade --pin 1.2"*)
        printf 'ab-upgrade: refused, reason=pin-invalid-version\n'
        exit 74
        ;;
    *"ab-upgrade --unpin"*)
        rm -f "$state/pin"
        printf 'ab-upgrade: pin removed\n'
        exit 0
        ;;
    *"ab-upgrade --pin "*)
        v=""
        prev=""
        for a in $last; do
            [ "$prev" = "--pin" ] && v=$a
            prev=$a
        done
        printf '%s\n' "$v" >"$state/pin"
        printf 'ab-upgrade: pinned to %s\n' "$v"
        exit 0
        ;;
    *"ab-upgrade --feed-check"*)
        printf 'source=feed feed=https://feed.invalid/v1\n'
        if [ -n "$pin" ]; then
            printf 'platform=%s platform_available=%s base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 pin=%s status=pinned\n' \
                "$running" "$cand" "$pin"
            exit 0
        fi
        if [ "${STUB_NO_CANDIDATE:-0}" = "1" ]; then
            printf 'platform=%s platform_available=%s base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=current\n' \
                "$running" "$running"
            exit 0
        fi
        printf 'platform=%s platform_available=%s base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=update\n' \
            "$running" "$cand"
        exit 10
        ;;
    *"ab-upgrade --feed --yes"*)
        if [ -n "$pin" ]; then
            printf '%s is available, but UPDATE_PIN=%s holds this machine\n' "$cand" "$pin"
            printf 'ab-upgrade: refused, reason=feed-pinned\n'
            exit 74
        fi
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2-r2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        echo $((gen + 1)) >"$state/generation"
        exit 0
        ;;
    *"ab-upgrade /tmp/payload-"*)
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2-r2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        echo $((gen + 1)) >"$state/generation"
        exit 0
        ;;
    *"ab-slot abandon"*)
        rm -f "$state/pending"
        exit 0
        ;;
    *"ab-slot status"*)
        printf 'slot=a upper=@overlay-25.12.2 generation=%s committed=a pending=%s p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partname boot=ok esp=ok packages=aligned packages_reason=none\n' \
            "$gen" "$pending"
        ;;
    *"sed -n"*)
        [ -n "$pin" ] && printf '%s\n' "$pin"
        exit 0
        ;;
    *"cat > "*)
        cat >/dev/null
        ;;
    *"test -f"*)
        exit 1
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$pin_bin/ssh"

reset_pin_state() {
  rm -rf "$pin_state"
  mkdir -p "$pin_state"
  : >"$pin_calls"
}

# run_feed_install <cmd...>: the driver with the stub machine in front of every ssh.
run_feed_install() {
  PATH="$pin_bin:$PATH" STUB_CALLS="$pin_calls" STUB_STATE="$pin_state" \
    AB_KEY="$tmp/key" AB_HOST=root@stub AB_FEED_INSTALL_RESULTS="$tmp/pin-results.tsv" \
    AB_PAYLOAD_DIR="$tmp/payloads" "$@" 2>&1
}

# --- ac-3: the plan is the five judgements, and it touches no machine -------
reset_pin_state
out="$(run_feed_install env AB_DRY_RUN=1 sh "$install" --case pin --expect 0.0.12)"
assert_eq "$?" "0" "ac-3 the pin plan runs without a machine"
assert_contains "$out" "ac-3 1/5 ab-upgrade --pin 0.0.11" "ac-3 the plan pins the release below the candidate"
assert_contains "$out" "ac-3 5/5 ab-upgrade --pin 1.2" "ac-3 the plan numbers five judgements"
assert_contains "$out" "restore: abandon whatever the payload armed" "ac-3 the plan says how the machine is put back"
assert_eq "$(wc -l <"$pin_calls" | tr -d ' ')" "0" "ac-3 the pin plan runs no remote command"

# --- ac-3: the happy path, five judgements and a clean machine afterwards ---
reset_pin_state
out="$(run_feed_install sh "$install" --case pin --expect 0.0.12)"
assert_eq "$?" "0" "ac-3 a machine one release behind passes the pin case"
assert_contains "$out" "pinned to 0.0.11" "ac-3 --pin is written on the machine"
assert_contains "$out" "status=pinned" "ac-3 --feed-check answers status=pinned while held"
assert_contains "$out" "pin=0.0.11" "ac-3 the machine line names the pin it obeyed"
assert_contains "$out" "reason=feed-pinned" "ac-3 --feed is refused with feed-pinned"
assert_contains "$out" "ab-upgrade --feed-check exit=10 again after --unpin" \
  "ac-3 --unpin puts the automatic path back"
assert_contains "$out" "installed into slot b, not the running slot a" \
  "ac-3 an explicit payload still installs while the pin is set"
assert_contains "$out" "abandoned: nothing switches slots on the next boot" \
  "ac-3 the armed slot is abandoned before the case ends"
assert_contains "$out" "reason=pin-invalid-version" "ac-3 an illegal pin value is refused"
assert_contains "$out" "== ac-3 PASS" "ac-3 the case reports PASS"
assert_eq "$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)" "0" "ac-3 the happy path has no red line"
# The results row is what the Lead reads as evidence: one row per case, name then verdict.
assert_eq "$(awk -F'\t' 'NR == 1 { print $1, $2, $3 }' "$tmp/pin-results.tsv")" \
  "ac-3 PASS root@stub" "ac-3 the results row carries the case, the verdict and the machine"
assert_eq "$(cat "$pin_state/pin" 2>/dev/null || true)" "" "ac-3 no pin is left on the machine"
assert_eq "$(cat "$pin_state/pending" 2>/dev/null || true)" "" "ac-3 no half-installed slot is left pending"
assert_contains "$(cat "$pin_calls")" "ab-slot abandon" "ac-3 the case clears the slot the payload armed"

# --- ac-3: a machine that is already newest cannot make the judgement ------
reset_pin_state
out="$(run_feed_install env STUB_NO_CANDIDATE=1 sh "$install" --case pin --expect 0.0.12)"
assert_eq "$?" "1" "ac-3 a machine with no candidate fails the pin case"
assert_contains "$out" "the pin case needs a machine one release behind" \
  "ac-3 the red row names the precondition, not the release"
assert_contains "$out" "== ac-3 FAIL" "ac-3 the case reports FAIL"

# --- ac-3: a machine that arrives pinned is a GAP, and is left alone -------
reset_pin_state
printf '0.0.9\n' >"$pin_state/pin"
out="$(run_feed_install sh "$install" --case pin --expect 0.0.12)"
assert_eq "$?" "3" "ac-3 a machine that arrives pinned is a GAP, not a red row"
assert_contains "$out" "already carries UPDATE_PIN=0.0.9" "ac-3 the GAP names the pin it found"
assert_eq "$(cat "$pin_state/pin")" "0.0.9" "ac-3 the case writes nothing on a machine it will not test"
case "$(cat "$pin_calls")" in
  *"ab-upgrade --pin"*) assert_eq "wrote" "nothing" "ac-3 no pin is written before the GAP" ;;
  *) assert_eq "nothing" "nothing" "ac-3 no pin is written before the GAP" ;;
esac

# --- ac-3: no payload to name is a GAP, and the machine is still released --
reset_pin_state
mkdir -p "$tmp/empty-payloads"
out="$(run_feed_install env AB_PAYLOAD_DIR="$tmp/empty-payloads" \
  sh "$install" --case pin --expect 0.0.12 --index-file "$tmp/no-such-index.txt")"
assert_eq "$?" "3" "ac-3 a missing payload is a GAP, not a pin failure"
assert_contains "$out" "no payload to name while the pin is set" "ac-3 the GAP says what is missing"
assert_eq "$(cat "$pin_state/pin" 2>/dev/null || true)" "" \
  "ac-3 the pin is released even when the payload judgement could not run"

# --- ac-13: the candidate is the flag's, the environment's, or the default --
out="$(AB_DRY_RUN=1 sh "$install" --case check)"
assert_contains "$out" "expect=0.0.10" "ac-13 the default candidate is unchanged"
out="$(AB_DRY_RUN=1 AB_EXPECT=0.0.12 sh "$install" --case check)"
assert_contains "$out" "expect=0.0.12" "ac-13 AB_EXPECT moves the candidate for one run"
out="$(AB_DRY_RUN=1 AB_EXPECT=0.0.12 sh "$install" --case check --expect 0.0.13)"
assert_contains "$out" "expect=0.0.13" "ac-13 --expect wins over AB_EXPECT"
out="$(sh "$install" --help 2>&1)"
assert_contains "$out" "AB_EXPECT=0.0.12" "ac-13 the usage names the environment variable"
assert_contains "$out" "--case pin" "ac-13 the usage names the pin case"

# --------------------------------------------------------------------------- #
# ac-13: the three facts ac-1 asks for after the commit boot, replayed
#
# The install is the part of this file that used to assert boot= alone. These runs walk the
# whole case against a stub machine whose state flips the way a real one does (generation
# advances when the payload is laid down, the slot and the version move at the commit boot),
# so esp=, the +1 generation and the untouched UPSTREAM_VERSION are shown to be judged - and
# shown to go red when they do not hold.
# --------------------------------------------------------------------------- #
ac13_bin="$tmp/ac13-bin"
ac13_state="$tmp/ac13-state"
ac13_calls="$tmp/ac13-calls"
mkdir -p "$ac13_bin"

cat >"$ac13_bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
last=""
for arg in "$@"; do last=$arg; done
state=${STUB_STATE:?}
read_state() { cat "$state/$1" 2>/dev/null || printf '%s' "$2"; }
gen=$(read_state generation 1)
esp=$(read_state esp ok)
pending=$(read_state pending none)
committed=$(read_state committed a)
slot=$(read_state slot a)
platform=$(read_state platform 0.0.11)
upstream=$(read_state upstream 25.12.2)
pin=$(read_state pin "")
case "$last" in
    *"/etc/platform-release"*)
        printf 'PLATFORM_VERSION=%s\nUPSTREAM_VERSION=%s\n' "$platform" "$upstream"
        ;;
    *"sha256sum"*)
        printf '%s\n%s  %s\n' "${STUB_PAYLOAD_SIZE:-100}" "${STUB_PAYLOAD_SHA:-deadbeef}" \
            "${AB_FEED_DIR:-/tmp/ab-feed}/payload.tar"
        ;;
    # The pin case (ac-3), replayed by the same machine: a pinned machine still answers
    # --feed-check (status=pinned, exit 0) and refuses the automatic install (74).
    *"ab-upgrade --pin 1.2"*)
        printf 'ab-upgrade: refused, reason=pin-invalid-version\n'
        exit 74
        ;;
    *"ab-upgrade --unpin"*)
        rm -f "$state/pin"
        printf 'ab-upgrade: pin removed\n'
        exit 0
        ;;
    *"ab-upgrade --pin "*)
        v=""
        prev=""
        for a in $last; do
            [ "$prev" = "--pin" ] && v=$a
            prev=$a
        done
        printf '%s\n' "$v" >"$state/pin"
        printf 'ab-upgrade: pinned to %s\n' "$v"
        exit 0
        ;;
    *"ab-upgrade --feed-check"*)
        # No --feed-url on this run, so the shipped config reaches the release.
        printf 'source=release feed=https://release.invalid/v1\n'
        if [ -n "$pin" ]; then
            printf 'platform=%s platform_available=0.0.12 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 pin=%s status=pinned\n' \
                "$platform" "$pin"
            exit 0
        fi
        printf 'platform=%s platform_available=0.0.12 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=update\n' \
            "$platform"
        exit 10
        ;;
    # The explicit payload path: installs while the pin is set, arms the other slot with
    # the same generation bump a real install makes.
    *"ab-upgrade /tmp/payload-"*)
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2-r2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        printf '%s\n' "$((gen + 1))" >"$state/generation"
        ;;
    *"ab-slot abandon"*)
        rm -f "$state/pending"
        ;;
    *"sed -n"*)
        [ -n "$pin" ] && printf '%s\n' "$pin"
        ;;
    *"cat > "*)
        # dev_push pipes the payload through cat.
        cat >/dev/null
        ;;
    *"ab-upgrade --feed --yes"*)
        if [ -n "$pin" ]; then
            printf '%s is available, but UPDATE_PIN=%s holds this machine\n' 0.0.12 "$pin"
            printf 'ab-upgrade: refused, reason=feed-pinned\n'
            exit 74
        fi
        printf 'platform=%s platform_available=0.0.12 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=none level=Z1 status=update\n' \
            "$platform"
        printf 'ab-upgrade: verified, installing\n'
        printf 'ab-upgrade: installed 25.12.2 into slot b (@overlay-25.12.2-r2), 0 conflict(s), reclaimed 0\n'
        printf 'b\n' >"$state/pending"
        # The layer is laid down here, which is when generation moves (lib.sh, measured).
        printf '%s\n' "$((gen + ${STUB_GEN_STEP:-1}))" >"$state/generation"
        ;;
    *"sync; reboot"*)
        # The commit boot: the candidate is the slot and the release file describes it.
        printf 'b\n' >"$state/slot"
        printf 'b\n' >"$state/committed"
        printf 'none\n' >"$state/pending"
        printf '%s\n' "${STUB_PLATFORM_AFTER:-0.0.12}" >"$state/platform"
        printf '%s\n' "${STUB_UPSTREAM_AFTER:-25.12.2}" >"$state/upstream"
        printf '%s\n' "${STUB_ESP_AFTER:-ok}" >"$state/esp"
        ;;
    *"ab-slot log --prev"*)
        printf 'stage=commit rootfs=25.12.2 result=ok action=commit\n'
        ;;
    *"ab-slot status"*)
        printf 'slot=%s upper=@overlay-25.12.2 generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=ok esp=%s packages=aligned packages_reason=none\n' \
            "$slot" "$gen" "$committed" "$pending" "$committed" "$esp"
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$ac13_bin/ssh"

cat >"$tmp/index.txt" <<'INDEX'
AB-FEED 1
channel stable
entry
platform 0.0.12
base 25.12.2
kernel 6.12.103
payload n5105-ab-25.12.2-upgrade.tar
size 100
sha256 deadbeef
end
INDEX

reset_ac13_state() {
  rm -rf "$ac13_state"
  mkdir -p "$ac13_state"
  printf '1\n' >"$ac13_state/generation"
  printf 'ok\n' >"$ac13_state/esp"
  printf 'none\n' >"$ac13_state/pending"
  printf 'a\n' >"$ac13_state/committed"
  printf 'a\n' >"$ac13_state/slot"
  printf '0.0.11\n' >"$ac13_state/platform"
  printf '25.12.2\n' >"$ac13_state/upstream"
  : >"$ac13_calls"
}

# run_ac13 [env assignments...]: the install case against the stub machine.
run_ac13() {
  PATH="$ac13_bin:$PATH" STUB_CALLS="$ac13_calls" STUB_STATE="$ac13_state" \
    AB_KEY="$tmp/key" AB_HOST=root@stub AB_FEED_INSTALL_RESULTS="$tmp/ac13-results.tsv" \
    AB_POLL_INTERVAL=1 AB_WAIT_UP=1 AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
    "$@" sh "$install" --case install --expect 0.0.12 --index-file "$tmp/index.txt" 2>&1
}

# --- ac-13: a good hop asserts esp, the +1 generation and the untouched base --
reset_ac13_state
out="$(run_ac13)"
assert_eq "$?" "0" "ac-13 the install case passes on a clean hop"
assert_contains "$out" "ok [ac-13] esp=ok" "ac-13 the boot's verdict on the ESP is asserted"
assert_contains "$out" "ok [ac-13] generation=2" "ac-13 the install is one generation, not a guess"
assert_contains "$out" "ok [ac-13] UPSTREAM_VERSION=25.12.2"   "ac-13 the base under the platform release did not move"
assert_contains "$out" "== ac-13 PASS" "ac-13 the case reports PASS"
assert_eq "$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)" "0" "ac-13 the clean hop has no red line"

# --- ac-13: each of the three is a judgement, not a printed field ----------
reset_ac13_state
out="$(run_ac13 env STUB_ESP_AFTER=dirty)"
assert_eq "$?" "1" "ac-13 an ESP the boot calls dirty is a FAIL"
assert_contains "$out" "FAIL [ac-13] esp=dirty, expected ok" "ac-13 the esp field is judged"

reset_ac13_state
out="$(run_ac13 env STUB_GEN_STEP=2)"
assert_eq "$?" "1" "ac-13 a generation that jumps by two is a FAIL"
assert_contains "$out" "FAIL [ac-13] generation=3, expected 2" "ac-13 the advancing generation is judged"

reset_ac13_state
out="$(run_ac13 env STUB_UPSTREAM_AFTER=25.12.3)"
assert_eq "$?" "1" "ac-13 a payload that moved the base is a FAIL"
assert_contains "$out" "FAIL [ac-13] UPSTREAM_VERSION=25.12.3, expected 25.12.2" \
  "ac-13 the base under the platform release is judged"

# --- ac-12: the plan names the source the flags will actually produce ------
# The static "source=release" was wrong for every --feed-url run, which is the run a
# local acceptance uses: the real assertion next to it expects source=feed there.
out="$(AB_DRY_RUN=1 sh "$install" --case check)"
assert_contains "$out" "ac-12 2/4 expect exit=10, source=release" \
  "ac-12 without --feed-url the plan expects source=release"
out="$(AB_DRY_RUN=1 sh "$install" --case check --feed-url https://mirror.invalid/v1)"
assert_contains "$out" "ac-12 2/4 expect exit=10, source=feed" \
  "ac-12 with --feed-url the plan expects source=feed"
assert_eq "$(printf '%s\n' "$out" | grep -c 'source=release' || true)" "0" \
  "ac-12 the plan does not promise the release source when a mirror was named"
assert_eq "$(printf '%s\n' "$out" | grep -c 'source=feed' || true)" "1" \
  "ac-12 the plan names exactly one source, the mirror's"

# --------------------------------------------------------------------------- #
# ac-13's row is its own sentence, not the previous case's
#
# The defect this locks (measured on the lab machine 2026-11-17): run_install never wrote
# CASE_NOTE and run_case never reset it, so under `--case all` - how the acceptance runs
# it - the ac-13 row carried ac-3's "committed b never moved" on the one case that moves
# the committed slot from b to a. The row is evidence, and that sentence was false. The
# stub now walks check, pin and install in one process, which is the shape that produced
# it; a case run alone could never show the contamination.
# --------------------------------------------------------------------------- #
mkdir -p "$tmp/all-payloads"
: >"$tmp/all-payloads/payload-0.0.12.tar"
run_all() {
  PATH="$ac13_bin:$PATH" STUB_CALLS="$ac13_calls" STUB_STATE="$ac13_state" \
    AB_KEY="$tmp/key" AB_HOST=root@stub AB_FEED_INSTALL_RESULTS="$tmp/all-results.tsv" \
    AB_PAYLOAD_DIR="$tmp/all-payloads" \
    AB_POLL_INTERVAL=1 AB_WAIT_UP=1 AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
    "$@" sh "$install" --case all --expect 0.0.12 --index-file "$tmp/index.txt" 2>&1
}
note_of() { awk -F'\t' -v c="$1" '$1 == c { print $4 }' "$tmp/all-results.tsv"; }

reset_ac13_state
rm -f "$tmp/all-results.tsv"
out="$(run_all)"
assert_eq "$?" "0" "ac-3/ac-13 --case all walks check, pin and install on one machine"
ac3_note=$(note_of ac-3)
ac12_note=$(note_of ac-12)
ac13_note=$(note_of ac-13)
assert_contains "$ac12_note" "feed-check saw 0.0.12 (source=release); exit=10" \
  "ac-12 the check row carries the candidate and the source it read"
assert_contains "$ac3_note" "held the automatic path" \
  "ac-3 the pin row keeps the sentence the pin case writes"
assert_eq "$(printf '%s' "$ac13_note" | grep -c 'held the automatic path' || true)" "0" \
  "ac-13 the install row does not reuse ac-3's sentence"
assert_eq "$(printf '%s' "$ac13_note" | grep -c 'never moved' || true)" "0" \
  "ac-13 the install row does not claim the committed slot never moved"
assert_contains "$ac13_note" "slot a -> b" \
  "ac-13 the row names the slot the upgrade landed in"
assert_contains "$ac13_note" "committed a -> b" \
  "ac-13 the row names where the committed slot moved"
assert_contains "$ac13_note" "reboots=1" "ac-13 the row says how many reboots it cost"
assert_contains "$ac13_note" "0.0.11 -> 0.0.12" "ac-13 the row names the version it moved"

finish
