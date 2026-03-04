"""Tests for benchmark.swebench.runner module."""

from __future__ import annotations

from pathlib import Path

import pytest

# ── Step 3.1: flip_order ──────────────────────────────────────────────


class TestFlipOrder:
    """Test flip_order randomization logic."""

    def test_flip_order_returns_both_conditions(self) -> None:
        """Verify flip_order returns both baseline and plankton."""
        from benchmark.swebench.runner import flip_order

        a, b = flip_order("repo__123", seed=42)
        assert {a, b} == {"baseline", "plankton"}

    def test_flip_order_deterministic(self) -> None:
        """Verify same seed produces same order."""
        from benchmark.swebench.runner import flip_order

        r1 = flip_order("repo__123", seed=42)
        r2 = flip_order("repo__123", seed=42)
        assert r1 == r2

    def test_flip_order_varies(self) -> None:
        """Verify different task IDs produce both orderings."""
        from benchmark.swebench.runner import flip_order

        results = {flip_order(f"task_{i}", seed=99) for i in range(20)}
        assert len(results) == 2


# ── Step 3.2: reset_repo ─────────────────────────────────────────────


class TestResetRepo:
    """Test reset_repo git cleanup."""

    def test_reset_repo_discards_modifications(self, tmp_git_repo: Path) -> None:
        """Verify modified tracked files are restored."""
        from benchmark.swebench.runner import reset_repo

        (tmp_git_repo / "stub.py").write_text("MODIFIED\n")
        reset_repo(tmp_git_repo)
        assert (tmp_git_repo / "stub.py").read_text() == "def foo(): pass\n"

    def test_reset_repo_removes_untracked(self, tmp_git_repo: Path) -> None:
        """Verify untracked files are removed."""
        from benchmark.swebench.runner import reset_repo

        (tmp_git_repo / "extra.txt").write_text("junk\n")
        reset_repo(tmp_git_repo)
        assert not (tmp_git_repo / "extra.txt").exists()


# ── Step 3.3: inject_hooks / remove_hooks ────────────────────────────

PLANKTON_ROOT = Path(__file__).resolve().parents[2]


class TestInjectHooks:
    """Test inject_hooks and remove_hooks file operations."""

    def test_inject_hooks_copies_hooks_dir(self, tmp_path: Path) -> None:
        """Verify hooks directory is copied to target repo."""
        from benchmark.swebench.runner import inject_hooks

        inject_hooks(tmp_path, plankton_root=PLANKTON_ROOT)
        assert (tmp_path / ".claude" / "hooks" / "multi_linter.sh").exists()

    def test_inject_hooks_copies_linter_configs(self, tmp_path: Path) -> None:
        """Verify linter config files are copied."""
        from benchmark.swebench.runner import inject_hooks

        inject_hooks(tmp_path, plankton_root=PLANKTON_ROOT)
        assert (tmp_path / ".ruff.toml").exists()

    def test_remove_hooks_cleans_up(self, tmp_path: Path) -> None:
        """Verify remove_hooks deletes injected files."""
        from benchmark.swebench.runner import inject_hooks, remove_hooks

        inject_hooks(tmp_path, plankton_root=PLANKTON_ROOT)
        remove_hooks(tmp_path)
        assert not (tmp_path / ".claude" / "hooks").exists()
        assert not (tmp_path / ".ruff.toml").exists()


# ── Step 3.4: append_result / save_patch ─────────────────────────────

import json


class TestAppendResult:
    """Test append_result JSONL output."""

    def test_append_result_writes_jsonl(self, tmp_path: Path) -> None:
        """Verify a single JSONL record is written with correct fields."""
        from benchmark.swebench.runner import append_result

        out = tmp_path / "results.jsonl"
        append_result(out, task_id="repo__1", condition="baseline", passed=True, patch="diff...", metadata={"k": "v"})
        lines = out.read_text().strip().splitlines()
        assert len(lines) == 1
        rec = json.loads(lines[0])
        assert rec["task_id"] == "repo__1"
        assert rec["condition"] == "baseline"
        assert rec["passed"] is True
        assert rec["patch"] == "diff..."
        assert rec["metadata"] == {"k": "v"}


class TestSavePatch:
    """Test save_patch file naming and content."""

    def test_save_patch_filename(self, tmp_path: Path) -> None:
        """Verify patch file is named correctly and contains diff."""
        from benchmark.swebench.runner import save_patch

        save_patch(tmp_path, task_id="django/django__12345", condition="plankton", patch="diff content")
        patches = list(tmp_path.glob("*.patch"))
        assert len(patches) == 1
        assert "django__django__12345" in patches[0].name
        assert "plankton" in patches[0].name
        assert patches[0].read_text() == "diff content"


# ── Step 3.5: check_abort_criteria ───────────────────────────────────


class TestCheckAbortCriteria:
    """Test check_abort_criteria threshold logic."""

    def test_check_abort_no_abort(self) -> None:
        """Verify no abort when all stats are below thresholds."""
        from benchmark.swebench.runner import check_abort_criteria

        stats = {"infra_errors": 1, "total_completed": 20, "consecutive_empty": 5, "sustained_429_seconds": 100}
        abort, reason = check_abort_criteria(stats)
        assert abort is False
        assert reason is None

    def test_check_abort_infra_error_rate(self) -> None:
        """Verify abort triggers on high infra error rate."""
        from benchmark.swebench.runner import check_abort_criteria

        stats = {"infra_errors": 5, "total_completed": 20, "consecutive_empty": 0, "sustained_429_seconds": 0}
        abort, reason = check_abort_criteria(stats)
        assert abort is True
        assert reason is not None
        assert "infra" in reason.lower()

    def test_check_abort_consecutive_empty(self) -> None:
        """Verify abort triggers on consecutive empty patches."""
        from benchmark.swebench.runner import check_abort_criteria

        stats = {"infra_errors": 0, "total_completed": 20, "consecutive_empty": 10, "sustained_429_seconds": 0}
        abort, reason = check_abort_criteria(stats)
        assert abort is True
        assert reason is not None
        assert "empty" in reason.lower()


# ── Step 3.6: run_task ───────────────────────────────────────────────

from unittest.mock import MagicMock


class TestRunTask:
    """Test run_task orchestration logic."""

    def _make_solve_fn(self) -> MagicMock:
        """Create a mock solve function that returns condition-specific results."""

        def _solve(task, *, condition, model, timeout, **kw):  # noqa: ARG001
            return {"patch": "diff...", "condition": condition, "passed": None, "metadata": {}}

        return MagicMock(side_effect=_solve)

    def test_run_task_calls_solve_twice(self, tmp_path: Path) -> None:
        """Verify run_task calls solve for both baseline and plankton conditions."""
        from benchmark.swebench.runner import run_task

        mock_solve = self._make_solve_fn()
        mock_reset = MagicMock()
        mock_inject = MagicMock()
        mock_remove = MagicMock()
        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=mock_solve,
            reset_fn=mock_reset,
            inject_fn=mock_inject,
            remove_fn=mock_remove,
        )
        assert mock_solve.call_count == 2
        conditions = {call.kwargs["condition"] for call in mock_solve.call_args_list}
        assert conditions == {"baseline", "plankton"}
        # Verify task dict passed as first positional arg
        for call in mock_solve.call_args_list:
            task_arg = call.args[0]
            assert "instance_id" in task_arg
            assert "repo_dir" in task_arg

    def test_run_task_resets_between_conditions(self, tmp_path: Path) -> None:
        """Verify run_task resets repo state between conditions."""
        from benchmark.swebench.runner import run_task

        mock_solve = self._make_solve_fn()
        mock_reset = MagicMock()
        mock_inject = MagicMock()
        mock_remove = MagicMock()
        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=mock_solve,
            reset_fn=mock_reset,
            inject_fn=mock_inject,
            remove_fn=mock_remove,
        )
        assert mock_reset.call_count >= 1

    def test_run_task_propagates_reset_exception(self, tmp_path: Path) -> None:
        """Verify run_task doesn't swallow exceptions from reset_fn."""
        from benchmark.swebench.runner import run_task

        def _solve(task, *, condition, model, timeout, **kw):
            return {"patch": "diff", "condition": condition, "passed": None, "metadata": {}}

        def bad_reset(repo_dir):
            raise OSError("disk full")

        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        with pytest.raises(OSError, match="disk full"):
            run_task(
                task,
                seed=42,
                model="test",
                timeout=60,
                results_dir=tmp_path / "results",
                patches_dir=tmp_path / "patches",
                plankton_root=tmp_path,
                solve_fn=_solve,
                reset_fn=bad_reset,
                inject_fn=MagicMock(),
                remove_fn=MagicMock(),
            )


# ── Step 3.7: run_all ───────────────────────────────────────────────


class TestRunAll:
    """Test run_all orchestration and abort logic."""

    def test_run_all_iterates_all_tasks(self, tmp_path: Path) -> None:
        """Verify run_all processes every task in the list."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(3)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert mock_run_task.call_count == 3
        assert result["tasks_completed"] == 3
        assert result["aborted"] is False

    def test_run_all_aborts_on_threshold(self, tmp_path: Path) -> None:
        """Verify run_all aborts when consecutive empty patch threshold is reached."""
        from benchmark.swebench.runner import run_all

        # Both conditions empty -> consecutive_empty increments. Abort at 10.
        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "", "passed": None, "metadata": {}},
                    "plankton": {"patch": "", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(50)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["aborted"] is True
        assert mock_run_task.call_count < 50

    def test_run_all_tracks_infra_errors(self, tmp_path: Path) -> None:
        """Verify run_all aborts when infra error rate is too high."""
        from benchmark.swebench.runner import run_all

        # Every task has an error in metadata -> infra_errors increments
        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"error": "timeout", "error_type": "infra"},
                    },
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(10)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        # All tasks have errors -> 100% infra error rate -> abort after a few
        assert result["aborted"] is True

    def test_run_all_tracks_sustained_429(self, tmp_path: Path) -> None:
        """Verify run_all aborts on sustained 429 rate-limit errors."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"stderr": "HTTP 429 rate limit", "elapsed_s": 120},
                    },
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(10)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        # 120s * 5+ tasks should exceed 600s threshold -> abort
        assert result["aborted"] is True

    def test_run_all_resets_429_on_success(self, tmp_path: Path) -> None:
        """Verify 429 counter resets when a successful task intervenes."""
        from benchmark.swebench.runner import run_all

        call_count = 0

        def alternating_task(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count % 2 == 1:
                return {
                    "task_id": "x",
                    "conditions": {
                        "baseline": {"patch": "diff", "passed": None, "metadata": {"stderr": "429", "elapsed_s": 100}},
                        "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                    },
                }
            return {
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }

        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(20)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=alternating_task,
        )
        # Alternating 429/success should reset counter, never reaching 600s
        assert result["aborted"] is False

    def test_run_all_empty_task_list(self, tmp_path: Path) -> None:
        """Verify run_all returns immediately for empty task list."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(return_value={"task_id": "x", "conditions": {}})
        result = run_all(
            [],
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["tasks_completed"] == 0
        assert result["aborted"] is False
        assert mock_run_task.call_count == 0

    def test_run_all_forwards_dry_run_to_run_task_fn(self, tmp_path: Path) -> None:
        """run_all with dry_run=True should forward dry_run=True to run_task_fn."""
        from benchmark.swebench.runner import run_all

        captured: dict = {}

        def spy_run_task(task, **kwargs):
            captured.update(kwargs)
            return {"task_id": task["instance_id"], "conditions": {}}

        tasks = [{"instance_id": "t1", "repo_dir": str(tmp_path)}]
        run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=spy_run_task,
            dry_run=True,
        )
        assert captured.get("dry_run") is True, "dry_run must be forwarded to run_task_fn"

    def test_run_task_includes_metadata_in_summary(self, tmp_path: Path) -> None:
        """Verify run_task preserves metadata in the result summary."""
        from benchmark.swebench.runner import run_task

        def solve_fn(task, *, condition, model, timeout, **kw):
            return {"patch": "diff", "condition": condition, "passed": None, "metadata": {"key": "val"}}

        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        result = run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=solve_fn,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )
        for cond_data in result["conditions"].values():
            assert "metadata" in cond_data
            assert cond_data["metadata"]["key"] == "val"


# ── remove_hooks cleanup ─────────────────────────────────────────────


class TestRemoveHooksCleanup:
    """Test remove_hooks cleanup behavior."""

    def test_remove_hooks_removes_empty_claude_dir(self, tmp_path: Path) -> None:
        """Verify .claude dir is removed when empty after hook removal."""
        from benchmark.swebench.runner import remove_hooks

        claude_dir = tmp_path / ".claude"
        hooks_dir = claude_dir / "hooks"
        hooks_dir.mkdir(parents=True)
        (hooks_dir / "hook.sh").write_text("#!/bin/sh\n")
        remove_hooks(tmp_path)
        assert not claude_dir.exists()

    def test_remove_hooks_preserves_nonempty_claude_dir(self, tmp_path: Path) -> None:
        """Verify .claude dir is preserved when it contains other files."""
        from benchmark.swebench.runner import remove_hooks

        claude_dir = tmp_path / ".claude"
        hooks_dir = claude_dir / "hooks"
        hooks_dir.mkdir(parents=True)
        (hooks_dir / "hook.sh").write_text("#!/bin/sh\n")
        (claude_dir / "settings.json").write_text("{}")
        remove_hooks(tmp_path)
        assert not hooks_dir.exists()
        assert claude_dir.exists()
        assert (claude_dir / "settings.json").exists()


# ── run_task solve_fn signature ──────────────────────────────────────


class TestRunTaskSignature:
    """Test run_task solve_fn call signature."""

    def test_run_task_passes_task_dict_to_solve(self, tmp_path: Path) -> None:  # noqa: E301
        """Verify run_task passes the full task dict to solve_fn."""
        from benchmark.swebench.runner import run_task

        received_args = []

        def spy_solve(task, *, condition, model, timeout, **kw):
            received_args.append(task)
            return {"patch": "diff", "condition": condition, "passed": None, "metadata": {}}

        task = {"instance_id": "repo__1", "problem_statement": "fix bug", "repo_dir": str(tmp_path)}
        run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=spy_solve,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )
        assert len(received_args) == 2
        for arg in received_args:
            assert arg["instance_id"] == "repo__1"
            assert arg["problem_statement"] == "fix bug"
            assert arg["repo_dir"] == str(tmp_path)


# ── Step B1: Error classification ────────────────────────────────────

import subprocess


class TestErrorClassification:
    """Test infra vs task error classification in run_all."""

    def test_timeout_counts_as_infra_error(self, tmp_path: Path) -> None:
        """Tasks with error_type=infra should trigger infra error abort."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"error": "timeout", "error_type": "infra"},
                    },
                    "plankton": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"error": "timeout", "error_type": "infra"},
                    },
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(10)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["aborted"] is True

    def test_empty_patch_not_counted_as_infra_error(self, tmp_path: Path) -> None:
        """Empty patches without error_type should NOT trigger infra error abort."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "", "passed": None, "metadata": {"error": "empty_patch"}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(10)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        # Should NOT abort due to infra errors (error without error_type is not infra)
        assert result["aborted"] is False

    def test_nonzero_returncode_sets_error_type_infra(self) -> None:
        """_parse_claude_output sets error_type=infra on non-zero returncode."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="not json", stderr="crash")
        metadata = _parse_claude_output(result, 5.0)
        assert metadata.get("error_type") == "infra"


# ── Slice A1: CLAUDE.md safety check ─────────────────────────────────


class TestClaudeMdSafetyCheck:
    """Test CLAUDE.md safety guard in run_all."""

    def test_run_all_raises_when_claude_md_exists_without_bak(self, tmp_path: Path) -> None:
        """run_all raises RuntimeError if CLAUDE.md exists without .bak."""
        from benchmark.swebench.runner import run_all

        (tmp_path / "CLAUDE.md").write_text("# test")
        with pytest.raises(RuntimeError, match="CLAUDE.md"):
            run_all(
                tasks=[],
                seed=1,
                model="m",
                timeout=60,
                results_dir=tmp_path / "r",
                patches_dir=tmp_path / "p",
                plankton_root=tmp_path,
            )

    def test_run_all_raises_when_both_claude_md_and_bak_exist(self, tmp_path: Path) -> None:
        """Should raise RuntimeError when both CLAUDE.md and .bak exist."""
        from benchmark.swebench.runner import run_all

        (tmp_path / "CLAUDE.md").write_text("# test")
        (tmp_path / "CLAUDE.md.bak").write_text("# backup")
        with pytest.raises(RuntimeError, match="CLAUDE.md"):
            run_all(
                tasks=[],
                seed=1,
                model="m",
                timeout=60,
                results_dir=tmp_path / "r",
                patches_dir=tmp_path / "p",
                plankton_root=tmp_path,
            )

    def test_run_all_proceeds_when_claude_md_bak_exists(self, tmp_path: Path) -> None:
        """run_all proceeds normally when only CLAUDE.md.bak exists."""
        from benchmark.swebench.runner import run_all

        (tmp_path / "CLAUDE.md.bak").write_text("# test")
        result = run_all(
            tasks=[],
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            plankton_root=tmp_path,
        )
        assert result["aborted"] is False
        assert result["tasks_completed"] == 0

    def test_run_all_proceeds_when_neither_exists(self, tmp_path: Path) -> None:
        """run_all proceeds normally when neither CLAUDE.md nor .bak exists."""
        from benchmark.swebench.runner import run_all

        result = run_all(
            tasks=[],
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            plankton_root=tmp_path,
        )
        assert result["aborted"] is False
        assert result["tasks_completed"] == 0


# ── Slice A2: Mid-run resume support ─────────────────────────────────


class TestResume:
    """Test mid-run resume via completed_ids."""

    def test_run_all_skips_completed_ids(self, tmp_path: Path) -> None:
        """run_all skips tasks whose instance_id is in completed_ids."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(3)]
        run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
            completed_ids={"t_0"},
        )
        assert mock_run_task.call_count == 2
        called_ids = [call.args[0]["instance_id"] for call in mock_run_task.call_args_list]
        assert "t_0" not in called_ids
        assert "t_1" in called_ids
        assert "t_2" in called_ids

    def test_load_completed_ids_with_both_conditions(self, tmp_path: Path) -> None:
        """load_completed_ids returns IDs that have both baseline and plankton."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        jsonl.write_text(
            json.dumps({"task_id": "t1", "condition": "baseline", "passed": None, "patch": "", "metadata": {}})
            + "\n"
            + json.dumps({"task_id": "t1", "condition": "plankton", "passed": None, "patch": "", "metadata": {}})
            + "\n"
            + json.dumps({"task_id": "t2", "condition": "baseline", "passed": None, "patch": "", "metadata": {}})
            + "\n"
        )
        result = load_completed_ids(results_dir)
        assert result == {"t1"}

    def test_load_completed_ids_nonexistent_file(self, tmp_path: Path) -> None:
        """load_completed_ids returns empty set for missing results dir."""
        from benchmark.swebench.runner import load_completed_ids

        result = load_completed_ids(tmp_path / "nonexistent")
        assert result == set()


# ── Slice A3: Sustained 429 tracking documentation tests ─────────────


class TestSustained429Tracking:
    """Document 429 accumulation and reset semantics per ADR."""

    def test_429_accumulates_across_consecutive_tasks(self, tmp_path: Path) -> None:
        """Six consecutive 429 tasks at 120s each (720s) exceed 600s threshold."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"stderr": "HTTP 429", "elapsed_s": 120},
                    },
                    "plankton": {
                        "patch": "diff",
                        "passed": None,
                        "metadata": {"stderr": "HTTP 429", "elapsed_s": 120},
                    },
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(6)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["aborted"] is True
        assert "429" in result.get("abort_reason", "")

    def test_429_resets_on_clean_task(self, tmp_path: Path) -> None:
        """Alternating 429/clean tasks never accumulate past threshold."""
        from benchmark.swebench.runner import run_all

        call_count = 0

        def alternating_task(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count % 2 == 1:
                return {
                    "task_id": "x",
                    "conditions": {
                        "baseline": {
                            "patch": "diff",
                            "passed": None,
                            "metadata": {"stderr": "HTTP 429", "elapsed_s": 120},
                        },
                        "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                    },
                }
            return {
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }

        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(20)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=alternating_task,
        )
        assert result["aborted"] is False
        assert result["tasks_completed"] == 20


# ── Slice C1: Malformed JSONL resilience ──────────────────────────────


class TestLoadCompletedIdsMalformed:
    """Test load_completed_ids with malformed JSONL lines."""

    def test_should_skip_malformed_jsonl_lines_and_return_valid_entries(self, tmp_path: Path) -> None:
        """Should skip malformed JSONL lines and return valid entries."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        jsonl.write_text(
            json.dumps({"task_id": "t1", "condition": "baseline", "passed": None, "patch": "", "metadata": {}})
            + "\n"
            + "NOT VALID JSON\n"
            + json.dumps({"task_id": "t1", "condition": "plankton", "passed": None, "patch": "", "metadata": {}})
            + "\n"
        )
        result = load_completed_ids(results_dir)
        assert result == {"t1"}

    def test_should_return_empty_set_when_all_lines_are_corrupt(self, tmp_path: Path) -> None:
        """Should return empty set when all lines are corrupt."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        jsonl.write_text("BAD LINE 1\nBAD LINE 2\n")
        result = load_completed_ids(results_dir)
        assert result == set()


# ── Slice C2: Validate condition names ────────────────────────────────


class TestLoadCompletedIdsConditionNames:
    """Test load_completed_ids validates condition names, not just count."""

    def test_should_not_mark_complete_with_two_baseline_entries(self, tmp_path: Path) -> None:
        """Should NOT mark task complete with 2 baseline entries and 0 plankton."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        jsonl.write_text(
            json.dumps({"task_id": "t1", "condition": "baseline", "passed": None, "patch": "", "metadata": {}})
            + "\n"
            + json.dumps({"task_id": "t1", "condition": "baseline", "passed": None, "patch": "x", "metadata": {}})
            + "\n"
        )
        result = load_completed_ids(results_dir)
        assert "t1" not in result

    def test_should_mark_complete_only_with_both_conditions(self, tmp_path: Path) -> None:
        """Should mark task complete only with both baseline and plankton."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        jsonl.write_text(
            json.dumps({"task_id": "t1", "condition": "baseline", "passed": None, "patch": "", "metadata": {}})
            + "\n"
            + json.dumps({"task_id": "t1", "condition": "plankton", "passed": None, "patch": "", "metadata": {}})
            + "\n"
        )
        result = load_completed_ids(results_dir)
        assert result == {"t1"}


# ── Slice A5: Seed recording in run_all return ────────────────────────


class TestRunAllReturnMetadata:
    """Test run_all returns seed, model, and timeout."""

    def test_should_include_seed_model_timeout_in_run_all_return(self, tmp_path: Path) -> None:
        """Should include seed, model, and timeout in run_all return dict."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": "t_0", "repo_dir": str(tmp_path)}]
        result = run_all(
            tasks,
            seed=42,
            model="claude-sonnet-4-20250514",
            timeout=1800,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["seed"] == 42
        assert result["model"] == "claude-sonnet-4-20250514"
        assert result["timeout"] == 1800


# ── Slice A4: run_task exception handling ─────────────────────────────


class TestRunTaskExceptionHandling:
    """Test run_task writes error result when solve raises."""

    def test_should_write_error_result_when_solve_raises_for_one_condition(self, tmp_path: Path) -> None:
        """Should write error result to JSONL when solve raises for one condition."""
        from benchmark.swebench.runner import flip_order, run_task

        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        first, second = flip_order("repo__1", seed=42)

        def raising_solve(task, *, condition, model, timeout, **kw):
            if condition == "baseline":
                raise RuntimeError("boom")
            return {"patch": "diff...", "condition": condition, "passed": None, "metadata": {}}

        result = run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=raising_solve,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )
        # Both conditions should have entries in JSONL
        results_file = tmp_path / "results" / "results.jsonl"
        lines = [json.loads(line) for line in results_file.read_text().strip().splitlines()]
        assert len(lines) == 2
        conditions_written = {line["condition"] for line in lines}
        assert conditions_written == {"baseline", "plankton"}

    def test_should_continue_to_second_condition_when_first_raises(self, tmp_path: Path) -> None:
        """Should continue to second condition when first raises."""
        from benchmark.swebench.runner import flip_order, run_task

        task = {"instance_id": "repo__1", "repo_dir": str(tmp_path)}
        first, second = flip_order("repo__1", seed=42)

        def raising_solve(task, *, condition, model, timeout, **kw):
            if condition == first:
                raise RuntimeError("boom")
            return {"patch": "good-diff", "condition": condition, "passed": None, "metadata": {}}

        result = run_task(
            task,
            seed=42,
            model="test",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            solve_fn=raising_solve,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )
        # The second condition should have a non-empty patch
        results_file = tmp_path / "results" / "results.jsonl"
        lines = [json.loads(line) for line in results_file.read_text().strip().splitlines()]
        second_entry = [l for l in lines if l["condition"] == second][0]
        assert second_entry["patch"] == "good-diff"
        # The failed condition should have empty patch and error metadata
        first_entry = [l for l in lines if l["condition"] == first][0]
        assert first_entry["patch"] == ""
        assert first_entry["metadata"]["error_type"] == "infra"


# ── Slice D: tasks_skipped count ──────────────────────────────────────


class TestTasksSkipped:
    """Test run_all reports tasks_skipped count."""

    def test_should_report_tasks_skipped_count(self, tmp_path: Path) -> None:
        """Should report tasks_skipped count when completed_ids provided."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(5)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
            completed_ids={"t_0", "t_2"},
        )
        assert result["tasks_skipped"] == 2
        assert result["tasks_completed"] == 3

    def test_should_report_tasks_skipped_zero(self, tmp_path: Path) -> None:
        """Should report tasks_skipped=0 when no completed_ids."""
        from benchmark.swebench.runner import run_all

        mock_run_task = MagicMock(
            return_value={
                "task_id": "x",
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }
        )
        tasks = [{"instance_id": f"t_{i}", "repo_dir": str(tmp_path)} for i in range(3)]
        result = run_all(
            tasks,
            seed=1,
            model="m",
            timeout=60,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            run_task_fn=mock_run_task,
        )
        assert result["tasks_skipped"] == 0


# --- dry_run forwarding through run_task ---


class TestRunTaskDryRun:
    """Test dry_run flag forwarding through run_task."""

    def test_run_task_forwards_dry_run(self, tmp_path, monkeypatch) -> None:
        """run_task(dry_run=True) must pass dry_run=True to the solve function."""
        import benchmark.swebench.runner as runner_mod
        from benchmark.swebench.runner import run_task

        captured: dict = {}

        def fake_solve(task, *, condition, model, timeout, **kwargs):
            captured.update(kwargs)
            return {"patch": "diff", "condition": condition, "passed": None, "metadata": {}}

        task = {"instance_id": "t1", "problem_statement": "fix", "repo_dir": str(tmp_path)}
        (tmp_path / ".git").mkdir()

        monkeypatch.setattr(runner_mod, "reset_repo", lambda *a, **k: None)
        monkeypatch.setattr(runner_mod, "inject_hooks", lambda *a, **k: None)
        monkeypatch.setattr(runner_mod, "remove_hooks", lambda *a, **k: None)

        run_task(
            task,
            seed=42,
            model="m",
            timeout=30,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            solve_fn=fake_solve,
            dry_run=True,
        )

        assert captured.get("dry_run") is True, "dry_run must be forwarded to solve_fn"
