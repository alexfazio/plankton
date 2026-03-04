"""Integration tests for CLI-to-execution wiring."""

from __future__ import annotations

import argparse
from pathlib import Path
from unittest.mock import patch

import pytest
from benchmark.swebench.__main__ import _build_parser, _run_all_cmd, _run_gate_cmd
from benchmark.swebench.gate import CriterionResult, GateConfig, GateResult

# ---------------------------------------------------------------------------
# Step 1: CLI dispatch / argument parsing
# ---------------------------------------------------------------------------


class TestCliDispatch:
    """Tests that argparse wiring produces correct Namespace objects."""

    def test_gate_subcommand_parses_and_dispatches(self, tmp_path):
        """Parse 'gate --repos-dir /tmp --tasks-jsonl tasks.jsonl' and verify fields."""
        tasks_file = tmp_path / "tasks.jsonl"
        tasks_file.touch()
        parser = _build_parser()
        args = parser.parse_args(["gate", "--repos-dir", str(tmp_path), "--tasks-jsonl", str(tasks_file)])
        assert args.subcommand == "gate"
        assert args.repos_dir == tmp_path
        assert args.tasks_jsonl == tasks_file

    def test_run_subcommand_with_resume(self, tmp_path):
        """Parse 'run --repos-dir /tmp --resume --tasks-jsonl tasks.jsonl' and verify resume flag."""
        tasks_file = tmp_path / "tasks.jsonl"
        tasks_file.touch()
        parser = _build_parser()
        args = parser.parse_args(["run", "--repos-dir", str(tmp_path), "--resume", "--tasks-jsonl", str(tasks_file)])
        assert args.subcommand == "run"
        assert args.resume is True

    def test_missing_repos_dir_exits_2(self):
        """Omitting required --repos-dir should cause SystemExit with code 2."""
        parser = _build_parser()
        with pytest.raises(SystemExit, match="2"):
            parser.parse_args(["gate"])


# ---------------------------------------------------------------------------
# Step 2: gate CLI end-to-end
# ---------------------------------------------------------------------------


class TestGateCmdEndToEnd:
    """Tests that _run_gate_cmd wires loading + gate + report correctly."""

    def _make_gate_result(self, *, passed: bool, results_dir: Path) -> GateResult:
        criteria = [CriterionResult(name="stub", passed=passed, detail="ok" if passed else "fail")]
        return GateResult(
            passed=passed,
            criteria=criteria,
            tasks_run=2,
            wall_time_s=10.0,
            results_dir=results_dir,
        )

    def test_gate_cmd_runs_and_prints_report(self, tmp_path, fake_task, write_tasks_jsonl, capsys):
        """Gate passing -> exit 0 and report printed."""
        tasks = [fake_task("t1"), fake_task("t2")]
        jsonl_path = write_tasks_jsonl(tasks)

        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            dry_run=False,
            skip_eval=False,
        )

        gate_result = self._make_gate_result(passed=True, results_dir=tmp_path / "results")

        with (
            patch("benchmark.swebench.gate.run_gate", return_value=gate_result),
            patch("benchmark.swebench.gate.format_gate_report", return_value="Gate: PASS"),
        ):
            with pytest.raises(SystemExit) as exc_info:
                _run_gate_cmd(args)
            assert exc_info.value.code == 0

        captured = capsys.readouterr()
        assert "PASS" in captured.out

    def test_gate_cmd_exits_1_on_failure(self, tmp_path, fake_task, write_tasks_jsonl, capsys):
        """Gate failing -> exit 1."""
        tasks = [fake_task("t1"), fake_task("t2")]
        jsonl_path = write_tasks_jsonl(tasks)

        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            dry_run=False,
            skip_eval=False,
        )

        gate_result = self._make_gate_result(passed=False, results_dir=tmp_path / "results")

        with (
            patch("benchmark.swebench.gate.run_gate", return_value=gate_result),
            patch("benchmark.swebench.gate.format_gate_report", return_value="Gate: FAIL"),
        ):
            with pytest.raises(SystemExit) as exc_info:
                _run_gate_cmd(args)
            assert exc_info.value.code == 1

        captured = capsys.readouterr()
        assert "FAIL" in captured.out

    def test_gate_cmd_loads_real_tasks_through_to_gate(self, tmp_path, fake_task, write_tasks_jsonl, capsys):
        """Gate cmd should load real JSONL tasks and pass them to run_gate (not mocked)."""
        tasks = [fake_task("t1"), fake_task("t2")]
        jsonl_path = write_tasks_jsonl(tasks)

        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            dry_run=False,
            skip_eval=False,
        )

        captured_tasks = []

        def spy_run_gate(tasks_arg, config, **kw):
            captured_tasks.extend(tasks_arg)
            criteria = [CriterionResult(name="stub", passed=True, detail="ok")]
            return GateResult(
                passed=True,
                criteria=criteria,
                tasks_run=len(tasks_arg),
                wall_time_s=1.0,
                results_dir=config.results_dir,
            )

        with patch("benchmark.swebench.gate.run_gate", side_effect=spy_run_gate):
            with pytest.raises(SystemExit):
                _run_gate_cmd(args)

        # Verify tasks loaded from JSONL made it through to run_gate
        assert len(captured_tasks) == 2
        assert captured_tasks[0]["instance_id"] == "t1"
        assert captured_tasks[1]["instance_id"] == "t2"
        assert "problem_statement" in captured_tasks[0]


# ---------------------------------------------------------------------------
# Step 2b: run CLI end-to-end
# ---------------------------------------------------------------------------


class TestRunCmdEndToEnd:
    """Tests that _run_all_cmd wires loading + run_all correctly."""

    def test_run_cmd_completes_and_exits_0(self, tmp_path, fake_task, write_tasks_jsonl, capsys):
        """Run cmd should load JSONL, run tasks, print summary, exit 0."""
        tasks = [fake_task("t1")]
        jsonl_path = write_tasks_jsonl(tasks)

        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            resume=False,
            dry_run=False,
        )

        run_all_result = {
            "aborted": False,
            "abort_reason": None,
            "tasks_completed": 1,
            "tasks_skipped": 0,
        }

        with patch("benchmark.swebench.runner.run_all", return_value=run_all_result):
            with pytest.raises(SystemExit) as exc_info:
                _run_all_cmd(args)
            assert exc_info.value.code == 0

        captured = capsys.readouterr()
        assert "Completed: 1" in captured.out

    def test_run_cmd_exits_1_on_abort(self, tmp_path, fake_task, write_tasks_jsonl, capsys):
        """Run cmd should exit 1 when run_all aborts."""
        tasks = [fake_task("t1")]
        jsonl_path = write_tasks_jsonl(tasks)

        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            resume=False,
            dry_run=False,
        )

        run_all_result = {
            "aborted": True,
            "abort_reason": "Infra error rate 100% exceeds 20% threshold",
            "tasks_completed": 1,
            "tasks_skipped": 0,
        }

        with patch("benchmark.swebench.runner.run_all", return_value=run_all_result):
            with pytest.raises(SystemExit) as exc_info:
                _run_all_cmd(args)
            assert exc_info.value.code == 1

        captured = capsys.readouterr()
        assert "ABORTED" in captured.out


# ---------------------------------------------------------------------------
# Step 5/6/7: --dry-run / --skip-eval CLI wiring
# ---------------------------------------------------------------------------


class TestDryRunCliWiring:
    """Tests that --dry-run and --skip-eval flags are wired end-to-end."""

    def test_parse_run_dry_run_flag(self, tmp_path):
        """Parse 'run ... --dry-run' should set args.dry_run=True."""
        tasks_file = tmp_path / "tasks.jsonl"
        tasks_file.touch()
        args = _build_parser().parse_args(
            ["run", "--repos-dir", str(tmp_path), "--tasks-jsonl", str(tasks_file), "--dry-run"]
        )
        assert args.dry_run is True

    def test_parse_gate_dry_run_and_skip_eval_flags(self, tmp_path):
        """Parse 'gate ... --dry-run --skip-eval' should set both flags."""
        tasks_file = tmp_path / "tasks.jsonl"
        tasks_file.touch()
        args = _build_parser().parse_args(
            ["gate", "--repos-dir", str(tmp_path), "--tasks-jsonl", str(tasks_file), "--dry-run", "--skip-eval"]
        )
        assert args.dry_run is True
        assert args.skip_eval is True

    def test_gate_cmd_forwards_dry_run_and_skip_eval_to_gate_config(self, tmp_path, fake_task, write_tasks_jsonl):
        """Gate CLI --dry-run and --skip-eval parse to GateConfig fields correctly."""
        tasks = [fake_task("t1"), fake_task("t2")]
        jsonl_path = write_tasks_jsonl(tasks)
        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            dry_run=True,
            skip_eval=True,
        )
        captured_config = {}

        def spy_run_gate(tasks_arg, config, **kw):
            captured_config["config"] = config
            criteria = [CriterionResult(name="stub", passed=True, detail="ok")]
            return GateResult(
                passed=True,
                criteria=criteria,
                tasks_run=len(tasks_arg),
                wall_time_s=1.0,
                results_dir=config.results_dir,
            )

        with patch("benchmark.swebench.gate.run_gate", side_effect=spy_run_gate):
            with pytest.raises(SystemExit):
                _run_gate_cmd(args)

        assert captured_config["config"].dry_run is True
        assert captured_config["config"].skip_eval is True

    def test_run_cmd_forwards_dry_run_to_run_all(self, tmp_path, fake_task, write_tasks_jsonl):
        """Run CLI --dry-run is forwarded to run_all."""
        tasks = [fake_task("t1")]
        jsonl_path = write_tasks_jsonl(tasks)
        args = argparse.Namespace(
            tasks_jsonl=jsonl_path,
            tasks_hf=None,
            instance_ids=None,
            difficulties=None,
            repos_dir=tmp_path,
            results_dir=tmp_path / "results",
            seed=42,
            model="test-model",
            timeout=60,
            no_checkout=True,
            resume=False,
            dry_run=True,
        )
        captured_kwargs: dict = {}

        def spy_run_all(*args, **kwargs):
            captured_kwargs.update(kwargs)
            return {"aborted": False, "abort_reason": None, "tasks_completed": 1, "tasks_skipped": 0}

        with patch("benchmark.swebench.runner.run_all", side_effect=spy_run_all):
            with pytest.raises(SystemExit):
                _run_all_cmd(args)

        assert captured_kwargs.get("dry_run") is True
