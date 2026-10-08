"""通知脚本：Gmail 邮件（手机装 Gmail App 就能收推送）+ 可选 webhook。配置写在项目根 .env（已加 .gitignore）：
  GMAIL_USER=你的 Gmail 地址
  GMAIL_APP_PASSWORD=16 位应用专用密码（不是登录密码）
  NOTIFY_EMAIL=收件地址（不填就发给自己）
  可选：NOTIFY_WEBHOOK=https://...   NOTIFY_WEBHOOK_KIND=slack | feishu | wecom | raw（默认 raw：POST {"title","body"}）
走 smtp.gmail.com:587 + STARTTLS（很多本机代理挡 465）。缺配置就跳过，只写日志，永不报错。
用法：notify.py "标题" "正文"。发送记录在 运行数据/pipeline/日志/notify.log。
"""
import datetime
import json
import os
import smtplib
import ssl
import sys
import urllib.request
from email.mime.text import MIMEText
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "运行数据/pipeline/日志/notify.log"
CAFILE = "/etc/ssl/cert.pem"  # python.org 版 Python 自带证书库可能为空，优先用系统的
PREFIX = f"[{ROOT.name}流水线]"


def env():
    values = {}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip("\"'")
    return values


def mail(e, title, body):
    user, pwd = e.get("GMAIL_USER"), e.get("GMAIL_APP_PASSWORD", "").replace(" ", "")
    if not (user and pwd):
        return None
    to = e.get("NOTIFY_EMAIL") or user
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"], msg["From"], msg["To"] = f"{PREFIX} {title}", user, to
    ctx = ssl.create_default_context(cafile=CAFILE if os.path.exists(CAFILE) else None)
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
        s.starttls(context=ctx)
        s.login(user, pwd)
        s.sendmail(user, [to], msg.as_string())
    return "mail:ok"


def webhook(e, title, body):
    url = e.get("NOTIFY_WEBHOOK")
    if not url:
        return None
    kind = e.get("NOTIFY_WEBHOOK_KIND", "raw")
    text = f"{PREFIX} {title}\n{body}"
    payload = {
        "slack": {"text": text},
        "feishu": {"msg_type": "text", "content": {"text": text}},
        "wecom": {"msgtype": "text", "text": {"content": text}},
    }.get(kind, {"title": title, "body": body})
    req = urllib.request.Request(url, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                 {"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).read()
    return f"webhook:{kind}:ok"


def main():
    title = sys.argv[1]
    body = sys.argv[2] if len(sys.argv) > 2 else ""
    e = env()
    results = []
    for fn in (mail, webhook):
        try:
            r = fn(e, title, body)
            if r:
                results.append(r)
        except Exception as err:  # noqa: BLE001 通知失败不能把流水线搞死
            results.append(f"{fn.__name__}:fail:{type(err).__name__}")
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"at": datetime.datetime.now().isoformat(timespec="seconds"),
                            "title": title, "results": results}, ensure_ascii=False) + "\n")
    print(" ".join(results) or "no-channel")


if __name__ == "__main__":
    main()
