#!/usr/bin/env bash
# Module: ci
# The S5 fixture has to create an unreferenced writable layer that reclamation really
# removes, and the grading phase has to see both halves of that. Both halves used to be
# missing on one line of the matrix:
#
#   the workflow passed a hardcoded `--orphan-layer @overlay-25.12.1`. An image built for
#   upstream 25.12.1 already carries that name as its own live layer, so the fixture found
#   it, renamed the layer it meant to create to `orphan-<pid>-<timestamp>` and carried on.
#   That name is outside the namespace both readers filter on: `ab-slot gc` lists subvolumes
#   with `path @overlay-*`, and the commit phase scanned `^@overlay-`. The layer could
#   therefore never be reclaimed and never be reported, and the run for that line printed
#   reclaimed=0 while claiming to have tested early reclamation.
#
#   ac-1  the orphan name is derived from the base and cannot be a layer the product names,
#         so base 25.12.1 creates a real, separate layer instead of colliding
#   ac-2  a name that collides with an existing layer stops the fixture: it must never
#         rename itself to something no reader looks at, which is what hid the gap
#   ac-3  a name a slot references is refused as well - reclamation would have to keep it
#   ac-4  `ab-slot gc` (the shipped tool) reclaims the layer the fixture created; a layer
#         outside the @overlay-* namespace is left alone, which is why the name matters
#   ac-5  the commit phase sees the layer: it requires --orphan, fails while the layer is
#         still there, fails when nothing was reclaimed in any boot, and passes only when
#         the ring shows a reclaim and the layer is gone
#
# The fixture and the phase are driven against a directory tree: `btrfs` is a stub over
# directories, and mount/umount are no-ops over the mount points the scripts create
# themselves. The scripts under test are the real ones - ab-fixtures.sh is copied
# byte-identically next to a lib.sh whose only change is the three loop-device helpers a
# build host cannot provide.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

fixtures="$root/scripts/ci/ab-fixtures.sh"
phase="$root/scripts/ci/s5-phase.sh"
workflow="$root/.github/workflows/ci-s5.yml"
ab_slot="$root/platform/usr/sbin/ab-slot"

# --------------------------------------------------------------------------- #
# ac-1: the name is derived, and it is one the product cannot produce
#
# The three shapes a writable layer really has (disk.sh's install, payload-build.sh's
# payload layer, upgrade_layer_name()'s -r<N> second layer of one base) are listed here so
# the assertion is about the naming rule and not about one version string.
# --------------------------------------------------------------------------- #

artifact_name() { # <base> -> the layer the fixture derives for that base
    local base=$1 out="$tmp/name-$1.env"
    : >"$out"
    CI_OUTPUT_ENV="$out" CI_TMP_ROOT="$tmp/name-ci" CI_LOG_DIR="$tmp/name-logs" \
        CI_IMAGE="$tmp/image" CI_UPSTREAM_VERSION="$base" CI_REPO_ROOT="$root" \
        PATH="$tmp/empty-bin:$PATH" \
        bash -c '. "$1/scripts/ci/lib.sh"
                 eval "$(sed -n "/^orphan_layer_base()/,/^}/p" "$1/scripts/ci/ab-fixtures.sh")"
                 eval "$(sed -n "/^orphan_layer_name()/,/^}/p" "$1/scripts/ci/ab-fixtures.sh")"
                 orphan_layer_name "$(orphan_layer_base "$2")"' \
        _ "$root" "$base" 2>/dev/null
}

assert_eq "$(artifact_name 25.12.1)" "@overlay-25.12.1-gc-orphan" \
    "ac-1 base 25.12.1 derives its orphan layer from the version"
assert_eq "$(artifact_name 25.12.0)" "@overlay-25.12.0-gc-orphan" \
    "ac-1 base 25.12.0 derives a different layer for its own version"
assert_eq "$(artifact_name '@overlay-25.12.1')" "@overlay-25.12.1-gc-orphan" \
    "ac-1 the layer-name spelling of the same base derives the same layer"

orphan='@overlay-25.12.1-gc-orphan'
for shape in '^@overlay-[0-9]+\.[0-9]+\.[0-9]+$' '^@overlay-[0-9]+\.[0-9]+\.[0-9]+-test[0-9]+$' \
    '^@overlay-[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$'; do
    if [[ "$orphan" =~ $shape ]]; then collides=yes; else collides=no; fi
    assert_eq "$collides" "no" "ac-1 the orphan name is not a layer shape the product produces: $shape"
done
case "$orphan" in
    @overlay-?*-gc-orphan) in_namespace=yes ;;
    *) in_namespace=no ;;
esac
assert_eq "$in_namespace" "yes" \
    "ac-1 the orphan name stays inside the @overlay-* namespace every reader filters on"

# The fallback is gone from the code: a rename is what made the layer invisible, so the
# script may no longer contain one.
assert_eq "$(grep -c 'choosing a fresh orphan name' "$fixtures" || true)" "0" \
    "ac-2 the fixture no longer renames a colliding layer"
assert_eq "$(grep -c 'date -u +%Y%m%dT%H%M%SZ' "$fixtures" || true)" "0" \
    "ac-2 the fixture no longer invents a timestamped name outside the namespace"

# The workflow asks for the base the run builds and hands the derived name to the phase.
s5_text="$(cat "$workflow")"
assert_eq "$(printf '%s\n' "$s5_text" | grep -c 'orphan-layer @overlay-25' || true)" "0" \
    "ac-1 no step hardcodes an orphan layer name any more"
assert_contains "$s5_text" '--orphan-layer "${CI_UPSTREAM_VERSION}"' \
    "ac-1 the fixture asks for the base the run builds"
assert_contains "$s5_text" 'id: fixture1' \
    "ac-1 the fixture step publishes what it created"
assert_contains "$s5_text" '--orphan "${{ steps.fixture1.outputs.orphan_layer }}"' \
    "ac-5 the commit phase grades the layer the fixture named"

# --------------------------------------------------------------------------- #
# The directory tree the fixture and the phase are driven against
# --------------------------------------------------------------------------- #

mkdir -p "$tmp/bin" "$tmp/image-bin"
for dir in "$tmp/bin" "$tmp/image-bin"; do
    cat >"$dir/sudo" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
FAKE
    cat >"$dir/losetup" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
    --find) printf '/dev/loop0\n' ;;
esac
exit 0
FAKE
    # Mounts are no-ops: each script creates the mount points it uses itself, so the tree
    # the test prepared is the tree the script reads.
    cat >"$dir/mount" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    cat >"$dir/umount" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    cat >"$dir/udevadm" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    # One directory per subvolume, under $BTRFS_TREE. `list` prints the same line shape
    # btrfs does, because both readers parse `path <name>`.
    cat >"$dir/btrfs" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
tree="${BTRFS_TREE:?}"
log="${BTRFS_LOG:-/dev/null}"
case "${1:-}" in
    subvolume)
        case "${2:-}" in
            # The status is what the caller branches on: a trailing `exit 0` for the whole
            # stub would report every subvolume as present and turn every fixture into a
            # collision.
            show) if [ -d "${3:-}" ]; then exit 0; else exit 1; fi ;;
            create) mkdir -p "${3:-}" && printf 'create %s\n' "$(basename "${3:-}")" >>"${log}" ;;
            delete) printf 'delete %s\n' "$(basename "${4:-}")" >>"${log}"; rm -rf "${4:-}" ;;
            sync) : ;;
            list)
                for sub in "${tree}"/*/; do
                    [ -d "${sub}" ] || continue
                    printf 'ID 256 gen 10 top level 5 path %s\n' "$(basename "${sub}")"
                done
                ;;
        esac
        ;;
esac
exit 0
FAKE
    chmod +x "$dir"/*
done
mkdir -p "$tmp/empty-bin"
: >"$tmp/image"

# The fixture, byte-identical, next to a lib.sh that differs in exactly one place: the three
# helpers that prove a loop device carries an image, which a directory tree cannot have.
mkdir -p "$tmp/scripts"
cp "$fixtures" "$tmp/scripts/ab-fixtures.sh"
{
    cat "$root/scripts/ci/lib.sh"
    cat <<'SHIM'

# --- test shim ------------------------------------------------------------- #
# A build host has no loop device and no /sys/block entry for one. Everything else in this
# file is the shipped library, and the fixture under test is the shipped script.
ci_udev_settle() { return 0; }
ci_loop_matches() { return 0; }
ci_wait_block() { return 0; }
SHIM
} >"$tmp/scripts/lib.sh"
assert_eq "$(cmp -s "$fixtures" "$tmp/scripts/ab-fixtures.sh" && echo same)" "same" \
    "the fixture under test is the shipped script, not a copy with edits"

write_state() { # <esp-dir> <layer-a> <layer-b>
    mkdir -p "$1/ab"
    cat >"$1/ab/state.json" <<JSON
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.1", "upper": "$2" },
    "b": { "rootfs": "25.12.4", "upper": "$3" }
  }
}
JSON
}

fixture_case() { # <case-name> -> fixture directory
    local dir="$tmp/$1"
    mkdir -p "$dir/ci/ab-fixtures/p4" "$dir/ci/ab-fixtures/p1-ro/ab" "$dir/logs"
    : >"$dir/image"
    # An image built for this base: the live layer a hardcoded name collided with, plus the
    # subvolumes disk.sh ships next to it.
    for sub in @overlay-25.12.1 @docker @swap @data; do
        mkdir -p "$dir/ci/ab-fixtures/p4/$sub"
    done
    write_state "$dir/ci/ab-fixtures/p1-ro" '@overlay-25.12.1' '@overlay-25.12.1'
    printf '%s\n' "$dir"
}

run_fixture() { # <case-dir> [base]
    local dir=$1 base=${2:-25.12.1}
    CI_IMAGE="$dir/image" CI_TMP_ROOT="$dir/ci" CI_LOG_DIR="$dir/logs" \
        CI_OUTPUT_ENV="$dir/out.env" CI_UPSTREAM_VERSION="$base" CI_REPO_ROOT="$root" \
        BTRFS_TREE="$dir/ci/ab-fixtures/p4" BTRFS_LOG="$dir/btrfs.log" \
        PATH="$tmp/bin:$PATH" \
        bash "$tmp/scripts/ab-fixtures.sh" --orphan-layer "$base" 2>&1
}

# --- ac-1: base 25.12.1 still gets a layer of its own ----------------------
case1=$(fixture_case ac1-base-25121)
out="$(run_fixture "$case1")"
assert_contains "$out" "created unreferenced writable layer ${orphan}" \
    "ac-1 base 25.12.1 creates the derived layer instead of colliding with its live one"
assert_file_exists "$case1/ci/ab-fixtures/p4/${orphan}/upper/marker" \
    "ac-1 the created layer is a writable layer (it carries upper/)"
assert_eq "$(cat "$case1/ci/ab-fixtures/p4/${orphan}/upper/marker" 2>/dev/null)" "orphan" \
    "ac-1 the marker the fixture writes is inside the layer it named"
assert_eq "$(find "$case1/ci/ab-fixtures/p4" -maxdepth 1 -name 'orphan-*' | wc -l | tr -d ' ')" "0" \
    "ac-1 nothing outside the namespace is created"
assert_contains "$(cat "$case1/out.env")" "orphan_layer=${orphan}" \
    "ac-1 the fixture publishes the name it created for the phase"
assert_eq "$(ls "$case1/ci/ab-fixtures/p4" | sort | tr '\n' ' ')" \
    "@data @docker @overlay-25.12.1 ${orphan} @swap " \
    "ac-1 the image's own layers and subvolumes are untouched"

# base 25.12.0 must not be graded by the 25.12.1 name either: the name follows the base.
case0=$(fixture_case ac1-base-25120)
out="$(run_fixture "$case0" 25.12.0)"
assert_contains "$out" "created unreferenced writable layer @overlay-25.12.0-gc-orphan" \
    "ac-1 the name follows the base the run builds"

# --- ac-2: a collision is an error, never a rename -------------------------
case2=$(fixture_case ac2-collision)
mkdir -p "$case2/ci/ab-fixtures/p4/${orphan}/upper"
out="$(run_fixture "$case2")"
status=$?
assert_eq "$([ "$status" -ne 0 ] && echo failed || echo passed)" "failed" \
    "ac-2 a layer that already exists stops the fixture"
assert_contains "$out" "already exists on p4" \
    "ac-2 the failure names the collision"
assert_contains "$out" "not rename it" \
    "ac-2 the failure says why renaming is not the answer"
assert_eq "$(find "$case2/ci/ab-fixtures/p4" -maxdepth 1 -name 'orphan-*' | wc -l | tr -d ' ')" "0" \
    "ac-2 no fallback layer is created to get past the collision"
assert_eq "$(grep -c 'orphan_layer=' "$case2/out.env" 2>/dev/null || true)" "0" \
    "ac-2 a failed fixture publishes no layer for the phase to grade"

# --- ac-3: a layer a slot references is refused too ------------------------
case3=$(fixture_case ac3-referenced)
write_state "$case3/ci/ab-fixtures/p1-ro" "${orphan}" '@overlay-25.12.1'
out="$(run_fixture "$case3")"
status=$?
assert_eq "$([ "$status" -ne 0 ] && echo failed || echo passed)" "failed" \
    "ac-3 a name the state file references stops the fixture"
assert_contains "$out" "reclamation would have to keep it" \
    "ac-3 the failure explains that gc must keep a referenced layer"
assert_eq "$([ -d "$case3/ci/ab-fixtures/p4/${orphan}" ] && echo created || echo absent)" "absent" \
    "ac-3 nothing is created for a name the fixture refused"

# --------------------------------------------------------------------------- #
# ac-4: the shipped gc reclaims it
#
# ab-slot gc lists `path @overlay-*` and deletes what the state file does not name. Run
# against the tree the fixture produced, that is the proof that the new name is inside the
# set gc works on - and that the old fallback was not.
# --------------------------------------------------------------------------- #

gc_case=$(fixture_case ac4-gc)
run_fixture "$gc_case" >/dev/null
p4="$gc_case/ci/ab-fixtures/p4"
# The name the fixture used to fall back to, put next to the real layer: no reader in the
# pipeline looks at it, which is why it could survive every boot unnoticed.
mkdir -p "$p4/orphan-4614-20261116T172645Z/upper"

gc_esp="$gc_case/esp"
mkdir -p "$gc_esp/ab"
cp "$gc_case/ci/ab-fixtures/p1-ro/ab/state.json" "$gc_esp/ab/state.json"
: >"$gc_case/mounts"
gc_env() {
    AB_ESP="$gc_esp" AB_P4="$p4" AB_CMD=/dev/null AB_MOUNTS="$gc_case/mounts" \
        AB_SLOT_CFG_LIB="$root/platform/lib/ab-slot-cfg.sh" \
        AB_PARTITIONS_LIB="$root/platform/lib/ab-partitions.sh" \
        BTRFS_TREE="$p4" BTRFS_LOG="$gc_case/gc.log" \
        PATH="$tmp/bin:$PATH" sh "$ab_slot" "$@"
}
out="$(gc_env gc 2>&1)"
assert_eq "$([ "$?" -eq 0 ] && echo ok || echo failed)" "ok" \
    "ac-4 gc succeeds against the tree the fixture produced"
assert_contains "$out" "deleting ${orphan}" \
    "ac-4 gc deletes the layer the fixture created"
assert_eq "$([ -d "$p4/${orphan}" ] && echo present || echo gone)" "gone" \
    "ac-4 the unreferenced layer is off the writable partition"
assert_eq "$([ -d "$p4/@overlay-25.12.1" ] && echo present || echo gone)" "present" \
    "ac-4 the layer a slot references is kept"
assert_eq "$([ -d "$p4/orphan-4614-20261116T172645Z" ] && echo present || echo gone)" "present" \
    "ac-4 a name outside @overlay-* is never even a candidate: that is why the fixture may not use one"

# --------------------------------------------------------------------------- #
# ac-5: the commit phase sees the layer
#
# The phase is driven from a directory tree with the same no-op mounts, and the boot logs
# come from the ring: boot-0.log is the graded boot, boot-1/2 the boots before it. The boot
# that reclaims the fixture's layer is not necessarily the one being graded, which is why
# the count is read across the ring instead of from boot-0.log alone.
# --------------------------------------------------------------------------- #

phase_case() { # <case-name> -> phase directory
    local dir="$tmp/$1"
    mkdir -p "$dir/ci/s5-phase/esp/ab/log" "$dir/ci/s5-phase/p4" "$dir/logs"
    : >"$dir/image"
    for sub in @overlay-25.12.1 @overlay-25.12.1-test1 @docker @swap @data; do
        mkdir -p "$dir/ci/s5-phase/p4/$sub"
    done
    write_state "$dir/ci/s5-phase/esp" '@overlay-25.12.1' '@overlay-25.12.1-test1'
    printf 'conflicts=1\nbaseline=ok\n' >"$dir/ci/s5-phase/esp/ab/conflicts.log"
    printf 'ab-commit: committed slot=b upper=@overlay-25.12.1-test1\n' >"$dir/serial.log"
    # boot-2.log is the first boot: the fixture's layer is what gc removed there.
    printf 'stage=gc slot=a result=ok reclaimed=1\n' >"$dir/ci/s5-phase/esp/ab/log/boot-2.log"
    printf 'stage=gc slot=b result=ok reclaimed=0\n' >"$dir/ci/s5-phase/esp/ab/log/boot-0.log"
    printf 'stage=commit slot=b upper=@overlay-25.12.1-test1 rootfs=25.12.4 result=ok action=commit\n' \
        >>"$dir/ci/s5-phase/esp/ab/log/boot-0.log"
    printf '%s\n' "$dir"
}

run_phase() { # <case-dir> [extra args...]
    local dir=$1
    shift
    CI_IMAGE="$dir/image" CI_TMP_ROOT="$dir/ci" CI_LOG_DIR="$dir/logs" \
        CI_S5_PART_WAIT_ATTEMPTS=0 BTRFS_TREE="$dir/ci/s5-phase/p4" \
        BTRFS_LOG="$dir/phase-btrfs.log" PATH="$tmp/bin:$PATH" \
        bash "$phase" --phase commit --slot b --serial "$dir/serial.log" "$@" 2>&1
}

# --- ac-5: the honest run passes, and reports the reclaim the ring shows ---
good=$(phase_case ac5-good)
out="$(run_phase "$good" --orphan "$orphan")"
assert_contains "$out" "S5-RESULT=ok upgrade=b conflicts=1 reclaimed=1" \
    "ac-5 the phase counts the reclaim the earlier boot logged"
assert_contains "$out" "early reclamation removed 1 layer(s) across the log ring" \
    "ac-5 the report says where the count came from"

# --- ac-5: the layer is the assertion's subject ---------------------------
left=$(phase_case ac5-orphan-left)
mkdir -p "$left/ci/s5-phase/p4/${orphan}/upper"
out="$(run_phase "$left" --orphan "$orphan")"
assert_contains "$out" "S5-RESULT=fail reason=orphan-layer-left" \
    "ac-5 a layer that survived reclamation fails the phase"
assert_contains "$out" "is still on p4 after reclamation" \
    "ac-5 the failure names the layer"

# --- ac-5: the old fallback name is visible now ----------------------------
#
# This is the shape of the run the fix is about: the fixture created a layer gc never
# listed, so nothing was reclaimed and the leftover scan (which only looked at @overlay-*)
# had nothing to say either. Both files changed; the leftover is visible here.
fallback=$(phase_case ac5-fallback-left)
mkdir -p "$fallback/ci/s5-phase/p4/orphan-4614-20261116T172645Z/upper"
out="$(run_phase "$fallback" --orphan "$orphan")"
assert_contains "$out" "S5-RESULT=fail reason=unreferenced-layer-left" \
    "ac-5 a leftover outside @overlay-* is reported instead of ignored"
assert_contains "$out" "orphan-4614-20261116T172645Z" \
    "ac-5 the report names the leftover"

# --- ac-5: nothing reclaimed anywhere is a failure, not a green zero ------
idle=$(phase_case ac5-nothing-reclaimed)
printf 'stage=gc slot=b result=ok reclaimed=0\n' >"$idle/ci/s5-phase/esp/ab/log/boot-2.log"
printf 'stage=gc slot=b result=ok reclaimed=0\n' >>"$idle/ci/s5-phase/esp/ab/log/boot-0.log"
out="$(run_phase "$idle" --orphan "$orphan")"
assert_contains "$out" "S5-RESULT=fail reason=reclaim-not-exercised" \
    "ac-5 a run that reclaimed nothing no longer grades ok"
assert_contains "$out" "created ${orphan} for reclamation to remove" \
    "ac-5 the failure says what the fixture had created"

# --- ac-5: a referenced orphan is a fixture defect, not a product verdict --
referenced=$(phase_case ac5-referenced)
write_state "$referenced/ci/s5-phase/esp" "$orphan" '@overlay-25.12.1-test1'
out="$(run_phase "$referenced" --orphan "$orphan")"
assert_contains "$out" "S5-RESULT=fail reason=orphan-layer-referenced" \
    "ac-5 a layer the state file names is not an unreferenced layer"

# --- ac-5: a name outside the namespace is refused before anything is read -
out="$(run_phase "$good" --orphan 'orphan-4614-20261116T172645Z')"
assert_contains "$out" "--orphan must be a layer in the @overlay-* namespace" \
    "ac-5 the phase refuses a subject gc could never reclaim"

finish
