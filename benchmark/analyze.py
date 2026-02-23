"""Plankton Benchmark Analyzer — post-benchmark reporting and statistical analysis."""

from __future__ import annotations

import argparse
import json
import re as _re
from pathlib import Path  # noqa: TC003

from scipy.stats import binomtest  # noqa: TC002

SIGNIFICANCE_THRESHOLD = 0.05


def load_jsonl(path: Path) -> list[dict]:
    """Read a JSONL file, return list of parsed dicts."""
    entries = []
    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


_TASK_ID_RE = _re.compile(r"^HumanEval/\d+$")
_CLASSEVAL_TASK_ID_RE = _re.compile(r"^ClassEval_\d+$")


def validate_jsonl(entries: list[dict], expected_count: int = 164, benchmark: str = "evalplus") -> list[str]:
    """Return list of error strings for invalid JSONL entries."""
    is_classeval = benchmark == "classeval"
    task_id_re = _CLASSEVAL_TASK_ID_RE if is_classeval else _TASK_ID_RE
    if is_classeval and expected_count == 164:  # noqa: PLR2004
        expected_count = 20

    errors: list[str] = []
    if len(entries) != expected_count:
        errors.append(f"Expected count {expected_count}, got {len(entries)}")
    seen: set[str] = set()
    for i, entry in enumerate(entries):
        tid = entry.get("task_id", "")
        if not task_id_re.match(tid):
            errors.append(f"Invalid task_id at index {i}: {tid!r}")
        if tid in seen:
            errors.append(f"Duplicate task_id: {tid}")
        seen.add(tid)
        if is_classeval:
            predict = entry.get("predict")
            if not predict or not isinstance(predict, list) or not predict[0]:
                errors.append(f"Empty or missing predict at index {i} ({tid})")
        elif not entry.get("completion"):
            errors.append(f"Empty completion at index {i} ({tid})")
    return errors


_PASS_RE = _re.compile(r"^(pass@\d+):\s+([\d.]+)", _re.MULTILINE)


def parse_evalplus_stdout(stdout: str) -> dict:
    """Parse evalplus output to extract pass rates."""
    return {m.group(1): float(m.group(2)) for m in _PASS_RE.finditer(stdout)}


def compute_mcnemar(baseline_pass: set[str], plankton_pass: set[str], all_tasks: set[str]) -> dict:
    """Compute McNemar's test on paired binary outcomes using exact binomial test."""
    b_to_p_set = (all_tasks - baseline_pass) & plankton_pass
    p_to_b_set = (all_tasks - plankton_pass) & baseline_pass
    b_to_p = len(b_to_p_set)
    p_to_b = len(p_to_b_set)
    n = b_to_p + p_to_b
    if n == 0:
        p_value = 1.0
    else:
        result = binomtest(b_to_p, n, 0.5)
        p_value = result.pvalue
    return {
        "b_to_p": b_to_p,
        "p_to_b": p_to_b,
        "p_value": p_value,
        "significant": bool(p_value < SIGNIFICANCE_THRESHOLD),
    }


def generate_report(results_dir: Path) -> str:
    """Generate a markdown benchmark report from results directory."""
    metadata = json.loads((results_dir / "metadata.json").read_text())
    eval_results = json.loads((results_dir / "eval_results.json").read_text())

    lines = [
        "# Plankton Benchmark Report",
        "",
        "## Metadata",
        "",
        f"- **Model**: {metadata.get('model', 'N/A')}",
        f"- **Claude version**: {metadata.get('claude_version', 'N/A')}",
        f"- **Started**: {metadata.get('started_at', 'N/A')}",
        f"- **Finished**: {metadata.get('finished_at', 'N/A')}",
        "",
        "## Pass Rates",
        "",
    ]

    for condition, rates in eval_results.items():
        lines.extend((f"### {condition}", ""))
        for metric, value in rates.items():
            lines.append(f"- {metric}: {value:.4f}")
        lines.append("")

    # Delta section
    if "baseline" in eval_results and "plankton" in eval_results:
        lines.extend(("## Delta (plankton - baseline)", ""))
        baseline = eval_results["baseline"]
        plankton = eval_results["plankton"]
        for metric in baseline:
            if metric in plankton:
                delta = plankton[metric] - baseline[metric]
                lines.append(f"- {metric}: {delta:+.4f}")
        lines.append("")

    return "\n".join(lines)


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Plankton Benchmark Analyzer")
    parser.add_argument("--results-dir", required=True)
    args = parser.parse_args()
    report = generate_report(Path(args.results_dir))
    (Path(args.results_dir) / "REPORT.md").write_text(report)
    print(report)


if __name__ == "__main__":
    main()
