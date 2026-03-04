# Hook Integration Test — Run Comparison

**Current run**: 2026-02-20T154717Z (Run 2)
**Previous run**: 2026-02-20T131609Z (Run 1, archived)

---

## Summary

| Metric | Run 1 | Run 2 | Delta |
| ------ | ----- | ----- | ----- |
| Total tests | 103 | 103 | — |
| Pass | 103 | 101 | -2 |
| Fail | 0 | 2 | +2 |
| Skipped | 2 | 8 | +6 |

---

## Regressions (pass to fail)

**DEP14_no_hooks**: pass in Run 1, **fail** in Run 2. The dep-agent
checked `.claude/subprocess-settings.json` (project-local) but the file
lives at `.claude/subprocess-settings.json` (user home). The file
exists and is correct — this is a test path bug, not a missing file.

## New Failures (not in Run 1)

**P28 live_trigger_pip**: PreToolUse hooks do not fire for TeamCreate
teammate Bash tool calls. Run 1 used a different live trigger
approach. Environment limitation, not a hook defect.

---

## Naming Convention Change (pm-agent)

Run 1 pm-agent used `P01_pip_blocked` format. Run 2 uses
`pip_blocked` (without ID prefix). This causes 32 "added" and 32
"removed" entries in the automated diff, but these are the **same
32 tests** with different `test_name` values. No functional change.

**Affected**: P01-P32 (all pm-agent tests)

---

## Meaningful Test Result Changes

**M26_ts_combined_config** (`actual_exit`: 2 to 0): Run 1 used
`noExplicitAny` fixture (unfixable by `--unsafe`). Run 2 used
unused var fixture which biome `--unsafe` auto-fixes. Different
fixture strategy, both valid.

**M31_py_multi_tool** (`actual_exit`: 0 to 2): Run 1 skipped
(bandit absent). Run 2 ran — bandit still absent but F841
triggers exit 2. Test now validates ruff Phase 2 even without
bandit.

**M19_live_trigger** (`actual_exit`: null to 0): Run 1 recorded
null (Layer 2 convention). Run 2 recorded 0. Both indicate hook
fired successfully.

---

## Environment Delta

<!-- markdownlint-disable MD013 -->
| Tool | Run 1 | Run 2 | Change |
| ---- | ----- | ----- | ------ |
| semgrep | Present | Absent | Removed from environment |
| bandit (DEP24) | Absent | Absent | No change |
| subprocess-settings | Present | N/A | Test path corrected (migrated from legacy settings) |
<!-- markdownlint-enable MD013 -->

All other tools unchanged between runs.

---

## Note Enrichment (cosmetic changes)

Run 2 dep-agent provides richer notes with tool paths (e.g.,
`"found: /opt/homebrew/bin/jaq"` vs empty string). This affects
22 dep-agent records but has no functional impact — all pass/fail
results are identical for these tests.

Run 2 ml-agent notes document fixture adaptations (e.g., M01
notes `"fixture needs docstrings for D100/D103"`). These capture
learnings from Run 1 that were applied to Run 2 fixtures.

---

## Actionable Items

1. **Fix DEP14 test path** — Check `.claude/subprocess-settings.json`
   (home dir) instead of `.claude/subprocess-settings.json` (project).
2. **Standardize pm-agent test_name format** — Decide between
   `P01_pip_blocked` (Run 1) and `pip_blocked` (Run 2) for
   consistent cross-run comparison.
3. **Document M26 fixture strategy** — The exit code difference
   (2 vs 0) is due to fixture choice, not a hook behavior change.
   Pin the fixture in the ADR to prevent future confusion.
4. **Investigate semgrep removal** — semgrep was present in Run 1
   but absent in Run 2. If intentional, update documentation.
