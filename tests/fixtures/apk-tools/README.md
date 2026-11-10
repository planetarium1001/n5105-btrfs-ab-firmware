# apk-tools fixtures

Offline fixtures for `tests/modules/ci/test_initramfs_tools.sh`. They exist so that the
drift cases of `scripts/ci/apk_tools.py install` (a package whose sha256 no longer matches
the lockfile, a file whose sha256 no longer matches) can be exercised **without a feed**.

The build itself never reads this directory: the real contract is
`scripts/ci/initramfs-tools.lock.json`, which pins the whole 3.8 MiB closure of the
initramfs toolsets. A test that needed those bytes would have to download from
`downloads.immortalwrt.org` on every run, which is exactly the dependency the tests are
supposed to avoid.

## `libuuid1-2.41.5-r1.apk`

| Field | Value |
|---|---|
| Package | `libuuid1` |
| Version | `2.41.5-r1` (util-linux, same release as the sfdisk/blkid/blockdev toolchain) |
| Source | <https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/libuuid1-2.41.5-r1.apk> |
| Size | 13,569 bytes |
| sha256 | `a96bfcc3b0342770609dbbcb72719a0ccb65eb80490226843f3c9166293ae909` |

The file is the unmodified upstream package, copied once when the fixture was created. It
is small because the drift check never runs the program: it only hashes the `.apk` and
extracts the one shared object inside it.

## `minimal.lock.json`

A hand-written lockfile (`schema: 1`, `upstream_version: 25.12.2`, the same `feeds`
directories as the real lockfile) that describes **only** that one package, so
`apk_tools.py install --apk-dir <fixture> --dry-run` verifies real bytes in a few
milliseconds. It is not, and must never be treated as, the build lockfile.

| File entry | Value |
|---|---|
| `path` | `/lib/libuuid.so.1` |
| `kind` | `shared` |
| `mode` | `0644` |
| `size` | 28,741 bytes |
| `sha256` | `ca40d6c64da199eba93b8f374f876225a0a283d9f94a6c15ddf56ad2354cde05` |

That sha256 is identical to the `libuuid1` entry in the real lockfile, which is the point:
the fixture exercises the same image the production toolset installs.

## Regenerating

Both digests are verified by the test, so a rewritten fixture fails loudly instead of
silently weakening the drift check. To replace it with another upstream package:

```bash
curl -fsSLO https://downloads.immortalwrt.org/releases/25.12.2/packages/x86_64/base/libuuid1-2.41.5-r1.apk
shasum -a 256 libuuid1-2.41.5-r1.apk          # or: sha256sum
python3 - <<'PY'                              # image path, size and sha256
import sys, pathlib
sys.path.insert(0, "scripts/ci")
import elf_extract
for image in elf_extract.images(elf_extract.inflate_adb(pathlib.Path("libuuid1-2.41.5-r1.apk").read_bytes())):
    print(image["soname"], image["length"], image["sha256"])
PY
```

Then update `minimal.lock.json` (and this table) with the measured values. Do not paste a
value from a log: the whole point is that the number is what the bytes hash to.
