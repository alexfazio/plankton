# Hook Testing Guide

Testing reference for the Claude Code hooks in `.claude/hooks/`.
Architecture and runtime docs live in [docs/REFERENCE.md](../REFERENCE.md).

## Self-Test Suite

The `--self-test` flag runs automated tests covering all hooks:

```bash
.claude/hooks/test_hook.sh --self-test
```

### Multi-Linter Tests

**Dockerfile patterns**:

- `*.dockerfile` extension (valid content, expect pass)
- `*.dockerfile` extension (missing labels, expect fail)

**Other file types**:

- Python, Shell, JSON (valid), JSON (invalid), YAML

**Styled output format tests**:

- JSON violations output (`JSON_SYNTAX` code present)
- Dockerfile violations captured (`DL[0-9]+` codes present)

**Model selection tests**:

- Simple violation (F841) -> haiku
- Complexity violation (C901) -> sonnet
- Many violations (>5) -> opus
- Docstring violation (D103) -> sonnet

**TypeScript tests** (gated on Biome availability):

- Clean TS file -> exit 0
- TS unused variable -> exit 2
- JS clean file -> exit 0
- JSX a11y violation -> exit 2
- TS disabled -> exit 0 (skip)
- CSS clean -> exit 0
- CSS violation -> exit 2
- TS violations output contains `biome`
- Protected biome.json -> block
- TS simple -> haiku model
- TS >5 violations -> opus model
- JSON via Biome (D6) -> exit 0
- Biome not installed -> exit 0 (fallback)
- SFC (.vue) warning when semgrep absent
- D3 oxlint overlap: nursery rules skipped when oxlint enabled

### Package Manager Enforcement Tests

**Python (block mode)**:

- `pip install`, `pip3 install`, `python -m pip`, `python3 -m pip` blocked
- `python -m venv` blocked (suggests `uv venv`)
- `poetry add/install/run/lock/show/env` blocked
- `pipenv install/run/graph` blocked, bare `pipenv` blocked
- `uv pip` passthrough approved, `uv add` approved
- `pip freeze/list` blocked with specific replacements
- `pip install -e .` blocked (suggests `uv pip install -e .`)
- `pip download` allowed (in allowlist)
- Compound: `cd /app && pip install flask` blocked
- Diagnostics: `pip --version`, `poetry --help` approved

**JavaScript (block mode)**:

- `npm install/run/test/start/exec/init/uninstall` blocked
- `npx` blocked (suggests `bunx`)
- `yarn add/install/run/remove` blocked, bare `yarn` blocked
- `pnpm add/install/run/remove` blocked, bare `pnpm` blocked
- `npm audit/view/pack/publish/whoami/login` allowed (in allowlist)
- `yarn audit/info`, `pnpm audit/info` allowed
- `npm -g install` blocked (flag-before-subcommand parsing)
- `npm --registry=url audit` allowed (flag+allowlist)
- `bun add`, `bunx` passthrough approved
- Compound: `npm install && npm run build` blocked
- Cross-ecosystem: `pip install && npm install` blocked
- Diagnostics: `npm --version` approved

**Config toggle tests**:

- Python disabled (`"python": false`) -> pip install approved
- JavaScript disabled (`"javascript": false`) -> npm install approved

**Warn mode tests**:

- `pip install` in warn mode -> approved + `[hook:advisory]` to stderr
- `npm install` in warn mode -> approved + `[hook:advisory]` to stderr
- Warn + allowlist: `npm audit` still approved (no advisory)
- Warn + diagnostic: `pip --version` still approved
- Compound warn: `cd /app && pip install` -> advisory emitted
- Warn message format includes specific replacement command

**Bypass and edge cases**:

- `HOOK_SKIP_PM=1` -> all commands approved
- Non-package commands (`ls -la`) -> approved
- `jaq` missing -> fail-open (approve)
- `uv` missing -> block + `[hook:warning]` about missing replacement
- `bun` missing -> block + `[hook:warning]` about missing replacement
- `HOOK_DEBUG_PM=1` -> debug output emitted to stderr

**Compound command tests**:

- `uv pip + pip` compound (known limitation: uv pip passthrough approves
  whole command)
- `npm diag + npm install` -> blocked (regex finds second `npm install`)
- `pip diag + poetry add` -> blocked (independent poetry block)
- `pipenv diag + pipenv install` -> blocked
- `pip diag + pipenv install` -> blocked (cross-tool)
- `poetry diag + poetry add` -> blocked

Tests use temp files for content creation and `CLAUDE_PROJECT_DIR` override
for TypeScript-enabled config isolation.

## Testing Hooks Manually

### Test PostToolUse hook (multi_linter.sh)

```bash
# Test Python handler (should exit 0 for clean file)
echo 'def foo(): pass' > /tmp/test.py
echo '{"tool_input": {"file_path": "/tmp/test.py"}}' \
  | bash .claude/hooks/multi_linter.sh
echo "Exit: $?"

# Test with violations - use HOOK_SKIP_SUBPROCESS for deterministic exit codes
# Without it, subprocess would attempt fixes and exit code depends on success
cat > /tmp/complex.py << 'EOF'
def f(a,b,c,d,e,f,g,h,i,j,k):
    if a: return b
EOF
echo '{"tool_input": {"file_path": "/tmp/complex.py"}}' \
  | HOOK_SKIP_SUBPROCESS=1 bash .claude/hooks/multi_linter.sh
echo "Exit: $?"  # Exit 2 (violations reported, subprocess skipped)
```

### Test PreToolUse hook (protect_linter_configs.sh)

```bash
# Protected linter config (should return decision: block)
echo '{"tool_input": {"file_path": ".yamllint"}}' \
  | bash .claude/hooks/protect_linter_configs.sh
# Expected: {"decision": "block", "reason": "Protected linter config file..."}

# Protected hook script (should return decision: block)
echo '{"tool_input": {"file_path": ".claude/hooks/multi_linter.sh"}}' \
  | bash .claude/hooks/protect_linter_configs.sh
# Expected: {"decision": "block", "reason": "Protected Claude Code config..."}

# Protected settings (should return decision: block)
echo '{"tool_input": {"file_path": ".claude/settings.json"}}' \
  | bash .claude/hooks/protect_linter_configs.sh
# Expected: {"decision": "block", "reason": "Protected Claude Code config..."}

# Normal file (should return decision: approve)
echo '{"tool_input": {"file_path": "/tmp/normal.py"}}' \
  | bash .claude/hooks/protect_linter_configs.sh
# Expected: {"decision": "approve"}
```

### Test Stop hook (stop_config_guardian.sh)

```bash
# No modifications - should approve
echo '{"stop_hook_active": false}' | bash .claude/hooks/stop_config_guardian.sh
# Expected: {"decision": "approve"}

# With modifications (first invocation) - should block
echo "# test" >> .yamllint
echo '{"stop_hook_active": false}' | bash .claude/hooks/stop_config_guardian.sh
# Expected: {"decision": "block", "reason": "...", "systemMessage": "..."}

# Loop prevention (second invocation) - should approve
echo '{"stop_hook_active": true}' | bash .claude/hooks/stop_config_guardian.sh
# Expected: {"decision": "approve"}

# Restore after test
git checkout -- .yamllint
```

### Integration test (requires session restart)

1. Start new Claude Code session
2. Approve an edit to a protected config file
3. End session (Ctrl+C or /exit)
4. Stop hook should trigger, asking to restore
5. Choose "Yes, restore" or "No, keep"

## Testing Environment Variables

| Variable | Purpose | Used By |
| --- | --- | --- |
| `HOOK_SKIP_SUBPROCESS` | Skip delegation, report directly | multi_linter.sh |
| `HOOK_DEBUG_MODEL` | Output model selection | multi_linter.sh |
| `HOOK_SUBPROCESS_TIMEOUT` | Timeout for subprocess (300s) | multi_linter.sh |
| `HOOK_SESSION_PID` | Session PID for temp file scoping | multi_linter.sh |
| `HOOK_GUARD_PID` | Guard PID override | stop_cfg_guardian.sh, enforce_pm.sh |
| `HOOK_SKIP_PM` | Bypass PM enforcement | enforce_package_managers.sh |
| `HOOK_DEBUG_PM` | Log PM decisions to stderr | enforce_package_managers.sh |
| `HOOK_LOG_PM` | Log PM decisions to file | enforce_package_managers.sh |

Example usage:

```bash
# Test model selection without spawning subprocess
echo '{"tool_input": {"file_path": "/tmp/test.py"}}' \
  | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 .claude/hooks/multi_linter.sh
# Output: [hook:model] haiku
```

### Debug Output Locations

There are **TWO** debug output blocks for model selection:

1. **Inside `spawn_fix_subprocess()`** - Verbose format with counts:

   ```text
   [hook:model] haiku (count=3, opus_codes=false, sonnet_codes=false)
   ```

   Only reached during normal execution (when HOOK_SKIP_SUBPROCESS is not set).

2. **Script-level (main flow)** - Simple format:

   ```text
   [hook:model] haiku
   ```

   Runs before HOOK_SKIP_SUBPROCESS check, allowing tests to verify model
   selection without spawning subprocesses.

## Integration Test Suite

The hook system has a 103-test integration suite that exercises all four hooks
via their real stdin/stdout contracts. The suite runs as three parallel agents
using Claude Code's TeamCreate feature.

**Specification**: [adr-hook-integration-testing.md](../specs/adr-hook-integration-testing.md)

**Results**: [.claude/tests/hooks/results/RESULTS.md](../../.claude/tests/hooks/results/RESULTS.md)

### Suite Structure

| Agent | Hook Tested | Tests | Scope |
| --- | --- | --- | --- |
| `dep-agent` | Infrastructure | 29 | Dependencies + settings registration |
| `ml-agent` | `multi_linter.sh` | 42 | All file types, configs, toggles |
| `pm-agent` | `enforce_package_managers.sh` | 32 | Block/approve/compound/cfg |

**Excluded hooks**: `protect_linter_configs.sh` is covered by the
`test_hook.sh --self-test` suite. `stop_config_guardian.sh` requires an
interactive session restart which cannot be triggered from a TeamCreate
teammate context (teammates fire `TeammateIdle`, not `Stop`).

### Two Test Layers

- **Layer 1 (stdin/stdout)**: Pipe JSON to the hook script, capture exit
  code and output. This is the real execution path -- identical to how Claude
  Code delivers input to hooks.
- **Layer 2 (live trigger)**: Invoke an actual tool call (Edit or Bash) and
  observe whether the hook fires via the tool result.

### Running the Suite

The suite is orchestrated by the main agent following the
[Orchestrator Playbook](../specs/adr-hook-integration-testing.md#orchestrator-playbook).
Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` environment variable.

```text
Phase 0: Archive previous results, create team
Phase 1: dep-agent pre-flight (DEP01-DEP29)
Phase 2: ml-agent + pm-agent in parallel (M01-M42, P01-P32)
Phase 3: Aggregate JSONL, write RESULTS.md
Phase 4: Compare with archived previous run (if available)
```

Results are written as JSONL to `.claude/tests/hooks/results/` with one file
per agent. The aggregation command (`jaq -s`) produces pass/fail/skip counts
across all 103 tests.

### Known Limitations

**PreToolUse hooks do not fire for TeamCreate teammate Bash tool calls**:
When a teammate agent uses the Bash tool, PreToolUse hooks registered in
`.claude/settings.json` are not triggered. This means P28 (live trigger
for `enforce_package_managers.sh`) cannot be validated in a teammate
session. PostToolUse hooks DO fire for teammate Edit/Write tool calls
(confirmed by M19). This is a Claude Code agent teams architecture
constraint, not a hook defect -- all 31 direct invocation tests confirm
the hook logic is correct.

**subprocess-settings.json path**: The subprocess prevention settings file
lives at `.claude/subprocess-settings.json` (user home directory). The
integration test spec (DEP14) must check this path, not the project-local
`.claude/subprocess-settings.json`. The hook auto-creates this file if
missing (see [REFERENCE.md: Settings File Auto-Creation](../REFERENCE.md#settings-file-auto-creation)).

**Stop hook untestable via TeamCreate**: The `stop_config_guardian.sh` hook
fires on the `Stop` lifecycle event, which occurs at session end. TeamCreate
teammates trigger `TeammateIdle` when they finish, not `Stop`. Testing the
stop hook requires a manual session
(see [Test Stop hook](#test-stop-hook-stop_config_guardiansh)).

## Regression Testing After Hook Changes

After modifying `.claude/hooks/multi_linter.sh`, run these tests
to verify no regressions:

1. **Self-test suite** (structural + functional):

   ```bash
   bash .claude/hooks/test_hook.sh --self-test
   ```

   Expected: 110+ pass, 2 known failures (Python valid file
   detection, TS disabled skip counting).

2. **Feedback loop verification** (all file types):

   ```bash
   bash .claude/tests/hooks/verify_feedback_loop.sh
   ```

   Expected: 28+ pass, 0 fail. Skips are OK for linters not
   installed locally.

3. **Production path** (subprocess delegation with mock):

   ```bash
   bash .claude/tests/hooks/test_production_path.sh
   ```

   Tests the full subprocess delegation flow using a mock
   `claude` binary. No API access required.

4. **Five-channel output verification**:

   ```bash
   bash .claude/tests/hooks/test_five_channels.sh
   ```

   Automated channel output tests. Use `--runbook` flag for
   mitmproxy-based system-reminder delivery verification.
