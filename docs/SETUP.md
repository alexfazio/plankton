# setup

The easiest way to set up Plankton is using the **Interactive Setup Wizard**.

## interactive setup

Execute this command in your project root:

```bash
uv run --no-project scripts/setup.py
```

The wizard will:

1. **Check Dependencies**: Verify `jaq`, `ruff`, and `uv` are installed.
2. **Detect Languages**: Scan your project for Python, TypeScript, Docker, etc.
3. **Configure Hooks**: Interactively enable/disable language enforcement.
4. **Finalize Environment**: Generate `.claude/hooks/config.json` and ensure hook scripts are executable.

## manual setup

If you prefer manual setup, follow these steps.

## core dependencies

jaq and ruff are required for all languages. uv is the
package runner that invokes most Python-based linting tools.

```bash
brew install jaq ruff uv
```

jaq is a Rust-based jq alternative used internally by the
hooks for JSON parsing. ruff handles Python formatting and
linting. uv runs optional Python tools (ty, bandit, vulture,
flake8) from the project's virtual environment.

After installing the core three, run:

```bash
uv sync --all-extras
```

This installs most Python linting tools from pyproject.toml
into your project's virtual environment.

## python

Required: ruff (formatting + linting), uv (tool runner).

ruff is the backbone of Python enforcement. It handles
formatting, import ordering, naming conventions, and 500+
lint rules. Most formatting issues are fixed silently in
Phase 1 auto-format; the rest are caught in Phase 2 linter
collection.

Optional tools (all installed via `uv sync --all-extras`):

- ty — Rust-based type checker from Astral
- vulture — dead code detection (min confidence 80%)
- bandit — security vulnerability scanning
- flake8 + flake8-pydantic — Pydantic model validation
- flake8-async — async anti-pattern detection (ASYNC100+)

Install everything at once:

```bash
uv sync --all-extras
```

Gotcha: bandit and security linters exclude tests/, docs/,
and .venv/ by default. You can customize these paths via the
`exclusions` array in `.claude/hooks/config.json`.

## typescript

TypeScript is disabled by default. Enable it in config.json:

```json
{ "languages": { "typescript": { "enabled": true } } }
```

Required when enabled: biome (formatting + linting). Biome
also handles JSON formatting when the TypeScript pipeline
is active.

Optional tools:

- oxlint — additional TS/JS linting rules (enable via
  `oxlint_tsgolint: true` in config)
- semgrep — security scanning for TS/JS, session-scoped
  and advisory by default (enable via `semgrep: true`)
- knip — dead code and unused export detection (enable
  via `knip: true`)
- jscpd — duplicate code detection that works across
  languages. Runs as a session-scoped scan after a
  configurable number of file edits (default 3). Scans
  src/ and lib/ directories with a configurable similarity
  threshold. Advisory by default — reports duplicates but
  does not block.

Install biome and oxlint from package.json:

```bash
npm install
```

Or if you prefer bun:

```bash
bun install
```

Sub-options you can set in the typescript config object:

- `js_runtime`: auto-detects node/bun/pnpm, or set it
  explicitly to lock in a specific runner.
- `biome_nursery`: "off", "warn", or "error" for biome's
  experimental rules (default "warn").
- `biome_unsafe_autofix`: enable risky auto-fixes that may
  change semantics (default false).
- `tsgo`: experimental tsgo type checking (default false).

## shell

Optional: shfmt (formatting) and shellcheck (linting).

```bash
brew install shfmt shellcheck
```

shfmt auto-formats shell scripts in Phase 1 with `shfmt -w`.
shellcheck runs all optional checks enabled, producing
SC-prefixed error and warning codes. Both tools are
gracefully skipped if not installed.

## yaml

Optional: yamllint.

```bash
brew install yamllint
```

yamllint enforces all 23 rules explicitly configured in the
`.yamllint` config file. No auto-formatting — violations are
reported and must be fixed in code.

## markdown

Optional: markdownlint-cli2.

```bash
npm install -g markdownlint-cli2
```

Enforces heading style, line length (80 chars), list
formatting, and fenced code block language tags. Some rules
support auto-fix in Phase 1. Config lives in
`.markdownlint-cli2.jsonc`.

## dockerfile

Optional: hadolint (version >= 2.12.0 recommended).

```bash
brew install hadolint
```

Enforces Dockerfile best practices at maximum strictness,
including both DL-prefixed and SC-prefixed rules. Gotcha:
hadolint < 2.12.0 triggers a version warning at startup but
continues working — you just lose `disable-ignore-pragma`
support.

## toml

Optional: taplo.

```bash
brew install taplo
```

Enforces TOML formatting via `taplo fmt` in Phase 1.
Config in `taplo.toml`.

## json

Handled by jaq (already installed as a core dependency) for
syntax validation. If TypeScript is enabled, biome also
formats JSON files automatically. No additional tools needed.

## disabling languages

If a tool is installed system-wide but you do not want
Plankton to lint that language, disable it explicitly in
`.claude/hooks/config.json`:

```json
{ "languages": { "shell": false, "dockerfile": false } }
```

Tools are gracefully skipped when not installed, so you only
need explicit disabling when a tool IS present on your
system and you want to suppress its output. Only override
what you need — missing keys use defaults.

## starter configs

The default behavior (no config.json) enables everything.
Create `.claude/hooks/config.json` with only the keys you
want to override.

**Minimal (formatting only)** — auto-format runs, but no
linter collection or subprocess fixes. Good for cautious
adoption on an existing codebase where you want formatting
but are not ready for lint enforcement:

```json
{
  "phases": {
    "subprocess_delegation": false
  }
}
```

**Python-only** — full Python enforcement with ruff, ty,
bandit, and the rest, but all other language pipelines
disabled. Good for pure-Python repos that do not want noise
from shell or YAML linters:

```json
{
  "languages": {
    "shell": false,
    "yaml": false,
    "dockerfile": false,
    "markdown": false,
    "toml": false
  }
}
```

**Full-stack Python + TypeScript** — both pipelines active
with security scanning and dead code detection turned on.
Good for web projects with a Python backend and a
TypeScript frontend:

```json
{
  "languages": {
    "typescript": {
      "enabled": true,
      "semgrep": true,
      "knip": true
    }
  }
}
```

Full configuration reference in
[docs/REFERENCE.md](REFERENCE.md).

## verify your setup

```bash
.claude/hooks/test_hook.sh --self-test
```

If all checks pass, you are ready. The self-test verifies
every installed tool is accessible and the hook pipeline
works end-to-end.
