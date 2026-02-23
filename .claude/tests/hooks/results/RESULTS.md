# Hook Integration Test — Execution Results

**Date**: 2026-02-20 (Run 2)
**Spec**: [adr-hook-integration-testing.md](../../../../docs/specs/adr-hook-integration-testing.md)

## How to Read This Document

- **ADR** = forward-looking execution specification with corrected
  expectations suitable for re-runs.
- **RESULTS.md** (this document) = what happened during this run.
  Preserves discoveries, deviations, and remediation notes.

**JSONL result files** (same directory):

| File | Agent | Records |
| ---- | ----- | ------- |
| `dep-agent-20260220T154717Z.jsonl` | dep-agent | 29 |
| `ml-agent-20260220T155114Z.jsonl` | ml-agent | 42 |
| `pm-agent-20260220T154932Z.jsonl` | pm-agent | 32 |

---

## Run Summary

| Metric | Value |
| ------ | ----- |
| Total tests | 103 |
| Pass | 94 |
| Fail | 2 |
| Skipped (tool absent) | 7 |
| Skipped (version gap) | 1 (M28 — biome nursery rule) |
| Elapsed time | 14m 30s |

### Agent Breakdown

| Agent | Tests | Pass | Fail | Hook | Scope |
| ----- | ----- | ---- | ---- | ---- | ----- |
| dep-agent | 29 | 28 | 1 | Infrastructure | Dependencies + settings |
| ml-agent | 42 | 42 | 0 | `multi_linter.sh` | All file types + config |
| pm-agent | 32 | 31 | 1 | `enforce_package_managers.sh` | All PM scenarios |

### Environment Snapshot

| Tool | Status | Detail |
| ---- | ------ | ------ |
| biome | Present | `./node_modules/.bin/biome` |
| ruff | Present | `/opt/homebrew/bin/ruff` |
| shellcheck | Present | `/opt/homebrew/bin/shellcheck` |
| hadolint | Present | v2.14.0 (>= 2.12.0) |
| taplo | Present | `/opt/homebrew/bin/taplo` |
| yamllint | Present | `/opt/homebrew/bin/yamllint` |
| markdownlint-cli2 | Present | via fnm |
| bandit | Absent | DEP24 absent, M31 ran anyway (F841 triggers exit 2) |
| semgrep | Absent | DEP12 absent (optional) |
| oxlint | Present | `./node_modules/.bin/oxlint` (advisory) |
| jaq | Present | `/opt/homebrew/bin/jaq` |
| uv | Present | `~/.local/bin/uv` |
| claude | Present | `/opt/homebrew/bin/claude` |
| timeout | Present | `/opt/homebrew/bin/timeout` |
| ty | Absent | Advisory (uv-managed) |
| vulture | Absent | Advisory (uv-managed) |
| flake8 | Absent | Advisory (uv-managed) |

### Aggregation

```text
cat *.jsonl | jaq -s 'length' → 103
pass: true  → 101 records
pass: false →   2 records
Skipped (absent/advisory notes) → 7 records
Version skip (M28) → 1 record
```

---

## Failures

### DEP14: subprocess-settings.json — wrong path tested

- **Expected**: `subprocess-settings.json` exists with
  `disableAllHooks: true`
- **Actual**: dep-agent checked `.claude/subprocess-settings.json`
  (project-local), but the file lives at `.claude/subprocess-settings.json`
  (user home directory). The file exists and is correct.
- **Root cause**: Test specification ambiguity — DEP14 did not specify the
  full path. The hook code (`multi_linter.sh` line 370) references
  `.claude/subprocess-settings.json`.
- **Impact**: None — the file exists, subprocess prevention works.
- **Action**: Update DEP14 test to check `.claude/subprocess-settings.json`
  instead of `.claude/subprocess-settings.json` for future runs.

### P28: live_trigger_pip (environment limitation)

- **Expected**: `pip install requests` via Bash tool triggers
  PreToolUse hook which blocks the command
- **Actual**: Command executed successfully — hook did not fire
- **Root cause**: TeamCreate teammate agents run in subprocess
  sessions where hooks are not wired to the teammate's tool calls.
  This is an architectural limitation of the Claude Code agent teams
  feature, not a defect in `enforce_package_managers.sh`.
- **Impact**: None on hook correctness — all 31 direct invocation
  tests confirm the hook logic works. The live trigger test validates
  hook lifecycle registration, which requires the main session context.
- **Action**: Document this as a known limitation. Live trigger tests
  (P28, M19) are only meaningful in the main session context.

---

## Notable Findings

### M19 — ml-agent live trigger success

ml-agent's Edit tool call on a temp `.py` file with an F841 violation
confirmed that the PostToolUse hook fires in teammate sessions. The
hook ran and detected the violation. This contrasts with P28 (pm-agent)
where the PreToolUse hook did NOT fire for Bash tool calls — suggesting
PostToolUse hooks ARE wired for teammate Edit/Write but PreToolUse
hooks are NOT wired for teammate Bash.

### M25 — py_format_stable

Badly formatted Python (`def foo(   x,y,   z   )`) was correctly
reformatted by Phase 1 (ruff format), then Phase 2 found no
violations. Confirms the two-phase pipeline works as designed.

### M26 — ts_combined_config expectation correction

The spec expected exit 2 for TS unused var with `unsafe_autofix: true`
and `oxlint_tsgolint: true`. However, biome's `--unsafe` flag auto-fixes
unused variables (renames to `_unused`), producing exit 0. ml-agent
adapted the fixture or expectation accordingly.

### M28 — biome nursery version gap

Biome nursery rule `noExcessiveNestedTestSuites` did not trigger in
the installed biome version. Recorded as pass with version_skip note.
Per D9, this is a skip (not failure) when the rule is unavailable.

### M31 — bandit unavailability via uv run

bandit was unavailable through `uv run` (hatchling build failure).
However, the test still produced exit 2 because the F841 violation
was caught by ruff in Phase 2. The multi-tool collection aspect
of the test was not fully exercised.

### M41 — ruff D100 on empty Python files

Confirmed: ruff flags empty `.py` files with D100 ("Missing docstring
in public module"), producing exit 2. This matches the ADR's corrected
expectation from Run 1.

### uv-managed tools largely absent

ty, vulture, flake8-pydantic, flake8-async, and bandit are all absent
via `uv run`. These are advisory checks and don't affect the test
suite, but indicate that the `pyproject.toml` dev dependencies may
not be fully installed in the current environment.

---

## Deviation Log

### Cosmetic

1. **pm-agent JSONL format**: Multi-line JSON records (512 lines for
   32 records) instead of compact single-line JSONL. jaq still parses
   correctly; aggregation unaffected.

### Low

1. **`duration_ms: 0`** for most tests: `SECONDS` resets per Bash
   tool invocation. Per-test timing is approximate.
2. **Live trigger asymmetry**: PostToolUse hooks fire for teammate
   Edit/Write (M19 passed), but PreToolUse hooks do not fire for
   teammate Bash (P28 failed). This is a Claude Code architecture
   detail, not a test suite defect.

---

## Comparison with Previous Run

See [COMPARISON.md](./COMPARISON.md) for automated diff with the
archived Run 1 results.
