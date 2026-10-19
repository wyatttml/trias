#!/usr/bin/env bash
# Trias 一行接入：在你的项目根目录执行
#   curl -fsSL https://raw.githubusercontent.com/wyatttml/trias/main/install.sh | bash                 # 只装核心
#   curl -fsSL https://raw.githubusercontent.com/wyatttml/trias/main/install.sh | bash -s -- --full     # 再加值守、审稿包、读大文件拦截、两个只读子代理
# 做的事：把 pipeline/ 与模板拷进当前目录；已存在的文件一律跳过，不覆盖；不创建 .env，不改任何已有代码，不改你的 .claude/settings.json。
# 可选环境变量：TRIAS_REF=分支或标签（默认 main）   TRIAS_SRC=本地仓库路径（离线安装 / 自测用）
set -euo pipefail
REPO="wyatttml/trias"; REF="${TRIAS_REF:-main}"; DEST="$(pwd)"
say(){ printf '\033[1;33m⚖\033[0m  %s\n' "$*"; }

FULL=0
for a in "$@"; do case "$a" in --full) FULL=1;; *) echo "不认识的参数：$a（只有 --full）" >&2; exit 1;; esac; done

SRC="${TRIAS_SRC:-}"
if [ -z "$SRC" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  say "下载 $REPO@$REF …"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$TMP"
  SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi
[ -f "$SRC/pipeline/run.sh" ] || { echo "找不到 $SRC/pipeline/run.sh，安装中止" >&2; exit 1; }

copied=0; skipped=0
put(){ # put 源 目标：目标已存在就跳过
  if [ -e "$DEST/$2" ]; then echo "   跳过（已存在）$2"; skipped=$((skipped+1)); return; fi
  mkdir -p "$(dirname "$DEST/$2")"; cp "$SRC/$1" "$DEST/$2"; echo "   新增 $2"; copied=$((copied+1))
}
say "安装到 ${DEST}（$( [ "$FULL" = 1 ] && echo 全套 || echo 核心)）"
for f in run.sh state.py notify.py checks.sh tally.py run_sh_check.py \
         prompts/dev_start.md prompts/dev_rework.md prompts/accept.md prompts/check.md prompts/fix.md; do put "pipeline/$f" "pipeline/$f"; done
chmod +x "$DEST/pipeline/run.sh" "$DEST/pipeline/checks.sh" 2>/dev/null || true
put templates/AGENTS.md AGENTS.md
put templates/CLAUDE.md CLAUDE.md
put templates/项目状态.md 项目状态.md
put templates/停了怎么办.md pipeline/停了怎么办.md
put templates/.env.example .env.example
put "templates/手册_Sn_子阶段名.md" "手册/_模板_Sn_子阶段名.md"

if [ "$FULL" = 1 ]; then
  for f in duty.sh prompts/duty_incident.md prompts/duty_decide.md prompts/review_planner.md prompts/review_reviser.md; do put "pipeline/$f" "pipeline/$f"; done
  chmod +x "$DEST/pipeline/duty.sh" 2>/dev/null || true
  put templates/审稿包模板.md 审稿包模板.md
  put pipeline/hooks/bigread_guard.py .claude/hooks/bigread_guard.py
  put templates/agents/sample-viewer.md .claude/agents/sample-viewer.md
  put templates/agents/log-digger.md .claude/agents/log-digger.md
fi

touch "$DEST/.gitignore"
for line in ".env" "运行数据/"; do grep -qxF "$line" "$DEST/.gitignore" || { echo "$line" >> "$DEST/.gitignore"; echo "   .gitignore 加入 $line"; }; done

echo
say "完成：新增 $copied 个文件，跳过 $skipped 个。接下来："
cat <<'EOF'
   1. cp .env.example .env，填 Gmail 应用专用密码（可选，不填就只写日志）
   2. 让方案模型照 手册/_模板_Sn_子阶段名.md 写 手册/00_总方案.md 与 手册/S1_xxx.md …
   3. 把 项目状态.md 进度表改成你的子阶段
   4. 改 pipeline/checks.sh 里的测试命令，手跑：bash pipeline/checks.sh S1
   5. 启动：nohup bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
   完整说明：https://github.com/wyatttml/trias/blob/main/docs/DESIGN.md
EOF
if [ "$FULL" = 1 ]; then cat <<'EOF'
   全套还要两步：
   6. 值守：nohup bash pipeline/duty.sh >> 运行数据/pipeline/日志/duty.log 2>&1 &
      去睡觉时 echo 睡觉 > 运行数据/pipeline/值守模式，回来改回「日常」
   7. 读大文件拦截：把下面这段并进 .claude/settings.json（安装脚本不改你的设置）
      {"hooks": {"PreToolUse": [{"matcher": "Read|Bash", "hooks": [{"type": "command",
        "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bigread_guard.py"}]}]}}
EOF
fi
