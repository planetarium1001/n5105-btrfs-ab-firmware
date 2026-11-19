#!/bin/sh
# ab-services - the one repair for the daemons procd lost while the packages moved.
#
# Why this is a library and not a function of the boot hook: the repair belongs to the
# *follow*, and the follow has two carriers. platform/etc/init.d/ab-boot hands the first
# boot's follow to a detached worker that reconciles once that follow has settled, and
# platform/etc/hotplug.d/iface/90-ab-packages gives an `ifup` another attempt at the same
# follow (through platform/lib/ab-net-probe.sh). While all of this lived inside the init
# script only the first carrier could reach it, and the measured consequence on 2026-11-19 was
# a boot whose follow completed on `ifup` (`result=followed`) and that carries no
# `stage=services-reconciled` line at all: dockerd stayed down for the rest of that boot even
# though the repair had been written for exactly that window.
#
# Both carriers therefore source this file. Nothing here decides whether a follow succeeded -
# the caller passes that in (`services_reconcile <slot> <follow-status>`), because only the
# carrier knows - and nothing here is allowed to fail a boot or a hook.
#
# POSIX sh, no `local`: the variables a function needs are `_`-prefixed and set in the
# caller's shell, which is this image's convention (see platform/lib/ab-net-probe.sh).

# --------------------------------------------------------------------------- #
# Inputs
# --------------------------------------------------------------------------- #

# Where the enabled services are linked, where their scripts live, how long the worker waits
# for procd to finish walking the boot scripts, and the four commands a test has to be able
# to take over - the uptime it reads, the procd query it asks, and the sleeper it waits with.
AB_BOOT_RC_DIR="${AB_BOOT_RC_DIR:-/etc/rc.d}"
AB_BOOT_INITD_DIR="${AB_BOOT_INITD_DIR:-/etc/init.d}"
AB_BOOT_SETTLE_S="${AB_BOOT_SETTLE_S:-120}"
AB_BOOT_SETTLE_WAIT_S="${AB_BOOT_SETTLE_WAIT_S:-180}"
AB_BOOT_UPTIME_FILE="${AB_BOOT_UPTIME_FILE:-/proc/uptime}"
AB_BOOT_PROCD_STATE_CMD="${AB_BOOT_PROCD_STATE_CMD:-}"
AB_BOOT_SLEEP_CMD="${AB_BOOT_SLEEP_CMD:-sleep}"

# --------------------------------------------------------------------------- #
# The two channels a caller may already own
# --------------------------------------------------------------------------- #

# services_log <line...>: one ring log line, written by whoever owns that file in this
# process.
#
# ab-boot's log_append and ab-net-probe's ab_net_ring_log apply the same truncation rule to
# the same file (`${AB_ESP}/ab/log/boot-0.log`), so which of the two writes is a detail of the
# carrier, not of the fact. Routing every line through this one name is what lets the code
# below be the same code on both paths, byte for byte in the log an operator reads.
services_log() {
	if command -v log_append >/dev/null 2>&1; then
		log_append "$*"
		return 0
	fi
	if command -v ab_net_ring_log >/dev/null 2>&1; then
		ab_net_ring_log "$*"
		return 0
	fi
	_fallback_dir="${AB_ESP:-/boot}/ab/log"
	mkdir -p "${_fallback_dir}" 2>/dev/null || return 0
	printf '%s\n' "$*" >>"${_fallback_dir}/boot-0.log" 2>/dev/null || :
	return 0
}

# services_say <line...>: the console milestone, on the channel the carrier already uses.
#
# The boot worker speaks to the serial console (ab-boot's console_say, and ab-net-probe turns
# its own ab_net_say into that same channel with AB_NET_SAY=1); a hotplug hook does not,
# because an `ifup` is not a milestone a serial log has to carry. Handing the line to whichever
# of the two the caller has keeps that policy where it already lives instead of repeating it
# here.
services_say() {
	if command -v console_say >/dev/null 2>&1; then
		console_say "$*"
		return 0
	fi
	if command -v ab_net_say >/dev/null 2>&1; then
		ab_net_say "$*"
		return 0
	fi
	printf '%s\n' "$*" >"${AB_CONSOLE_DEV:-/dev/console}" 2>/dev/null || :
	return 0
}

# services_reconciled_this_boot: has this boot's repair already run?
#
# `stage=services-reconciled ... result=ok|partial` is the answer, read from the ring log the
# boot rotates (so the file only ever describes the boot that is running). A `skipped` line
# does not count: nothing was repaired there, the window is still open, and the next carrier -
# the next `ifup`, the next rung of the boot worker - has to be allowed to try.
services_reconciled_this_boot() {
	_rb_log="${AB_ESP:-/boot}/ab/log/boot-0.log"
	[ -r "${_rb_log}" ] || return 1
	grep -q 'stage=services-reconciled .*result=ok' "${_rb_log}" 2>/dev/null && return 0
	grep -q 'stage=services-reconciled .*result=partial' "${_rb_log}" 2>/dev/null && return 0
	return 1
}

# services_reconcile_repaired <slot>: the answer the reconcile itself stops on, written out
# once so both the cheap check at its entry and the one after the settle wait read the same
# way. Returns 0 when the caller must stop.
services_reconcile_repaired() {
	services_reconciled_this_boot || return 1
	services_log "stage=services-reconciled slot=${1:-?} result=skipped reason=already-reconciled"
	return 0
}

# --------------------------------------------------------------------------- #
# Service reconciliation
#
# Measured on the reference machine on 2026-11-19: the first boot of a base that was just
# aligned moves the whole package set (one measured boot upgraded 128 packages and kept 138,
# the third-round matrix measured 168 and 97), and that window overlaps the boot scripts
# procd runs after this hook (S19 to S99). A daemon that starts inside the window finds a
# kmod missing or being replaced, fails its own initialisation, and nothing tries it again in
# this boot. dockerd was down on the same machine from 03:59Z to 05:20Z through more than 15
# machine restarts, while the machine's own record said the client was present and the daemon
# was not. A longer wait cannot repair this: procd starts each service once, so the repair has
# to be a *new* start, asked for once the boot has settled and the packages have stopped
# moving.
#
# The measured failure, from the first boot of the controlled hop on 2026-11-19:
#
#   dockerd: failed to start daemon: Error initializing network controller: error obtaining
#   controller instance: failed to register "bridge" driver: failed to add jump rules to ipv4
#   NAT table: ... Warning: Extension addrtype revision 0 not supported, missing kernel
#   module?
#
# The criterion is procd's own instance record, and it is deliberately NOT "every enabled
# service whose `running` answers non-zero". That wider rule was measured and rejected: a
# healthy boot of the reference machine has seven enabled services whose `running` answers
# non-zero, and not one of them is broken. Measured on the same machine in the same session,
# with the ubus record each one leaves behind:
#
#   system, ucitrack, gpio_switch, firewall, packet_steering, cron, openclash
#       no instance record at all - procd never reached procd_close_instance for them
#       (a one-shot script, a script that re-applies state on demand, or a start_service
#       that returned early because the machine's own configuration says nothing to do)
#   urandom_seed
#       an instance record that is not running, with exit_code=0 - it finished its job
#
# Starting those would re-run boot scripts out of procd's order, start a service the user
# turned off in its own configuration, and report `result=partial` on a machine where nothing
# is wrong, which destroys the one signal this line exists to carry.
#
# What is left after that filter is exactly the defect: an instance procd created, that is not
# running, and that exited non-zero. On the measured broken boot that set was `dockerd`
# (running=false, exit_code=1) and nothing else. The same rule covers a service that procd
# respawned into a crash loop, because such an instance also ends non-zero.
#
# Note what this deliberately does not rely on: dockerd's init script sets no
# `procd_set_param respawn`, so procd never logged a crash loop for it and never retried it.
# A rule keyed on the `s in a crash loop` line would have missed the one case that was
# measured, which is why the instance record is the signal and the log line is not.
# --------------------------------------------------------------------------- #

# boot_uptime: whole seconds since boot. A test points this at a file of its own, because
# the question the wait asks is about time and no test may spend it.
boot_uptime() {
	_bu_seconds="$(cut -d. -f1 "${AB_BOOT_UPTIME_FILE}" 2>/dev/null)"
	case "${_bu_seconds}" in
		'' | *[!0-9]*) printf '0' ;;
		*) printf '%s' "${_bu_seconds}" ;;
	esac
}

# boot_sleep <seconds>: the worker's sleeper, so a test does not wait for it.
boot_sleep() {
	case "${1:-}" in
		'' | *[!0-9]*) return 0 ;;
	esac
	[ "${1}" -gt 0 ] || return 0
	# shellcheck disable=SC2086  # deliberate: AB_BOOT_SLEEP_CMD is a command line
	${AB_BOOT_SLEEP_CMD} "${1}" 2>/dev/null || :
	return 0
}

# boot_waited_for_settle: wait, bounded, until procd has walked the boot scripts.
#
# Before procd has reached S99 every service after this hook has no instance record yet, so
# the reconcile would find nothing and could only report a zero it did not earn. Measured on
# the reference machine, procd reaches `- init complete -` at an uptime of about 19 s, so the
# default threshold of 120 s leaves room for a slower first boot. The wait is bounded because
# a machine whose uptime cannot be read must still get its one reconcile attempt.
boot_waited_for_settle() {
	_bw_settle="${AB_BOOT_SETTLE_S}"
	case "${_bw_settle}" in
		'' | *[!0-9]*) _bw_settle=120 ;;
	esac
	_bw_budget="${AB_BOOT_SETTLE_WAIT_S}"
	case "${_bw_budget}" in
		'' | *[!0-9]*) _bw_budget=180 ;;
	esac
	_bw_waited=0
	while [ "$(boot_uptime)" -lt "${_bw_settle}" ]; do
		[ "${_bw_waited}" -lt "${_bw_budget}" ] || return 1
		boot_sleep 5
		_bw_waited=$((_bw_waited + 5))
	done
	return 0
}

# services_procd_available: can this machine be asked what procd did with a service?
#
# Two things are needed and both are taken from the image rather than assumed: the ubus CLI
# and jsonfilter (which is what /lib/functions/procd.sh reads the same object with). A test
# supplies its own query, so it is always "available" there.
services_procd_available() {
	[ -n "${AB_BOOT_PROCD_STATE_CMD}" ] && return 0
	command -v ubus >/dev/null 2>&1 || return 1
	command -v jsonfilter >/dev/null 2>&1 || return 1
	return 0
}

# services_procd_state <name>: "<running> <exit>" for the first instance procd records.
#
#   0  the two values are on stdout
#   1  procd cannot be asked on this machine
#   2  procd records no instance for this service (it never reached procd_close_instance)
#
# The query is procd's own ubus object, which is what `/etc/init.d/<name> running` reads too;
# `exit_code` is the field that separates "finished its job" from "died", and `running` alone
# cannot. AB_BOOT_PROCD_STATE_CMD replaces the whole query, which is how a test drives every
# one of those three answers without a procd.
services_procd_state() {
	_sp_name="${1:?services_procd_state needs a service name}"
	if [ -n "${AB_BOOT_PROCD_STATE_CMD}" ]; then
		# shellcheck disable=SC2086  # deliberate: AB_BOOT_PROCD_STATE_CMD is a command line
		${AB_BOOT_PROCD_STATE_CMD} "${_sp_name}"
		return $?
	fi
	command -v ubus >/dev/null 2>&1 || return 1
	command -v jsonfilter >/dev/null 2>&1 || return 1
	_sp_json="$(ubus call service list "{\"name\":\"${_sp_name}\"}" 2>/dev/null)" || return 1
	_sp_running="$(printf '%s\n' "${_sp_json}" |
		jsonfilter -e "@[\"${_sp_name}\"].instances[*].running" 2>/dev/null | head -n 1)"
	# No instance is the answer for a service procd never instantiated, and it is not the same
	# fact as an instance that is down. The caller skips both, but only one of them is a
	# candidate for the repair, so the two are kept apart here rather than collapsed.
	[ -n "${_sp_running}" ] || return 2
	_sp_exit="$(printf '%s\n' "${_sp_json}" |
		jsonfilter -e "@[\"${_sp_name}\"].instances[*].exit_code" 2>/dev/null | head -n 1)"
	printf '%s %s\n' "${_sp_running}" "${_sp_exit:-0}"
	return 0
}

# services_failed: the enabled procd services that procd started and that died, one per line.
#
# A service is a candidate when it is linked into the boot sequence, its init script says
# procd owns it, and procd's record for it is an instance that is not running and that exited
# non-zero. The link is the enable state, so a service somebody enabled by hand is treated
# like any other, and one that is not linked is left alone: starting a service the user turned
# off would be this hook overriding a decision it does not own.
services_failed() {
	_sf_found=""
	for _sf_link in "${AB_BOOT_RC_DIR}"/S*; do
		[ -e "${_sf_link}" ] || continue
		_sf_name="${_sf_link##*/}"
		# `S99dockerd` -> `dockerd`; the rank is one or more digits.
		_sf_name="$(printf '%s\n' "${_sf_name}" | sed 's/^S[0-9][0-9]*//')"
		[ -n "${_sf_name}" ] || continue
		_sf_init="${AB_BOOT_INITD_DIR}/${_sf_name}"
		[ -x "${_sf_init}" ] || continue
		# A service that does not use procd is not procd's to repair, and its "not running"
		# means nothing: measured, `system` and `ucitrack` answer non-zero on a healthy boot.
		grep -q '^USE_PROCD=1' "${_sf_init}" 2>/dev/null || continue
		_sf_state="$(services_procd_state "${_sf_name}")" || continue
		_sf_running="${_sf_state%% *}"
		_sf_exit="${_sf_state#* }"
		[ "${_sf_running}" = "false" ] || continue
		case "${_sf_exit}" in
			'' | 0) continue ;;
		esac
		_sf_found="${_sf_found}${_sf_found:+ }${_sf_name}"
	done
	[ -n "${_sf_found}" ] || return 0
	printf '%s\n' "${_sf_found}" | tr ' ' '\n'
	return 0
}

# services_reconcile <slot> <follow-status>: give the daemons procd lost a second start.
#
# Called by whichever carrier saw the follow settle - the detached boot worker, or the `ifup`
# rung that completed the follow the boot could not - so it never holds the boot, and it never
# decides whether the follow succeeded: a service that still refuses to start is logged and
# the boot or the hook continues. What it has to make visible is whether it ran at all
# (`result=skipped` and the reason), which services procd lost (`down=`), how many starts it
# asked for (`started=`) and which starts were refused (`failed=`).
#
# Once per boot: a machine has one window and one repair, so a second carrier that gets here
# (an `ifup` after the boot worker, or the boot worker after an `ifup` that followed first)
# reports `result=skipped reason=already-reconciled` instead of starting the same daemons a
# second time and writing a second verdict for one repair.
services_reconcile() {
	_sr_slot="${1:-?}"
	_sr_follow_rc="${2:-0}"
	# Checked before the follow status below on purpose: whether this boot has already been
	# repaired is a fact about the machine, while the status handed in describes one attempt at
	# the follow. It is also checked before the settle wait, so a duplicate costs no sleep.
	if services_reconcile_repaired "${_sr_slot}"; then
		return 0
	fi
	# A follow that never settled moved nothing, so the window this repairs did not open.
	# Reporting a reconcile there would be a claim the machine cannot back with a fact.
	if [ "${_sr_follow_rc}" != "0" ]; then
		services_log "stage=services-reconciled slot=${_sr_slot} result=skipped reason=follow-unsettled"
		services_say "ab-boot: the package follow did not settle, no service to reconcile"
		return 0
	fi
	if ! boot_waited_for_settle; then
		services_log "stage=services-reconciled slot=${_sr_slot} result=skipped reason=boot-not-settled uptime=$(boot_uptime)"
		services_say "ab-boot: the boot did not settle in time, no service to reconcile"
		return 0
	fi
	# Asked again, because the wait above can be minutes long and the window has two carriers:
	# an `ifup` can be waiting for the same boot to settle while this one is. The loop below is
	# the part that must not run twice, so the answer is taken again here, right before it.
	if services_reconcile_repaired "${_sr_slot}"; then
		return 0
	fi
	# The query is answered once, up front: a machine without procd's ubus object cannot tell
	# "no service died" from "nobody looked", and the two must not produce the same line.
	if ! services_procd_available; then
		services_log "stage=services-reconciled slot=${_sr_slot} result=skipped reason=no-procd-query"
		services_say "ab-boot: procd cannot be asked, no service to reconcile"
		return 0
	fi
	_sr_down="$(services_failed)"
	# The comma-separated form is what the ring log carries; it is built from the same list the
	# loop below starts, so the two can never disagree.
	_sr_down_list="$(printf '%s\n' "${_sr_down}" | tr '\n' ',' | sed 's/,$//')"
	_sr_started=0
	_sr_failed=""
	# shellcheck disable=SC2086  # deliberate word splitting: one service name per line
	for _sr_service in ${_sr_down}; do
		if "${AB_BOOT_INITD_DIR}/${_sr_service}" start >/dev/null 2>&1; then
			_sr_started=$((_sr_started + 1))
			services_say "ab-boot: started ${_sr_service}, which procd lost during this boot"
		else
			_sr_failed="${_sr_failed}${_sr_failed:+,}${_sr_service}"
			services_say "ab-boot: ${_sr_service} is still down, its own start refused"
		fi
	done
	_sr_result=ok
	[ -z "${_sr_failed}" ] || _sr_result=partial
	services_log "stage=services-reconciled slot=${_sr_slot} result=${_sr_result} started=${_sr_started} failed=${_sr_failed:-none} down=${_sr_down_list:-none}"
	return 0
}
