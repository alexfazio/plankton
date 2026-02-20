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
- `biome.json` - Biome linter/formatter (TypeScript/JS/CSS)
- `.oxlintrc.json` - oxlint configuration
- `.semgrep.yml` - Semgrep security rules
- `knip.json` - Knip dead code detection
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
