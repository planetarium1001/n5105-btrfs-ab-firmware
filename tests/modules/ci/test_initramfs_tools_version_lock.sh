#!/usr/bin/env bash
# Module: ci
#
# The initramfs toolset lockfile pins one upstream release, and its programs are the
# packages that release publishes. A matrix build asks for another release, so
# scripts/ci/initramfs-tools.sh derives a per-version lockfile for it under $CI_TMP_ROOT
# and keeps the pin a hard contract. Locked here:
#
#   ac-1 a build that names no release (the pin) still dies when the lockfile was not
#        bumped with it, with the message unchanged, and derives nothing
#   ac-1 a build whose release matches the lockfile verifies against that lockfile
#   ac-1 a build for another release derives <CI_TMP_ROOT>/locks/initramfs-tools-<v>.lock.json,
#        stages the toolset from that copy, announces the derived path and warns that the
#        drift assertion is not enforced for it, and the committed lockfile stays untouched
#   ac-1 CI_LOCK_STRICT=1 restores the pin contract for such a build: the same hard
#        failure and no derived lockfile
#
# Everything runs offline: the feeds are not reachable from a test, so CI_APK_TOOLS points
# at a stand-in that answers `lock` from the fixture release and runs the real
# scripts/ci/apk_tools.py for everything else. The staged bytes are the one real upstream
# package in tests/fixtures/apk-tools, so the install and its digest checks are real.
#
# Usage:
#   bash tests/modules/ci/test_initramfs_tools_version_lock.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

if ! command -v python3 >/dev/null 2>&1; then
  printf '# python3 unavailable, skipped\n'
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

script="$root/scripts/ci/initramfs-tools.sh"
real_tool="$root/scripts/ci/apk_tools.py"
fixtures="$root/tests/fixtures/apk-tools"

# The release the fake lockfile pins and the one the matrix build asks for.
lock_release="25.12.99"
build_release="25.12.94"
# The pin the repository ships, read from the one place that defines it
# (.github/upstream-pin.conf, read by ci_upstream_pin_read in scripts/ci/lib.sh): a build
# that names no release uses exactly this value.
pin=$(sed -n 's/^UPSTREAM_VERSION=//p' "$root/.github/upstream-pin.conf")

# The lockfile of this test: the fixture release (one real package) under a release name
# that is not the pin, so a build that names no release has to refuse it.
python3 - "$fixtures/minimal.lock.json" "$tmp/pin.lock.json" "$lock_release" <<'PY'
import json
import sys

source, destination, release = sys.argv[1:4]
lock = json.load(open(source, encoding="utf-8"))
lock["upstream_version"] = release
lock["generated_by"] = "tests/modules/ci/test_initramfs_tools_version_lock.sh (fake pin lockfile)"
lock["notes"] = [
    "Fake lockfile: the apk-tools fixture package under a release no feed publishes.",
]
open(destination, "w", encoding="utf-8").write(json.dumps(lock, indent=2) + "\n")
PY

apk_dir="$tmp/apks"
mkdir -p "$apk_dir"
cp "$fixtures/libuuid1-2.41.5-r1.apk" "$apk_dir/"

cat >"$tmp/apk_tools_stand_in.py" <<'PY'
"""Stand-in for scripts/ci/apk_tools.py while the feeds are unreachable.

`lock` answers with the fixture release, recording the arguments the stage passed and
the release it was asked for; every other subcommand runs the real tool, so the install
and its digest checks are the production code.
"""
import json
import os
import sys


def main(argv):
    if argv[:1] != ["lock"]:
        real = os.environ["STUB_REAL_TOOL"]
        os.execv(sys.executable, [sys.executable, real, *argv])
    options = {}
    rest = argv[1:]
    while rest:
        key = rest.pop(0).lstrip("-")
        options[key] = rest.pop(0)
    lock = json.load(open(os.environ["STUB_FIXTURE_LOCK"], encoding="utf-8"))
    lock["upstream_version"] = options["upstream-version"]
    lock["generated_by"] = "test stand-in for scripts/ci/apk_tools.py lock"
    with open(options["lock"], "w", encoding="utf-8") as handle:
        handle.write(json.dumps(lock, indent=2) + "\n")
    with open(os.environ["STUB_CALLS"], "a", encoding="utf-8") as handle:
        handle.write(
            "lock --lock {lock} --base-url {base-url} "
            "--upstream-version {upstream-version} --work {work}\n".format(**options)
        )
    print(f"[apk_tools] wrote {options['lock']}", file=sys.stderr)


main(sys.argv[1:])
PY

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
# curl stand-in: this test never downloads, so any request is a failure that names the URL.
set -uo pipefail
printf 'stub curl: the test does not download (%s)\n' "$*" >&2
exit 22
SH
chmod +x "$tmp/bin/curl"

run_stage() {
  # run_stage <tmp-root> [env assignment ...]
  local tmp_root=$1
  shift
  out=$(env \
    -u CI_UPSTREAM_VERSION -u CI_UPSTREAM_BASE -u CI_UPSTREAM_BASE_URL -u CI_LOCK_STRICT \
    -u CI_OUTPUT_ENV -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_ACTIONS \
    PATH="$tmp/bin:$PATH" \
    CI_TMP_ROOT="$tmp_root" \
    CI_APK_DIR="$apk_dir" \
    CI_APK_TOOLS_LOCK="$tmp/pin.lock.json" \
    CI_APK_TOOLS_SUMMARY="$tmp_root/tools.json" \
    CI_APK_TOOLS="$tmp/apk_tools_stand_in.py" \
    STUB_REAL_TOOL="$real_tool" \
    STUB_FIXTURE_LOCK="$tmp/pin.lock.json" \
    STUB_CALLS="$tmp_calls" \
    "$@" \
    bash "$script" --toolset boot --stage "$tmp_root/stage" 2>&1)
  code=$?
}

lock_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

hash_file() {
  bash -c '. "$1/scripts/ci/lib.sh" >/dev/null 2>&1; ci_sha256 "$2"' _ "$root" "$1"
}

lock_before=$(hash_file "$tmp/pin.lock.json")

# --------------------------------------------------------------------------- #
# 1. A build that names no release: the pin contract, and it still fails on a drifted
#    lockfile with the message it has always printed
# --------------------------------------------------------------------------- #
tmp_calls="$tmp/calls-pin"
: >"$tmp_calls"
run_stage "$tmp/ci-pin"
assert_eq "$code" "1" "ac-1 a build without CI_UPSTREAM_VERSION still fails on a lockfile the pin does not match"
assert_contains "$out" \
  "ERROR: lockfile pins upstream ${lock_release} but this build uses ${pin}; run initramfs-tools.sh --write-lock and commit the result" \
  "ac-1 the pin failure keeps its wording and names both releases"
if [ -e "$tmp/ci-pin/locks" ]; then pin_no_derive="present"; else pin_no_derive="absent"; fi
assert_eq "$pin_no_derive" "absent" "ac-1 a build without CI_UPSTREAM_VERSION derives no lockfile"
assert_eq "$(cat "$tmp_calls")" "" "ac-1 a build without CI_UPSTREAM_VERSION never calls the lock generator"

# --------------------------------------------------------------------------- #
# 2. A build whose release matches the lockfile: no derivation, the lockfile is used
# --------------------------------------------------------------------------- #
tmp_calls="$tmp/calls-match"
: >"$tmp_calls"
run_stage "$tmp/ci-match" CI_UPSTREAM_VERSION="$lock_release"
assert_eq "$code" "0" "ac-1 a build for the release the lockfile pins stages the toolset"
assert_eq "$(cat "$tmp_calls")" "" "ac-1 a matching release derives no lockfile"
assert_contains "$out" "upstream release ${lock_release}" \
  "ac-1 the stage reports the release of the lockfile it verified"
assert_file_exists "$tmp/ci-match/stage/lib/libuuid.so.1" "ac-1 the toolset is staged from the pinned lockfile"
assert_eq "$(printf '%s\n' "$out" | grep -c 'derived')" "0" \
  "ac-1 a matching release neither derives nor mentions a derived lockfile"

# --------------------------------------------------------------------------- #
# 3. A build for another release: a per-version lockfile is derived, staged from and
#    announced
# --------------------------------------------------------------------------- #
tmp_calls="$tmp/calls-derive"
: >"$tmp_calls"
run_stage "$tmp/ci-derive" CI_UPSTREAM_VERSION="$build_release"
derived="$tmp/ci-derive/locks/initramfs-tools-${build_release}.lock.json"
assert_eq "$code" "0" "ac-1 a build for another release stages the toolset from a derived lockfile"
assert_file_exists "$derived" "ac-1 the derived lockfile lands at CI_TMP_ROOT/locks/initramfs-tools-<version>.lock.json"
assert_eq "$(lock_field "$derived" upstream_version)" "$build_release" \
  "ac-1 the derived lockfile records the release the build asked for"
assert_contains "$out" "deriving a per-version lockfile for upstream ${build_release}: ${derived}" \
  "ac-1 the stage announces the release it derives for and the derived path"
assert_contains "$out" "WARNING: derived per-version lockfile: ${derived}" \
  "ac-1 the derive is a warning that names the derived path"
assert_contains "$out" "does not assert the committed lockfile (pinned ${lock_release})" \
  "ac-1 the warning names the release the committed lockfile still pins"
assert_contains "$out" "program drift is NOT enforced for this release" \
  "ac-1 the warning says the drift assertion is not enforced for this release"
assert_contains "$out" "CI_LOCK_STRICT=1 turns the same drift back into a hard failure" \
  "ac-1 the warning names the switch that restores the pin contract"
assert_contains "$(cat "$tmp_calls")" "--lock ${derived} " \
  "ac-1 the lock generator is asked to write the derived path"
assert_contains "$(cat "$tmp_calls")" "--upstream-version ${build_release} --work ${apk_dir}" \
  "ac-1 the lock generator is asked for the release the build wants, into the shared apk cache"
assert_contains "$out" "upstream release ${build_release}" \
  "ac-1 the stage reports the release of the derived lockfile it verified"
# The staged bytes prove which lockfile was used: the installer refuses a lockfile whose
# release is not the one the build asks for, so a pin-contract run would have died here.
assert_file_exists "$tmp/ci-derive/stage/lib/libuuid.so.1" \
  "ac-1 the derived lockfile passes verification and the toolset is staged from it"

derived_after=$(hash_file "$tmp/pin.lock.json")
assert_eq "$derived_after" "$lock_before" "ac-1 a derived build leaves the committed lockfile byte for byte untouched"

# The second toolset of the same build reuses the derived lockfile instead of resolving
# the feeds again; the staged bytes still have to pass the same verification.
: >"$tmp_calls"
run_stage "$tmp/ci-derive" CI_UPSTREAM_VERSION="$build_release"
assert_eq "$code" "0" "ac-1 a second toolset of the same build stages from the derived lockfile"
assert_eq "$(cat "$tmp_calls")" "" "ac-1 the derived lockfile is resolved once per build, not once per toolset"
assert_contains "$out" "reusing the derived lockfile ${derived}" \
  "ac-1 the reuse names the derived lockfile it verifies"
assert_file_exists "$tmp/ci-derive/stage/lib/libuuid.so.1" \
  "ac-1 the reused derived lockfile still verifies the bytes it stages"

# --------------------------------------------------------------------------- #
# 4. CI_LOCK_STRICT=1: the pin contract applies to every release again
# --------------------------------------------------------------------------- #
tmp_calls="$tmp/calls-strict"
: >"$tmp_calls"
run_stage "$tmp/ci-strict" CI_UPSTREAM_VERSION="$build_release" CI_LOCK_STRICT=1
assert_eq "$code" "1" "ac-1 CI_LOCK_STRICT=1 fails a build for another release"
assert_contains "$out" \
  "ERROR: lockfile pins upstream ${lock_release} but this build uses ${build_release}; run initramfs-tools.sh --write-lock and commit the result" \
  "ac-1 the strict failure is the pin message, unchanged"
if [ -e "$tmp/ci-strict/locks" ]; then strict_no_derive="present"; else strict_no_derive="absent"; fi
assert_eq "$strict_no_derive" "absent" "ac-1 CI_LOCK_STRICT=1 derives no lockfile"
assert_eq "$(cat "$tmp_calls")" "" "ac-1 CI_LOCK_STRICT=1 never calls the lock generator"

finish
