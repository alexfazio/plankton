"""Extract hook-related text from mitmproxy captures of Claude Code API requests."""

import json

from mitmproxy import http


def request(flow: http.HTTPFlow):
    """Extract and print hook-related text from intercepted Claude API requests."""
    if "api.anthropic.com" not in flow.request.pretty_url:
        return
    if flow.request.method != "POST":
        return
    try:
        data = json.loads(flow.request.content.decode("utf-8"))
        messages = data.get("messages", [])
        system = data.get("system", "")

        # Check system prompt for hook text
        sys_str = json.dumps(system)
        if "[hook" in sys_str or "violation" in sys_str:
            print("!! HOOK TEXT IN SYSTEM PROMPT !!")
            blocks = system if isinstance(system, list) else [system]
            for i, block in enumerate(blocks):
                s = json.dumps(block) if not isinstance(block, str) else block
                if "[hook" in s or "violation" in s:
                    start = max(0, s.find("[hook") - 50) if "[hook" in s else max(0, s.find("violation") - 50)
                    print(f"  system block {i}: ...{s[start : start + 150]}...")

        # Check all messages
        for i, msg in enumerate(messages):
            role = msg.get("role", "?")
            content = msg.get("content", "")

            if isinstance(content, list):
                for j, item in enumerate(content):
                    if item.get("type") == "tool_result":
                        c = str(item.get("content", ""))
                        ie = item.get("is_error", "ABSENT")
                        has_hook = "[hook" in c or "violation" in c or "hook error" in c
                        print(f"MSG[{i}] TOOL_RESULT:")
                        print(f"  content (first 500): {c[:500]}")
                        print(f"  is_error: {ie}")
                        print(f"  HAS_HOOK_TEXT: {has_hook}")
                    elif item.get("type") == "text":
                        t = item.get("text", "")
                        if "[hook" in t or "violation" in t:
                            print(f"MSG[{i}][{j}] TEXT WITH HOOK: {t[:200]}")
            elif isinstance(content, str):
                if "[hook" in content or "violation" in content:
                    print(f"MSG[{i}] STRING WITH HOOK: {content[:200]}")

    except Exception as e:
        print(f"Parse error: {e}")
