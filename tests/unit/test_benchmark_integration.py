"""Integration test for benchmark runner._run_task with mocked subprocess."""

import argparse
import json
import sys
from pathlib import Path
from subprocess import CompletedProcess

# benchmark/ is not a package — inject it onto sys.path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "benchmark"))

import runner  # noqa: E402


def test_run_task_produces_jsonl_and_log(tmp_path, monkeypatch):
    # -- setup directories --
    samples_dir = tmp_path / "samples"
    logs_dir = tmp_path / "logs"
    samples_dir.mkdir()
    logs_dir.mkdir()

    baseline_jsonl = samples_dir / "baseline.jsonl"
    plankton_jsonl = samples_dir / "plankton.jsonl"
    baseline_jsonl.touch()
    plankton_jsonl.touch()

    # -- fake task --
    task = {
        "prompt": 'def foo():\n    """Do stuff."""\n',
        "entry_point": "foo",
    }

    # -- fake args --
    args = argparse.Namespace(model="test-model", timeout=30, dry_run=False)

    # -- monkeypatch REPO_ROOT so plankton workdir stays in tmp --
    fake_repo = tmp_path / "fake_repo"
    fake_repo.mkdir()
    monkeypatch.setattr(runner, "REPO_ROOT", fake_repo)

    # -- mock subprocess.run --
    solution_code = 'def foo():\n    """Do stuff."""\n    return 42\n'

    def mock_subprocess_run(cmd, **kwargs):
        cmd_str = " ".join(str(c) for c in cmd)
        if "git" in cmd_str:
            return CompletedProcess(cmd, returncode=0, stdout="", stderr="")
        # claude command — write solution.py to cwd
        cwd = kwargs.get("cwd")
        if cwd is not None:
            (Path(cwd) / "solution.py").write_text(solution_code)
        return CompletedProcess(cmd, returncode=0, stdout='{"result":"ok"}', stderr="")

    import subprocess

    monkeypatch.setattr(subprocess, "run", mock_subprocess_run)

    # -- call _run_task --
    runner._run_task(
        "HumanEval/99",
        task,
        args,
        (baseline_jsonl, plankton_jsonl, logs_dir),
    )

    # -- assert baseline.jsonl --
    baseline_lines = [json.loads(l) for l in baseline_jsonl.read_text().strip().splitlines()]
    assert len(baseline_lines) == 1
    assert baseline_lines[0]["task_id"] == "HumanEval/99"

    # -- assert plankton.jsonl --
    plankton_lines = [json.loads(l) for l in plankton_jsonl.read_text().strip().splitlines()]
    assert len(plankton_lines) == 1
    assert plankton_lines[0]["task_id"] == "HumanEval/99"

    # -- assert log file --
    log_file = logs_dir / "HumanEval_99.json"
    assert log_file.exists()
    log_data = json.loads(log_file.read_text())
    assert "baseline" in log_data
    assert "plankton" in log_data
