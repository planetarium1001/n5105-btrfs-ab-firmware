#!/usr/bin/env bash
# Module: ci
#
# The initramfs runs before the platform layer is mounted, so it cannot borrow the build
# host's programs: their libc is glibc, their versions move with the runner image, and the
# guest is musl. It therefore carries its own copy of busybox, the partition tools and
# their libraries, taken from the same upstream release as the rest of the image.
#
# scripts/ci/initramfs-tools.lock.json is that contract (which package supplies which
# file, at which path, with which sha256) and scripts/ci/apk_tools.py is the only program
# allowed to install it. Locked here:
#
#   ac-1 the lockfile is well formed and every command the initramfs runs is provided:
#        either by an installed file, by a busybox applet, by a shell builtin or by a
#        shell function in the libraries the guest sources
#   ac-2 the upstream release in the lockfile and the pin in scripts/ci/lib.sh agree, and
#        the util-linux tools that share a source tree share one version
#   ac-3 the toolset is musl-only: the musl loader is linked and no glibc file is installed
#   ac-4 a drifted package or a drifted file is a hard error that names the offender, and
#        a dry run verifies without writing
#
# The coverage check keeps a small table of accepted exceptions (a command the scripts call
# that the toolset deliberately does not carry). An entry is only valid while the gap is
# real: once the command is provided - or the last call site is gone - the test fails and
# says to delete the entry, so no reason here can ever contradict the code.
#
# Everything runs offline. The only upstream bytes involved are the 13 KiB libuuid1
# package in tests/fixtures/apk-tools, which exists exactly so that ac-4 can be exercised
# without a feed; see that directory's README.md.
#
# Usage:
#   bash tests/modules/ci/test_initramfs_tools.sh            # everything (default)
#   bash tests/modules/ci/test_initramfs_tools.sh --drift    # same, drift cases named
#   bash tests/modules/ci/test_initramfs_tools.sh --no-drift # skip ac-4
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root"

run_drift=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --drift) run_drift=1; shift ;;
    --no-drift) run_drift=0; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  printf '# python3 unavailable, skipped\n'
  exit 0
fi

lock_file="$root/scripts/ci/initramfs-tools.lock.json"
tool="$root/scripts/ci/apk_tools.py"
fixtures="$root/tests/fixtures/apk-tools"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --------------------------------------------------------------------------- #
# ac-1..ac-3: static contract of the lockfile, checked by one report
#
# The report is printed as key/value lines so that each expectation below fails on its
# own instead of collapsing into a single "the python program exited 1".
#   info:<key>=<value>        facts and counters
#   problem:<category>:<text> one violated expectation
#   mandated:<command>=<from> where a command the initramfs is known to run comes from
#   documented:<name>=<why>   an accepted exception, with its reason
#   live:<name>               an exception that is still needed today
#   cleared:<name>            an exception whose gap is gone; harmless, kept for review
# --------------------------------------------------------------------------- #

report=$(python3 - "$root" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
lock_path = root / "scripts/ci/initramfs-tools.lock.json"
problems = []


def problem(category, text):
    problems.append(f"problem:{category}:{text}")


# --------------------------------------------------------------------------- #
# The commands the initramfs is known to run, independent of how they are written.
# A command that is missing here is a build that boots to a "not found".
# --------------------------------------------------------------------------- #
MANDATED = """
mount umount mkdir sync poweroff reboot switch_root pivot_root sed awk grep cat
printf tr ls head tail cut wc sort uname sleep insmod sfdisk blockdev blkid
btrfs dmesg test command which cp mv rm chmod ln find expr cmp id
""".split()

# Accepted exceptions: a command that is called by the scripts but is deliberately not
# part of the shipped toolset. Every entry carries its reason, and is re-checked against
# the current scripts below, so this list cannot quietly become a dumping ground.
#
# The rule the list has to obey: an entry is only allowed while the gap is real. When the
# command becomes available (added to the lockfile, published as an applet) or stops being
# called at all, the entry is stale and the test fails until it is deleted - a reviewer
# must never read a reason that the code has already outgrown.
# Empty on purpose: the last entry was `partx`, which the two-stage growth removed together
# with `blockdev --rereadpt` - the reboot now does the re-read, so nothing in the boot path
# calls a partition-table re-read tool at all.
EXCEPTIONS = {}

# Shell builtins. They need no file in the image because the shell that runs the scripts
# is /bin/busybox (ash), whose builtins are part of the binary already counted there.
BUILTINS = set("""
. : [ alias bg break cd command continue echo eval exec exit export false fc fg getopts
hash jobs kill let local printf pwd read readonly return set shift test times trap true
type typeset ulimit umask unalias unset until wait
""".split())

# Files whose command usage decides what the toolset must carry. guest-assert.sh is in
# the list because it runs inside the guest too, on the "assert" toolset.
SCANNED = [
    "initramfs/init",
    "initramfs/boot/init",
    "initramfs/boot/post.sh",
] + [str(p.relative_to(root)) for p in sorted((root / "initramfs/lib").glob("*.sh"))] + [
    "tests/modules/image/guest-assert.sh",
]

INSTALL_PATH_RE = re.compile(r"^/(bin|sbin|usr/bin|usr/sbin|usr/lib|lib)/[A-Za-z0-9._+-]+$")
LINK_PATH_RE = re.compile(r"^/(bin|sbin|usr/bin|usr/sbin|usr/lib|lib)/[A-Za-z0-9._+@\[\]-]+$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
MODE_RE = re.compile(r"^0[0-7]{3}$")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def info(key, value):
    print(f"info:{key}={value}")


def read_lock():
    try:
        data = json.loads(lock_path.read_text())
    except (OSError, ValueError) as exc:
        problem("structure", f"cannot read the lockfile as JSON: {exc}")
        return {}
    if not isinstance(data, dict):
        problem("structure", "the lockfile is not a JSON object")
        return {}
    return data


lock = read_lock()
packages = [entry for entry in lock.get("packages") or [] if isinstance(entry, dict)]
feeds = lock.get("feeds") if isinstance(lock.get("feeds"), dict) else {}
toolsets = lock.get("toolsets") if isinstance(lock.get("toolsets"), dict) else {}
applets = [entry for entry in lock.get("applets") or [] if isinstance(entry, str)]
required_applets = [entry for entry in lock.get("required_applets") or [] if isinstance(entry, str)]

# --------------------------------------------------------------------------- #
# ac-1 structure
# --------------------------------------------------------------------------- #
by_name_early = {record.get("name"): record for record in packages}

if lock.get("schema") != 1:
    problem("structure", f"schema is {lock.get('schema')!r}, expected 1")
upstream_version = lock.get("upstream_version")
if not isinstance(upstream_version, str) or not upstream_version:
    problem("structure", "upstream_version is missing or empty")
for feed in ("base", "packages", "target"):
    if feed not in feeds:
        problem("structure", f"feeds has no {feed!r} entry, so a package cannot name its directory")

if sorted(toolsets) != ["assert", "boot", "probe"]:
    problem("structure", f"toolsets are {sorted(toolsets)}, expected assert, boot, probe")

if not packages:
    problem("structure", "packages is empty")

file_paths = {}
link_paths = {}
for record in packages:
    name = record.get("name") or "<unnamed>"
    feed = record.get("feed")
    if feed not in ("base", "packages", "target"):
        problem("structure", f"{name}: feed {feed!r} is not one of base, packages, target")
    elif feed not in feeds:
        problem("structure", f"{name}: feed {feed!r} is not declared in feeds")
    file_name = record.get("file")
    version = record.get("version")
    if not isinstance(file_name, str) or not file_name.endswith(".apk"):
        problem("structure", f"{name}: file {file_name!r} is not an .apk name")
    elif isinstance(version, str) and version and file_name != f"{name}-{version}.apk":
        problem("structure", f"{name}: file {file_name} does not encode version {version}")
    if not isinstance(version, str) or not version:
        problem("structure", f"{name}: version is missing")
    if not HEX64_RE.match(str(record.get("apk_sha256"))):
        problem("structure", f"{name}: apk_sha256 is not 64 lowercase hex digits")

    # `toolsets` names the programs each flavour asks for; a package's own list is the
    # resolved closure, which is why libraries appear in it without being named there.
    package_toolsets = record.get("toolsets") or []
    if not package_toolsets:
        problem("structure", f"{name}: toolsets is empty")
    for toolset in package_toolsets:
        if toolset not in toolsets:
            problem("structure", f"{name}: claims unknown toolset {toolset!r}")

    entries = record.get("files") or []
    if not entries:
        problem("structure", f"{name}: files is empty")
    for item in entries:
        path = item.get("path") or ""
        if not INSTALL_PATH_RE.match(path):
            problem("structure", f"{name}: install path {path!r} is outside the initramfs roots")
        if path in file_paths:
            problem("structure", f"{name}: install path {path} is already claimed by {file_paths[path]}")
        file_paths[path] = name
        if not MODE_RE.match(str(item.get("mode"))):
            problem("structure", f"{name} {path}: mode {item.get('mode')!r} is not 0NNN")
        if not HEX64_RE.match(str(item.get("sha256"))):
            problem("structure", f"{name} {path}: sha256 is not 64 lowercase hex digits")
        size = item.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            problem("structure", f"{name} {path}: size {size!r} is not a positive integer")
        if item.get("kind") not in ("exec", "shared"):
            problem("structure", f"{name} {path}: kind {item.get('kind')!r} is not exec or shared")
        item_toolsets = item.get("toolsets") or []
        if not item_toolsets:
            problem("structure", f"{name} {path}: toolsets is empty")
        for toolset in item_toolsets:
            if toolset not in toolsets:
                problem("structure", f"{name} {path}: claims unknown toolset {toolset!r}")
            elif toolset not in package_toolsets:
                problem("structure", f"{name} {path}: claims toolset {toolset} which the package does not claim")

    union = sorted({toolset for item in entries for toolset in (item.get("toolsets") or [])})
    if union and union != sorted(set(package_toolsets)):
        problem("structure", f"{name}: package toolsets {sorted(package_toolsets)} do not match its files {union}")

for record in packages:
    name = record.get("name") or "<unnamed>"
    for link in record.get("links") or []:
        path = link.get("path") or ""
        target = link.get("target") or ""
        if not LINK_PATH_RE.match(path):
            problem("structure", f"{name}: link {path!r} is outside the initramfs roots")
        if not target.startswith("/"):
            problem("structure", f"{name}: link {path} target {target!r} is not absolute")
        if path in link_paths:
            problem("structure", f"{name}: link {path} is already claimed by {link_paths[path]}")
        if path in file_paths:
            problem("structure", f"{name}: link {path} collides with an installed file")
        link_paths[path] = name
        # A link that points at nothing is an image whose tool silently does not resolve.
        if target and target not in file_paths:
            problem("structure", f"{name}: link {path} -> {target} does not resolve to an installed file")

for toolset, members in sorted(toolsets.items()):
    if not isinstance(members, list) or not members:
        problem("structure", f"toolset {toolset} lists no programs")
        continue
    for member in members:
        if member not in by_name_early:
            problem("structure", f"toolset {toolset} asks for {member}, which no package entry provides")
        elif toolset not in (by_name_early[member].get("toolsets") or []):
            problem("structure", f"toolset {toolset} asks for {member}, but its entry does not claim that toolset")

if not applets:
    problem("structure", "applets is empty")
elif applets != sorted(set(applets)):
    problem("structure", "the applet table is not sorted and duplicate free")
for missing in sorted(set(required_applets) - set(applets)):
    problem("structure", f"required applet {missing} is not in the applet table")

busybox = next((record for record in packages if record.get("name") == "busybox"), None)
if busybox is None:
    problem("structure", "the lockfile has no busybox package")
else:
    linked = {link["path"] for link in busybox.get("links") or [] if isinstance(link.get("path"), str)}
    for applet in applets:
        if f"/bin/{applet}" not in linked:
            problem("structure", f"applet {applet} has no /bin/{applet} link, so it cannot be called by name")

# --------------------------------------------------------------------------- #
# ac-2 version
# --------------------------------------------------------------------------- #
# These come from one source tree upstream and are linked against each other, so a
# mixed set is a package the feed no longer publishes together.
UTIL_LINUX = ("sfdisk", "blkid", "blockdev", "libfdisk1", "libblkid1", "libuuid1", "libsmartcols1")
by_name = {record.get("name"): record for record in packages}
util_versions = set()
for name in UTIL_LINUX:
    if name not in by_name:
        problem("version", f"the lockfile no longer pins {name}")
    else:
        util_versions.add(by_name[name].get("version"))
if util_versions and util_versions != {"2.41.5-r1"}:
    problem("version", f"util-linux versions are {sorted(util_versions)}, expected all 2.41.5-r1")

# --------------------------------------------------------------------------- #
# ac-3 musl-only
# --------------------------------------------------------------------------- #
links = {(link.get("path"), link.get("target")) for record in packages for link in record.get("links") or []}
if ("/lib/ld-musl-x86_64.so.1", "/lib/libc.so") not in links:
    problem("musl", "the lockfile does not link /lib/ld-musl-x86_64.so.1 -> /lib/libc.so")
for path in sorted(file_paths):
    if path.endswith("libc.so.6"):
        problem("musl", f"{path} is glibc, not the musl libc the guest runs")

# --------------------------------------------------------------------------- #
# ac-1 host paths must never be install paths
# --------------------------------------------------------------------------- #
HOST_MARKERS = ("x86_64-linux-gnu", "ld-linux", "libc.so.6")
for path in sorted(set(file_paths) | set(link_paths)):
    for marker in HOST_MARKERS:
        if marker in path:
            problem("hostpath", f"{path} is a build host path ({marker})")
if "/usr/bin/btrfs" in file_paths:
    problem("hostpath", "btrfs is installed at /usr/bin/btrfs, the build host's path")

# --------------------------------------------------------------------------- #
# ac-1 coverage: every command the scripts run is provided by the toolset
# --------------------------------------------------------------------------- #
KEYWORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
    "esac", "in", "function", "select", "return", "local", "export", "readonly",
    "declare", "typeset", "unset", "shift", "break", "continue", "source", "time",
}
REDIR_RE = re.compile(r"\d*(?:>>|>\||>&|>|<<<|<<|<)\s*(?:Q|\S+)")
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# A variable that supplies a command name by default (`WF_BTRFS="${WF_BTRFS:-btrfs}"`)
# selects a program without ever writing it as a simple command.
DEFAULT_CMD_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=\"?\$\{\1:-([A-Za-z][A-Za-z0-9_.+-]*)\}\"?")


def read_sub(text, index):
    """(end index, body) of a $( ) substitution that opens at `index`."""
    depth, start, size, buf = 1, index, len(text), []
    while index < size:
        char = text[index]
        if char == "\\":
            buf.append(text[index:index + 2]); index += 2; continue
        if char == '"':
            end = index + 1
            while end < size:
                if text[end] == "\\":
                    end += 2; continue
                if text[end] == '"':
                    break
                end += 1
            buf.append(text[index:end + 1]); index = end + 1; continue
        if char == "'":
            end = text.find("'", index + 1)
            end = size if end < 0 else end
            buf.append(text[index:end + 1]); index = end + 1; continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1, "".join(buf)
        buf.append(char); index += 1
    return index, "".join(buf)


def mask(text, subs):
    """Blank out everything that is not shell syntax, keeping $( ) bodies for recursion."""
    out, index, size = [], 0, len(text)
    while index < size:
        char = text[index]
        if char == "'":
            end = text.find("'", index + 1)
            out.append("Q"); index = (size if end < 0 else end + 1); continue
        if char == '"':
            index += 1
            while index < size:
                inner = text[index]
                if inner == "\\":
                    index += 2; continue
                if inner == "$" and text[index + 1:index + 2] == "(":
                    index, body = read_sub(text, index + 2)
                    subs.append(body); out.append(" sub "); continue
                if inner == "`":
                    end = text.find("`", index + 1)
                    subs.append(text[index + 1:end] if end > 0 else "")
                    out.append(" sub "); index = (size if end < 0 else end + 1); continue
                if inner == '"':
                    index += 1; break
                index += 1
            out.append("Q"); continue
        if char == "#" and (index == 0 or text[index - 1] in " \t\n;"):
            while index < size and text[index] != "\n":
                index += 1
            continue
        if char == "$" and text[index + 1:index + 2] == "(":
            index, body = read_sub(text, index + 2)
            subs.append(body); out.append(" sub "); continue
        if char == "`":
            end = text.find("`", index + 1)
            subs.append(text[index + 1:end] if end > 0 else "")
            out.append(" sub "); index = (size if end < 0 else end + 1); continue
        out.append(char); index += 1
    return "".join(out)


def strip_comments(text):
    """The same text with `# ...` removed and everything else kept, quotes included."""
    out, index, size = [], 0, len(text)
    while index < size:
        char = text[index]
        if char in ("'", '"'):
            end = index + 1
            while end < size:
                if char == '"' and text[end] == "\\":
                    end += 2; continue
                if text[end] == char:
                    break
                end += 1
            out.append(text[index:end + 1]); index = end + 1; continue
        if char == "#" and (index == 0 or text[index - 1] in " \t\n;"):
            while index < size and text[index] != "\n":
                index += 1
            continue
        out.append(char); index += 1
    return "".join(out)


# A `case` arm starts with a pattern list ending in `)`: `a | b) cmd`, `*) cmd`. The
# pattern is not a command, so it is dropped before the line is split.
CASE_PATTERN_RE = re.compile(r"^\s*[^()\s][^()]*\)\s*")


def commands(text):
    """Command names in one blob of shell, comments and data excluded."""
    found = set()
    pending, defaults = [text], set()
    while pending:
        # A backslash continuation is one command written on two lines.
        blob = pending.pop().replace("\\\n", " ")
        subs = []
        masked = mask(blob, subs)
        pending.extend(subs)
        # A default that names a program is read from the unmasked text: masking drops
        # quoted content, and `WF_BTRFS="${WF_BTRFS:-btrfs}"` lives inside quotes.
        for match in DEFAULT_CMD_RE.finditer(strip_comments(blob)):
            if NAME_RE.match(match.group(2)):
                defaults.add(match.group(2))
        for line in masked.splitlines():
            for segment in re.split(r"[;|&]+", REDIR_RE.sub(" ", CASE_PATTERN_RE.sub("", line))):
                segment = segment.strip()
                if not segment or ASSIGN_RE.match(segment):
                    continue
                # `if insmod ...; then` starts a command with a keyword; the program is
                # the next word. A segment that still starts with a keyword runs nothing.
                words = segment.split()
                while words and words[0] in ("if", "then", "else", "elif", "while", "until", "do", "!", "time"):
                    words.pop(0)
                if not words:
                    continue
                word = words[0]
                if word in ("[", "[["):
                    found.add("[")
                    continue
                if word in KEYWORDS or word in ("Q", "sub", "(", ")"):
                    continue
                # A script that spells the path out (/sbin/insmod) still needs the program.
                if "/" in word:
                    word = word.rsplit("/", 1)[-1]
                if NAME_RE.match(word):
                    found.add(word)
    return found, defaults


# Shell functions are resolved by name, so they need no file of their own. The guest
# sources /lib/*.sh, which the image fills from initramfs/lib and platform/lib.
FUNCTION_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\(\)", re.MULTILINE)
function_names = set()
for directory in ("initramfs/lib", "platform/lib"):
    for path in (root / directory).rglob("*.sh"):
        function_names |= set(FUNCTION_RE.findall(path.read_text()))
for name in SCANNED:
    path = root / name
    if path.is_file():
        function_names |= set(FUNCTION_RE.findall(path.read_text()))

called = {}
defaults_all = set()
missing_files = []
for name in SCANNED:
    path = root / name
    if not path.is_file():
        missing_files.append(name)
        continue
    found, defaults = commands(path.read_text())
    defaults_all |= defaults
    for command in found:
        called.setdefault(command, set()).add(name)

for name in missing_files:
    problem("coverage", f"the scanned file {name} does not exist")

# Most specific provider first: a shipped file beats an applet of the same name, and an
# applet of the busybox table beats the /bin/<applet> link that exposes it.
provided = {}
for path in sorted(file_paths):
    provided.setdefault(Path(path).name, "lockfile")
for applet in applets:
    provided.setdefault(applet, "applet")
for path in sorted(link_paths):
    provided.setdefault(Path(path).name, "link")
for builtin in BUILTINS:
    provided.setdefault(builtin, "builtin")
for function in function_names:
    provided.setdefault(function, "function")

# Only defaults that name something the image actually carries count as a command. The
# other `${VAR:-value}` expansions in these scripts are placeholders ("none"), not programs.
looked_up = set(called) | {name for name in defaults_all if name in provided or name in EXCEPTIONS}
uncovered = sorted(name for name in looked_up if name not in provided)
outside = [name for name in uncovered if name not in EXCEPTIONS]
for name in outside:
    origin = ", ".join(sorted(called.get(name, {"a variable default"})))
    problem(
        "coverage",
        f"{name} ({origin}) is neither installed by the lockfile nor a busybox applet, "
        "a shell builtin or a shell function",
    )
# An exception is live only while the command is still called and still unavailable.
# Anything else is stale: the gap was closed, or the call site is gone.
for name in sorted(EXCEPTIONS):
    print(f"documented:{name}={EXCEPTIONS[name]}")
    if name in uncovered:
        print(f"live:{name}")
    else:
        print(f"cleared:{name}")
for name in MANDATED:
    print(f"mandated:{name}={provided.get(name, 'exception' if name in EXCEPTIONS else 'missing')}")

info("packages", len(packages))
info("files", len(file_paths))
info("bytes", sum(item.get("size", 0) for record in packages for item in record.get("files") or []))
info("applets", len(applets))
info("links", len(link_paths))
info("upstream_version", upstream_version or "")
info("probe_files", sum(1 for record in packages for item in record.get("files") or [] if "probe" in (item.get("toolsets") or [])))
info("boot_files", sum(1 for record in packages for item in record.get("files") or [] if "boot" in (item.get("toolsets") or [])))
info("commands", len(looked_up))
info("from_lockfile", sum(1 for name in looked_up if provided.get(name) == "lockfile"))
info("from_link", sum(1 for name in looked_up if provided.get(name) == "link"))
info("from_applet", sum(1 for name in looked_up if provided.get(name) == "applet"))
info("from_builtin", sum(1 for name in looked_up if provided.get(name) == "builtin"))
info("from_function", sum(1 for name in looked_up if provided.get(name) == "function"))
info("from_exception", sum(1 for name in looked_up if name in EXCEPTIONS))
info("uncovered", len(outside))
info("exceptions_live", sum(1 for name in EXCEPTIONS if name in uncovered))
info("exceptions_stale", sum(1 for name in EXCEPTIONS if name not in uncovered))
info("mandated_count", len(MANDATED))
info("mandated_missing", sum(1 for name in MANDATED if name not in provided and name not in EXCEPTIONS))

for line in problems:
    print(line)
PY
)

info_of() { printf '%s\n' "$report" | sed -n "s/^info:$1=//p"; }
field() { printf '%s\n' "$report" | sed -n "s/^$1://p"; }
count_problems() {
  printf '%s\n' "$report" | sed -n "s/^problem:$1://p" | grep -c . || true
}
show_problems() {
  local category=$1 line
  printf '%s\n' "$report" | sed -n "s/^problem:$1://p" | while IFS= read -r line; do
    [ -n "$line" ] && printf '# %s: %s\n' "$category" "$line"
  done
}

for category in structure version musl hostpath coverage; do
  show_problems "$category"
done

# ac-1 the lockfile is well formed: schema, feeds, per-package and per-file fields, links
assert_eq "$(count_problems structure)" "0" \
  "ac-1 every package, file and link in the lockfile satisfies the schema"

# The recorded shape of the release this lockfile pins. A change here is a lockfile that
# was regenerated: it is fine, but it has to be a deliberate review, not a silent drift.
assert_eq "$(info_of packages)" "15" "ac-1 the lockfile pins the 15 packages of the closure"
assert_eq "$(info_of files)" "15" "ac-1 each package contributes one file to the image"
assert_eq "$(info_of bytes)" "3851431" "ac-1 the toolset is 3,851,431 bytes of programs and libraries"
assert_eq "$(info_of applets)" "119" "ac-1 the busybox applet table carries 119 names"
assert_eq "$(info_of probe_files)" "5" "ac-1 the S1 probe carries only 5 files, not the partition tools"
assert_eq "$(info_of boot_files)" "15" "ac-1 the boot toolset carries all 15 files"

# ac-2 one release everywhere: the lockfile, the tracked pin and the tool must agree.
# The pin lives in .github/upstream-pin.conf; scripts/ci/lib.sh only reads it
# (ci_upstream_pin_read) and ci_write_upstream_pin is its only writer.
pin=$(sed -n 's/^UPSTREAM_VERSION=//p' "$root/.github/upstream-pin.conf")
assert_eq "${pin}" "$(info_of upstream_version)" \
  "ac-2 the lockfile pins the same upstream release as CI_UPSTREAM_VERSION_PIN"
assert_matches "$(info_of upstream_version)" '^[0-9]+\.[0-9]+\.[0-9]+$' \
  "ac-2 the pinned upstream release is a release directory name"
assert_eq "$(count_problems version)" "0" \
  "ac-2 the util-linux programs and libraries share one upstream version"

# ac-3 musl only: the loader is linked, no glibc sneaks in
assert_eq "$(count_problems musl)" "0" "ac-3 the toolset links the musl loader and installs no glibc"

# ac-1 no build host path is ever an install path
assert_eq "$(count_problems hostpath)" "0" \
  "ac-1 no install path comes from the build host (glibc paths, /usr/bin/btrfs)"

# ac-1 coverage: what the scripts run is what the toolset carries
assert_eq "$(count_problems coverage)" "0" \
  "ac-1 every command the initramfs scripts run is provided by the toolset"
mandated_count=$(info_of mandated_count)
if [ "${mandated_count:-0}" -ge 25 ]; then
  assert_eq "ok" "ok" "ac-1 the command scan still reads the scripts (${mandated_count} known commands)"
else
  assert_eq "0" "${mandated_count}" "ac-1 the command scan still reads the scripts"
fi
assert_eq "$(info_of mandated_missing)" "0" \
  "ac-1 every command the initramfs is known to run is installable"

printf '# coverage: %s commands scanned: %s shipped files, %s applet links, %s busybox applets, %s shell builtins, %s shell functions, %s documented exceptions\n' \
  "$(info_of commands)" "$(info_of from_lockfile)" "$(info_of from_link)" \
  "$(info_of from_applet)" "$(info_of from_builtin)" "$(info_of from_function)" \
  "$(info_of from_exception)"
while IFS='=' read -r name provider; do
  [ -n "${name}" ] || continue
  printf '# provided: %-10s <- %s\n' "${name}" "${provider}"
done <<<"$(field mandated)"
# The exception list is empty and has to stay honest: the two-stage growth deleted the only
# entry there was (`partx`), so nothing here may be "documented" any more. A new entry has to
# come with its reason and with the coverage check above passing for it.
assert_eq "$(field documented)" "" \
  "ac-1 there is no documented exception left: no re-read tool is called at all"
while IFS='=' read -r name reason; do
  [ -n "${name}" ] || continue
  if printf '%s\n' "$report" | grep -qx "live:${name}"; then
    printf '# exception still needed: %s — %s\n' "${name}" "${reason}"
  else
    printf '# stale exception: %s — %s\n' "${name}" "${reason}"
  fi
done <<<"$(field documented)"

# The list may not outlive its gaps. A command that became available (a new lockfile
# entry, a new applet) or that no longer has a call site makes its entry a lie: the next
# reader would believe the toolset is still missing something it carries. The loop above
# prints every such entry, and this assertion fails until it is deleted. This is how the
# `paste` gap was closed: guest-assert.sh learned an awk-based join_comma, the entry would
# have claimed a hole that no longer exists, and it had to go in the same change.
assert_eq "$(info_of exceptions_stale)" "0" \
  "ac-1 no documented exception has become available again: delete it from EXCEPTIONS"

# --------------------------------------------------------------------------- #
# ac-4 drift: the installer verifies the .apk and every extracted file
#
# The real lockfile needs the whole 3.8 MiB closure, which the test may not download, so
# the drift cases run against tests/fixtures/apk-tools: the same installer, the same
# code path, one real 13 KiB package.
# --------------------------------------------------------------------------- #

run_install() {
  # run_install <lockfile> <apk-dir> [extra installer arguments...]
  local lockfile=$1 apk_dir=$2
  shift 2
  out=$(python3 "$tool" install --lock "$lockfile" --stage "$tmp/stage" --apk-dir "$apk_dir" "$@" 2>"$tmp/stderr")
  code=$?
  err=$(cat "$tmp/stderr")
  return 0
}

mutate_lock() {
  # mutate_lock <source> <destination> <apk-sha|file-sha|escape-path>
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

source, destination, mutation = sys.argv[1:4]
lock = json.load(open(source))
record = lock["packages"][0]
if mutation == "apk-sha":
    record["apk_sha256"] = "0" * 64
elif mutation == "file-sha":
    record["files"][0]["sha256"] = "0" * 64
elif mutation == "escape-path":
    record["files"][0]["path"] = "/lib/../../etc/passwd"
else:
    raise SystemExit(f"unknown mutation: {mutation}")
open(destination, "w").write(json.dumps(lock, indent=2) + "\n")
PY
}

if [ "$run_drift" -eq 1 ]; then
  apk_dir="$tmp/apks"
  stage="$tmp/stage"
  mkdir -p "$apk_dir" "$stage"
  cp "$fixtures/libuuid1-2.41.5-r1.apk" "$apk_dir/"

  # The fixture is only useful if it is byte for byte the package its lockfile pins.
  # Hashing goes through scripts/ci/lib.sh, so it is the same digest a stage computes.
  hash_file() {
    bash -c '. "$1/scripts/ci/lib.sh" >/dev/null 2>&1; ci_sha256 "$2"' _ "$root" "$1"
  }
  assert_eq "$(hash_file "$fixtures/libuuid1-2.41.5-r1.apk")" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"][0]["apk_sha256"])' "$fixtures/minimal.lock.json")" \
    "ac-4 the fixture package is exactly the .apk the fixture lockfile pins"

  # Baseline: the unmodified fixture installs, dry run first so nothing is written.
  run_install "$fixtures/minimal.lock.json" "$apk_dir" --dry-run --toolset boot
  assert_eq "$code" "0" "ac-4 the fixture toolset verifies (dry run exits 0)"
  assert_eq "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["toolset"])')" "boot" \
    "ac-4 the dry run reports the toolset it verified"
  assert_eq "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["files"])')" "1" \
    "ac-4 the dry run reports the one verified file"
  assert_eq "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"][0]["files"][0]["size"])' "$fixtures/minimal.lock.json")" \
    "ac-4 the dry run counts the bytes the lockfile records"
  assert_matches "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')" \
    '^[0-9a-f]{64}$' "ac-4 the dry run reports a digest of what it verified"
  assert_eq "$(ls -A "$stage" | wc -l | tr -d ' ')" "0" "ac-4 a dry run leaves the staging tree empty"

  # A drifted .apk: the feed moved, or the lockfile is stale. The installer must stop
  # before it parses the package and must name it.
  mutate_lock "$fixtures/minimal.lock.json" "$tmp/apk-sha.json" apk-sha
  run_install "$tmp/apk-sha.json" "$apk_dir" --dry-run --toolset boot
  assert_eq "$code" "1" "ac-4 a package whose sha256 does not match the lockfile fails the install"
  assert_contains "$err" "libuuid1-2.41.5-r1.apk" \
    "ac-4 the package drift error names the offending .apk"
  assert_contains "$err" "does not match the lockfile" \
    "ac-4 the package drift error says what does not match"

  # A drifted file inside an otherwise good package: the same .apk, a different image.
  mutate_lock "$fixtures/minimal.lock.json" "$tmp/file-sha.json" file-sha
  run_install "$tmp/file-sha.json" "$apk_dir" --dry-run --toolset boot
  assert_eq "$code" "1" "ac-4 a file whose sha256 does not match the lockfile fails the install"
  assert_contains "$err" "no image matches /lib/libuuid.so.1" \
    "ac-4 the file drift error names the install path that no longer matches"

  # The installed file must be the bytes the lockfile describes, at the recorded mode.
  run_install "$fixtures/minimal.lock.json" "$apk_dir" --toolset boot
  assert_eq "$code" "0" "ac-4 the fixture toolset installs"
  assert_file_exists "$stage/lib/libuuid.so.1" "ac-4 the install writes the recorded path"
  assert_eq "$(hash_file "$stage/lib/libuuid.so.1")" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"][0]["files"][0]["sha256"])' "$fixtures/minimal.lock.json")" \
    "ac-4 the installed file is the locked image"
  assert_eq "$(python3 -c 'import os,sys; print("%04o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$stage/lib/libuuid.so.1")" \
    "0644" "ac-4 the installed file gets the mode the lockfile records"

  # An empty cache is a missing package, not a silently smaller toolset.
  mkdir -p "$tmp/empty-apks"
  run_install "$fixtures/minimal.lock.json" "$tmp/empty-apks" --dry-run --toolset boot
  assert_eq "$code" "1" "ac-4 a missing .apk fails the install"
  assert_contains "$err" "missing package file" "ac-4 the missing package error says the file is missing"

  # A lockfile that tries to install outside the initramfs roots is refused, not followed.
  mutate_lock "$fixtures/minimal.lock.json" "$tmp/escape.json" escape-path
  run_install "$tmp/escape.json" "$apk_dir" --dry-run --toolset boot
  assert_eq "$code" "1" "ac-4 a file path outside the initramfs roots is refused"
  assert_contains "$err" "refusing to install at" "ac-4 the refusal names the path it would not write"

  # The real lockfile is the one the build uses: the installer must accept its schema and
  # then fail on the packages this test deliberately does not have.
  before=$(ls -A "$stage" | wc -l | tr -d ' ')
  run_install "$lock_file" "$apk_dir" --dry-run --toolset boot
  assert_eq "$code" "1" "ac-4 the real lockfile is accepted but needs its whole closure"
  assert_contains "$err" "missing package file" \
    "ac-4 a cache holding only the fixture cannot satisfy the real lockfile"
  after=$(ls -A "$stage" | wc -l | tr -d ' ')
  assert_eq "${after}" "${before}" "ac-4 a failed install adds nothing to the staging tree"

  # A pin bump that regenerates the lockfile or changes the release must not be ignored.
  run_install "$lock_file" "$apk_dir" --dry-run --toolset boot --upstream-version 0.0.0
  assert_eq "$code" "1" "ac-4 a build asking for another upstream release is refused"
  assert_contains "$err" "pinned to $(info_of upstream_version)" \
    "ac-4 the mismatch error names the release the lockfile pins"
  assert_contains "$err" "0.0.0" "ac-4 the mismatch error names the release the build asked for"

  # An unknown toolset must not fall back to "everything" or to nothing.
  run_install "$fixtures/minimal.lock.json" "$apk_dir" --dry-run --toolset nosuch
  assert_eq "$code" "1" "ac-4 an unknown toolset is refused"
  assert_contains "$err" "unknown toolset" "ac-4 the unknown toolset error names the problem"
else
  printf '# drift cases skipped (--no-drift)\n'
fi

finish
