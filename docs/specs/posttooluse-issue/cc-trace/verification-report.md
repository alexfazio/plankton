# Verification Report: PostToolUse Hook Output Claims

**Date**: 2026-02-21
**Verifier**: Claude Opus 4.6 (automated with cc-trace skill)
**Target**: Claude Code v2.1.50
**Specs under verification**:

- `docs/specs/posttoolusewrite-hook-stderr-silent-drop.md`
- `docs/specs/jsonl-version-bisection.md`

---

## Summary

| # | Claim | Verdict | Phase |
| --- | ------- | --------- | ----- |
| 1 | All 5 channels silently dropped | **PARTIAL** | 2 |
| 2 | PreToolUse propagates output | **VERIFIED** | 3 |
| 3 | 3 hooks match PostToolUse:Write | **VERIFIED** | 1, 3 |
| 4 | "Normal processing" discards output | **VERIFIED** | 1, 3 |
| 5 | `\|\| echo "[]"` count bug | **VERIFIED** | 6 |
| 6 | GitHub issues exist and match | **VERIFIED** | 5 |
| 7 | 48 sessions across v2.1.9-v2.1.50 | **VERIFIED** | 4 |
| 8 | Zero PostToolUse in tool_results | **VERIFIED** | 4 |
| 9 | 18 PreToolUse positive controls | **VERIFIED** | 4 |
| 10 | Matrix.tsv internally consistent | **VERIFIED** | 4 |

**Overall**: 9 of 10 claims VERIFIED. Claim 1 PARTIALLY REFUTED — the hook
output is NOT "unconditionally discarded" for the stderr+exit2 channel.
It reaches the model via a system-reminder text block, just not via the
tool_result field.

---

## Critical Finding: The Hidden Channel

**This is the most important result of this verification.**

Mitmproxy capture of the actual API request body (Phase 2B) reveals that
for the stderr+exit2 channel, hook output IS delivered to the model:

```text
MSG[2] role=user content=list(2 blocks)
  [0] tool_result is_error=ABSENT
      content: File created successfully at: /tmp/verify-stderr-exit2-v2.txt
  [1] text (409 chars):
      <system-reminder>
      PostToolUse:Write hook blocking error from command:
      ".../hook-stderr-exit2.sh": [...]: [hook] 3 violation(s)
      remain after delegation
      </system-reminder>
```

**The tool_result field** (block [0]) contains only the Write tool's
hardcoded success message. **No hook text** — consistent with the spec's
claim and the JSONL evidence.

**But a separate text content block** (block [1]) is appended to the same
user message, containing the full hook error wrapped in `<system-reminder>`
tags. This text block IS sent to the API and IS visible to the model.

**Why JSONL didn't show this**: The client-side JSONL log format records
tool_result content but does NOT record adjacent text content blocks in
the same message. The mitmproxy capture sees the raw API request body
which includes all content blocks.

**Implication**: The spec's claim that PostToolUse output is
"unconditionally discarded" needs qualification. For stderr+exit2:

- **NOT in tool_result** — verified (the model cannot associate the
  feedback with the specific tool call)
- **IS in the API request** — verified (as a system-reminder text block)
- The model CAN see the hook output, but it arrives as ambient context
  rather than structured tool feedback

This explains the mystery of how haiku's thinking block in the B1 test
mentioned "3 violations remain after delegation" despite the tool_result
being clean: the model read the system-reminder text block.

---

## Phase 1: Static Binary Analysis (Claims 3, 4)

### 1A. Hook event type enumeration

**VERIFIED**: Both `PreToolUse` (48 occurrences) and `PostToolUse`
(60 occurrences) exist as distinct quoted strings. 16 total hook event
types found (more than the 6 commonly documented).

### 1B. Debug log strings

All five referenced strings found in the binary:

| String | Count | Context |
| -------- | ------- | --------- |
| `"does not start with"` | 4 | JSON classifier in `wTD()` |
| `"normal processing"` | 3 | Async discard path in `lbR()` |
| `"Checking initial response"` | 3 | Async detection check |
| `"unique hooks"` | 3 | Matcher count log in `mcA()` |
| `"permissionBehavior"` | 8 | PreToolUse-specific field in `PTD()` |

### 1C. Hook schema definitions

**VERIFIED**: Full schema recovered from binary at string offset 127007.
PreToolUse uniquely supports `permissionDecision`, `permissionDecisionReason`,
`updatedInput`. PostToolUse uniquely supports `updatedMCPToolOutput`. The
`decision` field maps to `permissionBehavior` (`approve` -> `allow`,
`block` -> `deny`).

### 1D. tool_result construction

**VERIFIED**: `"File created successfully at: "` is a hardcoded template
in `mapToolResultToToolResultBlockParam()`. The function constructs
`tool_use_id`, `type: "tool_result"`, and `content` together.

---

## Phase 2: Live mitmproxy Reproduction (Claims 1, 2)

### 2A. Mitmproxy setup

mitmweb 12.2.1 running on port 8080, flow file saved to
`posttoolusewrite-verify.mitm` (661KB, 20+ flows captured).

### 2B. stderr+exit2 channel test

**PARTIALLY REFUTED**: Hook output NOT in tool_result (consistent with
spec) BUT IS delivered as a system-reminder text block alongside the
tool_result. See Critical Finding above.

Only one of five channels was tested via mitmproxy (stderr+exit2).
The other four channels (stderr+exit0, JSON+exit2, JSON+exit0,
stderr+exit1) were verified indirectly through Phase 3 debug logs,
which show the same discard path for all channels. Whether those
channels also produce system-reminder text blocks requires additional
mitmproxy testing.

### 2C. PreToolUse positive control

The model self-censored based on CLAUDE.md instructions and did not
attempt the Edit tool call, so the PreToolUse hook was not triggered
during the mitmproxy session. However, PreToolUse propagation is
conclusively verified by Phase 3 debug logs (line 172-174 of
stderr-exit2-debug.txt shows `Hook result has permissionBehavior=allow`
followed by `Hook approved tool use for Write, bypassing permission check`).

### 2D. Evidence saved

- `posttoolusewrite-verify.mitm` — raw mitmproxy flows
- `mitmproxy-extraction.txt` — parsed extraction output

---

## Phase 3: Debug Log Cross-Reference (Claims 3, 4)

### 3A. 3-hook matcher count

**VERIFIED**: stderr-exit2-debug.txt line 181:
`Matched 3 unique hooks for query "Write" (3 before deduplication)`

PreToolUse matched 1 hook, PostToolUse matched 3 hooks.

### 3B. "Normal processing" discard path

**VERIFIED**: json-exit2-debug.txt lines 182-184 show the complete
sequence:

1. `Checking initial response for async: {"hookResult":"error",...}`
2. `Parsed initial response: {"hookResult":"error",...}`
3. `Initial response is not async, continuing normal processing`

The error IS logged (line 186) but then processing jumps directly to
LSP diagnostics and API request construction — no propagation to
tool_result.

### 3C. PreToolUse vs PostToolUse asymmetry

**VERIFIED**:

- **PreToolUse** (line 172-174): `success` -> `permissionBehavior=allow`
  -> `approved tool use for Write` — result IS consumed for permission
  decision
- **PostToolUse** (line 183): `error` -> logged -> next hook classified
  -> LSP diagnostics -> API request — result logged but NOT consumed by
  any downstream handler for tool_result construction

---

## Phase 4: JSONL Bisection Re-verification (Claims 7-10)

### 4A. Deterministic re-run

Script re-run produced identical results for the original 48 sessions.
One new session (0cd4ccbc, current verification session) was added by
the re-run, bringing the total to 49.

### 4B. Session count (Claim 7)

**VERIFIED**: Original matrix had 48 data rows + header. Claim of
"48 sessions" is accurate. Re-run added 1 new session (49 total).

### 4C. Zero PostToolUse output in tool_results (Claim 8)

**VERIFIED**: `awk -F'\t' '$6 == "Y"'` returned 0 rows in both original
and re-run matrices. No session in any version (v2.1.9 through v2.1.50)
has PostToolUse hook output appearing in the JSONL tool_result field.

### 4D. 18 PreToolUse sessions (Claim 9)

**VERIFIED**: Original matrix had exactly 18 PreToolUse=Y rows. Re-run
has 19 (current session 0cd4ccbc added 1).

### 4E. Spot-check 3 sessions

All three sessions verified against JSONL files:

| Session | Expected Version | Actual | Expected PreToolUse | Actual | Match |
| --- | --- | --- | --- | --- | --- |
| 5bec7174 | v2.1.31 | v2.1.31 | Y | Y (decision:block found) | YES |
| 8b97653f | v2.1.50 | v2.1.50 | Y | Y (3 decision:block found) | YES |
| 8f7dfe57 | v2.1.27 | v2.1.27 | N | N (no decision:block) | YES |

### Claim 10: Internal consistency

**VERIFIED**: Matrix data is reproducible (identical on re-run), column
values match JSONL file content on spot-check, and counts are internally
consistent.

---

## Phase 5: GitHub Issue Verification (Claim 6)

All 10 referenced issues exist and match their spec descriptions:

| Issue | Title | State | Match |
| ------- | ------- | ------- | ------- |
| #11224 | PostToolUse output per exit code/stream | CLOSED | YES |
| #18427 | PostToolUse cannot inject context | OPEN | YES |
| #23381 | PostToolUse blocking error shown twice | CLOSED (dup) | YES |
| #27314 | Async PostToolUse systemMessage dropped | OPEN | YES |
| #19009 | exit 2 'blocking error' doesn't block | OPEN | YES |
| #19115 | Conflicting JSON schemas for hooks | OPEN | YES |
| #24327 | PreToolUse exit 2 causes stop | OPEN | YES |
| #13650 | SessionStart stdout silently dropped | CLOSED | YES |
| #4809 | PostToolUse exit 1 blocks execution | CLOSED (dup) | YES |
| #24788 | additionalContext not surfacing (MCP) | OPEN | YES |

Deep-check of 3 key issues:

- **#11224**: Describes the three visibility modes for PostToolUse hooks
  (exit 0/1/2 with stdout/stderr). Specifically documents that stderr+exit2
  is the channel that shows output to both user and Claude. This is
  consistent with the mitmproxy finding (stderr+exit2 output IS delivered).
- **#18427**: Confirms PostToolUse cannot inject context, lists 7 attempted
  approaches (decision:block, systemMessage, additionalContext,
  hookSpecificOutput, etc.) — none work for tool_result injection.
- **#23381**: Reports decision:block duplication in v2.1.31.

---

## Phase 6: Multi-line Count Bug Verification (Claim 5)

### 6A. Bug reproduction

**VERIFIED**: The `|| echo "[]"` bug was successfully reproduced.

When shellcheck finds violations (exit code 1), `|| echo "[]"` inside
`$(...)` appends `[]` to valid JSON output. The variable then contains
two JSON values separated by a newline:

```text
Buggy: v=$(shellcheck -f json file 2>/dev/null || echo "[]")
Result: "[{...violations...}]\n[]"
jq output: "4\n0" (two lines — breaks integer comparison)
```

The fix `v=$(cmd) || true` correctly preserves valid JSON output while
suppressing the non-zero exit code.

### 6B. C1 evidence

**VERIFIED**: C1-multiline-root-cause directory contains analysis.md,
shellcheck-raw.json, jaq-length-output.txt, jaq-length-linecount.txt,
and test-violations.sh. The root cause analysis correctly identifies the
bug pattern and its systemic nature across all file type handlers.

**Note**: The C1 analysis.md recommends `v=$(cmd) || v="[]"` as the fix
(line 83), which is itself buggy — it overwrites valid output because
`$()` propagates the linter's exit code. The main spec document (lines
1081-1089) correctly identifies `v=$(cmd) || true` as the proper fix,
and the current codebase has been fixed accordingly.

---

## New Finding Resolution

**Question**: How does haiku know about hook errors despite clean tool_result?

**Answer**: The hook output IS delivered to the model, but through a
**separate text content block** (`<system-reminder>` tags) appended to
the same user message as the tool_result. This delivery mechanism:

1. Is NOT captured in the JSONL `tool_result` field (only tool_result
   content is logged, not adjacent text blocks)
2. IS captured in the mitmproxy API request body (shows all content blocks)
3. Explains why haiku can reference exact hook error text despite the
   tool_result being clean
4. Means the spec's "unconditionally discarded" characterization needs
   qualification — the output IS discarded from the tool_result but IS
   delivered through an adjacent text block channel

This is neither full propagation (the output doesn't arrive as structured
tool feedback that the model can associate with the specific tool call)
nor full discard (the model CAN see the text). It's a partial delivery
through an ambient context channel.

---

## Evidence Files

| File | Location |
| ------ | ---------- |
| Flows | `…/posttoolusewrite-drop-2026-02-21/posttoolusewrite-verify.mitm` |
| Extraction | `…/posttoolusewrite-drop-2026-02-21/mitmproxy-extraction.txt` |
| Debug logs | `…/posttoolusewrite-drop-2026-02-21/B1-debug-four-channel/` |
| JSONL bisect | `…/jsonl-version-bisect/matrix.tsv` |
| C1 analysis | `…/posttoolusewrite-drop-2026-02-21/C1-multiline-root-cause/` |
