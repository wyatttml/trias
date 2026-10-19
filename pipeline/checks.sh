#!/bin/bash
# 程序检查（按你的项目改这一个文件）。流水线在开发模型收尾后调用：bash pipeline/checks.sh S1
# 职责：把能用程序量出来的事量出来，写成 运行数据/pipeline/accept_<stage>.json：
#   {"stage", "items": {"项名": "pass" | "fail"}, "numbers": {...}, "logs": [...]}
# 之后 run.sh 会调 tally.py 合并冒烟、回归，算出 passed、返工级别、服务故障、偶发放行。验收模型只读结果，不重跑。
# 这里示范：全量测试、本阶段真实冒烟（三中取二）、密钥扫描，外加一个可选的回归集钩子。
set -u
stage="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/pipeline"; D="$ROOT/运行数据/pipeline"
mkdir -p "$D"
cd "$ROOT"
TEST_CMD="${TEST_CMD:-python3 -m pytest -q}"   # 换成你的命令：npm test、go test ./...、cargo test …

# 1. 全量测试（只在这里跑一次；开发模型只跑和改动相关的测试）
tests_rc=0
bash -c "$TEST_CMD" > "$D/tests_$stage.log" 2>&1 || tests_rc=$?

# 2. 本阶段真实冒烟：开发模型按手册写 scripts/smoke_<stage>.py，结果写 运行数据/smoke_<stage>.json，
#    顶层 status 为 PASS/FAIL，可选 steps 每步记成败。没过且没过的步不多（默认 ≤2 步）就再跑两次，tally.py 按「三中取二」算
rm -f "$D/smoke_${stage}"_run*.json
smoke(){ # $1 第几次
  rm -f "运行数据/smoke_$stage.json"
  python3 "scripts/smoke_$stage.py" >> "$D/smoke_$stage.log" 2>&1
  cp "运行数据/smoke_$stage.json" "$D/smoke_${stage}_run$1.json" 2>/dev/null || true
}
if [ -f "scripts/smoke_$stage.py" ]; then
  : > "$D/smoke_$stage.log"
  smoke 1
  if python3 "$P/tally.py" retry "$D/smoke_${stage}_run1.json"; then smoke 2; smoke 3; fi
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

# 4.（可选）回归集：每段都把一组固定样品重新做一遍，和上一段通过时的成品并排给验收员看。
#    你的脚本写 运行数据/pipeline/regress_<stage>.json：{"samples": {"样品": {"ok": true, "file": "成品路径", "error": ""}}}
rm -f "$D/regress_$stage.json"
if [ -f scripts/regress.py ]; then python3 scripts/regress.py --stage "$stage" > "$D/regress_$stage.log" 2>&1 || true; fi

python3 - "$stage" "$tests_rc" "$secret_hits" "$D" <<'PY'
import json, sys
stage, trc, hits, D = sys.argv[1:5]
result = {"stage": stage,
          "items": {"tests": "pass" if trc == "0" else "fail", "secrets": "pass" if hits == "0" else "fail"},
          "numbers": {"tests_exit": int(trc), "secret_hits": int(hits)},
          "logs": [f"运行数据/pipeline/tests_{stage}.log", f"运行数据/pipeline/smoke_{stage}.log"]}
open(f"{D}/accept_{stage}.json", "w", encoding="utf-8").write(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result["numbers"], ensure_ascii=False))
PY
