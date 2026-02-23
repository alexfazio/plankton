# Linear Issue: Enhance Hook Exit 2 Messages with Actionable Instructions

**Team**: AIG
**Priority**: Normal (3)
**Labels**: hooks, code-quality
**Project**: Incide

## Title

Enhance PostToolUse hook exit 2 messages to include Boy Scout Rule instructions

## Description

### Problem

When the `multi_linter.sh` PostToolUse hook's subprocess fails to fix all
violations (exit code 2), the main agent receives this message:

```text
[hook] 3 violation(s) remain after delegation
```

This message is purely informational - it reports *that* violations exist but
does not instruct the main agent to fix them. Without policy context from
CLAUDE.md, the main agent may continue working and ignore the remaining
violations. The Boy Scout Rule enforcement depends entirely on CLAUDE.md text,
not on the hook's mechanical output.

### Root Cause

The hook was designed with the assumption that CLAUDE.md would always contain
the Boy Scout Rule policy text ("you accept responsibility for ALL linting
violations in that file"). When porting the hooks to new projects, CLAUDE.md
may be minimal or absent, breaking the enforcement chain.

The current message lacks:

1. **Actionable instruction** - "Fix these violations" is never stated
2. **Policy context** - The Boy Scout Rule is not referenced
3. **Violation details** - The main agent doesn't see *which* violations remain
4. **File reference** - The file path is not included in the stderr message

### Solution

Enhance the exit 2 message in `multi_linter.sh` (currently line 849) to
include actionable instructions and violation context.

**Current** (line 849):

```bash
echo "[hook] ${remaining} violation(s) remain after delegation" >&2
```

**Proposed**:

```bash
# Collect remaining violations for the message
remaining_json=$(rerun_phase2_json "${file_path}" "${file_type}")
remaining_summary=$(echo "${remaining_json}" | jaq -r '.[] | "  - \(.linter) \(.code) at line \(.line): \(.message)"' 2>/dev/null | head -10)

cat >&2 <<EOF
[hook] ${remaining} violation(s) remain in ${file_path} after subprocess fix attempt.

Remaining violations:
${remaining_summary}

ACTION REQUIRED: Fix these violations using targeted Edit operations.
You own ALL violations in files you edit (Boy Scout Rule).
Do not modify linter config files to suppress violations.
EOF
```

### Changes Required

1. **`multi_linter.sh`** (~15 lines):
   - Add `rerun_phase2_json()` function that returns JSON (not just count)
   - Enhance the exit 2 block to include violation details and instructions
   - Include file path in the message
   - Add Boy Scout Rule reminder text

2. **Consideration**: The stderr message should stay concise. If >10 violations
   remain, truncate with "... and N more". The main agent doesn't need full
   JSON - a human-readable summary suffices.

### Acceptance Criteria

- [ ] Exit 2 message includes the file path
- [ ] Exit 2 message lists remaining violations (code, line, message)
- [ ] Exit 2 message includes "ACTION REQUIRED: Fix these violations"
- [ ] Exit 2 message includes Boy Scout Rule reference
- [ ] Exit 2 message truncates at 10 violations with "... and N more"
- [ ] Exit 0 behavior unchanged (silent success)
- [ ] `test_hook.sh --self-test` passes
- [ ] Manual test: create file with unfixable violations, verify enhanced message

### Impact

- **Without CLAUDE.md**: Main agent receives explicit fix instructions from the
  hook itself (self-contained enforcement)
- **With CLAUDE.md**: Message reinforces the documented policy
  (defense-in-depth)
- **Portability**: New projects using the hooks template get full enforcement
  without needing to write CLAUDE.md policy sections

### Related

- AIG-182: Multi-linter hook implementation
- AIG-200: Three-phase architecture
- AIG-203: Styled hook messages
- Portable hooks template: `.claude/plans/portable-hooks-template.md`

### Technical Notes

The `rerun_phase2()` function currently returns a violation count (integer).
Adding `rerun_phase2_json()` that returns the full JSON array is a small
change - it runs the same linters but captures output instead of counting.

The stderr output limit for Claude Code hooks is not documented. If the
message is too long, Claude Code may truncate it. Keep the summary concise
(~20 lines max).
