# PostToolUse Hook Output: Delivery via system-reminder Inside tool_result

Investigation into how Claude Code delivers PostToolUse command hook
output. Stderr+exit2 output IS delivered to the model as a
`<system-reminder>` tag embedded inside the `tool_result.content` string
(not as a separate content block — see Correction Notice 2026-02-22).

**Affected version**: Claude Code v2.1.50
**Discovered**: 2026-02-21
**Corrected**: 2026-02-21 (mitmproxy verification),
2026-02-22 (delivery mechanism correction — see Correction Notice below)
**Session**: `4caaa728-f9e5-4cf2-94b5-f22d0f1a0f6a`
**Document status**: Historical record. The active executable plan is
`make-plankton-work.md` (now COMPLETE). This document preserves
investigation details, evidence chains, and workaround designs for
reference.

## Correction Notice (2026-02-22)

The 2026-02-21 correction described the delivery mechanism as "a separate
`<system-reminder>` text block appended to the same user message as the
tool_result." **This was imprecise.** Live verification with mitmproxy
(3 iterations across shell, Python, and JSON) shows the `<system-reminder>`
is embedded **inside the `tool_result.content` string itself**, not as a
separate content block in the messages array. The tool_result content field
contains the success message followed by `\n\n<system-reminder>...\n\n</system-reminder>`.

This distinction matters: the JSONL forensics conclusion that "tool_result
contains ONLY the success message" was wrong — the tool_result content
includes both the success message and the system-reminder tag. The search
missed this because it looked for hook output as primary content rather
than searching for `<system-reminder>` tags within the content string.

Evidence: `make-plankton-work.md` Step 2 Live Verification Report
(mitmproxy rank-1, 3/3 iterations).

## Correction Notice (2026-02-21)

The original investigation concluded that PostToolUse hook output was
"unconditionally discarded." **This was wrong.** Mitmproxy capture of
the actual API request body proved that stderr+exit2 output IS delivered
to the model as a `<system-reminder>` tag embedded inside the
`tool_result.content` string (corrected 2026-02-22 — originally described
as a separate adjacent text block; see Correction Notice 2026-02-22 above).
The JSONL forensics missed this because the search looked for raw hook
output as primary content, not for `<system-reminder>` tags within the
content string. The GitHub issues referenced below describe the tool_result
field behavior accurately but do not account for the system-reminder
delivery channel.

**What is true** (hard evidence — mitmproxy capture, updated 2026-02-22):

- The `tool_result.content` string contains both the success message AND
  the `<system-reminder>` tag with hook stderr (not a separate text block)
- The model CAN read the system-reminder content (confirmed: opus-4-6
  thinking referenced specific violation codes from the hook JSON and
  explicitly said "hook flagged" in 3/3 iterations)
- The agent reliably ACTS on the feedback: Read + Edit calls in all
  3 test iterations (shell SC2034, Python F841, JSON JSON_SYNTAX)

**What was wrong** (claims corrected):

- "Unconditionally discarded" — wrong; delivered via system-reminder
- "Five channels all silently dropped" — only tool_result is empty;
  only stderr+exit2 was tested via mitmproxy, others untested
- "Agent had zero signal" — wrong; the signal arrives as ambient
  context, not structured tool feedback

**What remains unclear** (updated 2026-02-22):

- Whether the agent reliably ACTS on system-reminder hook feedback
  — **RESOLVED (2026-02-22)**: YES. Live verification with mitmproxy
  confirms 3/3 iterations: shell (SC2034), Python (F841), JSON
  (JSON_SYNTAX). Agent explicitly references hook output and makes
  Edit calls. See `make-plankton-work.md` Step 2 Live Verification
  Report.
- Whether multi_linter.sh's garbled output (Step 1 bug) was the real
  reason the agent ignored violations in the original session
  — **RESOLVED (2026-02-22)**: YES. Fixing the garbled output (Step 1)
  and protecting jaq calls (Step 1.5) was sufficient. No CC behavior
  issue — the delivery mechanism works when the hook produces clean
  output.
- Whether the other 4 output channels also produce system-reminder
  blocks (only stderr+exit2 was mitmproxy-tested) — *Still unknown*.
  Automated channel output tests pass (20/20), mitmproxy runbook ready
  in `test_five_channels.sh --runbook`.

Evidence: `cc-trace/verification-report.md` (mitmproxy capture Phase 2B)

## Summary

Claude Code v2.1.50 does NOT propagate PostToolUse hook output into a
separate `tool_result` field. However, for stderr+exit2, the hook's
stderr content IS delivered to the model as a `<system-reminder>` tag
embedded inside the `tool_result.content` string — the content field
contains both the success message and the system-reminder tag
(corrected 2026-02-22; see Correction Notice above).

The agent reliably acts on this feedback when the hook output is clean
(confirmed 3/3 iterations with mitmproxy rank-1 evidence — see
`make-plankton-work.md` Step 2 Live Verification Report). Garbled
output (pre-Step-1-fix) was ignored by the agent.

The terminal UI renders `PostToolUse:Write hook error` as a progress
indicator. Unlike what was originally claimed, this is NOT purely
cosmetic — the corresponding stderr content does reach the API via
the system-reminder channel.

## Observed Behavior

### What the user saw in the terminal

```text
Write(/Users/alex/Documents/cc-inbox/setapp/fix-setapp.sh)
  Wrote 252 lines to /Users/alex/Documents/cc-inbox/setapp/fix-setapp.sh
  PostToolUse:Write hook error
```

### What the agent received in its API context

```json
{
  "tool_use_id": "toolu_01YYnVvbNNPnUFFmXSJZgJGU",
  "type": "tool_result",
  "content": "File created successfully at: /Users/alex/Documents/cc-inbox/setapp/fix-setapp.sh"
}
```

No `is_error` field. No stderr appended. No exit code annotation.
**Correction**: The agent DID receive the hook's stderr via a
`<system-reminder>` text block (proven by mitmproxy), but the
tool_result itself contained zero signal. See Correction Notice.

### What should have happened

Based on the documented behavior in `docs/REFERENCE.md` (lines 479-484):

```text
PostToolUse:Edit hook error: Failed with non-blocking status code 2
[hook] 3 violation(s) remain after delegation
```

The tool result should have included the hook's stderr, either appended
to the content or delivered as an error annotation, so the agent could
act on the violations per the Boy Scout Rule in CLAUDE.md.

## Root Cause Analysis

### Evidence Chain

Three data sources were cross-referenced: the JSONL conversation log,
the debug log, and the hook source code.

**1. Hook execution timing** (debug log):

```text
11:24:25.345  PostToolUse:Write hook starts (multi_linter.sh)
              ...300 seconds of hook execution (subprocess timeout)...
11:29:25.690  "Hook output does not start with {, treating as plain text"
```

Duration: exactly 300 seconds, matching `SUBPROCESS_TIMEOUT=300` in
`config.json`. The `claude -p` subprocess timed out (exit 124), then
`rerun_phase2()` found remaining ShellCheck violations and the hook
exited with code 2.

**2. Missing hook result log line** (debug log):

In sessions where PostToolUse hooks exit 0, the debug log shows:

```text
Hook output does not start with {, treating as plain text
Hook PostToolUse:Write (PostToolUse) success:
```

In session `4caaa728`, the second line is **absent**:

```text
Hook output does not start with {, treating as plain text
LSP Diagnostics: getLSPDiagnosticAttachments called    <-- immediate next line
```

No `Hook PostToolUse:Write (PostToolUse) success:` or
`Hook PostToolUse:Write (PostToolUse) error:` was ever logged. The hook
result processing terminated after classifying the output as plain text.

**3. Tool result delivered to API** (JSONL line 42):

```json
{
  "tool_use_id": "toolu_01YYnVvbNNPnUFFmXSJZgJGU",
  "type": "tool_result",
  "content": "File created successfully at: /Users/alex/Documents/cc-inbox/setapp/fix-setapp.sh"
}
```

The `is_error` field is absent (not even `false`). The content contains
only the Write tool's native output. No hook stderr was appended.

### Corrected Hypothesis: tool_result Empty, system-reminder Delivers

The PostToolUse result handler does NOT propagate hook output as a
separate content block. However, mitmproxy capture proved that
stderr+exit2 content IS delivered to the model as a `<system-reminder>`
tag embedded inside the `tool_result.content` string:

```json
{
  "type": "tool_result",
  "content": "The file ...updated successfully.\n\n<system-reminder>\nPostToolUse:Write hook blocking error from command: \".claude/hooks/multi_linter.sh\": [hook] [\n  {\"line\": 2, \"code\": \"SC2034\", ...}\n]\n\n</system-reminder>",
  "tool_use_id": "toolu_..."
}
```

**Note**: The 2026-02-21 mitmproxy capture (`claude -p` mode, haiku)
originally showed this as `MSG[2] content=list(2 blocks)` — a separate
text block adjacent to the tool_result. The 2026-02-22 capture
(interactive mode, opus) corrected this: the system-reminder is inside
`tool_result.content`, not a separate block. Whether this reflects a
mode-dependent difference (`-p` vs interactive) or a 2026-02-21
analysis error has not been independently verified. The interactive-mode
finding is authoritative for production.

Evidence trail for tool_result being empty:

1. Plain text stderr + exit 2 → NOT in tool_result (JSONL forensics)
2. Plain text stderr + exit 0 → NOT in tool_result (cross-session)
3. JSON stdout + exit 2 → NOT in tool_result (live test, 2026-02-21)
4. Debug log shows no `Hook PostToolUse:Write success/error` line
   after the `treating as plain text` line

Evidence that output DOES reach the model:

1. Mitmproxy capture shows `<system-reminder>` text block (Phase 2B)
2. Haiku's thinking block referenced "3 violations remain" despite
   clean tool_result — it read the system-reminder
3. JSONL did not capture this because JSONL only logs tool_result
   content, not adjacent text blocks in the same message

**Why the original investigation missed this**: The JSONL forensics
methodology only checked tool_result fields. The mitmproxy capture
(run later) sees the raw API request body including all content blocks.
The GitHub issues (#18427, #24788) describe tool_result behavior
accurately but do not account for the system-reminder channel.

### Compounding Factor: Multiple Hook Matchers

The debug log shows:

```text
Matched 3 unique hooks for query "Write" (3 before deduplication)
```

Three hooks match PostToolUse:Write: `multi_linter.sh` (command hook)
and two internal Claude Code hooks (callback + likely file
watcher/diagnostics). The original session's debug log showed "Matched
2", but B1 investigation (2026-02-21) with a single registered custom
hook revealed 3 matchers — the 2 internal hooks are always present and
cannot be disabled.

Investigation B3 confirmed: no callback override. All 3 hooks' outputs
are logged in debug but collectively discarded. The bug is in the
PostToolUse result handler's "normal processing" path, not in result
merging between hooks.

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B3-callback-interaction/analysis.md`

## Frequency Analysis

Across 2,828 debug-logged sessions on this machine:

| Metric | Count |
| --- | --- |
| Sessions with "does not start with {" | 132 (4.6%) |
| Followed by Hook success/error (processed) | 1,322 |
| NOT followed by any Hook result (dropped) | 2,415 |

The 2,415 dropped occurrences include both exit 0 (benign, no feedback
needed) and exit 2 (violations lost). The exact exit-2-only count cannot
be determined from debug logs alone because the exit code is not logged
in the debug output for PostToolUse hooks. These numbers demonstrate the
bug is systematic, not a one-off. The exit-2 subset (lost violation
reports) is a strict subset of the 2,415 dropped occurrences.

## Reproduction Steps

### Prerequisites

- Claude Code v2.1.50 (or any version with the same hook output parser)
- A PostToolUse command hook that exits with code 2 and writes to stderr
- The hook must write plain text (not JSON) to stderr

### Minimal Reproduction

**Step 1**: Create a minimal PostToolUse hook that always fails:

```bash
# .claude/hooks/always-fail.sh
#!/bin/bash
echo "[hook] test violation remains" >&2
exit 2
```

**Step 2**: Register it in `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/always-fail.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Step 3**: Start Claude Code with debug logging:

```bash
claude --debug hooks
```

**Step 4**: Ask Claude to write a file:

```text
Write a hello world script to /tmp/test-hook.sh
```

**Step 5**: Observe:

- **Terminal UI** will show `PostToolUse:Write hook error`
- **Debug log** will show `Hook output does not start with {, treating
  as plain text` with no subsequent Hook result line
- **Agent behavior** will receive the hook's stderr via
  `<system-reminder>` text block (not tool_result). Whether the agent
  acts on this ambient feedback depends on the content quality — garbled
  output (pre-Step-1-fix) was ignored; clean output may be acted upon
  (see `make-plankton-work.md` terminal observations)

### Verification via JSONL

After the session, inspect the JSONL:

```bash
SESSION_ID="<session-id>"
JSONL=~/.claude/projects/<project-slug>/${SESSION_ID}.jsonl

# Find the Write tool_result
jaq -c 'select(.type == "user") |
  .message.content[]? |
  select(.type == "tool_result") |
  select(.content | test("File created"))' "$JSONL"
```

Expected (bug present): `content` contains only "File created
successfully..." with no hook stderr appended.

Expected (bug fixed): `content` includes hook stderr, or an `is_error`
field is set, or a separate annotation carries the hook feedback.

### Reproduction with multi_linter.sh (Original Case)

The original bug was triggered by writing a shell script with ShellCheck
violations where the subprocess timed out:

```bash
# Start Claude Code in the plankton project
cd ~/Documents/GitHub/plankton
claude

# Ask it to write a complex shell script (252+ lines)
# The multi_linter.sh hook will:
# 1. Phase 1: shfmt auto-format
# 2. Phase 2: shellcheck finds violations
# 3. Phase 3: subprocess times out after 300s
# 4. Verify: violations remain -> exit 2 + stderr
#
# Result: agent receives "File created successfully" only
```

## Impact

### Direct Impact

The agent does not reliably act on violation feedback. Two issues
compound:

```text
Agent writes file
  -> Hook detects violations
    -> Hook reports violations to stderr
      -> stderr delivered as <system-reminder>   <-- VERIFIED (mitmproxy)
        -> tool_result says "File created successfully" only
          -> Agent receives BOTH tool_result AND system-reminder
            -> Agent may or may not act on ambient system-reminder
              -> Compounded by: multi_linter.sh garbled output (Step 1 bug)
```

The original session's agent likely ignored the system-reminder because
the multi_linter.sh `rerun_phase2()` bug produced garbled output
(`56\n0 violation(s) remain`) — a bash syntax error, not actionable
feedback. Whether the agent acts on CLEAN system-reminder content
(post-Step-1-fix) is the key open question.

### Cascade Effects

1. **User confusion**: The terminal shows "hook error" but the agent
   says "No hold up" because it genuinely does not know
2. **Silent quality regression**: Files with linting violations are
   committed without the agent attempting fixes
3. **Wasted subprocess compute**: The 300-second subprocess timeout
   represents wasted API calls (haiku/sonnet model invocations) whose
   results are never acted upon
4. **Trust erosion**: Users who set up hooks expect enforcement; silent
   drops undermine the hook system's reliability

## Files Referenced

| File | Role |
| --- | --- |
| `~/.claude/projects/…/4caaa728…0f6a.jsonl` | Conversation log (72 ln, 140KB) |
| `~/.claude/debug/4caaa728…0f6a.txt` | Debug log with hook trace |
| `.claude/hooks/multi_linter.sh` | PostToolUse hook triggering bug |
| `.claude/hooks/config.json` | Hook config (`timeout: 300`) |
| `.claude/settings.json` | Hook registration (`PostToolUse` matcher) |
| `docs/REFERENCE.md` | Documents expected hook behavior (lines 479-484) |
| `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/` | Evidence dir |

## Key Debug Log Lines

The following debug log lines are the critical evidence trail. Listed
in chronological order with the significance of each.

```text
# 1. PreToolUse:Write hook approves the file write
11:24:25.262  Hook PreToolUse:Write (PreToolUse) success:
11:24:25.262  Hook result has permissionBehavior=allow

# 2. File is written atomically
11:24:25.342  Writing to temp file: .../fix-setapp.sh.tmp.6801.1771673065342
11:24:25.343  File .../fix-setapp.sh written atomically

# 3. PostToolUse hook starts — 3 matchers (multi_linter.sh + 2 internal)
#    Note: original session logged "Matched 2"; B1 investigation revealed 3
11:24:25.345  Matched 3 unique hooks for query "Write" (3 before deduplication)

# 4. 300 seconds of silence (subprocess running, then timeout)

# 5. Hook output arrives — classified as plain text, then NOTHING
11:29:25.690  Hook output does not start with {, treating as plain text
11:29:25.693  LSP Diagnostics: getLSPDiagnosticAttachments called
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
              No "Hook PostToolUse:Write (PostToolUse) success:" line
              No "Hook PostToolUse:Write (PostToolUse) error:" line
              Hook result was silently dropped from tool_result at this point
              (mitmproxy later proved stderr+exit2 IS delivered via system-reminder)

# 6. API request fires with the bare tool_result
11:29:25.743  [API:request] Creating client...
```

## JSONL Event Timeline

The full event sequence from the JSONL, annotated:

```text
L36  [11:24:24]  ASSISTANT  Write(fix-setapp.sh)         # Agent calls Write
L37  [11:24:25]  PROGRESS   PreToolUse:Write             # protect_linter_configs.sh approves
L38  [-------]   FILE-HISTORY-SNAPSHOT                    # File tracking
L39  [11:29:15]  QUEUE-OP   enqueue "what's the hold up?" # User types during 300s block
L40  [11:24:25]  PROGRESS   PostToolUse:Write (command)  # multi_linter.sh starts
L41  [11:24:25]  PROGRESS   PostToolUse:Write (callback) # Internal callback starts
L42  [11:29:25]  USER       tool_result for Write         # Result: "File created" ONLY
L43  [11:29:25]  QUEUE-OP   remove                        # Queued message dequeued
L44  [11:29:28]  ASSISTANT  Bash(chmod +x)                # Agent proceeds, unaware of hook error
```

Note the timestamp discontinuity: L40-L41 are at `11:24:25` (hook
start) but L42 is at `11:29:25` (hook end, 300s later). The tool
result was held until the hook completed, but the hook's stderr/exit
code was not incorporated into it.

## Additional Evidence: Edit vs Write Behavior Difference

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

## Secondary Bug: Multi-Line Violation Count

> **CONFIRMED** by investigation C1 (2026-02-21). This is an
> independent bug in `multi_linter.sh`, not in Claude Code. It
> compounds the primary PostToolUse drop bug but must be fixed
> independently. See Step 1 in Action Plan.

The Edit error above reveals a bug in `rerun_phase2()`: the `remaining`
variable captured on line 1307 contained `56\n0` (two numbers separated
by a newline) instead of a single integer. This caused:

1. **Bash syntax error on line 1309**: `[[ "56\n0" -eq 0 ]]` fails
   because bash cannot evaluate a multi-line string as an integer
2. **Garbled error message on line 1312**: `[hook] 56\n0 violation(s)
   remain after delegation` — the count is unreadable

The `rerun_phase2()` function (line 494-617) initializes `count=0` and
returns it via `echo "${count}"` on line 616. For shell files (line
558-563), it runs `shellcheck -f json` piped through `jaq 'length'`.

**Root cause identified** (investigation C1, 2026-02-21): The
`|| echo "[]"` fallback pattern in the linter capture
(`v=$(shellcheck -f json "${fp}" 2>/dev/null || echo "[]")`) appends
`[]` to valid JSON when shellcheck exits non-zero (normal behavior for
violations found). `jaq 'length'` then processes both JSON values as a
stream, outputting `56\n0`. This is systemic — the same pattern affects
all file types. See Step 1 in Action Plan for the fix.

## Agent Misinterpretation (Three Failure Layers)

> **ACTIONABLE**: These failure layers directly inform the workaround's
> PreToolUse block message design. The block message must explicitly
> state that violations are in the target file, not in the hook, to
> prevent Layer 3 misinterpretation.

Even when the error WAS delivered (Edit case), the agent misinterpreted
it. The agent's reasoning:

```text
The hook is reporting a syntax error. It seems like there's a newline
issue in the linter output parsing. But the edit itself went through.

Actually, the hook error seems to be an internal issue with the hook
script itself (line 1282 of multi_linter.sh has a syntax error). This
is not something I should fix - it's a protected file.
```

Three compounding failure layers:

1. **Layer 1 (Write)**: Hook error not in tool_result — delivered via
   system-reminder but agent did not act on it (garbled by Step 1 bug)
2. **Layer 2 (Edit)**: Hook error delivered but with confusing format
   (bash syntax error mixed with violation count) — agent cannot parse
   the actionable information
3. **Layer 3 (Reasoning)**: Agent correctly identifies the hook script
   is protected by CLAUDE.md and concludes it cannot act on a "hook
   bug" — when really the 56 violations are in `fix-setapp.sh`, not in
   the hook

## Plankton Hook Architecture Context

This section documents how `multi_linter.sh` communicates with Claude
Code, to inform both upstream fixes and local workarounds.

### Three-Phase Architecture

`multi_linter.sh` processes each Edit/Write in three sequential phases:

```text
Phase 1: Auto-Format (silent)
  shfmt (shell), ruff format (python), biome check --write (typescript)
  Runs unconditionally. Output suppressed. Exit status ignored.

Phase 2: Collect Violations (JSON)
  shellcheck -f json (shell), ruff check --output-format=json (python),
  biome lint --reporter=json (typescript), plus secondary linters
  Parses JSON output. Returns integer violation count.

Phase 3: Subprocess Delegation (optional)
  Spawns `claude -p` with violation context and Edit/Read/Bash tools.
  Uses --settings .claude/subprocess-settings.json (prevents recursion).
  Timeout: configurable via config.json (default 300s).
  After subprocess, re-runs Phase 1 + Phase 2 to verify.
```

Configuration in `.claude/hooks/config.json`:

```json
{
  "phases": {
    "auto_format": true,
    "subprocess_delegation": true
  },
  "subprocess": {
    "timeout": 300,
    "model_selection": {
      "sonnet_patterns": "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|...",
      "opus_patterns": "unresolved-attribute|type-assertion",
      "volume_threshold": 5
    }
  }
}
```

### Communication Contract

The hook communicates with Claude Code through two channels:

### Channel 1: Exit code

- `exit 0` — all violations resolved (or none found)
- `exit 2` — violations remain after best-effort fix (non-blocking)
- `exit 1` — hook itself failed (should not normally occur)

### Channel 2: Stderr (`>&2`)

- `[hook] N violation(s) remain after delegation` (exit 2, line 1312)
- `[hook:warning] subprocess timed out (exit 124)` (line 414)
- `[hook:warning] subprocess failed (exit N)` (line 416)
- `[hook:advisory] ...` (exit 0, informational messages)
- `[hook:model] opus|sonnet` (debug mode, line 1290)

**What Claude Code should do** (per `docs/REFERENCE.md` lines 479-484):

- Exit 0: No action needed (current behavior is correct)
- Exit 2 + stderr: Append stderr to tool result as advisory context so
  the agent can act on remaining violations per CLAUDE.md's Boy Scout
  Rule

**What Claude Code actually does** (corrected by mitmproxy, updated
2026-02-22):

- Exit 0: Correct — no annotation
- Exit 2 + stderr: Delivered as a `<system-reminder>` tag embedded
  inside `tool_result.content` (not a separate content block —
  corrected 2026-02-22). The agent reliably acts on clean feedback
  (3/3 mitmproxy-verified iterations). Pre-Step-1-fix garbled output
  was ignored; post-fix, the feedback loop works.

### Affected Output Paths in multi_linter.sh

Every stderr write in the hook bypasses the tool_result field but IS
delivered via `<system-reminder>` for exit 2 (mitmproxy-verified):

| Line | Output | Context |
| --- | --- | --- |
| 1269 | `[hook] ${collected_violations}` | Test mode (HOOK_SKIP_SUBPROCESS=1) |
| 1285 | `[hook] ${remaining} violation(s) remain...` | Exit with violations |
| 414 | `[hook:warning] subprocess timed out...` | Subprocess hit timeout |
| 416 | `[hook:warning] subprocess failed...` | Subprocess non-zero exit |
| 387 | `[hook:warning] created missing...` | Auto-created no-hooks settings |
| 1263 | `[hook:model] ${debug_model}` | Debug model selection |

Cross-session JSONL analysis found: **No PostToolUse hook stderr in any
tool_result field across all plankton sessions** when searching for raw
hook output as primary content. The 2026-02-22 mitmproxy finding shows
the system-reminder is embedded inside `tool_result.content` — whether
JSONL captures this (CC appends before logging) or omits it (CC appends
during API request assembly) has not been independently verified by
re-examining JSONL from a post-Step-1 session. See `make-plankton-work.md`
Evidence Hierarchy footnote [†].

### Exit 0 Stderr: Delivery Status Unknown

When `spawn_fix_subprocess()` encounters a timeout (exit 124) or
failure, it writes a warning to stderr (lines 414, 416) but then
continues to `rerun_phase2()`. If the re-run finds zero violations,
the hook exits 0 with stderr content.

Whether exit 0 + stderr produces a system-reminder block has NOT been
tested with mitmproxy. Only stderr+exit2 was verified. The JSONL
forensics found no exit 0 stderr in tool_results, but JSONL does not
capture system-reminder blocks. This is an open question.

## Workaround Strategies (Hook-Side)

> **Status**: These workarounds were designed before the mitmproxy
> finding that stderr+exit2 IS delivered via system-reminder. They may
> be unnecessary if the agent reliably acts on system-reminder content.
> See `make-plankton-work.md` for the verification-first plan.

Since tool_result never contains hook feedback, these strategies explore
alternative delivery channels. Note that stderr+exit2 already reaches
the model via system-reminder — the question is whether that's
sufficient for reliable agent action.

### Strategy 1: JSON Output to Stdout — NOT IN tool_result

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Strategy 2: Sidecar Violation File + CLAUDE.md Instruction — RECOMMENDED

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Strategy 3: Embed Marker Comment in Edited File

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Strategy 4: PreToolUse Gate with Enriched Lock Files — RECOMMENDED

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Recommended Approach (Pre-Mitmproxy Assessment)

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Failure Modes

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

## Constraints for Solution Design

Any fix must account for:

1. **PostToolUse hooks support both exit codes AND JSON** — per
   [official docs](https://code.claude.com/docs/en/hooks),
   PostToolUse hooks can use exit 2 + stderr OR exit 0 + JSON
   `{"decision":"block","reason":"..."}` on stdout. Both channels
   are documented but both are broken in CC v2.1.50 (see
   Investigation 2). PreToolUse uses a different schema
   (`hookSpecificOutput.permissionDecision`)
2. **Multiple hooks can match** — 3 hooks match PostToolUse:Write
   (1 custom + 2 internal); investigation B3 confirmed the bug is NOT
   in result merging — all hooks' outputs are collectively discarded
3. **Stderr is the data channel** — the hook's stderr (e.g., `[hook] 3
   violation(s) remain`) is the only feedback mechanism; it must reach
   the agent's context
4. **Exit 0 behavior** — exit 0 without stderr should remain silent
   (current behavior is correct). Exit 0 with stderr (advisory/warning
   messages like `[hook:warning] subprocess timed out`) — whether this
   produces a system-reminder block is untested (only stderr+exit2 was
   mitmproxy-verified)
5. **Non-blocking exit 2** — exit 2 is documented as "non-blocking"
   (the tool result still succeeds), but the stderr should be appended
   as advisory context
6. **The tool result format** — the tool_result `content` field is a
   string; hook feedback could be appended to it, added as a separate
   content block, or delivered via the `is_error` field
7. **Backward compatibility** — hooks that output nothing to stderr
   (exit 0) must continue to work identically
8. **Multi-line count bug** — `rerun_phase2()` returns multi-line
   output (e.g., `56\n0`) because the `|| echo "[]"` fallback pattern
   appends `[]` to valid linter JSON when linters exit non-zero on
   violations (normal behavior). Root cause confirmed by investigation
   C1 — systemic across all file types. Must be fixed independently
   of the Claude Code upstream bug
9. **Agent interpretation** — even when errors are delivered, the
   format must be clear enough that the agent acts on the file's
   violations rather than dismissing the error as a hook bug

## Remaining Investigation Items

Items needed for absolute certainty before implementing workarounds or
filing upstream.

### High Priority — COMPLETED AND RE-CONFIRMED

All three high-priority investigations were executed on 2026-02-21
using Claude Code v2.1.50 on macOS Darwin 24.6.0. Each test used
`claude -p` with `--output-format stream-json` and a dedicated
`--settings` file registering a single PostToolUse command hook.
Hook execution was verified via marker files written by each hook.

**Re-confirmation (2026-02-21)**: All three were re-run with fresh
hook scripts and isolated settings files. Evidence stored at
`.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/`. Write tests
all re-confirmed. Edit re-test was INCONCLUSIVE — the model (haiku)
attempted to Read the file first (permission denied in `-p` mode) and
never invoked the Edit tool, so the Edit hook never fired. The original
Edit finding stands from the first run but lacks independent
re-confirmation.

#### Investigation 1: Edit vs Write Asymmetry

**Result: NO ASYMMETRY — both drop hook output identically.**

| Tool | Hook exit | Hook ran? | tool_result content |
| ---- | --------- | --------- | ------------------- |
| Write | exit 2 + stderr | Yes | `File created successfully` |
| Edit | exit 2 + stderr | Yes | `file has been updated successfully` |

Both tool_results contained only the standard success message.
No hook stderr content was appended in either case. The earlier
observation that Edit propagated the error was likely due to
CLAUDE.md instructions causing the agent to *infer* violations
(the Boy Scout Rule), not actual hook output reaching the
tool_result.

**Conclusion**: The bug is tool-agnostic. PostToolUse hook output
is dropped for ALL tool types, not just Write.

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A1-edit-vs-write/`

#### Investigation 2: `{"decision":"block"}` Schema

**Result: SILENTLY DROPPED — not processed by PostToolUse.**

Hook script output `{"decision":"block","reason":"3 violations
remain after auto-fix"}` to stdout with exit 0. The tool_result
contained only `File created successfully`. The agent did NOT see
any block message.

This is the officially documented PostToolUse structured feedback
schema (per Claude Code docs). The fact that it is silently
dropped confirms PostToolUse hooks have no working output channel
whatsoever — not even the officially documented one.

**Conclusion**: Strategy 1 (any JSON format on stdout) is
definitively ruled out. The `{"decision":"block"}` schema is
documented for PostToolUse but is non-functional in v2.1.50.
PreToolUse uses a different schema (`hookSpecificOutput.permissionDecision`).

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A2-decision-block/`

#### Investigation 3: exit 1 (Fatal) vs exit 2 (Non-blocking)

**Result: exit 1 also silently dropped from tool_result.**

| Exit code | Hook ran? | File created? | tool_result content |
| --------- | --------- | ------------- | ------------------- |
| exit 1 | Yes | Yes | `File created successfully` |
| exit 2 | Yes | Yes | `File created successfully` |

Exit 1 did NOT prevent the Write from completing (confirming
PostToolUse hooks are truly post-operation, not blocking). More
importantly, exit 1 stderr was also silently dropped from
tool_result — the tool_result was identical to exit 2.

**Conclusion (original, pre-mitmproxy)**: This conclusion was based on
JSONL evidence only. The tool_result IS identical for both exit codes.
However, mitmproxy later proved that exit 2 stderr IS delivered via a
separate `<system-reminder>` text block, while exit 1 stderr is NOT.
The difference is invisible in JSONL but functionally significant.
See Correction Notice at top of document.

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A3-exit1-vs-exit2/`

#### Summary: Five-Channel Test Matrix (Corrected)

| Channel | Exit | In tool_result? | Via system-reminder? |
| ------- | ---- | --------------- | -------------------- |
| stderr + exit 2 | 2 | NO | **YES** (mitmproxy) |
| stderr + exit 1 | 1 | NO | Untested |
| JSON stdout + exit 2 | 2 | NO | Untested |
| JSON stdout + exit 0 | 0 | NO | Untested |
| stderr + exit 0 | 0 | NO | Untested |

No output channel populates the tool_result field. However,
stderr+exit2 IS delivered to the model via a `<system-reminder>`
text block (mitmproxy evidence). The model CAN read this content.
Whether the other 4 channels also produce system-reminder blocks
has not been tested with mitmproxy.

The PostToolUse feedback path in CC v2.1.50 is: stderr+exit2 →
system-reminder text block → model sees as ambient context (not
structured tool feedback).

### Medium Priority — COMPLETED

All three medium-priority investigations were completed on 2026-02-21.

#### Investigation B1: `--debug hooks` Four-Channel Test

**Status: RESOLVED** — debug logs reveal the exact discard point.

Four tests run with `--debug hooks --debug-file <path>`:

| Channel | `does not start with {` lines | JSON parsed? | In tool_result? |
| ------- | ----------------------------- | ------------ | --------------- |
| stderr + exit 2 | 2 (hook + internal) | N/A | **NO** |
| stderr + exit 0 | 2 (hook + internal) | N/A | **NO** |
| JSON + exit 2 | 1 (internal only) | YES | **NO** |
| JSON + exit 0 | 1 (internal only) | YES | **NO** |

**Key finding**: JSON output IS correctly parsed by Claude Code. Debug
logs show the flow: `"Checking initial response for async"` →
`"Parsed initial response"` → `"not async, continuing normal
processing"`. The discard happens in the "normal processing" path
after the async check — not in parsing.

**Hook count correction**: 3 PostToolUse hooks match Write (1 custom +
2 internal), not 2 as previously documented. The 2 internal hooks are
always present and cannot be disabled.

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B1-debug-four-channel/`

#### Investigation B2: Test on Newer CC Version

**Status: N/A** — v2.1.50 confirmed as latest (2026-02-21).

`claude doctor` output: Latest version = 2.1.50, Stable version =
2.1.39. No newer version exists to test against.

#### Investigation B3: Callback Hook Interaction

**Status: RESOLVED** — no callback override. Derived from B1 debug
logs.

All 3 hooks' outputs are logged in debug but collectively discarded.
The bug is in the PostToolUse result handler's "normal processing"
path, not in result merging between hooks. The callback does NOT
override the command hook's result — no hook result reaches the
tool_result regardless of exit code, output format, or hook count.

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B3-callback-interaction/analysis.md`

### Low Priority (completeness)

1. **Cross-platform verification**. The investigation was on macOS
   (Darwin 24.6.0). Verify the same behavior on Linux (where most CI
   runs). The hook output parser may differ between Electron/Node
   environments.

2. ~~**JSONL forensics on Edit case**~~. RESOLVED by Investigation
   1 — Edit tool_result is identical to Write (standard success
   message, no hook output). The earlier Edit "error" observation
   was agent inference from CLAUDE.md, not actual hook output.

## Action Plan

> **REDIRECTED**: The executable plan is in `make-plankton-work.md`.
> The plan below is the original pre-correction version, preserved for
> historical context. The corrected plan accounts for the mitmproxy
> finding that stderr+exit2 IS delivered via system-reminder, and
> follows a verification-first approach rather than jumping to
> workarounds.

Prioritized steps, each independently valuable. Later steps build on
earlier ones but are not blocked by them.

### Step 1: Fix `rerun_phase2()` Multi-Line Count Bug

**Effort**: 30 minutes | **Value**: High | **Risk**: None
**Status**: **COMPLETE** (2026-02-21) — see `make-plankton-work.md`

The `remaining` variable on line 1307 can capture multi-line output
(e.g., `56\n0`), causing a bash syntax error on line 1309 and a garbled
error message on line 1312. This breaks the hook even when the upstream
bug is fixed.

**Root cause (C1 investigation, 2026-02-21)**: The `|| echo "[]"`
fallback pattern in linter command captures. Linters exit non-zero when
violations are found (normal behavior), triggering the `|| echo "[]"`
which APPENDS `[]` to already-valid JSON output. `jaq 'length'` then
processes both JSON values as a stream, producing multi-line output:

```bash
# BUG (current code, e.g., line 561):
v=$(shellcheck -f json "${fp}" 2>/dev/null || echo "[]")
# shellcheck exits 1 (violations found) → || triggers
# v = "[{violations}]\n[]" (TWO JSON values)
# jaq 'length' outputs "56\n0" (two lines)
```

**Systemic impact**: The same `|| echo "[]"` pattern exists in ALL
file type handlers in `rerun_phase2()`:

| Line | Linter command | Affected? |
| ---- | -------------- | --------- |
| 504 | `ruff check --output-format=json` | YES — ruff exits 1 on violations |
| 510 | `uv run ty check --output-format gitlab` | YES — ty exits non-zero |
| 541 | `uv run bandit -f json` | YES — bandit exits non-zero |
| 561 | `shellcheck -f json` | YES — confirmed root cause |
| 597 | `hadolint --no-color -f json` | YES — hadolint exits non-zero |

**Two fixes required**:

1. **Source fix** (prevents the bug): Change all linter captures from
   `v=$(cmd || echo "[]")` to `v=$(cmd) || true`. The `|| true`
   suppresses the non-zero exit code (for `set -e`) while preserving
   the valid JSON already captured in `v`. The naive alternative
   `v=$(cmd) || v="[]"` is wrong — `$()` propagates the linter's
   exit code, so `|| v="[]"` overwrites valid output whenever the
   linter finds violations (exit non-zero is normal behavior).
   For jaq parse fallbacks (not linter commands), use
   `v=$(jaq ...) || v="[]"` since jaq failure means unparseable
   input and an empty array is the correct fallback.

2. **Defensive fix** (guards against other leaks): Add `| tail -1` to
   line 1307:

```bash
remaining=$(rerun_phase2 "${file_path}" "${file_type}" | tail -1)
```

Evidence: `.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/C1-multiline-root-cause/analysis.md`

### Step 2: Run the High-Priority Investigation Items

**Effort**: 1 hour | **Value**: High | **Risk**: None
**Status**: COMPLETED (2026-02-21)

All three investigations completed. Results:

- Edit vs Write asymmetry is NOT real — both drop identically
- `{"decision":"block"}` does NOT work for PostToolUse — dropped
- exit 1 does NOT propagate — also dropped, file still created

**Conclusion (original, pre-mitmproxy)**: This conclusion was based on
JSONL evidence only. Mitmproxy later proved that stderr+exit2 IS
delivered via system-reminder. See Correction Notice at top of document.
The corrected plan in `make-plankton-work.md` verifies whether the
system-reminder channel is sufficient before implementing workarounds.

### Step 3: Implement Strategy 4 Workaround (PreToolUse Gate)

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Step 4: File Upstream Bug Report

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

### Step 5: Transition Plan (When Upstream Fix Ships)

> **Superseded** — see `make-plankton-work.md` for the
> verification-first approach that replaced this section.

---

## Cross-Reference: Unprotected jaq Calls (Discovered 2026-02-21)

During investigation of intermittent `PostToolUse:Edit hook error`
messages (hook crash, exit != 0 and != 2), code review found that
Phase 2 violation collection uses unprotected jaq calls — 4 JSON
conversion calls and 13 JSON merge calls lack `|| true` or
`2>/dev/null`. Under `set -euo pipefail` (line 27), any jaq failure
crashes the hook with exit 1, which CC displays as a non-blocking
error and does NOT deliver stderr to the model.

This is a separate issue from the stderr delivery question investigated
in this document. Full analysis and affected line numbers documented in
`make-plankton-work.md` under "Code Review: Unprotected jaq Calls in
Phase 2 Collection."

---

## Related Upstream Issues

| Issue | Title | Status | Relevance |
| ----- | ----- | ------ | --------- |
| [#23381](https://github.com/anthropics/claude-code/issues/23381) | PostToolUse hook blocking error displayed twice (v2.1.31) | Closed | **Regression evidence**: `decision:block` WAS reaching Claude as `<system-reminder>` blocks in v2.1.31. Fix for duplication may have broken propagation entirely. |
| [#18427](https://github.com/anthropics/claude-code/issues/18427) | PostToolUse hooks cannot inject context visible to Claude | Open | Directly confirms our bug. `additionalContext`, `systemMessage`, `modifyResult`, and plain text stdout all fail. |
| [#27314](https://github.com/anthropics/claude-code/issues/27314) | Async PostToolUse hook systemMessage not delivered | Open | Same version (v2.1.50). Async hooks also drop `systemMessage`. |
| [#19009](https://github.com/anthropics/claude-code/issues/19009) | PostToolUse exit 2 shows "blocking error" but doesn't block | Open | Misleading terminology — PostToolUse exit 2 is post-operation, not blocking. |
| [#19115](https://github.com/anthropics/claude-code/issues/19115) | Documentation contradicts itself on decision schema | Open | Docs label `decision`/`reason` as deprecated for PreToolUse but PostToolUse still requires them. |
| [#24327](https://github.com/anthropics/claude-code/issues/24327) | PreToolUse exit 2 causes Claude to stop instead of acting | Open | Even when errors ARE delivered, the model may go idle. |
| [#13650](https://github.com/anthropics/claude-code/issues/13650) | SessionStart hook stdout silently dropped | Closed | Fixed in v2.0.76. Similar pattern to PostToolUse bug. |
| [#4809](https://github.com/anthropics/claude-code/issues/4809) | PostToolUse exit 1 blocks execution | Closed | Could not reproduce — exit 1 is non-blocking. Consistent with Investigation 3. |
| [#11224](https://github.com/anthropics/claude-code/issues/11224) | PostToolUse hook output visibility depends on exit code and stream (v2.0.35) | Open | **Regression evidence**: Empirically documented that exit 2 + stderr WAS the one working PostToolUse path in v2.0.35. Confirms the feature existed before v2.1.50 broke it. |
| [#24788](https://github.com/anthropics/claude-code/issues/24788) | PostToolUse additionalContext not surfacing for MCP tool calls | Open | Another broken PostToolUse output path — `additionalContext` in JSON not reaching Claude for MCP tools. |

### Regression Timeline

Evidence suggests PostToolUse feedback worked from at least v2.0.35
through v2.1.31 and broke by v2.1.50:

- **v2.0.35**: Issue #11224 empirically documents that `exit 2 +
  stderr` was the one working PostToolUse path. This is the earliest
  confirmed evidence of the feature working.
- **v2.1.31**: Issue #23381 reports `decision:block` being delivered
  to Claude as `<system-reminder>` blocks (duplicated). This proves
  the JSON propagation path also existed.
- **v2.1.41**: Changelog: "Fixed hook blocking errors (exit code 2)
  not showing stderr to the user." This fix may have been UI-only
  (terminal display) rather than API-level (model context).
- **v2.1.50**: tool_result field empty for all channels; stderr+exit2
  delivered via system-reminder text block (mitmproxy evidence).

**First-party JSONL bisection** (2026-02-21): Scanned 48 sessions
across v2.1.9-v2.1.50. Zero PostToolUse output found in tool_results
at ANY version. PreToolUse positive control confirms hooks were active
in 18 sessions (v2.1.31+). The bug predates all available first-party
data — the regression boundary cannot be narrowed beyond the external
evidence above. See `jsonl-version-bisection.md` for full methodology
and evidence at `.claude/tests/hooks/jsonl-version-bisect/`.

The upstream bug report (Step 4) should frame this as a **regression**
from v2.0.35/v2.1.31, not a missing feature. Include issues #11224
and #23381 as evidence that the propagation path previously worked.

## References

- [Claude Code Hooks Reference (official)](https://code.claude.com/docs/en/hooks)
- [Biome CLI Reporters](https://biomejs.dev/reference/reporters/)
- [Ruff configuration](https://docs.astral.sh/ruff/configuration/)
- [ShellCheck format flags](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md)
- [GitHub Issue #23381 - PostToolUse hook blocking error displayed twice](https://github.com/anthropics/claude-code/issues/23381)
- [GitHub Issue #18427 - PostToolUse hooks cannot inject context](https://github.com/anthropics/claude-code/issues/18427)
- [GitHub Issue #27314 - Async PostToolUse hook systemMessage not delivered](https://github.com/anthropics/claude-code/issues/27314)
- [GitHub Issue #13650 - SessionStart hook stdout silently dropped](https://github.com/anthropics/claude-code/issues/13650)
- [GitHub Issue #4809 - PostToolUse exit 1 blocks execution](https://github.com/anthropics/claude-code/issues/4809)
- [GitHub Issue #11224 - PostToolUse hook output visibility (v2.0.35)](https://github.com/anthropics/claude-code/issues/11224)
- [GitHub Issue #24788 - PostToolUse additionalContext not surfacing for MCP](https://github.com/anthropics/claude-code/issues/24788)
