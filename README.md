# Plankton

![Plankton mascot](assets/plankton-cover.png)

A ready-to-use template for real-time, hook-based code quality enforcement
in Claude Code. Provides automated linting, formatting, and code quality
checks that run in real time during Claude Code sessions.

> [!CAUTION]
> **Plankton is an experimental research project — not production-ready.**
>
> This software is experimental, unstable, and under active development. APIs will change without notice. Features may be incomplete or broken. Claude Code CLI updates and underlying model changes may break hooks at any time. Hooks spawn subprocesses that consume significantly more tokens than a standard Claude Code session — disable subprocess delegation in `config.json` if needed. There is no support, no documentation guarantees, and no warranty of any kind. Use at your own risk.

## Quick Start

1. **Use this template** to create a new repository
2. **Install dependencies**:

   ```bash
   pip install uv
   uv sync --all-extras
   ```

3. **Install pre-commit hooks**:

   ```bash
   uv run pre-commit install
   ```

4. **Verify hooks work**:

   ```bash
   .claude/hooks/test_hook.sh --self-test
   ```

5. **Start a Claude Code session** - hooks activate automatically

## What's Included

### Hook Scripts (`.claude/hooks/`)

| File | Type | Purpose |
| ---- | ---- | ------- |
| `multi_linter.sh` | PostToolUse | Three-phase linting after Edit/Write |
| `protect_linter_configs.sh` | PreToolUse | Blocks config file modifications |
| `stop_config_guardian.sh` | Stop | Detects config changes at session end |
| `approve_configs.sh` | Helper | Creates guard file for stop hook |
| `test_hook.sh` | Debug | Self-test suite for hook validation |
| `config.json` | Config | Runtime configuration for all hooks |
| `REFERENCE.md` | Docs | Detailed hook reference (at `docs/REFERENCE.md`) |

### Linter Configurations

| File | Linter | Language |
| ---- | ------ | -------- |
| `.ruff.toml` | Ruff | Python (formatting + linting) |
| `ty.toml` | ty | Python (type checking) |
| `.flake8` | flake8 | Python (Pydantic + async rules) |
| `.yamllint` | yamllint | YAML |
| `.shellcheckrc` | ShellCheck | Shell scripts |
| `.hadolint.yaml` | hadolint | Dockerfiles |
| `.markdownlint.jsonc` | markdownlint | Markdown (rules) |
| `.markdownlint-cli2.jsonc` | markdownlint-cli2 | Markdown (CLI config) |
| `.jscpd.json` | jscpd | Duplicate detection |
| `taplo.toml` | Taplo | TOML |

### Project Files

| File | Purpose |
| ---- | ------- |
| `pyproject.toml` | Project metadata and tool configuration |
| `.pre-commit-config.yaml` | Pre-commit hook configuration |
| `.claude/settings.json` | Claude Code hook registration |
| `CLAUDE.md` | Claude Code behavioral instructions |
| `Dockerfile` | Multi-stage Docker build |
| `docker-compose.yml` | Docker Compose for development |
| `.github/workflows/ci.yml` | GitHub Actions CI pipeline |
| `Makefile` | Common development commands |
| `vulture_whitelist.py` | Vulture false positive suppression |

## Hook System

The hooks use a three-phase architecture:

### Phase 1: Auto-Format (silent)

Applies automatic formatting fixes without reporting to Claude:

- Python: `ruff format` + `ruff check --fix`
- Shell: `shfmt` formatting
- TOML: `taplo fmt`
- Markdown: `markdownlint-cli2 --fix`
- JSON: `jaq` pretty-printing

### Phase 2: Collect Violations (JSON)

Runs linters and collects unfixable violations as structured JSON:

- Python: ruff, ty, flake8-pydantic, flake8-async, vulture, bandit
- Shell: ShellCheck
- YAML: yamllint
- JSON: syntax validation
- TOML: syntax validation
- Markdown: markdownlint-cli2
- Dockerfile: hadolint

### Phase 3: Delegate + Verify

Spawns a `claude -p` subprocess to fix collected violations, then
re-runs Phase 1 + Phase 2 to verify fixes were successful.

Model selection is complexity-based:

| Violation Type | Model | Examples |
| -------------- | ----- | -------- |
| Simple fixes | Haiku | F841, SC2034, JSON syntax |
| Refactoring | Sonnet | C901, PLR*, PYD*, D* |
| Complex/many | Opus | Type errors, >5 violations |

## Configuration

### Runtime Configuration (`config.json`)

Edit `.claude/hooks/config.json` to customize hook behavior. If the file is
missing, all features are enabled with sensible defaults.

#### Language Toggles

Enable or disable linting per language:

```json
{
  "languages": {
    "python": true,
    "shell": true,
    "yaml": true,
    "json": true,
    "toml": true,
    "dockerfile": true,
    "markdown": true,
    "typescript": false
  }
}
```

#### Phase Control

Disable auto-formatting or subprocess delegation:

```json
{
  "phases": {
    "auto_format": true,
    "subprocess_delegation": true
  }
}
```

#### Protected Files

Configure which linter config files are protected from modification:

```json
{
  "protected_files": [
    ".ruff.toml",
    "ty.toml",
    ".flake8"
  ]
}
```

#### Exclusions

Configure paths excluded from security linters (vulture, bandit):

```json
{
  "exclusions": [
    "tests/",
    "docs/",
    ".venv/"
  ]
}
```

#### Subprocess Settings

Configure subprocess timeout and model selection:

```json
{
  "subprocess": {
    "timeout": 300,
    "model_selection": {
      "sonnet_patterns": "C901|PLR[0-9]+|PYD[0-9]+",
      "opus_patterns": "unresolved-attribute",
      "volume_threshold": 5
    }
  }
}
```

### Configuration Reference

| Key | Type | Default | Purpose |
| --- | ---- | ------- | ------- |
| `languages.<type>` | boolean | true | Enable/disable linting per language |
| `protected_files` | string[] | 10 files | Protected file list |
| `exclusions` | string[] | tests/,docs/,... | Paths excluded from linters |
| `phases.auto_format` | boolean | true | Toggle Phase 1 auto-format |
| `phases.subprocess_delegation` | boolean | true | Toggle subprocess |
| `subprocess.timeout` | number | 300 | Subprocess timeout in seconds |
| `subprocess.model_selection.*` | varies | varies | Model selection patterns |
| `jscpd.*` | varies | varies | Duplicate detection settings |

### Environment Variable Overrides

| Variable | Overrides | Purpose |
| -------- | --------- | ------- |
| `HOOK_SUBPROCESS_TIMEOUT` | `subprocess.timeout` | Subprocess timeout |
| `HOOK_SKIP_SUBPROCESS=1` | `phases.subprocess_delegation` | Skip subprocess |
| `HOOK_DEBUG_MODEL=1` | N/A | Output model selection |

## Linter Configuration

Each linter has a standalone config file in the project root. Key
opinionated choices:

### Python (`.ruff.toml`)

- 50+ rule categories enabled (E, F, B, C901, PLR, D, S, UP, RUF, etc.)
- McCabe complexity limit: 10
- Google-style docstrings enforced
- Preview rules enabled for comprehensive coverage

### Python Types (`ty.toml`)

- Target Python 3.11+
- Tests get relaxed rules (warn instead of error)
- Division-by-zero and unresolved references are errors

### Shell (`.shellcheckrc`)

- Maximum enforcement: all optional checks enabled
- Extended dataflow analysis enabled
- Bash dialect enforced

### YAML (`.yamllint`)

- All 23 rules explicitly configured
- 120-character line length
- Maximum strictness with no implicit defaults

### Dockerfile (`.hadolint.yaml`)

- Maximum strictness with failure-threshold at warning
- Inline ignore pragmas disabled
- Label schema enforcement (maintainer, version)
- Only version pinning rules ignored (with documented rationale)

## Pre-Commit Setup

### Installation

```bash
# Install pre-commit
uv add --dev pre-commit

# Install hooks
uv run pre-commit install
```

### Running

```bash
# Run all hooks on all files
uv run pre-commit run --all-files

# Run specific hook
uv run pre-commit run ruff-check --all-files

# Run on staged files only (default on commit)
uv run pre-commit run
```

### Hook Phases

Pre-commit hooks run in order, matching the CC hook phases:

1. ruff-format (Python formatting)
2. ruff-check (Python linting)
3. flake8-async (async pattern detection)
4. ty-check (Python type checking)
5. shellcheck (Shell linting)
6. yamllint (YAML linting)
7. jaq (JSON syntax)
8. taplo (TOML linting)
9. hadolint (Dockerfile linting)
10. check-jsonschema + actionlint (GitHub Actions)
11. markdownlint (Markdown, advisory)
12. jscpd (Duplicate detection, advisory)

## Keeping Hooks and Pre-Commit in Sync

The CC hooks (`multi_linter.sh`) and pre-commit (`.pre-commit-config.yaml`)
enforce the same standards using the same tools. When modifying either
system, keep them aligned.

### Adding a New Linter

1. **Add the tool** to `pyproject.toml` dev dependencies
2. **Add to `multi_linter.sh`**: New case in the file type handler
3. **Add to `.pre-commit-config.yaml`**: New hook entry
4. **Create config file** in project root
5. **Add to `config.json`**: Language toggle (if new language)
6. **Add to protected_files** in `config.json`

### Removing a Linter

1. Remove from `multi_linter.sh`
2. Remove from `.pre-commit-config.yaml`
3. Remove config file
4. Remove from `config.json` protected_files
5. Remove from `pyproject.toml` dependencies

### Changing a Rule

1. Edit the linter's config file
2. Both CC hooks and pre-commit will pick up the change automatically
3. No need to modify hook scripts

### Verification Checklist

After any hook/pre-commit change, verify:

- [ ] `uv run pre-commit run --all-files` passes
- [ ] `.claude/hooks/test_hook.sh --self-test` passes
- [ ] `config.json` protected_files list matches CLAUDE.md list
- [ ] `config.json` protected_files matches default arrays in
      `protect_linter_configs.sh` and `stop_config_guardian.sh`
- [ ] New config files are added to `.gitignore` exclusions if needed
- [ ] CI workflow includes any new tools

## Settings Override

Create `.claude/settings.local.json` for personal overrides that
aren't committed to git:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/multi_linter.sh",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

Add `.claude/settings.local.json` to `.gitignore` if not already excluded.

## Quality Baseline

When starting a new project from this template:

1. **Run initial lint**: `uv run ruff check src tests`
2. **Fix all violations** before first commit
3. **Verify pre-commit**: `uv run pre-commit run --all-files`
4. **Test hooks**: `.claude/hooks/test_hook.sh --self-test`

The template ships with zero violations. Maintaining this baseline is
easier than remediating accumulated debt.

## Dependencies

### Required

| Tool | Install | Purpose |
| ---- | ------- | ------- |
| `jaq` | `brew install jaq` | JSON parsing in hooks |
| `ruff` | `uv add --dev ruff` | Python linting/formatting |
| `claude` | [claude.ai/code](https://claude.ai/code) | Subprocess delegation |

### Optional (gracefully skipped)

| Tool | Install (macOS) | Install (Linux) | Purpose |
| ---- | --------------- | --------------- | ------- |
| `ty` | `uv add --dev ty` | Same | Python type checking |
| `shfmt` | `brew install shfmt` | `apt install shfmt` | Shell formatting |
| `shellcheck` | `brew install shellcheck` | `apt install shellcheck` | Lint |
| `yamllint` | `uv add --dev yamllint` | Same | YAML linting |
| `hadolint` | `brew install hadolint` | GitHub releases | Dockerfile linting |
| `taplo` | `brew install taplo` | Download from GitHub | TOML linting |
| `markdownlint-cli2` | `npm i -g markdownlint-cli2` | Same | Markdown lint |
| `actionlint` | `brew install actionlint` | GitHub releases | GitHub Actions |
| `jscpd` | `npm install` (local) | Same | Duplicate detection |
| `vulture` | `uv add --dev vulture` | Same | Dead code detection |
| `bandit` | `uv add --dev bandit` | Same | Security scanning |
| `timeout` | `brew install coreutils` | Built-in | Subprocess timeout |

## Vulture Whitelist

The `vulture_whitelist.py` file suppresses false positives from vulture's
dead code detection. Add entries when vulture reports code that is
actually used dynamically:

```python
# Example entries:
my_fixture  # pytest fixture, used by dependency injection
MySignal    # Django signal, connected via decorator
```

Vulture verifies that each whitelisted name exists in the codebase.

## Troubleshooting

### Hook not running

- Verify `.claude/settings.json` has correct hook configuration
- Check file permissions: `ls -la .claude/hooks/*.sh`
- Run debug mode: `claude --debug "hooks" --verbose`

### Subprocess not fixing violations

- Check `claude` is in PATH: `which claude`
- Verify no-hooks settings: `cat ~/.claude/no-hooks-settings.json`
- Test manually: `HOOK_SKIP_SUBPROCESS=1 .claude/hooks/test_hook.sh file.py`

### Pre-commit failing

- Update hooks: `uv run pre-commit autoupdate`
- Clean cache: `uv run pre-commit clean`
- Run verbose: `uv run pre-commit run --all-files --verbose`

### Linter config changes blocked

- This is intentional! The PreToolUse hook protects config files.
- To make legitimate changes, the user must approve the blocked edit.
- The Stop hook will also check for unapproved changes at session end.

### Missing tools

- Hooks gracefully skip tools that aren't installed
- Install optional tools as needed (see Dependencies table)
- Only `jaq` and `ruff` are required; everything else is optional

### Model selection debugging

```bash
# See which model would be selected
echo '{"tool_input": {"file_path": "test.py"}}' \
  | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 \
  .claude/hooks/multi_linter.sh
```

## License

[Choose your license]
