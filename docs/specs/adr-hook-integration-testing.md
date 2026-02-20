# ADR: Hook Integration Testing via TeamCreate Agents

**Status**: Accepted
**Date**: 2026-02-20
**Author**: alex fazio + Claude Code clarification interview

**Note**: All factual claims carry a `[verify:]` marker referencing
the hook script or README section that authorizes the claim. These
markers must be resolved before this ADR moves to Accepted. Claims
without a verifiable source are marked `[verify: unresolved]`.

**Document type**: This is a hybrid ADR/test-specification. The
decisions (D1–D11) capture architectural choices; the test case
inventories (M01–M42, P01–P32, DEP01–DEP29) are the operational
specification that flows from those decisions. The document is
designed for direct consumption by an orchestrator agent that will
create an execution plan and run the test suite.

## Context and Problem Statement

The plankton hook system has no systematic real-execution
verification layer. The existing `test_hook.sh --self-test` suite
(~96 tests) validates the test harness's own logic but does not
directly exercise each hook via its stdin→stdout contract or the
live Claude Code hook lifecycle. There is no structured proof that:

1. Each hook accepts properly-formed JSON and returns the correct
   `decision` structure per the README contract
   [verify: docs/REFERENCE.md §Hook Schema Reference]
2. All required dependencies are installed and reachable
   [verify: docs/REFERENCE.md §Dependencies]
3. Hooks fire correctly in a live Claude Code session
   [verify: docs/REFERENCE.md §Hook Invocation Behavior]
4. Every documented scenario (violations, passthroughs, compound
   commands, config modes) produces the output described in the ADRs

## Decision Drivers

- **Real contract coverage**: test_hook.sh tests the harness, not
  the hooks' stdin→stdout JSON contract directly
- **Environment assurance**: Dependencies can silently degrade
  (e.g., hadolint < 2.12.0 [verify: docs/REFERENCE.md §hadolint
  Version Check]) without detection until a hook misbehaves
- **Durable audit trail**: A machine-readable JSONL log enables
  future comparisons and CI integration
- **Parallelism**: Multiple hooks can be tested concurrently via
  TeamCreate without blocking the main session
- **Self-contained fixtures**: Tests must not depend on pre-written
  files with violations — each test creates its own fixtures

## Decisions

### D1: Team Structure — Three TeamCreate Agents

**Decision**: Spawn three agents via TeamCreate:

| Agent | Hook Tested | Scope |
| --- | --- | --- |
| `ml-agent` | `multi_linter.sh` | All file types |
| `pm-agent` | `enforce_package_managers.sh` | All PM scenarios |
| `dep-agent` | Shared infrastructure | Deps + settings.json |

`protect_linter_configs.sh` and `stop_config_guardian.sh` are
excluded from dedicated agents:

- `protect_linter_configs.sh` behavior is simple path matching
  and is thoroughly covered by the existing self-test suite
  [verify: .claude/hooks/protect_linter_configs.sh §path matching]
- `stop_config_guardian.sh` cannot be tested via TeamCreate for
  two reasons: (1) the Stop lifecycle requires a session restart,
  which cannot be triggered deterministically in a non-interactive
  TeamCreate session; (2) TeamCreate teammates trigger the
  `TeammateIdle` lifecycle event, not `Stop` — the Stop event is
  architecturally unreachable from a teammate context
  [verify: docs/REFERENCE.md §Testing Stop Hook §Integration test]

**Alternatives considered**:

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| All 4 hooks as agents | Complete | Stop hook not testable | No |
| 2 agents (ml + pm) | Simple | No dep audit | No |
| **3 agents (ml + pm + dep)** | Balanced | Slightly more setup | **Yes** |
| Single agent | Simplest | No parallelism | No |

**Execution ordering**: dep-agent runs first as a pre-flight
environment check (~5 seconds). If required tools (jaq, ruff, uv,
claude) are absent, the orchestrator aborts before spawning ml-agent
or pm-agent. If only Biome is absent, the orchestrator continues —
ml-agent will fail M15–M18 per D4, which is the intended behavior.
After dep-agent completes, ml-agent and pm-agent run in parallel.

**Rationale**: The dep audit agent is lightweight but catches
environment issues (wrong tool version, missing jaq, unregistered
hook) that would silently degrade behavior without triggering a
visible test failure. Keeping it separate from ml-agent prevents a
dependency failure from contaminating linter test results.

### D2: Test Fixture Strategy — Inline Heredoc

**Decision**: Each test case creates its own temp fixture file
using an inline heredoc, invokes the hook, inspects output, then
cleans up. No pre-written fixture files with violations are
committed to the repository.

**Fixture pattern** (pseudocode — actual content varies per test):

```bash
tmp=$(mktemp /tmp/hook_test_XXXXXX.py)
cat > "${tmp}" << 'EOF'
def foo():
    unused_var = 1  # F841 violation
    pass
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"${tmp}\"}}" \
  | HOOK_SKIP_SUBPROCESS=1 bash .claude/hooks/multi_linter.sh)
exit_code=$?
rm -f "${tmp}"
# ... assert exit_code == 2, result contains [hook] ...
```

**Temp file cleanup guarantee**: Each agent sets a cleanup trap at
startup to handle orphaned temp files from timed-out tests:

```bash
trap 'rm -f /tmp/hook_test_*' EXIT
```

Individual tests still clean up after themselves (`rm -f "${tmp}"`),
but the trap ensures cleanup even when `timeout` kills a test
before its cleanup line executes. The parent process (agent) always
runs the EXIT trap regardless of how child processes terminate.

**TOML fixture path constraint**: TOML tests (M09, M10) MUST use
in-project paths (e.g., `.claude/tests/hooks/hook_test_XXXXXX.toml`)
instead of `/tmp/`. The project's `taplo.toml` has
`include = ["**/*.toml"]` which resolves relative to the project
root — taplo silently ignores files outside this scope, causing
tests to false-pass with exit 0 and no output
[verify: taplo.toml §include pattern]. The cleanup trap for TOML
fixtures uses the in-project path:
`trap 'rm -f .claude/tests/hooks/hook_test_*.toml' EXIT`.

**Alternatives considered**:

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Inline heredoc** | Self-contained, no repo files | Verbose | **Yes** |
| Pre-written fixture files | Reusable | Pre-poisoned files in repo | No |
| Pure stdin (no files) | No temp files | Can't test file-path hooks | No |
| Fixture factory function | DRY | Over-engineering for one run | No |

**Rationale**: Inline heredoc mirrors how `test_hook.sh --self-test`
already generates fixtures internally
[verify: .claude/hooks/test_hook.sh §self-test cases]. No fixture
maintenance burden; each test case is fully self-contained and
reproducible.

### D3: Two-Layer Test Execution

**Decision**: Each hook agent runs two test layers:

**Layer 1 — Stdin/stdout direct invocation**:

```bash
echo '{"tool_input": {"file_path": "/tmp/test.py"}}' \
  | bash .claude/hooks/multi_linter.sh
```

This IS the real execution path — Claude Code delivers input to
hooks as JSON on stdin; the hook returns JSON stdout and exit code.
[verify: docs/REFERENCE.md §Testing Hooks Manually, §Hook Schema Reference]

**Layer 2 — Live in-session trigger**:

The agent invokes an actual tool call (Edit for ml-agent, Bash for
pm-agent) with content known to trigger the hook, then observes
whether the hook fired via the tool result or stderr output.

In a TeamCreate session, each teammate runs in its own Claude Code
subprocess. When a teammate uses Edit/Write/Bash, the hooks
registered in `.claude/settings.json` fire for that teammate's
session [verify: .claude/settings.json §PreToolUse, §PostToolUse].
This confirms the hook lifecycle works for this project's
registration, not just the script's stdin/stdout behavior.

**What "live trigger confirmed" means**:

- ml-agent (M19): Calls `Edit` on a temp `.py` file with a
  violation. PostToolUse hook fires. Confirmed when the tool
  result contains the substring `"PostToolUse"` — either
  `"PostToolUse:Edit hook succeeded: Success"` (exit 0, subprocess
  fixed) or `"PostToolUse:Edit hook error: Failed with
  non-blocking status code 2"` (exit 2, violations remain). Both
  outcomes prove the hook lifecycle is active. Non-determinism is
  accepted: M19 does NOT use `HOOK_SKIP_SUBPROCESS` because the
  goal is lifecycle confirmation, not fix behavior testing.
  [verify: docs/REFERENCE.md §Hook Invocation Behavior]
- pm-agent (P28): Issues `Bash pip install requests`. PreToolUse
  hook fires and blocks the command. Confirmed when the tool
  result contains the substring `"hook:block"` — the block reason
  from `enforce_package_managers.sh`.
  [verify: docs/REFERENCE.md §Hook Invocation Behavior]

### D4: ml-agent Test Scope — All File Types

**Decision**: ml-agent tests all file types that multi_linter.sh
handles [verify: docs/REFERENCE.md §Linter Behavior by File Type],
plus conflict/interaction scenarios (M24–M31) and cross-language
toggle tests (M32–M38).

Each file type has at minimum a **clean test** (expect exit 0) and
a **violation test** (expect exit 2 with `[hook]` on stderr).

**File type coverage**:

| Type | Clean test | Violation test | Violation used |
| --- | --- | --- | --- |
| Python `.py` | M01 | M02 | F841 unused var |
| Shell `.sh` | M03 | M04 | SC2086 unquoted var |
| Markdown `.md` | M05 | M06 | MD013 line >80 chars |
| YAML `.yaml` | M07 | M08 | Wrong indentation |
| TOML `.toml` | M09 | M10 | Syntax error |
| JSON `.json` | M11 | M12 | Invalid JSON syntax |
| Dockerfile | M13 | M14 | DL3007 `ubuntu:latest` |
| TypeScript `.ts` | M15 | M16 | Unused variable |
| JavaScript `.js` | M17 | — | Clean only |
| CSS `.css` | M18 | — | Clean only |

**JS/CSS clean-only rationale**: Biome handles TypeScript, JavaScript,
and CSS with the same engine. The M16 TypeScript violation test covers
the violation detection code path for all three languages. M17/M18
confirm that clean files of each type are accepted without false
positives.

**TypeScript/JS/CSS gate**: These tests require Biome
[verify: docs/REFERENCE.md §Dependencies §Optional]. If the
`detect_biome()` chain finds no biome, log M15–M18 as
`pass: false, note: "BIOME_ABSENT"` and mark the suite as failed.
Biome is required (not optional) for this test run per the user's
explicit requirement. Tests M15–M18 use a `CLAUDE_PROJECT_DIR`
override pointing to a temp directory containing a `config.json`
with `typescript.enabled: true` (matching the project's current
default config) **and a `biome.json`** created with the required linter rules
(no `biome.json` exists at the project root — biome uses default
settings when no config is present, so the test must create one).
The `biome.json` is required because `multi_linter.sh` invokes
biome with `cd "${CLAUDE_PROJECT_DIR:-.}" && biome lint ...` — biome
looks for its config file in the working directory
[verify: .claude/hooks/multi_linter.sh §_lint_typescript §cd].
Without `biome.json` in the temp `CLAUDE_PROJECT_DIR`, biome uses
default settings which may produce non-deterministic results.
This is especially critical for M28 (`ts_nursery_error`) which
depends on biome's nursery rule configuration.

**Config isolation guarantee (ml-agent)**: Config-dependent tests
(M15–M18 and M20–M23) each create their own temp directory with a
custom `config.json` and set `CLAUDE_PROJECT_DIR` as a per-process
environment variable on the hook subprocess invocation. This provides
process-level isolation — ml-agent's config overrides cannot affect
pm-agent or dep-agent running concurrently, because environment
variable prefixes (`CLAUDE_PROJECT_DIR=/tmp/foo bash hook.sh`) scope
to that specific subprocess only. Same mechanism as pm-agent's P25–P27
(see D5 Config mode cases).

**Subprocess control**: All violation tests use
`HOOK_SKIP_SUBPROCESS=1` for deterministic exit codes. Without it,
the hook spawns `claude -p` which may fix violations and exit 0
regardless of the input content.
[verify: docs/REFERENCE.md §Testing Environment Variables]

**Live trigger test (M19)**: ml-agent calls `Edit` on a temp `.py`
file with an F841 violation and observes that the PostToolUse hook
fires. This confirms hook lifecycle registration.
[verify: docs/REFERENCE.md §Hook Invocation Behavior]

### D5: pm-agent Test Scope — All PM Scenarios

**Decision**: pm-agent tests all scenarios documented in
enforce_package_managers.sh
[verify: docs/specs/adr-package-manager-enforcement.md §D12].

**Payload format for all pm-agent tests**:

```bash
echo '{
  "tool_name": "Bash",
  "tool_input": {"command": "pip install requests"}
}' | bash .claude/hooks/enforce_package_managers.sh
```

[verify: .claude/hooks/enforce_package_managers.sh §input parsing,
docs/specs/adr-package-manager-enforcement.md §Input/Output Contract]

**Block cases** (expected: `decision: "block"`, exit 0):

| ID | Command | Expected `[hook:block]` prefix |
| --- | --- | --- |
| P01 | `pip install requests` | `pip` |
| P02 | `pip3 install flask` | `pip` |
| P03 | `python -m pip install pkg` | `python -m pip` |
| P04 | `python -m venv .venv` | `python -m venv` |
| P05 | `poetry add requests` | `poetry` |
| P06 | `pipenv install` | `pipenv` |
| P07 | `npm install lodash` | `npm` |
| P08 | `npx create-react-app` | `npx` |
| P09 | `yarn add lodash` | `yarn` |
| P10 | `pnpm install` | `pnpm` |

[verify: adr-package-manager-enforcement.md §D3, §D4]

**Approve cases** (expected: `decision: "approve"`, exit 0):

| ID | Command | Reason |
| --- | --- | --- |
| P11 | `uv add requests` | Preferred tool |
| P12 | `uv pip install -r req.txt` | uv pip passthrough |
| P13 | `bun add lodash` | Preferred tool |
| P14 | `bunx vite` | Preferred tool |
| P15 | `npm audit` | Allowlisted subcommand |
| P16 | `pip download requests` | Allowlisted subcommand |
| P17 | `yarn audit` | Allowlisted subcommand |
| P18 | `ls -la` | Non-PM command |

[verify: adr-package-manager-enforcement.md §D3, §D4, §D9]

**Compound command cases**:

| ID | Command | Expected | Source |
| --- | --- | --- | --- |
| P19 | `cd /app && pip install flask` | block (pip) | §D7 |
| P20 | `pip --version && poetry add req` | block (poetry) | Note |
| P21 | `pipenv --version && pipenv install` | block (pipenv) | Note |
| P22 | `pip --version && pipenv install` | block (pipenv) | Note G2 |
| P23 | `poetry --help && poetry add req` | block (poetry) | Note G1 |
| P24 | `npm audit && yarn add malicious` | block (yarn) | §D4 |

[verify: adr-package-manager-enforcement.md §D7, §Note on
independent blocks for poetry/pipenv]

**Config mode cases** (using `CLAUDE_PROJECT_DIR` override to a
temp directory containing a custom `config.json`).

**Config isolation guarantee**: Each config mode test creates its
own temp directory with its own `config.json` and sets
`CLAUDE_PROJECT_DIR` as a per-process environment variable on the
hook subprocess invocation. This provides process-level isolation —
pm-agent's config overrides (P25–P27) cannot affect ml-agent or
dep-agent running concurrently, because environment variable
prefixes (`CLAUDE_PROJECT_DIR=/tmp/foo bash hook.sh`) scope to
that specific subprocess only.

Test cases:

| ID | Config value | Command | Expected |
| --- | --- | --- | --- |
| P25 | `"python": false` | `pip install` | approve |
| P26 | `"python": "uv:warn"` | `pip install` | approve + advisory |
| P27 | `"javascript": false` | `npm install` | approve |

[verify: adr-package-manager-enforcement.md §D9,
.claude/hooks/enforce_package_managers.sh §parse_pm_config]

**Live trigger test (P28)**: pm-agent issues
`Bash pip install requests` via its Bash tool and confirms the
PreToolUse hook blocks the command.
[verify: docs/REFERENCE.md §Hook Invocation Behavior]

### D6: dep-agent Test Scope — Dependencies and Registration

**Decision**: dep-agent audits two categories:

**Category A — Tool presence and version**
[verify: docs/REFERENCE.md §Dependencies]:

| ID | Tool | Required | Check | Version Gate |
| --- | --- | --- | --- | --- |
| DEP01 | `jaq` | Yes | `command -v jaq` | — |
| DEP02 | `ruff` | Yes | `command -v ruff` | — |
| DEP03 | `uv` | Yes | `command -v uv` | — |
| DEP04 | `claude` | Yes | PATH search (4 locations) | — |
| DEP05 | `shfmt` | Optional | `command -v shfmt` | — |
| DEP06 | `shellcheck` | Optional | `command -v shellcheck` | — |
| DEP07 | `yamllint` | Optional | `command -v yamllint` | — |
| DEP08 | `hadolint` | Optional | `command -v hadolint` | — |
| DEP09 | `hadolint` version | Optional | `hadolint --version` | ≥ 2.12.0 |
| DEP10 | `taplo` | Optional | `command -v taplo` | — |
| DEP11 | `biome` | Required* | `detect_biome()` [verify: multi_linter.sh] | — |
| DEP12 | `semgrep` | Optional | `command -v semgrep` | — |
| DEP13 | `markdownlint-cli2` | Optional | `command -v markdownlint-cli2` | — |
| DEP23 | `oxlint` | Advisory | `command -v oxlint` (informational) | — |
| DEP24 | `bandit` | Optional | `uv run bandit --version` | — |

For Required tools: `pass: false` if absent.
For Required* tools (DEP11): `pass: false` if absent. Biome is
optional for daily hook operation but required for this test suite
per D4 — ml-agent tests M15–M18 hard-fail without it. DEP11 must
mirror the `detect_biome()` function in `multi_linter.sh`, which
probes `./node_modules/.bin/biome` first (the most common
installation path), then falls back to PATH, then to `npx biome`,
then to `pnpm exec biome`, then to `bunx biome`.
[verify: .claude/hooks/multi_linter.sh §detect_biome].
Note: `npx biome` is included in the fallback chain despite the PM
enforcement hook blocking `npx` commands — the hooks operate in
different lifecycle phases (PreToolUse vs PostToolUse).
For Optional tools: `pass: true` with `note: "absent"` if absent
(absence is expected and graceful).
For Advisory tools (DEP23): `pass: true` regardless of presence;
the note field records presence status for informational purposes.
DEP23 (oxlint): The hook never invokes oxlint directly — the
`oxlint_tsgolint` config flag only modifies biome's `--skip` flags
[verify: .claude/hooks/multi_linter.sh §oxlint_tsgolint]. DEP23
is advisory-only to document the tool's availability for future
reference.
DEP24 (bandit): needed for M31 (`py_multi_tool`) which tests
multi-tool Phase 2 collection. If absent, M31 is skipped. DEP24
uses `uv run bandit --version` because the hook invokes bandit via
`uv run bandit`, not bare `bandit`
[verify: .claude/hooks/multi_linter.sh §bandit invocation].
For DEP09: `pass: false` if hadolint found but version < 2.12.0.
[verify: docs/REFERENCE.md §hadolint Version Check]

**`claude` discovery order** [verify: docs/REFERENCE.md
§claude Command Discovery]:

1. `claude` in PATH
2. `~/.local/bin/claude`
3. `~/.npm-global/bin/claude`
4. `/usr/local/bin/claude`

**Category B — Settings registration and config**
[verify: .claude/settings.json, docs/REFERENCE.md §Configuration]:

| ID | Check | Expected |
| --- | --- | --- |
| DEP14 | `no-hooks-settings.json` has `disableAllHooks: true` | valid |
| DEP15 | PreToolUse `Edit\|Write` entry | protect_linter_configs.sh |
| DEP16 | PreToolUse `Bash` entry | enforce_package_managers.sh |
| DEP17 | PostToolUse `Edit\|Write` entry | multi_linter.sh |
| DEP18 | Stop entry | stop_config_guardian.sh |
| DEP19 | `.claude/hooks/config.json` exists | exists |
| DEP20 | `config.json` has `package_managers.python` | present |
| DEP21 | `config.json` has `package_managers.javascript` | present |

[verify: .claude/settings.json, docs/REFERENCE.md §Runtime
Configuration, docs/REFERENCE.md §Subprocess Hook Prevention]

**Category C — Test infrastructure**:

| ID | Tool | Required | Check |
| --- | --- | --- | --- |
| DEP22 | `timeout` | Yes | `command -v timeout \|\| command -v gtimeout` |

`timeout` (GNU coreutils) is required for per-test timeout
enforcement. On macOS, install via `brew install coreutils`.
If `gtimeout` is found instead of `timeout`, agents should use
`gtimeout` as a drop-in replacement.

**Category D — Advisory uv-managed tool checks**:

These checks verify that Python tools invoked via `uv run` in
`multi_linter.sh` are reachable through `uv run`. They are
advisory-only (`pass: true` regardless) because `uv run` can
auto-install packages from `pyproject.toml` dependencies. The
checks provide visibility into whether tools are pre-installed
(fast) or will require on-demand installation (slow, first-run
penalty).

| ID | Tool | Check | Note |
| --- | --- | --- | --- |
| DEP25 | `ty` | `uv run ty --version` | Type checker |
| DEP26 | `vulture` | `uv run vulture --version` | Dead code |
| DEP27 | `flake8-pydantic` | `uv run flake8 --version` | Pydantic lint |
| DEP28 | `flake8-async` | `uv run flake8 --version` | Async lint |
| DEP29 | `bandit` (advisory) | `uv run bandit --version` | Security |

DEP29 duplicates DEP24's check but is categorized as advisory
(always passes) rather than optional (gates M31). Both checks use
the same `uv run bandit --version` command. DEP24 determines
whether M31 is skipped; DEP29 provides informational output.

### D7: Log Format — JSONL

**Decision**: Each agent writes one JSON object per line (JSONL)
to its own log file. The main agent aggregates all files after all
three agents complete.

**Schema per test record**:

```json
{
  "hook": "multi_linter.sh",
  "test_name": "python_f841_violation",
  "category": "violation",
  "input_summary": "F841 unused var in .py file",
  "expected_decision": "exit_2",
  "expected_exit": 2,
  "actual_decision": "exit_2",
  "actual_exit": 2,
  "actual_output": "",
  "actual_stderr": "[hook] 1 violation(s) remain after delegation",
  "pass": true,
  "note": "",
  "timestamp": "2026-02-20T14:30:22Z",
  "duration_ms": 1000
}
```

For pm-agent tests (JSON stdout hooks):

```json
{
  "hook": "enforce_package_managers.sh",
  "test_name": "pip_install_blocked",
  "category": "block",
  "input_summary": "pip install requests",
  "expected_decision": "block",
  "expected_exit": 0,
  "actual_decision": "block",
  "actual_exit": 0,
  "actual_output": "{\"decision\":\"block\",\"reason\":\"...\"}",
  "actual_stderr": "",
  "pass": true,
  "note": "",
  "timestamp": "2026-02-20T14:30:45Z",
  "duration_ms": 2000
}
```

For dep-agent tests:

```json
{
  "hook": "infrastructure",
  "test_name": "dep_jaq_present",
  "category": "dependency",
  "input_summary": "command -v jaq",
  "expected_decision": "present",
  "expected_exit": 0,
  "actual_decision": "present",
  "actual_exit": 0,
  "actual_output": "/opt/homebrew/bin/jaq",
  "actual_stderr": "",
  "pass": true,
  "note": "",
  "timestamp": "2026-02-20T14:29:58Z",
  "duration_ms": 0
}
```

For live trigger tests (Layer 2):

```json
{
  "hook": "multi_linter.sh",
  "test_name": "live_trigger_edit_py",
  "category": "live_trigger",
  "input_summary": "Edit temp .py with F841 via tool",
  "expected_decision": "hook_fired",
  "expected_exit": null,
  "actual_decision": "hook_fired",
  "actual_exit": null,
  "actual_output": "PostToolUse:Edit hook succeeded: Success",
  "actual_stderr": "",
  "pass": true,
  "note": "Layer 2: confirmed hook lifecycle registration",
  "timestamp": "2026-02-20T14:31:10Z",
  "duration_ms": 3000
}
```

The `category: "live_trigger"` distinguishes Layer 2 from Layer 1
tests. Fields that don't apply to live trigger tests use `null`.
The `expected_decision: "hook_fired"` means either exit 0 or exit 2
confirms the hook ran — both are a pass.

**`actual_stderr` field**: Captures stderr output separately from
stdout. For PostToolUse hooks (ml-agent), stderr carries `[hook]`
violation messages. For PreToolUse hooks (pm-agent), stdout carries
the JSON decision and stderr carries `[hook:advisory]` warn-mode
messages. Tests that assert on advisory content (e.g., P26
`cfg_py_warn`) check `actual_stderr`. Capture pattern:
`actual_output=$(cmd 2>stderr_tmp); actual_stderr=$(cat stderr_tmp)`.

**Alternatives considered**:

| Format | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **JSONL** | Streamable, aggregatable via jaq | Requires jaq | **Yes** |
| Markdown table | Human-readable | Hard to aggregate | No |
| JSON array | Parseable | Requires full file in memory | No |
| CSV | Simple | Type-lossy, no nesting | No |

**Rationale**: JSONL is streamable — agents write results
incrementally without buffering the entire run. The main agent
aggregates with `jaq -s '.'` after all agents complete.

### D8: Log Location — .claude/tests/hooks/results/

**Decision**: Log files are written to
`.claude/tests/hooks/results/` in the project root, named
`<agent-name>-<timestamp>.jsonl`.

```text
.claude/tests/hooks/results/
├── archive/
│   └── 20260220T143022Z/          ← previous run
│       ├── dep-agent-20260220T131609Z.jsonl
│       ├── ml-agent-20260220T133812Z.jsonl
│       ├── pm-agent-20260220T132332Z.jsonl
│       └── RESULTS.md
├── dep-agent-<current-timestamp>.jsonl  ← current run
├── ml-agent-<current-timestamp>.jsonl
├── pm-agent-<current-timestamp>.jsonl
├── RESULTS.md
└── COMPARISON.md                  ← if archive/ has a previous run
```

This directory must be created before agent execution
(`mkdir -p .claude/tests/hooks/results/`). Phase 0 archives previous
run results before starting a new run — the `archive/` subdirectory
preserves historical runs for comparison (see Phase 4).

**Alternatives considered**:

| Location | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| `/tmp/` | No commit risk | Lost on reboot | No |
| `tests/hooks/results/` | Standard layout | New top-level dir | No |
| **`.claude/tests/hooks/results/`** | Near hook infra | — | **Yes** |
| `docs/specs/` | Near other specs | Wrong file type | No |

**Rationale**: Grouping under `.claude/` keeps test results
alongside the hook scripts and configuration they test. The
`.jsonl` extension is not linted by markdownlint-cli2.

### D9: Pass/Fail Criteria

**Decision**: A test case passes when ALL of the following hold:

1. **Exit code matches**: `actual_exit == expected_exit`
2. **Decision field matches**: For hooks that return JSON stdout
   (PreToolUse, Stop), `actual_decision == expected_decision`
   [verify: docs/REFERENCE.md §Hook Schema Reference]
3. **Prefix present** (for block/violation cases): `actual_output`
   contains the expected `[hook:block]`, `[hook]`,
   `[hook:advisory]`, or `[hook:warning]` prefix as appropriate
   [verify: docs/REFERENCE.md §Message Styling]

A test is **skipped** (not failed) when:

- An optional tool is absent AND the test gates on its presence
  (e.g., yamllint violation test skipped if yamllint absent)
- Exception: Biome absence is a **failure**, not a skip (per D4)

A test is also **skipped** (not failed) when:

- A required tool IS present but the specific rule/feature tested is
  unavailable in the installed version (e.g., biome nursery rule absent
  in biome 2.x). Record: `pass: true, note: "version_skip: <detail>"`.

A test **fails** when:

- Any pass condition above is not met
- The hook script itself exits non-zero unexpectedly
  (set -e firing due to an unhandled error)
- The hook hangs and is killed by a timeout

**Suite-level pass**: The full run passes when `pass: true` for all
non-skipped records across all three JSONL files.

### D10: Teardown Policy

**Decision**:

- **All pass**: Main agent sends `shutdown_request` to all three
  teammates and calls `TeamDelete` to clean up the team session.
- **Any failure**: Team is left open for inspection. Main agent
  reports failures in chat with actionable items. `TeamDelete` is
  NOT called. User can re-examine agent state or rerun individual
  agents.

**Alternatives considered**:

| Policy | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| Always teardown | Clean sessions | Lose debug context on failure | No |
| Never teardown | Always debuggable | Orphaned sessions accumulate | No |
| **Clean→teardown, fail→keep** | Balanced | Slightly more logic | **Yes** |

**Rationale**: Auto-teardown on clean runs is CI-friendly and
avoids orphaned team sessions. Preserving the team on failure
allows the user to inspect which agent failed and why, without
requiring a full rerun.

### D11: Verification Marker Policy

**Decision**: Every factual claim in this ADR (and in the agent
implementation scripts) that asserts hook behavior, an
input/output contract, or an expected output value carries a
`[verify:]` marker referencing its authoritative source.

**Format**:

```text
[verify: <source>]
```

Where `<source>` is one of:

- A file and section: `docs/REFERENCE.md §Dependencies`
- A script path: `.claude/hooks/multi_linter.sh §phase2`
- A spec reference: `adr-package-manager-enforcement.md §D12`
- `[verify: unresolved]` for claims that need investigation

**Policy**: No test case may be implemented without a `[verify:]`
marker that resolves to an actual line or section. Markers are the
bridge between this spec and the implementation. Resolving all
`[verify: unresolved]` markers is a gate for moving this ADR from
Proposed to Accepted. Resolved markers remain permanently in the
document as inline traceability links — when a referenced contract
changes, `grep '[verify:.*§Contract Name]'` finds all ADR claims
that depend on it. Resolution check: `grep '\[verify: unresolved\]'`
must return zero matches before acceptance.

## Complete Test Case Inventory

### ml-agent Test Cases (42 total)

All violation tests use `HOOK_SKIP_SUBPROCESS=1`
[verify: docs/REFERENCE.md §Testing Environment Variables].
All rows verify against [verify: docs/REFERENCE.md §Linter Behavior
by File Type]. M01–M02 also use [verify: docs/REFERENCE.md
§Testing Hooks Manually]. M19 verifies
[verify: docs/REFERENCE.md §Hook Invocation Behavior].

**Config-toggle tests (M20–M22)**: These tests use separate
`CLAUDE_PROJECT_DIR` overrides (one temp dir per test) to exercise
config-dependent code paths in `multi_linter.sh`. Each test creates a
`config.json` with the specified setting enabled. All use clean `.ts`
fixtures and expect exit 0 — the goal is verifying the config-reading
branch executes without error.
M20 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript
`biome_unsafe_autofix` branch, §rerun_phase1 `_unsafe` flag].
M21 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript
`oxlint_tsgolint` Biome --skip logic].
M22 is a defensive smoke test for tsgo (deferred, no implementation)
— confirms enabling it doesn't crash the hook.
M23 is the same defensive smoke test for knip (deferred, no
implementation) — split from M22 for per-setting attribution.

| ID | Name | Fixture | Expected | Gate |
| --- | --- | --- | --- | --- |
| M01 | python_clean | Clean `.py` | exit 0 | — |
| M02 | python_f841 | Unused var | exit 2, `[hook]` | — |
| M03 | shell_clean | Clean `.sh` | exit 0 | — |
| M04 | shell_sc2086 | Unquoted `$VAR` | exit 2, `[hook]` | shellcheck |
| M05 | markdown_clean | Clean `.md` | exit 0 | — |
| M06 | markdown_md013 | Line >80 chars | exit 2, `[hook]` | markdownlint-cli2 |
| M07 | yaml_clean | Clean `.yaml` | exit 0 | — |
| M08 | yaml_indent | Wrong indentation | exit 2, `[hook]` | yamllint |
| M09 | toml_clean | Clean `.toml` | exit 0 | — |
| M10 | toml_invalid | Syntax error | exit 2, `[hook]` | taplo |
| M11 | json_clean | Valid `.json` | exit 0 | — |
| M12 | json_invalid | Malformed JSON | exit 2, `[hook]` | — |
| M13 | dockerfile_clean | Clean Dockerfile | exit 0 | — |
| M14 | dockerfile_dl3007 | `FROM ubuntu:latest` | exit 2, `[hook]` | hadolint |
| M15 | ts_clean | Clean `.ts` | exit 0 | biome\* |
| M16 | ts_unused_var | Unused variable | exit 2, `[hook]` | biome\* |
| M17 | js_clean | Clean `.js` | exit 0 | biome\* |
| M18 | css_clean | Clean `.css` | exit 0 | biome\* |
| M19 | live_trigger | Edit `.py` via tool | hook fires | — |
| M20 | biome_unsafe_on | `.ts`, `unsafe_autofix: true` | exit 0 | biome\* |
| M21 | oxlint_skip_rules | `.ts`, `oxlint_tsgolint: true` | exit 0 | biome\* |
| M22 | tsgo_safe | Clean `.ts` + `tsgo: true` | exit 0 | biome\* |
| M23 | knip_safe | Clean `.ts` + `knip: true` | exit 0 | biome\* |

`biome*` = Required for this test suite; absence is failure, not
skip (see D4). All other gates: absence triggers skip with
`pass: true, note: "absent"`.

**Conflict/interaction tests (M24–M31)**: These tests exercise code
paths where multiple linters, config flags, or pipeline phases interact
on the same file. All use `HOOK_SKIP_SUBPROCESS=1` unless noted.
All use `CLAUDE_PROJECT_DIR` overrides for config-dependent tests.

| ID | Name | Fixture | Expected | Gate |
| --- | --- | --- | --- | --- |
| M24 | py_multi_violation | Python: F841 + type err | exit 2, multi | — |
| M25 | py_format_stable | Bad-format Python | exit 0 (P1 fmt, P2 clean) | — |
| M26 | ts_combined_config | TS + `unsafe`+`oxlint` | exit 2 | biome\* |
| M27 | py_no_autoformat | Python F841 + `auto_format: false` | exit 2 | — |
| M28 | ts_nursery_error | TS nursery + `nursery: "error"` | exit 2 | biome\* |
| M29 | py_no_subprocess | Python F841 + `subprocess: false` | exit 2 | — |
| M30 | ts_unsafe_resolves | TS fixable + `unsafe` | exit 0 (P1 fix) | biome\* |
| M31 | py_multi_tool | Python: B101 + F841 | exit 2, multi-tool | bandit |

M24 verifies [verify: docs/REFERENCE.md §Python File Flow Detail §Phase 2].
M25 verifies [verify: docs/REFERENCE.md §Phase 1 Auto-Format,
§Python File Flow Detail].
M26 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript,
config interaction]. Note: M26 does NOT gate on oxlint presence
because the hook never invokes oxlint directly — the
`oxlint_tsgolint` flag only modifies biome's `--skip` flags
[verify: .claude/hooks/multi_linter.sh §oxlint_tsgolint].
M27 verifies [verify: .claude/hooks/config.json §phases.auto_format].
M28 verifies [verify: .claude/hooks/multi_linter.sh §nursery_count
blocking path].
M29 verifies [verify: .claude/hooks/config.json
§phases.subprocess_delegation].
M30 verifies [verify: .claude/hooks/multi_linter.sh §_lint_typescript
Phase 1 --unsafe path].
M31 verifies [verify: docs/REFERENCE.md §Python File Flow Detail
§Phase 2 bandit + ruff].

**Concrete fixture content for non-obvious tests**:

M25 (`py_format_stable`) — Python with bad formatting but no
violations. Phase 1 (ruff format) reformats; Phase 2 (ruff check)
finds nothing:

```python
# Badly formatted but semantically clean
def foo(   x,y,   z   ):
    return x+y+z
```

M28 (`ts_nursery_error`) — TypeScript triggering a biome nursery
rule. Requires `biome.json` in the temp `CLAUDE_PROJECT_DIR` with
nursery rules enabled:

```typescript
// Triggers nursery rule (e.g., noExcessiveNestedTestSuites)
describe("a", () => { describe("b", () => { describe("c", () => {
  describe("d", () => { describe("e", () => { it("deep", () => {
  }); }); }); }); }); });
```

M30 (`ts_unsafe_resolves`) — TypeScript with a violation that
biome's `--unsafe` flag can auto-fix (e.g., removing a type
assertion that has a safe alternative):

```typescript
// Fixable by --unsafe: unnecessary type assertion
const x: string = "hello" as string;
```

**Cross-language / language toggle tests (M32–M38)**: These tests
verify that `languages.<type>: false` in `config.json` causes the hook
to passthrough (exit 0) even for files with violations. Each test
creates a violation fixture identical to an earlier test but with the
language disabled via `CLAUDE_PROJECT_DIR` override. All use
`HOOK_SKIP_SUBPROCESS=1`. M38 tests the fallback path for unrecognized
file extensions.

| ID | Name | Fixture | Config Override | Expected | Gate |
| --- | --- | --- | --- | --- | --- |
| M32 | lang_py_disabled | Python F841 | `python: false` | exit 0 | — |
| M33 | lang_ts_disabled | TS unused | `ts.enabled: false` | exit 0 | — |
| M34 | lang_shell_disabled | Shell SC2086 | `shell: false` | exit 0 | — |
| M35 | lang_md_disabled | Markdown MD013 | `markdown: false` | exit 0 | — |
| M36 | lang_yaml_disabled | YAML indent | `yaml: false` | exit 0 | — |
| M37 | lang_json_disabled | Invalid JSON | `json: false` | exit 0 | — |
| M38 | unknown_ext_passthrough | `.xyz` file | Default config | exit 0 | — |
| M39 | lang_toml_disabled | TOML syntax error | `toml: false` | exit 0 | — |
| M40 | lang_dockerfile_disabled | Dockerfile `:latest` | `dockerfile: false` | exit 0 | — |
| M41 | empty_py_file | Empty `.py` (0 bytes) | Default config | exit 2 (D100) | — |
| M42 | toml_tmp_path_ignored | TOML error at `/tmp/` | Default config | exit 0 | — |

M32–M37 verify [verify: .claude/hooks/multi_linter.sh §language toggle
check, .claude/hooks/config.json §languages].
M38 verifies [verify: .claude/hooks/multi_linter.sh §file extension
routing fallback].

### pm-agent Test Cases (32 total)

ADR-PM = `docs/specs/adr-package-manager-enforcement.md`

Block/approve cases verify [verify: ADR-PM §D3, §D4].
Allowlist cases verify [verify: ADR-PM §D9].
Compound cases verify [verify: ADR-PM §D7, §Note on independent
blocks for poetry/pipenv]. Config mode cases verify
[verify: ADR-PM §D9, §D2]. P18 verifies
[verify: .claude/hooks/enforce_package_managers.sh §exit].
P28 verifies [verify: docs/REFERENCE.md §Hook Invocation Behavior].

| ID | Name | Command | Expected |
| --- | --- | --- | --- |
| P01 | pip_blocked | `pip install requests` | block |
| P02 | pip3_blocked | `pip3 install flask` | block |
| P03 | python_m_pip | `python -m pip install pkg` | block |
| P04 | python_m_venv | `python -m venv .venv` | block |
| P05 | poetry_blocked | `poetry add requests` | block |
| P06 | pipenv_blocked | `pipenv install` | block |
| P07 | npm_blocked | `npm install lodash` | block |
| P08 | npx_blocked | `npx create-react-app` | block |
| P09 | yarn_blocked | `yarn add lodash` | block |
| P10 | pnpm_blocked | `pnpm install` | block |
| P11 | uv_approve | `uv add requests` | approve |
| P12 | uv_pip_approve | `uv pip install -r req.txt` | approve |
| P13 | bun_approve | `bun add lodash` | approve |
| P14 | bunx_approve | `bunx vite` | approve |
| P15 | npm_audit_allowed | `npm audit` | approve |
| P16 | pip_download_allowed | `pip download requests` | approve |
| P17 | yarn_audit_allowed | `yarn audit` | approve |
| P18 | ls_passthrough | `ls -la` | approve |
| P19 | compound_pip_cd | `cd /app && pip install flask` | block |
| P20 | cpd_pip_poetry | `pip -V && poetry add req` | block |
| P21 | cpd_pipenv_diag | `pipenv -V && pipenv install` | block |
| P22 | cpd_pip_pipenv | `pip -V && pipenv install` | block |
| P23 | cpd_poet_diag | `poetry -h && poetry add req` | block |
| P24 | cpd_npm_yarn | `npm audit && yarn add pkg` | block |
| P25 | cfg_py_off | `pip install` + `python: false` | approve |
| P26 | cfg_py_warn | `pip install` + `"uv:warn"` | approve, `[hook:advisory]` |
| P27 | cfg_js_off | `npm install` + `js: false` | approve |
| P28 | live_trigger | `Bash pip install` via tool | hook blocks |
| P29 | semicolon_compound | `ls ; pip install flask` | block |
| P30 | python3_m_pip | `python3 -m pip install pkg` | block |
| P31 | pnpm_audit_allowed | `pnpm audit` | approve |
| P32 | pipe_compound | `echo foo \| pip install -r /dev/stdin` | block |

### dep-agent Test Cases (29 total)

README = `docs/REFERENCE.md`

Required-tool checks (DEP01–DEP04) verify
[verify: README §Dependencies, README §claude Command Discovery].
Optional-tool checks (DEP05–DEP13, DEP24) verify
[verify: README §Dependencies]. DEP09 additionally checks the
minimum version [verify: README §hadolint Version Check].
Advisory-tool checks (DEP23, DEP25–DEP29) always pass; they
provide informational output about tool availability.
DEP14 verifies the no-hooks settings file
[verify: README §Subprocess Hook Prevention]. Settings keys
(DEP15–DEP18) verify [verify: .claude/settings.json].
Config keys (DEP19–DEP21) verify
[verify: README §Runtime Configuration,
README §Package Manager Enforcement].

| ID | Name | Check | Expected |
| --- | --- | --- | --- |
| DEP01 | jaq_present | `command -v jaq` | present |
| DEP02 | ruff_present | `command -v ruff` | present |
| DEP03 | uv_present | `command -v uv` | present |
| DEP04 | claude_present | PATH search | present |
| DEP05 | shfmt_opt | `command -v shfmt` | yes/no |
| DEP06 | shellcheck_opt | `command -v shellcheck` | yes/no |
| DEP07 | yamllint_opt | `command -v yamllint` | yes/no |
| DEP08 | hadolint_opt | `command -v hadolint` | yes/no |
| DEP09 | hadolint_ver | `hadolint --version` | ≥ 2.12.0 |
| DEP10 | taplo_opt | `command -v taplo` | yes/no |
| DEP11 | biome_opt | `detect_biome()` chain | yes/no |
| DEP12 | semgrep_opt | `command -v semgrep` | yes/no |
| DEP13 | mdlint_opt | `command -v markdownlint-cli2` | yes/no |
| DEP14 | no_hooks | `no-hooks-settings.json` | exists + `disableAllHooks` |
| DEP15 | set_pre_edit | `settings.json` | `Edit\|Write` |
| DEP16 | set_pre_bash | `settings.json` | `Bash` |
| DEP17 | set_post | `settings.json` | `PostToolUse` |
| DEP18 | set_stop | `settings.json` | `Stop` present |
| DEP19 | cfg_json | `hooks/config.json` | exists |
| DEP20 | cfg_py_key | `config.json` | `pkg_mgrs.python` |
| DEP21 | cfg_js_key | `config.json` | `pkg_mgrs.js` |
| DEP22 | timeout_present | `command -v timeout` | present |
| DEP23 | oxlint_advisory | `oxlint \|\| node_modules/.bin/oxlint` | advisory |
| DEP24 | bandit_opt | `uv run bandit --version` | yes/no |
| DEP25 | ty_advisory | `uv run ty --version` | advisory |
| DEP26 | vulture_advisory | `uv run vulture --version` | advisory |
| DEP27 | flake8_pydantic_advisory | `uv run flake8 --version` | advisory |
| DEP28 | flake8_async_advisory | `uv run flake8 --version` | advisory |
| DEP29 | bandit_advisory | `uv run bandit --version` | advisory |

## Main Agent Aggregation Logic

After all three agents write their JSONL logs, the main agent:

0. Verifies all three JSONL files exist and are non-empty
   (`test -s <file>`). If any file is missing or empty, report
   which agent failed and treat its tests as unknown failures.
1. Verifies record counts per agent:
   - ml-agent: 42 records expected
   - pm-agent: 32 records expected
   - dep-agent: 29 records expected
   If a file has fewer records than expected, report which agent
   produced a partial run and treat missing tests as unknown
   failures (the file is still included in aggregation).
2. Reads all three JSONL files with `jaq -s '.'`
3. Counts `pass: true` and `pass: false` records
4. Lists all failing test names with their `note` field
5. Applies the D10 teardown policy
6. Returns a findings report with actionable items for any failures

**Aggregation command** (run by main agent after agents complete):

```bash
jaq -s '. as $all |
  ($all | map(select(.pass == false)) | length) as $fails |
  ($all | map(select(.pass == true and (.note | test("absent|BIOME_ABSENT") | not))) | length) as $pass |
  ($all | map(select(.pass == true and (.note | test("absent|BIOME_ABSENT")))) | length) as $skipped |
  {
    passed: $pass,
    failed: $fails,
    skipped: $skipped,
    failures: (
      $all | map(select(.pass == false)) |
      map({hook, test_name, note})
    ),
    skips: (
      $all | map(select(.pass == true and (.note | test("absent|BIOME_ABSENT")))) |
      map({hook, test_name, note})
    )
  }' \
  .claude/tests/hooks/results/*.jsonl
```

## Test Timeouts

Each test invocation uses a per-test timeout to prevent a single
hung test from blocking the entire suite.

| Layer | Timeout | Rationale |
| --- | --- | --- |
| Layer 1 (stdin/stdout) | 30s | Phase 1+2 no subprocess; 30s generous |
| Layer 2 (M19 live Edit) | 120s | PostToolUse spawns subprocess (~25-30s) |
| Layer 2 (P28 live Bash) | 30s | PreToolUse blocks immediately, no subprocess |
| Suite-level backstop | 15 min | 103 tests × worst case; prevents runaway |

**Timeout mechanism**: Layer 1 tests use `${TIMEOUT_CMD} 30 bash
.claude/hooks/hook.sh`. Layer 2 timeouts are enforced by the
orchestrator's task management.

**Timeout command detection**: On macOS, GNU `timeout` is installed
as `gtimeout` via `brew install coreutils`. Each agent must detect
the available command at startup:

```bash
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
else
  echo "FATAL: neither timeout nor gtimeout found" >&2
  exit 1
fi
```

All subsequent timeout invocations use `${TIMEOUT_CMD}` instead of
bare `timeout`. DEP22 validates this requirement at pre-flight.

**Timeout behavior**: On timeout, mark the test as
`pass: false, note: "TIMEOUT_30s"` (or `TIMEOUT_120s`) and
continue to the next test. Do NOT abort the suite — collect
partial results.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Biome absent | Low | High | D4: fail TS tests explicitly |
| jaq absent | Low | High | DEP01 detects this first |
| hadolint version < 2.12.0 | Low | Med | DEP09 version check |
| config.json missing | Low | Med | DEP19 checks existence |
| HOOK_SKIP_SUBPROCESS ignored | Low | Med | Fails all violation tests |
| TeamCreate session orphaned | Low | Low | D10 keep-on-failure policy |
| JSONL write race condition | Very Low | Low | One file per agent |

## Scope Boundaries

**In scope**:

- `multi_linter.sh` testing (file types, config, toggles, M01–M42)
- `enforce_package_managers.sh` functional testing (P01–P32)
- Dependency presence and version auditing (DEP01–DEP29)
- Settings.json registration verification
- JSONL log production and main agent aggregation

**Out of scope**:

- `protect_linter_configs.sh` — covered by existing self-test
- `stop_config_guardian.sh` — requires interactive session restart
- CI integration of this test run (separate concern)
- Performance benchmarking (hook latency measurement)
- Test coverage of the test_hook.sh harness itself

## Config Coverage Analysis

The following table documents which `config.json` settings have
real code paths in `multi_linter.sh` and are therefore meaningful
to test:

| Setting | Config Path | Implemented? | Tested? |
| --- | --- | --- | --- |
| `biome_unsafe_autofix` | `lang.ts.biome_unsafe_autofix` | **Yes** (2) | M20 |
| `oxlint_tsgolint` | `lang.ts.oxlint_tsgolint` | **Partial** (--skip) | M21 |
| `tsgo` | `languages.typescript.tsgo` | **No** (deferred) | M22 (smoke) |
| `knip` | `languages.typescript.knip` | **No** (deferred) | M23 (smoke) |
| `jscpd.advisory_only` | `jscpd.advisory_only` | **Dead config** | — |

**Dead config finding**: `jscpd.advisory_only` is documented in
`docs/REFERENCE.md` (line 890) as configurable, but `multi_linter.sh`
never reads this value. The jscpd advisory behavior is hardcoded —
both the Python path and the TypeScript path emit
`[hook:advisory]` messages without checking the config flag. Changing
this setting to `false` has zero effect. This should be either wired
into the code or removed from the config to avoid confusion.

## Consequences

### Positive

- Structured proof that all hooks work end-to-end (103 test cases)
- Machine-readable JSONL audit trail enables future CI integration
- Dependency health monitoring catches silent degradation
- Parallel execution via TeamCreate keeps total runtime manageable
- Verification markers provide traceability between spec and
  implementation
- Post-review expansion from 95 to 103 tests added edge cases for
  TOML/Dockerfile language toggles, empty files, semicolon/pipe
  compound commands, and `python3 -m pip` variant

### Negative

- Maintenance burden: 103 test cases must be updated when hook
  behavior changes (mitigated by `[verify:]` markers that flag
  which tests depend on which contracts)
- TeamCreate dependency: test suite requires experimental agent
  teams feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`)
- Coupling: test case expectations are tightly coupled to hook
  output formats — format changes require test updates

### Neutral

- Does not replace `test_hook.sh --self-test` — the two suites
  are complementary (harness logic vs. integration behavior)
- JSONL logs accumulate in `.claude/tests/hooks/results/` and
  require periodic cleanup
- Companion execution results document
  ([RESULTS.md](../../.claude/tests/hooks/results/RESULTS.md)) captures
  findings and deviations from the initial run

## Implementation Checklist

- [x] Create `.claude/tests/hooks/results/` directory
- [x] Implement ml-agent (test cases M01–M19)
- [x] Implement pm-agent (test cases P01–P28)
- [x] Implement dep-agent (test cases DEP01–DEP29)
- [x] Implement main agent aggregation and teardown logic
- [x] Implement config-toggle tests M20–M23 (separate CLAUDE_PROJECT_DIR per test)
- [x] Implement conflict tests M24–M31 (multi-linter, config)
- [x] Implement language toggle tests M32–M38 (disable + unknown ext)
- [x] Resolve all `[verify: unresolved]` markers before Accepted
- [x] Confirm all 103 test cases produce JSONL records (including
  live trigger tests with `category: "live_trigger"`, config-toggle
  tests M20–M23, conflict tests M24–M31, cross-language tests
  M32–M38, and edge case tests M39–M42, P29–P32)
- [x] Confirm teardown/keep behavior per D10

## Acceptance Gates

This ADR moves from **Proposed** to **Accepted** when all of the
following conditions are met:

1. All `[verify: unresolved]` markers are resolved
   (`grep '\[verify: unresolved\]'` returns zero matches)
2. All 103 test cases produce valid JSONL records
3. The aggregation command runs without errors on the produced JSONL
4. The dep-agent pre-flight passes (DEP01–DEP04 all present)
5. The Implementation Checklist above is fully checked off
6. At least one clean run (all non-skipped tests pass) has been
   completed and its JSONL logs are available for review

## Orchestrator Playbook

This section provides the execution sequence for the orchestrator
agent that runs the test suite. The orchestrator is the main agent
that creates the team, assigns tasks, and aggregates results.

### Prerequisites

- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` environment variable set
  (required for TeamCreate)
- All hook scripts present in `.claude/hooks/`
- `.claude/settings.json` with hook registrations
- Test-required tools installed (see Phase 0 setup): biome, oxlint,
  bandit, timeout

### Phase 0: Setup

```bash
# Archive previous run results (if any)
if ls .claude/tests/hooks/results/*.jsonl 1>/dev/null 2>&1; then
  _archive=".claude/tests/hooks/results/archive/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${_archive}"
  mv .claude/tests/hooks/results/*.jsonl "${_archive}/"
  [ -f .claude/tests/hooks/results/RESULTS.md ] && \
    mv .claude/tests/hooks/results/RESULTS.md "${_archive}/RESULTS.md"
  [ -f .claude/tests/hooks/results/COMPARISON.md ] && \
    rm .claude/tests/hooks/results/COMPARISON.md
fi

mkdir -p .claude/tests/hooks/results/
echo '*.jsonl' > .claude/tests/hooks/results/.gitignore
```

**Test environment setup**: The dep-agent (Phase 1) verifies all
tool dependencies, but installing missing tools upfront avoids
mid-run failures. The following tools are needed for full test
coverage:

```bash
# Required* — biome (M15–M18, M26, M28, M30)
test -x ./node_modules/.bin/biome || command -v biome || bun add --dev @biomejs/biome

# Advisory — oxlint (hook uses oxlint_tsgolint flag to modify biome --skip only)
command -v oxlint || bun add --dev oxlint

# Optional — bandit (M31 py_multi_tool)
command -v bandit || uv pip install bandit

# Required — timeout (per-test timeout enforcement)
command -v timeout || command -v gtimeout || brew install coreutils
```

See dep-agent inventory (DEP01–DEP29) for the full dependency list.
If any Required tool is missing, dep-agent will abort the run.
If an Optional tool is missing, tests that gate on it are skipped
with `pass: true, note: "absent"`.

Create the team via TeamCreate:

| Parameter | Value |
| --- | --- |
| Team name | `hook-integration-test` |
| Description | `Integration testing of plankton hook system` |

### Phase 1: Environment Pre-Flight (dep-agent)

Spawn `dep-agent` as a TeamCreate teammate (subagent_type:
`general-purpose`). Assign it the dep-agent test inventory
(DEP01–DEP29).

**dep-agent prompt template**:

> Run the dep-agent test inventory from the hook integration testing
> ADR (DEP01–DEP29). For each test, write one JSONL record to
> `.claude/tests/hooks/results/dep-agent-<timestamp>.jsonl` using
> `jaq -n` (see JSONL write pattern below). After all tests
> complete, send a message to the orchestrator with the count of
> pass/fail results and list any failures.

**Wait for dep-agent to complete.** Check results:

- If **any** of DEP01–DEP04 (jaq, ruff, uv, claude) report
  `pass: false`: **abort** — the test infrastructure cannot
  function. Report failures and call TeamDelete.
- If DEP11 (biome) reports `pass: false`: **continue** — ml-agent
  will fail M15–M18 per D4, which is the intended behavior.
  Log the warning.
- Otherwise: proceed to Phase 2.

### Phase 2: Parallel Testing (ml-agent + pm-agent)

Spawn both agents as TeamCreate teammates (subagent_type:
`general-purpose`):

**ml-agent prompt template**:

> Run the ml-agent test inventory from the hook integration testing
> ADR (M01–M42). For each test: create a temp fixture, invoke the
> hook via stdin pipe, capture exit code and output, write one JSONL
> record to `.claude/tests/hooks/results/ml-agent-<timestamp>.jsonl`.
> Use `HOOK_SKIP_SUBPROCESS=1` for all violation tests. Use
> `CLAUDE_PROJECT_DIR` overrides for TypeScript, config-toggle,
> conflict, and cross-language tests (M15–M18, M20–M38). For M19
> (live trigger), use the Edit tool on a temp file and observe the
> PostToolUse result. After all tests complete, send a message to
> the orchestrator with results.

**pm-agent prompt template**:

> Run the pm-agent test inventory from the hook integration testing
> ADR (P01–P32). For each test: construct the JSON payload, pipe
> to enforce_package_managers.sh, capture exit code and stdout/stderr,
> write one JSONL record to
> `.claude/tests/hooks/results/pm-agent-<timestamp>.jsonl`. Use
> `CLAUDE_PROJECT_DIR` overrides for config mode tests (P25–P27).
> For P28 (live trigger), use the Bash tool with `pip install` and
> observe the PreToolUse result. After all tests complete, send a
> message to the orchestrator with results.

**Wait for both agents to complete.**

### Phase 3: Aggregation

After all agents complete, run the aggregation command (see Main
Agent Aggregation Logic section). Apply D10 teardown policy based
on results.

**Backstop enforcement**: The orchestrator tracks wall time from
team creation using file-based `date +%s` timestamps. At team
creation, the orchestrator writes the start timestamp:

```bash
date +%s > .claude/tests/hooks/results/.start_ts
```

At each checkpoint (agent idle notification, task completion),
the orchestrator reads this value back and computes elapsed time:

```bash
start=$(cat .claude/tests/hooks/results/.start_ts)
elapsed=$(( $(date +%s) - start ))
```

If `elapsed > 900` (15 minutes), the orchestrator sends
`shutdown_request` to all active agents, collects whatever JSONL
has been written, and runs the aggregation on partial results.
This prevents runaway orchestration.

**Note**: `SECONDS` (used in the JSONL write pattern for per-test
timing) works correctly within a single Bash tool call but does
NOT persist across separate Bash tool invocations — each call
starts a new shell process. The backstop uses file-based `date +%s`
instead for cross-invocation tracking.

### JSONL Write Pattern

All agents use `jaq -n` with `--arg` for safe JSON construction:

```bash
# Set once at agent start (substitute agent name):
LOGFILE=".claude/tests/hooks/results/ml-agent-$(date -u +%Y%m%dT%H%M%SZ).jsonl"

# Per-test timing:
SECONDS=0
# ... run the test ...
jaq -n \
  --arg hook "multi_linter.sh" \
  --arg test_name "python_clean" \
  --arg category "clean" \
  --arg input_summary "Clean .py file" \
  --arg expected_decision "exit_0" \
  --argjson expected_exit 0 \
  --arg actual_decision "exit_0" \
  --argjson actual_exit 0 \
  --arg actual_output "" \
  --arg actual_stderr "" \
  --argjson pass true \
  --arg note "" \
  --arg ts "$(date -u +%FT%TZ)" \
  --argjson dur "$((SECONDS * 1000))" \
  '{
    hook: $hook,
    test_name: $test_name,
    category: $category,
    input_summary: $input_summary,
    expected_decision: $expected_decision,
    expected_exit: $expected_exit,
    actual_decision: $actual_decision,
    actual_exit: $actual_exit,
    actual_output: $actual_output,
    actual_stderr: $actual_stderr,
    pass: $pass,
    note: $note,
    timestamp: $ts,
    duration_ms: $dur
  }' >> "${LOGFILE}"
```

Reset `SECONDS=0` before each test to measure per-test wall time.
`date -u +%FT%TZ` produces ISO 8601 UTC timestamps (e.g.,
`2026-02-20T14:30:22Z`). `$((SECONDS * 1000))` gives
second-level granularity in milliseconds — available in
bash, ksh, and zsh (not POSIX-specified; not available in dash
or ash).

This guarantees valid JSON with proper escaping of special
characters in output strings. `--argjson` is used for numeric and
boolean fields; `--arg` for strings.

### Agent Naming Convention

| Agent | TeamCreate name | JSONL file prefix |
| --- | --- | --- |
| Multi-linter tester | `ml-agent` | `ml-agent-` |
| Package manager tester | `pm-agent` | `pm-agent-` |
| Dependency auditor | `dep-agent` | `dep-agent-` |

### Completion Detection

The orchestrator detects agent completion via TeamCreate's built-in
idle notification mechanism. When a teammate completes its test
inventory and sends a results message, it goes idle. The
orchestrator receives the message and can check TaskList for
remaining work.

### Phase 4: Run Comparison (conditional)

This phase only executes when `archive/` contains a previous run.
If this is the first run, skip to teardown.

**Step 1 — Identify the most recent archived run**:

```bash
prev_run=$(ls -1d .claude/tests/hooks/results/archive/*/ 2>/dev/null \
  | sort -r | head -1)
if [ -z "${prev_run}" ]; then
  echo "No previous run found — skipping comparison."
  # Skip to teardown
fi
```

**Step 2 — Automated JSONL diff**:

Join current and previous JSONL records by `test_name` and report
field-level deltas across all three agents (dep-agent, ml-agent,
pm-agent):

```bash
jaq -s --slurpfile prev <(cat "${prev_run}"/*.jsonl) '
  . as $curr |
  ($prev | map({(.test_name): .}) | add) as $prev_map |
  ($curr | map({(.test_name): .}) | add) as $curr_map |
  {
    added: [$curr | .[] | select(.test_name as $t | $prev_map[$t] == null) | .test_name],
    removed: [$prev | .[] | select(.test_name as $t | $curr_map[$t] == null) | .test_name],
    changed: [
      $curr | .[] |
      select(.test_name as $t | $prev_map[$t] != null) |
      . as $c | $prev_map[.test_name] as $p |
      select($c.pass != $p.pass or $c.actual_exit != $p.actual_exit or $c.note != $p.note) |
      {
        test_name,
        pass: {old: $p.pass, new: $c.pass},
        actual_exit: {old: $p.actual_exit, new: $c.actual_exit},
        note: {old: $p.note, new: $c.note}
      }
    ]
  }
' .claude/tests/hooks/results/*.jsonl
```

**Step 3 — Environment snapshot comparison**:

If both runs have `RESULTS.md`, the orchestrator extracts the
Environment Snapshot tables and reports tool version changes
(e.g., `biome: 2.3.15 → 2.4.0`). dep-agent records provide the
structured data for this comparison — tool presence/version changes
in dep-agent explain exit code changes in ml-agent and pm-agent.

**Step 4 — Write COMPARISON.md**:

Write `.claude/tests/hooks/results/COMPARISON.md` with:

- **Run identifiers**: Timestamps of both runs
- **Environment delta**: Tool version/presence changes from
  dep-agent record comparison
- **Test result delta table**: test_name, old result, new result,
  delta type (added/removed/regression/resolved/changed)
- **Actionable items**: Regressions to investigate, resolved issues
  to confirm, environment drift to document

`COMPARISON.md` compares only the last two runs (current vs. most
recent archive). It is overwritten on each run, not accumulated.

---

## Execution Results

For findings, deviations, and remediation details from the first clean
run, see [RESULTS.md](../../.claude/tests/hooks/results/RESULTS.md).

---

## References

- [docs/REFERENCE.md](../README.md) — Hook architecture and
  testing documentation
- [.claude/hooks/multi_linter.sh](../../.claude/hooks/multi_linter.sh)
  — PostToolUse hook implementation
- [.claude/hooks/enforce_package_managers.sh](../../.claude/hooks/enforce_package_managers.sh)
  — PreToolUse Bash hook implementation
- [.claude/hooks/test_hook.sh](../../.claude/hooks/test_hook.sh)
  — Existing self-test suite (~96 tests)
- [.claude/settings.json](../../.claude/settings.json)
  — Hook registration
- [adr-package-manager-enforcement.md](adr-package-manager-enforcement.md)
  — PM enforcement decisions referenced as ADR-PM
- [adr-hook-schema-convention.md](adr-hook-schema-convention.md)
  — JSON schema convention for all hooks
- [jaq GitHub repository (jq alternative used in aggregation)](https://github.com/01mf02/jaq)
- [jq 1.8 Manual (current)](https://jqlang.org/manual/)
- [hadolint DL3007 rule source](https://github.com/hadolint/hadolint/blob/master/src/Hadolint/Rule/DL3007.hs)
- [Wooledge Bashism wiki (SECONDS not POSIX)](https://mywiki.wooledge.org/Bashism)
- [POSIX Shell Command Language specification](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)
- [Ruff F841 unused-variable rule](https://docs.astral.sh/ruff/rules/unused-variable/)
- [ShellCheck SC2086 wiki](https://www.shellcheck.net/wiki/SC2086)
- [Claude Code Agent Teams documentation](https://code.claude.com/docs/en/agent-teams)
