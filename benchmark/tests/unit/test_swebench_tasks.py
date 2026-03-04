"""Tests for benchmark.swebench.tasks module."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# ── TestLoadTasksFromJsonl ────────────────────────────────────────────


class TestLoadTasksFromJsonl:
    """Test load_tasks_from_jsonl JSONL loading."""

    def test_load_returns_list_of_dicts(self, tmp_path: Path) -> None:
        """Write 3-line JSONL, assert returns 3 dicts."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        lines = [json.dumps({"instance_id": f"id_{i}", "problem_statement": f"fix {i}"}) for i in range(3)]
        p.write_text("\n".join(lines) + "\n")
        result = load_tasks_from_jsonl(p)
        assert len(result) == 3
        assert all(isinstance(r, dict) for r in result)

    def test_load_missing_instance_id_raises(self, tmp_path: Path) -> None:
        """Line missing instance_id -> ValueError."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        p.write_text(json.dumps({"problem_statement": "fix"}) + "\n")
        with pytest.raises(ValueError, match="instance_id"):
            load_tasks_from_jsonl(p)

    def test_load_missing_problem_statement_raises(self, tmp_path: Path) -> None:
        """Line missing problem_statement -> ValueError."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        p.write_text(json.dumps({"instance_id": "id_0"}) + "\n")
        with pytest.raises(ValueError, match="problem_statement"):
            load_tasks_from_jsonl(p)

    def test_load_empty_file_returns_empty_list(self, tmp_path: Path) -> None:
        """Empty file returns empty list."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        p.write_text("")
        assert load_tasks_from_jsonl(p) == []

    def test_load_malformed_json_raises_with_line_number(self, tmp_path: Path) -> None:
        """Malformed JSON raises ValueError with line number."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        good = json.dumps({"instance_id": "id_0", "problem_statement": "fix"})
        p.write_text(f"{good}\n{{bad json}}\n")
        with pytest.raises(ValueError, match="[Ll]ine 2"):
            load_tasks_from_jsonl(p)

    def test_load_skips_blank_lines(self, tmp_path: Path) -> None:
        """JSONL with blank lines returns only valid entries."""
        from benchmark.swebench.tasks import load_tasks_from_jsonl

        p = tmp_path / "tasks.jsonl"
        line = json.dumps({"instance_id": "id_0", "problem_statement": "fix"})
        p.write_text(f"\n{line}\n\n{line}\n\n")
        result = load_tasks_from_jsonl(p)
        assert len(result) == 2


# ── TestLoadTasksFromHf ───────────────────────────────────────────────


class TestLoadTasksFromHf:
    """Test load_tasks_from_hf HuggingFace loading."""

    def test_load_uses_injected_fn(self) -> None:
        """Pass mock hf_load_fn returning list of dicts, assert result matches."""
        from benchmark.swebench.tasks import load_tasks_from_hf

        data = [
            {"instance_id": "id_0", "problem_statement": "fix"},
            {"instance_id": "id_1", "problem_statement": "bug"},
        ]
        mock_fn = MagicMock(return_value=data)
        result = load_tasks_from_hf("ds", "test", hf_load_fn=mock_fn)
        mock_fn.assert_called_once_with("ds", split="test")
        assert result == data

    def test_load_raises_import_error_without_datasets(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """No datasets module and no mock fn -> ImportError."""
        from benchmark.swebench.tasks import load_tasks_from_hf

        monkeypatch.setitem(__import__("sys").modules, "datasets", None)
        with pytest.raises(ImportError, match="datasets"):
            load_tasks_from_hf("ds", "test")

    def test_load_converts_rows_to_dicts(self) -> None:
        """Mock returns objects with dict-like interface, converted to plain dicts."""
        from benchmark.swebench.tasks import load_tasks_from_hf

        class FakeRow:
            def __init__(self, d: dict) -> None:
                self._d = d

            def items(self):
                return self._d.items()

        rows = [FakeRow({"instance_id": "id_0", "problem_statement": "fix"})]
        mock_fn = MagicMock(return_value=rows)
        result = load_tasks_from_hf("ds", "test", hf_load_fn=mock_fn)
        assert result == [{"instance_id": "id_0", "problem_statement": "fix"}]


# ── TestSelectTasks ───────────────────────────────────────────────────


class TestSelectTasks:
    """Test select_tasks filtering."""

    def _make_tasks(self, n: int = 5) -> list[dict]:
        difficulties = ["easy", "medium", "hard", "easy", "medium"]
        return [
            {"instance_id": f"id_{i}", "problem_statement": f"fix {i}", "difficulty": difficulties[i % 5]}
            for i in range(n)
        ]

    def test_select_by_instance_ids(self) -> None:
        """Select 2 by ID, correct 2 returned in order."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        result = select_tasks(tasks, instance_ids=["id_3", "id_1"])
        assert [t["instance_id"] for t in result] == ["id_3", "id_1"]

    def test_select_missing_id_raises(self) -> None:
        """Request missing ID -> KeyError."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        with pytest.raises(KeyError, match="id_99"):
            select_tasks(tasks, instance_ids=["id_99"])

    def test_select_by_difficulty(self) -> None:
        """Filter to 'easy', only easy returned."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        result = select_tasks(tasks, difficulties=["easy"])
        assert all(t["difficulty"] == "easy" for t in result)
        assert len(result) == 2

    def test_select_n(self) -> None:
        """n=2 from 5, get first 2."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        result = select_tasks(tasks, n=2)
        assert len(result) == 2
        assert result == tasks[:2]

    def test_select_duplicate_ids_deduplicates(self) -> None:
        """Duplicate instance_ids returns each task only once."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        result = select_tasks(tasks, instance_ids=["id_0", "id_0"])
        assert len(result) == 1
        assert result[0]["instance_id"] == "id_0"

    def test_select_no_filters_returns_all(self) -> None:
        """No filters returns all."""
        from benchmark.swebench.tasks import select_tasks

        tasks = self._make_tasks()
        assert select_tasks(tasks) == tasks


# ── TestCheckoutRepo ──────────────────────────────────────────────────


class TestCheckoutRepo:
    """Test checkout_repo clone + checkout logic."""

    def _make_task(self) -> dict:
        return {
            "instance_id": "id_0",
            "problem_statement": "fix",
            "repo": "owner/repo",
            "base_commit": "abc123",
        }

    def test_sets_repo_dir(self, tmp_path: Path) -> None:
        """Mock clone_fn/checkout_fn, assert returned task has repo_dir."""
        from benchmark.swebench.tasks import checkout_repo

        task = self._make_task()
        mock_clone = MagicMock()
        mock_checkout = MagicMock()
        result = checkout_repo(task, tmp_path, clone_fn=mock_clone, checkout_fn=mock_checkout)
        assert "repo_dir" in result
        expected_dir = tmp_path / "owner__repo"
        assert result["repo_dir"] == str(expected_dir)
        mock_clone.assert_called_once()
        mock_checkout.assert_called_once()

    def test_skips_clone_if_dir_exists(self, tmp_path: Path) -> None:
        """Create dir in tmp_path, assert clone_fn not called."""
        from benchmark.swebench.tasks import checkout_repo

        task = self._make_task()
        (tmp_path / "owner__repo").mkdir()
        mock_clone = MagicMock()
        mock_checkout = MagicMock()
        result = checkout_repo(task, tmp_path, clone_fn=mock_clone, checkout_fn=mock_checkout)
        mock_clone.assert_not_called()
        mock_checkout.assert_called_once()
        assert result["repo_dir"] == str(tmp_path / "owner__repo")

    def test_missing_repo_raises(self, tmp_path: Path) -> None:
        """No 'repo' field -> ValueError."""
        from benchmark.swebench.tasks import checkout_repo

        task = {"instance_id": "id_0", "problem_statement": "fix", "base_commit": "abc"}
        with pytest.raises(ValueError, match="repo"):
            checkout_repo(task, tmp_path)

    def test_missing_base_commit_raises(self, tmp_path: Path) -> None:
        """No 'base_commit' -> ValueError."""
        from benchmark.swebench.tasks import checkout_repo

        task = {"instance_id": "id_0", "problem_statement": "fix", "repo": "o/r"}
        with pytest.raises(ValueError, match="base_commit"):
            checkout_repo(task, tmp_path)


# ── TestPrepareTasks ──────────────────────────────────────────────────


class TestPrepareTasks:
    """Test prepare_tasks mapping."""

    def test_maps_checkout_over_all(self, tmp_path: Path) -> None:
        """3 tasks with mock, all get repo_dir."""
        from benchmark.swebench.tasks import prepare_tasks

        tasks = [
            {"instance_id": f"id_{i}", "problem_statement": "fix", "repo": f"o/r{i}", "base_commit": "abc"}
            for i in range(3)
        ]
        mock_checkout = MagicMock(side_effect=lambda t, rd, **kw: {**t, "repo_dir": str(rd / "mock")})
        # We use checkout_fn to inject the mock into checkout_repo
        # But prepare_tasks takes checkout_fn differently - let's just mock at the right level
        result = prepare_tasks(tasks, tmp_path, checkout_fn=mock_checkout)
        assert len(result) == 3
        assert all("repo_dir" in t for t in result)

    def test_empty_list_returns_empty(self, tmp_path: Path) -> None:
        """Empty list returns empty."""
        from benchmark.swebench.tasks import prepare_tasks

        assert prepare_tasks([], tmp_path) == []
