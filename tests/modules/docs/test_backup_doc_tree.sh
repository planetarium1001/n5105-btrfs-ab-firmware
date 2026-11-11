#!/usr/bin/env bash
# Module: docs
# ac-2: the restore decision tree asks "is the target disk at least as large as the
#       original?" first, and each of the four paths A-D carries a copy-pasteable command
#       block, the output to expect, and the condition under which that path is not
#       available. A path without those three is a paragraph, not a procedure.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

en="docs/backup.md"
zh="docs/backup.zh-CN.md"

# section_of <file> <heading pattern>: the body of one `###` section, up to the next one.
section_of() {
  awk -v pat="$2" '
    $0 ~ pat { inside = 1; next }
    inside && /^### / { exit }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# a fenced block with at least one command in it
has_command_block() {
  printf '%s\n' "$1" | awk '
    /^```/ { fence = !fence; next }
    fence && /^[[:space:]]*[a-z#]/ { found = 1 }
    END { exit !found }
  '
}

en_text="$(cat "$en")"
zh_text="$(cat "$zh")"

# --- the first question is the capacity question --------------------------
assert_contains "$en_text" "Q1, always the first question" \
  "ac-2 the tree says which question comes first"
assert_contains "$en_text" "is the target disk at least as large as the original" \
  "ac-2 the first question is the capacity comparison"
assert_contains "$zh_text" "永远先问第一句" "ac-2 中文版同样声明第一问"
assert_contains "$zh_text" "目标盘容量 ≥ 原盘容量" "ac-2 中文版第一问是容量比较"

# --- four paths, each with commands, expectations and a precondition ------
for p in A B C D; do
  body_en="$(section_of "$en" "^### $p\\. ")"
  body_zh="$(section_of "$zh" "^### $p\\. ")"
  assert_contains "$en_text" "### $p. " "ac-2 path $p has its own section"
  assert_contains "$zh_text" "### $p. " "ac-2 路径 $p 有自己的小节"

  if has_command_block "$body_en"; then
    assert_eq "yes" "yes" "ac-2 path $p carries a command block"
  else
    assert_eq "no command block" "yes" "ac-2 path $p carries a command block"
  fi
  if has_command_block "$body_zh"; then
    assert_eq "yes" "yes" "ac-2 路径 $p 带命令块"
  else
    assert_eq "no command block" "yes" "ac-2 路径 $p 带命令块"
  fi

  assert_contains "$body_en" '`Available when:`' "ac-2 path $p says when it is available"
  assert_contains "$body_en" '`Expected:`' "ac-2 path $p says what to expect"
  assert_contains "$body_en" '`Not available when:`' "ac-2 path $p says when it is not available"
  assert_contains "$body_zh" '`可用条件：`' "ac-2 路径 $p 写明可用条件"
  assert_contains "$body_zh" '`期望看到：`' "ac-2 路径 $p 写明期望输出"
  assert_contains "$body_zh" '`不可用时：`' "ac-2 路径 $p 写明不可用条件"
done

# Each command block has to be worth copying: name the tool it runs.
for tool in ab-backup ab-restore; do
  assert_contains "$(section_of "$en" '^### A\. ')" "$tool" "ac-2 path A runs $tool"
  assert_contains "$(section_of "$en" '^### B\. ')" "$tool" "ac-2 path B runs $tool"
done
assert_contains "$en_text" "blockdev --getsz" "ac-2 the capacity question has a command behind it"
assert_contains "$en_text" "partx" "ac-2 reading the original disk names the tool"
assert_contains "$en_text" "losetup" "ac-2 reading an image names the tool"
assert_contains "$zh_text" "blockdev --getsz" "ac-2 中文版同样给出容量判断命令"
assert_contains "$zh_text" "partx" "ac-2 中文版读原盘给出工具"
assert_contains "$zh_text" "losetup" "ac-2 中文版读镜像给出工具"

# --- the smaller disk answer is B, and only B -----------------------------
assert_contains "$en_text" "### B. Any disk, including a smaller one" \
  "ac-2 path B is the one that covers a smaller disk"
assert_contains "$zh_text" "### B. 任意盘，包括更小的盘" "ac-2 中文版把更小的盘放在路径 B"
assert_contains "$en_text" "there is no tool that makes a whole-disk image fit" \
  "ac-2 the doc says no tool makes a whole-disk image fit a smaller disk"
assert_contains "$zh_text" "没有任何工具能让整盘镜像变小装进去" \
  "ac-2 中文版同样说明不存在让小盘容纳整盘镜像的工具"

finish
