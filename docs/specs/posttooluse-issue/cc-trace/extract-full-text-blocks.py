"""Extract full text blocks from the second API request."""

import json

from mitmproxy import http

_request_count = 0


def _print_block(j: int, item: dict) -> None:
    item_type = item.get("type", "?")
    if item_type == "tool_result":
        c = item.get("content", "")
        ie = item.get("is_error", "ABSENT")
        print(f"    [{j}] tool_result is_error={ie}")
        print(f"        content: {c[:300]}")
    elif item_type == "text":
        t = item.get("text", "")
        print(f"    [{j}] text ({len(t)} chars):")
        print(f"        {t[:500]}")
    elif item_type == "tool_use":
        name = item.get("name", "?")
        print(f"    [{j}] tool_use name={name}")
    else:
        print(f"    [{j}] {item_type}")


def request(flow: http.HTTPFlow):
    """Extract full text blocks from API messages requests."""
    global _request_count  # noqa: PLW0603
    if "api.anthropic.com" not in flow.request.pretty_url:
        return
    if "/v1/messages" not in flow.request.pretty_url:
        return
    if "count_tokens" in flow.request.pretty_url:
        return
    if flow.request.method != "POST":
        return

    _request_count += 1
    try:
        data = json.loads(flow.request.content.decode("utf-8"))
        messages = data.get("messages", [])

        print(f"\n{'=' * 60}")
        print(f"API REQUEST #{_request_count}")
        print(f"Messages: {len(messages)}")

        for i, msg in enumerate(messages):
            role = msg.get("role", "?")
            content = msg.get("content", "")
            if not isinstance(content, list):
                print(f"  MSG[{i}] role={role} content=string({len(content)} chars)")
                continue
            print(f"  MSG[{i}] role={role} content=list({len(content)} blocks)")
            for j, item in enumerate(content):
                _print_block(j, item)

    except Exception as e:
        print(f"Parse error: {e}")
