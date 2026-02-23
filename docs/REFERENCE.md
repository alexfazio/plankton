# Plankton - Multi-Linter Hook System

Architecture and reference documentation for the Claude Code hooks that provide
automated code quality enforcement. The hook scripts live in `.claude/hooks/`.

## Architecture

```text
PreToolUse (Edit/Write)   PreToolUse (Bash)         PostToolUse (Edit/Write)   Stop (session end)
         |                        |                           |                       |
         v                        v                           v                       v
protect_linter_configs.sh  enforce_package_managers.sh  multi_linter.sh  stop_config_guardian.sh
         |                        |                      (Three Phases)     (Command Hook)
         v                        v                           |                   |
   File protected?        Cmd uses legacy PM?      +---------+---------+          v
    +- YES -> Block        +- YES -> Block         |         |         |    Detects config
    +- NO -> Allow         +- NO  -> Allow     Phase 1   Phase 2   Phase 3  changes via
                                                Auto-fmt  Collect   Delegate  git diff
                                                (silent)  (JSON)    + Verify
                                                                {decision: approve/block}
                                                    |         |         |
                                                    v         v         v
                                                 Format   violations  claude -p
                                                 applied  as JSON     subprocess
                                                              |         |
                                                              +----+----+
                                                                   v
                                                             Verify: rerun
                                                             Phase 1 + 2
                                                                   |
                                                              +----+----+
                                                              |         |
                                                           count=0   count>0
                                                              |         |
                                                              v         v
                                                           exit 0    exit 2
                                                          (silent)  (report)
```

## Message Flow During Execution

```text
+-------------------------------------------------------------------------------+
|                            EXECUTION TIMELINE                                 |
+-------------------------------------------------------------------------------+

  +-----------+        +-----------+        +-----------+
  |MAIN AGENT |        |   HOOK    |        | SUBPROCESS|
  | (Claude)  |        |  (bash)   |        |(claude -p)|
  +-----+-----+        +-----+-----+        +-----+-----+
        |                    |                    |
        | Edit tool invoked  |                    |
        | -----------------> |                    |
        |                    |                    |
        |              +-----+-----+              |
        |              | PHASE 1   |              |
        |              | (silent)  |              |
        |              +-----+-----+              |
        |                    |                    |
        |              +-----+-----+              |
        |              | PHASE 2   |              |
        |              | (collect) |              |
        |              +-----+-----+              |
        |                    |                    |
        |                    |  spawn_subprocess()|
        |                    | -----------------> |
        |                    |                    |
        |                    |              +-----+-----+
        |                    |              | FIXES     |
        |                    |              | VIOLATIONS|
        |                    |              +-----+-----+
        |                    |                    |
        |                    | <----------------- |
        |                    | (subprocess exits) |
        |                    |                    |
        |              +-----+-----+              |
        |              | VERIFY    |              |
        |              | Phase1+2  |              |
        |              +-----+-----+              |
        |                    |                    |
        | <----------------- |                    |
        | (hook exit+stderr) |                    |
        |                    |                    |
```

## Three-Phase Architecture

The multi-linter hook uses a format-collect-delegate approach:

### Phase 1: Auto-Format (silent)

- Applies automatic formatting to fix common issues
- Runs silently without reporting to Claude
- Reduces subprocess workload by ~40-50%

### Phase 2: Collect Violations (JSON)

- Runs linters to detect remaining issues
- Collects violations as structured JSON with line/column/code/message
- Does NOT report to main agent directly

### Phase 3: Delegate + Verify

- Spawns `claude -p` subprocess with violations JSON
- Subprocess uses Edit tool to fix each violation
- After subprocess exits, re-runs Phase 1 + Phase 2 to verify
- Exit 0 if all fixed, Exit 2 if violations remain

### Python File Flow Detail

```text
Edit/Write on *.py
       |
       v
+--------------------------------------------------------------+
|  PHASE 1: Auto-Format (silent)                               |
|  ------------------------------------------------------------|
|  1. ruff format --quiet (spacing, quotes, line-length)       |
|  2. ruff check --fix --quiet (imports, blank lines)          |
|                                                              |
|  Reduces subprocess workload by ~40-50%                      |
+--------------------------------------------------------------+
       |
       v
+--------------------------------------------------------------+
|  PHASE 2: Collect Violations (JSON)                          |
|  ------------------------------------------------------------|
|  2a. ruff check --preview --output-format=json               |
|  2b. ty check --output-format gitlab (type errors)           |
|  2c. jscpd (duplicate detection, advisory only)              |
|  2d. flake8 --select=PYD (Pydantic validation)               |
|  2e. vulture (dead code detection)                           |
|  2f. bandit (security scanning)                              |
|  2g. flake8-async (async anti-patterns, ASYNC100+)           |
+--------------------------------------------------------------+
       |
       v
+--------------------------------------------------------------+
|  PHASE 3: Delegate + Verify                                  |
|  ------------------------------------------------------------|
|  1. Spawn claude -p subprocess with violations JSON          |
|  2. Subprocess uses Edit to fix each violation               |
|  3. Re-run Phase 1 (ruff format + ruff check --fix)          |
|  4. Re-run Phase 2 to count remaining violations             |
|  5. Exit 0 if fixed, Exit 2 if violations remain            |
+--------------------------------------------------------------+
```

### TypeScript/JS/CSS File Flow Detail

```text
Edit/Write on *.ts/*.tsx/*.js/*.jsx/*.mjs/*.cjs/*.mts/*.cts/*.css
       |
       v
+--------------------------------------------------------------+
|  PHASE 1: Auto-Format (silent)                               |
|  ------------------------------------------------------------|
|  1. biome check --write (format + safe lint fixes)           |
|     Optional: --unsafe (biome_unsafe_autofix config)         |
|                                                              |
|  Uses detect_biome() for JS runtime auto-detection           |
+--------------------------------------------------------------+
       |
       v
+--------------------------------------------------------------+
|  PHASE 2: Collect Violations (JSON)                          |
|  ------------------------------------------------------------|
|  2a. biome lint --reporter=json (blocking)                   |
|  2b. Nursery advisory count (biome_nursery config)           |
|  2c. Semgrep session-scoped (after 3+ files, advisory)       |
|  2d. jscpd session-scoped (after 3+ files, advisory)         |
+--------------------------------------------------------------+
       |
       v
+--------------------------------------------------------------+
|  PHASE 3: Delegate + Verify                                  |
|  ------------------------------------------------------------|
|  1. Spawn claude -p subprocess with violations JSON          |
|  2. Subprocess uses Edit to fix each violation               |
|  3. Re-run Phase 1 (biome check --write)                     |
|  4. Re-run Phase 2 to count remaining violations             |
|  5. Exit 0 if fixed, Exit 2 if violations remain            |
+--------------------------------------------------------------+
```

**SFC Handling** (`.vue`, `.svelte`, `.astro`): These Single-File Component
formats are not fully supported by Biome. They receive Semgrep-only coverage
with a one-time warning per extension per session.

**Nursery Rules**: Biome nursery rules are experimental and configurable via
`biome_nursery` in config.json: `"off"` (skip), `"warn"` (advisory count),
or `"error"` (blocking). The hook validates that config.json and biome.json
nursery settings are in sync.

## Message Styling

Hook messages use prefixed format for severity classification:

### Marked Format (Hook-Specific)

All hook messages use `[hook:]` prefix with severity:

```text
[hook:error] claude binary not found, cannot delegate
[hook:warning] hadolint 2.10.0 < 2.12.0 (some features may not work)
[hook:advisory] Duplicate code detected
[hook] 3 violation(s) remain after delegation
```

| Prefix | Meaning | Exit Code |
| --- | --- | --- |
| `[hook:block]` | PreToolUse block — command blocked, replacement shown | 0 |
| `[hook:error]` | Fatal error, cannot proceed | 2 |
| `[hook:warning]` | Non-fatal issue, continues | 0 or 2 |
| `[hook:advisory]` | Informational only | 0 |
| `[hook]` | Violations remain after delegation | 2 |

### Subprocess Prompt

The subprocess receives violations as JSON with explicit rules:

```text
You are a code quality fixer. Fix ALL violations listed below in ${file}.

VIOLATIONS:
[{"line": 15, "column": 5, "code": "F841", "message": "...", "linter": "ruff"}]

RULES:
1. Use targeted Edit operations only - never rewrite the entire file
2. Fix each violation at its reported line/column
3. After fixing, run the formatter: ${format_cmd}
4. Verify by re-running the linter
5. If a violation cannot be fixed, explain why
```

This prompt embeds the Boy Scout Rule ("Fix ALL") and targeted edit strategy.

### Detailed Subprocess Prompt Examples

**For Python files:**

```text
You are a code quality fixer. Fix ALL violations listed below in ./path/to/file.py.

VIOLATIONS:
[
  {
    "line": 15,
    "column": 5,
    "code": "F841",
    "message": "Local variable `unused_var` is assigned to but never used",
    "linter": "ruff"
  },
  {
    "line": 23,
    "column": 12,
    "code": "unresolved-attribute",
    "message": "Cannot access attribute `foo` on type `None`",
    "linter": "ty"
  },
  {
    "line": 45,
    "column": 1,
    "code": "PYD002",
    "message": "Field default should use Field() with default parameter",
    "linter": "flake8-pydantic"
  }
]

RULES:
1. Use targeted Edit operations only - never rewrite the entire file
2. Fix each violation at its reported line/column
3. After fixing, run the formatter:
   ruff format './path/to/file.py'
4. Verify by re-running the linter
5. If a violation cannot be fixed, explain why

Do not add comments explaining fixes. Do not refactor beyond what's needed.
```

**For Shell files:**

```text
VIOLATIONS:
[
  {"line": 12, "column": 1, "code": "SC2034", "message": "UNUSED_VAR appears unused.", "linter": "shellcheck"},
  {"line": 25, "column": 8, "code": "SC2086", "message": "Double quote to prevent globbing.", "linter": "shellcheck"}
]

RULES:
...
3. After fixing, run the formatter: shfmt -w -i 2 -ci -bn './path/to/file.sh'
```

**For Dockerfile:**

```text
VIOLATIONS:
[
  {"line": 1, "column": 1, "code": "DL3007", "message": "Using latest is prone to errors.", "linter": "hadolint"},
  {"line": 1, "column": 1, "code": "DL3049", "message": "Label `maintainer` is missing.", "linter": "hadolint"}
]
```

**For TypeScript/JS/CSS files:**

```text
VIOLATIONS:
[
  {"line": 5, "column": 7, "code": "lint/correctness/noUnusedVariables", "message": "This variable is unused.", "linter": "biome"},
  {"line": 12, "column": 15, "code": "lint/suspicious/noDoubleEquals", "message": "Use === instead of ==.", "linter": "biome"}
]

RULES:
...
3. After fixing, run the formatter: biome format --write './path/to/file.ts'
```

**Note:** `format_cmd` is empty for YAML and Dockerfile (no auto-formatter available).

## What Each Agent Sees

### Main Agent Visibility

| Scenario | Message | Exit |
| --- | --- | --- |
| No violations | (nothing) | 0 |
| Violations fixed by subprocess | (nothing) | 0 |
| Violations remain after subprocess | `[hook] N remain` | 2 |
| jscpd duplicates found | `[hook:advisory]...` | 0/2 |
| hadolint too old | `[hook:warning]...` | 0/2 |
| claude not found | `[hook:error]...` | 2 |

### Subprocess Visibility

The subprocess receives ONLY the prompt and has access to:

- **Tools**: Per-tier (haiku/sonnet: `Edit,Read`; opus: `Edit,Read,Write`)
- **Max turns**: Per-tier (haiku/sonnet: 10; opus: 15)
- **File context**: The file path is passed as an argument

The subprocess does **NOT** see:

- Main agent's conversation history
- Other files edited in the session
- Any hook output

### Subprocess Invisibility Model

```text
+-----------------------------------------------------------------------------+
|                     VISIBILITY MODEL                                        |
+-----------------------------------------------------------------------------+
|                                                                             |
|  MAIN AGENT CONTEXT:                                                        |
|  -------------------                                                        |
|  [User message]                                                             |
|  [Assistant response + Edit tool call]                                      |
|  [Edit tool result]                                                         |
|  [Hook stderr if exit 2] <-- ONLY THIS from hook                            |
|  [Assistant continues...]                                                   |
|                                                                             |
|  SUBPROCESS CONTEXT (completely separate):                                  |
|  -----------------------------------------                                  |
|  [Prompt: "You are a code quality fixer..."]                                |
|  [Subprocess response + Edit tool call]                                     |
|  [Edit tool result]                                                         |
|  [Subprocess response + Read tool call]                                     |
|  [Read tool result]                                                         |
|  ... (up to max_turns per tier)                                             |
|  [Subprocess exits]                                                         |
|                                                                             |
|  Main agent NEVER sees subprocess context.                                  |
|  Subprocess stdout discarded (>/dev/null); stderr flows to hook             |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### Hook Internal Visibility

The hook (bash script) sees:

- **Stdin**: JSON with `tool_input.file_path`
- **Linter outputs**: JSON format from each linter
- **Subprocess exit code**: Captured and logged (timeout=124, errors=non-zero)
- **Verification counts**: From `rerun_phase2()`

### Quick Reference

| Question | Answer |
| --- | --- |
| Who generates structured JSON? | Hook (bash) runs linters with JSON flags |
| Why JSON instead of raw output? | Unified format for line/column parsing |
| How does main agent receive messages? | Via stderr when hook exits code 2 |
| Is main agent blocked? | Yes, hooks are synchronous |
| Does main agent see subprocess work? | No, output discarded (`>/dev/null`) |

## All Possible Messages

| # | Message | Location | Trigger | Dest |
| --- | --- | --- | --- | --- |
| 1 | Hook input JSON | stdin | Always | Hook |
| 2 | Subprocess prompt | `spawn_fix_subprocess()` | has_issues | Subprocess |
| 3 | `[hook:advisory]...` | `_handle_jscpd_ts_session()` | jscpd | stderr |
| 4 | `[hook:warning]...` | Dockerfile handler | Old hadolint | stderr |
| 5 | `[hook:error]...` | `spawn_fix_subprocess()` | No claude | stderr |
| 6 | `[hook] N remain` | Main verification flow | Verify fails | stderr |

## Exit Code Strategy

| Exit | Meaning | Main Agent Sees |
| --- | --- | --- |
| 0 | No issues, or subprocess fixed all | Nothing |
| 2 | Violations remain after delegation | `[hook] N remain` |

**Key behavior**: The hook delegates to subprocess first. Exit 2 only
occurs if violations **remain after** the subprocess attempts fixes.
All output goes to stderr.

> **Known behavior (CC v2.1.50)**: Exit 2 stderr does NOT appear in
> the `tool_result` field. However, mitmproxy evidence confirms it IS
> delivered as a `<system-reminder>` text block in the same API message.
> The model can read this content but may not reliably act on it.
> See `docs/specs/posttooluse-issue/make-plankton-work.md` for status.

**Note on Exit 2 rarity**: In practice, exit 2 is rare because the subprocess
is highly effective. It has full Edit tool access and will aggressively fix
violations - including deleting problematic code, refactoring entire functions,
or removing unused imports. Exit 2 typically only occurs when:

- Subprocess times out (max 10 turns exceeded)
- File permission errors prevent editing
- Conflicting fixes where fix A breaks fix B
- Linter false positives that cannot be resolved

## Hook Execution Model

Hooks are **SYNCHRONOUS**. The main agent is **BLOCKED** until the hook
completes:

```text
+-----------------------------------------------------------------------------+
|                         HOOK EXECUTION MODEL                                |
+-----------------------------------------------------------------------------+
|                                                                             |
|  MAIN AGENT              CLAUDE CODE              HOOK                      |
|      |                       |                      |                       |
|      | "Edit file.py"        |                      |                       |
|      | ------------------->  |                      |                       |
|      |                       |                      |                       |
|      |                       | Execute Edit         |                       |
|      |                       | (file modified)      |                       |
|      |                       |                      |                       |
|      |                       | Run PostToolUse hook |                       |
|      |                       | ------------------->  |                       |
|      |                       |                      |                       |
|      |  +------------------------------------------+|                       |
|      |  | MAIN AGENT IS BLOCKED HERE               ||                       |
|      |  | Cannot proceed until hook returns        ||                       |
|      |  | No other tools can be invoked            ||  (hook running)       |
|      |  | No responses can be generated            ||  Phase 1...           |
|      |  +------------------------------------------+|  Phase 2...           |
|      |                       |                      |  Subprocess...        |
|      |                       |                      |  Verify...            |
|      |                       |                      |                       |
|      |                       | <------------------- |                       |
|      |                       | exit code + stderr   |                       |
|      |                       |                      |                       |
|      | <------------------   |                      |                       |
|      | Tool result + hook    |                      |                       |
|      | output (if exit 2)    |                      |                       |
|      |                       |                      |                       |
|      | (now unblocked,       |                      |                       |
|      |  can continue)        |                      |                       |
|      |                       |                      |                       |
|                                                                             |
+-----------------------------------------------------------------------------+
```

When exit code is 2, Claude Code shows:

```text
PostToolUse:Edit hook error: Failed with non-blocking status code 2
[hook] 3 violation(s) remain after delegation
```

### Complete Timeline with Blocking

```text
+-----------------------------------------------------------------------------+
|                    COMPLETE TIMELINE WITH BLOCKING                          |
+-----------------------------------------------------------------------------+
|                                                                             |
|  T=0s     Main agent invokes Edit on file.py                                |
|           -------------------------------------------                       |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=0.1s   Claude Code executes Edit (file modified)                         |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=0.2s   Hook starts                                                       |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=0.5s   Phase 1: ruff format + ruff check --fix                           |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=1.0s   Phase 2: Collect violations (ruff, ty, flake8, vulture, bandit)   |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=1.5s   Hook spawns subprocess: claude -p "..."                           |
|           Main agent: BLOCKED                                               |
|           Hook: BLOCKED (waiting for subprocess)                            |
|                                                                             |
|  T=1.5s   Subprocess starts, reads prompt                                   |
|  to       Subprocess uses Edit/Read to fix violations (per-tier tools)      |
|  T=25s    (subprocess works autonomously)                                   |
|           Main agent: BLOCKED                                               |
|           Hook: BLOCKED                                                     |
|                                                                             |
|  T=25s    Subprocess exits                                                  |
|           Main agent: BLOCKED                                               |
|           Hook: UNBLOCKED                                                   |
|                                                                             |
|  T=25.5s  Hook runs rerun_phase1() + rerun_phase2()                         |
|           Main agent: BLOCKED                                               |
|                                                                             |
|  T=26s    Hook exits with code 0 or 2                                       |
|           Main agent: UNBLOCKED                                             |
|                                                                             |
|  T=26s+   Main agent continues execution                                    |
|           - If exit 0: proceeds normally                                    |
|           - If exit 2: sees "[hook] N violation(s) remain..."               |
|                        may attempt manual fix or continue                   |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### Scenario: Violations Fixed Successfully

```text
+-------------------------------------------------------------------------------+
|                           SCENARIO: Python File with Violations                |
+-------------------------------------------------------------------------------+

MAIN AGENT                          HOOK                              SUBPROCESS
    |                                |                                    |
    |  Edit ./path/to/foo.py         |                                    |
    | -----------------------------> |                                    |
    |                                |                                    |
    |                          stdin: {"tool_input":                      |
    |                                  {"file_path":"./path/to/foo.py"}}  |
    |                                |                                    |
    |                                +-- Phase 1: ruff format (silent)    |
    |                                +-- Phase 1: ruff check --fix        |
    |                                |                                    |
    |                                +-- Phase 2: ruff check -> JSON      |
    |                                +-- Phase 2: ty check -> JSON        |
    |                                +-- Phase 2: flake8 --select=PYD     |
    |                                |                                    |
    |                                |   collected_violations = [...]     |
    |                                |   has_issues = true                |
    |                                |                                    |
    |                                |  claude -p "You are a code..."     |
    |                                | ---------------------------------> |
    |                                |                                    |
    |                                |                              Subprocess
    |                                |                              reads file,
    |                                |                              uses Edit
    |                                |                              to fix
    |                                |                                    |
    |                                | <--------------------------------- |
    |                                |  (subprocess exits)                |
    |                                |                                    |
    |                                +-- rerun_phase1()                   |
    |                                +-- rerun_phase2() -> count = 0      |
    |                                |                                    |
    | <----------------------------- |                                    |
    |  (exit 0, no stderr)           |                                    |
    |                                |                                    |
    |  Edit completed                |                                    |
    |                                |                                    |
```

### Scenario: Violations Remain After Subprocess

```text
+-------------------------------------------------------------------------------+
|                    SCENARIO: Violations Remain After Subprocess                |
+-------------------------------------------------------------------------------+

MAIN AGENT                          HOOK                              SUBPROCESS
    |                                |                                    |
    |  ... (same as above) ...       |                                    |
    |                                |                                    |
    |                                +-- rerun_phase1()                   |
    |                                +-- rerun_phase2() -> count = 2      |
    |                                |                                    |
    | <----------------------------- |                                    |
    |  stderr: "[hook] 2 violation(s)|                                    |
    |           remain after         |                                    |
    |           delegation"          |                                    |
    |  exit 2                        |                                    |
    |                                |                                    |
    |  Main agent sees error,        |                                    |
    |  may attempt manual fix        |                                    |
    |                                |                                    |
```

## Linter Behavior by File Type

| Type | Phase 1: Auto-Format | Phase 2: Collect Violations |
| --- | --- | --- |
| Python | `ruff format` + `--fix` | Ruff+ty+pydantic+vulture+bandit+async*** |
| Shell (.sh/.bash) | `shfmt -w` | ShellCheck semantic |
| TS/JS/CSS | `biome check --write` | Biome lint+nursery+Semgrep+jscpd** |
| JSON | `jaq '.'` or `biome format`* | Syntax errors |
| TOML | `taplo fmt` | Syntax errors |
| Markdown (.md/.mdx) | `markdownlint --no-globs --fix` | Unfixable rules |
| YAML | (none) | All yamllint issues |
| Dockerfile | (none) | All hadolint issues |

**Phase 3** applies to all file types: collected violations are passed to the
subprocess for fixing, then verified.

**\*\* Semgrep and jscpd run in advisory/session-scoped mode** for TS/JS/CSS
files (separate session tracking from Python). Semgrep requires `.semgrep.yml`
in the project root and runs after 3+ TS files modified.

**\* JSON formatting** uses Biome when TypeScript is enabled and Biome is
available (D6), falling back to jaq pretty-print otherwise.

**Note on Markdown --no-globs**: The hook uses `--no-globs` to disable config
globs from `.markdownlint-cli2.jsonc`. Without this flag, markdownlint-cli2
merges the explicit file path with config globs, causing it to lint many files
instead of just the edited file.

**\*\*\* jscpd runs in advisory mode** - reports duplicates but does not block.
Session-scoped (runs once after 3+ Python files modified). See "Note on jscpd"
below for details. flake8-async checks for async anti-patterns (ASYNC100+).

**Dockerfile Pattern Matching:** The hook recognizes these patterns:

- `Dockerfile` - Standard Dockerfile
- `Dockerfile.*` - Named variants (e.g., `Dockerfile.nginx`)
- `*/Dockerfile` - Dockerfiles in subdirectories
- `*/Dockerfile.*` - Named variants in subdirectories
- `*.dockerfile` - Alternative extension

### Subprocess Fix Strategies

The subprocess (Phase 3) uses different strategies depending on violation type:

| Violation | Model | Fix Strategy |
| --- | --- | --- |
| F841 (unused variable) | Haiku | Delete the assignment line |
| C901 (complexity) | Sonnet | Refactor to early returns |
| PLR0913 (too many args) | Sonnet | Group params into dataclass |
| Type errors (None access) | Sonnet | Add None checks, type guards |
| SC2086 (unquoted var) | Haiku | Add quotes: `$VAR` -> `"${VAR}"` |
| Unresolved import | Sonnet | Remove import and dependent code |
| YAML indentation | Haiku | Fix spacing to match style |
| D401 (imperative mood) | Sonnet | Rewrite "Returns" -> "Return" |
| D417 (missing Args) | Sonnet | Add Args section from signature |
| D205/D400/D415 | Sonnet | Fix formatting/punctuation |
| ASYNC100+ (async anti-patterns) | Sonnet | Fix async/await misuse |
| FAST001-003 (FastAPI patterns) | Sonnet | Fix FastAPI-specific issues |

**Important**: The subprocess prioritizes linter satisfaction over code
preservation. It will delete entire functions or imports if that's the
simplest way to resolve a violation. This is intentional - the hook enforces
the Boy Scout Rule aggressively.

### Phase 1 vs Phase 3 Fix Scope

Not all violations require the subprocess. Phase 1 auto-formatters handle
many issues silently:

| Fixed by Phase 1 (auto-format) | Requires Phase 3 (subprocess) |
| --- | --- |
| Import sorting (I001) | Unused variables (F841)* |
| Blank lines (E302, E303) | Complexity (C901, PLR*) |
| Trailing whitespace | Type errors (ty) |
| Quote style | Pydantic issues (PYD*) |
| Indentation (Python) | Unresolved imports |
| JSON/TOML formatting | ShellCheck semantic issues |
| D400/D415 (punctuation)** | D401/D417 (semantic docstrings) |
| | Async anti-patterns (ASYNC100+) |
| | FastAPI patterns (FAST001-003) |

*F841 has an "unsafe" fix in ruff that Phase 1 skips; subprocess handles it.
**D400/D415 have auto-fixes in ruff; D401/D417 require semantic understanding.

## Files

| File | Description |
| --- | --- |
| `multi_linter.sh` | PostToolUse hook - lints edited files |
| `protect_linter_configs.sh` | PreToolUse hook - blocks config & hook edits |
| `enforce_package_managers.sh` | PreToolUse - blocks legacy package managers |
| `stop_config_guardian.sh` | Stop hook - detects config changes |
| `approve_configs.sh` | Helper - creates guard file for stop hook |
| `test_hook.sh` | Debug utility with `--self-test` suite |
| `config.json` | Runtime configuration for all hooks |

## Debugging

### View registered hooks

```bash
# In Claude Code session
/hooks
```

### Debug mode

```bash
claude --debug "hooks" --verbose
```

### Test hook manually

```bash
# Test single file
.claude/hooks/test_hook.sh path/to/file.sh

# Run comprehensive self-test suite
.claude/hooks/test_hook.sh --self-test
```

### Self-Test Suite

The `--self-test` flag runs automated tests covering multi-linter behavior,
package manager enforcement, model selection, and TypeScript integration.

See [Testing Guide](tests/README.md#self-test-suite) for the full test catalog.

### Log location

```text
~/.claude/debug/
```

## Investigation Principles

When debugging hook behavior or unexpected agent responses:

1. **Verify the actual problem before implementing workarounds.**
   Test whether the existing mechanism works under controlled
   conditions before building alternatives. A clean reproduction
   test is faster than a workaround and may reveal the problem
   is elsewhere.
2. **Rank evidence sources.** Higher-ranked evidence overrides
   lower: mitmproxy API capture (definitive) > controlled
   reproduction > source code reading > JSONL forensics
   (incomplete) > terminal observation > GitHub issues
   (unreviewed).
3. **Test before you gate.** If a delivery mechanism appears
   broken, run a controlled test with clean output before
   adding gates or workarounds.

See `docs/specs/posttooluse-issue/make-plankton-work.md`
(Evidence Hierarchy table) for the full ranked matrix.

## Testing Hooks Manually

See [Testing Guide](tests/README.md#testing-hooks-manually) for manual testing
examples covering PostToolUse, PreToolUse, and Stop hooks.

## Hook Schema Reference

### CC Specification (Official)

Per [official Claude Code docs](https://code.claude.com/docs/en/hooks)
(verified against CC v2.1.50):

| Hook Type | Spec Schema | Exit Code |
| --- | --- | --- |
| PreToolUse | `hookSpecificOutput.permissionDecision` (allow/deny/ask) | 0 |
| PostToolUse | `{"decision": "block", "reason": "..."}` | 0 or 2 |
| Stop | `{"decision": "block", "reason": "..."}` | 0 |

**PreToolUse** uses `hookSpecificOutput` with `permissionDecision`
(allow/deny/ask) and `permissionDecisionReason`. The older top-level
`decision`/`reason` fields are deprecated for PreToolUse.

### What This Project's Hooks Actually Output

| Hook | Actual Output | Format |
| --- | --- | --- |
| `protect_linter_configs.sh` | `{"decision": "block/approve"}` | Legacy* |
| `enforce_package_managers.sh` | `{"decision": "block/approve"}` | Legacy* |
| `multi_linter.sh` | stderr + exit code | Exit 0/2 |
| `stop_config_guardian.sh` | `{"decision": "block/approve"}` | Matches spec |

**\*Legacy**: The PreToolUse hooks use the older `{"decision": "block"}`
format rather than the newer `hookSpecificOutput.permissionDecision` format.
Both work in CC v2.1.50 — the deprecated format is still accepted.

**PostToolUse behavior**: Exit 0 = no issues. Exit 2 = stderr fed to Claude
(non-blocking, tool already ran).

> **Known behavior (CC v2.1.50)**: PostToolUse output does not appear
> in `tool_result` but stderr+exit2 IS delivered via `<system-reminder>`
> text block. See `docs/specs/posttooluse-issue/` for details.

## Hook Invocation Behavior

The PreToolUse hook fires on **all** Edit/Write operations, not just protected
files. This is by design -- Claude Code matchers only support tool names, not file
paths.

**What you see:**

```text
Write(src/app/utils.py)
  PreToolUse:Write hook succeeded: Success
```

**What it means:**

- "Succeeded" = hook ran and returned a decision
- For non-protected files: hook approves immediately (fast path)
- For protected files: hook denies with reason

The hook uses internal filtering (path/basename matching) to determine
protection. This architecture is intentional and provides maximum flexibility
for file-level logic.

## Configuration

Hooks are configured in `.claude/settings.json`:

- `hooks.PreToolUse`: Command hook for file-level protection (blocks edits)
- `hooks.PostToolUse`: Command hook for linting (Edit/Write matcher)
- `hooks.Stop`: Command hook for config restoration (detects changes via git)

## Runtime Configuration (config.json)

The hooks read `.claude/hooks/config.json` at startup for runtime configuration.
If the file is missing, all features are enabled with sensible defaults.

### Configuration Options

| Key | Type | Default | Purpose |
| --- | ---- | ------- | ------- |
| `languages.<type>` | bool | true | Per-language on/off toggle |
| `languages.typescript` | object | — | TS/JS/CSS config (sub-options below) |
| `…typescript.enabled` | bool | false | Enable TS/JS/CSS linting |
| `…typescript.js_runtime` | string | "auto" | JS runtime: auto/node/bun/pnpm |
| `…typescript.biome_nursery` | string | "warn" | Nursery: off/warn/error |
| `…ts.biome_unsafe_autofix` | bool | false | Allow Biome unsafe fixes |
| `…ts.oxlint_tsgolint` | bool | false | Enable oxlint/tsgolint |
| `…typescript.tsgo` | bool | false | Enable tsgo type checking |
| `…typescript.semgrep` | bool | true | Semgrep session scan for TS/JS |
| `…typescript.knip` | bool | false | Enable Knip dead code detection |
| `protected_files` | str[] | 14 configs | Linter configs protected from edits |
| `exclusions` | str[] | tests/,… | Directories excluded from security linters |
| `phases.auto_format` | bool | true | Phase 1 auto-format |
| `phases.subprocess_delegation` | bool | true | Phase 3 subprocess delegation |
| `hook_enabled` | bool | true | Master kill switch (disables all linting) |
| `subprocess.tiers` | object | — | Per-tier subprocess config (see [Phase 3 Subprocess](#phase-3-subprocess)) |
| `subprocess.global_model_override` | string\|null | null | One model |
| `subprocess.volume_threshold` | number | 5 | Violations that trigger opus |
| `subprocess.settings_file` | string\|null | null | Override settings path |
| `jscpd.session_threshold` | number | 3 | Files modified before jscpd runs |
| `jscpd.scan_dirs` | str[] | ["src/","lib/"] | Dirs to scan for dupes |
| `jscpd.advisory_only` | bool | true | Report-only mode (no blocking) |
| `package_managers.python` | str\|false | "uv" | Python PM: uv/uv:warn/off |
| `package_managers.javascript` | str\|false | "bun" | JS PM: bun/bun:warn/off |
| `…allowed_subcommands.<tool>` | str[] | (varies) | Exempt subcommands |

### Example: Disable Markdown Linting

```json
{
  "languages": {
    "markdown": false
  }
}
```

Environment variables override config.json values:

- `HOOK_SUBPROCESS_TIMEOUT` overrides per-tier timeout (and `timeout_override`)
- `HOOK_SKIP_SUBPROCESS=1` disables subprocess regardless of config

### Package Manager Enforcement

The `package_managers` section configures `enforce_package_managers.sh`, which
intercepts legacy package manager commands in Claude's Bash tool before execution.

**Three enforcement modes** (per ecosystem):

| Value | Behavior |
| --- | --- |
| `"uv"` / `"bun"` | Block command, suggest replacement |
| `"uv:warn"` / `"bun:warn"` | Allow command, emit `[hook:advisory]` to stderr |
| `false` | Enforcement disabled for this ecosystem |

**Disable Python enforcement:**

```json
{
  "package_managers": {
    "python": false
  }
}
```

**Enable warn mode for migration:**

```json
{
  "package_managers": {
    "python": "uv:warn",
    "javascript": "bun:warn"
  }
}
```

**Environment variable overrides:**

- `HOOK_SKIP_PM=1` — bypass all package manager enforcement for the session
  (`HOOK_SKIP_PM=1 claude ...`)
- `HOOK_DEBUG_PM=1` — log matching decisions to stderr for troubleshooting
- `HOOK_LOG_PM=1` — log all decisions to `/tmp/.pm_enforcement_<pid>.log`

## Defense in Depth: Prevention + Recovery

The hooks use a two-layer protection strategy:

| Layer | Hook | When | Purpose |
| --- | --- | --- | --- |
| 1 | PreToolUse | Before edit | Block ALL edits to config files |
| 2 | Stop | Session end | Detect changes, offer restoration |

**Layer 1: PreToolUse** (`protect_linter_configs.sh`):

- Blocks modifications to entire files:
  - `.markdownlint.jsonc`
  - `.markdownlint-cli2.jsonc`
  - `.shellcheckrc`
  - `.yamllint`
  - `.hadolint.yaml`
  - `.jscpd.json`
  - `.flake8`
  - `taplo.toml`
  - `.ruff.toml`
  - `ty.toml`
  - `biome.json`
  - `.oxlintrc.json`
  - `.semgrep.yml`
  - `knip.json`
  - `.claude/hooks/*` (entire hooks directory)
  - `.claude/settings.json` (Claude Code settings)
  - `.claude/settings.local.json` (local overrides)
- Some protected files (e.g., `biome.json`, `.oxlintrc.json`, `.semgrep.yml`,
  `knip.json`) may not yet exist in the repo but are pre-configured so they are
  immediately protected when the corresponding linter is enabled
- Returns `{"decision": "block"}` to prevent edit
- User can explicitly approve blocked edits (override)

**Layer 2: Stop** (`stop_config_guardian.sh`):

- Runs when session ends
- Uses `git diff` to detect modified config files (programmatic, no LLM)
- If changes detected:
  1. Checks hash-based guard file for prior approval
  2. If hashes match -> allows session to end (no re-prompt)
  3. If no guard or hash mismatch -> blocks and prompts user
  4. Claude uses AskUserQuestion to ask user
  5. User chooses: restore to last commit OR keep changes
  6. If keep: creates guard file with content hashes via `approve_configs.sh`
  7. If restore: runs `git checkout -- <file>` for each modified file
- Catches user-approved edits that bypassed PreToolUse

**Why both?** PreToolUse prevents tampering in real-time. Stop provides a
safety net for user-approved changes, allowing undo before session ends.

### Stop Hook Architecture

```text
+-------------------------------------------------------------------------+
|                    STOP HOOK ARCHITECTURE                               |
+-------------------------------------------------------------------------+
|                                                                         |
|  DETECTION (programmatic - no LLM):                                     |
|  ----------------------------------                                     |
|                                                                         |
|    stop_config_guardian.sh                                              |
|           |                                                             |
|           +-- git diff --name-only -- .yamllint                         |
|           +-- git diff --name-only -- .flake8                           |
|           +-- git diff --name-only -- .shellcheckrc                     |
|           +-- git diff --name-only -- ...                               |
|           |                                                             |
|           v                                                             |
|    Modified files? --NO--> {"decision": "approve"}                      |
|           |                                                             |
|          YES                                                            |
|           |                                                             |
|           v                                                             |
|    Guard file exists? (/tmp/stop_hook_approved_${PPID}.json)            |
|           |                                                             |
|    +------+------+                                                      |
|   YES            NO                                                     |
|    |              |                                                     |
|    v              |                                                     |
|  Hashes match?    |                                                     |
|    |              |                                                     |
|  +-+-+            |                                                     |
| YES  NO           |                                                     |
|  |    |           |                                                     |
|  v    v           v                                                     |
| approve  -------> {"decision": "block", ...}                            |
|                                                                         |
|  -------------------------------------------------------------------   |
|                                                                         |
|  USER INTERACTION (LLM - only AFTER detection):                         |
|  -----------------------------------------------                        |
|                                                                         |
|    Claude receives reason (directive)                                   |
|           |                                                             |
|           v                                                             |
|    Uses AskUserQuestion tool                                            |
|           |                                                             |
|           v                                                             |
|    User responds                                                        |
|           |                                                             |
|     +-----+-----+                                                       |
|  "Keep"      "Restore"                                                  |
|     |           |                                                       |
|     v           v                                                       |
|  approve_configs.sh    git checkout -- <files>                          |
|  (creates guard file)                                                   |
|                                                                         |
+-------------------------------------------------------------------------+
```

### Hash-Based Guard Mechanism

The stop hook uses content hashes to prevent re-prompting when the user has
already approved config modifications within the same session:

**Guard File**: `/tmp/stop_hook_approved_${PPID}.json`

```json
{
  "approved_at": "2026-01-04T19:48:11Z",
  "files": {
    ".yamllint": "sha256:ffb4f4f50a840ec57276cb67c848bd5239ad25af01411d65ee984ca177077c7c"
  }
}
```

**Behavior**:

| Scenario | Guard File | Hashes | Decision |
| --- | --- | --- | --- |
| First session end | None | N/A | Block, prompt user |
| Same content, same session | Exists | Match | Approve (no re-prompt) |
| New content after approval | Exists | Mismatch | Block, re-prompt |
| Different session | None (PPID changed) | N/A | Block, prompt user |

**Helper Script**: `approve_configs.sh` creates the guard file when user
selects "Keep changes". Claude invokes it via:

```bash
.claude/hooks/approve_configs.sh ${PPID} .yamllint .flake8
```

This prevents the "flaky re-prompting" issue where the stop hook would ask
about the same unchanged files multiple times within a session.

## Stop Hook Schema

The Stop hook MUST return JSON matching this schema:

```json
{"decision": "approve"}
{"decision": "block", "reason": "...", "systemMessage": "..."}
```

- `decision`: "approve" (allow session to end) or "block" (prevent exit)
- `reason`: Directive that Claude reads to know how to proceed
- `systemMessage`: User-facing warning message (advisory)

### Field Semantics

**Important**: When forcing tool use (like AskUserQuestion), put the instruction
in `reason`, not `systemMessage`:

- **`reason`**: What Claude reads for its next action. Put tool invocation
  directives here (e.g., "Use AskUserQuestion tool NOW").
- **`systemMessage`**: Shown to the user as context. Keep brief and
  informational.

Claude may ignore instructions in `systemMessage` if it has prior context about
the changes. The `reason` field is authoritative for Claude's behavior.

**Note**: Stop hooks use the same `decision` field as PreToolUse, not `ok`.

**Loop Prevention**: Stop hooks receive a `stop_hook_active` boolean
in their input JSON. When `true`, Claude Code is continuing from a prior
stop hook block. Your hook MUST check this and return `{"decision": "approve"}`
to prevent infinite loops:

```bash
input=$(cat)
stop_hook_active=$(jaq -r '.stop_hook_active // false' <<<"${input}")
[[ "${stop_hook_active}" == "true" ]] && echo '{"decision": "approve"}' && exit 0
```

## Model Configuration

**Note**: All hooks in this project use command type (`"type": "command"`), not
prompt type. The model configuration below applies to prompt-type hooks and is
documented here for reference.

Prompt hooks support an optional `model` field:

```json
{
  "type": "prompt",
  "model": "claude-sonnet-4-5-20250929",
  "prompt": "...",
  "timeout": 60
}
```

- Default: Haiku (fast, small model)
- Sonnet: Better reasoning for complex validation
- Opus: Maximum capability (if available)

## Dependencies

**Required:**

- `jaq` - JSON parsing (Rust jq alternative)
- `ruff` - Python formatting and linting
- `uv` - Python tool runner (invokes ty, pydantic, vulture, bandit, flake8-async)
- `claude` - Claude Code CLI (for subprocess delegation)

**Optional (gracefully skipped if not installed):**

- `ty` - Python type checking (Astral's Rust-based type checker)
- `pydantic` - Pydantic model linting (via flake8)
- `vulture` - Dead code detection (uses `vulture_whitelist.py` for false positives)
- `bandit` - Security scanning (uses `pyproject.toml [tool.bandit]`)
- `flake8-async` - Async anti-pattern detection (ASYNC100+)
- `shfmt` - Shell script formatting
- `shellcheck` - Shell script linting
- `yamllint` - YAML linting (baseline fully enforced)
- `hadolint` - Dockerfile linting (>= 2.12.0 recommended)
- `taplo` - TOML formatting and linting
- `markdownlint-cli2` - Markdown linting
- `npx` - Node package runner (used for jscpd and biome auto-detection)
- `jscpd` - Duplicate code detection (via npx, no install needed)
- `biome` - TypeScript/JS/CSS formatting and linting (via npm/npx)
- `semgrep` - Security scanning for TS/JS (session-scoped, advisory)

**Tool Invocation Pattern:** The hook uses `uv run` to invoke project
dependencies (ty, pydantic), leveraging the project's virtual
environment without hardcoded path discovery. This follows the thin
wrapper principle - configuration lives in config files, the hook
delegates execution to the project's toolchain.

**hadolint Version Check:** The hook verifies hadolint >= 2.12.0 at runtime.
Older versions will trigger a warning but still run (graceful degradation).
Version 2.12.0+ is required for `disable-ignore-pragma` support.

**claude Command Discovery:** The hook searches for claude in this order:

1. `claude` in PATH (standard install)
2. `~/.local/bin/claude` (user install)
3. `~/.npm-global/bin/claude` (npm global)
4. `/usr/local/bin/claude` (system install)

If not found, outputs `[hook:error] claude binary not found, cannot delegate`.

## Phase 3 Subprocess

The Phase 3 subprocess is a `claude -p` process spawned by
`multi_linter.sh` to fix violations that Phase 1 auto-formatting
cannot handle. This section consolidates all subprocess configuration.

### Invocation

The subprocess CLI call (`multi_linter.sh:549-556`):

```bash
local disallowed_flag=()
if [[ -n "${disallowed_tools}" ]]; then
  disallowed_flag=(--disallowedTools "${disallowed_tools}")
fi
${timeout_cmd} "${claude_cmd}" -p "${prompt}" \
  --dangerously-skip-permissions \
  --settings "${settings_file}" \
  "${disallowed_flag[@]}" \
  --max-turns "${tier_max_turns}" \
  --model "${model}" \
  "${fp}" >/dev/null
```

Key flags:

- `--dangerously-skip-permissions` — enables headless operation
  (always paired with `--disallowedTools` unless all tools allowed)
- `--disallowedTools` — blacklist derived per tier (see Tool Scope)
- `--settings` — project-local settings with hooks disabled
- `>/dev/null` — stdout discarded; stderr flows to hook's stderr

### Tier Configuration

All subprocess settings are organized into `subprocess.tiers`
in `.claude/hooks/config.json`:

```json
{
  "subprocess": {
    "_comment": "Per-tier config for Phase 3 subprocess...",
    "tiers": {
      "haiku": {
        "patterns": "E[0-9]+|W[0-9]+|F[0-9]+|...",
        "tools": "Edit,Read",
        "max_turns": 10,
        "timeout": 120
      },
      "sonnet": {
        "patterns": "C901|PLR[0-9]+|...",
        "tools": "Edit,Read",
        "max_turns": 10,
        "timeout": 300
      },
      "opus": {
        "patterns": "unresolved-attribute|type-assertion",
        "tools": "Edit,Read,Write",
        "max_turns": 15,
        "timeout": 600
      }
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
```

**Precedence**: `global_model_override` > `volume_threshold` >
opus patterns > sonnet patterns > haiku patterns > fallback.
When `global_model_override` is set, ALL tier selection is skipped.
`max_turns_override` and `timeout_override` override per-tier
values when set.

**Unmatched patterns**: Trigger a stderr warning and fall back
to haiku (cheapest-safe fallback).

**Old config format**: Old flat keys (`subprocess.timeout`,
`subprocess.model_selection.*`) are not supported. If detected,
the hook emits a clear error with migration instructions.

### Tool Scope

Each tier declares allowed tools. The `--disallowedTools`
blacklist is derived at runtime: (tool universe) minus
(tier-specific tools). The tool universe is pinned in
`multi_linter.sh:507`:

```text
tool_universe="Edit,Read,Write,Bash,Glob,Grep,WebFetch,WebSearch,NotebookEdit,Task"
```

Update this list when upgrading `cc_tested_version`.

| Tier | Allowed Tools | Blocked |
| --- | --- | --- |
| haiku | `Edit,Read` | Write, Bash, Glob, Grep, WebFetch, WebSearch, etc. |
| sonnet | `Edit,Read` | Same as haiku |
| opus | `Edit,Read,Write` | Bash, Glob, Grep, WebFetch, WebSearch, etc. |

**Safety invariant**: `--dangerously-skip-permissions` is never
passed without `--disallowedTools`, except when tier tools equal
the full tool universe (all tools allowed). In that case the
flag is omitted and a warning is emitted.

### Model Selection

Tier selection is based on violation code patterns:

| Violation Type | Tier | Rationale |
| --- | --- | --- |
| Simple (F841, SC2034, E/W/F codes) | haiku | Fast, cheap |
| YAML/JSON/TOML/Dockerfile | haiku | Config formatting |
| Complexity (C901, PLR\*) | sonnet | Refactoring reasoning |
| Pydantic (PYD001-PYD006) | sonnet | Pydantic knowledge |
| FastAPI (FAST001-003) | sonnet | Framework patterns |
| Type errors (unresolved-import) | sonnet | Import resolution |
| Markdown (MD013, MD060) | sonnet | Semantic shortening |
| Docstrings (D001-D418) | sonnet | Semantic rewriting |
| Complex type (unresolved-attribute) | opus | Architectural |
| >5 violations (any type) | opus | Volume analysis |

| Model | Speed | Cost | Capability |
| --- | --- | --- | --- |
| Haiku | ~5s | Lowest | Basic fixes |
| Sonnet | ~15s | Medium | Refactoring |
| Opus | ~25s | Highest | Complex types |

Patterns are loaded dynamically from `config.json` via
`load_model_patterns()` at startup (`subprocess.tiers.{tier}.patterns`),
with readonly applied after loading. Defaults are used as fallback
if config.json is missing.

### Settings File

**Location**: `.claude/subprocess-settings.json` (project-local,
inside the project's `.claude/` directory).

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
```

**Why hooks are disabled**: `claude -p` subprocesses inherit
hooks from the parent session. Without `disableAllHooks`, the
subprocess's Edit calls would re-trigger the PostToolUse hook,
causing recursive subprocess spawning.

**Override**: Set `subprocess.settings_file` in config.json to
use a different settings file (e.g., for Z.AI provider routing):

```json
{
  "subprocess": {
    "settings_file": "~/.claude/glm-no-hooks-settings.json"
  }
}
```

**Auto-creation**: If `.claude/subprocess-settings.json` is missing,
the hook auto-creates it using atomic `mktemp+mv` (safe for
concurrent invocations). A warning is logged:

```text
[hook:warning] created missing .claude/subprocess-settings.json
```

### Overrides

| Override | Scope | Effect |
| --- | --- | --- |
| `global_model_override` | All tiers | Skips pattern match and volume check |
| `max_turns_override` | All tiers | Overrides per-tier `max_turns` |
| `timeout_override` | All tiers | Overrides per-tier `timeout` |
| `HOOK_SUBPROCESS_TIMEOUT` env | Runtime | Overrides timeout at shell level |
| `HOOK_SKIP_SUBPROCESS=1` env | Runtime | Disables subprocess entirely |

### Safety

`--dangerously-skip-permissions` is an implementation invariant,
not a user toggle. The subprocess is bounded by:

- **Tool scope**: `--disallowedTools` blocks everything outside
  the tier's tool list
- **Turn limit**: `--max-turns` per tier (default 10-15)
- **Timeout**: Per tier (default 120s-600s)
- **Single-file context**: Receives exactly one file path
- **No hooks**: Settings disable all hooks
- **Non-fatal**: Subprocess failure does not block the parent hook

These constraints make the subprocess comparable to a
deterministic auto-formatter that already runs without permission
prompts in Phase 1.

## Model Usage in Hook System

```text
+-----------------------------------------------------------------------------+
|                         MODEL USAGE IN HOOK SYSTEM                          |
+-----------------------------------------------------------------------------+
|                                                                             |
|  COMPONENT                  MODEL                   CONFIGURABLE?           |
|  -------------------------------------------------------------------------  |
|  Main Agent                 User's configured       Yes (user setting)      |
|                             model (Opus/Sonnet)                             |
|                                                                             |
|  PostToolUse Hook           None (bash script)      N/A                     |
|  (multi_linter.sh)                                                          |
|                                                                             |
|  Subprocess                 Per-tier selection      Yes (subprocess.tiers)  |
|  (claude -p)                haiku/sonnet/opus                               |
|                                                                             |
|  Stop Hook                  Configurable via        Yes (in settings.json)  |
|  (prompt type)              "model" field                                   |
|                                                                             |
+-----------------------------------------------------------------------------+
```

## Testing Environment Variables

See [Testing Guide](tests/README.md#testing-environment-variables) for the
complete environment variable reference and debug output locations.

## Linter Configuration Files

Linter configurations use standalone config files in the project root. This
separation improves maintainability and aligns with each tool's canonical
location.

| Linter | Config File |
| --- | --- |
| Ruff | `.ruff.toml` |
| ty | `ty.toml` |
| pydantic | `.flake8` |
| vulture | `vulture_whitelist.py` (false positive suppression) |
| bandit | `pyproject.toml [tool.bandit]` |
| ShellCheck | `.shellcheckrc` (maximum enforcement) |
| yamllint | `.yamllint` (all 23 rules configured) |
| hadolint | `.hadolint.yaml` (maximum strictness) |
| taplo | `taplo.toml` |
| markdownlint | `.markdownlint.jsonc`, `.markdownlint-cli2.jsonc` |
| jscpd | `.jscpd.json` (5% threshold) |
| flake8-async | `.flake8` (shares config with pydantic) |
| Biome | `biome.json` (TS/JS/CSS formatting + linting) |
| oxlint | `.oxlintrc.json` (TS/JS linting, when enabled) |
| Knip | `knip.json` (dead code detection, when enabled) |
| Semgrep | `.semgrep.yml` (security rules for TS/JS) |

**Note on Taplo:** Auto-formatting is now applied via `taplo fmt`. Only syntax
errors that cannot be auto-fixed are reported. See `taplo.toml` for config.

<!-- Note: Uses .flake8 config for per-file-ignores -->

**Note on Markdown (Two-Layer Enforcement):** Markdownlint uses a scoped
enforcement model to balance strict standards with practical constraints:

| Layer | Scope | Config | Purpose |
| --- | --- | --- | --- |
| Hook (PostToolUse) | ALL `.md` files | `.markdownlint*.jsonc` | Boy Scout |
| CI (pre-commit) | Maintained only | `.markdownlintignore` | Zero violations |

**CI-Scoped Paths** (must have zero violations):

- `*.md` at repo root (README.md, CLAUDE.md, etc.)
- `.claude/**/*.md` (except `.tmp/`, `plans/`, `skills/*/reports/`)
- `docs/**/*.md` (curated documentation)

**Excluded from CI** (but still linted by hook when edited):

- `.claude/.tmp/`, `.claude/plans/`, `.claude/skills/*/reports/`
- `data/`, `tmp/`
- Build artifacts (`.venv/`, `node_modules/`)

This model achieves zero violations on maintained files without requiring fixes
to large numbers of violations in legacy/auto-generated docs. The hook ensures
gradual cleanup via Boy Scout Rule: edit a file, own all its violations.

## Python Formatter Decision

**Decision**: Use ruff format exclusively. Do not add Black.

### Comparison (January 2026)

| Criterion | Ruff | Black |
| --- | --- | --- |
| Performance | 0.10s (250k lines) | 3.20s (250k lines) |
| Speed ratio | 1x (baseline) | ~30x slower |
| Compatibility | >99.9% Black-compatible | N/A |
| Language | Rust | Python |
| Config | .ruff.toml | pyproject.toml |

### Rationale

1. **Performance**: Ruff is 30x faster than Black, easily meeting the 500ms
   constraint
2. **Compatibility**: >99.9% Black-compatible output means no quality loss
3. **Simplicity**: Single tool for both formatting and linting reduces
   complexity
4. **Official guidance**: Astral (ruff maintainers) describes ruff format as
   "designed as a drop-in replacement for Black"

### Minor Differences from Black

Ruff differs from Black in edge cases (per Astral documentation):

- Expression collapsing (may fit more on one line)
- F-string formatting (normalizes quotes and spacing)
- Trailing commas in function definitions

These differences are intentional and considered improvements by the ruff team.

### Verification

Verify formatting performance by timing a format operation:

```bash
time ruff format --quiet src/app/utils.py
```

Expected: All files format in <100ms (well under 500ms constraint).

## Linter Output Processing

### Why Structured JSON Instead of Raw Output?

The hook (bash script) generates structured JSON for two reasons:

1. **Unified format** - Different linters have different output formats. JSON
   normalizes them.
2. **Easier for subprocess** - The subprocess can parse exact line/column to
   make targeted edits.

```text
+-----------------------------------------------------------------------------+
|                    LINTER OUTPUT FORMATS IN HOOK                            |
+-----------------------------------------------------------------------------+
|                                                                             |
|  NATIVE JSON OUTPUT:                                                        |
|  -------------------                                                        |
|  ruff check --output-format=json file.py                                    |
|  -> [{"code":"F841","message":"...","location":{"row":15,"column":5}}]      |
|                                                                             |
|  shellcheck -f json file.sh                                                 |
|  -> [{"line":12,"column":1,"code":2034,"message":"..."}]                    |
|                                                                             |
|  hadolint -f json Dockerfile                                                |
|  -> [{"line":1,"code":"DL3007","message":"..."}]                            |
|                                                                             |
|  ty check --output-format gitlab file.py                                    |
|  -> [{"check_name":"...","location":{"positions":{"begin":{...}}}}]         |
|                                                                             |
|  CONVERTED TO JSON (via sed/jaq):                                           |
|  --------------------------------                                           |
|  yamllint -f parsable file.yaml                                             |
|  -> "file.yaml:5:3: [error] wrong indentation (indentation)"               |
|  -> Hook parses with sed, converts to JSON                                  |
|                                                                             |
|  flake8 --select=PYD file.py                                                |
|  -> "file.py:45:1: PYD002 Field default should use Field()"                |
|  -> Hook parses with sed, converts to JSON                                  |
|                                                                             |
|  markdownlint-cli2 file.md                                                  |
|  -> "file.md:10 MD041/first-line-heading ..."                               |
|  -> Hook parses with sed, converts to JSON                                  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### Parsing Robustness by Linter

```text
+-----------------------------------------------------------------------------+
|                    PARSING ROBUSTNESS BY LINTER                             |
+-----------------------------------------------------------------------------+
|                                                                             |
|  ROBUST (Native JSON):                                                      |
|  ---------------------                                                      |
|  ruff        --output-format=json    (structured, stable)                   |
|  shellcheck  -f json                 (structured, stable)                   |
|  hadolint    -f json                 (structured, stable)                   |
|  ty          --output-format gitlab  (JSON, stable)                         |
|                                                                             |
|  FRAGILE (sed/regex parsing):                                               |
|  ----------------------------                                               |
|  yamllint    -f parsable -> sed      (format could change)                  |
|  flake8      text -> sed             (format could change)                  |
|  markdownlint text -> sed            (format could change)                  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

**Fragility examples:**

- **yamllint** (YAML handler): Breaks if message contains `:` or `()`
  characters, or if level becomes uppercase `[ERROR]`
- **flake8** (Python handler): Breaks if file path contains `:` or code format
  changes (e.g., `PYD-002` instead of `PYD002`)
- **markdownlint** (Markdown handler): Breaks if output format or rule names
  change

### Mitigation Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep current sed parsing | Simple, works now | Fragile, version-dependent |
| Use `--format json` where available | Robust | Not all tools support it |
| Pass raw linter output to subprocess | Simpler hook | Subprocess must parse |
| Fail gracefully on parse errors | Safer | May miss violations |

**Decision**: Keep sed parsing for all three tools. The formats are stable and
the parsing is well-tested. Native JSON alternatives either don't exist
(yamllint, flake8) or require complex configuration (markdownlint-cli2
outputFormatters).

### markdownlint-cli2 JSON Output (Investigated, Not Implemented)

While markdownlint-cli2 supports JSON output via outputFormatters, it requires:

1. Installing `markdownlint-cli2-formatter-json` npm package
2. Configuring `.markdownlint-cli2.jsonc` with outputFormatters
3. Output goes to a file, not stdout

This overhead is not justified given:

- The current sed parsing works reliably
- The output format is stable
- The hook would need to manage temp files

### yamllint Conversion Example

```bash
# yamllint raw output: "file.yaml:5:3: [error] wrong indentation (indentation)"

yaml_json=$(echo "${yamllint_output}" | while IFS= read -r line; do
  line_num=$(echo "${line}" | sed -E 's/.*:([0-9]+):[0-9]+: .*/\1/')
  col_num=$(echo "${line}" | sed -E 's/.*:[0-9]+:([0-9]+): .*/\1/')
  msg=$(echo "${line}" | sed -E 's/.*\[[a-z]+\] ([^(]+).*/\1/')
  code=$(echo "${line}" | sed -E 's/.*\(([^)]+)\).*/\1/')
  jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" --arg m "${msg}" \
    '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"yamllint"}'
done | jaq -s '.')
```

### Why flake8 JSON Would Need a Plugin

Flake8 has no built-in JSON output format. To get JSON output, you must
write a custom formatter plugin:

```python
from flake8.formatting.base import BaseFormatter
import json

class JSONFormatter(BaseFormatter):
    def format(self, error):
        return json.dumps({
            'filename': error.filename,
            'line': error.line_number,
            'column': error.column_number,
            'code': error.code,
            'text': error.text
        })
```

Then register as an entry point and invoke with `flake8 --format=json`. This is
significant overhead for parsing 6 stable rule codes (PYD001-PYD006), so we keep
sed parsing.

**Note on hadolint:** The hook uses `--no-color` flag to strip ANSI escape
sequences from output. Configuration uses maximum strictness with:

- `failure-threshold: warning` (stricter than default `info`)
- `disable-ignore-pragma: true` (prevents inline `# hadolint ignore=xxx`
  bypasses)
- `label-schema` enforcement (requires `maintainer` and `version` labels)
- Documented ignores only for version pinning rules (DL3008/DL3013/DL3018)

**Note on JSON (\*):** The JSON handler uses `cmp -s` to compare formatted
output with the original file before replacing. This idempotency check prevents
unnecessary file timestamp updates when content is already properly formatted.

**Note on jscpd (Phase 2c):** Duplicate code detection runs in **advisory mode**
only for Python files. Key characteristics:

- **Session-scoped**: Only runs once per session after 3+ Python files modified
- **Advisory only**: Reports duplicates but does NOT block (no
  `has_issues=true`)
- **Caching**: Uses `/tmp/.jscpd_session_${PPID}` to track files and `.done`
  marker
- **Threshold**: 5% duplication allowed, 10 min lines, 50 min tokens
- **Coverage**: Scans directories configured in config.json and .jscpd.json
- **Excludes**: Tests, data, docs, .claude/.tmp (per .jscpd.json ignore list)

This provides awareness of code duplication without disrupting development flow.
Run `npx jscpd --config .jscpd.json` for current baseline.

## Testing Stop Hook

See [Testing Guide](tests/README.md#test-stop-hook-stop_config_guardiansh) for
manual and integration testing instructions.

## Implementation Details

This section documents internal behaviors of the hook implementation.

### Subprocess Exit Code Handling

The hook captures and logs subprocess exit codes instead of swallowing them
with `|| true`. This provides visibility into subprocess failures:

```text
[hook:warning] subprocess timed out (exit 124)
[hook:warning] subprocess failed (exit 3)
```

Exit code 124 specifically indicates timeout (from `timeout` command). Other
non-zero codes indicate subprocess errors. These warnings appear on stderr
but do not block the hook from continuing.

### Path Normalization for Security Linters

The `is_excluded_from_security_linters()` function normalizes absolute paths
to relative paths using `CLAUDE_PROJECT_DIR` (set automatically by Claude
Code for all hooks):

```bash
# Input: /home/user/project/tests/test_foo.py
# Normalized: tests/test_foo.py
# Result: Matches tests/* exclusion pattern
```

This ensures exclusion patterns like `tests/*` work correctly regardless of
whether the hook receives absolute or relative paths.

## Integration Test Suite

The hook system has a 103-test integration suite. See
[Testing Guide](tests/README.md#integration-test-suite) for suite structure,
test layers, execution instructions, and known limitations.

**Specification**: [adr-hook-integration-testing.md](specs/adr-hook-integration-testing.md)

**Results**: [.claude/tests/hooks/results/RESULTS.md](../.claude/tests/hooks/results/RESULTS.md)

## Known Issues

### PostToolUse Hook Output Not in tool_result (CC v2.1.50)

Claude Code v2.1.50 does NOT propagate PostToolUse hook output into
the `tool_result` field. The tool_result contains only the Write/Edit
success message. However, mitmproxy capture proved that stderr+exit2
IS delivered to the model as a `<system-reminder>` tag embedded inside
the `tool_result.content` string (not as a separate content block).
The model CAN read and act on this content (confirmed: opus-4-6
thinking referenced hook violation codes in 3/3 mitmproxy iterations).

Whether the agent reliably ACTS on this ambient system-reminder
feedback (vs structured tool feedback) is under investigation. A
compounding bug in `multi_linter.sh` (`rerun_phase2()` producing
garbled multi-line output) was fixed in Step 1; the live verification
test (Step 2) has not yet been executed.

See [posttooluse-issue/](specs/posttooluse-issue/) for investigation
details and the executable plan (`make-plankton-work.md`).

### ShellCheck Info-Level Compliance (pre-commit)

All hook scripts pass `shellcheck` with `enable=all` (maximum
enforcement via `.shellcheckrc`). Info-level findings are
handled as follows:

- **SC2016** (single-quote expressions): Suppressed inline
  where strings are intentional literal patterns (grep
  searches, test fixtures)
- **SC2310** (function in if-condition): Suppressed inline
  where exit status capture is intentional
- **SC2312** (masked return value): Fixed with `|| true`
  in process substitutions and command substitutions
- **SC2249** (missing default case): Fixed by adding
  default `*)` case with warning message
- **SC2329** (unused function): Suppressed inline for
  functions invoked indirectly as callbacks

These changes improve robustness without altering hook
behavior. The SC2249 default case adds a stderr warning
for unknown `js_runtime` values (previously silent no-op).

---

## References

- [Ruff Formatter documentation (Astral)](https://docs.astral.sh/ruff/formatter/)
- [Ruff Formatter announcement blog post](https://astral.sh/blog/the-ruff-formatter)
- [Known deviations from Black (Ruff docs)](https://docs.astral.sh/ruff/formatter/black/)
- [Claude Code Hooks reference (official)](https://code.claude.com/docs/en/hooks)
