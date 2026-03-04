"""Integration tests for abort criteria within run_all."""

from __future__ import annotations

from pathlib import Path


class TestAbortWiring:
    """run_all abort criteria should fire during iteration."""

    def test_abort_on_consecutive_empty_patches(self, tmp_path):
        """run_all should abort after 10 consecutive empty-patch tasks."""
        from benchmark.swebench.runner import run_all

        tasks = [{"instance_id": f"t-{i}", "problem_statement": "fix", "repo_dir": str(tmp_path)} for i in range(15)]

        def empty_run_task(task, **kw):
            return {
                "task_id": task["instance_id"],
                "conditions": {
                    "baseline": {"patch": "", "passed": None, "metadata": {}},
                    "plankton": {"patch": "", "passed": None, "metadata": {}},
                },
            }

        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            run_task_fn=empty_run_task,
        )
        assert result["aborted"] is True
        assert result["tasks_completed"] == 10  # stops at threshold
        assert "empty" in result["abort_reason"].lower()

    def test_abort_on_infra_error_rate(self, tmp_path):
        """run_all should abort when infra error rate exceeds 20%."""
        from benchmark.swebench.runner import run_all

        tasks = [{"instance_id": f"t-{i}", "problem_statement": "fix", "repo_dir": str(tmp_path)} for i in range(5)]

        def infra_error_run_task(task, **kw):
            return {
                "task_id": task["instance_id"],
                "conditions": {
                    "baseline": {"patch": "diff", "passed": None, "metadata": {"error_type": "infra"}},
                    "plankton": {"patch": "diff", "passed": None, "metadata": {}},
                },
            }

        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            run_task_fn=infra_error_run_task,
        )
        assert result["aborted"] is True
        assert "infra" in result["abort_reason"].lower()

    def test_exception_in_run_task_counted_as_infra_error(self, tmp_path):
        """RuntimeError from run_task_fn should be caught and counted as infra error."""
        from benchmark.swebench.runner import run_all

        call_count = 0

        def exploding_run_task(task, **kw):
            nonlocal call_count
            call_count += 1
            raise RuntimeError("boom")

        tasks = [{"instance_id": f"t-{i}", "problem_statement": "fix", "repo_dir": str(tmp_path)} for i in range(5)]

        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            run_task_fn=exploding_run_task,
        )
        # Should NOT raise — exception caught internally
        # First task: 1 infra error / 1 total = 100% > 20% → abort
        assert result["aborted"] is True
        assert result["tasks_completed"] == 1
        assert "infra" in result["abort_reason"].lower()

    def test_exception_does_not_increment_consecutive_empty(self, tmp_path):
        """Exceptions should trigger infra abort, not consecutive-empty abort."""
        from benchmark.swebench.runner import run_all

        # 9 empty-patch tasks (below threshold of 10), then 1 exception
        call_idx = 0

        def mixed_run_task(task, **kw):
            nonlocal call_idx
            call_idx += 1
            if call_idx <= 9:
                return {
                    "task_id": task["instance_id"],
                    "conditions": {
                        "baseline": {"patch": "", "passed": None, "metadata": {}},
                        "plankton": {"patch": "", "passed": None, "metadata": {}},
                    },
                }
            raise RuntimeError("boom")

        tasks = [{"instance_id": f"t-{i}", "problem_statement": "fix", "repo_dir": str(tmp_path)} for i in range(15)]

        result = run_all(
            tasks,
            seed=42,
            model="m",
            timeout=60,
            results_dir=tmp_path / "results",
            patches_dir=tmp_path / "patches",
            plankton_root=tmp_path,
            run_task_fn=mixed_run_task,
        )
        # Exception on task 10 should abort via infra error (1/10 = 10%, but
        # the synthetic result has a non-empty sentinel patch "<exception>",
        # so consecutive_empty resets rather than hitting 10)
        assert result["aborted"] is False or "infra" in (result["abort_reason"] or "").lower()
        # consecutive_empty should NOT reach 10 — the exception result has a
        # non-empty sentinel patch that resets the counter
        if result["aborted"]:
            assert "empty" not in result["abort_reason"].lower()
