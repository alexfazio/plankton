"""Integration tests: gate → run_task → solve chain."""

from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import MagicMock

from benchmark.swebench.gate import GateConfig, run_gate


class TestGateRunnerChain:
    """Gate calls run_task which calls solve — full chain with mocked solve."""

    def _make_git_repo(self, tmp_path: Path) -> Path:
        """Create a minimal git repo."""
        tmp_path.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init"], cwd=tmp_path, capture_output=True, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=tmp_path, capture_output=True, check=True)
        subprocess.run(["git", "config", "user.name", "T"], cwd=tmp_path, capture_output=True, check=True)
        (tmp_path / "stub.py").write_text("def foo(): pass\n")
        subprocess.run(["git", "add", "."], cwd=tmp_path, capture_output=True, check=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=tmp_path, capture_output=True, check=True)
        return tmp_path

    def test_gate_runs_two_tasks_through_both_conditions(self, tmp_path):
        """Gate should process 2 tasks, each getting baseline and plankton conditions."""
        repo1 = self._make_git_repo(tmp_path / "repo1")
        repo2 = self._make_git_repo(tmp_path / "repo2")

        tasks = [
            {"instance_id": "task-1", "problem_statement": "fix", "repo_dir": str(repo1)},
            {"instance_id": "task-2", "problem_statement": "fix", "repo_dir": str(repo2)},
        ]

        solve_calls = []

        def mock_solve(task, *, condition, model, timeout, **kw):
            solve_calls.append({"task_id": task["instance_id"], "condition": condition})
            return {
                "patch": f"diff for {condition}",
                "condition": condition,
                "passed": None,
                "metadata": {"elapsed_s": 1.0, "stderr": "hook: linter" if condition == "plankton" else ""},
            }

        # Create a custom run_task_fn that uses our mock_solve
        from benchmark.swebench.runner import run_task

        def custom_run_task(task, *, seed, model, timeout, results_dir, patches_dir, **kw):
            return run_task(
                task,
                seed=seed,
                model=model,
                timeout=timeout,
                results_dir=results_dir,
                patches_dir=patches_dir,
                plankton_root=tmp_path,  # dummy, hooks won't exist but inject_fn is mocked
                solve_fn=mock_solve,
                reset_fn=MagicMock(),
                inject_fn=MagicMock(),
                remove_fn=MagicMock(),
            )

        config = GateConfig(
            seed=42,
            model="test-model",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
        )

        result = run_gate(tasks, config, run_task_fn=custom_run_task, wall_clock_fn=lambda: 1.0)

        # Both tasks processed
        assert result.tasks_run == 2
        # Solve called 4 times (2 tasks × 2 conditions)
        assert len(solve_calls) == 4
        conditions_seen = {c["condition"] for c in solve_calls}
        assert conditions_seen == {"baseline", "plankton"}

    def test_run_task_passes_kwargs_to_solve(self, tmp_path):
        """run_task must pass condition, model, timeout as keyword args."""
        repo = self._make_git_repo(tmp_path / "repo")

        captured_kwargs = []

        def kwarg_capture_solve(task, **kwargs):
            captured_kwargs.append(kwargs)
            return {"patch": "diff", "condition": kwargs["condition"], "passed": None, "metadata": {}}

        from benchmark.swebench.runner import run_task

        task = {"instance_id": "kw-test", "problem_statement": "fix", "repo_dir": str(repo)}
        run_task(
            task,
            seed=1,
            model="m",
            timeout=30,
            results_dir=tmp_path / "r",
            patches_dir=tmp_path / "p",
            plankton_root=tmp_path,
            solve_fn=kwarg_capture_solve,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )

        assert len(captured_kwargs) == 2
        for kw in captured_kwargs:
            assert kw["condition"] in ("baseline", "plankton")
            assert kw["model"] == "m"
            assert kw["timeout"] == 30
        # Both conditions should be represented
        conditions = {kw["condition"] for kw in captured_kwargs}
        assert conditions == {"baseline", "plankton"}
