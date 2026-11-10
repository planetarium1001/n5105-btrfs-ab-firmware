#!/usr/bin/env bash
# Stage "grub": render the ESP bootloader configuration and the runtime slot file,
# then assert both.
#
# GRUB configuration is generated, never hand-edited, so this script renders the
# template and then refuses to produce an image unless all five documented rules hold:
#
#   1. `default` and `fallback` both name the committed entry, the menu order fixes the
#      entry index of each slot (slot a is entry 0, slot b is entry 1), and every kernel
#      line ends in the serial console, which is the one /dev/console binds to. A
#      truncated or missing runtime file therefore boots the committed slot with a
#      fallback that is that same slot, instead of falling back to the slot that failed
#   2. every menuentry is defined before the runtime override is sourced, and before
#      the serial console is set up: GRUB stops reading the file at the first error,
#      so the tail must never be able to cost the machine a boot
#   3. no environment block machinery (`load_env`, `save_env`, `grubenv`, `.mod`
#      probing): the GRUB in the ESP is a standalone EFI binary with no `env` module,
#      so those commands do not exist there and a menu using them boots the committed
#      slot forever
#   4. GRUB script is not bash: no `&&`, `||` or `${x:-y}` expansions
#   5. every @TOKEN@ placeholder has been replaced
#
# The runtime file is /boot/grub/ab-slot.cfg: `set fallback=<committed>` first and
# `set default=<pending-or-committed>` second, written by platform/lib/ab-slot-cfg.sh,
# the same code ab-slot, ab-boot and the boot initramfs use on the device, so the build
# and the device cannot disagree. Writing the fallback first is the power-cut contract:
# a file cut short keeps both entries on the committed slot.
#
# `--check FILE [SLOTCFG]` runs the assertions alone, which is what tests/modules/ab
# uses to prove each rule actually rejects a broken file, and to prove the runtime
# file format is checked too.
#
# `--verify-esp IMAGE` mounts the ESP of a ready image and proves that GRUB can boot
# it: the EFI loader, the menu, grub-script-check on the menu, the loader really
# carries the `source` command the menu depends on, and the runtime file agrees with
# ab/state.json. The boot stages of a QEMU pipeline cannot assert any of that while
# they hand a kernel to QEMU with -kernel.
#
# Inputs (environment):
#   CI_GRUB_TEMPLATE    template path (default: scripts/ci/grub.cfg.in)
#   CI_GRUB_OUTPUT      rendered path (default: $CI_TMP_ROOT/grub/grub.cfg)
#   CI_SLOT_CFG_OUT     runtime slot file path (default: next to CI_GRUB_OUTPUT)
#   CI_COMMITTED_SLOT   committed slot, a or b (default: a)
#   CI_SLOT_CFG_PATH    runtime file path as GRUB sees it (default: /boot/grub/ab-slot.cfg)
#   CI_GRUB_TIMEOUT     menu timeout in seconds (default: 3)
#
# Outputs: grub_cfg, grub_cfg_sha256, ab_slot_cfg_path, ab_slot_cfg_sha256,
#          ab_slot_cfg_slot, committed_slot, committed_index

set -euo pipefail

CI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "${CI_SCRIPT_DIR}/lib.sh"
# shellcheck source=platform/lib/ab-slot-cfg.sh
. "${CI_REPO_ROOT}/platform/lib/ab-slot-cfg.sh"

on_error() {
    local status=$?
    ci_log "ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${status})"
    exit "${status}"
}
trap on_error ERR

ci_stage_init grub

# slot_cfg_check <file> [<committed slot>]: the runtime file has to be the pair of
# commands the menu sources, in the documented order, with the committed slot as its
# fallback. Without a committed slot only the shape is checked, which is all a
# standalone `--check` can know.
slot_cfg_check() {
    local file="$1"
    local committed="${2:-}"
    local pair default_slot fallback_slot
    if ! ab_slot_cfg_verify "${file}"; then
        ci_die "runtime slot file ${file} is not a usable pair of commands (${AB_SLOT_CFG_REASON})"
    fi
    default_slot="$(ab_slot_cfg_get "${file}")" \
        || ci_die "runtime slot file ${file} names no default slot"
    fallback_slot="$(ab_slot_cfg_fallback "${file}")" \
        || ci_die "runtime slot file ${file} names no fallback slot"
    if [ -n "${committed}" ]; then
        if ! pair="$(ab_slot_cfg_check_pair "${file}" "${committed}")"; then
            ci_die "runtime slot file ${file} does not fall back to the committed slot (${AB_SLOT_CFG_REASON})"
        fi
        # check_pair answers "<default> <fallback>"; both values are reported so a
        # mismatch in the log is enough to see which line was wrong.
        default_slot="${pair%% *}"
        fallback_slot="${pair##* }"
    fi
    ci_log "runtime slot file ${file} is valid (fallback ${fallback_slot}, default ${default_slot})"
}

# check_grub <file>: the five rendering rules, in the documented order.
#
# Comment lines are dropped first: the header of the template explains what is
# forbidden and would otherwise trip its own check.
check_grub() {
    local file="$1"
    local problems=0
    local code
    local base_default
    local base_fallback
    local entry_ids
    local last_entry_line
    local source_line
    local serial_line
    code="$(mktemp)"
    # shellcheck disable=SC2064  # expand now, the trap fires after the function returns
    trap "rm -f '${code}'" RETURN

    sed '/^[[:space:]]*#/d' "${file}" >"${code}"

    # 1. a concrete pair on the committed entry, with the slot to index mapping the
    #    runtime file and the tools assume. The static fallback is deliberately the
    #    committed entry: it is what a truncated or missing runtime file leaves behind.
    base_default="$(sed -n 's/^set default=\([0-9][0-9]*\)$/\1/p' "${code}" | head -n 1)"
    base_fallback="$(sed -n 's/^set fallback=\([0-9][0-9]*\)$/\1/p' "${code}" | head -n 1)"
    if [ -z "${base_default}" ]; then
        ci_warn "rule 1: no concrete 'set default=<entry>' line in ${file}"
        problems=$((problems + 1))
    fi
    if [ -z "${base_fallback}" ]; then
        ci_warn "rule 1: no concrete 'set fallback=<entry>' line in ${file}"
        problems=$((problems + 1))
    fi
    if [ -n "${base_default}" ] && [ -n "${base_fallback}" ] && [ "${base_default}" != "${base_fallback}" ]; then
        ci_warn "rule 1: 'set fallback=${base_fallback}' must name the committed entry ${base_default}: a truncated runtime file would otherwise fall back to the slot that just failed"
        problems=$((problems + 1))
    fi
    entry_ids="$(grep -oE -- '--id [A-Za-z0-9_-]+' "${code}" | sed 's/--id //' | tr '\n' ',')"
    if [ "${entry_ids}" != "n5105-a,n5105-b,n5105-recovery," ]; then
        ci_warn "rule 1: the menu entries must be a, b then recovery so entry 0 is slot a and entry 1 is slot b, got: ${entry_ids:-none}"
        problems=$((problems + 1))
    fi
    for entry in a b; do
        if ! grep -qF "ab.slot=${entry}" "${code}"; then
            ci_warn "rule 1: no menu entry passes ab.slot=${entry} to the kernel"
            problems=$((problems + 1))
        fi
    done
    # 1c. the serial console has to be the last console= on every kernel line: Linux
    #     binds /dev/console to the last one, and every milestone our hooks print goes
    #     there. Ending in console=tty0 sends all of it to the local screen and leaves
    #     an empty serial log, which is a boot nobody can debug.
    while IFS= read -r kernel_line; do
        last_console="$(printf '%s\n' "${kernel_line}" | sed 's/.*console=\([^ ]*\).*/\1/')"
        case "${last_console}" in
            ttyS0*) : ;;
            *)
                ci_warn "rule 1: the last console= on a kernel line is '${last_console}', not the serial port: $(printf '%s' "${kernel_line}" | cut -c1-80)"
                problems=$((problems + 1))
                ;;
        esac
    done < <(grep -E '^[[:space:]]*linux ' "${code}" || true)

    # 2. everything the machine needs to boot is defined before the parts that can
    #    fail. Line numbers, because the order is the whole point.
    last_entry_line="$(grep -nE '^menuentry ' "${code}" | tail -n 1 | cut -d: -f1 || true)"
    source_line="$(grep -nE '^[[:space:]]*source [^[:space:]]+' "${code}" | head -n 1 | cut -d: -f1 || true)"
    serial_line="$(grep -nE '^[[:space:]]*(if[[:space:]]+)?serial[[:space:]]' "${code}" \
        | head -n 1 | cut -d: -f1 || true)"
    if [ -z "${last_entry_line}" ]; then
        ci_warn "rule 2: the configuration defines no menuentry"
        problems=$((problems + 1))
    else
        if [ -z "${source_line}" ]; then
            ci_warn "rule 2: the configuration never sources the runtime slot file"
            problems=$((problems + 1))
        elif [ "${source_line}" -le "${last_entry_line}" ]; then
            ci_warn "rule 2: the runtime slot file is sourced before the last menuentry (line ${source_line} <= ${last_entry_line})"
            problems=$((problems + 1))
        fi
        if [ -n "${serial_line}" ] && [ "${serial_line}" -le "${last_entry_line}" ]; then
            ci_warn "rule 2: the serial console is set up before the last menuentry (line ${serial_line} <= ${last_entry_line})"
            problems=$((problems + 1))
        fi
    fi
    if ! grep -qE '^if \[ -f [^] ]*ab-slot\.cfg \]; then$' "${code}"; then
        ci_warn "rule 2: sourcing the runtime slot file is not guarded by 'if [ -f <ab-slot.cfg> ]'"
        problems=$((problems + 1))
    fi

    # 3. no environment block machinery: the shipped GRUB has no env module, so a
    #    menu that waits for one would silently boot the committed slot forever.
    local forbidden
    for forbidden in load_env save_env grubenv '.mod' ab_try; do
        if grep -qF "${forbidden}" "${code}"; then
            ci_warn "rule 3: '${forbidden}' does not work in the ESP's GRUB, which has no env module: $(grep -nF "${forbidden}" "${code}" | head -n 1)"
            problems=$((problems + 1))
        fi
    done

    # 4. no bash-isms
    if grep -q '&&' "${code}"; then
        ci_warn "rule 4: '&&' is not GRUB script"
        problems=$((problems + 1))
    fi
    if grep -q '||' "${code}"; then
        ci_warn "rule 4: '||' is not GRUB script"
        problems=$((problems + 1))
    fi
    if grep -Eq '\$\{[^}]*:-' "${code}"; then
        ci_warn "rule 4: '\${x:-y}' is not GRUB script"
        problems=$((problems + 1))
    fi

    # 5. no unreplaced placeholder
    if grep -Eq '@[A-Z_][A-Z0-9_]*@' "${file}"; then
        ci_warn "rule 5: unreplaced placeholder(s): $(grep -Eo '@[A-Z_][A-Z0-9_]*@' "${file}" | sort -u | tr '\n' ' ')"
        problems=$((problems + 1))
    fi

    if [ "${problems}" -ne 0 ]; then
        ci_die "rendered GRUB configuration violates ${problems} rule(s): ${file}"
    fi
    ci_log "grub configuration satisfies all five rendering rules: ${file}"
}

# --check mode: assertions only, used by the test suite.
if [ "${1:-}" = "--check" ]; then
    [ -f "${2:-}" ] || ci_die "--check needs a file"
    check_grub "$2"
    if [ "$#" -ge 3 ]; then
        [ -f "$3" ] || ci_die "--check: no runtime slot file at $3"
        # The static default names the committed entry, so the pair checks do not need
        # a second input.
        check_committed="$(sed '/^[[:space:]]*#/d' "$2" \
            | sed -n 's/^set default=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
        check_committed_slot="$(ab_slot_cfg_slot "${check_committed}")" \
            || ci_die "--check: the menu's default entry ${check_committed:-none} is not a slot"
        slot_cfg_check "$3" "${check_committed_slot}"
    fi
    ci_log "stage grub (check) finished"
    exit 0
fi

# --------------------------------------------------------------------------- #
# --verify-esp <image>: prove the ESP of a ready image can boot through GRUB, and
# that the runtime file it carries agrees with ab/state.json.
# --------------------------------------------------------------------------- #
if [ "${1:-}" = "--verify-esp" ]; then
    image="${2:-}"
    [ -n "${image}" ] || ci_die "--verify-esp needs a disk image"
    [ -f "${image}" ] || ci_die "image not found: ${image}"
    ci_require_cmd sudo losetup grub-script-check
    sudo -n true 2>/dev/null || ci_die "passwordless sudo is required to read the ESP back"

    esp_mnt="${CI_TMP_ROOT}/grub-esp"
    mkdir -p "${esp_mnt}"
    loopdev="$(sudo losetup --find --show --partscan "${image}")"
    # shellcheck disable=SC2064  # expand now, the trap fires after the mount is done
    trap "sudo umount '${esp_mnt}' 2>/dev/null || true; sudo losetup -d '${loopdev}' 2>/dev/null || true" EXIT
    attempt=0
    until [ -b "${loopdev}p1" ] || [ "${attempt}" -ge 40 ]; do
        attempt=$((attempt + 1))
        sleep 0.25
    done
    [ -b "${loopdev}p1" ] || ci_die "partition 1 did not appear on ${image}"
    sudo mount -t vfat -o ro "${loopdev}p1" "${esp_mnt}" \
        || ci_die "the ESP of ${image} is not a mountable FAT filesystem"

    # 1. the loader the firmware runs
    loader="$(sudo find "${esp_mnt}" -type f -iname 'bootx64.efi' -print -quit)"
    [ -n "${loader}" ] || ci_die "the ESP carries no EFI/BOOT/BOOTX64.EFI, OVMF has nothing to start"
    ci_log "EFI loader: ${loader#"${esp_mnt}"/}"
    # The commands the menu relies on have to exist in the loader: `source` for the
    # override, `test` for the file guard around it (`[` is registered with `test` in
    # the same module), `serial` for the diagnostics block. This is the assumption that
    # once made an earlier menu silently boot the committed slot forever.
    for command in source test serial; do
        if ! sudo grep -aq "${command}" "${loader}"; then
            ci_die "the EFI loader carries no '${command}' command; the menu's '${command}' block cannot work on a real machine"
        fi
    done
    if sudo grep -aq 'load_env' "${loader}"; then
        ci_warn "the EFI loader carries load_env after all; the file based override stays the mechanism in use"
    fi

    # 2. the menu itself: our rules plus GRUB's own parser, on what the ESP really has
    esp_cfg="${esp_mnt}/boot/grub/grub.cfg"
    [ -f "${esp_cfg}" ] || ci_die "the ESP carries no boot/grub/grub.cfg"
    esp_cfg_copy="${CI_TMP_ROOT}/esp-grub.cfg"
    # tee, not a redirected sudo cat: the redirect would happen as the runner user and
    # the file has to stay readable by the checks below.
    sudo cat "${esp_cfg}" | tee "${esp_cfg_copy}" >/dev/null
    check_grub "${esp_cfg_copy}"
    grub-script-check "${esp_cfg_copy}" || ci_die "grub-script-check rejects the menu on the ESP"
    ci_log "grub-script-check accepts the menu on the ESP"

    # 3. the runtime file: valid, and equal to what ab/state.json implies. ab-slot and
    #    ab-boot write `pending` when there is one and `committed` otherwise, so
    #    anything else is a half written pair.
    esp_cfg_slot="${esp_mnt}/boot/grub/ab-slot.cfg"
    slot_cfg_check "${esp_cfg_slot}"
    state="${esp_mnt}/ab/state.json"
    [ -f "${state}" ] || ci_die "the ESP carries no ab/state.json"
    committed="$(sudo sed -n 's/.*"committed": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
    if sudo grep -q '"pending": *null' "${state}"; then
        pending="none"
    else
        pending="$(sudo sed -n 's/.*"pending": *"\([ab]\)".*/\1/p' "${state}" | head -n 1)"
    fi
    case "${pending}" in
        a | b) expect_slot="${pending}" ;;
        none) expect_slot="${committed}" ;;
        *) ci_die "ab/state.json has no usable pending field (${pending:-empty})" ;;
    esac
    [ -n "${committed}" ] || ci_die "ab/state.json has no committed slot"

    # The pair has to hold together: the fallback stays on the committed slot, the
    # default moves to the candidate. With a pending slot that also means the two lines
    # must differ, or a failed try would have nowhere to go.
    slot_cfg_check "${esp_cfg_slot}" "${committed}"
    esp_slot="$(ab_slot_cfg_get "${esp_cfg_slot}")"
    esp_fallback="$(ab_slot_cfg_fallback "${esp_cfg_slot}")"
    ci_log "runtime slot file on the ESP: next=${esp_slot}, fallback=${esp_fallback}, committed=${committed}, pending=${pending}"
    [ "${esp_slot}" = "${expect_slot}" ] \
        || ci_die "the menu will next boot slot ${esp_slot}, but state.json says committed=${committed} pending=${pending}"
    [ "${esp_fallback}" = "${committed}" ] \
        || ci_die "the fallback says slot ${esp_fallback}, the committed slot is ${committed}"
    case "${pending}" in
        a | b)
            [ "${esp_slot}" != "${esp_fallback}" ] \
                || ci_die "slot ${pending} is pending but the fallback points at it too, a failed try would have nowhere to go"
            ;;
    esac

    # 4. the menu must actually read the runtime file; without this line the file is
    #    decoration and the committed slot boots forever.
    if ! grep -qF 'ab-slot.cfg' "${esp_cfg_copy}"; then
        ci_die "the menu on the ESP never sources ab-slot.cfg, so the runtime decision is ignored"
    fi

    ci_emit_output "esp_cfg" "${esp_cfg}"
    ci_emit_output "esp_slot_cfg" "${esp_cfg_slot}"
    ci_emit_output "esp_next_slot" "${esp_slot}"
    ci_emit_output "esp_committed" "${committed}"
    ci_emit_output "esp_pending" "${pending}"
    ci_log "ESP verified: GRUB can boot it, and the runtime file points at slot ${esp_slot}, matching state.json"
    ci_log "stage grub (verify-esp) finished"
    exit 0
fi

template="${CI_GRUB_TEMPLATE:-${CI_REPO_ROOT}/scripts/ci/grub.cfg.in}"
output="${CI_GRUB_OUTPUT:-${CI_TMP_ROOT}/grub/grub.cfg}"
committed="${CI_COMMITTED_SLOT:-a}"
slot_cfg_path="${CI_SLOT_CFG_PATH:-/boot/grub/ab-slot.cfg}"
timeout_s="${CI_GRUB_TIMEOUT:-3}"

[ -f "${template}" ] || ci_die "template not found: ${template}"
case "${committed}" in
    a) committed_index=0 ;;
    b) committed_index=1 ;;
    *) ci_die "committed slot must be a or b, got ${committed}" ;;
esac
if [ "${committed_index}" != "$(ab_slot_cfg_index "${committed}")" ]; then
    ci_die "the committed slot ${committed} is entry ${committed_index}, but platform/lib/ab-slot-cfg.sh maps it to $(ab_slot_cfg_index "${committed}")"
fi
# The runtime file sits next to the rendered configuration so a caller can install
# both with one directory copy; CI_SLOT_CFG_OUT overrides it.
slot_cfg_out="${CI_SLOT_CFG_OUT:-$(dirname "${output}")/ab-slot.cfg}"

mkdir -p "$(dirname "${output}")"
sed -e "s|@GRUB_TIMEOUT@|${timeout_s}|g" \
    -e "s|@COMMITTED_INDEX@|${committed_index}|g" \
    -e "s|@COMMITTED_SLOT@|${committed}|g" \
    -e "s|@AB_SLOT_CFG_PATH@|${slot_cfg_path}|g" \
    "${template}" >"${output}"

check_grub "${output}"

# The image boots the committed slot until `ab-slot pending` says otherwise: both lines
# name it, which is the state a truncated runtime file degrades to.
ab_slot_cfg_write "${slot_cfg_out}" "${committed}" "${committed}" \
    || ci_die "cannot write the runtime slot file ${slot_cfg_out} (${AB_SLOT_CFG_REASON})"
slot_cfg_check "${slot_cfg_out}" "${committed}"

cfg_sha="$(ci_sha256 "${output}")"
slot_cfg_sha="$(ci_sha256 "${slot_cfg_out}")"
ci_log "rendered ${output} (committed slot ${committed}, entry ${committed_index}, sha256 ${cfg_sha})"
ci_log "wrote ${slot_cfg_out} (next boot: slot ${committed}, sha256 ${slot_cfg_sha})"

ci_emit_output "grub_cfg" "${output}"
ci_emit_output "grub_cfg_sha256" "${cfg_sha}"
ci_emit_output "ab_slot_cfg_path" "${slot_cfg_out}"
ci_emit_output "ab_slot_cfg_sha256" "${slot_cfg_sha}"
ci_emit_output "ab_slot_cfg_slot" "${committed}"
ci_emit_output "committed_slot" "${committed}"
ci_emit_output "committed_index" "${committed_index}"

ci_log "stage grub finished"
