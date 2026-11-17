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
# criterion command. The driver builds its remote script out of fields six and seven, so
# what is asserted here is what the machine will actually run.
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
    ]))
PY
)

fixture_field() { # <name> <column>
    printf '%s\n' "$summary" | awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }'
}

assert_eq "$(printf '%s\n' "$summary" | cut -f1 | tr '\n' ' ')" "$names_list " \
  "ac-2 the manifest carries exactly the eight samples D3 fixed, in order"
assert_eq "$(printf '%s\n' "$summary" | awk -F'\t' 'NF != 7' | wc -l | tr -d ' ')" "0" \
  "ac-2 every sample names its packages, config, marker, expectation and criterion"
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
        luci-app-openclash) echo 'init=yes svc=stopped missing=0' ;;
        luci-app-ttyd) echo 'init=yes bin=yes svc=stopped missing=0' ;;
        istore) echo 'ver=istore-1.0 launcher=/usr/libexec/istore' ;;
        docker) echo 'client=yes daemon=yes' ;;
        kmod-usb-storage) echo 'kernel=6.12.103 mod=builtin loaded=no missing=0' ;;
        htop) echo 'rc=0 ver=htop-3.5.3-r1' ;;
    esac
}

# build_mark_answer <file> [gap|installed]: what --mark's remote half reports. istore is the
# sample the feed does not offer, so it answers with an empty version.
build_mark_answer() {
    : >"$1"
    local n
    for n in $names_list; do
        if [ "$n" = "istore" ] && [ "${2:-gap}" = "gap" ]; then
            printf 'istore\t0\t\t\t\tnot-installed\n' >>"$1"
        else
            printf '%s\t0\t%s-1.0-r1\t%s\t%s\tmarked\n' "$n" "$n" "$sha_cfg" "$sha_data" >>"$1"
        fi
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

probe_state="$tmp/drymark.tsv"
out=$(run_probe "$tmp/mark.tsv" --mark --dry-run) && rc=0 || rc=$?
assert_eq "$([ -e "$probe_state" ] && echo yes || echo no)" "no" \
  "ac-3 --dry-run --mark writes no baseline"
probe_state="$tmp/state.tsv"

# --------------------------------------------------------------------------- #
# --install and --unmark
# --------------------------------------------------------------------------- #

{
    for n in $names_list; do
        if [ "$n" = "istore" ]; then
            printf 'istore\t1\tERROR: unable to select packages: istore (no such package)\n'
        else
            printf '%s\t0\tOK: 27 MiB in 231 packages\n' "$n"
        fi
    done
} >"$tmp/install.tsv"
out=$(run_probe "$tmp/install.tsv" --install) && rc=0 || rc=$?
assert_eq "$rc" "4" "ac-2 --install with one unavailable package exits 4"
assert_contains "$out" "probe=htop status=pass ac=ac-2 packages=htop" \
  "ac-2 an installed sample is a pass"
assert_contains "$out" "probe=istore status=gap ac=ac-2 reason=install-failed rc=1" \
  "ac-2 istore is the GAP round 03 measured, not a FAIL"
assert_contains "$out" 'detail="ERROR: unable to select packages' \
  "ac-2 the GAP row carries apk's own words"
assert_contains "$out" 'rerun="sh scripts/device/follow-probe.sh --install --sample istore"' \
  "ac-2 the GAP row carries the rerun command"

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
