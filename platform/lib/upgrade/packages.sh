#!/bin/sh
# packages.sh - make the target slot's package metadata describe the version it carries.
#
# A downgrade (or an upgrade) replaces the system tree but not the user's apk state: the
# writable layer carries `/etc/apk/world`, which pins the kernel the machine used to run,
# and a feed list (`/etc/apk/repositories.d/*.list` on the current image, `/etc/apk/
# distfeeds.list` on older ones), which still points at the old release. On a real machine
# that combination fails like this (measured on 2026-11-11, 20261111-12 quality.md):
#
#   apk add kmod-usb-storage        -> rc=0 and nothing happens
#   apk add kmod-usb-storage=6.12.87-r1
#                                   -> rc=99 kernel-6.12.103: breaks: ... satisfies: world[kernel=6.12.103]
#
# So installing a kmod for the kernel the machine is now running is impossible, and the
# failure text names neither cause. This library aligns the two files with the version the
# slot now carries, before the machine is allowed to try it.
#
# The alignment is offline and file-level on purpose:
#
#   * it never runs `apk`. A machine that upgrades while its feeds are unreachable is
#     normal, and "aligned" is a statement about the metadata, not about the network;
#   * it never adds or removes packages. `--force-broken-world` plus installing a different
#     kernel package would add a second owner of the ESP's kernel/initrd files, which is
#     exactly what ab-slot owns.
#
# What runs `apk` in this file is the *follow* half, and it is a separate layer from the
# aligner above: aligning metadata is offline and mechanical, following packages needs a
# network, a transaction and a record of what the transaction did. That layer is
# ab_packages_gate / ab_packages_prefetch / ab_packages_follow, further down; the two rules
# above (never run apk from the aligner, never add or remove packages) stay true for it.
#
# ab_packages_align <payload-dir> <target-slot> <target-sys> <target-upper>
#
#   Returns 0 when the target's metadata names the target version, non-zero with
#   AB_PACKAGES_REASON set when it cannot (nothing to align from, an unwritable file, a
#   rewrite that did not read back). AB_PACKAGES_KERNEL carries the identity that was
#   written, for the state line the caller publishes.
#
#   On success it also sets AB_PACKAGES_FOLLOW=pending and AB_PACKAGES_HINT, which the
#   caller publishes with the verdict (see ab_packages_record_follow_fields): a base whose
#   metadata was aligned has *not* had its packages followed yet, and saying so in the same
#   line is what keeps `packages=aligned` from being read as "the packages moved".
#
# Neither failure blocks the upgrade: the machine boots and runs, it just cannot install
# packages matched to its kernel until the metadata is fixed, and that is what the
# `packages=` field of `ab-slot status` is for.

# Read by the caller.
# shellcheck disable=SC2034
AB_PACKAGES_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_KERNEL=""
# A note that belongs with a *successful* alignment (today: `feeds-rewritten`, an edit of
# the user's that was moved rather than dropped). The record's `reason=` is written by the
# caller, which currently passes `none` on success; this variable is what a caller has to
# forward for the note to reach `ab/packages`.
# shellcheck disable=SC2034
AB_PACKAGES_ALIGN_NOTE=""
# The follow state a successful alignment hands to the caller: `pending`, because the
# packages have not moved yet - only their metadata describes the new base now. Empty when
# the alignment did not succeed, so a caller that publishes in both cases cannot turn a
# failed alignment into a promise that a follow is coming.
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW=""
# shellcheck disable=SC2034
AB_PACKAGES_HINT=""

# The three names whose version decides whether what is installed can run on this base.
#
# Measured 2026-11-18 on the device: the 25.12.0 base pins base-files=1933~... and
# kernel=6.12.87~..., the 25.12.2 base pins 1950~... and 6.12.103~...; the aligner moved
# only the kernel, so a machine crossing that pair kept a base-files pin from the release it
# left, and `apk info -v` disagreed with the feed the slot now reads. libc rides along for
# the same reason: it is the soname every binary in the slot links against, so a libc pin
# from another release describes a machine that no longer exists either.
AB_PACKAGES_PINS="kernel base-files libc"

_packages_fail() {
    AB_PACKAGES_REASON="$1"
    printf 'packages: %s\n' "$1" >&2
    return 1
}

# _packages_pin_lines <file> <name>: every `<name>=<version>` line of a world file, one per
# line. Written with sed rather than awk because it is also used to read the target base's
# own world inside a rewrite's read-back, where a second awk would need its own quoting.
_packages_pin_lines() {
    [ -f "$1" ] || return 0
    sed -n "s/^\($2=[^[:space:]]*\).*/\1/p" "$1"
}

# _packages_pin_versions <file> <name>: the distinct versions a world file pins for one name.
# Two different ones mean two of them were installed at some point - see the aligner.
_packages_pin_versions() {
    _pv_lines=$(_packages_pin_lines "$1" "$2")
    [ -n "${_pv_lines}" ] || return 0
    printf '%s\n' "${_pv_lines}" | sed "s/^$2=//" | sort -u
}

# _packages_base_pin <sys-root> <name>: what the *target base* pins for one name, as a whole
# `<name>=<version>` line, or empty when it does not pin it.
#
# The kernel falls back to the base's apk database: that is the contract the aligner already
# had (a slot whose payload carries no world file still carries an installed kernel), and a
# pin that is read from the wrong place would be a guess about the release.
_packages_base_pin() {
    _bp=$(_packages_pin_lines "$1/etc/apk/world" "$2")
    if [ -z "${_bp}" ] && [ "$2" = "kernel" ]; then
        _bp=$(_packages_kernel_from_db "$1/lib/apk/db/installed")
    fi
    printf '%s' "${_bp}"
}

# _packages_kernel_from_db <installed>: the kernel package the slot's apk database holds,
# as `kernel=<version>`. Used when the payload's own world file does not pin one.
_packages_kernel_from_db() {
    [ -f "$1" ] || return 0
    awk '
        /^P:kernel$/ { find = 1; next }
        /^$/ { find = 0 }
        find && /^V:/ { printf "kernel=%s\n", substr($0, 3); exit }
    ' "$1"
}

# _packages_version_from_manifest <payload-dir>: the version the payload claims.
_packages_version_from_manifest() {
    sed -n 's/.*"rootfs": *"\([^"]*\)".*/\1/p' "$1/manifest.json" 2>/dev/null | head -n 1
}

# _packages_rewrite <file> <awk-program> <awk -v args...>: rewrite through a copy, keep the
# original as <file>.ab-align.bak, and rename. A reader never sees half a file, and the
# original is still there to roll back to when the result does not read back.
_packages_rewrite() {
    _file="$1"
    _program="$2"
    shift 2
    _bak="${_file}.ab-align.bak"
    _tmp="${_file}.ab-align.$$"
    [ -f "${_bak}" ] || cp "${_file}" "${_bak}" 2>/dev/null || return 1
    # shellcheck disable=SC2086  # the -v assignments are single words by construction
    awk "$@" "${_program}" "${_file}" >"${_tmp}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        return 1
    }
    sync 2>/dev/null || true
    mv "${_tmp}" "${_file}" 2>/dev/null || {
        rm -f "${_tmp}" 2>/dev/null || true
        return 1
    }
    sync 2>/dev/null || true
    return 0
}

# _packages_restore <file>: put the pre-rewrite copy back (used when the read-back fails).
_packages_restore() {
    _bak="$1.ab-align.bak"
    [ -f "${_bak}" ] || return 1
    cp "${_bak}" "$1" 2>/dev/null || return 1
    sync 2>/dev/null || true
    return 0
}

# _packages_world_mismatch <file> <wanted line...>: 0 when some line for one of the wanted
# names differs from the wanted line. The wanted lines are whole `<name>=<version>` pairs, so
# "a line that starts with the wanted pin but is not it" (a longer version with the same
# prefix) counts as a mismatch: the read-back exists to catch a rewrite that landed wrong.
_packages_world_mismatch() {
    _wm_file=$1
    shift
    awk -v wants="$*" '
        BEGIN {
            n = split(wants, w, " ")
            for (i = 1; i <= n; i++) want[w[i]] = 1
        }
        {
            for (k in want) if (index($0, k) == 1 && $0 != k) bad = 1
        }
        END { exit bad ? 0 : 1 }
    ' "${_wm_file}"
}

# _packages_feeds_mismatch <file> <wanted version> [wanted kmods segment]: 0 when some
# /releases/<x>/ names another version, or - when a kernel-bound kmods segment is given -
# some /kmods/<segment>/ names another one.
#
# The kmods segment is only rewritten from a segment the *target* base ships itself (see
# _packages_kmods_segment): guessing a kernel build hash is worse than leaving the old one
# in plain sight, and the base's own feed file already carries the right one.
_packages_feeds_mismatch() {
    awk -v want="$2" -v kmods="${3:-}" '
        {
            rest = $0
            while (match(rest, /\/releases\/[0-9][0-9.]*\//)) {
                seg = substr(rest, RSTART + 10, RLENGTH - 11)
                if (seg != want) bad = 1
                rest = substr(rest, RSTART + RLENGTH)
            }
            rest = $0
            while (match(rest, /\/kmods\/[^\/]+\//)) {
                seg = substr(rest, RSTART + 7, RLENGTH - 8)
                if (kmods != "" && seg != kmods) bad = 1
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
        END { exit bad ? 0 : 1 }
    ' "$1"
}

# _packages_feed_files <root>: the repository files this root ships, one relative path per
# line, in the order apk consults them.
#
# repositories.d/*.list comes first because that is what apk-tools 3 reads, and on the
# measured image (192.168.2.49, 2026-11-18) it is the only place the feeds live: there is
# neither /etc/apk/distfeeds.list nor /etc/apk/repositories. The two older names are kept
# for images that use them, and are only ever handled when the base itself ships one - a
# file apk never opens must not be created just to be able to claim `aligned`.
_packages_feed_files() {
    for _ff in "$1/etc/apk/repositories.d/"*.list; do
        [ -f "${_ff}" ] || continue
        printf '%s\n' "${_ff#"$1"/}"
    done
    for _ff in "$1/etc/apk/distfeeds.list" "$1/etc/apk/repositories"; do
        [ -f "${_ff}" ] || continue
        printf '%s\n' "${_ff#"$1"/}"
    done
}

# _packages_kmods_segment <root>: the `kmods/<segment>` directory the root's own feeds
# name, or empty. This is where the target's kernel build hash comes from: it is not
# guessable, and the base's own file already states it.
_packages_kmods_segment() {
    _ks=""
    while IFS= read -r _kf; do
        [ -n "${_kf}" ] || continue
        _ks=$(sed -n 's#.*/kmods/\([^/]*\)/.*#\1#p' "$1/${_kf}" 2>/dev/null | head -n 1)
        [ -n "${_ks}" ] && break
    done <<KMODS
$(_packages_feed_files "$1")
KMODS
    printf '%s' "${_ks}"
}

# _packages_feed_normalize <file> <version> <kmods segment>: the file's content with every
# release segment (and, when one is known, every kmods segment) brought to the target's
# values, on stdout. Used twice: as the rewrite, and as the test that tells a pure shadow of
# the base's file from a file the user actually changed.
_packages_feed_normalize() {
    awk -v ver="$2" -v kmods="${3:-}" '
        {
            line = $0
            out = ""
            rest = line
            while (match(rest, /\/releases\/[0-9][0-9.]*\//)) {
                out = out substr(rest, 1, RSTART - 1) "/releases/" ver "/"
                rest = substr(rest, RSTART + RLENGTH)
            }
            line = out rest
            if (kmods != "") {
                out = ""
                rest = line
                while (match(rest, /\/kmods\/[^\/]+\//)) {
                    out = out substr(rest, 1, RSTART - 1) "/kmods/" kmods "/"
                    rest = substr(rest, RSTART + RLENGTH)
                }
                line = out rest
            }
            print line
        }
    ' "$1"
}

# _packages_feed_write <file> <version> <kmods segment>: rewrite one feed file in place
# through a copy, with the same rules as _packages_rewrite: a reader never sees half a file,
# the pre-rewrite copy is kept until the result reads back, and it comes back on a mismatch.
_packages_feed_write() {
    _fw_norm=$(_packages_feed_normalize "$1" "$2" "$3") || return 1
    _fw_bak="$1.ab-align.bak"
    [ -f "${_fw_bak}" ] || cp "$1" "${_fw_bak}" 2>/dev/null || return 1
    _fw_tmp="$1.ab-align.$$"
    if ! printf '%s\n' "${_fw_norm}" >"${_fw_tmp}" 2>/dev/null; then
        rm -f "${_fw_tmp}" 2>/dev/null || true
        return 1
    fi
    sync 2>/dev/null || true
    if ! mv "${_fw_tmp}" "$1" 2>/dev/null; then
        rm -f "${_fw_tmp}" 2>/dev/null || true
        return 1
    fi
    sync 2>/dev/null || true
    if [ "$(cat "$1" 2>/dev/null)" != "${_fw_norm}" ]; then
        _packages_restore "$1"
        return 1
    fi
    return 0
}

# _packages_feed_align_one <upper> <sys> <relative path> <version> <kmods segment>: bring one
# feed file into line, or say why it already is. Sets _packages_feed_result to
# none|shadow-dropped|rewritten and returns 1 only when the writable layer cannot be written.
#
# Three outcomes, never a guess:
#   * the writable layer has no copy, or the base does not ship the file -> nothing to do
#     (and nothing is created: that is how `aligned` came to describe a file apk never
#     opens);
#   * the copy is byte-identical to the base's own file, or differs from it in exactly the
#     release and kernel build the upgrade moves -> it is a shadow of the old base and is
#     dropped, so the base's own file wins and later upgrades stop inheriting it;
#   * anything else is the user's edit (a mirror, an extra feed, a comment) and is rewritten
#     in place, keeping every byte the upgrade does not have to move.
_packages_feed_align_one() {
    _fa_base="$2/$3"
    _fa_upper="$1/$3"
    _packages_feed_result="none"
    [ -f "${_fa_base}" ] || return 0
    [ -f "${_fa_upper}" ] || return 0
    _fa_base_text=$(cat "${_fa_base}" 2>/dev/null)
    if [ "$(cat "${_fa_upper}" 2>/dev/null)" = "${_fa_base_text}" ]; then
        rm -f "${_fa_upper}" 2>/dev/null || return 1
        _packages_feed_result="shadow-dropped"
        return 0
    fi
    if [ "$(_packages_feed_normalize "${_fa_upper}" "$4" "$5")" = "${_fa_base_text}" ]; then
        rm -f "${_fa_upper}" 2>/dev/null || return 1
        _packages_feed_result="shadow-dropped"
        return 0
    fi
    _packages_feed_write "${_fa_upper}" "$4" "$5" || return 1
    _packages_feed_result="rewritten"
    return 0
}

ab_packages_align() {
    _payload="$1"
    _target="$2"
    _sys="$3"
    _upper="$4"
    AB_PACKAGES_REASON=""
    AB_PACKAGES_KERNEL=""
    AB_PACKAGES_ALIGN_NOTE=""
    AB_PACKAGES_FOLLOW=""
    AB_PACKAGES_HINT=""

    _version="$(_packages_version_from_manifest "${_payload}")"
    if [ -z "${_version}" ]; then
        _packages_fail "payload-without-version"
        return 1
    fi
    # Defence in depth: the version is pasted into a feed path. `ab-upgrade` refuses a
    # version outside this character set already; a library that another caller drives must
    # not depend on that.
    case "${_version}" in
        .* | *[!A-Za-z0-9._~+-]*)
            _packages_fail "version-invalid"
            return 1
            ;;
    esac

    # 1. the identities the target base pins: kernel, base-files and libc, each read from the
    #    payload's tree, never from the running system, because the running system is the
    #    version being replaced. Which names are pinned at all is the base's answer: a base
    #    that does not pin one of them has no opinion about it, and inventing a pin for it
    #    would add a constraint the user never asked for.
    _want_kernel=$(_packages_base_pin "${_sys}" kernel)
    _want_base=$(_packages_base_pin "${_sys}" base-files)
    _want_libc=$(_packages_base_pin "${_sys}" libc)
    AB_PACKAGES_KERNEL="${_want_kernel:-unknown}"

    # 2. world in the writable layer: the pins that make apk refuse a package for this base.
    #    Every line of the three is moved, not just the first one: a world with two pins for
    #    one name would otherwise keep the second one and still report success.
    _world="${_upper}/etc/apk/world"
    _world_changed=0
    # What the read-back below expects; only names the world pins *and* the base pins end up
    # here, because those are the only lines this step is allowed to move.
    _pins_want=""
    if [ -f "${_world}" ]; then
        # shellcheck disable=SC2086  # a space separated list of names by construction
        for _name in ${AB_PACKAGES_PINS}; do
            _distinct=$(_packages_pin_versions "${_world}" "${_name}" | grep -c . || true)
            if [ "${_distinct:-0}" -gt 1 ]; then
                # Two different pins for one name mean two of them were installed at some
                # point (measured: a machine that ran two kernels). Picking one would be a
                # guess about the user's intent, and half a rewrite - one name moved, the
                # other left - is worse than none, because the slot would then describe a
                # release that never existed. Nothing at all is written, here or in the
                # feeds below.
                case "${_name}" in
                    kernel) _packages_fail "multiple-kernel-pins" ;;
                    *) _packages_fail "multiple-base-pins" ;;
                esac
                return 1
            fi
        done
        # A base that pins nothing this library owns has nothing to compare against, and a
        # world that pins one of them while the base says nothing cannot be moved: the two
        # cases are told apart by whether the base carries a world at all.
        if [ -z "${_want_kernel}" ] && [ -n "$(_packages_pin_lines "${_world}" kernel)" ]; then
            _packages_fail "kernel-unknown"
            return 1
        fi
        _need_rewrite=0
        _pins_moved=""
        for _name in ${AB_PACKAGES_PINS}; do
            _have=$(_packages_pin_lines "${_world}" "${_name}")
            [ -n "${_have}" ] || continue
            _want=$(_packages_base_pin "${_sys}" "${_name}")
            # The base does not pin this name: the pin is the user's, and the base has no
            # opinion about it. Moving it would replace a constraint with a guess.
            [ -n "${_want}" ] || continue
            _pins_want="${_pins_want} ${_want}"
            if [ "${_have}" != "${_want}" ]; then
                _need_rewrite=1
                _pins_moved="${_pins_moved} ${_name}"
            fi
        done
        if [ "${_need_rewrite}" = "1" ]; then
            if ! _packages_rewrite "${_world}" '
                    {
                        if (kw != "" && $0 ~ /^kernel=/) { print kw; next }
                        if (bw != "" && $0 ~ /^base-files=/) { print bw; next }
                        if (lw != "" && $0 ~ /^libc=/) { print lw; next }
                        print
                    }' -v kw="${_want_kernel}" -v bw="${_want_base}" -v lw="${_want_libc}"; then
                _packages_fail "world-unwritable"
                return 1
            fi
            _world_changed=1
        fi
    fi

    # 3. the feeds that are actually read. The file names come from the *base*, not from a
    #    list in this file: on the measured image apk reads /etc/apk/repositories.d/*.list
    #    and has neither /etc/apk/distfeeds.list nor /etc/apk/repositories, so writing those
    #    two made `aligned` a claim about a file apk never opens, while the real feed - a
    #    copy the writable layer inherited from the base it was snapshotted from - kept
    #    naming the old release and the old kernel's kmods directory.
    _feeds_shadow=0
    _feeds_rewritten=0
    _kmods=$(_packages_kmods_segment "${_sys}")
    while IFS= read -r _rel; do
        [ -n "${_rel}" ] || continue
        # customfeeds.list is the user's own feed list by definition: it names no release,
        # so it is never a shadow of the base's file and is never rewritten.
        case "${_rel}" in
            */customfeeds.list) continue ;;
        esac
        if ! _packages_feed_align_one "${_upper}" "${_sys}" "${_rel}" "${_version}" "${_kmods}"; then
            _packages_fail "distfeeds-unwritable"
            return 1
        fi
        case "${_packages_feed_result}" in
            shadow-dropped) _feeds_shadow=$((_feeds_shadow + 1)) ;;
            rewritten) _feeds_rewritten=$((_feeds_rewritten + 1)) ;;
        esac
    done <<FEEDS
$(_packages_feed_files "${_sys}")
FEEDS

    # 4. read back what was written: the verdict has to be evidence, not the intent. A
    #    rewrite that did not land is exactly the silent failure this whole task is about,
    #    and a rewrite that landed *wrong* (say, an `&` expanded inside the replacement) is
    #    worse than one that did not land, so the original comes back.
    # shellcheck disable=SC2086  # one `name=version` pair per word by construction
    if [ "${_world_changed}" = "1" ] && _packages_world_mismatch "${_world}" ${_pins_want}; then
        _packages_restore "${_world}"
        _packages_fail "world-not-verified"
        return 1
    fi
    while IFS= read -r _rel; do
        [ -n "${_rel}" ] || continue
        # customfeeds.list belongs to the user by definition, so the align loop above never
        # rewrites it. Reading it back here would demand that it name the target release and
        # would therefore report the skip itself as a failure: a base that ships the template
        # plus a writable layer that still names the old release - which is exactly what a
        # feed step leaves behind - would fail the whole alignment with a correct result in
        # hand. The two places have to agree on which files this library owns.
        case "${_rel}" in
            */customfeeds.list) continue ;;
        esac
        _feeds="${_upper}/${_rel}"
        [ -f "${_feeds}" ] || continue
        if _packages_feeds_mismatch "${_feeds}" "${_version}" "${_kmods}"; then
            _packages_restore "${_feeds}"
            _packages_fail "distfeeds-not-verified"
            return 1
        fi
    done <<FEEDS
$(_packages_feed_files "${_sys}")
FEEDS
    # The pre-rewrite copies are only useful until the result is proven; a `.ab-align.bak`
    # left in the user's own /etc would be junk nobody knows to delete. (`*.bak` next to a
    # feed file is the image's own copy, not this library's: it is never touched.)
    rm -f "${_world}.ab-align.bak" 2>/dev/null || true
    while IFS= read -r _rel; do
        [ -n "${_rel}" ] || continue
        rm -f "${_upper}/${_rel}.ab-align.bak" 2>/dev/null || true
    done <<FEEDS
$(_packages_feed_files "${_sys}")
FEEDS
    rm -f "${_upper}/etc/apk/distfeeds.list.ab-align.bak" 2>/dev/null || true
    rm -f "${_upper}/etc/apk/repositories.ab-align.bak" 2>/dev/null || true

    _packages_log="packages: ${_target} on ${_version}"
    [ "${_world_changed}" = "1" ] && _packages_log="${_packages_log}, world pinned${_pins_moved} to this base"
    [ "${_feeds_shadow}" -gt 0 ] && _packages_log="${_packages_log}, ${_feeds_shadow} shadowed feed file(s) dropped"
    [ "${_feeds_rewritten}" -gt 0 ] && _packages_log="${_packages_log}, ${_feeds_rewritten} edited feed file(s) moved to ${_version}"
    [ "${_world_changed}" = "0" ] && [ "${_feeds_shadow}" = "0" ] && [ "${_feeds_rewritten}" = "0" ] \
        && _packages_log="${_packages_log}, metadata already matched"
    # An edit of the user's was rewritten rather than dropped. The state stays `aligned` -
    # the feeds do describe this release now - and the note travels on AB_PACKAGES_REASON so
    # a caller that forwards it can say so in the record instead of calling it `none`.
    if [ "${_feeds_rewritten}" -gt 0 ]; then
        AB_PACKAGES_ALIGN_NOTE="feeds-rewritten"
        AB_PACKAGES_REASON="feeds-rewritten"
        printf 'packages: %s edited feed file(s) rewritten, user changes kept\n' \
            "${_feeds_rewritten}" >&2
    else
        AB_PACKAGES_ALIGN_NOTE=""
    fi
    # The metadata of this slot describes the new base now; its packages do not. The follow
    # state and the command that retries it travel to the caller, which publishes them in the
    # same line as the verdict: `packages=aligned` with no `follow=` would read as "the
    # packages moved", and that claim is the one this whole change exists to stop making.
    AB_PACKAGES_FOLLOW="pending"
    AB_PACKAGES_HINT="ab-packages update"
    printf '%s\n' "${_packages_log}" >&2
    return 0
}

# --------------------------------------------------------------------------- #
# Plugins: the one seam a declared package source enters a transaction through
#
# A plugin is data - a directory of key=value lines under /etc/ab/plugins.d - and
# platform/lib/ab-plugins.sh is the whole vocabulary of what it may say. This library knows
# exactly one thing about it: an optional hook, `ab_plugins_repos_append <root> <out>`, that
# appends the feeds of the plugins that are enabled *and* verified *and* unchanged since
# their check. Everything else here follows from two rules.
#
#   * One repository set per transaction. A command that reads the machine's own files today
#     reads the machine's own files *plus* the declared feeds tomorrow, and it reads them
#     from one file apk is pointed at with --repositories-file - never from a mix of some
#     paths that were redirected and some that were not. Two views of the same machine is how
#     a package appears to exist in one transaction and not in the next.
#   * Nothing changes when nothing is declared. `--repositories-file` appears only when a
#     plugin contributes a feed (ac-9): a machine with no plugin sends apk byte for byte the
#     command line it sent before plugins existed, because the alternative is a machine that
#     behaves differently depending on which code path asked.
#
# The declarations belong to the machine that is running, not to the tree apk is pointed at:
# a platform upgrade replaces the system tree and leaves /etc/ab alone, so reading the target
# tree for plugins would read a layer that is about to be replaced. `ab_packages_repos_file
# <root> <out>` therefore concatenates the *target's* feed files and appends the *running
# machine's* plugin feeds.
#
# Nothing in this section runs apk or reaches the network: it reads declarations, writes one
# file in /tmp, and the caller decides whether to use it.
# --------------------------------------------------------------------------- #

# _packages_plugins_root: where the declarations live. The running machine, with one
# exception - a test or a chroot has to be able to point them at a fixture without writing
# /etc, and production never sets AB_PLUGINS_ROOT.
_packages_plugins_root() {
    printf '%s' "${AB_PLUGINS_ROOT:-/}"
}

# _packages_plugins_lib_file: the plugin library to source, or nothing when this machine has
# none - which is a machine without plugins, not a broken one.
#
# Order: what the caller named, the copy that ships next to this file (a checkout, and the
# installed /lib/upgrade + /lib pair), then the installed path. AB_PACKAGES_LIB is how every
# caller already names this file, so its directory is the one place the sibling is knowable
# from a purely POSIX shell: a sourced file has no path of its own.
_packages_plugins_lib_file() {
    _plf_sibling=""
    if [ -n "${AB_PACKAGES_LIB:-}" ]; then
        _plf_sibling=$(dirname "${AB_PACKAGES_LIB}")/../ab-plugins.sh
    fi
    for _plf_try in "${AB_PLUGINS_LIB:-}" "${_plf_sibling}" /lib/ab-plugins.sh; do
        [ -n "${_plf_try}" ] || continue
        [ -f "${_plf_try}" ] || continue
        printf '%s' "${_plf_try}"
        return 0
    done
    return 1
}

# _packages_plugins_load: 0 when the append hook is defined in *this* shell.
#
# Loaded on demand rather than when this file is sourced: an image without the plugin library
# then keeps working exactly as before, and the aligner - which must never see a plugin - does
# not carry one into every shell that reads this file. The check is on the function, not on a
# flag, because a caller may have sourced the library already.
_packages_plugins_load() {
    command -v ab_plugins_repos_append >/dev/null 2>&1 && return 0
    _pll_file=$(_packages_plugins_lib_file) || return 1
    # shellcheck source=/dev/null
    . "${_pll_file}" 2>/dev/null || return 1
    command -v ab_plugins_repos_append >/dev/null 2>&1
}

# _packages_plugins_injected: 0 when a plugin contributes a feed right now.
#
# The same predicate the seam itself uses, so "is anything injected" and "does the file hold
# more than the machine's own feeds" cannot disagree.
_packages_plugins_injected() {
    _pji_count=""
    _packages_plugins_load || return 1
    _pji_count=$(ab_plugins_active_count "$(_packages_plugins_root)" 2>/dev/null) || return 1
    case "${_pji_count}" in
        '' | *[!0-9]* | 0) return 1 ;;
    esac
    return 0
}

# _packages_plugins_tmp: the directory the injected repositories file is written to.
#
# Named by mktemp, for one reason: the file this directory holds is opened for truncation by
# root, so a name anyone can guess - `/tmp/repositories`, or `ab-plugins.$$` - is a name anyone
# can pre-place as a symlink. mktemp picks the name and creates the directory 0700, so the
# only thing that can be inside it is what this process put there. The caller removes it with
# _packages_plugins_tmp_drop once the apk call that needed the file has returned.
_packages_plugins_tmp() {
    _ppt_dir=$(mktemp -d "${TMPDIR:-/tmp}/ab-plugins.XXXXXX" 2>/dev/null) || return 1
    printf '%s' "${_ppt_dir}"
}

# _packages_plugins_tmp_drop <dir>: remove a directory _packages_plugins_tmp made, and nothing
# else. The name is checked rather than trusted: a caller after an empty answer would otherwise
# hand `rm -rf` an empty or arbitrary path.
_packages_plugins_tmp_drop() {
    _ppt_drop=${1:-}
    [ -n "${_ppt_drop}" ] || return 0
    case "${_ppt_drop}" in
        "${TMPDIR:-/tmp}"/ab-plugins.*) rm -rf "${_ppt_drop}" 2>/dev/null || : ;;
    esac
    return 0
}

# _packages_plugins_skip <reason>: one journal line for "a declaration wanted to take part and
# could not".
#
# A file that cannot be written under /tmp degrades the transaction to the machine's own feeds.
# That degradation used to be silent, and silence is the wrong answer here: a prune asked
# against half the sources reads "the base does not offer this name" about a package a plugin
# feed carries, and drops the world entry. The journal is where that becomes a fact, and the
# caller that must not guess (`ab_packages_prune`) refuses instead.
_packages_plugins_skip() {
    ab_plugins_journal "${AB_ESP:-/boot}/ab/plugins.journal" "plugin-skip reason=$1"
    return 0
}

# ab_packages_repos_file <root> <out>: the repository set one transaction reads, in apk's own
# order - the root's feed files first (`repositories.d/*.list`, then `distfeeds.list`, then
# `repositories`), then the declared plugin feeds, one per line, after them: apk reads the
# file top to bottom and the base must win a tie.
#
# <out> is truncated first, so a second call describes the same set once rather than twice.
# Returns 0 when the result is non-empty, 1 otherwise - the same answer the gate has always
# read from its own copy, which this replaced.
ab_packages_repos_file() {
    _rpf_root=$1
    _rpf_out=$2
    : >"${_rpf_out}" 2>/dev/null || return 1
    while IFS= read -r _rpf_rel; do
        [ -n "${_rpf_rel}" ] || continue
        cat "${_rpf_root}/${_rpf_rel}" >>"${_rpf_out}" 2>/dev/null || :
    done <<FILES
$(_packages_feed_files "${_rpf_root}")
FILES
    if _packages_plugins_load; then
        # The running machine's declarations, regardless of the root the feeds came from.
        ab_plugins_repos_append "$(_packages_plugins_root)" "${_rpf_out}" 2>/dev/null || :
    fi
    [ -s "${_rpf_out}" ]
}

# _packages_apk_repos_args <root> [<dir>]: `--repositories-file <file>` when a plugin
# contributes a feed, and nothing at all when none does.
#
# The empty answer is the contract (ac-9). A caller writes
#
#   apk ... $(_packages_apk_repos_args "$root") ...
#
# and with no plugin the words expand to nothing, so the command line stays byte for byte the
# one it was before this seam existed. The two words are printed space separated and read
# back through word splitting, and the path may not contain a blank (it is a mktemp name).
#
# <dir> is for the one caller whose apk command line is built once and used by several
# invocations (ab-slot): it names a directory it made and will remove. Every other caller
# passes none, and the directory is made here - only after the predicate says a plugin is
# really in play, so a machine without plugins leaves nothing under /tmp per apk call. The
# caller that got a pair removes it with _packages_apk_repos_drop.
#
# An empty answer has two meanings and the caller must be able to tell them apart: "nothing is
# declared" is a machine with one feed set, while "a declaration is in play and its file could
# not be built" is a machine whose apk is about to read half its sources. The second one is
# journalled here, one line per apk call that loses it, and _packages_plugins_seam_lost is the
# predicate a caller that must not guess uses.
_packages_apk_repos_args() {
    _rpa_root=$1
    _rpa_tmp=${2:-}
    _packages_plugins_injected || return 0
    if [ -z "${_rpa_tmp}" ]; then
        _rpa_tmp=$(_packages_plugins_tmp) || {
            _packages_plugins_skip "tmp-unwritable"
            return 0
        }
    fi
    mkdir -p "${_rpa_tmp}" 2>/dev/null || {
        _packages_plugins_skip "tmp-unwritable"
        return 0
    }
    if ! ab_packages_repos_file "${_rpa_root}" "${_rpa_tmp}/repositories" 2>/dev/null; then
        _packages_plugins_tmp_drop "${_rpa_tmp}"
        _packages_plugins_skip "tmp-unwritable"
        return 0
    fi
    printf '%s %s\n' "--repositories-file" "${_rpa_tmp}/repositories"
}

# _packages_plugins_seam_lost: 0 when a declared feed is in play and the file that carries it
# cannot be made. Nothing is journalled here - this is the question, not the event, and the
# caller that asks it is about to refuse.
_packages_plugins_seam_lost() {
    _psl_tmp=""
    _packages_plugins_injected || return 1
    _psl_tmp=$(_packages_plugins_tmp) || return 0
    [ -n "${_psl_tmp}" ] || return 0
    _packages_plugins_tmp_drop "${_psl_tmp}"
    return 1
}

# _packages_apk_repos_drop <seam-args>: remove the private directory behind a
# `--repositories-file` pair, once the apk call that read the file has returned. The pair is
# the handle the callers already hold, so no caller has to learn a second return value.
_packages_apk_repos_drop() {
    _prd_file=${1:-}
    [ -n "${_prd_file}" ] || return 0
    # The last word is the file; the directory holding it is one component up. Removing the
    # file alone would leave an empty directory behind on every apk call.
    _prd_file=${_prd_file##* }
    _packages_plugins_tmp_drop "${_prd_file%/*}"
}

# _packages_plugins_suspend: one journal line when a transaction that meant to read declared
# feeds did not reach them (ac-7).
#
# It is a note, not a verdict: the verdict stays the record's existing `follow=pending
# reason=network`, written by the caller. A journal that cannot be written must not turn a
# network failure into a second failure, and ab_plugins_journal already returns 0 in that
# case.
_packages_plugins_suspend() {
    _packages_plugins_injected || return 0
    ab_plugins_journal "${AB_ESP:-/boot}/ab/plugins.journal" \
        "plugin-suspended reason=network"
    return 0
}

# --------------------------------------------------------------------------- #
# Package follow: one controlled reinstall, on the first boot of a new base
#
# The alignment above keeps the machine able to *ask* for packages that belong to the
# release it now runs; it does not make the installed packages belong to it. A machine that
# crosses a release keeps what apk installed under the old ABI - kmods built for the old
# kernel, libraries with the old soname - and nothing in the boot path used to notice.
#
# ab_packages_refresh <target-dir> is that follow-up, and it is the one place in this
# library that runs `apk`:
#
#   * once per base. ab-boot asks for it on the first boot of a slot an upgrade aligned,
#     and `refresh=<version>` in the published record is the "already attempted" marker,
#     so a machine that reboots every day reinstalls once, not every boot;
#   * behind a reachability probe that costs one HEAD request. `apk update` is never the
#     probe: a machine whose feed is down must not spend seven index fetches to learn it;
#   * never for the kernel package. It owns the ESP's kernel/initrd files, and a second
#     installer of those is exactly what ab-slot exists to prevent;
#   * with a fall-back: a full reinstall that fails degrades to the kernel/ABI subset
#     (kmod-*, libc, docker), and the record says which of the two happened. A subset that
#     works is worth more than a boot that came back from a half-installed world.
#
# Measured facts this was written against (device 192.168.2.49, 2026-11-18, apk-tools
# 3.0.5 on ImmortalWrt 25.12.2):
#
#   * /var is a symlink to /tmp, so the apk index cache does not survive a reboot; with an
#     empty cache `apk add` answers `(no such package)` and fetches nothing, so the
#     transaction opens with exactly one `apk update`;
#   * `apk add --force-reinstall` is accepted, and `apk add name=version` still resolves,
#     so the world's own constraints are passed through verbatim: a refresh must not
#     quietly drop a pin the user set;
#   * there is no `timeout` applet, hence _packages_refresh_bounded;
#   * the feeds live in /etc/apk/repositories.d/*.list, which is where the probe looks
#     first (that image has neither /etc/apk/distfeeds.list nor /etc/apk/repositories).
# --------------------------------------------------------------------------- #

# Read by the caller (ab-boot publishes them into its ring log).
# shellcheck disable=SC2034
AB_PACKAGES_REFRESH_STATE=""
# shellcheck disable=SC2034
AB_PACKAGES_REFRESH_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_REFRESH_VERSION=""
# What a prune dropped from the world, so the caller's ring log can name it.
# shellcheck disable=SC2034
AB_PACKAGES_REFRESH_DROPPED_COUNT=0
# shellcheck disable=SC2034
AB_PACKAGES_REFRESH_DROPPED_LIST=""
# Wall-clock cap for one apk transaction, and for the probe.
AB_PACKAGES_REFRESH_TIMEOUT="${AB_PACKAGES_REFRESH_TIMEOUT:-180}"
AB_PACKAGES_REFRESH_PROBE_TIMEOUT="${AB_PACKAGES_REFRESH_PROBE_TIMEOUT:-8}"

# _packages_refresh_record_file: the one line the state commands read.
_packages_refresh_record_file() {
    printf '%s' "${AB_PACKAGES_FILE:-${AB_ESP:-/boot}/ab/packages}"
}

# _packages_refresh_record_field <key>: one field of the published record, or empty.
_packages_refresh_record_field() {
    _rf=$(_packages_refresh_record_file)
    [ -r "${_rf}" ] || return 0
    sed -n "s/^packages=[a-z]* .* $1=\([^ ]*\).*/\1/p" "${_rf}" 2>/dev/null | tail -n 1
}

# _packages_refresh_record_state: the state the record already carries, `unknown` when it
# carries none. A follow that could not run keeps this verdict: the machine learnt nothing
# new about its packages, so it must not publish anything new about them.
_packages_refresh_record_state() {
    _rf=$(_packages_refresh_record_file)
    _rs=""
    [ -r "${_rf}" ] && _rs=$(sed -n 's/^packages=\([a-z]*\).*/\1/p' "${_rf}" 2>/dev/null | tail -n 1)
    case "${_rs}" in
        aligned | limited) printf '%s' "${_rs}" ;;
        *) printf 'unknown' ;;
    esac
}

# _packages_refresh_publish <state> <reason> <refresh-version>: republish the record.
#
# `reason=` has to stay the second field: ab-slot reads the state and the reason with one
# regex each. Everything after them (version=, kernel=, slot=) is kept exactly as the
# aligner wrote it - a refresh that rewrote those would become a second author of facts it
# did not establish. `refresh=` is appended because it is this function's own field.
_packages_refresh_publish() {
    _ps=$1
    _pr=$2
    _pv=$3
    # Optional: how many world entries a prune dropped, and which ones. They sit right after
    # reason= (the shape the record documents), and a line that does not carry them must not
    # inherit them from a previous run's verdict.
    _pd=${4:-0}
    _pl=${5:-}
    _file=$(_packages_refresh_record_file)
    _dir=$(dirname "${_file}")
    mkdir -p "${_dir}" 2>/dev/null || {
        printf 'packages: cannot create %s, the follow stays unrecorded\n' "${_dir}" >&2
        return 1
    }
    _old=""
    [ -r "${_file}" ] && _old=$(tail -n 1 "${_file}" 2>/dev/null)
    # Only a record this format understands is carried over. A hand-edited line or a file
    # that something else wrote must not have its words appended to this one: the result
    # would be a record no reader can take apart.
    case "${_old}" in
        packages=*) ;;
        *) _old="" ;;
    esac
    _line="packages=${_ps} reason=${_pr}"
    if [ "${_pd}" -gt 0 ] 2>/dev/null; then
        _line="${_line} world_dropped=${_pd}"
        [ -n "${_pl}" ] && _line="${_line} dropped=${_pl}"
    fi
    # shellcheck disable=SC2086  # the fields of a one-line record are single words by construction
    for _kv in ${_old}; do
        case "${_kv}" in
            packages=* | reason=* | refresh=* | world_dropped=* | dropped=*) continue ;;
        esac
        _line="${_line} ${_kv}"
    done
    _line="${_line} refresh=${_pv}"
    _tmp="${_file}.tmp.$$"
    if ! printf '%s\n' "${_line}" >"${_tmp}" 2>/dev/null; then
        rm -f "${_tmp}" 2>/dev/null || true
        printf 'packages: cannot write %s\n' "${_tmp}" >&2
        return 1
    fi
    sync 2>/dev/null || true
    if ! mv "${_tmp}" "${_file}" 2>/dev/null; then
        rm -f "${_tmp}" 2>/dev/null || true
        printf 'packages: cannot publish %s\n' "${_file}" >&2
        return 1
    fi
    sync 2>/dev/null || true
    # Read back: a record that did not land only makes the next boot ask again, which is
    # harmless; a record that landed *wrong* would be a verdict nobody wrote.
    if [ "$(tail -n 1 "${_file}" 2>/dev/null)" != "${_line}" ]; then
        printf 'packages: %s did not read back\n' "${_file}" >&2
        return 1
    fi
    AB_PACKAGES_REFRESH_STATE=${_ps}
    AB_PACKAGES_REFRESH_REASON=${_pr}
    AB_PACKAGES_REFRESH_VERSION=${_pv}
    if [ "${_pd}" -gt 0 ] 2>/dev/null; then
        AB_PACKAGES_REFRESH_DROPPED_COUNT=${_pd}
        AB_PACKAGES_REFRESH_DROPPED_LIST=${_pl}
    fi
    return 0
}

# _packages_refresh_version <target-dir> <record-version>: the token `refresh=` is keyed
# on. The aligner's own version= comes first, so a record reads `version=X ... refresh=X`;
# platform-release is the fallback for a record written before that field existed, and a
# value outside the character set (an unsubstituted @UPSTREAM_VERSION@) is never a key.
_packages_refresh_version() {
    case "${2:-}" in
        '' | unknown) ;;
        *)
            printf '%s' "$2"
            return 0
            ;;
    esac
    _rp="$1/etc/platform-release"
    if [ -r "${_rp}" ]; then
        _rv=$(sed -n 's/^UPSTREAM_VERSION=//p' "${_rp}" 2>/dev/null | head -n 1)
        case "${_rv}" in
            '' | .* | *[!A-Za-z0-9._~+-]*) : ;;
            *)
                printf '%s' "${_rv}"
                return 0
                ;;
        esac
    fi
    printf 'unknown'
}

# _packages_refresh_feed_url <target-dir>: the first repository URL apk would consult.
#
# <target-dir> is the *merged* root, so this reads exactly the file apk reads after the
# aligner has decided between a shadow and an edit - repositories.d/*.list first (apk-tools
# 3; the only place the measured image keeps its feeds), then the two older names for
# images that use them. customfeeds.list is skipped: it is the user's own list, never the
# file that decides whether this base can be followed.
_packages_refresh_feed_url() {
    for _feeds in "$1/etc/apk/repositories.d/"*.list \
        "$1/etc/apk/distfeeds.list" "$1/etc/apk/repositories"; do
        [ -f "${_feeds}" ] || continue
        case "${_feeds}" in
            */customfeeds.list) continue ;;
        esac
        _url=$(awk '/^[ \t]*https?:\/\// { sub(/^[ \t]*/, ""); sub(/[ \t].*/, ""); print; exit }' \
            "${_feeds}" 2>/dev/null)
        [ -n "${_url}" ] || continue
        printf '%s' "${_url}"
        return 0
    done
    return 1
}

# _packages_refresh_probe <url>: 0 when the feed answers at all, 1 when it does not, 2 when
# no fetcher exists. One HEAD request (spider): enough to tell "the mirror is down" from
# "the package is not there", and deliberately not an `apk update`.
_packages_refresh_probe() {
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q --spider -T "${AB_PACKAGES_REFRESH_PROBE_TIMEOUT}" "$1" >/dev/null 2>&1
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --spider -T "${AB_PACKAGES_REFRESH_PROBE_TIMEOUT}" "$1" >/dev/null 2>&1
        return $?
    fi
    return 2
}

# _packages_refresh_bounded <seconds> <command...>: run one command under a wall-clock cap.
# The measured machine has no `timeout` applet, so the cap is a watchdog: SIGTERM at the
# deadline, SIGKILL two seconds later, and 124 for the caller - the token coreutils
# `timeout` uses, so there is one status to recognise.
_packages_refresh_bounded() {
    _secs=$1
    shift
    case "${_secs}" in
        '' | *[!0-9]* | 0)
            "$@"
            return $?
            ;;
    esac
    "$@" &
    _bounded_pid=$!
    # The watchdog's own stdio is dropped: a `sleep` left behind by a command that
    # finished early must not hold the caller's stdout pipe open (measured: a captured
    # `$(...)` never returned until the full timeout had elapsed).
    (
        sleep "${_secs}"
        kill -TERM "${_bounded_pid}" 2>/dev/null || exit 0
        sleep 2
        kill -KILL "${_bounded_pid}" 2>/dev/null || :
    ) >/dev/null 2>&1 &
    _bounded_watch=$!
    wait "${_bounded_pid}"
    _bounded_rc=$?
    kill -TERM "${_bounded_watch}" 2>/dev/null || :
    wait "${_bounded_watch}" 2>/dev/null || :
    case "${_bounded_rc}" in
        143 | 137) return 124 ;;
    esac
    return "${_bounded_rc}"
}

# ab_packages_run_bounded <seconds> <command...>: the same watchdog, published.
#
# `ab-packages plugins check` has to cap one HEAD request and one `apk update` the way this
# library caps its own transactions, and a second copy of these rules is how the two would
# start disagreeing about what 124 means. A non-numeric or zero cap runs the command
# unbounded, exactly as _packages_refresh_bounded does.
ab_packages_run_bounded() {
    _packages_refresh_bounded "$@"
}

# _packages_refresh_apk <target-dir> <apk arguments...>: one apk command against the target
# root. Production passes "/", which is apk's own default; anything else is a sandbox and
# gets --root, so a transaction can never reach the running root by accident. --timeout is
# apk's network-inactivity cap; the wall-clock cap is the watchdog around it.
#
# It takes the plugin seam's feed set as well, and that is not decoration: the world prune
# (`_packages_prune_candidates`) asks apk which world entries this release cannot select, and
# a prune that cannot see a declared feed would answer "no such package" for a package a
# plugin offers - and drop it from the world. One repository view per machine, including the
# question of what a source offers.
_packages_refresh_apk() {
    _apk_root=$1
    shift
    # shellcheck disable=SC2086  # zero or two single-word arguments by construction
    _apk_repos=$(_packages_apk_repos_args "${_apk_root}")
    if [ -z "${_apk_root}" ] || [ "${_apk_root}" = "/" ]; then
        # shellcheck disable=SC2086
        _packages_refresh_bounded "${AB_PACKAGES_REFRESH_TIMEOUT}" \
            apk ${_apk_repos} --timeout "${AB_PACKAGES_REFRESH_TIMEOUT}" "$@"
    else
        # shellcheck disable=SC2086
        _packages_refresh_bounded "${AB_PACKAGES_REFRESH_TIMEOUT}" \
            apk --root "${_apk_root}" ${_apk_repos} --timeout "${AB_PACKAGES_REFRESH_TIMEOUT}" "$@"
    fi
    _apk_rc=$?
    _packages_apk_repos_drop "${_apk_repos}"
    return "${_apk_rc}"
}

# _packages_refresh_world <world-file> [full|subset]: the constraints to reinstall, one per
# line. Two kinds of entry are never passed on:
#   * `kernel` / `kernel=...`: ab-slot owns the ESP's kernel and initrd, and a second
#     package writing those files is the one thing the A/B tooling must not allow;
#   * `!name` constraints and `@tag` lines, which are not packages.
# The subset mode keeps the kernel/ABI-relevant part of the world, which is what a failed
# full transaction degrades to.
_packages_refresh_world() {
    [ -f "$1" ] || return 1
    awk -v want="${2:-full}" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            if (substr(line, 1, 1) == "!" || substr(line, 1, 1) == "@") next
            name = line
            sub(/[=<>~].*/, "", name)
            if (name == "kernel") next
            if (want == "subset") {
                if (name ~ /^kmod-/ || name == "libc" || name ~ /^libc-/ || name ~ /^docker/) print line
                next
            }
            print line
        }
    ' "$1"
}

# _packages_refresh_apk_capture <target-dir> <apk arguments...>: one apk command with both
# streams on stdout, because apk writes its solver verdict to stderr and a prune has to read
# it. Returns apk's own status.
_packages_refresh_apk_capture() {
    _cap_root=$1
    shift
    _cap_out=$(_packages_refresh_apk "${_cap_root}" "$@" 2>&1)
    _cap_rc=$?
    printf '%s\n' "${_cap_out}"
    return "${_cap_rc}"
}

# _packages_prune_candidates <target-dir> <constraint...>: the world entries apk itself calls
# "(no such package)", one name per line on stdout.
#
# The question "is this package offered by the release this slot runs" is answered by running
# the transaction the refresh would run, in --simulate: that is the failure the machine would
# hit, not a second opinion about it. A pin whose version is gone answers differently
# (`<pkg>-<version>:` plus `breaks: world[...]`), so it never looks like a missing package.
#
# Returns 0 when apk answered (with or without candidates), 1 when the transaction failed for
# some other reason: the caller must then leave the world alone, because a prune that cannot
# name what it drops is a mass delete.
_packages_prune_candidates() {
    _pcd_target=$1
    shift
    _pcd_out=$(_packages_refresh_apk_capture "${_pcd_target}" --simulate add --force-reinstall "$@")
    _pcd_rc=$?
    if [ "${_pcd_rc}" -eq 0 ]; then
        return 0
    fi
    _pcd_names=$(printf '%s\n' "${_pcd_out}" \
        | sed -n 's/^  \([^ ][^ ]*\) (no such package):$/\1/p' \
        | sed 's/[=<>~].*//')
    if [ -z "${_pcd_names}" ]; then
        printf 'packages: apk refused the transaction, and not with a missing package:\n' >&2
        printf '%s\n' "${_pcd_out}" | head -n 6 | sed 's/^/packages:   /' >&2
        return 1
    fi
    printf '%s\n' "${_pcd_names}" | sort -u
    return 0
}

# _packages_prune_confirm <target-dir> <candidates-file>: the candidates the indexes do not
# offer either, one name per line on stdout.
#
# Two independent answers, the same way the aligner reads its own writes back: the solver
# says "cannot select", the index says "not there". A candidate the index does offer is a pin
# whose version is gone, not a package this release lacks - dropping that entry would throw
# away something the user can still install.
_packages_prune_confirm() {
    _pcf_names=$(cat "$2" 2>/dev/null)
    [ -n "${_pcf_names}" ] || return 0
    # shellcheck disable=SC2086  # one word per package name by construction
    _pcf_offered=$(_packages_refresh_apk_capture "$1" search -q -e ${_pcf_names})
    while IFS= read -r _pcf_name; do
        [ -n "${_pcf_name}" ] || continue
        case " $(printf '%s' "${_pcf_offered}" | tr '\n' ' ') " in
            *" ${_pcf_name} "*) continue ;;
        esac
        printf '%s\n' "${_pcf_name}"
    done <"$2"
}

# _packages_prune_world <world-file> <drop-file>: remove exactly the named entries and keep
# every other byte. Verified on the way out: the count has to drop by exactly as many entries
# as were dropped, and no dropped name may still be in the file, or the pre-rewrite copy comes
# back. Returns 1 when the file could not be written or did not read back right.
_packages_prune_world() {
    _pww_world=$1
    _pww_drop=$2
    _pww_before=$(grep -c . "${_pww_world}" 2>/dev/null || true)
    _pww_n=$(grep -c . "${_pww_drop}" 2>/dev/null || true)
    _pww_before=${_pww_before:-0}
    _pww_n=${_pww_n:-0}
    if ! _packages_rewrite "${_pww_world}" '
            BEGIN {
                while ((getline _dropped < dropfile) > 0) {
                    if (_dropped == "") continue
                    drop[_dropped] = 1
                }
            }
            {
                name = $0
                sub(/[=<>~].*/, "", name)
                if (name in drop) next
                print
            }' -v dropfile="${_pww_drop}"; then
        return 1
    fi
    _pww_after=$(grep -c . "${_pww_world}" 2>/dev/null || true)
    if [ "${_pww_after:-0}" -ne "$((_pww_before - _pww_n))" ]; then
        _packages_restore "${_pww_world}"
        printf 'packages: the world lost %s entries instead of %s, restored\n' \
            "$((_pww_before - ${_pww_after:-0}))" "${_pww_n}" >&2
        return 1
    fi
    while IFS= read -r _pww_name; do
        [ -n "${_pww_name}" ] || continue
        if awk -v n="${_pww_name}" '
                { line = $0; sub(/[=<>~].*/, "", line); if (line == n) found = 1 }
                END { exit !found }' "${_pww_world}"; then
            _packages_restore "${_pww_world}"
            printf 'packages: %s is still in the world after the prune, restored\n' "${_pww_name}" >&2
            return 1
        fi
    done <"${_pww_drop}"
    rm -f "${_pww_world}.ab-align.bak" 2>/dev/null || true
    return 0
}

# _packages_prune_index_usable <target-dir> <world-file>: 0 when the indexes can answer at all.
#
# The prune's question is "does this release offer X", and an index that cannot be read
# answers "no" to everything - which is exactly the shape of a world where nothing is offered.
# The two must never be confused: dropping every entry because the index was missing is a mass
# delete dressed as a diagnostic. The canaries are names the world does not mention, so a feed
# that answers them is a feed that was read; only then is an "absent" answer believable.
# Measured 2026-11-18: `apk --root <dir>` with an empty cache answers nothing for every name.
_packages_prune_index_usable() {
    _piu_target=$1
    _piu_world=$2
    _piu_names=$(_packages_refresh_world "${_piu_world}" full \
        | awk '{ name = $0; sub(/[=<>~].*/, "", name); print name }')
    _piu_probe=""
    for _piu_canary in apk-openssl base-files busybox dropbear libc procd uci ubus; do
        case " ${_piu_names} " in
            *" ${_piu_canary} "*) continue ;;
        esac
        _piu_probe="${_piu_probe} ${_piu_canary}"
    done
    # Every canary happens to be in this world: fall back to the world's own names, which
    # still separates "read nothing" from "offered something".
    [ -n "${_piu_probe}" ] || _piu_probe=${_piu_names}
    [ -n "${_piu_probe}" ] || return 1
    # shellcheck disable=SC2086  # one word per package name by construction
    _piu_offered=$(_packages_refresh_apk_capture "${_piu_target}" search -q -e ${_piu_probe})
    # A name has to come back, not merely "some output": apk's warnings about a cache it
    # cannot read are output too, and a guard that counts them as an answer is no guard at
    # all. Measured 2026-11-18: a sandbox root answered with nothing but "opening from cache
    # ...: No such file or directory" and every world entry was dropped.
    _piu_words=$(printf '%s' "${_piu_offered}" | tr '\n' ' ')
    for _piu_name in ${_piu_probe}; do
        case " ${_piu_words} " in
            *" ${_piu_name} "*) return 0 ;;
        esac
    done
    return 1
}

# ab_packages_prune <target-dir>: drop the world entries the release this slot runs does not
# offer.
#
# A move between releases can leave the world naming packages the new base's feeds no longer
# carry (measured 2026-11-18: a 25.12.2 machine with community packages, downgrading to
# 25.12.0). Nothing else notices: the slot installs, and then *every* later apk transaction
# fails to solve because one world entry cannot be selected - including the reinstall this
# library runs and a plain `apk add kmod-x` by hand.
#
# Dropping the entry fixes the transactions and keeps everything else: the package stays
# installed, its files and its `/etc/config` stay exactly as they are (an unmanaged package is
# not a deleted one), and the record names what was dropped and why. `/data` and the user's
# configuration are never touched.
#
# The index has to be current - the caller refreshes it - because the answer comes from apk:
# first the transaction it would run (--simulate), then the indexes, so a pin whose version is
# gone is never mistaken for a package the release lacks.
#
# Sets AB_PACKAGES_PRUNE_COUNT / AB_PACKAGES_PRUNE_LIST / AB_PACKAGES_PRUNE_REASON.
# Returns 0 when the question was answered (whether or not anything was dropped), 1 when the
# world could not be rewritten, 2 when apk could not answer - nothing is ever touched then.
ab_packages_prune() {
    _prune_target=${1:-/}
    while [ "${#_prune_target}" -gt 1 ] && [ "${_prune_target%/}" != "${_prune_target}" ]; do
        _prune_target=${_prune_target%/}
    done
    AB_PACKAGES_PRUNE_COUNT=0
    AB_PACKAGES_PRUNE_LIST=""
    AB_PACKAGES_PRUNE_REASON=""

    _prune_world="${_prune_target}/etc/apk/world"
    if [ ! -s "${_prune_world}" ]; then
        AB_PACKAGES_PRUNE_REASON="world-empty"
        return 2
    fi
    _prune_full=$(_packages_refresh_world "${_prune_world}" full)
    if [ -z "${_prune_full}" ]; then
        return 0
    fi
    # A declared feed can carry a world entry the base does not: that is exactly what
    # `plugins apply` writes into the world. If its file cannot be built, every apk question
    # below is asked against the machine's own feeds alone, and "this release does not offer
    # the name" would be an answer about half the sources. That is not a smaller prune, it is
    # a wrong one, so it is refused the way every unanswerable prune is.
    if _packages_plugins_seam_lost; then
        AB_PACKAGES_PRUNE_REASON="prune-unanswerable"
        printf 'packages: a declared feed is in play and its repositories file cannot be built; nothing is dropped\n' >&2
        return 2
    fi
    _prune_tmp="${TMPDIR:-/tmp}/ab-packages-prune.$$"
    # shellcheck disable=SC2086  # one word per world constraint by construction
    if ! _packages_prune_candidates "${_prune_target}" ${_prune_full} \
        >"${_prune_tmp}" 2>"${_prune_tmp}.log"; then
        sed 's/^/packages: /' "${_prune_tmp}.log" >&2 2>/dev/null || true
        rm -f "${_prune_tmp}" "${_prune_tmp}.log"
        AB_PACKAGES_PRUNE_REASON="prune-unanswerable"
        return 2
    fi
    if [ ! -s "${_prune_tmp}" ]; then
        rm -f "${_prune_tmp}" "${_prune_tmp}.log"
        return 0
    fi
    # Two answers before anything is dropped: the index has to be readable (a feed that
    # cannot answer must not look like a release that offers nothing), and the caller has to
    # say its index refresh worked when it made one.
    case "${AB_PACKAGES_PRUNE_INDEX_OK:-1}" in
        0)
            rm -f "${_prune_tmp}" "${_prune_tmp}.log"
            AB_PACKAGES_PRUNE_REASON="index-stale"
            printf 'packages: the index refresh failed, nothing is dropped\n' >&2
            return 2
            ;;
    esac
    if ! _packages_prune_index_usable "${_prune_target}" "${_prune_world}"; then
        rm -f "${_prune_tmp}" "${_prune_tmp}.log"
        AB_PACKAGES_PRUNE_REASON="index-unusable"
        printf 'packages: the indexes answer nothing for any name, so no "missing" answer is believable; nothing is dropped\n' >&2
        return 2
    fi
    _prune_keep=$(cat "${_prune_tmp}")
    _prune_drop=$(_packages_prune_confirm "${_prune_target}" "${_prune_tmp}")
    if [ -z "${_prune_drop}" ]; then
        printf 'packages: apk cannot select %s, but the feed offers it (a pin, not a missing package); nothing dropped\n' \
            "$(printf '%s' "${_prune_keep}" | tr '\n' ' ')" >&2
        rm -f "${_prune_tmp}" "${_prune_tmp}.log"
        return 0
    fi
    printf '%s\n' "${_prune_drop}" >"${_prune_tmp}"
    if ! _packages_prune_world "${_prune_world}" "${_prune_tmp}"; then
        rm -f "${_prune_tmp}" "${_prune_tmp}.log"
        AB_PACKAGES_PRUNE_REASON="prune-unwritable"
        return 1
    fi
    AB_PACKAGES_PRUNE_COUNT=$(grep -c . "${_prune_tmp}" 2>/dev/null || true)
    AB_PACKAGES_PRUNE_LIST=$(grep . "${_prune_tmp}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    rm -f "${_prune_tmp}" "${_prune_tmp}.log"
    printf 'packages: %s world entr(ies) dropped, this release does not offer them: %s\n' \
        "${AB_PACKAGES_PRUNE_COUNT}" "${AB_PACKAGES_PRUNE_LIST}" >&2
    return 0
}

# SUPERSEDED. ab_packages_follow (further down) is the follow engine now: it gates the
# world on the target tree, prefetches the moving set, applies the prefetched bodies as files
# with no network at all, and writes the follow record from the transaction's own output.
#
# This function is kept because tests/modules/upgrade/test_packages_refresh.sh asserts its
# exact command lines, and it must not be reachable from the boot path: it decides by exit
# status, and the transaction it runs (`apk add --force-reinstall`) is the measured no-op -
# rc=0, `[APK unavailable, skipped]` per package, nothing moved. Retire it together with
# that test. Until ab-boot asks for ab_packages_follow_if_ready instead of this, a first boot
# still takes this path - that switch is the boot hook's own change, not this library's.
#
# ab_packages_refresh <target-dir>: make the installed packages belong to the base the
# machine now runs. Returns 0 when the whole world was reinstalled, 1 when the result is
# limited (degraded, stale feeds, unwritable record), 2 when the feed did not answer, 3
# when there was nothing to work with. Never reboots, never blocks a boot, and never
# touches /etc/config: the packages' own protected paths are apk's business, not this
# library's.
ab_packages_refresh() {
    _target=${1:-/}
    # `x/` and `x//` name the same directory; one trailing slash keeps every join below
    # a single one.
    while [ "${#_target}" -gt 1 ] && [ "${_target%/}" != "${_target}" ]; do
        _target=${_target%/}
    done
    AB_PACKAGES_REFRESH_STATE=""
    AB_PACKAGES_REFRESH_REASON=""
    AB_PACKAGES_REFRESH_VERSION=""
    AB_PACKAGES_REFRESH_DROPPED_COUNT=0
    AB_PACKAGES_REFRESH_DROPPED_LIST=""

    _previous=$(_packages_refresh_record_state)
    _version=$(_packages_refresh_version "${_target}" "$(_packages_refresh_record_field version)")
    AB_PACKAGES_REFRESH_VERSION=${_version}

    _world="${_target}/etc/apk/world"
    if [ ! -s "${_world}" ]; then
        printf 'packages: no world at %s, nothing to follow\n' "${_world}" >&2
        _packages_refresh_publish "${_previous}" "world-empty" "${_version}" || :
        return 3
    fi

    _feed=$(_packages_refresh_feed_url "${_target}")
    if [ -z "${_feed}" ]; then
        printf 'packages: no feed under %s/etc/apk, nothing to follow\n' "${_target}" >&2
        _packages_refresh_publish "${_previous}" "no-feeds" "${_version}" || :
        return 3
    fi

    # 1. one request, and no apk: this is the whole offline story.
    if ! _packages_refresh_probe "${_feed}"; then
        printf 'packages: %s did not answer, the follow is skipped (offline)\n' "${_feed}" >&2
        _packages_refresh_publish "${_previous}" "offline" "${_version}" || :
        return 2
    fi

    # 2. a feed that still names another release cannot make packages follow this base:
    #    whatever it resolves was built for the base the machine came from. Recording that
    #    is worth more than a no-op transaction published as `aligned`.
    _feed_release=$(printf '%s\n' "${_feed}" | sed -n 's#.*/releases/\([0-9][0-9.]*\)/.*#\1#p' | head -n 1)
    if [ -n "${_feed_release}" ] && [ "${_feed_release}" != "${_version}" ]; then
        printf 'packages: feed names release %s while the slot runs %s (feeds-stale)\n' \
            "${_feed_release}" "${_version}" >&2
        _packages_refresh_publish "limited" "feeds-stale" "${_version}" || :
        return 1
    fi

    _full=$(_packages_refresh_world "${_world}" full)
    if [ -z "${_full}" ]; then
        printf 'packages: the world holds nothing but entries this library does not own\n' >&2
        _packages_refresh_publish "${_previous}" "no-packages" "${_version}" || :
        return 0
    fi

    # 3. the full transaction. The index is fetched here because /var is a tmpfs on the
    #    measured image; its status is reported but the reinstall decides the verdict, since
    #    a warm cache can serve a transaction a failed index fetch did not need.
    _index_ok=0
    if _packages_refresh_apk "${_target}" update; then
        _index_ok=1
    else
        printf 'packages: apk update failed, the reinstall goes ahead on the cache\n' >&2
    fi

    # 3b. a world entry the target's own feeds do not offer poisons every later apk
    #     transaction on this slot - including the one below and a plain `apk add kmod-x` by
    #     hand. Drop those entries (the packages stay installed, with their configuration)
    #     and carry what was dropped into the record.
    AB_PACKAGES_PRUNE_INDEX_OK=${_index_ok}
    ab_packages_prune "${_target}" || :
    _dropped=${AB_PACKAGES_PRUNE_COUNT:-0}
    _dropped_list=${AB_PACKAGES_PRUNE_LIST:-}
    if [ "${_dropped}" -gt 0 ]; then
        AB_PACKAGES_REFRESH_DROPPED_COUNT=${_dropped}
        AB_PACKAGES_REFRESH_DROPPED_LIST=${_dropped_list}
        # The transaction below has to be built from the world as it is *now*: one name that
        # is no longer offered makes apk refuse the whole set.
        _full=$(_packages_refresh_world "${_world}" full)
        if [ -z "${_full}" ]; then
            printf 'packages: nothing this release offers is left in the world after the prune\n' >&2
            _packages_refresh_publish "limited" "pruned" "${_version}" "${_dropped}" "${_dropped_list}" || :
            return 0
        fi
    fi

    # shellcheck disable=SC2086  # one word per world constraint by construction
    _packages_refresh_apk "${_target}" add --force-reinstall ${_full}
    _rc=$?
    if [ "${_rc}" -eq 0 ]; then
        if [ "${_dropped}" -gt 0 ]; then
            # The survivors follow this base; the verdict still says something was dropped,
            # because a slot that lost packages is not `aligned` with the release's set.
            _packages_refresh_publish "limited" "pruned" "${_version}" "${_dropped}" "${_dropped_list}" || return 1
            return 0
        fi
        printf 'packages: reinstalled the whole world (%s entries) for %s\n' \
            "$(printf '%s\n' "${_full}" | grep -c .)" "${_version}" >&2
        _packages_refresh_publish "aligned" "none" "${_version}" || return 1
        return 0
    fi

    # 4. the fall-back: at least what the new kernel and the ABI need.
    _reason="apk-${_rc}"
    [ "${_rc}" -eq 124 ] && _reason="timeout"
    _subset=$(_packages_refresh_world "${_world}" subset)
    if [ -z "${_subset}" ]; then
        printf 'packages: the full reinstall failed (%s) and the world has no kernel/ABI subset\n' \
            "${_reason}" >&2
        _packages_refresh_publish "limited" "refresh-failed" "${_version}" "${_dropped}" "${_dropped_list}" || :
        return 1
    fi
    printf 'packages: the full reinstall failed (%s), falling back to %s kernel/ABI entries\n' \
        "${_reason}" "$(printf '%s\n' "${_subset}" | grep -c .)" >&2
    # shellcheck disable=SC2086  # one word per world constraint by construction
    _packages_refresh_apk "${_target}" add --force-reinstall ${_subset}
    _rc=$?
    if [ "${_rc}" -eq 0 ]; then
        _packages_refresh_publish "limited" "partial" "${_version}" "${_dropped}" "${_dropped_list}" || return 1
        return 1
    fi
    _reason="apk-${_rc}"
    [ "${_rc}" -eq 124 ] && _reason="timeout"
    printf 'packages: the kernel/ABI subset failed too (%s)\n' "${_reason}" >&2
    _packages_refresh_publish "limited" "${_reason}" "${_version}" "${_dropped}" "${_dropped_list}" || :
    return 1
}

# --------------------------------------------------------------------------- #
# The follow record: one line, one writer, and only facts this engine established
#
# Shape (design.md §2):
#
#   packages=<aligned|followed|limited> reason=<token> follow=<state>
#            upgraded=<n> kept=<n> skipped=<kind:name,...> cache=<bytes>
#            dropped=<names> version=<base> kernel=<pin> slot=<a|b> hint=<command>
#
# Four rules that are not style:
#
#   * `reason=` stays the second field. `ab-slot status` reads the state and the reason with
#     one regex each, and a field in front of it silently turns the reason into the state;
#   * `hint=` is last because its value is a command with a space in it
#     (`ab-packages update`). Every field before it is a single word, which is what makes the
#     rest of the line splittable;
#   * a field this engine did not establish is carried over from the previous line, never
#     invented. version= / kernel= / slot= were established by the aligner, and an engine that
#     rewrote them would be a second author of facts it never measured;
#   * a line the format does not understand is replaced, not extended: an unrelated file glued
#     to this verdict is a record no reader can take apart.
# --------------------------------------------------------------------------- #

# Read by the caller after a publish, so a ring log can name what was recorded. These are the
# names the boot hook already reads (`stage=packages-refresh ... result=<state> reason=<token>
# version=<base>`); AB_PACKAGES_FOLLOW above is a different thing - the state a successful
# *alignment* hands over, before any follow has run.
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_STATE=""
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_VERSION=""

# _packages_record_get <key>: one field of the record, or empty. Only the last line is read:
# the record is one line, and a file that grew a second one was appended to by something that
# does not know the format.
_packages_record_get() {
    _rg_file=$(_packages_refresh_record_file)
    [ -r "${_rg_file}" ] || return 0
    tail -n 1 "${_rg_file}" 2>/dev/null | awk -v k="$1" '
        {
            for (i = 1; i <= NF; i++) {
                if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit }
            }
        }'
}

# _packages_record_state: the packages= verdict, `unknown` when the record carries none this
# library can name.
_packages_record_state() {
    _rst=$(_packages_record_get packages)
    case "${_rst}" in
        aligned | followed | limited) printf '%s' "${_rst}" ;;
        *) printf 'unknown' ;;
    esac
}

# _packages_record_state_keep <fallback>: the verdict already in the record when it is one this
# library can stand behind, else the fallback. A follow that could not run must not downgrade a
# verdict it did not re-measure, and a base nobody has followed yet starts from the fallback.
_packages_record_state_keep() {
    _rsk=$(_packages_record_state)
    case "${_rsk}" in
        unknown) printf '%s' "$1" ;;
        *) printf '%s' "${_rsk}" ;;
    esac
}

# _packages_reason_carry <fallback>: the reason a new line keeps when this engine has nothing
# new to say. A reason that describes a *transient* failure (this attempt found no network,
# this transaction failed) must not survive into the next line, or the machine keeps reporting
# a reason for an attempt that is over. `feeds-rewritten` is the opposite case: it is a fact
# about the user's own file, and it stays true until the next alignment.
_packages_reason_carry() {
    _rc_prev=$(_packages_record_get reason)
    case "${_rc_prev}" in
        '' | network | no-evidence | timeout | apk-* | declined | no-world | no-packages | no-apk)
            printf '%s' "$1"
            ;;
        *) printf '%s' "${_rc_prev}" ;;
    esac
}

# _packages_record_publish <state> <reason> <follow> <facts> <hint>: write the record.
#
# <facts> is a space separated `key=value` list appended after follow= (upgraded=, kept=,
# skipped=, cache=, dropped=) and may be empty. Returns 1 when the line could not be written or
# did not read back: a record that landed *wrong* is a verdict nobody wrote.
_packages_record_publish() {
    _pp_state=$1
    _pp_reason=$2
    _pp_follow=$3
    _pp_facts=${4:-}
    _pp_hint=${5:-none}
    _pp_file=$(_packages_refresh_record_file)
    _pp_dir=$(dirname "${_pp_file}")
    mkdir -p "${_pp_dir}" 2>/dev/null || {
        printf 'packages: cannot create %s, the follow stays unrecorded\n' "${_pp_dir}" >&2
        return 1
    }
    _pp_old=""
    [ -r "${_pp_file}" ] && _pp_old=$(tail -n 1 "${_pp_file}" 2>/dev/null)
    case "${_pp_old}" in
        packages=*) ;;
        *) _pp_old="" ;;
    esac
    # `hint=` is the last field and its value holds one space, so everything from it on is
    # dropped rather than carried word by word - the second word of a command is not a field.
    _pp_old=${_pp_old%% hint=*}
    _pp_line="packages=${_pp_state} reason=${_pp_reason} follow=${_pp_follow}"
    # shellcheck disable=SC2086  # the fact list is single words by construction
    for _pp_kv in ${_pp_facts}; do
        _pp_line="${_pp_line} ${_pp_kv}"
    done
    # shellcheck disable=SC2086  # the fields of a one-line record are single words by construction
    for _pp_kv in ${_pp_old}; do
        case "${_pp_kv}" in
            packages=* | reason=* | follow=* | upgraded=* | kept=* | skipped=* | cache=* \
                | dropped=* | world_dropped=* | hint=* | refresh=*)
                continue
                ;;
        esac
        _pp_line="${_pp_line} ${_pp_kv}"
    done
    _pp_line="${_pp_line} hint=${_pp_hint}"
    _pp_tmp="${_pp_file}.tmp.$$"
    if ! printf '%s\n' "${_pp_line}" >"${_pp_tmp}" 2>/dev/null; then
        rm -f "${_pp_tmp}" 2>/dev/null || true
        printf 'packages: cannot write %s\n' "${_pp_tmp}" >&2
        return 1
    fi
    sync 2>/dev/null || true
    if ! mv "${_pp_tmp}" "${_pp_file}" 2>/dev/null; then
        rm -f "${_pp_tmp}" 2>/dev/null || true
        printf 'packages: cannot publish %s\n' "${_pp_file}" >&2
        return 1
    fi
    sync 2>/dev/null || true
    if [ "$(tail -n 1 "${_pp_file}" 2>/dev/null)" != "${_pp_line}" ]; then
        printf 'packages: %s did not read back\n' "${_pp_file}" >&2
        return 1
    fi
    AB_PACKAGES_FOLLOW_STATE=${_pp_follow}
    AB_PACKAGES_FOLLOW_REASON=${_pp_reason}
    # The base the line describes, so a ring log can say which one it followed without reading
    # the record again. `unknown` when the aligner never published a version.
    AB_PACKAGES_FOLLOW_VERSION=$(_packages_record_get version)
    [ -n "${AB_PACKAGES_FOLLOW_VERSION}" ] || AB_PACKAGES_FOLLOW_VERSION="unknown"
    return 0
}

# ab_packages_record_follow_fields: what a caller appends to the align verdict so the record
# says a follow is still owed. Printed as `follow=pending hint=ab-packages update`, and empty
# when the alignment did not succeed - a failed alignment must not promise a follow.
ab_packages_record_follow_fields() {
    [ -n "${AB_PACKAGES_FOLLOW}" ] || return 0
    printf 'follow=%s hint=%s' "${AB_PACKAGES_FOLLOW}" "${AB_PACKAGES_HINT:-none}"
}

# ab_packages_follow_pending [reason]: publish the align-time verdict. `follow=pending` is the
# one field that makes a boot worker run at all, and `packages=` stays whatever the aligner
# established: the metadata is aligned, the packages have not moved.
ab_packages_follow_pending() {
    _fpd_reason=${1:-}
    [ -n "${_fpd_reason}" ] || _fpd_reason=$(_packages_reason_carry none)
    # The publish below owns packages=, reason=, follow= and hint=; everything the prefetch
    # established has to be handed over as a fact or the carry-over rules drop it, and the
    # first boot would then not know which entries were held back or what it has on disk.
    _fpd_facts=""
    for _fpd_key in upgraded kept skipped cache dropped; do
        _fpd_val=$(_packages_record_get "${_fpd_key}")
        [ -n "${_fpd_val}" ] && _fpd_facts="${_fpd_facts} ${_fpd_key}=${_fpd_val}"
    done
    _packages_record_publish "$(_packages_record_state_keep aligned)" "${_fpd_reason}" \
        pending "${_fpd_facts}" "ab-packages update"
}

# ab_packages_follow_never: the user chose to replace the system only. No state machine and no
# hint: there is nothing left to run, and saying `ab-packages update` would be a loop.
ab_packages_follow_never() {
    _packages_record_publish "$(_packages_record_state_keep aligned)" \
        "$(_packages_reason_carry none)" never "" "none"
}

# ab_packages_follow_abandoned: the network fallback ran out (W3, 24 hours). The packages stay
# where they are and the reason stays `network`, so a later reader can still explain it.
ab_packages_follow_abandoned() {
    _packages_record_publish "$(_packages_record_state_keep aligned)" network abandoned "" \
        "ab-packages update"
}

# _packages_follow_publish_pending <reason>: the follow could not run this time.
_packages_follow_publish_pending() {
    _fpp_reason=$1
    _packages_record_publish "$(_packages_record_state_keep aligned)" "${_fpp_reason}" \
        pending "" "ab-packages update" || :
    AB_PACKAGES_FOLLOW_REASON=${_fpp_reason}
}

# --------------------------------------------------------------------------- #
# The gate: three propositions, judged on the target tree, writing only /tmp
#
# design.md §5, and the reason each one is asked before the switch rather than after:
#
#   P  pin agreement - two file reads. A world that pins another release's kernel/base-files/
#      libc cannot follow this base, and no index fetch would change that answer.
#   S  solvability   - `apk --root <target> ... update` then `--simulate upgrade`. This is the
#      transaction the first boot would run, so an entry it cannot select is the failure the
#      machine would hit - not a second opinion about it.
#   L  local packages - `apk policy` names the sources a package comes from; one that only the
#      installed database answers for is a local .apk, and whether it can be replayed on this
#      base depends on a body being kept and on the kernel it was built against.
#
# Everything is measured, and nothing is written outside the gate's own /tmp directory: the
# index goes to --cache-dir there, the feed set to --repositories-file there, so an `update`
# cannot leave a cache inside the tree it is judging and a failed judgement leaves the target
# byte for byte as it was (ac-5).
#
# Results (read by the caller and by the plan renderer):
#   AB_PACKAGES_GATE_STATE    ok | blocked | gap
#   AB_PACKAGES_GATE_REASON   none | pin-mismatch | unsolvable | unreachable | no-world |
#                             no-apk | no-feeds | no-tmp
#   AB_PACKAGES_GATE_S/_P/_L  ok | blocked | gap | skipped
#   AB_PACKAGES_GATE_SKIPPED  `kind:name,...`, the attribution tokens of design.md §3
#   AB_PACKAGES_GATE_BLOCKED  the world entries apk could not select, space separated
#   AB_PACKAGES_GATE_INDEX    ok | failed - the index refresh, reported and not decisive
#   AB_PACKAGES_GATE_WORLD    upper | base - which world file the pins were read from
# --------------------------------------------------------------------------- #

AB_PACKAGES_GATE_TIMEOUT="${AB_PACKAGES_GATE_TIMEOUT:-60}"

# shellcheck disable=SC2034
AB_PACKAGES_GATE_STATE=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_S=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_P=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_L=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_INDEX=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_BLOCKED=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_SKIPPED=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_WORLD=""
# shellcheck disable=SC2034
AB_PACKAGES_GATE_PIN_DETAIL=""
AB_PACKAGES_GATE_TMPDIR=""

# _packages_gate_token_add <kind:name>: record one attribution, once.
_packages_gate_token_add() {
    case ",${AB_PACKAGES_GATE_SKIPPED}," in
        *",$1,"*) return 0 ;;
    esac
    if [ -n "${AB_PACKAGES_GATE_SKIPPED}" ]; then
        AB_PACKAGES_GATE_SKIPPED="${AB_PACKAGES_GATE_SKIPPED},$1"
    else
        AB_PACKAGES_GATE_SKIPPED="$1"
    fi
}

# _packages_gate_apk <root> <cache-dir> <repositories-file> <apk args...>: one apk command
# against the target tree, under the wall-clock cap. Both the index cache and the feed set are
# the gate's own copies in /tmp; --root is what makes the answer describe the target and not
# the machine that is running the gate.
_packages_gate_apk() {
    _ga_root=$1
    _ga_cache=$2
    _ga_repos=$3
    shift 3
    _packages_refresh_bounded "${AB_PACKAGES_GATE_TIMEOUT}" \
        apk --root "${_ga_root}" --cache-dir "${_ga_cache}" \
        --repositories-file "${_ga_repos}" "$@"
}

# _packages_gate_repos <root> <out-file>: the feeds the target will read, concatenated, or 1
# when the root ships none.
#
# One file would be the wrong question: passing only the base's distfeeds makes the user's own
# feeds invisible, so every package installed from a third-party source would look like one no
# source offers. The concatenation in apk's own order is the set apk reads on the booted
# machine, which is what a prediction has to describe.
#
# The set is `ab_packages_repos_file`'s, plugin feeds included: the gate is judging the first
# boot's transaction, and after this change that transaction reads them. With no plugin
# declared the file is the concatenation above, byte for byte, because the append hook only
# ever writes when one is.
_packages_gate_repos() {
    _gr_root=$1
    _gr_out=$2
    ab_packages_repos_file "${_gr_root}" "${_gr_out}"
}

# _packages_gate_pins <target-root> <sys-root>: P. Returns 0 when they agree, 1 when a pin
# names another release, 2 when there is no world to read.
#
# "Before and after the aligner" is decided as "the world the machine will boot with against
# the world the base ships": the aligner reads its own rewrite back before it reports success,
# so a rewrite that landed wrong is already `world-not-verified` and never reaches here.
_packages_gate_pins() {
    _gp_target=$1
    _gp_sys=$2
    _gp_world="${_gp_target}/etc/apk/world"
    AB_PACKAGES_GATE_WORLD="upper"
    if [ ! -s "${_gp_world}" ]; then
        _gp_world="${_gp_sys}/etc/apk/world"
        AB_PACKAGES_GATE_WORLD="base"
    fi
    [ -s "${_gp_world}" ] || return 2
    # shellcheck disable=SC2086  # a space separated list of names by construction
    for _gp_name in ${AB_PACKAGES_PINS}; do
        _gp_have=$(_packages_pin_lines "${_gp_world}" "${_gp_name}")
        [ -n "${_gp_have}" ] || continue
        if [ "$(_packages_pin_versions "${_gp_world}" "${_gp_name}" | grep -c . || true)" -gt 1 ]; then
            AB_PACKAGES_GATE_PIN_DETAIL="${_gp_name}: two pins"
            return 1
        fi
        _gp_want=$(_packages_base_pin "${_gp_sys}" "${_gp_name}")
        [ -n "${_gp_want}" ] || continue
        if [ "${_gp_have}" != "${_gp_want}" ]; then
            AB_PACKAGES_GATE_PIN_DETAIL="${_gp_name} ${_gp_have} vs ${_gp_want}"
            return 1
        fi
    done
    return 0
}

# _packages_gate_solve <root> <cache> <repos>: S. Returns 0 when apk can solve the world.
#
# The second call is the answer and the first one only fills the index: a machine that left
# /var on tmpfs has no cache at all, and a cache that already carries the index still answers
# after an `update` that failed. AB_PACKAGES_GATE_INDEX says which of the two happened, so a
# mirror problem is visible without being mistaken for an unsolvable world.
_packages_gate_solve() {
    _gs_root=$1
    _gs_cache=$2
    _gs_repos=$3
    if _gs_idx=$(_packages_gate_apk "${_gs_root}" "${_gs_cache}" "${_gs_repos}" update 2>&1); then
        AB_PACKAGES_GATE_INDEX="ok"
    else
        AB_PACKAGES_GATE_INDEX="failed"
    fi
    _gs_out=$(_packages_gate_apk "${_gs_root}" "${_gs_cache}" "${_gs_repos}" --simulate upgrade 2>&1)
    _gs_rc=$?
    [ "${_gs_rc}" -eq 0 ] && return 0
    # Two failures apk names differently, and they carry different tokens:
    #   `  name (no such package):`  - no source offers it at all            -> DROPPED
    #   `    breaks: world[name=v]`  - the version the world pins is gone    -> PINNED
    _gs_gone=$(printf '%s\n' "${_gs_out}" \
        | sed -n 's/^  \([^ ][^ ]*\) (no such package):$/\1/p' | sed 's/[=<>~].*//' | sort -u)
    _gs_pinned=$(printf '%s\n' "${_gs_out}" \
        | sed -n 's/^ *breaks: world\[\([^]]*\)\].*$/\1/p' | sed 's/[=<>~].*//' | sort -u)
    _gs_names=$(printf '%s\n%s\n' "${_gs_gone}" "${_gs_pinned}" | grep . | sort -u)
    while IFS= read -r _gs_name; do
        [ -n "${_gs_name}" ] || continue
        case " $(printf '%s' "${_gs_gone}" | tr '\n' ' ') " in
            *" ${_gs_name} "*) _packages_gate_token_add "gone:${_gs_name}" ;;
            *) _packages_gate_token_add "pinned:${_gs_name}" ;;
        esac
    done <<NAMES
${_gs_names}
NAMES
    AB_PACKAGES_GATE_BLOCKED=$(printf '%s\n' "${_gs_names}" \
        | awk 'NF { printf "%s%s", sep, $0; sep = " " }')
    if [ -n "${_gs_names}" ]; then
        AB_PACKAGES_GATE_REASON="unsolvable"
        printf 'packages: gate blocked, apk cannot select:\n' >&2
        printf '%s\n' "${_gs_names}" | head -n 5 | sed 's/^/packages:   /' >&2
        return 1
    fi
    if [ "${AB_PACKAGES_GATE_INDEX}" = "failed" ]; then
        AB_PACKAGES_GATE_REASON="unreachable"
        printf 'packages: gate blocked, the index refresh did not answer:\n' >&2
        printf '%s\n' "${_gs_idx}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
        printf '%s\n' "${_gs_out}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
        return 1
    fi
    AB_PACKAGES_GATE_REASON="unsolvable"
    printf 'packages: gate blocked, apk refused the transaction:\n' >&2
    printf '%s\n' "${_gs_out}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
    return 1
}

# _packages_db_depends <installed-db> <package>: the dependency list apk recorded for one
# package, or empty. The database is a blank-line separated block format and `D:` belongs to
# the block whose `P:` precedes it.
_packages_db_depends() {
    [ -f "$1" ] || return 0
    awk -v want="$2" '
        /^P:/ { pkg = substr($0, 3); next }
        pkg == want && /^D:/ { print substr($0, 3); exit }
    ' "$1" 2>/dev/null
}

# _packages_gate_local <root> <sys> <cache> <repos>: L. Returns 0 when every local package was
# classified, 1 when apk could not answer.
#
# A local package is replayed from a body kept in /etc/apk/ab/local (design.md §10); without a
# body it is `local:` (NO COPY) - the installed files stay, nothing is reinstalled, and the
# record says what the operator has to do. A body that was built against another kernel is
# `stale-abi:`: replaying it would install a module that cannot load, which is worse than
# keeping the one that is already there.
_packages_gate_local() {
    _gl_root=$1
    _gl_sys=$2
    _gl_cache=$3
    _gl_repos=$4
    _gl_world="${_gl_root}/etc/apk/world"
    [ -s "${_gl_world}" ] || _gl_world="${_gl_sys}/etc/apk/world"
    _gl_db="${_gl_root}/lib/apk/db/installed"
    [ -f "${_gl_db}" ] || _gl_db="${_gl_sys}/lib/apk/db/installed"
    _gl_assets="${_gl_root}/etc/apk/ab/local"
    _gl_kernel=$(_packages_base_pin "${_gl_sys}" kernel)
    _gl_kernel=${_gl_kernel#kernel=}
    _gl_names=$(_packages_refresh_world "${_gl_world}" full \
        | awk '{ name = $0; sub(/[=<>~].*/, "", name); print name }')
    # shellcheck disable=SC2086  # one package name per line by construction
    for _gl_name in ${_gl_names}; do
        if ! _gl_out=$(_packages_gate_apk "${_gl_root}" "${_gl_cache}" "${_gl_repos}" policy "${_gl_name}" 2>/dev/null); then
            return 1
        fi
        # An answer with no sources in it is not "local", it is an answer this gate cannot read;
        # treating it as local would attribute a hole to a package nobody looked at.
        if [ -z "$(printf '%s' "${_gl_out}" | tr -d ' \t\n')" ]; then
            return 1
        fi
        # Every non-header line of `apk policy` names a source. The installed database is the
        # one source that needs no feed; anything else means a repository offers the package,
        # and a repository package is not this proposition's business.
        _gl_src=$(printf '%s\n' "${_gl_out}" | sed 's/^[ \t]*//' | grep -v '^$' \
            | grep -v ':$' | grep -vx 'lib/apk/db/installed')
        [ -z "${_gl_src}" ] || continue
        _gl_body=$(ls "${_gl_assets}/${_gl_name}-"*.apk 2>/dev/null | head -n 1)
        if [ -z "${_gl_body}" ]; then
            _packages_gate_token_add "local:${_gl_name}"
            continue
        fi
        _gl_need=$(_packages_db_depends "${_gl_db}" "${_gl_name}" \
            | tr ' ' '\n' | sed -n 's/^kernel=//p' | head -n 1)
        [ -n "${_gl_need}" ] || continue
        if [ -n "${_gl_kernel}" ] && [ "${_gl_need}" != "${_gl_kernel}" ]; then
            _packages_gate_token_add "stale-abi:${_gl_name}"
        fi
    done
    return 0
}

# _packages_gate_body <target-root> <sys-root>: the propositions, in the order that spends the
# least to learn the most.
_packages_gate_body() {
    _gt_target=$1
    _gt_sys=$2
    _gt_world_file="${_gt_target}/etc/apk/world"
    if [ ! -s "${_gt_world_file}" ]; then
        _gt_world_file="${_gt_sys}/etc/apk/world"
    fi
    if [ ! -s "${_gt_world_file}" ]; then
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="no-world"
        return 2
    fi

    _packages_gate_pins "${_gt_target}" "${_gt_sys}"
    case $? in
        0) AB_PACKAGES_GATE_P="ok" ;;
        *)
            AB_PACKAGES_GATE_P="blocked"
            AB_PACKAGES_GATE_STATE="blocked"
            AB_PACKAGES_GATE_REASON="pin-mismatch"
            printf 'packages: gate blocked, the world pins another release than this base (%s)\n' \
                "${AB_PACKAGES_GATE_PIN_DETAIL}" >&2
            return 1
            ;;
    esac

    if ! command -v apk >/dev/null 2>&1; then
        AB_PACKAGES_GATE_S="gap"
        AB_PACKAGES_GATE_L="gap"
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="no-apk"
        return 2
    fi

    AB_PACKAGES_GATE_TMPDIR="${AB_PACKAGES_GATE_TMP:-${TMPDIR:-/tmp}}/ab-gate.$$"
    if ! mkdir -p "${AB_PACKAGES_GATE_TMPDIR}/cache" 2>/dev/null; then
        AB_PACKAGES_GATE_S="gap"
        AB_PACKAGES_GATE_L="gap"
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="no-tmp"
        return 2
    fi
    _gt_repos="${AB_PACKAGES_GATE_TMPDIR}/repositories"
    if ! _packages_gate_repos "${_gt_target}" "${_gt_repos}" \
        && ! _packages_gate_repos "${_gt_sys}" "${_gt_repos}"; then
        AB_PACKAGES_GATE_S="gap"
        AB_PACKAGES_GATE_L="gap"
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="no-feeds"
        return 2
    fi

    _packages_gate_solve "${_gt_target}" "${AB_PACKAGES_GATE_TMPDIR}/cache" "${_gt_repos}"
    case $? in
        0) AB_PACKAGES_GATE_S="ok" ;;
        *)
            AB_PACKAGES_GATE_S="blocked"
            AB_PACKAGES_GATE_STATE="blocked"
            return 1
            ;;
    esac

    if ! _packages_gate_local "${_gt_target}" "${_gt_sys}" \
        "${AB_PACKAGES_GATE_TMPDIR}/cache" "${_gt_repos}"; then
        AB_PACKAGES_GATE_L="gap"
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="no-apk"
        return 2
    fi
    AB_PACKAGES_GATE_L="ok"
    # `gap` is not a failure of a proposition: it is a hole in what can be followed. The three
    # states then mean "everything the world names can follow", "something cannot and that
    # blocks the follow", and "the follow can run but this much of it cannot move".
    if [ -n "${AB_PACKAGES_GATE_SKIPPED}" ]; then
        AB_PACKAGES_GATE_STATE="gap"
        AB_PACKAGES_GATE_REASON="none"
        return 2
    fi
    AB_PACKAGES_GATE_STATE="ok"
    AB_PACKAGES_GATE_REASON="none"
    return 0
}

# ab_packages_gate <target-root> [<sys-root>]: the three propositions of design.md §5.
#
# Returns 0 (ok), 1 (blocked) or 2 (gap). Nothing outside the gate's /tmp directory is written,
# on any path: the scratch directory is removed before the answer is returned, so a caller can
# compare the target tree byte for byte afterwards.
ab_packages_gate() {
    _gate_target=${1:?ab_packages_gate needs the target tree}
    _gate_sys=${2:-$1}
    while [ "${#_gate_target}" -gt 1 ] && [ "${_gate_target%/}" != "${_gate_target}" ]; do
        _gate_target=${_gate_target%/}
    done
    while [ "${#_gate_sys}" -gt 1 ] && [ "${_gate_sys%/}" != "${_gate_sys}" ]; do
        _gate_sys=${_gate_sys%/}
    done
    AB_PACKAGES_GATE_STATE=""
    AB_PACKAGES_GATE_REASON="none"
    AB_PACKAGES_GATE_S="skipped"
    AB_PACKAGES_GATE_P="skipped"
    AB_PACKAGES_GATE_L="skipped"
    AB_PACKAGES_GATE_INDEX=""
    AB_PACKAGES_GATE_BLOCKED=""
    AB_PACKAGES_GATE_SKIPPED=""
    AB_PACKAGES_GATE_WORLD=""
    AB_PACKAGES_GATE_PIN_DETAIL=""
    AB_PACKAGES_GATE_TMPDIR=""

    _packages_gate_body "${_gate_target}" "${_gate_sys}"
    _gate_rc=$?
    if [ -n "${AB_PACKAGES_GATE_TMPDIR}" ]; then
        rm -rf "${AB_PACKAGES_GATE_TMPDIR}" 2>/dev/null || :
        AB_PACKAGES_GATE_TMPDIR=""
    fi
    return "${_gate_rc}"
}

# _packages_transaction_names <world-file> [full|subset]: the package *names* a follow may
# move, one per line, without the world's operators.
#
# Measured 2026-11-18 on the device (apk-tools 3.0.5): `apk upgrade base-files=1950~0c4...`
# answers "Package 'base-files=1950~0c4...' not found" and exits 1 for *every* version
# qualified spec - including one whose version the feeds carry - while `apk upgrade base-files`
# resolves. The plan believed the opposite (`apk add name=version` still resolves, which is
# true, so the world's lines were passed through verbatim). The pins are not lost by dropping
# the operator here: apk reads them from the world file itself, which is exactly where a pin
# belongs, and the solver still refuses a transaction the pins forbid.
_packages_transaction_names() {
    _ptn_world=$1
    _packages_refresh_world "${_ptn_world}" "${2:-full}" \
        | awk '{ name = $0; sub(/[=<>~].*/, "", name); print name }'
}

# --------------------------------------------------------------------------- #
# Prefetch: the bodies and the index, downloaded before the switch
#
# Measured 2026-11-18 on the device (apk-tools 3.0.5, ImmortalWrt 25.12.2) - and this is the
# second correction of what the plan believed:
#
#   * a follow to the feed's latest is 3,445,041 bytes over 39 packages (3.3 MiB), which is
#     the *moving set*, not the world: `apk fetch --recursive` over the world downloads 316
#     bodies and 105 MB. So the prefetch asks the solver what it would move (`upgrade
#     --simulate`) and fetches exactly that, which is also why `cache=` in the record can be
#     compared with the 3.3 MiB the design promises;
#   * `apk --network=0` does not exist in this apk: the boolean parser rejects `0` (and
#     `false`), accepts `no`/`yes`, and `--network=no` makes apk answer "nothing to do" for a
#     transaction whose bodies are on disk - it disables the repositories, so it cannot be the
#     offline switch. What works with the network actually unreachable is installing the
#     prefetched files themselves: `apk add --virtual <name> --allow-untrusted
#     --force-non-repository --cache-dir <cache> --cache-max-age <large> <bodies>` moves 39
#     packages with zero network attempts (measured with blackholed routes), and
#     `apk del <name>` puts the world back byte for byte;
#   * a body fetched by `apk fetch` carries no signature of its own (the repository's index is
#     what is signed), so installing it as a file needs `--allow-untrusted` - the same
#     primitive platform/lib/ab-pkgs-assets.sh already replays a kept local body with.
#
# So the download can happen while the machine still runs a slot that works, and the first
# boot of the new one needs no network at all - which is what takes captive portals and home
# outages off the critical path (design.md §8).
#
# A prefetch that fails is not an upgrade that fails. The record falls back to
# `follow=pending reason=network` and the network fallback picks it up (design.md §9).
# --------------------------------------------------------------------------- #

AB_PACKAGES_PREFETCH_TIMEOUT="${AB_PACKAGES_PREFETCH_TIMEOUT:-300}"

# shellcheck disable=SC2034
AB_PACKAGES_PREFETCH_STATE=""
# shellcheck disable=SC2034
AB_PACKAGES_PREFETCH_REASON=""
# shellcheck disable=SC2034
AB_PACKAGES_PREFETCH_COUNT=0
# shellcheck disable=SC2034
AB_PACKAGES_PREFETCH_CACHE=0

# _packages_cache_dir <target-root>: where the bodies for the first boot go. design.md §10 puts
# it next to world and db on the writable layer: it rides the generation snapshot, needs no new
# subvolume and no initramfs change, and never touches /data.
_packages_cache_dir() {
    printf '%s/etc/apk/ab/cache' "$1"
}

# _packages_cache_files <dir>: the bodies in a cache directory, one per line.
_packages_cache_files() {
    [ -d "$1" ] || return 0
    for _cf in "$1"/*.apk; do
        [ -f "${_cf}" ] || continue
        printf '%s\n' "${_cf}"
    done
}

# _packages_cache_bytes <dir>: how many bytes the bodies in a cache directory are, summed from
# the files themselves. `du` would answer in blocks (the busybox one in KiB) and the record
# wants bytes a reader can compare with the 3.3 MiB a follow is expected to cost.
_packages_cache_bytes() {
    _cb_total=0
    while IFS= read -r _cb_file; do
        [ -n "${_cb_file}" ] || continue
        _cb_size=$(wc -c <"${_cb_file}" 2>/dev/null | tr -d ' ')
        case "${_cb_size}" in
            '' | *[!0-9]*) continue ;;
        esac
        _cb_total=$((_cb_total + _cb_size))
    done <<FILES
$(_packages_cache_files "$1")
FILES
    printf '%s' "${_cb_total}"
}

# _packages_prefetch_apk <root> <cache> <apk args...>: one apk command whose index cache is the
# same directory the bodies go to. The first boot reads the same directory: the index and the
# bodies travel together, which is what lets the apply run with no network at all.
#
# The feed set is the seam's, so the bodies fetched here are the bodies the first boot's
# transaction will ask for. With no plugin declared the extra words are absent and this is the
# command line it always was (ac-9).
_packages_prefetch_apk() {
    _pa_root=$1
    _pa_cache=$2
    shift 2
    # shellcheck disable=SC2086  # zero or two single-word arguments by construction
    _pa_repos=$(_packages_apk_repos_args "${_pa_root}")
    # shellcheck disable=SC2086
    _packages_refresh_bounded "${AB_PACKAGES_PREFETCH_TIMEOUT}" \
        apk --root "${_pa_root}" --cache-dir "${_pa_cache}" ${_pa_repos} \
        --timeout "${AB_PACKAGES_PREFETCH_TIMEOUT}" "$@"
    _pa_rc=$?
    _packages_apk_repos_drop "${_pa_repos}"
    return "${_pa_rc}"
}

# _packages_moving_names <apk-simulate-output>: the packages a simulated transaction would
# install, upgrade or downgrade, one name per line.
#
# Measured 2026-11-18 on apk-tools 3.0.5: a transaction that moves packages prints
# `( 1/39) Upgrading libopenssl3 (3.5.7-r1 -> 3.5.9-r1)` and `( 2/39) Installing usign (...)`,
# and one with nothing to do prints only `OK: 282.0 MiB in 316 packages`. The name is what
# `apk fetch` takes; the version is not passed on purpose - a version qualified spec is what
# `apk upgrade` refuses (- see _packages_transaction_names).
_packages_moving_names() {
    # One -e per verb, not an alternation: BSD sed (the host the tests run on) has no `\|`,
    # and a parser that silently matches nothing would report "the world is current" for every
    # transaction - the exact class of lie this task removes.
    printf '%s\n' "$1" \
        | sed -n -e 's/.*Upgrading \([^ ][^ ]*\) (.*/\1/p' \
            -e 's/.*Downgrading \([^ ][^ ]*\) (.*/\1/p' \
            -e 's/.*Reinstalling \([^ ][^ ]*\) (.*/\1/p' \
            -e 's/.*Installing \([^ ][^ ]*\) (.*/\1/p' \
        | sort -u
}

# ab_packages_prefetch <target-root> [<skipped-list>]: fetch every body the follow will need.
#
# Returns 0 when the cache is populated, 1 when it is not (and the upgrade is still fine), 3
# when there is nothing to fetch. Sets AB_PACKAGES_PREFETCH_{STATE,REASON,COUNT,CACHE}. The
# skipped list a gate produced is written into the record here because this is the first moment
# after the confirmation where the record may be written at all.
ab_packages_prefetch() {
    _pf_target=$1
    while [ "${#_pf_target}" -gt 1 ] && [ "${_pf_target%/}" != "${_pf_target}" ]; do
        _pf_target=${_pf_target%/}
    done
    _pf_skipped=${2:-}
    AB_PACKAGES_PREFETCH_STATE=""
    AB_PACKAGES_PREFETCH_REASON=""
    AB_PACKAGES_PREFETCH_COUNT=0
    AB_PACKAGES_PREFETCH_CACHE=0

    _pf_world="${_pf_target}/etc/apk/world"
    if [ ! -s "${_pf_world}" ]; then
        AB_PACKAGES_PREFETCH_STATE="empty"
        AB_PACKAGES_PREFETCH_REASON="no-world"
        return 3
    fi
    _pf_want=$(_packages_transaction_names "${_pf_world}" full)
    if [ -z "${_pf_want}" ]; then
        AB_PACKAGES_PREFETCH_STATE="empty"
        AB_PACKAGES_PREFETCH_REASON="no-packages"
        return 3
    fi
    _pf_cache=$(_packages_cache_dir "${_pf_target}")
    if ! mkdir -p "${_pf_cache}" 2>/dev/null; then
        AB_PACKAGES_PREFETCH_STATE="failed"
        AB_PACKAGES_PREFETCH_REASON="cache-unwritable"
        _packages_follow_publish_pending "network"
        return 1
    fi
    # Nothing from an earlier attempt is counted: the number in the record describes this
    # download, and a leftover body would make it describe two.
    rm -f "${_pf_cache}"/*.apk 2>/dev/null || :
    if ! command -v apk >/dev/null 2>&1; then
        AB_PACKAGES_PREFETCH_STATE="failed"
        AB_PACKAGES_PREFETCH_REASON="no-apk"
        _packages_follow_publish_pending "network"
        return 1
    fi
    if ! _pf_idx=$(_packages_prefetch_apk "${_pf_target}" "${_pf_cache}" update 2>&1); then
        printf 'packages: prefetch: the index did not answer, the follow stays pending\n' >&2
        # A declared feed that could not be read is suspended for this transaction, and the
        # journal is the only place that says so: the record's `reason=network` cannot tell a
        # base feed from a plugin one.
        _packages_plugins_suspend || :
        AB_PACKAGES_PREFETCH_STATE="failed"
        AB_PACKAGES_PREFETCH_REASON="network"
        _packages_follow_publish_pending "network"
        return 1
    fi
    # What to download is the solver's answer, not the world: measured 2026-11-18, one follow
    # moves 39 of 316 installed packages and `apk fetch --recursive` over the world pulls 105 MB
    # instead of 3.3 MiB. A world that is already current is a prefetch with nothing to do, and
    # that is a fact the record can carry (`upgraded=0 kept=<n>` at first boot), not a failure.
    # shellcheck disable=SC2086  # one word per world name by construction
    if ! _pf_sim=$(_packages_prefetch_apk "${_pf_target}" "${_pf_cache}" \
        upgrade --simulate ${_pf_want} 2>&1); then
        printf 'packages: prefetch: apk cannot solve the world, the follow stays pending\n' >&2
        printf '%s\n' "${_pf_sim}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
        AB_PACKAGES_PREFETCH_STATE="failed"
        AB_PACKAGES_PREFETCH_REASON="unsolvable"
        _packages_follow_publish_pending "network"
        return 1
    fi
    _pf_moving=$(_packages_moving_names "${_pf_sim}")
    if [ -z "${_pf_moving}" ]; then
        # Nothing moves: the bodies the first boot would need are already on the disk (the
        # installed ones). The record still says pending, because the follow itself has not
        # run; the first boot then reports `upgraded=0 kept=<n>`, which is the measured shape
        # of an already current world.
        _pf_skipped_fact=""
        [ -n "${_pf_skipped}" ] && _pf_skipped_fact="skipped=${_pf_skipped} "
        _packages_record_publish "$(_packages_record_state_keep aligned)" \
            "$(_packages_reason_carry none)" pending "${_pf_skipped_fact}cache=0" \
            "ab-packages update" || :
        AB_PACKAGES_PREFETCH_STATE="ok"
        AB_PACKAGES_PREFETCH_REASON="nothing-to-move"
        AB_PACKAGES_PREFETCH_COUNT=0
        AB_PACKAGES_PREFETCH_CACHE=0
        printf 'packages: prefetch: the world is already current, nothing to download\n' >&2
        return 0
    fi
    # shellcheck disable=SC2086  # one body name per word by construction
    _pf_out=$(_packages_prefetch_apk "${_pf_target}" "${_pf_cache}" fetch \
        -o "${_pf_cache}" ${_pf_moving} 2>&1)
    _pf_rc=$?
    _pf_n=$(printf '%s\n' "$(_packages_cache_files "${_pf_cache}")" | grep -c . || true)
    _pf_n=${_pf_n:-0}
    if [ "${_pf_rc}" -ne 0 ] || [ "${_pf_n}" -eq 0 ]; then
        # The count is the evidence, not the status: `apk fetch` that selected nothing exits 0.
        case "${_pf_rc}" in
            0) AB_PACKAGES_PREFETCH_REASON="no-evidence" ;;
            124) AB_PACKAGES_PREFETCH_REASON="timeout" ;;
            *) AB_PACKAGES_PREFETCH_REASON="apk-${_pf_rc}" ;;
        esac
        printf 'packages: prefetch: fetch %s left %s bodies, the follow stays pending\n' \
            "${AB_PACKAGES_PREFETCH_REASON}" "${_pf_n}" >&2
        printf '%s\n' "${_pf_out}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
        # A fetch that failed at the transport is the same network answer a failed index is,
        # so a body a declared feed did not hand over suspends that feed. A fetch that exited
        # 0 having selected nothing is `no-evidence`, which is not a network claim and gets
        # none made for it.
        if [ "${_pf_rc}" -ne 0 ]; then
            _packages_plugins_suspend || :
        fi
        # Half a download is worse than none: the first boot would see bodies, take the offline
        # path with an incomplete set, fail the transaction and have no retry. Dropping what was
        # fetched keeps the first boot on the network fallback, where it belongs.
        rm -f "${_pf_cache}"/*.apk 2>/dev/null || :
        AB_PACKAGES_PREFETCH_STATE="failed"
        # The record's token is the design's one word for "the bodies could not be fetched";
        # the precise reason above is for the ring log.
        _packages_follow_publish_pending "network"
        return 1
    fi
    AB_PACKAGES_PREFETCH_STATE="ok"
    AB_PACKAGES_PREFETCH_REASON="none"
    AB_PACKAGES_PREFETCH_COUNT=${_pf_n}
    AB_PACKAGES_PREFETCH_CACHE=$(_packages_cache_bytes "${_pf_cache}")
    _pf_facts="cache=${AB_PACKAGES_PREFETCH_CACHE}"
    [ -n "${_pf_skipped}" ] && _pf_facts="skipped=${_pf_skipped} ${_pf_facts}"
    _packages_record_publish "$(_packages_record_state_keep aligned)" \
        "$(_packages_reason_carry none)" pending "${_pf_facts}" "ab-packages update" || :
    printf 'packages: prefetched %s bodies (%s bytes) for the first boot\n' \
        "${_pf_n}" "${AB_PACKAGES_PREFETCH_CACHE}" >&2
    return 0
}

# --------------------------------------------------------------------------- #
# Follow: apk upgrade on the first boot of a new base, judged by what it printed
#
# The primitive is `apk upgrade` over the world's own constraints minus the kernel. Measured
# 2026-11-18:
#
#   * `apk upgrade dnsmasq-full` moves 2.93-r1 -> 2.93-r2 and keeps a user-edited
#     /etc/config/dhcp byte for byte, writing the package's copy to dhcp.apk-new;
#   * `apk add --force-reinstall` pins the *installed* version, so when the index no longer
#     carries it apk prints `[APK unavailable, skipped]` and exits 0 - which is how the previous
#     implementation published `packages=aligned` for a transaction that never ran.
#
# So the verdict comes from the output: `Upgrading <name> (<old> -> <new>)` per package moved,
# `[APK unavailable, skipped]` as the signature of the no-op. A run that printed nothing but
# `OK:` next to a skipped line did nothing and is recorded as `follow=failed
# reason=no-evidence`; a run with no upgrade and no skip is a world that was already current.
# --------------------------------------------------------------------------- #

AB_PACKAGES_FOLLOW_TIMEOUT="${AB_PACKAGES_FOLLOW_TIMEOUT:-300}"

# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_MODE=""
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_UPGRADED=0
# shellcheck disable=SC2034
AB_PACKAGES_FOLLOW_KEPT=0

# _packages_follow_apk <root> <apk args...>: one apk command against the machine that will run
# the packages. "/" is apk's own default and gets no --root, so a boot worker never passes a
# flag that would make apk treat the running root as a sandbox.
#
# The feed set is the seam's here too, and deliberately for every path this runs on: the
# prefetch wrote its index into the same cache directory, so the offline apply finds the
# declared feeds' indexes there and needs no network to use them. With no plugin declared the
# extra words are absent and the command line is unchanged (ac-9).
_packages_follow_apk() {
    _fk_root=$1
    shift
    # shellcheck disable=SC2086  # zero or two single-word arguments by construction
    _fk_repos=$(_packages_apk_repos_args "${_fk_root}")
    # shellcheck disable=SC2086
    if [ -z "${_fk_root}" ] || [ "${_fk_root}" = "/" ]; then
        _packages_refresh_bounded "${AB_PACKAGES_FOLLOW_TIMEOUT}" \
            apk ${_fk_repos} --timeout "${AB_PACKAGES_FOLLOW_TIMEOUT}" "$@"
    else
        _packages_refresh_bounded "${AB_PACKAGES_FOLLOW_TIMEOUT}" \
            apk --root "${_fk_root}" ${_fk_repos} --timeout "${AB_PACKAGES_FOLLOW_TIMEOUT}" "$@"
    fi
    _fk_rc=$?
    _packages_apk_repos_drop "${_fk_repos}"
    return "${_fk_rc}"
}

# _packages_follow_kept <constraints> <moved names>: how many world entries this transaction did
# not move. A package apk left alone is kept, and saying how many is what makes `upgraded=39`
# readable next to a 236-entry world.
_packages_follow_kept() {
    _fkept_kept=0
    _fkept_moved=" $(printf '%s' "$2" | tr '\n' ' ') "
    while IFS= read -r _fkept_line; do
        [ -n "${_fkept_line}" ] || continue
        _fkept_name=${_fkept_line%%[=<>~]*}
        case "${_fkept_moved}" in
            *" ${_fkept_name} "*) ;;
            *) _fkept_kept=$((_fkept_kept + 1)) ;;
        esac
    done <<LIST
$1
LIST
    printf '%s' "${_fkept_kept}"
}

# AB_PACKAGES_FOLLOW_OFFLINE_OUT: the transaction's output, kept in a file rather than a
# variable: an apk with 300 packages prints a line per package, and the callers in the boot
# hook run under `sh` on a tmpfs machine.
AB_PACKAGES_FOLLOW_VIRTUAL="${AB_PACKAGES_FOLLOW_VIRTUAL:-.ab-follow}"

# _packages_follow_cached_bodies <cache>: the prefetched bodies, one per line. Only a file that
# follows apk's `<name>-<version>.apk` naming is passed back to apk: a body with any other name
# is refused by apk with a message about packages nobody asked for, and one refused file fails
# the whole transaction.
_packages_follow_cached_bodies() {
    _fcb_dir=$1
    while IFS= read -r _fcb_file; do
        [ -n "${_fcb_file}" ] || continue
        _fcb_name=${_fcb_file##*/}
        case "${_fcb_name}" in
            *[!A-Za-z0-9._~+-]*) continue ;;
        esac
        printf '%s\n' "${_fcb_file}"
    done <<FILES
$(_packages_cache_files "${_fcb_dir}")
FILES
}

# _packages_follow_offline: apply the bodies the prefetch left, with no network.
#
# Returns apk's own status; AB_PACKAGES_FOLLOW_OFFLINE_OUT carries the output. The virtual
# package is the mechanism: `apk add <files>` alone would persist the bodies in the world
# (measured: "You tried to add a non-repository package to system, but it would be lost on next
# reboot"), and a world nobody wrote by hand must not gain entries. `apk del <virtual>` restores
# the world byte for byte (measured) and does not remove anything it pulled in, because every
# body installed is already in the world by its own name.
#
# The cache arguments are not decoration: with `--network=no` apk stops reading the repositories
# and answers "no jobs", so the offline run keeps the network on and the bodies are what makes
# it need nothing from it. The measured run with blackholed routes made zero network attempts.
_packages_follow_offline() {
    AB_PACKAGES_FOLLOW_OFFLINE_OUT=""
    _pfo_bodies=$(_packages_follow_cached_bodies "${_fo_cache}")
    if [ -z "${_pfo_bodies}" ]; then
        printf 'packages: the cache holds no body to apply offline\n' >&2
        return 1
    fi
    # 1. the virtual entry is added only around the transaction and never published.
    # shellcheck disable=SC2086  # one body path per word by construction
    AB_PACKAGES_FOLLOW_OFFLINE_OUT=$(_packages_follow_apk "${_fo_target}" \
        --cache-dir "${_fo_cache}" --cache-max-age 100000 \
        add --virtual "${AB_PACKAGES_FOLLOW_VIRTUAL}" --allow-untrusted --force-non-repository \
        ${_pfo_bodies} 2>&1)
    _pfo_rc=$?
    # 2. the world is put back whether the transaction worked or not. A failure that leaves the
    #    virtual entry behind would make the next attempt's `apk add` answer "already
    #    satisfied" and hide what is missing.
    _pfo_del=$(_packages_follow_apk "${_fo_target}" del "${AB_PACKAGES_FOLLOW_VIRTUAL}" 2>&1) || :
    printf '%s\n' "${_pfo_del}" | grep -v '^$' | sed 's/^/packages: /' >&2
    return "${_pfo_rc}"
}

# _packages_follow_established_facts: the facts the prefetch or the gate already established,
# as record word pairs.
#
# A failed attempt must not drop them: measured 2026-11-18 on the device, two early `ifup` rungs
# published `follow=failed` with an empty fact list, and the `cache=3867245` the prefetch had
# written was gone from the record the successful rung then read - so the record that finally
# said `follow=followed` carried no `cache=` at all, which is exactly the ac-6 field a reader
# checks. Whatever a run couldn't measure stays what the run before it established.
_packages_follow_established_facts() {
    _fef_facts=""
    for _fef_key in upgraded kept skipped cache dropped; do
        _fef_val=$(_packages_record_get "${_fef_key}")
        [ -n "${_fef_val}" ] && _fef_facts="${_fef_facts} ${_fef_key}=${_fef_val}"
    done
    printf '%s' "${_fef_facts# }"
}

# ab_packages_follow_can_offline <target-root>: 0 when the prefetched bodies are already on the
# disk, so the follow needs no network at all.
#
# Measured 2026-11-18: the first boot asked the network probe before it ever asked this library,
# so a machine whose bodies were prefetched still waited four rungs for a feed that was not
# needed (ring log: probe=offline result=pending, then the apply only happened on an ifup). The
# prefetch exists precisely so the network question is not on the path; this is the predicate
# that lets the worker skip it.
ab_packages_follow_can_offline() {
    _co_root=${1:-${AB_PACKAGES_TARGET:-/}}
    while [ "${#_co_root}" -gt 1 ] && [ "${_co_root%/}" != "${_co_root}" ]; do
        _co_root=${_co_root%/}
    done
    [ -n "$(_packages_cache_files "$(_packages_cache_dir "${_co_root}")" 2>/dev/null)" ]
}

# ab_packages_follow <target-root>: make the installed packages belong to the base the machine
# now runs.
#
# Returns 0 when the follow completed (including "there was nothing to move"), 1 when it did
# not, 3 when there is nothing to work with. Sets AB_PACKAGES_FOLLOW_STATE/_REASON/_VERSION and the
# counters; the record itself is published here, because the transaction is the only thing that
# knows what happened.
ab_packages_follow() {
    _fo_target=${1:-/}
    while [ "${#_fo_target}" -gt 1 ] && [ "${_fo_target%/}" != "${_fo_target}" ]; do
        _fo_target=${_fo_target%/}
    done
    AB_PACKAGES_FOLLOW_MODE=""
    AB_PACKAGES_FOLLOW_UPGRADED=0
    AB_PACKAGES_FOLLOW_KEPT=0
    AB_PACKAGES_FOLLOW_STATE=""
    AB_PACKAGES_FOLLOW_REASON=""
    AB_PACKAGES_FOLLOW_VERSION=""

    _fo_world="${_fo_target}/etc/apk/world"
    if [ ! -s "${_fo_world}" ]; then
        printf 'packages: no world at %s, nothing to follow\n' "${_fo_world}" >&2
        _packages_follow_publish_pending "no-world"
        return 3
    fi
    _fo_want=$(_packages_transaction_names "${_fo_world}" full)
    if [ -z "${_fo_want}" ]; then
        printf 'packages: the world holds nothing but entries this library does not own\n' >&2
        _packages_follow_publish_pending "no-packages"
        return 0
    fi
    if ! command -v apk >/dev/null 2>&1; then
        _packages_follow_publish_pending "no-apk"
        return 1
    fi

    _fo_cache=$(_packages_cache_dir "${_fo_target}")
    if [ -n "$(_packages_cache_files "${_fo_cache}")" ]; then
        AB_PACKAGES_FOLLOW_MODE="offline"
    else
        AB_PACKAGES_FOLLOW_MODE="online"
    fi

    # 1. no usable prefetch: the network has to be there, and the probe on this platform knows
    #    how to tell a captive portal from a mirror. It lives in its own file (design.md §9), so
    #    a library without it simply tries the transaction.
    if [ "${AB_PACKAGES_FOLLOW_MODE}" = "online" ] && command -v ab_net_probe >/dev/null 2>&1; then
        if ! ab_net_probe; then
            printf 'packages: no usable network, the follow stays pending\n' >&2
            # The record says `reason=network` for the whole follow; the journal is what
            # distinguishes "the declared feeds were suspended" from "the machine was offline"
            # for the operator who asks why a plugin's packages did not move.
            _packages_plugins_suspend || :
            _packages_follow_publish_pending "network"
            return 1
        fi
    fi

    # 2. the transaction: the world's package names, minus the kernel entry this library never
    #    touches, and with no network at all when the bodies are already on the disk.
    #
    # Measured 2026-11-18 (apk-tools 3.0.5): `apk upgrade <name>=<version>` answers
    # "Package '...' not found" for every version qualified spec, so the world's operators are
    # stripped here (`_packages_transaction_names`) - the pins stay in the world file, where the
    # solver reads them anyway. The offline branch installs the prefetched *files*:
    # `apk add --virtual <name> --allow-untrusted --force-non-repository --cache-dir <cache>
    # --cache-max-age <large> <bodies>`, which moved 39 packages with blackholed routes and zero
    # network attempts. Its one addition to the world is the virtual entry, removed again by
    # `apk del` before anything is published; `--network=no` was tried first and is not an
    # offline switch at all (it disables the repositories and reports "nothing to do").
    if [ "${AB_PACKAGES_FOLLOW_MODE}" = "offline" ]; then
        _packages_follow_offline
        _fo_rc=$?
        _fo_out="${AB_PACKAGES_FOLLOW_OFFLINE_OUT:-}"
    else
        if ! _fo_out=$(_packages_follow_apk "${_fo_target}" update 2>&1); then
            printf 'packages: apk update failed, the follow stays pending (network)\n' >&2
            _packages_plugins_suspend || :
            _packages_follow_publish_pending "network"
            return 1
        fi
        # 2b. A world entry this base's own feeds no longer offer poisons every later apk
        #     transaction on the slot, including the one below: apk refuses the whole set for
        #     one name it cannot find. Dropping the entry keeps the installed package and its
        #     configuration, and the record says which entries went. This is the only place
        #     that still runs, so the judgement the retired refresh made has to live here -
        #     without it a downgrade ends in `follow=failed` for good (measured on the plan:
        #     the gate blocks, nothing is prefetched, and every retry hits the same orphan).
        if [ "${AB_PACKAGES_PRUNE_INDEX_OK:-0}" != "0" ] || command -v ab_packages_prune >/dev/null 2>&1; then
            AB_PACKAGES_PRUNE_INDEX_OK=1
            if ab_packages_prune "${_fo_target}" && [ "${AB_PACKAGES_PRUNE_COUNT:-0}" -gt 0 ]; then
                _fo_dropped="${AB_PACKAGES_PRUNE_LIST:-}"
                printf 'packages: dropped %s world entr(y|ies) this base does not offer: %s\n' \
                    "${AB_PACKAGES_PRUNE_COUNT}" "${_fo_dropped}" >&2
                # The transaction has to be built from the world as it is now.
                _fo_want=$(_packages_transaction_names "${_fo_world}" full)
            fi
        fi
        # 2c. The online transaction gets the same evidence check the offline one is held to:
        #     the solver says which packages would move, and a transaction that moves none of
        #     them is not a follow. It is also what makes a world that is already current a
        #     real answer (`upgraded=0 kept=<n>`) instead of a silence that reads like success.
        #     A simulate that cannot solve is not decided here: the transaction below runs and
        #     its own failure is what gets recorded.
        # shellcheck disable=SC2086  # one word per world name by construction
        if _fo_sim=$(_packages_follow_apk "${_fo_target}" upgrade --simulate ${_fo_want} 2>&1); then
            _fo_expected=$(_packages_moving_names "${_fo_sim}")
            if [ -z "${_fo_expected}" ]; then
                _fo_kept=$(_packages_follow_kept "${_fo_want}" "")
                AB_PACKAGES_FOLLOW_UPGRADED=0
                AB_PACKAGES_FOLLOW_KEPT=${_fo_kept}
                _fo_facts="upgraded=0 kept=${_fo_kept}"
                _fo_skip_list=$(_packages_record_get skipped)
                [ -n "${_fo_skip_list}" ] && _fo_facts="${_fo_facts} skipped=${_fo_skip_list}"
                _packages_record_publish "followed" "none" "followed" "${_fo_facts}" "none" || return 1
                printf 'packages: followed 0 package(s) (%s kept) in %s mode, the world is current\n' \
                    "${_fo_kept}" "${AB_PACKAGES_FOLLOW_MODE}" >&2
                rm -f "${_fo_cache}"/* 2>/dev/null || :
                return 0
            fi
        fi
        # shellcheck disable=SC2086  # one word per world name by construction
        _fo_out=$(_packages_follow_apk "${_fo_target}" upgrade ${_fo_want} 2>&1)
        _fo_rc=$?
    fi

    # 3. what the transaction says it did.
    # Lines that name an upgrade apk did *not* do are dropped first: the measured no-op prints
    # `(1/1) [APK unavailable, skipped] Upgrading htop (3.3.0-r1)`, which otherwise reads as a
    # package that moved.
    # The four verbs apk-tools 3.0.5 uses for a package it does something to (measured on the
    # device 2026-11-18 by reading the strings out of /usr/bin/apk and watching a downgrade):
    # `Upgrading` and `Downgrading` move a package to the base's version, `Installing` adds one
    # the world asked for, and `Replacing` reinstalls the version already there. The first
    # three are what `upgraded=` counts; `Replacing` is evidence the transaction ran but is not
    # a package that followed, so it is parsed on its own - it used to be invisible, and a
    # downgrade of 25.12.2-built packages onto 25.12.1 reported `upgraded=0` for a move that
    # really happened.
    _fo_did=$(printf '%s\n' "${_fo_out}" | grep -v 'APK unavailable, skipped' || :)
    _fo_up=$(printf '%s\n' "${_fo_did}" \
        | sed -n -e 's/.*Upgrading \([^ ][^ ]*\) .*/\1/p' -e 's/.*Downgrading \([^ ][^ ]*\) .*/\1/p' \
        | sort -u)
    # The offline path installs its virtual entry in the same transaction; it is not a package
    # that followed anything.
    _fo_new=$(printf '%s\n' "${_fo_did}" | sed -n 's/.*Installing \([^ ][^ ]*\) .*/\1/p' \
        | grep -vx "${AB_PACKAGES_FOLLOW_VIRTUAL}" | sort -u)
    _fo_repl=$(printf '%s\n' "${_fo_did}" | sed -n 's/.*Replacing \([^ ][^ ]*\) .*/\1/p' | sort -u)
    _fo_moved=$(printf '%s\n%s\n' "${_fo_up}" "${_fo_new}" | grep . | sort -u)
    _fo_n=$(printf '%s\n' "${_fo_moved}" | grep -c . || true)
    _fo_n=${_fo_n:-0}
    _fo_skipped_n=$(printf '%s\n' "${_fo_out}" | grep -c 'APK unavailable, skipped' || true)
    _fo_skipped_n=${_fo_skipped_n:-0}

    if [ "${_fo_rc}" -ne 0 ]; then
        case "${_fo_rc}" in
            124) _fo_reason="timeout" ;;
            *) _fo_reason="apk-${_fo_rc}" ;;
        esac
        printf 'packages: the follow transaction failed (%s)\n' "${_fo_reason}" >&2
        printf '%s\n' "${_fo_out}" | grep . | head -n 5 | sed 's/^/packages:   /' >&2
        _packages_record_publish "$(_packages_record_state_keep aligned)" "${_fo_reason}" \
            failed "$(_packages_follow_established_facts)" "ab-packages update" || :
        AB_PACKAGES_FOLLOW_REASON=${_fo_reason}
        return 1
    fi
    if [ "${AB_PACKAGES_FOLLOW_MODE}" = "offline" ] && [ "${_fo_rc}" -eq 0 ] \
        && [ "${_fo_n}" -eq 0 ] && [ -z "${_fo_repl}" ]; then
        # The prefetch promised bodies for this base; a transaction that applied none of them
        # did not follow anything. Saying `followed` here is the lie this task exists to
        # remove, so it is recorded as what it is and the network fallback gets its turn. A
        # transaction that only replaced same-version bodies did run (its output names them),
        # and that is `upgraded=0 kept=<n>` - the world needed no move.
        printf 'packages: the offline transaction applied nothing the prefetch downloaded\n' >&2
        _packages_record_publish "$(_packages_record_state_keep aligned)" "no-evidence" \
            failed "$(_packages_follow_established_facts)" "ab-packages update" || :
        AB_PACKAGES_FOLLOW_REASON="no-evidence"
        return 1
    fi
    if [ "${_fo_n}" -eq 0 ] && [ -z "${_fo_new}" ] && [ "${_fo_skipped_n}" -gt 0 ]; then
        # The measured no-op: exit 0, `[APK unavailable, skipped]` per package, nothing moved.
        printf 'packages: the transaction skipped everything it was asked for, nothing moved\n' >&2
        _packages_record_publish "$(_packages_record_state_keep aligned)" "no-evidence" \
            failed "$(_packages_follow_established_facts)" "ab-packages update" || :
        AB_PACKAGES_FOLLOW_REASON="no-evidence"
        return 1
    fi

    _fo_kept=$(_packages_follow_kept "${_fo_want}" "${_fo_moved}")
    AB_PACKAGES_FOLLOW_UPGRADED=${_fo_n}
    AB_PACKAGES_FOLLOW_KEPT=${_fo_kept}
    # The two facts a follow cannot measure stay what the prefetch and the gate established: the
    # attribution list and the size of what was downloaded. Recomputing them here would mean
    # asking the network a question this run may not be able to (the offline path has none).
    _fo_facts="upgraded=${_fo_n} kept=${_fo_kept}"
    _fo_skip_list=$(_packages_record_get skipped)
    [ -n "${_fo_skip_list}" ] && _fo_facts="${_fo_facts} skipped=${_fo_skip_list}"
    _fo_cache_bytes=$(_packages_record_get cache)
    if [ -z "${_fo_cache_bytes}" ] && [ "${AB_PACKAGES_FOLLOW_MODE}" = "offline" ]; then
        # The prefetch is the source of this number, but an earlier failed rung may have dropped
        # it (see _packages_follow_established_facts). The bodies are still on the disk at this
        # point - they are deleted below - so the transaction can measure what it applied.
        _fo_cache_bytes=$(_packages_cache_bytes "${_fo_cache}")
    fi
    [ -n "${_fo_cache_bytes}" ] && _fo_facts="${_fo_facts} cache=${_fo_cache_bytes}"
    _packages_record_publish "followed" "none" "followed" "${_fo_facts}" "none" || return 1
    printf 'packages: followed %s package(s) (%s kept) in %s mode\n' \
        "${_fo_n}" "${_fo_kept}" "${AB_PACKAGES_FOLLOW_MODE}" >&2
    # The cache is a consumable (design.md §10): its bodies are in the apk database now and its
    # size lives in the record, so keeping the files would only cost the writable layer. The
    # index files go with them: they name the release the slot just left, so the next follow
    # would fetch its own anyway (measured 2026-11-18: 14 APKINDEX files stayed behind after a
    # follow of 128 packages, in the layer that has to stay small).
    rm -f "${_fo_cache}"/* 2>/dev/null || :
    return 0
}

# ab_packages_follow_due [slot]: 0 when the record says this base still owes a follow.
#
# The read-only question a boot hook asks before it starts a worker. `follow=pending` is the
# due flag; a record written before the field existed (an upgrade by the previous platform
# version) counts as due once, because nothing ever followed it, while `followed`, `failed`,
# `abandoned` and `never` are answers that only a human or `ab-packages update` changes.
ab_packages_follow_due() {
    _fd_slot=${1:-}
    _fd_file=$(_packages_refresh_record_file)
    [ -r "${_fd_file}" ] || return 1
    case "$(_packages_record_state)" in
        aligned | followed | limited) ;;
        *) return 1 ;;
    esac
    if [ -n "${_fd_slot}" ]; then
        _fd_rec_slot=$(_packages_record_get slot)
        [ -z "${_fd_rec_slot}" ] || [ "${_fd_rec_slot}" = "${_fd_slot}" ] || return 1
    fi
    case "$(_packages_record_get follow)" in
        pending) return 0 ;;
        '') return 0 ;;
        *) return 1 ;;
    esac
}

# ab_packages_follow_if_ready [target-root] [slot]: the boot worker's single entry point. Runs
# the follow when the record is due and does nothing at all when it is not, so a hook can call
# it unconditionally. The single-instance lock belongs to the caller (design.md §9): this
# function is one transaction, not a scheduler.
ab_packages_follow_if_ready() {
    _fri_slot=${2:-}
    ab_packages_follow_due "${_fri_slot}" || return 0
    ab_packages_follow "${1:-${AB_PACKAGES_TARGET:-/}}"
}

# --------------------------------------------------------------------------- #
# Package snapshots: the record a package-level rollback replays
#
# A snapshot is text on the writable layer, in <layer>/apk/snapshots/. It is not a
# backup of files (ab-backup owns that): it records which versions this machine had, so
# `ab-slot packages revert` can ask apk for them again. That is why it stays out of the
# running root - nothing under upper/ changes because of it.
#
# The newest AB_APK_SNAPSHOT_KEEP are kept. Retention lives here rather than in the
# caller so a machine that is upgraded often does not accumulate a directory listing per
# week on a 128 MiB partition.
# --------------------------------------------------------------------------- #

AB_APK_SNAPSHOT_KEEP="${AB_APK_SNAPSHOT_KEEP:-3}"

_packages_snapshot_dir() {
    printf '%s/apk/snapshots' "$1"
}

# _packages_installed: one `name version` line per installed package.
#
# The source is `apk info -v`. Bare `apk info` is deliberately never read: under
# apk-tools 3 (3.0.5 on the measured machine, 2026-11-14) it prints the names only, which
# is how a 317-package machine produced a snapshot of versionless lines. `apk list
# --installed` is the documented fallback, and its first field is the same `name-version`.
#
# The split is "the last dash followed by a digit": names carry dashes
# (kmod-nls-iso8859-1) and versions carry one of their own (-r1), so neither the first nor
# the last dash is right. A line that does not split is a failure, not something to drop:
# returning fewer lines than there were is exactly the silent loss this exists to catch.
#
# Returns 0 with the lines on stdout, 1 when apk cannot answer at all, 2 when a line does
# not split. The lines that did not split (up to three) are named on stderr.
_packages_installed() {
    _raw=""
    if _info=$(apk info -v 2>/dev/null); then
        _raw=${_info}
    fi
    if [ -z "${_raw}" ]; then
        _raw=$(apk list --installed 2>/dev/null | awk 'NF { print $1 }')
    fi
    [ -n "${_raw}" ] || return 1

    _total=$(printf '%s\n' "${_raw}" | grep -c . || true)
    _unparsed=$(printf '%s\n' "${_raw}" | grep . | sed -n '/^\(.*\)-\([0-9].*\)$/!p')
    if [ -n "${_unparsed}" ]; then
        _bad=$(printf '%s\n' "${_unparsed}" | grep -c . || true)
        printf 'packages: %s of %s lines could not be split into name and version\n' \
            "${_bad}" "${_total}" >&2
        printf '%s\n' "${_unparsed}" | head -n 3 | while IFS= read -r _line; do
            printf 'packages: unparsed %s\n' "${_line}" >&2
        done
        return 2
    fi
    printf '%s\n' "${_raw}" | grep . | sed -n 's/^\(.*\)-\([0-9].*\)$/\1 \2/p'
}

# _packages_sha256 <file>: the hex digest of a payload, or empty when no tool can make
# one. The device is busybox (sha256sum); a build host may have shasum or openssl.
_packages_sha256() {
    [ -f "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{ print $1; exit }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{ print $1; exit }'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{ print $NF; exit }'
    else
        return 1
    fi
}

# _packages_payload_file <payload-dir> <name> <version>: the .apk a package was fetched
# as. `apk fetch` names it <name>-<version>.apk; the glob is only a second chance for a
# version apk re-spelled.
_packages_payload_file() {
    if [ -n "${3:-}" ]; then
        _exact="$1/$2-$3.apk"
        if [ -f "${_exact}" ]; then
            printf '%s' "${_exact}"
            return 0
        fi
    fi
    _found=$(find "$1" -maxdepth 1 -name "$2-*.apk" 2>/dev/null | head -n 1)
    [ -n "${_found}" ] || return 1
    printf '%s' "${_found}"
}


# _packages_prune_payloads <payload-dir> <packages>: drop archives that are not the
# installed set's name-version pair. A per-package fetch that hit a rolled feed leaves the
# newer file behind, and the recursive fallback may add another version; the record only
# ever lists the expected files, but a leftover would still be installed by a glob-style
# consumer, so it is removed here.
_packages_prune_payloads() {
    _pr_dir=$1
    for _pr_f in "${_pr_dir}"/*.apk; do
        [ -f "${_pr_f}" ] || continue
        _pr_keep=0
        while IFS=' ' read -r _pr_name _pr_ver; do
            [ -n "${_pr_name}" ] || continue
            if [ "${_pr_f}" = "${_pr_dir}/${_pr_name}-${_pr_ver}.apk" ]; then
                _pr_keep=1
                break
            fi
        done <<PRUNE_LIST
$2
PRUNE_LIST
        [ "${_pr_keep}" = "1" ] || rm -f "${_pr_f}"
    done
}

# ab_packages_payloads_verified <snapshot> <payload-dir>: 0 when the snapshot lists
# payloads, the directory holds them, and every recorded sha256 matches the file; the
# number verified is printed. 1 when there is nothing usable to verify (no payload lines,
# no directory, a file that is not there); 2 when a digest does not match.
#
# The digest list is the whole trust chain for a local .apk: the device reports
# `UNTRUSTED signature` and we do not carry its keyring, so `--allow-untrusted` is only
# safe because the record says what each byte should be.
ab_packages_payloads_verified() {
    _verified_files=$(ab_packages_payload_files "$1" "$2") || return $?
    printf '%s\n' "${_verified_files}" | grep -c .
}

# ab_packages_payload_files <snapshot> <payload-dir>: the .apk paths the snapshot lists and
# whose digest matches, one per line. Same returns as ab_packages_payloads_verified.
#
# The caller installs exactly these paths instead of a glob of the directory: a file that
# apk fetch dropped in but the snapshot does not list was never checked by anything, and
# installing it would put a package on the machine that no record vouches for.
ab_packages_payload_files() {
    _snap=$1
    _pdir=$2
    _apkfiles=$(sed -n 's/^apkfile  *//p' "${_snap}" 2>/dev/null)
    [ -n "${_apkfiles}" ] || return 1
    [ -d "${_pdir}" ] || return 1
    _found=""
    while IFS=' ' read -r _name _sha; do
        [ -n "${_name}" ] || continue
        _file=$(_packages_payload_file "${_pdir}" "${_name}" "") || return 1
        _got=$(_packages_sha256 "${_file}")
        [ -n "${_got}" ] || return 2
        [ "${_got}" = "${_sha}" ] || return 2
        _found="${_found}${_file}
"
    done <<APKFILES
${_apkfiles}
APKFILES
    [ -n "${_found}" ] || return 1
    printf '%s' "${_found}"
}

# _packages_world_report <snapshot>: reconcile the world with the package set. The count
# line goes to stdout (it is a machine-readable fact); the first five world entries that
# have no package in the snapshot go to stderr, because a name apk would have to resolve
# again is exactly what a replay cannot fix on its own.
_packages_world_report() {
    awk '
        /^pkg      / { pkg[$2] = 1; next }
        /^world    / { entry[++n] = substr($0, 10); next }
        END {
            matched = 0
            shown = 0
            for (i = 1; i <= n; i++) {
                key = entry[i]
                sub(/[=<>~].*/, "", key)
                if (key in pkg) {
                    matched++
                } else if (shown < 5) {
                    printf "  world-unmatched  %s\n", key > "/dev/stderr"
                    shown++
                }
            }
            printf "revert world=%d matched=%d\n", n, matched
        }
    ' "$1"
}

# _packages_fetch_per_package <payload-dir> <packages>: fetch every installed package on
# its own, without `--recursive`. The installed set already contains the dependency closure
# (apk installed it), so a recursive solve adds nothing but a reason to fail: it makes apk
# resolve the pinned set against `/etc/apk/world`, and on a freshly flashed machine that
# world is older than the feed, so the solve dies on `world[libopenssl3=...]` and takes
# every payload with it.
#
# The loop stops at the first fetch that fails: one failure is enough to know this route
# does not work here, and a machine whose feed is unreachable must not spend one connection
# attempt per installed package before the caller falls back. Returns 0 when every fetch
# succeeded, 1 otherwise; whether the files actually landed is checked separately.
_packages_fetch_per_package() {
    _pp_dir=$1
    _pp_missing=0
    # The feed set is the seam's, for the same reason the follow's is: this fetch runs on the
    # running machine, and a package a declared feed carries is fetched from nowhere else. The
    # root is the running one (no --root), which is the tree the install of a revert will meet.
    # shellcheck disable=SC2086  # zero or two single-word arguments by construction
    _pp_repos=$(_packages_apk_repos_args "")
    # apk-tools 3.0.5 rejects a version pin in `apk fetch` ("unable to select package (or
    # its dependencies)" for every `name=version` tried on the device), so the fetch has to
    # name the package only. That still avoids the one-shot `--recursive` world solve, which
    # was the F2 defect. The version is then checked against the installed set: a feed that
    # has rolled since the machine was flashed hands back a newer file, and recording that
    # file would make the snapshot describe a state that never existed. Such a package is
    # dropped and counted as missing; the caller's recursive fallback may still land it, and
    # otherwise the record says payload-incomplete instead of pretending.
    while IFS=' ' read -r _pp_name _pp_ver; do
        [ -n "${_pp_name}" ] || continue
        # shellcheck disable=SC2086
        if ! apk ${_pp_repos} fetch -o "${_pp_dir}" "${_pp_name}" >/dev/null 2>&1; then
            # A fetch that cannot run at all is a feed/network failure: stop here instead of
            # paying a connection timeout for every installed package.
            _packages_apk_repos_drop "${_pp_repos}"
            return 1
        fi
        if [ -f "${_pp_dir}/${_pp_name}-${_pp_ver}.apk" ]; then
            for _pp_f in "${_pp_dir}/${_pp_name}-"*.apk; do
                [ -f "${_pp_f}" ] || continue
                [ "${_pp_f}" = "${_pp_dir}/${_pp_name}-${_pp_ver}.apk" ] || rm -f "${_pp_f}"
            done
        else
            rm -f "${_pp_dir}/${_pp_name}-"*.apk 2>/dev/null || true
            _pp_missing=$((_pp_missing + 1))
        fi
    done <<PACKAGES
$2
PACKAGES
    _packages_apk_repos_drop "${_pp_repos}"
    [ "${_pp_missing}" -eq 0 ]
}

# _packages_payload_record <payload-dir> <apkfile> <packages>: write one
# `apkfile <name> <sha256>` line per package whose archive is present and digestable, print
# how many packages had no usable archive. A file without a digest is a missing payload,
# not a line to write and hope: the digest list is the whole trust chain for a local .apk
# (the device does not carry the feed's keyring), and a revert verifies every line of it.
_packages_payload_record() {
    _pr_dir=$1
    _pr_apkfile=$2
    : >"${_pr_apkfile}"
    _pr_missing=0
    while IFS=' ' read -r _pr_name _pr_ver; do
        [ -n "${_pr_name}" ] || continue
        _pr_sha=""
        if _pr_file=$(_packages_payload_file "${_pr_dir}" "${_pr_name}" "${_pr_ver}"); then
            _pr_sha=$(_packages_sha256 "${_pr_file}")
        fi
        if [ -z "${_pr_sha}" ]; then
            _pr_missing=$((_pr_missing + 1))
            continue
        fi
        printf 'apkfile  %s %s\n' "${_pr_name}" "${_pr_sha}" >>"${_pr_apkfile}"
    done <<PACKAGES
$3
PACKAGES
    printf '%s' "${_pr_missing}"
}

# ab_packages_snapshot <layer> <upstream> <platform> [--no-payloads]: write one snapshot,
# print its path.
#
# The payloads are fetched by default, because on the measured machine the feed carries
# only the newest version (`apk policy htop` -> 3.5.3-r1 while the machine runs 3.3.0-r1),
# so a manifest without the files cannot be replayed once anything moved. A failed or
# partial fetch is recorded as `payloads no` plus one `payload-gap <reason>` line, and the
# manifest still succeeds: the record of what this machine runs is the main deliverable,
# the files are the part that needs a network.
#
# The fetch has two stages. Stage one is _packages_fetch_per_package above: no solver, one
# package per call. Stage two is the historical one-shot `apk fetch --recursive`, kept as a
# fallback for whatever stage one cannot fetch (a package a re-spelled feed answers to, an
# apk that disagrees about `name=version` on the command line). Either stage is judged by
# the files and digests on disk, never by the fetch command's exit status; a set that does
# not cover every installed package is a `payload-gap`, and its directory is removed.
#
# Both stages read the feed set a follow reads, plugin feeds included. A snapshot that could
# only see the base's feeds would record `payload-gap` for every package a declared feed
# carries, and the revert that trusts this snapshot would then have no offline way back.
ab_packages_snapshot() {
    _layer=${1:?ab_packages_snapshot needs a layer}
    _upstream=${2:?ab_packages_snapshot needs the upstream version}
    _platform=${3:?ab_packages_snapshot needs the platform version}
    shift 3
    _want_payloads=1
    for _arg in "$@"; do
        case "${_arg}" in
            --no-payloads) _want_payloads=0 ;;
            *)
                _packages_fail "snapshot-argument-invalid"
                return 1
                ;;
        esac
    done

    _dir=$(_packages_snapshot_dir "${_layer}")
    mkdir -p "${_dir}" || return 1

    _id=$(date -u +%Y%m%dT%H%M%SZ)
    _file="${_dir}/snapshot-${_id}.txt"
    # The id has one-second resolution; two snapshots in the same second are told apart by
    # a -N suffix. Reusing the bare name after its predecessor was reaped would make a
    # *new* snapshot sort before the -N files that are actually older, and the retention
    # pass would delete it. So once any file exists for this id, the next one is
    # max(+N)+1, never the bare name again.
    if [ -e "${_file}" ] || ls "${_dir}/snapshot-${_id}-"*.txt >/dev/null 2>&1; then
        _max=0
        for _f in "${_dir}/snapshot-${_id}.txt" "${_dir}/snapshot-${_id}-"*.txt; do
            [ -e "${_f}" ] || continue
            _b=${_f##*/}
            _b=${_b%.txt}
            _b=${_b##*-}
            case "${_b}" in
                '' | *[!0-9]*) _s=1 ;;
                *) _s=${_b} ;;
            esac
            [ "${_s}" -gt "${_max}" ] && _max=${_s}
        done
        _n=$((_max + 1))
        _file="${_dir}/snapshot-${_id}-${_n}.txt"
    fi
    # The payload directory is named after the snapshot, not after the id: a same-second
    # second snapshot is `-2` and needs its own .d, or two records would share a payload
    # set that only one of them describes.
    _sid=${_file##*/snapshot-}
    _sid=${_sid%.txt}
    _snapdir="${_dir}/snapshot-${_sid}.d"
    _pdir="${_snapdir}/payloads"

    _packages=$(_packages_installed)
    _prc=$?
    if [ "${_prc}" -ne 0 ]; then
        case "${_prc}" in
            2) _packages_fail "apk-info-unparsed" ;;
            *) _packages_fail "apk-info-failed" ;;
        esac
        return 1
    fi
    _pkgnum=$(printf '%s\n' "${_packages}" | grep -c . || true)
    # The world of an image-stage system lives in @sys, not in the writable layer: the
    # first boot of a flashed image has an empty upper. Falling back to the merged view
    # keeps `world=N` honest there; a payload slot always has its own file in upper.
    _worldfile="${_layer}/upper/etc/apk/world"
    [ -f "${_worldfile}" ] || _worldfile=/etc/apk/world
    # A world with entries but no readable package list is not an empty machine, it is a
    # broken apk. Writing "0 packages" here would make every later revert a silent no-op.
    if [ "${_pkgnum}" -eq 0 ] && [ -s "${_worldfile}" ]; then
        _packages_fail "apk-info-empty"
        return 1
    fi
    _worldnum=0
    if [ -f "${_worldfile}" ]; then
        _worldnum=$(grep -c . "${_worldfile}" || true)
    fi

    _payloads_written=0
    _payload_gap=""
    _apkfiles=""
    if [ "${_want_payloads}" = "1" ] && [ "${_pkgnum}" -gt 0 ]; then
        _apkfiles="${_snapdir}/apkfile"
        if mkdir -p "${_pdir}" 2>/dev/null; then
            # Stage one: no --recursive, no world solve. The installed set is the closure.
            _packages_fetch_per_package "${_pdir}" "${_packages}" || true
            _missing=$(_packages_payload_record "${_pdir}" "${_apkfiles}" "${_packages}")
            _fallback_failed=0
            if [ "${_missing}" != "0" ]; then
                # Stage two: the historical one-shot fetch, for the machines where fetching
                # pins one at a time does not land every file. It may hit the same world
                # solve, which is why it is no longer the only attempt.
                printf 'packages: payload fetch fell back to --recursive (per-package fetch incomplete)\n' >&2
                _pins=$(printf '%s\n' "${_packages}" | awk '{ print $1 "=" $2 }')
                # Same seam, same root as the per-package stage: a fallback that read a
                # narrower feed set than the attempt before it could only fail for a reason
                # that has nothing to do with the packages.
                # shellcheck disable=SC2086  # zero or two single-word arguments by construction
                _snap_repos=$(_packages_apk_repos_args "")
                # shellcheck disable=SC2086  # one word per pin by construction
                if apk ${_snap_repos} fetch --recursive -o "${_pdir}" ${_pins} >/dev/null 2>&1; then
                    _packages_apk_repos_drop "${_snap_repos}"
                    _packages_prune_payloads "${_pdir}" "${_packages}"
                    _missing=$(_packages_payload_record "${_pdir}" "${_apkfiles}" "${_packages}")
                else
                    _packages_apk_repos_drop "${_snap_repos}"
                    _fallback_failed=1
                fi
            fi
            if [ "${_missing}" = "0" ]; then
                _payloads_written=1
            elif [ "${_fallback_failed}" = "1" ]; then
                # A feed that cannot be reached and a disk that filled up look the same
                # from here, and either way the manifest is still worth writing.
                _payload_gap="apk-fetch-failed"
            else
                # Both fetch routes answered and the set is still short. Naming it
                # incomplete keeps the reason stable for a reader; nothing is claimed.
                _payload_gap="payload-incomplete"
            fi
        else
            _payload_gap="payloads-unwritable"
        fi
        if [ "${_payloads_written}" = "0" ]; then
            # Nothing half-populated is left behind: a directory that exists but does not
            # verify would send a later revert down the local path with a broken set.
            rm -rf "${_snapdir}" 2>/dev/null || true
            _apkfiles=""
        fi
    fi

    {
        printf 'AB-APK-SNAPSHOT 1\n'
        printf 'created  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'upstream %s\n' "${_upstream}"
        printf 'platform %s\n' "${_platform}"
        printf 'packages %s\n' "${_pkgnum}"
        printf 'world %s\n' "${_worldnum}"
        if [ "${_payloads_written}" = "1" ]; then
            printf 'payloads yes\n'
        else
            printf 'payloads no\n'
        fi
        if [ -n "${_payload_gap}" ]; then
            printf 'payload-gap %s\n' "${_payload_gap}"
        fi
        if [ -f "${_worldfile}" ]; then
            while IFS= read -r _entry || [ -n "${_entry}" ]; do
                [ -n "${_entry}" ] || continue
                printf 'world    %s\n' "${_entry}"
            done <"${_worldfile}"
        fi
        printf '%s\n' "${_packages}" | while IFS=' ' read -r _name _version; do
            [ -n "${_name}" ] || continue
            printf 'pkg      %s %s\n' "${_name}" "${_version}"
        done
        if [ "${_payloads_written}" = "1" ] && [ -f "${_apkfiles}" ]; then
            cat "${_apkfiles}"
        fi
        printf 'end\n'
    } >"${_file}" || {
        rm -rf "${_snapdir}" 2>/dev/null || true
        rm -f "${_file}" 2>/dev/null || true
        _packages_fail "snapshot-unwritable"
        return 1
    }
    # The record is what a later revert trusts; the payload files are worth several hundred
    # megabytes and may still be in flight through the page cache.
    sync 2>/dev/null || true
    if [ -n "${_apkfiles}" ]; then
        rm -f "${_apkfiles}" 2>/dev/null || true
    fi
    if [ -n "${_payload_gap}" ]; then
        printf 'packages: payload-gap %s\n' "${_payload_gap}" >&2
    fi

    _packages_snapshot_reap "${_layer}"
    printf '%s\n' "${_file}"
}

# _packages_snapshot_files <layer>: snapshot files, oldest first.
_packages_snapshot_files() {
    _dir=$(_packages_snapshot_dir "$1")
    [ -d "${_dir}" ] || return 0
    # The id has one-second resolution, so two snapshots in the same second are told apart
    # by a -N suffix. That suffix is the *later* write, which plain `sort` would place
    # first ("-" < "."); the sort key makes the number the last thing compared.
    find "${_dir}" -maxdepth 1 -name 'snapshot-*.txt' 2>/dev/null \
        | sed 's#^.*/##' | awk '
        {
            name = $0
            id = name
            sub(/^snapshot-/, "", id)
            sub(/\.txt$/, "", id)
            n = 1
            if (id ~ /-[0-9]+$/) {
                n = id
                sub(/^.*-/, "", n)
                sub(/-[0-9]+$/, "", id)
            }
            printf "%s %06d %s\n", id, n, name
        }' | sort | cut -d' ' -f3
}

_packages_snapshot_reap() {
    _dir=$(_packages_snapshot_dir "$1")
    _files=$(_packages_snapshot_files "$1")
    [ -n "${_files}" ] || return 0
    _count=$(printf '%s\n' "${_files}" | wc -l | tr -d ' ')
    [ "${_count}" -gt "${AB_APK_SNAPSHOT_KEEP}" ] || return 0
    _drop=$((_count - AB_APK_SNAPSHOT_KEEP))
    printf '%s\n' "${_files}" | head -n "${_drop}" | while IFS= read -r _name; do
        rm -f "${_dir}/${_name}" || :
        # The payloads belong to exactly one manifest: reaping the text without the .d
        # would leave up to 300 MiB of files nothing on the machine can name.
        rm -rf "${_dir}/${_name%.txt}.d" || :
    done
}

# _packages_snapshot_field <file> <key>: one header value, or empty.
_packages_snapshot_field() {
    sed -n "s/^$2  *//p" "$1" 2>/dev/null | head -n 1
}

# _packages_snapshot_count <file> <key>: a header count. The counts are read by pattern
# rather than with _packages_snapshot_field because `world 3` and the `world    <entry>`
# lines differ by one space: reading a snapshot written before the counts existed must not
# return the first entry as if it were a number.
_packages_snapshot_count() {
    sed -n "s/^$2 \([0-9][0-9]*\)\$/\\1/p" "$1" 2>/dev/null | head -n 1
}

# ab_packages_list <layer>: the snapshots on this layer, newest first.
ab_packages_list() {
    _layer=${1:?ab_packages_list needs a layer}
    _files=$(_packages_snapshot_files "${_layer}")
    if [ -z "${_files}" ]; then
        printf 'snapshot: no snapshots\n'
        printf '  Next: ab-slot packages snapshot\n'
        return 0
    fi
    _count=$(printf '%s\n' "${_files}" | wc -l | tr -d ' ')
    printf '%s snapshots kept (newest %s retained)\n' "${_count}" "${AB_APK_SNAPSHOT_KEEP}"
    printf '%s\n' "${_files}" | sort -r | while IFS= read -r _name; do
        _path="$(_packages_snapshot_dir "${_layer}")/${_name}"
        _id=${_name#snapshot-}
        _id=${_id%.txt}
        _base=$(_packages_snapshot_field "${_path}" upstream)
        _platform=$(_packages_snapshot_field "${_path}" platform)
        # A count that is not there is not a zero. A file this listing cannot read, or one
        # written before the header carried the counts, says nothing about how many packages
        # or world entries it holds; `${_pkgs:-0}` printed `0` for both, which is the one
        # answer a reader must never be given by accident. `0` is only what a readable
        # record with no such entry reports.
        # A readable regular file is the precondition for any count: busybox `grep -c`
        # answers 0 for a directory, so a corrupted record that happens to be one would read
        # as an empty snapshot. Measured on the device, 2026-11-16.
        if [ -f "${_path}" ] && [ -r "${_path}" ]; then
            _pkgs=$(grep -c '^pkg ' "${_path}" 2>/dev/null || true)
            _world=$(_packages_snapshot_count "${_path}" world)
        else
            _pkgs=""
            _world=""
        fi
        case "${_pkgs}" in
            '' | *[!0-9]*) _pkgs=unreadable ;;
        esac
        case "${_world}" in
            '' | *[!0-9]*) _world=unreadable ;;
        esac
        _payloads=$(_packages_snapshot_field "${_path}" payloads)
        printf 'snapshot %s  base %s  platform %s  %s packages  world %s  payloads %s\n' \
            "${_id}" "${_base}" "${_platform}" "${_pkgs}" "${_world}" "${_payloads:-no}"
    done
}
