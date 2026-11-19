#!/usr/bin/env bash
# Module: device
# ac-2 / ac-3: the offline contract of scripts/device/follow-probe.sh, the driver that
# carries the eight community samples across every base hop.
#
# What this file is for
# ---------------------
# The driver has two halves. The remote half runs on the machine and reports facts; the
# local half decides. This test replaces the machine with a stub `ssh` that prints the rows
# the remote half would print, so the deciding half - which is the half that decides whether
# a hop is green - is exercised without a device.
#
# The four states are not decoration, they are the finding:
#   pass  the package is still USABLE (its own criterion, from the manifest), and its fake
#         config and data marker still hash to what --mark saw
#   fail  one of those is not true. The row names which: not-installed, unusable,
#         check-crashed, config-changed, data-lost, no-answer, no-baseline
#   gap   the sample could not be installed when --mark ran. istore is the measured case
#         (`apk add istore` rc=1, "no such package", round 03 and again 2026-11-18): the
#         feed does not offer it, and that says nothing about the A/B machinery, so it must
#         not be reported as a FAIL
#   skip  no machine answered. A probe that reached nothing is not evidence of anything,
#         so it may never print a pass
#
# Why the version is NOT asserted
# -------------------------------
# A package that follows the new base is reinstalled and therefore gets a NEW version. The
# baseline records the version as a fact for the report; --verify compares only the two
# sha256 values. Asserting the version equal would fail exactly the behaviour this task
# exists to add, which is why the pass case below hands --verify a version the baseline
# never saw.
#
# Why the criteria are read out of the fixture
# --------------------------------------------
# "Still usable" has a different answer per package (stylesheet served, daemon answers,
# .ko present under the running kernel, binary starts). Those answers live in
# tests/fixtures/follow-samples.json, one command plus the ERE its output has to match, and
# the assertions on that file here are the half that keeps a single generic "apk list says
# installed" from quietly replacing them: a criterion that cannot tell "the package is
# there" from "the package works" is the defect this task was opened for.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

probe="$root/scripts/device/follow-probe.sh"
fixture="$root/tests/fixtures/follow-samples.json"
assert_file_exists "$probe" "ac-2 the package-follow driver exists"
assert_file_exists "$fixture" "ac-2 the sample manifest exists"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The machine, replaced: every ssh call prints one canned TSV and exits with STUB_RC.
# STUB_TOUCH is the witness that a dry run contacted nothing.
cat >"$tmp/bin/ssh" <<'STUB'
#!/bin/sh
[ -n "${STUB_TOUCH:-}" ] && : >"${STUB_TOUCH}"
[ -n "${STUB_ANSWER:-}" ] && [ -f "${STUB_ANSWER}" ] && cat "${STUB_ANSWER}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/bin/ssh"

# D3 fixed the set at eight samples; a manifest that drifts has to fail here rather than in
# a matrix run on the device.
names_list="luci-theme-argon luci-app-argon-config luci-app-openclash luci-app-ttyd istore docker kmod-usb-storage htop"

# One line per sample: name, packages, config path, data marker, expected output, needs,
# criterion command, setup. The driver builds its remote script out of fields six, seven and
# eight, so what is asserted here is what the machine will actually run.
summary=$(python3 - "$fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
for sample in doc.get("samples") or []:
    check = sample.get("check") or {}
    print("\t".join([
        sample.get("name") or "",
        " ".join(sample.get("packages") or []),
        sample.get("config_path") or "",
        sample.get("data_marker") or "",
        check.get("expect") or "",
        ",".join(sample.get("needs") or []),
        check.get("cmd") or "",
        sample.get("setup") or "",
    ]))
PY
)

fixture_field() { # <name> <column>
    printf '%s\n' "$summary" | awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }'
}

assert_eq "$(printf '%s\n' "$summary" | cut -f1 | tr '\n' ' ')" "$names_list " \
  "ac-2 the manifest carries exactly the eight samples D3 fixed, in order"
assert_eq "$(printf '%s\n' "$summary" | awk -F'\t' 'NF != 8' | wc -l | tr -d ' ')" "0" \
  "ac-2 every sample names its packages, config, marker, expectation, criterion and setup"
assert_eq "$(printf '%s\n' "$summary" | awk -F'\t' '$3 !~ /^\/etc\/config\//' | wc -l | tr -d ' ')" "0" \
  "ac-3 the fake config lives under /etc/config/ on every sample"
assert_eq "$(printf '%s\n' "$summary" | awk -F'\t' '$4 !~ /^\/data\//' | wc -l | tr -d ' ')" "0" \
  "ac-3 the data marker lives on the shared data partition on every sample"
assert_eq "$(printf '%s\n' "$summary" | cut -f7 | sort -u | wc -l | tr -d ' ')" "8" \
  "ac-2 no two samples share one criterion"

# The criteria that decide "usable", not "installed". A fixture edited to `apk list` for all
# eight would still pass every assertion above and would answer nothing.
assert_contains "$(fixture_field docker 7)" "docker info" \
  "ac-2 docker is judged by the daemon answering"
assert_contains "$(fixture_field kmod-usb-storage 7)" "/lib/modules" \
  "ac-2 the kmod is judged by its .ko under the running kernel"
assert_contains "$(fixture_field luci-theme-argon 7)" "cascade.css" \
  "ac-2 the theme is judged by its stylesheet being served"
assert_contains "$(fixture_field htop 7)" "htop --version" \
  "ac-2 htop is judged by the binary starting"
assert_contains "$(fixture_field luci-app-argon-config 7)" "luci.argon" \
  "ac-2 the LuCI app is judged by its rpcd plugin executing"
# Measured 2026-11-18 on 25.12.2 (6.12.103): usb-storage is BUILT IN - the package ships
# only /etc/modules.d/usb-storage and the kernel's own modules.builtin names the object - so
# a criterion that looked for the .ko alone reports a healthy sample as broken.
assert_contains "$(fixture_field kmod-usb-storage 7)" "modules.builtin" \
  "ac-2 the kmod criterion accepts a module the running kernel was built with"

# --- the two criteria round 1 falsified ------------------------------------ #
# ttyd: the binary is not in the directory the first version of the criterion named
# (/etc/init.d/ttyd:8 sets PROG=/usr/bin/ttyd on this image), so the criterion was failing a
# healthy machine before any hop. A criterion that hard-codes one directory measures the
# directory, not the package.
assert_eq "$(fixture_field luci-app-ttyd 7 | grep -c '/usr/sbin' || true)" "0" \
  "ac-2 the ttyd criterion no longer hard-codes the directory the daemon is not in"
assert_contains "$(fixture_field luci-app-ttyd 7)" "_bin /etc/init.d/ttyd ttyd" \
  "ac-2 the ttyd criterion asks the init script and PATH where the daemon is"
assert_contains "$(fixture_field luci-app-ttyd 5)" "bin=/" \
  "ac-2 the ttyd row reports the path it found, so a base that moves the binary is visible"
# The other direction: the criterion still has to fail when there is no binary at all. A
# "found something" reading would pass every machine and answer nothing.
ttyd_expect=$(fixture_field luci-app-ttyd 5)
assert_eq "$(printf '%s\n' 'init=yes bin=none svc=stopped missing=0' | grep -Ec "$ttyd_expect" || true)" "0" \
  "ac-2 the ttyd criterion fails when no daemon binary was found"
assert_eq "$(printf '%s\n' 'init=yes bin=/usr/bin/ttyd svc=running missing=0' | grep -Ec "$ttyd_expect" || true)" "1" \
  "ac-2 the ttyd criterion accepts the daemon this image actually ships"

# openclash: enabled at boot with no process is this package's steady state on the reference
# machine, and a probe that will not start a proxy can never make it anything else. Accepting
# it is not "any state passes": an init script that is gone or unparsable still fails, and
# the baseline comparison is what turns a criterion that never held into a named gap rather
# than a regression.
assert_contains "$(fixture_field luci-app-openclash 5)" "expected-not-running" \
  "ac-2 the openclash criterion accepts the steady state the baseline measures"
openclash_expect=$(fixture_field luci-app-openclash 5)
assert_eq "$(printf '%s\n' 'init=yes svc=missing missing=0' | grep -Ec "$openclash_expect" || true)" "0" \
  "ac-2 the openclash criterion still fails when the init script is gone"
assert_eq "$(printf '%s\n' 'init=no svc=expected-not-running missing=0' | grep -Ec "$openclash_expect" || true)" "0" \
  "ac-2 the openclash criterion still fails when the init script does not parse"

# --- docker's setup is declared where the driver can run it ---------------- #
# The criterion is the daemon answering, so the daemon has to be brought up by something.
# It was declared in the manifest and executed by nothing, which left the sample measuring a
# process that could never be there.
assert_contains "$(fixture_field docker 8)" "/etc/init.d/dockerd enable" \
  "ac-2 docker's setup enables the daemon, so it comes back by itself after a hop"
assert_contains "$(fixture_field docker 8)" "/etc/init.d/dockerd start" \
  "ac-2 docker's setup also starts it, which is what the baseline needs"
assert_eq "$(printf '%s\n' "$summary" | awk -F'\t' '$8 != "" && $1 != "docker"' | wc -l | tr -d ' ')" "0" \
  "ac-2 docker is the only sample that changes the machine's running state"

# --------------------------------------------------------------------------- #
# The rows the machine would print
# --------------------------------------------------------------------------- #

sha_cfg=$(printf 'c%.0s' $(seq 1 64))
sha_data=$(printf 'd%.0s' $(seq 1 64))
stub_rc=0
probe_state="$tmp/state.tsv"

run_probe() { # <answer-file> <args...>
    local answer=$1
    shift
    PATH="$tmp/bin:$PATH" STUB_ANSWER="$answer" STUB_RC="$stub_rc" STUB_TOUCH="${STUB_TOUCH:-}" \
        AB_KEY=/dev/null AB_HOST=root@stub AB_FOLLOW_STATE="$probe_state" \
        sh "$probe" "$@"
}

healthy_check() { # <name>: the fact line a working sample prints
    case "$1" in
        luci-theme-argon) echo 'css=200 missing=0' ;;
        luci-app-argon-config) echo 'rpc=ok js=200 missing=0' ;;
        luci-app-openclash) echo 'init=yes svc=expected-not-running missing=0' ;;
        luci-app-ttyd) echo 'init=yes bin=/usr/bin/ttyd svc=stopped missing=0' ;;
        istore) echo 'ver=istore-1.0 launcher=/usr/libexec/istore' ;;
        docker) echo 'client=yes daemon=yes' ;;
        kmod-usb-storage) echo 'kernel=6.12.103 mod=builtin loaded=no missing=0' ;;
        htop) echo 'rc=0 ver=htop-3.5.3-r1' ;;
    esac
}

# unusable_check <name>: the same criterion answered by a machine where the sample is broken.
unusable_check() { # <name>
    case "$1" in
        luci-app-ttyd) echo 'init=yes bin=none svc=stopped missing=0' ;;
        *) echo 'broken=yes' ;;
    esac
}

# build_mark_answer <file> [gap|installed] [<name whose criterion does not hold here>]:
# what --mark's remote half reports. istore is the sample the feed does not offer, so it
# answers with an empty version; the optional third argument records one sample's criterion
# output as one that does not satisfy its ERE, which is the shape round 1 measured on ttyd.
build_mark_answer() {
    : >"$1"
    local n cr co
    for n in $names_list; do
        if [ "$n" = "istore" ] && [ "${2:-gap}" = "gap" ]; then
            printf 'istore\t0\t\t\t\tnot-installed\t0\tver=none launcher=none\n' >>"$1"
            continue
        fi
        cr=0
        co=$(healthy_check "$n")
        if [ -n "${3:-}" ] && [ "$n" = "$3" ]; then
            co=$(unusable_check "$n")
        fi
        printf '%s\t0\t%s-1.0-r1\t%s\t%s\tmarked\t%s\t%s\n' \
            "$n" "$n" "$sha_cfg" "$sha_data" "$cr" "$co" >>"$1"
    done
}

# build_verify_answer <file> [name] [version|config|data|rc|out|drop] [value]
build_verify_answer() {
    : >"$1"
    local n v cs ds cr co
    for n in $names_list; do
        v="$n-1.0-r1"
        cs=$sha_cfg
        ds=$sha_data
        cr=0
        co=$(healthy_check "$n")
        if [ "$n" = "${2:-}" ]; then
            case "${3:-}" in
                version) v=$4 ;;
                config) cs=$4 ;;
                data) ds=$4 ;;
                rc) cr=$4 ;;
                out) co=$4 ;;
                drop) continue ;;
            esac
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$v" "$cs" "$ds" "$cr" "$co" >>"$1"
    done
}

# --------------------------------------------------------------------------- #
# ac-3: --mark records the baseline
# --------------------------------------------------------------------------- #

build_mark_answer "$tmp/mark.tsv"
out=$(run_probe "$tmp/mark.tsv" --mark) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-3 --mark with one uninstallable sample exits 4: a gap, not a failure"
assert_contains "$out" "probe=luci-theme-argon status=pass ac=ac-3" \
  "ac-3 an installed sample records a baseline"
assert_contains "$out" "probe=istore status=gap ac=ac-3 reason=install-gap" \
  "ac-3 a sample the feed does not offer is a GAP"
assert_contains "$out" "--sample istore" \
  "ac-3 the GAP row carries the command that reruns just that sample"
assert_file_exists "$probe_state" "ac-3 --mark writes the state file"

assert_eq "$(grep -vc '^#' "$probe_state")" "8" "ac-3 one baseline row per sample"
assert_eq "$(awk -F'\t' '$2 == "pass" && $3 != "" && length($5) == 64 && length($7) == 64' "$probe_state" | wc -l | tr -d ' ')" "7" \
  "ac-3 each installed sample records its version, config sha256 and data sha256"
assert_eq "$(awk -F'\t' '$1 == "istore" { print $2 }' "$probe_state")" "gap" \
  "ac-3 the uninstallable sample is a gap row, so --verify can tell it apart from a failure"
assert_contains "$(awk -F'\t' '$1 == "docker" { print $4 }' "$probe_state")" "/etc/config/docker" \
  "ac-3 the baseline names the file whose hash it recorded"
# The criterion's own answer is part of the baseline: without it --verify cannot tell a
# sample this hop broke from a criterion that never matched here in the first place.
assert_eq "$(awk -F'\t' '$1 == "htop" { print NF }' "$probe_state")" "9" \
  "ac-3 the baseline records the criterion's answer next to the two hashes"
assert_eq "$(awk -F'\t' '$1 == "htop" { print $9 }' "$probe_state")" "rc=0 ver=htop-3.5.3-r1" \
  "ac-3 the recorded answer is what the machine printed, not a verdict"
assert_contains "$out" "probe=luci-app-ttyd status=pass ac=ac-3 usable=yes" \
  "ac-3 --mark says which samples already answer their criterion"

# A remote half that answered without the criterion's output is a driver or manifest that
# predates the column: the row says it does not know, rather than blaming the sample.
probe_state="$tmp/state-short.tsv"
awk -F'\t' 'BEGIN { OFS = "\t" } { NF = 6; print }' "$tmp/mark.tsv" >"$tmp/mark-short.tsv"
out=$(run_probe "$tmp/mark-short.tsv" --mark) && rc=0 || rc=$?
assert_contains "$out" "probe=htop status=pass ac=ac-3 usable=unknown" \
  "ac-3 a baseline without the criterion's answer is recorded as unknown, not as broken"
probe_state="$tmp/state.tsv"

cp "$probe_state" "$tmp/state.once"
out=$(run_probe "$tmp/mark.tsv" --mark) && rc=0 || rc=$?
assert_command_ok "ac-3 a second --mark writes the same baseline (the marker is derived, not timestamped)" \
  cmp -s "$tmp/state.once" "$probe_state"

# --------------------------------------------------------------------------- #
# ac-2 / ac-3: --verify asserts both halves
# --------------------------------------------------------------------------- #

# The version is different on purpose: a package that followed the new base was reinstalled.
build_verify_answer "$tmp/verify.tsv" htop version "htop-9.9-r9"
out=$(run_probe "$tmp/verify.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 --verify with only the known install gap exits 4"
assert_contains "$out" "probe=htop status=pass ac=ac-2" \
  "ac-2 a sample whose version changed after the hop is still the same package"
assert_contains "$out" "probe=docker status=pass ac=ac-2 usable=yes" \
  "ac-2 docker passes on the daemon's answer"
assert_contains "$out" "config=unchanged data=unchanged" \
  "ac-3 a passing row states both survival facts"
assert_contains "$out" "probe=istore status=gap ac=ac-3 reason=install-gap" \
  "ac-2 the gap sample stays a gap across the hop"

build_verify_answer "$tmp/bad-usable.tsv" htop out "rc=127 ver=htop-3.5.3-r1"
out=$(run_probe "$tmp/bad-usable.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-2 a sample that will not run fails the run"
assert_contains "$out" "probe=htop status=fail ac=ac-2 reason=unusable" \
  "ac-2 the row names the criterion, not the package record"
assert_contains "$out" 'check="rc=127 ver=htop-3.5.3-r1"' \
  "ac-2 the row carries what the criterion printed, so a reader can see why"

build_verify_answer "$tmp/bad-config.tsv" kmod-usb-storage config "$(printf 'e%.0s' $(seq 1 64))"
out=$(run_probe "$tmp/bad-config.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-3 a changed config fails the run"
assert_contains "$out" "probe=kmod-usb-storage status=fail ac=ac-3 reason=config-changed" \
  "ac-3 the fake config did not survive the hop"
assert_contains "$out" "probe=luci-theme-argon status=pass" \
  "ac-3 one changed config does not take the other samples down"

build_verify_answer "$tmp/bad-data.tsv" docker data "$(printf 'f%.0s' $(seq 1 64))"
out=$(run_probe "$tmp/bad-data.tsv" --verify) && rc=0 || rc=$?
assert_contains "$out" "probe=docker status=fail ac=ac-3 reason=data-lost" \
  "ac-3 a changed data marker fails the run"
assert_contains "$out" "/data/ab-follow/docker.marker" \
  "ac-3 the row names the marker that changed"

build_verify_answer "$tmp/not-installed.tsv" docker version ""
out=$(run_probe "$tmp/not-installed.tsv" --verify) && rc=0 || rc=$?
assert_contains "$out" "probe=docker status=fail ac=ac-2 reason=not-installed" \
  "ac-2 a package that is gone after the hop is a failure, not a gap"

build_verify_answer "$tmp/crashed.tsv" luci-app-ttyd rc "2"
out=$(run_probe "$tmp/crashed.tsv" --verify) && rc=0 || rc=$?
assert_contains "$out" "probe=luci-app-ttyd status=fail ac=ac-2 reason=check-crashed rc=2" \
  "ac-2 a criterion that cannot run is reported as such, not as a broken package"

build_verify_answer "$tmp/missing-row.tsv" kmod-usb-storage drop
out=$(run_probe "$tmp/missing-row.tsv" --verify) && rc=0 || rc=$?
assert_contains "$out" "probe=kmod-usb-storage status=fail ac=ac-2 reason=no-answer" \
  "ac-2 a sample the machine did not answer for is a failure"

# A sample the baseline does not cover is a harness problem, not a device problem: the row
# must say so instead of quietly reporting a pass for something nobody marked.
awk -F'\t' 'BEGIN { OFS = "\t" } $1 != "htop"' "$probe_state" >"$tmp/state.partial"
cp "$probe_state" "$tmp/state.full"
cp "$tmp/state.partial" "$probe_state"
out=$(run_probe "$tmp/verify.tsv" --verify --sample htop) && rc=0 || rc=$?
assert_contains "$out" "probe=htop status=fail ac=ac-3 reason=no-baseline" \
  "ac-3 a sample with no baseline fails instead of passing"
cp "$tmp/state.full" "$probe_state"

# No baseline at all is a usage error: --verify before --mark can only measure itself.
probe_state="$tmp/absent.tsv"
out=$(run_probe "$tmp/verify.tsv" --verify 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "ac-3 --verify without a baseline is a usage error"
assert_contains "$out" "run --mark before the hop" "ac-3 the error says what to do"
probe_state="$tmp/state.tsv"

# --------------------------------------------------------------------------- #
# ac-2: only pass -> fail is a regression
# --------------------------------------------------------------------------- #
# Round 1 measured what the other reading costs: one criterion with a hard-coded path was
# already failing on the image the chain started from, every hop reported it as a failure,
# and five matrix cases went red for a defect no hop had anything to do with. The baseline
# now records the criterion's own answer, so the two cases are told apart.

# A baseline where ttyd's criterion does not hold, which is exactly the round-1 shape.
probe_state="$tmp/state-broken.tsv"
build_mark_answer "$tmp/mark-broken.tsv" gap luci-app-ttyd
out=$(run_probe "$tmp/mark-broken.tsv" --mark) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-3 a baseline whose criterion failed still exits 4, not 1"
assert_contains "$out" "probe=luci-app-ttyd status=pass ac=ac-3 usable=no" \
  "ac-3 --mark names the criterion that does not hold on the baseline image"
assert_contains "$out" 'check="init=yes bin=none svc=stopped missing=0"' \
  "ac-3 --mark carries the answer, so the wrong criterion is visible before the first hop"
assert_contains "$out" "probe=htop status=pass ac=ac-3 usable=yes" \
  "ac-3 a sample that does answer is still recorded as usable"

# The same wrong answer after the hop is the baseline's defect, not the hop's.
build_verify_answer "$tmp/verify-broken.tsv" luci-app-ttyd out "$(unusable_check luci-app-ttyd)"
out=$(run_probe "$tmp/verify-broken.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 a criterion that already failed before the hop is a gap, not a failure"
assert_contains "$out" "probe=luci-app-ttyd status=gap ac=ac-2 reason=baseline-unusable" \
  "ac-2 the row names the sample and says why it was not counted"
assert_contains "$out" 'baseline_check="init=yes bin=none svc=stopped missing=0"' \
  "ac-2 the row carries what the machine answered before the hop"
assert_contains "$out" "probe=htop status=pass" \
  "ac-2 one unusable criterion does not take the other samples down"

# The other direction, which must stay a failure: the criterion held at baseline and does
# not after the hop. A driver that turned every unusable answer into a gap would pass every
# hop, which is the defect this whole change is one step away from.
probe_state="$tmp/state-healthy.tsv"
build_mark_answer "$tmp/mark-healthy.tsv" gap
out=$(run_probe "$tmp/mark-healthy.tsv" --mark) && rc=0 || rc=$?
build_verify_answer "$tmp/verify-regressed.tsv" luci-app-ttyd out "$(unusable_check luci-app-ttyd)"
out=$(run_probe "$tmp/verify-regressed.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-2 the same answer after a healthy baseline fails the run"
assert_contains "$out" "probe=luci-app-ttyd status=fail ac=ac-2 reason=unusable" \
  "ac-2 pass -> fail is the regression the criterion exists to catch"
assert_contains "$out" 'expect="^init=yes bin=/[^ ]+ svc=(running|stopped) missing=0$"' \
  "ac-2 the failing row states the criterion it applied"

# A baseline written before the answer was recorded cannot be classified, so it stays a
# failure and says so: silence about the class would be worse than the old behaviour.
probe_state="$tmp/state-old.tsv"
awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ { print; next } { NF = 8; print }' \
    "$tmp/state-healthy.tsv" >"$probe_state"
out=$(run_probe "$tmp/verify-regressed.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-2 an older baseline still fails on an unusable sample"
assert_contains "$out" "reason=unusable" \
  "ac-2 an older baseline reports the criterion it applied"
assert_contains "$out" "baseline=unrecorded" \
  "ac-2 the row says the baseline could not be classified instead of guessing"

# The two survival facts are not part of that classification: they were hashed on this
# machine at --mark, so a config or a data marker this hop destroyed is a failure even for a
# sample whose criterion never matched. A broken criterion may not hide a lost marker.
probe_state="$tmp/state-healthy.tsv"
build_verify_answer "$tmp/baseline-and-lost.tsv" luci-app-ttyd out "$(unusable_check luci-app-ttyd)"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "luci-app-ttyd" { $4 = "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5" } { print }' \
    "$tmp/baseline-and-lost.tsv" >"$tmp/baseline-and-lost2.tsv"
out=$(run_probe "$tmp/baseline-and-lost2.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "1" "ac-3 a lost data marker fails even when the criterion is unusable"
assert_contains "$out" "probe=luci-app-ttyd status=fail ac=ac-3 reason=data-lost" \
  "ac-3 the row reports the loss rather than the inherited criterion"
probe_state="$tmp/state.tsv"

# --------------------------------------------------------------------------- #
# skip and --dry-run
# --------------------------------------------------------------------------- #

stub_rc=255
out=$(run_probe "$tmp/verify.tsv" --verify) && rc=0 || rc=$?
assert_eq "$rc" "3" "ac-2 a machine that does not answer is a skip (exit 3)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'status=skip')" "8" "ac-2 every sample is reported as skipped"
assert_eq "$(printf '%s\n' "$out" | grep -c 'status=pass')" "0" "ac-2 a skip never prints a pass"
stub_rc=0

out=$(STUB_TOUCH="$tmp/touched" run_probe "$tmp/verify.tsv" --verify --dry-run) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-2 --dry-run exits 0"
assert_contains "$out" "follow-probe dry-run: action=verify" "ac-2 --dry-run states the action it would take"
assert_contains "$out" "nothing was contacted" "ac-2 --dry-run says so"
assert_eq "$([ -e "$tmp/touched" ] && echo yes || echo no)" "no" "ac-2 --dry-run makes no ssh call"

# The dry run prints the script the machine would run, so what is on trial is visible: the
# criteria come from the manifest, not from a branch in the driver.
assert_contains "$out" "docker info" "ac-2 the dry run shows the manifest's criterion"
assert_contains "$out" "_missing luci-theme-argon" "ac-2 the dry run shows the criterion for the theme too"
# The one command that changes the machine is visible before it runs, in the plan row and in
# the script: a probe that starts a daemon without saying so is what round 1 had.
assert_contains "$out" 'setup="/etc/init.d/dockerd enable && /etc/init.d/dockerd start"' \
  "ac-2 the dry run names the setup it would run"

# --------------------------------------------------------------------------- #
# _bin: the helper the ttyd criterion is built on
# --------------------------------------------------------------------------- #
# The function is taken out of the remote script the dry run prints and run against trees
# laid out the way this image is, so what is asserted is the lookup the machine performs and
# not the spelling of a path in a fixture.
remote_script=$(printf '%s\n' "$out" | sed -n '/follow-probe dry-run: remote script:/,$p' | sed 's/^    //')
bin_fn=$(printf '%s\n' "$remote_script" | sed -n '/^_bin() {/,/^}/p')
assert_eq "$(printf '%s\n' "$bin_fn" | grep -c 'command -v' || true)" "1" \
  "ac-2 _bin has a PATH fallback for a base that moves the daemon"
assert_eq "$(printf '%s\n' "$bin_fn" | grep -c '/usr/sbin' || true)" "0" \
  "ac-2 _bin names no fixed directory"
{
    printf '%s\n' "$bin_fn"
    printf '_bin "$1" "$2"\n'
} >"$tmp/bin-lookup.sh"

bin_root="$tmp/binroot"
mkdir -p "$bin_root/etc/init.d" "$bin_root/usr/bin" "$tmp/elsewhere" "$tmp/empty-path"
printf '#!/bin/sh\nexit 0\n' >"$bin_root/usr/bin/ttyd"
printf '#!/bin/sh\n' >"$bin_root/etc/init.d/ttyd"
printf 'PROG=%s\n' "$bin_root/usr/bin/ttyd" >>"$bin_root/etc/init.d/ttyd"
chmod +x "$bin_root/usr/bin/ttyd" "$bin_root/etc/init.d/ttyd"
assert_eq "$(sh "$tmp/bin-lookup.sh" "$bin_root/etc/init.d/ttyd" ttyd)" \
  "$bin_root/usr/bin/ttyd" \
  "ac-2 _bin finds the daemon where the init script says it is, not in a fixed directory"

# Gone from the path the init script names and nowhere else: the answer is empty, which is
# what makes the criterion fail. A lookup that answered a path regardless would pass every
# machine. The name is synthetic so the assertion does not depend on what a developer's
# machine happens to have installed.
rm -f "$bin_root/usr/bin/ttyd"
assert_eq "$(PATH="$tmp/empty-path:/bin:/usr/bin" sh "$tmp/bin-lookup.sh" "$bin_root/etc/init.d/ttyd" ttyd-lookup-probe)" "" \
  "ac-2 _bin answers nothing when the daemon is gone, so the criterion can still fail"

printf '#!/bin/sh\nexit 0\n' >"$tmp/elsewhere/ttyd-lookup-probe"
chmod +x "$tmp/elsewhere/ttyd-lookup-probe"
assert_eq "$(PATH="$tmp/elsewhere:/bin:/usr/bin" sh "$tmp/bin-lookup.sh" "$bin_root/etc/init.d/ttyd" ttyd-lookup-probe)" \
  "$tmp/elsewhere/ttyd-lookup-probe" \
  "ac-2 _bin falls back to PATH when the path the init script names no longer resolves"

probe_state="$tmp/drymark.tsv"
out=$(run_probe "$tmp/mark.tsv" --mark --dry-run) && rc=0 || rc=$?
assert_eq "$([ -e "$probe_state" ] && echo yes || echo no)" "no" \
  "ac-3 --dry-run --mark writes no baseline"
probe_state="$tmp/state.tsv"

# --------------------------------------------------------------------------- #
# --install and --unmark
# --------------------------------------------------------------------------- #

# The remote half answers five fields per sample: apk's status and words, then the setup's
# status and words. A sample with no setup reports "absent", which is a fact about the
# manifest rather than a step that failed.
{
    for n in $names_list; do
        case "$n" in
            istore) printf 'istore\t1\tERROR: unable to select packages: istore (no such package)\tabsent\t\n' ;;
            docker) printf 'docker\t0\tOK: 27 MiB in 231 packages\t0\tdockerd started\n' ;;
            *) printf '%s\t0\tOK: 27 MiB in 231 packages\tabsent\t\n' "$n" ;;
        esac
    done
} >"$tmp/install.tsv"
out=$(run_probe "$tmp/install.tsv" --install) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 --install with one unavailable package exits 4"
assert_contains "$out" "probe=htop status=pass ac=ac-2 packages=htop setup=absent" \
  "ac-2 an installed sample is a pass, and says it had no setup to run"
assert_contains "$out" "probe=docker status=pass ac=ac-2 packages=docker dockerd setup=ok" \
  "ac-2 the row carries the setup that brought the daemon up"
assert_contains "$out" "probe=istore status=gap ac=ac-2 reason=install-failed rc=1" \
  "ac-2 istore is the GAP round 03 measured, not a FAIL"
assert_contains "$out" 'detail="ERROR: unable to select packages' \
  "ac-2 the GAP row carries apk's own words"
assert_contains "$out" 'setup=skipped' \
  "ac-2 a setup is not attempted for a package that did not install"
assert_contains "$out" 'rerun="sh scripts/device/follow-probe.sh --install --sample istore"' \
  "ac-2 the GAP row carries the rerun command"

# The setup is generated by the driver, so its position in the script is checkable: after
# apk add, and only when apk succeeded. A setup that ran first would report the install's
# failure as the daemon's.
inst_script=$(printf '%s\n' "$(run_probe "$tmp/install.tsv" --install --dry-run)" |
    sed -n '/follow-probe dry-run: remote script:/,$p' | sed 's/^    //')
assert_contains "$inst_script" 'if [ "$_rc" = 0 ]; then' \
  "ac-2 the setup runs only when the packages are on the machine"
apk_line=$(printf '%s\n' "$inst_script" | grep -n 'apk add docker dockerd' | cut -d: -f1)
setup_line=$(printf '%s\n' "$inst_script" | grep -n 'dockerd enable' | cut -d: -f1)
assert_eq "$([ -n "$apk_line" ] && [ -n "$setup_line" ] && [ "$apk_line" -lt "$setup_line" ] && echo after-apk || echo wrong)" \
  "after-apk" "ac-2 docker's setup follows its apk add in the script the machine runs"

# A setup that did not run leaves the sample installed but unable to answer, so the row is a
# gap: it is a finding about the machine, and the hop has not happened yet.
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "docker" { $4 = "1"; $5 = "dockerd: not found" } { print }' \
    "$tmp/install.tsv" >"$tmp/install-setup-failed.tsv"
out=$(run_probe "$tmp/install-setup-failed.tsv" --install) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 a setup that did not run is a gap, not a failure"
assert_contains "$out" "probe=docker status=gap ac=ac-2 reason=setup-failed rc=1" \
  "ac-2 the gap names the setup and its exit status"
assert_contains "$out" 'setup="dockerd: not found"' \
  "ac-2 the row carries what the setup said"

# The rule is "a sample that cannot be installed is a gap" for every sample, not a special
# case for istore: a feed that stops offering htop must read the same way.
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "htop" { $2 = "1" } { print }' "$tmp/install.tsv" >"$tmp/install-broken.tsv"
out=$(run_probe "$tmp/install-broken.tsv" --install) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 a package that stops installing is still a gap, not a failure"
assert_contains "$out" "probe=htop status=gap ac=ac-2 reason=install-failed" \
  "ac-2 the gap rule is not istore-specific"

# --unmark reports what it restored per sample; the same TSV shape answers it.
{
    for n in $names_list; do printf '%s\t0\trestored\n' "$n"; done
} >"$tmp/unmark.tsv"
out=$(run_probe "$tmp/unmark.tsv" --unmark) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-3 --unmark restores every sample and exits 0"
assert_contains "$out" "probe=docker status=pass ac=ac-3 config=/etc/config/docker restored=restored" \
  "ac-3 --unmark says which file it put back"

# --------------------------------------------------------------------------- #
# matrix.sh: what this driver's verdict becomes
# --------------------------------------------------------------------------- #
# follow-probe.sh decides per sample; matrix.sh decides per case. Round 1 measured the two
# disagreeing: the probe said "this criterion never matched here" and the matrix turned it
# into five red cases. The two functions that read a verdict are taken out of matrix.sh and
# run against canned probe output, so what is asserted is the grading and not the machine.
# The seam is AB_FOLLOW_PROBE, and ev() is stubbed because there is no evidence log here.
matrix="$root/scripts/device/matrix.sh"
assert_file_exists "$matrix" "ac-3 the matrix driver exists"
assert_contains "$(cat "$matrix")" 'FOLLOW_PROBE=${AB_FOLLOW_PROBE:-' \
  "ac-3 the matrix probe is a seam, so its grading can be tested without a machine"

follow_harness="$tmp/matrix-follow.sh"
{
    printf 'ev() { printf "EVIDENCE %%s\\n" "$*" >>"%s"; }\n' "$tmp/follow-evidence.log"
    # assert_follow and the two readers, up to the next section banner. A source of the
    # whole file would run the seven cases against a stub machine.
    awk '/^assert_follow\(\) \{/,/^# assert_markers/' "$matrix" | sed '$d'
} >"$follow_harness"
assert_contains "$(cat "$follow_harness")" "_follow_unjudged_rows" \
  "ac-3 the harness carries the readers the grading uses"

# A probe, canned: prints the rows of one case and exits with PROBE_RC.
cat >"$tmp/probe-stub.sh" <<'PROBE'
#!/bin/sh
[ -n "${PROBE_ROWS:-}" ] && cat "${PROBE_ROWS}"
exit "${PROBE_RC:-0}"
PROBE
chmod +x "$tmp/probe-stub.sh"

matrix_follow() { # <rows-file> <probe rc>: what matrix.sh makes of these rows
    PROBE_ROWS=$1 PROBE_RC=$2 sh -c '
        . "$1"
        AB_FOLLOW_STATE=$2 FOLLOW_PROBE=$3
        assert_follow M3
        printf "RC=%s\n" "$?"
    ' _ "$follow_harness" "$matrix_state" "$tmp/probe-stub.sh" 2>&1
}

# assert_follow only asks whether a baseline file exists; what it is judged against is the
# probe's rows, which are canned below.
matrix_state="$tmp/matrix-state.tsv"
: >"$matrix_state"
probe_state="$matrix_state"

{ for n in $names_list; do
      if [ "$n" = "istore" ]; then
          printf 'probe=istore status=gap ac=ac-3 reason=install-gap rerun="sh scripts/device/follow-probe.sh --install --sample istore"\n'
      else
          printf 'probe=%s status=pass ac=ac-2 usable=yes\n' "$n"
      fi
  done; } >"$tmp/rows-pass-gap.tsv"
out=$(matrix_follow "$tmp/rows-pass-gap.tsv" 4)
assert_contains "$out" "RC=0" "ac-3 a case whose samples passed and one gap is not red"
assert_contains "$out" "GAP  [M3] follow: istore(install-gap) not judged" \
  "ac-3 the case names the sample the feed does not offer"
assert_contains "$(cat "$tmp/follow-evidence.log")" "follow M3 rc=4" \
  "ac-3 the probe's exit status reaches the evidence"

# The round-1 shape: every hop judged a criterion that was already failing at baseline.
{ for n in $names_list; do
      if [ "$n" = "luci-app-ttyd" ]; then
          printf 'probe=luci-app-ttyd status=gap ac=ac-2 reason=baseline-unusable baseline_check="init=yes bin=none svc=stopped missing=0" check="init=yes bin=none svc=stopped missing=0"\n'
      elif [ "$n" = "istore" ]; then
          printf 'probe=istore status=gap ac=ac-3 reason=install-gap\n'
      else
          printf 'probe=%s status=pass ac=ac-2 usable=yes\n' "$n"
      fi
  done; } >"$tmp/rows-baseline.tsv"
out=$(matrix_follow "$tmp/rows-baseline.tsv" 4)
assert_contains "$out" "RC=0" \
  "ac-3 a criterion that was already failing at baseline does not take the case down"
assert_contains "$out" "luci-app-ttyd(baseline-unusable)" \
  "ac-3 the case names the sample whose criterion never matched, so it is not mistaken for a feed gap"
# A reason that merely starts with "baseline" must not be swallowed by the reader, and a
# real failure in the same output must still be counted: the reader is a filter, not a
# blanket.
cat "$tmp/rows-baseline.tsv" >"$tmp/rows-mixed.tsv"
printf 'probe=htop status=fail ac=ac-2 reason=unusable expect="^rc=0" check="rc=127"\n' >>"$tmp/rows-mixed.tsv"
out=$(matrix_follow "$tmp/rows-mixed.tsv" 1)
assert_contains "$out" "RC=1" "ac-3 one real regression makes the case red even beside a gap"
assert_contains "$out" "htop usable before the hop, not after it" \
  "ac-3 the failing case names the sample that stopped working"
assert_eq "$(printf '%s\n' "$out" | grep -c 'luci-app-ttyd(' || true)" "0" \
  "ac-3 the baseline gap is not listed as the reason the case failed"

# Production now reports that class as a gap, but the matrix must not depend on the exit
# code alone to keep it out of the failure list.
printf 'probe=luci-app-ttyd status=fail ac=ac-2 reason=baseline-unusable baseline_check="x" check="y"\n' \
  >"$tmp/rows-baseline-fail.tsv"
out=$(matrix_follow "$tmp/rows-baseline-fail.tsv" 1)
assert_contains "$out" "RC=0" "ac-3 a failing row that names the baseline is still not a regression"

# A probe that reached nothing may not turn a case green: the hop's own ssh worked seconds
# before, so an unanswered probe is a real defect in the driver, not a machine that is away.
printf 'probe=htop status=skip ac=ac-2 reason=no-machine\n' >"$tmp/rows-skip.tsv"
out=$(matrix_follow "$tmp/rows-skip.tsv" 3)
assert_contains "$out" "RC=1" "ac-3 a probe that judged nothing fails the case"
assert_contains "$out" "the probe reached no machine" "ac-3 the failing case says why"

# No baseline at all stays a skip, not a pass and not a failure of the hop: a run that never
# marked has nothing to judge against, and the plan says so before the run starts.
out=$(sh -c '
    . "$1"
    AB_FOLLOW_STATE=/nonexistent FOLLOW_PROBE=$2
    assert_follow M3
    printf "RC=%s\n" "$?"
' _ "$follow_harness" "$tmp/probe-stub.sh" 2>&1)
assert_contains "$out" "RC=0" "ac-3 no baseline does not fail the case"
assert_contains "$out" "skip follow [M3]: no baseline" "ac-3 the case says nothing was marked"

# --------------------------------------------------------------------------- #
# usage
# --------------------------------------------------------------------------- #

out=$(STUB_ANSWER="$tmp/verify.tsv" AB_KEY=/dev/null sh "$probe" --install --mark 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "ac-2 two actions at once is a usage error"
out=$(STUB_ANSWER="$tmp/verify.tsv" AB_KEY=/dev/null AB_FOLLOW_STATE="$tmp/state.tsv" \
    sh "$probe" --verify --sample no-such-sample 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "2" "ac-2 a --sample the manifest does not name is a usage error"
out=$(sh "$probe" --help 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "0" "ac-2 --help exits 0"

finish
