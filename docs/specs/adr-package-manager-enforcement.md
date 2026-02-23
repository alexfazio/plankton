# ADR: Package Manager Enforcement via PreToolUse Hook

**Status**: Accepted
**Date**: 2026-02-16
**Author**: alex fazio + Claude Code clarification interview

**Note**: This ADR includes implementation-level detail (regex patterns,
bash code, processing flow) because these ARE the core architectural
decisions. The choices of regex dialect, elif vs. if control flow, and
word boundary strategy directly embody decisions D3, D4, and D7.

## Context and Problem Statement

Claude Code sessions frequently use `pip`, `npm`, `yarn`, or `pnpm` for
package management instead of the project's preferred toolchain (`uv` for
Python, `bun` for JS/TS). This creates inconsistent lockfiles, mixed
dependency trees, and slower installations. There is no enforcement
mechanism to prevent Claude from defaulting to the ecosystem-standard
tools rather than the project-preferred alternatives.

Claude defaults to widely-known package managers (`pip install`,
`npm install`) unless explicitly instructed otherwise. CLAUDE.md
instructions alone are insufficient because Claude may not always follow
soft guidance, especially in long sessions or after context compaction.
The existing hook architecture only enforces linter config protection
(PreToolUse) and code quality (PostToolUse), but has no Bash command
interception for package manager enforcement.

## Decision Drivers

- **Consistency**: One lockfile format, one dependency tree, one installer
  per ecosystem
- **Performance**: `uv` is 10-100x faster than pip; `bun` is significantly
  faster than npm
- **Existing patterns**: Follow the established PreToolUse block+message
  pattern from `protect_linter_configs.sh`
- **Configurability**: All enforcement controllable via `config.json`
  (existing configuration pattern)
- **Graceful degradation**: Enforcement can be disabled per ecosystem
- **Compound command safety**: Must catch package managers inside compound
  commands (`cd foo && pip install bar`)

## Decisions

### D1: Hook Type - PreToolUse with Bash Matcher

**Decision**: Use a PreToolUse hook with `"matcher": "Bash"` to intercept
commands before execution.

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **PreToolUse Bash** | Prevents wrong command | New settings entry | **Yes** |
| **Stop hook** | Simpler lifecycle | Damage done (lockfiles, env) | No |
| **CLAUDE.md only** | Zero effort | Soft, ignored in long sessions | No |
| **PostToolUse Bash** | Detect after | Too late, side effects done | No |

**Rationale**: The Stop hook pattern (detect-then-recover) does not fit
because by session end, `pip install` has already polluted the environment,
created wrong lockfiles, and installed into the wrong location. Prevention
is the correct strategy, matching the existing defense pattern: PreToolUse
for prevention (`protect_linter_configs.sh`), Stop for recovery
(`stop_config_guardian.sh`).

### D2: Enforcement Mode - Block by Default, Warn via Config

**Decision**: Block the command and suggest the correct replacement in the
error message. Do not attempt to auto-rewrite the command. Configurable
warn mode is available via the `:warn` config suffix for migration
scenarios.

**Three-position enforcement model**:

| Config Value | Behavior | Use Case |
| --- | --- | --- |
| `"uv"` | Block (command prevented, replacement suggested) | Steady state |
| `"uv:warn"` | Warn (command proceeds, advisory on stderr) | Migration |
| `false` | Off (no enforcement) | Ecosystem not applicable |

Block is the **default and recommended** mode. The `:warn` suffix is
opt-in for teams transitioning to uv/bun who want visibility before
commitment.

**Rationale for block as default**:

1. Command flag mapping between package managers is non-trivial
   (`npm install` flags do not all 1:1 map to `bun add` equivalents
   — e.g., `--save-optional`, `--save-peer` behave differently)
2. Silent rewriting could produce subtly wrong commands
3. The agent has full context to reformulate correctly after receiving
   the block message
4. Matches the existing config protection hook philosophy: "Fix the code,
   not the rules" becomes "Use the right tool, don't rewrite the wrong one"

**Agent-vs-human caveat for warn mode**: Warn mode works differently for
AI agents than for human developers. A human sees a warning and exercises
judgment before the next command. An AI agent (Claude) receives the
warning in context, but the current command **already executed** — the
lockfile damage already happened. The warning only helps if Claude
modifies behavior in subsequent commands. For this reason, warn mode for
package managers should be treated as a **time-bounded migration tool**,
not permanent enforcement. Industry precedent (ESLint, typescript-eslint)
confirms that warnings as permanent enforcement are an anti-pattern due
to habituation — teams (and agents) stop responding to warnings that
never block progress.

**Warn mode time-boxing recommendation**: Since warn mode allows
commands to execute (causing lockfile damage before the advisory is
processed), and since industry precedent (ESLint, typescript-eslint)
confirms that warnings as permanent enforcement are an anti-pattern due
to habituation, teams should treat warn mode as a bounded migration
tool. When enabling `:warn`, set a specific deadline (e.g., 2 sprints
or 30 days) and create a tracking item (Linear issue, calendar event)
to escalate to block mode. Do not leave warn mode enabled indefinitely.

**Warn mode behavioral contract**: When enforcement mode is `warn`, the
hook outputs `{"decision": "approve"}` (allowing the command) and writes
an advisory to stderr using the same `[hook:advisory]` prefix as the
CLI tool preferences hook. The replacement command suggestion is included
in the advisory message. This matches the warn infrastructure in
[ADR: CLI Tool Preference Warnings](adr-cli-tool-preference-warnings.md).

### D3: Python Enforcement Scope

**Decision**: Block `pip`, `pip3`, `python -m pip`, `python -m venv`,
`poetry`, and `pipenv`. Allow `uv pip` passthrough since `uv pip install`
is a valid uv command (pip compatibility mode).

**Commands blocked**:

| Blocked Command | Suggested Replacement | Notes |
| --- | --- | --- |
| `pip install <pkg>` | `uv add <pkg>` | Direct replacement |
| `pip install -r reqs.txt` | `uv pip install -r reqs.txt` | uv compat |
| `pip3 install <pkg>` | `uv add <pkg>` | pip3 alias |
| `python -m pip install <pkg>` | `uv add <pkg>` | Module invocation |
| `python -m venv .venv` | `uv venv` | Significantly faster |
| `poetry <any>` | `uv` equivalents | Blanket block (all subcommands) |
| `pipenv <any>` | `uv` equivalents | Blanket block (all subcommands) |
| `pip install -e .` | `uv pip install -e .` | Editable install |
| `pip freeze` | `uv pip freeze` | Read-only (still blocked) |
| `pip list` | `uv pip list` | Read-only (still blocked) |

**All pip subcommands are blocked** unless prefixed by `uv` or listed in the
configurable `allowed_subcommands.pip` allowlist (see D9). By default, only
`pip download` is allowlisted because it has no `uv` equivalent
(tracked in [astral-sh/uv#3163](https://github.com/astral-sh/uv/issues/3163)).
Read-only commands like `pip freeze` and `pip list` are blocked because
`uv pip freeze` and `uv pip list` are direct replacements with identical
output.

**Poetry and pipenv are blanket-blocked**: All subcommands are blocked by
default (empty allowlist in `allowed_subcommands.poetry` and
`allowed_subcommands.pipenv`). This is simpler and more secure than
enumerating specific subcommands — `poetry show`, `poetry env use`, and
any future subcommands are all caught. Specific exceptions can be added
to the allowlist arrays in `config.json` if needed.

**Allowed (not blocked)**:

| Command | Why Allowed |
| --- | --- |
| `uv pip install` | Valid uv command (pip compatibility mode) |
| `uv add`, `uv sync`, `uv run` | Preferred toolchain |
| `source .venv/bin/activate` | Activation is fine; creation goes through uv |
| `python script.py` | Runtime, not package management |
| `pip download` | Allowlisted — no uv equivalent ([#3163](https://github.com/astral-sh/uv/issues/3163)) |

**Matching strategy**: Uses conditional bash matching — check for `uv pip`
prefix first (passthrough), then check for bare `pip`/`pip3`. Word
boundaries use POSIX ERE character classes, not PCRE `\b` (which is
unavailable in bash `=~` on macOS). See "Regex Patterns" section for
portable implementation.

### D4: JavaScript Enforcement Scope

**Decision**: Block ALL npm, npx, yarn, and pnpm commands except a
configurable allowlist of npm-registry-specific subcommands.

**Commands blocked**:

| Blocked Command | Suggested Replacement |
| --- | --- |
| `npm install` / `npm i` / `npm ci` | `bun install` or `bun add <pkg>` |
| `npm run <script>` | `bun run <script>` |
| `npm test` | `bun test` |
| `npm start` | `bun run start` |
| `npm exec` / `npx <pkg>` | `bunx <pkg>` |
| `npm init` | `bun init` |
| `npm uninstall` / `npm remove` | `bun remove` |
| `yarn <subcommand>` (except audit, info) | bun equivalents |
| `pnpm <subcommand>` (except audit, info) | bun equivalents |

**Rationale for blocking script runners** (`npm run`, `npm test`,
`npm start`): If you are standardizing on bun, partial enforcement creates
confusion about which npm commands are acceptable. `bun run`, `bun test`
are direct replacements. Consistent enforcement is simpler to reason about.

**npm registry allowlist** (configurable in `allowed_subcommands.npm`,
see D9):

| Allowed Subcommand | Bun Equivalent | Status |
| --- | --- | --- |
| `npm audit` | `bun audit` (v1.2.15) | Bun equivalent available |
| `npm view` | `bun info` / `bun pm view` | Bun equivalent available |
| `npm pack` | `bun pm pack` (v1.1.27) | Bun equivalent available |
| `npm publish` | `bun publish` | Bun equivalent available |
| `npm whoami` | `bun pm whoami` (v1.1.30) | Bun equivalent available |
| `npm login` | — | No bun equivalent |

These commands do not affect the dependency tree — they are
registry/metadata operations. Five of six now have bun equivalents
(bun pm pack since v1.1.27, bun publish since v1.1.30, bun pm whoami
since v1.1.30, bun audit since v1.2.15, bun pm view since v1.2.15),
but the allowlist is kept as-is because:
(1) bun equivalents are recent and may have edge cases, (2) allowing
registry operations doesn't violate the core enforcement goal, (3)
shrinking is easy when bun matures, expanding after a bug is disruptive.
As of this writing, bun is at v1.3.9 (not yet 2.x). Several open issues
affect the bun equivalents of allowlisted npm commands: no `audit fix`
equivalent ([#20238](https://github.com/oven-sh/bun/issues/20238)),
`bun publish` fails in CI authentication
([#24124](https://github.com/oven-sh/bun/issues/24124)) and with custom
registries ([#18670](https://github.com/oven-sh/bun/issues/18670)), and
there is no `bun login` equivalent. Two issues have been resolved since
the initial draft: `bun audit` hanging indefinitely
([#20800](https://github.com/oven-sh/bun/issues/20800), closed
2025-09-09) and `bun pm pack` ignoring prepack scripts
([#24314](https://github.com/oven-sh/bun/issues/24314), closed
2026-01-23). Review the allowlist at Q4 2026 or when bun reaches 2.x
stable (whichever comes first), focusing on audit fix, publish CI auth,
and custom registry support.

**yarn/pnpm registry allowlist** (configurable in `allowed_subcommands.yarn`
and `allowed_subcommands.pnpm`, see D9): `yarn audit`, `yarn info`,
`pnpm audit`, and `pnpm info` are allowed by default for registry
inspection. Bare `yarn` and bare `pnpm` (no subcommand) are blocked
because they are equivalent to `yarn install` and `pnpm install`
respectively.

### D5: npx and Internal Hook Usage

**Decision**: npx is blocked for Claude's Bash tool invocations. Internal
hook usage of npx (e.g., `npx jscpd` in `multi_linter.sh`) is unaffected.

**Rationale**: Hook scripts run as bash processes outside of Claude's Bash
tool. The PreToolUse hook only fires on Claude's own Bash tool invocations
via the Claude Code hook lifecycle, not on shell commands within hook
scripts. The subprocess also uses `--settings subprocess-settings.json`
which disables hooks entirely. Internal npx usage in hooks is inherently
safe from this enforcement.

### D6: Runtime Scope - Package Managers Only

**Decision**: Do not block `node` runtime invocations. Only block package
manager commands.

**Alternatives considered**: Blocking `node script.js` in favor of
`bun script.js` for runtime performance.

**Rationale**: `node` appears in too many legitimate contexts
(`node --version`, shebang lines, debugging). The benefit of
bun-as-runtime is speed (nice-to-have), while package manager enforcement
is about consistency (lockfile format, dependency tree - a correctness
concern). The risk-to-benefit ratio for runtime enforcement is too high.

### D7: Compound Command Handling

**Decision**: Scan the entire `tool_input.command` string using substring
matching with word boundaries. Do not only check the first command in a
pipeline or chain.

**Rationale**: Claude frequently generates compound commands like:

```bash
cd /path && pip install -r requirements.txt
if ! pip list | grep pkg; then pip install pkg; fi
npm install && npm run build
```

Checking only the first command is trivially bypassable. False positives
from substrings are handled with word boundary matching via POSIX ERE
character classes (see "Regex Patterns" section).

**Known limitations**: Full command string scanning may produce false
positives in these edge cases:

- Here-docs: `cat <<EOF\npip install foo\nEOF` — blocked even though
  `cat` is the actual command
- Comments: `# pip install foo` — blocked even though it's a comment
- Quoted strings: `echo "pip install foo"` — blocked even though it's
  a string literal
- Variable assignments: `PKG_MGR=pip` — blocked (false positive: the
  bare pip regex matches `pip` after `=` since `=` is not in `[a-zA-Z0-9_]`)
- ~~Cross-tool Python diagnostic compound~~ (resolved in 2026-02
  restructure): `pip --version && poetry add requests` previously
  approved because the pip diagnostic no-op exited the elif chain
  before poetry was checked. Poetry and pipenv now use independent
  if blocks, so cross-tool compounds are caught (including
  `pip --version && pipenv install`). The `uv pip`
  passthrough remains (see D7 warn-mode compound behavior).

These are accepted trade-offs. In practice, Claude rarely generates
commands with package manager names in comments or here-docs. The
pragmatic substring approach catches 99%+ of real cases.

- **Warn mode compound behavior**: In warn mode, `warn()` calls `exit 0`
  — same as `block()`. For compound commands like `pip install && npm install`,
  only the first match emits a warning; subsequent violations in the same
  command execute silently. In block mode, the entire command is prevented
  and Claude retries (hitting the next violation). In warn mode, all parts
  of the compound command execute but only one advisory is emitted. This is
  accepted because: (1) warn mode is advisory-only, (2) the first warning
  signals the project's toolchain preference, (3) cross-ecosystem compound
  commands are rare in practice.

- **Shell variable expansion evasion**: `cmd=pip; $cmd install requests`
  evades detection because `$cmd` is not expanded at the regex level.
  Accepted: the hook prevents unintentional use of wrong package managers,
  not adversarial evasion. Claude does not generate variable-indirection
  patterns for package management.

**Compound command behavior**: When a command contains multiple package
manager violations (e.g., `pip install && npm install`), the hook blocks on
the first match and returns immediately. Claude retries and hits the second
violation on the next attempt. This is consistent with
`protect_linter_configs.sh` (which returns immediately on first path match)
and avoids the complexity of multi-error collection in a PreToolUse hook.

### D8: Message Style

**Decision**: Adopt the `[hook:]` message prefix style used by
`multi_linter.sh`, extending it with a new `block` severity level.

**Format**:

```text
[hook:block] pip is not allowed. Use: uv add <packages>
```

Where:

- `[hook:block]` prefix extends `[hook:]` conventions (new severity
  for PreToolUse blocks)
- The blocked tool name is stated
- The specific replacement command is provided (computed from the
  blocked command, not just the tool name)
- Message is concise (single line when possible)

**Replacement command specificity**: The block message includes the
specific replacement command computed from the blocked command. For
example:

- `pip install requests flask` -> `Use: uv add requests flask`
- `pip install -r requirements.txt` ->
  `Use: uv pip install -r requirements.txt`
- `npm install lodash` -> `Use: bun add lodash`
- `npx create-react-app` -> `Use: bunx create-react-app`

**Warn message format**: When enforcement mode is `warn`, the advisory
uses different framing — "detected/prefer" instead of "not allowed/use":

```text
[hook:advisory] pip detected. Prefer: uv add requests flask
[hook:advisory] npm detected. Prefer: bun add lodash
[hook:advisory] npx detected. Prefer: bunx create-react-app
```

The `[hook:advisory]` prefix matches the CLI tool preferences hook
(see [ADR: CLI Tool Preference Warnings](adr-cli-tool-preference-warnings.md)).
The mode-aware framing ensures warn messages are factually accurate — pip
IS allowed in warn mode, so "not allowed" would be incorrect.

### D9: Configuration Design

**Decision**: Top-level `package_managers` key in `config.json` with
lightweight toggles (not a full command mapping).

**Schema**:

```json
{
  "package_managers": {
    "python": "uv",
    "javascript": "bun",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
```

**Note on value types**: The `package_managers` section uses string
values (`"uv"`, `"bun"`) while the `languages` section uses booleans
(`true`/`false`). In `package_managers`, `"python": false` disables
enforcement; in `languages`, `"python": false` disables linting. The
string value serves dual purpose: enables enforcement AND names the
replacement tool used in block messages.

**Toggle behavior**:

- `"python": "uv"` — enforce uv, block pip/poetry/pipenv
- `"python": "uv:warn"` — enforce uv, warn on pip/poetry/pipenv (advisory only)
- `"python": false` — disable Python package manager enforcement
- `"javascript": "bun"` — enforce bun, block npm/yarn/pnpm
- `"javascript": "bun:warn"` — enforce bun, warn on npm/yarn/pnpm (advisory only)
- `"javascript": false` — disable JS package manager enforcement

**Enforcement mode parsing**: The `:warn` suffix is stripped to extract
the replacement tool name. `"uv:warn"` → tool=`uv`, mode=`warn`.
`"uv"` → tool=`uv`, mode=`block` (default). `false` → mode=`off`.

```bash
parse_pm_config() {
  local value="$1"
  case "${value}" in
    false) echo "off" ;;
    *:warn) echo "warn:${value%:warn}" ;;
    *) echo "block:${value}" ;;
  esac
}
# "uv"      → "block:uv"
# "uv:warn" → "warn:uv"
# false      → "off"
```

**Allowlist behavior**: The `allowed_subcommands` object provides a
unified configurable allowlist for every blocked tool. Each key maps a
tool name to an array of allowed subcommands. An empty array (`[]`)
means blanket block (no exceptions). When a blocked tool's subcommand
appears in its allowlist, the hook approves the command. Every tool
follows the same enforcement pattern: extract subcommand → check
allowlist → block if not found.

**Unified helper function**:

```bash
is_allowed_subcommand() {
  local tool="$1" subcmd="$2"
  local allowed
  while IFS= read -r allowed; do
    [[ "${subcmd}" == "${allowed}" ]] && return 0
  done < <(jaq -r ".package_managers.allowed_subcommands.${tool} // [] | .[]" \
    "${config_file}" 2>/dev/null)
  return 1
}
```

```bash
approve() {
  echo '{"decision": "approve"}'
  exit 0
}

block() {
  local tool="$1" subcmd="${2:-}"
  local replacement
  replacement=$(compute_replacement_message "${tool}" "${subcmd}")
  echo "{\"decision\": \"block\", \"reason\": \"[hook:block] ${tool} is not allowed. Use: ${replacement}\"}"
  exit 0
}
```

```bash
warn() {
  local tool="$1" subcmd="${2:-}"
  local replacement
  replacement=$(compute_replacement_message "${tool}" "${subcmd}")
  echo '{"decision": "approve"}'
  echo "[hook:advisory] ${tool} detected. Prefer: ${replacement}" >&2
  exit 0
}
```

```bash
enforce() {
  local mode="$1" tool="$2" subcmd="${3:-}"
  if [[ "${mode}" == "warn" ]]; then
    warn "${tool}" "${subcmd}"
  else
    block "${tool}" "${subcmd}"
  fi
}
```

```bash
# Pseudocode — maps tool+subcmd to replacement command string
# See "Replacement Command Computation" table for full mapping
compute_replacement_message() {
  local tool="$1" subcmd="${2:-}"
  case "${tool}:${subcmd}" in
    pip:install|pip3:install)
      # If command contains -r → "uv pip install -r <file>"
      # If command contains -e → "uv pip install -e ."
      # Otherwise → "uv add <packages>" ;;
    pip:uninstall)   echo "uv remove <packages>" ;;
    pip:freeze)      echo "uv pip freeze" ;;
    pip:list)        echo "uv pip list" ;;
    pip:*)           echo "uv <equivalent>" ;;
    "python -m pip":*) echo "uv add <packages>" ;;
    "python -m venv":*) echo "uv venv" ;;
    npm:install|npm:i|npm:ci) echo "bun add <pkg> or bun install" ;;
    npm:run)         echo "bun run <script>" ;;
    npm:test)        echo "bun test" ;;
    npm:start)       echo "bun run start" ;;
    npm:exec)        echo "bunx <pkg>" ;;
    npm:init)        echo "bun init" ;;
    npm:*)           echo "bun <equivalent>" ;;
    npx:*)           echo "bunx <pkg>" ;;
    poetry:add)      echo "uv add <packages>" ;;
    poetry:install)  echo "uv sync" ;;
    poetry:run)      echo "uv run <cmd>" ;;
    poetry:lock)     echo "uv lock" ;;
    poetry:*)        echo "uv <equivalent>" ;;
    pipenv:install)  echo "uv add <pkg> or uv sync" ;;
    pipenv:run)      echo "uv run <cmd>" ;;
    pipenv:*)        echo "uv <equivalent>" ;;
    yarn:add)        echo "bun add <packages>" ;;
    yarn:install)    echo "bun install" ;;
    yarn:run)        echo "bun run <script>" ;;
    yarn:*)          echo "bun <equivalent>" ;;
    pnpm:add)        echo "bun add <packages>" ;;
    pnpm:install)    echo "bun install" ;;
    pnpm:run)        echo "bun run <script>" ;;
    pnpm:*)          echo "bun <equivalent>" ;;
  esac
}
```

**Helper functions**: `approve()` outputs approve JSON and exits. `block()`
and `warn()` both call `compute_replacement_message()` to get the
replacement command, then frame it differently — block says "X is not
allowed. Use: Y", warn says "X detected. Prefer: Y". This mode-aware
framing is consistent with the CLI tool preferences ADR tone (see
[ADR: CLI Tool Preference Warnings](adr-cli-tool-preference-warnings.md)).
`enforce()` dispatches to `block()` or `warn()` based on the parsed mode
from `parse_pm_config()` (see D9). `compute_replacement_message()` maps
tool+subcmd pairs to replacement command strings per the Replacement
Command Computation table.

**Rationale**: The actual blocked patterns and suggestion messages stay
hardcoded in the script (domain knowledge). Config controls enforcement
toggles and per-tool subcommand exemptions. This unifies three prior
patterns into one: npm had a configurable allowlist
(`npm_allowed_subcommands`), yarn/pnpm had hardcoded `case` statements,
and pip/poetry/pipenv had no allowlist mechanism. Now all six tools use
the same `is_allowed_subcommand()` helper with config-driven arrays.

**Design note — config value types**: The `package_managers` section uses
string values (`"uv"`, `"bun"`) rather than the boolean toggles used in
`languages` (e.g., `"python": true`). This is intentional: the string
value serves a dual purpose — it enables enforcement AND names the
replacement tool used in block messages. `false` disables enforcement.
The accessor pattern differs from `is_language_enabled()`:

```bash
get_pm_enforcement() {
  local lang="$1"
  jaq -r ".package_managers.${lang} // false" \
    "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json" 2>/dev/null
}
# Returns "uv", "bun", or "false"
```

### D10: Default State

**Decision**: Enabled by default in the template.

**Rationale**: Unlike TypeScript support (which requires Biome installation
and is opt-in), package manager enforcement has no external dependencies.
It only requires that the user has `uv` and/or `bun` installed, which is
a prerequisite for the project's intended workflow. Users who do not want
enforcement can set `"python": false` or `"javascript": false`.

The template ships with `"python": "uv"` and `"javascript": "bun"` in
`config.json`. If the `package_managers` key is absent or the config file
is missing, enforcement is disabled (fail-open via `// false` jaq
fallback), consistent with the script's fail-safe philosophy. "Enabled by
default" refers to the template's shipped configuration, not to hardcoded
script behavior.

### Prerequisites for Adoption

Before enabling enforcement, the following should be true:

- **Python**: `uv` installed and available in PATH (`brew install uv` or
  `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- **JavaScript**: `bun` installed and available in PATH
  (`curl -fsSL https://bun.sh/install | bash`)
- **Python projects**: Should have been initialized with `uv init` or
  have a `pyproject.toml`. Existing `requirements.txt`-only projects
  should migrate lockfiles before enabling enforcement
- **JS projects**: Should have `bun.lock` (or legacy `bun.lockb`) or be
  ready to generate one via `bun install`
- **jaq**: `jaq` (a jq clone written in Rust) installed and available in
  PATH (`brew install jaq` or `cargo install jaq`). Required for JSON parsing
  of stdin input and config.json. If jaq is missing, the hook fails open
  (approves all commands)
- **Fallback**: If prerequisites are not met, the replacement tool
  existence check (see "Replacement Tool Existence Check" section)
  warns on first blocked command that the replacement is unavailable.
  Enforcement still blocks — it does not fall back to allowing pip/npm

### D11: Architecture - Separate Script File

**Decision**: Create a new file `.claude/hooks/enforce_package_managers.sh`,
registered as a separate PreToolUse entry in `.claude/settings.json` with
`"matcher": "Bash"`.

**Alternatives considered**: Combining with
`protect_linter_configs.sh` in a single script.

**Rationale**: A combined PreToolUse script will not work cleanly because
the matchers are different. `protect_linter_configs.sh` matches
`Edit|Write`; the new hook needs to match `Bash`. Separate entries in
`settings.json` are required regardless. Benefits of separation:

1. Independent testing (can test package manager logic in isolation)
2. Independent disabling (can remove one hook without affecting the other)
3. Separation of concerns (file protection vs command interception)
4. Cleaner codebase (each script has a single responsibility)

### D12: Testing Strategy

**Decision**: Full self-test coverage added to `test_hook.sh` covering
all enforcement scenarios.

**Test cases required** (implemented via a new `test_bash_command()` helper
in `test_hook.sh` that handles: JSON with `tool_input.command`, stdout
capture for decision JSON, stderr capture for advisories, temp `config.json`
via `CLAUDE_PROJECT_DIR` override, and PATH mocking for replacement tool
existence checks):

| Test | Input | Expected |
| --- | --- | --- |
| pip install blocked | `pip install requests` | block + suggest `uv add` |
| pip3 blocked | `pip3 install flask` | block |
| python -m pip blocked | `python -m pip install pkg` | block |
| python3 -m pip blocked | `python3 -m pip install pkg` | block |
| python -m venv blocked | `python -m venv .venv` | block + suggest `uv venv` |
| poetry blocked | `poetry add requests` | block |
| pipenv blocked | `pipenv install` | block |
| uv pip passthrough | `uv pip install -r req.txt` | approve |
| uv add passthrough | `uv add requests` | approve |
| npm install blocked | `npm install lodash` | block + suggest `bun add` |
| npm run blocked | `npm run build` | block + suggest `bun run` |
| npx blocked | `npx create-react-app` | block + suggest `bunx` |
| yarn blocked | `yarn add lodash` | block |
| pnpm blocked | `pnpm install` | block |
| npm audit allowed | `npm audit` | approve (allowlisted) |
| npm view allowed | `npm view lodash` | approve (allowlisted) |
| compound pip | `cd /app && pip install flask` | block |
| compound npm | `npm install && npm run build` | block |
| bun passthrough | `bun add lodash` | approve |
| bunx passthrough | `bunx vite` | approve |
| python disabled | `pip install` (python: false) | approve |
| javascript disabled | `npm install` (javascript: false) | approve |
| pip freeze blocked | `pip freeze` | block + suggest `uv pip freeze` |
| pip list blocked | `pip list` | block + suggest `uv pip list` |
| pip editable blocked | `pip install -e .` | block + suggest uv pip |
| jaq missing | `pip install` (jaq unavailable) | approve (fail-open) |
| non-package cmd | `ls -la` | approve |
| bare yarn blocked | `yarn` | block (bare = install) |
| bare pnpm blocked | `pnpm` | block (bare = install) |
| yarn audit allowed | `yarn audit` | approve (allowlisted) |
| yarn info allowed | `yarn info lodash` | approve (allowlisted) |
| pnpm audit allowed | `pnpm audit` | approve (allowlisted) |
| pnpm info allowed | `pnpm info lodash` | approve (allowlisted) |
| npm audit+yarn bypass | `npm audit && yarn add lodash` | block (yarn) |
| npm flags before subcmd | `npm -g install foo` | block |
| npm --registry flag | `npm --registry=... install foo` | block |
| bare npm | `npm` | block |
| poetry show blocked | `poetry show` | block (blanket) |
| poetry env blocked | `poetry env use 3.11` | block (blanket) |
| bare poetry blocked | `poetry` | block (blanket) |
| pipenv graph blocked | `pipenv graph` | block (blanket) |
| pip download allowed | `pip download requests` | approve (allowlisted) |
| pip download -d allowed | `pip download -d ./pkgs requests` | approve |
| cross-ecosystem compound | `pip install && npm install` | block (pip first) |
| uv + pip compound | `uv pip install && pip install` | approve (elif) |
| npm --version diag | `npm --version` | approve (diagnostic) |
| pip --version diag | `pip --version` | approve (diagnostic) |
| poetry --help diag | `poetry --help` | approve (diagnostic) |
| npm --version compound | `npm --version && npm install` | block (install) |
| npm flag+allowlist | `npm --registry=url audit` | approve (flag+allowlisted) |
| npm -g install | `npm -g install foo` | block (flag+blocked subcmd) |
| pip diag+poetry compound | `pip --version && poetry add` | block (poetry) |
| pipenv compound | `pipenv --version && pipenv install` | block (same-tool) |
| pip+pipenv compound | `pip --version && pipenv install` | block (pipenv) |
| poetry diag+add compound | `poetry --help && poetry add` | block (poetry) |
| uv missing warning | `pip install` (uv not in PATH) | block + stderr warning |
| bun missing warning | `npm install` (bun not in PATH) | block + warning |
| debug mode output | `pip install` (HOOK_DEBUG_PM=1) | block + stderr debug |
| HOOK_SKIP_PM bypass | `pip install` (HOOK_SKIP_PM=1) | approve |
| pip warn mode | `pip install` (python: "uv:warn") | approve + advisory |
| npm warn mode | `npm install` (js: "bun:warn") | approve + advisory |
| warn + allowlist | `npm audit` (js: "bun:warn") | approve (no warn) |
| warn + diagnostic | `pip --version` (py: "uv:warn") | approve (no warn) |
| compound warn | `cd /app && pip install` (py: "uv:warn") | approve + advise |
| warn msg format | `pip install flask` (py: "uv:warn") | has `uv add flask` |

**Integration testing checklist**: The unit tests above validate the
script's stdin-to-stdout logic in isolation. The following manual
integration steps should be performed after implementation to verify
end-to-end behavior in a live Claude Code session:

1. **Matcher triggers**: Run `pip install requests` in a Claude session
   and verify the PreToolUse:Bash hook fires (visible in `--debug hooks`)
2. **Block message received**: Verify Claude sees the block reason and
   does not attempt to execute the original command
3. **Replacement reformulation**: Verify Claude reformulates the command
   using the suggested replacement (e.g., `uv add requests`)
4. **Compound command retry**: Run `pip install && npm install` and
   verify Claude retries after the first block, then hits the second
5. **Warn mode advisory**: Set `"python": "uv:warn"` and verify Claude
   receives the `[hook:advisory]` message in context
6. **Fail-open**: Temporarily rename `config.json` and verify `pip
   install` is approved (not blocked)

## Settings Registration

The new hook is registered as a second PreToolUse entry in
`.claude/settings.json`.

**Note**: This is a partial snippet showing only the new PreToolUse entry
to add to the existing `PreToolUse` array. Existing `PostToolUse`
(multi_linter.sh) and `Stop` (stop_config_guardian.sh) entries remain
unchanged. See `.claude/settings.json` for the complete configuration.

```json
{
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
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/enforce_package_managers.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Script Architecture

### Script Conventions

The script must follow these conventions from the existing codebase:

- **Preamble**: `set -euo pipefail` (required, matches all existing hooks)
- **Exit code**: Always exit 0. Use JSON stdout for the decision, matching
  `protect_linter_configs.sh` convention. Do NOT use the exit-code-based
  approach (exit 2 = block) shown in some Claude Code documentation
  examples — the project standardizes on JSON stdout + exit 0
- **Hook schema convention**: Uses `{"decision": "approve|block"}` convention
  matching `protect_linter_configs.sh`, not the official Claude Code
  `permissionDecision: "allow|deny|ask"` schema. This is intentional:
  (1) cross-hook consistency within the project, (2) no `ask` use case
  for binary enforcement decisions, (3) schema migration across all hooks
  is a separate concern if needed later. See
  [ADR: Hook JSON Schema Convention](adr-hook-schema-convention.md) for
  the full divergence analysis and migration path. **Note**: The schema
  convention ADR's 2026-02 update confirms that the `decision` field is
  now deprecated for PreToolUse hooks. This hook will require migration
  to `hookSpecificOutput.permissionDecision` when the atomic migration
  documented in the schema convention ADR is executed
- **Fail-open**: If `jaq` is missing, input JSON is malformed, or any
  parsing error occurs, output `{"decision": "approve"}` and exit 0.
  A broken hook must not block all Bash commands. This matches the
  fail-open pattern in `protect_linter_configs.sh` (lines 19-23)
- **Config loading**: Use `"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"`
  for config file path (not relative paths). `CLAUDE_PROJECT_DIR` is set
  by Claude Code runtime to the project root
- **Debug output**: `HOOK_DEBUG_PM=1` logs matching decisions to stderr
  (consistent with `HOOK_DEBUG_MODEL` in `multi_linter.sh`). Example output:
  `[hook:debug] PM check: command='pip install flask', action='block'`
- **Auto-protection**: The new script at `.claude/hooks/enforce_package_managers.sh`
  is automatically protected from modification by the existing
  `protect_linter_configs.sh` which blocks edits to all `.claude/hooks/*` files

### Performance Characteristics

Expected execution time is <50ms (two `jaq` invocations for JSON parsing
and config loading, plus bash regex matching). The 5-second timeout in
`settings.json` provides ~100x headroom and matches the existing
`protect_linter_configs.sh` timeout. No network I/O or disk I/O beyond
the single `config.json` read.

### Input/Output Contract

**Input** (stdin JSON from Claude Code runtime):

```json
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "pip install requests flask"
  }
}
```

**Output** (stdout JSON per PreToolUse spec — always exit 0):

```json
{"decision": "approve"}
```

or:

```json
{"decision": "block", "reason": "[hook:block] pip is not allowed. Use: uv add requests flask"}
```

### Processing Flow

```text
1. Read stdin JSON (fail-open: approve if empty or malformed)
2. Extract tool_input.command via jaq (fail-open: approve if jaq missing)
3. Load ${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json
   -> package_managers section (fail-open: use defaults if missing)
4. If python enforcement enabled (value != "false"):
   a0. Parse mode: "uv" → block, "uv:warn" → warn (see parse_pm_config)
   a. Check for uv prefix (passthrough if found — elif chain required)
   b. Match pip/pip3: extract subcommand, check allowed_subcommands.pip
   b2. Diagnostic flags (--version, -v, -V, --help, -h): no-op
       (elif chain exits, preventing bare-pip block)
   c. Match python -m pip / python -m venv
   d. (independent if block) poetry: extract subcommand, check
      allowed_subcommands.poetry; diagnostic flags: no-op
   e. (independent if block) pipenv: extract subcommand, check
      allowed_subcommands.pipenv; diagnostic flags: no-op
   f. If matched and not allowlisted: call block() or warn() per mode
   Note: pip/python-m family (a–c) uses elif chain because "uv pip"
   contains substring "pip". Poetry and pipenv (d, e) use independent
   if blocks — cross-tool compounds like `pip --version && poetry add
   requests` ARE caught. The uv pip passthrough calls exit 0
   immediately, so `uv pip install && pip install` still approves
   (documented limitation — see D7 warn-mode compound behavior).
5. If javascript enforcement enabled (value != "false"):
   a0. Parse mode: "bun" → block, "bun:warn" → warn (see parse_pm_config)
   Each JS tool checked independently (separate if blocks, NOT elif):
   a. npm: extract subcommand, check allowed_subcommands.npm;
      then try flag+subcommand extraction (npm -g install → extract
      subcommand after flags, check allowlist); then diagnostic
      flags (no-op); then bare flag catch; then bare npm
   b. npx: diagnostic flags (no-op); then enforce (suggest bunx)
   c. yarn: extract subcommand, check allowed_subcommands.yarn;
      diagnostic flags (no-op); bare yarn = yarn install (enforce)
   d. pnpm: extract subcommand, check allowed_subcommands.pnpm;
      diagnostic flags (no-op); bare pnpm = pnpm install (enforce)
   Independent checks prevent allowlist bypass in compound commands
   (e.g., npm audit && yarn add bypassed the old elif chain).
   Diagnostic no-ops in JS if blocks safely continue to next tool.
   "Enforce" calls block() or warn() per the parsed mode.
6. If no match: approve
7. Always exit 0 (JSON stdout carries the decision)
```

### Regex Patterns (Bash ERE)

All patterns use POSIX Extended Regular Expressions (ERE) compatible with
bash `=~` on macOS and Linux. PCRE features (lookbehinds, lookaheads,
`\b` word boundaries) are **not used** because:

- bash `=~` uses ERE, not PCRE
- macOS ships BSD grep without `-P` (PCRE) support
- `\b` is unreliable in bash `=~` across platforms

Word boundaries use character class alternatives:
`(^|[^a-zA-Z0-9_])` for start, `([^a-zA-Z0-9_]|$)` for end.

**Python enforcement** — elif chain for pip/python-m family;
independent if blocks for poetry/pipenv:

```bash
WB_START='(^|[^a-zA-Z0-9_])'
WB_END='([^a-zA-Z0-9_]|$)'

# py_mode set from parse_pm_config (e.g., "block" or "warn")

# Block 1: pip/python-m elif chain
# (elif required — "uv pip" contains "pip"; separate if would
# false-positive on uv pip install)
if [[ "${command}" =~ ${WB_START}uv[[:space:]]+pip ]]; then
  approve  # uv pip passthrough — exit 0, script ends here

elif [[ "${command}" =~ ${WB_START}pip3?[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pip" "${subcmd}" || \
    enforce "${py_mode}" "pip" "${subcmd}"
elif [[ "${command}" =~ \
    ${WB_START}pip3?[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pip diagnostic — no-op
elif [[ "${command}" =~ ${WB_START}pip3?${WB_END} ]]; then
  enforce "${py_mode}" "pip"  # bare pip
elif [[ "${command}" =~ \
    ${WB_START}python3?[[:space:]]+-m[[:space:]]+pip${WB_END} ]]; then
  enforce "${py_mode}" "python -m pip"
elif [[ "${command}" =~ \
    ${WB_START}python3?[[:space:]]+-m[[:space:]]+venv${WB_END} ]]; then
  enforce "${py_mode}" "python -m venv"
fi

# Block 2: poetry — independent (catches "pip diag && poetry add")
if [[ "${command}" =~ ${WB_START}poetry[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "poetry" "${subcmd}" || \
    enforce "${py_mode}" "poetry" "${subcmd}"
elif [[ "${command}" =~ \
    ${WB_START}poetry[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # poetry diagnostic — no-op
elif [[ "${command}" =~ ${WB_START}poetry${WB_END} ]]; then
  enforce "${py_mode}" "poetry"  # bare poetry
fi

# Block 3: pipenv — independent (catches "pip diag && pipenv install")
if [[ "${command}" =~ ${WB_START}pipenv[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pipenv" "${subcmd}" || \
    enforce "${py_mode}" "pipenv" "${subcmd}"
elif [[ "${command}" =~ \
    ${WB_START}pipenv[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pipenv diagnostic — no-op
elif [[ "${command}" =~ ${WB_START}pipenv${WB_END} ]]; then
  enforce "${py_mode}" "pipenv"  # bare pipenv
fi
```

**Note on independent blocks for poetry/pipenv**: Poetry and pipenv
use independent if blocks (not elif from the pip chain) so cross-tool
compound commands are caught. In `pip --version && poetry add
requests`, the pip elif chain hits the diagnostic no-op and exits to
`fi`; the independent poetry block then matches `poetry add`. The
cross-tool case `pip --version && pipenv install` works identically:
the pip elif exits to `fi`, then the independent pipenv block matches
`pipenv install`. The pip/python-m family retains the elif chain
because `uv pip` contains substring `pip` — a separate if block for
pip would false-positive on `uv pip install` commands. Same-tool
diagnostic compounds (`pipenv --version && pipenv install` and
`poetry --help && poetry add requests`) are also correctly blocked:
the first if-branch (`${WB_START}pipenv[[:space:]]+([a-zA-Z]+)` or
`${WB_START}poetry[[:space:]]+([a-zA-Z]+)`, where `${WB_START}` is
`(^|[^a-zA-Z0-9_])`) scans the full string. At the first occurrence,
`--version` or `--help` fails `[a-zA-Z]+` (starts with `-`), so the
regex finds the blocked subcommand at the second occurrence. The
diagnostic elif branch is never entered.

**JavaScript enforcement** — independent if blocks per tool (NOT elif):

Each JS package manager is checked independently. This prevents the
allowlist bypass where `npm audit && yarn add malicious-pkg` was approved
because the npm allowlist match exited the elif chain before yarn was
checked. With independent if blocks, an allowlist hit continues to the
next tool check; only a block hit exits immediately.

```bash
# Each JS PM checked independently — enforce exits, allowlist continues
# js_mode set from parse_pm_config (e.g., "block" or "warn")

# npm (independent check)
if [[ "${command}" =~ ${WB_START}npm[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "npm" "${subcmd}" || enforce "${js_mode}" "npm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]*[[:space:]]+([a-zA-Z]+) ]]; then
  # flags before subcommand — extract subcommand after flags, check allowlist
  # npm -g install → captures "install" → not allowlisted → enforce
  # npm --registry=url audit → captures "audit" → allowlisted → approve
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "npm" "${subcmd}" || enforce "${js_mode}" "npm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # npm diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}npm[[:space:]]+- ]]; then
  enforce "${js_mode}" "npm"  # unrecognized flags with no subcommand after
elif [[ "${command}" =~ ${WB_START}npm${WB_END} ]]; then
  enforce "${js_mode}" "npm"  # bare npm
fi

# npx (independent check)
if [[ "${command}" =~ ${WB_START}npx[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # npx diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}npx${WB_END} ]]; then
  enforce "${js_mode}" "npx"  # suggest bunx
fi

# yarn (independent check — not elif from npm)
if [[ "${command}" =~ ${WB_START}yarn[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "yarn" "${subcmd}" || enforce "${js_mode}" "yarn" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}yarn[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # yarn diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}yarn${WB_END} ]]; then
  enforce "${js_mode}" "yarn" "install"  # bare yarn = yarn install
fi

# pnpm (independent check — not elif from yarn)
if [[ "${command}" =~ ${WB_START}pnpm[[:space:]]+([a-zA-Z]+) ]]; then
  subcmd="${BASH_REMATCH[2]}"
  is_allowed_subcommand "pnpm" "${subcmd}" || enforce "${js_mode}" "pnpm" "${subcmd}"
elif [[ "${command}" =~ ${WB_START}pnpm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
  :  # pnpm diagnostic — continue to next tool check
elif [[ "${command}" =~ ${WB_START}pnpm${WB_END} ]]; then
  enforce "${js_mode}" "pnpm" "install"  # bare pnpm = pnpm install
fi
```

**Design note — why JS uses separate if blocks but Python uses elif**:
JavaScript tools (npm, yarn, pnpm) are independent names with no
substring aliasing — `npm` is never a substring of `yarn`. Separate if
blocks are safe and required to prevent compound command bypass. Python
tools have substring aliasing: `uv pip` contains `pip`. Separate if
blocks would false-positive `uv pip install` as a bare `pip` invocation.
The Python elif chain ordering (check `uv pip` first, then bare `pip`)
is essential. See "Note on elif chain" above.

**Design note — npm flag+subcommand extraction**: The npm block includes
a flag-then-subcommand regex (`npm -flag subcmd`) that extracts the
subcommand after flags and checks the allowlist. This prevents blocking
legitimate allowlisted commands with flag prefixes
(`npm --registry=url audit` → approve) while still catching violations
(`npm -g install` → block). The pattern `-[^[:space:]]*[[:space:]]+`
matches one flag token (dash + non-spaces + space) before the subcommand.
Diagnostic flags (`--version`, `--help`) are handled by a separate
no-op branch that fires before the blanket flag catch. **Multi-flag
limitation**: npm commands with multiple flags before the subcommand
(e.g., `npm -g --registry=url install foo`) are not fully parsed — the
regex extracts only one flag token, and the second flag (`--registry`)
fails the `([a-zA-Z]+)` subcommand capture. The command falls through
to the bare flag catch and is correctly blocked, but with a generic
replacement suggestion rather than a specific one. This is accepted
because multi-flag npm commands are rare in Claude-generated code and
the block behavior is correct.

### Replacement Command Computation

The script extracts the packages/arguments from the blocked command and
constructs the replacement:

| Pattern | Extraction | Replacement |
| --- | --- | --- |
| `pip install <pkgs>` | `<pkgs>` | `uv add <pkgs>` |
| `pip install -r <file>` | `-r <file>` | `uv pip install -r <file>` |
| `pip install -e .` | `-e .` | `uv pip install -e .` |
| `pip uninstall <pkgs>` | `<pkgs>` | `uv remove <pkgs>` |
| `pip freeze` | - | `uv pip freeze` |
| `pip list` | - | `uv pip list` |
| `python -m venv <dir>` | `<dir>` | `uv venv <dir>` (or `uv venv`) |
| `npm install <pkg>` | `<pkg>` | `bun add <pkg>` |
| `npm install` (no args) | - | `bun install` |
| `npm run <script>` | `<script>` | `bun run <script>` |
| `npm test` | - | `bun test` |
| `npx <pkg>` | `<pkg>` | `bunx <pkg>` |
| `poetry add <pkgs>` | `<pkgs>` | `uv add <pkgs>` |
| `poetry install` | - | `uv sync` |
| `poetry run <cmd>` | `<cmd>` | `uv run <cmd>` |
| `poetry lock` | - | `uv lock` |
| `poetry <other>` | - | `uv` equivalents (generic) |
| `pipenv install <pkg>` | `<pkg>` | `uv add <pkg>` |
| `pipenv install` | - | `uv sync` |
| `pipenv run <cmd>` | `<cmd>` | `uv run <cmd>` |
| `pipenv <other>` | - | `uv` equivalents (generic) |
| `yarn add <pkg>` | `<pkg>` | `bun add <pkg>` |
| `yarn install` / bare `yarn` | - | `bun install` |
| `yarn run <script>` | `<script>` | `bun run <script>` |
| `yarn <other>` | - | `bun` equivalents (generic) |
| `pnpm add <pkg>` | `<pkg>` | `bun add <pkg>` |
| `pnpm install` / bare `pnpm` | - | `bun install` |
| `pnpm run <script>` | `<script>` | `bun run <script>` |
| `pnpm <other>` | - | `bun` equivalents (generic) |

For compound commands where extraction is ambiguous, the message suggests
the general replacement tool without attempting to rewrite the full
compound command.

### Replacement Tool Existence Check

When blocking a command and suggesting a replacement, the hook checks (once
per session) whether the replacement tool is installed. If the replacement
tool is missing, the hook still blocks the command but appends a warning to
stderr on first occurrence:

```bash
# Session-scoped warning for missing replacement tool
if ! command -v uv >/dev/null 2>&1; then
  local marker="/tmp/.pm_warn_uv_${HOOK_GUARD_PID:-${PPID}}"
  if [[ ! -f "${marker}" ]]; then
    echo "[hook:warning] uv not found — pip blocked but replacement unavailable. Install: brew install uv" >&2
    touch "${marker}"
  fi
fi
```

**Note on `HOOK_GUARD_PID`**: This variable is used by the existing hook
infrastructure (specifically `stop_config_guardian.sh`) to scope session
marker files to the Claude Code session's process ID. The fallback `${PPID}`
ensures markers work
even if `HOOK_GUARD_PID` is not set. Marker files in `/tmp/` are transient —
they persist until system reboot or `/tmp` cleanup, which is the intended
behavior (session-scoped, not permanent).

**Rationale**: Without this check, Claude receives a block message saying
"use uv instead" but has no way to know uv is not installed. The result is a
frustrating loop: Claude tries `uv`, gets "command not found", and has no
remediation path. The warning provides actionable feedback. The command is
still blocked regardless — policy enforcement is unconditional. This follows
the established pattern from `multi_linter.sh` (hadolint version warning).

### Observability

The debug variable `HOOK_DEBUG_PM=1` provides interactive troubleshooting
output. For passive data collection to assess enforcement effectiveness
over time, the hook supports an optional decision log:

- **Variable**: `HOOK_LOG_PM=1` enables logging to
  `/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log` (session-scoped)
- **Format**: `timestamp | action(approve/block/warn) | tool | subcmd |
  command_excerpt` (one line per decision)
- **Disabled by default**: No overhead when not enabled
- **Use cases**: Periodic audit of enforcement decisions, false positive
  detection, identifying unanticipated bypass patterns
- **Review**: `grep block /tmp/.pm_enforcement_*.log` to see what's
  being caught across sessions

This is complementary to `HOOK_DEBUG_PM=1`: debug mode is for
interactive troubleshooting, log mode is for post-session analysis.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| False positive on substring | Low | Low | ERE word boundary classes |
| Compound cmd false positives | Low | Med | Documented known limitations |
| npm allowlist too restrictive | Low | Low | Configurable via config.json |
| New package managers emerge | Low | Low | Designed for extension |
| jaq unavailable on system | Low | Med | Fail-open: approve all |
| Here-doc/comment false match | Low | Low | Accepted trade-off (see D7) |

**Note**: PCRE portability is **not** a risk — all patterns use POSIX ERE
natively in bash `=~`. This was a deliberate design choice (see "Regex
Patterns" section). The risk was eliminated by design rather than mitigated.

## Scope Boundaries

**In scope**:

- Package manager enforcement (pip, npm, yarn, pnpm, poetry, pipenv)
- Configurable per-ecosystem toggles
- npm registry allowlist
- Compound command detection
- Full test coverage in test_hook.sh

**Out of scope**:

- Runtime enforcement (blocking `node` in favor of `bun`)
- Build tool enforcement (blocking `webpack` in favor of `vite`)
- Other ecosystem tools (conda, brew, cargo, gem, go get) — conda
  operates its own environment and dependency resolution system orthogonal
  to pip/uv; replacing it requires a different toolchain migration (e.g.,
  to pixi/rattler), not a simple command substitution. brew/cargo/gem/go
  are unrelated ecosystems
- Lock file migration tooling
- CLAUDE.md documentation updates (this ADR serves as documentation)

## Consequences

### Positive

- Enforces consistent lockfile format and dependency tree per ecosystem
- Catches package manager drift that CLAUDE.md alone cannot prevent
- Configurable per-ecosystem with three-position model (block/warn/off)
- Unified allowlist architecture for all 6 tools — extensible and maintainable
- Fail-open design ensures broken hooks never block legitimate Bash commands

### Negative

- Legitimate pip/npm use is blocked (e.g., pip in a conda environment where
  uv is not appropriate) — mitigated by per-ecosystem toggle and allowlists
- Adoption friction for new team members unfamiliar with the enforcement
  mechanism — mitigated by clear block messages with replacement commands
- Compound command false positives for here-docs, comments, and strings
  — accepted trade-off (see D7)
- Warn mode provides weaker enforcement for AI agents than for human
  developers — command executes before warning is processed (see D2)

### Neutral

- Does not address runtime enforcement (node vs bun) — intentionally scoped
  to package managers only (see D6)
- The `{\"decision\": \"approve|block\"}` schema convention is separate from
  this ADR (see [ADR: Hook Schema Convention](adr-hook-schema-convention.md))

## Rollback and Emergency Disable

Three methods for disabling enforcement, ordered by granularity:

1. **Per-ecosystem toggle** (config.json): Set `"python": false` or
   `"javascript": false` in the `package_managers` section. Requires no
   session restart — config is loaded on each hook invocation.

2. **Full hook removal** (settings.json): Remove the `Bash` matcher entry
   from the `PreToolUse` array in `.claude/settings.json`. Requires session
   restart. The `Edit|Write` PreToolUse hook (config protection) is
   unaffected.

3. **Session override** (environment variable): Run
   `HOOK_SKIP_PM=1 claude ...` to bypass enforcement for a single session.
   This matches the `HOOK_SKIP_SUBPROCESS` pattern in `multi_linter.sh`.
   The hook checks this variable at startup and exits with
   `{"decision": "approve"}` immediately if set.

## Implementation Checklist

- [ ] Create `.claude/hooks/enforce_package_managers.sh`
- [ ] Add `package_managers` section to `.claude/hooks/config.json`
- [ ] Register new PreToolUse entry in `.claude/settings.json`
  (Bash matcher)
- [ ] Add self-test cases to `.claude/hooks/test_hook.sh`
- [ ] Update `docs/REFERENCE.md` with new hook documentation
- [ ] Add `[hook:block]` to docs/REFERENCE.md severity table (new prefix for
  PreToolUse blocks, extending existing `[hook:error/warning/advisory]`)
- [ ] Create prerequisites check script (`test_hook.sh --check-deps` or
  standalone `check-prerequisites.sh`) that verifies jaq, uv, bun, and
  other required/optional tools are installed, with actionable install
  commands for missing ones
- [ ] Verify all existing tests still pass after changes

---

## References

- [uv GitHub repository (10-100x faster claim)](https://github.com/astral-sh/uv)
- [Bun v1.2.15 release notes (bun audit, bun pm view)](https://bun.com/blog/bun-v1.2.15)
- [Bun audit official documentation](https://bun.com/docs/install/audit)
- [DigitalOcean uv guide](https://www.digitalocean.com/community/conceptual-articles/uv-python-package-manager)
- [Stack Overflow: bash word boundary regex portability](https://stackoverflow.com/questions/9792702/does-bash-support-word-boundary-regular-expressions)
- [Stack Overflow: macOS grep -P not supported](https://stackoverflow.com/questions/77662026/grep-invalid-option-p-error-when-doing-regex-in-bash-script)
- [bun add documentation (--dev flag)](https://bun.com/docs/pm/cli/add)
- [uv issue #3163 - pip download equivalent (still open)](https://github.com/astral-sh/uv/issues/3163)
- [Bun v1.2.19 release notes (--quiet flag for bun pm pack)](https://bun.com/blog/bun-v1.2.19)
- [Bun v1.1.27 release notes (bun pm pack)](https://bun.com/blog/bun-v1.1.27)
- [Bun v1.1.30 release notes (bun publish, bun pm whoami)](https://bun.com/blog/bun-v1.1.30)
- [Stack Overflow - bash =~ uses ERE, not PCRE](https://stackoverflow.com/questions/27476347/matching-word-boundary-with-bash-regex)
- [bun info / bun pm view documentation](https://bun.com/docs/pm/cli/info)
- [Bun GitHub Releases (latest v1.3.9)](https://github.com/oven-sh/bun/releases)
- [uv CLI Reference (no download subcommand)](https://docs.astral.sh/uv/reference/cli)
- [uv latest release 0.10.4](https://github.com/astral-sh/uv/releases/tag/0.10.4)
- [Bun publish documentation](https://bun.com/docs/pm/cli/publish)
- [Bun scopes and registries (no bun login)](https://bun.com/docs/pm/scopes-registries)
- [Bun audit hangs indefinitely (#20800)](https://github.com/oven-sh/bun/issues/20800)
- [Bun audit fix request (#20238)](https://github.com/oven-sh/bun/issues/20238)
- [Bun publish CI auth failure (#24124)](https://github.com/oven-sh/bun/issues/24124)
- [Bun publish GitHub Package Registry failure (#15245)](https://github.com/oven-sh/bun/issues/15245)
- [Bun publish custom registry failure (#18670)](https://github.com/oven-sh/bun/issues/18670)
- [Bun pm pack prepack script issue (#24314)](https://github.com/oven-sh/bun/issues/24314)
- [Bun pm pack bundledDependencies issue (#16394)](https://github.com/oven-sh/bun/issues/16394)
- [Bun audit --prod monorepo issue (#26675)](https://github.com/oven-sh/bun/issues/26675)
- [Bun pm whoami confusion (#22614)](https://github.com/oven-sh/bun/issues/22614)
- [npm to bun migration guide](https://bun.com/docs/guides/install/from-npm-install-to-bun-install)
- [jaq GitHub repository - project self-description](https://github.com/01mf02/jaq)
- [Bun text-based lockfile announcement (bun.lock)](https://bun.com/blog/bun-lock-text-lockfile)
- [Bun lockfile documentation](https://bun.com/docs/pm/lockfile)
- [uv pip compatibility documentation](https://docs.astral.sh/uv/pip/compatibility/)
- [Bun v1.3.9 latest release](https://github.com/oven-sh/bun/releases/tag/bun-v1.3.9)
- [uv installation documentation](https://docs.astral.sh/uv/getting-started/installation/)
