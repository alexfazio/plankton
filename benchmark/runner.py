"""Plankton Benchmark Runner — EvalPlus HumanEval+ A/B testing.

Runs EvalPlus HumanEval+ tasks through Claude Code in two conditions:
  A (baseline): no hooks via cc -bare
  B (plankton): hooks active via standard claude CLI

Produces JSONL files consumable by evalplus.evaluate.
"""

import argparse
import json
import os
import shutil
import subprocess  # noqa: S404  # nosec B404
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent
PROMPT_TEMPLATE = (SCRIPT_DIR / "prompt_template.txt").read_text().strip()

GIT = shutil.which("git") or "git"
CLAUDE = shutil.which("claude") or "claude"
ALLOWED_TOOLS = "Edit,Read,Write,Bash,Glob,Grep"
DISALLOWED_TOOLS = ""

HUMANEVAL_TASK_COUNT = 164
CLASSEVAL_TASK_COUNT = 20
CLASSEVAL_DATA = SCRIPT_DIR / "ClassEval_data.json"
CLASSEVAL_PROMPT_TEMPLATE = (SCRIPT_DIR / "classeval_prompt_template.txt").read_text().strip()


def get_classeval_tasks(data_path: Path = CLASSEVAL_DATA, limit: int | None = None) -> dict[str, dict]:
    """Load ClassEval tasks from JSON file, keyed by task_id."""
    with open(data_path, encoding="utf-8") as f:
        raw = json.load(f)
    tasks = {t["task_id"]: t for t in raw}
    if limit:
        task_ids = sorted(tasks.keys())[:limit]
        tasks = {tid: tasks[tid] for tid in task_ids}
    return tasks


def get_tasks(limit: int | None = None) -> dict:
    """Load HumanEval+ tasks from evalplus."""
    from evalplus.data import get_human_eval_plus

    tasks = get_human_eval_plus()
    if limit:
        task_ids = sorted(tasks.keys())[:limit]
        tasks = {tid: tasks[tid] for tid in task_ids}
    return tasks


def write_class_skeleton(task: dict, dest: Path) -> str:
    """Write class skeleton (imports + skeleton) to solution.py.

    Returns the full written content string.
    """
    import_stmt = task.get("import_statement", [])
    skeleton = task["skeleton"]
    parts = []
    if import_stmt:
        if isinstance(import_stmt, list):
            parts.extend(import_stmt)
        else:
            parts.extend(import_stmt.strip().splitlines())
    parts.extend(("", skeleton))
    content = "\n".join(parts)
    (dest / "solution.py").write_text(content)
    return content


def write_stub(task: dict, dest: Path) -> str:
    """Write function stub (signature + docstring + pass) to solution.py.

    Returns the prompt prefix used for completion extraction.
    """
    prompt = task["prompt"]
    stub = prompt + "    pass\n"
    (dest / "solution.py").write_text(stub)
    return prompt


def _git_init(work_dir: Path) -> None:
    """Initialize a git repo with an initial commit."""
    subprocess.run(  # noqa: S603  # nosec B603
        [GIT, "init", "--quiet"], cwd=work_dir, capture_output=True, check=False
    )


def _git_commit(work_dir: Path, *, allow_empty: bool = False) -> None:
    """Stage all files and commit."""
    subprocess.run(  # noqa: S603  # nosec B603
        [GIT, "add", "."], cwd=work_dir, capture_output=True, check=False
    )
    cmd = [GIT, "commit", "--quiet", "-m", "init"]
    if allow_empty:
        cmd.append("--allow-empty")
    subprocess.run(  # noqa: S603  # nosec B603
        cmd, cwd=work_dir, capture_output=True, check=False
    )


def _build_cmd(condition: str, model: str, prompt: str = PROMPT_TEMPLATE) -> list[str]:
    """Build the claude -p command for a given condition."""
    if condition == "baseline":
        return [
            CLAUDE,
            "--setting-sources",
            "",
            "--settings",
            os.path.expanduser("~/.claude/bare-settings.json"),
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--allowedTools",
            ALLOWED_TOOLS,
            "-p",
            "--output-format",
            "json",
            "--dangerously-skip-permissions",
            "--model",
            model,
            prompt,
        ]
    return [
        CLAUDE,
        "--allowedTools",
        ALLOWED_TOOLS,
        "-p",
        "--output-format",
        "json",
        "--dangerously-skip-permissions",
        "--model",
        model,
        prompt,
    ]


def run_condition(  # noqa: PLR0913
    condition: str,
    work_dir: Path,
    model: str,
    timeout: int,
    *,
    dry_run: bool = False,
    prompt: str = PROMPT_TEMPLATE,
) -> tuple[str, dict]:
    """Run claude -p for one condition. Returns (code_output, metadata)."""
    cmd = _build_cmd(condition, model, prompt)

    if dry_run:
        print(f"  [DRY RUN] {condition}: {' '.join(cmd)}")
        print(f"  [DRY RUN] cwd: {work_dir}")
        return "", {}

    print(f"  Running {condition}...", end=" ", flush=True)
    start = time.time()

    # Unset CLAUDECODE to allow nested claude -p invocations
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

    try:
        result = subprocess.run(  # noqa: S603  # nosec B603
            cmd,
            cwd=work_dir,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
        elapsed = time.time() - start
        print(f"done ({elapsed:.1f}s)")

        metadata = _parse_claude_output(result, elapsed)
        solution_path = work_dir / "solution.py"
        if solution_path.exists():
            return solution_path.read_text(), metadata
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        print(f"TIMEOUT ({elapsed:.1f}s)")
        return "", {"error": "timeout", "elapsed_s": round(elapsed, 1)}
    except Exception as e:
        print(f"ERROR: {e}")
        return "", {"error": str(e)}
    else:
        return "", metadata


def _parse_claude_output(result: subprocess.CompletedProcess[str], elapsed: float) -> dict:
    """Extract metadata from a claude -p subprocess result."""
    metadata: dict = {"returncode": result.returncode, "elapsed_s": round(elapsed, 1)}
    try:
        metadata["claude_output"] = json.loads(result.stdout)
    except (json.JSONDecodeError, ValueError):
        metadata["raw_stdout"] = result.stdout[:2000]
    if result.stderr:
        metadata["stderr"] = result.stderr[:2000]
    return metadata


def extract_completion(full_code: str, prompt: str) -> str:
    """Extract the completion (code after the prompt prefix).

    EvalPlus expects just the completion, not the full code.
    """
    if full_code.startswith(prompt):
        return full_code[len(prompt) :]
    return full_code


def setup_plankton_workdir(task: dict) -> Path:
    """Write stub into the plankton repo root so hooks fire naturally.

    No copies needed — .claude/hooks/ and linter configs are already
    present. Returns REPO_ROOT as work_dir.
    """
    write_stub(task, REPO_ROOT)
    return REPO_ROOT


def setup_baseline_workdir(task: dict, task_id: str) -> Path:
    """Create a minimal working directory for baseline (no hooks)."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"baseline_{task_id.replace('/', '_')}_"))
    _git_init(work_dir)
    write_stub(task, work_dir)
    _git_commit(work_dir)
    return work_dir


def append_jsonl(path: Path, task_id: str, completion: str) -> None:
    """Append one entry to a JSONL file."""
    entry = {"task_id": task_id, "completion": completion}
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def append_classeval_jsonl(path: Path, task_id: str, code: str) -> None:
    """Append one ClassEval entry to a JSONL file."""
    entry = {"task_id": task_id, "predict": [code]}
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def _get_completed_tasks(baseline_jsonl: Path, plankton_jsonl: Path) -> set[str]:
    """Return task_ids completed in BOTH JSONL files (for --resume)."""
    if not baseline_jsonl.exists() or not plankton_jsonl.exists():
        return set()

    def _load_task_ids(path: Path) -> set[str]:
        ids: set[str] = set()
        for line in path.read_text(encoding="utf-8").strip().splitlines():
            if line.strip():
                ids.add(json.loads(line)["task_id"])
        return ids

    return _load_task_ids(baseline_jsonl) & _load_task_ids(plankton_jsonl)


def run_evalplus(samples_path: Path, mini: bool) -> dict:
    """Run evalplus.evaluate on a JSONL samples file."""
    wrapper = str(SCRIPT_DIR / "evalplus_wrapper.py")
    cmd = [
        sys.executable,
        wrapper,
        "--dataset",
        "humaneval",
        "--samples",
        str(samples_path),
        "--i-just-wanna-run",
    ]
    if mini:
        cmd.append("--mini")

    print(f"\n  evalplus: {' '.join(cmd)}")
    result = subprocess.run(  # noqa: S603  # nosec B603
        cmd,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def run_classeval(samples_path: Path, data_path: Path = CLASSEVAL_DATA) -> dict:
    """Run ClassEval evaluation on a JSONL samples file."""
    wrapper = str(SCRIPT_DIR / "classeval_wrapper.py")
    cmd = [sys.executable, wrapper, str(samples_path), str(data_path)]

    print(f"\n  classeval: {' '.join(cmd)}")
    result = subprocess.run(  # noqa: S603  # nosec B603
        cmd,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def _build_metadata(args: argparse.Namespace, task_count: int) -> dict:
    """Build run metadata dict."""
    cc_version = subprocess.run(  # noqa: S603  # nosec B603
        [CLAUDE, "-v"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return {
        "claude_code_version": cc_version,
        "model": args.model,
        "task_count": task_count,
        "mini": args.mini,
        "timeout": args.timeout,
        "start_time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


def _setup_classeval_baseline_workdir(task: dict, task_id: str) -> Path:
    """Create a minimal working directory for classeval baseline (no hooks)."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"baseline_{task_id.replace('/', '_')}_"))
    _git_init(work_dir)
    write_class_skeleton(task, work_dir)
    _git_commit(work_dir)
    return work_dir


def _setup_classeval_plankton_workdir(task: dict) -> Path:
    """Write class skeleton into the plankton repo root so hooks fire naturally."""
    write_class_skeleton(task, REPO_ROOT)
    return REPO_ROOT


def _run_task(  # noqa: PLR0914
    task_id: str,
    task: dict,
    args: argparse.Namespace,
    output_files: tuple[Path, Path, Path],
    *,
    benchmark: str = "evalplus",
) -> None:
    """Run both conditions for a single task."""
    baseline_jsonl, plankton_jsonl, logs_dir = output_files
    is_classeval = benchmark == "classeval"

    if is_classeval:
        prompt_text = CLASSEVAL_PROMPT_TEMPLATE
        baseline_dir = _setup_classeval_baseline_workdir(task, task_id)
        plankton_setup = _setup_classeval_plankton_workdir
    else:
        prompt_text = PROMPT_TEMPLATE
        baseline_dir = setup_baseline_workdir(task, task_id)
        plankton_setup = setup_plankton_workdir

    baseline_code, baseline_meta = run_condition(
        "baseline",
        baseline_dir,
        args.model,
        args.timeout,
        dry_run=args.dry_run,
        prompt=prompt_text,
    )

    baseline_completion = baseline_code if is_classeval else extract_completion(baseline_code, task["prompt"])

    if not args.dry_run:
        if is_classeval:
            append_classeval_jsonl(baseline_jsonl, task_id, baseline_completion)
        else:
            append_jsonl(baseline_jsonl, task_id, baseline_completion)

    plankton_dir = plankton_setup(task)
    plankton_code, plankton_meta = run_condition(
        "plankton",
        plankton_dir,
        args.model,
        args.timeout,
        dry_run=args.dry_run,
        prompt=prompt_text,
    )

    plankton_completion = plankton_code if is_classeval else extract_completion(plankton_code, task["prompt"])

    if not args.dry_run:
        if is_classeval:
            append_classeval_jsonl(plankton_jsonl, task_id, plankton_completion)
        else:
            append_jsonl(plankton_jsonl, task_id, plankton_completion)
        task_log = {"task_id": task_id, "baseline": baseline_meta, "plankton": plankton_meta}
        log_file = logs_dir / f"{task_id.replace('/', '_')}.json"
        log_file.write_text(json.dumps(task_log, indent=2))

    shutil.rmtree(baseline_dir, ignore_errors=True)
    # plankton_dir is REPO_ROOT — clean up only the stub file
    (plankton_dir / "solution.py").unlink(missing_ok=True)


def _evaluate_and_report(
    results_dir: Path,
    baseline_jsonl: Path,
    plankton_jsonl: Path,
    mini: bool,
    benchmark: str = "evalplus",
) -> None:
    """Run evaluator on both conditions, parse results, and generate report."""
    from analyze import generate_report, load_jsonl, parse_evalplus_stdout, validate_jsonl

    is_classeval = benchmark == "classeval"
    expected = CLASSEVAL_TASK_COUNT if is_classeval else HUMANEVAL_TASK_COUNT
    label_name = "ClassEval" if is_classeval else "EvalPlus"

    print(f"\n=== {label_name} Evaluation ===")

    # Validate JSONL files before evaluation
    for label, path in [("baseline", baseline_jsonl), ("plankton", plankton_jsonl)]:
        entries = load_jsonl(path)
        errors = validate_jsonl(entries, expected_count=expected)
        if errors:
            print(f"\n  WARNING: {label} JSONL validation errors:")
            for err in errors:
                print(f"    - {err}")

    if is_classeval:
        print("\nBaseline:")
        baseline_eval = run_classeval(baseline_jsonl)
        print(baseline_eval["stdout"])
        if baseline_eval["stderr"]:
            print(baseline_eval["stderr"])

        print("\nPlankton:")
        plankton_eval = run_classeval(plankton_jsonl)
        print(plankton_eval["stdout"])
        if plankton_eval["stderr"]:
            print(plankton_eval["stderr"])
    else:
        print("\nBaseline:")
        baseline_eval = run_evalplus(baseline_jsonl, mini)
        print(baseline_eval["stdout"])
        if baseline_eval["stderr"]:
            print(baseline_eval["stderr"])

        print("\nPlankton:")
        plankton_eval = run_evalplus(plankton_jsonl, mini)
        print(plankton_eval["stdout"])
        if plankton_eval["stderr"]:
            print(plankton_eval["stderr"])

    # Save raw output for debugging
    eval_raw = {"baseline": baseline_eval, "plankton": plankton_eval}
    (results_dir / "eval_raw.json").write_text(json.dumps(eval_raw, indent=2))

    # Parse pass rates and save structured results
    eval_results = {
        "baseline": parse_evalplus_stdout(baseline_eval["stdout"]),
        "plankton": parse_evalplus_stdout(plankton_eval["stdout"]),
    }
    (results_dir / "eval_results.json").write_text(json.dumps(eval_results, indent=2))

    # Generate and save report
    report = generate_report(results_dir)
    (results_dir / "REPORT.md").write_text(report)
    print(report)


def _load_tasks(args: argparse.Namespace) -> tuple[dict, int]:
    is_classeval = args.benchmark == "classeval"
    if is_classeval and args.mini:
        print("WARNING: --mini is not applicable to classeval, ignoring")
    if is_classeval:
        print(f"Loading ClassEval tasks (limit={args.tasks})...")
        tasks = get_classeval_tasks(limit=args.tasks)
    else:
        print(f"Loading HumanEval+ tasks (limit={args.tasks})...")
        tasks = get_tasks(args.tasks)
    print(f"Loaded {len(tasks)} tasks")
    task_count = CLASSEVAL_TASK_COUNT if is_classeval else HUMANEVAL_TASK_COUNT
    return tasks, task_count


def _print_progress(tasks_done: int, run_start: float, total_tasks: int, current_index: int) -> None:
    avg = (time.time() - run_start) / tasks_done
    remaining_tasks = total_tasks - current_index
    eta_min = (avg * remaining_tasks) / 60
    print(f"  Progress: {tasks_done} done, avg {avg:.0f}s/task, ~{eta_min:.0f}min remaining")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Plankton Benchmark Runner")
    parser.add_argument("--tasks", type=int, default=None, help="Limit to first N tasks")
    parser.add_argument("--mini", action="store_true", help="Use HumanEval+ Mini (fewer tests)")
    parser.add_argument("--model", default="claude-haiku-4-5-20251001", help="Model ID")
    parser.add_argument("--results-dir", default=str(SCRIPT_DIR / "results"), help="Output directory")
    parser.add_argument("--timeout", type=int, default=300, help="Timeout per task (seconds)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument("--skip-eval", action="store_true", help="Skip evalplus evaluation")
    parser.add_argument("--resume", action="store_true", help="Skip tasks already in JSONL files")
    parser.add_argument(
        "--benchmark",
        choices=["evalplus", "classeval"],
        default="evalplus",
        help="Benchmark suite to run (default: evalplus)",
    )
    return parser


def main() -> None:  # noqa: PLR0912
    """Run the Plankton benchmark suite."""
    args = _build_parser().parse_args()

    results_dir = Path(args.results_dir)
    samples_dir = results_dir / "samples"
    logs_dir = results_dir / "logs"
    samples_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    if (REPO_ROOT / "CLAUDE.md").exists() and not args.dry_run:
        print("WARNING: CLAUDE.md still exists. Rename to CLAUDE.md.bak before benchmark runs.")
        print("  mv CLAUDE.md CLAUDE.md.bak")
        sys.exit(1)

    tasks, task_count = _load_tasks(args)

    baseline_jsonl = samples_dir / "baseline.jsonl"
    plankton_jsonl = samples_dir / "plankton.jsonl"

    if args.resume:
        completed = _get_completed_tasks(baseline_jsonl, plankton_jsonl)
        print(f"Resuming: {len(completed)} tasks already completed, skipping them")
    else:
        completed = set()
        baseline_jsonl.unlink(missing_ok=True)
        plankton_jsonl.unlink(missing_ok=True)

    metadata = _build_metadata(args, len(tasks))

    task_ids = sorted(tasks.keys())
    run_start = time.time()
    tasks_done = 0
    for i, task_id in enumerate(task_ids, 1):
        if task_id in completed:
            print(f"\n[{i}/{len(task_ids)}] {task_id} — SKIPPED (resume)")
            continue
        print(f"\n[{i}/{len(task_ids)}] {task_id}")
        _run_task(
            task_id,
            tasks[task_id],
            args,
            (baseline_jsonl, plankton_jsonl, logs_dir),
            benchmark=args.benchmark,
        )
        tasks_done += 1
        _print_progress(tasks_done, run_start, len(task_ids), i)

    metadata["end_time"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if not args.dry_run:
        (results_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))

    if not args.dry_run and not args.skip_eval:
        if args.tasks and args.tasks < task_count:
            print(f"\n  Skipping eval (partial run: {args.tasks}/{task_count} tasks)")
            print("  Run without --tasks for full evaluation")
        else:
            _evaluate_and_report(results_dir, baseline_jsonl, plankton_jsonl, args.mini, args.benchmark)

    print("\n=== Benchmark Complete ===")
    print(f"Results: {results_dir}")


if __name__ == "__main__":
    main()
