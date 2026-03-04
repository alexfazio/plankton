"""Plankton SWE-bench Analyzer — post-benchmark reporting and statistical analysis."""

from __future__ import annotations

import json
import logging
from pathlib import Path  # noqa: TC003

from scipy.stats import binomtest  # noqa: TC002

_logger = logging.getLogger(__name__)

SIGNIFICANCE_THRESHOLD = 0.05

_REQUIRED_FIELDS = {"task_id", "condition", "passed", "patch"}


def load_jsonl(path: Path) -> list[dict]:
    """Read a JSONL file, return list of parsed dicts."""
    entries = []
    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def validate_jsonl(entries: list[dict], expected_count: int | None = None) -> list[str]:
    """Return list of error strings. Required fields: task_id, condition, passed, patch."""
    errors: list[str] = []
    if expected_count is not None and len(entries) != expected_count:
        errors.append(f"Expected count {expected_count}, got {len(entries)}")
    seen: set[tuple[str, str]] = set()
    for i, entry in enumerate(entries):
        missing = _REQUIRED_FIELDS - set(entry.keys())
        if missing:
            errors.append(f"Missing fields at index {i}: {', '.join(sorted(missing))}")
        tid = entry.get("task_id", "")
        cond = entry.get("condition", "")
        key = (tid, cond)
        if key in seen:
            errors.append(f"Duplicate task_id+condition: {tid}/{cond}")
        seen.add(key)
    return errors


def compute_mcnemar(baseline_pass: set[str], plankton_pass: set[str], all_tasks: set[str]) -> dict:
    """Compute McNemar's test on paired binary outcomes.

    Returns: b_to_p, p_to_b, p_value, significant, odds_ratio, ci_95
    """
    b_to_p_set = (all_tasks - baseline_pass) & plankton_pass
    p_to_b_set = (all_tasks - plankton_pass) & baseline_pass
    b_to_p = len(b_to_p_set)
    p_to_b = len(p_to_b_set)
    n = b_to_p + p_to_b

    if n == 0:
        p_value = 1.0
        odds_ratio = None
        ci_95 = None
    else:
        result = binomtest(b_to_p, n, 0.5)
        p_value = result.pvalue
        odds_ratio = b_to_p / p_to_b if p_to_b > 0 else None
        ci = result.proportion_ci(method="exact")
        ci_95 = (ci.low, ci.high)

    return {
        "b_to_p": b_to_p,
        "p_to_b": p_to_b,
        "p_value": p_value,
        "significant": bool(p_value < SIGNIFICANCE_THRESHOLD),
        "odds_ratio": odds_ratio,
        "ci_95": ci_95,
    }


def load_paired_results(baseline_path: Path, plankton_path: Path) -> dict:
    """Merge baseline and plankton JSONL into {task_id: {baseline: {...}, plankton: {...}}}."""
    baseline_entries = load_jsonl(baseline_path)
    plankton_entries = load_jsonl(plankton_path)

    baseline_ids = {e["task_id"] for e in baseline_entries}
    plankton_ids = {e["task_id"] for e in plankton_entries}

    if baseline_ids != plankton_ids:
        msg = f"Mismatched task sets: {len(baseline_ids)} baseline vs {len(plankton_ids)} plankton"
        raise ValueError(msg)

    paired: dict = {}
    for entry in baseline_entries:
        paired[entry["task_id"]] = {"baseline": entry}
    for entry in plankton_entries:
        paired[entry["task_id"]]["plankton"] = entry
    return paired


def load_paired_results_from_combined(path: Path) -> dict:
    """Load a single mixed JSONL (both conditions) into paired dict.

    Each entry must have a ``condition`` field (``"baseline"`` or ``"plankton"``).
    Returns ``{task_id: {"baseline": {...}, "plankton": {...}}}``.
    """
    entries = load_jsonl(path)
    paired: dict = {}
    for entry in entries:
        if "condition" not in entry:
            msg = f"Entry missing 'condition' field: {entry.get('task_id', '<unknown>')}"
            raise ValueError(msg)
        tid = entry["task_id"]
        cond = entry["condition"]
        paired.setdefault(tid, {})[cond] = entry

    # Filter to only fully-paired entries; warn about orphans
    orphans = [tid for tid, conditions in paired.items() if set(conditions.keys()) != {"baseline", "plankton"}]
    for tid in orphans:
        _logger.warning("Orphaned task %s: missing condition(s), dropping from paired results", tid)
        del paired[tid]

    return paired


def generate_report(paired: dict, metadata: dict) -> str:
    """Generate a Markdown report with pass rates, delta, McNemar's test, seed."""
    baseline_pass = {tid for tid, d in paired.items() if d["baseline"].get("passed")}
    plankton_pass = {tid for tid, d in paired.items() if d["plankton"].get("passed")}
    all_tasks = set(paired.keys())
    total = len(all_tasks)

    b_rate = len(baseline_pass) / total if total else 0
    p_rate = len(plankton_pass) / total if total else 0
    delta = p_rate - b_rate

    mcnemar = compute_mcnemar(baseline_pass, plankton_pass, all_tasks)

    seed = metadata.get("seed", "N/A")

    lines = [
        "# SWE-bench Benchmark Report",
        "",
        "## Metadata",
        "",
        f"- **seed**: {seed}",
        f"- **model**: {metadata.get('model', 'N/A')}",
        "",
        "## Pass Rate",
        "",
        f"- baseline: {b_rate:.4f} ({len(baseline_pass)}/{total})",
        f"- plankton: {p_rate:.4f} ({len(plankton_pass)}/{total})",
        f"- delta: {delta:+.4f}",
        "",
        "## McNemar's Test",
        "",
        f"- p_value: {mcnemar['p_value']:.6f}",
        f"- significant: {mcnemar['significant']}",
        f"- fail→pass (Plankton helped): {mcnemar['b_to_p']}",
        f"- pass→fail (regressions): {mcnemar['p_to_b']}",
        f"- odds_ratio: {mcnemar['odds_ratio']}",
        f"- ci_95: {mcnemar['ci_95']}",
        "",
    ]

    return "\n".join(lines)
