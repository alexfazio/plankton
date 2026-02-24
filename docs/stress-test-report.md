# Stress Test Report

Generated: 2026-02-23T17:16:40Z

## Summary

| Metric | Count |
| ------ | ----- |
| Total  | 133   |
| Pass   | 125   |
| Fail   | 0     |
| Skip   | 8     |

## Per-Category Breakdown

| Category | Pass | Fail | Skip |
| -------- | ---- | ---- | ---- |
| A: Language Handlers | 46 | 0 | 4 |
| B: Model Selection | 11 | 0 | 3 |
| C: Config Toggles | 12 | 0 | 0 |
| D: PreToolUse Protection | 21 | 0 | 0 |
| E: Stop Hook | 7 | 0 | 1 |
| F: Session-Scoped | 8 | 0 | 0 |
| G: Edge Cases | 15 | 0 | 0 |
| H: Performance | 5 | 0 | 0 |

## Failures

None.

## Skips

| # | Test | Reason |
| - | ---- | ------ |
| 8 | A8: Python PYD pydantic lint | flake8-pydantic requires uv project |
| 9 | A9: Python vulture dead code | vulture requires uv project |
| 10 | A10: Python bandit security | bandit requires uv project |
| 11 | A11: Python ASYNC patterns | flake8-async requires uv project |
| 53 | B3: unresolved-attribute -> opus | ty not available in test context |
| 62 | B12: ASYNC -> sonnet | flake8-async requires uv project |
| 64 | B14: PYD -> sonnet | flake8-pydantic requires uv project |
| 101 | E4: Guard file matching hash -> approve | PPID mismatch in subshell |

## Performance

| Test | Description | Actual | Limit |
| ---- | ----------- | ------ | ----- |
| H1 | Python clean | 1134ms | 2000ms |
| H2 | Shell clean | 171ms | 2000ms |
| H3 | YAML clean | 221ms | 2000ms |
| H4 | Markdown clean | 466ms | 2000ms |
| H5 | Biome 500-line | 1334ms | 2000ms |

## Recommendations

### sed parsing fragility (YAML/flake8)

The yamllint and flake8 parsable output is converted to JSON via
`sed` + `jaq` pipelines. Lines containing colons, parentheses, or
brackets in messages can confuse the regex. Consider switching to
native JSON output where available (yamllint does not support it;
flake8 supports `--format=json` in newer versions).

### Biome JSON reporter stability

Biome's `--reporter=json` output structure can change between
versions. The span-to-line conversion uses `split("\n")` on
sourceCode which may break if sourceCode is absent. Pin biome
version or add defensive nil checks in the jaq pipeline.

### Path handling edge cases

Files outside `CLAUDE_PROJECT_DIR` lose relative path conversion
for biome. The `_biome_relpath()` function falls back to absolute
paths, which biome may reject for project-scoped rules. Consider
warning when file is outside project root.

### Config toggle interaction bugs

When `auto_format=false` and `subprocess_delegation=false`, the
hook still runs Phase 2 and exits 2 on violations. This is correct
behavior but may surprise users who expect the hook to be fully
disabled. Consider a `hook_enabled=false` master toggle.

### Model selection boundary correctness

The volume threshold uses `>` (strictly greater than), so exactly
5 violations selects haiku/sonnet, not opus. This is intentional
but should be documented clearly. The boundary is at 6+ violations.

### Missing tool graceful degradation

All tool checks use `command -v` and skip gracefully. The only
hard dependency is `jaq` for JSON parsing. If jaq is missing, the
hook cannot function. Consider a startup check that warns if jaq
is not available.
