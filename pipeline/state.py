"""读写 项目状态.md 的子阶段进度表。表格行格式必须是：| S1 名称 | 状态 | 通过日期 |
用法（在任何目录都行）：
  state.py current        -> 打印 "S1|未开始"（第一个还没通过的子阶段）；全部通过打印 DONE
  state.py status S1      -> 打印该子阶段状态
  state.py name S1        -> 打印该子阶段名称
  state.py next S1        -> 打印进度表里 S1 下一行的编号（没有就打印空）
  state.py set S1 待验收   -> 改状态；改成「已通过…」时自动填日期；同时刷新「最近更新」
状态文件：环境变量 STATE_FILE；默认 本脚本目录/../项目状态.md。
子阶段编号前缀：环境变量 STAGE_PREFIX，默认 S（决策台账的 D1、D2 不会被当成子阶段）。
"""
import datetime
import os
import re
import sys
from pathlib import Path

STATUS = Path(os.environ.get("STATE_FILE") or Path(__file__).resolve().parents[1] / "项目状态.md")
PREFIX = os.environ.get("STAGE_PREFIX", "S")
PASSED = ("已通过", "已通过·待 AI 产品经理亲验")
ROW = re.compile(rf"^\|\s*({re.escape(PREFIX)}\d+)\s+([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$")


def rows():
    out = []
    for i, line in enumerate(STATUS.read_text(encoding="utf-8").split("\n")):
        m = ROW.match(line)
        if m:
            out.append((i, m.group(1), m.group(2).strip(), m.group(3).strip(), m.group(4).strip()))
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "current":
        for _, sid, _, status, _ in rows():
            if status not in PASSED:
                print(f"{sid}|{status}")
                return
        print("DONE")
    elif cmd == "status":
        print(next(s for _, sid, _, s, _ in rows() if sid == sys.argv[2]))
    elif cmd == "name":
        print(next(n for _, sid, n, _, _ in rows() if sid == sys.argv[2]))
    elif cmd == "next":
        ids = [sid for _, sid, _, _, _ in rows()]
        i = ids.index(sys.argv[2])
        print(ids[i + 1] if i + 1 < len(ids) else "")
    elif cmd == "set":
        sid, status = sys.argv[2], sys.argv[3]
        lines = STATUS.read_text(encoding="utf-8").split("\n")
        for i, s, name, _old, date in rows():
            if s == sid:
                if status.startswith("已通过") and not date:
                    date = datetime.date.today().isoformat()
                lines[i] = f"| {s} {name} | {status} | {date} |"
        text = "\n".join(lines)
        text = re.sub(r"- 最近更新：.*", f"- 最近更新：{datetime.date.today().isoformat()}", text, count=1)
        STATUS.write_text(text, encoding="utf-8")
        print(f"{sid} -> {status}")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
