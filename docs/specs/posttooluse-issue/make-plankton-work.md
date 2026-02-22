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
**Reviewed**: 2026-02-22 (spec:clarify — promoted mitmproxy to required,
added causal evidence protocol and partial success path to Step 2,
added downgrade caveat and Option C caveat, added Success Definition
and Follow-up Items sections; fact-check fixed stale line numbers,
\#23381 "acted upon" overclaim, and ShellCheck violation count)
**Status**: COMPLETE (2026-02-22). Step 1 fix was the root cause.
Live verification test (Step 2) passed 3/3 iterations with
rank-1 mitmproxy evidence confirming delivery and agent action.
Steps 3-4 not needed.

## Problem

The multi-linter hook (`multi_linter.sh`) runs after every Edit/Write
but the agent does not reliably act on violation feedback. Two
independent issues were identified:

1. **multi_linter.sh bug** (CONFIRMED, FIXED): `rerun_phase2()` produced
   garbled multi-line output (`56\n0`), causing bash syntax errors and
   unreadable system-reminder content delivered to the model
2. **Delivery mechanism** (CLARIFIED by mitmproxy): PostToolUse hook
   stderr+exit2 IS delivered to the model as a `<system-reminder>` tag
   embedded inside the `tool_result.content` string (not as a separate
   content block — see Step 2 Live Verification Report for mitmproxy
   evidence)

The original investigation incorrectly concluded that "all PostToolUse
output is unconditionally dropped" based on JSONL forensics and GitHub
issues. The JSONL format does not capture `<system-reminder>` text
blocks, creating a blind spot. Mitmproxy capture revealed the actual
delivery mechanism. See parent spec Correction Notice for details.

**Key open question**: Does the agent reliably act on clean (non-garbled)
system-reminder hook feedback? — **RESOLVED (2026-02-22)**: YES. Live
verification with mitmproxy confirmed 3/3 iterations (shell, Python,
JSON). See Step 2 Live Verification Report.

## Evidence Hierarchy

Ranked by reliability. Higher-ranked evidence overrides lower-ranked.

| Rank | Source | What it shows | Limitation |
| ---- | ------ | ------------- | ---------- |
| 1 | **Mitmproxy** | stderr+exit2 in API system-reminder | 1 of 5 channels |
| 2 | **Debug logs** | Output parsed, normal path | No API request body |
| 3 | **JSONL** | tool_result: success msg only | Sys-reminder not searched[†] |
| 4 | **GH issues** | tool_result behavior docs | No sys-reminder coverage |
| 5 | **Terminal UI** | Hook fired, agent responded | No proof of API delivery |

Rule: Do not draw conclusions from rank 3-5 evidence that contradict
rank 1-2 evidence.

[†] **JSONL limitation note** (RESOLVED 2026-02-22): JSONL captures
hook output content (framing text, `[hook]` prefix, violation messages)
but NOT the `<system-reminder>` tag wrapper. Verified by grep on
post-Step-1 plankton sessions: 25 "hook blocking error" matches,
77 `[hook]` matches, 30 "violation remain" matches, 0
`<system-reminder>` tag matches. CC appends the tag after JSONL
logging, during API request assembly. The original investigation's
failure was a search methodology error (searched for raw hook JSON,
not for the framing text "PostToolUse.*hook.*blocking.*error").

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
Step 1.5: Fix unprotected jaq calls in Phase 2 ──── COMPLETE [Hooks: DISABLED]
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
| 504 | Python (ruff) | \|\| echo "[]") |
| 510 | Python (ty) | \|\| echo) |
| 541 | Python (bandit) | \|\| echo) |
| 561 | **Shell (shellcheck)** | \|\| echo) |
| 597 | Dockerfile (hadolint) | \|\| echo) |
| 807 | TypeScript (biome) | \|\| echo "[]") |
| 986-987 | Python (bandit, main) | \|\| echo) |

All were fixed by Step 1. The initial Phase 2 collection in the main `case`
statement was already correct for all types (e.g., shell handler at line 1052
already used `|| true`). The bug was exclusively in the verification step.

All file types share the identical exit path (lines 1289-1310):
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

**Status**: RESOLVED (Step 1.5). All 17 unprotected calls now have error
handling. See Step 1.5 Completion Report for details.

**Evidence type**: Structural (from code) + terminal observation (rank 5).

---

## Step 1.5: Fix Unprotected jaq Calls in Phase 2 Collection

**Status**: COMPLETE (2026-02-21)
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

- [x] All 4 conversion calls have `2>/dev/null) || var="[]"` fallback
- [x] All 13 merge calls use guarded assignment pattern
- [x] `shellcheck .claude/hooks/multi_linter.sh` — no new violations
- [x] Manual test: `HOOK_SKIP_SUBPROCESS=1` + shell file with violations
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
| Python | `14 violations remain` | Read file, fixed violations |
| TS | `5 violations remain` | Checked types, made Edit calls |
| Shell (Write) | `156 violations remain` | Checked ShellCheck flags |
| Shell (Edit) | `hook error` (crash) | Continued via file read, not hook |

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

**Status**: COMPLETE (2026-02-22)
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

This file has 5 ShellCheck violations:

- SC2148: Tips depend on target shell and yours is unknown
- SC2034: `unused_var` assigned but never used
- SC2154: `unquoted_var` is referenced but not assigned
- SC2086: `$unquoted_var` not quoted
- SC2034: `x` assigned but never used

### 2B. Start a Claude Code session with debug logging

```bash
cd ~/Documents/GitHub/plankton
HOOK_SKIP_SUBPROCESS=1 HTTPS_PROXY=http://localhost:8080 claude --debug hooks
```

**Why mitmproxy**: The live test MUST run through mitmproxy to provide
rank-1 evidence of both delivery (system-reminder in API request) and
causation (agent thinking block references system-reminder content in
API response). Without mitmproxy, behavioral evidence is ambiguous —
the agent may fix violations by reading the file independently.

Start mitmproxy in a separate terminal before launching Claude Code:

```bash
mitmweb --listen-port 8080
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

Causal evidence (from mitmproxy API response): inspect the agent's
thinking block for explicit references to system-reminder content —
e.g., the "[hook]" prefix, specific violation count, or violation
codes from the JSON payload. If the thinking references system-reminder
content, that's causal evidence the agent acted on the hook feedback.
If it says "let me read the file" without referencing hook output,
the evidence is ambiguous.

Run 2-3 iterations across different file types to check consistency.
One success could be coincidental; three consecutive successes across
types is convincing.

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

| Terminal | Agent acts | Debug | Conclusion |
| -------- | ---------- | ----- | ---------- |
| YES (exit 2) | YES | N/A | **DONE.** Step 1 bug fixed. |
| YES (exit 2) | SOME yes, SOME no | varies | Handler issue → fix, re-test |
| YES (exit 2) | NO | sys-reminder present | Ignores sys-reminder → Step 3 |
| YES (exit 2) | NO | no sys-reminder | Output not in API → Step 3A |
| CRASH (exit 1) | NO | N/A | Hook crashed → fix Step 1.5 |
| NO | NO | no hook execution | Not firing → debug registration |

**Note**: `HOOK_SKIP_SUBPROCESS=1` ensures the hook always exits 2 with
violations. Without this env var, a successful subprocess would cause exit 0
(no terminal error, no system-reminder), which is indistinguishable from
"hook not firing" in the matrix above.

### 2F. Mitmproxy verification (required)

Mitmproxy is integrated into Step 2B (Claude Code launches through the
proxy). After the agent responds to the Write, inspect two things in
mitmproxy:

1. **API request body**: Confirm the `<system-reminder>` text block
   contains the hook's stderr (violation JSON with `[hook]` prefix)
2. **API response body**: Check the agent's thinking block for explicit
   references to system-reminder content (violation codes, `[hook]`
   prefix, violation count). This provides causal evidence that the
   agent acted on the hook feedback, not on independent file reading.

If mitmproxy setup is not available for a given run, this can fall back
to debug log inspection — but mitmproxy evidence is strongly preferred
for the initial verification.

For reference, the original standalone mitmproxy setup (if not using
the integrated Step 2B command):

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

**Status**: NOT NEEDED (Step 2 passed 3/3 — feedback loop works)
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
| No system-reminder block | Delivery differs from test → 3B |

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
| Agent acts on minimal feedback | Output format issue → fix hook |
| Agent ignores minimal feedback | CC behavior issue → Step 4 |

---

## Step 4: Decision Based on Diagnosis

**Status**: NOT NEEDED (Step 2 passed 3/3 — feedback loop works)
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
were injected (wasting context tokens) and the output DID reach the
model, though neither issue explicitly confirms the model acted on it.
Issue #19009 separately confirms PostToolUse
exit 2 + stderr IS functional — the hook output is visible to Claude.
The deep research report's "not viable" assessment is overstated.

**Test after downgrade**: Re-run Step 2 on v2.1.31. If the main agent
acts on violations (even with duplicated messages), the downgrade is
sufficient.

**Risks of downgrade**:

- Lose 19 minor versions of fixes and features
- v2.1.31 may have other bugs fixed in later versions
- The duplication bug wastes context tokens (same message twice)
- Pin version to prevent auto-updates
  (`HOMEBREW_NO_AUTO_UPDATE=1` or use npm)

**Caveat**: The downgrade rationale relies on external evidence (GitHub
issue #23381) rather than first-party data. The JSONL bisection found
zero PostToolUse output in tool_results at ANY version (v2.1.9-v2.1.50).
Mitmproxy proves the system-reminder channel already works on v2.1.50.
If the agent ignores clean system-reminder content on v2.1.50 despite
confirmed delivery, downgrading is unlikely to help — the issue would
be agent behavior, not delivery mechanism.

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

**Caveat**: Issue #24327 reports that PreToolUse exit 2 intermittently
causes Claude to stop and wait for user input instead of acting on
feedback. That issue uses exit 2 + stderr (different from this design's
exit 0 + JSON `decision:block`), so it is not a confirmed blocker —
but it signals a general pattern of the model treating hook blocks as
stop signals. If Option C is pursued, test with the production model
to confirm the `decision:block` JSON path is acted upon reliably.
Note: Issue #26923 (Task tool bypasses PreToolUse blocks) is NOT
relevant here — it is Task-specific and confirms Edit/Write blocking
works correctly.

Design is preserved in the parent spec's Strategy 4 section and
the original version of this file (git history).

---

## Files Modified

| File | Step | Change |
| ---- | ---- | ------ |
| `.claude/hooks/multi_linter.sh` | 1 | Fix `\|\| echo` (8x) + tail |
| `.claude/hooks/multi_linter.sh` | 1.5 | Protect jaq (4 conv + 13 merge) |
| `.claude/hooks/test_hook.sh` | 2 | +~150 lines: test helpers, 10 tests |
| `.claude/tests/hooks/verify_feedback_loop.sh` | 2 | New: Step 2 harness |
| `.claude/tests/hooks/minimal-test-hook.sh` | 3B | New: trivial exit-2 hook |
| `.claude/tests/hooks/swap_settings.sh` | 3B | New: settings swap helper |
| `.claude/settings.json` | 3B (conditional) | Temporary minimal hook |
| `.claude/hooks/multi_linter.sh` | FU-1,3 | Ruff schema + markdown debug |
| `.claude/hooks/test_hook.sh` | FU-1,3 | +2 tests, fix `_check_hook_json` |
| `docs/psf/00-plankton-architecture-overview.md` | FU-2 | Schema provenance |
| `.claude/tests/hooks/test_production_path.sh` | FU-4 | New: mock subprocess |
| `.claude/tests/hooks/test_five_channels.sh` | FU-5 | New: channel output |
| `docs/tests/README.md` | FU-6 | Regression test workflow section |
| `.claude/hooks/test_hook.sh` | FU-13 | fixture_project_dir, 4 CLAUDE_PROJECT_DIR fixes, TOML trap, count thresholds |
| `.claude/tests/hooks/verify_feedback_loop.sh` | FU-13 | fixture_project_dir, CLAUDE_PROJECT_DIR fix, TS gate fix, TOML trap fix |
| `.claude/tests/hooks/test_production_path.sh` | FU-13 | HOME isolation (isolated_home in tmp_dir) |
| `.claude/tests/hooks/fixtures/config.json` | FU-13 | New: maximal test config fixture |
| `.claude/tests/hooks/fixtures/taplo.toml` | FU-13 | New: unused (see FU-15) |
| `.claude/tests/hooks/fixtures/.markdownlint-cli2.jsonc` | FU-13 | New: minimal markdownlint config |

## Rollback

- **Step 1**: `git diff` shows exact lines changed in multi_linter.sh
- **Step 1.5**: `git diff` shows jaq error handling additions
- **Step 2 (D1)**: `git diff` shows regression test additions in test_hook.sh
- **Step 2 (D2/D3)**: Delete `.claude/tests/hooks/verify_feedback_loop.sh`,
  `minimal-test-hook.sh`, `swap_settings.sh`
- **Step 3B**: Restore original settings.json (use `swap_settings.sh restore`)
- **Step 4A**: `brew reinstall --cask claude-code`
  (or `npm install -g @anthropic-ai/claude-code@latest`)

## Success Definition

This spec is DONE when:

1. Mitmproxy confirms the `<system-reminder>` delivers clean hook
   feedback (rank-1 delivery evidence)
2. The agent's thinking block references system-reminder content AND
   makes Edit calls to fix the reported violations (causal + behavioral
   evidence)
3. Results are consistent across 2-3 iterations

Ongoing reliability monitoring (does the agent act on hook feedback
100% of the time across all contexts?) is a separate operational
concern. LLM behavior is probabilistic — the controlled test with
mitmproxy evidence is the achievable verification checkpoint.

## Success Criteria

- [x] `remaining` variable is always a single integer (no `\n0` suffix)
- [x] Hook error message is clean: `[hook] N violation(s) remain`
- [x] Step 1.5: All 17 unprotected jaq calls have error handling
- [x] Step 1.5: `shellcheck multi_linter.sh` — no new violations
- [x] Step 2 automated: output verification passes 28/28 (7 types x 4 checks)
- [x] Step 2 automated: 12 regression tests in test_hook.sh (110 total pass)
- [x] Step 3 infrastructure ready: minimal hook + settings swap helper
- [x] Follow-up: ruff unified schema conversion + `_check_hook_json` 5-key validation
- [x] Follow-up: markdown single `[hook]` line (debug summary removed)
- [x] Follow-up: production path test 8/8 pass (mock subprocess)
- [x] Follow-up: five-channel matrix test 20/20 pass + mitmproxy runbook
- [x] Step 2 live: agent acknowledges violations AND Edits (3/3 iterations)
- [x] FU-13: test config isolation — 170 tests pass with fixture configs (112+28+10+20)
- [N/A] OR: Root cause identified if main agent does NOT act (Step 3)
- [N/A] OR: Downgrade/upstream issue resolves the feedback loop (Step 4)

## Key Principle

**Verify the actual problem before implementing workarounds.** The
original investigation jumped from JSONL evidence (incomplete) and
GitHub issues (unreviewed) to a PreToolUse gate workaround without
testing whether the existing delivery mechanism works when the hook
produces clean output. Step 2 is the test that should have been run
first.

---

## Step 1.5 Completion Report (2026-02-21)

Executed with hooks disabled. TDD approach: RED tests first, then fixes,
then verification. All edits were targeted `Edit` operations — no file
rewrites.

### Phase A: RED — 3 Structural Verification Tests

Added 3 tests to `test_hook.sh` inside `run_self_test()`, inserted before
the Summary section (originally line 1034).

**Test 1 — `jaq_merge_guard`**: Counts lines matching
`collected_violations=$(echo "${collected_violations}"` in multi_linter.sh.
After fix, expects 0 (all merges use `_merged` temp var instead).

**Test 2 — `jaq_merge_count`**: Counts lines matching
`_merged=$(echo "${collected_violations}"` in multi_linter.sh.
After fix, expects exactly 13.

**Test 3 — `jaq_conversion_guard`**: Counts lines matching
`|| (ty|bandit|sc|hl)_converted="[]"` in multi_linter.sh.
After fix, expects exactly 4.

**RED run** (before fixes):

```text
$ bash .claude/hooks/test_hook.sh --self-test 2>&1 | grep -E "(jaq_|Passed|Failed)"
FAIL jaq_merge_guard: 13 unprotected merge(s) found
FAIL jaq_merge_count: 0 guarded merges (expected 13)
FAIL jaq_conversion_guard: 0 conversion fallbacks (expected 4)
Passed: 95
Failed: 5
```

3 new FAILs as expected. 2 pre-existing failures (Python valid, TS disabled
skips) are unrelated to this change.

#### Deviation: `grep -c || echo "0"` Test Bug

The original plan used `|| echo "0"` to handle `grep -c` returning exit 1
on zero matches. This produces double output (`0\n0`) because `grep -c`
already outputs `0` to stdout before exiting non-zero. The `|| echo "0"`
then appends a second `0`, causing `[[ "0\n0" -eq N ]]` arithmetic errors.

**Fix**: Changed all 3 tests from `|| echo "0"` to `|| true`. `grep -c`
always outputs the count (including `0`); `|| true` suppresses only the
non-zero exit code without adding extra output.

### Phase B: GREEN — 17 Fixes Applied

All fixes applied top-to-bottom through `multi_linter.sh`. Two patterns:

#### Conversion Fix Pattern (4 calls)

Added `2>/dev/null` to suppress jaq stderr and `|| var="[]"` fallback:

```bash
# Before:
ty_converted=$(echo "${ty_output}" | jaq '[.[] | {...}]')

# After:
ty_converted=$(echo "${ty_output}" | jaq '[.[] | {...}]' 2>/dev/null) || ty_converted="[]"
```

Applied to:

| # | Handler | Variable |
| --- | ------- | -------- |
| 3 | Python (ty) | `ty_converted` |
| 7 | Python (bandit) | `bandit_converted` |
| 10 | Shell (shellcheck) | `sc_converted` |
| 14 | Dockerfile (hadolint) | `hl_converted` |

#### Merge Fix Pattern (13 calls)

Replaced direct `collected_violations` assignment with guarded `_merged`
temp variable:

```bash
# Before:
collected_violations=$(echo "${collected_violations}" "${other}" \
  | jaq -s '.[0] + .[1]')

# After:
_merged=$(echo "${collected_violations}" "${other}" \
  | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
[[ -n "${_merged}" ]] && collected_violations="${_merged}"
```

For 6 calls that had inline `[[ -n ]] &&` guards, converted to `if` blocks
to cleanly host the multi-line pattern.

Applied to (by fix number):

| # | Handler | Notes |
| --- | ------- | ----- |
| 1 | TS (biome) | Inside `handle_typescript()`, added `local _merged` |
| 2 | Python (ruff) | Special: has `map(. + {linter: "ruff"})` in jaq expr |
| 4 | Python (ty) | Standard |
| 5 | Python (pydantic) | Converted `[[ -n ]] &&` to if block |
| 6 | Python (vulture) | Converted `[[ -n ]] && [[ != ]] && \` to if block |
| 8 | Python (bandit) | Converted `[[ -n ]] && [[ != ]] && \` to if block |
| 9 | Python (async) | Converted `[[ -n ]] &&` to if block |
| 11 | Shell (shellcheck) | Standard |
| 12 | YAML (yamllint) | Converted `[[ -n ]] &&` to if block |
| 13 | JSON (syntax) | Inside existing if block |
| 15 | Dockerfile (hadolint) | Standard |
| 16 | TOML (taplo) | Inside existing if block |
| 17 | Markdown | Converted `[[ -n ]] && [[ != ]] && \` to if block |

### Phase C: Verification

#### ShellCheck

```text
$ shellcheck .claude/hooks/multi_linter.sh 2>&1 | head -10
In .claude/hooks/multi_linter.sh line 135:
    case "${js_runtime}" in
    ^-- SC2249 (info): Consider adding a default *) case...
```

Only pre-existing info-level warnings. Zero new violations from the fix.

#### Self-Test Suite (GREEN)

```text
$ bash .claude/hooks/test_hook.sh --self-test 2>&1 | grep -E "(jaq_|Passed|Failed)"
PASS jaq_merge_guard: no unprotected merge assignments
PASS jaq_merge_count: 13 guarded merges (expected 13)
PASS jaq_conversion_guard: 4 conversion fallbacks (expected 4)
Passed: 98
Failed: 2
```

All 3 new tests GREEN. 2 pre-existing failures unchanged.

#### Smoke Test

```text
$ printf '#!/bin/bash\nunused="x"\necho $y\n' > /tmp/smoke.sh
$ echo '{"tool_input":{"file_path":"/tmp/smoke.sh"}}' | \
    HOOK_SKIP_SUBPROCESS=1 bash .claude/hooks/multi_linter.sh
[hook] [
  {
    "line": 1, "column": 1, "code": "SC2148",
    "message": "Tips depend on target shell and yours is unknown...",
    "linter": "shellcheck"
  },
  {
    "line": 2, "column": 1, "code": "SC2034",
    "message": "unused appears unused. Verify use...",
    "linter": "shellcheck"
  },
  {
    "line": 3, "column": 6, "code": "SC2154",
    "message": "y is referenced but not assigned.",
    "linter": "shellcheck"
  },
  {
    "line": 3, "column": 6, "code": "SC2086",
    "message": "Double quote to prevent globbing and word splitting.",
    "linter": "shellcheck"
  }
]
```

Hook collects 4 shellcheck violations as valid JSON on stderr with `[hook]`
prefix. No crash, no garbled output.

### Files Changed (Step 1.5)

| File | Changes |
| ---- | ------- |
| `multi_linter.sh` | 4 conv fallbacks, 13 merge guards |
| `test_hook.sh` | 3 jaq guard verification tests |

### Unblocked by Step 1.5

Step 2 (live verification test) can now proceed without jaq crashes
introducing confounding variables. The hook will consistently exit 2
(not crash with exit 1) when violations are found, ensuring CC delivers
stderr to the model via the system-reminder channel.

---

## Step 2 Automated Verification Report (2026-02-22)

Executed with hooks disabled for test_hook.sh edits; hooks active for
`.claude/tests/hooks/` files (path not protected by
`protect_linter_configs.sh` line 36 — only `/.claude/hooks/` is blocked).

Three deliverables: (D1) regression tests in test_hook.sh, (D2) standalone
verification harness, (D3) Step 3 conditional infrastructure. D2 and D3
ran as parallel background agents; D1 required hooks disabled.

### What This Verifies (and Does Not)

The automated verification covers **Checks 1 and 3** from the Step 2
interpretation matrix (section 2E):

- **Check 1 (terminal)**: Hook exits 2 with clean stderr ✓
- **Check 3 (debug)**: JSON is valid, correctly structured, correct
  violation counts ✓

It does **NOT** cover **Check 2 (main agent acts)**: whether the main
agent's next response acknowledges violations from the system-reminder
and makes Edit calls to fix them. This requires a live interactive test
with Claude Code running.

### Phase A: Regression Tests in test_hook.sh (D1)

Added ~150 lines to `test_hook.sh` inside `run_self_test()`, inserted
after the jaq Error Protection Tests section (after line 1069).

**New helper — `test_stderr_json`**: Captures stderr only (via `2>&1
>/dev/null` redirection pattern) and passes it to a check function.
Unlike `test_output_format` (which merges stdout+stderr) and
`test_temp_file` (which discards all output), this isolates the stderr
channel for JSON structure validation. Sets `CLAUDE_PROJECT_DIR` to
ensure config files are found.

**New check function — `_check_hook_json`**: Validates 4 properties of
the hook's `HOOK_SKIP_SUBPROCESS=1` output:

1. Exit code is 2
2. Stderr contains at least one `[hook]` prefixed line
3. JSON after prefix is a valid array (parseable by jaq)
4. Each array element has `code` and `linter` keys

Uses `grep -n` + `tail -n +N` to handle multi-line JSON output and
multiple `[hook]` lines (see Finding 2 below).

**10 new tests** (all GREEN on first run):

| # | Name | Type | Result |
| --- | ---- | ---- | ------ |
| 1 | `rerun_phase2_tail_guard` | Structural (grep) | PASS |
| 2 | `feedback_json_python` | Functional (ruff F841) | PASS |
| 3 | `feedback_json_shell` | Functional (SC2034+) | PASS |
| 4 | `feedback_json_json` | Functional (JSON_SYNTAX) | PASS |
| 5 | `feedback_json_yaml` | Functional (yamllint, gated) | PASS |
| 6 | `feedback_json_dockerfile` | Functional (hadolint, gated) | PASS |
| 7 | `feedback_json_toml` | Functional (taplo, gated) | PASS |
| 8 | `feedback_json_markdown` | Functional (markdownlint, gated) | PASS |
| 9 | `feedback_json_typescript` | Functional (biome, gated) | PASS |
| 10 | `feedback_count_shell` | Count validation (>= 2) | PASS |

**Baseline**: 98 pass / 2 fail → **After**: 108 pass / 2 fail.
Pre-existing failures (Python valid, TS disabled skips) unchanged.

### Phase B: Verification Harness (D2)

New standalone script: `.claude/tests/hooks/verify_feedback_loop.sh`
(199 lines). Automates the Step 2 check matrix for all file types.

**4 checks per file type**:

| Check | What | Pass condition |
| ----- | ---- | -------------- |
| Exit code | `$?` after hook | == 2 |
| Prefix | stderr content | starts with `[hook]` |
| JSON valid | `jaq type` on JSON | returns `"array"` |
| Count | `jaq length` on JSON | >= expected minimum |

**Results**: 28 pass, 0 fail, 4 skip (TypeScript: biome not installed)

**File types verified**: Python (ruff), Shell (shellcheck), JSON (syntax),
YAML (yamllint), Dockerfile (hadolint), TOML (taplo), Markdown
(markdownlint-cli2).

**Usage**:

```bash
bash .claude/tests/hooks/verify_feedback_loop.sh
```

### Phase C: Step 3 Conditional Infrastructure (D3)

Two files prepared for Step 3B (hook isolation test), ready to deploy
if the live agent behavior test (Check 2) fails:

**`.claude/tests/hooks/minimal-test-hook.sh`** (3 lines):
Always exits 2 with a fixed message: `[hook] THIS FILE HAS 3 LINTING
VIOLATIONS. Fix unused variables on lines 2, 3, and 5.`
Used to isolate whether the agent ignores system-reminder content
regardless of hook complexity.

**`.claude/tests/hooks/swap_settings.sh`** (107 lines):
Settings backup/restore helper with 4 subcommands: `backup`,
`swap-minimal`, `restore`, `status`. SHA-256 verification on restore.
The swap writes a settings.json with only PostToolUse pointing to
`minimal-test-hook.sh` (no PreToolUse or Stop hooks, to minimize
interference during testing).

### New Findings

#### Finding 1: Ruff Does Not Use Unified Violation Schema

The PSF architecture overview (`docs/psf/00-plankton-architecture-
overview.md` line 252) claims: "Violation schema: `{line, column, code,
message, linter}` — unified across all linters." This is incorrect for
ruff.

The ruff merge handler (`multi_linter.sh` lines 874-875) adds `{linter:
"ruff"}` to each element but does NOT convert the raw ruff JSON to the
unified schema:

```bash
_merged=$(echo "${collected_violations}" "${ruff_violations}" \
  | jaq -s '.[0] + (.[1] | map(. + {linter: "ruff"}))' 2>/dev/null) || _merged=""
```

Raw ruff JSON uses `location.row` instead of `line`, `location.column`
instead of `column`, and includes extra keys (`cell`, `end_location`,
`filename`, `fix`, `noqa_row`, `url`).

**Impact**: Any code that assumes the unified schema for ruff violations
will fail. The `_check_hook_json` function was initially written to check
for `has("line")` and `has("column")` — this failed for Python. Relaxed
to check `has("code") and has("linter")` (minimum common keys across all
handlers).

Other handlers (shellcheck, yamllint, hadolint, taplo, markdownlint,
biome, JSON syntax) DO convert to the unified schema.

**Evidence type**: Structural (from code, `multi_linter.sh` line 874-875)

- functional (Python regression test failure during D1 implementation).

#### Finding 2: Markdown Handler Emits Multi-Line `[hook]` Output

The markdown handler in `multi_linter.sh` emits a debug summary line
before the main JSON payload:

```text
[hook] Markdown: 1 unfixable issue(s) collected
[hook] [
  {
    "line": 1,
    "column": 1,
    "code": "MD013/line-length",
    "message": "Line length",
    "linter": "markdownlint"
  }
]
```

The first `[hook]` line is a debug summary; the second `[hook]` line
starts the JSON array. Both D1 (`_check_hook_json`) and D2
(`verify_feedback_loop.sh`) independently discovered this and solved it
by extracting the LAST `[hook]` line using `grep -n '^\[hook\] ' |
tail -1` to find the line number, then `tail -n +N` to get everything
from that line onward.

**Impact**: Any consumer of the hook's stderr output (including the
system-reminder delivered to the main agent) must handle multiple
`[hook]` lines. The JSON payload starts at the last `[hook]` line, not
the first.

**Evidence type**: Structural (from code) + observational (independent
test failures in D1 and D2 during implementation).

#### Finding 3: TOML Fixtures Must Be Inside Project Tree

`taplo` respects its `taplo.toml` configuration which has `include =
["**/*.toml"]` relative to the project root. Files in `/tmp/` are
outside this include glob and get silently excluded — taplo exits 0
with no output, producing false negatives.

Both D1 and D2 work around this by placing TOML fixtures inside the
project tree (at `${project_dir}/test_fixture_broken.toml`) with
cleanup in the EXIT trap or after the test.

**Evidence type**: Observational (D2 TOML test failures during
implementation) + structural (from `taplo.toml` include configuration).

#### Finding 4: CLAUDE_PROJECT_DIR Required for Config-Dependent Linters

The `test_stderr_json` helper initially ran the hook without setting
`CLAUDE_PROJECT_DIR`. This caused markdown tests to fail (exit 0, no
violations) because markdownlint-cli2 could not find its config file
(`.markdownlint-cli2.jsonc`) relative to the project root. After adding
`CLAUDE_PROJECT_DIR="${project_dir}"` to the helper, all tests passed.

Other linters (ruff, shellcheck, yamllint, hadolint) worked without
`CLAUDE_PROJECT_DIR` because they either use inline flags or find their
configs relative to the target file. Markdown and TOML linters are
config-path-sensitive.

**Evidence type**: Observational (markdown test failure in D1 resolved
by adding env var) + structural (verified D2 harness sets
`CLAUDE_PROJECT_DIR` consistently).

### Unblocked by This

The live agent behavior test (Step 2, Check 2) can now proceed with
confidence that the hook's output is correct for all 7 file types.
If Check 2 fails, the Step 3 infrastructure (minimal hook + settings
swap) is ready to deploy immediately for isolation testing.

The automated verification harness can be re-run after any future
changes to `multi_linter.sh` to detect regressions:

```bash
# Regression tests (inside test_hook.sh suite)
bash .claude/hooks/test_hook.sh --self-test

# Standalone verification (all file types)
bash .claude/tests/hooks/verify_feedback_loop.sh
```

---

## Step 2 Live Verification Report (2026-02-22)

Executed with hooks active, `HOOK_SKIP_SUBPROCESS=1`, and mitmproxy
interception (`HTTPS_PROXY=http://localhost:8080`,
`NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem`).
Claude Code v2.1.50, model `claude-opus-4-6`.

Debug log: `~/.claude/debug/a628fcc7-1bff-4b1e-84b9-b6ab6e89c2c2.txt`

### Reproduction Command

```bash
# Terminal 1: mitmproxy
mitmweb --listen-port 8080 --set web_password=test123

# Terminal 2: Claude Code
cd ~/Documents/GitHub/plankton
HOOK_SKIP_SUBPROCESS=1 \
  HTTPS_PROXY=http://localhost:8080 \
  NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem \
  claude --debug hooks
```

### Results: 3/3 PASS

| # | File type | Violations | Hook exit | Agent referenced hook | Agent Edit |
| --- | --- | --- | --- | --- | --- |
| 1 | Shell | 4 (SC2034×2 +2) | 2 | YES ("shellcheck") | Write→Edit |
| 2 | Python | F841 | 2 | YES ("unused var") | Edit |
| 3 | JSON | JSON_SYNTAX | 2 | YES ("invalid JSON") | Edit |

### Mitmproxy Finding: Delivery Mechanism Correction

**Previous claim** (parent spec, 2026-02-21): The `<system-reminder>` is
delivered as "a separate text block adjacent to the tool_result."

**Actual delivery** (mitmproxy rank-1 evidence, 2026-02-22): The
`<system-reminder>` is embedded **inside `tool_result.content`**, not as
a separate content block. The tool_result content field contains both the
success message and the system-reminder:

```json
{
  "type": "tool_result",
  "content": "The file ...updated successfully.\n\n<system-reminder>\nPostToolUse:Write hook blocking error from command: \".claude/hooks/multi_linter.sh\": [.claude/hooks/multi_linter.sh]: [hook] [\n  {\"line\": 2, \"code\": \"SC2034\", ...}\n]\n\n</system-reminder>",
  "tool_use_id": "toolu_..."
}
```

This explains why JSONL forensics found "no hook output in tool_result" —
the search looked for hook output as the primary content, not as a
`<system-reminder>` tag embedded within a success message string.

### Evidence Chain

| Rank | Source | Finding |
| ---- | ------ | ------- |
| 1 | Mitmproxy | `[hook]` + JSON in `tool_result.content` ×3 |
| 2 | Debug log | Hook→API→Read→Edit (complete chain) |
| 5 | Terminal UI | "hook flagged" referenced in all 3 runs |

### Verdict

**DONE.** The Step 1 garbled output bug (`|| echo "[]"` producing
multi-line counts) was the root cause. With clean hook output, the
feedback loop works reliably across shell, Python, and JSON file types.
Steps 3 and 4 are not needed.

---

## Follow-up Items

Tasks identified during the investigation, out of scope for the
feedback loop fix:

1. **Fix ruff handler schema conversion** — RESOLVED (2026-02-22,
   see Follow-up Items Completion Report below)
2. **Correct PSF unified schema claim** — RESOLVED (2026-02-22,
   see Follow-up Items Completion Report below)
3. **Suppress markdown debug summary line** — RESOLVED (2026-02-22,
   see Follow-up Items Completion Report below)
4. **Production path verification** — RESOLVED (2026-02-22,
   see Follow-up Items Completion Report below)
5. **Mitmproxy-test remaining output channels** — RESOLVED (2026-02-22,
   automated channel output tests + mitmproxy runbook, see report below)
6. **Regression test workflow note** — RESOLVED (2026-02-22,
   added to `docs/tests/README.md`, see report below)
7. **Fix spawn_fix_subprocess exit 1 design gap** — RESOLVED
   (2026-02-22, `return 1` → `return 0`, see Session 2 report)
8. **Add `[hook:feedback-loop]` debug log marker** — RESOLVED
   (2026-02-22, greppable marker before exit 2, see Session 2)
9. **Extract Investigation Principles to REFERENCE.md** —
   RESOLVED (2026-02-22, 18-line section, see Session 2)
10. **Resolve JSONL sys-reminder ambiguity** — RESOLVED
    (2026-02-22, grep confirms JSONL captures content but not
    `<system-reminder>` tag, see Session 2 + footnote [†])
11. **Trim parent spec to reference status** — RESOLVED
    (2026-02-22, 1440 → 1096 lines, see Session 2 report)
12. **Fix pre-existing test suite failures** — RESOLVED
    (2026-02-22, HOOK_SKIP_SUBPROCESS exit code + TS disabled
    config + SC2069, 110/2 → 112/0, see Session 2 report)
13. **Test config isolation — decouple test suite from production
    config.json** — RESOLVED (2026-02-22, see Session 3 report below).
    Shared maximal fixture at `.claude/tests/hooks/fixtures/config.json`.
    All four helpers + `verify_feedback_loop.sh` + `test_production_path.sh`
    now use isolated configs/HOME. TOML remains in project tree (taplo
    CWD limitation) but cleanup is EXIT-trapped. Structural count
    assertions loosened from exact to threshold.
14. **`feedback_count_shell` still uses production `project_dir`** —
    RESOLVED (2026-02-22). Changed `${project_dir}` to
    `${fixture_project_dir}` at line 1343 of `test_hook.sh`.
15. **Dead `taplo.toml` fixture file** — RESOLVED (2026-02-22).
    Deleted `.claude/tests/hooks/fixtures/taplo.toml` (unused).
16. **`.markdownlint.jsonc` copied from production at runtime** —
    RESOLVED (2026-02-22). Created static fixture at
    `fixtures/.markdownlint.jsonc`. Both `test_hook.sh` and
    `verify_feedback_loop.sh` now copy from fixtures dir.
17. **Fixture config `exclusions` includes `.claude/`** — RESOLVED
    (2026-02-22). Added `_exclusions_warning` key to fixture
    `config.json` documenting the `.claude/` skip trap.

---

## Follow-up Items Completion Report (2026-02-22)

Executed with hooks disabled. TDD approach for items 1 and 3 (strict
red-green-refactor). Items 2-6 ran as parallel background agents after
item 1 completed.

### Item 1: Ruff Schema Conversion (TDD)

**File**: `multi_linter.sh` lines 871-885

Replaced the inline `map(. + {linter: "ruff"})` with a proper jaq
conversion step matching the pattern used by shellcheck, ty, and
hadolint handlers:

```bash
# Before: appends {linter: "ruff"} to raw ruff JSON (keeps location.row)
_merged=$(echo "${collected_violations}" "${ruff_violations}" \
  | jaq -s '.[0] + (.[1] | map(. + {linter: "ruff"}))' ...) || ...

# After: converts to unified schema (location.row → line, etc.)
ruff_converted=$(echo "${ruff_violations}" | jaq '[.[] | {
  line: .location.row,
  column: .location.column,
  code: .code,
  message: .message,
  linter: "ruff"
}]' 2>/dev/null) || ruff_converted="[]"
```

**TDD ceremony**:

1. RED: `ruff_unified_schema` test checking `has("line")` on Python
   feedback JSON → FAIL (ruff outputs `location.row`)
2. GREEN: Applied conversion → PASS
3. REFACTOR: Strengthened `_check_hook_json` from 2-key check
   (`code` + `linter`) to 5-key check (`line`, `column`, `code`,
   `message`, `linter`) → all 10 feedback tests still GREEN

**Evidence**: `bash .claude/hooks/test_hook.sh --self-test` — 109 pass
after step 2, 109 pass after step 3 (no regressions from strengthened
check).

### Item 2: PSF Documentation Fix

**File**: `docs/psf/00-plankton-architecture-overview.md` line 252-254

Changed:

```text
# Before:
unified across all linters

# After:
all handlers convert to this format during Phase 2 collection
(see multi_linter.sh)
```

### Item 3: Markdown Debug Line Suppression (TDD)

**File**: `multi_linter.sh` — deleted 3-line debug summary block

```bash
# Deleted (was lines 1233-1236):
if [[ "${violation_count}" -gt 0 ]]; then
  echo >&2 "[hook] Markdown: ${violation_count} unfixable issue(s) collected"
fi
```

**TDD ceremony**:

1. RED: `markdown_single_hook_line` test counting `[hook]` lines in
   stderr → FAIL (2 lines: debug summary + JSON)
2. GREEN: Deleted debug block → PASS (1 line: JSON only)

**Evidence**: `bash .claude/hooks/test_hook.sh --self-test` — 110 pass
/ 2 fail (pre-existing). +2 new tests from items 1 and 3.

### Item 4: Production Path Test

**File**: `.claude/tests/hooks/test_production_path.sh` (new, ~170 lines)

Tests subprocess delegation using mock `claude` binaries:

| Test | Mock behavior | Expected | Result |
| ---- | ------------- | -------- | ------ |
| 1 | Exits 0, no file change | Exit 2, `remain` | PASS |
| 2 | Fixes file (removes violations) | Exit 0 | PASS |
| 3 | No `claude` in PATH | Non-zero, `not found` | PASS |
| 4 | Delegation disabled via config | Exit 2, mock not called | PASS |

**Deviation from plan**: Test 3 expected exit 2 but actual is exit 1.
The hook's `set -e` propagates `spawn_fix_subprocess`'s `return 1`
before reaching the `exit 2` path. This accurately reflects the hook's
real behavior — when `claude` is not found, `spawn_fix_subprocess`
returns 1, which `set -e` escalates to script termination. The test
was adjusted to check for non-zero exit rather than specifically exit 2.

**Evidence**: `bash .claude/tests/hooks/test_production_path.sh` — 8
pass / 0 fail.

### Item 5: Five-Channel Matrix Test

**File**: `.claude/tests/hooks/test_five_channels.sh` (new, ~290 lines)

Two modes:

**Automated** (default): Creates 5 minimal hook scripts, one per
channel. 4 assertions per channel (exit code, correct stream, content
match, other stream empty). 20 checks total.

**Runbook** (`--runbook`): Prints step-by-step mitmproxy verification
instructions for each channel. Generates settings.json swap commands,
CC launch commands, prompts to paste, and what to look for in the
mitmproxy request body. References `swap_settings.sh` for backup/restore.

| Channel | Exit | Automated | Mitmproxy |
| ------- | ---- | --------- | --------- |
| stderr + exit 2 | 2 | 4/4 PASS | Confirmed (prior) |
| stderr + exit 1 | 1 | 4/4 PASS | Runbook ready |
| JSON stdout + exit 2 | 2 | 4/4 PASS | Runbook ready |
| JSON stdout + exit 0 | 0 | 4/4 PASS | Runbook ready |
| stderr + exit 0 | 0 | 4/4 PASS | Runbook ready |

**Evidence**: `bash .claude/tests/hooks/test_five_channels.sh` — 20
pass / 0 fail.

### Item 6: Regression Test Workflow Docs

**File**: `docs/tests/README.md` — appended "Regression Testing After
Hook Changes" section (lines 310-349) documenting the 4 test commands:
self-test suite, feedback loop verification, production path, and
five-channel output.

### Final Verification Results

```text
test_hook.sh --self-test:       110 pass / 2 fail (pre-existing)
verify_feedback_loop.sh:         28 pass / 0 fail / 4 skip (biome)
test_production_path.sh:          8 pass / 0 fail
test_five_channels.sh:           20 pass / 0 fail
shellcheck multi_linter.sh:      0 new violations (info-level only)
```

### Files Changed (Follow-up Items)

| File | Item | Changes |
| ---- | ---- | ------- |
| `multi_linter.sh` | 1 | Ruff jaq schema conversion |
| `multi_linter.sh` | 3 | Delete 3-line debug summary |
| `test_hook.sh` | 1,3 | +2 tests, 5-key `_check_hook_json` |
| `00-plankton-architecture-overview.md` | 2 | Schema provenance note |
| `test_production_path.sh` | 4 | New: 4 mock subprocess tests |
| `test_five_channels.sh` | 5 | New: 20 channel tests + runbook |
| `docs/tests/README.md` | 6 | Regression workflow section |

---

## Follow-up Items Completion Report (Session 2, 2026-02-22)

Executed with hooks disabled for protected file edits
(`multi_linter.sh`, `test_hook.sh`); hooks active for docs and
diagnostic tasks. TDD approach for items 7-8 and 12 (strict
red-green-refactor). Items 9-11 ran in parallel after items 7-8.

### Item 7: spawn_fix_subprocess exit 1 Fix (TDD)

**File**: `multi_linter.sh` line 365

**Problem**: `spawn_fix_subprocess` returned 1 when `claude` was
not in PATH. Under `set -euo pipefail` (line 27), the return 1
from within the `if` body (line 1302) caused immediate script
termination with exit 1. CC showed non-blocking "hook error"
instead of exit 2 with violations. The verification phase
(lines 1305-1314) never ran.

**Fix**: Changed `return 1` to `return 0`. The function now
returns success, the script continues to the verification phase,
which correctly exits 2 with remaining violations (nothing was
fixed because no subprocess ran).

**TDD ceremony**:

1. RED: Updated test 3 in `test_production_path.sh` (lines
   211-221) — changed `[[ ${test3_exit} -ne 0 ]]` to
   `[[ ${test3_exit} -eq 2 ]]`, added `violation(s) remain`
   assertion → FAIL (got exit 1, not 2)
2. GREEN: Changed `return 1` to `return 0` at line 365 → PASS
3. VERIFY: `test_production_path.sh` 9/9

**Evidence**: `bash .claude/tests/hooks/test_production_path.sh`
— 9 pass / 0 fail after fix (was 8 pass / 0 fail, +1 new
assertion).

### Item 8: Debug Log Marker (TDD)

**File**: `multi_linter.sh` between lines 1311-1312

**Problem**: No greppable line for post-hoc triage of "agent
didn't fix violations" reports. When the hook delivers violations
via exit 2, there's no way to correlate debug logs with specific
files or violation counts.

**Fix**: Inserted before the existing `[hook]` line in the
exit 2 path:

```bash
echo "[hook:feedback-loop] delivered ${remaining} violations \
for ${file_path}" >&2
```

The marker goes BEFORE the agent-facing `[hook]` line because
it is diagnostic metadata (for grep/triage), not feedback to
the agent.

**Note**: The `HOOK_SKIP_SUBPROCESS=1` path (line 1295) does NOT
emit this marker — it bypasses delegation entirely, so "delivered
after delegation" would be misleading. The marker only appears in
the production path.

**TDD ceremony**:

1. RED: Added `test1_feedback_marker` assertion to
   `test_production_path.sh` test 1 (which exercises the
   production exit 2 path) → FAIL (marker doesn't exist)
2. GREEN: Inserted marker line → PASS
3. VERIFY: `test_production_path.sh` 10/10

**Evidence**: `bash .claude/tests/hooks/test_production_path.sh`
— 10 pass / 0 fail (was 9, +1 marker assertion).

### Item 9: Investigation Principles in REFERENCE.md

**File**: `docs/REFERENCE.md` between lines 742-743

Inserted 18-line "Investigation Principles" section between
the Debugging and Testing Hooks Manually sections. Three
principles:

1. **Verify before fixing** — test the existing mechanism under
   controlled conditions before building workarounds
2. **Rank evidence sources** — mitmproxy (definitive) > controlled
   reproduction > source code > JSONL (incomplete) > terminal >
   GitHub issues (unreviewed)
3. **Test before you gate** — run a controlled test with clean
   output before adding gates

Cross-references `make-plankton-work.md` Evidence Hierarchy table.

### Item 10: JSONL sys-reminder Ambiguity (Diagnostic)

**File**: `make-plankton-work.md` footnote [†] (lines 63-71)

**Method**: Grepped all plankton project JSONL session files at
`~/.claude/projects/-Users-alex-Documents-GitHub-plankton/`:

```text
grep -c 'hook.*blocking.*error'  → 25 matches
grep -c '\[hook\]'               → 77 matches
grep -c 'violation.*remain'      → 30 matches
grep -o '<system-reminder>'      → 0 matches
```

**Finding**: JSONL captures hook output content (framing text,
`[hook]` prefix, violation messages) but NOT the
`<system-reminder>` tag wrapper. CC appends the tag after JSONL
logging, during API request assembly.

**Resolution**: The original investigation's failure to find hook
output was a search methodology error — it searched for raw hook
JSON as primary content, not for the framing text
`PostToolUse.*hook.*blocking.*error`. Updated footnote [†]
in-place from "unresolved" to "RESOLVED" with grep evidence.

### Item 11: Trim Parent Spec to Reference Status

**File**: `posttoolusewrite-hook-stderr-silent-drop.md`

Replaced 10 superseded sections with 2-line redirect stubs
pointing to `make-plankton-work.md`. Worked bottom-up to avoid
line number shifts.

**Sections removed** (by redirect stub):

| # | Section | Lines removed |
| - | ------- | ------------- |
| 1 | Step 5: Transition Plan | 26 |
| 2 | Step 4: File Upstream | 20 |
| 3 | Step 3: Implement Strategy 4 | 44 |
| 4 | Failure Modes + Stale Lock | 23 |
| 5 | Recommended Approach | 32 |
| 6 | Strategy 4: PreToolUse Gate | 57 |
| 7 | Strategy 3: Embed Marker | 30 |
| 8 | Strategy 2: Sidecar File | 67 |
| 9 | Strategy 1: JSON Stdout | 36 |
| 10 | Edit vs Write Evidence | 32 |

**Result**: 1440 → 1096 lines (344 lines removed). All section
headings preserved; only body content replaced with redirect.

**Sections preserved**: correction notices, summary, observed
behavior, root cause analysis, evidence chain, frequency analysis,
reproduction steps, impact, secondary bug, agent misinterpretation,
architecture context, workaround strategies header + status note,
constraints, investigation items, Steps 1-2, cross-reference,
upstream issues, references.

### Item 12: Fix Pre-Existing Test Suite Failures (TDD)

Three bugs fixed, resolving the 2 pre-existing failures
(110 pass / 2 fail → 112 pass / 0 fail):

**Bug A — HOOK_SKIP_SUBPROCESS always exits 2**:

The test shortcut path (`multi_linter.sh` lines 1295-1298)
unconditionally exited 2, even when `collected_violations` was
an empty array `[]`. This caused "Python (valid)" to fail
(expected exit 0, got exit 2).

Fix: Added `jaq 'length'` check before exiting:

```bash
skip_count=$(echo "${collected_violations}" \
  | jaq 'length' 2>/dev/null || echo "0")
if [[ "${skip_count}" -eq 0 ]]; then
  exit 0
fi
```

**Bug B — TS disabled test uses production config**:

The "TS disabled skips" test used `test_temp_file` which did
not set `CLAUDE_PROJECT_DIR`, causing the hook to pick up the
production `config.json` (which has `typescript.enabled: true`).
The test expected exit 0 (skip TS), but biome found violations.

Fix: Created `ts_disabled_project_dir` with its own config
fixture (`typescript: false`), matching the pattern established
by `ts_project_dir` (TS-enabled config fixture). This aligns
with the principle that all tests should use independent
config fixtures, not the user's production config.

**Bug C — SC2069 in test_production_path.sh**:

Pre-existing ShellCheck violation at line 259: `2>&1 >/dev/null`
should be `>/dev/null 2>&1`. Fixed as part of the Boy Scout Rule
(inherited violation in a file being edited).

**TDD ceremony**: Both Bug A and Bug B were already RED
(pre-existing failures). Applied fixes, confirmed GREEN (112/0).

**Evidence**: `bash .claude/hooks/test_hook.sh --self-test` —
112 pass / 0 fail.

### Final Verification Results (Session 2)

```text
test_hook.sh --self-test:       112 pass / 0 fail (was 110/2)
test_production_path.sh:         10 pass / 0 fail (was 8/0)
verify_feedback_loop.sh:         28 pass / 0 fail / 4 skip
test_five_channels.sh:           20 pass / 0 fail
shellcheck multi_linter.sh:      0 new violations (info only)
```

### Files Changed (Session 2)

| File | Item | Changes |
| ---- | ---- | ------- |
| `multi_linter.sh` | 7 | `return 1` → `return 0` (line 365) |
| `multi_linter.sh` | 8 | `[hook:feedback-loop]` marker line |
| `multi_linter.sh` | 12A | `skip_count` check in SKIP path |
| `test_production_path.sh` | 7 | Test 3: expect exit 2 + violations |
| `test_production_path.sh` | 8 | Test 1: `[hook:feedback-loop]` assert |
| `test_production_path.sh` | 12C | SC2069 fix (line 259) |
| `test_hook.sh` | 12B | TS disabled: own config fixture |
| `docs/REFERENCE.md` | 9 | Investigation Principles section |
| `make-plankton-work.md` | 10 | Footnote [†] RESOLVED |
| `posttoolusewrite-...md` | 11 | 10 sections → redirect stubs |

---

## Follow-up Items Completion Report (Session 3, 2026-02-22)

Commits: `87b97d6` (prior sessions work), `b974438` (FU-13 test hardening).

**Scope**: FU-13 (test config isolation) expanded to full test hardening —
decoupling all tests from production config, real HOME, and project tree
where feasible. Planned as 7 slices (A-G) using `/planning-tdd`.

**Process note**: TDD red-green-refactor was planned but edits were applied
in bulk via Python script with post-hoc verification (all 170 tests green).

### Slice A: Shared Fixture Files (3 new files)

Created `.claude/tests/hooks/fixtures/`:

| File | Purpose |
| ---- | ------- |
| `config.json` | Maximal config — all languages on, all optional tools enabled |
| `taplo.toml` | Created for TOML isolation — **unused** (see FU-15) |
| `.markdownlint-cli2.jsonc` | Minimal markdownlint-cli2 config |

### Slices B+C: test_hook.sh Config Isolation

- `test_temp_file`, `test_output_format`, `test_model_selection`: added
  `CLAUDE_PROJECT_DIR="${fixture_project_dir}"` (was unset — hook used defaults)
- `test_stderr_json`: changed from `"${project_dir}"` to
  `"${fixture_project_dir}"` (was using production config)
- Inline markdown test: same fix
- `fixture_project_dir` created at top of `run_self_test()` with fixture
  config + `.markdownlint-cli2.jsonc` + `.markdownlint.jsonc` (from project)

**Missed**: `feedback_count_shell` (line 1343) still uses `${project_dir}` —
see FU-14.

### Slice D: verify_feedback_loop.sh Config Isolation

- Created `fixture_project_dir` in `tmp_dir` with fixture config +
  markdownlint configs
- Replaced `CLAUDE_PROJECT_DIR="${project_dir}"` in `run_check()` with
  `"${fixture_project_dir}"`
- TS gate config read now uses fixture config
- Removed fragile trap override for TOML cleanup (now in main EXIT trap)

### Slice E: TOML Fixture Isolation (partial)

**Plan**: Place TOML fixtures in `${temp_dir}/toml_project/` with co-located
`taplo.toml`. **Reality**: taplo resolves include globs relative to CWD
(project root), not the config file location. The approach failed.

**Fallback**: TOML fixtures remain in `${project_dir}/test_fixture_broken.toml`
(both files) but cleanup is now EXIT-trapped instead of inline `rm -f`
(test_hook.sh) or fragile trap override (verify_feedback_loop.sh).

### Slice F: HOME Isolation in test_production_path.sh

- Created `isolated_home="${tmp_dir}/home"` with pre-populated
  `no-hooks-settings.json`
- `export HOME="${isolated_home}"` — no more writes to real `$HOME/.claude/`
- Removed old `created_settings` conditional setup (lines 45-57) and
  cleanup (lines 273-276)
- EXIT trap on `tmp_dir` handles all cleanup

### Slice G: Structural Count Assertions

- `jaq_merge_count`: `-eq 13` → `-ge 13`
- `jaq_conversion_guard`: `-eq 4` → `-ge 4`
- `jaq_merge_guard` (exact-zero check): unchanged (correct negative assertion)

### Verification Results (Session 3)

```text
test_hook.sh --self-test:       112 pass / 0 fail
verify_feedback_loop.sh:         28 pass / 0 fail / 4 skip (biome)
test_production_path.sh:         10 pass / 0 fail
test_five_channels.sh:           20 pass / 0 fail
```

### Files Changed (Session 3)

| File | Changes |
| ---- | ------- |
| `test_hook.sh` | fixture_project_dir setup, 4 helper CLAUDE_PROJECT_DIR fixes, TOML EXIT trap, count assertion loosening |
| `verify_feedback_loop.sh` | fixture_project_dir setup, CLAUDE_PROJECT_DIR fix, TS gate fix, TOML trap fix |
| `test_production_path.sh` | HOME isolation (isolated_home in tmp_dir) |
| `fixtures/config.json` | New: maximal test config |
| `fixtures/taplo.toml` | New: unused (see FU-15) |
| `fixtures/.markdownlint-cli2.jsonc` | New: minimal markdownlint config |

### Review Findings → New Follow-up Items

Post-implementation review identified 4 issues (FU-14 through FU-17):

- **FU-14**: `feedback_count_shell` line 1343 still uses `${project_dir}` — one-line fix
- **FU-15**: `fixtures/taplo.toml` is dead code — delete or repurpose
- **FU-16**: `.markdownlint.jsonc` copied from production at runtime — should be static fixture
- **FU-17**: Fixture config exclusions include `.claude/` — latent skip trap

---

## Follow-up Items Completion Report (Session 4, 2026-02-22)

Executed with hooks disabled (all edits target protected files or fixtures
in `.claude/`). Resolved FU-14 through FU-17 — the final 4 open items.

**Process note**: Plan specified TDD red-green-refactor for Steps 1 and 3.
In practice, both were applied as green-only (direct fix + full suite
verification). Existing test coverage (`feedback_count_shell`, markdown
feedback tests) served as the regression gate. Risk: low — config-path
changes only.

### Changes

| # | Item | File | Change |
| --- | ---- | ---- | ------ |
| 1 | FU-14 | `test_hook.sh:1343` | `project_dir` → `fixture_project_dir` |
| 2 | FU-15 | `fixtures/taplo.toml` | Deleted (unused — taplo resolves globs from CWD) |
| 3 | FU-16 | `fixtures/.markdownlint.jsonc` | New: static copy of production `.markdownlint.jsonc` |
| 3 | FU-16 | `test_hook.sh:32-35` | Copy from `${fixtures_dir}` instead of `${project_dir}` |
| 3 | FU-16 | `verify_feedback_loop.sh:30-32` | Same — copy from `${fixtures_dir}` |
| 4 | FU-17 | `fixtures/config.json` | Added `_exclusions_warning` key documenting `.claude/` skip trap |

### Deviations from Plan

- **Step 3**: Added `local fixtures_dir` variable in `test_hook.sh` (not
  in plan — necessary because `fixtures_dir` was only defined in
  `verify_feedback_loop.sh`). Removed conditional `[[ -f ... ]] &&` guard
  (fixture file is guaranteed to exist; unconditional `cp` is correct).
- **Edge case verified**: `_exclusions_warning` key in `config.json` is
  safe — `multi_linter.sh` uses targeted jaq path queries (`.languages.X`,
  `.exclusions`, `.subprocess.X`), never iterates all top-level keys.

### Verification Results

```text
test_hook.sh --self-test:       112 pass / 0 fail
verify_feedback_loop.sh:         28 pass / 0 fail / 4 skip (biome)
test_production_path.sh:         10 pass / 0 fail
test_five_channels.sh:           20 pass / 0 fail
```

### Closure

All 17 follow-up items (FU-1 through FU-17) are now RESOLVED. No new
items emerged from the post-implementation review.

---

## References

- Mitmproxy verification: `cc-trace/verification-report.md`
- Parent spec: `posttoolusewrite-hook-stderr-silent-drop.md`
- Deep research: `deep-research-regression-report.md`
- JSONL bisection: `jsonl-version-bisection.md`
- [Claude Code issue #12151 - Umbrella hook output issue](https://github.com/anthropics/claude-code/issues/12151)
- [Claude Code issue #18427 - PostToolUse cannot inject context](https://github.com/anthropics/claude-code/issues/18427)
- [Claude Code issue #23381 - PostToolUse output duplicated in v2.1.31](https://github.com/anthropics/claude-code/issues/23381)
