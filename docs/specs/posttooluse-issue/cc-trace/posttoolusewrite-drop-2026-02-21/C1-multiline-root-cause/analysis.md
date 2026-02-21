# C1: rerun_phase2() Multi-Line Root Cause Investigation

## Date: 2026-02-21
## Status: RESOLVED — Root cause definitively identified

## Root Cause

The `|| echo "[]"` fallback pattern in linter command captures triggers
when the linter exits non-zero due to finding violations (its NORMAL
behavior), appending `[]` to the already-valid JSON output.

### Bug chain (shell file example):

1. `v=$(shellcheck -f json "${fp}" 2>/dev/null || echo "[]")`
   - shellcheck outputs valid JSON array: `[{...}, {...}, ...]`
   - shellcheck exits 1 (violations found — normal behavior)
   - `|| echo "[]"` triggers because exit code ≠ 0
   - `v` = `[{violations}]\n[]` (TWO JSON values)

2. `count=$(echo "${v}" | jaq 'length' 2>/dev/null || echo "0")`
   - jaq processes both JSON values as a stream
   - First value: violations array → outputs `20`
   - Second value: `[]` → outputs `0`
   - `count` = `"20\n0"` (multi-line!)

3. `remaining=$(rerun_phase2 "${file_path}" "${file_type}")`
   - Captures `"20\n0"`
   - `[[ "20\n0" -eq 0 ]]` → bash syntax error (line 1282)

### Affected file types (SYSTEMIC)

The same `|| echo "[]"` pattern exists in ALL file type handlers:

| Line | Command | Fallback | Affected? |
|------|---------|----------|-----------|
| 504 | `ruff check --output-format=json` | `|| echo "[]"` | YES — ruff exits 1 on violations |
| 510 | `uv run ty check --output-format gitlab` | `|| echo "[]"` | YES — ty exits non-zero on violations |
| 541 | `uv run bandit -f json` | `|| echo '{"results":[]}'` | YES — bandit exits non-zero |
| 561 | `shellcheck -f json` | `|| echo "[]"` | YES — confirmed root cause |
| 597 | `hadolint --no-color -f json` | `|| echo "[]"` | YES — hadolint exits non-zero |

### Why it only manifested as `56\n0` (not `20\n0`)

The original bug was observed on `fix-setapp.sh` (252 lines) which had 56
ShellCheck violations. The test file in this investigation has 20 violations,
producing `20\n0`. The `\n0` suffix is always `0` because the appended
`[]` always has length 0.

## Evidence

| File | Contents |
|------|----------|
| `shellcheck-raw.json` | Raw shellcheck output: 1 line, single JSON array |
| `jaq-length-output.txt` | Direct pipeline output: `20` (single line) |
| `jaq-length-linecount.txt` | Line count: 1 |
| `test-violations.sh` | Test file with known violations |

### Key evidence: shellcheck exit codes

```
shellcheck (violations found): exit 1
shellcheck (clean file):       exit 0
```

### Variable capture comparison

```
WITH || echo "[]": v contains 2 JSON values → jaq outputs "20\n0"
WITHOUT (|| true): v contains 1 JSON value  → jaq outputs "20"
Using (; true):    v contains 1 JSON value  → jaq outputs "20"
```

## Correct Fix

The `| tail -1` fix on line 1280 is a DOWNSTREAM workaround. The proper
fix is at the source — each linter command capture should use:

```bash
# Instead of:
v=$(shellcheck -f json "${fp}" 2>/dev/null || echo "[]")

# Use:
v=$(shellcheck -f json "${fp}" 2>/dev/null) || v="[]"
```

The `|| v="[]"` form assigns `[]` ONLY when shellcheck produces no output
(tool not found, crash), rather than appending it to existing valid output.

Both fixes should be applied:
1. Source fix: `v=$(...) || v="[]"` in all linter captures (prevents the bug)
2. Defensive fix: `| tail -1` on line 1280 (guards against other multi-line leaks)

## Systemic Confirmation (2026-02-21)

Tested other linter commands to verify the same bug pattern:

### ruff check
- Exit code on violations: 1
- With `|| echo "[]"`: produces 2 JSON values
- `jaq 'length'` output: `<N>\n0` (confirmed multi-line)

### Summary
The `|| echo "[]"` fallback pattern is BROKEN for all linters that exit
non-zero when violations are found (which is standard linter behavior).
This is not a shellcheck-specific issue — it affects every file type
handler in rerun_phase2().
