#!/bin/bash
# Trias · 值守（可选组件）。常驻后台、本身不用 AI、不挂任何会话；不装它，run.sh 照样跑。每分钟看四件事：
#  一、出事：日志里出现「失败 / 卡住 / 退出码非 0（143 除外）」或 Traceback；或 run.pid 指向的主进程没了、又没有「停止」文件，连续 3 分钟
#     → 通知 AI 产品经理，同时起一个验收模型短会话（prompts/duty_incident.md）照「停了怎么办」查原因、能恢复就恢复，结果再通知。
#  二、判返工（决定文件带「返工待定稿」）：按 accept_<段>.json 的 escalation_level 起短会话起草返工单（prompts/duty_decide.md），
#     级别 1 → 验收模型，级别 2 起 → 方案模型。
#     白天：通知 + 弹窗（按草稿办 / 我自己看）；DUTY_AUTO 秒（默认 10 分钟）没回就按草稿办；点「我自己看」就一直等人。
#     夜里（运行数据/pipeline/值守模式 = 睡觉）：直接按草稿办，并通知。
#  三、其他「一直等」的决定（付费、删数据、改范围、改 .env、返工用完、额度用完）：白天由 run.sh 自己等人，这里不管；
#     夜里起方案模型短会话起草，能定的直接办并通知；涉及付费、删数据、改范围、改 .env 的留给人并通知。
#  短会话写不出可用的决定、或白天要先改手册时，不自动办，通知人。验收模型起草时说要先改手册，夜里自动转方案模型再起草一次。
#  四、审稿包（只在夜里）：项目根下 审稿包_*.md 前 10 行的「状态：…」驱动两轮审稿，
#     待方案模型审第 1 轮 → 方案模型 → 待验收模型处理第 1 轮 → 验收模型 → 待方案模型审第 2 轮 → 方案模型 → 已定。
#     前 10 行有「开发模型审：要」的包：方案模型第 1 轮之前先起一次开发模型只读同题审（prompts/review_dev.md，写 开发模型审稿_<主题>.md），
#     它不进状态机，没出结果不等不挡，下一轮照起方案模型。
#     别的状态字样一律不碰。每个状态只起一次、每包最多 4 次（含开发模型那次）；跑完状态没按预期变就记失败、通知、此包不再碰。
#     已定时通知第一句是回复文件最后一条「敲定：」，并自动记进一本账「落地 <包名> 的敲定结论」（归验收模型，到期明天）。
#  五、每轮：ledger_check.py --report 写 账检查.json；status_snapshot.py 重算 现状.md / 看板.html，并发早上摘要、进度邮件、卡住提醒、每日本地提交。
#     这两个文件不在就跳过，值守照常跑。
#  通知分三档（notify.py）：即时 = 弹窗 + 邮件；摘要 = 只进事件流，早上摘要里列。标题就是结论，正文第一句是人话，路径放末尾「想细看」。
#  记录：运行数据/pipeline/值守记录.md（同时是事件流）；短会话日志：运行数据/pipeline/日志/duty_*.log。
# 启动（在项目根；已在跑会自己退出）：nohup bash pipeline/duty.sh >> 运行数据/pipeline/日志/duty.log 2>&1 &
# 去睡觉：echo 睡觉 > 运行数据/pipeline/值守模式；回来：echo 日常 > 运行数据/pipeline/值守模式。只改这一个文件。
# 可配：DUTY_CLAUDE（claude 程序，默认同 run.sh 的 CLAUDE）、DUTY_LEAD_MODEL（验收模型）、DUTY_PLAN_MODEL（方案模型）、
#       DUTY_CODEX / DUTY_CODEX_MODEL（开发模型只读审稿用，默认同 run.sh 的 CODEX / CODEX_MODEL）、
#       DUTY_INCIDENT_PATTERN / DUTY_EXCL（日志里算出事 / 不算出事的字样）、DUTY_REVIEW_DIR（审稿包所在目录，默认项目根）。
# 测试用：DUTY_D（运行数据目录）、DUTY_ONCE=1（只扫一轮）、DUTY_FAKE=1（不调模型，草稿取 DUTY_FAKE_DRAFT；快照不发信、不提交）、
#        DUTY_NOTIFY（通知命令，收到「标题」「正文」，级别在环境变量 NOTIFY_LEVEL）、DUTY_LEDGER（入账用的账文件）、
#        DUTY_DIALOG=off（不弹带按钮的窗口）、DUTY_AUTO（白天自动按草稿的秒数）、DUTY_SLEEP（每轮间隔秒数）、
#        DUTY_FAKE_REVIEW（假跑时审稿短会话：advance=把状态改成下一步，默认；stuck=不改）、DUTY_LOG_FROM（从日志第几行后开始看，默认启动时的末尾）
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
shopt -s nullglob
P="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$P/.." && pwd)"
PROJECT_NAME="$(basename "$ROOT")"
D="${DUTY_D:-$ROOT/运行数据/pipeline}"
L="$D/日志/pipeline.log"
REC="$D/值守记录.md"
ST="$D/值守状态"
AUTO="${DUTY_AUTO:-600}"
CL="${DUTY_CLAUDE:-${CLAUDE:-claude}}"
LEAD="${DUTY_LEAD_MODEL:-claude-opus-5-5}"
PLAN="${DUTY_PLAN_MODEL:-claude-fable-5-1}"
CX="${DUTY_CODEX:-${CODEX:-codex}}"
CX_MODEL="${DUTY_CODEX_MODEL:-${CODEX_MODEL:-gpt-6-astra}}"
HIT="${DUTY_INCIDENT_PATTERN:-失败|卡住|退出码 [1-9]}"
EXCL="${DUTY_EXCL:-等待决定：|退出码 143( |$)}"
mkdir -p "$ST" "$D/日志"

PIDF="$D/duty.pid"
if [ -z "${DUTY_ONCE:-}" ]; then
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then echo "值守已在跑（pid $(cat "$PIDF")），不重复起"; exit 0; fi
  echo $$ > "$PIDF"
fi

now(){ date +%s; }
stamp(){ date '+%m-%d %H:%M'; }
mtime(){ python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1" 2>/dev/null || echo 0; }
say(){ # $1 级别（即时 / 摘要） $2 标题 $3 正文；$4=nopopup 时即时档也不弹「知道了」窗口（调用方自己弹带按钮的窗口）
  local np=0; [ "${4:-}" = nopopup ] && np=1
  if [ -n "${DUTY_NOTIFY:-}" ]; then NOTIFY_LEVEL="$1" ${DUTY_NOTIFY:-} "$2" "$3"; return; fi
  NOTIFY_LEVEL="$1" NOTIFY_SOURCE=duty.sh NOTIFY_NO_POPUP="$np" python3 "$P/notify.py" "$2" "$3" >/dev/null 2>&1 || true
}
snap(){ [ -f "$P/status_snapshot.py" ] && SNAP_D="$D" python3 "$P/status_snapshot.py" "$@" 2>/dev/null; }   # --where / --where-short / --check-sentence 句子
first_of(){ printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -n 1 | sed 's/^[[:space:]]*//'; }
ledger_add(){ # 事 出处 归谁 到期 → 记进一本账
  [ -f "$P/ledger_check.py" ] || return 0
  LEDGER_FILE="${DUTY_LEDGER:-}" python3 "$P/ledger_check.py" --add "$@" >/dev/null 2>&1 || record "入账失败｜$1"
}
tomorrow(){ python3 -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=1))'; }
record(){ echo "$(stamp)｜$*" >> "$REC"; }
last_line(){ grep -v '^[[:space:]]*$' "$1" | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
mode(){ [ "$(tr -d '[:space:]' < "$D/值守模式" 2>/dev/null)" = "睡觉" ] && echo 睡觉 || echo 日常; }
render(){ # $1 模板；其余是 键=值，替换 {键}
  python3 -c '
import sys
t=open(sys.argv[1],encoding="utf-8").read()
for kv in sys.argv[2:]:
    k,v=kv.split("=",1); t=t.replace("{"+k+"}",v)
print(t)' "$@"
}
short(){ # $1 lead|plan $2 提示词全文 $3 结果文件 → 跑一次性短会话，日志路径写到 SHORT_LOG
  local model="$LEAD"; [ "$1" = plan ] && model="$PLAN"
  SHORT_LOG="$D/日志/duty_$(date +%m%d_%H%M%S)_$1.log"
  if [ -n "${DUTY_FAKE:-}" ]; then printf '%b\n' "${DUTY_FAKE_DRAFT:-继续\n测试理由}" > "$3"; echo "FAKE $1" > "$SHORT_LOG"; return 0; fi
  command -v "$CL" >/dev/null 2>&1 || { echo "找不到 claude 程序（$CL），设 DUTY_CLAUDE" > "$SHORT_LOG"; return 1; }
  ( cd "$ROOT" && "$CL" -p --model "$model" --effort high --permission-mode bypassPermissions --output-format text "$2" > "$SHORT_LOG" 2>&1 )
}
short_dev(){ # $1 提示词文件 $2 审稿意见文件 → 开发模型只读跑一次，最后一条回复存成 $2；40 分钟没完就停掉
  SHORT_LOG="$D/日志/duty_$(date +%m%d_%H%M%S)_dev.log"
  if [ -n "${DUTY_FAKE:-}" ]; then printf '结论：假跑的开发模型审稿意见\n' > "$2"; echo "FAKE dev" > "$SHORT_LOG"; return 0; fi
  command -v "$CX" >/dev/null 2>&1 || { echo "找不到开发模型程序（$CX），设 DUTY_CODEX" > "$SHORT_LOG"; return 1; }
  "$CX" exec -m "$CX_MODEL" -c model_reasoning_effort='"high"' -c approval_policy='"never"' -s read-only -C "$ROOT" -o "$2" - < "$1" > "$SHORT_LOG" 2>&1 &
  local pid=$! t0; t0=$(now)
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(( $(now) - t0 )) -ge 2400 ]; then kill "$pid" 2>/dev/null; echo "值守：40 分钟没完，已停掉" >> "$SHORT_LOG"; break; fi
    sleep 10
  done
  wait "$pid" 2>/dev/null
}
who_name(){ [ "$1" = plan ] && echo 方案模型 || echo 验收模型; }

# ---------- 一、出事 ----------
n=0; [ -f "$L" ] && n=$(wc -l < "$L"); n="${DUTY_LOG_FROM:-$n}"   # 默认只看启动后新写的日志行
miss=0; last_inc=0
handle_incident(){ # $1 事件描述
  local out="$ST/incident_$(date +%m%d_%H%M%S).txt" head lvl where
  where="$(snap --where)"
  say 即时 "流水线出事了：$(snap --where-short || echo 停在哪没查到)，验收模型在看" "停在哪：${where:-没查到}。"$'\n'"验收模型短会话正在照「停了怎么办」查原因，能恢复就恢复，处理完再通知你。"$'\n\n'"想细看（值守看到的情况）："$'\n'"$1"
  short lead "$(render "$P/prompts/duty_incident.md" "EVENT=$1" "OUT=$out")" "$out"
  head="$(head -n 1 "$out" 2>/dev/null)"
  if [ -n "$head" ]; then
    lvl=摘要; [ "${head#要人定}" != "$head" ] && lvl=即时   # 恢复了、不用管的只进早上摘要；要人定的马上通知
    say "$lvl" "$head" "$(sed -n '2,3p' "$out")"$'\n\n'"想细看："$'\n'"$(sed -n '4,$p' "$out")"$'\n'"会话日志：$SHORT_LOG"; record "出事｜验收模型短会话｜$head"
  else
    say 即时 "流水线出事了，自动处理没成功，要你看" "停在哪：${where:-没查到}。验收模型短会话没写出结果。"$'\n\n'"想细看："$'\n'"$1"$'\n'"会话日志：$SHORT_LOG"; record "出事｜验收模型短会话没出结果｜$SHORT_LOG"
  fi
  last_inc=$(now)
}
check_incident(){
  [ -f "$L" ] || return
  [ $(( $(now) - last_inc )) -ge 1200 ] || return   # 上一件处理完 20 分钟内不再起会话，攒到一起再看
  local total new hit pid
  total=$(wc -l < "$L"); [ "$total" -lt "$n" ] && n=0
  new="$(tail -n +$((n+1)) "$L")"
  hit="$( { printf '%s\n' "$new" | grep '^\[' | grep -E "$HIT" | grep -vE "$EXCL"
            printf '%s\n' "$new" | grep 'Traceback'; } )"
  n=$total
  if [ -n "$hit" ]; then handle_incident "日志出事，最近 15 行："$'\n'"$(printf '%s\n' "$new" | tail -n 15)"; return; fi
  # 主进程：run.sh 正常退出（停止、全部完成）会删掉 run.pid；文件还在、进程却没了 = 异常退出或被杀
  pid="$(cat "$D/run.pid" 2>/dev/null)"
  if [ -f "$D/停止" ] || [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then miss=0; return; fi
  miss=$((miss+1))
  if [ "$miss" -ge 3 ]; then
    handle_incident "流水线可能悄悄停了：run.pid 里的进程 $pid 已不在，连续 3 分钟，且没有「停止」文件。日志末尾："$'\n'"$(tail -n 8 "$L")"
    miss=0
  fi
}

# ---------- 二、三、决定 ----------
apply_draft(){ # $1 决定文件 $2 决定行 → 只在仍是「----」时追加
  [ -f "$1" ] && [ "$(last_line "$1")" = "----" ] && echo "$2" >> "$1"
}
ask_draft(){ # 白天：带按钮的弹窗（仅 macOS），后台等点击
  [ "${DUTY_DIALOG:-}" = off ] && return
  command -v osascript >/dev/null 2>&1 || return 0
  local f="$1" title="$2" body="$3" line="$4" sf="$5"
  ( r="$(osascript - "$title" "$body" <<'AS' 2>/dev/null
on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"我自己看", "按草稿办"} default button "按草稿办" giving up after 3600
  return button returned of result
end run
AS
)"
    if [ "$r" = "按草稿办" ] && apply_draft "$f" "$line"; then echo applied > "$sf"; record "$(basename "$f" .md)｜点了按草稿办｜$line"; fi
    if [ "$r" = "我自己看" ] && [ -f "$f" ] && [ "$(last_line "$f")" = "----" ]; then
      echo "暂停（点了「我自己看」，不自动按草稿；看完在下一行写决定）" >> "$f"; echo blocked > "$sf"; record "$(basename "$f" .md)｜点了我自己看"
    fi ) &
}
draft_for(){ # $1 决定文件 $2 lead|plan $3 accept 文件 $4 草稿文件 → 0=写出草稿
  local hb
  if [ "$2" = plan ] && [ "$(mode)" = 睡觉 ]; then
    hb="只改 \`手册/\` 下的文件；项目是 Git 仓库就提交（\`git add 手册/<改的文件> && git commit -m \"<中性说明>\"\`），然后第一行写 \`返工：…\`。"
  else
    hb="不要改任何文件，第一行写 \`需先改手册：<改什么、为什么>\`。"
  fi
  rm -f "$4"
  short "$2" "$(render "$P/prompts/duty_decide.md" "WHO=$(who_name "$2")" "MODE=$( [ "$(mode)" = 睡觉 ] && echo '夜里，AI 产品经理在睡觉' || echo '白天，AI 产品经理在线，你只起草，他点头或 10 分钟没回才采用')" "FILE=$1" "DRAFT=$4" "ACCEPT=${3:-（没找到 accept 文件）}" "HANDBOOK=$hb")" "$4"
  [ -s "$4" ]
}
check_decisions(){
  local f="$D/等待决定.md" sf key stage acc lvl who draft line reason kind t why rec
  [ -f "$f" ] || return
  [ "$(last_line "$f")" = "----" ] || return
  if grep -q "返工待定稿" "$f"; then kind=返工
  elif grep -q "一直等你" "$f" && [ "$(mode)" = 睡觉 ]; then kind=夜间决定
  else return; fi
  key="等待决定_$(mtime "$f")"; sf="$ST/$key.state"; draft="$ST/$key.draft"
  stage="$(sed -n 's/^子阶段：\([^（]*\).*/\1/p' "$f" | head -n 1)"
  if [ -f "$sf" ]; then  # 已起草过：白天看要不要自动按草稿办
    read -r t line < "$sf"
    case "$line" in 继续|通过|返工：*|返工:*) ;; *) return;; esac   # 只有像样的决定才会自动办
    if [ "$t" != applied ] && [ "$t" != blocked ] && [ "$t" != told ] && [ $(( $(now) - t )) -ge "$AUTO" ]; then
      if apply_draft "$f" "$line"; then
        echo applied > "$sf"; record "${stage}｜白天 $((AUTO/60)) 分钟没回，按草稿办｜$line"
        say 摘要 "已按草稿办（${stage}）：$line" "$(sed -n '2p' "$draft" 2>/dev/null)。你 $((AUTO/60)) 分钟内没有回应，已按草稿办，流水线继续。"$'\n\n'"想细看（草稿其余部分）："$'\n'"$(sed -n '3,$p' "$draft" 2>/dev/null)"
      fi
    fi
    return
  fi
  acc="$D/accept_$stage.json"; [ -f "$acc" ] || acc=""
  lvl=1
  if [ -n "$acc" ]; then lvl="$(python3 -c 'import json,sys
try: print(max(1,int(json.load(open(sys.argv[1], encoding="utf-8")).get("escalation_level") or 1)))
except Exception: print(1)' "$acc")"; fi
  who=plan; [ "$kind" = 返工 ] && [ "$lvl" -le 1 ] && who=lead
  echo "$(now) 起草中" > "$sf"
  echo "$(stamp) $kind $stage 级别 $lvl → $(who_name "$who") 起草：$f"
  draft_for "$f" "$who" "$acc" "$draft" || true
  line="$(head -n 1 "$draft" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ "$who" = lead ] && [ "$(mode)" = 睡觉 ] && [ "${line#需先改手册}" != "$line" ]; then
    record "${stage}｜验收模型说要先改手册，夜里转方案模型｜$line"; who=plan; draft_for "$f" plan "$acc" "$draft" || true
    line="$(head -n 1 "$draft" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  reason="$(sed -n '2,$p' "$draft" 2>/dev/null)"
  why="$(sed -n 's/^原因：//p' "$f" | head -n 1)"; rec="$(sed -n 's/^推荐：//p' "$f" | head -n 1)"
  case "$line" in
    继续|通过|返工：*|返工:*)
      if [ "$(mode)" = 睡觉 ]; then
        apply_draft "$f" "$line" && { echo applied > "$sf"; record "${stage}｜夜里 $(who_name "$who") 定｜$line"
          say 摘要 "夜里已定（${stage}，$(who_name "$who")）：$line" "$(first_of "$reason")"$'\n'"流水线继续，接下来：$(snap --where-short || echo 照常跑)。"$'\n\n'"想细看："$'\n'"$reason"$'\n'"决定文件：$f"$'\n'"会话日志：$SHORT_LOG"; }
      else
        echo "$(now) $line" > "$sf"; record "${stage}｜白天 $(who_name "$who") 起草，等人｜$line"
        say 即时 "返工草稿待你看：${stage}，$(first_of "$reason")" "草稿：$line"$'\n'"你能怎么做：弹窗点「按草稿办」立即采用，点「我自己看」就等你，也可以在决定文件末尾直接写你的决定。$((AUTO/60)) 分钟没回自动按草稿办。"$'\n\n'"想细看："$'\n'"为什么返工：${why}"$'\n'"草稿（级别 ${lvl}，$(who_name "$who") 起草）：$reason"$'\n'"决定文件：$f" nopopup
        ask_draft "$f" "${PROJECT_NAME}：返工草稿待你看（${stage}）" "$(printf '%s\n\n%s\n\n%s 分钟没回自动按草稿办。' "草稿：$line" "$(echo "$reason" | head -n 4)" "$((AUTO/60))")" "$line" "$sf"
      fi ;;
    *)
      echo told > "$sf"; record "${stage}｜$(who_name "$who") 没给出能自动办的决定｜${line:-（空）}"
      say 即时 "要你定：${stage} ${line:-短会话没写出决定}" "问什么：${line:-$(who_name "$who") 短会话没写出能自动办的决定}"$'\n'"推荐什么：${rec:-没有推荐}"$'\n'"在决定文件末尾写你的决定（按推荐 / 继续 / 通过 / 返工：…）。"$'\n\n'"想细看："$'\n'"$reason"$'\n'"决定文件：$f"$'\n'"会话日志：$SHORT_LOG" ;;
  esac
}

# ---------- 四、审稿包（只在夜里） ----------
R="${DUTY_REVIEW_DIR:-$ROOT}"
RS="$D/审稿状态"
REVIEW_PER_PACK=4    # 每个审稿包最多起几次短会话（含开发模型只读审那次）
mkdir -p "$RS"
review_state(){ # $1 审稿包 → 前 10 行里第一条「状态：」后面的字样（去掉首尾空白）
  head -n 10 "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m 1 '^状态：' | sed 's/^状态：//'
}
review_fake_set(){ # 假跑：把状态行改成 $2
  local tmp="$1.duty_tmp"
  awk -v s="状态：$2" 'NR<=10 && !d && /^[[:space:]]*状态：/ { print s; d=1; next } { print }' "$1" > "$tmp" && mv "$tmp" "$1"
}
review_full(){ # $1 包名 $2 状态 → 起满了就记失败并通知，返回 0
  local cnt; cnt="$(cat "$RS/$1.count" 2>/dev/null)"; cnt="${cnt:-0}"
  [ "$cnt" -ge "$REVIEW_PER_PACK" ] || return 1
  touch "$RS/$1.failed"; record "审稿｜$1｜已起满 ${REVIEW_PER_PACK} 次短会话，不再碰｜状态：$2"
  say 即时 "审稿卡住：${1#审稿包_} 停在「$2」，值守不再重试" "这个审稿包已经起过 ${REVIEW_PER_PACK} 次短会话还没走完。你要做什么：看一眼，或白天叫验收模型接手。"$'\n\n'"想细看："$'\n'"审稿包：$R/$1.md"$'\n'"回复：$R/$1_回复.md"
}
review_count(){ local cnt; cnt="$(cat "$RS/$1.count" 2>/dev/null)"; echo $(( ${cnt:-0} + 1 )) > "$RS/$1.count"; }
check_reviews(){ # 每轮最多起一个审稿短会话，起完就返回，好让出事检查照常跑
  [ "$(mode)" = 睡觉 ] || return
  local f name st tag who tpl round next out after dv settle
  for f in "$R"/审稿包_*.md; do
    name="$(basename "$f" .md)"
    case "$name" in 审稿包模板|*_回复) continue;; esac
    [ -f "$RS/$name.failed" ] && continue
    st="$(review_state "$f")"
    dv="$R/开发模型审稿_${name#审稿包_}.md"
    if [ "$st" = "待方案模型审第 1 轮" ] && head -n 10 "$f" | grep -q '^[[:space:]]*开发模型审：要' \
       && [ ! -f "$RS/${name}_dev.done" ] && [ ! -f "$dv" ]; then
      review_full "$name" "$st" && continue
      review_count "$name"; touch "$RS/${name}_dev.done"   # 先记再起：中途崩了也不会重起
      echo "$(stamp) 审稿 ${name} 先起开发模型只读同题审"
      render "$P/prompts/review_dev.md" "PACK=$f" "OUT=$dv" > "$RS/${name}_dev.prompt"
      short_dev "$RS/${name}_dev.prompt" "$dv" || true
      if [ -s "$dv" ]; then record "审稿｜${name}｜开发模型同题审完成｜$(head -n 1 "$dv")"
      else record "审稿｜${name}｜开发模型没出结果，不等，方案模型照起｜${SHORT_LOG}"; fi
      return
    fi
    case "$st" in
      "待方案模型审第 1 轮")   who=plan; tpl=review_planner.md; round=1; next="待验收模型处理第 1 轮" ;;
      "待验收模型处理第 1 轮") who=lead; tpl=review_reviser.md; round=1; next="待方案模型审第 2 轮" ;;
      "待方案模型审第 2 轮")   who=plan; tpl=review_planner.md; round=2; next="已定" ;;
      *) continue ;;          # 已定、没有状态行、别的字样：一律不碰
    esac
    tag="${st// /}"
    [ -f "$RS/${name}_${tag}.done" ] && continue   # 这个状态已经起过一次
    review_full "$name" "$st" && continue
    review_count "$name"; touch "$RS/${name}_${tag}.done"   # 先记再起：中途崩了也不会重起
    out="$RS/${name}_${tag}.out"; rm -f "$out"
    echo "$(stamp) 审稿 ${name} 状态「${st}」→ $(who_name "$who") 短会话"
    short "$who" "$(render "$P/prompts/$tpl" "PACK=$f" "REPLY=$R/${name}_回复.md" "ROUND=$round" "CUR=$st" "NEXT=$next" "OUT=$out")" "$out" || true
    if [ -n "${DUTY_FAKE:-}" ] && [ "${DUTY_FAKE_REVIEW:-advance}" = advance ]; then review_fake_set "$f" "$next"; fi
    after="$(review_state "$f")"
    if [ "$after" = "$next" ]; then
      record "审稿｜${name}｜$(who_name "$who") 第 ${round} 轮完成｜${st} → ${next}｜$(head -n 1 "$out" 2>/dev/null)"
      if [ "$next" = 已定 ] && [ ! -f "$RS/${name}_已定.done" ]; then
        touch "$RS/${name}_已定.done"; record "审稿｜${name}｜已定"
        settle="$(grep '^[[:space:]]*敲定：' "$R/${name}_回复.md" 2>/dev/null | tail -n 1 | sed 's/^[[:space:]]*敲定：[[:space:]]*//')"
        snap --check-sentence "$settle" || { [ -f "$P/status_snapshot.py" ] && settle=""; }   # 敲定句带路径、写「见某文件」就不当标题用
        ledger_add "落地 ${name} 的敲定结论" "${name}_回复.md 第 2 轮" 验收模型 "$(tomorrow)"
        say 摘要 "审稿已定：${name#审稿包_}" "${settle:-审稿已定，但没抽到能直接看的敲定句，验收模型处理时补}"$'\n\n'"已记进一本账：验收模型明天前把敲定结论落地。"$'\n\n'"想细看："$'\n'"回复：${R}/${name}_回复.md（「第 2 轮」一节）"$'\n'"审稿包：${f}（第六节最后一行）"$'\n'"会话日志：${SHORT_LOG}"
      fi
    else
      touch "$RS/$name.failed"; record "审稿｜${name}｜$(who_name "$who") 第 ${round} 轮失败：状态应变成「${next}」，现在是「${after:-（没有状态行）}」，不再碰｜${SHORT_LOG}"
      say 即时 "审稿卡住：${name#审稿包_} 停在$(who_name "$who")那一步，值守不再重试" "$(who_name "$who")短会话跑完，状态没按预期变成「${next}」（现在是「${after:-没有状态行}」）。你要做什么：看一眼，或白天叫验收模型接手。"$'\n\n'"想细看："$'\n'"审稿包：${f}"$'\n'"回复：${R}/${name}_回复.md"$'\n'"会话日志：${SHORT_LOG}"
    fi
    return
  done
}

# ---------- 五、账检查与状态快照 ----------
snapshot(){
  touch "$ST/心跳"
  [ -f "$P/ledger_check.py" ] && LEDGER_FILE="${DUTY_LEDGER:-}" python3 "$P/ledger_check.py" --report --out "$D/账检查.json" >/dev/null 2>&1
  [ -f "$P/status_snapshot.py" ] || return 0
  if [ -n "${DUTY_FAKE:-}" ]; then SNAP_D="$D" SNAP_SEND=echo SNAP_NO_DAILY=1 python3 "$P/status_snapshot.py" >/dev/null 2>&1 || true
  else SNAP_D="$D" python3 "$P/status_snapshot.py" >> "$D/日志/status_snapshot.log" 2>&1 || true; fi
}

while true; do
  check_incident
  check_decisions
  check_reviews
  snapshot
  [ -n "${DUTY_ONCE:-}" ] && exit 0
  sleep "${DUTY_SLEEP:-60}"
done
