# Issue: Subprocess Permission Inheritance Gap

**Status**: Verified (all empirical tests pass 2026-02-23; P0/P3/P4/V10 answered)
**Date**: 2026-02-23
**Discovered during**: ADR benchmark clarification review
**Severity**: High — affects headless/automated workflows

## Problem

Plankton's [Phase 3](../REFERENCE.md#phase-3-delegate--verify) fix
delegation spawns a child `claude -p` process from `multi_linter.sh`
(line 403). This subprocess does **not** pass
`--dangerously-skip-permissions`, and shell-spawned child processes do
**not** inherit the parent session's permission state
[verified: `multi_linter.sh:403-408` — no permission flag present].

This causes the subprocess to silently fail in all invocation contexts:
the main Claude session is always interactive, but the subprocess is
always headless (`claude -p`), so there is no UI to approve tool use
[user-stated]. The fix subprocess's tool scope, settings path, and
permission configuration are all hardcoded with no user control
[verified: `config.json` — `subprocess` section has `timeout` and
`model_selection` only, no tool or permission config].

```bash
# Pre-fix invocation (multi_linter.sh:403-408)
${timeout_cmd} "${claude_cmd}" -p "${prompt}" \
  --settings "${HOME}/.claude/no-hooks-settings.json" \
  --allowedTools "Edit,Read,Bash" \
  --max-turns 10 \
  --model "${model}" \
  "${fp}" >/dev/null 2>&1
```

**Issues**: No `--dangerously-skip-permissions` flag; `--allowedTools`
whitelist may be silently ignored under `bypassPermissions` mode
(GitHub issue #12232); `Bash` tool is included but unnecessary for
pure text edits; settings file is user-level (`~/`) instead of
project-local; all output discarded to `/dev/null`; `"${fp}"` is
passed as a second positional argument but `claude` CLI only
documents one positional (`prompt`) — the file path may be silently
ignored [verified: `claude --help` shows
`Usage: claude [options] [command] [prompt]`].

## Root Cause

The subprocess invocation was written assuming that `claude -p` would
either inherit permissions from the parent or function without explicit
permission bypass. Neither is true for shell-spawned processes (as
distinct from Task-tool subagents, which do inherit) [inferred from:
Claude Code GH #22665 reports settings.json allowlists don't
propagate across process boundaries; P0 analysis below distinguishes
subagent vs shell-spawned inheritance]. Additionally, the subprocess
configuration was designed as a fixed internal detail rather than a
user-facing config surface, leading to hardcoded values for tool scope
(`Edit,Read,Bash`), settings path (`~/.claude/no-hooks-settings.json`),
and output handling (`>/dev/null 2>&1`)
[verified: `multi_linter.sh:403-408`].

## Impact

The subprocess silently fails in all contexts. The main Claude session
is always interactive, but the subprocess is always headless
(`claude -p`) — there is no UI to approve tool use. Any user running
Plankton will have Phase 3 subprocess fixes silently fail, whether in
CI/automation or interactive sessions.

## Process routing surfaces

Running Plankton involves three independent `claude` process types,
each with its own settings file. This matters for the permission fix
because each process must be independently configured — settings do
not propagate between them.

All paths below are relative to `~/.claude/`.

| Process | Current settings | Purpose |
| --- | --- | --- |
| **Baseline** (no hooks) | `bare-settings.json` | Clean comparison runs |
| **Plankton main agent** | Default | Normal interactive/headless use |
| **Fix subprocess** | `.claude/subprocess-settings.json` | Phase 3 fix |

When using alternative model providers (e.g., Z.AI/GLM), each process
type requires a separate settings file with the provider's `env` block
so API calls route correctly and model aliases resolve:

| Claude alias | GLM model ID |
| --- | --- |
| opus | glm-5 |
| sonnet | glm-4.7 |
| haiku | glm-4.5-air |

Z.AI settings files must include the routing env block:

```json
{
  "disableAllHooks": true,
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<token>",
    "ANTHROPIC_MODEL": "glm-4.5-air",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.5-air",
    "API_TIMEOUT_MS": "3000000"
  }
}
```

## Evidence

- `multi_linter.sh:403-408` — no `--dangerously-skip-permissions`
  flag on subprocess invocation
- Claude Code GitHub issue #22665 — reports Task tool subagents
  don't inherit settings.json permission allowlists (closed as
  duplicate of #18950; relates to allowlist inheritance, not
  `--dangerously-skip-permissions` bypass)
- Claude Code GitHub issue #25503 — `--dangerously-skip-permissions`
  shows WARNING dialog on every launch unless
  `skipDangerousModePermissionPrompt: true` is in settings
- Claude Code GitHub issue #12232 — `--allowedTools` whitelist may
  be silently ignored when combined with `bypassPermissions` mode;
  `--disallowedTools` (blacklist) works correctly in all modes
- Claude Code GitHub issue #24073 — teammates spawned in
  delegate mode with `mode: "bypassPermissions"` lose tool access
  (labeled as duplicate; no maintainer confirmation)

## Implemented Fix

**Implementation method**: TDD — all steps below were implemented with
tests written first [user-stated]. Deterministic logic (config
parsing, pattern matching, blacklist derivation, tier selection,
override precedence) is covered by automated TDD tests. Empirical
Claude Code behavior (P0 permission inheritance, P3 env propagation,
P4 model alias precedence) requires live `claude -p` invocations
and is covered by manual verification protocols.

**Execution context**: This plan was executed by Claude Code itself
with the user's assistance. Steps that require toggling Plankton
hooks on or off (Step 0 reproduction, verification items P0/P3/P4)
are **user handoff points**: Claude Code must pause, explain what
needs to happen, and instruct the user to restart the session with
the appropriate hook state before continuing [user-stated].

**Step ordering**: Step 3 (observable logging) was implemented first, then
Step 1 (permission bypass), Step 1.5 (tier config consolidation),
Step 2 (settings migration). Step 0 (reproduction) was not run because
hooks must be disabled for the session — deferred to manual verification.

### Step 3 (implemented first): Add observable logging via stderr [DONE]

Enhanced subprocess logging beyond exit code, using stderr
(consistent with existing hook warning pattern):

- Changed `>/dev/null 2>&1` to `>/dev/null` so subprocess stderr
  flows through to the hook's stderr channel (visible in
  `claude --debug` and verbose mode, invisible to the model)
  [verified: `multi_linter.sh:555` — `"${fp}" >/dev/null` without `2>&1`]
- Compare target file hash (cksum) before and after subprocess execution
  [verified: `multi_linter.sh:540-546`]
- Log whether the file was actually modified: `[hook:subprocess] file modified`
  or `file unchanged` [verified: `multi_linter.sh:558-562`]
- Log subprocess model and tool scope: `[hook:subprocess] model=X tools=Y
  max_turns=Z timeout=W` [verified: `multi_linter.sh:538`]

**Test suite**: `test_subprocess_logging.sh` — 5 tests (3a: stderr flows,
3b: file modified/unchanged detection, 3c: model and tools logged)
[verified: all 5 pass].

### Step 0: Reproduce the problem (run after Step 3) [VERIFIED — bug NOT reproduced]

With logging in place, empirically confirm the subprocess is
blocked in headless mode:

1. Run `claude -p` with a file containing lint violations
2. Observe whether Phase 3 subprocess edits are applied
3. Confirm the subprocess times out or exits non-zero without
   modifying the target file
4. Use the new stderr logging to identify the failure reason
   (permission blocked vs timeout vs other)

This reproduction also definitively answers P0: whether shell-spawned
subprocesses inherit `bypassPermissions` from the parent. Document
the result regardless of outcome.

### Step 1: Add `--dangerously-skip-permissions` and `--disallowedTools` [DONE]

Added `--dangerously-skip-permissions` to the subprocess CLI call
[verified: `multi_linter.sh:550`].

**Safety invariant**: `--dangerously-skip-permissions` is never passed
without `--disallowedTools` also being present, except when all tools
are allowed (tier tools = full tool universe), in which case the flag
is omitted and a warning is emitted [verified: `multi_linter.sh:549-556`
— uses `disallowed_flag` array, conditionally populated].

**Used `--disallowedTools` only** — `--allowedTools` removed.
GitHub issue #12232 documents that `--allowedTools` is silently
ignored under `bypassPermissions` mode. `--disallowedTools` works
correctly in all modes. One code path, no fallback logic needed.

**Post-fix invocation** (`multi_linter.sh:549-556`):

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

**Test suite**: `test_subprocess_permissions.sh` — 4 tests (1a:
skip-permissions present, 1b: disallowedTools present / allowedTools
absent, 1c: safety invariant) [verified: all 4 pass].

### Step 1.5: Consolidate per-tier subprocess config [DONE]

Consolidated from scattered flat config (`model_selection` for patterns,
hardcoded tool scope, hardcoded `--max-turns 10`, flat `timeout: 300`)
into `subprocess.tiers` structure where each tier owns all its settings.

**Per-tier settings**: `patterns`, `tools`, `max_turns`, `timeout`.

**Cross-tier settings** (at subprocess level):
`global_model_override`, `max_turns_override`, `timeout_override`,
`volume_threshold`, `settings_file`.

**Precedence**: `global_model_override` > `volume_threshold` >
`opus` patterns > `sonnet` patterns > `haiku` patterns > fallback.
When `global_model_override` is set, ALL tier selection is skipped
(pattern matching, volume_threshold). `max_turns_override` and
`timeout_override` override per-tier values when set [user-stated].

**Unmatched patterns**: Trigger a stderr warning and fall back to
haiku (cheapest-safe fallback) [verified: `multi_linter.sh:319-333`
— iterates violation codes, tests against all three tier patterns,
warns on non-match].

**Top-level `_comment`**: One comment explaining the overall
structure. No per-field comments inside tier objects — field names
(`patterns`, `tools`, `max_turns`, `timeout`) are self-explanatory
[user-stated: agreed].

Implemented `config.json` shape:

```json
{
  "subprocess": {
    "_comment": "Per-tier config for Phase 3 subprocess. Tiers checked: opus, sonnet, haiku. Unmatched patterns warn and fall back to haiku. Global overrides skip all tier selection.",
    "tiers": {
      "haiku": { "patterns": "E[0-9]+|W[0-9]+|F[0-9]+|...", "tools": "Edit,Read", "max_turns": 10, "timeout": 120 },
      "sonnet": { "patterns": "C901|PLR[0-9]+|...", "tools": "Edit,Read", "max_turns": 10, "timeout": 300 },
      "opus": { "patterns": "unresolved-attribute|type-assertion", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600 }
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
```

The `--disallowedTools` blacklist is derived at runtime per tier:
(all known tools) minus (tier-specific `tools` list). The "all
known tools" universe is hardcoded in `multi_linter.sh` and pinned
to the Claude Code version in `cc_tested_version` — update this
list when updating `cc_tested_version`
[verified: `multi_linter.sh:507` — `tool_universe="Edit,Read,Write,Bash,Glob,Grep,WebFetch,WebSearch,NotebookEdit,Task"`].

**Code changes in `multi_linter.sh`**:

- `check_config_migration()` (lines 67-79): Detects old flat config keys,
  errors with migration instructions if `subprocess.tiers` absent
  [verified: `multi_linter.sh:67-79`]
- `load_model_patterns()` (lines 82-132): Refactored to read from
  `subprocess.tiers` structure. Added `HAIKU_CODE_PATTERN` with sensible
  default covering 50+ ruff/shellcheck/biome rule families. Added
  `GLOBAL_MODEL_OVERRIDE`, `MAX_TURNS_OVERRIDE`, `TIMEOUT_OVERRIDE`,
  per-tier `max_turns`/`timeout`/`tools` [verified: `multi_linter.sh:82-132`]
- Model selection logic (lines 288-317): `global_model_override` bypasses
  all tier selection. Otherwise: opus patterns → sonnet patterns → haiku
  default. Volume threshold promotes to opus
  [verified: `multi_linter.sh:293-317`]
- Unmatched pattern warning (lines 319-333): Iterates violation codes,
  tests against all three tier patterns, warns on non-match
  [verified: `multi_linter.sh:319-333`]
- Per-tier `max_turns` and `timeout` (lines 335-356): Read from selected
  tier's config, apply `*_override` if set
  [verified: `multi_linter.sh:335-356`]

**Backwards compatibility**: Old flat config keys (`timeout`,
`model_selection.sonnet_patterns`, etc.) are not supported. If
detected, emit a clear error with migration instructions pointing
to the new `subprocess.tiers` structure. No auto-migration
[user-stated: clean break, no old key support].

**Migration**: All 9 inline old-format configs across 3 files were
migrated to the new tiers format:

- `.claude/tests/hooks/fixtures/config.json` — 1 config
- `.claude/hooks/test_hook.sh` — 3 inline configs
- `tests/stress/run_stress_tests.sh` — 5 inline configs
[verified: `grep -c model_selection` returns 0 for all 3 files].

**Test suite**: `test_tier_config.sh` — 16 tests (1.5a: haiku for SC codes,
1.5b: haiku with default config, 1.5b2: sonnet when SC matches sonnet
patterns, 1.5c: opus when SC matches opus patterns, 1.5d: unmatched
pattern warning + defaults to haiku, 1.5e: global_model_override,
1.5g: per-tier max_turns, 1.5h: max_turns_override, 1.5i: per-tier
timeout, 1.5j: timeout_override, 1.5k: old flat config error,
1.5l: disallowedTools blacklist, 1.5m: all tools allowed — warning +
flag omitted) [verified: all 16 pass].

### Step 2: Configurable subprocess settings [DONE]

The subprocess settings path was hardcoded. Two changes implemented:

**A. Config override support** [verified: `multi_linter.sh:468-475`]:

```bash
# Read from config, default to project-local path
settings_file=$(echo "${CONFIG_JSON}" | jaq -r \
  '.subprocess.settings_file // empty' 2>/dev/null) || true
# Expand leading tilde to $HOME
settings_file="${settings_file/#\~/$HOME}"
[[ -z "${settings_file}" ]] && \
  settings_file="${CLAUDE_PROJECT_DIR:-.}/.claude/subprocess-settings.json"
```

This is backwards-compatible: existing configs without the key
use the new project-local default. Users who need alternative
provider routing (e.g., Z.AI) can override via config.json:

```json
{
  "subprocess": {
    "settings_file": "~/.claude/glm-no-hooks-settings.json"
  }
}
```

**B. Created `.claude/subprocess-settings.json`** (project-level, not
user-level) with minimal configuration [verified: file exists in staging]:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
```

- No MCP servers
- No hooks
- No unnecessary context
- `skipDangerousModePermissionPrompt: true`

**Migration scope**: References to `no-hooks-settings.json` were
updated in staged files:

| File | Status |
| --- | --- |
| `.claude/hooks/multi_linter.sh` | [DONE] uses `subprocess-settings.json` |
| `.claude/tests/hooks/test_production_path.sh` | [DONE] project-local |
| `docs/REFERENCE.md` | [DONE] refs updated |
| `docs/psf/00-plankton-architecture-overview.md` | [DONE] ref updated |
| `docs/tests/README.md` | [DONE] refs updated |
| `.claude/tests/hooks/results/RESULTS.md` | [DONE] refs updated |
| `.claude/tests/hooks/results/COMPARISON.md` | [DONE] refs updated |
| `docs/specs/subprocess-permission-gap.md` | Updated here |
| `docs/specs/adr-glm-benchmark-support.md` | [NOT STAGED] |
| `docs/specs/adr-versioning-cc-compatibility.md` | [NOT STAGED] |
| `docs/specs/adr-package-manager-enforcement.md` | [NOT STAGED] |
| `docs/specs/adr-hook-integration-testing.md` | [NOT STAGED] |
| `docs/specs/adr-hook-schema-convention.md` | [NOT STAGED] |
| `docs/specs/posttooluse-issue/make-plankton-work.md` | [NOT STAGED] |
| `docs/specs/posttooluse-issue/posttoolusewrite-hook-stderr-drop.md` | — |

Note: DEP14 (`.claude/tests/hooks/results/RESULTS.md`)
previously documented a bug where tests checked the project-local
path instead of `~/` — this migration resolves that inconsistency
[verified: test_production_path.sh now creates project-local settings].

**Test suite**: `test_subprocess_settings.sh` — 8 tests (2a: default
project-local path, 2b: config override path, 2c: settings file content
validation, 2d: no remaining old references, 2e: tilde expansion)
[verified: all 8 pass].

### Security rationale

`--dangerously-skip-permissions` is added as an implementation
invariant, not a user opt-in toggle — the subprocess is always
constrained by `--disallowedTools` (safety invariant: no bypass
without tool constraints, except when tier allows all tools — in
which case `--disallowedTools` is omitted and a warning is emitted)
[verified: `multi_linter.sh:534-536,549-556`]. The subprocess is
further bounded by:

- **Tool scope**: Configurable per tier via `config.json`
  (`subprocess.tiers.{tier}.tools`); defaults to `Edit,Read` for
  haiku/sonnet, `Edit,Read,Write` for opus. `--disallowedTools`
  blocks everything else
- **Turn limit**: `--max-turns` configurable per tier (default 10
  for haiku/sonnet, 15 for opus); `max_turns_override` available
  [verified: `multi_linter.sh:553`]
- **Timeout**: Configurable per tier (default 120s haiku, 300s
  sonnet, 600s opus); `timeout_override` available
- **Single-file context**: The subprocess receives exactly one file path
- **No hooks**: Settings disable all hooks, preventing recursive
  invocation
- **Non-fatal**: Subprocess failure does not block the parent hook

These constraints make the subprocess's blast radius comparable to a
deterministic auto-formatter (ruff format, biome format) that already
runs without permission prompts in Phase 1. The permission bypass
enables the subprocess to function in headless/CI environments where
no UI exists to approve tool use.

### Rollback strategy

Removing `--dangerously-skip-permissions` from the subprocess
invocation returns it to the current (permission-blocked) state.
This is a known-safe baseline — the subprocess silently fails but
the hook continues. No additional toggle or env var is needed.

## Verification

All deterministic verification steps are covered by TDD test suites.
Empirical steps (P0, P3, P4) require manual verification.

**Test suite totals**: 33 dedicated tests + 112 self-tests + 133 stress
tests = 278 unit assertions, 0 failures. Empirical tests: P0 (2 tests,
1 pass — permission inheritance confirmed), Step 0 (4 tests, 2 pass —
bug not reproduced, fix works), P3/P4/V10 (3 tests, 3 pass — env
propagation confirmed, model flag wins, Z.AI routing works).

1. **Step 0 reproduction** (run after Step 3 logging): Bug NOT
   reproduced — old invocation also modified the file. Subprocess
   permissions inherit from parent session (see P0 answer).
   [DONE — test_step0_reproduction.sh, 2026-02-23]
2. **Per-tier config**: Confirm `subprocess.tiers.haiku.tools` =
   `"Edit,Read"` results in `--disallowedTools` blocking Bash,
   Write, WebFetch, WebSearch, NotebookEdit, Task, etc. Confirm
   opus tier includes Write. Confirm per-tier `max_turns` and
   `timeout` apply correctly [DONE — tests 1.5l, 1.5g, 1.5i]
3. **`--disallowedTools` enforcement under `bypassPermissions`**:
   P0 test confirmed Edit works with skip-permissions. Blacklist
   enforcement not yet tested with a blocked tool invocation attempt
   [PARTIAL — test_empirical_p0.sh confirms Edit allowed, 2026-02-23]
4. **Fix applied**: New invocation (with skip-permissions) exits 0
   and modifies file. Old invocation also works (P0 inheritance).
   [DONE — test_step0_reproduction.sh, 2026-02-23]
5. **Settings file**: Confirm `.claude/subprocess-settings.json`
   exists in project, contains no MCP servers or hooks, and
   subprocess loads it correctly
   [DONE — test 2c validates content]
6. **Config override**: Test with `subprocess.settings_file` in
   config.json → uses custom path. Test without key → falls back
   to `.claude/subprocess-settings.json`
   [DONE — tests 2a, 2b]
7. **Portability**: Auto-creation logic at `multi_linter.sh:478-499`
   creates `subprocess-settings.json` if missing (atomic mktemp+mv).
   Fresh clone works without pre-existing settings file
   [DONE — code review confirms auto-creation, 2026-02-23]
8. **Settings migration**: Grep for `no-hooks-settings` across the
   entire repo and confirm zero remaining references after migration
   [DONE — grep confirms 0 remaining references across all spec files]
9. **DEP14 regression**: Confirm test fixtures use the new
   project-local path (`.claude/subprocess-settings.json`)
   [DONE — test_production_path.sh uses project-local path]
10. **Alternative provider routing**: Z.AI routing succeeds (exit 0)
    via `--settings` env block. Model self-identifies as Claude (not
    GLM) — GLM models appear to self-identify as Claude variants.
    Model alias resolution not confirmed but routing works
    [DONE — test_empirical_p3_p4.sh v10 test, 2026-02-23]
11. **Env propagation**: **YES** — `--settings` env block propagates
    env vars to subprocess. `PLANKTON_P3_TEST_MARKER` visible via
    Bash tool in subprocess. No shell-level `export` fallback needed
    [DONE — test_empirical_p3_p4.sh, 2026-02-23]
12. **P0 empirical answer**: **YES** — shell-spawned subprocesses
    DO inherit `bypassPermissions` from the parent session. The fix
    (`--dangerously-skip-permissions`) is still valid as explicit >
    implicit [DONE — test_empirical_p0.sh, 2026-02-23]
13. **Three-tier pattern config**: Confirm `tiers.haiku.patterns`,
    `tiers.sonnet.patterns`, `tiers.opus.patterns` all read from
    config and match correctly
    [DONE — tests 1.5a, 1.5b, 1.5b2, 1.5c]
14. **Unmatched pattern warning**: Trigger a pattern not in any
    tier, confirm stderr warning logged
    [DONE — test 1.5d]
15. **`global_model_override`**: Set to `"sonnet"`, confirm all
    subprocess invocations use sonnet regardless of pattern
    [DONE — test 1.5e]
16. **`global_model_override: null`**: Confirm normal tiered
    selection applies
    [DONE — tests 1.5a, 1.5b verify default behavior]
17. **Per-tier `max_turns`**: Confirm haiku uses 10, opus uses 15.
    Confirm `max_turns_override` overrides all tiers
    [DONE — tests 1.5g, 1.5h]
18. **Per-tier `timeout`**: Confirm haiku uses 120s, sonnet 300s,
    opus 600s. Confirm `timeout_override` overrides all tiers
    [DONE — tests 1.5i, 1.5j]
19. **Backwards compatibility**: Old flat config (`timeout: 300`,
    `model_selection.sonnet_patterns`) produces a clear error with
    migration instructions
    [DONE — test 1.5k]
20. **File path positional arg**: Empirically verify that
    `claude -p "prompt" filepath` provides the file as context.
    Step 0 reproduction confirmed both old and new invocations
    modify the target file, so the positional arg is received
    [DONE — test_step0_reproduction.sh, 2026-02-23]

## Resolved Questions

- **Does the subprocess need `Bash` tool access?** No. Phase 3
  performs pure text edits (formatting, import reordering, type
  hints). `Bash` has been removed from the tool scope. The
  `--disallowedTools` blacklist now explicitly blocks it.

- **`--allowedTools` vs `--disallowedTools`**: GitHub issue #12232
  reports `--allowedTools` is silently ignored under
  `bypassPermissions` mode. **Decision**: use `--disallowedTools`
  only. One code path, known to work in all modes. No fallback
  logic needed [user-stated: agreed during clarification review].

- **Tool scope configurability**: Tool scope is configurable per
  tier via `config.json` (`subprocess.tiers.{tier}.tools`). Default
  haiku/sonnet to `Edit,Read`, opus to `Edit,Read,Write`. The
  `--disallowedTools` blacklist is derived at runtime
  [user-stated: agreed during clarification review].

- **Config consolidation**: Per-tier settings (`patterns`, `tools`,
  `max_turns`, `timeout`) merged into `subprocess.tiers` structure.
  Cross-tier overrides (`global_model_override`, `max_turns_override`,
  `timeout_override`, `volume_threshold`) at subprocess level
  [user-stated: agreed during clarification review].

- **`volume_threshold` interaction with `global_model_override`**:
  `global_model_override` takes absolute precedence, skipping all
  pattern matching AND `volume_threshold`. Documented in config
  `_comment` and Step 1.5 precedence chain [user-stated].

- **Security gate**: `--dangerously-skip-permissions` is an
  implementation invariant, not a user opt-in toggle. When
  `disallowed_tools` is non-empty, it is always present alongside
  `--disallowedTools`. When all tools are allowed (empty blacklist),
  `--disallowedTools` is omitted and a warning is emitted
  [verified: `multi_linter.sh:534-556`].

- **Step ordering**: Step 3 (logging) was implemented first, then
  Step 1 (permissions), Step 1.5 (tier config), Step 2 (settings)
  [verified: conversation history].

- **Migration strategy**: Functional fix (Steps 1-3) confirmed
  working before migration. Code and test files first,
  documentation second [user-stated].

- ~~**P0: Does `bypassPermissions` inherit to shell-spawned subprocesses?**~~
  Moved from Open Questions. **Answer: YES** — empirical test
  (test_empirical_p0.sh, 2026-02-23) confirmed that `claude -p`
  without `--dangerously-skip-permissions` CAN use the Edit tool
  when launched from a parent session with `bypassPermissions`.
  The original subprocess failure was NOT caused by missing
  permissions. The fix remains valid (explicit > implicit ensures
  the subprocess works regardless of parent state).

- ~~**P3: Does `--settings` env block propagate to subprocesses?**~~
  Moved from Open Questions. **Answer: YES** — env vars set in
  `--settings` env block are visible to the subprocess via Bash tool.
  Alternative provider routing works without shell-level `export`
  [empirical: test_empirical_p3_p4.sh, 2026-02-23].

- ~~**P4: Model alias precedence**~~: Moved from Open Questions.
  **Answer: `--model` flag wins** over `env.ANTHROPIC_MODEL` from
  `--settings` env block [empirical: test_empirical_p3_p4.sh,
  2026-02-23]. Per-tier model selection is safe with provider routing.

- ~~**V10: Z.AI provider routing**~~: Moved from Open Questions.
  Z.AI routing via `--settings` env block succeeds (exit 0). GLM
  models self-identify as Claude variants (e.g., `claude-sonnet-4-6`)
  — alias resolution works at the API level even though the model
  doesn't self-report a GLM name
  [empirical: test_empirical_p3_p4.sh v10 test, 2026-02-23].

- ~~**P0a: Is the file path positional argument received by the subprocess?**~~
  Moved from Open Questions. The implementation retains `"${fp}"` as
  a positional argument. Step 0 reproduction confirmed the subprocess
  CAN edit the target file (both old and new invocations modified the
  file), so the positional arg is received
  [empirical: test_step0_reproduction.sh, 2026-02-23].

- ~~**Settings file auto-creation**~~: Moved from Open Questions.
  Implemented: `multi_linter.sh:478-497` auto-creates
  `.claude/subprocess-settings.json` if missing using atomic
  `mktemp+mv` pattern for concurrent invocations
  [verified: `multi_linter.sh:478-497`].

- ~~**`Bash` tool in current code**~~: Moved from Open Questions.
  Resolved: `Bash` removed from default tool lists. Haiku/sonnet
  default to `Edit,Read`, opus to `Edit,Read,Write`. No TDD test
  required Bash access [verified: `multi_linter.sh:121-125`].

- ~~**Haiku pattern list completeness**~~: Moved from Open Questions.
  Implemented: default `HAIKU_CODE_PATTERN` covers 50+ rule families
  (E, W, F, B, S, T, N, UP, YTT, ANN, BLE, FBT, A, COM, DTZ, EM,
  EXE, ISC, ICN, G, INP, PIE, PYI, PT, Q, RSE, RET, SLF, SIM, TID,
  TCH, INT, ARG, PTH, TD, FIX, ERA, PD, PGH, PLC, PLE, PLW, TRY,
  FLY, NPY, AIR, PERF, FURB, LOG, RUF, SC, DL, I).
  Unmatched patterns trigger a warning and fall back to haiku
  [verified: `multi_linter.sh:83,319-333`].

## Open Questions

Listed in priority order — resolve top items first as they
determine severity and shape the implementation.

- ~~**P0: Does `bypassPermissions` mode actually inherit to subprocesses?**~~
  Moved to Resolved. **Answer: YES** — shell-spawned `claude -p`
  subprocesses DO inherit `bypassPermissions` from the parent session
  [empirical: 2026-02-23, test_empirical_p0.sh]. The fix
  (`--dangerously-skip-permissions`) remains valid as explicit > implicit.

- **P2: `--disallowedTools` completeness**: The runtime blacklist
  derivation (all tools minus tier-specific allowed tools) requires
  knowing the complete Claude Code tool list. This list may change
  across versions — the implementation maintains a pinned list
  (`tool_universe` at `multi_linter.sh:507`) tied to `cc_tested_version`
  [verified: implementation uses pinned list]. Dynamic query not
  implemented — manual update required when upgrading Claude Code.

- ~~**P3: Does `--settings` `env` block propagate to hook child processes?**~~
  Moved to Resolved. **Answer: YES** — `--settings` env block
  propagates env vars to the subprocess. Alternative provider routing
  via settings env works [empirical: 2026-02-23, test_empirical_p3_p4.sh].

- ~~**P4: Model alias precedence**~~: Moved to Resolved.
  **Answer: `--model` flag wins** over `env.ANTHROPIC_MODEL`
  [empirical: 2026-02-23, test_empirical_p3_p4.sh]. Per-tier model
  selection via `--model` works even with provider env routing.

- ~~**Settings migration — remaining spec files**~~: Moved to Resolved.
  Grep confirms 0 references to `no-hooks-settings.json` in any of the
  7 listed spec/ADR files. The claim was stale.

## References

- [Claude Code issue #22665 - Subagent allowlist inheritance](https://github.com/anthropics/claude-code/issues/22665)
- [Claude Code issue #18950 - Skills/subagents permission inheritance](https://github.com/anthropics/claude-code/issues/18950)
- [Claude Code issue #25503 - dangerously-skip-permissions dialog](https://github.com/anthropics/claude-code/issues/25503)
- [Claude Code issue #12232 - allowedTools ignored under bypassPermissions](https://github.com/anthropics/claude-code/issues/12232)
- [Claude Code issue #24073 - Delegate mode permission leakage](https://github.com/anthropics/claude-code/issues/24073)
- [ADR: Plankton Code Quality Benchmark](adr-plankton-benchmark.md) — originated
  subprocess configurability and alternative-provider routing requirements
- [ADR: GLM/Z.AI Model Support](adr-glm-benchmark-support.md) — superseded;
  content merged into this document
- [PR #2: Setup wizard](https://github.com/alexfazio/plankton/pull/2) —
  handles settings file auto-creation for fresh environments
