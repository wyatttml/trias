#!/bin/bash
# Trias · 编排脚本（单线参考实现）。方案见 docs/DESIGN.md，出了事看 pipeline/停了怎么办.md。
# 用法（在项目根目录）：
#   Mac:   nohup caffeinate -dims bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
#   Linux: nohup bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
# 停：touch 运行数据/pipeline/停止（不要 pkill 模型进程，会误杀你自己正在用的对话）
# 改了本文件要先跑 python3 pipeline/run_sh_check.py，出「可以重启」再重启；新进程会等正在跑的开发模型做完再接手，不重复开工。
# 可选的值守 pipeline/duty.sh 在跑时，返工单先由它起短会话起草；没跑时和单人用法一样，验收结论直接喂回开发模型。
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 必须 UTF-8，否则 sed/bash 按字节切中文会出乱码

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/pipeline"; D="$ROOT/运行数据/pipeline"; L="$D/日志"; M="$ROOT/手册"; E="$ROOT/验收证据"
mkdir -p "$L" "$E"
cd "$ROOT"

# ---------- 可改参数（也可用环境变量覆盖） ----------
CODEX="${CODEX:-codex}"                              # 开发模型 CLI（Codex）
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"    # workspace-write（保守）或 danger-full-access（能起浏览器、跑 Git）；提示词里的权限说明跟着变
CLAUDE="${CLAUDE:-claude}"                           # 验收模型 CLI（Claude Code）
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-5-5}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-high}"               # 验收、亲修一律高强度
MAX_REWORK="${MAX_REWORK:-4}"                        # 返工上限，配合返工四级；用完仍不过就停下等人
AUTO_WAIT="${AUTO_WAIT:-600}"                        # 需决定：这么多秒没人答就自动按推荐（只对允许自动的那些）
REMIND="${REMIND:-300}"                              # 第二次提醒的间隔
POLL="${POLL:-30}"                                   # 等人时每隔多少秒看一次决定文件
MANUAL_WAIT="${MANUAL_WAIT:-300}"                    # 本段还没手册时，每隔多少秒再看一次
MANUAL_REVIEW_STAGES="${MANUAL_REVIEW_STAGES:-}"     # 空格分隔；这些子阶段通过后记为「已通过·待 AI 产品经理亲验」
MANUAL_EXCLUDE="${MANUAL_EXCLUDE:-审稿|审阅|review}"   # 文件名带这些字样的不算手册
QUOTA_PATTERN="${QUOTA_PATTERN:-hit your .*limit|usage limit|limit reached|quota exceeded}"   # 模型额度用完的字样
HELP_LINE="${HELP_LINE:-新建一个 Claude Code 对话，粘贴这句：流水线停了，按 pipeline/停了怎么办.md 处理}"
PROJECT_NAME="$(basename "$ROOT")"
export STATE_FILE="$ROOT/项目状态.md"

# ---------- 小工具 ----------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$L/pipeline.log"; }
notify(){ python3 "$P/notify.py" "$1" "$2" >/dev/null 2>&1 || true; }
st(){ python3 "$P/state.py" "$@"; }
stop_requested(){ [ -f "$D/停止" ]; }
# 脚本因任何错误退出（含 set -u 的「变量未赋值」，它不触发 ERR），先通知再退，不在半夜静默停掉
exit_alarm(){ [ "$1" -ne 0 ] || { rm -f "$D/run.pid"; return 0; }   # 正常退出（停止、全部完成）删掉 run.pid；异常退出留着，值守据此判断「主进程没了」
  notify "流水线异常退出" "退出码 ${1}，最后一条命令：${2}。报错在 运行数据/pipeline/日志/nohup.out 末尾。"$'\n'"$HELP_LINE"; }
trap 'exit_alarm $? "$BASH_COMMAND"' EXIT
manual_file(){ # 先找本段自己的手册（S1a_*.md）；没有再找去掉小写后缀的共用手册（S1_*.md），共用手册里要写到本段名才算
  local f; f="$(ls "$M" 2>/dev/null | grep "^${1}_" | grep -vE "$MANUAL_EXCLUDE" | head -1)"
  if [ -z "$f" ] && [ "${1%[[:lower:]]}" != "$1" ]; then
    f="$(ls "$M" 2>/dev/null | grep "^${1%%[[:lower:]]*}_" | grep -vE "$MANUAL_EXCLUDE" | head -1)"
    [ -n "$f" ] && ! grep -q "$1" "$M/$f" && f=""
  fi
  echo "$f"; }
rework_count(){ cat "$D/rework_$1" 2>/dev/null || echo 0; }
commit_all(){ git rev-parse --git-dir >/dev/null 2>&1 || return 0; git add -A . >/dev/null 2>&1; git commit -q -m "$1" >/dev/null 2>&1 || true; }
render(){ # render 模板 KEY=VALUE ...；VERDICT_FILE=路径 会读文件内容填 {VERDICT}
  python3 - "$@" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if k == "VERDICT_FILE":
        k, v = "VERDICT", open(v, encoding="utf-8").read()
    t = t.replace("{" + k + "}", v)
print(t)
PY
}
jget(){ python3 -c 'import json,sys
try: v = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2])
except Exception: v = None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$1" "$2"; }   # jget 文件 键：读 JSON 顶层一个值
mtime(){ python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1" 2>/dev/null || echo 0; }
tuning_note(){ # $1 验收结论文件：有「## 调优清单」就输出一句提醒（成品质量问题不归开发模型，要人或方案模型改提示词 / 模板）
  local c; c="$(python3 -c 'import re,sys
try: t = open(sys.argv[1], encoding="utf-8").read()
except Exception: t = ""
m = re.search(r"^## 调优清单\s*\n(.*?)(?=^## |\Z)", t, re.S | re.M)
print(len([x for x in (m.group(1) if m else "").splitlines() if x.strip()]))' "$1")"
  [ "${c:-0}" -gt 0 ] && printf '\n\n有 %s 条要改提示词 / 模板，见 %s 的「调优清单」。' "$c" "$1"; }
drop_last_line(){ local t; t="$(mktemp)"; sed '$d' "$1" > "$t" && mv "$t" "$1"; }
duty_alive(){ local p; p="$(cat "$D/duty.pid" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
sandbox_note(){ # $1 dev|accept：按 CODEX_SANDBOX 给提示词里的权限说明
  if [ "$CODEX_SANDBOX" = "workspace-write" ]; then
    case "$1" in
      dev) echo "你跑在工作区沙箱里：起不了浏览器、写不了 Git。沙箱里跑不了的测试或冒烟，在交付说明里写清楚即可，不要反复折腾；流水线会在沙箱外跑一遍，以它为准。";;
      *)   echo "开发模型在沙箱里，跑不了浏览器、Git 这类事；交付说明里这类「环境限制」以流水线在沙箱外跑出的结果为准。";;
    esac
  else
    case "$1" in
      dev) echo "你有完整的本机权限，收尾前要自己把本阶段冒烟真实跑通、相关测试跑绿，不要再把「沙箱跑不了」写进交付说明。权限放开不等于范围放开：只在本目录改东西，不切分支、不合并、不推送。";;
      *)   echo "开发模型有完整本机权限：交付说明里再拿「沙箱限制」解释没验的项，不接受，判返工要求补验。";;
    esac
  fi
}

# ---------- 跑模型 ----------
run_codex(){ # $1 子阶段 $2 提示词文件
  local out="$L/$1_dev_$(date +%Y%m%d_%H%M%S).log" pid rc
  log "开发模型开工 $1 -> $out"
  "$CODEX" exec -m "$CODEX_MODEL" -c model_reasoning_effort="\"$CODEX_EFFORT\"" -c approval_policy='"never"' \
    -s "$CODEX_SANDBOX" -C "$ROOT" -o "$D/$1_dev_last.txt" - < "$2" > "$out" 2>&1 &
  pid=$!; echo "$pid" > "$D/dev.pid"
  wait "$pid"; rc=$?; rm -f "$D/dev.pid"
  log "开发模型退出码 $rc"; return $rc
}
run_claude(){ # $1 子阶段 $2 提示词文件 $3 日志名（accept / fix）
  local out="$L/$1_${3:-accept}_$(date +%Y%m%d_%H%M%S).log" rc
  log "验收模型开工 $1（${3:-accept}） -> $out"
  "$CLAUDE" -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --permission-mode bypassPermissions --output-format text "$(cat "$2")" > "$out" 2>&1
  rc=$?; log "验收模型退出码 $rc"; return $rc
}
after_dev(){ # $1 子阶段：开发（或亲修）收尾后的统一处理
  if [ "$(st status "$1")" != "待验收" ]; then log "开发模型没把状态改为待验收，流水线代改"; st set "$1" "待验收" >/dev/null; fi
  rm -f "$D/返工单_$1.md"
  commit_all "dev: $1 开发提交（流水线代提交）"
}

# ---------- 通过：改状态、把遗留项追加进下一阶段手册、提交 ----------
pass_stage(){ # $1 子阶段
  local stg="已通过" nx nm vf="$E/$1/验收结论.md"
  case " $MANUAL_REVIEW_STAGES " in *" $1 "*) stg="已通过·待 AI 产品经理亲验";; esac
  st set "$1" "$stg" >/dev/null; rm -f "$D/rework_$1"
  # 本段回归成品记为「上一版」，下一段并排对比用；只跑了部分件时按件合并，没跑的件保留上一版那份
  [ -f "$D/regress_$1.json" ] && python3 -c 'import json,os,sys
new, prev = sys.argv[1:3]; d = json.load(open(new, encoding="utf-8"))
old = json.load(open(prev, encoding="utf-8")) if os.path.exists(prev) else {}
d["samples"] = {**(old.get("samples") or {}), **(d.get("samples") or {})}
json.dump(d, open(prev, "w", encoding="utf-8"), ensure_ascii=False, indent=2)' "$D/regress_$1.json" "$D/regress_prev.json"
  nx="$(st next "$1")"
  if [ -f "$vf" ] && [ -n "$nx" ]; then
    nm="$(manual_file "$nx")"
    # 下一段还没有手册：遗留先存 运行数据/pipeline/遗留_待并入_<下一段>.md，写手册的人并进去
    python3 - "$vf" "${nm:+$M/$nm}" "$1" "$D/遗留_待并入_${nx}.md" <<'PY'
import sys, re, datetime
vf, manual, stage, pending = sys.argv[1:5]
m = re.search(r"^## 遗留到下一阶段\s*\n(.*?)(?=^## |\Z)", open(vf, encoding="utf-8").read(), re.S | re.M)
body = m.group(1).strip() if m else ""
if body:
    with open(manual or pending, "a", encoding="utf-8") as f:
        f.write(f"\n\n## 上一阶段遗留（{stage} 验收，{datetime.date.today()}）\n\n{body}\n")
    print("遗留项已写入", manual or pending)
PY
    [ -n "$nm" ] || [ ! -f "$D/遗留_待并入_${nx}.md" ] || notify "$1 的遗留项先存着（${nx} 还没有手册）" "已存到 $D/遗留_待并入_${nx}.md，写 ${nx} 手册时请并进去。"
  fi
  commit_all "pipeline: $1 验收通过"
  log "$1 -> $stg"
}

# ---------- 等人：弹窗（仅 Mac）+ 邮件各两次；允许自动的，10 分钟没人答按推荐办 ----------
ask_dialog(){ # $1 标题 $2 正文 $3 决定文件 $4 弹窗保留秒数。「按推荐办」= 追加「按推荐」；「我自己看」= 追加一行暂停，之后不再自动按推荐
  command -v osascript >/dev/null 2>&1 || return 0
  ( r="$(osascript - "$1" "$2" "$4" <<'AS' 2>>"$L/dialog.log"
on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"我自己看", "按推荐办"} default button "按推荐办" giving up after (item 3 of argv as integer)
  return button returned of result
end run
AS
)"
    [ "$r" = "按推荐办" ] && [ -f "$3" ] && echo "按推荐" >> "$3"
    [ "$r" = "我自己看" ] && [ -f "$3" ] && echo "暂停（点了「我自己看」，不再自动按推荐；看完在下一行写决定）" >> "$3" ) &
}
quota_hit(){ # $1 子阶段：这一段最新的日志里是额度用完，就输出一句说明（额度用完不自动继续，免得一遍遍白跑）
  local lg; lg="$(ls -t "$L/$1_"*.log 2>/dev/null | head -1)"
  [ -n "$lg" ] && grep -qiE "$QUOTA_PATTERN" "$lg" && echo "模型额度用完，日志 ${lg}。额度恢复后在决定文件写「继续」重跑，不会自动继续"
}
wait_fail(){ # $1 子阶段 $2 原因：模型进程异常退出；额度用完就一直等，否则允许自动继续
  local q; q="$(quota_hit "$1")"
  if [ -n "$q" ]; then wait_decision "$1" "$2。$q" "继续" 0; else wait_decision "$1" "$2" "继续" 1; fi
}
wait_decision(){ # $1 子阶段 $2 原因 $3 推荐（继续 / 通过 / 返工：xxx） $4 允许自动按推荐(1/0)
  # 前缀变量：DRAFT_GATE=1 返工待定稿（交值守起草，不通知不弹窗）；KEEP_ROUNDS=1 「继续」不清零返工轮数（服务故障用）
  local f="$D/等待决定.md" rec="${3:-继续}" auto="${4:-0}" gate="${DRAFT_GATE:-}" hint last t0 el reminded=0 x
  if [ -n "$gate" ] && ! duty_alive; then gate=""; log "值守没在跑，返工待定稿改为照常通知"; fi
  if [ "$auto" = 1 ]; then hint="$(( AUTO_WAIT / 60 )) 分钟没人回应，流水线会自动按推荐办。"
  else hint="这件事流水线不能自己定（付费、删数据、改范围、改 .env、返工用完、额度用完之类），会一直等你。"; fi
  printf '子阶段：%s\n原因：%s\n推荐：%s\n%s\n\n在本文件最后一行写你的决定并保存，只能是：按推荐 / 继续 / 通过 / 返工：要改什么\n（下面是分隔线，决定写在它下面）\n----\n' "$1" "$2" "$rec" "$hint" > "$f"
  if [ -z "$gate" ]; then
    notify "流水线停了，等你决定（${1}）" "$2"$'\n\n'"推荐：$rec"$'\n'"$hint"$'\n\n'"处理方法（二选一）："$'\n'"1. 在 Mac 弹窗里点「按推荐办」，或打开 ${f} 在最后一行写决定。"$'\n'"2. $HELP_LINE"
    ask_dialog "${PROJECT_NAME} 流水线停了（${1}）" "$(printf '%s\n\n推荐：%s\n%s' "$(echo "$2" | head -n 8)" "$rec" "$hint")" "$f" "$REMIND"
  fi
  log "等待决定：$1 推荐=$rec 自动=$auto${gate:+ 交值守起草} 原因=$2"
  t0="$(date +%s)"
  while true; do
    stop_requested && { log "收到停止"; exit 0; }
    last="$(grep -v '^[[:space:]]*$' "$f" | tail -n 1 | tr -d '[:space:]')"
    [ "$last" = "----" ] && last=""
    el=$(( $(date +%s) - t0 ))
    if [ -z "$last" ] && [ "$reminded" = 0 ] && [ "$el" -ge "$REMIND" ] && [ -z "$gate" ]; then
      reminded=1
      notify "再提醒一次：流水线在等你（${1}）" "推荐：$rec"$'\n'"$hint"$'\n\n'"决定文件：$f"$'\n'"$HELP_LINE"
      if [ "$auto" = 1 ]; then x="$REMIND"; else x=86400; fi
      ask_dialog "${PROJECT_NAME} 流水线还在等你（${1}）" "$(printf '%s\n\n推荐：%s\n%s' "$(echo "$2" | head -n 6)" "$rec" "$hint")" "$f" "$x"
    fi
    if [ -z "$last" ] && [ "$auto" = 1 ] && [ "$el" -ge "$AUTO_WAIT" ]; then
      last="按推荐"; log "$AUTO_WAIT 秒无人回应，自动按推荐办"
      notify "已自动按推荐办（${1}）" "推荐：$rec"$'\n\n'"你没有回应，流水线已按推荐继续，不用你操作。"
    fi
    if [ "$last" = "按推荐" ]; then
      # 推荐可能带括号说明（「通过（前提是…）」），只取开头的指令词；不可机械执行的不能静默死循环
      x="$(echo "$rec" | tr -d '[:space:]')"
      case "$x" in 通过*) last="通过";; 继续*) last="继续";; 返工：*|返工:*) last="$x";; *) last="";; esac
      if [ -z "$last" ]; then
        log "推荐「${rec}」不是可执行指令，无法按推荐办；请在决定文件里直接写 通过 / 继续 / 返工：…"
        notify "按推荐办失败（${1}）" "推荐写的是「${rec}」，流水线无法机械执行。请打开 $f 直接写 通过 / 继续 / 返工：要改什么"
        drop_last_line "$f"
      else log "按推荐：$last"; fi
    fi
    case "$last" in
      继续) [ -n "${KEEP_ROUNDS:-}" ] || echo 0 > "$D/rework_$1"; rm -f "$f"; return 0;;
      通过) if [ "$(jget "$D/accept_$1.json" passed)" != true ]; then   # 程序结果没过（或没有）不能通过，谁写都不行，接着等
          log "$1 决定写了通过，但 accept_$1.json 的程序结果没过，不能通过，接着等决定"
          notify "决定写了通过，但程序结果没过（${1}）" "测试、冒烟或回归没过，按规矩不能标通过。请在决定文件末尾写「继续」或「返工：要改什么」。"$'\n\n'"想细看：$D/accept_$1.json、$f"
          printf '原因：决定写了「通过」，但程序结果没过，不能通过。请写 继续 / 返工：要改什么\n----\n' >> "$f"; auto=0; rec="继续"; sleep "$POLL"; continue; fi
        pass_stage "$1"; rm -f "$f"; return 0;;
      返工：*|返工:*) x="${last#返工：}"; x="${x#返工:}"
        [ "$x" = "按验收结论" ] || echo "$x" > "$D/返工单_$1.md"
        [ -n "$gate" ] || echo 0 > "$D/rework_$1"   # 返工待定稿那次不清零轮数
        st set "$1" "返工中" >/dev/null; log "返工 $1"; rm -f "$f"; return 0;;
    esac
    sleep "$POLL"
  done
}
wait_manual(){ # $1 子阶段：本段手册还没写好就等着（只通知一次），写好了自己接着跑，不用重启
  local said=0
  until [ -n "$(manual_file "$1")" ]; do
    stop_requested && { log "收到停止"; exit 0; }
    if [ "$said" = 0 ]; then
      said=1; log "$1 还没有手册（${M}/${1}_*.md），等手册再开工"
      notify "$1 等手册" "手册目录里还没有 ${1}_*.md。写好后流水线自己接着跑，不用重启。$( [ -f "$D/遗留_待并入_$1.md" ] && echo "上一段的遗留在 $D/遗留_待并入_$1.md，请并进手册。")"
    fi
    sleep "$MANUAL_WAIT"
  done
}
ledger_wait(){ # $1 子阶段：开工前查一本账（「到期 = 本段开工前」没结的就等）和手册核对（核对后点名文件改动太多就等重核）
  local due ck said=0; RECHECK_NOTE=""; [ -f "$P/ledger_check.py" ] || return 0
  until due="$(python3 "$P/ledger_check.py" --due "$1")"; do
    stop_requested && { log "收到停止"; exit 0; }
    [ "$said" = 1 ] || { said=1; log "$1 开工前账上还有没结的：$(echo "$due" | sed 's/（.*//' | tr '\n' ' ')"
      notify "$1 开工前还有事没做完，流水线在等" "一本账里有 $(echo "$due" | grep -c .) 条写着「$1 开工前」要做完，做完改成「已结」，流水线自己接着跑。"$'\n'"$due"$'\n\n'"想细看：$ROOT/未结待办.md"; }
    sleep "$MANUAL_WAIT"
  done; said=0
  while ck="$(python3 "$P/ledger_check.py" --recheck "$1" "$M/$(manual_file "$1")")"; [ "$(echo "$ck" | head -n 1)" = stop ]; do
    stop_requested && { log "收到停止"; exit 0; }
    [ "$said" = 1 ] || { said=1; log "$1 手册要重核：$(echo "$ck" | sed -n 2p)"
      notify "$1 手册要先重核再开工" "手册核对之后，它点名的代码改了不少。方案模型按现在的代码重核手册、改手册头「核对主干：<提交号>」并提交，流水线自己接着跑。"$'\n\n'"$(echo "$ck" | sed 1d)"; }
    sleep "$MANUAL_WAIT"
  done
  [ "$(echo "$ck" | head -n 1)" = note ] && RECHECK_NOTE="$(echo "$ck" | sed 1d)"; return 0
}

# ---------- 一个子阶段走一步（按当前状态分支） ----------
run_stage(){ # $1 子阶段 $2 状态
  local stage="$1" status="$2" name file n k v lvl cl final vf verdict summary rec auto acc
  name="$(st name "$stage")"
  wait_manual "$stage"; file="$(manual_file "$stage")"
  acc="$D/accept_$stage.json"
  log "当前 $stage $name 状态=$status"
  case "$status" in
    未开始|开发中|返工中)
      if [ "$status" = "返工中" ]; then
        n=$(( $(rework_count "$stage") + 1 )); echo "$n" > "$D/rework_$stage"
        lvl="$(jget "$acc" escalation_level)"; [ "${lvl:-0}" -ge 1 ] 2>/dev/null || lvl=1
        v="$D/返工单_$stage.md"
        # 返工四级：同一项第 4 次真失败转方案模型；方案模型回了「返工：…」就有返工单，照单让开发模型修，不再转
        if { [ "$lvl" -ge 4 ] && [ ! -f "$v" ]; } || [ "$n" -gt "$MAX_REWORK" ]; then
          wait_decision "$stage" "同一项已第 ${lvl} 次真失败（或返工已超过 $MAX_REWORK 轮），按返工四级交方案模型。结论见 $E/$stage/验收结论.md，计数见 $D/fail_counts_$stage.json。方案模型改完手册后写「返工：要改什么」，或判「通过」。" "交方案模型定：改手册后写「返工：…」或写「通过」" 0
          return
        fi
        [ -f "$v" ] || v="$E/$stage/验收结论.md"
        log "返工级别 ${lvl}（第 ${n} 轮）"
        if [ "$lvl" = 3 ]; then   # 第 3 级：验收模型亲自只修这一项，开发模型不再碰
          render "$P/prompts/fix.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$n" VERDICT_FILE="$v" > "$D/${stage}_fix_prompt.md"
          run_claude "$stage" "$D/${stage}_fix_prompt.md" fix || run_claude "$stage" "$D/${stage}_fix_prompt.md" fix \
            || { wait_fail "$stage" "第 3 级亲修的验收模型连续两次异常退出，日志在 $L"; return; }
          after_dev "$stage"; return
        fi
        if [ "$lvl" = 2 ]; then   # 第 2 级：先开一个只读检查会话写检查单，再照单修
          cl="$E/$stage/检查单_第${n}轮.md"
          render "$P/prompts/check.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$n" VERDICT_FILE="$v" > "$D/${stage}_check_prompt.md"
          if run_codex "$stage" "$D/${stage}_check_prompt.md" && [ -s "$cl" ]; then v="$cl"; log "检查单已出：$cl"
          else log "检查会话异常或没写检查单，直接按返工单修"; fi
        fi
        render "$P/prompts/dev_rework.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$n" SANDBOX_NOTE="$(sandbox_note dev)" VERDICT_FILE="$v" > "$D/${stage}_prompt.md"
      else
        [ "$status" = 未开始 ] && ledger_wait "$stage"
        st set "$stage" "开发中" >/dev/null
        render "$P/prompts/dev_start.md" STAGE="$stage" NAME="$name" FILE="$file" SANDBOX_NOTE="$(sandbox_note dev)" > "$D/${stage}_prompt.md"
        [ -n "${RECHECK_NOTE:-}" ] && printf '\n\n## 手册核对之后代码的变化（流水线自动附）\n%s\n\n现状以代码为准，和手册不一致的地方写进「开工核对」。\n' "$RECHECK_NOTE" >> "$D/${stage}_prompt.md"
      fi
      run_codex "$stage" "$D/${stage}_prompt.md" || run_codex "$stage" "$D/${stage}_prompt.md" \
        || { wait_fail "$stage" "开发模型连续两次异常退出，日志在 $L"; return; }
      after_dev "$stage"
      ;;
    待验收)
      mkdir -p "$E/$stage"
      [ -f "$acc" ] && mv -f "$acc" "$D/accept_${stage}_prev.json"   # 上一轮结果挪开：哪一步没写出来时，旧数据不能冒充本轮
      log "程序检查 checks.sh $stage"
      bash "$P/checks.sh" "$stage" > "$L/${stage}_checks_$(date +%Y%m%d_%H%M%S).log" 2>&1 || log "checks.sh 退出码非零，看结果文件"
      if [ ! -f "$acc" ]; then
        # 结果文件不在 = 流水线自己的故障（不是开发的问题），重跑不会好：第一次自动重试一遍，再出现就停下等人
        n=$(( $(cat "$D/accept_missing_$stage" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/accept_missing_$stage"
        if [ "$n" -le 1 ]; then wait_decision "$stage" "程序检查没有生成 accept_$stage.json，日志在 $L" "继续" 1
        else wait_decision "$stage" "程序检查连续 $n 次没有生成 ${acc}。这是流水线自身故障，重跑不会好，需要人看 $L 里最近的 ${stage}_checks 日志。" "继续" 0; fi
        return
      fi
      rm -f "$D/accept_missing_$stage"
      log "计数定级：$(python3 "$P/tally.py" finish "$stage" 2>&1 | tail -n 1)"
      if [ "$(jget "$acc" service_outage)" = true ]; then   # 服务故障不算返工：不叫验收模型、不占轮次，恢复后原样重跑
        KEEP_ROUNDS=1 wait_decision "$stage" "程序检查碰上服务故障（超时、429、5xx、连不上之类），不算返工轮次。等服务恢复后原样重跑。结果见 $acc" "继续" 1
        return
      fi
      k=$(( $(rework_count "$stage") + 1 )); final=""
      [ "$k" -gt "$MAX_REWORK" ] && final="（这是最后一次验收）"
      render "$P/prompts/accept.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$k$final" MAX="$(( MAX_REWORK + 1 ))" SANDBOX_NOTE="$(sandbox_note accept)" > "$D/${stage}_accept_prompt.md"
      run_claude "$stage" "$D/${stage}_accept_prompt.md" || run_claude "$stage" "$D/${stage}_accept_prompt.md" \
        || { wait_fail "$stage" "验收模型连续两次异常退出，日志在 $L"; return; }
      vf="$E/$stage/验收结论.md"
      verdict="$(head -n 1 "$vf" 2>/dev/null | tr -d '[:space:]')"
      summary="$(sed -n '/给 AI 产品经理的一句话摘要/,$p' "$vf" 2>/dev/null | sed -n '2,4p')"
      case "$verdict" in
        结论：通过|结论:通过)
          if [ "$(jget "$acc" passed)" != true ]; then   # 程序结果没过就不能通过：验收员写了「通过」也改判返工
            log "验收员判通过，但 accept_$stage.json 的程序结果没过，改判返工"
            if [ "$k" -gt "$MAX_REWORK" ]; then
              wait_decision "$stage" "验收员判通过，但程序结果没过（见 ${acc}），且返工轮数已用完。程序结果没过不能判通过，需要人看。" "继续" 0
            else
              printf '验收员判了通过，但流水线跑出的程序结果没过，按规矩不能通过。请看 运行数据/pipeline/accept_%s.json 的 failed_items，修到全过。\n' "$stage" > "$D/返工单_$stage.md"
              st set "$stage" "返工中" >/dev/null
            fi
            return
          fi
          pass_stage "$stage"
          notify "$stage $name 验收通过" "$summary"$'\n\n'"流水线已自动进入下一段，不用你操作。$(tuning_note "$vf")";;
        结论：返工|结论:返工)
          if [ "$k" -gt "$MAX_REWORK" ]; then
            wait_decision "$stage" "最后一次验收仍判返工。结论见 $vf"$'\n'"$summary" "继续" 0
          elif duty_alive; then   # 有值守：返工单先由值守起短会话起草（白天给人看 10 分钟，夜里直接办）
            DRAFT_GATE=1 wait_decision "$stage" "返工待定稿：验收员判返工（第 $k 次验收）。结论见 $vf"$'\n'"$summary$(tuning_note "$vf")" "返工：按验收结论" 0
          else
            st set "$stage" "返工中" >/dev/null; log "返工 $stage"
            notify "$stage $name 判返工（第 $k 次验收）" "$summary"$'\n\n'"开发模型会自动返工，不用你操作。$(tuning_note "$vf")"
          fi;;
        结论：需决定|结论:需决定)
          rec="$(python3 -c 'import re,sys; m=re.findall(r"^推荐决定[：:]\s*(.+)$", open(sys.argv[1], encoding="utf-8").read(), re.M); print(m[-1].strip() if m else "")' "$vf")"
          auto="$(python3 -c 'import re,sys; m=re.findall(r"^可自动按推荐[：:]\s*(.+)$", open(sys.argv[1], encoding="utf-8").read(), re.M); print("1" if m and m[-1].strip().startswith("是") else "0")' "$vf")"
          wait_decision "$stage" "验收员需要你决定。结论见 $vf"$'\n'"$summary" "${rec:-继续}" "$auto";;
        *) wait_decision "$stage" "验收结论文件缺失或第一行格式不对：$vf" "继续" 1;;
      esac
      ;;
    *) wait_decision "$stage" "进度表里出现未知状态「${status}」" "继续" 0;;
  esac
}

# ---------- 接管：上一次流水线留下的开发模型还在跑，就等它做完；做完了看有没有正常收尾 ----------
takeover(){
  local pid taken cur stage
  pid="$(cat "$D/dev.pid" 2>/dev/null)"
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || { rm -f "$D/dev.pid"; return 0; }
  taken="$(date +%s)"; log "接管：等正在运行的开发模型（pid ${pid}）做完，不重复开工"
  while kill -0 "$pid" 2>/dev/null; do stop_requested && { log "收到停止"; exit 0; }; sleep "$POLL"; done
  rm -f "$D/dev.pid"
  cur="$(st current)"; stage="${cur%%|*}"
  if [ "$cur" != DONE ] && [ -f "$D/${stage}_dev_last.txt" ] && [ "$(mtime "$D/${stage}_dev_last.txt")" -ge "$taken" ]; then
    log "接管的开发模型已完成 $stage"; after_dev "$stage"
  else
    log "接管的开发模型没有正常收尾，按当前状态重新开工"
  fi
}

# ---------- 主循环 ----------
echo $$ > "$D/run.pid"
log "流水线启动 ROOT=$ROOT 开发=${CODEX_MODEL}（沙箱 ${CODEX_SANDBOX}） 验收=$CLAUDE_MODEL 返工上限=$MAX_REWORK$(duty_alive && echo ' 值守在跑')"
takeover
while true; do
  stop_requested && { log "收到停止"; exit 0; }
  cur="$(st current)"
  if [ "$cur" = "DONE" ]; then
    log "全部子阶段已通过"; notify "流水线全部完成" "所有子阶段已通过，等你做总验。"; exit 0
  fi
  run_stage "${cur%%|*}" "${cur#*|}"
done
