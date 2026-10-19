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

new_project(){ # 在临时目录搭一个假项目；$1 子阶段（默认 "S1 S2 S3"），每段一份手册、一个假冒烟
  local T s stages="${1:-S1 S2 S3}"; T="$(mktemp -d)"
  mkdir -p "$T/手册" "$T/运行数据/pipeline" "$T/scripts"
  cp -R "$REPO/pipeline" "$T/pipeline"; cp "$FAKES/smoke.py" "$T/scripts/smoke.py"
  { echo "# 项目状态"; echo; echo "## 子阶段进度"; echo "| 子阶段 | 状态 | 通过日期 |"; echo "| --- | --- | --- |"
    for s in $stages; do echo "| $s 段 | 未开始 | |"; done; } > "$T/项目状态.md"
  for s in $stages; do
    cp "$REPO/templates/手册_Sn_子阶段名.md" "$T/手册/${s}_段.md"
    printf 'import runpy, sys\nsys.argv = ["smoke.py", "%s"]\nrunpy.run_path("scripts/smoke.py")\n' "$s" > "$T/scripts/smoke_$s.py"
  done
  echo "$T"
}
run_pipeline(){ # $1 项目目录 $2 最长秒数，其余是环境变量
  local T="$1" max="$2"; shift 2
  ( cd "$T" && env PATH="$FAKES:$PATH" CODEX=codex CLAUDE=claude TEST_CMD=true POLL=1 "$@" bash pipeline/run.sh > run.out 2>&1 ) &
  local pid=$! i
  for i in $(seq 1 "$max"); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then touch "$T/运行数据/pipeline/停止"; sleep 2; kill $pid 2>/dev/null; fi
  wait $pid 2>/dev/null
}
plog(){ cat "$1/运行数据/pipeline/日志/pipeline.log" 2>/dev/null; }
jq1(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d, ensure_ascii=False))' "$1" "$2" 2>/dev/null; }   # jq1 文件 a.b.c：取一个值
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
( cd "$T" && printf 'DEMO_API_KEY=sk-test-abcdefghijklmnop\n' > .env && printf 'x = "sk-test-abcdefgh"\n' > leak.py && TEST_CMD=true bash pipeline/checks.sh S1 >/dev/null 2>&1 )
check "secret_hits 大于 0"            "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"numbers\"][\"secret_hits\"]>0 else 1)' '$T/运行数据/pipeline/accept_S1.json'"
check "结果文件不含密钥本身"           "! grep -q 'sk-test' '$T/运行数据/pipeline/accept_S1.json'"
rm -rf "$T"

echo "场景四：一行安装——新增文件、重复安装不覆盖、.gitignore 不重复追加"
T="$(mktemp -d)"
( cd "$T" && printf 'node_modules/\n' > .gitignore && TRIAS_SRC="$REPO" bash "$REPO/install.sh" >/dev/null 2>&1 && echo "我的改动" >> AGENTS.md && TRIAS_SRC="$REPO" bash "$REPO/install.sh" > second.out 2>&1 )
check "流水线脚本与模板都已装好"       "[ -x '$T/pipeline/run.sh' ] && [ -f '$T/pipeline/tally.py' ] && [ -f '$T/项目状态.md' ] && [ -f '$T/pipeline/停了怎么办.md' ]"
check "默认不装可选组件"               "[ ! -e '$T/pipeline/duty.sh' ] && [ ! -e '$T/.claude' ]"
check "第二次安装不覆盖已有文件"        "grep -q '我的改动' '$T/AGENTS.md' && grep -q '新增 0 个文件' '$T/second.out'"
check ".gitignore 各项只出现一次"        "[ \$(grep -cx '.env' '$T/.gitignore') = 1 ] && [ \$(grep -cx '运行数据/' '$T/.gitignore') = 1 ]"
check "不会创建 .env"                   "[ ! -e '$T/.env' ]"
rm -rf "$T"

echo "场景五：返工四级——验收写通过但程序没过 → 改判返工 → 级别 2 出检查单 → 级别 3 验收模型亲修 → 级别 4 一直等人"
T="$(new_project S1)"
run_pipeline "$T" 60 FAKE_SCENARIO=passfirst FAKE_SMOKE=fail
check "验收写了通过，被改判返工"        "plog '$T' | grep -q '改判返工'"
check "级别 2 先出检查单"              "[ -s '$T/验收证据/S1/检查单_第2轮.md' ] && grep -q 'check S1' '$T/codex_calls.txt'"
check "级别 2 的返工提示词用的是检查单"  "grep -q '根子：' '$T/运行数据/pipeline/S1_prompt.md'"
check "级别 3 由验收模型亲修"           "grep -q 'fix S1' '$T/claude_calls.txt' && ls '$T/运行数据/pipeline/日志/' | grep -q '^S1_fix_'"
check "级别 4 停下交方案模型、一直等人"  "grep -q '交方案模型' '$T/运行数据/pipeline/等待决定.md' && grep -q '一直等你' '$T/运行数据/pipeline/等待决定.md'"
check "一直等时不自动按推荐"            "! plog '$T' | grep -q '自动按推荐办'"
check "判返工的通知带调优清单提醒"      "grep -q '要改提示词 / 模板' '$T/运行数据/pipeline/日志/notify.log'"
rm -rf "$T"

echo "场景六：服务故障——冒烟连不上 → 不叫验收模型、不计数 → 自动继续重跑 → 恢复后通过"
T="$(new_project S1)"
run_pipeline "$T" 60 FAKE_SMOKE=outage AUTO_WAIT=2 REMIND=60
check "认出服务故障"                   "plog '$T' | grep -q '服务故障'"
check "故障那轮没叫验收模型"            "[ \$(grep -c 'accept S1' '$T/claude_calls.txt') = 1 ]"
check "冒烟失败没有计入返工次数"        "! grep -q 'smoke:a' '$T/运行数据/pipeline/fail_counts_S1.json' 2>/dev/null"
check "恢复后 S1 通过"                 "grep -q '^| S1 .*| 已通过 |' '$T/项目状态.md'"
rm -rf "$T"

echo "场景七：冒烟偶发——第一次挂、后两次过 → 算过，记 flaky_steps"
T="$(new_project S1)"
run_pipeline "$T" 40 FAKE_SMOKE=flaky
check "冒烟三中取二算过"                "[ \"\$(jq1 '$T/运行数据/pipeline/accept_S1.json' numbers.smoke.flaky_steps)\" = '[\"a\"]' ]"
check "没有返工，一次通过"              "! plog '$T' | grep -q '返工 S1' && grep -q '^| S1 .*| 已通过 |' '$T/项目状态.md'"
rm -rf "$T"

echo "场景八：等手册 + 子段共用手册 + 遗留暂存"
T="$(new_project "S1 S2a S2b")"
rm -f "$T/手册/S2a_段.md" "$T/手册/S2b_段.md"
( sleep 6; printf '# S2 共用手册\n\n## S2a\n要做：甲\n\n## S2b\n要做：乙\n' > "$T/手册/S2_段.md" ) & HLP=$!
run_pipeline "$T" 60 MANUAL_WAIT=1
wait "$HLP"
check "没手册时通知「等手册」"          "titles '$T' | grep -q '^S2a 等手册'"
check "S1 的遗留先暂存"                "grep -q 'S1 留下的小毛病' '$T/运行数据/pipeline/遗留_待并入_S2a.md'"
check "手册写好后自己接着跑，S2a、S2b 都通过" "grep -q '^| S2a .*| 已通过 |' '$T/项目状态.md' && grep -q '^| S2b .*| 已通过 |' '$T/项目状态.md'"
check "S2a 的遗留写进共用手册"          "grep -q 'S2a 留下的小毛病' '$T/手册/S2_段.md'"
rm -rf "$T"

echo "场景九：有值守时，返工先进「返工待定稿」，不发「等你决定」"
T="$(new_project "S1 S2")"
sleep 300 & SLP=$!; echo "$SLP" > "$T/运行数据/pipeline/duty.pid"
( f="$T/运行数据/pipeline/等待决定.md"
  for i in $(seq 1 40); do grep -q '返工待定稿' "$f" 2>/dev/null && break; sleep 1; done
  cp "$f" "$T/gate_snapshot.md" 2>/dev/null; echo "按推荐" >> "$f" ) & HLP=$!
run_pipeline "$T" 60
wait "$HLP" 2>/dev/null; { kill "$SLP"; wait "$SLP"; } 2>/dev/null
check "决定文件写着返工待定稿"           "grep -q '返工待定稿' '$T/gate_snapshot.md'"
check "没有发「等你决定」"              "! titles '$T' | grep -q '等你决定'"
check "按推荐后进返工，S2 最终通过"      "plog '$T' | grep -q '返工 S2' && grep -q '^| S2 .*| 已通过 |' '$T/项目状态.md'"
rm -rf "$T"

echo "场景十：值守假跑——夜里按草稿办、白天到点按草稿办、日志出事起短会话"
duty(){ # $1 项目目录，其余是环境变量
  local T="$1"; shift
  ( cd "$T" && env DUTY_ONCE=1 DUTY_FAKE=1 DUTY_DIALOG=off DUTY_NOTIFY="bash $T/note.sh" "$@" bash pipeline/duty.sh >> duty.out 2>&1 )
}
mk_wait(){ printf '子阶段：S1\n原因：返工待定稿：验收员判返工\n推荐：返工：按验收结论\n\n----\n' > "$1/运行数据/pipeline/等待决定.md"; }
T="$(new_project S1)"; printf 'echo "$1" >> %s/notes.txt\n' "$T" > "$T/note.sh"
echo 睡觉 > "$T/运行数据/pipeline/值守模式"; mk_wait "$T"
duty "$T" DUTY_FAKE_DRAFT='返工：修好 a 步\n理由一句'
check "夜里直接按草稿办"                "[ \"\$(tail -n 1 '$T/运行数据/pipeline/等待决定.md')\" = '返工：修好 a 步' ] && grep -q '^夜里已定' '$T/notes.txt'"
echo 日常 > "$T/运行数据/pipeline/值守模式"; mk_wait "$T"; touch -t 202001010000 "$T/运行数据/pipeline/等待决定.md"
duty "$T" DUTY_FAKE_DRAFT='继续\n理由一句' DUTY_AUTO=0
check "白天先只起草、通知人"             "grep -q '^返工草稿待你看' '$T/notes.txt' && [ \"\$(tail -n 1 '$T/运行数据/pipeline/等待决定.md')\" = '----' ]"
duty "$T" DUTY_AUTO=0
check "白天到点没人回，按草稿办"         "[ \"\$(tail -n 1 '$T/运行数据/pipeline/等待决定.md')\" = '继续' ] && grep -q '^已按草稿办' '$T/notes.txt'"
mkdir -p "$T/运行数据/pipeline/日志"; printf '[x] 正常\nTraceback (most recent call last):\n' > "$T/运行数据/pipeline/日志/pipeline.log"
duty "$T" DUTY_LOG_FROM=0 DUTY_FAKE_DRAFT='已恢复：测试'
check "日志出 Traceback 起出事短会话"    "grep -q '^出事处理结果：已恢复' '$T/notes.txt'"
rm -rf "$T"

echo "场景十一：审稿包假跑——夜里三次串到「已定」；卡住的记失败不重试"
T="$(new_project S1)"; printf 'echo "$1" >> %s/notes.txt\n' "$T" > "$T/note.sh"; echo 睡觉 > "$T/运行数据/pipeline/值守模式"
printf '# 审稿包_甲\n\n状态：待方案模型审第 1 轮\n' > "$T/审稿包_甲.md"
for i in 1 2 3 4; do duty "$T"; done
check "三轮串到「已定」并通知一次"       "grep -q '^状态：已定' '$T/审稿包_甲.md' && [ \$(grep -c '^审稿已定' '$T/notes.txt') = 1 ]"
printf '# 审稿包_乙\n\n状态：待方案模型审第 1 轮\n' > "$T/审稿包_乙.md"
duty "$T" DUTY_FAKE_REVIEW=stuck; duty "$T" DUTY_FAKE_REVIEW=stuck
check "状态没变就记失败、只起一次"       "[ -f '$T/运行数据/pipeline/审稿状态/审稿包_乙.failed' ] && [ \$(cat '$T/运行数据/pipeline/审稿状态/审稿包_乙.count') = 1 ]"
rm -rf "$T"

echo "场景十二：读大文件拦截"
T="$(mktemp -d)"; printf 'x' > "$T/a.png"; printf 'hi' > "$T/s.txt"; head -c 300000 /dev/zero | tr '\0' 'a' > "$T/big.log"
guard(){ python3 "$REPO/pipeline/hooks/bigread_guard.py"; }
check "主对话读图片被拒"                "echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$T/a.png\"}}' | guard | grep -q deny"
check "主对话 cat 大日志被拒"           "echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $T/big.log\"}}' | guard | grep -q deny"
check "小文件放行"                      "[ -z \"\$(echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$T/s.txt\"}}' | guard)\" ]"
check "子代理读图片放行"                "[ -z \"\$(echo '{\"hook_event_name\":\"PreToolUse\",\"agent_id\":\"x\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$T/a.png\"}}' | guard)\" ]"
check "坏输入不卡住（放行）"            "[ -z \"\$(echo 'not json' | guard)\" ]"
rm -rf "$T"

echo "场景十三：改 run.sh 后的检查"
T="$(mktemp -d)"; printf '#!/bin/bash\nset -u\necho "$UNSET_THING"\n' > "$T/bad.sh"
if command -v shellcheck >/dev/null 2>&1; then
  check "本仓库 run.sh 出「可以重启」"    "python3 '$REPO/pipeline/run_sh_check.py' | grep -q '可以重启'"
else
  check "本仓库 run.sh 没有未赋值变量（没装 shellcheck）" "python3 '$REPO/pipeline/run_sh_check.py' | grep -q '未赋值变量: 无'"
fi
check "未赋值变量被抓出来"              "python3 '$REPO/pipeline/run_sh_check.py' '$T/bad.sh' | grep -q 'UNSET_THING'"
rm -rf "$T"

echo "场景十四：一行安装 --full——可选组件都装上，不改用户设置"
T="$(mktemp -d)"
( cd "$T" && TRIAS_SRC="$REPO" bash "$REPO/install.sh" --full > full.out 2>&1 )
check "值守、审稿提示词、审稿包模板装好" "[ -x '$T/pipeline/duty.sh' ] && [ -f '$T/pipeline/prompts/review_planner.md' ] && [ -f '$T/审稿包模板.md' ]"
check "钩子和两个子代理装进 .claude/"    "[ -f '$T/.claude/hooks/bigread_guard.py' ] && [ -f '$T/.claude/agents/sample-viewer.md' ] && [ -f '$T/.claude/agents/log-digger.md' ]"
check "打印 settings 片段、不建 settings.json" "grep -q 'bigread_guard' '$T/full.out' && [ ! -e '$T/.claude/settings.json' ]"
rm -rf "$T"

echo
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit "$fail"
