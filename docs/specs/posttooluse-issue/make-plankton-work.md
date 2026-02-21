# Make Plankton Work: Hook Feedback Loop Restoration

Executable plan to restore the multi-linter hook feedback loop.
Verification-first approach: triangulate the exact issue using hard
evidence before implementing any fix or workaround.

**Parent spec**: `posttoolusewrite-hook-stderr-silent-drop.md`
**Created**: 2026-02-21
**Corrected**: 2026-02-21 (mitmproxy evidence invalidated original plan;
spec:clarify review fixed test design, removed CLAUDE.md dependency,
streamlined diagnostic flow; code review confirmed bug was systemic
across all file types, added unverified terminal observations)
**Status**: Step 1 complete. Step 1.5 (jaq fix) pending. Step 2
(live verification) pending. Surface observations consistent with
fix but not hard evidence.

## Problem

The multi-linter hook (`multi_linter.sh`) runs after every Edit/Write
but the agent does not reliably act on violation feedback. Two
independent issues were identified:

1. **multi_linter.sh bug** (CONFIRMED, FIXED): `rerun_phase2()` produced
   garbled multi-line output (`56\n0`), causing bash syntax errors and
   unreadable system-reminder content delivered to the model
2. **Delivery mechanism** (CLARIFIED by mitmproxy): PostToolUse hook
   stderr+exit2 IS delivered to the model as a `<system-reminder>` text
   block — NOT in the `tool_result` field, but as an adjacent content
   block in the same API message

The original investigation incorrectly concluded that "all PostToolUse
output is unconditionally dropped" based on JSONL forensics and GitHub
issues. The JSONL format does not capture `<system-reminder>` text
blocks, creating a blind spot. Mitmproxy capture revealed the actual
delivery mechanism. See parent spec Correction Notice for details.

**Key open question**: Does the agent reliably act on clean (non-garbled)
system-reminder hook feedback? This has not been formally verified —
unverified terminal observations (see below) are consistent with YES
but do not constitute hard evidence.

## Evidence Hierarchy

Ranked by reliability. Higher-ranked evidence overrides lower-ranked.

| Rank | Source | What it shows | Limitation |
| ---- | ------ | ------------- | ---------- |
| 1 | **Mitmproxy capture** | stderr+exit2 IS in API request as system-reminder | Only tested 1 of 5 channels |
| 2 | **Debug logs** | Hook output parsed, enters "normal processing" path | Does not show API request body |
| 3 | **JSONL forensics** | tool_result never contains hook output | Does NOT capture system-reminder blocks |
| 4 | **GitHub issues** | Describe tool_result behavior | Do not account for system-reminder channel |
| 5 | **Terminal UI observations** | Hook fired, agent appeared to respond | Does not prove API delivery or causation |

Rule: Do not draw conclusions from rank 3-5 evidence that contradict
rank 1-2 evidence.

## Approach: Verify Before Fixing

### Hook State Requirements

Some steps require hooks **disabled** (editing protected files), others
require hooks **active** (testing hook behavior). Each step's header
includes a `**Hooks**:` line indicating the required state.

**Toggle workflow**: The user stops Claude Code and resumes the same
conversation with hooks disabled or enabled. Context is fully preserved
across the toggle — no session restart, no context loss. When Claude Code
reaches a step requiring a different hook state, it should ask the user:
"The next step requires hooks [ACTIVE/DISABLED]. Please resume with hooks
[enabled/disabled]."

**Transition map** (one toggle needed):

```text
Hooks DISABLED ──── Step 1.5 (edit protected file)
       │
  [user resumes with hooks enabled]
       │
Hooks ACTIVE ────── Steps 2, 3, 4 (test hook behavior)
```

### Decision Tree

```text
Step 1: Fix multi_linter.sh garbled output ──── DONE
          │
Step 1.5: Fix unprotected jaq calls in Phase 2 ──── PENDING [Hooks: DISABLED]
          │
Step 2: Live verification test (with HOOK_SKIP_SUBPROCESS=1) [Hooks: ACTIVE]
          │
          ├── Main agent acts on violations? ── YES ── DONE (problem was Step 1 bug)
          │
          NO
          │
Step 3: Diagnose WHY main agent ignores system-reminder [Hooks: ACTIVE]
          │
          ├── 3A: Mitmproxy: is clean output in system-reminder?
          │     └── NO ──── Fix multi_linter.sh output format
          │     └── YES ──── Continue to 3B
          │
          ├── 3B: Test with a MINIMAL hook (not multi_linter.sh)
          │     └── Minimal hook feedback acted on ── multi_linter.sh issue
          │     └── Minimal hook feedback ignored ── CC behavior issue
          │
Step 4: Decision based on Step 3 findings [Hooks: varies by option]
          │
          ├── CC behavior issue ──── Downgrade CC or file upstream
          └── multi_linter.sh issue ──── Fix the hook output format
```

---

## Step 1: Fix `rerun_phase2()` Multi-Line Count Bug

**Status**: COMPLETE (2026-02-21)
**Effort**: 30 min | **Risk**: None | **File**: `.claude/hooks/multi_linter.sh`

### Root Cause

The `|| echo "[]"` fallback in linter command captures appends `[]` to
valid JSON when linters exit non-zero on violations (normal behavior).
`jaq 'length'` then processes two JSON values, producing multi-line
output (`56\n0`).

### Changes Applied (9 total)

- Line 504: `|| echo "[]")` -> `) || true`
- Lines 510, 541, 561, 597, 986: `|| echo)` -> `) || true`
- Line 807: `|| echo "[]")` -> `) || biome_violations="[]"`
- Line 987: `|| echo)` -> `) || bandit_results="[]"`
- Line 1280: added `| tail -1`

**Why `|| true` not `|| v="[]"`**: Linters exit non-zero when they find
violations. `v=$(cmd)` captures stdout but propagates the exit code.
`|| v="[]"` would overwrite valid JSON. `|| true` suppresses the exit
code while preserving `v`.

### Verification Results

- `rerun_phase2` returns `1` for file with SC2034 (single-line integer)
- `rerun_phase2` returns `0` for clean file (single-line integer)
- Arithmetic comparison works without syntax errors
- `HOOK_SKIP_SUBPROCESS=1` test: exit 2 with clean violations JSON

### Code Review: Bug Was Systemic, Not Shell-Specific

Code review of `multi_linter.sh` (2026-02-21) confirms the `|| echo "[]"`
bug existed in `rerun_phase2()` for **all** file type handlers, not just
shell. Affected lines (pre-fix):

| Line | Handler | Pattern |
| ---- | ------- | ------- |
| 504 | Python (ruff) | `|| echo "[]")` |
| 510 | Python (ty) | `|| echo)` |
| 541 | Python (bandit) | `|| echo)` |
| 561 | **Shell (shellcheck)** | `|| echo)` |
| 597 | Dockerfile (hadolint) | `|| echo)` |
| 807 | TypeScript (biome) | `|| echo "[]")` |
| 986-987 | Python (bandit, main) | `|| echo)` |

All were fixed by Step 1. The initial Phase 2 collection in the main `case`
statement was already correct for all types (e.g., shell handler at line 1038
already used `|| true`). The bug was exclusively in the verification step.

All file types share the identical exit path (lines 1268-1287):
`HOOK_SKIP_SUBPROCESS` check → `spawn_fix_subprocess` → `rerun_phase1` →
`rerun_phase2` → `remaining` comparison → exit 0 or exit 2.

**Evidence type**: Structural (from code), not observational.

### Code Review: Unprotected jaq Calls in Phase 2 Collection

Separate from the Step 1 `rerun_phase2()` fix, the Phase 2 violation
**collection** step has unprotected jaq calls that can crash the hook
under `set -euo pipefail` (line 27).

**Symptom**: CC shows `PostToolUse:Edit hook error` (non-blocking) instead
of `PostToolUse:Edit hook returned blocking error` (blocking, exit 2).
When this happens, violation feedback is **lost** — CC does not feed
stderr to the model for exit codes other than 2.

**Affected jaq conversion calls** (no `|| true`, no `2>/dev/null`):

| Line | Handler | Call |
| ---- | ------- | ---- |
| 886 | Python (ty) | `ty_converted=$(... \| jaq '[.[] \| {...}]')` |
| 990 | Python (bandit) | `bandit_converted=$(... \| jaq '[.[] \| {...}]')` |
| 1041 | Shell (shellcheck) | `sc_converted=$(... \| jaq '[.[] \| {...}]')` |
| 1137 | Dockerfile (hadolint) | `hl_converted=$(... \| jaq '[.[] \| {...}]')` |

**Affected jaq merge calls** (13 total, all handlers):
Lines 811, 873, 894, 948, 973, 999, 1020, 1049, 1073, 1090, 1145, 1171,
1221 — all use `jaq -s '.[0] + .[1]'` with no fallback.

**Impact**: Hook crashes (exit 1), CC shows non-blocking error, violation
feedback lost for that Edit operation. The main agent may still fix
violations by reading the file directly, but this is coincidental — the
designed feedback loop is broken for that operation.

**Distinction from Step 1**: Step 1 fixed `rerun_phase2()` (the
verification step AFTER subprocess delegation). This finding is in the
Phase 2 collection step (BEFORE subprocess delegation). Both are in
`multi_linter.sh` but in different code paths.

**Status**: UNRESOLVED. Observed intermittently on shell Edit operations.
Systemic in code (all handlers affected), but only observed for shell.

**Evidence type**: Structural (from code) + terminal observation (rank 5).

---

## Step 1.5: Fix Unprotected jaq Calls in Phase 2 Collection

**Status**: PENDING
**Hooks**: DISABLED (edits protected file `.claude/hooks/multi_linter.sh`)
**Effort**: 30 min | **Risk**: None | **File**: `.claude/hooks/multi_linter.sh`
**Depends on**: Step 1 (complete)
**Blocks**: Step 2 (jaq crashes introduce confounding variables into the
live verification test)

### Why Before Step 2

The unprotected jaq calls (documented in "Code Review: Unprotected jaq
Calls" above) cause the hook to crash intermittently with exit 1. When
this happens:

- CC shows `PostToolUse:Edit hook error` (non-blocking)
- CC does NOT deliver stderr to the model (only exit 2 delivers stderr)
- Step 2 would incorrectly conclude "feedback loop broken"

Fixing these calls BEFORE Step 2 eliminates this confounding variable.

### Fix Patterns

Two categories require different handling:

**Conversion calls** (4 calls — lines 886, 990, 1041, 1137):
Failure means the linter's output couldn't be parsed. Safe fallback is
an empty array — skip that linter's results for this run.

```bash
# BEFORE (unprotected):
sc_converted=$(echo "${shellcheck_output}" | jaq '[.[] | {...}]')

# AFTER (protected):
sc_converted=$(echo "${shellcheck_output}" | jaq '[.[] | {...}]' \
  2>/dev/null) || sc_converted="[]"
```

**Merge calls** (13 calls — lines 811, 873, 894, 948, 973, 999, 1020,
1049, 1073, 1090, 1145, 1171, 1221):
Failure means two JSON arrays couldn't be merged. Critical: naive
`|| true` would set `collected_violations` to empty string, LOSING all
previously collected violations. Use a guarded assignment:

```bash
# BEFORE (unprotected — crash loses ALL violations):
collected_violations=$(echo "${collected_violations}" "${sc_converted}" \
  | jaq -s '.[0] + .[1]')

# AFTER (protected — preserves existing violations on failure):
_merged=$(echo "${collected_violations}" "${sc_converted}" \
  | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
[[ -n "${_merged}" ]] && collected_violations="${_merged}"
```

### Execution

Run with hooks disabled. After applying all fixes:

```bash
shellcheck .claude/hooks/multi_linter.sh
```

Verify zero new ShellCheck violations introduced by the fix.

### Verification

- [ ] All 4 conversion calls have `2>/dev/null) || var="[]"` fallback
- [ ] All 13 merge calls use guarded assignment pattern
- [ ] `shellcheck .claude/hooks/multi_linter.sh` — no new violations
- [ ] Manual test: `HOOK_SKIP_SUBPROCESS=1` + shell file with violations
  → hook exits 2 (not 1) and reports violation count

**Evidence type**: Structural (from code).

---

## Unverified Terminal Observations (2026-02-21)

The following terminal observations were collected during informal testing
AFTER the Step 1 fix. They are **not hard evidence** — they rank below
rank 4 in the Evidence Hierarchy (terminal UI does not prove API-level
delivery or causation).

**Caveat**: The main agent's apparent response to violations could be caused
by the system-reminder OR by the model reading the file and noticing issues
independently. Only mitmproxy (rank 1) can distinguish these.

| File type | Terminal output | Main agent response |
| --------- | -------------- | ------------------- |
| Python | `[hook] 14 violation(s) remain after delegation` | Thinking: "Let me read the current state of the file to see what violations need fixing" |
| TypeScript | `[hook] 5 violation(s) remain after delegation` | Thinking: "Let me check what types of violations remain." Made Edit calls replacing non-null assertions with guards. |
| Shell (Write) | `[hook] 156 violation(s) remain after delegation` | Thinking: "156 violations... Let me check what ShellCheck is flagging." |
| Shell (Edit) | `PostToolUse:Edit hook error` (non-blocking crash) | Agent continued fixing (likely from file reading, not hook feedback). Next Edit produced normal blocking error with 16 violations. |

**What these observations suggest (not prove)**:
- The hook fires and produces clean output for all three types on Write
- The main agent's behavior is consistent with acting on the system-reminder
- The issue does not appear to be shell-specific for Write operations
- Shell Edit operations intermittently crash the hook (see "Unprotected
  jaq Calls" finding above), losing violation feedback for that operation

**What these observations do NOT prove**:
- That the system-reminder was in the API request body
- That the main agent acted BECAUSE of the system-reminder
- That the feedback loop is reliable across different violation counts/types
- Whether the Edit crash is shell-specific or affects other handlers in practice

These observations are useful context for Step 2 (they suggest what the
outcome is likely to be) but do not substitute for it.

---

## Step 2: Live Verification Test

**Status**: PENDING (surface observations consistent with Step 1 being the
complete fix, but formal verification not yet performed)
**Hooks**: ACTIVE (testing hook feedback delivery to the main agent)
**Effort**: 15 min | **Risk**: None
**Depends on**: Step 1.5 (complete)

This is the decisive test. It determines whether the feedback loop
works now that multi_linter.sh produces clean output.

### 2A. Create a test file with known violations

```bash
cat > /tmp/test-hook-feedback.sh << 'EOF'
#!/bin/bash
unused_var="hello"
echo $unquoted_var
x=foo
EOF
chmod +x /tmp/test-hook-feedback.sh
```

This file has 3+ ShellCheck violations:
- SC2034: `unused_var` assigned but never used
- SC2086: `$unquoted_var` not quoted
- SC2034: `x` assigned but never used

### 2B. Start a Claude Code session with debug logging

```bash
cd ~/Documents/GitHub/plankton
HOOK_SKIP_SUBPROCESS=1 claude --debug hooks
```

**Why `HOOK_SKIP_SUBPROCESS=1`**: Without this, the hook's Phase 3 subprocess
(`claude -p`) will attempt to fix the violations internally. If the subprocess
fixes all 3 violations, the hook exits 0 and the main agent sees **nothing**
(no system-reminder). This would be a false negative — the hook worked, but
the main agent feedback loop was never tested. Setting this env var bypasses
Phase 3 so violations are always reported to the main agent via exit 2.

### 2C. Ask Claude to write the test file

```text
Write this exact content to /tmp/test-hook-feedback.sh:
#!/bin/bash
unused_var="hello"
echo $unquoted_var
x=foo
```

**Optional**: After the Write test completes, repeat with an Edit
operation on the same file to verify identical feedback behavior for
both tool types (per Investigation 1 in the parent spec).

### 2D. Observe three things

**Check 1 — Terminal UI**: Does a `PostToolUse:Write hook` message appear?

```text
Look for any of:
  - "PostToolUse:Write hook returned blocking error" (exit 2, designed)
  - "PostToolUse:Write hook error" (could be exit 2 per REFERENCE.md,
    or crash if exit 1 — check stderr content to disambiguate)
Expected: YES — some PostToolUse:Write message appears.
If NO PostToolUse message appears at all → hook didn't fire.
```

**Check 2 — Main agent behavior**: In the main agent's NEXT response
after the Write, does it acknowledge shellcheck violations from the
system-reminder AND make at least one Edit call to fix them?

```text
"Acts on violations" means BOTH:
  (a) The main agent's response text references the hook-reported violations
  (b) The main agent makes at least one Edit call to address them
Partial fix counts — the feedback loop is working even if not every
violation is resolved in a single pass.

If YES → Feedback loop works. STOP. Problem was Step 1 bug.
If NO  → Continue to Check 3.
```

**Check 3 — Debug log**: After the session, check the debug log for
the system-reminder delivery:

```bash
# Find the debug log
DEBUG_LOG=$(ls -t ~/.claude/debug/*.txt | head -1)

# Check for system-reminder with hook output
grep -A5 "system-reminder" "$DEBUG_LOG" | head -20

# Check for the "does not start with {" line and what follows
grep -A3 "does not start with" "$DEBUG_LOG"
```

### 2E. Interpretation matrix

| Check 1 (terminal) | Check 2 (main agent acts) | Check 3 (debug) | Conclusion |
| ------------------- | ------------------------- | ---------------- | ---------- |
| YES (exit 2) | YES | N/A | **DONE.** Problem was Step 1 bug. |
| YES (exit 2) | NO | system-reminder present | Main agent ignores system-reminder → Step 3 |
| YES (exit 2) | NO | no system-reminder | multi_linter.sh output not reaching API → Step 3A |
| CRASH (exit 1) | NO | N/A | Hook crashed (jaq or other) → fix Step 1.5 first |
| NO | NO | no hook execution | Hook not firing → debug hook registration |

**Note**: `HOOK_SKIP_SUBPROCESS=1` ensures the hook always exits 2 with
violations. Without this env var, a successful subprocess would cause exit 0
(no terminal error, no system-reminder), which is indistinguishable from
"hook not firing" in the matrix above.

### 2F. Optional: mitmproxy verification

If Check 2 is NO and you want definitive API-level evidence:

```bash
# Terminal 1: start mitmproxy
mitmweb --listen-port 8080

# Terminal 2: start Claude Code through proxy
HOOK_SKIP_SUBPROCESS=1 HTTPS_PROXY=http://localhost:8080 claude --debug hooks
```

Then repeat steps 2C-2D and inspect the API request body in mitmproxy
for the `<system-reminder>` text block content.

---

## Step 3: Diagnose Why Main Agent Ignores System-Reminder

**Status**: CONDITIONAL (only if Step 2 Check 2 is NO)
**Hooks**: ACTIVE (testing hook behavior and delivery mechanisms)
**Effort**: 1-2 hr | **Risk**: None

Only execute this step if the agent does NOT act on violations in Step
2. The goal is to triangulate the exact failure point.

### 3A. Verify clean output reaches the API

Run the mitmproxy verification (Step 2F). Inspect the `<system-reminder>`
text block in the API request body.

**Check**: Is the hook's stderr content present and readable?

```text
Expected (clean): "[hook] 3 violation(s) remain after delegation"
Bad (garbled):    "[hook] 56\n0 violation(s) remain after delegation"
Bad (truncated):  "[hook]"
Bad (absent):     No system-reminder block at all
```

| Result | Next action |
| ------ | ----------- |
| Clean, readable text | Continue to 3B |
| Garbled or truncated | Fix multi_linter.sh output → re-run Step 2 |
| No system-reminder block | The delivery mechanism differs from the verification test → 3B |

### 3B. Isolate: multi_linter.sh vs CC behavior

Test with a minimal hook to eliminate multi_linter.sh complexity:

```bash
# .claude/hooks/minimal-test-hook.sh
#!/bin/bash
echo "[hook] THIS FILE HAS 3 LINTING VIOLATIONS. Fix them NOW." >&2
exit 2
```

Register as PostToolUse:Write (temporarily replace multi_linter.sh
in settings.json). Run Step 2 again with this minimal hook.

| Result | Conclusion |
| ------ | ---------- |
| Main agent acts on minimal hook feedback | multi_linter.sh output format issue → fix the hook |
| Main agent ignores minimal hook feedback | CC behavior issue → Step 4 |

---

## Step 4: Decision Based on Diagnosis

**Status**: CONDITIONAL (only if Step 3 shows a CC behavior issue)
**Hooks**: ACTIVE for Option A (downgrade test), DISABLED for Option C
(editing hook/settings files)

### Option A: Downgrade Claude Code

If Step 3B shows the model ignores system-reminder content regardless
of hook complexity, and this is a CC behavior regression:

**Target version**: v2.1.31 (last version where issue #23381 confirms
`decision:block` reached the agent, even if duplicated).

```bash
# Check current version
claude --version

# Downgrade via Homebrew cask (installed at /opt/homebrew/bin/claude)
# Homebrew casks don't support @version — use the git history method:
cd "$(brew --repository homebrew/homebrew-cask)"
git log --oneline -- Casks/c/claude-code.rb | grep -i "2.1.31"
# Find the commit hash, then:
git checkout <COMMIT_HASH> -- Casks/c/claude-code.rb
brew reinstall --cask claude-code
git checkout HEAD -- Casks/c/claude-code.rb   # restore formula

# Prevent auto-update back to latest
export HOMEBREW_NO_AUTO_UPDATE=1

# Verify
claude --version
```

**Alternative**: Uninstall the cask and use npm for precise version control:

```bash
brew uninstall --cask claude-code
npm install -g @anthropic-ai/claude-code@2.1.31
# npm supports pinning: won't auto-update
claude --version
```

**Caveat from deep-research-report.md**: The report claims "downgrading
is not viable" because v2.1.31 had a duplication bug (#23381). However,
fact-checking against the actual issue reveals the duplication was
**cosmetic, not breaking**: two identical `<system-reminder>` blocks
were injected (wasting context tokens) but the output DID reach the
model and was acted upon. Issue #19009 separately confirms PostToolUse
exit 2 + stderr IS functional — the hook output is visible to Claude.
The deep research report's "not viable" assessment is overstated.

**Test after downgrade**: Re-run Step 2 on v2.1.31. If the main agent
acts on violations (even with duplicated messages), the downgrade is
sufficient.

**Risks of downgrade**:
- Lose 19 minor versions of fixes and features
- v2.1.31 may have other bugs fixed in later versions
- The duplication bug wastes context tokens (same message twice)
- Need to pin version to prevent auto-updates (`HOMEBREW_NO_AUTO_UPDATE=1` or switch to npm)

### Option B: File upstream issue

If the issue is clearly a CC behavior problem (system-reminder content
ignored by the model), file a focused upstream report:

**Title**: `PostToolUse stderr+exit2 delivered as system-reminder but
model does not act on it`

**Body must include**:
- Mitmproxy evidence showing the system-reminder IS delivered
- Evidence that the model ignores the content
- Comparison: PreToolUse structured feedback IS acted upon
- NOT the original "unconditionally dropped" framing (that's wrong)
- Cross-reference: #12151 (umbrella issue), #18427

**Do NOT**:
- Claim output is "silently dropped" (it's not — it's delivered
  via system-reminder)
- Reference the five-channel matrix as "all broken" (only
  tool_result is empty; system-reminder works for stderr+exit2)
- Include workaround details

### Option C: Implement PreToolUse gate (last resort)

Only if both A and B are impractical. Routes violation feedback
through the working PreToolUse channel (structured tool feedback
the agent reliably acts on).

Design is preserved in the parent spec's Strategy 4 section and
the original version of this file (git history).

---

## Files Modified

| File | Step | Change |
| ---- | ---- | ------ |
| `.claude/hooks/multi_linter.sh` | 1 | Fix `\|\| echo` (8x) + tail |
| `.claude/hooks/multi_linter.sh` | 1.5 | Protect jaq calls (4 conv + 13 merge) |
| `.claude/settings.json` | 3B (conditional) | Temporary minimal hook |

## Rollback

- **Step 1**: `git diff` shows exact lines changed in multi_linter.sh
- **Step 1.5**: `git diff` shows jaq error handling additions
- **Step 3B**: Restore original settings.json
- **Step 4A**: `brew reinstall --cask claude-code` (or `npm install -g @anthropic-ai/claude-code@latest` if switched to npm)

## Success Criteria

- [x] `remaining` variable is always a single integer (no `\n0` suffix)
- [x] Hook error message is clean: `[hook] N violation(s) remain`
- [ ] Step 1.5: All 17 unprotected jaq calls have error handling
- [ ] Step 1.5: `shellcheck multi_linter.sh` — no new violations
- [ ] Step 2 executed: live test with `HOOK_SKIP_SUBPROCESS=1`
- [ ] Main agent acknowledges violations AND makes Edit call(s) to fix
- [ ] OR: Root cause identified if main agent does NOT act (Step 3)
- [ ] OR: Downgrade/upstream issue resolves the feedback loop (Step 4)

## Key Principle

**Verify the actual problem before implementing workarounds.** The
original investigation jumped from JSONL evidence (incomplete) and
GitHub issues (unreviewed) to a PreToolUse gate workaround without
testing whether the existing delivery mechanism works when the hook
produces clean output. Step 2 is the test that should have been run
first.

---

## References

- Mitmproxy verification: `cc-trace/verification-report.md`
- Parent spec: `posttoolusewrite-hook-stderr-silent-drop.md`
- Deep research: `deep-research-regression-report.md`
- JSONL bisection: `jsonl-version-bisection.md`
- [Claude Code issue #12151 - Umbrella hook output issue](https://github.com/anthropics/claude-code/issues/12151)
- [Claude Code issue #18427 - PostToolUse cannot inject context](https://github.com/anthropics/claude-code/issues/18427)
- [Claude Code issue #23381 - PostToolUse output duplicated in v2.1.31](https://github.com/anthropics/claude-code/issues/23381)
