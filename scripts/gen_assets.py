#!/usr/bin/env python3
"""生成 assets/ 下的三张图：banner.svg、demo.svg、social-preview.png。改图改这里，不要手改 assets/。

用法：python3 scripts/gen_assets.py            三张都生成（PNG 要本机有 Chrome / Chromium）
      python3 scripts/gen_assets.py --no-png   只生成两张 SVG
Python 直接写 SVG；PNG 用 Chrome headless 截图。社交预览图换了要到 GitHub 仓库 Settings 手动上传。
demo.svg 回放的是 tests/ 里假模型跑出的 pipeline.log（场景一，节选）和对应的邮件；日志格式变了就照新日志改 DEMO_LINES。
"""
import os
import shutil
import subprocess
import sys
import tempfile
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
A = ROOT / "assets"

SERIF = "Georgia,'Times New Roman','Songti SC','Noto Serif CJK SC',serif"
SANS = "'PingFang SC','Hiragino Sans GB','Noto Sans CJK SC','Microsoft YaHei',sans-serif"
MONO = "'SF Mono',Menlo,Consolas,'PingFang SC','Noto Sans CJK SC',monospace"
GOLD, CREAM, GPT, OPUS = "#C9A063", "#F5E6C8", "#10A37F", "#D97757"

PILLS = ["≈380 行 bash", "零依赖", "无人值守", "卡住才发邮件"]
COLUMNS = [("立法", "Fable", "写手册", OPUS), ("执行", "GPT · Codex", "写代码", GPT), ("司法", "Opus", "做验收", OPUS)]


def text_width(s, size):
    """粗估文字宽度：中文按 1 个字号，其余按 0.56 个字号。"""
    return sum(size if ord(c) > 0x2E80 else size * 0.56 for c in s)


def defs():
    return f'''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0B1020"/><stop offset="1" stop-color="#1C2547"/></linearGradient>
  <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F3D9A4"/><stop offset="1" stop-color="{GOLD}"/></linearGradient>
  <radialGradient id="glow" cx="0.78" cy="0.35" r="0.55"><stop offset="0" stop-color="#3A4C8F" stop-opacity="0.55"/><stop offset="1" stop-color="#0B1020" stop-opacity="0"/></radialGradient>
</defs>'''


def left_block():
    out = [f'<text x="72" y="132" font-family="{SERIF}" font-size="104" font-weight="bold" fill="{CREAM}" letter-spacing="2">Trias</text>',
           f'<text x="76" y="190" font-family="{SANS}" font-size="36" font-weight="bold" fill="#FFFFFF">三权分立的 AI 开发流水线</text>',
           f'<text x="76" y="232" font-family="{SERIF}" font-size="21" font-style="italic" fill="#9AA6CF">Separation of powers for coding agents.</text>',
           f'<text x="76" y="282" font-family="{SANS}" font-size="20" fill="#C9D0EA">一个模型立法，一个模型执行，另一家的模型司法。</text>',
           f'<text x="76" y="312" font-family="{SANS}" font-size="20" fill="#C9D0EA">你只管看邮件。</text>']
    x = 76.0
    for p in PILLS:
        w = round(text_width(p, 17) + 34)
        out.append(f'<rect x="{x:.1f}" y="344" width="{w}" height="35" rx="18" fill="#FFFFFF" fill-opacity=".07" stroke="#FFFFFF" stroke-opacity=".18"/>')
        out.append(f'<text x="{x + w / 2:.1f}" y="365" font-family="{SANS}" font-size="17" fill="#DCE2F5" text-anchor="middle">{escape(p)}</text>')
        x += w + 12
    return "\n".join(out)


def temple():
    out = ['<path d="M740.0 125.0 L975.0 55.0 L1210.0 125.0 Z" fill="url(#gold)" opacity=".95"/>',
           '<path d="M780.0 117.0 L975.0 69.0 L1170.0 117.0 Z" fill="#0F1630" opacity=".55"/>',
           f'<text x="975" y="110" font-family="{SERIF}" font-size="22" fill="{CREAM}" text-anchor="middle" letter-spacing="6">TRIAS</text>',
           '<rect x="750" y="129" width="450" height="18" rx="3" fill="url(#gold)"/>']
    for cx, (power, who, does, c) in zip((815, 975, 1135), COLUMNS):
        out += [f'<rect x="{cx - 38}" y="151" width="76" height="12" rx="2" fill="{c}"/>',
                f'<rect x="{cx - 28}" y="163" width="56" height="150" fill="{c}" opacity=".18" stroke="{c}" stroke-width="2"/>']
        out += [f'<line x1="{cx + d}" y1="169" x2="{cx + d}" y2="307" stroke="{c}" stroke-width="2" opacity=".55"/>' for d in (-14, 0, 14)]
        out += [f'<text x="{cx}" y="233" font-family="{SANS}" font-size="26" font-weight="bold" fill="#FFFFFF" text-anchor="middle" writing-mode="tb">{power}</text>',
                f'<rect x="{cx - 38}" y="313" width="76" height="12" rx="2" fill="{c}"/>',
                f'<text x="{cx}" y="353" font-family="{SANS}" font-size="17" font-weight="600" fill="{c}" text-anchor="middle">{escape(who)}</text>',
                f'<text x="{cx}" y="377" font-family="{SANS}" font-size="15" fill="#AEB6D3" text-anchor="middle">{does}</text>']
    return "\n".join(out)


def banner(w=1280, h=440, rx=24, dy_left=0, temple_tf=""):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="Trias：三权分立的 AI 开发流水线">
{defs()}
<rect width="{w}" height="{h}" rx="{rx}" fill="url(#bg)"/>
<rect width="{w}" height="{h}" rx="{rx}" fill="url(#glow)"/>
<g transform="translate(0 {dy_left})">
{left_block()}
</g>
<g transform="{temple_tf}">
{temple()}
</g>
</svg>
'''


# 行：(缩进, 颜色, 粗细, 文字)。邮件行缩进；颜色按事件类型。
DIM, TXT, DEV, ACC, OK, WARN, MAIL, CMD = "#8B949E", "#C9D1D9", "#39C5CF", "#F0883E", "#56D364", "#E3B341", "#F0A6CA", "#E6EDF3"
DEMO_LINES = [
    (0, CMD, 700, "$ bash pipeline/run.sh"),
    (0, DIM, 400, "流水线启动 开发=gpt-6-astra（沙箱 workspace-write） 验收=claude-opus-5-5 返工上限=4"),
    (0, TXT, 600, "当前 S1 需求解析 状态=未开始"),
    (0, DEV, 400, "开发模型开工 S1"),
    (0, DIM, 400, "程序检查 checks.sh S1"),
    (0, DIM, 400, '计数定级：{"passed": true, "escalation_level": 0, "service_outage": false}'),
    (0, ACC, 400, "验收模型开工 S1"),
    (0, OK, 700, "S1 -> 已通过"),
    (1, MAIL, 600, "✉  邮件 · S1 需求解析 验收通过"),
    (0, TXT, 600, "当前 S2 检索接口 状态=未开始"),
    (0, DEV, 400, "开发模型开工 S2"),
    (0, DIM, 400, "程序检查 checks.sh S2"),
    (0, ACC, 400, "验收模型开工 S2"),
    (0, WARN, 700, "返工 S2"),
    (1, MAIL, 600, "✉  邮件 · S2 检索接口 判返工（第 1 次验收）"),
    (0, WARN, 700, "当前 S2 检索接口 状态=返工中"),
    (0, WARN, 400, "返工级别 1（第 1 轮）"),
    (0, DEV, 400, "开发模型开工 S2"),
    (0, DIM, 400, "程序检查 checks.sh S2"),
    (0, ACC, 400, "验收模型开工 S2"),
    (0, OK, 700, "S2 -> 已通过"),
    (1, MAIL, 600, "✉  邮件 · S2 检索接口 验收通过"),
    (0, TXT, 600, "当前 S3 导出报告 状态=未开始"),
    (0, DEV, 400, "开发模型开工 S3"),
    (0, DIM, 400, "程序检查 checks.sh S3"),
    (0, ACC, 400, "验收模型开工 S3"),
    (0, OK, 700, "S3 -> 已通过·待 AI 产品经理亲验"),
    (1, MAIL, 600, "✉  邮件 · S3 导出报告 验收通过"),
    (0, OK, 700, "全部子阶段已通过"),
    (1, MAIL, 600, "✉  邮件 · 流水线全部完成"),
]


def demo(cycle=15.8):
    n = len(DEMO_LINES)
    w, h = 900, 76 + 21 * (n - 1) + 35
    step = 72.0 / n            # 最后一行在约 72% 处出现，停到 96% 一起淡出，再循环
    css = []
    for i in range(n):
        s = i * step
        css.append(f"@keyframes k{i}{{0%,{s:.2f}%{{opacity:0}}{s + 0.6:.2f}%,96%{{opacity:1}}100%{{opacity:0}}}}.l{i}{{animation:k{i} {cycle}s linear infinite}}")
    css.append("@media (prefers-reduced-motion: reduce){text{animation:none!important;opacity:1!important}}")
    rows = []
    for i, (ind, c, wt, t) in enumerate(DEMO_LINES):
        rows.append(f'<text class="l{i}" x="{44 if ind else 26}" y="{76 + 21 * i}" fill="{c}" font-weight="{wt}">{escape(t)}</text>')
    title = "pipeline.log — 3 个子阶段 · 1 次返工 · 0 次人工介入"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="Trias 流水线运行日志回放">
<style>{"".join(css)}</style>
<rect width="{w}" height="{h}" rx="14" fill="#0D1117"/>
<rect width="{w}" height="40" rx="14" fill="#161B22"/>
<rect y="26" width="{w}" height="14" fill="#161B22"/>
<circle cx="24" cy="20" r="6.5" fill="#FF5F57"/><circle cx="46" cy="20" r="6.5" fill="#FEBC2E"/><circle cx="68" cy="20" r="6.5" fill="#28C840"/>
<text x="{w / 2:.0f}" y="25" font-family="{MONO}" font-size="13" fill="#8B949E" text-anchor="middle">{escape(title)}</text>
<g font-family="{MONO}" font-size="14.5">
{chr(10).join(rows)}
</g>
</svg>
'''


def find_chrome():
    for c in (os.environ.get("CHROME"), "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              "/Applications/Chromium.app/Contents/MacOS/Chromium"):
        if c and os.path.exists(c):
            return c
    for name in ("google-chrome", "chromium", "chromium-browser", "chrome"):
        if shutil.which(name):
            return shutil.which(name)
    return None


def social_png(out):
    """社交预览图 1280x640、不要圆角：banner 同一套元素，左侧下移，神庙放大 1.25 倍放在右侧。"""
    chrome = find_chrome()
    if not chrome:
        print("没找到 Chrome / Chromium（可设 CHROME=路径），跳过 social-preview.png")
        return
    svg = banner(1280, 640, 0, dy_left=78, temple_tf="translate(-304 45) scale(1.25)")
    with tempfile.TemporaryDirectory() as d:
        page = Path(d) / "p.html"
        page.write_text(f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;background:#0B1020}}</style>{svg}', encoding="utf-8")
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=1280,640", f"--screenshot={out}", page.as_uri()],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("写好", out)


def main():
    A.mkdir(exist_ok=True)
    (A / "banner.svg").write_text(banner(), encoding="utf-8")
    (A / "demo.svg").write_text(demo(), encoding="utf-8")
    print("写好", A / "banner.svg", A / "demo.svg")
    if "--no-png" not in sys.argv:
        social_png(A / "social-preview.png")


if __name__ == "__main__":
    main()
