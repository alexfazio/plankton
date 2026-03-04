"""Shared fixtures for integration tests."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def tmp_git_repo(tmp_path: Path) -> Path:
    """Real initialized git repo with one committed file."""
    subprocess.run(["git", "init"], cwd=tmp_path, capture_output=True, check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=tmp_path, capture_output=True, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=tmp_path, capture_output=True, check=True)
    (tmp_path / "stub.py").write_text("def foo(): pass\n")
    subprocess.run(["git", "add", "."], cwd=tmp_path, capture_output=True, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=tmp_path, capture_output=True, check=True)
    return tmp_path


@pytest.fixture
def fake_task(tmp_git_repo):
    """Factory for fake task dicts with all required fields."""

    def _make(instance_id="test__repo__1", **overrides):
        base = {
            "instance_id": instance_id,
            "problem_statement": "Fix the bug",
            "repo": "test/repo",
            "base_commit": "abc123",
            "repo_dir": str(tmp_git_repo),
        }
        base.update(overrides)
        return base

    return _make


@pytest.fixture
def write_tasks_jsonl(tmp_path):
    """Write tasks to a JSONL file and return the path."""

    def _write(tasks, filename="tasks.jsonl"):
        p = tmp_path / filename
        with p.open("w", encoding="utf-8") as f:
            for t in tasks:
                f.write(json.dumps(t) + "\n")
        return p

    return _write


@pytest.fixture
def mock_solve_fn():
    """Factory for mock solve functions that return valid results."""

    def _make(patch="diff --git a/stub.py b/stub.py\n"):
        calls = []

        def solve(task, *, condition, model, timeout, **kw):
            calls.append({"task": task, "condition": condition, "model": model, "timeout": timeout})
            return {
                "patch": patch,
                "condition": condition,
                "passed": None,
                "metadata": {"elapsed_s": 1.0, "stderr": "hook: linter ran" if condition == "plankton" else ""},
            }

        solve.calls = calls
        return solve

    return _make
