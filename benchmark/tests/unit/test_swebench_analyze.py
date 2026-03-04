"""Tests for benchmark.swebench.analyze module."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

# === Step 2.1: load_jsonl + validate_jsonl ===


def test_load_jsonl_valid(tmp_path: Path) -> None:
    p = tmp_path / "data.jsonl"
    p.write_text(
        json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""})
        + "\n"
        + json.dumps({"task_id": "t2", "condition": "baseline", "passed": False, "patch": "x"})
        + "\n"
    )
    from benchmark.swebench.analyze import load_jsonl

    result = load_jsonl(p)
    assert len(result) == 2
    assert result[0]["task_id"] == "t1"


def test_validate_jsonl_missing_passed() -> None:
    from benchmark.swebench.analyze import validate_jsonl

    entries = [
        {"task_id": "t1", "condition": "baseline", "patch": "x"},  # missing passed
    ]
    errors = validate_jsonl(entries)
    assert any("passed" in e for e in errors)


def test_validate_jsonl_duplicate_task_ids() -> None:
    from benchmark.swebench.analyze import validate_jsonl

    entries = [
        {"task_id": "t1", "condition": "baseline", "passed": True, "patch": "x"},
        {"task_id": "t1", "condition": "baseline", "passed": False, "patch": "y"},
    ]
    errors = validate_jsonl(entries)
    assert any("uplicate" in e or "duplicate" in e.lower() for e in errors)


# === Step 2.2: compute_mcnemar ===


def test_compute_mcnemar_returns_all_keys() -> None:
    from benchmark.swebench.analyze import compute_mcnemar

    result = compute_mcnemar({"a"}, {"a", "b"}, {"a", "b", "c"})
    assert set(result.keys()) == {"b_to_p", "p_to_b", "p_value", "significant", "odds_ratio", "ci_95"}


def test_compute_mcnemar_no_discordant() -> None:
    from benchmark.swebench.analyze import compute_mcnemar

    result = compute_mcnemar({"a", "b"}, {"a", "b"}, {"a", "b", "c"})
    assert result["p_value"] == 1.0
    assert result["odds_ratio"] is None
    assert result["ci_95"] is None


def test_compute_mcnemar_direction() -> None:
    from benchmark.swebench.analyze import compute_mcnemar

    # b_to_p: tasks that baseline fails but plankton passes
    # baseline passes: {a}, plankton passes: {a, b, c, d}
    # all: {a, b, c, d, e}
    # b_to_p = {b, c, d} (3), p_to_b = {} (0)
    result = compute_mcnemar({"a"}, {"a", "b", "c", "d"}, {"a", "b", "c", "d", "e"})
    assert result["b_to_p"] == 3
    assert result["p_to_b"] == 0
    assert result["odds_ratio"] is None  # p_to_b == 0


# === Step 2.3: load_paired_results ===


def test_load_paired_results_structure(tmp_path: Path) -> None:
    from benchmark.swebench.analyze import load_paired_results

    base = tmp_path / "base.jsonl"
    plank = tmp_path / "plank.jsonl"
    base.write_text(json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""}) + "\n")
    plank.write_text(json.dumps({"task_id": "t1", "condition": "plankton", "passed": False, "patch": "p"}) + "\n")
    result = load_paired_results(base, plank)
    assert "t1" in result
    assert result["t1"]["baseline"]["condition"] == "baseline"
    assert result["t1"]["plankton"]["condition"] == "plankton"


def test_load_paired_results_asymmetric(tmp_path: Path) -> None:
    from benchmark.swebench.analyze import load_paired_results

    base = tmp_path / "base.jsonl"
    plank = tmp_path / "plank.jsonl"
    base.write_text(json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""}) + "\n")
    plank.write_text(json.dumps({"task_id": "t2", "condition": "plankton", "passed": False, "patch": "p"}) + "\n")
    with pytest.raises(ValueError, match="Mismatched"):
        load_paired_results(base, plank)


# === Step 2.4: generate_report ===


def test_generate_report_sections() -> None:
    from benchmark.swebench.analyze import generate_report

    paired = {
        "t1": {
            "baseline": {"passed": True},
            "plankton": {"passed": False},
        },
    }
    report = generate_report(paired, {"seed": 42})
    assert "Pass Rate" in report
    assert "McNemar" in report
    assert "baseline" in report
    assert "plankton" in report


def test_generate_report_includes_seed() -> None:
    from benchmark.swebench.analyze import generate_report

    paired = {
        "t1": {
            "baseline": {"passed": True},
            "plankton": {"passed": True},
        },
    }
    report = generate_report(paired, {"seed": 12345})
    assert "12345" in report


# === Step C1: load_paired_results_from_combined ===


def test_generate_report_includes_flip_direction_labels() -> None:
    from benchmark.swebench.analyze import generate_report

    paired = {
        "t1": {"baseline": {"passed": False}, "plankton": {"passed": True}},
        "t2": {"baseline": {"passed": True}, "plankton": {"passed": False}},
        "t3": {"baseline": {"passed": True}, "plankton": {"passed": True}},
    }
    report = generate_report(paired, {"seed": 42})
    assert "fail→pass" in report or "fail->pass" in report
    assert "pass→fail" in report or "pass->fail" in report
    assert "Plankton helped" in report
    assert "regressions" in report


def test_load_paired_results_combined(tmp_path: Path) -> None:
    from benchmark.swebench.analyze import load_paired_results_from_combined

    p = tmp_path / "combined.jsonl"
    p.write_text(
        json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""})
        + "\n"
        + json.dumps({"task_id": "t1", "condition": "plankton", "passed": False, "patch": "p"})
        + "\n"
        + json.dumps({"task_id": "t2", "condition": "baseline", "passed": False, "patch": ""})
        + "\n"
        + json.dumps({"task_id": "t2", "condition": "plankton", "passed": True, "patch": "q"})
        + "\n"
    )
    result = load_paired_results_from_combined(p)
    assert len(result) == 2
    assert result["t1"]["baseline"]["passed"] is True
    assert result["t1"]["plankton"]["passed"] is False
    assert result["t2"]["plankton"]["passed"] is True


def test_load_paired_results_combined_missing_condition(tmp_path: Path) -> None:
    from benchmark.swebench.analyze import load_paired_results_from_combined

    p = tmp_path / "bad.jsonl"
    p.write_text(json.dumps({"task_id": "t1", "passed": True, "patch": ""}) + "\n")
    with pytest.raises(ValueError, match="condition"):
        load_paired_results_from_combined(p)


# === Slice B1: No duplicate raw b_to_p/p_to_b lines ===


# === Slice A3: load_paired_results_from_combined orphan handling ===


def test_should_return_only_fully_paired_tasks(tmp_path: Path) -> None:
    """Should return only fully-paired tasks from combined JSONL with orphan entries."""
    from benchmark.swebench.analyze import load_paired_results_from_combined

    p = tmp_path / "combined.jsonl"
    p.write_text(
        json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""})
        + "\n"
        + json.dumps({"task_id": "t1", "condition": "plankton", "passed": False, "patch": "p"})
        + "\n"
        + json.dumps({"task_id": "t2", "condition": "baseline", "passed": False, "patch": ""})
        + "\n"
    )
    result = load_paired_results_from_combined(p)
    assert "t1" in result
    assert "t2" not in result


def test_should_log_warning_for_orphaned_tasks(tmp_path: Path, caplog) -> None:
    """Should log warning when combined JSONL has tasks missing one condition."""
    import logging

    from benchmark.swebench.analyze import load_paired_results_from_combined

    p = tmp_path / "combined.jsonl"
    p.write_text(
        json.dumps({"task_id": "t1", "condition": "baseline", "passed": True, "patch": ""})
        + "\n"
        + json.dumps({"task_id": "t1", "condition": "plankton", "passed": False, "patch": "p"})
        + "\n"
        + json.dumps({"task_id": "t2", "condition": "baseline", "passed": False, "patch": ""})
        + "\n"
    )
    with caplog.at_level(logging.WARNING):
        load_paired_results_from_combined(p)
    assert any("t2" in record.message for record in caplog.records)


# === Slice A2: validate_jsonl duplicate detection scoped per condition ===


def test_should_not_flag_duplicate_when_same_task_id_different_conditions() -> None:
    """Should not flag duplicate when same task_id appears with different conditions."""
    from benchmark.swebench.analyze import validate_jsonl

    entries = [
        {"task_id": "t1", "condition": "baseline", "passed": True, "patch": "x"},
        {"task_id": "t1", "condition": "plankton", "passed": False, "patch": "y"},
    ]
    errors = validate_jsonl(entries)
    assert not any("uplicate" in e.lower() or "duplicate" in e.lower() for e in errors)


def test_should_flag_duplicate_when_same_task_id_and_condition() -> None:
    """Should flag duplicate when same task_id+condition appears twice."""
    from benchmark.swebench.analyze import validate_jsonl

    entries = [
        {"task_id": "t1", "condition": "baseline", "passed": True, "patch": "x"},
        {"task_id": "t1", "condition": "baseline", "passed": False, "patch": "y"},
    ]
    errors = validate_jsonl(entries)
    assert any("uplicate" in e.lower() or "duplicate" in e.lower() for e in errors)


def test_report_should_not_contain_bare_b_to_p_lines() -> None:
    """Report should NOT contain bare 'b_to_p:' or 'p_to_b:' lines."""
    from benchmark.swebench.analyze import generate_report

    paired = {
        "t1": {"baseline": {"passed": False}, "plankton": {"passed": True}},
        "t2": {"baseline": {"passed": True}, "plankton": {"passed": False}},
    }
    report = generate_report(paired, {"seed": 42})
    for line in report.splitlines():
        stripped = line.strip().lstrip("- ")
        # Bare lines like "b_to_p: 1" without any label prefix should not exist
        assert not stripped.startswith("b_to_p:"), f"Found bare b_to_p line: {line}"
        assert not stripped.startswith("p_to_b:"), f"Found bare p_to_b line: {line}"
