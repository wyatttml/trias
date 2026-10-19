#!/usr/bin/env python3
"""Trias · 读大文件拦截（可选组件，Claude Code PreToolUse 钩子）。

主对话要读图片、PDF、超过 BIG_BYTES 的文件时直接拒绝，提示交给只读子代理（成品交 sample-viewer、日志交 log-digger），
主对话只收结论。大段原文和图片一进主对话就一直占着上下文，后面每一轮都要为它付费。
子代理、无人值守（--permission-mode bypassPermissions，流水线和值守的短会话都是）不拦。任何异常一律放行（fail open），绝不卡住对话。

装法：install.sh --full 会把本文件放到 .claude/hooks/，并打印要加进 .claude/settings.json 的片段：
  {"hooks": {"PreToolUse": [{"matcher": "Read|Bash", "hooks": [{"type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bigread_guard.py"}]}]}}
"""
import json
import os
import re
import sys

# ---------- 参数：按需改 ----------
BIG_BYTES = 200 * 1024        # 超过这么大的文件，主对话不整段读
READ_LIMIT_OK = 300           # Read 带 limit 且不超过这么多行，算只看片段，放行
MEDIA_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.heic', '.pdf', '.svg'}
READ_CMDS = re.compile(r'\b(cat|less|more|open|base64|xxd|hexdump|strings)\b')   # 整段读的命令
PEEK_CMDS = re.compile(r'\b(head|tail)\b')                                      # 看片段的命令：只拦图片 / PDF
MEDIA_HINT = '主对话不直接看图片 / PDF：交 sample-viewer 子代理，只收结论。'
BIG_HINT = '主对话不整段读大文件：日志交 log-digger，成品交 sample-viewer，只收结论；只看片段请加 limit，或用 head / tail / grep。'


def exempt(inp):
    return inp.get('permission_mode') == 'bypassPermissions' or bool(inp.get('agent_id'))


def is_media(path):
    return os.path.splitext(path)[1].lower() in MEDIA_EXT


def is_big(path):
    try:
        return os.path.getsize(path) > BIG_BYTES
    except OSError:
        return False


def reason(name, ti):
    if name == 'Read':
        p = ti.get('file_path', '')
        if is_media(p):
            return MEDIA_HINT
        if is_big(p) and not (ti.get('limit') and ti.get('limit') <= READ_LIMIT_OK):
            return BIG_HINT
        return None
    if name == 'Bash':
        cmd = ti.get('command', '')
        tokens = re.findall(r'[^\s\'"|;&<>()]+', cmd)
        files = [os.path.expanduser(t) for t in tokens if os.path.isfile(os.path.expanduser(t))]
        if not files:
            return None
        if READ_CMDS.search(cmd):
            if any(is_media(f) for f in files):
                return MEDIA_HINT
            if any(is_big(f) for f in files):
                return BIG_HINT
        elif PEEK_CMDS.search(cmd) and any(is_media(f) for f in files):
            return MEDIA_HINT
    return None


def main():
    try:
        inp = json.load(sys.stdin)
        if inp.get('hook_event_name') != 'PreToolUse' or exempt(inp):
            return
        r = reason(inp.get('tool_name', ''), inp.get('tool_input') or {})
        if r:
            print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                                                     'permissionDecision': 'deny',
                                                     'permissionDecisionReason': r}}, ensure_ascii=False))
    except Exception:
        pass


if __name__ == '__main__':
    main()
