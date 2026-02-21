# JSONL Version Bisection: PostToolUse Hook Output Regression

Forensic analysis of JSONL conversation logs to identify the exact
Claude Code version where PostToolUse hook output stopped being
propagated to tool_results.

**Parent spec**: `posttoolusewrite-hook-stderr-silent-drop.md`
**Created**: 2026-02-21
**Executed**: 2026-02-21
**Status**: Complete — Outcome #2 (bug predates available data)

## Results Summary

Scanned 48 sessions (839 skipped as tiny/subprocess) across 10 CC versions
(v2.1.9 through v2.1.50). 25 plankton sessions, 23 incide sessions.

**Finding: Zero PostToolUse output in tool_results across ALL versions.**

| VERSION | SESSIONS | HOOKS_RAN | PRETOOLUSE | IN_RESULT | SYSREM |
| ------- | -------- | --------- | ---------- | --------- | ------ |
| 2.1.9 | 1 | 1 Y | 0 | 0 | 0 |
| 2.1.27 | 2 | 2 Y | 0 | 0 | 0 |
| 2.1.29 | 2 | 2 Y | 0 | 0 | 0 |
| 2.1.31 | 4 | 4 Y | 3 | 0 | 0 |
| 2.1.38 | 4 | 4 Y | 0 | 0 | 0 |
| 2.1.39 | 8 | 6 Y | 0 | 0 | 0 |
| 2.1.47 | 8 | 4 Y, 3 N, 1 N/A | 7 | 0 | 0 |
| 2.1.49 | 10 | 9 Y | 5 | 0 | 0 |
| 2.1.50 | 7 | 5 Y, 2 N/A | 3 | 0 | 0 |

**PreToolUse positive control**: 18 sessions across v2.1.31-v2.1.50 have
PreToolUse `decision:block` in tool_results, proving hooks were installed
and JSONL captured hook output. PostToolUse output is absent in ALL of
these sessions.

**Conclusion (Outcome #2)**: The bug predates all available first-party
JSONL data (v2.1.9+). PostToolUse hook output was never propagated to
tool_results in any scanned session. External evidence from GitHub issues #11224
(v2.0.35) and #23381 (v2.1.31) remains the only proof that the
feature ever worked.

**Script bugs found during execution** (fixed in the extracted script):

1. Read tool results (line-numbered content) matched as false positives —
   fixed by checking success message appears in first 150 chars
2. `done > "$MATRIX_FILE"` redirect captured echo statements — fixed by
   appending inside scan_session
3. `(( skipped++ ))` aborted under `set -e` when skipped=0 — fixed with
   `$((skipped + 1))`

**Evidence**: `.claude/tests/hooks/jsonl-version-bisect/`

## Objective

Pinpoint the exact Claude Code version where PostToolUse hook output
was last successfully delivered to the agent's tool_result. This
strengthens the upstream bug report (parent spec Step 4) by providing
first-party regression evidence rather than relying on external issue
reports (#11224, #23381).

## Data Sources

### JSONL File Locations

| Project | Directory | Sessions | CC Versions |
| ------- | --------- | -------- | ----------- |
| plankton | `~/.claude/projects/…-plankton/` | 108 | v2.1.47, .49, .50 |
| incide (main) | `~/.claude/projects/…-incide/` | 771 | v2.0.76–v2.1.39 |
| incide (worktrees) | `~/.claude/projects/…-incide-worktrees-*/` | TBD | TBD |
| incide (other) | `~/.claude/projects/…-incide-*/` | TBD | TBD |

### Version Distribution (Known)

From preliminary scan on 2026-02-21:

**Plankton** (108 sessions):

| Version | Sessions |
| ------- | -------- |
| v2.1.50 | 59 |
| v2.1.49 | 28 |
| v2.1.47 | 16 |
| NO_VERSION | 5 |

**Incide main** (771 sessions, from first 5 lines):

| Version | Sessions |
| ------- | -------- |
| v2.1.27 | 453 |
| v2.1.29 | 152 |
| v2.1.31 | 64 |
| v2.1.39 | 44 |
| v2.1.38 | 42 |
| v2.0.76 | 3 |
| v2.1.5 | 2 |
| v2.1.9 | 1 |
| v2.1.4 | 1 |
| v2.1.3 | 1 |
| v2.1.14 | 1 |
| v2.1.1 | 1 |
| NO_VERSION | 6 |

### Version Field Location

The `version` field appears in most JSONL lines (not just the first
line). To extract reliably:

```bash
# Extract version from any line in the file
version=$(jaq -r '.version // empty' "$file" 2>/dev/null | sort -u | head -1)
```

Some older JSONL files (5 in plankton, 6 in incide) have NO version
field in any line. These sessions cannot be used for version bisection
but may provide useful data if their creation timestamp can be
correlated with known CC version installation dates.

### JSONL Line Structure

Each line is a JSON object. Relevant fields for this analysis:

```json
{
  "type": "user",           // "user" lines contain tool_results
  "version": "2.1.50",     // CC version (most lines)
  "timestamp": "...",       // ISO timestamp
  "message": {
    "content": [            // ARRAY for tool_results, STRING for plain text
      {
        "type": "tool_result",
        "tool_use_id": "toolu_...",
        "content": "File created successfully at: /path/to/file.sh"
      }
    ]
  }
}
```

### Schema Variations Across Versions

Verified across v2.0.76-v2.1.50 on 2026-02-21:

| Field | Behavior | Versions |
| ----- | -------- | -------- |
| `.message.content` | **string** or **array** (tool results) | All |
| `.tool_result.content` | **string**; sometimes **array** | v2.1.9+ |
| `.tool_result.is_error` | Optional boolean; absent = success | All |
| `.type` top-level | `user`/`assistant`/`queue-operation`; more v2.1.9+ | All |

**Parsing guards required**:

1. Filter `select(.type == "user")` first
   (skip progress/system/file-history lines)
2. Guard `.message.content` type: `select(.message.content | type == "array")`
3. Normalize `tool_result.content`:
   coerce array form to joined string
4. Treat `is_error` as optional: `.is_error // false`

For progress events (indicating hook execution, v2.1.9+):

```json
{
  "type": "progress",
  "version": "2.1.27",
  "data": {
    "type": "hook_progress",
    "hookEvent": "PostToolUse",
    "hookName": "PostToolUse:Write",
    "command": "/path/to/.claude/hooks/multi_linter.sh"
  },
  "parentToolUseID": "toolu_...",
  "toolUseID": "toolu_...",
  "timestamp": "..."
}
```

**Important**: Progress events do NOT exist before v2.1.9. Versions
v2.0.76-v2.1.5 have no `type: "progress"` lines at all. The hook-ran
column is `N/A` for these versions (not `N`).

## Search Methodology

### Positive Signal: Hook Output in tool_result

A tool_result that contains hook output text alongside a standard
success message proves the CC version propagated PostToolUse output.

**True positive criteria** (ALL must be met):

1. The JSONL line has `type == "user"`
2. It contains a `tool_result` entry
3. The `content` field contains a standard success message:
   - `"File created successfully"` (Write)
   - `"file has been updated successfully"` (Edit)
   - Or other standard tool success messages
4. AND the `content` field ALSO contains hook output text:
   - `[hook]` — main output prefix
   - `[hook:warning]` — subprocess warnings
   - `[hook:error]` — fatal errors
   - `[hook:advisory]` — informational messages
   - `[hook:model]` — debug model selection
   - `violation(s) remain` — specific delegation result
   - `hook error` — CC-generated error prefix
   - `blocking error` — CC-generated blocking error

### False Positive Detection

**Known false positive patterns** (EXCLUDE these):

1. **Test output in Read results**: A Read tool_result showing the
   contents of a test file or log that mentions `[hook]`. Detected by:
   - The tool_result does NOT contain a standard Write/Edit success
     message
   - The content contains line numbers (e.g., `1→`) indicating
     a Read tool output

2. **Agent quoting hook text**: The agent mentions `[hook]` in its
   reasoning or output. Detected by:
   - The JSONL line has `type == "assistant"` (not `type == "user"`)

3. **PreToolUse hook output**: PreToolUse hooks DO propagate output
   (this is the working channel). Detected by:
   - The tool_result is associated with a PreToolUse block decision,
     not a PostToolUse result
   - The content contains `{"decision":"block"` JSON without a
     standard success message

### Negative Signal: Hook Ran But Output Absent

A session where PostToolUse hooks demonstrably ran (progress events
exist) but tool_results contain only standard success messages proves
the CC version has the bug.

**Negative signal criteria**:

1. Progress events contain `PostToolUse:Write` or `PostToolUse:Edit`
   (proves a PostToolUse hook fired)
2. Tool_results for Write/Edit contain ONLY the standard success
   message (no hook output appended)

### Positive Control: PreToolUse Evidence

PreToolUse hook output IS reliably delivered to the agent. A session
that contains a PreToolUse `{"decision":"block"}` response in a
tool_result proves:

1. Hooks were installed in that session
2. JSONL captured hook output
3. The CC version could propagate hook decisions

If PostToolUse output is **absent** in the SAME session where
PreToolUse evidence exists, this is strong regression evidence (hooks
worked for Pre but not Post).

**Detection**: Search `type == "user"` lines for tool_result content
containing `"decision"` and `"block"` without a standard Write/Edit
success message.

### Secondary Signal: system-reminder Injection

In v2.1.31 (per issue #23381), PostToolUse `decision:block` output
was delivered to the agent as `<system-reminder>` blocks in `type ==
"system"` lines. This is a different propagation path than tool_result
content appending.

**Detection**: Search `type == "system"` lines for content containing
hook output patterns (`[hook`, `violation`, `decision.*block`).

### Edge Cases

1. **Hook exited 0 (no violations)**: No stderr to propagate. These
   sessions prove nothing about propagation — skip them. Only sessions
   where violations were found (exit 2) are relevant, but we cannot
   determine the exit code from JSONL alone.

2. **Hook not installed**: Sessions before hooks were added to the
   project have no PostToolUse hooks. These prove nothing. The incide
   project may not have had hooks in all versions — check git history.

3. **Different hook formats**: Incide's hooks may use different output
   prefixes. Search patterns should be broad enough to catch
   alternative formats.

4. **Multi-project hooks**: The plankton hooks (multi_linter.sh) were
   developed in this project. The incide project may have copied them
   or used an earlier version. Git history determines which prefixes
   to search for.

5. **No progress events before v2.1.9**: Versions v2.0.76-v2.1.5 do
   not emit `type: "progress"` lines. The HOOKS_RAN column is `N/A`
   for these versions — absence of progress events does NOT prove
   hooks didn't run.

6. **Subprocess sessions**: Many JSONL files (especially v2.1.31) are
   subprocess sessions spawned by hooks (first user message starts
   with "You are a" fixer prompt). These have no PostToolUse hooks
   and must be excluded. Detect via first user message content.

7. **Tiny abandoned sessions**: Most v2.1.27 sessions (451 of 453)
   are 3-4 line abandoned sessions with no tool use. Skip files with
   fewer than 10 lines.

## Hook Output Patterns

### multi_linter.sh Output Patterns (Current)

All stderr patterns in multi_linter.sh that would appear in
tool_results if propagation worked:

| Line | Pattern | Context |
| ---- | ------- | ------- |
| 32 | `[hook] error: jaq is required...` | Fatal: jaq missing |
| 261 | `[hook:model] ${model}` | Debug model selection |
| 364 | `[hook:error] claude binary not found...` | Fatal: no claude |
| 377 | `[hook:error] failed to create temp file...` | Fatal: temp file |
| 387 | `[hook:warning] created missing ${settings_file}` | Auto-created |
| 414 | `[hook:warning] subprocess timed out...` | Subprocess timeout |
| 416 | `[hook:warning] subprocess failed...` | Subprocess failure |
| 651 | `[hook:advisory] Semgrep: N finding(s)` | Semgrep results |
| 684 | `[hook:advisory] Duplicate code detected (TS/JS)` | jscpd results |
| 710 | `[hook:warning] config.json biome_nursery=...` | Config mismatch |
| 722 | `[hook:warning] file outside project root...` | Path warning |
| 743 | `[hook:warning] No linter available...` | Missing linter |
| 754 | `[hook:warning] biome not found...` | Missing biome |
| 823 | `[hook:advisory] Biome nursery: N diagnostic(s)` | Nursery results |
| 918 | `[hook:advisory] Duplicate code detected` | jscpd results |
| 1131 | `[hook:warning] hadolint N < 2.12.0...` | Old hadolint |
| 1205 | `[hook] Markdown: N unfixable issue(s)` | Markdown linting |
| 1263 | `[hook:model] ${debug_model}` | Debug model selection |
| 1269 | `[hook] ${collected_violations}` | Test mode violations |
| 1285 | `[hook] ${remaining} violation(s) remain...` | Post-delegation |

### enforce_package_managers.sh Output Patterns

| Line | Pattern | Context |
| ---- | ------- | ------- |
| 271 | `[hook:warning] ${tool} not found...` | Missing replacement |
| 280 | `[hook:debug] PM check:...action='approve'` | Debug: approved |
| 297 | `[hook:debug] PM check:...action='block'` | Debug: blocked |
| 303 | `[hook:block] ${tool} is not allowed...` | Block reason (JSON) |
| 314 | `[hook:debug] PM check:...action='warn'` | Debug: warned |
| 321 | `[hook:advisory] ${tool} detected...` | Tool preference |

### Consolidated Search Regex

For broad matching across all hook versions:

```bash
# Primary pattern (high specificity)
HOOK_PATTERN='\[hook[:\]]'

# Secondary patterns (lower specificity, use with Write/Edit context)
VIOLATION_PATTERN='violation\(s\) remain|remain after delegation'
HOOK_ERROR_PATTERN='hook error|blocking error'

# JSON format pattern (for v2.1.31-era decision:block propagation)
DECISION_PATTERN='"decision".*"block"'

# Combined regex for tool_result content search
COMBINED='(\[hook[:\]]|violation\(s\) remain|hook error|blocking error|"decision".*"block")'
```

## Script Design

### Input

- JSONL files from plankton and incide project directories
- Configurable project directory list (start with plankton + incide
  main, expand to worktrees/other if needed)

### Processing Pipeline

```text
For each JSONL file:
  0. Skip if <10 lines (abandoned session)
  0a. Skip if first user message starts with "You are a" (subprocess)
  1. Extract CC version (from any line with .version field)
  2. Extract session ID (from filename: UUID.jsonl)
  3. Scan for PostToolUse progress events (proves hooks ran; N/A pre-v2.1.9)
  4. Scan for PreToolUse block evidence (positive control)
  5. Scan for tool_results matching Write/Edit success patterns
  6. Within those tool_results, search for hook output patterns
  7. Scan type=="system" lines for hook patterns (system-reminder path)
  8. Apply false positive filters
  9. Output: (version, session_id, lines, hook_ran, pretooluse_evidence,
              hook_in_result, sysreminder_match, snippet_if_positive)
```

### Output Format

**Primary output**: Version-sorted evidence matrix (TSV)

```text
VERSION  SESSIONS  SKIPPED  HOOKS_RAN  PRETOOLUSE  HOOK_IN_RESULT  SYSREMINDER
2.0.76   3         0        N/A        0           0               0
2.1.5    2         2        N/A        0           0               0
2.1.9    1         0        Y          ?           ?               ?
2.1.27   453       451      Y          ?           ?               ?
2.1.31   64        32       Y          ?           ?               ?
...
2.1.50   59        0        Y          Y           0               0
```

Column definitions:

- **SKIPPED**: Sessions excluded (subprocess or <10 lines)
- **HOOKS_RAN**: `Y`/`N` from progress events; `N/A` for pre-v2.1.9
- **PRETOOLUSE**: Sessions with PreToolUse block evidence (positive control)
- **HOOK_IN_RESULT**: Sessions with hook output in tool_result content
- **SYSREMINDER**: Sessions with hook output in system-reminder lines

**Secondary output**: Evidence snippets for positive matches

```text
=== POSITIVE MATCH ===
Version: 2.1.31
Session: abc123...
File: /path/to/session.jsonl
Line: 42
Tool: Write
Snippet (first 200 chars of tool_result content):
  "File created successfully at: /path/to/file.sh\n[hook] 3 violation(s)
  remain after delegation"
```

**Summary output**: Regression boundary

```text
LAST WORKING VERSION: v2.1.31 (or whichever)
FIRST BROKEN VERSION: v2.1.38 (or whichever)
EVIDENCE: N positive matches in vX.Y.Z, 0 positive matches in vA.B.C+
```

### Performance Considerations

- 879+ JSONL files, some potentially large
- Use `jaq` for JSON processing (faster than jq)
- Process files in parallel where possible (`xargs -P`)
- For large files, use early termination: stop scanning a file once
  a positive match is found (for the "any evidence" question)
- For the full matrix, scan all files completely

### Implementation: Bash + jaq Pipeline

```bash
#!/bin/bash
# jsonl_version_bisect.sh — PostToolUse output regression bisection
#
# Usage: ./jsonl_version_bisect.sh [project_dir...]
# Default: plankton + incide main project dirs

set -euo pipefail

# --- Configuration ---

PLANKTON_DIR="${HOME}/.claude/projects/-Users-alex-Documents-GitHub-plankton"
INCIDE_DIR="${HOME}/.claude/projects/-Users-alex-Documents-GitHub-incide"

# Finding C: correct array expansion for default dirs
if (( $# > 0 )); then
  PROJECT_DIRS=("$@")
else
  PROJECT_DIRS=("${PLANKTON_DIR}" "${INCIDE_DIR}")
fi

MIN_LINES=10  # Finding F: skip abandoned sessions

# Hook output patterns (regex for jaq)
HOOK_PATTERN='\\[hook[:\\]]|violation\\(s\\) remain|hook error|blocking error|"decision".*"block"'
SUCCESS_PATTERN='File created|updated successfully'

# Output files — Finding K: persistent evidence dir
EVIDENCE_DIR=".claude/tests/hooks/jsonl-version-bisect"
mkdir -p "${EVIDENCE_DIR}"
MATRIX_FILE="${EVIDENCE_DIR}/matrix.tsv"
EVIDENCE_FILE="${EVIDENCE_DIR}/evidence.txt"
SUMMARY_FILE="${EVIDENCE_DIR}/summary.txt"

# --- Functions ---

extract_version() {
  local file="$1"
  jaq -r '.version // empty' "$file" 2>/dev/null | sort -u | head -1
}

is_subprocess_session() {
  # Finding E: detect subprocess sessions (spawned by hooks)
  local file="$1"
  local first_user_msg
  first_user_msg=$(jaq -r '
    select(.type == "user") |
    if (.message.content | type) == "string" then .message.content
    elif (.message.content | type) == "array" then
      [.message.content[]? | select(.type == "text") | .text] | first // ""
    else "" end
  ' "$file" 2>/dev/null | head -1)
  [[ "$first_user_msg" == "You are a"* ]]
}

# Normalize tool_result content — Finding B: handle string and array
normalize_content() {
  # jaq filter: returns string regardless of .content type
  cat <<'JQ'
if (.content | type) == "string" then .content
elif (.content | type) == "array" then
  [.content[]? | select(.type == "text") | .text] | join("\n")
else "" end
JQ
}

scan_session() {
  local file="$1"
  local version session_id line_count hooks_ran pretooluse_ev
  local hook_in_result sysreminder_match snippet

  # Finding F: skip tiny files
  line_count=$(wc -l < "$file" | tr -d ' ')
  if (( line_count < MIN_LINES )); then
    return 1  # signal: skipped
  fi

  version=$(extract_version "$file")
  [[ -z "$version" ]] && version="UNKNOWN"
  session_id=$(basename "$file" .jsonl)

  # Finding E: skip subprocess sessions
  if is_subprocess_session "$file"; then
    return 1  # signal: skipped
  fi

  # Finding A: correct progress event format (.data.hookEvent)
  local progress_hit
  progress_hit=$(jaq -r '
    select(.type == "progress") |
    select(.data?.hookEvent? == "PostToolUse") |
    .data.hookName
  ' "$file" 2>/dev/null | head -1)
  [[ -n "$progress_hit" ]] && hooks_ran="Y" || hooks_ran="N"

  # Finding D: mark N/A for pre-v2.1.9 (no progress events existed)
  if [[ "$hooks_ran" == "N" ]]; then
    local has_any_progress
    has_any_progress=$(jaq -r 'select(.type == "progress") | .type' \
      "$file" 2>/dev/null | head -1)
    [[ -z "$has_any_progress" ]] && hooks_ran="N/A"
  fi

  # Finding G: PreToolUse control signal
  # Search for tool_results containing decision:block WITHOUT success msg
  local pre_hit
  pre_hit=$(jaq -c '
    select(.type == "user") |
    select(.message.content | type == "array") |
    .message.content[]? |
    select(.type == "tool_result") |
    select(
      (if (.content | type) == "string" then .content else
        [.content[]? | select(.type == "text") | .text] | join("\n")
      end) as $c |
      ($c | test("\"decision\".*\"block\"")) and
      ($c | test("File created|updated successfully") | not)
    ) | .tool_use_id
  ' "$file" 2>/dev/null | head -1)
  [[ -n "$pre_hit" ]] && pretooluse_ev="Y" || pretooluse_ev="N"

  # Finding B: corrected tool_result search with schema guards
  local match
  match=$(jaq -c '
    select(.type == "user") |
    select(.message.content | type == "array") |
    .message.content[]? |
    select(.type == "tool_result") |
    (if (.content | type) == "string" then .content
     elif (.content | type) == "array" then
       [.content[]? | select(.type == "text") | .text] | join("\n")
     else "" end) as $c |
    select($c | test("File created|updated successfully")) |
    select($c | test("\\[hook[:\\]]|violation\\(s\\) remain|hook error|blocking error|\"decision\".*\"block\"")) |
    {tool_use_id, content: ($c | .[0:300])}
  ' "$file" 2>/dev/null | head -1)

  if [[ -n "$match" ]]; then
    hook_in_result="Y"
    snippet="$match"
  else
    hook_in_result="N"
    snippet=""
  fi

  # Finding H: search system-reminder lines for hook patterns
  local sys_hit
  sys_hit=$(jaq -c '
    select(.type == "system") |
    .message?.content? // "" |
    if type == "string" then . else "" end |
    select(test("\\[hook[:\\]]|violation\\(s\\) remain|\"decision\".*\"block\""))
  ' "$file" 2>/dev/null | head -1)
  [[ -n "$sys_hit" ]] && sysreminder_match="Y" || sysreminder_match="N"

  # Output TSV line (Finding M: expanded columns)
  printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\n" \
    "$version" "$session_id" "$line_count" \
    "$hooks_ran" "$pretooluse_ev" "$hook_in_result" "$sysreminder_match"

  # Output evidence if any positive signal found
  if [[ "$hook_in_result" == "Y" || "$sysreminder_match" == "Y" ]]; then
    {
      echo "=== POSITIVE MATCH ==="
      echo "Version: $version"
      echo "Session: $session_id"
      echo "File: $file"
      echo "Lines: $line_count"
      echo "Channel: tool_result=$hook_in_result sysreminder=$sysreminder_match"
      echo "PreToolUse control: $pretooluse_ev"
      [[ -n "$snippet" ]] && echo "Snippet: $snippet"
      [[ -n "$sys_hit" ]] && echo "SysReminder: $sys_hit"
      echo ""
    } >> "$EVIDENCE_FILE"
  fi
}

# --- Main ---

echo "VERSION BISECTION: PostToolUse Hook Output Regression"
echo "====================================================="
echo ""

: > "$MATRIX_FILE"
: > "$EVIDENCE_FILE"

skipped=0
scanned=0

# Scan all JSONL files
for dir in "${PROJECT_DIRS[@]}"; do
  echo "Scanning: $dir"
  for file in "$dir"/*.jsonl; do
    [[ -f "$file" ]] || continue
    if scan_session "$file"; then
      (( scanned++ ))
    else
      (( skipped++ ))
    fi
  done
done > "$MATRIX_FILE"

echo "Scanned: $scanned sessions, Skipped: $skipped"
echo ""
echo "--- Version Summary ---"
# Aggregate by version (Finding M: expanded columns)
sort -t$'\t' -k1,1V "$MATRIX_FILE" | \
  awk -F'\t' '{
    v[$1]++
    if ($4=="Y") hr[$1]++
    if ($4=="N/A") na[$1]++
    if ($5=="Y") pre[$1]++
    if ($6=="Y") hir[$1]++
    if ($7=="Y") sr[$1]++
  } END {
    printf "%-10s %8s %9s %10s %9s %7s\n", \
      "VERSION", "SESSIONS", "HOOKS_RAN", "PRETOOLUSE", "IN_RESULT", "SYSREM"
    for (k in v) {
      hr_val = na[k]+0 > 0 ? "N/A" : hr[k]+0
      printf "%-10s %8d %9s %10d %9d %7d\n", \
        k, v[k], hr_val, pre[k]+0, hir[k]+0, sr[k]+0
    }
  }' | sort -t. -k1,1n -k2,2n -k3,3n | tee "$SUMMARY_FILE"

echo ""
echo "Evidence: $EVIDENCE_FILE"
echo "Matrix:   $MATRIX_FILE"
echo "Summary:  $SUMMARY_FILE"
```

## Expected Findings

### Hypothesis

Based on the regression timeline in the parent spec:

- **v2.0.76 through v2.1.31**: PostToolUse output MAY appear in
  tool_results (if hooks were installed and violations were found)
- **v2.1.38+**: PostToolUse output is likely absent from tool_results
- **v2.1.47+**: PostToolUse output is confirmed absent (parent spec
  investigations)

The bisection target is the version boundary between v2.1.31 and
v2.1.47. The incide project has sessions at v2.1.38 (42 sessions)
and v2.1.39 (44 sessions), which are in the gap.

### Possible Outcomes

1. **Clear boundary found**: e.g., v2.1.31 has positive matches,
   v2.1.38 has none. The regression is between v2.1.31 and v2.1.38.
   This narrows the changelog window to examine.

2. **No positive matches in any version**: Hooks may not have been
   installed during earlier CC versions, or violations may never have
   been found in those sessions. The analysis is inconclusive for
   those versions, but still useful for confirming the negative
   (no evidence of the feature working in first-party data).

3. **Sporadic positive matches**: Some sessions at a version show
   positive, others don't. This could indicate the bug is
   intermittent, or that only certain hook configurations triggered
   propagation. Requires deeper investigation of the positive
   sessions.

### Success Criteria

The analysis is complete when one of these outcomes is reached:

1. **Clear boundary with PreToolUse control**: At least one version
   has PostToolUse output in tool_results (or system-reminders), AND
   a later version has PreToolUse evidence but no PostToolUse output.
   This proves the regression occurred between those versions.
   **Result**: Update parent spec with exact boundary.

2. **All negative, PreToolUse present**: No version shows PostToolUse
   output, but PreToolUse evidence exists in sessions across multiple
   versions. This proves hooks were active but PostToolUse output was
   never propagated in the available data.
   **Result**: "Bug predates available first-party data (v2.0.76+)."

3. **Inconclusive**: No PreToolUse evidence in any session. Cannot
   distinguish "hooks not installed" from "hooks installed but output
   dropped."
   **Result**: "Inconclusive — hooks may not have been active in
   scanned sessions. Expand to worktree/other project dirs."

## Limitations

1. **Hook installation timing**: The incide project may not have had
   PostToolUse hooks in all CC versions. Sessions without hooks cannot
   prove the feature was broken — only that hooks weren't present.
   Git history should be cross-referenced to determine when hooks
   were first added to each project.

2. **Exit 0 sessions**: Sessions where the hook ran but found no
   violations (exit 0) produce no stderr. These sessions cannot
   prove propagation worked or didn't. Only exit 2 sessions (with
   violations) are useful positive evidence.

3. **False positives from Read/Bash**: The agent reading files that
   contain `[hook]` text produces false positives. The script's false
   positive detection (requiring BOTH success message AND hook text)
   mitigates this but may not catch all cases. Manual verification of
   positive matches is required.

4. **Version field gaps**: 11 sessions across both projects lack the
   version field. These cannot be used for version correlation.

5. **JSONL format evolution**: Verified on 2026-02-21 that schema is
   consistent across v2.0.76-v2.1.50 with four known variations (see
   Schema Variations table above). The script handles all variants via
   type guards and content normalization.

## Execution Plan

### Step 0: Git-log preamble (optional, recommended)

Check when PostToolUse hooks were first added to each project:

```bash
# Plankton: when was multi_linter.sh first committed?
git -C ~/Documents/GitHub/plankton log --oneline --diff-filter=A \
  -- .claude/hooks/multi_linter.sh

# Incide: when were hooks first added?
git -C ~/Documents/GitHub/incide log --oneline --diff-filter=A \
  -- .claude/hooks/multi_linter.sh .claude/settings.json
```

If hooks were added after a certain date, sessions before that date
can be marked `N/A (no hooks)` instead of `N (bug confirmed)`. This
is a nice-to-have — the script runs without it and the PreToolUse
control signal provides equivalent information per-session.

### Step 1: Run the bisection script

Start with plankton + incide main directories:

```bash
.claude/tests/hooks/jsonl-version-bisect.sh
```

If no positive matches found and PreToolUse evidence is sparse,
expand to incide worktree and other project dirs:

```bash
.claude/tests/hooks/jsonl-version-bisect.sh \
  ~/.claude/projects/-Users-alex-Documents-GitHub-incide-worktrees-*/ \
  ~/.claude/projects/-Users-alex-Documents-GitHub-incide-*/
```

### Step 2: Verify positive matches

Manually inspect evidence snippets in `evidence.txt` to confirm they
are genuine hook output, not false positives. Check each snippet for:

- Hook output co-located with Write/Edit success message (true positive)
- Read tool output showing file contents with `[hook]` (false positive)
- Agent-generated text quoting hook patterns (false positive)

### Step 3: Evaluate against success criteria

Compare results against the three success criteria. Determine which
outcome was reached and document the conclusion.

### Step 4: Update parent spec

Add the regression boundary (or "predates data" / "inconclusive"
conclusion) to the parent spec's Regression Timeline and Step 4
(upstream report).

## Files

| File | Role |
| ---- | ---- |
| `docs/specs/jsonl-version-bisection.md` | This spec |
| `docs/specs/posttoolusewrite-hook-stderr-silent-drop.md` | Parent spec |
| `.claude/tests/hooks/jsonl-version-bisect.sh` | Analysis script |
| `.claude/tests/hooks/jsonl-version-bisect/matrix.tsv` | Per-session output |
| `.claude/tests/hooks/jsonl-version-bisect/evidence.txt` | Match evidence |
| `.claude/tests/hooks/jsonl-version-bisect/summary.txt` | Version summary |
