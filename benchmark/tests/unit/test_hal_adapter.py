"""Tests for benchmark.swebench.hal_adapter module."""

from __future__ import annotations

import json

# --- Step 1: run() basic dispatch ---


class TestRunBasicDispatch:
    """Test HAL-compatible run() function."""

    def test_run_single_task_returns_patch(self, tmp_git_repo, monkeypatch):
        """run() with one task returns {instance_id: patch_string}."""
        from benchmark.swebench import hal_adapter

        def mock_solve(input_data, *, condition, model, timeout, **kw):
            return {"patch": "diff --git a/file.py", "condition": condition, "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        result = hal_adapter.run(
            {"django__django-1234": {"problem_statement": "fix bug", "repo_dir": str(tmp_git_repo)}},
            condition="plankton",
        )
        assert result == {"django__django-1234": "diff --git a/file.py"}

    def test_run_multiple_tasks(self, tmp_git_repo, monkeypatch):
        """run() with multiple tasks returns patches for all in insertion order."""
        from benchmark.swebench import hal_adapter

        call_ids = []

        def mock_solve(input_data, *, condition, model, timeout, **kw):
            call_ids.append(input_data["instance_id"])
            return {
                "patch": f"patch-{input_data['instance_id']}",
                "condition": condition,
                "passed": None,
                "metadata": {},
            }

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        tasks = {
            "task-1": {"problem_statement": "a", "repo_dir": str(tmp_git_repo)},
            "task-2": {"problem_statement": "b", "repo_dir": str(tmp_git_repo)},
        }
        result = hal_adapter.run(tasks, condition="baseline")
        assert len(result) == 2
        assert result["task-1"] == "patch-task-1"
        assert result["task-2"] == "patch-task-2"
        # Step 6 fix: verify insertion order, not just set membership
        assert call_ids == ["task-1", "task-2"]

    def test_run_passes_condition_kwarg(self, tmp_git_repo, monkeypatch):
        """run() forwards condition kwarg to solve()."""
        from benchmark.swebench import hal_adapter

        captured_conditions = []

        def mock_solve(input_data, *, condition, model, timeout, **kw):
            captured_conditions.append(condition)
            return {"patch": "", "condition": condition, "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
        )
        assert captured_conditions == ["baseline"]

    def test_run_defaults_to_plankton(self, tmp_git_repo, monkeypatch):
        """run() defaults to plankton condition when not specified."""
        from benchmark.swebench import hal_adapter

        captured = []

        def mock_solve(input_data, *, condition, model, timeout, **kw):
            captured.append(condition)
            return {"patch": "", "condition": condition, "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        hal_adapter.run({"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}})
        assert captured == ["plankton"]


# --- Step 2: Hook injection ---


class TestRunHookInjection:
    """Test hook injection/removal for plankton condition."""

    def test_plankton_injects_hooks(self, tmp_git_repo, monkeypatch):
        """Plankton condition calls inject_hooks before solve."""
        from benchmark.swebench import hal_adapter

        calls = []

        def mock_inject(task_dir, *, plankton_root):
            calls.append(("inject", str(task_dir)))

        def mock_remove(task_dir):
            calls.append(("remove", str(task_dir)))

        def mock_solve(input_data, **kw):
            calls.append(("solve", input_data["instance_id"]))
            return {"patch": "", "condition": "plankton", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "inject_hooks", mock_inject)
        monkeypatch.setattr(hal_adapter, "remove_hooks", mock_remove)

        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="plankton",
        )
        assert calls == [("inject", str(tmp_git_repo)), ("solve", "t1"), ("remove", str(tmp_git_repo))]

    def test_baseline_no_hooks(self, tmp_git_repo, monkeypatch):
        """Baseline condition does NOT inject hooks."""
        from benchmark.swebench import hal_adapter

        inject_called = False

        def mock_inject(task_dir, *, plankton_root):
            nonlocal inject_called
            inject_called = True

        def mock_solve(input_data, **kw):
            return {"patch": "", "condition": "baseline", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "inject_hooks", mock_inject)

        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
        )
        assert not inject_called

    def test_hooks_cleaned_on_solve_error(self, tmp_git_repo, monkeypatch):
        """Hooks removed even if solve() raises."""
        from benchmark.swebench import hal_adapter

        removed = []

        def mock_inject(task_dir, *, plankton_root):
            pass

        def mock_remove(task_dir):
            removed.append(str(task_dir))

        def mock_solve(input_data, **kw):
            raise RuntimeError("boom")

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "inject_hooks", mock_inject)
        monkeypatch.setattr(hal_adapter, "remove_hooks", mock_remove)

        result = hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="plankton",
        )
        assert removed == [str(tmp_git_repo)]
        assert result["t1"] == ""


# --- Step 3: repo_dir resolution ---


class TestRepoDir:
    """Test repo_dir resolution from task data."""

    def test_uses_repo_dir_from_task(self, tmp_git_repo, monkeypatch):
        """Uses repo_dir from task data when present."""
        from benchmark.swebench import hal_adapter

        captured_dirs = []

        def mock_solve(input_data, **kw):
            captured_dirs.append(input_data.get("repo_dir"))
            return {"patch": "", "condition": "baseline", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": "/custom/path"}},
            condition="baseline",
        )
        assert captured_dirs == ["/custom/path"]

    def test_falls_back_to_cwd(self, tmp_git_repo, monkeypatch):
        """Falls back to cwd if repo_dir not in task data."""
        from benchmark.swebench import hal_adapter

        captured_dirs = []

        def mock_solve(input_data, **kw):
            captured_dirs.append(input_data.get("repo_dir"))
            return {"patch": "", "condition": "baseline", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.chdir(tmp_git_repo)

        hal_adapter.run(
            {"t1": {"problem_statement": "x"}},
            condition="baseline",
        )
        assert captured_dirs[0] == str(tmp_git_repo)


# --- Step 4: Error handling ---


class TestErrorHandling:
    """Test partial results on errors."""

    def test_timeout_does_not_block_other_tasks(self, tmp_git_repo, monkeypatch):
        """If one task errors, other tasks still get processed."""
        from benchmark.swebench import hal_adapter

        call_count = 0

        def mock_solve(input_data, **kw):
            nonlocal call_count
            call_count += 1
            if input_data["instance_id"] == "bad":
                raise RuntimeError("exploded")
            return {"patch": "good-patch", "condition": "baseline", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        result = hal_adapter.run(
            {
                "bad": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)},
                "good": {"problem_statement": "y", "repo_dir": str(tmp_git_repo)},
            },
            condition="baseline",
        )
        assert call_count == 2
        assert result["bad"] == ""
        assert result["good"] == "good-patch"

    def test_failed_tasks_return_empty_patch(self, tmp_git_repo, monkeypatch):
        """Failed tasks return empty string, not missing key."""
        from benchmark.swebench import hal_adapter

        def mock_solve(input_data, **kw):
            raise RuntimeError("boom")

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        result = hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
        )
        assert "t1" in result
        assert result["t1"] == ""


# --- Step 5: Metadata side-channel ---


class TestMetadataLogging:
    """Test optional metadata logging to results_dir."""

    def test_writes_metadata_when_results_dir_provided(self, tmp_git_repo, tmp_path, monkeypatch):
        """Writes per-task metadata JSONL when results_dir kwarg given."""
        from benchmark.swebench import hal_adapter

        def mock_solve(input_data, **kw):
            return {"patch": "p", "condition": "plankton", "passed": None, "metadata": {"elapsed_s": 12.5}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "inject_hooks", lambda *a, **kw: None)
        monkeypatch.setattr(hal_adapter, "remove_hooks", lambda *a, **kw: None)

        results_dir = tmp_path / "results"
        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="plankton",
            results_dir=str(results_dir),
        )
        meta_file = results_dir / "hal_metadata.jsonl"
        assert meta_file.exists()
        lines = meta_file.read_text().strip().split("\n")
        record = json.loads(lines[0])
        assert record["instance_id"] == "t1"
        assert record["condition"] == "plankton"
        assert "elapsed_s" in record

    def test_no_metadata_when_results_dir_absent(self, tmp_git_repo, monkeypatch):
        """No metadata file created when results_dir not provided."""
        from benchmark.swebench import hal_adapter

        def mock_solve(input_data, **kw):
            return {"patch": "", "condition": "baseline", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        # Should not raise
        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
        )


# --- Step 6: Export ---


class TestExport:
    """Test module exports."""

    def test_run_importable_from_package(self):
        """Run is importable from benchmark.swebench."""
        from benchmark.swebench import run  # noqa: F401

    def test_hal_adapter_run_at_expected_path(self):
        """run() is callable at benchmark.swebench.hal_adapter.run (HAL CLI path)."""
        import importlib

        mod = importlib.import_module("benchmark.swebench.hal_adapter")
        assert callable(mod.run)


# --- Edge case: invalid condition (Step 1 remediation) ---


class TestConditionValidation:
    """Test early validation of condition kwarg."""

    def test_invalid_condition_raises_valueerror(self, tmp_git_repo):
        """run() raises ValueError immediately for invalid condition."""
        import pytest
        from benchmark.swebench import hal_adapter

        with pytest.raises(ValueError, match="condition"):
            hal_adapter.run(
                {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
                condition="typo",
            )


# --- Edge case: missing problem_statement (Step 2 remediation) ---


class TestProblemStatementValidation:
    """Test validation of required task fields."""

    def test_missing_problem_statement_raises(self, tmp_git_repo):
        """run() raises ValueError when problem_statement is absent."""
        import pytest
        from benchmark.swebench import hal_adapter

        with pytest.raises(ValueError, match="problem_statement"):
            hal_adapter.run(
                {"t1": {"repo_dir": str(tmp_git_repo)}},
                condition="baseline",
            )


# --- Edge case: inject_hooks failure propagates (Step 3 remediation) ---


class TestInjectHooksFailFast:
    """Test that inject_hooks failures are not silently swallowed."""

    def test_inject_hooks_error_propagates(self, tmp_git_repo, monkeypatch):
        """inject_hooks failure raises, not silently caught."""
        import pytest
        from benchmark.swebench import hal_adapter

        def bad_inject(task_dir, *, plankton_root):
            raise FileNotFoundError("no hooks dir")

        monkeypatch.setattr(hal_adapter, "inject_hooks", bad_inject)

        with pytest.raises(FileNotFoundError, match="no hooks dir"):
            hal_adapter.run(
                {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
                condition="plankton",
            )


# --- Edge case: remove_hooks failure is safe (Step 4 remediation) ---


class TestRemoveHooksSafe:
    """Test that remove_hooks failure doesn't abort the run."""

    def test_remove_hooks_error_does_not_abort(self, tmp_git_repo, monkeypatch):
        """If remove_hooks raises, remaining tasks still processed."""
        from benchmark.swebench import hal_adapter

        call_count = 0

        def mock_inject(task_dir, *, plankton_root):
            pass

        def bad_remove(task_dir):
            raise OSError("cleanup failed")

        def mock_solve(input_data, **kw):
            nonlocal call_count
            call_count += 1
            return {"patch": "p", "condition": "plankton", "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "inject_hooks", mock_inject)
        monkeypatch.setattr(hal_adapter, "remove_hooks", bad_remove)

        result = hal_adapter.run(
            {
                "t1": {"problem_statement": "a", "repo_dir": str(tmp_git_repo)},
                "t2": {"problem_statement": "b", "repo_dir": str(tmp_git_repo)},
            },
            condition="plankton",
        )
        assert call_count == 2
        assert result["t1"] == "p"
        assert result["t2"] == "p"


# --- Edge case: _write_metadata failure is safe (Step 5 remediation) ---


class TestMetadataWriteSafe:
    """Test that metadata write failure doesn't abort the run."""

    def test_metadata_write_error_does_not_abort(self, tmp_git_repo, monkeypatch):
        """If metadata write fails, remaining tasks still processed."""
        from benchmark.swebench import hal_adapter

        call_count = 0

        def mock_solve(input_data, **kw):
            nonlocal call_count
            call_count += 1
            return {"patch": "p", "condition": "baseline", "passed": None, "metadata": {}}

        def bad_write_metadata(*args, **kwargs):
            raise OSError("disk full")

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)
        monkeypatch.setattr(hal_adapter, "_write_metadata", bad_write_metadata)

        result = hal_adapter.run(
            {
                "t1": {"problem_statement": "a", "repo_dir": str(tmp_git_repo)},
                "t2": {"problem_statement": "b", "repo_dir": str(tmp_git_repo)},
            },
            condition="baseline",
            results_dir="/fake/path",
        )
        assert call_count == 2
        assert result["t1"] == "p"
        assert result["t2"] == "p"


# --- Metadata passthrough (Deviation 2 remediation) ---


class TestMetadataPassthrough:
    """Test that arbitrary metadata keys pass through to JSONL."""

    def test_custom_metadata_keys_in_jsonl(self, tmp_git_repo, tmp_path, monkeypatch):
        """Arbitrary metadata keys from solve() appear in JSONL output."""
        from benchmark.swebench import hal_adapter

        def mock_solve(input_data, **kw):
            return {
                "patch": "p",
                "condition": "baseline",
                "passed": None,
                "metadata": {"custom_key": 42, "nested": {"a": 1}},
            }

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        results_dir = tmp_path / "results"
        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
            results_dir=str(results_dir),
        )
        record = json.loads((results_dir / "hal_metadata.jsonl").read_text().strip())
        assert record["custom_key"] == 42
        assert record["nested"] == {"a": 1}


# --- Step 7: Final polish (metadata collision, empty input, string timeout) ---


class TestMetadataCollision:
    """Test that metadata keys cannot overwrite explicit instance_id/condition."""

    def test_metadata_instance_id_does_not_overwrite(self, tmp_path):
        """_write_metadata with metadata containing instance_id does NOT overwrite the explicit one."""
        from benchmark.swebench.hal_adapter import _write_metadata

        _write_metadata(
            str(tmp_path),
            instance_id="real-id",
            condition="baseline",
            metadata={"instance_id": "evil-id", "condition": "evil"},
        )
        record = json.loads((tmp_path / "hal_metadata.jsonl").read_text().strip())
        assert record["instance_id"] == "real-id"
        assert record["condition"] == "baseline"


class TestEmptyInput:
    """Test run() with empty input dict."""

    def test_empty_input_returns_empty(self):
        """run({}, condition='baseline') returns {}."""
        from benchmark.swebench.hal_adapter import run

        assert run({}, condition="baseline") == {}


class TestStringTimeout:
    """Test that string timeout is coerced to int."""

    def test_string_timeout_coerced_to_int(self, tmp_git_repo, monkeypatch):
        """run(input, timeout='900') passes timeout=900 (int) to solve."""
        from benchmark.swebench import hal_adapter

        captured = []

        def mock_solve(input_data, *, condition, model, timeout, **kw):
            captured.append(timeout)
            return {"patch": "", "condition": condition, "passed": None, "metadata": {}}

        monkeypatch.setattr(hal_adapter, "solve", mock_solve)

        hal_adapter.run(
            {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
            condition="baseline",
            timeout="900",
        )
        assert captured == [900]
        assert isinstance(captured[0], int)

    def test_non_numeric_timeout_raises_valueerror(self, tmp_git_repo):
        """run() with non-numeric timeout string raises ValueError."""
        import pytest
        from benchmark.swebench.hal_adapter import run

        with pytest.raises(ValueError, match="invalid literal"):
            run(
                {"t1": {"problem_statement": "x", "repo_dir": str(tmp_git_repo)}},
                condition="baseline",
                timeout="abc",
            )


class TestEmptyInputWithResultsDir:
    """Test empty input with results_dir produces no side-effects."""

    def test_empty_input_with_results_dir_no_metadata_file(self, tmp_path):
        """run({}) with results_dir returns {} and creates no metadata file."""
        from benchmark.swebench.hal_adapter import run

        out = tmp_path / "out"
        result = run({}, condition="baseline", results_dir=str(out))
        assert result == {}
        assert not (out / "hal_metadata.jsonl").exists()
