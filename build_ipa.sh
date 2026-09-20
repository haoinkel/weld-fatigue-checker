#!/usr/bin/env bash
# build_ipa.sh — 一键把最新代码推到 GitHub，触发 Actions 构建【未签名 IPA】并下载
#
# 用法：
#   bash build_ipa.sh                 # 使用默认提交信息
#   bash build_ipa.sh "你的提交说明"   # 自定义提交信息
#
# 前置：
#   - 在本仓库根目录运行（Git Bash / WSL / macOS Terminal 均可）
#   - 能访问 github.com（push + API）
#   - git remote "origin" 形如 https://<PAT>@github.com/haoinkel/weld-fatigue-checker.git
#     （脚本自动从 remote 提取 PAT 调用 API，不在文件里写死）
#
# 产物：当前目录下的 WeldFatigueChecker-unsigned.ipa

set -uo pipefail

# ---------- 0. 路径与常量 ----------
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
OWNER_REPO="haoinkel/weld-fatigue-checker"
WF="build_ipa_sideload.yml"
ART="WeldFatigueChecker-unsigned"
API="https://api.github.com/repos/$OWNER_REPO"
MSG="${1:-build: 界面科技感美化 + 缺陷识别增强 (auto)}"

# ---------- 1. 从 git remote 提取 PAT ----------
REMOTE="$(git remote get-url origin 2>/dev/null)"
TOKEN="$(printf '%s' "$REMOTE" | sed -E 's#^https://([^@]+)@.*#\1#')"
if [ -z "$TOKEN" ] || [ "$TOKEN" = "$REMOTE" ]; then
  echo "⚠️ 未能从 git remote 提取 GitHub Token。"
  echo "   请在本脚本上方手动设置： TOKEN=ghp_xxx  或配置 git credential helper / gh auth login。"
  exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"

# 检查 curl 是否可用（下载步骤需要）
if ! command -v curl >/dev/null 2>&1; then
  echo "⚠️ 未找到 curl，无法自动轮询/下载。脚本只完成 push，请到 GitHub Actions 页面手动下载 IPA。"
  AUTO_DL=0
else
  AUTO_DL=1
fi

# ---------- 2. 提交并推送（push 触发 Actions）----------
echo "==> [1/4] 提交本地改动"
git add -A
if git diff --cached --quiet 2>/dev/null; then
  echo "    无新改动，直接进入构建触发。"
else
  git commit -m "$MSG" >/dev/null && echo "    committed: $MSG"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
echo "==> [2/4] 推送到 $BRANCH（触发 Actions: $WF）"
git push origin "$BRANCH"
SHA="$(git rev-parse HEAD 2>/dev/null)"

if [ "$AUTO_DL" -eq 0 ]; then
  echo "✅ 已推送。请打开 https://github.com/$OWNER_REPO/actions 查看构建，"
  echo "   完成后在 Artifacts 下载 $ART.ipa，用 Sideloadly 侧载到 iPad。"
  exit 0
fi

# ---------- 3. 轮询 Actions，等待本次 push 的 run ----------
echo "==> [3/4] 轮询 Actions 运行状态（commit ${SHA:0:8}）..."
RUN_ID=""
for i in $(seq 1 30); do
  RUN_ID="$(curl -s -H "$AUTH" "$API/actions/runs?head_sha=$SHA" \
    | grep -o '"id":[0-9]*,"name":"Build unsigned IPA (Sideloadly)"' \
    | head -1 | grep -o '[0-9]*')"
  [ -n "$RUN_ID" ] && break
  sleep 5
done
if [ -z "$RUN_ID" ]; then
  echo "❌ 未检测到 Actions run。请到 https://github.com/$OWNER_REPO/actions 手动查看/下载。"
  exit 1
fi
echo "    run id = $RUN_ID  (https://github.com/$OWNER_REPO/actions/runs/$RUN_ID)"

ST=""; CONCL=""
for i in $(seq 1 120); do
  BODY="$(curl -s -H "$AUTH" "$API/actions/runs/$RUN_ID")"
  ST="$(printf '%s' "$BODY" | grep -o '"status":"[a-z]*"' | head -1 | sed 's/.*:"//;s/"//')"
  CONCL="$(printf '%s' "$BODY" | grep -o '"conclusion":"[a-z]*"' | head -1 | sed 's/.*:"//;s/"//')"
  printf "    status=%-9s conclusion=%s\r" "$ST" "$CONCL"
  if [ "$ST" = "completed" ]; then
    echo ""
    if [ "$CONCL" = "success" ]; then break; fi
    echo "❌ 构建失败 ($CONCL)。详见 https://github.com/$OWNER_REPO/actions/runs/$RUN_ID"
    exit 1
  fi
  sleep 10
done

# ---------- 4. 下载 artifact IPA ----------
echo "==> [4/4] 下载 artifact: $ART"
DL="$(curl -s -H "$AUTH" "$API/actions/artifacts" \
  | grep -o "\"name\":\"$ART\"[^\}]*\"archive_download_url\":\"[^\"]*\"" \
  | grep -o 'https://[^"]*')"
if [ -z "$DL" ]; then
  echo "❌ 未找到 artifact 下载链接。请到 Actions 页面手动下载。"
  exit 1
fi
ZIP="${ART}.zip"
curl -L -H "$AUTH" -o "$ZIP" "$DL"
echo "    已下载 $ZIP"

# 解压 IPA（git bash 通常自带 unzip）
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIP" -d "${ART}_extract" >/dev/null 2>&1 || true
  IPA="$(find "${ART}_extract" -name '*.ipa' | head -1)"
  if [ -n "$IPA" ]; then
    mv -f "$IPA" "./${ART}.ipa"
    rm -rf "${ART}_extract" "$ZIP"
    echo "✅ 完成：${ART}.ipa 已生成在当前目录。"
    echo "   用 Sideloadly + 免费 Apple ID 侧载到 iPad 即可。"
    exit 0
  fi
fi

echo "✅ 完成：压缩包为 $ZIP（本机无 unzip，请手动解压取得 .ipa）。"
echo "   用 Sideloadly + 免费 Apple ID 侧载到 iPad 即可。"
