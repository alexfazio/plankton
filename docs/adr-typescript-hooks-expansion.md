# ADR: TypeScript Hooks Expansion

**Status**: Draft (all questions resolved)
**Date**: 2026-02-14
**Author**: alex fazio + Claude Code clarification interview
**Related**: [Linear Document](https://linear.app/ad-main/document/typescript-equivalent-of-ruff-for-claude-code-hooks-366e4ee6d5f6) | ADAI-13

## Context and Problem Statement

The cc-hooks-portable-template currently provides automated code quality
enforcement for Python, Shell, JSON, TOML, Markdown, YAML, and Dockerfile
via a three-phase PostToolUse hook architecture (auto-format, collect JSON
violations, delegate to subprocess + verify). The goal is to expand this
system to cover TypeScript and the broader JavaScript/web ecosystem with
equivalent extreme opinionatedness.

The Linear document "TypeScript Equivalent of Ruff for Claude Code Hooks"
evaluated four Rust/Go-based tools: Biome, Oxlint+Oxfmt, Deno Lint, and
Rslint. This ADR captures the decisions and rationale from a detailed
clarification interview conducted on 2026-02-14.

## Decision Drivers

- **Ruff parity**: Match the Python hook's depth (6 linters in Phase 2)
- **Single-binary philosophy**: Prefer tools that combine multiple functions
  (like Ruff combines linting + formatting)
- **JSON output**: All Phase 2 tools must produce structured JSON parseable
  by jaq (existing hook dependency)
- **Sub-500ms Phase 1**: Auto-format must complete within the existing
  performance budget
- **Graceful degradation**: Optional tools skipped if not installed (existing
  pattern)
- **Configurability**: All tool toggles and behaviors controllable via
  config.json

## Decisions

### D1: Primary Linter and Formatter - Biome

**Decision**: Use Biome as the single primary linter+formatter for
TypeScript/JavaScript.

**Alternatives considered**:

| Tool | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Biome** | Single binary (format+lint), `--reporter=json`, two-tier auto-fix, type-aware v2 | 436 rules (fewer than Oxlint), experimental Vue/Svelte SFC support (v2.3+, limitations with framework-specific syntax) | **Selected** |
| **Oxlint + Oxfmt** | 660+ rules, 50-100x ESLint, Vue/Svelte/Astro plugins | Two binaries, Oxfmt alpha (Dec 2025), no built-in formatter stability | Rejected |
| **Biome + Oxlint hybrid** | Maximum rule coverage | Double-reporting of overlapping rules, increased complexity | Rejected |
| **Deno Lint** | Fast (~21ms/file), Rust-based | Only ~228 rules, no type-aware linting, awkward outside Deno | Rejected |
| **Rslint** | TypeScript-first, typescript-go powered | Experimental (Aug 2025), no stable release | Rejected |

**Rationale**:

1. **Single binary** matches Ruff's philosophy - one tool for format + lint
2. `biome check --write` combines Phase 1 (format + safe auto-fix) in one
   command
3. `--reporter=json` produces structured diagnostics directly parseable by
   jaq
4. Two-tier auto-fix (`--write` safe vs `--write --unsafe`) mirrors Ruff's
   `--fix` vs `--fix --unsafe-fixes`
5. Sub-100ms per file, comfortably within the 500ms Phase 1 budget
6. Running both Biome and Oxlint causes double-reporting of overlapping
   ESLint-equivalent rules with no benefit

### D2: Supplemental Tool Stack

**Decision**: Biome + Semgrep (optional) + jscpd

Where Python uses 5 specialized per-file tools (ruff + ty + flake8 + vulture
\+ bandit) plus jscpd, TypeScript uses one comprehensive single binary
(Biome: 436 rules for format + lint + partial type-awareness) plus
session-scoped advisory tools. Both achieve aggressive linting through
different architectures. The TS per-edit blocking time (~0.4s) is lower
than Python's (~0.8s) because Biome consolidates what Python splits across
multiple tools.

| Tool | Python Equivalent | Role | Scan Mode |
| --- | --- | --- | --- |
| **Biome** | ruff (format + lint) | Format, lint, import sorting | Per-file, blocking |
| **Semgrep** | bandit (note 1) | Security scanning | Session-scoped, advisory |
| **jscpd** | jscpd | Duplicate detection | Session-scoped, advisory |

**Note 1**: Unlike bandit (per-file blocking in Python hooks), Semgrep
runs session-scoped (after 3+ TS files modified) and is an optional
enhancement — runs if installed (`brew install semgrep` or
`uv pip install semgrep`), graceful skip if not.

**CI-recommended tools** (not in hooks by default):

| Tool | Python Equivalent | Role | Default |
| --- | --- | --- | --- |
| **Knip** | vulture | Dead code/unused exports | `knip: false` (opt-in via config) |
| **tsc/tsgo** | ty | Type checking | `tsc: false` (see D3) |

#### Semgrep (Security Scanner)

- **Why Semgrep**: Native TypeScript support, `--json` flag for structured
  output, open-source, 50+ framework support (Express, NestJS, React,
  Angular)
- **Alternatives rejected**: njsscan (no native TS), Snyk Code (commercial),
  eslint-plugin-security (requires ESLint)
- **Scan mode**: Session-scoped advisory (after 3+ TS files modified, scans
  all modified TS files in the session). Uses a curated local ruleset
  (`.semgrep.yml`, 5-10 rules) for performance. `--config auto` (2500+
  rules, 5-15s overhead from rule parsing) is deferred to CI only.
  See Q3 (resolved) for rationale
- **Timing**: 1-3s per file with local ruleset. `--config auto` takes 5-15s
  per invocation due to rule downloading and YAML parsing (~40% of total
  time), regardless of file count
- **Limitation**: Cross-file taint analysis (tracking user input to dangerous
  sink across files) won't work per-file - that's a CI concern
- **JSON output**: `semgrep --json --config .semgrep.yml <modified-files>`

#### Knip (Dead Code Detection)

- **Why Knip**: Most comprehensive TS dead code detector, detects unused
  exports/dependencies/devDependencies/config files, JSON reporter available
- **Alternatives rejected**: ts-prune (maintenance mode, recommends Knip),
  unimported (production-mode only, no test awareness), tsr (project ended)
- **Scan mode**: Session-scoped after 3+ TS files modified (like jscpd).
  Knip analyzes the whole project graph - per-file doesn't make sense
- **Output**: Advisory only via `[hook:advisory]`

### D3: Type Checking Strategy

**Decision**: Skip type checking in PostToolUse hooks. Defer to IDE
(real-time) and CI (enforcement).

**The problem**: Biome's type synthesizer is significantly more limited than
initially documented. The Linear document claimed "~75% of typescript-eslint
coverage" but this is misleading:

- The 75% figure refers to the detection rate of **one specific rule**
  (`noFloatingPromises`), not coverage of all typescript-eslint rules
- Biome currently has 15-16 rules in the Project domain, of which
  ~8 are type-aware (use type inference) and ~8 are project-level analysis
  (import resolution, dependency checking). Type-aware rules:
  `noFloatingPromises`, `noMisusedPromises`, `useAwaitThenable`,
  `noUnnecessaryConditions`, `useArraySortCompare`, `useConsistentEnumValueType`,
  `useExhaustiveSwitchCases`, `useFind`.
  Project-level rules: `noUnresolvedImports`, `noImportCycles`,
  `noDeprecatedImports`, `noPrivateImports`, `noUndeclaredDependencies`,
  `useImportExtensions`, `useJsonImportAttributes`, `useRegexpExec`
- typescript-eslint has ~86 type-aware rules
- Biome explicitly states it is "not trying to implement a full-fledged
  type system or a type checker like TypeScript"
- Biome's type synthesizer is designed as a linting aid, NOT a replacement
  for tsc

**Research findings** (2026-02-14):

| Option | Speed | Suitable for Hooks? | Notes |
| --- | --- | --- | --- |
| `tsc --noEmit` | 2-5s+ (project) | No - too slow | Baseline, project-wide only |
| `tsc --incremental` | 2-4.5s | No - marginal improvement | Cache helps but still slow |
| `tsgo` (typescript-go) | 0.5-1s (~10x faster) | Borderline | Best alternative, will become TS 7.0 |
| Biome type synthesizer | <100ms | Yes but incomplete | 15-16 Project domain rules (~8 type-aware) vs ~86 in typescript-eslint |
| Skip in hooks | N/A | N/A | Defer to IDE + CI |

**Why skip**: Type checking is fundamentally project-wide (requires the
full module graph to resolve imports and types). Even tsgo at 0.5-1s adds
blocking latency to every edit session. The IDE (VSCode + TS language
server) already provides real-time incremental type checking with
in-memory caching. CI enforces type safety at merge time. Adding type
checking to hooks duplicates both layers while degrading developer
experience.

**Three-layer type safety strategy**:

| Layer | Tool | When | Purpose |
| --- | --- | --- | --- |
| IDE | VSCode + TS Server | Real-time | Developer feedback |
| Hooks | Biome (lint + 15-16 Project domain rules, ~8 type-aware) | Post-edit | Fast formatting/linting |
| CI | `tsc --noEmit` or `tsgo` | Pre-merge | Enforcement gate |

**Escape hatch**: If a future project requires type checking in hooks,
the config supports it via `"tsc": true`. The recommended tool would be
`tsgo` (`npm install -g @typescript/native-preview`) which is 7-10x
faster than tsc and is the foundation for the official TypeScript 7.0 compiler.
This is documented but **disabled by default**.

**Config impact**: The `typescript.tsc` field defaults to `false` (changed
from the earlier proposed `true`).

### D4: File Scope and Extension Handling

**Decision**: All web files, with tiered handling by extension.

#### Full Pipeline (Biome + Semgrep)

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`
- `.css` (Biome only — Semgrep not applicable for CSS)

#### Semgrep Only (SFC files)

- `.vue`, `.svelte`, `.astro`

**Rationale**: Biome v2.3+ has experimental support for Vue SFCs,
Svelte, and Astro files (formatting and linting of script/style blocks),
but the support has known limitations with framework-specific syntax
(e.g., Svelte control-flow, Astro JSX-like syntax). Cross-language lint
rules are not yet supported. Until SFC support stabilizes, Semgrep
provides more reliable security scanning for these file types.

**CSS**: Biome's CSS support is stable (31 rules, ~21 ported from Stylelint,
formatting Prettier-compatible). CSS files are handled by Biome only (not
Semgrep). Auto-enabled when `typescript.enabled: true` — no separate config
flag needed.

**SCSS**: Deferred until Biome ships SCSS parser support (2026 roadmap #1
priority, work started). Users needing SCSS linting should use Stylelint
in their CI pipeline.

**Future**: When Biome adds SFC and SCSS support, the tiering can be
adjusted via config.

### D5: Framework Support

**Decision**: Support multiple frameworks (React, Vue, Svelte, Astro,
Next.js).

- **React/JSX-a11y**: Biome handles natively (built-in rules)
- **Vue/Svelte/Astro**: Semgrep-only for now. Biome lacks plugins for these
- **Framework-specific rules**: Biome's correctness and security groups
  cover common patterns. Framework-specific deep linting deferred to CI

### D6: JSON Handler Takeover

**Decision**: Biome takes over JSON formatting when TypeScript is enabled.

- When `typescript.enabled: true` in config.json, Biome formats JSON/JSONC
  files instead of jaq
- jaq remains as fallback for projects without Biome (when `typescript.enabled:
  false`)
- Biome's JSON formatting is Prettier-compatible
- Removes one code path from the hook for TS-enabled projects

### D7: Architecture - Same Script, Named Function

**Decision**: Add a `handle_typescript()` function to the existing
`multi_linter.sh`, called from a new case branch in the main dispatch.

**Rationale**:

1. `config.json` already has `"typescript": false` placeholder ready to flip
2. Three-phase pattern (format, collect, delegate) is identical
3. A new case branch (`*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.css)
   handle_typescript ;;`) follows the existing dispatch pattern
4. A separate script would require a second PostToolUse hook registration
5. Named function keeps the main case statement clean (the Python handler
   is already ~170 lines inline; adding ~150-200 more inline would push
   the case past 1100 lines)

**Estimated changes**:

| Location | Lines | Description |
| --- | --- | --- |
| `handle_typescript()` | ~150-200 | New function (Phase 1-3 for TS) |
| `is_typescript_enabled()` | ~10 | New config function (handles nested object) |
| Main `file_type` case | ~5 | New case branch dispatching to function |
| `spawn_fix_subprocess()` | ~5 | `format_cmd` case for typescript |
| `rerun_phase1()` | ~10 | Biome re-format after subprocess |
| `rerun_phase2()` | ~15 | Biome lint + Semgrep recheck |
| Config loading | ~20 | TS-specific settings parsing |
| **Total** | **~215-265** | Across main function + 5 satellite functions |

### D8: JS Runtime - Configurable

**Decision**: Add `js_runtime` field to config.json TypeScript section.

**Values**: `"auto"` (default), `"npm"`, `"pnpm"`, `"bun"`

**Auto-detect order** (when `"auto"`):

1. `./node_modules/.bin/biome` (project-local dependency)
2. `npx biome` (npm)
3. `pnpm exec biome` (pnpm)
4. `bunx biome` (bun)

This matches the existing `claude` command discovery pattern in the hook
(tries PATH, then ~/.local/bin, then ~/.npm-global/bin, etc.).

**Runtime caching**: The auto-detect result is cached after the first TS
file edit in the session (via a session-scoped variable or temp file at
`/tmp/.biome_path_${PPID}`). Subsequent PostToolUse invocations reuse the
cached path, avoiding 4-location detection on every Edit/Write. This is
critical since hooks fire on every edit operation.

**Canonical install** (documented but not enforced):
`npm install --save-dev @biomejs/biome`

### D9: Strictness - All Stable + Configurable Nursery

**Decision**: Enable all stable Biome rules. Nursery rules configurable
via `biome_nursery` field.

#### Nursery Rules Explained

Nursery rules are Biome's equivalent of Ruff's `--preview` flag:

- ~72 experimental rules out of 436+ total (~16%)
- **Not subject to semver** - breaking changes can occur without warning
- May have bugs or performance problems
- Can be removed entirely between versions
- Require explicit opt-in on stable Biome releases
- Promoted to stable groups after at least one minor version cycle

#### Configuration

| `biome_nursery` value | Behavior | Analogy |
| --- | --- | --- |
| `"off"` | Only stable rules | Conservative |
| `"warn"` (default) | Nursery reported as advisory, non-blocking | Like ruff --preview |
| `"error"` | Nursery treated as errors, trigger subprocess | Maximum opinionatedness |

#### Biome Config Mapping

```json
// biome_nursery: "off"
{ "linter": { "rules": { "all": true } } }

// biome_nursery: "warn"
{ "linter": { "rules": { "all": true, "nursery": "warn" } } }

// biome_nursery: "error"
{ "linter": { "rules": { "all": true, "nursery": "error" } } }
```

### D10: Auto-Fix Tiers - Configurable

**Decision**: Phase 1 auto-fix safety level is configurable via
`biome_unsafe_autofix` field.

| `biome_unsafe_autofix` | Phase 1 Command | Behavior |
| --- | --- | --- |
| `false` (default) | `biome check --write` | Safe fixes only (no semantic changes) |
| `true` | `biome check --write --unsafe` | All fixes including semantic changes |

This mirrors the Python hook's approach: Phase 1 runs `ruff check --fix`
(safe), while Phase 3 subprocess handles unsafe fixes. The configurable
option allows aggressive users to enable unsafe auto-fix in Phase 1.

### D11: Scan Scope by Tool

**Decision**: Mixed per-file and session-scoped scanning.

| Tool | Scope | Trigger | Blocking? |
| --- | --- | --- | --- |
| Biome (lint) | Per-file | Every Edit/Write on TS/JS | Yes (triggers subprocess) |
| Biome (format) | Per-file | Every Edit/Write on TS/JS | Silent (Phase 1) |
| Semgrep | Session-scoped | After 3+ TS files modified (scans all modified) | Advisory only |
| tsc/tsgo | Skipped in hooks | Deferred to IDE + CI | N/A (disabled by default) |
| Knip | Session-scoped | After 3+ TS files modified (if `knip: true`) | Advisory only (CI-recommended, off by default) |
| jscpd | Session-scoped | After 3+ files modified | Advisory only (existing) |

### D12: Model Selection - Shared Patterns

**Decision**: Shared `sonnet_patterns` and `opus_patterns` regex covering
both Python and TypeScript violations.

#### TypeScript Model Mapping

| Violation Type | Model | Examples |
| --- | --- | --- |
| Simple auto-fixable | Haiku | Unused vars, import ordering, formatting leftovers |
| Semantic / complexity | Sonnet | Biome complexity rules, type-aware rules (`noFloatingPromises`, `useAwaitThenable`), React hook deps (`useExhaustiveDependencies`) |
| Complex / high volume | Opus | Volume >5 violations of any type |

**Note**: Since type checking is deferred to IDE + CI (D3), there are no
tsc error codes in the model selection patterns. If `tsc: true` is enabled
as an escape hatch, tsc errors (TS2322, TS2345, etc.) would route to opus.

#### Updated Pattern Config

```json
"model_selection": {
  "sonnet_patterns": "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+|complexity|useExhaustiveDependencies|noFloatingPromises|useAwaitThenable",
  "opus_patterns": "unresolved-attribute|type-assertion",
  "volume_threshold": 5
}
```

Biome-specific type-aware rules route to sonnet. The opus tier is
reserved for complex architectural violations and high-volume batches.

### D13: Config Shape - TS Nested, Others Flat

**Decision**: TypeScript gets a nested config object. Other languages
remain as simple boolean toggles.

#### Updated config.json Structure

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
    "typescript": {
      "enabled": true,
      "js_runtime": "auto",
      "biome_nursery": "warn",
      "biome_unsafe_autofix": false,
      "tsc": false,
      "semgrep": true,
      "knip": false
    }
  }
}
```

**Rationale**: TypeScript requires more configuration than other languages
due to the multi-tool stack, JS runtime detection, and nursery rule
management. Other languages don't need this complexity - their tools are
simpler and have fewer knobs. Avoiding a breaking change to existing
config for Python/Shell/etc.

**Backward compatibility**: The hook must handle both `"typescript": false`
(old format) and `"typescript": { "enabled": true, ... }` (new format).

**Implementation**: A dedicated `is_typescript_enabled()` function (not
the generic `is_language_enabled()`) handles both formats:

```bash
is_typescript_enabled() {
  local ts_config
  ts_config=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript' 2>/dev/null)
  case "${ts_config}" in
    false|null) return 1 ;;          # boolean false or missing
    true) return 0 ;;                # simple boolean true (legacy)
    *) # nested object - check .enabled field
      local enabled
      enabled=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript.enabled // false' 2>/dev/null)
      [[ "${enabled}" != "false" ]]
      ;;
  esac
}
```

The generic `is_language_enabled()` continues to work for all other
languages (Python, Shell, etc.) which remain as simple boolean toggles.

### D14: Config File Protection

**Decision**: Add TypeScript tool configs to the protected files list.

**New protected files**:

- `biome.json` - Biome linter/formatter configuration
- `.semgrep.yml` - Semgrep curated security ruleset (local, 5-10 rules)
- `knip.json` or `knip.config.ts` - Knip dead code detection config

**Updated protected_files list**:

```json
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
  "ty.toml",
  "biome.json",
  ".semgrep.yml",
  "knip.json"
]
```

The `protect_linter_configs.sh` PreToolUse hook will be updated to
recognize these additional files.

### D15: Pre-commit Config - TypeScript Hooks

**Decision**: Add TypeScript hooks to `.pre-commit-config.yaml` using the
same patterns as existing Python hooks.

**Hook structure**: Two separate hooks, mirroring `ruff-format` +
`ruff-check`:

```yaml
# === PHASE 1a: TS FORMATTING ===
- id: biome-format
  name: biome (format)
  entry: bash -c 'command -v biome >/dev/null 2>&1 || exit 0; biome format --write "$@"' --
  language: system
  files: \.(jsx?|tsx?|cjs|cts|mjs|mts|css)$

# === PHASE 2a: TS LINTING ===
- id: biome-lint
  name: biome (lint)
  entry: bash -c 'command -v biome >/dev/null 2>&1 || exit 0; biome lint --write "$@"' --
  language: system
  files: \.(jsx?|tsx?|cjs|cts|mjs|mts|css)$
```

**Key design choices**:

| Choice | Decision | Rationale |
| --- | --- | --- |
| `language: system` | Consistent with all 12 existing hooks | Avoids version conflicts with project-local Biome |
| Graceful degradation | `command -v biome` check exits 0 if not found | When TS is disabled, Biome is not installed, hooks skip silently |
| Two hooks (not one) | `biome format` + `biome lint` | Phase 1/Phase 2 clarity; can disable independently |
| Insertion point | After Python (Phase 1a/2a), before Shell (Phase 4) | Groups by language, matches multi_linter.sh organization |
| No test exclusions | Biome lints all files including tests | Matches ruff (no excludes). Use biome.json `overrides` for per-project exceptions |
| No SFC files | `.vue`, `.svelte`, `.astro` excluded from pattern | Biome can't parse SFCs; Semgrep is CC-hooks-only |

**Pre-commit vs CC hooks split** (follows Python model):

| Tool | Pre-commit? | CC Hooks? | Rationale |
| --- | --- | --- | --- |
| Biome (format) | Yes | Yes (Phase 1) | Fast, deterministic |
| Biome (lint) | Yes | Yes (Phase 2) | Fast, deterministic |
| Semgrep | No | Yes (session-scoped advisory) | 5-15s with --config auto; 1-3s/file with local ruleset |
| Knip | No | Yes (session-scoped) | Project-scoped, 10-60s |
| tsc/tsgo | No | No (deferred) | IDE + CI only |
| jscpd | Yes (existing) | Yes (existing) | Already in pre-commit |

**INTENTIONAL EXCLUSIONS update**: The comment section at the bottom of
`.pre-commit-config.yaml` will be updated:

```yaml
# === INTENTIONAL EXCLUSIONS ===
# The following tools run in CC hooks and/or CI but NOT in pre-commit:
# - vulture: High false positive rate, advisory-only (needs whitelist)
# - bandit: Security scanning belongs in CI gates, not commit-time
# - flake8-pydantic: Niche Pydantic feedback, real-time via CC hooks
# - semgrep: Session-scoped security scanning, 5-15s with --config auto
# - knip: Project-scoped dead code analysis, 10-60s too slow for commit
# - tsc/tsgo: Type checking deferred to IDE (real-time) and CI (gate)
```

**JSON formatting in pre-commit**: Stays jaq. The D6 Biome JSON takeover
applies only to CC hooks' Phase 1 auto-format. The pre-commit JSON hook
(`jaq empty`) is syntax validation, not formatting.

### D16: Template Structure - Opt-in TypeScript Layer

**Decision**: Keep the template Python-first. TypeScript support is an
opt-in layer activated via setup process.

**Rationale**: The template's core value is the hooks system, not the
project scaffolding. Shipping both Python and TypeScript files would
confuse users. The opt-in approach keeps the initial template clean
while making TS activation straightforward.

**Always-present (harmless if TS unused)**:

- `.gitignore` with TS patterns pre-included (see below)
- `.pre-commit-config.yaml` with Biome hooks (skip gracefully if not
  installed)
- `config.json` with `"typescript": false` placeholder (existing)

**Created by init process** (`make init-typescript` or documented steps):

- `biome.json` - Biome configuration (see Q2)
- `package.json` - with `@biomejs/biome` as devDependency
- `tsconfig.json` - TypeScript compiler configuration
- Updates `config.json` to set `typescript.enabled: true`

**.gitignore TS patterns** (pre-included):

```gitignore
# TypeScript / JavaScript
dist/
.next/
.turbo/
*.tsbuildinfo
coverage/
.biome/
```

These patterns are harmless when no TS files exist and prevent
accidental commits if TS is activated later.

**What the init process does NOT change**:

- Python scaffolding (`src/__init__.py`, `tests/`, `pyproject.toml`)
  remains untouched
- Hook scripts are already TS-aware (graceful degradation)
- Pre-commit hooks are already present (skip when Biome not installed)

### D17: jscpd Scope Extension

**Decision**: Extend jscpd configuration to cover TypeScript and
JavaScript files.

**Changes to `.jscpd.json`**:

```json
{
  "format": ["python", "bash", "yaml", "typescript", "javascript",
             "tsx", "jsx", "css"],
  "path": ["src/"]
}
```

**Changes to `.pre-commit-config.yaml`** (jscpd hook):

```yaml
- id: jscpd
  name: jscpd (duplicates)
  entry: npx jscpd --config .jscpd.json --threshold 5
  language: system
  files: \.(py|sh|yaml|yml|ts|tsx|js|jsx|mjs|cjs|css)$
  pass_filenames: false
  stages: [pre-commit]
  verbose: true
```

**Rationale**: jscpd already runs in both pre-commit and CC hooks. TS/JS
files should be included in duplicate detection just like Python and
Shell. The `src/` scan directory is shared by both Python and TypeScript
files in the template structure.

## Phase Mapping: Python to TypeScript

| Phase | Python | TypeScript |
| --- | --- | --- |
| **Phase 1: Auto-Format** | `ruff format` + `ruff check --fix` | `biome check --write` (or `--write --unsafe` if configured) |
| **Phase 2a: Primary lint** | `ruff check --preview --output-format=json` | `biome lint --reporter=json` |
| **Phase 2b: Type checking** | `ty check --output-format gitlab` | Skipped (deferred to IDE + CI). Biome's ~8 type-aware rules (out of 15-16 Project domain rules) provide baseline coverage |
| **Phase 2c: Duplicate detection** | `jscpd` (session-scoped) | `jscpd` (session-scoped, existing) |
| **Phase 2d: Domain-specific** | `flake8 --select=PYD` (Pydantic) | N/A (no TS equivalent) |
| **Phase 2e: Dead code** | `vulture` | `knip` (CI-recommended, opt-in via `knip: true` in config) |
| **Phase 2f: Security** | `bandit` | `semgrep --json --config .semgrep.yml` (session-scoped, advisory) |
| **CSS: Format + Lint** | N/A | `biome check --write` + `biome lint --reporter=json` (same as TS/JS) |
| **Phase 3: Delegate** | `claude -p` subprocess | `claude -p` subprocess (same mechanism) |

## Performance Budget

Hooks are **synchronous and blocking** — the main agent cannot proceed
until the hook completes (see README "Hook Execution Model"). Every tool
invocation directly impacts developer experience. The TypeScript handler
must stay within the same performance envelope as the Python handler.

### Per-Edit Blocking Time Comparison

| Phase | Python | TypeScript | Notes |
| --- | --- | --- | --- |
| **Phase 1: Auto-Format** | ~300ms (ruff format + ruff check --fix) | ~100ms (`biome check --write`) | TS is faster; single combined command |
| **Phase 2: Blocking** | ~500ms (ruff + ty + flake8 + vulture + bandit) | ~100ms (biome lint only) | Advisory tools are session-scoped, not per-edit |
| **Phase 2: Session-scoped** | jscpd (~2-5s, once/session) | jscpd + Semgrep (3-9s) + Knip (10-60s) | One-time blocks, not per-edit |
| **Phase 3: Subprocess** | ~5-25s (model-dependent) | ~5-25s (same mechanism) | Identical subprocess model |
| **Verify** | ~500ms (rerun Phase 1 + 2) | ~200ms (biome only, skip advisory) | TS skips Semgrep in verify |
| **Total per-edit blocking** | **~0.8s + subprocess** | **~0.4s + subprocess** | TS slightly faster per-edit |

### Key Performance Decisions

- **`biome check --write`** (CC hooks) vs **`biome format` + `biome lint`**
  (pre-commit): CC hooks use a single combined command for speed (~100ms).
  Pre-commit uses two separate commands for independent disable control.
  The pre-commit overhead is acceptable since it runs at commit-time, not
  per-edit
- **Verification skips advisory**: `rerun_phase2()` for TypeScript only
  re-runs Biome lint (~100ms), not Semgrep. Advisory tools don't affect
  the pass/fail decision, so re-running them during verification adds
  unnecessary latency
- **Phase 1 workload reduction**: Biome's combined format+lint auto-fix
  is estimated to reduce subprocess triggers by 50-70% (vs Python's
  40-50%), because `biome check --write` handles more rule categories
  in auto-fix mode than ruff's safe-fix subset
- **Subprocess timeout**: 300s (5 minutes) is adequate for TypeScript
  violations. The subprocess model is identical to Python (same
  `claude -p` mechanism, same 10-turn limit). TS violations (React
  hook dependencies, async patterns) are comparable in complexity to
  Python violations (type errors, complexity refactoring). Monitor
  post-implementation to validate this assumption

### Session-Scoped Advisory Timing

| Tool | Trigger | Scope | Expected Time | Pattern |
| --- | --- | --- | --- | --- |
| jscpd | 3+ files modified | Full `src/` scan | ~2-5s | Existing, unchanged |
| Semgrep | 3+ TS files modified | All modified TS files | ~3-9s (1-3s/file) | New, uses local ruleset |
| Knip | 3+ TS files modified (if `knip: true`) | Full project graph | ~10-60s | CI-recommended, off by default in hooks |

Session-scoped tools block once per session at the threshold trigger.
The one-time block is acceptable since it amortizes advisory value
across all subsequent edits in the session.

## Research Findings

### Biome Type-Aware Linting (Fact-Check)

The Linear document's claim of "~75% of typescript-eslint coverage" for
Biome's type synthesizer is **misleading**:

- The 75% figure is the detection rate of **one specific rule**
  (`noFloatingPromises`), not coverage of all typescript-eslint rules
- Biome has 15-16 Project domain rules (of which ~8 are type-aware) vs ~86 in typescript-eslint
- Biome's "Biotype" type synthesizer is a "rudimentary type synthesiser"
  that reimplements a minimal subset of TypeScript's type checker in Rust
- Biome explicitly states users should continue using tsc for type safety
- The type synthesizer is designed to power specific lint rules, not to
  replace type checking

**Source**: Biome v2 announcement, GitHub issue #3187, arendjr blog post

### Nursery Rules Stability

- ~72 nursery rules out of 436+ total (~16%)
- Not subject to semantic versioning
- Promotion requires at least one full minor version cycle
- Promotion criteria: bug severity, bug frequency, feature completeness
- Can be enabled selectively per-rule or as a group
- Recommended for testing/early adoption, not production-critical code

**Source**: Biome documentation, GitHub discussions #7131

### Biome + Oxlint Coexistence

- **Not recommended** as dual primary linters
- Both reimplement ESLint rules, causing double-reporting
- Different type-aware strategies: Biome = custom Rust synthesizer,
  Oxlint = tsgolint (Go wrapper around typescript-go)
- Community consensus: choose one, not both

**Source**: oxc-project/oxc discussions #1709, biomejs/biome discussions #1281

### Security Scanner Comparison

| Tool | TS Support | JSON Output | Open Source | Per-File |
| --- | --- | --- | --- | --- |
| **Semgrep** | Native | `--json` | Yes | Yes |
| Snyk Code | Yes | Yes | Commercial | Yes |
| njsscan | Transpile first | `--json` | Yes | Yes |

**Winner**: Semgrep - native TS, JSON output, open-source, 50+ framework
support.

### Dead Code Detector Comparison

| Tool | Status | Scope | JSON Output |
| --- | --- | --- | --- |
| **Knip** | Active | Full project graph | Yes |
| ts-prune | Maintenance mode | Exports only | Limited |
| unimported | Active | Production only | Limited |
| tsr | Ended | Full project | N/A |

**Winner**: Knip - most comprehensive, actively maintained, industry
recommendation (Effective TypeScript).

## Open Questions

### ~~Q1: Type Checking Strategy~~ (RESOLVED)

**Resolution**: Skip type checking in hooks. Defer to IDE (real-time) and
CI (enforcement). See D3 for full rationale. Config field `tsc` defaults
to `false`. Escape hatch: enable `tsc: true` with tsgo for projects that
require it.

### ~~Q2: Biome.json Template Contents~~ (RESOLVED)

**Resolution**: Ship a static `biome.json` in the template. Users edit it
directly, like `.ruff.toml`. No dynamic generation.

**Template contents**:

```json
{
  "$schema": "https://biomejs.dev/schemas/2.0.0/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "files": {
    "ignoreUnknown": true
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 80,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": {
      "all": true,
      "nursery": "warn"
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "double",
      "trailingCommas": "all",
      "semicolons": "always"
    }
  },
  "assist": {
    "enabled": true,
    "actions": {
      "source": {
        "organizeImports": "on"
      }
    }
  }
}
```

**Key design choices**:

| Setting | Value | Rationale |
| --- | --- | --- |
| `indentStyle` | `"space"` | JS/TS ecosystem standard (vs tabs default) |
| `indentWidth` | `2` | JS/TS convention (not Python's 4) |
| `lineWidth` | `80` | Standard across ecosystems |
| `lineEnding` | `"lf"` | Unix standard, matches `.gitattributes` |
| `quoteStyle` | `"double"` | Biome/Prettier default |
| `trailingCommas` | `"all"` | Reduces git diffs |
| `semicolons` | `"always"` | Explicit, safer |
| `rules.all` | `true` | Maximum opinionatedness (like Ruff `select = ["ALL"]`) |
| `rules.nursery` | `"warn"` | D9 default — advisory, non-blocking |
| `organizeImports` | `"on"` | Auto-sort imports on format |
| `vcs.useIgnoreFile` | `true` | Respects `.gitignore` patterns |
| `files.ignoreUnknown` | `true` | Skip files Biome doesn't understand |

**Why static** (not dynamic):

- Biome's ecosystem is built around static `biome.json` — no dynamic
  generation mechanism exists
- `.ruff.toml` on the Python side is also static — consistency
- Simpler to debug: what's in `biome.json` is what Biome uses
- Users leverage Biome's built-in `extends` for project-specific overrides

**Nursery sync with config.json**: The `biome.json` ships with
`"nursery": "warn"` matching the D9 default. If the user changes
`biome_nursery` in `config.json`, they should also update `biome.json`
to match. The config.json field documents intent; biome.json controls
behavior.

**Known noisy rules** (no overrides in template — users customize
per-project):

- `style/noMagicNumbers` — common in test files with hardcoded values
- `style/useNamingConvention` — may conflict with React component naming
  or Vue composable patterns (`useXxx`)
- `style/noShoutyConstants` — opinionated about `UPPER_CASE` constants
- `correctness/useExhaustiveDependencies` — React hook false positives
  (per-line suppression available via `// biome-ignore`)

These are left enabled for maximum opinionatedness. Projects that need
exceptions should use biome.json `overrides` or inline suppressions.

### ~~Q3: Semgrep Ruleset~~ (RESOLVED)

**Resolution**: CC hooks use a curated local ruleset (`.semgrep.yml`,
5-10 rules). `--config auto` is deferred to CI only.

**Performance rationale**: `--config auto` downloads 2500+ rules from the
Semgrep registry, and rule YAML parsing accounts for ~40% of total
execution time (5-15s per invocation). A local ruleset with 5-10 curated
security rules reduces this to 1-3s per file, making session-scoped
execution practical (3-9s total when scanning 3+ modified files).

**Ruleset strategy**:

| Context | Config | Rules | Timing |
| --- | --- | --- | --- |
| CC hooks (session-scoped) | `--config .semgrep.yml` | 5-10 curated | 1-3s/file |
| CI pipeline | `--config auto` | 2500+ community | 5-15s (acceptable) |
| Pre-commit | Not included | N/A | N/A |

**Local ruleset focus** (security-critical patterns for TS/JS):

- `eval()` / `new Function()` — code injection
- `innerHTML` / `dangerouslySetInnerHTML` — XSS
- Hardcoded secrets / API keys
- SQL injection (string concatenation in queries)
- Command injection (`child_process.exec` with user input)
- Path traversal (`fs.readFile` with unsanitized paths)
- JWT misuse (hardcoded secrets, missing verification)

The exact `.semgrep.yml` contents will be defined during implementation,
drawing from Semgrep's `p/typescript` and `p/security-audit` registry
rulesets. The local file is version-controlled and protected via the
PreToolUse hook (D14).

**Original options evaluated**:

| Ruleset | Coverage | False Positives | Timing | Verdict |
| --- | --- | --- | --- | --- |
| `--config auto` | Broadest (community) | Higher | 5-15s | CI only |
| `--config p/typescript` | TS-specific | Medium | ~3-5s | Middle ground |
| `--config p/security-audit` | Security-focused | Lower | ~2-4s | Good |
| Custom `.semgrep.yml` | Curated | Lowest | 1-3s/file | **Selected** |

### ~~Q4: CSS/SCSS Handling~~ (RESOLVED)

**Resolution**: CSS files handled via Biome. SCSS deferred until Biome
ships SCSS parser support. No Stylelint dependency.

**Current state** (February 2026):

- Biome CSS support is **stable** (31 rules, ~21 ported from Stylelint)
- CSS formatting is Prettier-compatible (97%)
- SCSS support is **in development** (Biome's 2026 roadmap #1 priority,
  work started)
- CSS Modules have known issues (`:global()` flagged as unknown
  pseudo-class)

**Implementation**:

- `.css` files added to the Biome handler in D4 (Full Pipeline)
- Auto-enabled when `typescript.enabled: true` — no separate config flag
- Same pipeline as TS/JS: `biome check --write` (Phase 1) + `biome lint
  --reporter=json` (Phase 2)
- Performance: sub-100ms per file (same as TS/JS)
- Pre-commit: `.css` added to biome-format and biome-lint hook patterns

**Why Biome only (no Stylelint)**:

1. **D1 consistency**: Single-binary philosophy — adding Stylelint would
   introduce a second linter, contradicting the ADR's architectural DNA
2. **31 rules cover high-value cases**: duplicate properties, empty blocks,
   unknown properties/pseudo-classes, invalid grid areas, invalid gradients
3. **No new dependency**: Biome already handles CSS — no install, no
   config file, no protected file addition
4. **SCSS gap is temporary**: Biome's SCSS work is underway; adding
   Stylelint now creates throwaway code

**SCSS deferral**:

- Users needing SCSS linting should use Stylelint in their CI pipeline
- When Biome ships SCSS, add `.scss` to the handler pattern — zero new
  code paths needed
- Monitor: Biome blog/releases and GitHub discussion #3441

**Alternatives rejected**:

| Option | Why Rejected |
| --- | --- |
| Stylelint for CSS+SCSS | Extra dependency, config file, handler code path — contradicts single-binary philosophy |
| Biome CSS + Stylelint SCSS | Hybrid approach creates throwaway code when Biome ships SCSS |
| Skip CSS entirely | CSS is a natural companion to web projects; leaving it unlinted creates a coverage gap |

### ~~Q5: Install and Dependency Documentation~~ (RESOLVED)

**Resolution**: Makefile target (`make init-typescript`) for TypeScript
activation. Dependencies documented with all package managers. Manual
`npm install` step.

**Dependency matrix**:

| Tool | Install Method | Required? | Purpose |
| --- | --- | --- | --- |
| Biome | `npm i -D @biomejs/biome` | Required | Lint + format (TS/JS/CSS/JSON) |
| Semgrep | `brew install semgrep` or `pip install semgrep` | Optional (runs if installed) | Security scanning |
| Knip | `npm i -D knip` | Optional (CI-recommended) | Dead code detection (off in hooks by default) |
| tsgo | `npm i -g @typescript/native-preview` | Optional | Type checking (escape hatch) |
| jscpd | `npx jscpd` (no install) | Optional | Duplicate detection (existing) |
| jaq | `brew install jaq` | Required | JSON parsing (existing) |

**Init process**: `make init-typescript`

| Step | Action | Existing File Handling |
| --- | --- | --- |
| 1. Create `biome.json` | Copy template (see Q2) | Skip if exists |
| 2. Create `tsconfig.json` | Create minimal config | Skip if exists |
| 3. Create/update `package.json` | Add `@biomejs/biome` to devDependencies | If exists: merge via `jaq`; if not: create minimal |
| 4. Update `config.json` | Set `typescript.enabled: true` | Always update |
| 5. Print next steps | Display install commands | N/A |

**Output message** (printed after init):

```text
TypeScript support initialized.

Next steps:
  npm install          (or: pnpm install / bun install)

Optional enhancements:
  brew install semgrep   (security scanning)
  pip install semgrep    (alternative install method)
  npm i -D knip          (dead code detection, CI-recommended)
```

**Key design choices**:

| Choice | Decision | Rationale |
| --- | --- | --- |
| Makefile target | `make init-typescript` | Discoverable, self-documenting, consistent with Make conventions |
| Manual `npm install` | Not run automatically | User controls when dependencies download; avoids surprises |
| Existing `package.json` | Merge devDependencies via `jaq` | Preserves existing deps and formatting |
| Idempotent | Skip existing config files | Running twice is safe; won't overwrite customized configs |
| Pre-commit unchanged | No `.pre-commit-config.yaml` modifications | Hooks use graceful degradation per D15 |

**Documentation approach** (README):

- Required dependencies listed at top with all three package managers
- Optional dependencies in a separate section with purpose and benefits
  explained
- Semgrep: document both `brew install semgrep` (macOS) and
  `pip install semgrep` (universal) — note that Homebrew does not support
  multiple Semgrep versions
- Hook auto-detects missing tools and outputs `[hook:warning]` with
  install instructions (existing pattern from Python handler)

**Minimal `package.json`** (created by init when none exists):

```json
{
  "private": true,
  "devDependencies": {
    "@biomejs/biome": "^2.0.0"
  }
}
```

**Minimal `tsconfig.json`** (created by init when none exists):

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
```

### ~~Q6: Testing Strategy~~ (RESOLVED)

**Resolution**: Two-tier testing architecture using the existing custom
`test_hook.sh` framework. Unit tests for routine validation, manual E2E
tests via `claude -p --debug` for full-chain verification.

**Context**: The existing `test_hook.sh --self-test` runs 14 automated
tests covering Dockerfile patterns, Python, Shell, JSON, YAML, and model
selection. TypeScript support needs equivalent test coverage. Background
research confirmed: (1) no official Anthropic test framework or
`--dry-run` flag exists for hooks; (2) hooks DO fire in `claude -p` pipe
mode; (3) the project's JSON-piping approach is effectively the state of
the art for hook testing.

#### Two-Tier Testing Architecture

**Tier 1: Unit Tests** (fast, deterministic, free)

Extend `test_hook.sh --self-test` with TypeScript test cases. All unit
tests use `HOOK_SKIP_SUBPROCESS=1` for deterministic exit codes and
`HOOK_DEBUG_MODEL=1` for model selection verification. Tests require
Biome installed (consistent with existing tool dependency approach --
tests skip gracefully if Biome is missing, matching the hadolint pattern).

| # | Test | Input | Expected | Env Vars |
| --- | --- | --- | --- | --- |
| 1 | Clean TS file | Valid `const x: number = 1` | Exit 0 | `HOOK_SKIP_SUBPROCESS=1` |
| 2 | TS with unused var | `const unused = 1` | Exit 2 (violations reported) | `HOOK_SKIP_SUBPROCESS=1` |
| 3 | JS file handling | `.js` file with violations | Exit 2 (Biome lints) | `HOOK_SKIP_SUBPROCESS=1` |
| 4 | JSX file handling | React component with a11y issue | Exit 2 (Biome reports) | `HOOK_SKIP_SUBPROCESS=1` |
| 5 | Config: TS disabled | TS file edited with `typescript: false` | Exit 0 (skip) | `HOOK_SKIP_SUBPROCESS=1` |
| 6 | Biome not installed | TS file edited (Biome removed from PATH) | Exit 0 + warning | `HOOK_SKIP_SUBPROCESS=1` |
| 7 | Model: simple (unused var) | `const unused = 1` | `[hook:model] haiku` | `HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1` |
| 8 | Model: complex (type-aware) | `useExhaustiveDependencies` violation | `[hook:model] sonnet` | `HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1` |
| 9 | Model: volume (>5) | 6+ Biome violations | `[hook:model] opus` | `HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1` |
| 10 | JSON via Biome | `.json` file (TS enabled) | Biome formats (not jaq) | `HOOK_SKIP_SUBPROCESS=1` |
| 11 | Config: nursery=warn | Nursery rule triggered | `[hook:advisory]` output | `HOOK_SKIP_SUBPROCESS=1` |
| 12 | Protected config: biome.json | Attempt to edit `biome.json` | `{"decision": "block"}` | N/A (PreToolUse) |
| 13 | Pre-commit: Biome format | `pre-commit run biome-format` | Pass (or skip if no Biome) | N/A |
| 14 | Pre-commit: graceful skip | Biome not in PATH | Exit 0 (skip, not fail) | N/A |
| 15 | CSS: clean file | Valid `.css` with correct properties | Exit 0 | `HOOK_SKIP_SUBPROCESS=1` |
| 16 | CSS: violations | `.css` with duplicate properties | Exit 2 (violations reported) | `HOOK_SKIP_SUBPROCESS=1` |

**Test helpers**: Uses existing `test_temp_file()`, `test_existing_file()`,
`test_output_format()`, and `test_model_selection()` helpers from
`test_hook.sh`. TypeScript tests follow identical patterns to the existing
Python and Dockerfile tests.

**Tool dependencies**: Tests require Biome installed. If Biome is not
found, TS-specific tests skip with a warning (not a failure), matching the
existing graceful degradation pattern. Semgrep and Knip tests are skipped
if those tools are not installed (advisory tools are optional).

**Tier 2: E2E Validation** (manual, non-deterministic, API cost)

Three `claude -p` commands for full-chain validation. Run manually during
final implementation review, NOT in CI (API cost, ~25s per test,
non-deterministic model output).

```bash
# E2E Test 1: TS violations → hook fires → subprocess fixes
# Expected: PostToolUse:Write hook fires, exit 0 (violations fixed)
echo 'const unused = 1; const also_unused = 2;' > /tmp/e2e_test.ts
claude -p "Edit /tmp/e2e_test.ts to add a function that uses these variables" \
  --allowedTools "Read,Edit,Write" \
  --output-format json \
  --debug 2>&1 | grep -E 'PostToolUse:(Edit|Write) hook'

# E2E Test 2: TS disabled in config → hook skips
# Expected: No PostToolUse hook output for TS files
# (Temporarily set typescript.enabled: false in config.json)
claude -p "Write a TypeScript file at /tmp/e2e_disabled.ts with content 'const x = 1'" \
  --allowedTools "Write" \
  --debug 2>&1 | grep -c 'biome'  # Should be 0

# E2E Test 3: Biome not installed → graceful degradation
# Expected: hook:warning about missing tool, no crash
# (Temporarily rename/remove biome from PATH)
claude -p "Write a TypeScript file at /tmp/e2e_nobiome.ts with content 'const x = 1'" \
  --allowedTools "Write" \
  --debug 2>&1 | grep 'hook:warning'
```

**Key flags for E2E testing**:

| Flag | Purpose |
| --- | --- |
| `--allowedTools "Read,Edit,Write"` | Auto-approve tools (no prompts) |
| `--output-format json` | Structured output with session metadata |
| `--debug` | Shows hook execution: matched hooks, exit codes, output |
| `--verbose` | Shows hook progress in transcript |

#### Implementation Testing Workflow (Regression Gate)

During TS handler implementation, run the regression gate before each
commit:

```bash
# 1. Run existing test suite (all 14 tests must pass)
.claude/hooks/test_hook.sh --self-test

# 2. After adding TS tests, run expanded suite
.claude/hooks/test_hook.sh --self-test
# Expected: 14 existing + 16 new TS tests = 30 total, all pass

# 3. Final validation (once, before PR)
# Run the 3 E2E commands above
```

This ensures existing Python/Shell/YAML/JSON/Dockerfile/Markdown/TOML
handlers are not broken by the TS handler addition. The TS handler is
additive (new case branch in the dispatch at line ~493 of
`multi_linter.sh`), so existing handlers should not be affected, but the
regression gate provides confidence.

#### Sub-Decision Resolutions

| Sub-Decision | Resolution | Rationale |
| --- | --- | --- |
| Extend test_hook.sh or new file? | Extend `test_hook.sh` | Single test suite, consistent patterns, shared helpers |
| Test fixtures | Generate temp files | Consistent with existing tests (all use `${temp_dir}`) |
| Semgrep without Semgrep? | Skip with warning | Optional tool; graceful degradation pattern |
| HOOK_SKIP_SUBPROCESS=1? | Yes, for all unit tests | Deterministic exit codes; subprocess tested via E2E |

### ~~Q7: Linear Document Corrections~~ (RESOLVED)

**Resolution**: The Linear document "TypeScript Equivalent of Ruff for
Claude Code Hooks" has been updated (2026-02-14) to correct the
type-aware coverage claims:

**Changes applied**:

1. **Comparison matrix**: Type-aware rules row updated from "Yes (v2
   built-in synthesizer)" to "Yes (v2 built-in synthesizer, ~6 rules)"
2. **Recommendation point 6**: Expanded to list all 6 type-aware rules
   explicitly and added clarification that the ~75% figure refers to
   one rule's detection rate, not overall typescript-eslint coverage
3. **Biome detailed table**: Type checking row changed from "Yes (v2) |
   Built-in type synthesizer, ~75% of typescript-eslint coverage" to
   "Limited (v2) | Built-in type synthesizer with ~6 rules. NOT a
   replacement for tsc"
4. **Sources section**: Added Biome v2 announcement, type inference blog,
   and 2026 roadmap links

## Consequences

### Positive

- TypeScript files get the same aggressive lint-on-edit treatment as Python
- Single-binary Biome matches Ruff's developer experience
- Security scanning (Semgrep) provides immediate feedback on vulnerabilities
- Dead code detection (Knip) prevents unused export accumulation
- Configurable strictness allows teams to tune opinionatedness
- Protected config files prevent accidental rule weakening
- Pre-commit Biome hooks provide commit-time enforcement matching Python
- Opt-in TS layer keeps the template clean for Python-only users
- CSS files get formatting + linting via the same Biome pipeline (31
  stable rules, no extra dependency)
- Graceful degradation in pre-commit (skip when Biome not installed)
  eliminates manual YAML commenting/uncommenting

### Negative

- More dependencies to install (Biome required; Semgrep, Knip optional)
- Increased hook execution time for session-scoped tools (Semgrep 3-9s
  if installed) on the trigger edit (3rd TS file modified). Knip
  (10-60s) is CI-recommended and off by default in hooks
- Vue/Svelte/Astro files get limited coverage (Semgrep only, no Biome)
- Nursery rules may cause unexpected advisory noise
- config.json structure becomes asymmetric (TS nested, others flat)
- SCSS/Sass/Less files have no hook coverage until Biome ships SCSS
  parser support
- CSS Modules may trigger false positives (`:global()` pseudo-class
  flagged as unknown)
- No type checking in hooks means type errors only caught by IDE and CI
- Per-edit blocking time is actually lower than Python (~0.4s vs ~0.8s)
  because `biome check --write` is a single combined command
- SFC files have zero pre-commit coverage (Biome can't parse, Semgrep
  is CC-hooks-only)
- Pre-commit Biome wrapper uses `command -v` which may behave differently
  in some shell environments

### Risks

- Biome's JSON reporter format is documented as "experimental" - may change
- Semgrep's `--config auto` ruleset may add noisy rules over time
- Knip defaults to CI-only (`knip: false`). Users who opt-in to
  hooks-based Knip face session-scoped scanning that may miss dead
  code introduced in the first 2 files
- Biome's ~8 type-aware rules (out of 15-16 Project domain rules) provide
  limited type safety coverage compared to the ~86 rules in typescript-eslint
- Init process for TS activation may conflict with existing `package.json`
  in projects that already have one

## Clarification Summary

### 1. Problem

The cc-hooks-portable-template provides aggressive, automated code quality
enforcement for Python and other languages via PostToolUse hooks, but has
no TypeScript/JavaScript coverage. As the template is intended for
projects that include TypeScript codebases, this gap means TypeScript
files bypass the Boy Scout Rule (edit a file, own all its violations)
that the hook system enforces for every other supported language.

### 2. Root Cause

The TypeScript linting ecosystem has been fragmented and fast-moving,
with no clear "Ruff equivalent" until recently. The Python hook benefits
from Ruff's single-binary, opinionated, Rust-based design that combines
formatting, linting, and auto-fixing in one tool with native JSON output.
TypeScript lacked a tool with equivalent philosophy, performance, and
integration characteristics suitable for a synchronous PostToolUse hook
that must complete within a strict performance budget.

Additionally, TypeScript type checking is fundamentally project-wide (it
requires the full module graph), making it incompatible with the per-file
hook execution model. This created uncertainty about how to achieve
equivalent depth without the `ty` (type checker) equivalent that the
Python stack enjoys.

### 3. Solution

Expand the existing `multi_linter.sh` hook with a TypeScript handler
using this tool stack:

**Core (per-file, blocking)**:

- **Biome** (format + lint): Single Rust binary, `biome check --write`
  for Phase 1, `biome lint --reporter=json` for Phase 2. All stable
  rules enabled (`{ "all": true }`), nursery configurable
  (`off`/`warn`/`error`). Two-tier auto-fix configurable (safe-only
  default, unsafe optional). Handles `.ts`, `.tsx`, `.js`, `.jsx`,
  `.mjs`, `.cjs` files and takes over JSON formatting when enabled

**Supplemental (session-scoped advisory)**:

- **Semgrep** (security, optional enhancement): Session-scoped advisory
  scanning (after 3+ TS files, scans all modified files) via
  `semgrep --json --config .semgrep.yml`. Uses curated local ruleset
  (5-10 rules, 1-3s/file) instead of `--config auto` (5-15s). Catches
  eval(), innerHTML, hardcoded secrets, injection patterns. Runs on all
  web files including `.vue`, `.svelte`, `.astro`. Runs if installed
  (`brew install semgrep` or `uv pip install semgrep`), graceful skip
  if not
- **jscpd** (duplicates): Existing session-scoped advisory (unchanged)

**CI-recommended (opt-in via config)**:

- **Knip** (dead code): Detects unused exports, dependencies, and
  devDependencies. Default `knip: false` — too slow for hooks (10-60s
  session-scoped block). CI catches dead code at merge time. Enable
  in hooks via `"knip": true` in config.json

**Not in hooks by default (deferred to IDE + CI)**:

- **Type checking** (`tsc --noEmit` or `tsgo`). Too slow for per-edit
  hooks (2-5s project-wide). IDE provides real-time feedback, CI enforces
  at merge time. Config field `tsc` available as escape hatch (default:
  `false`). See D3
- **Dead code detection** (Knip). Too slow for hooks (10-60s
  session-scoped). CI catches dead code at merge time. Config field
  `knip` available as opt-in (default: `false`)

**SFC handling**: `.vue`, `.svelte`, `.astro` files get Semgrep-only
(Biome doesn't parse SFCs). All other web files get the full Biome +
Semgrep pipeline.

**Configuration**: Nested TypeScript section in `config.json` with
per-tool toggles (`enabled`, `js_runtime`, `biome_nursery`,
`biome_unsafe_autofix`, `tsc`, `semgrep`, `knip`). JS runtime
auto-detection or explicit selection. New tool configs (`biome.json`,
`.semgrep.yml`, `knip.json`) added to protected files list.

**Architecture**: Same script (`multi_linter.sh`), new case branch
(`*.ts | *.tsx | ...`) dispatching to a named `handle_typescript()`
function (~150-200 lines). Five satellite functions also modified
(~50-70 lines): `spawn_fix_subprocess()`, `rerun_phase1()`,
`rerun_phase2()`, plus new `is_typescript_enabled()` config function.
Shared model selection patterns (haiku for simple fixes, sonnet for
semantic/complexity, opus for volume >5). Subprocess delegation
identical to Python handler. JS runtime auto-detection is cached per
session (`/tmp/.biome_path_${PPID}`).

**Performance alignment**: Per-edit blocking time is ~0.4s + subprocess
(vs Python's ~0.8s + subprocess). Advisory tools (Semgrep, Knip) are
session-scoped (after 3+ TS files), not per-edit. Verification phase
(`rerun_phase2()`) skips advisory tools for TypeScript, re-running
only Biome lint (~100ms). See Performance Budget section for full
timing comparison.

**Pre-commit**: Two Biome hooks (`biome-format` + `biome-lint`) using
`language: system` with graceful degradation (exit 0 if Biome not
installed). Inserted after Python hooks. Semgrep, Knip, and tsc are
CC-hooks-only (documented in INTENTIONAL EXCLUSIONS). Pre-commit JSON
validation stays jaq (D6 Biome takeover is CC-hooks only).

**Template structure**: Opt-in TS layer. Python scaffolding unchanged.
`.gitignore` pre-includes TS patterns. `make init-typescript` creates
`biome.json`, `package.json`, `tsconfig.json` and flips
`typescript.enabled` in `config.json`.

**Testing strategy**: Two-tier architecture. Tier 1: 16 unit tests in
`test_hook.sh --self-test` using `HOOK_SKIP_SUBPROCESS=1` for
deterministic results (exit codes, output patterns, model selection).
Tier 2: 3 manual E2E validation commands via `claude -p --debug
--allowedTools "Read,Edit,Write"` for full-chain verification. Hooks
fire in pipe mode (confirmed by official docs). Regression gate: run
`--self-test` (30 total tests) before each commit during implementation.

### 4. Verification

#### Automated Tests (see Q6 for full test suite)

The 16 TypeScript unit tests in `test_hook.sh --self-test` (Q6, Tier 1)
cover: functional behavior (clean file, violations, extension handling),
configuration (TS disabled, nursery, JSON takeover), model selection
(haiku/sonnet/opus), graceful degradation (Biome missing), protected
config files (biome.json), and pre-commit hooks (Biome format/lint,
graceful skip).

The 3 E2E validation commands (Q6, Tier 2) cover the full Claude Code
-> hook -> subprocess -> verify chain for: violations fixed, TS
disabled, and Biome not installed.

Run the regression gate (`test_hook.sh --self-test`) before each commit
during implementation. All 30 tests (14 existing + 16 new TS) must pass.

#### Manual Verification Checks

The following checks require manual validation (timing measurements,
multi-edit sessions, or tool-specific setup that cannot be reliably
automated in the test suite):

1. **Performance budget test**: Time `biome check --write` on a single
   TS file. Verify Phase 1 completes in <200ms (well within 500ms
   budget). Time `semgrep --config .semgrep.yml` on a single file.
   Verify it completes in <3s with the local ruleset

2. **Verify scope test**: With `HOOK_DEBUG_MODEL=1`, trigger a TS
   file edit that produces violations. After subprocess fixes, verify
   that `rerun_phase2()` only runs Biome lint (not Semgrep)

3. **Runtime caching test**: Edit two TS files consecutively. Verify
   that Biome binary path detection runs only on the first edit
   (check for `/tmp/.biome_path_${PPID}` existence after first edit)

4. **Semgrep session-scoped test**: Edit 3 TS files in a session.
   Verify Semgrep runs on the 3rd edit, scanning all 3 modified
   files. Verify it uses `.semgrep.yml` (not `--config auto`)

---

## References

- [Biome Linter Overview (official rule count)](https://biomejs.dev/linter/)
- [Biome JavaScript Rules (nursery count)](https://biomejs.dev/linter/javascript/rules/)
- [Biome v2 Announcement (75% noFloatingPromises figure)](https://biomejs.dev/blog/biome-v2/)
- [Biome v2.3 Release (Vue/Svelte/Astro SFC support)](https://biomejs.dev/blog/biome-v2-3/)
- [Biome 2026 Roadmap](https://biomejs.dev/blog/roadmap-2026/)
- [Biome useExhaustiveDependencies Rule](https://biomejs.dev/linter/rules/use-exhaustive-dependencies/)
- [Biome Linter Domains Documentation](https://biomejs.dev/linter/domains/)
- [Biome useRegexpExec Rule Documentation](https://biomejs.dev/linter/rules/use-regexp-exec/)
- [Biome CSS Rules](https://biomejs.dev/linter/css/rules/)
- [Biome Type-Aware Linter Umbrella Issue #3187](https://github.com/biomejs/biome/issues/3187)
- [Biome Stylelint Rules Tracking Issue #2511](https://github.com/biomejs/biome/issues/2511)
- [Biome Differences with Prettier](https://biomejs.dev/formatter/differences-with-prettier/)
- [Biome Official Pre-commit Hooks](https://github.com/biomejs/pre-commit)
- [Biome Benchmark Suite](https://github.com/biomejs/biome/blob/main/benchmark/README.md)
- [Biome Reporters Documentation](https://biomejs.dev/reference/reporters/)
- [Biome Configuration Reference (quoteStyle default)](https://biomejs.dev/reference/configuration/)
- [typescript-eslint Rules Overview](https://typescript-eslint.io/rules/)
- [Deno Lint Rules List](https://docs.deno.com/lint/)
- [TypeScript Native Port Announcement (10x speed)](https://devblogs.microsoft.com/typescript/typescript-native-port/)
- [TypeScript Native Preview (tsgo) npm package](https://www.npmjs.com/package/@typescript/native-preview)
- [Progress on TypeScript 7 (December 2025)](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)
- [Oxfmt Alpha Announcement (Dec 2025)](https://oxc.rs/blog/2025-12-01-oxfmt-alpha.html)
- [Oxlint v1.0 Stable Release](https://oxc.rs/blog/2025-06-10-oxlint-stable.html)
- [Oxlint Benchmark (50-100x claim)](https://github.com/oxc-project/bench-linter)
- [Rslint GitHub Repository (web-infra-dev)](https://github.com/web-infra-dev/rslint)
- [ts-prune README (maintenance mode)](https://github.com/nadeesha/ts-prune)
- [Semgrep Pre-commit Documentation](https://semgrep.dev/docs/extensions/pre-commit)
- [Semgrep Performance Issue #5257](https://github.com/semgrep/semgrep/issues/5257)
- [Semgrep Performance Principles](https://semgrep.dev/docs/kb/rules/rule-file-perf-principles)
- [Semgrep 2025 Performance Benchmarks](https://semgrep.dev/blog/2025/benchmarking-semgrep-performance-improvements/)
- [Semgrep Run Rules Documentation](https://semgrep.dev/docs/running-rules)
- [Knip Documentation](https://knip.dev/)
- [Knip Performance Guide](https://knip.dev/guides/performance)
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Run Claude Code Programmatically (claude -p)](https://code.claude.com/docs/en/headless)
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide)
- [bats-core (Bash Automated Testing System)](https://github.com/bats-core/bats-core)
- [bats-mock (Stubbing library for BATS)](https://github.com/jasonkarns/bats-mock)
