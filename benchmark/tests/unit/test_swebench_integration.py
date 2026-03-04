"""Integration tests for benchmark.swebench package."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock


class TestPackageExports:
    """Tests that swebench package exports are properly callable."""

    def test_all_exports_callable(self) -> None:
        """Verify all public swebench exports are callable."""
        from benchmark.swebench import (
            compute_mcnemar,
            generate_report,
            load_paired_results,
            load_paired_results_from_combined,
            run_all,
            run_task,
            solve,
        )

        for fn in (
            compute_mcnemar,
            generate_report,
            load_paired_results,
            load_paired_results_from_combined,
            run_all,
            run_task,
            solve,
        ):
            assert callable(fn)


class TestEndToEndMock:
    """End-to-end integration tests using mocked external dependencies."""

    def test_run_task_produces_jsonl_and_patches(self, tmp_git_repo: Path) -> None:
        """Test that run_task produces JSONL output and patch files."""
        from benchmark.swebench.runner import run_task

        results_dir = tmp_git_repo / "results"
        patches_dir = tmp_git_repo / "patches"

        def mock_solve(task, *, condition, model, timeout, **kw):
            # Simulate modifying a file
            (Path(task["repo_dir"]) / "stub.py").write_text(f"# {condition}\n")
            return {
                "patch": f"diff for {condition}",
                "condition": condition,
                "passed": None,
                "metadata": {"elapsed_s": 1.0},
            }

        task = {
            "instance_id": "test/repo__1",
            "problem_statement": "fix the bug",
            "repo_dir": str(tmp_git_repo),
        }
        result = run_task(
            task,
            seed=42,
            model="test-model",
            timeout=60,
            results_dir=results_dir,
            patches_dir=patches_dir,
            plankton_root=tmp_git_repo,
            solve_fn=mock_solve,
            reset_fn=MagicMock(),
            inject_fn=MagicMock(),
            remove_fn=MagicMock(),
        )

        # Verify structure
        assert result["task_id"] == "test/repo__1"
        assert set(result["conditions"].keys()) == {"baseline", "plankton"}

        # Verify JSONL file
        jsonl_path = results_dir / "results.jsonl"
        assert jsonl_path.exists()
        lines = jsonl_path.read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == 2
        for line in lines:
            record = json.loads(line)
            assert "task_id" in record
            assert "condition" in record
            assert "patch" in record
            assert record["passed"] is None

        # Verify patch files
        patches = list(patches_dir.glob("*.patch"))
        assert len(patches) == 2
