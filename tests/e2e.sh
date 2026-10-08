#!/bin/bash
# 端到端自测：用假模型在临时项目里跑完整闭环，不调用任何真实模型、不发邮件。
# 用法：bash tests/e2e.sh        退出码 0 = 全部断言通过
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAKES="$REPO/tests/fakes"
fail=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fail=1; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

new_project(){ # 在临时目录搭一个有 S1–S3 的假项目
  local T; T="$(mktemp -d)"
  mkdir -p "$T/手册" "$T/运行数据/pipeline" "$T/scripts"
  cp -R "$REPO/pipeline" "$T/pipeline"; cp "$REPO/templates/项目状态.md" "$T/项目状态.md"
  for s in S1 S2 S3; do cp "$REPO/templates/手册_Sn_子阶段名.md" "$T/手册/${s}_段.md"; done
  printf 'import json\njson.dump({"status":"PASS"},open("运行数据/smoke_S1.json","w"))\n' > "$T/scripts/smoke_S1.py"
  echo "$T"
}
run_pipeline(){ # $1 项目目录 $2 最长秒数，其余是环境变量
  local T="$1" max="$2"; shift 2
  ( cd "$T" && env PATH="$FAKES:$PATH" CODEX=codex CLAUDE=claude "$@" bash pipeline/run.sh > run.out 2>&1 ) &
  local pid=$! i
  for i in $(seq 1 "$max"); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then touch "$T/运行数据/pipeline/停止"; sleep 2; kill $pid 2>/dev/null; fi
  wait $pid 2>/dev/null
}
titles(){ python3 -c 'import json,sys;[print(json.loads(l)["title"]) for l in open(sys.argv[1],encoding="utf-8")]' "$1/运行数据/pipeline/日志/notify.log" 2>/dev/null; }

echo "场景一：开发 → 程序检查 → 验收 → 返工一轮 → 通过 → 遗留追加 → 亲验标记 → 全部完成"
T="$(new_project)"
run_pipeline "$T" 120 MANUAL_REVIEW_STAGES="S3"
check "S1、S2 记为已通过"            "grep -q '^| S1 .*| 已通过 |' '$T/项目状态.md' && grep -q '^| S2 .*| 已通过 |' '$T/项目状态.md'"
check "S3 记为已通过·待 AI 产品经理亲验"  "grep -q '^| S3 .*| 已通过·待 AI 产品经理亲验 |' '$T/项目状态.md'"
check "执行模型自己交回「待验收」，无需流水线代改" "! grep -q '流水线代改' '$T/运行数据/pipeline/日志/pipeline.log'"
check "S2 被判返工一次并重做"         "grep -q '返工 S2' '$T/运行数据/pipeline/日志/pipeline.log'"
check "返工提示词带着验收结论原文"     "grep -q '结论：返工' '$T/运行数据/pipeline/S2_prompt.md'"
check "S1 的遗留项追加进 S2 手册"     "grep -q 'S1 留下的小毛病' '$T/手册/S2_段.md'"
check "S2 的遗留项追加进 S3 手册"     "grep -q 'S2 留下的小毛病' '$T/手册/S3_段.md'"
check "发出「全部完成」通知"          "titles '$T' | grep -q '流水线全部完成'"
check "没有残留的等待或返工文件"       "! ls '$T/运行数据/pipeline' | grep -qE '等待决定|返工单|rework_|dev.pid'"
rm -rf "$T"

echo "场景二：验收判需决定 → 弹窗 + 邮件 → 再提醒 → 无人回应 → 自动按推荐通过"
T="$(new_project)"
run_pipeline "$T" 60 FAKE_SCENARIO=decide AUTO_WAIT=8 REMIND=3 POLL=1
check "发出「等你决定」通知"          "titles '$T' | grep -q '^流水线停了，等你决定（S1）'"
check "发出「再提醒一次」通知"        "titles '$T' | grep -q '^再提醒一次：流水线在等你（S1）'"
check "发出「已自动按推荐办」通知"    "titles '$T' | grep -q '^已自动按推荐办（S1）'"
check "S1 按推荐判为已通过"           "grep -q '^| S1 .*| 已通过 |' '$T/项目状态.md'"
if command -v osascript >/dev/null 2>&1 || [ -x "$FAKES/osascript" ]; then
  check "弹窗至少弹了首次与再提醒两次" "[ \$(wc -l < '$T/dialog_calls.txt' 2>/dev/null || echo 0) -ge 2 ]"
fi
rm -rf "$T"

echo "场景三：程序检查——密钥泄露会被扫出来，且值不出现在结果里"
T="$(new_project)"
( cd "$T" && printf 'DEMO_API_KEY=sk-test-abcdefghijklmnop\n' > .env && printf 'x = "sk-test-abcdefgh"\n' > leak.py && bash pipeline/checks.sh S1 >/dev/null 2>&1 )
check "secret_hits 大于 0"            "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"numbers\"][\"secret_hits\"]>0 else 1)' '$T/运行数据/pipeline/accept_S1.json'"
check "结果文件不含密钥本身"           "! grep -q 'sk-test' '$T/运行数据/pipeline/accept_S1.json'"
rm -rf "$T"

echo "场景四：一行安装——新增文件、重复安装不覆盖、.gitignore 不重复追加"
T="$(mktemp -d)"
( cd "$T" && printf 'node_modules/\n' > .gitignore && TRIAS_SRC="$REPO" bash "$REPO/install.sh" >/dev/null 2>&1 && echo "我的改动" >> AGENTS.md && TRIAS_SRC="$REPO" bash "$REPO/install.sh" > second.out 2>&1 )
check "流水线脚本与模板都已装好"       "[ -x '$T/pipeline/run.sh' ] && [ -f '$T/项目状态.md' ] && [ -f '$T/pipeline/停了怎么办.md' ]"
check "第二次安装不覆盖已有文件"        "grep -q '我的改动' '$T/AGENTS.md' && grep -q '新增 0 个文件' '$T/second.out'"
check ".gitignore 各项只出现一次"        "[ \$(grep -cx '.env' '$T/.gitignore') = 1 ] && [ \$(grep -cx '运行数据/' '$T/.gitignore') = 1 ]"
check "不会创建 .env"                   "[ ! -e '$T/.env' ]"
rm -rf "$T"

echo
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit "$fail"
