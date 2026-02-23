# Benchmark Implementation — Session Log

## Session 1: Test Infrastructure + Pipeline Wiring

**Date**: 2026-02-23

### What was built

#### Phase 1: Unit tests for existing runner.py (Slice A)

**File**: `tests/unit/test_runner.py` — 11 tests

| Test                              | Covers                         |
| --------------------------------- | ------------------------------ |
| `test_write_stub`                 | Writes solution.py             |
| `test_starts_with_prompt`         | Strips prompt prefix           |
| `test_does_not_start_with_prompt` | Returns full code, no prefix   |
| `test_baseline`                   | Baseline has bare-settings     |
| `test_plankton`                   | Omits bare-settings            |
| `test_valid_json`                 | Parses JSON stdout to metadata |
| `test_invalid_json`               | Falls back on bad JSON         |
| `test_with_stderr`                | Captures stderr in metadata    |
| `test_append_two_entries`         | Appends valid JSONL lines      |
| `test_creates_workdir`            | Creates temp dir with git+stub |
| `test_writes_stub_to_repo_root`   | Writes to patched REPO_ROOT    |

#### Phase 2: Reporting/analysis script (Slice B)

**File**: `benchmark/analyze.py` — new module\
**File**: `tests/unit/test_analyze.py` — 11 tests

Functions built (all TDD):

| Function                         | Purpose                        |
| -------------------------------- | ------------------------------ |
| `load_jsonl(path)`               | Read JSONL into dicts          |
| `validate_jsonl(entries, count)` | Validate ids, dupes, empties   |
| `parse_evalplus_stdout(stdout)`  | Extract pass@N from evalplus   |
| `compute_mcnemar(b, p, tasks)`   | McNemar exact binomial test    |
| `generate_report(results_dir)`   | Markdown report from eval data |
| `main()`                         | CLI writes REPORT.md           |

**Dependency added**: `scipy` (for `binomtest`).

#### Phase 3: Integration test (Slice C)

**File**: `tests/unit/test_benchmark_integration.py` — 1 test

`test_run_task_produces_jsonl_and_log`: Mocks subprocess to test
`_run_task` end-to-end — verifies JSONL entries and log creation.

#### Phase 4: Pipeline wiring

**Changes to `benchmark/runner.py`**:

1. `_evaluate_and_report()` now:
   - Validates JSONL files before evalplus (warns, does not abort)
   - Parses evalplus stdout into structured pass rates
   - Saves `eval_results.json` (parsed) + `eval_raw.json` (raw)
   - Calls `generate_report()` and writes `REPORT.md`
2. Added `--resume` flag:
   - `_get_completed_tasks()` returns task_ids present in BOTH JSONLs
   - Skips completed tasks, preserves existing files
   - Without `--resume`, deletes existing files (original behavior)
3. Progress display:
   - Shows `tasks_done`, average time per task, ETA in minutes

**New tests for pipeline features**: 5 additional tests
(eval_results format, resume logic, flag acceptance).

### Test suite

**28 tests, all passing** (0.63s):

- `test_analyze.py`: 11
- `test_runner.py`: 16
- `test_benchmark_integration.py`: 1

### Phase 2 execution (partial)

Full benchmark started: `runner.py --mini --model claude-haiku-4-5-20251001`

**Stopped after approximately 17 tasks** (of 164). Results so far:

- `baseline.jsonl`: 18 entries
- `plankton.jsonl`: 17 entries
- 17 log files in `benchmark/results/logs/`

Mismatch (18 vs 17) means the run was interrupted mid-task.
The `--resume` flag re-runs any task not in BOTH files.

### To resume

```bash
.venv/bin/python benchmark/runner.py --mini --model claude-haiku-4-5-20251001 --resume
```

### Files created or modified

| File                                       | Action                |
| ------------------------------------------ | --------------------- |
| `benchmark/analyze.py`                     | Created               |
| `benchmark/runner.py`                      | Modified (--resume)   |
| `tests/unit/test_runner.py`                | Created               |
| `tests/unit/test_analyze.py`               | Created               |
| `tests/unit/test_benchmark_integration.py` | Created               |
| `pyproject.toml`                           | Added scipy dev dep   |
| `uv.lock`                                  | Updated               |
