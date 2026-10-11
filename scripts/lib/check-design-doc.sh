#!/usr/bin/env bash
# Vendored from hey-yvan/yy-skills@810e967 (design-brainstorm/scripts/check-design-doc.sh, MIT).
# Do not edit here: resync from upstream (scripts/lib/check_harness.py pins the upstream body hash).
# check-design-doc.sh — design-brainstorm 产物（设计文档）的确定性校验
#
# 用法:
#   bash scripts/check-design-doc.sh <design-doc.md> [--handed-off]
#
# 检查类别(与 SKILL.md Verification 对齐):
#   1. 文件名 YYYY-MM-DD-<slug>.md(slug 为 2-6 个小写字母数字词,连字符分隔)
#   2. 首行是一级标题(# ),且存在 **Date:** 行
#   3. 必需节齐全且非空: Context / Discussion / Approach / Architecture
#   4. **Date:** 与文件名日期一致
#   5. 占位符扫描: TBD / TODO / FIXME / XXX(整词)、[Feature Name]、待定 / 待补充 / 待完善
#   6. --handed-off: 额外要求 "## Assumptions & Open Questions" 存在且非空
#   7. WARN(不算失败): 全文超 400 行 → 可能未蒸馏或该拆子项目
#
# 已知限制(确定性 ≠ 全覆盖):
#   - 占位符按整词文本匹配:正文合法引用 "TODO" 一词(如设计一个 TODO 应用)会误报;
#     故意不扫 <slug> / YYYY-MM-DD —— 设计"文件命名规则"类主题时它们是合法正文。
#   - 节名锚点固定英文(## Context 等)且要求整行精确匹配,行尾多余空格或其他语言节名
#     会被判缺节 —— 这是约定,不是 bug。
#   - 空节判定不剔除 HTML 注释(注释行算内容);模板残留靠占位符扫描兜底。
#   - Assumptions 节里"每条带默认倾向"的形态检查不在脚本内(见 references/self-review.md 第 5 项)。
#   - 不校验日期等于系统当天:"落盘当天"是写作纪律(模型侧遵守),校验器必须能在任意日期
#     复跑(CI/回溯审计),只强制文件名与 **Date:** 字段互相一致。
#   - CRLF(Windows)文档先剥 \r 再做内容检查,文件名与占位符规则不受影响。
#
# 退出码: 0 全部通过 / 1 至少一项失败 / 2 参数错误

set -uo pipefail

usage() { echo "用法: bash $0 <design-doc.md> [--handed-off]" >&2; }

DOC=""
HANDED_OFF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --handed-off) HANDED_OFF=1; shift ;;
    -h|--help) usage; exit 2 ;;
    --*) echo "未知选项: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$DOC" ]]; then DOC="$1"; shift
      else echo "多余参数: $1" >&2; usage; exit 2; fi ;;
  esac
done

if [[ -z "$DOC" ]]; then usage; exit 2; fi
if [[ ! -f "$DOC" ]]; then echo "❌ 文件不存在: $DOC" >&2; exit 2; fi

FAIL=0
ok()   { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; FAIL=1; }
warn() { printf '⚠️  %s\n' "$1"; }

BASE=$(basename "$DOC")

# CRLF 归一化:内容检查在剥 \r 的临时副本上做(精确行匹配吃不了 \r),文件名仍看原名
WORK="$DOC"
TMP_WORK=""
if grep -q $'\r' "$DOC"; then
  TMP_WORK=$(mktemp)
  tr -d '\r' < "$DOC" > "$TMP_WORK"
  WORK="$TMP_WORK"
fi
trap '[[ -n "$TMP_WORK" ]] && rm -f "$TMP_WORK"' EXIT

# 1. 文件名格式
FILE_DATE=""
if [[ "$BASE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-[a-z0-9]+(-[a-z0-9]+){1,5}\.md$ ]]; then
  FILE_DATE="${BASH_REMATCH[1]}"
  ok "文件名格式: $BASE"
else
  bad "文件名应为 YYYY-MM-DD-<slug>.md(slug 2-6 个小写词,连字符分隔): $BASE"
fi

# 2a. 首行一级标题
if head -n 1 "$WORK" | grep -qE '^# [^#]'; then
  ok "首行一级标题"
else
  bad "首行应为一级标题(# <Feature Name>)"
fi

# 2b + 4. Date 行存在且与文件名一致
DATE_LINE=$(grep -m1 -E '^\*\*Date:\*\*' "$WORK" || true)
if [[ -n "$DATE_LINE" ]]; then
  DOC_DATE=$(printf '%s\n' "$DATE_LINE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1 || true)
  if [[ -z "$DOC_DATE" ]]; then
    bad "**Date:** 行缺 YYYY-MM-DD 格式日期"
  elif [[ -n "$FILE_DATE" && "$DOC_DATE" != "$FILE_DATE" ]]; then
    bad "**Date:**($DOC_DATE) 与文件名日期($FILE_DATE)不一致"
  else
    ok "**Date:** $DOC_DATE"
  fi
else
  bad "缺 **Date:** 行"
fi

# 3 + 6. 必需节齐全且非空
section_nonempty() {
  awk -v sec="## $1" '
    !insec && $0 == sec { insec = 1; next }
    insec && /^## /     { exit }
    insec && NF > 0     { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$WORK"
}

REQUIRED=(Context Discussion Approach Architecture)
if [[ "$HANDED_OFF" -eq 1 ]]; then
  REQUIRED+=("Assumptions & Open Questions")
fi
for sec in "${REQUIRED[@]}"; do
  if ! grep -qxF "## $sec" "$WORK"; then
    bad "缺必需节: ## $sec"
  elif section_nonempty "$sec"; then
    ok "## $sec 存在且非空"
  else
    bad "## $sec 是空节"
  fi
done

# 5. 占位符扫描(ASCII 整词 + 非整词 token 分两把扫,规避 BSD/GNU grep 词界差异)
PH_HITS=$( { grep -nwE 'TBD|TODO|FIXME|XXX' "$WORK" || true; \
             grep -nE '\[Feature Name\]|待定|待补充|待完善' "$WORK" || true; } | sort -t: -k1,1n -u )
if [[ -n "$PH_HITS" ]]; then
  bad "占位符残留(逐条替换成实内容或默认倾向):"
  printf '%s\n' "$PH_HITS" | sed 's/^/     /'
else
  ok "无占位符残留"
fi

# 7. 长度 WARN
LINES=$(wc -l < "$WORK" | tr -d '[:space:]')
if [[ "$LINES" -gt 400 ]]; then
  warn "全文 $LINES 行(>400): 可能未蒸馏,或该拆子项目(references/design-doc-format.md 长度一节)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ check-design-doc: 全部通过 ($BASE)"
else
  echo "❌ check-design-doc: 存在失败项,按上方 ❌ 逐条修复"
fi
exit "$FAIL"
