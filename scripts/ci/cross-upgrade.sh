#!/usr/bin/env bash
# Stage "cross-upgrade": install this release's payload over the previous release's image.
#
# Every other stage proves something about one release. This one proves the seam between
# two: an image built from release N-1, upgraded with the payload of release N, has to
# boot, commit and agree with the payload it was given. It is the only evidence that the
# update prompt's "patch ranges are covered in CI" is a statement about upgrades and not
# about builds.
#
# The stage is split on purpose, because the expensive half cannot run on a laptop:
#
#   run     boot the image under QEMU, install the payload, copy the facts out
#   assert  grade a directory of facts (status lines, digests, serial log)
#
# `assert` is what the test suite exercises; `run` is what CI executes.
#
# Facts the grader reads from <out>:
#   status.before          `ab-slot status` before the install
#   status.after           `ab-slot status` after the install
#   status.committed       `ab-slot status` after the reboot that commits the slot
#   esp.sha256             `sha256sum` of vmlinuz-<slot> and initrd-<slot> on the ESP
#   payload.sha256         `sha256sum` of kernel.bin and initramfs.cpio.gz in the payload
#   serial.log             the guest's serial output
#   skip                   present when there was no previous release to upgrade from
#
# Output: `cross-upgrade=ok|fail|skipped` plus `reason=` and the fields that disagreed.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

CI_MIN_UPSTREAM_MAJOR="${CI_MIN_UPSTREAM_MAJOR:-25}"

usage() {
    cat <<'USAGE'
usage: cross-upgrade.sh <subcommand>

  run     --image <old.img> --payload <new.tar> --out <dir> [--inject unhealthy]
  assert  --out <dir>
  parse   --serial <file> --out <dir>    split the status blocks out of a saved serial log
USAGE
}

# field <file> <name>: one `name=value` token from a status line.
field() {
    [ -f "$1" ] || return 1
    sed -n "s/.*[[:space:]]$2=\([^[:space:]]*\).*/\1/p" "$1" | head -n 1
}

# grade <out>: the whole verdict, from files only.
grade() {
    _out="$1"
    _fail=""
    if [ -f "${_out}/skip" ]; then
        printf 'cross-upgrade=skipped reason=%s\n' "$(cat "${_out}/skip")"
        return 0
    fi

    # An injected failure has the opposite expectation: the candidate must be abandoned
    # and the machine must come back to the slot it was on. Grading it with the success
    # rules would call the healthy outcome a failure.
    if [ -f "${_out}/inject" ]; then
        grep -q 'stage=abandon .*action=reboot-to-committed' "${_out}/serial.log" 2>/dev/null ||
            _fail="abandon-not-recorded"
        if [ -z "${_fail}" ]; then
            [ "$(field "${_out}/status.committed" pending)" = "none" ] || _fail="pending-not-cleared"
            [ "$(field "${_out}/status.committed" committed)" = "$(field "${_out}/status.before" committed)" ] ||
                _fail="did-not-return-to-the-previous-slot"
        fi
        if [ -n "${_fail}" ]; then
            printf 'cross-upgrade=fail reason=%s\n' "${_fail}"
            return 0
        fi
        printf 'cross-upgrade=ok inject=%s returned=%s\n' "$(cat "${_out}/inject")" \
            "$(field "${_out}/status.committed" committed)"
        return 0
    fi

    _pending=$(field "${_out}/status.after" pending)
    _committed=$(field "${_out}/status.after" committed)
    _next=$(field "${_out}/status.after" next)
    [ -n "${_pending}" ] || _fail="status-after-missing"
    [ -z "${_fail}" ] && [ "${_pending}" != "none" ] || _fail=${_fail:-pending-already-none}
    [ -z "${_fail}" ] && [ "${_next}" = "${_pending}" ] || _fail=${_fail:-next-does-not-point-at-the-candidate}
    [ -z "${_fail}" ] && [ "${_committed}" != "${_pending}" ] || _fail=${_fail:-candidate-already-committed}

    _gen_after=$(field "${_out}/status.after" generation)
    _gen_done=$(field "${_out}/status.committed" generation)
    if [ -z "${_fail}" ]; then
        [ "$(field "${_out}/status.committed" pending)" = "none" ] ||
            _fail="pending-not-cleared-after-commit"
        [ "$(field "${_out}/status.committed" committed)" = "${_pending}" ] ||
            _fail="candidate-not-committed"
        case "${_gen_done}" in
            '' | *[!0-9]*) _fail="generation-unreadable" ;;
            *) [ "${_gen_done}" -gt "${_gen_after:-0}" ] || _fail="generation-did-not-advance" ;;
        esac
        [ "$(field "${_out}/status.committed" packages)" = "aligned" ] ||
            _fail="packages-not-aligned-after-commit"
    fi

    if [ -z "${_fail}" ]; then
        [ -s "${_out}/esp.sha256" ] || _fail="esp-digests-missing"
        [ -s "${_out}/payload.sha256" ] || _fail="payload-digests-missing"
        if [ -z "${_fail}" ]; then
            # Compare by name, not by position: the payload and the ESP name the same
            # two members differently (kernel.bin vs vmlinuz-<slot>).
            _kernel_esp=$(awk '$2 ~ /vmlinuz/ { print $1 }' "${_out}/esp.sha256")
            _kernel_pay=$(awk '$2 ~ /kernel\.bin/ { print $1 }' "${_out}/payload.sha256")
            _initrd_esp=$(awk '$2 ~ /initrd/ { print $1 }' "${_out}/esp.sha256")
            _initrd_pay=$(awk '$2 ~ /initramfs/ { print $1 }' "${_out}/payload.sha256")
            if [ -z "${_kernel_esp}" ] || [ "${_kernel_esp}" != "${_kernel_pay}" ]; then
                _fail="kernel-on-esp-is-not-the-payload-kernel"
            elif [ -z "${_initrd_esp}" ] || [ "${_initrd_esp}" != "${_initrd_pay}" ]; then
                _fail="initrd-on-esp-is-not-the-payload-initrd"
            fi
        fi
    fi

    if [ -z "${_fail}" ]; then
        grep -q 'stage=commit .*result=ok' "${_out}/serial.log" 2>/dev/null ||
            _fail="commit-not-recorded-in-serial"
    fi

    if [ -n "${_fail}" ]; then
        printf 'cross-upgrade=fail reason=%s\n' "${_fail}"
        return 0
    fi
    printf 'cross-upgrade=ok slot=%s generation=%s\n' "${_pending}" "${_gen_done:-0}"
}

# --------------------------------------------------------------------------- #
# The guest half. It runs in CI, on Linux, with sudo and loop devices; on a laptop it
# says so instead of pretending.
#
# The hook is this stage's own, not ab-fixtures': the three status blocks it prints are
# exactly the facts `assert` reads, and a shared fixture would have to grow options for
# a stage that is not S5.
# --------------------------------------------------------------------------- #

cross_prepare() {
    _image=$1 _payload=$2 _work=$3
    _loop=$(sudo losetup --find --show --partscan "${_image}") || return 1
    _p4="${_loop}p4"
    _mnt="${_work}/p4"
    sudo mkdir -p "${_mnt}"
    sudo mount "${_p4}" "${_mnt}" || { sudo losetup -d "${_loop}"; return 1; }
    _layer=""
    for _cand in "${_mnt}"/@overlay-*; do
        [ -d "${_cand}" ] || continue
        _layer="${_cand##*/}"
        break
    done
    if [ -z "${_layer}" ]; then
        sudo umount "${_mnt}"; sudo losetup -d "${_loop}"
        return 1
    fi
    _upper="${_mnt}/${_layer}/upper"
    sudo mkdir -p "${_upper}/etc"
    sudo cp "${_payload}" "${_upper}/payload.tar"
    sudo tee "${_upper}/etc/rc.local" >/dev/null <<'RCLOCAL'
#!/bin/sh
# Cross-version fixture. The first boot prints the status, installs the payload and prints
# it again with the candidate pending; the second boot prints it once more after the
# commit. Every status line is announced, so the grader never has to guess which boot it
# is looking at. The hook removes itself, so a third boot says nothing.
rm -f /etc/rc.local
if [ -f /payload.tar ]; then
  echo "CROSS-STATUS-BEFORE" >/dev/console
  ab-slot status >/dev/console 2>&1
  echo "CROSS-INSTALL" >/dev/console
  ab-upgrade /payload.tar >/dev/console 2>&1
  echo "ab-upgrade: exit=$?" >/dev/console
  echo "CROSS-STATUS-PENDING" >/dev/console
  ab-slot status >/dev/console 2>&1
  rm -f /payload.tar
else
  echo "CROSS-STATUS-COMMITTED" >/dev/console
  ab-slot status >/dev/console 2>&1
fi
echo "CROSS-STATUS-DONE" >/dev/console
exit 0
RCLOCAL'
#!/bin/sh
# Cross-version fixture. Prints the status line three times - before the install, with
# the candidate pending, and on the next boot after the commit - and removes itself so a
# later boot does not repeat any of it.
echo "CROSS-STATUS-BEFORE" >/dev/console
ab-slot status >/dev/console 2>&1
if [ -f /payload.tar ]; then
  echo "CROSS-INSTALL" >/dev/console
  ab-upgrade /payload.tar >/dev/console 2>&1
  echo "ab-upgrade: exit=$?" >/dev/console
  echo "CROSS-STATUS-PENDING" >/dev/console
  ab-slot status >/dev/console 2>&1
  rm -f /payload.tar
fi
echo "CROSS-STATUS-DONE" >/dev/console
rm -f /etc/rc.local
exit 0
RCLOCAL
    sudo chmod 0755 "${_upper}/etc/rc.local"
    sudo sync
    sudo umount "${_mnt}"
    sudo losetup -d "${_loop}"
}

# extract_blocks <serial> <out>: split the three status blocks out of the serial log.
extract_blocks() {
    _serial=$1 _out=$2
    awk -v out="${_out}" '
        /CROSS-STATUS-BEFORE/ { w = "before"; next }
        /CROSS-STATUS-PENDING/ { w = "after"; next }
        /CROSS-STATUS-COMMITTED/ { w = "committed"; next }
        /CROSS-INSTALL/ { w = ""; next }
        w != "" && /^slot=/ { print > (out "/status." w); w = "" }
    ' "${_serial}"
}

# esp_digests <image> <out>: the kernel and initrd actually written to the ESP.
esp_digests() {
    _image=$1 _out=$2
    _loop=$(sudo losetup --find --show --partscan "${_image}") || return 1
    _mnt=$(mktemp -d)
    sudo mount "${_loop}p1" "${_mnt}" || { sudo losetup -d "${_loop}"; return 1; }
    ( cd "${_mnt}" && sha256sum vmlinuz-* initrd-* 2>/dev/null ) >"${_out}"
    sudo umount "${_mnt}"
    sudo losetup -d "${_loop}"
    rmdir "${_mnt}" 2>/dev/null || :
}

payload_digests() {
    _payload=$1 _out=$2
    _dir=$(mktemp -d)
    tar -xf "${_payload}" -C "${_dir}" kernel.bin initramfs.cpio.gz 2>/dev/null || return 1
    ( cd "${_dir}" && sha256sum kernel.bin initramfs.cpio.gz ) >"${_out}"
    rm -rf "${_dir}"
}

run_stage() {
    _image=${1:?--image is required}
    _payload=${2:?--payload is required}
    _out=${3:?--out is required}
    _inject=${4:-}
    mkdir -p "${_out}"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        printf 'cross-upgrade: skipped reason=qemu-not-available\n'
        return 0
    fi
    command -v losetup >/dev/null 2>&1 || {
        printf 'cross-upgrade: skipped reason=loop-devices-not-available\n'
        return 0
    }

    _work="${CI_TMP_ROOT:-/tmp}/cross-upgrade"
    mkdir -p "${_work}"
    cp "${_image}" "${_work}/old.img"
    cross_prepare "${_work}/old.img" "${_payload}" "${_work}" || {
        printf 'cross-upgrade=fail reason=cannot-prepare-the-old-image\n'
        return 0
    }

    # Boot 1 installs and prints the pending status; boot 2 commits and prints the third.
    CI_QEMU_MODE="uefi-disk" CI_QEMU_DISK="${_work}/old.img" CI_JUDGE_PREFIX="" \
        CI_QEMU_STOP_PATTERN='CROSS-STATUS-DONE' CI_QEMU_TIMEOUT="${CI_QEMU_TIMEOUT:-900}" \
        CI_QEMU_CASE="cross-boot1" \
        bash "${CI_SCRIPT_DIR}/qemu-smoke.sh" >"${_out}/serial.log" 2>&1 || true
    CI_QEMU_MODE="uefi-disk" CI_QEMU_DISK="${_work}/old.img" CI_JUDGE_PREFIX="" \
        CI_QEMU_STOP_PATTERN='CROSS-STATUS-DONE' CI_QEMU_TIMEOUT="${CI_QEMU_TIMEOUT:-900}" \
        CI_QEMU_CASE="cross-boot2" \
        bash "${CI_SCRIPT_DIR}/qemu-smoke.sh" >>"${_out}/serial.log" 2>&1 || true

    extract_blocks "${_out}/serial.log" "${_out}"
    esp_digests "${_work}/old.img" "${_out}/esp.sha256" || :
    payload_digests "${_payload}" "${_out}/payload.sha256" || :
    [ -n "${_inject}" ] && [ "${_inject}" != "none" ] && printf '%s\n' "${_inject}" >"${_out}/inject"
    grade "${_out}"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "${cmd}" in
    run)
        image="" payload="" out="" inject=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --image) image=${2:?--image needs a value}; shift 2 ;;
                --payload) payload=${2:?--payload needs a value}; shift 2 ;;
                --out) out=${2:?--out needs a value}; shift 2 ;;
                --inject) inject=${2:?--inject needs a value}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        run_stage "${image}" "${payload}" "${out}" "${inject}"
        ;;
    assert)
        out=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --out) out=${2:?--out needs a value}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        [ -n "${out}" ] || ci_die "--out is required"
        grade "${out}"
        ;;
    parse)
        serial="" out=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --serial) serial=${2:?--serial needs a value}; shift 2 ;;
                --out) out=${2:?--out needs a value}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        [ -n "${serial}" ] && [ -n "${out}" ] || ci_die "--serial and --out are required"
        mkdir -p "${out}"
        extract_blocks "${serial}" "${out}"
        ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
esac
