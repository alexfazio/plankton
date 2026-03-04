"""Plankton SWE-bench validation gate -- 2-task dry run with 6 criteria."""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path


@dataclass
class CriterionResult:
    """Result of a single gate criterion check."""

    name: str
    passed: bool
    detail: str


@dataclass
class GateConfig:
    """Configuration for gate execution."""

    seed: int
    model: str
    timeout: float
    results_dir: Path
    patches_dir: Path
    dry_run: bool = False
    skip_eval: bool = False


@dataclass
class GateResult:
    """Aggregate result of all gate criteria."""

    passed: bool
    criteria: list[CriterionResult]
    tasks_run: int
    wall_time_s: float
    results_dir: Path


def _iter_conditions(task_results: list[dict]):
    """Yield (task_id, condition_name, condition_data) for all conditions."""
    for task in task_results:
        for cond_name, cond_data in task["conditions"].items():
            yield task["task_id"], cond_name, cond_data


def check_no_crash_or_timeout(task_results: list[dict]) -> CriterionResult:
    """Criterion 1: no infra errors or timeouts in any condition."""
    for task_id, cond_name, cond_data in _iter_conditions(task_results):
        meta = cond_data.get("metadata", {})
        if meta.get("error_type") == "infra":
            return CriterionResult(
                name="no_crash_or_timeout",
                passed=False,
                detail=f"{task_id}/{cond_name}: infra error",
            )
        if meta.get("error") == "timeout":
            return CriterionResult(
                name="no_crash_or_timeout",
                passed=False,
                detail=f"{task_id}/{cond_name}: timeout",
            )
    return CriterionResult(name="no_crash_or_timeout", passed=True, detail="ok")


def check_patches_nonempty(task_results: list[dict]) -> CriterionResult:
    """Criterion 2: all patches are non-empty strings."""
    for task_id, cond_name, cond_data in _iter_conditions(task_results):
        patch = cond_data.get("patch", "")
        if not patch:
            return CriterionResult(
                name="patches_nonempty",
                passed=False,
                detail=f"{task_id}/{cond_name}: empty patch",
            )
    return CriterionResult(name="patches_nonempty", passed=True, detail="ok")


def check_hook_activity(task_results: list[dict]) -> CriterionResult:
    """Criterion 3: plankton condition shows hook evidence."""
    all_dry = all(
        task.get("conditions", {}).get("plankton", {}).get("metadata", {}).get("dry_run") for task in task_results
    )
    if all_dry:
        return CriterionResult(name="hook_activity", passed=True, detail="skipped (dry run)")
    for task in task_results:
        plankton = task["conditions"].get("plankton", {})
        meta = plankton.get("metadata", {})
        if meta.get("dry_run"):
            continue
        claude_output = meta.get("claude_output")
        stderr = meta.get("stderr", "")

        # Check for hook evidence (case-insensitive)
        claude_str = str(claude_output).lower() if claude_output is not None else ""
        stderr_lower = stderr.lower()
        if "posttooluse" in claude_str:
            continue
        if "hook" in stderr_lower or "linter" in stderr_lower:
            continue

        # No evidence found in this task
        if claude_output is None:
            return CriterionResult(
                name="hook_activity",
                passed=False,
                detail=f"{task['task_id']}: cannot verify: no claude_output or hook stderr",
            )
        return CriterionResult(
            name="hook_activity",
            passed=False,
            detail=f"{task['task_id']}: no hook evidence found",
        )

    return CriterionResult(name="hook_activity", passed=True, detail="ok")


def check_eval_harness_verdicts(task_results: list[dict]) -> CriterionResult:
    """Criterion 4: all passed fields are non-None."""
    missing: list[str] = []
    has_any = False
    for task_id, cond_name, cond_data in _iter_conditions(task_results):
        if cond_data.get("passed") is None:
            missing.append(f"{task_id}/{cond_name}")
        else:
            has_any = True
    if not has_any:
        return CriterionResult(
            name="eval_harness_verdicts",
            passed=False,
            detail="deferred: eval harness not run",
        )
    if missing:
        return CriterionResult(
            name="eval_harness_verdicts",
            passed=False,
            detail=f"missing verdicts: {', '.join(missing)}",
        )
    return CriterionResult(name="eval_harness_verdicts", passed=True, detail="ok")


def check_patches_differ(task_results: list[dict]) -> CriterionResult:
    """Criterion 5: at least one task has different patches between conditions."""
    for task in task_results:
        baseline_patch = task["conditions"].get("baseline", {}).get("patch", "")
        plankton_patch = task["conditions"].get("plankton", {}).get("patch", "")
        if baseline_patch != plankton_patch:
            return CriterionResult(name="patches_differ", passed=True, detail="ok")
    return CriterionResult(
        name="patches_differ",
        passed=False,
        detail="all patches identical between conditions",
    )


def check_cost_and_time(
    task_results: list[dict],
    wall_time_s: float,
    *,
    min_wall_s: float = 0,
    max_wall_s: float = 7200,
    max_cost_usd: float = 5.0,
) -> CriterionResult:
    """Criterion 6: wall time and cost within expected ranges."""
    if wall_time_s < min_wall_s:
        return CriterionResult(
            name="cost_and_time",
            passed=False,
            detail=f"wall time {wall_time_s:.0f}s below minimum {min_wall_s:.0f}s",
        )
    if wall_time_s > max_wall_s:
        return CriterionResult(
            name="cost_and_time",
            passed=False,
            detail=f"wall time {wall_time_s:.0f}s exceeds maximum {max_wall_s:.0f}s",
        )

    # Check cost if available -- pass optimistically if no cost data
    total_cost = 0.0
    has_cost = False
    for _task_id, _cond_name, cond_data in _iter_conditions(task_results):
        meta = cond_data.get("metadata", {})
        cost = meta.get("cost_usd")
        if cost is not None:
            total_cost += cost
            has_cost = True

    if has_cost and total_cost > max_cost_usd:
        return CriterionResult(
            name="cost_and_time",
            passed=False,
            detail=f"total cost ${total_cost:.2f} exceeds ${max_cost_usd:.2f}",
        )

    return CriterionResult(name="cost_and_time", passed=True, detail="ok")


def run_gate(
    tasks: list[dict],
    config: GateConfig,
    *,
    run_task_fn: Callable[..., dict[str, Any]] | None = None,
    wall_clock_fn: Callable[[], float] | None = None,
    expected_ranges: dict | None = None,
) -> GateResult:
    """Run tasks through both conditions, check 6 criteria.

    When *dry_run* is True it is forwarded to run_task_fn so the claude
    subprocess is not invoked.  When *skip_eval* is True criterion 4
    (eval_harness_verdicts) is marked as skipped rather than evaluated,
    allowing the gate to pass without an evaluation harness installed.
    """
    if not tasks:
        msg = "tasks list is empty — nothing to validate"
        raise ValueError(msg)

    if wall_clock_fn is None:
        wall_clock_fn = time.monotonic

    if run_task_fn is None:
        from benchmark.swebench.runner import run_task

        run_task_fn = run_task

    start = wall_clock_fn()

    task_results = []
    for task in tasks:
        result = run_task_fn(
            task,
            seed=config.seed,
            model=config.model,
            timeout=int(config.timeout),
            results_dir=config.results_dir,
            patches_dir=config.patches_dir,
            dry_run=config.dry_run,
        )
        task_results.append(result)

    wall_time_s = wall_clock_fn() - start

    # Build cost/time kwargs from expected_ranges
    cost_kwargs: dict[str, Any] = {}
    if expected_ranges:
        for key in ("min_wall_s", "max_wall_s", "max_cost_usd"):
            if key in expected_ranges:
                cost_kwargs[key] = expected_ranges[key]

    if config.skip_eval:
        eval_criterion = CriterionResult(
            name="eval_harness_verdicts",
            passed=True,
            detail="skipped (no eval harness)",
        )
    else:
        eval_criterion = check_eval_harness_verdicts(task_results)

    criteria = [
        check_no_crash_or_timeout(task_results),
        check_patches_nonempty(task_results),
        check_hook_activity(task_results),
        eval_criterion,
        check_patches_differ(task_results),
        check_cost_and_time(task_results, wall_time_s, **cost_kwargs),
    ]

    return GateResult(
        passed=all(c.passed for c in criteria),
        criteria=criteria,
        tasks_run=len(task_results),
        wall_time_s=wall_time_s,
        results_dir=config.results_dir,
    )


def format_gate_report(result: GateResult) -> str:
    """Human-readable gate report string."""
    header = "PASS" if result.passed else "FAIL"
    lines = [
        f"Gate: {header}",
        f"Tasks run: {result.tasks_run}",
        f"Wall time: {result.wall_time_s:.1f}s",
        f"Results: {result.results_dir}",
        "",
    ]
    for c in result.criteria:
        status = "PASS" if c.passed else "FAIL"
        line = f"  [{status}] {c.name}"
        if not c.passed:
            line += f" -- {c.detail}"
        lines.append(line)

    return "\n".join(lines)
