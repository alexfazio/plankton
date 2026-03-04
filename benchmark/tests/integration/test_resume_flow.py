"""Integration tests for the save → load → resume flow."""

from __future__ import annotations

import json


class TestResumeFlow:
    """run_all should skip completed tasks identified from prior results."""

    class _RunTaskFn:
        def __init__(self):
            self.calls: list[str] = []

        def __call__(self, task, *, seed, model, timeout, results_dir, patches_dir, plankton_root, **kw):
            self.calls.append(task["instance_id"])
            from benchmark.swebench.runner import append_result, save_patch

            for cond in ("baseline", "plankton"):
                append_result(
                    results_dir / "results.jsonl",
                    task_id=task["instance_id"],
                    condition=cond,
                    passed=None,
                    patch=f"diff for {cond}",
                    metadata={"elapsed_s": 1.0},
                )
                save_patch(patches_dir, task_id=task["instance_id"], condition=cond, patch=f"diff for {cond}")
            return {
                "task_id": task["instance_id"],
                "conditions": {
                    "baseline": {"patch": "diff for baseline", "passed": None, "metadata": {"elapsed_s": 1.0}},
                    "plankton": {"patch": "diff for plankton", "passed": None, "metadata": {"elapsed_s": 1.0}},
                },
            }

    def _make_run_task_fn(self):
        return self._RunTaskFn()

    def test_run_all_skips_completed_tasks(self, tmp_path):
        """Tasks with both conditions in prior JSONL should be skipped."""
        from benchmark.swebench.runner import run_all

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        patches_dir = tmp_path / "patches"

        # Pre-populate results for task-1
        jsonl = results_dir / "results.jsonl"
        for cond in ("baseline", "plankton"):
            record = {"task_id": "task-1", "condition": cond, "passed": None, "patch": "diff", "metadata": {}}
            with jsonl.open("a") as f:
                f.write(json.dumps(record) + "\n")

        tasks = [
            {"instance_id": "task-1", "problem_statement": "fix", "repo_dir": str(tmp_path)},
            {"instance_id": "task-2", "problem_statement": "fix", "repo_dir": str(tmp_path)},
            {"instance_id": "task-3", "problem_statement": "fix", "repo_dir": str(tmp_path)},
        ]

        mock_fn = self._make_run_task_fn()
        # Ensure CLAUDE.md doesn't exist at plankton_root
        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_path,  # no CLAUDE.md here
            run_task_fn=mock_fn,
            completed_ids={"task-1"},
        )

        assert result["tasks_skipped"] == 1
        assert result["tasks_completed"] == 2
        assert "task-1" not in mock_fn.calls
        assert "task-2" in mock_fn.calls
        assert "task-3" in mock_fn.calls

    def test_partial_completion_not_skipped(self, tmp_path):
        """Task with only baseline (no plankton) should NOT be in completed_ids."""
        from benchmark.swebench.runner import load_completed_ids

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        jsonl = results_dir / "results.jsonl"
        record = {"task_id": "task-1", "condition": "baseline", "passed": None, "patch": "diff", "metadata": {}}
        jsonl.write_text(json.dumps(record) + "\n")

        completed = load_completed_ids(results_dir)
        assert "task-1" not in completed

    def test_full_cycle_run_save_resume(self, tmp_path):
        """Full cycle: run 1 task, then resume should skip it."""
        from benchmark.swebench.runner import load_completed_ids, run_all

        results_dir = tmp_path / "results"
        results_dir.mkdir()
        patches_dir = tmp_path / "patches"

        tasks = [{"instance_id": "cycle-1", "problem_statement": "fix", "repo_dir": str(tmp_path)}]

        mock_fn = self._make_run_task_fn()

        # First run
        run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_path,
            run_task_fn=mock_fn,
        )
        assert len(mock_fn.calls) == 1

        # Load completed and resume
        completed = load_completed_ids(results_dir)
        assert "cycle-1" in completed

        mock_fn2 = self._make_run_task_fn()
        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_path,
            run_task_fn=mock_fn2,
            completed_ids=completed,
        )
        assert result["tasks_skipped"] == 1
        assert result["tasks_completed"] == 0
        assert len(mock_fn2.calls) == 0
