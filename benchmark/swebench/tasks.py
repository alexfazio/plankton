"""Plankton SWE-bench task loading — JSONL, HuggingFace, repo checkout."""

from __future__ import annotations

import json
import shutil
import subprocess  # noqa: S404  # nosec B404
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

GIT = shutil.which("git") or "git"
_REQUIRED_FIELDS = {"instance_id", "problem_statement"}


def load_tasks_from_jsonl(path: Path) -> list[dict]:
    """Read JSONL file, validate required fields, return list of dicts."""
    tasks: list[dict] = []
    with path.open(encoding="utf-8") as f:  # noqa: PTH123
        for lineno, raw_line in enumerate(f, 1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as exc:
                msg = f"Line {lineno}: invalid JSON: {exc}"
                raise ValueError(msg) from exc
            missing = _REQUIRED_FIELDS - entry.keys()
            if missing:
                msg = f"Line {lineno}: missing required fields: {', '.join(sorted(missing))}"
                raise ValueError(msg)
            tasks.append(entry)
    return tasks


def load_tasks_from_hf(
    dataset_name: str = "princeton-nlp/SWE-bench_Lite",
    split: str = "test",
    *,
    hf_load_fn: Callable | None = None,
) -> list[dict]:
    """Load from HuggingFace datasets. Injectable hf_load_fn for tests."""
    if hf_load_fn is None:
        try:
            from datasets import load_dataset
        except ImportError:
            msg = "Install 'datasets' package: pip install datasets"
            raise ImportError(msg)  # noqa: B904
        hf_load_fn = load_dataset

    rows = hf_load_fn(dataset_name, split=split)
    return [dict(row.items()) if not isinstance(row, dict) else row for row in rows]


def select_tasks(
    tasks: list[dict],
    *,
    instance_ids: list[str] | None = None,
    difficulties: list[str] | None = None,
    n: int | None = None,
) -> list[dict]:
    """Pure filter: by IDs, then difficulty, then cap at n."""
    result = list(tasks)

    if instance_ids is not None:
        by_id = {t["instance_id"]: t for t in result}
        seen: set[str] = set()
        filtered = []
        for iid in instance_ids:
            if iid not in by_id:
                msg = f"Task not found: {iid}"
                raise KeyError(msg)
            if iid not in seen:
                seen.add(iid)
                filtered.append(by_id[iid])
        result = filtered

    if difficulties is not None:
        result = [t for t in result if t.get("difficulty") in difficulties]

    if n is not None:
        result = result[:n]

    return result


def checkout_repo(
    task: dict,
    repos_dir: Path,
    *,
    clone_fn: Callable | None = None,
    checkout_fn: Callable | None = None,
) -> dict:
    """Clone repo + checkout base_commit. Returns new task dict with repo_dir."""
    if "repo" not in task:
        msg = "Task missing required field: repo"
        raise ValueError(msg)
    if "base_commit" not in task:
        msg = "Task missing required field: base_commit"
        raise ValueError(msg)

    clone_path = repos_dir / task["repo"].replace("/", "__")

    if clone_fn is None:

        def clone_fn(repo: str, dest: Path) -> None:
            subprocess.run(  # noqa: S603 S607  # nosec B603
                [GIT, "clone", f"https://github.com/{repo}.git", str(dest)],
                check=True,
                capture_output=True,
            )

    if checkout_fn is None:

        def checkout_fn(dest: Path, commit: str) -> None:
            subprocess.run([GIT, "checkout", commit], cwd=dest, check=True, capture_output=True)  # noqa: S603  # nosec B603
            subprocess.run([GIT, "clean", "-fd"], cwd=dest, check=True, capture_output=True)  # noqa: S603  # nosec B603

    if not clone_path.exists():
        clone_fn(task["repo"], clone_path)

    checkout_fn(clone_path, task["base_commit"])

    return {**task, "repo_dir": str(clone_path)}


def prepare_tasks(
    tasks: list[dict],
    repos_dir: Path,
    *,
    checkout_fn: Callable | None = None,
) -> list[dict]:
    """Map checkout_repo over tasks."""
    if checkout_fn is None:
        for t in tasks:
            for field in ("repo", "base_commit"):
                if field not in t:
                    msg = f"Task {t.get('instance_id', '?')} missing required field: {field}"
                    raise ValueError(msg)
    if checkout_fn is not None:
        return [checkout_fn(t, repos_dir) for t in tasks]
    return [checkout_repo(t, repos_dir) for t in tasks]
