#!/bin/bash
# 三模型流水线 · 编排脚本（单线参考实现）。方案见 docs/DESIGN.md。
# 用法（在项目根目录）：
#   Mac:   nohup caffeinate -dims bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
#   Linux: nohup bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
# 停：touch 运行数据/pipeline/停止（不要 pkill 模型进程，会误杀你自己正在用的对话）
# 改了本文件要重启才生效；新进程会按 pid 文件等正在跑的开发模型做完再接手，不会重复开工。
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 必须 UTF-8，否则 sed/bash 按字节切中文会出乱码

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/pipeline"; D="$ROOT/运行数据/pipeline"; L="$D/日志"; M="$ROOT/手册"; E="$ROOT/验收证据"
mkdir -p "$L" "$E"
cd "$ROOT"

# ---------- 可改参数（也可用环境变量覆盖） ----------
CODEX="${CODEX:-codex}"                              # 开发模型 CLI（Codex）。Mac 的 ChatGPT 桌面版自带一份：/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"    # workspace-write（保守）或 danger-full-access（能起浏览器、跑 Git）
CLAUDE="${CLAUDE:-claude}"                           # 验收模型 CLI（Claude Code）
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-5-5}"
MAX_REWORK="${MAX_REWORK:-2}"                        # 返工上限；第 MAX_REWORK+1 次验收由验收员自裁
AUTO_WAIT="${AUTO_WAIT:-600}"                        # 需决定：这么多秒没人答就自动按推荐（只对允许自动的那些）
REMIND="${REMIND:-300}"                              # 第二次提醒的间隔
POLL="${POLL:-30}"                                   # 等人时每隔多少秒看一次决定文件
MANUAL_REVIEW_STAGES="${MANUAL_REVIEW_STAGES:-}"     # 空格分隔；这些子阶段通过后记为「已通过·待 AI 产品经理亲验」
PROJECT_NAME="$(basename "$ROOT")"
export STATE_FILE="$ROOT/项目状态.md"

# ---------- 小工具 ----------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$L/pipeline.log"; }
notify(){ python3 "$P/notify.py" "$1" "$2" >/dev/null 2>&1 || true; }
st(){ python3 "$P/state.py" "$@"; }
stop_requested(){ [ -f "$D/停止" ]; }
manual_file(){ ls "$M" 2>/dev/null | grep "^$1_" | head -1; }
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
drop_last_line(){ local t; t="$(mktemp)"; sed '$d' "$1" > "$t" && mv "$t" "$1"; }

# ---------- 跑模型 ----------
run_codex(){ # $1 子阶段 $2 提示词文件
  local out="$L/$1_dev_$(date +%Y%m%d_%H%M%S).log" pid rc
  log "开发模型开工 $1 -> $out"
  "$CODEX" exec -m "$CODEX_MODEL" -c model_reasoning_effort='"high"' -c approval_policy='"never"' \
    -s "$CODEX_SANDBOX" -C "$ROOT" -o "$D/$1_dev_last.txt" - < "$2" > "$out" 2>&1 &
  pid=$!; echo "$pid" > "$D/dev.pid"
  wait "$pid"; rc=$?; rm -f "$D/dev.pid"
  log "开发模型退出码 $rc"; return $rc
}
run_claude(){ # $1 子阶段 $2 提示词文件
  local out="$L/$1_accept_$(date +%Y%m%d_%H%M%S).log" rc
  log "验收模型开工 $1 -> $out"
  "$CLAUDE" -p --model "$CLAUDE_MODEL" --permission-mode bypassPermissions --output-format text "$(cat "$2")" > "$out" 2>&1
  rc=$?; log "验收模型退出码 $rc"; return $rc
}

# ---------- 通过：改状态、把遗留项追加进下一阶段手册、提交 ----------
pass_stage(){ # $1 子阶段
  local stg="已通过" nx vf="$E/$1/验收结论.md"
  case " $MANUAL_REVIEW_STAGES " in *" $1 "*) stg="已通过·待 AI 产品经理亲验";; esac
  st set "$1" "$stg" >/dev/null; rm -f "$D/rework_$1"
  nx="$(st next "$1")"
  if [ -f "$vf" ] && [ -n "$nx" ] && [ -n "$(manual_file "$nx")" ]; then
    python3 - "$vf" "$M/$(manual_file "$nx")" "$1" <<'PY'
import sys, re, datetime
vf, manual, stage = sys.argv[1:4]
m = re.search(r"^## 遗留到下一阶段\s*\n(.*?)(?=^## |\Z)", open(vf, encoding="utf-8").read(), re.S | re.M)
body = m.group(1).strip() if m else ""
if body:
    with open(manual, "a", encoding="utf-8") as f:
        f.write(f"\n\n## 上一阶段遗留（{stage} 验收，{datetime.date.today()}）\n\n{body}\n")
    print("遗留项已写入", manual)
PY
  fi
  commit_all "pipeline: $1 验收通过"
  log "$1 -> $stg"
}

# ---------- 等人：弹窗（仅 Mac）+ 邮件各两次；允许自动的，10 分钟没人答按推荐办 ----------
ask_dialog(){ # $1 标题 $2 正文 $3 决定文件 $4 弹窗保留秒数。点「按推荐办」就往决定文件追加「按推荐」。没有 osascript（Linux）就跳过。
  command -v osascript >/dev/null 2>&1 || return 0
  ( r="$(osascript - "$1" "$2" "$4" <<'AS' 2>>"$L/dialog.log"
on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"我自己看", "按推荐办"} default button "按推荐办" giving up after (item 3 of argv as integer)
  return button returned of result
end run
AS
)"
    [ "$r" = "按推荐办" ] && [ -f "$3" ] && echo "按推荐" >> "$3" ) &
}
wait_decision(){ # $1 子阶段 $2 原因 $3 推荐（继续 / 通过 / 返工：xxx） $4 允许自动按推荐(1/0)
  local f="$D/等待决定.md" rec="${3:-继续}" auto="${4:-0}" hint last t0 el reminded=0 x
  if [ "$auto" = 1 ]; then hint="$(( AUTO_WAIT / 60 )) 分钟没人回应，流水线会自动按推荐办。"
  else hint="这件事涉及新开付费服务、删数据、改范围或改 .env，流水线会一直等你。"; fi
  printf '子阶段：%s\n原因：%s\n推荐：%s\n%s\n\n在本文件最后一行写你的决定并保存，只能是：按推荐 / 继续 / 通过 / 返工：要改什么\n（下面是分隔线，决定写在它下面）\n----\n' "$1" "$2" "$rec" "$hint" > "$f"
  notify "流水线停了，等你决定（${1}）" "$2"$'\n\n'"推荐：$rec"$'\n'"$hint"$'\n\n'"处理方法（二选一）："$'\n'"1. 在 Mac 弹窗里点「按推荐办」。"$'\n'"2. 打开 ${f}，在最后一行写决定并保存。"
  ask_dialog "${PROJECT_NAME} 流水线停了（${1}）" "$(printf '%s\n\n推荐：%s\n%s' "$(echo "$2" | head -n 8)" "$rec" "$hint")" "$f" "$REMIND"
  log "等待决定：$1 推荐=$rec 自动=$auto 原因=$2"
  t0="$(date +%s)"
  while true; do
    stop_requested && { log "收到停止"; exit 0; }
    last="$(grep -v '^[[:space:]]*$' "$f" | tail -n 1 | tr -d '[:space:]')"
    [ "$last" = "----" ] && last=""
    el=$(( $(date +%s) - t0 ))
    if [ -z "$last" ] && [ "$reminded" = 0 ] && [ "$el" -ge "$REMIND" ]; then
      reminded=1
      notify "再提醒一次：流水线在等你（${1}）" "推荐：$rec"$'\n'"$hint"$'\n\n'"决定文件：$f"
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
      继续) echo 0 > "$D/rework_$1"; rm -f "$f"; return 0;;
      通过) pass_stage "$1"; rm -f "$f"; return 0;;
      返工：*|返工:*) x="${last#返工：}"; echo "${x#返工:}" > "$D/返工单_$1.md"; st set "$1" "返工中" >/dev/null; echo 0 > "$D/rework_$1"; rm -f "$f"; return 0;;
    esac
    sleep "$POLL"
  done
}

# ---------- 一个子阶段走一步（按当前状态分支） ----------
run_stage(){ # $1 子阶段 $2 状态
  local stage="$1" status="$2" name file n k v final vf verdict summary rec auto
  name="$(st name "$stage")"; file="$(manual_file "$stage")"
  [ -n "$file" ] || { wait_decision "$stage" "手册目录 $M 里找不到 ${stage}_*.md，没有手册不能开工" "继续" 0; return; }
  log "当前 $stage $name 状态=$status"
  case "$status" in
    未开始|开发中|返工中)
      if [ "$status" = "返工中" ]; then
        n=$(( $(rework_count "$stage") + 1 )); echo "$n" > "$D/rework_$stage"
        if [ "$n" -gt "$MAX_REWORK" ]; then wait_decision "$stage" "返工已超过 $MAX_REWORK 轮，验收仍未通过。结论见 $E/$stage/验收结论.md" "通过" 1; return; fi
        v="$D/返工单_$stage.md"; [ -f "$v" ] || v="$E/$stage/验收结论.md"
        render "$P/prompts/dev_rework.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$n" VERDICT_FILE="$v" > "$D/${stage}_prompt.md"
      else
        st set "$stage" "开发中" >/dev/null
        render "$P/prompts/dev_start.md" STAGE="$stage" NAME="$name" FILE="$file" > "$D/${stage}_prompt.md"
      fi
      run_codex "$stage" "$D/${stage}_prompt.md" || run_codex "$stage" "$D/${stage}_prompt.md" \
        || { wait_decision "$stage" "开发模型连续两次异常退出，日志在 $L" "继续" 1; return; }
      if [ "$(st status "$stage")" != "待验收" ]; then log "开发模型没把状态改为待验收，流水线代改"; st set "$stage" "待验收" >/dev/null; fi
      rm -f "$D/返工单_$stage.md"
      commit_all "dev: $stage 开发提交（流水线代提交）"
      ;;
    待验收)
      mkdir -p "$E/$stage"
      log "程序检查 checks.sh $stage"
      bash "$P/checks.sh" "$stage" > "$L/${stage}_checks_$(date +%Y%m%d_%H%M%S).log" 2>&1 || log "程序检查未全过，交给验收员判断"
      if [ ! -f "$D/accept_$stage.json" ]; then
        # 结果文件不在 = 流水线自己的故障（不是开发的问题），重跑不会好：第一次自动重试一遍，再出现就停下等人，不要反复骚扰
        n=$(( $(cat "$D/accept_missing_$stage" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/accept_missing_$stage"
        if [ "$n" -le 1 ]; then wait_decision "$stage" "程序检查没有生成 accept_$stage.json，日志在 $L" "继续" 1
        else wait_decision "$stage" "程序检查连续 $n 次没有生成 $D/accept_$stage.json。这是流水线自身故障，重跑不会好，需要人看 $L 里最近的 ${stage}_checks 日志。" "继续" 0; fi
        return
      fi
      rm -f "$D/accept_missing_$stage"
      k=$(( $(rework_count "$stage") + 1 )); final=""
      [ "$k" -gt "$MAX_REWORK" ] && final="（这是最后一次验收）"
      render "$P/prompts/accept.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$k$final" MAX="$(( MAX_REWORK + 1 ))" > "$D/${stage}_accept_prompt.md"
      run_claude "$stage" "$D/${stage}_accept_prompt.md" || run_claude "$stage" "$D/${stage}_accept_prompt.md" \
        || { wait_decision "$stage" "验收模型连续两次异常退出，日志在 $L" "继续" 1; return; }
      vf="$E/$stage/验收结论.md"
      verdict="$(head -n 1 "$vf" 2>/dev/null | tr -d '[:space:]')"
      summary="$(sed -n '/给 AI 产品经理的一句话摘要/,$p' "$vf" 2>/dev/null | sed -n '2,4p')"
      case "$verdict" in
        结论：通过|结论:通过)
          pass_stage "$stage"
          notify "$stage $name 验收通过" "$summary"$'\n\n'"流水线已自动进入下一段，不用你操作。";;
        结论：返工|结论:返工)
          if [ "$k" -gt "$MAX_REWORK" ]; then wait_decision "$stage" "最后一次验收仍判返工。结论见 $vf"$'\n'"$summary" "通过" 1
          else st set "$stage" "返工中" >/dev/null; log "返工 $stage"; notify "$stage $name 判返工（第 $k 次验收）" "$summary"$'\n\n'"开发模型会自动返工，不用你操作。"; fi;;
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

# ---------- 接管：上一次流水线留下的开发模型还在跑，就等它做完 ----------
takeover(){
  local pid; pid="$(cat "$D/dev.pid" 2>/dev/null)"
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || { rm -f "$D/dev.pid"; return 0; }
  log "接管：等正在运行的开发模型（pid ${pid}）做完，不重复开工"
  while kill -0 "$pid" 2>/dev/null; do stop_requested && { log "收到停止"; exit 0; }; sleep 30; done
  rm -f "$D/dev.pid"
}

# ---------- 主循环 ----------
log "流水线启动 ROOT=$ROOT 开发=${CODEX_MODEL}（沙箱 ${CODEX_SANDBOX}） 验收=$CLAUDE_MODEL 返工上限=$MAX_REWORK"
takeover
while true; do
  stop_requested && { log "收到停止"; exit 0; }
  cur="$(st current)"
  if [ "$cur" = "DONE" ]; then
    log "全部子阶段已通过"; notify "流水线全部完成" "所有子阶段已通过，等你做总验。"; exit 0
  fi
  run_stage "${cur%%|*}" "${cur#*|}"
done
