"""End-to-end pipeline integration tests: JSONL → prepare → run → analyze → report."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock


class TestFullPipeline:
    """Wire all modules together in a realistic flow."""

    def _write_jsonl(self, path: Path, tasks: list[dict]) -> Path:
        with path.open("w", encoding="utf-8") as f:
            for t in tasks:
                f.write(json.dumps(t) + "\n")
        return path

    def _make_run_task_fn(self):
        """Mock run_task_fn that writes JSONL and returns results."""
        calls = []

        def fn(task, *, seed, model, timeout, results_dir, patches_dir, plankton_root, **kw):
            from benchmark.swebench.runner import append_result, save_patch

            calls.append(task["instance_id"])
            results_dir.mkdir(parents=True, exist_ok=True)
            patches_dir.mkdir(parents=True, exist_ok=True)
            summaries = {}
            for cond in ("baseline", "plankton"):
                patch = f"diff --git a/fix.py\n--- {cond} fix for {task['instance_id']}"
                # Simulate: plankton passes, baseline fails for first task
                passed = (cond == "plankton") if task["instance_id"].endswith("-1") else True
                append_result(
                    results_dir / "results.jsonl",
                    task_id=task["instance_id"],
                    condition=cond,
                    passed=passed,
                    patch=patch,
                    metadata={"elapsed_s": 2.0},
                )
                save_patch(patches_dir, task_id=task["instance_id"], condition=cond, patch=patch)
                summaries[cond] = {"patch": patch, "passed": passed, "metadata": {"elapsed_s": 2.0}}
            return {"task_id": task["instance_id"], "conditions": summaries}

        setattr(fn, "calls", calls)
        return fn

    def test_full_pipeline_jsonl_to_report(self, tmp_path):
        """Full pipeline: load JSONL → prepare (mock checkout) → run_all → analyze → report."""
        from benchmark.swebench.analyze import generate_report, load_paired_results_from_combined
        from benchmark.swebench.runner import run_all
        from benchmark.swebench.tasks import load_tasks_from_jsonl, prepare_tasks, select_tasks

        # 1. Write tasks JSONL
        tasks_data = [
            {
                "instance_id": f"repo__issue-{i}",
                "problem_statement": f"Fix bug {i}",
                "repo": "test/repo",
                "base_commit": "abc123",
            }
            for i in range(1, 4)
        ]
        jsonl_path = self._write_jsonl(tmp_path / "tasks.jsonl", tasks_data)

        # 2. Load and prepare (mock checkout just adds repo_dir)
        tasks = load_tasks_from_jsonl(jsonl_path)
        tasks = select_tasks(tasks)

        # Use mock checkout_fn
        tasks = prepare_tasks(tasks, tmp_path / "repos", checkout_fn=lambda t, d: {**t, "repo_dir": str(tmp_path)})

        assert len(tasks) == 3

        # 3. Run all
        results_dir = tmp_path / "results"
        patches_dir = tmp_path / "patches"
        mock_fn = self._make_run_task_fn()

        result = run_all(
            tasks,
            seed=42,
            model="test-model",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_path,  # no CLAUDE.md here
            run_task_fn=mock_fn,
        )

        assert not result["aborted"]
        assert result["tasks_completed"] == 3
        assert len(mock_fn.calls) == 3

        # 4. Load paired results from combined JSONL
        paired = load_paired_results_from_combined(results_dir / "results.jsonl")
        assert len(paired) == 3
        for tid, data in paired.items():
            assert "baseline" in data
            assert "plankton" in data

        # 5. Generate report
        report = generate_report(paired, {"seed": 42, "model": "test-model"})
        assert "# SWE-bench Benchmark Report" in report
        assert "seed" in report
        assert "McNemar" in report
        assert "baseline" in report
        assert "plankton" in report
        # Task issue-1: baseline fails, plankton passes → should show in McNemar
        assert "fail→pass" in report or "Plankton helped" in report

        # 6. Verify patch files exist
        patches = list(patches_dir.glob("*.patch"))
        assert len(patches) == 6  # 3 tasks × 2 conditions

    def test_pipeline_with_resume(self, tmp_path):
        """Run 2/3 tasks, then resume to complete the remaining 1."""
        from benchmark.swebench.analyze import load_paired_results_from_combined
        from benchmark.swebench.runner import load_completed_ids, run_all

        results_dir = tmp_path / "results"
        patches_dir = tmp_path / "patches"

        tasks = [
            {"instance_id": f"resume-{i}", "problem_statement": f"Fix {i}", "repo_dir": str(tmp_path)}
            for i in range(1, 4)
        ]

        # First run: only run 2 tasks (simulate by providing 2 tasks)
        mock_fn1 = self._make_run_task_fn()
        run_all(
            tasks[:2],
            seed=42,
            model="m",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_path,
            run_task_fn=mock_fn1,
        )
        assert len(mock_fn1.calls) == 2

        # Resume: load completed, run all 3 tasks
        completed = load_completed_ids(results_dir)
        assert len(completed) == 2

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
        assert result["tasks_skipped"] == 2
        assert result["tasks_completed"] == 1
        assert mock_fn2.calls == ["resume-3"]

        # Verify combined JSONL has all 3 tasks
        paired = load_paired_results_from_combined(results_dir / "results.jsonl")
        assert len(paired) == 3
