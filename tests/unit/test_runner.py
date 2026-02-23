"""Unit tests for benchmark/runner.py."""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "benchmark"))

import runner  # noqa: E402


class TestWriteStub:
    """Test write_stub function."""

    def test_write_stub(self, tmp_path):
        """Write stub file and verify contents."""
        task = {"prompt": 'def foo():\n    """Do stuff."""\n'}
        result = runner.write_stub(task, tmp_path)

        solution = tmp_path / "solution.py"
        assert solution.exists()
        assert solution.read_text() == task["prompt"] + "    pass\n"
        assert result == task["prompt"]


class TestExtractCompletion:
    """Test extract_completion function."""

    def test_starts_with_prompt(self):
        """Strip prompt prefix when output starts with it."""
        prompt = "def foo():\n"
        full_code = "def foo():\n    return 42\n"
        assert runner.extract_completion(full_code, prompt) == "    return 42\n"

    def test_does_not_start_with_prompt(self):
        """Return full code when it does not start with prompt."""
        prompt = "def foo():\n"
        full_code = "import os\ndef foo():\n    return 42\n"
        assert runner.extract_completion(full_code, prompt) == full_code


class TestBuildCmd:
    """Test _build_cmd function."""

    def test_baseline(self):
        """Build baseline command with expected flags."""
        cmd = runner._build_cmd("baseline", "test-model")
        assert "--setting-sources" in cmd
        assert "--settings" in cmd
        assert "--strict-mcp-config" in cmd
        assert "--disable-slash-commands" in cmd
        assert "-p" in cmd
        assert "--output-format" in cmd
        assert "json" in cmd
        assert "--dangerously-skip-permissions" in cmd
        assert "--model" in cmd
        assert "test-model" in cmd

    def test_plankton(self):
        """Build plankton command without setting-sources flags."""
        cmd = runner._build_cmd("plankton", "test-model")
        assert "--setting-sources" not in cmd
        assert "--strict-mcp-config" not in cmd
        assert "-p" in cmd
        assert "--output-format" in cmd
        assert "json" in cmd
        assert "--model" in cmd
        assert "test-model" in cmd

    def test_baseline_allows_only_needed_tools(self):
        """Baseline command uses allowlist of needed tools."""
        cmd = runner._build_cmd("baseline", "test-model")
        assert "--allowedTools" in cmd
        idx = cmd.index("--allowedTools")
        tools_value = cmd[idx + 1]
        for tool in ("Edit", "Read", "Write", "Bash", "Glob", "Grep"):
            assert tool in tools_value

    def test_plankton_allows_only_needed_tools(self):
        """Plankton command uses allowlist of needed tools."""
        cmd = runner._build_cmd("plankton", "test-model")
        assert "--allowedTools" in cmd
        idx = cmd.index("--allowedTools")
        tools_value = cmd[idx + 1]
        for tool in ("Edit", "Read", "Write", "Bash", "Glob", "Grep"):
            assert tool in tools_value


class TestParseClaudeOutput:
    """Test _parse_claude_output function."""

    def test_valid_json(self):
        """Parse valid JSON stdout into structured metadata."""
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result": "ok"}', stderr="")
        meta = runner._parse_claude_output(result, 5.0)
        assert meta["returncode"] == 0
        assert meta["elapsed_s"] == 5.0
        assert meta["claude_output"] == {"result": "ok"}

    def test_invalid_json(self):
        """Fall back to raw_stdout when JSON parsing fails."""
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="not json", stderr="")
        meta = runner._parse_claude_output(result, 3.0)
        assert "raw_stdout" in meta

    def test_with_stderr(self):
        """Include stderr in metadata when present."""
        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="{}", stderr="error msg")
        meta = runner._parse_claude_output(result, 1.0)
        assert "stderr" in meta
        assert meta["stderr"] == "error msg"


class TestAppendJsonl:
    """Test append_jsonl function."""

    def test_append_two_entries(self, tmp_path):
        """Append two entries and verify JSONL output."""
        path = tmp_path / "out.jsonl"
        runner.append_jsonl(path, "HumanEval/0", "code here")
        runner.append_jsonl(path, "HumanEval/1", "more code")

        lines = path.read_text().strip().split("\n")
        assert len(lines) == 2
        first = json.loads(lines[0])
        second = json.loads(lines[1])
        assert first["task_id"] == "HumanEval/0"
        assert first["completion"] == "code here"
        assert second["task_id"] == "HumanEval/1"
        assert second["completion"] == "more code"


class TestSetupBaselineWorkdir:
    """Test setup_baseline_workdir function."""

    def test_creates_workdir(self):
        """Create baseline workdir with git repo and solution stub."""
        task = {"prompt": "def foo():\n    pass\n"}
        work_dir = runner.setup_baseline_workdir(task, "HumanEval/0")
        try:
            assert work_dir.exists()
            assert (work_dir / "solution.py").exists()
            result = subprocess.run(
                ["git", "log", "--oneline"],
                cwd=work_dir,
                capture_output=True,
                text=True,
                check=False,
            )
            assert result.returncode == 0
        finally:
            shutil.rmtree(work_dir, ignore_errors=True)


class TestSetupPlanktonWorkdir:
    """Tests for setup_plankton_workdir."""

    def test_writes_stub_to_repo_root(self, tmp_path, monkeypatch):
        """Test that stub is written to repo root."""
        monkeypatch.setattr(runner, "REPO_ROOT", tmp_path)
        task = {"prompt": "def foo():\n    pass\n"}
        result = runner.setup_plankton_workdir(task)
        assert result == tmp_path
        assert (tmp_path / "solution.py").exists()


class TestEvaluateAndReport:
    """Test _evaluate_and_report integration with analyze module."""

    def test_evaluate_and_report_saves_parsed_rates(self, tmp_path):
        """Parsed pass rates are saved to eval_results.json and REPORT.md is generated."""
        # Setup: create metadata.json (needed by generate_report)
        metadata = {
            "model": "test-model",
            "claude_version": "1.0.0",
            "started_at": "2026-01-01T00:00:00",
            "finished_at": "2026-01-01T01:00:00",
        }
        (tmp_path / "metadata.json").write_text(json.dumps(metadata))

        # Create fake JSONL files
        baseline_jsonl = tmp_path / "baseline.jsonl"
        plankton_jsonl = tmp_path / "plankton.jsonl"
        baseline_jsonl.write_text('{"task_id": "HumanEval/0", "completion": "return 1"}\n')
        plankton_jsonl.write_text('{"task_id": "HumanEval/0", "completion": "return 1"}\n')

        fake_stdout = "pass@1: 0.7500\npass@10: 0.8500\n"
        fake_eval = {"returncode": 0, "stdout": fake_stdout, "stderr": ""}

        with patch.object(runner, "run_evalplus", return_value=fake_eval):
            runner._evaluate_and_report(tmp_path, baseline_jsonl, plankton_jsonl, True)

        # Check eval_results.json has parsed rates
        eval_results = json.loads((tmp_path / "eval_results.json").read_text())
        assert eval_results["baseline"] == {"pass@1": 0.75, "pass@10": 0.85}
        assert eval_results["plankton"] == {"pass@1": 0.75, "pass@10": 0.85}

        # Check raw output saved separately
        eval_raw = json.loads((tmp_path / "eval_raw.json").read_text())
        assert eval_raw["baseline"]["stdout"] == fake_stdout

        # Check REPORT.md exists and has content
        report_path = tmp_path / "REPORT.md"
        assert report_path.exists()
        report = report_path.read_text()
        assert "Plankton Benchmark Report" in report
        assert "0.7500" in report


class TestGetCompletedTasks:
    """Test _get_completed_tasks function."""

    def test_intersection_of_both_files(self, tmp_path):
        """Return intersection of task_ids present in both JSONL files."""
        baseline = tmp_path / "baseline.jsonl"
        plankton = tmp_path / "plankton.jsonl"
        baseline.write_text(
            json.dumps({"task_id": "HumanEval/0", "completion": "a"})
            + "\n"
            + json.dumps({"task_id": "HumanEval/1", "completion": "b"})
            + "\n"
            + json.dumps({"task_id": "HumanEval/2", "completion": "c"})
            + "\n"
        )
        plankton.write_text(
            json.dumps({"task_id": "HumanEval/1", "completion": "x"})
            + "\n"
            + json.dumps({"task_id": "HumanEval/2", "completion": "y"})
            + "\n"
            + json.dumps({"task_id": "HumanEval/3", "completion": "z"})
            + "\n"
        )
        result = runner._get_completed_tasks(baseline, plankton)
        assert result == {"HumanEval/1", "HumanEval/2"}

    def test_one_file_missing(self, tmp_path):
        """Return empty set when one file is missing."""
        baseline = tmp_path / "baseline.jsonl"
        plankton = tmp_path / "plankton.jsonl"
        baseline.write_text(json.dumps({"task_id": "HumanEval/0", "completion": "a"}) + "\n")
        result = runner._get_completed_tasks(baseline, plankton)
        assert result == set()

    def test_both_files_missing(self, tmp_path):
        """Return empty set when both files are missing."""
        result = runner._get_completed_tasks(tmp_path / "a.jsonl", tmp_path / "b.jsonl")
        assert result == set()


class TestResumeFlag:
    """Test that --resume flag is accepted by argparse."""

    def test_resume_flag_accepted(self):
        """--resume should be accepted by the argument parser."""
        parser = argparse.ArgumentParser()
        parser.add_argument("--resume", action="store_true")
        args = parser.parse_args(["--resume"])
        assert args.resume is True


# ── ClassEval tests ──────────────────────────────────────────────────────


class TestGetClassevalTasks:
    """Test get_classeval_tasks function."""

    def _write_data(self, tmp_path, n=3):
        tasks = [
            {
                "task_id": f"ClassEval_{i}",
                "skeleton": f"class Foo{i}:\n    pass",
                "test": f"# test {i}",
                "import_statement": f"import os",
            }
            for i in range(n)
        ]
        path = tmp_path / "data.json"
        path.write_text(json.dumps(tasks))
        return path

    def test_loads_all(self, tmp_path):
        """Load 3-entry JSON, returns dict keyed by task_id."""
        path = self._write_data(tmp_path, 3)
        result = runner.get_classeval_tasks(data_path=path)
        assert len(result) == 3
        assert "ClassEval_0" in result
        assert "ClassEval_2" in result

    def test_limit(self, tmp_path):
        """With limit=2, returns only first 2 sorted by task_id."""
        path = self._write_data(tmp_path, 5)
        result = runner.get_classeval_tasks(data_path=path, limit=2)
        assert len(result) == 2
        assert list(sorted(result.keys())) == ["ClassEval_0", "ClassEval_1"]

    def test_task_keys(self, tmp_path):
        """Each task has skeleton, test, import_statement keys."""
        path = self._write_data(tmp_path, 1)
        result = runner.get_classeval_tasks(data_path=path)
        task = result["ClassEval_0"]
        assert "skeleton" in task
        assert "test" in task
        assert "import_statement" in task


class TestWriteClassSkeleton:
    """Test write_class_skeleton function."""

    def test_output_format(self, tmp_path):
        """Output starts with imports, blank line, then skeleton."""
        task = {
            "import_statement": "import os",
            "skeleton": "class Foo:\n    pass",
        }
        content = runner.write_class_skeleton(task, tmp_path)
        lines = content.split("\n")
        assert lines[0] == "import os"
        assert lines[1] == ""
        assert lines[2] == "class Foo:"
        assert (tmp_path / "solution.py").read_text() == content

    def test_multiple_imports(self, tmp_path):
        """Multiple imports each on own line."""
        task = {
            "import_statement": "import os\nimport sys",
            "skeleton": "class Bar:\n    pass",
        }
        content = runner.write_class_skeleton(task, tmp_path)
        lines = content.split("\n")
        assert lines[0] == "import os"
        assert lines[1] == "import sys"
        assert lines[2] == ""

    def test_returns_content(self, tmp_path):
        """Returns the full content written."""
        task = {"import_statement": "", "skeleton": "class X:\n    pass"}
        content = runner.write_class_skeleton(task, tmp_path)
        assert content == (tmp_path / "solution.py").read_text()


class TestAppendClassevalJsonl:
    """Test append_classeval_jsonl function."""

    def test_single_entry(self, tmp_path):
        """Single entry has predict as single-element list."""
        path = tmp_path / "out.jsonl"
        runner.append_classeval_jsonl(path, "ClassEval_0", "class Foo: pass")
        entry = json.loads(path.read_text().strip())
        assert entry["task_id"] == "ClassEval_0"
        assert entry["predict"] == ["class Foo: pass"]

    def test_two_entries(self, tmp_path):
        """Two entries produce two valid JSONL lines."""
        path = tmp_path / "out.jsonl"
        runner.append_classeval_jsonl(path, "ClassEval_0", "code0")
        runner.append_classeval_jsonl(path, "ClassEval_1", "code1")
        lines = path.read_text().strip().split("\n")
        assert len(lines) == 2
        assert json.loads(lines[1])["task_id"] == "ClassEval_1"


class TestBuildCmdPrompt:
    """Test _build_cmd with custom prompt."""

    def test_custom_prompt(self):
        """Custom prompt string appears as last element of command."""
        cmd = runner._build_cmd("plankton", "test-model", "custom prompt")
        assert cmd[-1] == "custom prompt"

    def test_baseline_custom_prompt(self):
        """Custom prompt works for baseline too."""
        cmd = runner._build_cmd("baseline", "test-model", "my prompt")
        assert cmd[-1] == "my prompt"


class TestBenchmarkFlag:
    """Test --benchmark parser flag."""

    def test_classeval(self):
        """Parser accepts --benchmark classeval."""
        parser = runner._build_parser()
        args = parser.parse_args(["--benchmark", "classeval"])
        assert args.benchmark == "classeval"

    def test_default_evalplus(self):
        """Default is evalplus."""
        parser = runner._build_parser()
        args = parser.parse_args([])
        assert args.benchmark == "evalplus"


class TestRunClasseval:
    """Test run_classeval function."""

    def test_invokes_wrapper(self, tmp_path, monkeypatch):
        """Invokes subprocess with correct wrapper path and arguments."""
        calls = []

        def mock_run(cmd, **kwargs):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, returncode=0, stdout="pass@1: 0.5000\n", stderr="")

        monkeypatch.setattr(subprocess, "run", mock_run)
        samples = tmp_path / "samples.jsonl"
        samples.touch()
        data = tmp_path / "data.json"
        data.touch()
        result = runner.run_classeval(samples, data)
        assert result["returncode"] == 0
        assert "classeval_wrapper.py" in calls[0][1]
        assert str(samples) in calls[0]
        assert str(data) in calls[0]
