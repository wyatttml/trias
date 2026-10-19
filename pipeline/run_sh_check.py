#!/usr/bin/env python3
"""改完 run.sh、重启前必跑（停了怎么办第 9 节）。三步，任一步不过就不要重启：
1. bash -n 语法；2. shellcheck -S error；3. 未赋值变量：run.sh 开了 set -u，引用过但整份脚本里从没赋值的变量，
运行到那行时会让流水线静默退出。用法：python3 pipeline/run_sh_check.py [run.sh 路径]"""
import re, shutil, subprocess, sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent / "run.sh")
text = path.read_text(encoding="utf-8")
ok = True

r = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
print("1. bash -n:", "过" if r.returncode == 0 else "不过\n" + r.stderr); ok &= r.returncode == 0

if shutil.which("shellcheck"):
    r = subprocess.run(["shellcheck", "-S", "error", "-f", "gcc", str(path)], capture_output=True, text=True)
    print("2. shellcheck -S error:", "过" if r.returncode == 0 else "不过\n" + r.stdout); ok &= r.returncode == 0
else:
    print("2. shellcheck 没装（Mac: brew install shellcheck；Linux: sudo apt install shellcheck），装好再跑"); ok = False

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
code = "\n".join(re.sub(r"(^|\s)#.*$", "", line) for line in text.splitlines())   # 去掉注释
code_refs = re.sub(r"'[^'\n]*'", "''", code)                                          # 单引号里不展开，去掉再找引用（sed 的 $p 之类）
refs = {}
for m in re.finditer(r"\$(\{?)(" + NAME + r")(:?[-+=?])?", code_refs):
    if m.group(1) and m.group(3):      # ${X:-默认} ${X:+…} ${X:=…} 这些带默认值的写法在 set -u 下是安全的
        continue
    refs.setdefault(m.group(2), code_refs.count("\n", 0, m.start()) + 1)


def statement_ends_after(src, i):
    """从赋值的 = 往后吃掉值（处理引号与 $( )），看这条语句是不是到此结束。
    `FOO=1 cmd` 这种前缀赋值只对那一条命令生效，不算全局赋值。"""
    n, depth, q = len(src), 0, None
    while i < n:
        c = src[i]
        if q:
            if c == "\\": i += 1
            elif c == q: q = None
        elif c in "\"'": q = c
        elif c == "\\": i += 1
        elif c == "(" : depth += 1
        elif c == ")" and depth: depth -= 1
        elif depth == 0 and (c.isspace() or c in ";|&)}"):
            break
        i += 1
    rest = src[i:].lstrip(" \t")
    return not rest or rest[0] in "\n;|&)}#"


assigned = set()
for m in re.finditer(r"(?<![A-Za-z0-9_$])(" + NAME + r")=", code):
    if statement_ends_after(code, m.end()):
        assigned.add(m.group(1))
for m in re.finditer(r"\b(?:local|declare|export|readonly)\b([^\n;|&]*)", code):
    assigned |= {w.split("=")[0] for w in m.group(1).split() if re.fullmatch(NAME + r"(=.*)?", w)}
assigned |= set(re.findall(r"\bfor\s+(" + NAME + r")\s+in", code))
assigned |= set(re.findall(r"\bread\s+(?:-[a-z]+\s+)*(" + NAME + ")", code))
assigned |= set(re.findall(r"\$\{(" + NAME + r"):=", code))
builtin = {"HOME", "PATH", "USER", "PWD", "OLDPWD", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LINENO", "BASH_COMMAND", "BASH_SOURCE",
           "FUNCNAME", "RANDOM", "SECONDS", "PIPESTATUS", "PPID", "BASHPID", "HOSTNAME", "IFS", "OPTARG", "OPTIND", "REPLY", "EPOCHSECONDS"}
missing = {v: ln for v, ln in refs.items() if v not in assigned and v not in builtin and not v.isdigit()}
if missing:
    print("3. 未赋值变量（set -u 下运行到就退出）:", ", ".join(f"{v}（第 {ln} 行首次引用）" for v, ln in sorted(missing.items(), key=lambda x: x[1])))
    ok = False
else:
    print("3. 未赋值变量: 无")
print("结论:", "可以重启" if ok else "不要重启，先改")
sys.exit(0 if ok else 1)
