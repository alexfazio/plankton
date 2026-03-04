"""Plankton SWE-bench A/B runner — coin flip, hook injection, abort criteria."""

from __future__ import annotations

import json
import random
import shutil
import subprocess  # noqa: S404  # nosec B404
from collections.abc import Callable  # noqa: TC003
from pathlib import Path
from typing import Any, cast

GIT = shutil.which("git") or "git"
PLANKTON_ROOT = Path(__file__).resolve().parent.parent.parent  # repo root

# Abort thresholds (from ADR)
_INFRA_ERROR_THRESHOLD = 0.20
_CONSECUTIVE_EMPTY_THRESHOLD = 10
_SUSTAINED_429_THRESHOLD = 600  # seconds
_REQUIRED_CONDITIONS = 2  # baseline + plankton


def flip_order(task_id: str, seed: int) -> tuple[str, str]:
    """Seeded coin flip: returns ("baseline", "plankton") or reverse."""
    rng = random.Random(f"{seed}:{task_id}")  # noqa: S311  # nosec B311
    if rng.random() < 0.5:  # noqa: PLR2004
        return ("baseline", "plankton")
    return ("plankton", "baseline")


def reset_repo(repo_dir: Path) -> None:
    """Reset repo: git checkout . && git clean -fd."""
    subprocess.run([GIT, "checkout", "."], cwd=repo_dir, capture_output=True, check=True)  # noqa: S603  # nosec B603
    subprocess.run([GIT, "clean", "-fd"], cwd=repo_dir, capture_output=True, check=True)  # noqa: S603  # nosec B603


_INJECT_FILES = [".ruff.toml", "ty.toml", ".claude/subprocess-settings.json"]


def inject_hooks(task_dir: Path, plankton_root: Path = PLANKTON_ROOT) -> None:
    """Copy Plankton hooks + linter configs into task repo."""
    src_hooks = plankton_root / ".claude" / "hooks"
    if not src_hooks.is_dir():
        detail = "exists but is not a directory" if src_hooks.exists() else "not found"
        msg = f"Hooks source directory {detail}: {src_hooks}"
        raise FileNotFoundError(msg)
    dst_hooks = task_dir / ".claude" / "hooks"
    dst_hooks.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src_hooks, dst_hooks, dirs_exist_ok=True)
    for fname in _INJECT_FILES:
        src = plankton_root / fname
        if src.exists():
            dst = task_dir / fname
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)


def remove_hooks(task_dir: Path) -> None:
    """Remove injected hooks and configs from task repo."""
    hooks_dir = task_dir / ".claude" / "hooks"
    if hooks_dir.exists():
        shutil.rmtree(hooks_dir)
    for fname in _INJECT_FILES:
        p = task_dir / fname
        if p.exists():
            p.unlink()
    # Clean up empty .claude/ directory
    claude_dir = task_dir / ".claude"
    if claude_dir.exists() and claude_dir.is_dir() and not any(claude_dir.iterdir()):
        claude_dir.rmdir()


def append_result(  # noqa: PLR0913
    path: Path,
    *,
    task_id: str,
    condition: str,
    passed: bool | None,
    patch: str,
    metadata: dict,
) -> None:
    """Append one JSON line to JSONL results file.

    ``passed`` is populated by the evaluation harness post-run, not by solve().
    During the benchmark run it will typically be None.
    """
    record = {
        "task_id": task_id,
        "condition": condition,
        "passed": passed,
        "patch": patch,
        "metadata": metadata,
    }
    with open(path, "a", encoding="utf-8") as f:  # noqa: PTH123
        f.write(json.dumps(record) + "\n")


def save_patch(
    patches_dir: Path,
    *,
    task_id: str,
    condition: str,
    patch: str,
) -> None:
    """Save patch as {task_id}_{condition}.patch (slashes replaced with __)."""
    safe_id = task_id.replace("/", "__")
    patches_dir.mkdir(parents=True, exist_ok=True)
    (patches_dir / f"{safe_id}_{condition}.patch").write_text(patch, encoding="utf-8")


def check_abort_criteria(stats: dict) -> tuple[bool, str | None]:
    """Check abort thresholds per ADR mid-run criteria."""
    total = stats.get("total_completed", 0)
    if total > 0 and stats.get("infra_errors", 0) / total > _INFRA_ERROR_THRESHOLD:
        rate = stats["infra_errors"] / total
        return True, f"Infra error rate {rate:.0%} exceeds 20% threshold"
    if stats.get("consecutive_empty", 0) >= _CONSECUTIVE_EMPTY_THRESHOLD:
        count = stats["consecutive_empty"]
        return True, f"Consecutive empty patches: {count} (threshold {_CONSECUTIVE_EMPTY_THRESHOLD})"
    if stats.get("sustained_429_seconds", 0) >= _SUSTAINED_429_THRESHOLD:
        return True, f"Sustained 429 for {stats['sustained_429_seconds']}s (threshold {_SUSTAINED_429_THRESHOLD}s)"
    return False, None


def run_task(  # noqa: PLR0913
    task: dict,
    *,
    seed: int,
    model: str,
    timeout: int,
    results_dir: Path,
    patches_dir: Path,
    plankton_root: Path = PLANKTON_ROOT,
    solve_fn: Callable[..., dict[str, Any]] | None = None,
    reset_fn: Callable[..., None] | None = None,
    inject_fn: Callable[..., None] | None = None,
    remove_fn: Callable[..., None] | None = None,
    dry_run: bool = False,
) -> dict:
    """Run one task in both conditions. Returns summary dict."""
    from benchmark.swebench.agent import solve as _default_solve

    do_solve = solve_fn or _default_solve
    do_reset = reset_fn or reset_repo
    do_inject = inject_fn or inject_hooks
    do_remove = remove_fn or remove_hooks

    task_id = task["instance_id"]
    task_dir = Path(task["repo_dir"])
    first, second = flip_order(task_id, seed)
    results_file = results_dir / "results.jsonl"
    results_dir.mkdir(parents=True, exist_ok=True)
    patches_dir.mkdir(parents=True, exist_ok=True)

    summaries: dict[str, dict] = {}

    for i, condition in enumerate((first, second)):
        if i > 0:
            do_reset(task_dir)

        if condition == "plankton":
            do_inject(task_dir, plankton_root=plankton_root)

        try:
            result = do_solve(task, condition=condition, model=model, timeout=timeout, dry_run=dry_run)
        except Exception as exc:  # noqa: BLE001
            import logging as _logging

            _logging.getLogger(__name__).warning(
                "solve raised for task %s condition %s: %s",
                task_id,
                condition,
                exc,
            )
            result = {
                "patch": "",
                "condition": condition,
                "passed": None,
                "metadata": {"error": str(exc), "error_type": "infra"},
            }

        if condition == "plankton":
            do_remove(task_dir)

        patch = cast("str", result.get("patch", ""))
        passed = cast("bool | None", result.get("passed"))
        metadata = cast("dict", result.get("metadata", {}))

        append_result(results_file, task_id=task_id, condition=condition, passed=passed, patch=patch, metadata=metadata)
        save_patch(patches_dir, task_id=task_id, condition=condition, patch=patch)
        summaries[condition] = {"patch": patch, "passed": passed, "metadata": metadata}

    return {"task_id": task_id, "conditions": summaries}


def run_all(  # noqa: PLR0913
    tasks: list[dict],
    *,
    seed: int,
    model: str,
    timeout: int,
    results_dir: Path,
    patches_dir: Path,
    plankton_root: Path = PLANKTON_ROOT,
    run_task_fn: Callable[..., dict[str, Any]] | None = None,
    completed_ids: set[str] | None = None,
    dry_run: bool = False,
) -> dict:
    """Run all tasks. Returns {"aborted": bool, "tasks_completed": int, ...}."""
    # Safety check: CLAUDE.md must be backed up before benchmark runs
    if (plankton_root / "CLAUDE.md").exists():
        raise RuntimeError("CLAUDE.md exists — rename it to CLAUDE.md.bak before running the benchmark")  # noqa: TRY003

    do_run_task = run_task_fn or run_task
    done_ids = completed_ids or set()
    tasks_skipped = 0

    stats = {
        "infra_errors": 0,
        "total_completed": 0,
        "consecutive_empty": 0,
        "sustained_429_seconds": 0,
    }
    aborted = False
    abort_reason = None

    for task in tasks:
        if task["instance_id"] in done_ids:
            tasks_skipped += 1
            continue
        try:
            result = do_run_task(
                task,
                seed=seed,
                model=model,
                timeout=timeout,
                results_dir=results_dir,
                patches_dir=patches_dir,
                plankton_root=plankton_root,
                dry_run=dry_run,
            )
        except Exception:
            import logging

            logging.getLogger(__name__).warning(
                "Task %s failed with exception",
                task["instance_id"],
                exc_info=True,
            )
            result = {
                "conditions": {
                    "_error": {"patch": "<exception>", "passed": None, "metadata": {"error_type": "infra"}},
                },
            }
        stats["total_completed"] += 1

        conditions = result.get("conditions", {})
        both_empty = all(not c.get("patch", "") for c in conditions.values())
        if both_empty:
            stats["consecutive_empty"] += 1
        else:
            stats["consecutive_empty"] = 0

        # Track infra errors (only error_type=="infra", not empty patches/test failures)
        dict_conditions: list[dict[str, Any]] = [v for v in conditions.values() if isinstance(v, dict)]
        for cond_data in dict_conditions:
            if cond_data.get("metadata", {}).get("error_type") == "infra":
                stats["infra_errors"] += 1
                break

        # Track sustained 429s (best-effort heuristic from stderr)
        has_429 = any(
            "429" in str(cond_data.get("metadata", {}).get("stderr", ""))
            or "rate limit" in str(cond_data.get("metadata", {}).get("stderr", "")).lower()
            for cond_data in dict_conditions
        )
        if has_429:
            # Approximate: use elapsed_s from metadata if available, else default 60s
            elapsed = max(
                (cond_data.get("metadata", {}).get("elapsed_s", 60) for cond_data in dict_conditions),
                default=60,
            )
            stats["sustained_429_seconds"] += int(elapsed)
        else:
            stats["sustained_429_seconds"] = 0

        should_abort, reason = check_abort_criteria(stats)
        if should_abort:
            aborted = True
            abort_reason = reason
            break

    return {
        "aborted": aborted,
        "abort_reason": abort_reason,
        "tasks_completed": stats["total_completed"],
        "tasks_skipped": tasks_skipped,
        "seed": seed,
        "model": model,
        "timeout": timeout,
    }


def load_completed_ids(results_dir: Path) -> set[str]:
    """Load task IDs that have both baseline and plankton results from JSONL file."""
    results_file = results_dir / "results.jsonl"
    if not results_file.exists():
        return set()

    task_conditions: dict[str, set[str]] = {}
    with open(results_file, encoding="utf-8") as f:  # noqa: PTH123
        for line in f:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                import logging

                logging.getLogger(__name__).warning("Skipping malformed JSONL line: %s", line.strip()[:100])
                continue
            task_id = record.get("task_id")
            condition = record.get("condition")
            if task_id and condition:
                if task_id not in task_conditions:
                    task_conditions[task_id] = set()
                task_conditions[task_id].add(condition)

    return {task_id for task_id, conditions in task_conditions.items() if conditions >= {"baseline", "plankton"}}
