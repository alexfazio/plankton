# ADR: CLI Tool Preference Warnings via PreToolUse Hook

**Status**: Draft
**Date**: 2026-02-18
**Author**: alex fazio + Claude Code clarification interview

**Related**: This ADR reuses the hook infrastructure from
[ADR: Package Manager Enforcement](adr-package-manager-enforcement.md) but
uses a fundamentally different enforcement mode (warn vs block).

## Context and Problem Statement

Claude Code occasionally generates `grep` or `jq` commands in Bash despite
the project preferring `rg` (ripgrep) and `jaq`. While Claude Code's built-in
Grep tool already uses ripgrep internally (confirmed via `@vscode/ripgrep`
npm package), and the system prompt since v0.2.114 prefers rg in Bash, there
is no enforcement for the minority of cases where Claude generates these tools
directly in Bash commands.

Unlike package manager enforcement (which blocks commands because using the
wrong tool corrupts lockfiles and dependency trees — a **correctness**
concern), CLI tool preferences are driven by **performance and consistency**.
This different motivation justifies warn-mode enforcement: the command
proceeds, but Claude receives an advisory suggesting the preferred tool.

### Why This Is Separate from Package Manager Enforcement

| Aspect | Package Manager ADR | This ADR |
| --- | --- | --- |
| Motivation | Correctness (lockfiles, deps) | Performance, consistency |
| Enforcement mode | Block (`"block"`) | Warn (`"approve"` + stderr) |
| Risk of wrong tool | High (corrupted state) | Low (slower, different format) |
| Drop-in replacement? | Yes (pip -> uv) | Partial (edge cases) |

## Decision Drivers

- **Consistency**: Prefer the same tools the hooks themselves use (jaq, not jq)
- **Performance**: rg is faster than grep; jaq is faster than jq
- **Non-disruption**: Warnings must not block Claude's workflow — advisory only
- **Compatibility awareness**: Neither rg nor jaq is a full drop-in replacement
- **Existing patterns**: Follow the established PreToolUse hook architecture

## Decisions

### D1: Enforcement Mode - Warn, Not Block

**Decision**: Use warn-mode enforcement. The hook outputs
`{"decision": "approve"}` (allowing the command) and writes a warning to
stderr. Claude receives the warning as context for future commands.

**Rationale**: Unlike package managers where the wrong tool produces
incorrect artifacts (wrong lockfile format, wrong install location), using
grep instead of rg produces correct but potentially slower results. Blocking
would be disproportionate to the risk.

**Shared warn infrastructure**: The `warn()` pattern (approve JSON + stderr
advisory with `[hook:advisory]` prefix) is shared with the package manager
enforcement hook's configurable warn mode (see
[ADR: Package Manager Enforcement, D2](adr-package-manager-enforcement.md)).
Both hooks use identical output semantics: `{"decision": "approve"}` on
stdout, `[hook:advisory] <message>` on stderr.

**Warning format**:

```text
[hook:advisory] grep detected in Bash command. Prefer: rg (ripgrep). Claude Code's Grep tool already uses ripgrep internally.
```

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Warn (approve + stderr)** | Non-disruptive | Claude may ignore | **Yes** |
| **Block (like pkg mgrs)** | Enforced | Disproportionate | No |
| **CLAUDE.md only** | Zero effort | Insufficient | No |
| **Auto-rewrite** | Seamless | Not drop-in; bug #15897 | No |

### D2: Hook Integration - Same Script or Companion

**Decision**: TBD — either extend `enforce_package_managers.sh` with a
warn path, or create a companion `warn_tool_preferences.sh` script. Both
approaches share the same PreToolUse Bash matcher.

**Trade-offs**:

| Approach | Pros | Cons |
| --- | --- | --- |
| Extend existing script | One script, one config | Mixes block+warn logic |
| Companion script | Clean separation | Two scripts for one matcher |

**Note**: Multiple hooks can be registered under the same matcher in
`.claude/settings.json`. The hooks array supports multiple entries.

### D3: grep -> rg Enforcement Scope

**Decision**: Warn when Claude generates `grep` directly in Bash commands.
Default: **off** (opt-in).

**Rationale**: Claude Code's built-in Grep tool already uses ripgrep
internally. The system prompt explicitly says "ALWAYS use Grep for search
tasks. NEVER invoke `grep` or `rg` as a Bash command." This means grep in
Bash is already discouraged at the prompt level. Hook enforcement adds a
safety net for the minority of cases where Claude ignores this guidance
(documented in [anthropics/claude-code#1029](https://github.com/anthropics/claude-code/issues/1029),
improved but not eliminated in v0.2.114).

**Off by default** because: the existing system prompt guidance handles most
cases, and grep has legitimate uses in compound commands (e.g.,
`command | grep pattern` where the Grep tool cannot substitute for piped
input).

**Commands warned**:

| Detected Pattern | Warning Message |
| --- | --- |
| `grep` in Bash | `Prefer: rg. Use Grep tool for searches.` |
| `egrep` in Bash | `Prefer: rg (ripgrep). egrep is deprecated.` |
| `fgrep` in Bash | `Prefer: rg -F (fixed strings). fgrep is deprecated.` |

**Not warned**: `rg` in Bash (the system prompt says don't use it either,
but that's the Grep tool's concern, not this hook's).

### D4: jq -> jaq Enforcement Scope

**Decision**: Warn when Claude generates `jq` in Bash commands.
Default: **on** (enabled).

**Rationale**: Unlike grep (where Claude Code has a built-in Grep tool),
there is no built-in jaq/jq tool in Claude Code. Claude defaults to `jq`
for JSON processing in Bash. The project's hooks all use `jaq`. Warning
about jq promotes consistency with the project's own toolchain.

**On by default** because: there is no built-in alternative (unlike grep),
and jaq is already a project dependency (used by all hooks for JSON parsing).

**Commands warned**:

| Detected Pattern | Warning Message |
| --- | --- |
| `jq` in Bash | `Prefer: jaq. Lacks --stream, --jsonargs.` |

**Compatibility gaps documented in warning**: The warning message itself
notes the known jaq limitations so Claude can make an informed decision
about whether to use jaq or stick with jq for a specific command.

### D5: jaq Compatibility Gaps (Reference)

jaq is ~95% compatible with jq. Known gaps:

**Missing CLI flags** (jq has them, jaq does not):

| jq Flag | Purpose | jaq Status |
| --- | --- | --- |
| `--ascii-output` / `-a` | ASCII escape non-ASCII | Missing |
| `--raw-output0` | NUL-separated raw output | Missing |
| `--unbuffered` | Flush output | Missing |
| `--stream` / `--stream-errors` | Streaming JSON parsing | Missing |
| `--seq` | JSON text sequence | Missing |
| `--jsonargs` | JSON arguments | Missing |

**Behavioral differences**:

- Multi-file slurp: jq combines all files into one array; jaq yields one
  array per file
- `null | .[1:]` returns `null` in jq, errors in jaq
- NaN: jaq prints `"NaN"` as string; jq prints `null`
- Division by zero: jaq follows IEEE 754 (yields nan/infinite); jq errors

**What jaq adds**: YAML/CBOR/TOML/XML support, in-place editing (`-i`),
objects with non-string keys.

### D6: Configuration Design

**Decision**: New `tool_preferences` section in `config.json`.

**Schema**:

```json
{
  "tool_preferences": {
    "grep": false,
    "jq": "jaq"
  }
}
```

**Toggle behavior**:

- `"grep": "rg"` — warn when grep detected, suggest rg
- `"grep": false` — no grep warning (default)
- `"jq": "jaq"` — warn when jq detected, suggest jaq (default)
- `"jq": false` — no jq warning

**Note on value types**: Follows the same dual-purpose string convention as
`package_managers` — the string value enables the warning AND names the
preferred tool used in the warning message.

### D7: Extensibility

The `tool_preferences` section is designed for future expansion:

| Tool | Preferred | Rationale | Priority |
| --- | --- | --- | --- |
| `grep` | `rg` | Performance, .gitignore | Low |
| `jq` | `jaq` | Consistency with hooks | Medium |
| `find` | `fd` | Performance, .gitignore | Future |
| `cat` | `bat` | Syntax highlighting | Future |
| `ls` | `eza` | Better defaults | Future |

Only grep and jq are in scope for this ADR. Others are noted for context.

## Regex Patterns (Bash ERE)

Uses the same POSIX ERE word boundary strategy as the package manager hook:

```bash
WB_START='(^|[^a-zA-Z0-9_])'
WB_END='([^a-zA-Z0-9_]|$)'

# grep/egrep/fgrep detection
if [[ "${command}" =~ ${WB_START}(e|f)?grep${WB_END} ]]; then
  warn "grep" "rg"
fi

# jq detection (but NOT jaq)
if [[ "${command}" =~ ${WB_START}jq${WB_END} ]]; then
  warn "jq" "jaq"
fi
```

**Note**: `jq` matches only `jq` (2 chars) — will not match `jaq` (3 chars)
because the word boundary requires a non-alphanumeric character or string
boundary after the match. No substring aliasing issue like Python's `uv pip`
containing `pip`.

## Test Cases

| Test | Input | Expected |
| --- | --- | --- |
| grep warned | `grep -r "pattern" .` | approve + stderr warning |
| egrep warned | `egrep "pattern" file` | approve + stderr warning |
| fgrep warned | `fgrep "literal" file` | approve + stderr warning |
| rg approved | `rg "pattern" .` | approve (no warning) |
| jq warned | `jq '.field' file.json` | approve + stderr warning |
| jaq approved | `jaq '.field' file.json` | approve (no warning) |
| grep disabled | `grep "p"` (grep: false) | approve (no warning) |
| jq disabled | `jq '.f'` (jq: false) | approve (no warning) |
| compound grep | `cat file \| grep pattern` | approve + stderr warning |
| compound jq | `curl url \| jq '.data'` | approve + stderr warning |
| non-tool cmd | `ls -la` | approve (no warning) |
| grep in word | `autogrep tool` | approve (word boundary prevents match) |

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Warning fatigue | Med | Low | Off-by-default for grep; concise messages |
| Claude ignores warnings | Med | Low | Advisory only — no functional impact |
| jaq compatibility miss | Low | Med | Warning includes known gap list |
| False positive on substring | Low | Low | ERE word boundary classes |

## Scope Boundaries

**In scope**:

- Warn-mode enforcement for grep -> rg and jq -> jaq
- Configurable per-tool toggles in config.json
- Shared infrastructure with package manager hook
- jaq compatibility gap documentation

**Out of scope**:

- Block-mode enforcement (see package manager ADR)
- find -> fd, cat -> bat, ls -> eza (future expansion)
- Modifying Claude Code's built-in Grep tool behavior
- Auto-rewriting commands via updatedInput

## Rollback

Disable warnings by setting `"grep": false` and `"jq": false` in the
`tool_preferences` section of `config.json`. No session restart required.

## Implementation Checklist

- [ ] Decide D2: extend existing script or create companion
- [ ] Implement warn path (approve + stderr) in chosen script
- [ ] Add `tool_preferences` section to config.json
- [ ] Add test cases to test_hook.sh
- [ ] Update docs/REFERENCE.md with warn-mode documentation

---

## References

- [CC #1029 - grep vs rg][cc1029] (improved in v0.2.114)
- [CC #73 - ripgrep usage][cc73] (Grep tool uses rg)
- [CC #6415 - USE_BUILTIN_RIPGREP][cc6415]
- [jaq - compatibility docs][jaq]
- [ripgrep FAQ - not a drop-in][rgfaq]
- [ADR: Package Manager Enforcement][pkgmgr]

[cc1029]: https://github.com/anthropics/claude-code/issues/1029
[cc73]: https://github.com/anthropics/claude-code/issues/73
[cc6415]: https://github.com/anthropics/claude-code/issues/6415
[jaq]: https://github.com/01mf02/jaq
[rgfaq]: https://github.com/BurntSushi/ripgrep/blob/master/FAQ.md
[pkgmgr]: adr-package-manager-enforcement.md
