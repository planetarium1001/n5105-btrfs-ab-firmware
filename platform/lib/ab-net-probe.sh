#!/bin/sh
# ab-net-probe - is there a usable package feed on this network, and if not, when to ask again.
#
# The package follow of a freshly aligned base is a network transaction: `apk upgrade`
# against the feeds the aligner moved to the new release. Everything that can go wrong
# there is a network question - a captive portal, a DNS hijack, an unplugged cable - and
# none of it may block a boot or turn into a verdict the machine cannot keep. So this
# library answers three questions and nothing else:
#
#   1. is the feed actually answering with a feed? (`ab_net_probe`: ok / portal / offline)
#   2. may this worker run the transaction right now? (`ab_net_lock_*`: one apk
#      transaction at a time, never two interleaved ones)
#   3. when is the next rung of the retry ladder? (`ab_net_follow_boot` / `ifup`)
#
# It does not run apk itself. The transaction belongs to platform/lib/upgrade/packages.sh
# (its `ab_packages_follow_*` entry); this file only decides whether and when to call it,
# so the boot path can hand the work over and return.
#
# Measured facts this was written against (device 192.168.2.49, 2026-11-18, apk-tools
# 3.0.5 on ImmortalWrt 25.12.2, see research/2026-11-18-device-apk-probe.md):
#
#   * an apk v3 index starts with the four bytes `ADBd` (hexdump of a real index:
#     `4144 4264`); an authentication page or a hijacked DNS answer cannot produce them;
#   * `--spider` only asks for the status code and judged the captive portal `ok`
#     (measured: 2 of 3 cases misjudged), which is why the magic is checked instead;
#   * the smallest file a feed publishes is the release's target index (targets/x86/64,
#     16390 bytes) while the packages index beside it is ~1.5 MB, so the probe prefers a
#     `targets/` URL and pays 16 KB instead of 1.5 MB on every rung;
#   * the machine has no `od` and no `xxd`; `head -c 4` + `cmp -s` is the whole check;
#   * there is no `timeout` applet: the fetch carries its own cap (`uclient-fetch -T`),
#     and the retry ladder is a sleeping loop, not a timer;
#   * /var is a tmpfs, so /var/lock is empty on every boot - a lock left by a power cut
#     cannot survive it. The ESP fallback below covers hosts that have no /var/lock.
#
# Sourced by platform/etc/init.d/ab-boot (the detached first-boot worker) and
# platform/etc/hotplug.d/iface/90-ab-packages (the ifup rung). POSIX sh, no `local`: the
# variables a function needs are `_`-prefixed and set in the caller's shell, which is this
# image's convention (see platform/lib/upgrade/packages.sh).

# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #

AB_ESP="${AB_ESP:-/boot}"
# The one-line record the aligner publishes and `ab-slot status` reads.
AB_PACKAGES_FILE="${AB_PACKAGES_FILE:-${AB_ESP}/ab/packages}"
# The library that owns the follow transaction. Same variable ab-boot has always used,
# so a caller that points the hook at a sandbox library points this at it too.
AB_PACKAGES_LIB="${AB_PACKAGES_LIB:-/lib/upgrade/packages.sh}"
# The root the transaction acts on: "/" on a machine, a directory in a test.
AB_PACKAGES_TARGET="${AB_PACKAGES_TARGET:-/}"

# The probe. AB_NET_PROBE_INPUT replays a recorded response body instead of fetching one
# (the same idea as AB_PROBE_INPUT in scripts/device/apk-protection-probe.sh): the file's
# bytes are what the fetcher would have written, so the classification runs for real.
AB_NET_PROBE_INPUT="${AB_NET_PROBE_INPUT:-}"
AB_NET_PROBE_URL="${AB_NET_PROBE_URL:-}"
AB_NET_PROBE_TIMEOUT="${AB_NET_PROBE_TIMEOUT:-8}"
AB_NET_PROBE_MAGIC="${AB_NET_PROBE_MAGIC:-ADBd}"
AB_NET_PROBE_TMP="${AB_NET_PROBE_TMP:-/tmp}"

# The retry ladder. W1's rungs are *absolute* seconds from the moment the worker starts, not
# gaps: an attempt can take minutes (a probe on a blackholed route measured 8 s, a
# transaction far longer), and a window that stretches with every attempt is not a window.
# The six rungs design.md §9 asks for in the first five minutes - immediately, then at 15,
# 30, 60 and 120 s, and one last look at the five-minute mark - are therefore the offsets
# 0/15/30/60/120/300. W3 then asks every half hour until a day has passed, and the record
# says `follow=abandoned`.
AB_NET_FOLLOW_W1="${AB_NET_FOLLOW_W1:-0 15 30 60 120 300}"
AB_NET_FOLLOW_W3_INTERVAL="${AB_NET_FOLLOW_W3_INTERVAL:-1800}"
AB_NET_FOLLOW_W3_DEADLINE="${AB_NET_FOLLOW_W3_DEADLINE:-86400}"
# One apk transaction at a time. /var/lock is a tmpfs on this image, which is why the lock
# lives there: a lock left by a power cut, a watchdog reset or a hard kill is gone with the
# boot that made it.
AB_NET_FOLLOW_LOCK="${AB_NET_FOLLOW_LOCK:-/var/lock/ab-packages-follow.lock}"

# A worker that sleeps for a day must be drivable by a test: both the clock and the sleep
# are commands, so a fixture can advance time instead of waiting for it.
AB_NET_NOW_CMD="${AB_NET_NOW_CMD:-}"
AB_NET_SLEEP_CMD="${AB_NET_SLEEP_CMD:-sleep}"
# Console lines are for the boot carrier. A hotplug hook leaves this unset: an ifup is not
# a milestone a serial log has to carry.
AB_NET_SAY="${AB_NET_SAY:-0}"

# Where the boot slot is written by GRUB, and the id of this boot (the same two files
# ab-boot and ab-slot read, so a test can describe a machine that restarted).
AB_CMD="${AB_CMD:-/proc/cmdline}"
AB_BOOT_ID_FILE="${AB_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
AB_NET_RING_LOG_MAX="${AB_NET_RING_LOG_MAX:-32768}"

# The service reconcile a settled follow owes the boot (platform/lib/ab-services.sh). It is a
# separate file because this library does not own that repair - it only decides when to call
# it - and ab-boot sources the same file for its own worker.
AB_SERVICES_LIB="${AB_SERVICES_LIB:-/lib/ab-services.sh}"

# The verdict of the last rung this shell took (`followed`, `skipped`, `pending`, ...), empty
# before any rung ran. ab_net_attempt clears it and ab_net_follow_call writes it, and the
# `ifup` rung reads it: only a rung that really followed has closed the window in which procd
# starts the boot scripts, so only that rung may reconcile the services procd lost.
AB_NET_FOLLOW_RESULT=""

# --------------------------------------------------------------------------- #
# Plumbing
# --------------------------------------------------------------------------- #

# ab_net_now: seconds since the epoch, as an integer.
ab_net_now() {
    if [ -n "${AB_NET_NOW_CMD}" ]; then
        ${AB_NET_NOW_CMD}
        return 0
    fi
    date -u +%s 2>/dev/null || printf '0'
}

# ab_net_sleep <seconds>: wait, through the configured sleeper.
ab_net_sleep() {
    case "${1:-}" in
        '' | *[!0-9]*) return 0 ;;
    esac
    [ "${1}" -gt 0 ] || return 0
    ${AB_NET_SLEEP_CMD} "${1}" 2>/dev/null || :
    return 0
}

# ab_net_ring_log <line>: the ring log ab-boot rotates, one line per fact. The tail
# truncation rule is the same one ab-boot and the two net hooks use, so a pulled ESP
# explains a boot from a single file whatever stopped the machine.
ab_net_ring_log() {
    _log_dir="${AB_ESP}/ab/log"
    _log_file="${_log_dir}/boot-0.log"
    _log_tmp="${_log_file}.tmp.$$"
    mkdir -p "${_log_dir}" 2>/dev/null || return 0
    [ -f "${_log_file}" ] && cat "${_log_file}" >"${_log_tmp}" 2>/dev/null
    printf '%s\n' "$*" >>"${_log_tmp}" 2>/dev/null || return 0
    if [ "$(wc -c <"${_log_tmp}" 2>/dev/null || printf '0')" -gt "${AB_NET_RING_LOG_MAX}" ]; then
        tail -c $((AB_NET_RING_LOG_MAX - 512)) "${_log_tmp}" >"${_log_tmp}.tail" 2>/dev/null &&
            printf 'TRUNCATED=1\n' >>"${_log_tmp}.tail" &&
            mv "${_log_tmp}.tail" "${_log_tmp}"
    fi
    sync
    mv "${_log_tmp}" "${_log_file}" 2>/dev/null || :
    sync
    return 0
}

# ab_net_say <line...>: the console milestone, when the caller asked for one. ab-boot has
# already defined console_say (platform/lib/ab-console.sh) by the time its worker runs, so
# the line reaches the serial log the same way every other boot milestone does.
ab_net_say() {
    [ "${AB_NET_SAY}" = "1" ] || return 0
    if command -v console_say >/dev/null 2>&1; then
        console_say "$*"
        return 0
    fi
    printf '%s\n' "$*" >"${AB_CONSOLE_DEV:-/dev/console}" 2>/dev/null || :
    return 0
}

# --------------------------------------------------------------------------- #
# The record
#
# `/boot/ab/packages` is one line of key=value fields. The aligner owns what it means; the
# network layer is the only writer of `reason=network` and `follow=abandoned`, and it never
# reorders or drops a field it did not set: everything else is somebody else's fact.
# --------------------------------------------------------------------------- #

ab_net_record_file() {
    printf '%s' "${AB_PACKAGES_FILE}"
}

# ab_net_record_field <key>: one field of the record, or empty.
#
# The line is split into fields rather than matched with one regex, so a field is found
# wherever it stands: the record is written by two libraries and this reader must not
# depend on the position of a key it does not own.
ab_net_record_field() {
    _rec_file="$(ab_net_record_file)"
    [ -r "${_rec_file}" ] || return 0
    tail -n 1 "${_rec_file}" 2>/dev/null |
        tr ' \t' '\n\n' | sed -n "s/^$1=//p" | tail -n 1
}

# ab_net_record_set <key=value>...: rewrite the named fields in place.
#
# The position of a field is part of the format (`reason=` is the second field, `ab-slot`
# reads state and reason with one regex each), so the line is rebuilt field by field in
# its original order and a key the record does not carry yet is appended. Written to a
# temporary file, synced, renamed, and read back: a half-written verdict would be a fact
# nobody authored.
ab_net_record_set() {
    _set_file="$(ab_net_record_file)"
    [ -r "${_set_file}" ] || return 1
    _set_line="$(tail -n 1 "${_set_file}" 2>/dev/null)"
    case "${_set_line}" in
        packages=*) ;;
        *) return 1 ;;
    esac
    [ "$#" -gt 0 ] || return 0
    _set_new="$(printf '%s\n' "${_set_line}" | awk -v pairs="$*" '
        {
            n = split(pairs, p, " ")
            for (i = 1; i <= n; i++) {
                if (p[i] == "") continue
                key = p[i]
                sub(/=.*/, "", key)
                want[key] = p[i]
            }
            out = ""
            for (i = 1; i <= NF; i++) {
                key = $i
                sub(/=.*/, "", key)
                if (key in want) {
                    out = out (out == "" ? "" : " ") want[key]
                    done[key] = 1
                } else {
                    out = out (out == "" ? "" : " ") $i
                }
            }
            for (i = 1; i <= n; i++) {
                if (p[i] == "") continue
                key = p[i]
                sub(/=.*/, "", key)
                if (key in done) continue
                out = out " " p[i]
                done[key] = 1
            }
            print out
        }')"
    [ -n "${_set_new}" ] || return 1
    _set_tmp="${_set_file}.tmp.$$"
    printf '%s\n' "${_set_new}" >"${_set_tmp}" 2>/dev/null || {
        rm -f "${_set_tmp}" 2>/dev/null || :
        return 1
    }
    sync 2>/dev/null || :
    mv "${_set_tmp}" "${_set_file}" 2>/dev/null || {
        rm -f "${_set_tmp}" 2>/dev/null || :
        return 1
    }
    sync 2>/dev/null || :
    [ "$(tail -n 1 "${_set_file}" 2>/dev/null)" = "${_set_new}" ]
}

# ab_net_follow_due <slot>: is there a follow outstanding for this slot?
#
# The rule belongs to the library that owns the record: once it is loaded, its answer
# (`ab_packages_follow_due`) is the one that counts, and this function is a thin alias so the
# two carriers ask the same question.
#
# What is left here is the case where that library is not on the machine (a partial install, a
# chroot, a test that only supplies a stub). It restates the rule for the two shapes of record
# that exist:
#
#   * a record with a `follow=` field: `followed`, `failed`, `abandoned` and `never` are
#     settled and never retried by a timer - a failed transaction is the user's to re-run
#     (`ab-packages update`), and an abandoned one already waited a day;
#   * a record from before that field: one attempt per base, keyed on `refresh=<version>`.
#
# ab-boot states the same fallback rule as `packages_refresh_due`, because a boot hook cannot
# be sourced by a hotplug hook. tests/modules/upgrade/test_net_probe.sh asserts that the two
# restatements agree on the same records, that the loaded owner's gate is the one used, and
# names the single shape where the fallback is stricter: a record with neither `follow=` nor a
# usable `version=` is due for the owner and not for the boot carrier, which then starts no
# worker for a base it cannot name.
ab_net_follow_due() {
    [ -n "${1:-}" ] || return 1
    if [ "${AB_NET_ENTRY_LOADED:-0}" = "1" ] && command -v ab_packages_follow_due >/dev/null 2>&1; then
        ab_packages_follow_due "$1"
        return $?
    fi
    _due_file="$(ab_net_record_file)"
    [ -r "${_due_file}" ] || return 1
    _due_follow="$(ab_net_record_field follow)"
    case "${_due_follow}" in
        '' | pending) ;;
        *) return 1 ;;
    esac
    _due_slot="$(ab_net_record_field slot)"
    [ -z "${_due_slot}" ] || [ "${_due_slot}" = "$1" ] || return 1
    [ -n "${_due_follow}" ] && return 0
    _due_version="$(ab_net_record_field version)"
    case "${_due_version}" in
        '' | unknown) return 1 ;;
    esac
    [ "$(ab_net_record_field refresh)" = "${_due_version}" ] && return 1
    return 0
}

# ab_net_running_slot: the slot this boot runs, from the kernel command line the way the
# initramfs reads it. A hotplug event has no other way to know which base it is on.
ab_net_running_slot() {
    [ -r "${AB_CMD}" ] || return 1
    _slot_value="$(tr ' \t' '\n\n' <"${AB_CMD}" 2>/dev/null | sed -n 's/^ab\.slot=//p' | head -n 1)"
    case "${_slot_value}" in
        a | b) printf '%s' "${_slot_value}" ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------- #
# The probe
# --------------------------------------------------------------------------- #

# ab_net_probe_url <target-dir>: the index URL to ask for.
#
# Read from the same files apk reads, in the same order (repositories.d/*.list first: that
# is the only place this image keeps feeds). `customfeeds.list` is skipped - it is the
# user's own list and it is not what decides whether this base can be followed - and a
# `targets/` line wins over a `packages/` line because it is the same release, the same
# mirror and a hundred times smaller.
ab_net_probe_url() {
    for _url_file in "$1/etc/apk/repositories.d/"*.list \
        "$1/etc/apk/distfeeds.list" "$1/etc/apk/repositories"; do
        [ -f "${_url_file}" ] || continue
        case "${_url_file}" in
            */customfeeds.list) continue ;;
        esac
        _url_first=""
        _url_target=""
        while IFS= read -r _url_line; do
            [ -n "${_url_line}" ] || continue
            [ -n "${_url_first}" ] || _url_first="${_url_line}"
            case "${_url_line}" in
                */targets/*) _url_target="${_url_line}" ;;
            esac
        done <<EOF
$(awk '/^[ \t]*https?:\/\// { sub(/^[ \t]*/, ""); sub(/[ \t].*/, ""); print }' "${_url_file}" 2>/dev/null)
EOF
        if [ -n "${_url_target}" ]; then
            printf '%s' "${_url_target}"
            return 0
        fi
        if [ -n "${_url_first}" ]; then
            printf '%s' "${_url_first}"
            return 0
        fi
    done
    return 1
}

# ab_net_probe_body <url> <out>: the first bytes of <url> into <out>.
#   0   the fetcher wrote something (possibly nothing: an empty body is a fact too)
#   <n> the fetcher's own status: uclient-fetch answers 4 for a network error, so no small
#       number can be reserved here
#   3   there is no URL to ask
#   127 there is no fetcher on this machine (the shell's "command not found", which no
#       fetcher of ours returns)
ab_net_probe_body() {
    if [ -n "${AB_NET_PROBE_INPUT}" ]; then
        [ -r "${AB_NET_PROBE_INPUT}" ] || return 1
        head -c 64 "${AB_NET_PROBE_INPUT}" >"$2" 2>/dev/null || return 1
        return 0
    fi
    [ -n "$1" ] || return 3
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T "${AB_NET_PROBE_TIMEOUT}" -O "$2" "$1" >/dev/null 2>&1
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T "${AB_NET_PROBE_TIMEOUT}" -O "$2" "$1" >/dev/null 2>&1
        return $?
    fi
    return 127
}

# ab_net_probe [target-dir]: ok | portal | offline | unknown.
#
#   ok       the answer starts with the apk index magic: this is a feed, not a web page
#   portal   bytes came back and they are not a feed: a captive portal, a proxy, a
#            hijacked DNS answer, an error page
#   offline  nothing came back: no route, refused, timed out (measured: 8.05 s against a
#            blackholed address with -T 8, 0.03 s against a closed port)
#   unknown  this machine cannot ask (no feed URL in the target, or no fetcher at all).
#            The caller tries the transaction anyway: an unanswered question must not stop
#            a follow that might work, and the transaction is the thing that knows.
#
# The magic is compared with `head -c 4` + `cmp -s` because the device has neither `od` nor
# `xxd`. A body shorter than four bytes fails the comparison, which is the honest answer.
ab_net_probe() {
    _probe_dir="${AB_NET_PROBE_TMP}/ab-net-probe.$$"
    rm -rf "${_probe_dir}" 2>/dev/null || :
    mkdir -p "${_probe_dir}" 2>/dev/null || {
        printf 'unknown'
        return 0
    }
    _probe_url="${AB_NET_PROBE_URL}"
    [ -n "${_probe_url}" ] || _probe_url="$(ab_net_probe_url "${1:-${AB_PACKAGES_TARGET}}")"
    : >"${_probe_dir}/body"
    ab_net_probe_body "${_probe_url}" "${_probe_dir}/body"
    case $? in
        3 | 127)
            rm -rf "${_probe_dir}" 2>/dev/null || :
            printf 'unknown'
            return 0
            ;;
    esac
    head -c 4 "${_probe_dir}/body" >"${_probe_dir}/head" 2>/dev/null || :
    printf '%s' "${AB_NET_PROBE_MAGIC}" >"${_probe_dir}/magic"
    if cmp -s "${_probe_dir}/head" "${_probe_dir}/magic"; then
        rm -rf "${_probe_dir}" 2>/dev/null || :
        printf 'ok'
        return 0
    fi
    if [ -s "${_probe_dir}/body" ]; then
        rm -rf "${_probe_dir}" 2>/dev/null || :
        printf 'portal'
        return 1
    fi
    rm -rf "${_probe_dir}" 2>/dev/null || :
    printf 'offline'
    return 2
}

# --------------------------------------------------------------------------- #
# The single-instance lock
#
# Risk 5 of design.md: a first-boot worker and a hotplug event can meet, and two apk
# transactions must never interleave. `mkdir` is atomic, so the lock is a directory -
# but a directory left by a killed worker would then refuse every later attempt, so it
# carries an owner line and is taken over when no live process of this boot can hold it
# (the rule ab-slot uses for its state lock: no owner, another boot id, or a dead pid).
# --------------------------------------------------------------------------- #

# ab_net_lock_dir: the lock directory this machine can actually use.
#
# /var/lock is the documented path and the right one on the image (tmpfs: nothing survives
# a power cut). Measured: a checkout, a chroot and the CI host have no writable /var/lock,
# and the ESP carries the identical lock there.
ab_net_lock_dir() {
    _lock_parent="$(dirname "${AB_NET_FOLLOW_LOCK}" 2>/dev/null)"
    if [ -n "${_lock_parent}" ] && mkdir -p "${_lock_parent}" 2>/dev/null && [ -w "${_lock_parent}" ]; then
        printf '%s' "${AB_NET_FOLLOW_LOCK}"
        return 0
    fi
    mkdir -p "${AB_ESP}/ab" 2>/dev/null || return 1
    printf '%s' "${AB_ESP}/ab/.follow.lock"
}

# ab_net_lock_own <dir>: say who holds the lock, and since when.
ab_net_lock_own() {
    _own_boot="$(cat "${AB_BOOT_ID_FILE}" 2>/dev/null)" || _own_boot=""
    [ -n "${_own_boot}" ] || _own_boot="unknown"
    printf 'pid=%s boot=%s at=%s\n' "$$" "${_own_boot}" "$(ab_net_now)" \
        >"$1/owner" 2>/dev/null || :
    return 0
}

# ab_net_lock_take: 0 taken, 1 a live worker holds it, 2 there is no usable lock at all.
ab_net_lock_take() {
    _take_dir="$(ab_net_lock_dir)" || return 2
    if mkdir "${_take_dir}" 2>/dev/null; then
        ab_net_lock_own "${_take_dir}"
        return 0
    fi
    _take_pid="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "${_take_dir}/owner" 2>/dev/null | head -n 1)"
    _take_boot="$(sed -n 's/.*[ ]boot=\([^ ]*\).*/\1/p' "${_take_dir}/owner" 2>/dev/null | head -n 1)"
    _take_now_boot="$(cat "${AB_BOOT_ID_FILE}" 2>/dev/null)" || _take_now_boot=""
    if [ -n "${_take_pid}" ] && [ -n "${_take_now_boot}" ] &&
        [ "${_take_boot}" = "${_take_now_boot}" ] && kill -0 "${_take_pid}" 2>/dev/null; then
        return 1
    fi
    # Nobody alive can be holding it: this boot's writer died, the lock came from a
    # previous boot, or it was never finished. Take it over - and say "no usable lock"
    # (not "somebody else is running") if even that fails, so the ring log blames the
    # right thing.
    rm -rf "${_take_dir}" 2>/dev/null || :
    mkdir "${_take_dir}" 2>/dev/null || return 2
    ab_net_lock_own "${_take_dir}"
    return 0
}

# ab_net_lock_drop: release, idempotently.
ab_net_lock_drop() {
    _drop_dir="$(ab_net_lock_dir)" || return 0
    rm -rf "${_drop_dir}" 2>/dev/null || :
    return 0
}

# --------------------------------------------------------------------------- #
# The transaction the ladder calls
# --------------------------------------------------------------------------- #

# ab_net_follow_publish_network: the record says the network is why nothing ran.
#
# `reason=network` is the network layer's own verdict, but the record belongs to
# platform/lib/upgrade/packages.sh: when that library is loaded its publisher is used, so the
# hint and the field order stay its business. The in-place writer below is the fallback for a
# machine where the library is not there at all.
ab_net_follow_publish_network() {
    if [ "${AB_NET_ENTRY_LOADED:-0}" = "1" ] && command -v ab_packages_follow_pending >/dev/null 2>&1; then
        ab_packages_follow_pending network >/dev/null 2>&1 && return 0
    fi
    ab_net_record_set reason=network
}

# ab_net_follow_entry_load: source the follow library into this shell. Sourcing has to
# happen here and not in a `$(...)`: a function defined in a subshell is gone when it
# returns.
ab_net_follow_entry_load() {
    [ -f "${AB_PACKAGES_LIB}" ] || return 1
    if [ "${AB_NET_ENTRY_LOADED:-0}" != "1" ]; then
        # shellcheck source=platform/lib/upgrade/packages.sh disable=SC1090
        . "${AB_PACKAGES_LIB}"
        AB_NET_ENTRY_LOADED=1
    fi
    return 0
}

# ab_net_follow_entry_name: the entry this library exposes.
#
# The name is the one design.md §8/§9 gives the first-boot worker (`if_ready`: apply what
# the prefetch already fetched, if the record says there is something to do). The two older
# spellings are accepted so this unit does not have to land in the same commit as the
# library rewrite; the caller logs which one it used, so a skew is visible in the ring log
# instead of being guessed at.
ab_net_follow_entry_name() {
    for _name in ab_packages_follow_if_ready ab_packages_follow ab_packages_refresh; do
        if command -v "${_name}" >/dev/null 2>&1; then
            printf '%s' "${_name}"
            return 0
        fi
    done
    return 1
}

# ab_net_follow_call <entry> <slot> <rung> <probe>: one follow transaction.
#
# The library publishes its own verdict into the record; this only reads it back and puts
# it in the ring log, so an operator sees what the transaction did without opening the
# record. The state/reason/version variables are read under both spellings for the same
# version-skew reason as above.
ab_net_follow_call() {
    _call_entry=$1
    _call_slot=$2
    _call_rung=$3
    _call_probe=$4
    # `ab_packages_follow_if_ready <target-root> <slot>`: the slot is the entry's own gate
    # (a follow for the other slot is another base's business). Older spellings take one
    # argument and ignore the second.
    "${_call_entry}" "${AB_PACKAGES_TARGET}" "${_call_slot}"
    _call_rc=$?
    _call_state="${AB_PACKAGES_FOLLOW_STATE:-${AB_PACKAGES_REFRESH_STATE:-}}"
    _call_reason="${AB_PACKAGES_FOLLOW_REASON:-${AB_PACKAGES_REFRESH_REASON:-}}"
    _call_version="${AB_PACKAGES_FOLLOW_VERSION:-${AB_PACKAGES_REFRESH_VERSION:-}}"
    # The entry is asked after this shell has already seen the record as due, and the record can
    # change between the two (another rung finished first). An entry that returns 0 having run
    # no transaction then leaves every variable empty, and the log used to say
    # `result=unknown reason=unknown version=unknown` - which reads like a failure and was
    # measured on the device 2026-11-18. Name it for what it is.
    if [ "${_call_rc}" -eq 0 ] && [ -z "${_call_state}" ]; then
        _call_state=skipped
        _call_reason=nothing-due
        _call_version=${_call_version:-unknown}
    fi
    # The verdict of this rung, published for the carrier that has to act on it. It is the same
    # token the ring log line below carries, so a carrier and an operator reading that log can
    # never disagree about what this rung did.
    AB_NET_FOLLOW_RESULT=${_call_state:-unknown}
    _call_dropped="${AB_PACKAGES_FOLLOW_DROPPED_COUNT:-${AB_PACKAGES_REFRESH_DROPPED_COUNT:-0}}"
    case "${_call_dropped}" in
        '' | *[!0-9]*) _call_dropped=0 ;;
    esac
    # `mode=` is the mechanism the transaction actually used (`offline` = the prefetched files,
    # `online` = the feeds), and `upgraded=`/`kept=` are what it moved: the three facts ac-6 is
    # read from, next to the record rather than only inside it.
    ab_net_ring_log "stage=packages-refresh slot=${_call_slot} rung=${_call_rung} probe=${_call_probe} entry=${_call_entry} mode=${AB_PACKAGES_FOLLOW_MODE:-unknown} upgraded=${AB_PACKAGES_FOLLOW_UPGRADED:-0} kept=${AB_PACKAGES_FOLLOW_KEPT:-0} result=${_call_state:-unknown} reason=${_call_reason:-unknown} version=${_call_version:-unknown} dropped=${_call_dropped}"
    ab_net_say "ab-boot: package follow ${_call_state:-unknown} (${_call_reason:-unknown}) for ${_call_version:-unknown}"
    # What a prune dropped is its own milestone: a machine that lost world entries has to
    # be able to see it without reading the record, and the names are what an operator acts
    # on. The ring log carries every name; the console line stays readable.
    if [ "${_call_dropped}" -gt 0 ]; then
        _call_list="${AB_PACKAGES_FOLLOW_DROPPED_LIST:-${AB_PACKAGES_REFRESH_DROPPED_LIST:-unknown}}"
        ab_net_ring_log "stage=packages-prune slot=${_call_slot} result=ok dropped=${_call_dropped} version=${_call_version:-unknown} packages=${_call_list}"
        if [ "$(printf '%s' "${_call_list}" | tr ',' '\n' | grep -c .)" -gt 8 ]; then
            ab_net_say "ab-boot: ${_call_dropped} package(s) not offered by ${_call_version:-unknown} were dropped from slot ${_call_slot}'s world (list in ab/log/boot-0.log)"
        else
            ab_net_say "ab-boot: ${_call_dropped} package(s) not offered by ${_call_version:-unknown} were dropped from slot ${_call_slot}'s world (${_call_list})"
        fi
    fi
    return "${_call_rc}"
}

# --------------------------------------------------------------------------- #
# One rung of the ladder
# --------------------------------------------------------------------------- #

# ab_net_attempt <slot> <rung>: one rung.
#   0  the follow is settled: the entry ran, or the record says there is nothing to do
#   1  no usable network: nothing was run, the record says reason=network
#   2  another worker is running the transaction
#   3  nothing to run or nowhere to run it: the record keeps its pending state
#
# Whatever the answer, AB_NET_FOLLOW_RESULT ends up naming the verdict of this rung (empty when
# the rung never got as far as running the entry), which is what a carrier decides on.
ab_net_attempt() {
    _att_slot=$1
    _att_rung=$2
    # Cleared first: a rung that returns before it runs the entry must not leave the verdict of
    # an earlier rung of this shell behind for a carrier to act on.
    AB_NET_FOLLOW_RESULT=""
    ab_net_follow_due "${_att_slot}" || return 0
    ab_net_lock_take
    case $? in
        0) ;;
        2)
            ab_net_ring_log "stage=packages-refresh slot=${_att_slot} rung=${_att_rung} result=skipped reason=lock-unavailable"
            return 3
            ;;
        *)
            ab_net_ring_log "stage=packages-refresh slot=${_att_slot} rung=${_att_rung} result=skipped reason=locked"
            return 2
            ;;
    esac
    # The library that owns the record is asked from here on: it is loaded before the probe,
    # so the network verdict is published by its writer, and its due gate - not this file's
    # fallback - decides whether there is still work. Called after the lock, never before, so
    # a rung that loses the race costs nothing.
    ab_net_follow_entry_load || :
    if ! ab_net_follow_due "${_att_slot}"; then
        ab_net_lock_drop
        return 0
    fi
    # The prefetch exists so that this boot never needs the network - and the offline apply is
    # the *cheap* rung, not a fallback: measured 2026-11-18, the worker asked the feed before it
    # asked the library, so a machine with every body on the disk still waited four rungs for a
    # feed and only applied the follow on an ifup. The library owns the question
    # (`ab_packages_follow_can_offline`), and when it says yes the probe is not asked at all.
    _att_probe=""
    if command -v ab_packages_follow_can_offline >/dev/null 2>&1 \
        && ab_packages_follow_can_offline "${AB_PACKAGES_TARGET}"; then
        _att_probe="prefetched"
    fi
    [ -n "${_att_probe}" ] || _att_probe="$(ab_net_probe "${AB_PACKAGES_TARGET}")"
    case "${_att_probe}" in
        portal | offline)
            # The network is the reason, and the record has to say so: `follow=pending` with
            # no reason is a machine that looks like it was never asked.
            ab_net_follow_publish_network
            AB_NET_FOLLOW_RESULT=pending
            ab_net_ring_log "stage=packages-refresh slot=${_att_slot} rung=${_att_rung} probe=${_att_probe} result=pending reason=network"
            ab_net_say "ab-boot: no usable package feed (${_att_probe}), the follow stays pending"
            ab_net_lock_drop
            return 1
            ;;
    esac
    if ! ab_net_follow_entry_load || ! _att_entry="$(ab_net_follow_entry_name)"; then
        AB_NET_FOLLOW_RESULT=deferred
        ab_net_ring_log "stage=packages-refresh slot=${_att_slot} rung=${_att_rung} probe=${_att_probe} result=deferred reason=entry-missing lib=${AB_PACKAGES_LIB}"
        ab_net_say "ab-boot: ${AB_PACKAGES_LIB} exposes no follow entry, the record keeps follow pending"
        ab_net_lock_drop
        return 3
    fi
    ab_net_follow_call "${_att_entry}" "${_att_slot}" "${_att_rung}" "${_att_probe}"
    ab_net_lock_drop
    return 0
}

# --------------------------------------------------------------------------- #
# The two carriers
# --------------------------------------------------------------------------- #

# ab_net_follow_abandon <slot>: 24 h of an unusable network is a verdict, not a wait.
ab_net_follow_abandon() {
    ab_net_follow_entry_load || :
    if [ "${AB_NET_ENTRY_LOADED:-0}" = "1" ] && command -v ab_packages_follow_abandoned >/dev/null 2>&1; then
        if ! ab_packages_follow_abandoned >/dev/null 2>&1; then
            ab_net_ring_log "stage=packages-refresh slot=$1 result=fail reason=record-unwritable"
            ab_net_say "ab-boot: package follow gave up, but the record cannot be written"
            return 1
        fi
    elif ! ab_net_record_set follow=abandoned reason=network; then
        ab_net_ring_log "stage=packages-refresh slot=$1 result=fail reason=record-unwritable"
        ab_net_say "ab-boot: package follow gave up, but the record cannot be written"
        return 1
    fi
    ab_net_ring_log "stage=packages-refresh slot=$1 result=abandoned reason=network window=${AB_NET_FOLLOW_W3_DEADLINE}"
    ab_net_say "ab-boot: package follow abandoned after ${AB_NET_FOLLOW_W3_DEADLINE}s without a usable feed; ab-packages update retries it on demand"
    return 1
}

# ab_net_follow_long <slot> <started-at>: W3, every half hour until the deadline.
ab_net_follow_long() {
    _long_slot=$1
    _long_start=$2
    _long_rung=0
    while :; do
        _long_now="$(ab_net_now)"
        [ "$((_long_now - _long_start))" -lt "${AB_NET_FOLLOW_W3_DEADLINE}" ] || break
        ab_net_sleep "${AB_NET_FOLLOW_W3_INTERVAL}"
        _long_rung=$((_long_rung + 1))
        ab_net_attempt "${_long_slot}" "w3-${_long_rung}"
        case $? in
            0) return 0 ;;
            3) return 1 ;;
        esac
    done
    ab_net_follow_abandon "${_long_slot}"
}

# ab_net_follow_boot <slot>: W1 then W3. The detached first-boot worker calls this once and
# is the only thing that ever waits.
ab_net_follow_boot() {
    _boot_slot=${1:-?}
    _boot_start="$(ab_net_now)"
    _boot_rung=0
    for _boot_offset in ${AB_NET_FOLLOW_W1}; do
        case "${_boot_offset}" in
            '' | *[!0-9]*) continue ;;
        esac
        # The offsets are absolute, so the wait is what is left of the offset after the
        # attempts before it. An attempt that overran makes the next rung immediate rather
        # than pushing the whole window out.
        _boot_now="$(ab_net_now)"
        _boot_elapsed=$((_boot_now - _boot_start))
        _boot_wait=$((_boot_offset - _boot_elapsed))
        ab_net_sleep "${_boot_wait}"
        _boot_rung=$((_boot_rung + 1))
        ab_net_attempt "${_boot_slot}" "w1-${_boot_rung}"
        case $? in
            0) return 0 ;;
            3) return 1 ;;
        esac
    done
    ab_net_follow_long "${_boot_slot}" "${_boot_start}"
}

# ab_net_follow_ifup: W2, one attempt per `ifup`. An event is the best evidence that
# something changed, so it does not wait its turn behind a 30-minute sleep: it asks once,
# under the same lock, and a running worker makes it a no-op instead of a second
# transaction.
#
# This rung also reconciles the services procd lost, when the follow it just ran is the one
# that closed the window - see ab_net_follow_reconcile below.
ab_net_follow_ifup() {
    if [ -z "${1:-}" ]; then
        ab_net_ring_log "stage=packages-refresh result=skipped reason=slot-unknown"
        return 0
    fi
    ab_net_attempt "$1" w2-ifup
    _ifup_rc=$?
    ab_net_follow_reconcile "$1" "${_ifup_rc}"
    # The hook's own answer stays the same: an `ifup` is never failed, delayed or judged by
    # what the packages or the services did.
    return 0
}

# ab_net_follow_reconcile <slot> <attempt-status>: the repair a settled follow owes the boot.
#
# Why this rung has to do it at all: ab-boot hands the first boot's follow to a detached
# worker, and that worker reconciles after its own follow. On the machine this was written
# for, the first boot had no usable feed - the follow answered `result=pending reason=network`
# - so the worker had nothing to close and the follow was left to the `ifup` that arrived ten
# minutes later. That `ifup` followed (`result=followed`), and the boot carries no
# `stage=services-reconciled` line at all: procd had given up on dockerd while apk was
# replacing the package set, and the one repair written for that window was reachable from the
# worker only. So the rung that actually closes the window repairs it.
#
# Only a rung that really followed: `pending` and `failed` leave the window open, and
# restarting daemons then would race the transaction that is still moving packages; a rung
# that found nothing due never opened a window. The repair itself decides whether it is still
# wanted (it is once per boot, and ab-services.sh says so), so this function adds no second
# rule - and it never fails: the follow is a package question, the repair a service one.
ab_net_follow_reconcile() {
    _fr_slot=${1:-?}
    _fr_rc=${2:-1}
    [ "${_fr_rc}" = "0" ] || return 0
    [ "${AB_NET_FOLLOW_RESULT:-}" = "followed" ] || return 0
    # Sourced here rather than at the top of this file: the ladder's other rungs, the probe and
    # a test of either never need the service layer, and ab-boot's worker already has it.
    if ! command -v services_reconcile >/dev/null 2>&1 && [ -f "${AB_SERVICES_LIB}" ]; then
        # shellcheck source=platform/lib/ab-services.sh disable=SC1090
        . "${AB_SERVICES_LIB}"
    fi
    if ! command -v services_reconcile >/dev/null 2>&1; then
        # Without the library there is nothing to call, and a hook that stayed silent here
        # would look exactly like a repair that found nothing to do.
        ab_net_ring_log "stage=services-reconciled slot=${_fr_slot} result=skipped reason=services-lib-missing lib=${AB_SERVICES_LIB}"
        return 0
    fi
    # The status is the caller's to name: this rung's follow has settled, which is what the
    # one guard services_reconcile takes from its caller is about.
    services_reconcile "${_fr_slot}" 0
    return 0
}
