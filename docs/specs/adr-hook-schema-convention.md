# ADR: Hook JSON Schema Convention

**Status**: Accepted
**Date**: 2026-02-16
**Author**: alex fazio + Claude Code clarification interview

## Context and Problem Statement

The project's Claude Code hooks use a JSON output schema that diverges from
the official Claude Code documentation. All three hook types (PreToolUse,
PostToolUse, Stop) use a convention that works in practice but does not match
the documented `hookSpecificOutput.permissionDecision` schema. This ADR
documents the divergence, explains why it exists, evaluates the risks, and
establishes the project's position on whether to migrate.

## The Two Schemas

### Project Convention (current)

All hooks use `{"decision": "approve|block"}` with always exit 0:

**PreToolUse** (`protect_linter_configs.sh`):

```json
{"decision": "approve"}
{"decision": "block", "reason": "Protected linter config file (biome.json). Fix the code, not the rules."}
```

**Stop** (`stop_config_guardian.sh`):

```json
{"decision": "approve"}
{"decision": "block", "reason": "...", "systemMessage": "..."}
```

**PostToolUse** (`multi_linter.sh`):

No JSON output. Uses exit codes only: exit 0 (clean) or exit 2 (violations
remain, stderr fed to Claude).

All PreToolUse and Stop hooks exit 0 unconditionally. The JSON `decision`
field carries the actual allow/block semantics.

### Official Claude Code Schema

The Claude Code documentation defines two approaches for command hooks:

**Approach 1 — Exit-code based** (simpler):

- Exit 0: Operation allowed, stdout included in transcript
- Exit 2: Operation blocked, stderr shown to Claude
- Any other exit code: Non-blocking error

**Approach 2 — JSON stdout** (richer):

```json
{
  "hookSpecificOutput": {
    "permissionDecision": "allow|deny|ask",
    "updatedInput": {
      "command": "modified_command_here"
    }
  },
  "systemMessage": "Message for Claude (the agent, not the user)"
}
```

Key differences from the project convention:

| Aspect | Project Convention | Official Schema |
| --- | --- | --- |
| Top-level key | `decision` | `hookSpecificOutput.permissionDecision` |
| Allow value | `"approve"` | `"allow"` |
| Block value | `"block"` | `"deny"` |
| User prompt | Not supported | `"ask"` |
| Nesting | Flat | Nested under `hookSpecificOutput` |
| Exit code | Always 0 | 0 (allow), 2 (block), or JSON |
| Reason field | `"reason"` (top-level) | `"systemMessage"` (top-level) |
| Input rewriting | Not supported | `updatedInput` |

### The `ask` Option

The official schema supports a third permission decision: `ask`. When a
PreToolUse hook returns `"permissionDecision": "ask"`, Claude Code prompts
the user for explicit confirmation before executing the tool. This creates
a three-way decision model:

- **allow**: Proceed silently
- **deny**: Block and inform Claude
- **ask**: Pause and let the user decide

The project's `approve|block` convention has no equivalent to `ask`. All
decisions are binary.

## Why the Divergence Exists

### 1. Historical Timing

The hooks were written when the exit-code-based approach (exit 0 = allow,
exit 2 = block) was the primary documented method for command hooks. The
project added structured JSON on top of exit 0 for richer messages
(block reasons, system messages). The header comment in
`protect_linter_configs.sh` (line 8) reads:

```text
# Output: JSON schema per PreToolUse spec
```

This indicates the author believed `{"decision": "approve|block"}` *was*
the spec at the time of writing. The `hookSpecificOutput.permissionDecision`
nested schema was either not yet documented or not yet discovered.

### 2. Claude Code Accepts Both Schemas

Claude Code's runtime is lenient about the JSON shape it accepts from
command hooks. The project's `{"decision": "block", "reason": "..."}` format
successfully blocks operations, even though it does not match the officially
documented key paths. This means the divergence has no functional impact
today — the hooks work correctly in all observed scenarios.

**Evidence**: `protect_linter_configs.sh` reliably blocks edits to protected
files using the project convention. `stop_config_guardian.sh` reliably
blocks session exit when config files are modified. Both have been tested
extensively via `test_hook.sh --self-test` and in production Claude Code
sessions.

### 3. Binary Decisions Suffice

Every hook in the project makes binary decisions:

- **protect_linter_configs.sh**: File is protected (block) or not (approve).
  No ambiguity, no user judgment needed.
- **stop_config_guardian.sh**: Config files modified (block + directive to
  use AskUserQuestion) or not (approve). The "ask the user" functionality
  is implemented at a higher level — the Stop hook blocks, then Claude
  invokes AskUserQuestion as instructed by the `reason` field. The hook
  itself does not use the `ask` permission decision.
- **multi_linter.sh**: Violations exist (exit 2) or not (exit 0). Binary.
- **enforce_package_managers.sh** (proposed): Command is allowed (approve)
  or blocked (block). Binary.

There is no hook in the project where the hook itself is uncertain and needs
to defer the decision to the user via `ask`.

### 4. Not a Subprocess Limitation

One might hypothesize that `ask` is unavailable because subprocesses
(`claude -p`) cannot prompt the user. This is incorrect. PreToolUse hooks
fire on the **main agent's** tool invocations, not on subprocess commands.
The subprocess runs with `--settings .claude/subprocess-settings.json`
which disables all hooks entirely. The `ask` option would work fine in the
main agent's PreToolUse hooks — it would prompt the user in the interactive
Claude session before executing the Bash command.

The reason `ask` is not used is design choice (binary decisions), not
technical limitation.

## Decision

**Maintain the project convention** (`{"decision": "approve|block"}` with
exit 0) for all current and new hooks. Do not adopt the official
`hookSpecificOutput.permissionDecision` schema at this time.

### Rationale

1. **Cross-hook consistency**: All three existing hooks (PreToolUse,
   PostToolUse, Stop) use the same convention. Introducing the official
   schema in one hook while others use the project convention creates
   confusion and maintenance burden.

2. **No functional gap**: The project's hooks make binary decisions. The
   `ask` permission decision is not needed for any current or planned hook.
   The Stop hook achieves "ask the user" semantics through a different
   mechanism (block + AskUserQuestion directive).

3. **Working in production**: The convention has been validated through
   extensive testing and real-world Claude Code sessions. There is no
   bug to fix.

4. **Migration cost**: Adopting the official schema requires changing all
   three hooks simultaneously, updating docs/REFERENCE.md, updating test_hook.sh,
   and re-validating all behavior. This is a non-trivial migration for
   zero functional gain.

5. **Piecemeal migration is worse**: Introducing the official schema in
   only the new `enforce_package_managers.sh` while keeping the project
   convention in existing hooks would create two conventions — worse than
   having one non-standard convention consistently.

## Risks and Mitigations

| Risk | Lklhd | Imp | Mitigation |
| --- | --- | --- | --- |
| CC tightens validation | Med | Hi | `decision` deprecated; migration noted |

**2026-02 Update**: The official Claude Code documentation now explicitly
states that `decision` and `reason` fields are **deprecated for PreToolUse**
hooks. The recommended schema is `hookSpecificOutput.permissionDecision`
with values `allow|deny|ask`. The deprecated `approve|block` values are
still mapped by the runtime (hooks continue to work), but this confirms the
risk is materializing. The project should plan the atomic migration
documented in "Risk Detail: Validation Tightening" below. For PostToolUse,
Stop, and other events, the top-level `decision` field remains current and
is not deprecated.
| New hook needs `ask` | Low | Med | Evaluate then; may migrate |
| Non-standard schema confusion | Low | Low | This ADR documents it |
| `updatedInput` needed | Low | Med | Requires official schema |
| Official schema changes | V.Low | Med | Convention unaffected |

### Risk Detail: Validation Tightening

If Claude Code begins rejecting `{"decision": "block"}` in favor of
requiring `{"hookSpecificOutput": {"permissionDecision": "deny"}}`, all
PreToolUse and Stop hooks would break simultaneously. The migration path
is mechanical:

1. Replace `"decision": "approve"` with
   `"hookSpecificOutput": {"permissionDecision": "allow"}`
2. Replace `"decision": "block"` with
   `"hookSpecificOutput": {"permissionDecision": "deny"}`
3. Move `"reason"` content to `"systemMessage"` (already used in Stop hook)
4. Update test_hook.sh assertions
5. Update docs/REFERENCE.md schema reference table

This migration is straightforward but should be done as a single atomic
change across all hooks, not piecemeal.

### Risk Detail: Future `ask` Use Cases

Plausible scenarios where `ask` would add value:

- **Package manager enforcement with exceptions**: Instead of a static
  allowlist, the hook could `ask` when it encounters an unfamiliar npm
  subcommand: "npm dedupe detected — allow this?"
- **Destructive Bash commands**: A safety hook that catches `rm -rf` and
  prompts the user rather than blocking outright.
- **First-time enforcement**: Block by default but `ask` on first
  occurrence per session, then remember the user's choice.

If any of these scenarios become requirements, the project should migrate
all hooks to the official schema at that point.

## Consequences

### Positive

- All hooks use one convention — easy to understand, copy, and test
- New hooks (enforce_package_managers.sh) match existing patterns exactly
- No migration effort required now
- docs/REFERENCE.md schema reference table remains simple and accurate

### Negative

- Project does not use the official documented schema
- `ask` permission decision is unavailable without migration
- `updatedInput` (command rewriting) is unavailable without migration
- Contributors familiar with Claude Code docs may be surprised by the
  non-standard convention

### Neutral

- This ADR serves as the canonical explanation of the divergence
- Migration path is documented and ready to execute when needed

## Implementation Notes

### Convention Reference

All hooks must follow this convention:

```bash
# Allow operation
echo '{"decision": "approve"}'
exit 0

# Block operation (PreToolUse)
echo '{"decision": "block", "reason": "Explanation for Claude"}'
exit 0

# Block session exit (Stop)
jaq -n \
  --arg reason "Directive for Claude" \
  --arg msg "User-facing advisory" \
  '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
exit 0
```

### Field Semantics

| Field | Used By | Purpose |
| --- | --- | --- |
| `decision` | PreToolUse, Stop | `"approve"` or `"block"` |
| `reason` | PreToolUse, Stop | Message Claude reads for context |
| `systemMessage` | Stop | User-facing advisory context (brief) |

**Clarification on `reason` vs `systemMessage`**: In the official Claude
Code docs, `systemMessage` is what Claude reads. In this project's
convention, `reason` serves that role for PreToolUse hooks (Claude reads the
block reason to understand why the operation was denied). The Stop hook uses
both: `reason` for Claude's action directive (e.g., "invoke AskUserQuestion
with these parameters") and `systemMessage` for brief user-facing context.

### Where the Convention Is Documented

- **docs/REFERENCE.md** line 817: Hook Schema Reference table
- **protect_linter_configs.sh** lines 8-10: Header comment
- **stop_config_guardian.sh** lines 13-14: Header comment
- **This ADR**: Canonical explanation of divergence and rationale

## Related Documents

- [ADR: Package Manager Enforcement](adr-package-manager-enforcement.md) —
  Script Conventions section references this schema convention
- [docs/REFERENCE.md Hook Schema Reference](../REFERENCE.md) — Line 817,
  documents the convention in table form
- [Architecture Overview](psf/00-cc-hooks-template-architecture-overview.md) —
  Data Model section documents the JSON schemas
