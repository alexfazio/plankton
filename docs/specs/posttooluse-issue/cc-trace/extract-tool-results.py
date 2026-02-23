"""Extract tool_result contents from mitmproxy captures."""

import json

from mitmproxy import http


def _process_item(i, j, item):
    if item.get("type") == "tool_result":
        tool_id = item.get("tool_use_id", "?")
        c = item.get("content", "")
        ie = item.get("is_error", "ABSENT")
        c_str = json.dumps(c) if not isinstance(c, str) else c
        has_hook = any(
            kw in c_str
            for kw in [
                "[hook",
                "violation",
                "hook error",
                "remain after",
                "blocking error",
            ]
        )
        print(f"\n  TOOL_RESULT[{i}][{j}]:")
        print(f"    tool_use_id: {tool_id}")
        print(f"    is_error: {ie}")
        print(f"    HAS_HOOK_TEXT: {has_hook}")
        print(f"    content: {c_str[:500]}")

    elif item.get("type") == "text":
        t = item.get("text", "")
        if any(
            kw in t
            for kw in [
                "hook error",
                "remain after delegation",
                "blocking error",
                "hook blocking",
            ]
        ):
            print(f"\n  TEXT_WITH_HOOK_ERROR[{i}][{j}]:")
            start = max(0, t.find("hook") - 50)
            print(f"    ...{t[start : start + 200]}...")


def request(flow: http.HTTPFlow):
    """Extract tool_result contents from API requests."""
    if "api.anthropic.com" not in flow.request.pretty_url:
        return
    if flow.request.method != "POST":
        return
    if "/v1/messages" not in flow.request.pretty_url:
        return
    try:
        data = json.loads(flow.request.content.decode("utf-8"))
        messages = data.get("messages", [])

        print(f"\n=== API REQUEST to {flow.request.pretty_url} ===")
        print(f"Messages count: {len(messages)}")

        for i, msg in enumerate(messages):
            content = msg.get("content", "")
            if not isinstance(content, list):
                continue
            for j, item in enumerate(content):
                _process_item(i, j, item)

        # Check system prompt
        system = data.get("system", "")
        sys_str = json.dumps(system)
        if any(
            kw in sys_str
            for kw in [
                "remain after delegation",
                "hook blocking",
                "hook error",
            ]
        ):
            print("\n  !! HOOK ERROR TEXT IN SYSTEM PROMPT !!")

    except Exception as e:
        print(f"Parse error: {e}")
