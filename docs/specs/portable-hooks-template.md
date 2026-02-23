# Implementation Plan: Portable Claude Code Hooks Template

**Date**: 2026-02-04
**Status**: Draft
**Target**: GitHub template repository at `Documents/GitHub/cc-hooks-template/`

## 1. Problem

The Claude Code hooks system in the Incide codebase (`/.claude/hooks/`) is a
sophisticated 3-phase linting enforcement system that took months to develop
(AIG-182 through AIG-243). It cannot be reused in new projects without manual
extraction, adaptation, and understanding of implicit dependencies. Every new
Python project starts without code quality enforcement during Claude Code
sessions.

## 2. Root Cause

The hooks are embedded in the Incide codebase alongside project-specific
configuration, documentation, and infrastructure. While the hook scripts
themselves are generic (no hardcoded project paths), the surrounding ecosystem
(linter configs, protected file lists, exclusion patterns, settings.json paths,
CLAUDE.md policy text) creates tight coupling that prevents direct reuse.

## 3. Solution

Create a GitHub template repository that packages the entire hooks system as a
one-time-copy, framework-agnostic Python project starter. Users create new
repos from the template and get working hooks immediately. The template evolves
independently per project after creation.

## 4. Template Repository Structure

```text
cc-hooks-template/
├── .claude/
│   ├── hooks/
│   │   ├── config.json              # NEW: Runtime configuration
│   │   ├── multi_linter.sh          # PostToolUse hook (3-phase)
│   │   ├── protect_linter_configs.sh # PreToolUse hook (config protection)
│   │   ├── stop_config_guardian.sh   # Stop hook (config guardian)
│   │   ├── approve_configs.sh        # Helper (guard file creation)
│   │   ├── test_hook.sh             # Debug/self-test utility
│   │   └── REFERENCE.md             # Hook system documentation
│   └── settings.json                # Committed hook configuration
├── .github/
│   └── workflows/
│       └── ci.yml                   # GitHub Actions CI (lint + test)
├── src/
│   ├── __init__.py                  # Package init
│   └── app/
│       └── __init__.py              # Application package init
├── tests/
│   ├── __init__.py                  # Test package init
│   ├── conftest.py                  # Minimal fixtures
│   └── unit/
│       └── __init__.py              # Unit test package init
├── .ruff.toml                       # Python linter (opinionated defaults)
├── ty.toml                          # Type checker config
├── .flake8                          # Pydantic/async linter config
├── .yamllint                        # YAML linter config
├── .shellcheckrc                    # Shell linter config
├── .hadolint.yaml                   # Dockerfile linter config
├── .markdownlint.jsonc              # Markdown linter config
├── .markdownlint-cli2.jsonc         # markdownlint-cli2 config
├── .jscpd.json                      # Duplicate code detection config
├── taplo.toml                       # TOML formatter config
├── vulture_whitelist.py             # Empty whitelist with comments
├── .pre-commit-config.yaml          # Pre-commit hooks (synced with CC hooks)
├── .gitignore                       # Standard Python .gitignore
├── Dockerfile                       # Multi-stage Python Dockerfile
├── docker-compose.yml               # Development stack
├── Makefile                         # lint, test, format, install-hooks targets
├── pyproject.toml                   # Project config with [tool.bandit] etc.
├── CLAUDE.md                        # Simplified: hooks policy only
└── README.md                        # Template usage documentation
```

## 5. Detailed Implementation Steps

### Phase 1: Core Hook Scripts

#### Step 1.1: Copy hook scripts from Incide

Source files:

- `.claude/hooks/multi_linter.sh` (PostToolUse) - needs config.json integration
- `.claude/hooks/protect_linter_configs.sh` (PreToolUse) - needs config.json integration
- `.claude/hooks/stop_config_guardian.sh` (Stop hook) - needs config.json integration
- `.claude/hooks/approve_configs.sh` (helper) - copy as-is, no changes needed
- `.claude/hooks/test_hook.sh` (debug utility) - copy as-is, no changes needed

The scripts are already project-agnostic in their core logic (use
`CLAUDE_PROJECT_DIR` for path normalization, invoke linters by standard
names). The modifications in Steps 1.2-1.4 add config.json reading to
replace hardcoded lists and thresholds.

**Step 1.2: Adapt `multi_linter.sh` to read `config.json`**

Changes needed to `multi_linter.sh`:

1. At script top, add config loading function:

   ```bash
   # Load configuration (falls back to all-enabled if missing)
   load_config() {
     local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
     if [[ -f "${config_file}" ]]; then
       CONFIG_JSON=$(cat "${config_file}")
     else
       CONFIG_JSON='{}'  # Empty = all defaults
     fi
   }

   # Check if a language is enabled (default: true)
   is_language_enabled() {
     local lang="$1"
     local enabled
     enabled=$(echo "${CONFIG_JSON}" | jaq -r ".languages.${lang} // true" 2>/dev/null)
     [[ "${enabled}" != "false" ]]
   }
   ```

2. Wrap each file-type handler with language check:

   ```bash
   # Before (current):
   python) lint_python "$file" ;;

   # After (with config):
   python) is_language_enabled "python" && lint_python "$file" ;;
   ```

3. Read exclusion patterns from config:

   ```bash
   get_exclusions() {
     local defaults='["tests/","docs/",".venv/","scripts/","node_modules/",".git/"]'
     echo "${CONFIG_JSON}" | jaq -r ".exclusions // ${defaults} | .[]" 2>/dev/null
   }
   ```

4. Read model selection patterns from config (replaces hardcoded constants):

   ```bash
   # Current (hardcoded):
   readonly SONNET_CODE_PATTERN='C901|PLR[0-9]+|...'
   readonly OPUS_CODE_PATTERN='unresolved-attribute|...'

   # New (config-driven with defaults):
   load_model_patterns() {
     local default_sonnet='C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+'
     local default_opus='unresolved-attribute|type-assertion'
     SONNET_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r ".subprocess.model_selection.sonnet_patterns // \"${default_sonnet}\"" 2>/dev/null)
     OPUS_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r ".subprocess.model_selection.opus_patterns // \"${default_opus}\"" 2>/dev/null)
     VOLUME_THRESHOLD=$(echo "${CONFIG_JSON}" | jaq -r ".subprocess.model_selection.volume_threshold // 5" 2>/dev/null)
     readonly SONNET_CODE_PATTERN OPUS_CODE_PATTERN VOLUME_THRESHOLD
   }
   ```

5. Read subprocess timeout from config:

   ```bash
   # Current (hardcoded/env var):
   local timeout_val="${HOOK_SUBPROCESS_TIMEOUT:-300}"

   # New (config-driven, env var still overrides):
   local config_timeout
   config_timeout=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.timeout // 300' 2>/dev/null)
   local timeout_val="${HOOK_SUBPROCESS_TIMEOUT:-${config_timeout}}"
   ```

6. Read phase toggles from config:

   ```bash
   # Check if auto-format phase is enabled (default: true)
   is_auto_format_enabled() {
     local enabled
     enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.auto_format // true' 2>/dev/null)
     [[ "${enabled}" != "false" ]]
   }

   # Check if subprocess delegation is enabled (default: true)
   is_subprocess_enabled() {
     local enabled
     enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.subprocess_delegation // true' 2>/dev/null)
     [[ "${enabled}" != "false" ]]
   }
   ```

   Wrap Phase 1 and Phase 3 calls:

   ```bash
   # Phase 1:
   is_auto_format_enabled && run_phase1 "$file" "$type"

   # Phase 3 (replaces current HOOK_SKIP_SUBPROCESS check):
   if is_subprocess_enabled && [[ -z "${HOOK_SKIP_SUBPROCESS:-}" ]]; then
     spawn_fix_subprocess "$file" "$violations" "$type"
   fi
   ```

   **Note**: `HOOK_SKIP_SUBPROCESS` env var still works as an override for
   testing, even when config says `subprocess_delegation = true`.

**Step 1.3: Adapt `protect_linter_configs.sh` to read `config.json`**

Changes needed:

1. Read protected files list from config instead of hardcoded case statement:

   ```bash
   # Load protected files from config, or use defaults
   load_protected_files() {
     local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
     if [[ -f "${config_file}" ]]; then
       # Read explicit protected_files array
       PROTECTED_FILES=$(jaq -r '.protected_files // [] | .[]' "${config_file}" 2>/dev/null)
     fi
     if [[ -z "${PROTECTED_FILES}" ]]; then
       # Default: all standard linter config files
       PROTECTED_FILES=".markdownlint.jsonc .markdownlint-cli2.jsonc .shellcheckrc
         .yamllint .hadolint.yaml .jscpd.json .flake8 taplo.toml .ruff.toml ty.toml"
     fi
   }
   ```

2. The `.claude/hooks/*` and `.claude/settings.json` protection stays
   hardcoded (always protected regardless of config).

**Step 1.4: Adapt `stop_config_guardian.sh` to read `config.json`**

Changes needed:

1. Read `PROTECTED_FILES` array from config instead of hardcoded array:

   ```bash
   # Current (hardcoded):
   PROTECTED_FILES=(".markdownlint.jsonc" ".shellcheckrc" ...)

   # New (config-driven):
   load_protected_files_from_config() {
     local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
     if [[ -f "${config_file}" ]]; then
       mapfile -t PROTECTED_FILES < <(
         jaq -r '.protected_files // [] | .[]' "${config_file}" 2>/dev/null
       )
     fi
     if [[ ${#PROTECTED_FILES[@]} -eq 0 ]]; then
       PROTECTED_FILES=(
         ".markdownlint.jsonc" ".markdownlint-cli2.jsonc" ".shellcheckrc"
         ".yamllint" ".hadolint.yaml" ".jscpd.json" ".flake8"
         "taplo.toml" ".ruff.toml" "ty.toml"
       )
     fi
   }
   ```

### Phase 2: Configuration File

**Step 2.1: Create `.claude/hooks/config.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "_comment": "Claude Code Hooks Configuration - edit this file to customize hook behavior",

  "languages": {
    "python": true,
    "shell": true,
    "yaml": true,
    "json": true,
    "toml": true,
    "dockerfile": true,
    "markdown": true,
    "typescript": false
  },

  "protected_files": [
    ".markdownlint.jsonc",
    ".markdownlint-cli2.jsonc",
    ".shellcheckrc",
    ".yamllint",
    ".hadolint.yaml",
    ".jscpd.json",
    ".flake8",
    "taplo.toml",
    ".ruff.toml",
    "ty.toml"
  ],

  "exclusions": [
    "tests/",
    "docs/",
    ".venv/",
    "scripts/",
    "node_modules/",
    ".git/",
    ".claude/"
  ],

  "phases": {
    "auto_format": true,
    "subprocess_delegation": true
  },

  "subprocess": {
    "timeout": 300,
    "model_selection": {
      "sonnet_patterns": "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+",
      "opus_patterns": "unresolved-attribute|type-assertion",
      "volume_threshold": 5
    }
  },

  "jscpd": {
    "session_threshold": 3,
    "scan_dirs": ["src/", "lib/"],
    "advisory_only": true
  }
}
```

**Design decisions:**

- Falls back to all-enabled defaults when file is missing
- `jaq` parses it natively (zero new dependencies)
- `$schema` field enables IDE validation (future)
- `_comment` field for human documentation (jaq ignores it)
- Protected files are explicit (user controls the list, not derived)
- Exclusions replace the hardcoded `is_excluded_from_security_linters()`
  function when present
- `phases` section controls Phase 1 (auto_format) and Phase 3
  (subprocess_delegation) independently. Phase 2 (collect violations) is
  always on - disabling it would make the hook pointless
- `subprocess.model_selection` patterns are configurable so users can adjust
  which violation types trigger sonnet vs opus without editing bash
- Environment variables (`HOOK_SUBPROCESS_TIMEOUT`, `HOOK_SKIP_SUBPROCESS`)
  still override config.json values for testing/debugging

### Phase 3: Settings and CLAUDE.md

**Step 3.1: Create `.claude/settings.json`**

```json
{
  "permissions": {
    "allow": [],
    "deny": [],
    "ask": []
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/protect_linter_configs.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/multi_linter.sh",
            "timeout": 60
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/stop_config_guardian.sh",
            "timeout": 10
          }
        ]
      }
    ]
  },
  "disableAllHooks": false
}
```

**Key change from Incide**: Relative paths (`.claude/hooks/...`) instead of
absolute paths (`/Users/alex/.../...`). Claude Code resolves relative paths
from the project root.

**Note**: The `permissions.allow` array is empty. Each project populates this
with project-specific permissions. The Incide settings.json has ~90 entries
accumulated over time - none belong in a template.

**Step 3.2: Create simplified `CLAUDE.md`**

Content limited to what the hooks mechanically depend on:

```markdown
# CLAUDE.md

## Code Quality Enforcement

This project uses Claude Code hooks for automated code quality enforcement.

### Linting Ownership Policy (Boy Scout Rule)

When you edit a file using Edit or Write operations, you accept responsibility
for ALL linting violations in that file - whether you introduced them or they
were pre-existing. There are no exceptions.

- Fix violations immediately when the PostToolUse hook reports them
- Use targeted Edit operations - never rewrite entire files to fix violations
- Address violations before moving on to the next task

**Rationale**: Pre-existing violations in files you touch are technical debt
you inherited. Fixing them is part of the edit, not a separate task.

### Linter Config File Protection

**Protected files** (modification forbidden):

- `.ruff.toml` - Python linting (ruff)
- `ty.toml` - Python type checking (ty)
- `.flake8` - Pydantic model linting rules
- `.yamllint` - YAML linting rules
- `.shellcheckrc` - Shell script linting
- `.hadolint.yaml` - Dockerfile linting
- `taplo.toml` - TOML formatting rules
- `.markdownlint.jsonc` - Markdown linting rules
- `.markdownlint-cli2.jsonc` - markdownlint-cli2 config
- `.jscpd.json` - Duplicate code detection
- `.claude/hooks/*` - Hook scripts
- `.claude/settings.json` - Claude Code settings

**Policy**: These files define code quality standards. Modifying them to make
violations disappear (instead of fixing the code) is strictly forbidden.
Fix the code, not the rules.

### Hook Behavior

- **PostToolUse**: Runs linters after every Edit/Write. Auto-formats, collects
  violations, and delegates fixes to a subprocess
- **PreToolUse**: Blocks modifications to linter config files and hook scripts
- **Stop**: Checks for config file modifications at session end

See `docs/REFERENCE.md` for detailed hook documentation.
```

**Note**: This is deliberately minimal. No project architecture, no commands,
no domain knowledge. Just the policy text the hooks depend on. The protected
files list is hardcoded (not derived from config.json) because CLAUDE.md is a
static file read by the LLM. When adding/removing protected files, update both
config.json and this list.

### Phase 4: Linter Configuration Files

#### Step 4.1: Copy opinionated defaults from Incide

All 10 linter config files copied with these modifications:

<!-- markdownlint-disable MD013 -->
| File | Changes from Incide | Rationale |
| ---- | ------------------- | --------- |
| `.ruff.toml` | Remove per-file-ignores for `src/app/data_models.py` | Incide-specific Gemini API constraint |
| `.ruff.toml` | Keep line-length, target-version, rule selections | Generic Python standards |
| `ty.toml` | Remove Incide-specific path exclusions | Clean slate |
| `.flake8` | Remove per-file-ignores for `src/app/data_models.py` | Incide-specific |
| `.flake8` | Keep PYD rule selection, exclude patterns | Generic |
| `.yamllint` | Copy as-is | Already generic (120-char lines, no doc-start) |
| `.shellcheckrc` | Copy as-is | Already generic (all severity levels) |
| `.hadolint.yaml` | Copy as-is | Already generic (maximum strictness) |
| `.markdownlint.jsonc` | Copy as-is | Already generic |
| `.markdownlint-cli2.jsonc` | Remove Incide-specific globs if any | Clean slate |
| `.jscpd.json` | Update `path` entries to `["src/", "lib/"]` | Generic, not `webapp/evaluation/` |
| `taplo.toml` | Copy as-is | Already generic |
<!-- markdownlint-enable MD013 -->

**Step 4.2: Create `vulture_whitelist.py`**

```python
"""Vulture whitelist for false positive suppression.

Add unused-looking names here that are actually used dynamically.
Common examples:
- pytest fixtures (used by dependency injection)
- Django signals, admin classes
- __all__ exports
- Celery tasks registered by decorator
- Click/Typer CLI commands

Format: one Python expression per line.
Vulture checks that each name exists in the codebase.

See: https://github.com/jendrikseipp/vulture
"""
```

**Step 4.3: Create `pyproject.toml`**

Minimal project config with tool sections the hooks depend on:

```toml
[project]
name = "my-project"
version = "0.1.0"
description = "Project description"
requires-python = ">=3.11"
dependencies = []

[project.optional-dependencies]
dev = [
    # Linting & formatting
    "ruff",
    "ty",
    "flake8",
    "flake8-pydantic",
    "flake8-async",
    "vulture",
    "bandit",
    # Testing
    "pytest",
    "pytest-xdist",
    # Pre-commit
    "pre-commit",
    # YAML linting
    "yamllint",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-n auto"

[tool.bandit]
exclude_dirs = ["tests", "docs", ".venv", "scripts"]
skips = []

[tool.vulture]
min_confidence = 80
paths = ["src"]
exclude = ["tests", ".venv"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.backends"
```

### Phase 5: Pre-Commit Configuration

**Step 5.1: Create `.pre-commit-config.yaml`**

Mirrors the 13 hooks from Incide's pre-commit config, adapted for the
template. Uses `repo: local` for all hooks (consistent with Claude Code hooks).

Execution order matches Incide:

1. ruff-format
2. ruff-check
3. flake8-async
4. ty-check
5. shellcheck
6. yamllint
7. check-json (jaq)
8. taplo-check
9. hadolint
10. check-jsonschema (GitHub workflows)
11. actionlint
12. markdownlint
13. jscpd

Each hook uses `language: system` with `entry: uv run ...` or direct binary
invocation, matching the Incide pattern.

**Structure sketch** (representative entries, not complete):

```yaml
repos:
  - repo: local
    hooks:
      # Phase 1: Formatting (fast, auto-fix)
      - id: ruff-format
        name: ruff format
        entry: uv run ruff format
        language: system
        types: [python]

      # Phase 2: Linting (no auto-fix, report only)
      - id: ruff-check
        name: ruff check
        entry: uv run ruff check --preview
        language: system
        types: [python]

      - id: flake8-async
        name: flake8 async
        entry: uv run flake8 --select=ASYNC
        language: system
        types: [python]
        exclude: ^(tests|scripts|scripts-dev|docs)/

      - id: ty-check
        name: ty type check
        entry: uv run ty check
        language: system
        types: [python]

      # Non-Python linters
      - id: shellcheck
        name: shellcheck
        entry: shellcheck
        language: system
        types: [shell]

      - id: yamllint
        name: yamllint
        entry: uv run yamllint -f parsable
        language: system
        types: [yaml]

      - id: check-json
        name: check json syntax
        entry: bash -c 'for f in "$@"; do jaq empty "$f"; done'
        language: system
        types: [json]

      - id: taplo-check
        name: taplo check
        entry: taplo check
        language: system
        types: [toml]

      - id: hadolint
        name: hadolint
        entry: hadolint --no-color
        language: system
        files: (Dockerfile|\.dockerfile)$

      - id: check-jsonschema-github-workflows
        name: validate github workflows
        entry: check-jsonschema --builtin-schema vendor.github-workflows
        language: system
        files: ^\.github/workflows/

      - id: actionlint
        name: actionlint
        entry: actionlint
        language: system
        files: ^\.github/workflows/

      - id: markdownlint
        name: markdownlint
        entry: markdownlint-cli2
        language: system
        types: [markdown]
        verbose: true  # Warns but does not block commits

      - id: jscpd
        name: jscpd duplicate detection
        entry: npx jscpd --config .jscpd.json
        language: system
        pass_filenames: false  # Cross-file detection
```

**Copy from Incide**: Use `incide/.pre-commit-config.yaml` as the source.
Remove Incide-specific exclude patterns and file paths. Keep all hook
definitions, execution order, and `repo: local` pattern.

### Phase 6: Project Skeleton

#### Step 6.1: Python project structure

```text
src/
  __init__.py           # Package marker
  app/
    __init__.py         # Application package marker
tests/
  __init__.py           # Test package marker
  conftest.py           # Minimal fixtures (see below)
  unit/
    __init__.py         # Unit test package marker
```

**Step 6.2: `tests/conftest.py`**

Minimal fixture file with example to show pattern:

```python
"""Shared test fixtures."""

import pytest
from pathlib import Path


@pytest.fixture
def tmp_data_dir(tmp_path: Path) -> Path:
    """Create a temporary data directory for test isolation."""
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    return data_dir
```

**Step 6.3: `Dockerfile`**

Framework-agnostic multi-stage Python Dockerfile. Uses best practices that
align with hadolint config (pinned base image, LABEL metadata, non-root
user):

```dockerfile
FROM python:3.11-slim AS base

LABEL maintainer="developer"
LABEL version="0.1.0"

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --shell /bin/bash --create-home app

WORKDIR /app

FROM base AS builder

COPY pyproject.toml uv.lock ./
RUN pip install --no-cache-dir uv \
    && uv sync --frozen --no-dev

FROM base AS runtime

COPY --from=builder /app/.venv /app/.venv
COPY src/ ./src/

ENV PATH="/app/.venv/bin:$PATH"
USER app

CMD ["python", "-m", "app"]
```

**Step 6.4: `docker-compose.yml`**

Minimal development stack:

```yaml
services:
  app:
    build: .
    volumes:
      - ./src:/app/src
    environment:
      - PYTHONUNBUFFERED=1
```

**Step 6.5: `.github/workflows/ci.yml`**

GitHub Actions CI pipeline that runs the same checks as pre-commit + tests:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - run: uv sync --all-extras --locked
      - run: uv run pre-commit run --all-files

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - run: uv sync --all-extras --locked
      - run: uv run pytest tests/
```

**Step 6.6: `.gitignore`**

Standard Python gitignore:

```text
# Python
__pycache__/
*.py[cod]
*.egg-info/
dist/
build/

# Virtual environments
.venv/

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
Thumbs.db

# Type checkers
.mypy_cache/

# Test/coverage
.pytest_cache/
htmlcov/
.coverage

# Docker
docker-compose.override.yml
```

**Step 6.7: `Makefile`**

Standard development targets:

<!-- markdownlint-disable MD010 -->
```makefile
.PHONY: install lint test format install-hooks clean

install:
	uv sync --all-extras

lint:
	uv run ruff check src tests
	uv run ruff format --check src tests

test:
	uv run pytest tests/

format:
	uv run ruff format src tests
	uv run ruff check --fix src tests

install-hooks:
	uv run pre-commit install

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type d -name .pytest_cache -exec rm -rf {} +
	rm -rf dist build *.egg-info
```
<!-- markdownlint-enable MD010 -->

### Phase 7: Documentation

**Step 7.1: Template `README.md`**

Comprehensive documentation covering:

1. **Quick Start** - How to use the template (GitHub "Use this template"),
   first-time setup commands (`uv sync`, `uv run pre-commit install`)

2. **What's Included** - File listing with purposes, organized by category
   (hooks, linter configs, project skeleton, CI)

3. **Hook System** - Overview of 3-phase architecture, link to
   docs/REFERENCE.md for full details

4. **Configuration** - How to edit `config.json`:
   - Enabling/disabling languages
   - Managing protected files
   - Adjusting security linter exclusions
   - Subprocess configuration (timeout, model selection patterns)
   - Phase toggles (auto_format, subprocess_delegation)
   - jscpd settings (scan dirs, thresholds)

5. **Linter Configuration** - Overview of each config file, what it controls,
   how to customize. Table mapping file to linter to purpose

6. **Pre-Commit Setup** - How to install and run pre-commit hooks

7. **Keeping Hooks and Pre-Commit in Sync** - Detailed manual sync guide:

   **When adding a new linter:**

   1. Install the linter tool (document install command)
   2. Create its config file in the project root (e.g., `.newlintrc`)
   3. Add the config file to `config.json` `protected_files` array
   4. Add the config file to `CLAUDE.md` protected files list
   5. Add a lint function in `multi_linter.sh` (e.g., `lint_newformat()`)
   6. Wire the function into the file-type case statement
   7. Add a hook entry in `.pre-commit-config.yaml` at the correct
      position in the execution order
   8. Test: `uv run pre-commit run newlint --all-files`
   9. Test: edit a file in Claude session, verify hook detects violations

   **When removing a linter:**

   1. Remove the hook entry from `.pre-commit-config.yaml`
   2. Remove the lint function from `multi_linter.sh`
   3. Remove from `config.json` `protected_files` array
   4. Remove from `CLAUDE.md` protected files list
   5. Delete the config file
   6. Uninstall the tool if no longer needed

   **When changing linter rules:**

   1. Edit the config file directly (e.g., add/remove rules in `.ruff.toml`)
   2. No changes needed to hooks or pre-commit (they read config at runtime)
   3. Run `uv run pre-commit run --all-files` to verify no new violations

   **Sync verification checklist:**

   - [ ] Every linter in `config.json` `protected_files` has a config file
   - [ ] Every config file has a matching pre-commit hook entry
   - [ ] Every pre-commit hook has a matching function in `multi_linter.sh`
   - [ ] `CLAUDE.md` protected files list matches `config.json`
   - [ ] `uv run pre-commit run --all-files` passes
   - [ ] `.claude/hooks/test_hook.sh --self-test` passes

8. **Settings Override** - How to use `.claude/settings.local.json` for
   per-developer overrides:
   - Create `.claude/settings.local.json` (not committed to git)
   - Override hook timeouts for slow machines
   - Disable hooks entirely during debugging (`"disableAllHooks": true`)
   - Add developer-specific permissions
   - Explain that Claude Code merges `settings.json` (committed) with
     `settings.local.json` (personal), with local taking precedence

9. **Establishing Your Quality Baseline** - Guidance for new projects:
   - First run will have zero violations (clean slate advantage)
   - As code grows, vulture false positives will surface - add entries
     to `vulture_whitelist.py`
   - jscpd duplicate detection starts clean - run
     `npx jscpd --config .jscpd.json` periodically to check baseline
   - bandit may flag patterns in test files - add to
     `[tool.bandit] exclude_dirs` in `pyproject.toml`
   - When inheriting an existing codebase: expect initial violation surge.
     Fix file-by-file as you edit (Boy Scout Rule), not all at once

10. **Dependencies** - Required and optional tool installations with
    exact install commands for macOS and Linux

11. **Vulture Whitelist** - What it is, how to populate it, common false
    positive patterns (pytest fixtures, CLI decorators, `__all__` exports,
    signal handlers)

12. **Troubleshooting** - Common issues and solutions:
    - Hook not firing: check settings.json paths, `claude --debug hooks`
    - Subprocess timeout: increase in config.json or `HOOK_SUBPROCESS_TIMEOUT`
    - False positives: add to whitelist/config, not to linter config
    - Pre-commit vs hook disagreement: run sync verification checklist
    - `jaq` not found: `brew install jaq`
    - `timeout` not found on macOS: `brew install coreutils`

**Step 7.2: Update `docs/REFERENCE.md`**

Copy from Incide with these changes:

- Remove all AIG-* issue references (Incide-specific)
- Remove Incide-specific file paths from examples
- Add section on `config.json` configuration
- Update protected file list references to point to config.json
- Keep all architectural documentation (3-phase, model selection, etc.)

## 6. What Changes from Incide (Behavioral Differences)

### In the Template (vs Incide)

<!-- markdownlint-disable MD013 -->
| Aspect | Incide | Template |
| ------ | ------ | -------- |
| Settings file | `settings.json` with ~90 permissions + absolute paths | `settings.json` with relative paths, empty permissions |
| Protected files | Hardcoded in 2 bash scripts | Read from `config.json`, fallback to defaults |
| Exclusion patterns | Hardcoded `scripts-dev/`, `evaluation/` | Convention defaults `tests/`, `docs/`, `scripts/`, `.venv/` |
| Language support | All enabled, no toggle | Configurable per-language in `config.json` |
| Phase toggles | Hardcoded (all phases always on) | `auto_format` and `subprocess_delegation` toggleable in `config.json` |
| Model selection | Hardcoded `readonly` constants in bash | Configurable patterns in `config.json`, with same defaults |
| Subprocess timeout | Hardcoded 300s, env var override | `config.json` default, env var still overrides |
| CLAUDE.md | ~1000 lines of project documentation | ~50 lines of hooks policy only (explicit protected file list) |
| jscpd scan dirs | `src/app`, `webapp`, `evaluation` | `src/`, `lib/` (configurable in `config.json`) |
| Linter configs | Incide-specific per-file-ignores | Clean defaults, no per-file-ignores |
| Vulture whitelist | Project-specific entries | Empty with comments |
| Pre-commit | 13 hooks with Incide paths | 13 hooks with generic paths |
| Settings paths | Absolute: `/Users/alex/.../incide/...` | Relative: `.claude/hooks/...` |
| Project skeleton | N/A (existing project) | Full starter: src/app/, tests/, Dockerfile, CI, Makefile |
<!-- markdownlint-enable MD013 -->

### Behavioral Changes in New Projects

1. **Clean slate**: No pre-existing violations. Hooks enforce from day one
2. **No Gemini API workarounds**: `.flake8` PYD001 exclusion for
   `data_models.py` is removed (Incide-specific constraint)
3. **Fewer false positives initially**: Vulture whitelist is empty, but will
   need population as project grows
4. **No project-specific exclusions**: Security linters use convention
   defaults. Projects with unusual directory layouts need to update config.json
5. **No accumulated permissions**: settings.json starts with empty allow list.
   Users build up permissions organically during Claude Code sessions

## 7. Dependencies (What Must Be Installed)

### Required (hook scripts fail without these)

| Tool | Purpose | Install |
| ---- | ------- | ------- |
| `jaq` | JSON parsing in hooks + config.json | `brew install jaq` |
| `ruff` | Python formatting + linting | `uv add --dev ruff` |
| `claude` | Claude Code CLI (subprocess delegation) | npm install |
| `uv` | Python package manager | `pip install uv` |

### Optional (gracefully skipped if missing)

<!-- markdownlint-disable MD013 -->
| Tool | Purpose | Install |
| ---- | ------- | ------- |
| `ty` | Python type checking | `uv add --dev ty` |
| `flake8` + `flake8-pydantic` | Pydantic model linting | `uv add --dev flake8 flake8-pydantic` |
| `flake8-async` | Async anti-patterns | `uv add --dev flake8-async` |
| `vulture` | Dead code detection | `uv add --dev vulture` |
| `bandit` | Security scanning | `uv add --dev bandit` |
| `shellcheck` | Shell script linting | `brew install shellcheck` |
| `shfmt` | Shell formatting | `brew install shfmt` |
| `yamllint` | YAML linting | `uv add --dev yamllint` |
| `hadolint` | Dockerfile linting | `brew install hadolint` |
| `taplo` | TOML formatting | `brew install taplo` |
| `markdownlint-cli2` | Markdown linting | `npm install -g markdownlint-cli2` |
| `jscpd` | Duplicate code detection | via `npx` (no install needed) |
| `actionlint` | GitHub Actions linting | `brew install actionlint` |
<!-- markdownlint-enable MD013 -->

## 8. Verification

After creating the template:

1. **Self-test**: Run `.claude/hooks/test_hook.sh --self-test` in the template
   repo. All tests should pass
2. **Clean project test**: Create a new repo from template, add a Python file
   with intentional violations, verify hooks detect and fix them
3. **Language toggle test**: Disable `python` in config.json, edit a `.py`
   file, verify no linting occurs
4. **Phase toggle test**: Set `phases.auto_format = false` in config.json,
   edit a file with formatting issues, verify Phase 1 is skipped but
   violations are still collected (Phase 2) and delegated (Phase 3)
5. **Protected file test**: Attempt to edit `.ruff.toml` in a Claude session,
   verify PreToolUse blocks it
6. **Stop hook test**: Modify a config file manually, end session, verify stop
   hook prompts for restoration
7. **Pre-commit test**: Run `uv run pre-commit run --all-files` on a clean
   repo, verify all 13 hooks pass
8. **CI test**: Push to GitHub, verify CI workflow runs lint + test jobs
   successfully
9. **Config fallback test**: Delete config.json, run hook, verify all linters
   still enabled (default behavior preserved)
10. **Dockerfile lint test**: Edit the template Dockerfile, verify hadolint
    runs via PostToolUse hook

## 9. Follow-Up Actions

1. **Linear Issue**: Enhance hook exit 2 messages to include actionable
   instructions (see `.claude/plans/linear-issue-hook-messages.md`)
2. **TypeScript support**: Add `lint_typescript()` function to
   `multi_linter.sh` when ready (eslint, prettier integration)
3. **V2: Generate pre-commit from config.json**: Build a script that reads
   `config.json` and generates `.pre-commit-config.yaml`, eliminating manual
   sync
