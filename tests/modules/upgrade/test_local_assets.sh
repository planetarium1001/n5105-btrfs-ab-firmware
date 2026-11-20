#!/usr/bin/env bash
# Module: upgrade
# The kept bodies of local packages: what a replay installs, and what the store refuses to keep.
#
# A follow asks the feeds for every world entry, so a package that came from a feed follows the
# base by itself. A package installed from a local `.apk` has no source at all: apk records that
# it is installed and never where it came from, and the body is gone when the transaction ends
# (measured 2026-11-18: `find / -name '*.apk'` is empty on the device, because /var is a tmpfs).
# `/etc/apk/ab/local/` is where a body is kept so that such a package can be replayed onto the
# next base.
#
#   ac-1 a body is kept under apk's own `<name>-<version>.apk` name, which is the name the gate's
#        L proposition looks for (`ls <assets>/<name>-*.apk`). A file that does not follow that
#        naming is stored under the name and version its own `.PKGINFO` carries, and a file this
#        library cannot name is refused instead of being filed under a guess.
#   ac-2 one body per name: capturing a higher version removes the lower one, and the version the
#        machine runs is never removed as a duplicate.
#   ac-3 a body whose name a feed starts offering is `superseded`: journalled first, deleted
#        second, so "this package stopped being replayable from a kept body" is a fact on disk.
#   ac-4 the store is bounded by AB_PKGS_CACHE_MAX, and over the bound the oldest bodies that are
#        not the installed version go first.
#   ac-5 replay is one `apk add --allow-untrusted <body>` per body on the root being repaired -
#        no `--force-*`, no `--overwrite`, no `--root /` - and a `/etc/config/*` the user edited
#        keeps its checksum while the package's copy lands as `*.apk-new`.
#   ac-6 nothing outside `<root>/etc/apk/ab/` is written except what apk itself installs, and the
#        library never names /data: the store rides the writable layer with `world` (design §10).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

lib="$root/platform/lib/ab-pkgs-assets.sh"
if [ ! -f "$lib" ]; then
  printf 'not ok 1 - the kept-body library exists\n' >&2
  printf '    missing %s\n' "$lib" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- a machine-shaped tree ---------------------------------------------------
# The store lives beside `world` and the apk database on the writable layer, so the fixture is
# the root the tool would see: a world, feeds, the installed database and one file the user
# edited under /etc/config.
fixture_root="$tmp/root"
mkroot() {
  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/etc/apk/repositories.d" "$fixture_root/lib/apk/db" \
    "$fixture_root/etc/config" "$fixture_root/etc/apk/ab/local"
  cat >"$fixture_root/etc/apk/world" <<'WORLD'
base-files=1950~0c4cd0f9920a
busybox
kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
libc=1.2.5-r5
htop=3.3.0-r1
luci-theme-argon
WORLD
  printf '%s\n' 'https://downloads.example/releases/25.12.2/targets/x86/64/packages/packages.adb' \
    >"$fixture_root/etc/apk/repositories.d/distfeeds.list"
  printf '%s\n' 'https://pkgs.example.net/x86_64/packages.adb' \
    >"$fixture_root/etc/apk/repositories.d/customfeeds.list"
  cat >"$fixture_root/lib/apk/db/installed" <<'DB'
C:Q1aaaa=
P:htop
V:3.3.0-r1
D:so:libc.so.6

C:Q1bbbb=
P:luci-theme-argon
V:1.0-r2
D:kernel=6.12.103~0413601b1c3f0490e17f340fe09229ea-r1
DB
  # The user's own edit of a config file the package also ships. This is the file ac-7 says
  # must survive a replay byte for byte.
  printf 'config interface lan\n\toption proto dhcp\n\toption ifname eth0\n' \
    >"$fixture_root/etc/config/htop"
}
mkroot

bin="$tmp/bin"
mkdir -p "$bin"
calls="$tmp/apk-calls"
: >"$calls"

# --- the stand-in for apk-tools ---------------------------------------------
# Three applets matter, and each is written to the behaviour measured on the device on
# 2026-11-18 rather than to a convenient shape:
#
#   policy <name>            the candidate versions and the sources that offer them, one source
#                            per line (`lib/apk/db/installed` for the installed database, a feed
#                            URL otherwise)
#   version -t <a> <b>       `<`, `=` or `>`, ordered on the numeric part of the version
#   add --allow-untrusted <file>
#                            install the file; a `/etc/config/*` the user edited keeps its bytes
#                            and the package's copy lands as `*.apk-new`
cat >"$bin/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >>"${APK_CALLS:-/dev/null}"
root=""
applet=""
allow=0
simulate=0
arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    --allow-untrusted) allow=1; shift ;;
    --simulate) simulate=1; shift ;;
    --cache-dir|--timeout|--repositories-file) shift 2 ;;
    --no-network) shift ;;
    version|policy|add|adbdump) applet=$1; shift ;;
    -*) shift ;;
    *)
      if [ "$applet" = "version" ]; then
        if [ -z "$v1" ]; then v1=$1; else v2=$1; fi
      else
        arg=$1
      fi
      shift
      ;;
  esac
done

db_version() {
  [ -f "$root/lib/apk/db/installed" ] || return 0
  awk -v want="$1" '
    /^P:/ { pkg = substr($0, 3); next }
    pkg == want && /^V:/ { print substr($0, 3); exit }
  ' "$root/lib/apk/db/installed"
}

db_set() {
  name=$1
  ver=$2
  file="$root/lib/apk/db/installed"
  awk -v name="$name" -v ver="$ver" '
    { pkg_before = pkg }
    /^P:/ { pkg = substr($0, 3) }
    pkg == name && /^V:/ { print "V:" ver; done = 1; next }
    { print }
    END { if (!done) { print ""; print "P:" name; print "V:" ver } }
  ' "$file" >"$file.new" 2>/dev/null || return 0
  mv "$file.new" "$file"
}

# fixture_identity: `<name> <version>` for a fixture body. The fixtures are either a real tar
# package (the shape the library falls back to for v2) or a synthetic v3 body: the literal
# `ADBd` magic followed by the identity a real `apk adbdump` would print, kept in `<file>.info`.
# A body in the store has neither, so the relaxed `<name>-<version>.apk` name is the last answer.
fixture_identity() {
  if info=$(tar -xzOf "$1" .PKGINFO 2>/dev/null) || info=$(tar -xzOf "$1" ./.PKGINFO 2>/dev/null); then
    name=$(printf '%s\n' "$info" | sed -n 's/^pkgname[ ]*=[ ]*//p' | head -n 1)
    ver=$(printf '%s\n' "$info" | sed -n 's/^pkgver[ ]*=[ ]*//p' | head -n 1)
    [ -n "$name" ] && [ -n "$ver" ] && { printf '%s %s\n' "$name" "$ver"; return 0; }
  fi
  if [ -f "$1.info" ]; then
    name=$(sed -n 's/^name=//p' "$1.info" | head -n 1)
    ver=$(sed -n 's/^version=//p' "$1.info" | head -n 1)
    [ -n "$name" ] && [ -n "$ver" ] && { printf '%s %s\n' "$name" "$ver"; return 0; }
  fi
  file=${1##*/}
  file=${file%.apk}
  last=${file##*-}
  rest=${file%-*}
  [ "$rest" = "$file" ] && return 1
  case "$last" in
    r?*)
      num=${last#r}
      case "$num" in
        '' | *[!0-9]*) ;;
        *)
          ver=${rest##*-}
          name=${rest%-*}
          [ -n "$name" ] && { printf '%s %s\n' "$name" "$ver-$last"; return 0; }
          ;;
      esac
      ;;
  esac
  case "$last" in
    [0-9]*) printf '%s %s\n' "$rest" "$last"; return 0 ;;
  esac
  return 1
}

case "$applet" in
  version)
    a=${v1%-r*}
    b=${v2%-r*}
    awk -v a="$a" -v b="$b" 'BEGIN {
      n = split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 4; i++) {
        if ((x[i] + 0) > (y[i] + 0)) { print ">"; exit }
        if ((x[i] + 0) < (y[i] + 0)) { print "<"; exit }
      }
      print "="
    }'
    ;;
  adbdump)
    [ "$(head -c 4 "$arg" 2>/dev/null)" = "ADBd" ] || {
      printf 'ERROR: %s: ADB header error\n' "$arg" >&2
      exit 99
    }
    id=$(fixture_identity "$arg") || {
      printf 'ERROR: %s: ADB header error\n' "$arg" >&2
      exit 99
    }
    name=${id%% *}
    ver=${id#* }
    printf '#%%SCHEMA: 676B6370\n# ADB block, size: 0, compat: 0, ver: 0\ninfo:\n  name: %s\n  version: %s\n  arch: x86_64\npaths: # 0 items\n' \
      "$name" "$ver"
    ;;
  policy)
    ver=$(db_version "$arg")
    printf '%s policy:\n' "$arg"
    printf '  %s:\n' "${ver:-0}"
    printf '    lib/apk/db/installed\n'
    if [ -f "${APK_FEEDS:-/nonexistent}" ] && grep -qx "$arg" "${APK_FEEDS}"; then
      printf '  %s:\n' "${APK_FEED_VERSION:-9.9.9-r9}"
      printf '    https://downloads.example/releases/25.12.2/targets/x86/64/packages/packages.adb\n'
    fi
    ;;
  add)
    id=$(fixture_identity "$arg") || {
      printf 'ERROR: untrusted archive\n' >&2
      exit 99
    }
    name=${id%% *}
    ver=${id#* }
    if [ "$simulate" = "1" ]; then
      printf '(1/1) Installing %s (%s)\n' "$name" "$ver"
      printf 'OK: 1 MiB in 1 packages\n'
      exit 0
    fi
    [ "$allow" = "1" ] || { printf 'ERROR: untrusted archive\n' >&2; exit 99; }
    x="${APK_EXTRACT:-/tmp}/apk-extract.$$"
    rm -rf "$x"
    mkdir -p "$x"
    tar -xzf "$arg" -C "$x" 2>/dev/null || :
    if [ -d "$x" ] && [ "$(find "$x" -type f 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
      ( cd "$x" && find . -type f ) | while IFS= read -r member; do
        rel=${member#./}
        case "$rel" in
          .PKGINFO|.CONFIG) continue ;;
          etc/config/*)
            if [ -f "$root/$rel" ]; then
              cp "$x/$rel" "$root/$rel.apk-new"
            else
              mkdir -p "$root/$(dirname "$rel")"
              cp "$x/$rel" "$root/$rel"
            fi
            ;;
          *)
            mkdir -p "$root/$(dirname "$rel")"
            cp "$x/$rel" "$root/$rel"
            ;;
        esac
      done
    fi
    db_set "$name" "$ver"
    printf '(1/1) Installing %s (%s)\n' "$name" "$ver"
    ;;
esac
exit 0
APK
chmod +x "$bin/apk"

# apk_calls: the stub's transcript, so a test can assert the exact command line the library used
# rather than trusting that "it worked".
apk_calls() {
  cat "$calls"
}
reset_calls() {
  : >"$calls"
}

# asset_env: one call of the library, in POSIX sh, with the store and the transcript pointed at
# the fixture. `sh -c` on purpose: the library has to run on the image's shell, not only under
# the bash that runs this file.
asset_env() {
  PATH="$bin:$PATH" APK_CALLS="$calls" APK_FEEDS="${APK_FEEDS:-/nonexistent}" \
    APK_EXTRACT="$tmp" AB_PKGS_CACHE_MAX="${AB_PKGS_CACHE_MAX:-268435456}" \
    sh -c ". '$lib'; $1"
}

asset_dir="$fixture_root/etc/apk/ab/local"

# --- ac-6 the library is POSIX sh and never names /data ---------------------
assert_command_ok "ac-6 the library parses as POSIX sh" sh -n "$lib"
assert_eq "$(grep -v '^[[:space:]]*#' "$lib" | grep -c '/data' || true)" "0" \
  "ac-6 no code path in the store reaches into /data: it rides the writable layer with world"
assert_eq "$(asset_env "ab_pkgs_assets_dir '$fixture_root'")" "$asset_dir" \
  "ac-6 the store is under the root being repaired, beside world and the apk database"
assert_eq "$(asset_env "ab_pkgs_assets_dir '/'")" "/etc/apk/ab/local" \
  "ac-6 and on the running root it is exactly /etc/apk/ab/local"

# --- ac-1 keeping a body -----------------------------------------------------
mkapk() { # <dir> <name> <version> [<config content>]
  local d="$1" name=$2 ver=$3 conf=${4:-}
  rm -rf "$d"
  mkdir -p "$d"
  {
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = %s\n' "$ver"
  } >"$d/.PKGINFO"
  mkdir -p "$d/usr/bin"
  printf '#!/bin/sh\necho %s\n' "$name" >"$d/usr/bin/$name"
  if [ -n "$conf" ]; then
    mkdir -p "$d/etc/config"
    printf '%s' "$conf" >"$d/etc/config/$name"
  fi
  tar -czf "$d.apk" -C "$d" .
}

mkapk "$tmp/pkg-htop" htop 3.3.1-r1 'config htop
	option upstream 1
'
reset_calls
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/pkg-htop.apk'" 2>&1)
assert_eq "$?" "0" "ac-1 a well-formed body is kept"
assert_file_exists "$asset_dir/htop-3.3.1-r1.apk" \
  "ac-1 the body is stored under apk's own <name>-<version>.apk name"
assert_eq "$(ls "$asset_dir"/htop-*.apk 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "ac-1 exactly one body exists for the name"
assert_eq "$(cmp -s "$tmp/pkg-htop.apk" "$asset_dir/htop-3.3.1-r1.apk" && printf same)" "same" \
  "ac-1 the kept body is the file byte for byte"

# The gate finds a kept body with `ls <assets>/<name>-*.apk` (packages.sh, L proposition). That
# pattern is the interface between the two files, so it is asserted rather than assumed.
gate_glob=$(ls "$asset_dir"/htop-*.apk 2>/dev/null | head -n 1)
assert_eq "${gate_glob##*/}" "htop-3.3.1-r1.apk" \
  "ac-1 and the gate's own <name>-*.apk glob finds it"

# A renamed file is stored under the name and version its .PKGINFO carries: a user's
# `luci-theme-argon.apk` must not become an asset called `luci-theme-argon` with no version.
mkapk "$tmp/pkg-argon" luci-theme-argon 1.0-r2 'config argon
	option mode dark
'
cp "$tmp/pkg-argon.apk" "$tmp/some-download.apk"
reset_calls
asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/some-download.apk'" >/dev/null 2>&1
assert_file_exists "$asset_dir/luci-theme-argon-1.0-r2.apk" \
  "ac-1 a file that does not follow the naming is kept under its .PKGINFO name and version"
assert_eq "$(ls "$asset_dir"/some-download* 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-1 and never under the name it happened to be downloaded as"

printf 'not a package at all\n' >"$tmp/garbage.apk"
reset_calls
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/garbage.apk'; printf 'state=%s reason=%s' \"\$AB_PKGS_ASSETS_STATE\" \"\$AB_PKGS_ASSETS_REASON\"" 2>&1)
assert_contains "$out" "reason=asset-unidentified" \
  "ac-1 a file that cannot be named is refused, not filed under a guess"
assert_eq "$(ls "$asset_dir"/*.apk 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "ac-1 and the store is left with the two bodies that were named"

# --- ac-2 one body per name --------------------------------------------------
# Two versions of one package are two worlds, and the gate's `<name>-*.apk` glob must not have to
# choose. The higher version stays; the lower one is removed and named.
mkapk "$tmp/pkg-htop-old" htop 2.9.0-r1
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/pkg-htop-old.apk'; printf 'pruned=%s' \"\$AB_PKGS_ASSETS_PRUNED\"" 2>&1)
assert_eq "$(ls "$asset_dir"/htop-*.apk 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "ac-2 capturing a second version leaves one body for the name"
assert_file_exists "$asset_dir/htop-3.3.1-r1.apk" \
  "ac-2 and the body that stays is the higher version"
assert_contains "$out" "htop-2.9.0-r1" \
  "ac-2 the version the prune removed is named, not silently dropped"

# The version the machine runs is not a duplicate: dropping it would delete the one body a
# rollback could replay. htop runs 3.3.0-r1 here only in the database, so this is the fixture
# for a base that moved while a body it still runs is kept.
mkapk "$tmp/pkg-htop-running" htop 3.3.0-r1
asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/pkg-htop-running.apk'" >/dev/null 2>&1
assert_file_exists "$asset_dir/htop-3.3.0-r1.apk" \
  "ac-2 the version the database says is installed survives the prune"

# --- ac-3 superseded ---------------------------------------------------------
# A feed that starts offering the name owns it from then on: it is signed, it follows the base.
# The body is journalled first and deleted second.
mkapk "$tmp/pkg-argon" luci-theme-argon 1.0-r2
cp "$tmp/pkg-argon.apk" "$asset_dir/luci-theme-argon-1.0-r2.apk" 2>/dev/null || :
: >"$tmp/feeds-argon"
APK_FEEDS="$tmp/feeds-argon" out=$(APK_FEEDS="$tmp/feeds-argon" asset_env "ab_pkgs_assets_superseded '$fixture_root'; printf 'superseded=%s' \"\$AB_PKGS_ASSETS_SUPERSEDED\"" 2>&1)
assert_eq "$(ls "$asset_dir"/luci-theme-argon-*.apk 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "ac-3 a name no feed offers is not superseded"

printf 'luci-theme-argon\n' >"$tmp/feeds-argon"
out=$(APK_FEEDS="$tmp/feeds-argon" asset_env "ab_pkgs_assets_superseded '$fixture_root'; printf 'superseded=%s' \"\$AB_PKGS_ASSETS_SUPERSEDED\"" 2>&1)
assert_contains "$out" "luci-theme-argon-1.0-r2" "ac-3 a name a feed offers is superseded"
assert_eq "$(ls "$asset_dir"/luci-theme-argon-*.apk 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 and its body is removed"
assert_file_exists "$asset_dir/superseded" "ac-3 the decision is journalled beside the store"
assert_contains "$(cat "$asset_dir/superseded")" "superseded name=luci-theme-argon version=1.0-r2" \
  "ac-3 the journal names the package and the version it took back"
assert_contains "$(cat "$asset_dir/superseded")" "source=distfeeds" \
  "ac-3 and which feed list took it over, so the entry is actionable"
# The journal is the record of something that can no longer be replayed: it survives the store
# being emptied of that name, which is the whole point of writing it down.
: >"$tmp/feeds-argon"
out=$(APK_FEEDS="$tmp/feeds-argon" asset_env "ab_pkgs_assets_superseded '$fixture_root'; printf 'state=%s' \"\$AB_PKGS_ASSETS_STATE\"" 2>&1)
assert_contains "$out" "state=ok" "ac-3 a store with nothing to supersede says so"

# --- ac-4 the size bound -----------------------------------------------------
# Over the bound, the oldest body that is not the installed version goes first. The fixture
# builds four bodies with distinct ages and a bound that fits two of them.
mkroot
for spec in "alpha 1.0-r1" "beta 1.0-r1" "htop 3.3.0-r1"; do
  name=${spec%% *}
  ver=${spec##* }
  mkapk "$tmp/pkg-$name" "$name" "$ver"
  cp "$tmp/pkg-$name.apk" "$asset_dir/$name-$ver.apk"
  # One second apart, oldest first: the pruning order is the only thing under test, and a
  # file system with a coarse clock would otherwise make the order unobservable.
  touch -t 20260101000$(( ${#name} % 9 )).00 "$asset_dir/$name-$ver.apk" 2>/dev/null || :
done
touch -t 202601010000.00 "$asset_dir/alpha-1.0-r1.apk" 2>/dev/null || :
touch -t 202601010001.00 "$asset_dir/beta-1.0-r1.apk" 2>/dev/null || :
touch -t 202601010002.00 "$asset_dir/htop-3.3.0-r1.apk" 2>/dev/null || :
sizes=$(wc -c <"$asset_dir/alpha-1.0-r1.apk")
out=$(AB_PKGS_CACHE_MAX=$(( sizes * 2 )) asset_env "ab_pkgs_assets_prune '$fixture_root'; printf 'bytes=%s reason=%s pruned=%s' \"\$AB_PKGS_ASSETS_BYTES\" \"\$AB_PKGS_ASSETS_REASON\" \"\$AB_PKGS_ASSETS_PRUNED\"" 2>&1)
assert_contains "$out" "reason=quota" "ac-4 a store over the bound prunes because of the bound"
assert_contains "$out" "alpha-1.0-r1" "ac-4 the oldest body is the first to go"
assert_eq "$( ( [ -f "$asset_dir/htop-3.3.0-r1.apk" ] && printf kept ) )" "kept" \
  "ac-4 the version the database says is installed is kept to the end"
assert_eq "$(asset_env "ab_pkgs_assets_bytes '$fixture_root'")" "$(printf '%s' "$out" | sed -n 's/^bytes=\([0-9]*\).*/\1/p')" \
  "ac-4 the reported size is the store's size, not an estimate"

# --- ac-5 replay -------------------------------------------------------------
mkroot
mkapk "$tmp/pkg-htop" htop 3.3.1-r1 'config htop
	option upstream 1
'
asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/pkg-htop.apk'" >/dev/null 2>&1
before_sum=$(cksum <"$fixture_root/etc/config/htop")
reset_calls
out=$(asset_env "ab_pkgs_assets_replay '$fixture_root'" 2>&1)
assert_contains "$out" "replay name=htop version=3.3.1-r1 result=ok" \
  "ac-5 replay installs the kept body and measures that the version moved"
assert_eq "$(grep -c 'add --allow-untrusted' "$calls" || true)" "1" \
  "ac-5 one transaction per body"
assert_contains "$(apk_calls)" "--root $fixture_root add --allow-untrusted $asset_dir/htop-3.3.1-r1.apk" \
  "ac-5 and the command is apk add --allow-untrusted on the root being repaired"
assert_eq "$(grep -c -e '--force' -e '--overwrite' -e '--reinstall' "$calls" || true)" "0" \
  "ac-5 nothing tells apk to make the body fit: replay installs it as it is"
after_sum=$(cksum <"$fixture_root/etc/config/htop")
assert_eq "$after_sum" "$before_sum" \
  "ac-5 the config file the user edited keeps its checksum across the replay"
assert_file_exists "$fixture_root/etc/config/htop.apk-new" \
  "ac-5 and the package's own copy is left beside it as *.apk-new"
assert_contains "$(cat "$fixture_root/etc/config/htop.apk-new")" "option upstream 1" \
  "ac-5 the *.apk-new file is the package's version, so the difference can be read"
out=$(asset_env "ab_pkgs_assets_replay '/' 'htop' 2>/dev/null; printf 'rc=%s' \$?")
assert_contains "$out" "replay name=htop result=failed reason=no-body" \
  "ac-5 a body that is not in the store is reported as a gap, not as a success"
assert_contains "$out" "rc=1" "ac-5 and the caller gets a failure status"
assert_eq "$(grep -c 'add --allow-untrusted' "$calls" || true)" "1" \
  "ac-5 the replay itself ran exactly once, so the failed attempt did not run it again"

# The running root is spelled as no prefix at all: `apk --root /` would make apk treat the
# machine it is running on as a sandbox, which is not what a replay means.
reset_calls
asset_env "_ab_pkgs_apk '' version -t 1.0-r1 1.0-r1" >/dev/null 2>&1
assert_eq "$(head -n 1 "$calls")" "version -t 1.0-r1 1.0-r1" \
  "ac-5 the running root gets no --root flag"

# --- ac-5 replay of an already installed body -------------------------------
# A body that is installed at the same version answers `unchanged`: the same rule the record
# follows, where a transaction that moved nothing is not a follow.
reset_calls
out=$(asset_env "ab_pkgs_assets_replay '$fixture_root' 'htop'" 2>&1)
assert_contains "$out" "result=unchanged" \
  "ac-5 replaying the version already installed is reported as unchanged, not as a success"

# --- cache: a consumable, never the kept bodies -----------------------------
mkdir -p "$fixture_root/etc/apk/ab/cache"
printf 'body\n' >"$fixture_root/etc/apk/ab/cache/foo-1.0-r1.apk"
asset_env "ab_pkgs_cache_clean '$fixture_root'" >/dev/null 2>&1
assert_eq "$(ls "$fixture_root/etc/apk/ab/cache" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "the cache is emptied when a follow ends"
assert_file_exists "$asset_dir/htop-3.3.1-r1.apk" \
  "and the kept bodies are not what the cache clean touches"
assert_matches "$(asset_env "ab_pkgs_cache_report '$fixture_root'")" \
  '^cache-files=[0-9]+ cache-bytes=[0-9]+ cache-max=[0-9]+$' \
  "the cache report is one line of facts a caller can read"

# --- the command: keeping a body and installing it is one step ---------------
# `ab-packages replay <file>` is how a local package is installed so that its body is kept at the
# same moment: apk keeps nothing itself, so the install and the copy have to be the same act or
# the second one never happens.
esp="$tmp/boot"
mkdir -p "$esp/ab"
printf 'packages=aligned reason=none follow=pending version=25.12.2 kernel=kernel=6.12.103~x slot=a hint=ab-packages update\n' \
  >"$esp/ab/packages"
cli="$root/platform/usr/sbin/ab-packages"
cli_env() {
  PATH="$bin:$PATH" APK_CALLS="$calls" APK_FEEDS="${APK_FEEDS:-/nonexistent}" APK_EXTRACT="$tmp" \
    AB_PACKAGES_ROOT="$fixture_root" AB_ESP="$esp" \
    AB_PACKAGES_FILE="$esp/ab/packages" \
    AB_PACKAGES_LIB="$root/platform/lib/upgrade/packages.sh" \
    AB_PKGS_ASSETS_LIB="$lib" \
    AB_PLAN_LIB="$root/platform/lib/ab-plan.sh" \
    AB_VERSION_LIB="$root/platform/lib/ab-version.sh" \
    sh "$cli" "$@"
}
mkapk "$tmp/pkg-ui" ui 1.0-r1
reset_calls
out=$(cli_env replay --yes "$tmp/pkg-ui.apk" 2>&1)
assert_contains "$out" "replay name=ui version=1.0-r1 result=ok" \
  "ac-1 ab-packages replay installs the file it was handed"
assert_file_exists "$asset_dir/ui-1.0-r1.apk" \
  "ac-1 and keeps its body in the same step, so the next base can replay it"

# --- identity comes from the package, not from the file name ----------------
# A v3 body is a synthetic `ADBd` container plus the info block a real `apk adbdump` prints; the
# stub answers from that sidecar, so a test can give a body any file name and still be honest
# about what the package says. The point under test is which of the two wins.
mkroot
mkadb() { # <path> <name> <version>
  printf 'ADBd' >"$1"
  printf 'name=%s\nversion=%s\n' "$2" "$3" >"$1.info"
}
mkadb "$tmp/minieap-0.94.0_x86-64.apk" minieap 0.94.0
assert_eq "$(asset_env "ab_pkgs_asset_identify '$tmp/minieap-0.94.0_x86-64.apk'")" "minieap 0.94.0" \
  "ac-1 a v3 body whose file name is not apk-shaped is named from its own info block"
assert_eq "$(asset_env "ab_pkgs_asset_format '$tmp/minieap-0.94.0_x86-64.apk'")" "v3" \
  "ac-3 the format sniffer names an ADB container by its magic"
mkadb "$tmp/htop-9.9.9-r9.apk" tree 2.2.1-r2
assert_eq "$(asset_env "ab_pkgs_asset_identify '$tmp/htop-9.9.9-r9.apk'")" "tree 2.2.1-r2" \
  "ac-1 the package's own metadata outranks a plausible-looking file name"
asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/minieap-0.94.0_x86-64.apk'" >/dev/null 2>&1
assert_file_exists "$asset_dir/minieap-0.94.0.apk" \
  "ac-1 the kept body carries the metadata name and version"
assert_eq "$(ls "$asset_dir" | grep -c 'x86-64' || true)" "0" \
  "ac-1 and never the name it happened to be downloaded as"

# The fast path accepts apk's no-revision shape too, because apk's own metadata may carry none.
assert_eq "$(asset_env "ab_pkgs_asset_split 'x/minieap-0.94.0.apk'")" "minieap 0.94.0" \
  "ac-1 the fast path accepts <name>-<version> with no revision"
assert_eq "$(asset_env "ab_pkgs_asset_split 'x/foo-bar.apk' >/dev/null 2>&1 || printf failed")" "failed" \
  "ac-1 a name with no version at all is still not split into two words"

# --- a file that is not an apk says which kind it is ------------------------
printf '!<arch>\n' >"$tmp/demo.ipk"
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/demo.ipk'; printf 'reason=%s' \"\$AB_PKGS_ASSETS_REASON\"" 2>&1)
assert_contains "$out" "reason=asset-format-ipk" \
  "ac-3 an ipk is refused as an ipk, not as an unnameable package"
printf '#!/bin/sh\necho hi\n' >"$tmp/demo.run"
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/demo.run'; printf 'reason=%s' \"\$AB_PKGS_ASSETS_REASON\"" 2>&1)
assert_contains "$out" "reason=asset-format-run" \
  "ac-3 a .run script is refused as a script"
assert_eq "$(ls "$asset_dir"/*.ipk "$asset_dir"/*.run 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-3 neither is written to the store"

# --- superseded compares versions, it does not just check the name ----------
# The live failure: distfeeds offered only 0.93-r2 while the body was 0.94.0, and the body was
# deleted anyway. A feed that is older cannot replace what the machine runs.
mkroot
mkapk "$tmp/pkg-mini" minieap 0.94.0
cp "$tmp/pkg-mini.apk" "$asset_dir/minieap-0.94.0.apk"
printf 'minieap\n' >"$tmp/feeds-mini"
out=$(APK_FEEDS="$tmp/feeds-mini" APK_FEED_VERSION=0.93-r2 \
  asset_env "ab_pkgs_assets_superseded '$fixture_root'; printf 'superseded=%s' \"\$AB_PKGS_ASSETS_SUPERSEDED\"" 2>&1)
assert_eq "$(ls "$asset_dir"/minieap-0.94.0.apk 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "ac-4 a feed that only knows an older version does not take the body over"
assert_contains "$(cat "$asset_dir/superseded" 2>/dev/null)" "kept name=minieap version=0.94.0 reason=source-older" \
  "ac-4 and the decision to keep it is written down"
assert_eq "$(printf '%s' "$out" | sed -n 's/.*superseded=\(.*\)/\1/p')" "" \
  "ac-4 nothing is reported as superseded when nothing was"
out=$(APK_FEEDS="$tmp/feeds-mini" APK_FEED_VERSION=0.95-r1 \
  asset_env "ab_pkgs_assets_superseded '$fixture_root'; printf 'superseded=%s' \"\$AB_PKGS_ASSETS_SUPERSEDED\"" 2>&1)
assert_contains "$out" "minieap-0.94.0" \
  "ac-4 a feed that knows a newer version does take the body over"
assert_eq "$(ls "$asset_dir"/minieap-*.apk 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "ac-4 and the body is removed"
assert_contains "$(cat "$asset_dir/superseded" 2>/dev/null)" "superseded name=minieap version=0.94.0" \
  "ac-4 the journal still records the supersede, so the deletion is visible"

# --- the declaration is checked, never taken on trust -----------------------
# The stub is the apk on this fixture. A v3 body is identifiable from its info block, so a
# declaration that disagrees with it is refused before the store is touched; a file whose
# identity nothing can answer is refused as unverifiable rather than filed under the guess.
mkroot
mkadb "$tmp/decl.apk" minieap 0.94.0
reset_calls
out=$(cli_env replay --yes --name minieap --version 0.94.0 "$tmp/decl.apk" 2>&1)
assert_contains "$out" "kept minieap-0.94.0 (declared)" \
  "ac-2 a declaration the package confirms keeps the body under the declared name"
assert_contains "$out" "replay name=minieap version=0.94.0 result=ok" \
  "ac-2 and the replay moves the database to the declared version"
assert_file_exists "$asset_dir/minieap-0.94.0.apk" \
  "ac-2 the body is in the store after the confirmed declaration"

# A declaration may spell the revision apk normalised away (`0.94.0-r0` vs `0.94.0`); that is
# the same version to apk, and the store keeps the package's own spelling.
out=$(cli_env replay --yes --name minieap --version 0.94.0-r0 "$tmp/decl.apk" 2>&1)
assert_contains "$out" "kept minieap-0.94.0 (declared)" \
  "ac-2 a declaration with an explicit -r0 matches the metadata's 0.94.0"
assert_file_exists "$asset_dir/minieap-0.94.0.apk" \
  "ac-2 and the store keeps the package's own spelling"

before=$(ls "$asset_dir"/*.apk 2>/dev/null | wc -l | tr -d ' ')
out=$(cli_env replay --yes --name minieap --version 0.9.0 "$tmp/decl.apk" 2>&1)
rc=$?
assert_contains "$out" "refused, reason=asset-name-mismatch" \
  "ac-2 a declaration the package contradicts is refused"
assert_eq "$rc" "74" "ac-2 and the refusal is the before-anything-written code"
assert_eq "$(ls "$asset_dir"/*.apk 2>/dev/null | wc -l | tr -d ' ')" "$before" \
  "ac-2 the store is untouched by the refused declaration"

printf 'ADBd' >"$tmp/blob.bin"
out=$(cli_env replay --yes --name blob --version 1.0 "$tmp/blob.bin" 2>&1)
rc=$?
assert_contains "$out" "refused, reason=asset-name-unverifiable" \
  "ac-2 a declaration nothing can confirm is refused, not filed under a guess"
assert_eq "$rc" "74" "ac-2 and that refusal also writes nothing"

# --- keeping the same body twice is not a failure ---------------------------
# A second `replay <same file>` finds the bytes already in the store. That is "kept", not a
# write that failed: the store copy is what a follow would replay either way.
mkroot
mkadb "$tmp/twice.apk" twice 1.0-r1
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/twice.apk'; printf 'state=%s captured=%s' \"\$AB_PKGS_ASSETS_STATE\" \"\$AB_PKGS_ASSETS_CAPTURED\"")
assert_contains "$out" "state=ok" "ac-1 keeping a body that is already kept still succeeds"
assert_contains "$out" "twice-1.0-r1" "ac-1 and the kept body is reported by the library"
out=$(asset_env "ab_pkgs_assets_capture '$fixture_root' '$tmp/twice.apk'; printf 'state=%s' \"\$AB_PKGS_ASSETS_STATE\"")
assert_contains "$out" "state=ok" "ac-1 the second keep of the same bytes is not a failure"
assert_eq "$(ls "$asset_dir"/twice-*.apk | wc -l | tr -d ' ')" "1" \
  "ac-1 and the store still holds exactly one body for the name"

# --- the kept decision is journalled once, not once per maintenance run ------
# A feed that stays older makes the same decision every time the store is maintained. The
# journal is a record of decisions, not a counter of runs.
mkroot
mkapk "$tmp/pkg-stay" stay 2.0-r1
cp "$tmp/pkg-stay.apk" "$asset_dir/stay-2.0-r1.apk"
printf 'stay\n' >"$tmp/feeds-stay"
for _i in 1 2 3; do
  APK_FEEDS="$tmp/feeds-stay" APK_FEED_VERSION=1.0-r1 \
    asset_env "ab_pkgs_assets_superseded '$fixture_root'" >/dev/null 2>&1
done
assert_eq "$(grep -c 'kept name=stay version=2.0-r1 reason=source-older' "$asset_dir/superseded" 2>/dev/null || true)" "1" \
  "ac-4 the kept decision is written once even when maintenance runs three times"
assert_file_exists "$asset_dir/stay-2.0-r1.apk" \
  "ac-4 and the older feed never takes the body over"

# --- the report -------------------------------------------------------------
assert_matches "$(asset_env "ab_pkgs_assets_report '$fixture_root'")" \
  '^assets=[0-9]+ assets-bytes=[0-9]+ superseded=[0-9]+$' \
  "the store report is one line of facts, and a store that cannot be read is never zero"

finish
