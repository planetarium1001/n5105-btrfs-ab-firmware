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
#   serial.log             the guest's serial output, both boots appended in boot order
#   skip                   present when there was no previous release to upgrade from
#   expect.same-base       present when the run also has to prove the two releases share a
#                          base and a kernel (same-base gate, `--expect-same-base`)
#   facts/                 the files release-same-base.sh judge grades when it is set:
#                          old-index.txt, old-SHA256SUMS, new-version, new-pin, new-manifest.json
#
# Output: `cross-upgrade=ok|fail|skipped` plus `reason=` and the fields that disagreed.
# With --expect-same-base the verdict is additionally gated on `same-base=ok`, and the
# per-criterion lines are printed above it.

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"

CI_MIN_UPSTREAM_MAJOR="${CI_MIN_UPSTREAM_MAJOR:-25}"

usage() {
    cat <<'USAGE'
usage: cross-upgrade.sh <subcommand>

  run     --image <old.img|old.img.gz> --payload <new.tar> --out <dir> [--inject unhealthy]
          [--expect-same-base] [--facts <dir>]
  assert  --out <dir> [--expect-same-base] [--facts <dir>]
  parse   --serial <file> --out <dir>    split the status blocks out of a saved serial log
  stage-image --src <file> --dest <file> write the image as a plain disk image (a .gz is
                                         decompressed, anything else is copied)
  stage-boot-files --esp <dir> --dest <dir> copy an ESP's vmlinuz-* and initrd-* into a
                                         staging directory as kernel.bin and initrd.cpio.gz
USAGE
}

# field <file> <name>: one `name=value` token from a status line.
# field <file> <name>: one value out of a status block. A missing file is an empty value,
# not a failure: grade() reads four of these in a row, and under `set -e` a non-zero field
# ended the whole stage before it could say what was missing (run 43588155580 printed no
# verdict at all, and the run page only knew that the step had failed).
field() {
    if [ ! -f "$1" ]; then
        return 0
    fi
    sed -n "s/.*[[:space:]]$2=\([^[:space:]]*\).*/\1/p" "$1" | head -n 1
}

# same_base_check <out> [payload]: the same-base gate, on top of the cross verdict.
#
# `cross` answers "can this release install over the previous one". It does not say whether
# the two share a base and a kernel, which is what the update prompt's "patch ranges are
# covered" sentence means - grade() never reads a base or a kernel. When the caller asks for
# the same-base gate the criteria live in one place, scripts/ci/release-same-base.sh, and
# this function only forwards the facts and refuses to call a skip or a crash a pass.
#
# Returns 0 when every criterion passed, 1 otherwise; prints the per-criterion lines and one
# `same-base=` verdict either way, so a red gate names the fact that disagreed.
same_base_check() {
    local _out=$1 _payload=${2:-} _facts _sb_out
    _facts="${_out}/facts"
    if [ ! -d "${_facts}" ]; then
        printf 'same-base=fail reason=facts-missing\n'
        return 1
    fi
    if _sb_out="$(bash "${CI_SCRIPT_DIR}/release-same-base.sh" judge --dir "${_facts}" \
        ${_payload:+--new-payload "${_payload}"} 2>&1)"; then
        :
    else
        printf '%s\n' "${_sb_out}"
        printf 'same-base=fail reason=judge-crashed\n'
        return 1
    fi
    printf '%s\n' "${_sb_out}"
    case "${_sb_out}" in
        *"same-base=ok"*) return 0 ;;
        *) return 1 ;;
    esac
}

# grade <out> [payload]: the whole verdict, from files only.
grade() {
    _out="$1"
    _grade_payload=${2:-}
    _fail=""
    if [ -f "${_out}/skip" ]; then
        # A skipped stage graded as skipped is the honest answer for the cross gate, and the
        # caller decides what to do with it. With --expect-same-base it is not: the caller
        # asked this run to prove a same-base upgrade, and a stage that could not run proved
        # nothing - "cannot judge" is a failure of the gate, not a third outcome.
        if [ -f "${_out}/expect.same-base" ]; then
            printf 'same-base=fail reason=stage-skipped\n'
            printf 'cross-upgrade=fail reason=stage-skipped detail=%s\n' "$(cat "${_out}/skip")"
            return 0
        fi
        printf 'cross-upgrade=skipped reason=%s\n' "$(cat "${_out}/skip")"
        return 0
    fi

    # An injected failure has the opposite expectation: the candidate must be abandoned
    # and the machine must come back to the slot it was on. Grading it with the success
    # rules would call the healthy outcome a failure.
    if [ -f "${_out}/inject" ]; then
        grep -Eq 'stage=abandon .*action=reboot-to-committed|ab-commit: abandoned slot=' "${_out}/serial.log" 2>/dev/null ||
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

    _gen_before=$(field "${_out}/status.before" generation)
    _gen_after=$(field "${_out}/status.after" generation)
    _gen_done=$(field "${_out}/status.committed" generation)
    if [ -z "${_fail}" ]; then
        [ "$(field "${_out}/status.committed" pending)" = "none" ] ||
            _fail="pending-not-cleared-after-commit"
        [ "$(field "${_out}/status.committed" committed)" = "${_pending}" ] ||
            _fail="candidate-not-committed"
        # The install bumps the generation (it writes the pending candidate); the commit
        # keeps it. Measured on 0.0.10-rc4: before=1, after install=2, after commit=2. So the
        # invariants are "the transaction advanced past the starting generation" and "the
        # committed state did not move backwards", not "the commit bumps generation".
        case "${_gen_done}" in
            '' | *[!0-9]*) _fail="generation-unreadable" ;;
            *)
                case "${_gen_before}" in
                    '' | *[!0-9]*) _fail="generation-unreadable" ;;
                    *) [ "${_gen_done}" -gt "${_gen_before}" ] || _fail="generation-did-not-advance" ;;
                esac
                [ -n "${_fail}" ] || [ "${_gen_done}" -ge "${_gen_after:-0}" ] ||
                    _fail="generation-moved-backwards"
                ;;
        esac
        [ "$(field "${_out}/status.committed" packages)" = "aligned" ] ||
            _fail="packages-not-aligned-after-commit"
    fi

    if [ -z "${_fail}" ]; then
        [ -s "${_out}/esp.sha256" ] || _fail="esp-digests-missing"
        [ -s "${_out}/payload.sha256" ] || _fail="payload-digests-missing"
        if [ -z "${_fail}" ]; then
            # Compare by name, not by position: the payload and the ESP name the same
            # two members differently (kernel.bin vs vmlinuz-<slot>). The ESP carries the
            # boot files of both slots; only the committed slot's pair is comparable with
            # the payload, and a bare /vmlinuz/ match would concatenate both digests.
            _slot_done=$(field "${_out}/status.committed" committed)
            _kernel_esp=$(awk -v slot="${_slot_done}" '$2 == "vmlinuz-" slot { print $1 }' "${_out}/esp.sha256")
            _kernel_pay=$(awk '$2 ~ /kernel\.bin/ { print $1 }' "${_out}/payload.sha256")
            _initrd_esp=$(awk -v slot="${_slot_done}" '$2 == "initrd-" slot { print $1 }' "${_out}/esp.sha256")
            _initrd_pay=$(awk '$2 ~ /initramfs/ { print $1 }' "${_out}/payload.sha256")
            if [ -z "${_kernel_esp}" ] || [ "${_kernel_esp}" != "${_kernel_pay}" ]; then
                _fail="kernel-on-esp-is-not-the-payload-kernel"
            elif [ -z "${_initrd_esp}" ] || [ "${_initrd_esp}" != "${_initrd_pay}" ]; then
                _fail="initrd-on-esp-is-not-the-payload-initrd"
            fi
        fi
    fi

    if [ -z "${_fail}" ]; then
        grep -Eq 'stage=commit .*result=ok|ab-commit: committed slot=' "${_out}/serial.log" 2>/dev/null ||
            _fail="commit-not-recorded-in-serial"
    fi

    if [ -n "${_fail}" ]; then
        printf 'cross-upgrade=fail reason=%s\n' "${_fail}"
        return 0
    fi
    # The same-base criteria are graded after the cross ones, and only ever add a failure:
    # a run whose base or kernel moved is a cross upgrade that is not a same-base one, and
    # with --expect-same-base the caller asked for the stronger claim.
    if [ -f "${_out}/expect.same-base" ]; then
        if same_base_check "${_out}" "${_grade_payload}"; then
            :
        else
            printf 'cross-upgrade=fail reason=same-base-criteria-failed\n'
            return 0
        fi
    fi
    printf 'cross-upgrade=ok slot=%s generation=%s\n' "${_pending}" "${_gen_done:-0}"
}

# --------------------------------------------------------------------------- #
# The guest half. It runs in CI, on Linux, with sudo and loop devices; on a laptop it
# says so instead of pretending.
#
# The hook is this stage's own, not ab-fixtures': the three status blocks it prints are
# exactly the facts `assert` reads, and a shared fixture would have to grow options for
# a stage that is not S5. The network fixture beside it is the one thing the stage does
# borrow: the candidate's health check needs a WAN the single-NIC boot would not have.
# --------------------------------------------------------------------------- #

# cross_fixture_install_cmd <same-base>: the one line the fixture runs to install the payload.
#
# The same-base gate boots the PREVIOUS release's published image, and that image carries the
# ab-upgrade of its own release. Two releases on one base share their rootfs version exactly, so
# the older release's "already installed" guard - which knew only the base - refused the newer
# payload with 74 and the gate went red for a reason that has nothing to do with the thing the
# gate proves. `--force` is the honest flag there: the gate asks "can this machine take this
# release", not "does the old guard let it".
#
# The cross gate keeps the bare command. Its old image runs a different base (measured 25.12.1
# against 25.12.2), the guard never fires, and leaving it alone keeps the stronger claim that a
# payload installs without any escape hatch.
cross_fixture_install_cmd() {
    if [ "${1:-}" = "1" ]; then
        printf 'ab-upgrade --force /payload.tar'
    else
        printf 'ab-upgrade /payload.tar'
    fi
}

# cross_fixture_rc_local <same-base>: the fixture script, printed. Pure: no loop device, no
# mount, no root - which is what lets a test assert the install line of both modes.
cross_fixture_rc_local() {
    _install_cmd=$(cross_fixture_install_cmd "${1:-}")
    cat <<RCLOCAL
#!/bin/sh
# Cross-version fixture. Three boots are involved:
#   boot 1  /payload.tar is present, no install marker exists: install once, print the
#           status BEFORE and after staging, then DONE (the caller stops here).
#   boot 2  the candidate first boot. The snapshot carried /payload.tar and this hook into
#           the candidate's writable layer, but /boot/cross-fixture-installed lives on the
#           shared ESP and says the install already happened, so this hook is a no-op.
#           ab-commit commits at S99 and the caller stops on its console line.
#   boot 3  the committed slot: the state is settled (pending=none, slot==committed), so
#           this hook prints the post-commit status the grader reads, then disarms itself.
# Printing the committed status from boot 2 would describe a state ab-commit has not
# produced yet: rc.local is S95 and ab-commit is S99.
if [ -f /payload.tar ] && [ ! -f /boot/cross-fixture-installed ]; then
  : >/boot/cross-fixture-installed
  echo "CROSS-STATUS-BEFORE" >/dev/console
  ab-slot status >/dev/console 2>&1
  echo "CROSS-INSTALL" >/dev/console
  ${_install_cmd} >/dev/console 2>&1
  echo "ab-upgrade: exit=\$?" >/dev/console
  echo "CROSS-STATUS-PENDING" >/dev/console
  ab-slot status >/dev/console 2>&1
  rm -f /payload.tar
  echo "CROSS-STATUS-DONE" >/dev/console
else
  [ -f /boot/cross-fixture-installed ] || exit 0
  line="\$(ab-slot status 2>/dev/null | sed -n '1p')"
  case "\${line}" in
    *" pending=none "*) : ;;
    *) exit 0 ;;
  esac
  slot=""
  committed=""
  for field in \${line}; do
    case "\${field}" in
      slot=*) slot="\${field#slot=}" ;;
      committed=*) committed="\${field#committed=}" ;;
    esac
  done
  [ -n "\${slot}" ] && [ "\${slot}" = "\${committed}" ] || exit 0
  echo "CROSS-STATUS-COMMITTED" >/dev/console
  ab-slot status >/dev/console 2>&1
  echo "CROSS-STATUS-DONE" >/dev/console
  rm -f /boot/cross-fixture-installed /etc/rc.local
fi
exit 0
RCLOCAL
}

cross_prepare() {
    _image=$1 _payload=$2 _work=$3 _same_base=${4:-}
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
    cross_fixture_rc_local "${_same_base}" | sudo tee "${_upper}/etc/rc.local" >/dev/null
    sudo chmod 0755 "${_upper}/etc/rc.local"

    # The candidate boots with one virtio NIC. net-seed reads a machine with a single
    # ethernet port as "LAN only", writes a static br-lan and no wan section at all, and
    # ab-commit's wan-present probe then fails with no-wan-device-in-uci: boot 2 of tag
    # run 43622253559 printed "ab-commit: abandoned slot=b reason=healthcheck-failed" for
    # exactly that. A minimal network file in the same writable layer closes the gap
    # without a second NIC, because net-seed only generates a configuration when
    # /etc/config/network is absent, and the probe then has a wan to find. The shape is
    # the one the ab stage writes into its image for S5 - loopback plus wan on eth0 - so
    # the two stages do not grow two answers to what a single-NIC machine looks like.
    sudo mkdir -p "${_upper}/etc/config"
    sudo tee "${_upper}/etc/config/network" >/dev/null <<'NETWORK'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
NETWORK

    sudo sync
    sudo umount "${_mnt}"
    sudo losetup -d "${_loop}"
}

# cross_stage_image <src> <dest>: the image a caller handed over, as a plain disk image.
#
# The artifacts are published compressed and named `*.img.gz`, and a caller that finds the
# image by that name used to hand the gzip bytes straight to losetup: it answered "file does
# not fit into a 512-byte sector" and then a partition that does not exist, which names the
# sector size instead of the compression (run 43570531757). Staging the file here makes every
# caller work the same way, and a torn archive says so instead of becoming a loop-device error
# three lines later.
cross_stage_image() {
    _src=$1 _dest=$2
    case "${_src}" in
        *.gz)
            gzip -dc "${_src}" >"${_dest}" 2>/dev/null || {
                rm -f "${_dest}"
                printf 'cross-upgrade=fail reason=cannot-decompress-the-image src=%s\n' "${_src##*/}"
                return 1
            }
            ;;
        *)
            cp "${_src}" "${_dest}" || {
                rm -f "${_dest}"
                printf 'cross-upgrade=fail reason=cannot-copy-the-image src=%s\n' "${_src##*/}"
                return 1
            }
            ;;
    esac
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

# esp_stage_boot_files <esp-dir> <dest-dir>: the boot files an already-mounted ESP carries.
#
# Kept apart from the mount below so the selection is reachable without a loop device: a test
# hands it a directory. It stages the first vmlinuz-* as kernel.bin and the first initrd-* as
# initrd.cpio.gz, and stages nothing when the tree carries no such pair.
esp_stage_boot_files() {
    local _esp=$1 _dest=$2 _cand _kernel="" _initrd=""
    for _cand in "${_esp}"/vmlinuz-*; do
        [ -f "${_cand}" ] || continue
        _kernel=${_cand}
        break
    done
    for _cand in "${_esp}"/initrd-*; do
        [ -f "${_cand}" ] || continue
        _initrd=${_cand}
        break
    done
    [ -n "${_kernel}" ] && [ -n "${_initrd}" ] || return 1
    mkdir -p "${_dest}" || return 1
    cp "${_kernel}" "${_dest}/kernel.bin" 2>/dev/null &&
        cp "${_initrd}" "${_dest}/initrd.cpio.gz" 2>/dev/null && return 0
    rm -f "${_dest}/kernel.bin" "${_dest}/initrd.cpio.gz"
    return 1
}

# esp_boot_files <image> <dest-dir>: mount the image's ESP read-only and stage its boot files.
#
# The two boots in run_stage hand qemu-smoke the kernel and initrd of the system being
# upgraded, not the payload's: in uefi-disk mode the firmware boots the disk through GRUB, so
# the log has to describe the old image, and the payload's kernel is the new one.
esp_boot_files() {
    local _image=$1 _dest=$2 _loop _mnt _ok
    _loop=$(sudo losetup --find --show --partscan "${_image}") || return 1
    _mnt=$(mktemp -d)
    sudo mount -o ro "${_loop}p1" "${_mnt}" || {
        sudo losetup -d "${_loop}"
        rmdir "${_mnt}" 2>/dev/null || :
        return 1
    }
    if esp_stage_boot_files "${_mnt}" "${_dest}"; then
        _ok=0
    else
        _ok=1
    fi
    sudo umount "${_mnt}"
    sudo losetup -d "${_loop}"
    rmdir "${_mnt}" 2>/dev/null || :
    return "${_ok}"
}

# esp_digests <image> <out>: the kernel and initrd actually written to the ESP.
esp_digests() {
    # local, not the file's usual bare underscore style: run_stage also owns _image and
    # _out, and without this the second call below writes inside the first call's output
    # file (cross-out/esp.sha256/payload.sha256: Not a directory, run 43573287849).
    local _image=$1 _out=$2
    _loop=$(sudo losetup --find --show --partscan "${_image}") || return 1
    _mnt=$(mktemp -d)
    sudo mount "${_loop}p1" "${_mnt}" || { sudo losetup -d "${_loop}"; return 1; }
    ( cd "${_mnt}" && sha256sum vmlinuz-* initrd-* 2>/dev/null ) >"${_out}"
    sudo umount "${_mnt}"
    sudo losetup -d "${_loop}"
    rmdir "${_mnt}" 2>/dev/null || :
}

payload_digests() {
    local _payload=$1 _out=$2
    _dir=$(mktemp -d)
    tar -xf "${_payload}" -C "${_dir}" kernel.bin initramfs.cpio.gz 2>/dev/null || return 1
    ( cd "${_dir}" && sha256sum kernel.bin initramfs.cpio.gz ) >"${_out}"
    rm -rf "${_dir}"
}

# stage_skip <reason>: the one place a stage says it could not run.
#
# The cross gate reports a skip and lets its caller decide - `release.yml` treats it as not a
# pass already. When the caller asked for the same-base gate the decision is made here: the
# skip is written as the fact it is, and grade() turns it into a failure, because a gate that
# could not judge proved nothing. The plain cross run keeps its old output and exit status.
stage_skip() {
    printf 'cross-upgrade: skipped reason=%s\n' "$1"
    if [ -f "${_out}/expect.same-base" ]; then
        printf '%s\n' "$1" >"${_out}/skip"
        grade "${_out}" "${_payload:-}"
    fi
    return 0
}

run_stage() {
    _image=${1:?--image is required}
    _payload=${2:?--payload is required}
    _out=${3:?--out is required}
    _inject=${4:-}
    _expect_same_base=${5:-}
    _facts_src=${6:-}
    mkdir -p "${_out}"
    if [ -n "${_expect_same_base}" ]; then
        : >"${_out}/expect.same-base"
    fi
    if [ -n "${_facts_src}" ] && [ ! -d "${_facts_src}" ]; then
        # A caller that names a facts directory which is not there asked for a gate that
        # cannot be graded: say so as a verdict, not as a copy error under `set -e` with no
        # line for the workflow to read.
        printf 'same-base=fail reason=facts-missing\n'
        printf 'cross-upgrade=fail reason=facts-missing\n'
        return 0
    fi
    if [ -n "${_facts_src}" ]; then
        # The caller stages the facts it owns (the old release's index and checksums, this
        # release's platform version and pin); the identity of the payload is measured here,
        # from the bytes this run installs, so a caller cannot state a digest the artifact
        # does not have. Both halves land in <out>/facts, which is what makes
        # `assert --out <dir>` on the same directory reach the same verdict.
        rm -rf "${_out}/facts"
        mkdir -p "${_out}/facts"
        cp -R "${_facts_src}"/. "${_out}/facts"/
    fi
    if [ -f "${_out}/expect.same-base" ] && [ -n "${_payload}" ]; then
        mkdir -p "${_out}/facts"
        ci_sha256 "${_payload}" >"${_out}/facts/new-payload.sha256"
        ci_file_size "${_payload}" >"${_out}/facts/new-payload.size"
        # The manifest is a member of the payload, so it is read out of the artifact the
        # stage installs rather than restated by the caller. A tar without one leaves the
        # caller's copy in place; judge() names the missing manifest if there is none.
        if [ ! -f "${_out}/facts/new-manifest.json" ]; then
            tar -xOf "${_payload}" manifest.json >"${_out}/facts/new-manifest.json" 2>/dev/null ||
                rm -f "${_out}/facts/new-manifest.json"
        fi
    fi

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        stage_skip qemu-not-available
        return 0
    fi
    command -v losetup >/dev/null 2>&1 || {
        stage_skip loop-devices-not-available
        return 0
    }

    _work="${CI_TMP_ROOT:-/tmp}/cross-upgrade"
    mkdir -p "${_work}"
    # The caller may hand over the `.img.gz` it found: the helper stages plain bytes and has
    # already printed the reason when it cannot.
    if ! cross_stage_image "${_image}" "${_work}/old.img"; then
        return 0
    fi
    cross_prepare "${_work}/old.img" "${_payload}" "${_work}" "${_expect_same_base}" || {
        printf 'cross-upgrade=fail reason=cannot-prepare-the-old-image\n'
        return 0
    }

    # The kernels the two boots are handed come from the old image's own ESP, not from the
    # payload: uefi-disk boots the disk through GRUB, and the log has to describe the system
    # being upgraded. qemu-smoke requires both names in that mode too, and the payload's
    # kernel is the new one.
    _boot="${_work}/boot"
    if ! esp_boot_files "${_work}/old.img" "${_boot}"; then
        printf 'cross-upgrade=fail reason=cannot-read-the-old-esp\n'
        return 0
    fi

    # Boot 1 installs and prints the pending status; boot 2 commits; boot 3 prints the committed
    # status from the settled state (the fixture hook is a no-op on boot 2).
    # A failed boot is still graded, never trusted: the line below keeps the exit status in
    # the serial log, because swallowing it is how a missing CI_KERNEL once disappeared.
    #
    # The guest's words are not qemu-smoke's stdout. qemu-smoke writes the console to a
    # file in its own qemu scratch directory and copies it to
    # ${CI_LOG_DIR}/serial-<case>.log; its stdout is stage progress for a human. This
    # stage used to redirect that stdout into serial.log, so extract_blocks never found a
    # CROSS-STATUS-* line and every graded run ended reason=status-after-missing (tag run
    # 43622253559). Each boot's guest serial is appended below, in boot order, to the one
    # file the grader reads; the stdout is kept next to it for diagnosis only.
    #
    # The fallback is qemu-smoke's own, line for line: when CI_LOG_DIR is unset it logs
    # under ${CI_TMP_ROOT}/logs, and a local run has to read the copy from the same place.
    _log_dir="${CI_LOG_DIR:-${CI_TMP_ROOT:-${RUNNER_TEMP:-/tmp}/ci}/logs}"
    : >"${_out}/serial.log"
    CI_QEMU_MODE="uefi-disk" CI_QEMU_DISK="${_work}/old.img" CI_JUDGE_PREFIX="" \
        CI_KERNEL="${_boot}/kernel.bin" CI_INITRAMFS="${_boot}/initrd.cpio.gz" \
        CI_QEMU_STOP_PATTERN='CROSS-STATUS-DONE' CI_QEMU_TIMEOUT="${CI_QEMU_TIMEOUT:-900}" \
        CI_QEMU_CASE="cross-boot1" \
        bash "${CI_SCRIPT_DIR}/qemu-smoke.sh" >"${_out}/boot1.stdout.log" 2>&1 ||
        printf '[cross] boot 1 exited %s\n' "$?" >>"${_out}/serial.log"
    _serial="${_log_dir}/serial-cross-boot1.log"
    if [ -s "${_serial}" ] && cat "${_serial}" >>"${_out}/serial.log"; then
        :
    else
        printf '[cross] boot 1: no guest serial at %s\n' "${_serial}" >>"${_out}/serial.log"
    fi
    CI_QEMU_MODE="uefi-disk" CI_QEMU_DISK="${_work}/old.img" CI_JUDGE_PREFIX="" \
        CI_KERNEL="${_boot}/kernel.bin" CI_INITRAMFS="${_boot}/initrd.cpio.gz" \
        CI_QEMU_STOP_PATTERN='^(ab-commit: committed slot=|ab-commit: abandoned slot=)' \
        CI_QEMU_TIMEOUT="${CI_QEMU_TIMEOUT:-900}" \
        CI_QEMU_CASE="cross-boot2" \
        bash "${CI_SCRIPT_DIR}/qemu-smoke.sh" >"${_out}/boot2.stdout.log" 2>&1 ||
        printf '[cross] boot 2 exited %s\n' "$?" >>"${_out}/serial.log"
    _serial="${_log_dir}/serial-cross-boot2.log"
    if [ -s "${_serial}" ] && cat "${_serial}" >>"${_out}/serial.log"; then
        :
    else
        printf '[cross] boot 2: no guest serial at %s\n' "${_serial}" >>"${_out}/serial.log"
    fi
    # Boot 3: the committed slot. The only boot where the state is settled at S95, so the
    # fixture hook can print the post-commit status without racing ab-commit.
    CI_QEMU_MODE="uefi-disk" CI_QEMU_DISK="${_work}/old.img" CI_JUDGE_PREFIX="" \
        CI_KERNEL="${_boot}/kernel.bin" CI_INITRAMFS="${_boot}/initrd.cpio.gz" \
        CI_QEMU_STOP_PATTERN='CROSS-STATUS-DONE' CI_QEMU_TIMEOUT="${CI_QEMU_TIMEOUT:-900}" \
        CI_QEMU_CASE="cross-boot3" \
        bash "${CI_SCRIPT_DIR}/qemu-smoke.sh" >"${_out}/boot3.stdout.log" 2>&1 ||
        printf '[cross] boot 3 exited %s\n' "$?" >>"${_out}/serial.log"
    _serial="${_log_dir}/serial-cross-boot3.log"
    if [ -s "${_serial}" ] && cat "${_serial}" >>"${_out}/serial.log"; then
        :
    else
        printf '[cross] boot 3: no guest serial at %s\n' "${_serial}" >>"${_out}/serial.log"
    fi

    extract_blocks "${_out}/serial.log" "${_out}"
    esp_digests "${_work}/old.img" "${_out}/esp.sha256" || :
    payload_digests "${_payload}" "${_out}/payload.sha256" || :
    # An if, not a && chain: with an empty --inject the chain returns non-zero and set -e
    # ends the script here, before grade() can print anything - the run then reports "no
    # verdict line" instead of the verdict (run 43584337812).
    if [ -n "${_inject}" ] && [ "${_inject}" != "none" ]; then
        printf '%s\n' "${_inject}" >"${_out}/inject"
    fi
    grade "${_out}" "${_payload}"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "${cmd}" in
    fixture)
        # Print the fixture script for one mode. The two gates differ in exactly one word and
        # this is where a test can see it without a loop device or root.
        _fixture_same_base=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --same-base) _fixture_same_base=1; shift ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        cross_fixture_rc_local "${_fixture_same_base}"
        ;;
    run)
        image="" payload="" out="" inject="" expect_same_base="" facts=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --image) image=${2:?--image needs a value}; shift 2 ;;
                --payload) payload=${2:?--payload needs a value}; shift 2 ;;
                --out) out=${2:?--out needs a value}; shift 2 ;;
                --inject) inject=${2:?--inject needs a value}; shift 2 ;;
                --expect-same-base) expect_same_base=1; shift ;;
                --facts) facts=${2:?--facts needs a directory}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        run_stage "${image}" "${payload}" "${out}" "${inject}" "${expect_same_base}" "${facts}"
        ;;
    assert)
        out="" expect_same_base="" facts=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --out) out=${2:?--out needs a value}; shift 2 ;;
                --expect-same-base) expect_same_base=1; shift ;;
                --facts) facts=${2:?--facts needs a directory}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        [ -n "${out}" ] || ci_die "--out is required"
        mkdir -p "${out}"
        if [ -n "${expect_same_base}" ]; then
            : >"${out}/expect.same-base"
        fi
        if [ -n "${facts}" ]; then
            [ -d "${facts}" ] || ci_die "--facts is not a directory: ${facts}"
            rm -rf "${out}/facts"
            mkdir -p "${out}/facts"
            cp -R "${facts}"/. "${out}/facts"/
        fi
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
    stage-boot-files)
        esp="" dest=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --esp) esp=${2:?--esp needs a value}; shift 2 ;;
                --dest) dest=${2:?--dest needs a value}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        [ -n "${esp}" ] && [ -n "${dest}" ] || ci_die "--esp and --dest are required"
        esp_stage_boot_files "${esp}" "${dest}"
        ;;
    stage-image)
        src="" dest=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --src) src=${2:?--src needs a value}; shift 2 ;;
                --dest) dest=${2:?--dest needs a value}; shift 2 ;;
                *) ci_die "unknown argument $1" ;;
            esac
        done
        [ -n "${src}" ] && [ -n "${dest}" ] || ci_die "--src and --dest are required"
        cross_stage_image "${src}" "${dest}"
        ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
esac
