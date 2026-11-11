#!/usr/bin/env bash
# Module: docs
# ac-1: docs/backup.md and docs/backup.zh-CN.md both state the three-product contract,
#       the capacity lower bound of each product, and the mechanism that makes a
#       whole-disk image fail on smaller media - and their section headings line up one
#       to one, so the translation cannot drift away from the contract.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
source "$root/tests/lib/assert.sh"

cd "$root" || exit 1

en="docs/backup.md"
zh="docs/backup.zh-CN.md"

assert_file_exists "$en" "ac-1 the English contract exists"
assert_file_exists "$zh" "ac-1 the Chinese contract exists"

en_text="$(cat "$en")"
zh_text="$(cat "$zh")"

# --- the three products and their lower bounds ----------------------------
for needle in "Install image" "Data package" "Whole-disk image"; do
  assert_contains "$en_text" "$needle" "ac-1 the contract names the product: $needle"
done
for needle in "安装镜像" "data 包" "整盘镜像"; do
  assert_contains "$zh_text" "$needle" "ac-1 中文契约点名产物：$needle"
done

assert_contains "$en_text" "514 MiB" "ac-1 the install image floor is a number, not a feeling"
assert_contains "$zh_text" "514 MiB" "ac-1 中文契约写了安装镜像的下界"

assert_contains "$en_text" "independent of the disk size" \
  "ac-1 the data package is stated to be capacity independent"
assert_contains "$zh_text" "与磁盘容量无关" "ac-1 中文契约写明 data 包与容量无关"

assert_contains "$en_text" "only media at least as large as the original disk" \
  "ac-1 the whole-disk image is bounded below by the original disk"
assert_contains "$zh_text" "只能恢复到不小于原盘的介质" "ac-1 中文契约定下整盘镜像的下界"

# --- the mechanism: it fails while writing, not after booting -------------
for needle in "last_usable_lba" "is_gpt_valid" "0xEE" "no partition nodes"; do
  assert_contains "$en_text" "$needle" "ac-1 the failure mechanism names $needle"
done
for needle in "last_usable_lba" "is_gpt_valid" "0xEE" "一个分区节点都没有"; do
  assert_contains "$zh_text" "$needle" "ac-1 中文契约的机理解释含 $needle"
done
assert_contains "$en_text" "fails while writing" "ac-1 the doc says when, not only what"
assert_contains "$zh_text" "写入阶段就失败" "ac-1 中文契约同样说明失败发生在写入阶段"

# --- sections line up one to one -----------------------------------------
en_sections="$(sed -n 's/^## \([0-9][0-9]*\)\..*/\1/p' "$en" | tr '\n' ' ')"
zh_sections="$(sed -n 's/^## \([0-9][0-9]*\)\..*/\1/p' "$zh" | tr '\n' ' ')"
assert_eq "$zh_sections" "$en_sections" "ac-1 the numbered sections are the same, in the same order"
assert_eq "$(grep -c '^## ' "$zh")" "$(grep -c '^## ' "$en")" \
  "ac-1 the two documents have the same number of sections"
assert_eq "$en_sections" "1 2 3 4 5 " "ac-1 the contract is divided into the five numbered sections"

finish
