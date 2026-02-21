# B3: Callback Hook Interaction Analysis

## Date: 2026-02-21
## Status: RESOLVED — derived from B1 debug logs

## Key Finding: 3 PostToolUse Hooks, Not 2

The spec previously documented "Matched 2 unique hooks" from the original
session's debug log. The B1 investigation reveals **3 unique hooks** match
PostToolUse:Write:

```text
Matched 1 unique hooks for query "Write" (1 before deduplication)  # PreToolUse
Matched 3 unique hooks for query "Write" (3 before deduplication)  # PostToolUse
```

- 1 custom command hook (our test hook)
- 2 internal Claude Code hooks (callback + likely file watcher/diagnostics)

The original session had `multi_linter.sh` as the custom hook. With only
1 registered PostToolUse hook, CC still produces 3 total. The 2 internal
hooks are always present and cannot be disabled.

## Internal Hook Behavior

The internal hooks produce non-JSON output:

- **stderr tests**: 2 "does not start with {" lines → both our hook AND
  an internal hook produce plain text. The second internal hook likely
  produces empty or minimal non-JSON output.
- **JSON tests**: 1 "does not start with {" line → only the internal
  hook(s) produce non-JSON. Our hook's JSON IS parsed.

## JSON Parsing Path

The debug logs reveal the JSON parsing flow:

```text
Hooks: Checking initial response for async: {"decision":"block","reason":"..."}
Hooks: Parsed initial response: {"decision":"block","reason":"..."}
Hooks: Initial response is not async, continuing normal processing
```

The JSON IS correctly parsed. But it's classified as "not async" and
routed to "normal processing" — which for PostToolUse discards the result.

## Does Callback Override Custom Hook?

**No evidence of override.** The debug logs show ALL hook results are logged:

```text
Hook PostToolUse:Write (PostToolUse) error:  [hook] 3 violation(s) remain
```

The issue is not that the callback "wins" over the command hook. The issue
is that **no PostToolUse hook result reaches the tool_result**, regardless
of exit code, output format, or hook count. All 3 hooks' outputs are
logged but collectively discarded.

## Discard Point

The discard happens AFTER the debug log line:
```text
Hook PostToolUse:Write (PostToolUse) error: <output>
```

And BEFORE the API request is constructed. The "normal processing" path
for PostToolUse hooks does not propagate results to the tool_result.

## Evidence

All findings derived from B1 debug log files:
- `B1-debug-four-channel/stderr-exit2-debug.txt`
- `B1-debug-four-channel/json-exit0-debug.txt`
