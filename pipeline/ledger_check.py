"""一本账检查（只用标准库）。账是项目根的 未结待办.md，格式见 templates/未结待办.md。

两类输出，分开用：
  --due 段            给 run.sh 段首：列出账上「到期 = <段> 开工前」且没结的条目，有就退出码 3（流水线停下等）。
  --add 事 出处 归谁 到期   往账末尾追加一条（编号自动取下一个）；同一件事（一字不差）已有没结的就不重复加。
  --recheck 段 手册   手册头「核对主干：<提交号>」到现在，手册点名的文件有多少提交。第一行输出 ok / note / stop / none
                      （none = 手册没写核对行）；note、stop 后面几行是提交清单。超过 RECHECK_DAYS 天或 RECHECK_COMMITS 个提交才 stop。
  --report [--out 文件]  给值守每轮跑：账格式、到期、规则卡里的现状句、交接五项。这些只提醒，永不拦流水线；检查器自己出错单列 error。
用法（任何目录）：python3 pipeline/ledger_check.py --due S2
"""
import argparse, datetime, fcntl, json, os, re, subprocess, sys
from pathlib import Path

import state  # 同目录的 state.py：读 项目状态.md 进度表

ROOT = Path(__file__).resolve().parents[1]
LEDGER = Path(os.environ.get("LEDGER_FILE") or ROOT / "未结待办.md")
RULE_CARDS = [ROOT / "CLAUDE.md", ROOT / "AGENTS.md"]
COLS = ["编号", "事", "出处", "归谁", "到期", "状态", "做完证据"]
STATES = {"未结", "在做", "已结"}
OWNERS = {"方案模型", "开发模型", "验收模型", "AI 产品经理"}
HANDOFF_SECTIONS = ["⑤", "①", "②", "③", "④"]
HANDOFF_BANNED = ["上一份", "仍有效", "照上一份", "交接归档"]
HANDOFF_MAX = 3000
RECHECK_DAYS, RECHECK_COMMITS = 5, 10


def stages():
    try:
        return [sid for _, sid, _, _, _ in state.rows()]
    except OSError:
        return []


def table_rows(text):
    """markdown 表格行（跳过分隔行），返回 [(行号, [格...])]。"""
    rows = []
    for no, line in enumerate(text.splitlines(), 1):
        t = line.strip()
        if t.startswith("|") and not re.fullmatch(r"\|[\s:|-]+\|", t):
            rows.append((no, [c.strip() for c in t.strip("|").split("|")]))
    return rows


def due_kind(s, sts):
    m = re.fullmatch(r"(\S+) (开工前|通过后)", s)
    if m and m.group(1) in sts:
        return ("stage", m.group(1), m.group(2))
    try:
        return ("date", datetime.date.fromisoformat(s), "")
    except ValueError:
        return None


def parse_ledger(sts):
    """返回 (条目列表, 格式问题列表)。"""
    if not LEDGER.exists():
        return [], [{"key": "ledger:missing", "text": "一本账 未结待办.md 不在"}]
    items, problems, seen = [], [], set()
    for no, cells in table_rows(LEDGER.read_text(encoding="utf-8")):
        if cells[:1] == ["编号"]:
            if cells != COLS:
                problems.append({"key": f"ledger:header:{no}", "text": f"账表头应为 {' / '.join(COLS)}"})
            continue
        if len(cells) != len(COLS):
            problems.append({"key": f"ledger:cols:{no}", "text": f"账第 {no} 行有 {len(cells)} 列，应为 {len(COLS)} 列"})
            continue
        it = dict(zip(COLS, cells), 行=no)
        code, bad = it["编号"], []
        if not re.fullmatch(r"T\d{2,}", code):
            bad.append("编号应为 T 加数字")
        if code in seen:
            bad.append("编号重复")
        seen.add(code)
        if not it["事"]:
            bad.append("没写事")
        if it["归谁"] not in OWNERS:
            bad.append("归谁只许 " + " / ".join(sorted(OWNERS)))
        if it["状态"] not in STATES:
            bad.append("状态只许 未结 / 在做 / 已结")
        if it["状态"] == "已结" and not it["做完证据"]:
            bad.append("已结要写做完证据")
        it["_due"] = due_kind(it["到期"], sts)
        if it["_due"] is None:
            bad.append(f"到期「{it['到期']}」不合格：只许「<段> 开工前 / 通过后」（段名在进度表里）或日期 YYYY-MM-DD")
        problems += [{"key": f"ledger:{code}:{b[:6]}", "text": f"账 {code}（第 {no} 行）：{b}"} for b in bad]
        items.append(it)
    return items, problems


def due_before(stage, items):
    return [it for it in items if it["状态"] != "已结" and it["_due"] == ("stage", stage, "开工前")]


def overdue(items, today):
    out = []
    for it in items:
        d = it["_due"]
        if it["状态"] != "已结" and d and d[0] == "date" and d[1] <= today:
            word = "今天到期" if d[1] == today else f"已过期 {(today - d[1]).days} 天"
            out.append({"key": f"due:{it['编号']}:{d[1]}", "code": it["编号"], "owner": it["归谁"],
                        "text": f"{it['编号']}（{it['归谁']}）{word}：{it['事'][:60]}"})
    return out


def rule_card_hits(sts):
    """规则卡不放现状：同一句里有段名（含 S1a 的前缀 S1），又有「停在 / 还没 / 已做完 / 已通过 / 未开始 / 正在 / 等 S2」。只提醒。"""
    names = {s[:i] for s in sts for i in range(2, len(s) + 1) if re.fullmatch(r"[A-Z]+\d+[a-z]*", s[:i])}
    if not names:
        return []
    alt = "|".join(sorted(map(re.escape, names), key=len, reverse=True))
    name_re = re.compile(rf"(?<![A-Za-z0-9])(?:{alt})(?![A-Za-z0-9])")
    wait_re = re.compile(rf"等\s*(?:{alt})(?![A-Za-z0-9])")
    words = ("停在", "还没", "已做完", "已通过", "未开始", "正在")
    hits = []
    for card in (c for c in RULE_CARDS if c.exists()):
        for s in re.split(r"[。；;\n]", card.read_text(encoding="utf-8")):
            if name_re.search(s) and (any(w in s for w in words) or wait_re.search(s)):
                short = s.strip()[:50]
                hits.append({"key": f"card:{card.name}:{short}", "text": f"规则卡 {card.name} 里像是现状句：「{short}」"})
    return hits


def handoff_problems(codes, closed):
    out = []
    for f in sorted(ROOT.glob("交接_最新*.md")):
        text, name, secs, cur = f.read_text(encoding="utf-8"), f.name, {}, None
        for line in text.splitlines():
            if line.startswith("## "):
                cur = next((m for m in HANDOFF_SECTIONS if m in line), None)
                secs.setdefault(cur, [])
            elif cur:
                secs[cur].append(line)
        out += [{"key": f"handoff:{name}:缺{m}", "text": f"交接 {name} 缺第{m}节"} for m in HANDOFF_SECTIONS if m not in secs]
        n = len(re.sub(r"\s", "", text))
        if n > HANDOFF_MAX:
            out.append({"key": f"handoff:{name}:超长", "text": f"交接 {name} 约 {n} 字，超过 {HANDOFF_MAX} 字提醒线"})
        for mark in ("③", "④"):
            body = "\n".join(secs.get(mark, []))
            bad = [w for w in HANDOFF_BANNED if w in body] + re.findall(r"交接_(?!最新)\S+?\.md", body)
            if bad:
                out.append({"key": f"handoff:{name}:{mark}", "text": f"交接 {name} 第{mark}节指了旧交接或「{bad[0]}」"})
        steps = []
        for line in secs.get("③", []):
            if re.match(r"\d+\.\s", line):
                steps.append([line])
            elif steps:
                steps[-1].append(line)
        for i, st in enumerate(steps, 1):
            body = "\n".join(st)
            if "算对：" not in body:
                out.append({"key": f"handoff:{name}:算对:{i}", "text": f"交接 {name} 第③节第 {i} 步没有「算对：」行"})
            for code in re.findall(r"T\d{2,}", body):
                if code not in codes:
                    out.append({"key": f"handoff:{name}:引用错:{code}", "text": f"交接 {name} 第③节引用了账上没有的 {code}"})
                elif code in closed:
                    out.append({"key": f"handoff:{name}:已结:{code}", "text": f"交接 {name} 第③节的 {code} 账上已结，交接该更新"})
    return out


def add_item(thing, source, owner, due):
    thing = thing.replace("|", "/").replace("\n", " ")
    with open(LEDGER, "a+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        text = f.read()
        for _, cells in table_rows(text):
            if len(cells) == len(COLS) and cells[1] == thing and cells[5] != "已结":
                return cells[0]
        nums = [int(m) for m in re.findall(r"^\| T(\d+) \|", text, re.M)]
        code = f"T{(max(nums) + 1 if nums else 1):02d}"
        f.write(("" if not text or text.endswith("\n") else "\n") + f"| {code} | {thing} | {source} | {owner} | {due} | 未结 | |\n")
        return code


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=60).stdout.strip()


def recheck(stage, manual):
    text = Path(manual).read_text(encoding="utf-8")
    m = re.search(rf"{re.escape(stage)}\s*核对主干[：:]\s*([0-9a-f]{{7,40}})", text) or \
        re.search(r"^[^A-Za-z\n]*核对主干[：:]\s*([0-9a-f]{7,40})", text, re.M)
    if not m:
        return "none", []
    base = m.group(1)
    if not git("rev-parse", "--verify", "-q", base + "^{commit}"):
        return "stop", [f"核对提交 {base} 在仓库里找不到"]
    tracked = git("-c", "core.quotepath=off", "ls-files").splitlines()
    named = set()
    for tok in re.findall(r"`([^`\s]+\.(?:py|js|jsx|ts|tsx|vue|go|rs|java|rb|php|sql|sh|md|json|ya?ml|toml|txt))(?::\d+)?`", text):
        named.update(t for t in tracked if t == tok or t.endswith("/" + tok))
    named.discard(os.path.relpath(Path(manual).resolve(), ROOT))
    log = git("log", "--oneline", f"{base}..HEAD", "--", *sorted(named)).splitlines() if named else []
    if not log:
        return "ok", []
    age = (datetime.datetime.now() - datetime.datetime.fromtimestamp(int(git("show", "-s", "--format=%ct", base) or 0))).days
    head = [f"手册按 {base[:8]} 核对（{age} 天前），之后它点名的文件有 {len(log)} 个提交："] + log[:15]
    return ("stop" if age >= RECHECK_DAYS or len(log) >= RECHECK_COMMITS else "note"), head


def report(today):
    sts = stages()
    items, fmt = parse_ledger(sts)
    codes = {it["编号"] for it in items}
    closed = {it["编号"] for it in items if it["状态"] == "已结"}
    res = {"at": datetime.datetime.now().isoformat(timespec="seconds"), "open": len(codes - closed),
           "format": fmt, "due": overdue(items, today), "cards": [], "handoff": [], "error": []}
    for key, fn in (("cards", lambda: rule_card_hits(sts)), ("handoff", lambda: handoff_problems(codes, closed))):
        try:
            res[key] = fn()
        except Exception as err:  # noqa: BLE001 检查器自己出错单报，不当成到期
            res["error"].append({"key": f"error:{key}", "text": f"本轮 {key} 检查没做完：{type(err).__name__}: {err}"})
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--due", metavar="段")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--add", nargs=4, metavar=("事", "出处", "归谁", "到期"))
    ap.add_argument("--recheck", nargs=2, metavar=("段", "手册"))
    ap.add_argument("--out")
    ap.add_argument("--today")
    a = ap.parse_args()
    if a.add:
        print(add_item(*a.add))
        return 0
    if a.recheck:
        try:
            kind, lines = recheck(*a.recheck)
        except Exception as err:  # noqa: BLE001 核对没做完不拦流水线
            kind, lines = "none", [f"核对没做完：{err}"]
        print("\n".join([kind] + lines))
        return 0
    if a.due:
        try:
            items, _ = parse_ledger(stages())
        except Exception as err:  # noqa: BLE001 账读不了不拦流水线，只打一行
            print(f"账检查没做完：{err}")
            return 0
        hit = due_before(a.due, items)
        for it in hit:
            print(f"{it['编号']}（{it['归谁']}）：{it['事']}")
        return 3 if hit else 0
    data = json.dumps(report(datetime.date.fromisoformat(a.today) if a.today else datetime.date.today()), ensure_ascii=False, indent=1)
    if a.out:
        tmp = Path(a.out + ".tmp")
        tmp.write_text(data, encoding="utf-8")
        tmp.replace(a.out)
    else:
        print(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
