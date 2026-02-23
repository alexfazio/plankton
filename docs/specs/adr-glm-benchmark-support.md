# ADR: GLM/Z.AI Model Support for Benchmarking

**Status**: Superseded — merged into [Subprocess Permission Inheritance Gap](subprocess-permission-gap.md)
**Date**: 2026-02-23
**Author**: alex fazio + Claude Code research synthesis
**Parent ADR**: [ADR: Plankton Code Quality Benchmark](adr-plankton-benchmark.md)

## Context

Z.AI provides GLM models accessible through an Anthropic-compatible API.
Claude Code can run natively with GLM via the `cc -glm` zsh wrapper,
which passes `--settings ~/.claude/zai-settings.json`. This settings
file routes all API calls through `https://api.z.ai/api/anthropic` and
maps Claude model aliases to GLM equivalents:

| Claude alias | GLM model ID |
| --- | --- |
| opus | glm-5 |
| sonnet | glm-4.7 |
| haiku | glm-4.5-air |

Running the benchmark with GLM tests whether Plankton's write-time
enforcement generalizes beyond Claude models — a stronger claim than
single-model results.

## Three routing surfaces

Running a full A/B benchmark with GLM requires routing three
independent `claude` process types through Z.AI:

All paths below are relative to `~/.claude/`.

| Process | Current settings | GLM settings |
| --- | --- | --- |
| **Baseline** (no hooks) | `bare-settings.json` | `glm-bare-settings.json` |
| **Plankton main agent** | Default | `--settings zai-settings.json` |
| **Fix subprocess** | `subprocess-settings.json` | `glm-subprocess-settings.json` |

Each settings file must include the Z.AI `env` block so the process
connects to the correct API endpoint and resolves model aliases
correctly.

## Required changes

### 1. Make subprocess settings configurable (multi_linter.sh)

The subprocess settings path is hardcoded at line 404 of
`multi_linter.sh`. Add support for reading
`subprocess.settings_file` from `config.json`:

```bash
# Read from config, default to subprocess-settings.json
SUBPROCESS_SETTINGS=$(echo "${CONFIG_JSON}" | jaq -r \
  '.subprocess.settings_file // empty' 2>/dev/null) || true
[[ -z "${SUBPROCESS_SETTINGS}" ]] && \
  SUBPROCESS_SETTINGS=".claude/subprocess-settings.json"
```

This is backwards-compatible: existing configs without the key
use the current default.

### 2. Create GLM settings files

**`~/.claude/glm-bare-settings.json`** — baseline (no hooks, Z.AI routing):

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

**`~/.claude/glm-subprocess-settings.json`** — same content (for
Plankton subprocesses). Separate file for clarity even though
content is identical to `glm-bare-settings.json`.

The existing `~/.claude/zai-settings.json` is used as-is for
the Plankton main agent condition.

### 3. Add --settings override to runner.py

Add a `--settings` argument to `runner.py` that overrides the
settings file per condition:

- **Baseline**: `--settings ~/.claude/glm-bare-settings.json`
- **Plankton**: `--settings ~/.claude/zai-settings.json`

The `--model haiku` flag stays unchanged — the
`ANTHROPIC_DEFAULT_HAIKU_MODEL` env var in the settings file
resolves the alias to `glm-4.5-air` automatically.

### 4. Configure Plankton for GLM subprocess routing

Add to the project's `.claude/hooks/config.json`:

```json
{
  "subprocess": {
    "settings_file": "~/.claude/glm-subprocess-settings.json"
  }
}
```

Remove this key after GLM benchmark runs to restore default
behaviour.

## Verification protocol (TDD)

Execute each step and verify before proceeding to the next.

1. **multi_linter.sh config read**: Add `subprocess.settings_file`
   support. Test with config key present → uses custom path. Test
   without key → falls back to `subprocess-settings.json`.

2. **glm-bare-settings.json routes to Z.AI**: Run
   `claude --settings ~/.claude/glm-bare-settings.json -p "hi"`
   and verify the response comes from GLM (check model field).

3. **glm-subprocess-settings.json routes to Z.AI with no hooks**:
   Same test, confirm zero hook invocations.

4. **Baseline zero-hook verification**: Run a baseline task with
   `glm-bare-settings.json` and confirm no PostToolUse hook
   activity (same protocol as Phase 0 Step 4).

5. **Subprocess routing**: Run a Plankton task that triggers lint
   violations. Check hook logs for `[hook:model]` output and
   verify the subprocess used `glm-subprocess-settings.json`.

6. **Model alias resolution**: Confirm `--model haiku` resolves
   to `glm-4.5-air` when Z.AI env vars are active (check output
   metadata or API logs).

7. **2-task ClassEval dry run**: `--dry-run` to verify command
   construction.

8. **2-task ClassEval live run**: Both conditions complete, JSONL
   is valid, GLM model IDs appear in metadata.

## Open questions

- Does Claude Code's `--settings` `env` block propagate env vars
  to child processes spawned by hooks (via `subprocess`/`bash`)?
  If not, the subprocess will not inherit Z.AI routing from the
  settings file and shell-level `export` would be needed as a
  fallback. **Must be tested empirically in verification step 5.**

- Does `--model haiku` resolve correctly when
  `ANTHROPIC_DEFAULT_HAIKU_MODEL` comes from a settings `env`
  block rather than a real shell env var? **Must be tested in
  verification step 6.**

- If both `--settings zai-settings.json` (with
  `env.ANTHROPIC_MODEL: "glm-5"`) and `--model haiku` are
  passed, which takes precedence? **Must be tested before the
  full run.**
