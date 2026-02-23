# ADR: TypeScript Hooks Expansion

**Status**: Proposed
**Date**: 2026-02-14
**Author**: alex fazio + Claude Code clarification interview
**Related**: [Linear Document][linear-ts-hooks] | ADAI-13

[linear-ts-hooks]: https://linear.app/ad-main/document/typescript-equivalent-of-ruff-for-claude-code-hooks-366e4ee6d5f6

## Context and Problem Statement

The plankton currently provides automated code quality
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
| **Biome** | Single binary, JSON, auto-fix | 436 rules, exp. SFC | **Yes** |
| **Oxlint+Oxfmt** | 520+ rules, 50-100x ESLint | Two bins, Oxfmt alpha | No |
| **Biome+Oxlint** | Max rule coverage | Double-report, complex | No |
| **Deno Lint** | Fast (~21ms/file), Rust | ~123 rules, no type | No |
| **Rslint** | TS-first, tsgo powered | Experimental, no release | Rejected |

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

**Decision**: Biome + oxlint+tsgolint (opt-in) + Semgrep (optional) +
jscpd + tsgo (opt-in)

Where Python uses 5 specialized per-file tools (ruff + ty + flake8 + vulture
\+ bandit) plus jscpd, TypeScript uses one comprehensive single binary
(Biome: 436 rules for format + lint + partial type-awareness) plus
type-aware linting (oxlint+tsgolint, opt-in) and session-scoped advisory
tools. Both achieve aggressive linting through different architectures.
The TS per-edit blocking time (~0.4-1.4s depending on oxlint opt-in) is
comparable to Python's (~0.8s).

| Tool | Python Equivalent | Role | Scan Mode |
| --- | --- | --- | --- |
| **Biome** | ruff (format+lint) | Format, lint, imports | Per-file blocking |
| **oxlint+tsgolint** | ty (type check) | 45 type-aware rules | Per-file opt-in |
| **Semgrep** | bandit (note 1) | Security scanning | Session-scoped, advisory |
| **jscpd** | jscpd | Duplicate detection | Session-scoped, advisory |

**Note 1**: Unlike bandit (per-file blocking in Python hooks), Semgrep
runs session-scoped (after 3+ TS files modified) and is an optional
enhancement — runs if installed (`brew install semgrep` or
`uv pip install semgrep`), graceful skip if not.

**Note 2**: oxlint+tsgolint runs ONLY type-aware rules (45 rules that
require type information). It does NOT overlap with Biome's 430+
non-type-aware lint rules. However, 3 rules overlap in the type-aware
space: Biome's nursery `noFloatingPromises`, `noMisusedPromises`, and
`useAwaitThenable` duplicate oxlint's `no-floating-promises`,
`no-misused-promises`, and `await-thenable`. When oxlint is enabled,
the hook disables these 3 Biome nursery rules to prevent
double-reporting (see D3). This avoids the double-reporting issue
identified in D1 when evaluating Biome+Oxlint as dual general linters.
See D3 for full rationale.

**Opt-in tools** (off by default, opt-in via config.json):

| Tool | Python Equivalent | Role | Default |
| --- | --- | --- | --- |
| **oxlint+tsgolint** | ty | Type-aware lint (45 rules) | `false` (D3) |
| **tsgo** | ty (full) | Full type check (session) | `false` (D3) |
| **Knip** | vulture | Dead code/unused exports | `knip: false` (opt-in) |

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

**Decision**: Two-tool opt-in type safety strategy. Per-file type-aware
linting via oxlint+tsgolint (45 rules) and session-scoped full type
checking via tsgo. Both disabled by default. Without oxlint opt-in,
hooks have no reliable blocking type-aware coverage — Biome's type-aware
rules are all in the nursery group (experimental, severity "information")
and provide advisory-only diagnostics via the project domain Scanner.

**The problem**: Biome's type synthesizer is significantly more limited than
initially documented. The Linear document claimed "~75% of typescript-eslint
coverage" but this is misleading:

- The 75% figure refers to the detection rate of **one specific rule**
  (`noFloatingPromises`), not coverage of all typescript-eslint rules
- Biome has 4-6 type-aware rules, ALL in the **nursery** group with
  default severity "information" (not "error"). These rules belong to
  the **project domain**, which activates the Biome Scanner (module
  graph resolution) with non-trivial performance overhead:
  - `noFloatingPromises` (~85% detection rate as of v2.1, v2.0.0+)
  - `noMisusedPromises` (v2.1.0+)
  - `useExhaustiveCase` (v2.0.0+)
  - `useAwaitThenable` (v2.3.9+, limited: only checks global Promise
    class, not custom thenables)
  - `noUnnecessaryConditions` (v2.3.x+, type-aware narrowing)
  - `noNestedPromises` (v2.3.15+)
  Additional type-aware rules are under active development (see
  umbrella issue #3187, now closed — initial implementation shipped)
- typescript-eslint has ~59 type-aware rules
- Biome explicitly states it is "not trying to implement a full-fledged
  type system or a type checker like TypeScript"
- Biome's type synthesizer is designed as a linting aid, NOT a replacement
  for tsc

**Why this matters for Claude Code hooks**: Claude Code operates as a CLI
tool and never sees IDE diagnostics. Without type-aware checking in hooks,
Claude can introduce type-unsafe code (wrong argument types, missing
properties, async/promise errors) that passes all hook checks. Errors
only surface at CI (too late — cascading type errors may have spread
across multiple files in the session).

**Research findings** (2026-02-14):

| Option | Speed | Type Coverage | Suitable for Hooks? | Notes |
| --- | --- | --- | --- | --- |
| `tsc --noEmit` | 2-5s+ | Full (~59) | No - too slow | Project-wide |
| `tsc --incremental` | 2-4.5s | Full | No - marginal | Node ~500ms |
| `tsgo --noEmit` (cold) | 0.5-4s (10x) | Full (99.9%) | Session only | Full |
| **oxlint+tsgolint** | **0.2-1s** | **45 rules** | **Yes, opt-in** | **None** |
| Biome synthesizer | <100ms | 4-6 nursery | Advisory only | Module graph |
| tsgo LSP daemon | <500ms | Full | Future | No client exists |

#### Tool 1: oxlint+tsgolint — Per-File Type-Aware Linting (opt-in)

**Architecture**: oxlint (Rust CLI) + tsgolint (Go binary wrapping
typescript-go). oxlint handles CLI, path traversal, and diagnostic
printing. tsgolint handles type analysis using the same engine as tsgo.

**Key constraint**: Runs ONLY type-aware rules — the 45 rules that
require type information. All non-type-aware rules are disabled to avoid
overlap with Biome's 430+ lint rules. This resolves the double-reporting
concern identified in D1 when Biome+Oxlint was rejected as a hybrid.

**Rules covered** (45 type-aware, high-value subset):

| Category | Rules | Errors Caught |
| --- | --- | --- |
| Promise/async | `no-floating-promises`, `no-misused-*` | Unhandled promise |
| Type safety | `no-unsafe-argument`, `no-unsafe-assignment` | Type mismatches |
| Narrowing | `no-unnecessary-type-assertion` | Null access |
| Other | `no-redundant-type-constituents`, etc. | Subtle misuse |

**What it won't catch** (requires full tsc): Structural type errors like
"property doesn't exist on this type" or deep generic inference failures.
These require the full type checker, not lint-level rules.

**Performance**: ~0.2-1s per file on small-medium projects. Go-based
binary has no Node.js startup overhead. **Hard timeout gate at 2s** — if
exceeded, skip and emit warning:

```text
[hook:warning] oxlint+tsgolint exceeded 2s budget on {file}, skipping type-aware checks
```

**Maturity**: Alpha (as of February 2026). Known OOM and deadlock issues
on large monorepos. Ships as opt-in (`oxlint_tsgolint: false`) until
stable. Graceful degradation if not installed.

**Prerequisite**: Requires TypeScript 7.0+ tsconfig semantics. tsgolint
uses `typescript-go` (the Go port of tsc), which expects TS 7 config
options. Config options deprecated in TS 6 or removed in TS 7 will not
work. Projects on TypeScript 5.x need tsconfig migration before opting
in.

**Stability coupling**: tsgolint shims `typescript-go` internal APIs
(not public APIs). This means tsgolint's stability is coupled to
`typescript-go`'s internal implementation details. A `typescript-go`
internal refactor could break tsgolint without warning, independent of
tsgolint's own release cycle.

**Invocation**: Configure `.oxlintrc.json` with all categories disabled
and specific `typescript/*` type-aware rules enabled. The `--type-aware`
flag adds type-aware rules on top of regular rules — it does NOT replace
them. To run only type-aware rules, use:

```bash
oxlint --type-aware --tsconfig tsconfig.json -A all \
  -D typescript/no-floating-promises \
  -D typescript/no-misused-promises \
  -D typescript/await-thenable \
  -D typescript/no-unsafe-argument \
  -D typescript/no-unsafe-assignment \
  -D typescript/no-unsafe-return \
  -D typescript/no-unsafe-call \
  -D typescript/no-unnecessary-type-assertion \
  -D typescript/strict-boolean-expressions \
  --format json <file>
```

Or configure in `.oxlintrc.json` (recommended for hooks):

```json
{
  "categories": { "correctness": "off", "suspicious": "off", "style": "off", "pedantic": "off", "restriction": "off" },
  "rules": {
    "typescript/no-floating-promises": "error",
    "typescript/no-misused-promises": "error",
    "typescript/await-thenable": "error",
    "typescript/no-unsafe-argument": "error",
    "typescript/no-unsafe-assignment": "error",
    "typescript/no-unsafe-return": "error",
    "typescript/no-unsafe-call": "error",
    "typescript/no-unnecessary-type-assertion": "error",
    "typescript/strict-boolean-expressions": "error"
  }
}
```

**Note**: The `--only-type-aware` flag does not exist in oxlint's CLI.
The `-A all` (allow all) flag disables all non-type-aware rules, then
`-D` (deny) flags enable specific type-aware rules.

**Config**: `"oxlint_tsgolint": false` in `typescript` config section.

**Biome overlap resolution**: When `oxlint_tsgolint: true`, the hook
disables Biome's overlapping nursery type-aware rules to prevent
double-reporting. This is implemented by passing CLI overrides:

```bash
biome lint \
  --rule nursery/noFloatingPromises=off \
  --rule nursery/noMisusedPromises=off \
  --rule nursery/useAwaitThenable=off \
  --reporter=json <file>
```

This avoids duplicate diagnostics AND skips the Biome Scanner overhead
for these rules. `useExhaustiveCase` is NOT disabled because oxlint
has no equivalent rule. `noUnnecessaryConditions`, `noImportCycles`,
and `noNestedPromises` are also kept since oxlint does not cover them.

#### Tool 2: tsgo — Session-Scoped Full Type Checking (opt-in)

**Architecture**: `tsgo --noEmit` runs the full TypeScript type checker
(Go port, 99.9% of 20,000 TS test cases passing). Session-scoped
advisory, matching the Semgrep pattern.

**Trigger**: After 3+ TS files modified in the session, run
`tsgo --noEmit` on the full project. Report type errors as
`[hook:advisory]`. Session tracking via `/tmp/.tsgo_session_${PPID}`
with `.done` marker (same pattern as Semgrep).

**Performance**: 0.5-4s one-time block per session (project-dependent).
tsgo is ~10x faster than tsc. Acceptable as a one-time session-scoped
cost, not acceptable per-edit.

**Maturity**: Preview (`@typescript/native-preview`). More stable than
oxlint+tsgolint — backed by Microsoft, foundation for TypeScript 7.0.

**Output**: Advisory only. Type errors are reported but do not block or
trigger subprocess delegation. The reasoning: full tsc-level errors may
include false positives or complex structural issues that the subprocess
cannot fix reliably. Advisory surfaces awareness; CI enforces.

**Config**: `"tsgo": false` in `typescript` config section. (Replaces
the previous `"tsc": false` escape hatch with a dedicated field.)

#### Four-Layer Type Safety Strategy

| Layer | Tool | When | Coverage | Default |
| --- | --- | --- | --- | --- |
| IDE | VSCode + TS Server | Real-time | Full | Always on |
| Hooks (fast) | Biome+**oxlint** | Per-edit | Lint types | Biome: on, oxlint: **opt-in** |
| Hooks (full) | **tsgo --noEmit** | Session (3+) | Full types | **Opt-in** |
| CI | `tsc --noEmit` or `tsgo` | Pre-merge | Full | Always on |

**Config impact**: The `typescript.tsc` field is replaced by two fields:
`"oxlint_tsgolint": false` (per-file type-aware linting) and
`"tsgo": false` (session-scoped full checking). Both default to `false`.

**Future**: When tsgo LSP matures (`tsgo --lsp --stdio`), a daemon-based
approach could deliver per-file full type checking at <500ms after
warm-up. This would require a custom thin LSP client (~200-400 LOC) and
is documented as a future enhancement, not a current deliverable.

### D4: File Scope and Extension Handling

**Decision**: All web files, with tiered handling by extension.

#### Full Pipeline (Biome + Semgrep)

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.mts`, `.cts`
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

#### SFC Coverage Warning

When editing `.vue`, `.svelte`, or `.astro` files without Semgrep installed,
the hook emits a one-time session warning:

```text
[hook:warning] No linter available for .vue files. Install semgrep for security scanning: brew install semgrep
```

This fires once per SFC extension per session (tracked via
`/tmp/.sfc_warned_${ext}_${PPID}`). Without Semgrep, SFC files receive
zero lint coverage since Biome cannot parse SFC files.

### D5: Framework Support

**Decision**: Support multiple frameworks (React, Vue, Svelte, Astro,
Next.js).

- **React/JSX-a11y**: Biome handles natively (built-in rules)
- **Vue/Svelte/Astro**: Semgrep-only for now. Biome lacks plugins for these
- **Framework-specific rules**: Biome's correctness and security groups
  cover common patterns. Framework-specific deep linting deferred to CI

### D6: JSON Handler Takeover

**Decision**: Biome takes over JSON formatting when TypeScript is enabled.

- When `typescript.enabled: true` in config.json AND Biome is available,
  Biome formats JSON/JSONC files instead of jaq
- When `typescript.enabled: true` but Biome is not installed, jaq is used
  as fallback (prevents a formatting gap during the setup window between
  `init-typescript.sh` and `npm install`)
- jaq remains the default for projects without TypeScript enabled
  (`typescript.enabled: false` or `typescript: false`)
- Biome's JSON formatting is Prettier-compatible
- Implementation: the JSON case branch checks Biome availability before
  delegating; falls back to jaq if Biome is absent

### D7: Architecture - Same Script, Named Function

**Decision**: Add a `handle_typescript()` function to the existing
`multi_linter.sh`, called from a new case branch in the main dispatch.

**Rationale**:

1. `config.json` already has `"typescript": false` placeholder ready to flip
2. Three-phase pattern (format, collect, delegate) is identical
3. A new case branch (`*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts
   | *.cts | *.css) handle_typescript ;;`) follows the existing dispatch
   pattern
4. A separate script would require a second PostToolUse hook registration
5. Named function keeps the main case statement clean (the Python handler
   is already ~170 lines inline; adding ~150-200 more inline would push
   the case past 1100 lines)

**Estimated changes**:

| Location | Lines | Description |
| --- | --- | --- |
| `handle_typescript()` | ~150-200 | New function (Phase 1-3 for TS) |
| `is_typescript_enabled()` | ~10 | New config function (nested object) |
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

- ~72 nursery rules out of 436+ total (~16%)
- **Not subject to semver** - breaking changes can occur without warning
- May have bugs or performance problems
- Can be removed entirely between versions
- Require explicit opt-in on stable Biome releases
- Promoted to stable groups after at least one minor version cycle

#### Configuration

| `biome_nursery` value | Behavior | Analogy |
| --- | --- | --- |
| `"off"` | Only stable rules | Conservative |
| `"warn"` (default) | Nursery as advisory, non-blocking | Like ruff --preview |
| `"error"` | Nursery as errors, triggers subprocess | Max opinionatedness |

#### Biome Config Mapping

```json
// biome_nursery: "off"
{ "linter": { "rules": { "recommended": true, "a11y": "error", "complexity": "warn", "correctness": "error", "performance": "warn", "security": "error", "style": "warn", "suspicious": "error" } } }

// biome_nursery: "warn"
{ "linter": { "rules": { "recommended": true, "a11y": "error", "complexity": "warn", "correctness": "error", "performance": "warn", "security": "error", "style": "warn", "suspicious": "error", "nursery": "warn" } } }

// biome_nursery: "error"
{ "linter": { "rules": { "recommended": true, "a11y": "error", "complexity": "warn", "correctness": "error", "performance": "warn", "security": "error", "style": "warn", "suspicious": "error", "nursery": "error" } } }
```

#### Nursery Mismatch Validation

The hook validates at startup that `biome_nursery` in `config.json` matches
the `nursery` value in `biome.json`. If they diverge, the hook emits:

```text
[hook:warning] config.json biome_nursery='warn' but biome.json nursery='error' — behavior follows biome.json
```

This prevents silent misconfiguration where the user thinks nursery rules
are advisory but `biome.json` actually treats them as errors (triggering
unexpected subprocess spawns). The validation adds <5ms overhead (single
file read of `biome.json`).

### D10: Auto-Fix Tiers - Configurable

**Decision**: Phase 1 auto-fix safety level is configurable via
`biome_unsafe_autofix` field.

| `biome_unsafe_autofix` | Phase 1 Command | Behavior |
| --- | --- | --- |
| `false` (default) | `biome check --write` | Safe fixes only (no semantic) |
| `true` | `biome check --write --unsafe` | All fixes incl. semantic |

This mirrors the Python hook's approach: Phase 1 runs `ruff check --fix`
(safe), while Phase 3 subprocess handles unsafe fixes. The configurable
option allows aggressive users to enable unsafe auto-fix in Phase 1.

**oxlint compatibility note**: When `oxlint_tsgolint: true`, unsafe
auto-fix (`biome_unsafe_autofix: true`) is **not recommended**. Biome's
`useImportType` unsafe auto-fix can change `import { Foo }` to
`import type { Foo }`, which may affect oxlint's type resolution
(known issue biomejs/biome#4640). The default `biome_unsafe_autofix:
false` is critical for oxlint compatibility.

### D11: Scan Scope by Tool

**Decision**: Mixed per-file and session-scoped scanning.

| Tool | Scope | Trigger | Blocking? |
| --- | --- | --- | --- |
| Biome (lint) | Per-file | Every Edit/Write on TS/JS | Yes (subprocess) |
| Biome (format) | Per-file | Every Edit/Write on TS/JS | Silent (Phase 1) |
| oxlint+tsgolint | Per-file | Edit/Write if `oxlint_tsgolint` | Yes (subprocess, 2s) |
| Semgrep | Session | After 3+ TS files (all modified) | Advisory only |
| tsgo | Session | After 3+ TS files (if `tsgo`) | Advisory only |
| Knip | Session | After 3+ TS files (if `knip`) | Advisory (CI-rec, off) |
| jscpd | Session-scoped | After 3+ files modified | Advisory only (existing) |

**Session tracking mechanism**: Semgrep, tsgo, and Knip use the same
`/tmp/` temp file pattern as jscpd for session-scoped tracking. Modified
TS files are appended to `/tmp/.semgrep_session_${PPID}` (and
`/tmp/.tsgo_session_${PPID}`, `/tmp/.knip_session_${PPID}` if enabled).
When the file reaches 3+ entries, the next TS file edit triggers the
session-scoped scan. A `.done` marker prevents re-triggering within the
same session.

**oxlint+tsgolint timeout gate**: Per-file oxlint+tsgolint invocations
are wrapped in `timeout 2s`. If the timeout is exceeded (exit 124), the
hook emits `[hook:warning] oxlint+tsgolint exceeded 2s budget` and
skips type-aware checking for that file. The session-scoped tsgo check
serves as a safety net for skipped per-file checks.

### D12: Model Selection - Shared Patterns

**Decision**: Shared `sonnet_patterns` and `opus_patterns` regex covering
both Python and TypeScript violations.

#### TypeScript Model Mapping

| Violation Type | Model | Examples |
| --- | --- | --- |
| Simple auto-fixable | Haiku | Unused vars, imports, formatting |
| Semantic / complex | Sonnet | Complexity, type-aware, hook deps |
| Type-aware (oxlint) | Sonnet | oxlint type-aware violations |
| Complex / high volume | Opus | Volume >5 violations of any type |

**Note**: oxlint+tsgolint type-aware violations route to sonnet because
they require semantic understanding to fix (type mismatches, async
patterns, null safety). tsgo advisory output does NOT trigger subprocess
delegation — it is informational only.

#### Updated Pattern Config

```json
"model_selection": {
  "sonnet_patterns": "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+|complexity|useExhaustiveDependencies|noFloatingPromises|useAwaitThenable|no-unsafe-argument|no-unsafe-assignment|no-unsafe-return|no-unsafe-call|no-unsafe-member-access|no-unsafe-type-assertion|no-unsafe-unary-minus|no-unsafe-enum-comparison|no-misused-promises|no-unnecessary-type-assertion|no-unnecessary-type-arguments|no-unnecessary-boolean-literal-compare|strict-boolean-expressions|await-thenable|no-unnecessary-condition|no-confusing-void-expression|no-base-to-string|no-redundant-type-constituents|no-duplicate-type-constituents|no-floating-promises|no-implied-eval|no-deprecated|no-for-in-array|no-misused-spread|no-array-delete|switch-exhaustiveness-check|unbound-method|return-await|only-throw-error|require-await|require-array-sort-compare|restrict-plus-operands|restrict-template-expressions|prefer-promise-reject-errors|promise-function-async",
  "opus_patterns": "unresolved-attribute|type-assertion",
  "volume_threshold": 5
}
```

Biome and oxlint type-aware rules route to sonnet. The opus tier is
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
      "oxlint_tsgolint": false,
      "tsgo": false,
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
- `.oxlintrc.json` - oxlint configuration (if used)
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
  ".oxlintrc.json",
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
| oxlint+tsgolint | No | Yes (per-file, opt-in) | Type-aware lint, 2s timeout gate |
| tsgo | No | Yes (session-scoped advisory, opt-in) | Full type checking after 3+ TS files |
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
# - oxlint+tsgolint: Per-file type-aware lint, opt-in in CC hooks only
# - tsgo: Session-scoped type checking advisory, opt-in in CC hooks only
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

**Created by init process** (`scripts/init-typescript.sh` or documented steps):

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

## Full Coverage Dependencies

For zero-warning, zero-skip operation with all lint coverage enabled:

| Tool | Install | Purpose | Without It |
| --- | --- | --- | --- |
| **jaq** | `brew install jaq` | JSON parsing (existing) | Hook cannot run |
| **@biomejs/biome** | `npm i -D @biomejs/biome` | Lint + format (TS/JS/CSS/JSON) | TS handler skipped entirely |
| **semgrep** | `brew install semgrep` or `pip install semgrep` | Security scanning + SFC coverage | SFC files get zero coverage; [hook:warning] emitted |

Optional (off by default, opt-in via config.json):

| Tool | Install | Config Flag | Purpose |
| --- | --- | --- | --- |
| **oxlint+tsgolint** | `npm i -D oxlint oxlint-tsgolint` | `"oxlint_tsgolint": true` | Per-file type-aware linting (45 rules, see D3). Requires TS 7.0+ tsconfig |
| **tsgo** | `npm i -g @typescript/native-preview` | `"tsgo": true` | Session-scoped full type checking (see D3) |
| **knip** | `npm i -D knip` | `"knip": true` | Dead code detection (CI-recommended) |

## Files Modified (Implementation Checklist)

| File | Action | Description |
| --- | --- | --- |
| `.claude/hooks/multi_linter.sh` | Modify | Add `handle_typescript()` function (~150-200 lines), case branch, satellite functions |
| `.claude/hooks/config.json` | Modify | Add `biome.json`, `.semgrep.yml`, `knip.json` to `protected_files`; add `oxlint_tsgolint` and `tsgo` fields; update `sonnet_patterns` with TS + oxlint rules |
| `.claude/hooks/protect_linter_configs.sh` | Modify | Recognize new protected config files |
| `.claude/hooks/test_hook.sh` | Modify | Add 16+ TypeScript unit tests (including oxlint+tsgolint and tsgo tests) |
| `.pre-commit-config.yaml` | Modify | Add `biome-format` and `biome-lint` hooks; extend jscpd file pattern; update INTENTIONAL EXCLUSIONS |
| `.jscpd.json` | Modify | Add `typescript`, `javascript`, `tsx`, `jsx`, `css` to format list |
| `.gitignore` | Modify | Add TS patterns (`dist/`, `.next/`, `*.tsbuildinfo`, etc.) |
| `CLAUDE.md` | Modify | Add `biome.json`, `.semgrep.yml`, `knip.json` to protected files list |
| `scripts/init-typescript.sh` | Create | Init script that creates `biome.json`, `package.json`, `tsconfig.json`, updates `config.json` |
| `biome.json` | Create (by init) | Biome configuration template (see Q2) |
| `package.json` | Create (by init) | Minimal package.json with `@biomejs/biome` devDependency |
| `tsconfig.json` | Create (by init) | Minimal TypeScript compiler configuration |
| `.semgrep.yml` | Create (by init) | Curated security ruleset (see Q3) |

## Phase Mapping: Python to TypeScript

| Phase | Python | TypeScript |
| --- | --- | --- |
| **Phase 1: Auto-Format** | `ruff format` + `ruff check --fix` | `biome check --write` (or `--write --unsafe` if configured) |
| **Phase 2a: Primary lint** | `ruff check --preview --output-format=json` | `biome lint --reporter=json` |
| **Phase 2b: Type-aware linting** | `ty check --output-format gitlab` | oxlint+tsgolint (45 type-aware rules, per-file, opt-in via `oxlint_tsgolint: true`). Biome's type-aware nursery rules provide advisory baseline when oxlint disabled. tsgo session-scoped advisory (opt-in via `tsgo: true`) |
| **Phase 2c: Duplicate detection** | `jscpd` (session-scoped) | `jscpd` (session-scoped, existing) |
| **Phase 2d: Domain-specific** | `flake8 --select=PYD` (Pydantic) | N/A (no TS equivalent) |
| **Phase 2e: Dead code** | `vulture` | `knip` (CI-recommended, opt-in via `knip: true` in config) |
| **Phase 2f: Security** | `bandit` | `semgrep --json --config .semgrep.yml` (session-scoped, advisory) |
| **CSS: Format + Lint** | N/A | `biome check --write` + `biome lint --reporter=json` (same as TS/JS) |
| **Phase 3: Delegate** | `claude -p` subprocess | `claude -p` subprocess (same mechanism) |

### TypeScript Subprocess Prompt

The subprocess receives a prompt parallel to the Python/Shell examples
documented in the README. Key differences:

**Format command**: `biome format --write <file>`

**Linter field**: `"biome"` for Biome violations, `"oxlint"` for
oxlint+tsgolint type-aware violations.

**TS-specific fix strategies** (included in subprocess prompt when
relevant violation types are present):

| Violation | Fix Strategy |
| --- | --- |
| `useExhaustiveDependencies` | Add missing deps to array, or extract values to `useRef`/`useCallback` |
| `noFloatingPromises` | Add `await`, `.catch()`, or `void` prefix |
| `no-unsafe-argument` / `no-unsafe-assignment` (oxlint) | Add explicit type annotations or type guards |
| `strict-boolean-expressions` (oxlint) | Add explicit null/undefined checks or `Boolean()` |
| `useAwaitThenable` | Remove unnecessary `await` on non-Promise values |
| `noDoubleEquals` | Replace `==` with `===` (and `!=` with `!==`) |

**Example TypeScript subprocess prompt**:

```text
You are a code quality fixer. Fix ALL violations listed below in ./src/api/handler.ts.

VIOLATIONS:
[
  {
    "line": 12,
    "column": 3,
    "code": "lint/suspicious/noDoubleEquals",
    "message": "Use === instead of ==",
    "linter": "biome"
  },
  {
    "line": 28,
    "column": 5,
    "code": "typescript/no-floating-promises",
    "message": "Promises must be awaited, returned, or explicitly ignored with void",
    "linter": "oxlint"
  }
]

RULES:
1. Use targeted Edit operations only - never rewrite the entire file
2. Fix each violation at its reported line/column
3. After fixing, run the formatter:
   biome format --write './src/api/handler.ts'
4. Verify by re-running the linter
5. If a violation cannot be fixed, explain why

FIX STRATEGIES:
- noFloatingPromises: Add `await`, `.catch()`, or `void` prefix
- no-unsafe-argument: Add explicit type annotations or type guards

Do not add comments explaining fixes. Do not refactor beyond what's needed.
```

## Performance Budget

Hooks are **synchronous and blocking** — the main agent cannot proceed
until the hook completes (see README "Hook Execution Model"). Every tool
invocation directly impacts developer experience. The TypeScript handler
must stay within the same performance envelope as the Python handler.

### Per-Edit Blocking Time Comparison

| Phase | Python | TypeScript (Biome only) | TypeScript (+ oxlint opt-in) | Notes |
| --- | --- | --- | --- | --- |
| **Phase 1: Auto-Format** | ~300ms (ruff format + ruff check --fix) | ~100ms (`biome check --write`) | ~100ms | TS is faster; single combined command |
| **Phase 2: Blocking** | ~500ms (ruff + ty + flake8 + vulture + bandit) | ~100-300ms (biome lint + Scanner, note 1) | ~300ms-1.1s (biome + oxlint) | oxlint adds ~200ms-1s when enabled |
| **Phase 2: Session-scoped** | jscpd (~2-5s, once/session) | jscpd + Semgrep (3-9s) + Knip (10-60s) | + tsgo (0.5-4s) | One-time blocks, not per-edit |
| **Phase 3: Subprocess** | ~5-25s (model-dependent) | ~5-25s (same mechanism) | ~5-25s | Identical subprocess model |
| **Verify** | ~500ms (rerun Phase 1 + 2) | ~200ms (biome only, skip advisory) | ~400ms-1.2s (biome + oxlint) | Verify re-runs blocking tools only |
| **Total per-edit blocking** | **~0.8s + subprocess** | **~0.4-0.6s + subprocess** | **~0.6-1.4s + subprocess** | With oxlint, comparable to Python |

**Note 1 (Scanner overhead)**: When nursery type-aware rules are enabled
(the default `biome_nursery: "warn"`), Biome activates its Scanner module
to build a module graph for type inference. This adds an estimated
+50-200ms overhead (project-size dependent) on top of the base ~100ms
biome lint time. When `oxlint_tsgolint: true`, these nursery rules are
disabled (see D3), eliminating Scanner overhead. **Post-implementation
action**: Measure actual Scanner overhead on representative projects and
update this table (see Manual Verification Checks).

### Key Performance Decisions

- **`biome check --write`** (CC hooks) vs **`biome format` + `biome lint`**
  (pre-commit): CC hooks use a single combined command for speed (~100ms).
  Pre-commit uses two separate commands for independent disable control.
  The pre-commit overhead is acceptable since it runs at commit-time, not
  per-edit
- **Verification skips advisory**: `rerun_phase2()` for TypeScript
  re-runs Biome lint + oxlint+tsgolint (if enabled), not Semgrep or tsgo.
  Advisory tools don't affect the pass/fail decision, so re-running them
  during verification adds unnecessary latency. oxlint IS re-run in
  verify because its violations trigger subprocess delegation
- **Biome Scanner overhead**: Biome's type-aware nursery rules
  (`noFloatingPromises`, `noMisusedPromises`, `useAwaitThenable`, etc.)
  belong to the `project` domain, which activates the Biome Scanner.
  The Scanner builds a module graph for type inference. This overhead
  is not measured in the Phase 2 timing above. When `oxlint_tsgolint:
  true`, the hook disables these rules (see D3), eliminating Scanner
  overhead. When oxlint is disabled, Scanner overhead is accepted as
  a trade-off for advisory-level type-aware diagnostics
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
| tsgo | 3+ TS files modified (if `tsgo: true`) | Full project (`tsgo --noEmit`) | ~0.5-4s | New, advisory only |
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
- Biome has a small number of type-aware rules shipped in production
  (3 as of v2.1, with 22 planned per issue #3187) vs ~59 type-aware
  rules in typescript-eslint
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

- **Not recommended as dual primary linters** — both reimplement ESLint
  rules, causing double-reporting of non-type-aware violations
- Different type-aware strategies: Biome = custom Rust synthesizer (2
  rules), Oxlint = tsgolint (Go wrapper around typescript-go, 45 rules)
- Community consensus: choose one for general linting, not both
- **D3 resolution**: Use Biome for formatting + non-type-aware linting,
  oxlint for type-aware rules ONLY. This scoped usage avoids
  double-reporting because the rule sets don't overlap. oxlint is
  configured to run only its 45 type-aware rules, not its 520+
  non-type-aware rules

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
- Per-edit blocking time without oxlint is lower than Python (~0.4s vs
  ~0.8s) because Biome consolidates format+lint into a single `biome check
  --write` command
- With oxlint+tsgolint opt-in, per-edit blocking (~0.6-1.4s) is comparable
  to Python's ~0.8s while providing 45 type-aware rules that catch common
  type errors Claude Code would otherwise miss
- Session-scoped tsgo provides full type checking as advisory, catching
  structural type errors that lint rules cannot detect

### Negative

- More dependencies to install (Biome required; Semgrep, Knip optional)
- Increased hook execution time for session-scoped tools (Semgrep 3-9s
  if installed) on the trigger edit (3rd TS file modified). Knip
  (10-60s) is CI-recommended and off by default in hooks
- Vue/Svelte/Astro files get limited coverage (Semgrep only, no Biome
  formatting/linting; zero pre-commit coverage since Semgrep is
  CC-hooks-only)
- Nursery rules may cause unexpected advisory noise
- config.json structure becomes asymmetric (TS nested, others flat)
- SCSS/Sass/Less files have no hook coverage until Biome ships SCSS
  parser support
- CSS Modules may trigger false positives (`:global()` pseudo-class
  flagged as unknown)
- oxlint+tsgolint is alpha — known OOM/deadlock issues on large monorepos.
  Mitigated by opt-in default and 2s timeout gate
- With oxlint enabled, per-edit blocking time increases from ~0.4s to
  ~0.6-1.4s (still comparable to Python's ~0.8s)
- Pre-commit Biome wrapper uses `command -v` which may behave differently
  in some shell environments

### Risks

- Biome's JSON reporter format is documented as "experimental and subject
  to changes in patch releases." **Mitigation**: Pin the expected JSON
  schema structure in unit tests (tests #2, #3, #7-9 validate output
  patterns). If Biome changes the schema, tests break immediately.
  RDJSON (`--reporter=rdjson`, standardized Reviewdog format) was
  evaluated as an alternative but rejected because it lacks the
  `severity` field needed for model selection logic. Document known-good
  Biome version (2.3.x) in the dependency table
- Semgrep's `--config auto` ruleset may add noisy rules over time
- Knip defaults to CI-only (`knip: false`). Users who opt-in to
  hooks-based Knip face session-scoped scanning that may miss dead
  code introduced in the first 2 files
- Biome's 4-6 type-aware rules are all in nursery (experimental, severity
  "information") and do not provide reliable blocking coverage. oxlint's
  45 rules improve this significantly but still don't match full tsc
  (~59 typescript-eslint type-aware rules equivalent)
- oxlint+tsgolint alpha stability risk — may produce false positives,
  crash, or deadlock on specific codebases. The 2s timeout gate and
  opt-in default mitigate production impact
- oxlint+tsgolint supply chain coupling — tsgolint shims `typescript-go`
  internal APIs (not public APIs). A `typescript-go` internal refactor
  could break tsgolint without warning, independent of tsgolint's own
  release cycle. This compounds the alpha stability risk above
- oxlint+tsgolint requires TypeScript 7.0+ tsconfig semantics. Projects
  on TypeScript 5.x need tsconfig migration before opting in
- Init process for TS activation may conflict with existing `package.json`
  in projects that already have one
- **Rollback mitigation**: Set `typescript.enabled: false` in `config.json`
  to instantly disable the TS handler. Pin Biome version in `package.json`
  (`"@biomejs/biome": "2.3.x"`) to avoid breaking changes from major
  version bumps

## Clarification Summary

### 1. Problem

The plankton provides aggressive, automated code quality
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
  rules enabled (all stable groups set to `"error"` or `"warn"`),
  nursery configurable
  (`off`/`warn`/`error`). Two-tier auto-fix configurable (safe-only
  default, unsafe optional). Handles `.ts`, `.tsx`, `.js`, `.jsx`,
  `.mjs`, `.cjs`, `.mts`, `.cts` files and takes over JSON formatting
  when enabled (with jaq fallback when Biome is not installed)

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

**Opt-in type safety (per-file + session-scoped)**:

- **oxlint+tsgolint** (type-aware lint, per-file blocking): 45
  type-aware rules scoped to avoid overlap with Biome. Per-file
  execution with 2s hard timeout gate. Catches unsafe assignments,
  misused promises, unnecessary type assertions, and other common
  type errors Claude Code would otherwise miss. Config field
  `oxlint_tsgolint` (default: `false`). See D3
- **tsgo** (full type checking, session-scoped advisory): Go port of
  TypeScript compiler (~7-10x faster than tsc). Runs after 3+ TS files
  modified, scans all modified files. Reports as `[hook:advisory]`.
  Catches structural type errors that lint rules cannot detect. Config
  field `tsgo` (default: `false`). See D3

**Not in hooks by default (deferred to IDE + CI)**:

- **Dead code detection** (Knip). Too slow for hooks (10-60s
  session-scoped). CI catches dead code at merge time. Config field
  `knip` available as opt-in (default: `false`)

**SFC handling**: `.vue`, `.svelte`, `.astro` files get Semgrep-only
(Biome doesn't parse SFCs). All other web files get the full Biome +
Semgrep pipeline.

**Configuration**: Nested TypeScript section in `config.json` with
per-tool toggles (`enabled`, `js_runtime`, `biome_nursery`,
`biome_unsafe_autofix`, `oxlint_tsgolint`, `tsgo`, `semgrep`, `knip`). JS runtime
auto-detection or explicit selection. New tool configs (`biome.json`,
`.semgrep.yml`, `knip.json`) added to protected files list.

**Architecture**: Same script (`multi_linter.sh`), new case branch
(`*.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.css`)
dispatching to a named `handle_typescript()`
function (~150-200 lines). Five satellite functions also modified
(~50-70 lines): `spawn_fix_subprocess()`, `rerun_phase1()`,
`rerun_phase2()`, plus new `is_typescript_enabled()` config function.
Shared model selection patterns (haiku for simple fixes, sonnet for
semantic/complexity, opus for volume >5). Subprocess delegation
identical to Python handler. JS runtime auto-detection is cached per
session (`/tmp/.biome_path_${PPID}`).

**Performance alignment**: Per-edit blocking time is ~0.4-0.6s +
subprocess without oxlint (includes estimated Biome Scanner overhead
of +50-200ms when nursery type-aware rules are active), ~0.6-1.4s +
subprocess with oxlint opt-in (vs Python's ~0.8s + subprocess).
Advisory tools (Semgrep, tsgo, Knip) are session-scoped (after 3+ TS
files), not per-edit. Verification phase (`rerun_phase2()`) skips
advisory tools for TypeScript, re-running only Biome lint + oxlint
if enabled (~100-400ms). See Performance Budget section for full
timing comparison.

**Pre-commit**: Two Biome hooks (`biome-format` + `biome-lint`) using
`language: system` with graceful degradation (exit 0 if Biome not
installed). Inserted after Python hooks. Semgrep, Knip, and tsc are
CC-hooks-only (documented in INTENTIONAL EXCLUSIONS). Pre-commit JSON
validation stays jaq (D6 Biome takeover is CC-hooks only).

**Template structure**: Opt-in TS layer. Python scaffolding unchanged.
`.gitignore` pre-includes TS patterns. `scripts/init-typescript.sh` creates
`biome.json`, `package.json`, `tsconfig.json` and flips
`typescript.enabled` in `config.json`.

**Testing strategy**: Two-tier architecture. Tier 1: 21 unit tests in
`test_hook.sh --self-test` using `HOOK_SKIP_SUBPROCESS=1` for
deterministic results (exit codes, output patterns, model selection).
Tier 2: 3 manual E2E validation commands via `claude -p --debug
--allowedTools "Read,Edit,Write"` for full-chain verification. Hooks
fire in pipe mode (confirmed by official docs). Regression gate: run
`--self-test` (35 total tests) before each commit during implementation.

### 4. Verification

#### Automated Tests (see Q6 for full test suite)

The 21 TypeScript unit tests in `test_hook.sh --self-test` (Q6, Tier 1)
cover: functional behavior (clean file, violations, extension handling),
configuration (TS disabled, nursery, JSON takeover), model selection
(haiku/sonnet/opus), graceful degradation (Biome missing), protected
config files (biome.json), pre-commit hooks (Biome format/lint,
graceful skip), oxlint+tsgolint (type-aware violations, disabled
default, timeout gate), and tsgo (session advisory, disabled default).

The 3 E2E validation commands (Q6, Tier 2) cover the full Claude Code
-> hook -> subprocess -> verify chain for: violations fixed, TS
disabled, and Biome not installed.

Run the regression gate (`test_hook.sh --self-test`) before each commit
during implementation. All 35 tests (14 existing + 21 new TS) must pass.

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
   that `rerun_phase2()` only runs Biome lint + oxlint if enabled
   (not Semgrep or tsgo)

3. **oxlint timeout gate test**: With `oxlint_tsgolint: true`, edit
   a large TS file (>5000 lines). Verify oxlint completes within 2s
   or is killed by timeout gate with a warning, not a blocking failure

4. **tsgo session advisory test**: With `tsgo: true`, edit 3+ TS
   files in a session. Verify tsgo runs on the trigger edit, reports
   as `[hook:advisory]`, and does not block the edit

5. **Runtime caching test**: Edit two TS files consecutively. Verify
   that Biome binary path detection runs only on the first edit
   (check for `/tmp/.biome_path_${PPID}` existence after first edit)

6. **Semgrep session-scoped test**: Edit 3 TS files in a session.
   Verify Semgrep runs on the 3rd edit, scanning all 3 modified
   files. Verify it uses `.semgrep.yml` (not `--config auto`)

7. **Scanner overhead measurement**: With `biome_nursery: "warn"`
   (default) and `oxlint_tsgolint: false` (default), time
   `biome lint --reporter=json` on a TS file that triggers nursery
   type-aware rules (e.g., `noFloatingPromises`). Compare against
   a run with nursery disabled (`biome_nursery: "off"`). The
   difference is Scanner overhead. Update the Performance Budget
   table with measured values (estimated +50-200ms in this ADR)

---

## Appendix: Resolved Questions

The following questions were resolved during the clarification interview
on 2026-02-14. Their resolutions are incorporated into the relevant
decisions (D1-D17) above. Kept here for historical context and
alternative-options documentation.

### ~~Q1: Type Checking Strategy~~ (RESOLVED)

**Resolution**: Two-tool opt-in type safety strategy. (1) oxlint+tsgolint
for per-file blocking (45 type-aware rules, 2s timeout gate), (2) tsgo
for session-scoped advisory (full type checking after 3+ TS files). Both
default to `false`. See D3 for full rationale, research findings, and
four-layer type safety strategy (IDE → hooks fast → hooks complete → CI).

### ~~Q2: Biome.json Template Contents~~ (RESOLVED)

**Resolution**: Ship a static `biome.json` in the template. Users edit it
directly, like `.ruff.toml`. No dynamic generation.

**Template contents**:

```json
{
  "$schema": "https://biomejs.dev/schemas/2.3.11/schema.json",
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
      "recommended": true,
      "a11y": "error",
      "complexity": "warn",
      "correctness": "error",
      "performance": "warn",
      "security": "error",
      "style": "warn",
      "suspicious": "error",
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
| `rules.*` groups | All set to `"error"` or `"warn"` | Maximum opinionatedness — all stable groups enabled with appropriate severity. `"all": true` was changed in Biome v2; explicit group enablement is the v2-compatible approach |
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

**Known side-effect: `organizeImports` and CSS import order**: The
`assist.actions.source.organizeImports: "on"` setting runs during
Phase 1 (`biome check --write`) and may regroup side-effect CSS imports
(e.g., `import './reset.css'`), changing their cascade order. Projects
with order-dependent CSS imports should set `"organizeImports": "off"`
in biome.json or use `// biome-ignore organize-imports` inline.

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

**Template `.semgrep.yml`** (shipped with init process, version-controlled):

```yaml
rules:
  # 1. Code Injection: eval() / new Function()
  - id: cc-hooks-no-eval
    patterns:
      - pattern-either:
          - pattern: eval($X)
          - pattern: new Function(...)
    message: >
      Avoid eval() and new Function() — they execute arbitrary code from
      strings, enabling code injection attacks.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-94: Improper Control of Generation of Code"

  # 2. XSS: innerHTML / dangerouslySetInnerHTML
  - id: cc-hooks-no-inner-html
    patterns:
      - pattern-either:
          - pattern: $EL.innerHTML = $X
          - pattern: dangerouslySetInnerHTML={{__html: $X}}
    message: >
      Setting innerHTML or dangerouslySetInnerHTML with dynamic content
      enables XSS attacks. Use textContent or a sanitization library.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-79: Cross-site Scripting (XSS)"

  # 3. Hardcoded Secrets: API keys and tokens
  - id: cc-hooks-no-hardcoded-secret
    patterns:
      - pattern: |
          $VAR = "..."
      - metavariable-regex:
          metavariable: $VAR
          regex: (?i).*(secret|password|api_key|apikey|token|auth).*
    message: >
      Possible hardcoded secret in variable assignment. Use environment
      variables or a secrets manager instead.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-798: Use of Hard-coded Credentials"

  # 4. SQL Injection: string concatenation in queries
  - id: cc-hooks-no-sql-concat
    patterns:
      - pattern-either:
          - pattern: $DB.query(`...${$X}...`)
          - pattern: $DB.query("..." + $X + "...")
          - pattern: $DB.execute(`...${$X}...`)
    message: >
      SQL query built with string concatenation is vulnerable to injection.
      Use parameterized queries or an ORM.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-89: SQL Injection"

  # 5. Command Injection: child_process with user input
  - id: cc-hooks-no-command-injection
    patterns:
      - pattern-either:
          - pattern: exec($CMD)
          - pattern: execSync($CMD)
          - pattern: child_process.exec($CMD)
          - pattern: child_process.execSync($CMD)
    message: >
      exec()/execSync() spawn a shell and are vulnerable to command
      injection. Use execFile() or spawn() with argument arrays instead.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-78: OS Command Injection"

  # 6. Path Traversal: unsanitized file paths
  - id: cc-hooks-no-path-traversal
    patterns:
      - pattern-either:
          - pattern: fs.readFile($PATH, ...)
          - pattern: fs.readFileSync($PATH, ...)
          - pattern: fs.writeFile($PATH, ...)
          - pattern: fs.writeFileSync($PATH, ...)
      - metavariable-pattern:
          metavariable: $PATH
          patterns:
            - pattern-not: "..."
    message: >
      File operation with dynamic path may allow path traversal. Validate
      and sanitize file paths before use.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-22: Path Traversal"

  # 7. JWT Misuse: hardcoded secrets
  - id: cc-hooks-no-jwt-hardcoded-secret
    patterns:
      - pattern-either:
          - pattern: jwt.sign($DATA, "...", ...)
          - pattern: jwt.verify($DATA, "...", ...)
    message: >
      JWT signed/verified with a hardcoded string secret. Use environment
      variables or a key management service.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-798: Use of Hard-coded Credentials"
```

The rules are namespaced with `cc-hooks-` prefix and prioritize low
false-positive rates for a hook environment (conservative patterns,
no taint analysis which requires cross-file tracking). The local file
is version-controlled and protected via the PreToolUse hook (D14).

**Why broad rules are acceptable**: Semgrep runs as advisory-only
(session-scoped, non-blocking). Its output goes to `[hook:advisory]`
and does NOT trigger subprocess delegation. This means false positives
(e.g., `cc-hooks-no-command-injection` flagging legitimate `exec()`
calls in build scripts) surface awareness without causing automatic
code changes. This is fundamentally different from Biome rules, which
ARE blocking and DO trigger subprocess fixes. Broad advisory rules are
safe; broad blocking rules would not be.

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

**Resolution**: Init script (`scripts/init-typescript.sh`) for TypeScript
activation. Dependencies documented with all package managers. Manual
`npm install` step.

**Dependency matrix**:

| Tool | Install Method | Required? | Purpose |
| --- | --- | --- | --- |
| Biome | `npm i -D @biomejs/biome` | Required | Lint + format (TS/JS/CSS/JSON) |
| oxlint+tsgolint | `npm i -D oxlint oxlint-tsgolint` | Optional (opt-in) | 45 type-aware lint rules (per-file blocking) |
| Semgrep | `brew install semgrep` or `pip install semgrep` | Optional (runs if installed) | Security scanning |
| Knip | `npm i -D knip` | Optional (CI-recommended) | Dead code detection (off in hooks by default) |
| tsgo | `npm i -g @typescript/native-preview` | Optional (opt-in) | Full type checking (session-scoped advisory) |
| jscpd | `npx jscpd` (no install) | Optional | Duplicate detection (existing) |
| jaq | `brew install jaq` | Required | JSON parsing (existing) |

**Init process**: `scripts/init-typescript.sh`

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
  npm i -D oxlint oxlint-tsgolint  (type-aware lint, 45 rules per-file)
  npm i -g @typescript/native-preview  (full type checking, session advisory)
  brew install semgrep   (security scanning)
  pip install semgrep    (alternative install method)
  npm i -D knip          (dead code detection, CI-recommended)
```

**Key design choices**:

| Choice | Decision | Rationale |
| --- | --- | --- |
| Init script | `scripts/init-typescript.sh` | No Makefile dependency, consistent with bash-based hook system, won't conflict with project Makefiles |
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
    "@biomejs/biome": "^2.3.0"
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
| 17 | oxlint: type-aware violation | `const x: any = 1; fn(x)` (unsafe argument) | Exit 2 (oxlint reports) | `HOOK_SKIP_SUBPROCESS=1` + `oxlint_tsgolint: true` |
| 18 | oxlint: disabled (default) | Same file, `oxlint_tsgolint: false` | Exit 0 (Biome only) | `HOOK_SKIP_SUBPROCESS=1` |
| 19 | oxlint: timeout gate | Large file triggering >2s | Exit 0 + warning (timeout) | `HOOK_SKIP_SUBPROCESS=1` + `oxlint_tsgolint: true` |
| 20 | tsgo: session advisory | 4th TS file modified, type error | `[hook:advisory]` with tsgo output | `HOOK_SKIP_SUBPROCESS=1` + `tsgo: true` |
| 21 | tsgo: disabled (default) | 4th TS file, `tsgo: false` | No tsgo output | `HOOK_SKIP_SUBPROCESS=1` |

**Test helpers**: Uses existing `test_temp_file()`, `test_existing_file()`,
`test_output_format()`, and `test_model_selection()` helpers from
`test_hook.sh`. TypeScript tests follow identical patterns to the existing
Python and Dockerfile tests.

**Tool dependencies**: Tests require Biome installed. If Biome is not
found, TS-specific tests skip with a warning (not a failure), matching the
existing graceful degradation pattern. Semgrep and Knip tests are skipped
if those tools are not installed (advisory tools are optional).
oxlint+tsgolint tests (17-19) require oxlint and oxlint-tsgolint
installed and `oxlint_tsgolint: true` in config — skip with warning if
not available. tsgo tests (20-21) require @typescript/native-preview
installed and `tsgo: true` — skip with warning if not available.

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
# Expected: 14 existing + 21 new TS tests = 35 total, all pass

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
| oxlint without oxlint? | Skip with warning | Optional tool; same graceful degradation pattern |
| tsgo without tsgo? | Skip with warning | Optional tool; same graceful degradation pattern |
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

---

## References

- [Biome Linter Overview (official rule count: 436)](https://biomejs.dev/linter/)
- [Biome JavaScript Rules (nursery count)](https://biomejs.dev/linter/javascript/rules/)
- [Biome v2 Announcement (75% noFloatingPromises figure)](https://biomejs.dev/blog/biome-v2/)
- [Biome v2.1 Announcement](https://biomejs.dev/uk/blog/biome-v2-1)
- [Biome v2.3 Announcement (Vue/Svelte/Astro support)](https://biomejs.dev/blog/biome-v2-3/)
- [Biome 2026 Roadmap](https://biomejs.dev/blog/roadmap-2026/)
- [Biome useExhaustiveDependencies Rule](https://biomejs.dev/linter/rules/use-exhaustive-dependencies/)
- [Biome Linter Domains Documentation](https://biomejs.dev/linter/domains/)
- [Biome useRegexpExec Rule Documentation](https://biomejs.dev/linter/rules/use-regexp-exec/)
- [Biome CSS Rules](https://biomejs.dev/linter/css/rules/)
- [Biome CSS Rules Sources (Stylelint ported rules)](https://biomejs.dev/linter/css/sources)
- [Biome Type-Aware Linter Umbrella Issue #3187](https://github.com/biomejs/biome/issues/3187)
- [Biome Stylelint Rules Tracking Issue #2511](https://github.com/biomejs/biome/issues/2511)
- [Biome Differences with Prettier](https://biomejs.dev/formatter/differences-with-prettier/)
- [Biome Official Pre-commit Hooks](https://github.com/biomejs/pre-commit)
- [Biome Benchmark Suite](https://github.com/biomejs/biome/blob/main/benchmark/README.md)
- [Biome Reporters Documentation](https://biomejs.dev/reference/reporters/)
- [Biome Configuration Reference](https://biomejs.dev/reference/configuration/)
- [typescript-eslint Rules Overview](https://typescript-eslint.io/rules/)
- [Deno Lint Rules List](https://docs.deno.com/lint/)
- [TypeScript Native Port Announcement](https://devblogs.microsoft.com/typescript/typescript-native-port/)
- [TypeScript Native Preview (tsgo) npm package](https://www.npmjs.com/package/@typescript/native-preview)
- [TypeScript 7.0 Guide (tsgo test parity)](https://picode.bunnode.com/blog/typescript-7-ultimate-guide)
- [Progress on TypeScript 7 (December 2025)](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)
- [Oxfmt Alpha Announcement (Dec 2025)](https://oxc.rs/blog/2025-12-01-oxfmt-alpha.html)
- [Oxlint v1.0 Stable Announcement (VoidZero)](https://voidzero.dev/posts/announcing-oxlint-1-stable)
- [Oxlint Type-Aware Linting Announcement (VoidZero)](https://voidzero.dev/posts/announcing-oxlint-type-aware-linting)
- [Oxlint Benchmark Repository](https://github.com/oxc-project/bench-linter)
- [Oxlint Type-Aware Linting Rules](https://oxc.rs/docs/guide/usage/linter/rules)
- [tsgolint GitHub Repository](https://github.com/oxc-project/tsgolint)
- [Rslint GitHub Repository](https://github.com/web-infra-dev/rslint)
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
- [Biome v2.3.15 Release (noNestedPromises)](https://github.com/biomejs/biome/releases)
- [Oxlint v1.0 InfoQ Coverage (520+ rules)](https://www.infoq.com/news/2025/08/oxlint-v1-released/)
- [Oxlint Type-Aware Linting (Cloudflare investigation, 45 of 59 rules)](https://github.com/cloudflare/agents/issues/862)
- [tsgolint v0.12.0 Release Notes](https://newreleases.io/project/github/oxc-project/tsgolint/release/v0.12.0)
- [Deno 2.2 Release Blog (123 built-in lint rules)](https://deno.com/blog/v2.2)
- [Rslint Announcement (Socket.dev)](https://socket.dev/blog/rspack-introduces-rslint-a-typescript-first-linter-written-in-go)
- [Effective TypeScript - Knip recommendation](https://effectivetypescript.com/2023/07/29/knip/)
