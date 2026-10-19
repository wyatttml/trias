"""计数定级：把一轮程序检查的结果算成「过没过、第几级返工、是不是服务故障、有没有偶发可放行」。通用，一般不用改。
用法：
  tally.py retry  <冒烟结果.json>   退出码 0 = 这次冒烟值得重跑（没过、且没过的步不超过 SMOKE_RETRY_STEPS 步）
  tally.py finish <子阶段>          checks.sh 跑完后由 run.sh 调用：读 accept_<子阶段>.json，合并冒烟、回归，写回结论

accept_<子阶段>.json 由 checks.sh 写，至少含 {"stage", "items": {"项名": "pass" | "fail"}, "numbers": {...}}。
finish 再并入两样（都可以没有）：
  冒烟：运行数据/pipeline/smoke_<子阶段>_run1.json、run2、run3（checks.sh 每跑一次存一份）。
       结果 JSON 顶层 status 为 PASS / FAIL；可选 steps（列表 [{"name","status","error"}] 或字典 {步名: {"status","error"}}）。
       「三中取二、过了直接过」：第一次就过的步算过；没过的步看后两次，两次都过算过（偶发，记 flaky_steps），否则算真失败。
  回归：运行数据/pipeline/regress_<子阶段>.json：{"samples": {"样品": {"ok": true, "file": "成品路径", "error": "..."}}}。
       每件记为 regress:<样品>；和 regress_prev.json（上一段通过时的那份）配成并排清单 side_by_side，给验收员对照看。
写回的字段：
  passed            全部项过了才是 true（偶发后过了的冒烟步、被放行的偶发失败算过）
  escalation_level  当前没过的项里，累计真失败次数最多的那个次数（0 = 全过）。1 执行模型修，2 先出检查单，3 验收模型亲修，4 转方案模型
  service_outage    真失败里有连接类错误（超时、429、5xx、连不上…），且全量测试、密钥扫描都过：等服务恢复原样重跑，不计数
  flaky_allowed     偶发失败放行的项：名字以 FLAKY_PREFIXES 开头、上一批过了、本段第一次坏，且别的项全过
计数存 fail_counts_<子阶段>.json（只加不清）；各项上一次结果存 last_items.json。
可调环境变量：SMOKE_RETRY_STEPS（默认 2）、FLAKY_PREFIXES（空格分隔，默认 "regress:"；设成空就不放行）、
OUTAGE_PATTERN（连接类错误的正则，大小写不敏感）。
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("TRIAS_ROOT") or Path(__file__).resolve().parents[1])
D = ROOT / "运行数据/pipeline"
RETRY_STEPS = int(os.environ.get("SMOKE_RETRY_STEPS", "2"))
FLAKY_PREFIXES = tuple(os.environ.get("FLAKY_PREFIXES", "regress:").split())
OUTAGE = re.compile(os.environ.get(
    "OUTAGE_PATTERN",
    r"timed? ?out|timeout|connect(ion)?[ _]?(error|refused|reset|aborted)|unavailable|\b429\b|\b5\d\d\b"
    r"|rate.?limit|tls|ssl|name or service not known|temporary failure|network is unreachable"), re.I)
DETERMINISTIC = ("tests", "secrets")   # 这两项坏了就不可能是服务故障


def load(p, default=None):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 文件没有或坏了都当没有
        return default


def save(p, data):
    Path(p).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def steps_of(run):
    """一次冒烟结果 → {步名: (过没过, 错误文字)}；没有 steps 就把整次当一步 smoke。"""
    if not isinstance(run, dict):
        return {}
    st = run.get("steps")
    out = {}
    if isinstance(st, dict):
        st = [dict(v, name=k) if isinstance(v, dict) else {"name": k, "status": v} for k, v in st.items()]
    if isinstance(st, list) and st:
        for s in st:
            if isinstance(s, dict) and s.get("name"):
                out[str(s["name"])] = (str(s.get("status", "")).upper() in ("PASS", "OK", "TRUE"),
                                       str(s.get("error") or s.get("detail") or ""))
        if out:
            return out
    return {"smoke": (str(run.get("status", "")).upper() == "PASS", str(run.get("error") or ""))}


def cmd_retry(path):
    run = load(path)
    if not run or str(run.get("status", "")).upper() == "PASS":
        return 1
    failed = [k for k, (ok, _) in steps_of(run).items() if not ok]
    return 0 if 0 < len(failed) <= RETRY_STEPS else 1


def merge_smoke(stage, items, numbers):
    runs = [load(D / f"smoke_{stage}_run{i}.json") for i in (1, 2, 3)]
    if runs[0] is None:
        if "smoke" not in items:
            items["smoke"] = "fail"
        numbers.setdefault("smoke", {})["status"] = numbers.get("smoke", {}).get("status") or "缺冒烟结果"
        return {}
    first, later = steps_of(runs[0]), [steps_of(r) for r in runs[1:] if r is not None]
    flaky, true_failed, errors = [], [], {}
    for name, (ok, err) in first.items():
        if ok:
            items[f"smoke:{name}"] = "pass"
            continue
        if len(later) == 2 and all(name in r and r[name][0] for r in later):
            items[f"smoke:{name}"] = "pass"
            flaky.append(name)
            continue
        items[f"smoke:{name}"] = "fail"
        true_failed.append(name)
        errors[name] = " ".join([err] + [r[name][1] for r in later if name in r])
    items.pop("smoke", None)
    numbers["smoke"] = {"status": "FAIL" if true_failed else "PASS", "runs": 1 + len(later),
                        "flaky_steps": flaky, "true_failed_steps": true_failed}
    return {f"smoke:{k}": v for k, v in errors.items()}


def merge_regress(stage, items, numbers):
    cur = load(D / f"regress_{stage}.json")
    if not cur:
        return {}
    prev = (load(D / "regress_prev.json") or {}).get("samples", {})
    errors, pairs = {}, []
    for sid, s in (cur.get("samples") or {}).items():
        ok = bool(s.get("ok"))
        items[f"regress:{sid}"] = "pass" if ok else "fail"
        if not ok:
            errors[f"regress:{sid}"] = str(s.get("error") or "")
        if s.get("file"):
            pairs.append({"id": sid, "previous": (prev.get(sid) or {}).get("file"), "current": s["file"]})
    numbers["regress"] = {"samples": len(cur.get("samples") or {}),
                          "bad_samples": [k[8:] for k, v in items.items() if k.startswith("regress:") and v == "fail"],
                          "side_by_side": pairs}
    return errors


def cmd_finish(stage):
    acc_path = D / f"accept_{stage}.json"
    acc = load(acc_path)
    if acc is None:
        print(f"没有 {acc_path}，不算", file=sys.stderr)
        return 1
    items = {k: ("pass" if v in ("pass", True) else "fail") for k, v in (acc.get("items") or {}).items()}
    numbers = acc.setdefault("numbers", {})
    errors = merge_smoke(stage, items, numbers)
    errors.update(merge_regress(stage, items, numbers))
    failing = [k for k, v in items.items() if v == "fail"]

    outage = bool(failing) and not any(k in DETERMINISTIC for k in failing) \
        and any(OUTAGE.search(errors.get(k, "")) for k in failing)

    counts_path = D / f"fail_counts_{stage}.json"
    counts = load(counts_path, {})
    history = load(D / "last_items.json", {})
    allowed = []
    if not outage and failing and FLAKY_PREFIXES:
        cand = [k for k in failing if k.startswith(FLAKY_PREFIXES) and counts.get(k, 0) == 0 and history.get(k) == "pass"]
        if cand and len(cand) == len(failing):
            allowed = cand
    if not outage:
        for k in failing:
            if k not in allowed:
                counts[k] = counts.get(k, 0) + 1
        save(counts_path, counts)
        history.update(items)
        save(D / "last_items.json", history)
    real = [k for k in failing if k not in allowed]
    acc.update({"items": items, "passed": not real, "failed_items": real, "flaky_allowed": allowed,
                "service_outage": outage, "escalation_level": max([counts.get(k, 1) for k in real], default=0)})
    save(acc_path, acc)
    print(json.dumps({k: acc[k] for k in ("passed", "failed_items", "escalation_level", "service_outage", "flaky_allowed")},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "retry":
        sys.exit(cmd_retry(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "finish":
        sys.exit(cmd_finish(sys.argv[2]))
    raise SystemExit(__doc__)
