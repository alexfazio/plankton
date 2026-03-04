"""Integration tests for task field validation at boundaries."""

from __future__ import annotations

import pytest


class TestPrepareTasksValidation:
    """Tasks missing checkout-required fields should fail early in prepare_tasks."""

    def test_missing_repo_field_raises_valueerror(self, tmp_path):
        """Raise ValueError when 'repo' field is missing from task."""
        from benchmark.swebench.tasks import prepare_tasks

        tasks = [{"instance_id": "t1", "problem_statement": "fix it", "base_commit": "abc"}]
        with pytest.raises(ValueError, match="repo"):
            prepare_tasks(tasks, tmp_path)

    def test_missing_base_commit_raises_valueerror(self, tmp_path):
        """Raise ValueError when 'base_commit' field is missing from task."""
        from benchmark.swebench.tasks import prepare_tasks

        tasks = [{"instance_id": "t2", "problem_statement": "fix it", "repo": "foo/bar"}]
        with pytest.raises(ValueError, match="base_commit"):
            prepare_tasks(tasks, tmp_path)

    def test_custom_checkout_fn_skips_validation(self, tmp_path):
        """When checkout_fn is provided, prepare_tasks delegates without field checks."""
        from benchmark.swebench.tasks import prepare_tasks

        tasks = [{"instance_id": "t3", "problem_statement": "fix it"}]
        called = []

        def tracking_fn(t, d):
            called.append(t["instance_id"])
            return {**t, "repo_dir": str(d)}

        result = prepare_tasks(tasks, tmp_path, checkout_fn=tracking_fn)
        assert result[0]["repo_dir"] == str(tmp_path)
        assert called == ["t3"]

    def test_empty_tasks_list_returns_empty(self, tmp_path):
        """prepare_tasks([]) with no checkout_fn should return [] without error."""
        from benchmark.swebench.tasks import prepare_tasks

        result = prepare_tasks([], tmp_path)
        assert result == []
