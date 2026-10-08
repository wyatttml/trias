#!/bin/bash
# 程序检查（按你的项目改这一个文件）。流水线在开发模型收尾后调用：bash pipeline/checks.sh S1
# 职责：把能用程序量出来的事量出来，写成 运行数据/pipeline/accept_<stage>.json，至少含 {"stage","passed","numbers"}。
# 验收模型只读这个文件，不重跑测试。这里示范三项：全量测试、本阶段真实冒烟、密钥扫描。
set -u
stage="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/运行数据/pipeline"
mkdir -p "$D"
cd "$ROOT"

# 1. 全量测试（换成你的命令：npm test、go test ./...、pytest …）
tests_rc=0
python3 -m pytest -q > "$D/tests_$stage.log" 2>&1 || tests_rc=$?

# 2. 本阶段真实冒烟：开发模型按手册写 scripts/smoke_<stage>.py，结果写 运行数据/smoke_<stage>.json，顶层 status 为 PASS/FAIL
smoke_rc=0; smoke_status="缺冒烟脚本"
if [ -f "scripts/smoke_$stage.py" ]; then
  python3 "scripts/smoke_$stage.py" > "$D/smoke_$stage.log" 2>&1 || smoke_rc=$?
  smoke_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", "缺结果文件"))' "运行数据/smoke_$stage.json" 2>/dev/null || echo 缺结果文件)"
fi

# 3. 密钥扫描：.env 里名字含 KEY/SECRET/PASSWORD/TOKEN 的值，取前 12 位在代码里找；命中数写进结果，值本身永不输出
secret_hits=0
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    case "$k" in *KEY*|*SECRET*|*PASSWORD*|*TOKEN*) ;; *) continue;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ "${#v}" -ge 12 ] || continue
    n="$(grep -rIl --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules --exclude-dir=运行数据 --exclude=.env -F -- "${v:0:12}" . 2>/dev/null | wc -l | tr -d ' ')"
    secret_hits=$(( secret_hits + n ))
  done < .env
fi

python3 - "$stage" "$tests_rc" "$smoke_rc" "$smoke_status" "$secret_hits" "$D" <<'PY'
import json, sys
stage, trc, src, sstat, hits, D = sys.argv[1:7]
passed = trc == "0" and sstat.upper() == "PASS" and hits == "0"
result = {"stage": stage, "passed": passed,
          "numbers": {"tests_exit": int(trc), "smoke_exit": int(src), "smoke_status": sstat, "secret_hits": int(hits)},
          "logs": [f"运行数据/pipeline/tests_{stage}.log", f"运行数据/pipeline/smoke_{stage}.log"]}
open(f"{D}/accept_{stage}.json", "w", encoding="utf-8").write(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result["numbers"], ensure_ascii=False))
sys.exit(0 if passed else 1)
PY
