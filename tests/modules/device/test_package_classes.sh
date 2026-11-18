#!/bin/sh
# Module: device
# The three-class chain driver (scripts/device/package-classes.sh): ac-12 and ac-13 against a
# machine that is a directory.
#
# What is under test is the claim ac-12 makes: a package the base's own feed serves, a package
# the user's own source serves and a package that has no source at all each survive a base hop
# with their fake configuration and their /data marker byte-identical, and each is judged by
# its own criterion. ac-13 is the same question about the source itself: the list is
# byte-identical, the source still resolves, and it can still install a package it has not
# served yet.
#
# Three groups, three negatives, because a group that cannot go red is not being judged:
#
#   distfeeds   the binary stopped running / the new base's feed stopped offering the name
#   customfeeds the list was rewritten / the source stopped resolving / the source stopped
#               serving a package it had not served yet
#   local       the kept body changed / the replay failed
#
# The machine below is a directory tree plus a stub `ssh`, a stub `apk` and a stub
# `ab-packages`. The driver's own remote halves are not stubbed: the stub ssh hands the program
# it receives on stdin to `sh -s`, so what the driver sends is parsed and executed here, and a
# remote half that stopped being POSIX would fail on the CI runner exactly as it would on the
# device. That is also why this file is POSIX sh and not bash: it runs under dash there.
#
# A broken machine is replayed with one environment variable naming the break (STUB_BREAK),
# which the stub applies at the hop - the moment a real machine's own follow would have run.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)

# --- assertions ------------------------------------------------------------- #
# tests/lib/assert.sh is bash; this file has to run under dash, so the four helpers it needs
# are written out. The output shape is the same: `ok N - message` and `not ok N - message`,
# with the failure detail on stderr.
_ok=0
_bad=0
ok() {
    _ok=$((_ok + 1))
    printf 'ok %d - %s\n' "${_ok}" "${1}"
}
not_ok() {
    _bad=$((_bad + 1))
    printf 'not ok %d - %s\n' "$((_ok + _bad))" "${1}"
    printf '    %s\n' "${2:-}" >&2
}
eq() { # <actual> <expected> <message>
    if [ "${1}" = "${2}" ]; then ok "${3}"; else not_ok "${3}" "expected [${2}] got [${1}]"; fi
}
contains() { # <haystack> <needle> <message>
    case "${1}" in
        *"${2}"*) ok "${3}" ;;
        *) not_ok "${3}" "missing [${2}] in [$(printf '%s' "${1}" | cut -c1-400)]" ;;
    esac
}
finish() {
    printf '# assertions: %d, failures: %d\n' "$((_ok + _bad))" "${_bad}"
    [ "${_bad}" -eq 0 ]
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "${tmp}"' EXIT

driver="${root}/scripts/device/package-classes.sh"

# --- the driver itself, before any machine is built -------------------------- #
if [ ! -f "${driver}" ]; then
    not_ok "ac-12 the three-class chain driver exists" "no ${driver}"
    finish
    exit 1
fi
ok "ac-12 the three-class chain driver exists"
eq "$(sh -n "${driver}" 2>&1; echo $?)" "0" "ac-12 the driver parses under sh"
# The CI runner's /bin/sh is dash, and this repository has already been bitten once by a
# construct that bash-as-sh accepts and dash refuses at parse time.
if command -v dash >/dev/null 2>&1; then
    eq "$(dash -n "${driver}" 2>&1; echo $?)" "0" "ac-12 and under dash, the shell the CI runner uses"
fi
eq "$(sed -n '1p' "${driver}")" '#!/bin/sh' "ac-12 the driver declares the POSIX sh interpreter"
# The three classes have to be three: a driver that judged one kind of package would answer
# ac-12's first sentence and none of its second.
contains "$(cat "${driver}")" "CLASSES=\"distfeeds customfeeds local\"" \
    "ac-12 the driver names the three classes as three"
contains "$(cat "${driver}")" "ab-version.sh" \
    "ac-12 the direction of a hop is computed from the versions, not read off a base name"
contains "$(cat "${driver}")" "customfeeds.list" \
    "ac-13 the user's source is the file the aligner never rewrites"
contains "$(cat "${driver}")" "ab-packages sources" \
    "ac-13 source attribution is the product's own answer, not a second implementation"
contains "$(cat "${driver}")" "ab-packages replay" \
    "ac-12 the local class is replayed through the product's own path"
eq "$(grep -c 'follow-samples\.json\|software-samples\.json' "${driver}" || true)" "0" \
    "ac-12 the driver keeps no sample list of its own"
# A second sha256 implementation is how two drivers start disagreeing about "the file moved":
# the machine's own `sha256sum` is the one read.
eq "$(grep -c 'jq -r\|openssl dgst' "${driver}" || true)" "0" \
    "ac-12 the file hashes are the machine's own sha256sum, not a second implementation"

# --- the machine ------------------------------------------------------------ #
# hash_file <path>: the machine's own sha256sum name, falling back to the laptop's shasum. The
# test compares two bytes; which tool computes the digest is not part of the claim.
hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"${1}" | cut -d' ' -f1
    else
        shasum -a 256 <"${1}" | cut -d' ' -f1
    fi
}

bin="${tmp}/bin"
calls="${tmp}/calls.log"
state="${tmp}/state"
fake="${tmp}/device"
payloads="${tmp}/payloads"
results="${tmp}/results.tsv"
evidence="${tmp}/evidence"
baseline="${tmp}/baseline.tsv"

mkdir -p "${bin}" "${state}" "${payloads}" \
    "${fake}/etc/config" "${fake}/etc/apk/repositories.d" "${fake}/etc/apk/ab/local" \
    "${fake}/data/ab-follow" "${fake}/boot/ab" "${fake}/tmp" "${fake}/feeds/dist" "${fake}/feeds/custom"
: >"${tmp}/key"

customfeeds="${fake}/etc/apk/repositories.d/customfeeds.list"
distfeeds="${fake}/etc/apk/repositories.d/distfeeds.list"
world="${fake}/etc/apk/world"
assets="${fake}/etc/apk/ab/local"
record="${fake}/boot/ab/packages"
marker_dir="${fake}/data/ab-follow"
config_dir="${fake}/etc/config"
scratch="${fake}/tmp"

# Placeholders, not archives: one byte that is not a tar header reads as "not a tar" on both
# GNU tar and bsdtar, so lib.sh's shape check (which only speaks for a real tar) stays out.
for p in payload-25.12.1.tar payload-25.12.2.tar; do
    printf 'placeholder, not a tar\n' >"${payloads}/${p}"
done
# The local class: a body no feed offers. Its name follows apk's own shape, because that
# `<name>-<version>-r<rev>.apk` name is the interface between the kept-body store and the gate.
local_body="${tmp}/vault-sample-2.1-r0.apk"
printf 'a body no feed serves\n' >"${local_body}"

# --- the stand-ins ---------------------------------------------------------- #
# sha256sum is what the device's busybox calls the tool; a laptop may call it shasum. The
# remote half calls sha256sum, so the stand-in only forwards to whichever exists.
cat >"${bin}/sha256sum" <<'SHIM'
#!/bin/sh
if command -v shasum >/dev/null 2>&1; then exec shasum -a 256 "$@"; fi
exec sha256sum "$@"
SHIM

# The distfeeds sample's own binary: usable exactly while apk has it installed, which is what
# makes "the package is gone" and "the package no longer runs" the same break here.
cat >"${bin}/htop" <<'HTOP'
#!/bin/sh
if grep -q '^htop ' "${STUB_STATE:?}/installed" 2>/dev/null; then
    printf 'htop 3.5.3\n'
    exit 0
fi
printf 'htop: not found\n' >&2
exit 127
HTOP

# apk: the five applets the remote halves use. Versions and availability come from a feed
# directory per source, so "the new base's feed stopped offering it" and "the user's source
# cannot serve a package it has not served" are file operations rather than flags.
cat >"${bin}/apk" <<'APK'
#!/bin/sh
state=${STUB_STATE:?apk needs STUB_STATE}
fake=${STUB_ROOT:?apk needs STUB_ROOT}
world=${fake}/etc/apk/world
inst="${state}/installed"
db=$inst

db_has() { grep -q "^$1 " "$db" 2>/dev/null; }
db_ver() { awk -v n="$1" '$1 == n { print $2; exit }' "$db" 2>/dev/null; }
db_put() { # <name> <version>
    awk -v n="$1" '$1 != n' "$db" >"${db}.tmp" 2>/dev/null || :
    [ -f "${db}.tmp" ] && mv "${db}.tmp" "$db"
    printf '%s %s\n' "$1" "$2" >>"$db"
}
db_del() {
    awk -v n="$1" '$1 != n' "$db" >"${db}.tmp" 2>/dev/null || :
    [ -f "${db}.tmp" ] && mv "${db}.tmp" "$db"
}
world_put() {
    grep -q "^$1=" "$world" 2>/dev/null && return 0
    printf '%s=%s\n' "$1" "$2" >>"$world"
}
world_del() {
    awk -v n="$1" 'index($0, n "=") != 1' "$world" >"${world}.tmp" 2>/dev/null || :
    [ -f "${world}.tmp" ] && mv "${world}.tmp" "$world"
}
# repo_dir <url>: which feed directory a URL belongs to, so `--repository` is honoured instead
# of guessed at. This is the one fact ac-13 turns on: the package has to come from that source.
repo_dir() {
    if grep -qxF "$1" "${fake}/etc/apk/repositories.d/customfeeds.list" 2>/dev/null; then
        printf '%s\n' "${fake}/feeds/custom"
        return 0
    fi
    if grep -qxF "$1" "${fake}/etc/apk/repositories.d/distfeeds.list" 2>/dev/null; then
        printf '%s\n' "${fake}/feeds/dist"
        return 0
    fi
    printf '%s\n' "${fake}/feeds/empty"
}
feed_body() { # <dir> <name>: the body that feed offers for <name>, or empty
    for f in "$1/$2-"*.apk; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}
body_id() { # <path>: the name and version apk's own file name carries
    stem=${1##*/}
    stem=${stem%.apk}
    rev=${stem##*-}
    rest=${stem%-*}
    ver=${rest##*-}
    printf '%s %s-%s\n' "${rest%-*}" "${ver}" "${rev}"
}

case "${1:-}" in
    list)
        shift
        [ "${1:-}" = "--installed" ] && shift
        name=${1:-}
        if [ -n "${name}" ] && db_has "${name}"; then
            printf '%s-%s x86_64 {%s} (test)\n' "${name}" "$(db_ver "${name}")" "${name}"
        fi
        exit 0
        ;;
    info)
        shift
        [ "${1:-}" = "-e" ] && shift
        db_has "${1:?apk info needs a name}"
        exit $?
        ;;
    update)
        printf 'OK: %s packages\n' "$(wc -l <"$db" | tr -d ' ')"
        exit "${STUB_APK_UPDATE_RC:-0}"
        ;;
    fetch)
        shift
        url=""
        out=""
        name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --repository) url=${2:-}; shift 2 ;;
                -o) out=${2:-}; shift 2 ;;
                *) name=$1; shift ;;
            esac
        done
        [ ! -f "${state}/fetch-broken" ] || { printf 'ERROR: bad gateway\n' >&2; exit 1; }
        src=$(feed_body "$(repo_dir "${url}")" "${name}") || {
            printf 'ERROR: %s: unable to select package\n' "${name}" >&2
            exit 1
        }
        mkdir -p "${out}" || exit 1
        cp "${src}" "${out}/" || exit 1
        printf 'fetching %s\n' "${src##*/}"
        exit 0
        ;;
    add)
        shift
        url=""
        name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --repository) url=${2:-}; shift 2 ;;
                --allow-untrusted | --force-reinstall | -u) shift ;;
                -*) shift ;;
                *) name=$1; shift ;;
            esac
        done
        case "${name}" in
            *.apk)
                [ -f "${name}" ] || { printf 'ERROR: %s: not found\n' "${name}" >&2; exit 1; }
                set -- $(body_id "${name}")
                db_put "$1" "$2"
                world_put "$1" "$2"
                printf 'OK: %s-%s\n' "$1" "$2"
                exit 0
                ;;
        esac
        if [ -n "${url}" ]; then
            src=$(feed_body "$(repo_dir "${url}")" "${name}") || {
                printf 'ERROR: %s: unable to select package from %s\n' "${name}" "${url}" >&2
                exit 1
            }
        else
            src=$(feed_body "${fake}/feeds/dist" "${name}") || {
                printf 'ERROR: %s: unable to select package\n' "${name}" >&2
                exit 1
            }
        fi
        set -- $(body_id "${src}")
        db_put "$1" "$2"
        world_put "$1" "$2"
        printf 'OK: %s-%s\n' "$1" "$2"
        exit 0
        ;;
    del)
        shift
        for n in "$@"; do
            db_del "${n}"
            world_del "${n}"
            printf 'OK: %s purged\n' "${n}"
        done
        exit 0
        ;;
esac
exit 0
APK

# ab-packages: `sources` (ac-13's attribution) and `replay` (ac-12's local class), in the
# interface platform/usr/sbin/ab-packages publishes. `sources` answers out of the installed
# database and the feed directories, so a source that stopped offering a name says so.
cat >"${bin}/ab-packages" <<'ABPKG'
#!/bin/sh
state=${STUB_STATE:?ab-packages needs STUB_STATE}
fake=${STUB_ROOT:?ab-packages needs STUB_ROOT}
inst="${state}/installed"
assets="${fake}/etc/apk/ab/local"

db_has() { grep -q "^$1 " "${inst}" 2>/dev/null; }
db_ver() { awk -v n="$1" '$1 == n { print $2; exit }' "${inst}" 2>/dev/null; }
db_put() {
    awk -v n="$1" '$1 != n' "${inst}" >"${inst}.tmp" 2>/dev/null || :
    [ -f "${inst}.tmp" ] && mv "${inst}.tmp" "${inst}"
    printf '%s %s\n' "$1" "$2" >>"${inst}"
}

case "${1:-}" in
    sources)
        name=${2:?ab-packages sources needs a name}
        db_has "${name}" || {
            printf 'package=%s source=unknown reason=no-answer\n' "${name}"
            exit 1
        }
        case "${name}" in
            "${STUB_LOCAL_PKG:-vault-sample}")
                # Only the installed database answers for a local package: that is the gate's
                # own definition of one.
                printf 'package=%s source=installed\n' "${name}"
                exit 0
                ;;
        esac
        src=$(for f in "${fake}/feeds/dist/${name}-"*.apk; do
            [ -f "$f" ] && { printf '%s\n' "$f"; break; }
        done)
        if [ -n "${src}" ]; then
            printf 'package=%s source=feed url=%s\n' "${name}" "${STUB_DIST_URL}"
        fi
        # The URL is read out of the operator's list, so a source this run added is the one the
        # attribution names - and a list that names nothing attributes nothing.
        curl=$(sed -n 's/[[:space:]]*$//;/^[[:space:]]*#/d;/^[[:space:]]*$/d;p' \
            "${fake}/etc/apk/repositories.d/customfeeds.list" 2>/dev/null | head -n 1)
        if [ -n "${curl}" ]; then
            if [ -n "$(for f in "${fake}/feeds/custom/${name}-"*.apk; do [ -f "$f" ] && printf x; done)" ]; then
                printf 'package=%s source=customfeeds url=%s\n' "${name}" "${curl}"
            fi
        fi
        exit 0
        ;;
    replay)
        shift
        [ "${1:-}" = "--yes" ] && shift
        file=${1:-}
        if [ -z "${file}" ] || [ ! -f "${file}" ]; then
            printf 'replay name=? result=failed reason=no-body\n'
            printf 'replay result=fail ok=0 unchanged=0 failed=1\n'
            exit 1
        fi
        stem=${file##*/}
        stem=${stem%.apk}
        rev=${stem##*-}
        rest=${stem%-*}
        ver=${rest##*-}
        name=${rest%-*}
        mkdir -p "${assets}" || exit 1
        if [ -f "${state}/replay-broken" ]; then
            printf 'replay name=%s version=%s result=failed reason=apk-1\n' "${name}" "${ver}-${rev}"
            printf 'replay result=fail ok=0 unchanged=0 failed=1\n'
            exit 1
        fi
        if [ "${file}" != "${assets}/${name}-${ver}-${rev}.apk" ]; then
            if [ "$(cd "$(dirname "${file}")" && pwd)/${file##*/}" != \
            "$(cd "${assets}" 2>/dev/null && pwd)/${name}-${ver}-${rev}.apk" ]; then
            cp "${file}" "${assets}/${name}-${ver}-${rev}.apk" || exit 1
        fi
        fi
        db_put "${name}" "${ver}-${rev}"
        # A real `apk add --allow-untrusted` writes the world entry too; a replay that only
        # touched the database would make the world assertion below test the stub.
        grep -q "^${name}=" "${fake}/etc/apk/world" 2>/dev/null ||
            printf '%s=%s\n' "${name}" "${ver}-${rev}" >>"${fake}/etc/apk/world"
        printf 'replay name=%s version=%s result=%s\n' "${name}" "${ver}-${rev}" \
            "$(db_has "${name}" && printf unchanged || printf ok)"
        printf 'replay result=ok ok=1 unchanged=0 failed=0\n'
        exit 0
        ;;
esac
exit 0
ABPKG

# The machine. dev_ssh hands the whole remote command over as one argument, so the last
# argument is what the machine would run; the driver's generated program arrives on stdin as
# `sh -s`, and is executed here rather than being echoed, which is what makes the remote half
# under test the driver's own.
#
# POSIX sh on purpose: it runs as `sh`, which is bash on the laptop this file is written on and
# dash on the CI runner, and a bashism in here would fail only on the runner.
cat >"${bin}/ssh" <<'STUB'
#!/bin/sh
cmd=""
for a in "$@"; do cmd=$a; done
printf '%s\n' "${cmd}" >>"${STUB_CALLS:?stub needs STUB_CALLS}"
state=${STUB_STATE:?stub needs STUB_STATE}
fake=${STUB_ROOT:?stub needs STUB_ROOT}
get() { cat "${state}/${1}" 2>/dev/null || printf '%s' "${2-}"; }
put() { printf '%s\n' "$2" >"${state}/${1}"; }

status_line() {
    printf 'slot=%s upper=%s generation=%s committed=%s pending=%s p4=ok data=ok docker=ok swap=ok next=%s disk=/dev/nvme0n1 method=partname boot=%s esp=%s packages=%s packages_reason=none\n' \
        "$(get slot a)" "$(get upper @overlay-25.12.0)" "$(get generation 1)" \
        "$(get committed a)" "$(get pending none)" "$(get committed a)" \
        "$(get boot ok)" "$(get esp ok)" "$(get packages aligned)"
}

# The break one environment variable names, applied at the hop: the moment a real machine's own
# follow and the new base's own files would have done it.
apply_break() {
    case "${STUB_BREAK:-none}" in
        distfeeds-gone)
            # The package did not survive the hop: the record is gone, so the binary is too.
            awk '$1 != "htop"' "${state}/installed" >"${state}/installed.tmp" 2>/dev/null || :
            [ -f "${state}/installed.tmp" ] && mv "${state}/installed.tmp" "${state}/installed"
            ;;
        distfeeds-feed)
            # The binary still runs; the base's own feed has never heard of the package.
            rm -f "${fake}/feeds/dist/"*.apk
            ;;
        customfeeds-rewritten)
            # What the aligner would do if it owned the file: one line rewritten.
            printf 'https://mirror.example/other/x86_64/packages.adb\n' >>"${fake}/etc/apk/repositories.d/customfeeds.list"
            ;;
        customfeeds-gone)
            # The list still names the source; the source no longer resolves.
            rm -f "${fake}/feeds/custom/"*.apk
            ;;
        local-replay)
            # The kept body is there and unchanged; apk refuses to install it on this base.
            printf 'replay refuses this base\n' >"${state}/replay-broken"
            ;;
        customfeeds-new)
            # The source answers for what it already carried; a new package it cannot serve.
            printf 'cannot serve what it has not served\n' >"${state}/fetch-broken"
            ;;
        local-replay)
            # The body is there and unchanged; apk refuses to install it on this base.
            ;;
        local-body)
            # The kept body moved: one byte appended is enough.
            for f in "${fake}/etc/apk/ab/local/"*.apk; do
                [ -f "$f" ] || continue
                printf 'tampered\n' >>"$f"
            done
            ;;
    esac
}

case "${cmd}" in
    'sh -s')
        # The driver's generated half: the program arrives on stdin, exactly as ssh would hand
        # it to the machine's shell.
        exec sh -s
        ;;
    'ab-slot status')
        if [ "${STUB_NO_COMMITTED:-0}" = "1" ]; then
            printf 'slot=a upper=@overlay-25.12.0 generation=1 committed=- pending=none boot=ok esp=ok\n'
            exit 0
        fi
        status_line
        ;;
    'ab-slot rootfs') get rootfs 25.12.0 ;;
    'ab-slot gc' | 'true') exit 0 ;;
    'cat > '*)
        target=$(printf '%s' "${cmd#cat > }" | tr -d "'")
        mkdir -p "$(dirname "${target}")" 2>/dev/null || :
        cat >"${target}"
        ;;
    'ab-upgrade --check '*)
        [ "${STUB_CHECK_RC:-0}" = "0" ] || {
            printf 'ab-upgrade: refused, reason=payload-already-installed\n'
            exit "${STUB_CHECK_RC}"
        }
        exit 0
        ;;
    'ab-upgrade --yes '*)
        payload=${cmd##* }
        new=""
        case "${payload}" in
            *25.12.1.tar) new=25.12.1 ;;
            *25.12.2.tar) new=25.12.2 ;;
        esac
        [ -n "${new}" ] || { printf 'ab-upgrade: unknown payload\n' >&2; exit 1; }
        put generation "$(( $(get generation 1) + 1 ))"
        put next_rootfs "${new}"
        if [ "$(get slot a)" = "a" ]; then put pending b; else put pending a; fi
        apply_break
        printf 'ab-upgrade: installed %s into slot %s\n' "${new}" "$(get pending a)"
        ;;
    'sync; reboot')
        target=$(get pending "$(get slot a)")
        put slot "${target}"
        put committed "${target}"
        put pending none
        put rootfs "$(get next_rootfs "$(get rootfs)")"
        put upper "@overlay-$(get rootfs)"
        # The follow's own record. `dropped=` is the only place a machine says which world
        # entries its prune removed, and the driver reads exactly that field.
        if [ -n "${STUB_LOSS_WORLD:-}" ]; then
            awk -v n="${STUB_LOSS_WORLD}" 'index($0, n "=") != 1' "${fake}/etc/apk/world" >"${fake}/etc/apk/world.tmp" 2>/dev/null || :
            [ -f "${fake}/etc/apk/world.tmp" ] && mv "${fake}/etc/apk/world.tmp" "${fake}/etc/apk/world"
            printf 'packages=aligned reason=none refresh=1\n' >"${fake}/boot/ab/packages"
        elif [ -n "${STUB_DROP_WORLD:-}" ]; then
            awk -v n="${STUB_DROP_WORLD}" 'index($0, n "=") != 1' "${fake}/etc/apk/world" >"${fake}/etc/apk/world.tmp" 2>/dev/null || :
            [ -f "${fake}/etc/apk/world.tmp" ] && mv "${fake}/etc/apk/world.tmp" "${fake}/etc/apk/world"
            printf 'packages=aligned reason=none world_dropped=1 dropped=%s refresh=1\n' "${STUB_DROP_WORLD}" \
                >"${fake}/boot/ab/packages"
        else
            printf 'packages=aligned reason=none refresh=1\n' >"${fake}/boot/ab/packages"
        fi
        ;;
    'for d in /mnt/slots/'*) exit 0 ;;
    'cat '*) cat "$(printf '%s' "${cmd#cat }" | tr -d "'")" 2>/dev/null ;;
    *) exit 0 ;;
esac
exit 0
STUB

chmod +x "${bin}/ssh" "${bin}/apk" "${bin}/ab-packages" "${bin}/htop" "${bin}/sha256sum"

# --- the harness ------------------------------------------------------------ #
# reset_machine [<base>]: a healthy machine at the bottom of the chain, with the user's own
# source already in the list (ac-13's premise), a distfeeds sample in its feed and a body in the
# kept-body store.
reset_machine() {
    base=${1:-25.12.0}
    rm -rf "${state}" "${fake}" "${evidence}" "${baseline}" "${results}" "${calls}"
    mkdir -p "${state}" "${fake}/etc/config" "${fake}/etc/apk/repositories.d" \
        "${fake}/etc/apk/ab/local" "${fake}/data/ab-follow" "${fake}/boot/ab" "${fake}/tmp" \
        "${fake}/feeds/dist" "${fake}/feeds/custom"
    printf '%s\n' "${base}" >"${state}/rootfs"
    printf 'a\n' >"${state}/slot"
    printf 'a\n' >"${state}/committed"
    printf 'none\n' >"${state}/pending"
    printf '1\n' >"${state}/generation"
    printf 'ok\n' >"${state}/boot"
    printf 'ok\n' >"${state}/esp"
    printf 'aligned\n' >"${state}/packages"
    printf '@overlay-%s\n' "${base}" >"${state}/upper"
    : >"${state}/installed"
    : >"${fake}/etc/apk/world"
    printf 'packages=aligned reason=none refresh=1\n' >"${record}"
    # The three sources, as files the machine reads:
    #   distfeeds.list   the base's own feed, rewritten by every hop
    #   customfeeds.list the operator's own source, which the aligner never rewrites
    #   feeds/           what each of them serves
    printf '%s\n' "https://base.example/releases/${base}/packages/x86_64/packages.adb" >"${distfeeds}"
    printf "# the operator's own source\n%s\n" \
        "https://custom.example/x86_64/packages.adb" >"${customfeeds}"
    printf 'body of htop\n' >"${fake}/feeds/dist/htop-3.5.3-r0.apk"
    printf 'body of jq\n' >"${fake}/feeds/custom/jq-1.7.1-r0.apk"
    printf 'body of tmux\n' >"${fake}/feeds/custom/tmux-3.4-r0.apk"
    printf 'config system \x27system\x27\n' >"${config_dir}/system"
    : >"${calls}"
}

# drv [args...]: the driver against the stub machine, budgets cut to seconds.
drv() {
    PATH="${bin}:${PATH}" \
        STUB_CALLS="${calls}" STUB_STATE="${state}" STUB_ROOT="${fake}" \
        STUB_DIST_URL="https://base.example/releases/x/packages/x86_64/packages.adb" \
        STUB_CUSTOM_URL="https://custom.example/x86_64/packages.adb" \
        STUB_LOCAL_PKG="vault-sample" \
        STUB_BREAK="${STUB_BREAK:-none}" \
        STUB_DROP_WORLD="${STUB_DROP_WORLD:-}" \
        STUB_LOSS_WORLD="${STUB_LOSS_WORLD:-}" \
        AB_KEY="${tmp}/key" AB_HOST=root@stub AB_REMOTE_TMP="${scratch}" \
        AB_RESULTS="${RESULTS:-${results}}" AB_EVIDENCE_DIR="${EVIDENCE:-${evidence}}" \
        AB_POLL_INTERVAL=1 AB_WAIT_UP=1 AB_WAIT_UP_FIRST=1 AB_WAIT_UP_HARD=2 \
        AB_PKGCLASS_STATE="${BASELINE:-${baseline}}" \
        AB_PKGCLASS_MARKER_DIR="${marker_dir}" AB_PKGCLASS_CONFIG_DIR="${config_dir}" \
        AB_PKGCLASS_CUSTOMFEEDS="${customfeeds}" AB_PKGCLASS_WORLD="${world}" \
        AB_PKGCLASS_ASSETS="${assets}" AB_PKGCLASS_RECORD="${record}" \
        AB_PKGCLASS_SCRATCH="${scratch}" \
        AB_PKGCLASS_DISTFEED_PKG=htop \
        AB_PKGCLASS_DISTFEED_CHECK="${bin}/htop --version" \
        AB_PKGCLASS_DISTFEED_EXPECT='^htop [0-9]' \
        AB_PKGCLASS_CUSTOMFEED_PKG=jq \
        AB_PKGCLASS_CUSTOMFEED_URL="${CUSTOM_URL-https://custom.example/x86_64/packages.adb}" \
        AB_PKGCLASS_NEW_PKG=tmux \
        AB_PKGCLASS_LOCAL_PKG="${LOCAL_PKG-vault-sample}" \
        AB_PKGCLASS_LOCAL_APK="${LOCAL_APK-${local_body}}" \
        sh "${driver}" "$@" 2>&1
}

rows() { cut -f1 "${RESULTS:-${results}}" 2>/dev/null | tr '\n' ' '; }
verdicts() { cut -f2 "${RESULTS:-${results}}" 2>/dev/null | tr '\n' ' '; }
note_of() { awk -F'\t' -v c="$1" '$1 == c { print $4; exit }' "${RESULTS:-${results}}" 2>/dev/null; }
installs() { grep -c 'ab-upgrade --yes' "${calls}" 2>/dev/null || true; }
baseline_rows() { grep -c '^\(distfeeds\|customfeeds\|local\)	' "${baseline}" 2>/dev/null || true; }

# --- the plan, and it touches nothing -------------------------------------- #
# A dry run is read by an operator standing in front of one machine: it has to say what each hop
# expects and what each class will be judged on, and it may not open a socket to find out.
reset_machine
out=$(drv --dry-run)
eq "$?" "0" "ac-12 --dry-run exits zero"
eq "$(printf '%s\n' "${out}" | grep -oE '^# (C1|C2) ' | awk '{print $2}' | tr '\n' ' ')" \
    "C1 C2 " "ac-12 the chain is planned in one order, climbing"
eq "$(wc -l <"${calls}" | tr -d ' ')" "0" "ac-12 --dry-run sends no ssh, not one"
eq "$([ -f "${results}" ] && echo written || echo absent)" "absent" \
    "ac-12 --dry-run writes no result row"
eq "$([ -d "${evidence}" ] && echo created || echo absent)" "absent" \
    "ac-12 --dry-run creates no evidence directory"
eq "$([ -f "${baseline}" ] && echo written || echo absent)" "absent" \
    "ac-12 --dry-run records no baseline"
c1_line=$(printf '%s\n' "${out}" | grep '^# C1 ')
contains "${c1_line}" "kind=base" "ac-12 every hop of this chain carries a base"
contains "${c1_line}" "from-rootfs=25.12.0 to-rootfs=25.12.1" \
    "ac-12 the first hop names the base it starts from and the one it installs"
contains "${c1_line}" "direction=up" "ac-12 the hop says which way it goes"
contains "${c1_line}" "rollback=older" "ac-12 after a rise the slot left behind is the older base"
contains "${c1_line}" "classes=distfeeds,customfeeds,local" \
    "ac-12 the plan names the three classes it will judge"
contains "${c1_line}" "baseline=record-once" \
    "ac-12 the plan says the baseline is recorded once"
contains "${out}" "class distfeeds: record" "ac-12 the plan states the distfeeds criterion"
contains "${out}" "class customfeeds: customfeeds.list byte-identical" \
    "ac-13 the plan states the customfeeds criterion as byte-identity"
contains "${out}" "class local: record" "ac-12 the plan states the local criterion"
contains "${out}" "world_dropped" "ac-12 the plan says a pruned world entry is recorded, not lost"
contains "${out}" "install htop from distfeeds.list" \
    "ac-12 the plan names the source each class is installed from"

# --- ac-12/ac-13: the whole chain ------------------------------------------ #
reset_machine
out=$(drv)
rc=$?
eq "${rc}" "0" "ac-12 the chain on a healthy machine exits zero"
eq "$(rows)" "C1 C2 " "ac-12 one row per hop, in chain order"
eq "$(verdicts)" "PASS PASS " "ac-12 every hop passes"
eq "$(installs)" "2" "ac-12 each hop installs its own payload"
eq "$(grep -cE 'ab-upgrade --check' "${calls}" || true)" "2" \
    "ac-12 every hop is validated before it is written"
eq "$(baseline_rows)" "3" "ac-12 the baseline records all three classes"
contains "$(sed -n '1p' "${baseline}")" "schema=1" "ac-12 the baseline carries a schema"
contains "$(sed -n '1p' "${baseline}")" "customfeeds_sha256=" \
    "ac-13 the baseline records the user's list by sha256"

# The row has to carry a verdict per class: a single "samples ok" would not say which of the
# three sources survived.
contains "$(note_of C1)" "classes=distfeeds:pass,customfeeds:pass,local:pass" \
    "ac-12 every class has a verdict of its own in the row"
contains "$(note_of C2)" "classes=distfeeds:pass,customfeeds:pass,local:pass" \
    "ac-12 and the verdict is reached again after the second hop"
contains "$(note_of C1)" "customfeeds-list=unchanged" \
    "ac-13 the row says the user's list did not move"
contains "$(note_of C1)" "base 25.12.0->25.12.1 (up)" \
    "ac-12 the row names the base it climbed and the direction it took"
contains "$(note_of C2)" "base 25.12.1->25.12.2 (up)" \
    "ac-12 the second hop climbs the second base"
contains "$(note_of C1)" "replay=result=ok,failed=0" \
    "ac-12 the row records the replay the local class was judged on"
contains "$(note_of C1)" "new=tmux:install=yes,del=removed" \
    "ac-13 the row records the new package the source had not served yet"
contains "$(note_of C1)" "world_dropped=none" \
    "ac-12 a hop that pruned nothing says so"

# The baseline is recorded once for the whole chain, and a later run finds it instead of
# recording a second one: re-marking after a hop would record the post-hop configuration as the
# truth, which is the fact the hop measures.
contains "$(cat "${evidence}/00-baseline.log")" "baseline created" \
    "ac-12 the baseline is recorded, once, before the first hop"
out=$(drv --only C1)
contains "${out}" "already records the three classes" \
    "ac-12 a baseline that is there is judged, not recorded again"
eq "$(grep -c "config pkgclass 'distfeeds'" "${config_dir}/htop")" "1" \
    "ac-12 and the machine's fake config is not re-marked by that run"

# The user's own file is the operator's: byte-identical after the chain.
eq "$(cat "${customfeeds}")" '# the operator'"'"'s own source
https://custom.example/x86_64/packages.adb' \
    "ac-13 the user's list is byte-identical after the chain"
# Every class's fake configuration and /data marker are still what the baseline recorded, and
# they are still the only thing this driver wrote there.
eq "$(grep -c "config pkgclass 'distfeeds'" "${config_dir}/htop")" "1" \
    "ac-12 the distfeeds fake config survived both hops"
eq "$(grep -c 'option ab_marker' "${config_dir}/htop")" "1" \
    "ac-12 the distfeeds fake config carries exactly one marker option"
eq "$(grep -c "config pkgclass 'customfeeds'" "${config_dir}/jq")" "1" \
    "ac-13 the customfeeds fake config survived both hops"
eq "$(grep -c "config pkgclass 'local'" "${config_dir}/vault-sample")" "1" \
    "ac-12 the local fake config survived both hops"
eq "$([ -f "${marker_dir}/htop.marker" ] && echo there || echo absent)" "there" \
    "ac-12 the distfeeds /data marker is still there"
eq "$([ -f "${marker_dir}/jq.marker" ] && echo there || echo absent)" "there" \
    "ac-13 the customfeeds /data marker is still there"
eq "$([ -f "${marker_dir}/vault-sample.marker" ] && echo there || echo absent)" "there" \
    "ac-12 the local /data marker is still there"
eq "$([ -f "${assets}/vault-sample-2.1-r0.apk" ] && echo there || echo absent)" "there" \
    "ac-12 the kept body is still in /etc/apk/ab/local/ under the same name"
eq "$(hash_file "${assets}/vault-sample-2.1-r0.apk")" "$(hash_file "${local_body}")" \
    "ac-12 the kept body is byte-identical to the file it was taken from"

# --- ac-12: one class at a time, and the row names which ------------------- #
# The distfeeds sample stopped running after the hop. The other two classes still pass, and
# the row has to say which one is red: a chain that reported "a class failed" would leave the
# reader to guess.
reset_machine
out=$(STUB_BREAK=distfeeds-gone drv)
eq "$?" "1" "ac-12 a distfeeds sample that stopped running fails the hop"
eq "$(verdicts)" "FAIL " "ac-12 the hop is the FAIL row"
contains "$(note_of C1)" "class=distfeeds" "ac-12 the row names distfeeds"
contains "$(note_of C1)" "classes=distfeeds:fail,customfeeds:pass,local:pass" \
    "ac-12 the other two classes still pass, one verdict each"
eq "$(installs)" "1" "ac-12 the chain stops at the hop that failed"

# The local body moved: a kept body that no longer hashes to what the baseline saw is not the
# body that would be replayed, whatever the package record still says.
reset_machine
out=$(STUB_BREAK=local-body drv)
eq "$?" "1" "ac-12 a changed kept body fails the hop"
contains "$(note_of C1)" "class=local" "ac-12 the row names local"
contains "$(note_of C1)" "reason=body-changed" "ac-12 and says the body's bytes moved"

# The replay itself fails: the local class's own criterion, and the only one that says the
# package can still be installed on the base the machine now runs.
reset_machine
out=$(STUB_BREAK=local-replay drv)
eq "$?" "1" "ac-12 a failed replay fails the hop"
contains "$(note_of C1)" "class=local" "ac-12 a failed replay names local"
contains "$(note_of C1)" "reason=replay-failed" "ac-12 and says the replay is what failed"

# --- ac-13: the user's source, three ways it can go wrong ------------------ #
# The one failure ac-13 exists for: the list was rewritten. Byte-identity is the assertion, so
# one appended line is enough to go red.
reset_machine
out=$(STUB_BREAK=customfeeds-rewritten drv)
eq "$?" "1" "ac-13 a rewritten customfeeds.list fails the hop"
contains "$(note_of C1)" "class=customfeeds" "ac-13 the row names customfeeds"
contains "$(note_of C1)" "reason=customfeeds-rewritten" \
    "ac-13 and says the file is what moved"
contains "$(note_of C1)" "customfeeds-list=rewritten" \
    "ac-13 the row records the file's verdict, not only the class's"

# The list still names the source, and the source no longer resolves: a file that is unchanged
# and a source that is gone are two different sentences.
reset_machine
out=$(STUB_BREAK=customfeeds-gone drv)
eq "$?" "1" "ac-13 a source that stopped resolving fails the hop"
contains "$(note_of C1)" "class=customfeeds" "ac-13 that failure names customfeeds"
contains "$(note_of C1)" "customfeeds-list=unchanged" \
    "ac-13 the file itself was not what moved in this case"
contains "$(note_of C1)" "source-gone" "ac-13 and the reason is the source, not the file"

# A source that can serve what it already carried but not a package it has not served yet is
# not a source a user can keep using.
reset_machine
out=$(STUB_BREAK=customfeeds-new drv)
eq "$?" "1" "ac-13 a source that cannot install a new package fails the hop"
contains "$(note_of C1)" "class=customfeeds" "ac-13 that failure names customfeeds"
contains "$(note_of C1)" "cannot-install-new" "ac-13 and the reason is the install"

# A sample the new base's own feed stopped offering is the distfeeds class's criterion, even
# though the binary still runs: "installed" is not "available from the feed this base reads".
reset_machine
out=$(STUB_BREAK=distfeeds-feed drv)
eq "$?" "1" "ac-12 a name the new base's feed stopped offering fails the hop"
contains "$(note_of C1)" "class=distfeeds" "ac-12 that failure names distfeeds"
contains "$(note_of C1)" "feed-no-longer-offers" "ac-12 and says the feed is what changed"

# --- ac-12: the world entry ----------------------------------------------- #
# A world entry the follow's prune removed is the one legitimate way it disappears: the entry
# is recorded and the class is judged on its other facts.
reset_machine
out=$(STUB_BREAK=none STUB_DROP_WORLD=jq drv)
eq "$?" "0" "ac-12 a pruned world entry does not fail the hop"
contains "$(note_of C1)" "world_dropped=jq" "ac-12 the row records what the prune dropped"
contains "$(note_of C1)" "customfeeds:pass" \
    "ac-12 the class whose entry was pruned is still judged on its own facts"

# An entry that is gone and that nothing on the machine accounts for is a loss, and a loss is
# not a prune: the record names what it dropped, and this one names nothing.
reset_machine
out=$(STUB_LOSS_WORLD=jq drv)
eq "$?" "1" "ac-12 a world entry lost without a record fails the hop"
contains "$(note_of C1)" "class=customfeeds" "ac-12 the loss names the class whose entry went"
contains "$(note_of C1)" "reason=world-lost" "ac-12 and says the world entry is what went missing"

# --- ac-12: a body the store already keeps -------------------------------- #
# --local-pkg adopts a body already in /etc/apk/ab/local/ instead of pushing one: that is the
# state of a machine where a local package was installed on an earlier base.
reset_machine
printf 'a body the store already keeps\n' >"${assets}/vault-sample-2.1-r0.apk"
out=$(LOCAL_PKG=vault-sample LOCAL_APK= drv --only C1)
eq "$?" "0" "ac-12 a body already kept is adopted instead of pushed"
contains "$(note_of C1)" "local:pass" \
    "ac-12 and the local class is judged on the body the store already held"
eq "$(grep -c 'cat > .*vault-sample' "${calls}" || true)" "0" \
    "ac-12 no body is pushed when the store already holds one"

# --- ac-13: the source this run brought ----------------------------------- #
# When the operator's file does not carry the source yet, --customfeed-url is where it goes: it
# is added inside a marked block, indexed once, and left behind, because it is the source
# ac-13 asks about and not a trace of this run.
reset_machine
printf '# nothing of the operator\x27s own yet\n' >"${customfeeds}"
out=$(drv --only C1 --customfeed-url https://mirror.example/immortalwrt/25.12.0/x86_64/packages.adb)
eq "$?" "0" "ac-13 a run that brings its own source passes"
contains "$(cat "${customfeeds}")" '# ab-pkgclass source begin' \
    "ac-13 the added source is marked, so a later run recognises its own block"
contains "$(cat "${customfeeds}")" 'https://mirror.example/immortalwrt/25.12.0/x86_64/packages.adb' \
    "ac-13 the added source is the URL it was given"
eq "$(grep -c 'ab-pkgclass source begin' "${customfeeds}")" "1" \
    "ac-13 the block is written once, not once per hop"
contains "${out}" "source_state added" \
    "ac-13 the run records that it added the source, and that it was indexed"

# A source the run did not have to add is the operator's: its file is not touched at all.
reset_machine
before=$(cat "${customfeeds}")
out=$(drv --only C1)
eq "$?" "0" "ac-13 a run that finds the source in place passes"
eq "$(cat "${customfeeds}")" "${before}" "ac-13 a source that was already there is not written to"
contains "${out}" "source_state preexisting" \
    "ac-13 and the run records that the source was already there"

# --- environment, baseline and usage --------------------------------------- #
# A payload that is not there is an environment gap, named before the machine is touched.
reset_machine
mkdir -p "${tmp}/empty"
out=$(RESULTS="${tmp}/gap.tsv" drv --payload-dir "${tmp}/empty")
eq "$?" "4" "ac-12 a payload that is not there is an environment gap"
eq "$(cut -f2 "${tmp}/gap.tsv")" "GAP" "ac-12 the row is GAP when the payload is missing"
eq "$(wc -l <"${calls}" | tr -d ' ')" "0" \
    "ac-12 a missing payload is reported before the machine is touched"

# A local class with no body is the chain's own precondition: a package the feeds still offer
# is superseded, not local, so the row names the class and the flag that supplies a body.
reset_machine
out=$(LOCAL_PKG= LOCAL_APK= RESULTS="${tmp}/nobody.tsv" BASELINE="${tmp}/nobody-baseline.tsv" drv --only C1)
eq "$?" "4" "ac-12 a local class with no body is a gap"
eq "$(cut -f2 "${tmp}/nobody.tsv")" "GAP" "ac-12 the row is GAP, never PASS"
contains "$(cut -f4 "${tmp}/nobody.tsv")" "local" "ac-12 the gap names the class it is about"
contains "${out}" "--local-apk" "ac-12 and names the flag that supplies a body"
eq "$([ -f "${tmp}/nobody-baseline.tsv" ] && echo written || echo absent)" "absent" \
    "ac-12 nothing is recorded when the baseline cannot be established"

# No source in the file and none named: ac-13's premise is missing, which is a gap and not a
# verdict about the machine's packages.
reset_machine
: >"${customfeeds}"
out=$(CUSTOM_URL= RESULTS="${tmp}/nosrc.tsv" BASELINE="${tmp}/nosrc-baseline.tsv" drv --only C1)
eq "$?" "4" "ac-13 a machine with no user source is a gap"
contains "$(cut -f4 "${tmp}/nosrc.tsv")" "customfeeds" \
    "ac-13 the gap names the class whose premise is missing"

# A machine with no committed slot stops the run at the red line, before anything is written.
reset_machine
out=$(STUB_NO_COMMITTED=1 RESULTS="${tmp}/red.tsv" BASELINE="${tmp}/red-baseline.tsv" drv --only C1)
eq "$?" "3" "ac-12 a machine with no committed slot stops the run at the red line"
contains "${out}" "red-line" "ac-12 the red line says what it refused to do"
eq "$([ -f "${tmp}/red.tsv" ] && echo written || echo absent)" "absent" \
    "ac-12 the red line writes no verdict row for a hop it never walked"

# --- --only, --from and --resume ------------------------------------------- #
reset_machine
out=$(drv --only C1)
eq "$?" "0" "ac-12 --only walks one hop"
eq "$(rows)" "C1 " "ac-12 --only records that hop and nothing else"

# A machine already past the step it was told to walk fails the hop's own chain-position
# assertion, and the row says so rather than reporting a broken payload.
reset_machine 25.12.1
out=$(drv --only C1)
eq "$?" "1" "ac-12 a hop whose start the machine is past fails"
contains "$(note_of C1)" "chain broken" "ac-12 the row says the machine is not where the hop starts"

reset_machine 25.12.1
printf 'C1\tPASS\t-\tfrom an earlier run\n' >"${results}"
out=$(drv --from 2)
eq "$?" "0" "ac-12 --from 2 walks the rest of the chain"
eq "$(rows)" "C1 C2 " "ac-12 the resumed run keeps the earlier row and adds its own"
eq "$(installs)" "1" "ac-12 --from starts at the step it was given, not at the top"

# --resume skips what already passed, and only while everything before it passed too: skipping
# a hole would walk a later hop on a machine that never made the earlier one.
reset_machine 25.12.1
printf 'C1\tPASS\t-\tfrom an earlier run\n' >"${results}"
out=$(drv --resume)
eq "$(installs)" "1" "ac-12 --resume does not walk a hop that already passed"
reset_machine
printf 'C1\tFAIL\t-\tfrom an earlier run\n' >"${results}"
out=$(drv --resume)
eq "$(installs)" "2" "ac-12 --resume does not resume over a hole"

# --- usage ------------------------------------------------------------------ #
reset_machine
out=$(drv --nonsense)
eq "$?" "2" "ac-12 an unknown argument is a usage error"
out=$(drv --only XX)
eq "$?" "2" "ac-12 an unknown case is a usage error"
out=$(drv --only C1 --from 2)
eq "$?" "2" "ac-12 --only and --from are exclusive"
out=$(drv --from 99)
eq "$?" "2" "ac-12 --from needs a step that exists"
out=$(drv --only C1 --distfeed-pkg 'bad name')
eq "$?" "2" "ac-12 a package name that would have to be escaped is a usage error"
out=$(drv --help)
eq "$?" "0" "ac-12 --help exits zero"
contains "${out}" "--local-apk" "ac-12 and lists the flag the local class needs"

finish
