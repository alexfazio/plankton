"""Tests for benchmark/analyze.py — strict TDD."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "benchmark"))

import json

import analyze

# ── 1. load_jsonl ──────────────────────────────────────────────────────────


def test_load_jsonl(tmp_path):
    p = tmp_path / "data.jsonl"
    rows = [{"task_id": "HumanEval/0", "completion": "pass"}, {"task_id": "HumanEval/1", "completion": "return 1"}]
    p.write_text("\n".join(json.dumps(r) for r in rows))
    result = analyze.load_jsonl(p)
    assert result == rows


# ── 2. validate_jsonl ─────────────────────────────────────────────────────


def _make_entries(n=164):
    return [{"task_id": f"HumanEval/{i}", "completion": f"code_{i}"} for i in range(n)]


def test_validate_jsonl_valid():
    assert analyze.validate_jsonl(_make_entries(164), expected_count=164) == []


def test_validate_jsonl_wrong_count():
    errs = analyze.validate_jsonl(_make_entries(10), expected_count=164)
    assert any("count" in e.lower() for e in errs)


def test_validate_jsonl_bad_task_id():
    entries = _make_entries(2)
    entries[1]["task_id"] = "BadId/999"
    errs = analyze.validate_jsonl(entries, expected_count=2)
    assert any("task_id" in e.lower() or "BadId" in e for e in errs)


def test_validate_jsonl_duplicate():
    entries = _make_entries(3)
    entries[2]["task_id"] = "HumanEval/0"
    errs = analyze.validate_jsonl(entries, expected_count=3)
    assert any("duplicate" in e.lower() for e in errs)


def test_validate_jsonl_empty_completion():
    entries = _make_entries(2)
    entries[0]["completion"] = ""
    errs = analyze.validate_jsonl(entries, expected_count=2)
    assert any("empty" in e.lower() or "completion" in e.lower() for e in errs)


# ── ClassEval validate_jsonl ─────────────────────────────────────────────


def _make_classeval_entries(n=20):
    return [{"task_id": f"ClassEval_{i}", "predict": [f"class C{i}: pass"]} for i in range(n)]


def test_validate_classeval_valid():
    assert analyze.validate_jsonl(_make_classeval_entries(20), expected_count=20, benchmark="classeval") == []


def test_validate_classeval_humaneval_id_rejected():
    entries = _make_classeval_entries(2)
    entries[1]["task_id"] = "HumanEval/0"
    errs = analyze.validate_jsonl(entries, expected_count=2, benchmark="classeval")
    assert any("task_id" in e.lower() or "HumanEval" in e for e in errs)


def test_validate_classeval_missing_predict():
    entries = _make_classeval_entries(2)
    del entries[0]["predict"]
    errs = analyze.validate_jsonl(entries, expected_count=2, benchmark="classeval")
    assert any("predict" in e.lower() for e in errs)


# ── 3. parse_evalplus_stdout ──────────────────────────────────────────────


def test_parse_evalplus_stdout():
    stdout = """\
Some preamble text
Base: HumanEval
Extra: HumanEval+
pass@1:	0.7500
pass@10:	0.8500
Done.
"""
    result = analyze.parse_evalplus_stdout(stdout)
    assert result == {"pass@1": 0.75, "pass@10": 0.85}


# ── 4. compute_mcnemar ───────────────────────────────────────────────────


def test_mcnemar_significant():
    all_tasks = {f"HumanEval/{i}" for i in range(100)}
    both_pass = {f"HumanEval/{i}" for i in range(50)}
    # 30 flip baseline->plankton, 5 flip plankton->baseline
    b_to_p_tasks = {f"HumanEval/{i}" for i in range(50, 80)}
    p_to_b_tasks = {f"HumanEval/{i}" for i in range(80, 85)}
    baseline_pass = both_pass | p_to_b_tasks
    plankton_pass = both_pass | b_to_p_tasks
    result = analyze.compute_mcnemar(baseline_pass, plankton_pass, all_tasks)
    assert result["b_to_p"] == 30
    assert result["p_to_b"] == 5
    assert result["p_value"] < 0.05
    assert result["significant"] is True


def test_mcnemar_not_significant():
    all_tasks = {f"HumanEval/{i}" for i in range(100)}
    both_pass = {f"HumanEval/{i}" for i in range(50)}
    b_to_p_tasks = {f"HumanEval/{i}" for i in range(50, 65)}
    p_to_b_tasks = {f"HumanEval/{i}" for i in range(65, 80)}
    baseline_pass = both_pass | p_to_b_tasks
    plankton_pass = both_pass | b_to_p_tasks
    result = analyze.compute_mcnemar(baseline_pass, plankton_pass, all_tasks)
    assert result["b_to_p"] == 15
    assert result["p_to_b"] == 15
    assert result["p_value"] > 0.05
    assert result["significant"] is False


# ── 5. generate_report ───────────────────────────────────────────────────


def _setup_results_dir(tmp_path):
    metadata = {
        "model": "gpt-4o",
        "claude_version": "3.5",
        "started_at": "2025-01-01T00:00:00Z",
        "finished_at": "2025-01-01T01:00:00Z",
    }
    eval_results = {
        "baseline": {"pass@1": 0.70, "pass@10": 0.80},
        "plankton": {"pass@1": 0.78, "pass@10": 0.88},
    }
    (tmp_path / "metadata.json").write_text(json.dumps(metadata))
    (tmp_path / "eval_results.json").write_text(json.dumps(eval_results))
    return tmp_path


def test_generate_report(tmp_path):
    d = _setup_results_dir(tmp_path)
    report = analyze.generate_report(d)
    assert "# Plankton Benchmark Report" in report
    assert "gpt-4o" in report
    assert "pass@1" in report
    assert "Delta" in report or "delta" in report.lower()


# ── 6. CLI main ──────────────────────────────────────────────────────────


def test_main_writes_report(tmp_path, monkeypatch):
    _setup_results_dir(tmp_path)
    monkeypatch.setattr("sys.argv", ["analyze", "--results-dir", str(tmp_path)])
    analyze.main()
    report_path = tmp_path / "REPORT.md"
    assert report_path.exists()
    assert "Plankton Benchmark Report" in report_path.read_text()
