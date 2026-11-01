"""Trias · 状态快照（值守的可选部分，只用标准库）。

值守每轮调一次（不带参数）：从源头重算，同一份数据写三个出口、发三类邮件：
  运行数据/pipeline/现状.md     给接手的模型开局读：≤600 字五节，路径只放「想细看」
  运行数据/pipeline/看板.html   给 AI 产品经理：首屏「到哪了 / 要我做什么 / 有没有卡住」，超 5 分钟没刷新整页变灰
  运行数据/pipeline/现状.json   程序内部的中间文件
  邮件：早上摘要（每天一封，没动静也没积压就不发，连着 3 天没动静发一封）、进度邮件（里程碑攒 30 分钟合一封，新段开工立刻发）、
        卡住两档（日志 3 小时没新行 / 一轮开工 6 小时还没结论，同一轮每档只发一次）
另外每天一次：把讨论记录（审稿包、方案、交接、一本账、项目状态）本地提交，不推送。
源头：项目状态.md 进度表、pipeline.log、等待决定.md、审稿包状态行、账检查.json（ledger_check.py --report）、值守记录.md（事件流）。
用法（任何目录）：
  python3 pipeline/status_snapshot.py                       每轮：重算 + 该发的发
  python3 pipeline/status_snapshot.py --where               只打一行「现在到哪了」（--where-short 只打段和步）
  python3 pipeline/status_snapshot.py --check-sentence "句子"  结论句合格（不空、不含路径、不以「见」开头、≥8 字）退出码 0
测试用环境变量：SNAP_D（运行数据目录）、SNAP_NOW（假装现在，YYYY-MM-DD HH:MM）、SNAP_SEND=echo（不发信，打印）、SNAP_NO_DAILY=1（不做每日提交）。
"""
import datetime, html, json, os, re, subprocess, sys
from pathlib import Path

import state  # 同目录的 state.py：读 项目状态.md 进度表

P = Path(__file__).resolve().parent
ROOT = P.parent
D = Path(os.environ.get("SNAP_D") or ROOT / "运行数据/pipeline")
LOG, EVENTS, STATE = D / "日志/pipeline.log", D / "值守记录.md", D / "值守状态"
REVIEW_DIR = Path(os.environ.get("DUTY_REVIEW_DIR") or ROOT)
DIGEST_HOUR = int(os.environ.get("SNAP_DIGEST_HOUR", "8"))
DAILY_FILES = ["审稿包_*.md", "*审稿_*.md", "方案*.md", "交接*.md", "交接归档", "未结待办.md", "项目状态.md"]
PASSED = state.PASSED
WHO_FIX = {1: "开发模型直接改", 2: "先出检查单再改", 3: "验收模型亲修", 4: "转方案模型"}
LINE = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)$")
PATHLIKE = re.compile(r"(^|[\s`（(：:])(/|运行数据/|验收证据/|手册/|pipeline/)|\S+/\S+\.(md|json|log|py|sh|html|txt)\b")


def now():
    v = os.environ.get("SNAP_NOW")
    return datetime.datetime.strptime(v, "%Y-%m-%d %H:%M") if v else datetime.datetime.now().replace(microsecond=0)


def read(p):
    try:
        return Path(p).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def jload(p, default):
    try:
        return json.loads(read(p)) if Path(p).exists() else default
    except ValueError:
        return default


def jsave(p, data):
    tmp = Path(f"{p}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    tmp.replace(p)


def ago(dt, at):
    m = int((at - dt).total_seconds() // 60)
    return f"{m} 分钟" if m < 60 else f"{m // 60} 小时{m % 60:02d} 分" if m < 1440 else f"{m // 1440} 天"


def good_sentence(s):
    s = (s or "").strip()
    return len(s) >= 8 and not PATHLIKE.search(s) and not re.match(r"^(见|详见|结论见)", s)


# ---------- 抽数 ----------
def stage_table():
    try:
        return [{"stage": sid, "name": name, "status": st} for _, sid, name, st, _ in state.rows()]
    except OSError:
        return []


def goal_line(stage):
    """手册「## 1. 目标」下第一行（去掉「一句话：」），当这一段的人话说明。"""
    base = re.sub(r"[a-z]+$", "", stage)
    for pat in (f"{stage}_*.md", f"{base}_*.md"):
        for f in sorted((ROOT / "手册").glob(pat)):
            m = re.search(r"^##\s*1\.\s*目标\s*\n+(.+)$", read(f), re.M)
            if m and not m.group(1).startswith("#"):
                return re.sub(r"^一句话[：:]\s*", "", m.group(1).strip())
    return ""


def verdict_line(stage):
    """验收结论「一句话摘要」节第一行。"""
    sec = read(ROOT / "验收证据" / stage / "验收结论.md").split("一句话摘要", 1)
    return next((x.strip().lstrip("-*0-9.、 ").strip() for x in sec[1].splitlines()[1:] if x.strip()), "") if len(sec) > 1 else ""


def log_since_start():
    lines, start, out = read(LOG).splitlines()[-4000:], 0, []
    for i, x in enumerate(lines):
        if "] 流水线启动 " in x:
            start = i
    for x in lines[start:]:
        m = LINE.match(x)
        if m:
            out.append((datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"), m.group(2)))
        elif out:  # 多行日志（等待决定的原因）挂到上一条
            out[-1] = (out[-1][0], out[-1][1] + "\n" + x)
    return out


def lane_and_milestones(table):
    L = {"stage": "", "name": "", "step": "", "round": 1, "round_at": None, "last_at": None, "done": False, "waiting": False}
    ms, contra = [], []
    for t, msg in log_since_start():
        first = msg.split("\n", 1)[0]
        L["last_at"] = t
        if m := re.match(r"当前 (\S+) (.*?) 状态=(\S+)", first):
            if m.group(1) != L["stage"]:
                L.update(stage=m.group(1), name=m.group(2), round=1, round_at=t)
            L.update(step=m.group(3), waiting=False)
            if m.group(3) == "未开始":
                ms.append({"at": t, "kind": "开工", "stage": m.group(1), "text": f"开始 {m.group(1)}：{goal_line(m.group(1)) or m.group(2)}"})
        elif first.startswith("开发模型开工"):
            L.update(step="开发模型在做", round_at=t, waiting=False)
        elif first.startswith("验收模型开工"):
            L.update(step="验收模型亲修" if "（fix）" in first else "验收中")
        elif first.startswith("等待决定："):
            L.update(step="等你定", waiting=True)
            if "推荐=返工" in first:
                ms.append({"at": t, "kind": "返工", "stage": L["stage"], "text": f"{L['stage']} 判返工：{verdict_line(L['stage']) or '验收结论没写一句话摘要'}"})
        elif m := re.match(r"返工级别 (\d+)（第 (\d+) 轮）", first):
            L.update(round=int(m.group(2)) + 1, step=f"返工中，{WHO_FIX.get(int(m.group(1)), '')}")
        elif first.startswith("返工 "):
            L.update(step="返工中", waiting=False)
        elif m := re.match(r"(\S+) -> 已通过", first):
            ms.append({"at": t, "kind": "通过", "stage": m.group(1), "text": f"{m.group(1)} 通过：{verdict_line(m.group(1)) or '验收结论没写一句话摘要'}"})
        elif first.startswith("全部子阶段已通过"):
            L.update(done=True, step="全部做完", waiting=False)
            left = [r["stage"] for r in table if r["status"] not in PASSED]
            if left:
                contra.append(f"日志说全部子阶段已通过，进度表里 {'、'.join(left[:3])} 还没通过")
    left = [r for r in table if r["status"] not in PASSED]
    if not L["stage"] or (L["done"] and left):  # 日志里没有：按进度表第一个没通过的段补位
        L.update(stage=left[0]["stage"], name=left[0]["name"], step=left[0]["status"], done=False) if left else L.update(done=True, step="全部做完")
    return L, ms, contra


def events(at, hours):
    """值守记录.md：notify.py 写的「YYYY-MM-DD HH:MM｜通知｜级别｜来源｜标题｜结论句」。"""
    out = []
    for x in read(EVENTS).splitlines()[-1500:]:
        parts = [p.strip() for p in x.split("｜")]
        try:
            t = datetime.datetime.strptime(parts[0], "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        if len(parts) >= 6 and parts[1] == "通知" and (at - t).total_seconds() <= hours * 3600:
            out.append({"at": t, "title": parts[4], "text": parts[5]})
    return out


def waiting_decisions():
    out = []
    for f in sorted(D.glob("等待决定*.md")):
        lines = [x for x in read(f).splitlines() if x.strip()]
        if lines and lines[-1].strip() == "----":
            get = lambda k: next((x.split("：", 1)[1].strip() for x in lines if x.startswith(k + "：")), "")  # noqa: E731
            out.append({"stage": get("子阶段"), "why": get("原因"), "rec": get("推荐"), "file": str(f),
                        "forever": any("一直等你" in x for x in lines)})
    return out


def reviews():
    out = []
    for f in sorted(REVIEW_DIR.glob("审稿包_*.md")):
        if f.stem == "审稿包模板" or f.stem.endswith("_回复"):
            continue
        st = next((x.strip()[3:] for x in read(f).splitlines()[:10] if x.strip().startswith("状态：")), "")
        if st and st != "已定":
            out.append({"name": f.stem.replace("审稿包_", ""), "state": st, "failed": (D / "审稿状态" / f"{f.stem}.failed").exists()})
    return out


def run_alive():
    try:
        os.kill(int(read(D / "run.pid").strip()), 0)
        return True
    except (ValueError, OSError):
        return False


def ledger_rows():
    out = []
    for x in read(ROOT / "未结待办.md").splitlines():
        c = [v.strip() for v in x.split("|")]
        if len(c) >= 8 and re.fullmatch(r"T\d+", c[1]) and c[6] != "已结":
            out.append({"id": c[1], "what": c[2], "who": c[4], "due": c[5], "state": c[6]})
    return out


def collect():
    at, table = now(), stage_table()
    lane, ms, contra = lane_and_milestones(table)
    progress, bad = [], []
    for e in events(at, 24 * 7):
        if e["title"].startswith("审稿已定") or re.search(r"夜里已定|已按草稿办|已自动按推荐办", e["title"]):
            (progress if good_sentence(e["text"]) else bad).append(e)
    progress += [{"at": m["at"], "title": f"{m['stage']} 验收通过", "text": m["text"].split("：", 1)[1]} for m in ms if m["kind"] == "通过"]
    ledger, rv, alive = jload(D / "账检查.json", {}), reviews(), run_alive()
    stopped = (D / "停止").exists()
    watch = contra + [f"{e['title']}，但没抽到人话结论" for e in bad] + [d["text"] for d in ledger.get("due", [])]
    for key in ("format", "cards", "handoff", "error"):
        watch += [x.get("text", "") for x in ledger.get(key, [])][:2]
    watch += [f"审稿 {r['name']} 卡住（停在「{r['state']}」），值守不再重试" for r in rv if r["failed"]]
    if not lane["done"] and not lane["waiting"] and lane["last_at"] and (at - lane["last_at"]).total_seconds() >= 3 * 3600:
        watch.append(f"{lane['stage']} 已 {ago(lane['last_at'], at)}没动静")
    if not alive and not lane["done"]:
        watch.insert(0, "流水线没在跑" + ("（放了「停止」文件）" if stopped else "，也没有「停止」文件"))
    hb = STATE / "心跳"
    return {"at": at, "lane": lane, "milestones": ms, "progress": sorted(progress, key=lambda p: p["at"]), "watch": watch,
            "waiting": waiting_decisions(), "reviews": rv, "alive": alive, "stopped": stopped, "table": table,
            "heartbeat": datetime.datetime.fromtimestamp(hb.stat().st_mtime).strftime("%m-%d %H:%M") if hb.exists() else "没有"}


# ---------- 出口 ----------
def where(s):
    L = s["lane"]
    if L["done"]:
        return "全部子阶段做完了"
    return f"在做 {L['stage']}：{goal_line(L['stage']) or L['name']}（第 {L['round']} 轮，{L['step'] or '状态不明'}）"


def recent(s, n):
    items = [(m["at"], m["text"]) for m in s["milestones"] if m["kind"] != "通过"] + [(p["at"], f"{p['title']}：{p['text']}") for p in s["progress"]]
    return [f"{t:%m-%d %H:%M} {x}" for t, x in sorted(items)[-n:]]


def status_md(s):
    sec = ["# 现状（程序每轮重算，别手改）", f"更新：{s['at']:%m-%d %H:%M}", "", "## 在哪段", f"- {where(s)}", "", "## 在等什么"]
    wait = [f"- {w['stage']}：{w['why'][:50]}；推荐 {w['rec'] or '没有推荐'}" for w in s["waiting"]] + [f"- 审稿 {r['name']}：{r['state']}" for r in s["reviews"]]
    sec += wait[:5] or ["- 没有"]
    sec += ["", "## 过期待办与要留意"] + ([f"- {x[:70]}" for x in s["watch"][:5]] or ["- 没有"])
    sec += ["", "## 最近 5 个里程碑"] + ([f"- {x[:70]}" for x in recent(s, 5)] or ["- 没有"])
    tail = ["", "## 想细看", "- 账 未结待办.md；交接 交接_最新.md", "- 运行数据/pipeline/ 下：日志/pipeline.log、值守记录.md、看板.html"]
    while len("\n".join(sec + tail)) > 600:  # 超 600 字：最长的条目先截短，短到 15 字还超就整条去掉
        i = max((j for j, x in enumerate(sec) if x.startswith("- ")), key=lambda j: len(sec[j]), default=None)
        if i is None:
            break
        if len(sec[i]) > 15:
            sec[i] = sec[i][:-11] + "…"
        else:
            sec.pop(i)
    return "\n".join(sec + tail) + "\n"


CSS = """:root{--bg:#f5f4f0;--card:#fff;--ink:#1f1d1a;--mute:#77716a;--line:#e6e2da;--acc:#4f5bd5;--acc-bg:#eceefc;--ok:#2f7d5b;--ok-bg:#e8f3ed;--warn:#b0641a;--warn-bg:#fbefe1;--soft:#f0eee9}
@media (prefers-color-scheme:dark){:root{--bg:#181715;--card:#22211e;--ink:#ece8e0;--mute:#9a948a;--line:#35322d;--acc:#9aa3f5;--acc-bg:#2a2c45;--ok:#7cc4a0;--ok-bg:#1f3129;--warn:#e7a862;--warn-bg:#3a2b1b;--soft:#2a2825}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 -apple-system,"PingFang SC","Hiragino Sans GB","Noto Sans CJK SC",sans-serif}
main{max-width:920px;margin:0 auto;padding:20px 16px 60px}h1{font-size:22px;margin:0}.row{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0 0}
nav{position:sticky;top:0;background:var(--bg);display:flex;gap:6px;overflow-x:auto;padding:12px 0;border-bottom:1px solid var(--line)}
nav a{flex:none;color:var(--mute);text-decoration:none;font-size:14px;padding:4px 12px;border-radius:999px;background:var(--soft)}
section{margin-top:28px;scroll-margin-top:60px}h2{font-size:17px;margin:0 0 10px}h2 small{font-weight:400;color:var(--mute);font-size:13px;margin-left:8px}
.box,.item{background:var(--card);border:1px solid var(--line);border-radius:12px}.box{overflow:hidden}.big{font-size:24px;font-weight:700;margin:2px 0 8px}
.pad{padding:16px 18px}.mute{color:var(--mute);font-size:13px}.pill{display:inline-block;font-size:12px;padding:2px 10px;border-radius:999px;white-space:nowrap;background:var(--soft);color:var(--mute)}
.acc{background:var(--acc-bg);color:var(--acc)}.ok{background:var(--ok-bg);color:var(--ok)}.warn{background:var(--warn-bg);color:var(--warn)}
.item{padding:12px 16px;margin-bottom:8px}.item.ok,.item.warn{border-color:transparent}.item p{margin:4px 0 0}
.bar{height:10px;border-radius:999px;background:var(--soft);overflow:hidden;margin:4px 0 12px}.bar i{display:block;height:100%;background:var(--ok)}
.tr{display:flex;gap:12px;align-items:baseline;padding:10px 16px;border-top:1px solid var(--line)}.tr:first-child{border-top:0}.tr.cur{background:var(--acc-bg)}
.grow{flex:1;min-width:0}.k{flex:none;width:64px;font-family:ui-monospace,Menlo,monospace;font-size:13px}.t{flex:none;width:96px;color:var(--mute);font-size:13px}
body.stale main{filter:grayscale(1);opacity:.55}#stale{display:none;background:var(--warn);color:#fff;padding:8px 16px;font-weight:600}body.stale #stale{display:block}"""


def board_html(s):
    e, L, at = html.escape, s["lane"], s["at"]
    alive = ("在跑", "ok") if s["alive"] else ("没在跑", "warn")
    meta = [f"第 {L['round']} 轮"] + ([f"{L['round_at']:%H:%M} 开工"] if L["round_at"] else []) + ([f"最后动静 {ago(L['last_at'], at)}前"] if L["last_at"] else [])
    now_card = (f"<div class='box pad'><div class='big' style='color:var(--ok)'>全部做完</div></div>" if L["done"] else
                f"<div class='box pad'><div class='big'>{e(L['stage'])} <small>{e(L['name'])}</small></div>"
                f"<span class='pill {'warn' if L['waiting'] else 'acc'}'>{e(L['step'] or '状态不明')}</span>"
                f"<p class='mute'>{' · '.join(meta)}</p><p>{e(goal_line(L['stage']))}</p></div>")
    todo = [f"<div class='item warn'><b>{e(w['stage'])} 在等你定</b><p>{e(w['why'][:160])}</p><p>推荐：{e(w['rec'] or '没有推荐')}　<span class='mute'>"
            f"{'会一直等你' if w['forever'] else '10 分钟不回就按推荐办'}</span></p></div>" for w in s["waiting"]]
    todo += [f"<div class='item warn'>{e(x)}</div>" for x in s["watch"][:8]]
    rows = ledger_rows()
    todo += [f"<div class='item'>{e(r['id'])} {e(r['what'][:80])}<span class='mute'>（到期 {e(r['due'])}）</span></div>" for r in rows if r["who"] == "AI 产品经理"]
    todo = todo or ["<div class='item ok'>现在没有要你定的事，也没有卡住、过期的事。</div>"]
    tbl, passed_n = s["table"], sum(1 for r in s["table"] if r["status"] in PASSED)
    pct = round(passed_n * 100 / len(tbl)) if tbl else 100
    stages = "".join(f"<div class='tr {'cur' if r['stage'] == L['stage'] and not L['done'] else ''}'><span class='k'>{e(r['stage'])}</span>"
                     f"<span class='grow'>{e(r['name'])}</span><span class='pill {'ok' if r['status'] in PASSED else 'acc' if r['stage'] == L['stage'] else ''}'>{e(r['status'])}</span></div>" for r in tbl)
    rv = "".join(f"<div class='tr'><span class='grow'><b>{e(r['name'])}</b></span><span class='pill {'warn' if r['failed'] else ''}'>"
                 f"{'卡住了' if r['failed'] else e(r['state'])}</span></div>" for r in s["reviews"]) or "<div class='item ok'>没有在审的</div>"
    led = "".join(f"<div class='tr'><span class='k'>{e(r['id'])}</span><span class='grow'>{e(r['what'][:90])}</span><span class='t'>{e(r['who'])}</span>"
                  f"<span class='t'>{e(r['due'])}</span></div>" for r in sorted(rows, key=lambda r: (not re.match(r"\d{4}-", r["due"]), r["due"])))
    evs = "".join(f"<div class='tr'><span class='t'>{e(x[:11])}</span><span class='grow'>{e(x[12:])}</span></div>" for x in reversed(recent(s, 15)))
    return f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{e(ROOT.name)} 看板</title><style>{CSS}</style></head><body>
<div id="stale">值守没在更新：这页超过 5 分钟没刷新，下面可能不是现在的情况</div><main>
<h1>{e(ROOT.name)} 看板</h1><div class="row"><span class="pill {alive[1]}">流水线{alive[0]}</span><span class="pill">快照 {at:%m-%d %H:%M}</span>
<span class="pill">值守心跳 {e(s['heartbeat'])}</span><span class="pill ok">已通过 {passed_n} / {len(tbl)} 段</span></div>
<nav><a href="#now">现在</a><a href="#todo">要你做</a><a href="#stages">进度</a><a href="#review">审稿</a><a href="#ledger">待办账</a><a href="#log">最近动静</a></nav>
<section id="now"><h2>现在在做什么</h2>{now_card}</section><section id="todo"><h2>要你做的</h2>{''.join(todo)}</section>
<section id="stages"><h2>进度<small>已通过 {passed_n} 段，还剩 {len(tbl) - passed_n} 段</small></h2><div class="bar"><i style="width:{pct}%"></i></div><div class="box">{stages}</div></section>
<section id="review"><h2>审稿</h2><div class="box">{rv}</div></section>
<section id="ledger"><h2>待办账<small>没结的 {len(rows)} 条</small></h2><div class="box">{led or "<div class='item ok'>没有</div>"}</div></section>
<section id="log"><h2>最近动静<small>新的在上</small></h2><div class="box">{evs or "<div class='item ok'>最近没有动静</div>"}</div></section>
</main><script>if(Date.now()-{int(at.timestamp() * 1000)}>5*60*1000)document.body.className='stale'</script></body></html>
"""


# ---------- 发信（走 notify.py 的「邮件」档，不记事件流） ----------
def send(title, body):
    if os.environ.get("SNAP_SEND") == "echo":
        print(f"[发信] {title}\n{body}\n")
        return True
    env = dict(os.environ, NOTIFY_LEVEL="邮件", NOTIFY_NO_EVENT="1", NOTIFY_SOURCE="status_snapshot")
    try:
        out = subprocess.run([sys.executable, str(P / "notify.py"), title, body], capture_output=True, text=True, timeout=90, env=env).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return ":ok" in out or "no-channel" in out   # 没配任何渠道也算发过，免得每分钟重试


def morning(s, at):
    cur_f = STATE / "摘要游标.json"
    cur = jload(cur_f, {})
    if at.hour < DIGEST_HOUR or cur.get("day") == f"{at:%Y-%m-%d}":
        return
    since = datetime.datetime.strptime(cur["sent_at"], "%Y-%m-%d %H:%M:%S") if cur.get("sent_at") else at - datetime.timedelta(days=1)
    prog = [p for p in s["progress"] if p["at"] > since][-5:]
    rework = [m for m in s["milestones"] if m["kind"] == "返工" and m["at"] > since]
    if not (prog or rework or s["waiting"] or s["watch"]) and (at - since).days < 3:
        return
    if s["waiting"]:
        head = f"{s['waiting'][0]['stage']} 在等你定：{s['waiting'][0]['why'][:40]}"
    elif s["watch"]:
        head = s["watch"][0]
    elif prog:
        head = f"{prog[-1]['title']}：{prog[-1]['text']}"
    elif rework:
        head = rework[-1]["text"]
    else:
        head = f"三天没动静：{where(s)}"
    out = [head, ""]
    if s["waiting"]:
        out += ["【等你定】"] + [f"- {w['stage']}：{w['why'][:60]}。推荐：{w['rec'] or '没有推荐'}。" + ("不定的话流水线一直停着。" if w["forever"] else "不定的话 10 分钟后自动按推荐办。") for w in s["waiting"][:3]] + [""]
    items = [f"- {p['title']}：{p['text']}" for p in prog] + [f"- {m['text']}" for m in rework]
    out += (["【昨天进展】"] + items[:5] + [""]) if items else []
    out += (["【今天到期 / 要留意】"] + [f"- {x}" for x in s["watch"][:3]] + [""]) if s["watch"] else []
    out += ["【现在到哪】", where(s), "", "【想细看】", f"看板：{D / '看板.html'}", f"账：{ROOT / '未结待办.md'}"] + [f"等待决定：{w['file']}" for w in s["waiting"][:3]]
    if send(f"早上摘要：{head[:40]}", "\n".join(out)):
        jsave(cur_f, {"day": f"{at:%Y-%m-%d}", "sent_at": f"{at:%Y-%m-%d %H:%M:%S}"})


def progress_mail(s, at):
    """里程碑合并：最早一条过 30 分钟，或里面有新段开工，就合成一封发。"""
    cur_f = STATE / "进度游标.json"
    cur = jload(cur_f, {})
    if not cur.get("until"):
        return jsave(cur_f, {"until": f"{at:%Y-%m-%d %H:%M:%S}"})  # 第一次跑不补发历史
    until = datetime.datetime.strptime(cur["until"], "%Y-%m-%d %H:%M:%S")
    new = [m for m in s["milestones"] if m["at"] > until]
    if not new or ((at - new[0]["at"]).total_seconds() < 1800 and not any(m["kind"] == "开工" for m in new)):
        return
    left = [r["stage"] for r in s["table"] if r["status"] not in PASSED]
    body = "\n".join(["刚发生什么："] + [f"- {m['text']}" for m in new] +
                     ["", f"现在到哪：{where(s)}；还剩 {len(left)} 段" + (f"（{'、'.join(left[:6])}）" if left else ""),
                      "要你做的：" + (f"{s['waiting'][0]['stage']} 在等你定，已单独通知" if s["waiting"] else "无"), "", f"想细看：{D / '看板.html'}"])
    kinds = "，".join({"开工": f"开始 {m['stage']}", "通过": f"{m['stage']} 通过", "返工": f"{m['stage']} 返工"}[m["kind"]] for m in new)
    if send(f"进度：{kinds[:60]}", body):
        jsave(cur_f, {"until": f"{new[-1]['at']:%Y-%m-%d %H:%M:%S}"})


def stuck_mail(s, at):
    f, L = STATE / "卡住提醒.json", s["lane"]
    told = jload(f, {})
    if L["done"] or L["waiting"] or not L["round_at"] or not L["last_at"] or s["stopped"]:
        return
    key = f"{L['stage']}:{L['round']}"
    if (at - L["last_at"]).total_seconds() >= 3 * 3600 and f"{key}:3h" not in told:
        if send(f"可能卡了：{L['stage']} {ago(L['last_at'], at)}没动静",
                f"{where(s)}。\n日志已经 {ago(L['last_at'], at)}没有新行，可能卡住了。\n要你做的：看一眼，或叫验收模型照「停了怎么办」查。\n\n想细看：{LOG}"):
            told[f"{key}:3h"] = f"{at}"
    elif (at - L["round_at"]).total_seconds() >= 6 * 3600 and f"{key}:6h" not in told:
        if send(f"做得久：{L['stage']} 第 {L['round']} 轮已 {ago(L['round_at'], at)}",
                f"{where(s)}。\n日志还在动，但这一轮开工 {ago(L['round_at'], at)}还没有结论。\n要你做的：无，先留意。\n\n想细看：{LOG}"):
            told[f"{key}:6h"] = f"{at}"
    jsave(f, told)


def daily_commit(at):
    """每天一次把讨论记录本地提交（不推送）；git 忙（index.lock）就下一轮再试。"""
    f = STATE / "每日提交.json"
    if jload(f, {}).get("day") == f"{at:%Y-%m-%d}" or os.environ.get("SNAP_NO_DAILY"):
        return
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), *a], capture_output=True, text=True, timeout=120)  # noqa: E731
    if git("rev-parse", "--git-dir").returncode:
        return jsave(f, {"day": f"{at:%Y-%m-%d}", "skip": "不是 Git 仓库"})
    files = [str(p.relative_to(ROOT)) for pat in DAILY_FILES for p in ROOT.glob(pat)]
    if files and git("add", "--", *files).returncode:
        return
    if git("diff", "--cached", "--quiet").returncode and git("commit", "-q", "-m", "值守：每日提交讨论记录").returncode:
        return
    jsave(f, {"day": f"{at:%Y-%m-%d}"})


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--check-sentence":
        return 0 if good_sentence(sys.argv[2] if len(sys.argv) > 2 else "") else 1
    s = collect()
    if arg in ("--where", "--where-short"):
        L = s["lane"]
        print(where(s) if arg == "--where" else ("全部做完" if L["done"] else f"{L['stage']}（{L['step']}）"))
        return 0
    STATE.mkdir(parents=True, exist_ok=True)
    jsave(D / "现状.json", s)
    (D / "现状.md").write_text(status_md(s), encoding="utf-8")
    (D / "看板.html").write_text(board_html(s), encoding="utf-8")
    for fn in (morning, progress_mail, stuck_mail):
        try:
            fn(s, s["at"])
        except Exception as err:  # noqa: BLE001 一个出口坏了不挡别的
            print(f"status_snapshot：{fn.__name__} {type(err).__name__}: {err}", file=sys.stderr)
    try:
        daily_commit(s["at"])
    except Exception as err:  # noqa: BLE001
        print(f"status_snapshot：daily_commit {type(err).__name__}: {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
