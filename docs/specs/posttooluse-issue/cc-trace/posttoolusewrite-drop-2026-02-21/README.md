# PostToolUse Drop Investigation — 2026-02-21

Investigation evidence for the PostToolUse hook stderr silent drop bug
(Claude Code v2.1.50). All tests ran sequentially on macOS Darwin 24.6.0.

## Results Summary

| ID | Investigation | Status | Result |
|----|--------------|--------|--------|
| A1-Write | Edit vs Write (Write) | CONFIRMED | tool_result = standard success only |
| A1-Edit | Edit vs Write (Edit) | INCONCLUSIVE | Model didn't use Edit tool |
| A2 | decision:block schema | CONFIRMED | JSON stdout silently dropped |
| A3-exit1 | exit 1 behavior | CONFIRMED | exit 1 stderr silently dropped |
| A3-exit2 | exit 2 behavior | CONFIRMED | exit 2 stderr silently dropped |
| B1 | Debug four-channel test | NEW — RESOLVED | See below |
| B2 | Newer CC version | N/A | v2.1.50 is latest |
| B3 | Callback interaction | NEW — RESOLVED | See below |
| C1 | rerun_phase2() root cause | NEW — RESOLVED | See below |

## B1: Debug Four-Channel Test Results

PostToolUse hook output IS logged in debug but NEVER propagated to
tool_result. All 4 channels confirmed dropped.

| Channel | Debug logged? | JSON parsed? | "plain text" lines | Propagated? |
|---------|--------------|-------------|-------------------|-------------|
| stderr + exit 2 | YES (error) | N/A | 2 | NO |
| stderr + exit 0 | YES (success) | N/A | 2 | NO |
| JSON + exit 2 | YES (error) | YES | 1 | NO |
| JSON + exit 0 | YES (success) | YES | 1 | NO |

**Key finding**: JSON output IS correctly parsed (debug shows "Checking
initial response for async" → "Parsed initial response" → "not async,
continuing normal processing"). The discard happens in "normal processing"
after the async check.

**Hook count**: 3 PostToolUse hooks match Write (1 custom + 2 internal),
not 2 as previously documented.

## B3: Callback Interaction

No evidence of callback overriding custom hook. All 3 hooks' outputs are
logged but collectively discarded. The bug is in the PostToolUse result
handler's "normal processing" path, not in result merging.

## C1: rerun_phase2() Multi-Line Root Cause

**Root cause**: The `|| echo "[]"` fallback pattern. Linters exit non-zero
when violations are found (normal behavior), triggering the fallback which
appends `[]` to valid JSON output. `jaq 'length'` then processes both JSON
values, producing multi-line output (e.g., `56\n0`).

**Fix**: Change `v=$(cmd || echo "[]")` to `v=$(cmd) || v="[]"` in all
linter captures. Also apply `| tail -1` defensively on line 1280.

**Systemic**: Same bug affects all file types (shellcheck, ruff, hadolint,
ty, bandit) — not just shell files.

## Environment

- Claude Code: v2.1.50 (latest via homebrew)
- macOS: Darwin 24.6.0
- Model: claude-haiku-4-5-20251001
- Mode: `claude -p --output-format stream-json --no-session-persistence`

## Evidence Files

Each subdirectory contains raw artifacts. See individual `analysis.md`
files in B3 and C1 for detailed findings.
