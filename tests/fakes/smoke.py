"""假冒烟：python3 scripts/smoke.py <子阶段>，按 FAKE_SMOKE 写 运行数据/smoke_<子阶段>.json。
pass（默认）全过；fail 一直 a 步失败；outage 前 3 次连不上、之后过；flaky 第 1 次 a 步失败、之后过。"""
import json, os, sys
stage = sys.argv[1]
mode = os.environ.get("FAKE_SMOKE", "pass")
cf = f"运行数据/fake_smoke_count_{stage}"
n = int(open(cf).read()) + 1 if os.path.exists(cf) else 1
open(cf, "w").write(str(n))
bad = {"fail": True, "outage": n <= 3, "flaky": n == 1}.get(mode, False)
err = "ConnectError: timed out" if mode == "outage" else "AssertionError: a 步结果不对"
step = {"name": "a", "status": "FAIL" if bad else "PASS", "error": err if bad else ""}
json.dump({"status": "FAIL" if bad else "PASS", "steps": [step]}, open(f"运行数据/smoke_{stage}.json", "w"))
