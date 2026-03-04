"""HAL harness adapter — bridges HAL's run() API to Plankton's solve()."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from benchmark.swebench.agent import solve
from benchmark.swebench.runner import PLANKTON_ROOT, inject_hooks, remove_hooks

logger = logging.getLogger(__name__)

_VALID_CONDITIONS = {"baseline", "plankton"}


def run(input: dict[str, dict], **kwargs) -> dict[str, str]:  # noqa: A002
    """HAL-compatible entry point.

    Invoke via: hal-eval --agent_function hal_adapter.run -A condition=plankton

    Args:
        input: {instance_id: task_data_dict} from HAL harness.
        **kwargs: HAL agent args (-A flags). Recognized keys:
            condition: "baseline" or "plankton" (default: "plankton")
            model: model ID (default: $SWEBENCH_MODEL or claude-haiku-4-5-20251001)
            timeout: seconds per task (default: 1800)
            results_dir: optional path for metadata JSONL side-channel

    Returns:
        {instance_id: patch_string} for HAL evaluation.
    """
    condition = kwargs.get("condition", "plankton")
    if condition not in _VALID_CONDITIONS:
        msg = f"invalid condition: {condition!r}, must be one of {_VALID_CONDITIONS}"
        raise ValueError(msg)

    model = kwargs.get("model")
    timeout = int(kwargs.get("timeout", 1800))
    results_dir = kwargs.get("results_dir")

    results: dict[str, str] = {}
    for instance_id, task_data in input.items():
        patch, metadata = _run_instance(instance_id, task_data, condition=condition, model=model, timeout=timeout)
        results[instance_id] = patch
        if results_dir:
            try:
                _write_metadata(results_dir, instance_id=instance_id, condition=condition, metadata=metadata)
            except Exception:
                logger.exception("_write_metadata() failed for %s", instance_id)
    return results


def _run_instance(
    instance_id: str,
    task_data: dict,
    *,
    condition: str,
    model: str | None,
    timeout: int,
) -> tuple[str, dict]:
    if "problem_statement" not in task_data:
        msg = f"task {instance_id!r} missing required field 'problem_statement'"
        raise ValueError(msg)

    task_dict = {**task_data, "instance_id": instance_id}
    if "repo_dir" not in task_dict:
        task_dict["repo_dir"] = str(Path.cwd())

    repo_dir = Path(task_dict["repo_dir"])

    if condition == "plankton":
        inject_hooks(repo_dir, plankton_root=PLANKTON_ROOT)

    try:
        result = solve(task_dict, condition=condition, model=model, timeout=timeout)
        return result.get("patch", ""), result.get("metadata", {})
    except Exception:
        logger.exception("solve() failed for %s", instance_id)
        return "", {"error": "solve_exception"}
    finally:
        if condition == "plankton":
            try:
                remove_hooks(repo_dir)
            except Exception:
                logger.exception("remove_hooks() failed for %s", instance_id)


def _write_metadata(
    results_dir: str,
    *,
    instance_id: str,
    condition: str,
    metadata: dict,
) -> None:
    """Append one metadata record to hal_metadata.jsonl."""
    out_dir = Path(results_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    record = {**metadata, "instance_id": instance_id, "condition": condition}
    with open(out_dir / "hal_metadata.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
