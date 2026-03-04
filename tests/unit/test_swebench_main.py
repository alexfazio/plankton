"""Tests for benchmark.swebench.__main__ CLI entry point."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ── TestBuildParser ───────────────────────────────────────────────────


class TestBuildParser:
    """Test argument parsing for gate and run subcommands."""

    def test_gate_subcommand_parses(self) -> None:
        """Verify gate subcommand parses repos-dir argument."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["gate", "--repos-dir", "/tmp"])
        assert args.subcommand == "gate"
        assert args.repos_dir == Path("/tmp")

    def test_run_subcommand_parses(self) -> None:
        """Verify run subcommand parses repos-dir argument."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["run", "--repos-dir", "/tmp"])
        assert args.subcommand == "run"
        assert args.repos_dir == Path("/tmp")

    def test_gate_defaults_seed_42(self) -> None:
        """Verify gate subcommand defaults seed to 42."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["gate", "--repos-dir", "/tmp"])
        assert args.seed == 42

    def test_run_resume_flag(self) -> None:
        """Verify run subcommand accepts --resume flag."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["run", "--repos-dir", "/tmp", "--resume"])
        assert args.resume is True


# ── TestLoadAndPrepareTasks ───────────────────────────────────────────


class TestLoadAndPrepareTasks:
    """Test _load_and_prepare_tasks dispatches correctly."""

    def _make_args(self, **overrides):
        """Create a minimal args namespace."""
        import argparse

        defaults = {
            "tasks_jsonl": None,
            "tasks_hf": "princeton-nlp/SWE-bench_Lite",
            "instance_ids": None,
            "difficulties": None,
            "repos_dir": Path("/tmp/repos"),
            "no_checkout": False,
        }
        defaults.update(overrides)
        return argparse.Namespace(**defaults)

    @patch("benchmark.swebench.tasks.prepare_tasks", return_value=[{"id": "prepared"}])
    @patch("benchmark.swebench.tasks.select_tasks", return_value=[{"id": "selected"}])
    @patch("benchmark.swebench.tasks.load_tasks_from_jsonl", return_value=[{"id": "from_jsonl"}])
    def test_loads_from_jsonl_when_set(self, mock_jsonl, mock_select, mock_prepare) -> None:
        """Load tasks from JSONL when tasks_jsonl is set."""
        from benchmark.swebench.__main__ import _load_and_prepare_tasks

        args = self._make_args(tasks_jsonl=Path("/tmp/tasks.jsonl"))
        _load_and_prepare_tasks(args)
        mock_jsonl.assert_called_once_with(Path("/tmp/tasks.jsonl"))

    @patch("benchmark.swebench.tasks.prepare_tasks", return_value=[{"id": "prepared"}])
    @patch("benchmark.swebench.tasks.select_tasks", return_value=[{"id": "selected"}])
    @patch("benchmark.swebench.tasks.load_tasks_from_hf", return_value=[{"id": "from_hf"}])
    def test_loads_from_hf_when_no_jsonl(self, mock_hf, mock_select, mock_prepare) -> None:
        """Fall back to HuggingFace when no JSONL path is provided."""
        from benchmark.swebench.__main__ import _load_and_prepare_tasks

        args = self._make_args()
        _load_and_prepare_tasks(args)
        mock_hf.assert_called_once_with("princeton-nlp/SWE-bench_Lite")

    @patch("benchmark.swebench.tasks.select_tasks", return_value=[{"id": "selected"}])
    @patch("benchmark.swebench.tasks.load_tasks_from_hf", return_value=[{"id": "from_hf"}])
    def test_no_checkout_skips_prepare(self, mock_hf, mock_select) -> None:
        """Skip prepare_tasks when no_checkout is True."""
        from benchmark.swebench.__main__ import _load_and_prepare_tasks

        with patch("benchmark.swebench.tasks.prepare_tasks") as mock_prepare:
            args = self._make_args(no_checkout=True)
            _load_and_prepare_tasks(args)
            mock_prepare.assert_not_called()

    @patch("benchmark.swebench.tasks.prepare_tasks", return_value=[{"id": "prepared"}])
    @patch("benchmark.swebench.tasks.select_tasks", return_value=[{"id": "selected"}])
    @patch("benchmark.swebench.tasks.load_tasks_from_hf", return_value=[{"id": "from_hf"}])
    def test_select_called_with_instance_ids(self, mock_hf, mock_select, mock_prepare) -> None:
        """Pass instance_ids through to select_tasks."""
        from benchmark.swebench.__main__ import _load_and_prepare_tasks

        args = self._make_args(instance_ids=["id1"])
        _load_and_prepare_tasks(args)
        mock_select.assert_called_once_with(
            [{"id": "from_hf"}],
            instance_ids=["id1"],
            difficulties=None,
        )


# ── TestRunGateCmd ────────────────────────────────────────────────────


class TestRunGateCmd:
    """Test _run_gate_cmd exit codes."""

    @patch("benchmark.swebench.__main__._load_and_prepare_tasks", return_value=[{"id": "t1"}])
    @patch("benchmark.swebench.gate.format_gate_report", return_value="Gate: PASS")
    @patch("benchmark.swebench.gate.run_gate")
    def test_exits_0_on_pass(self, mock_run_gate, mock_format, mock_load) -> None:
        """Exit with code 0 when gate passes."""
        import argparse

        from benchmark.swebench.__main__ import _run_gate_cmd
        from benchmark.swebench.gate import GateResult

        mock_run_gate.return_value = GateResult(
            passed=True,
            criteria=[],
            tasks_run=1,
            wall_time_s=10.0,
            results_dir=Path("/tmp/r"),
        )
        args = argparse.Namespace(
            seed=42,
            model="test",
            timeout=1800,
            results_dir=Path("/tmp/r"),
            repos_dir=Path("/tmp"),
            dry_run=False,
            skip_eval=False,
        )
        with pytest.raises(SystemExit) as exc_info:
            _run_gate_cmd(args)
        assert exc_info.value.code == 0

    @patch("benchmark.swebench.__main__._load_and_prepare_tasks", return_value=[{"id": "t1"}])
    @patch("benchmark.swebench.gate.format_gate_report", return_value="Gate: FAIL")
    @patch("benchmark.swebench.gate.run_gate")
    def test_exits_1_on_fail(self, mock_run_gate, mock_format, mock_load) -> None:
        """Exit with code 1 when gate fails."""
        import argparse

        from benchmark.swebench.__main__ import _run_gate_cmd
        from benchmark.swebench.gate import GateResult

        mock_run_gate.return_value = GateResult(
            passed=False,
            criteria=[],
            tasks_run=1,
            wall_time_s=10.0,
            results_dir=Path("/tmp/r"),
        )
        args = argparse.Namespace(
            seed=42,
            model="test",
            timeout=1800,
            results_dir=Path("/tmp/r"),
            repos_dir=Path("/tmp"),
            dry_run=False,
            skip_eval=False,
        )
        with pytest.raises(SystemExit) as exc_info:
            _run_gate_cmd(args)
        assert exc_info.value.code == 1


# ── TestRunAllCmd ─────────────────────────────────────────────────────


class TestRunAllCmd:
    """Test _run_all_cmd exit codes and resume behavior."""

    @patch("benchmark.swebench.__main__._load_and_prepare_tasks", return_value=[{"id": "t1"}])
    @patch("benchmark.swebench.runner.run_all")
    def test_exits_0_on_success(self, mock_run_all, mock_load) -> None:
        """Exit with code 0 when all tasks complete successfully."""
        import argparse

        from benchmark.swebench.__main__ import _run_all_cmd

        mock_run_all.return_value = {"aborted": False, "tasks_completed": 1, "tasks_skipped": 0}
        args = argparse.Namespace(
            seed=42,
            model="test",
            timeout=1800,
            results_dir=Path("/tmp/r"),
            repos_dir=Path("/tmp"),
            resume=False,
            dry_run=False,
        )
        with pytest.raises(SystemExit) as exc_info:
            _run_all_cmd(args)
        assert exc_info.value.code == 0

    @patch("benchmark.swebench.__main__._load_and_prepare_tasks", return_value=[{"id": "t1"}])
    @patch("benchmark.swebench.runner.run_all")
    def test_exits_1_on_abort(self, mock_run_all, mock_load) -> None:
        """Exit with code 1 when run is aborted."""
        import argparse

        from benchmark.swebench.__main__ import _run_all_cmd

        mock_run_all.return_value = {
            "aborted": True,
            "abort_reason": "infra",
            "tasks_completed": 0,
            "tasks_skipped": 0,
        }
        args = argparse.Namespace(
            seed=42,
            model="test",
            timeout=1800,
            results_dir=Path("/tmp/r"),
            repos_dir=Path("/tmp"),
            resume=False,
            dry_run=False,
        )
        with pytest.raises(SystemExit) as exc_info:
            _run_all_cmd(args)
        assert exc_info.value.code == 1

    @patch("benchmark.swebench.__main__._load_and_prepare_tasks", return_value=[{"id": "t1"}])
    @patch("benchmark.swebench.runner.load_completed_ids", return_value={"t0"})
    @patch("benchmark.swebench.runner.run_all")
    def test_resume_loads_completed_ids(self, mock_run_all, mock_load_ids, mock_load) -> None:
        """Load completed IDs from results dir when resume is True."""
        import argparse

        from benchmark.swebench.__main__ import _run_all_cmd

        mock_run_all.return_value = {"aborted": False, "tasks_completed": 1, "tasks_skipped": 0}
        args = argparse.Namespace(
            seed=42,
            model="test",
            timeout=1800,
            results_dir=Path("/tmp/r"),
            repos_dir=Path("/tmp"),
            resume=True,
            dry_run=False,
        )
        with pytest.raises(SystemExit):
            _run_all_cmd(args)
        mock_load_ids.assert_called_once_with(Path("/tmp/r"))
        # completed_ids should be passed to run_all
        _, kwargs = mock_run_all.call_args
        assert kwargs["completed_ids"] == {"t0"}


# ── TestPrereqsSubcommand ────────────────────────────────────────────


class TestPrereqsSubcommand:
    """Test prereqs subcommand parsing and dispatch."""

    def test_should_parse_prereqs_subcommand(self) -> None:
        """Verify parser accepts `prereqs` without error."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["prereqs"])
        assert args.subcommand == "prereqs"

    def test_should_parse_prereqs_with_full_flag(self) -> None:
        """Verify args.full is True when --full is passed."""
        from benchmark.swebench.__main__ import _build_parser

        args = _build_parser().parse_args(["prereqs", "--full"])
        assert args.full is True

    @patch("benchmark.swebench.prereqs.format_report", return_value="report")
    @patch("benchmark.swebench.prereqs.run_all_checks")
    def test_should_exit_0_when_all_prereqs_pass(self, mock_run, mock_fmt) -> None:
        """Exit 0 when all prereqs pass."""
        import argparse

        from benchmark.swebench.__main__ import _run_prereqs_cmd
        from benchmark.swebench.prereqs import PrereqResult

        mock_run.return_value = [PrereqResult(name=f"c{i}", passed=True, detail="ok", step=i) for i in range(1, 12)]
        args = argparse.Namespace(full=False)
        with pytest.raises(SystemExit) as exc_info:
            _run_prereqs_cmd(args)
        assert exc_info.value.code == 0

    @patch("benchmark.swebench.prereqs.format_report", return_value="report")
    @patch("benchmark.swebench.prereqs.run_all_checks")
    def test_should_exit_1_when_any_prereq_fails(self, mock_run, mock_fmt) -> None:
        """Exit 1 when any prereq fails."""
        import argparse

        from benchmark.swebench.__main__ import _run_prereqs_cmd
        from benchmark.swebench.prereqs import PrereqResult

        mock_run.return_value = [
            PrereqResult(name="c1", passed=True, detail="ok", step=1),
            PrereqResult(name="c2", passed=False, detail="bad", step=2),
        ]
        args = argparse.Namespace(full=False)
        with pytest.raises(SystemExit) as exc_info:
            _run_prereqs_cmd(args)
        assert exc_info.value.code == 1
