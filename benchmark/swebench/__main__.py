"""CLI entry point: python -m benchmark.swebench {gate,run}."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _build_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser with gate and run subcommands."""
    parser = argparse.ArgumentParser(prog="benchmark.swebench", description="Plankton SWE-bench benchmark")
    sub = parser.add_subparsers(dest="subcommand", required=True)

    def _add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--tasks-jsonl", type=Path, help="Load tasks from local JSONL")
        p.add_argument("--tasks-hf", default="princeton-nlp/SWE-bench_Lite", help="HuggingFace dataset name")
        p.add_argument("--instance-ids", nargs="+", help="Select specific task IDs")
        p.add_argument("--difficulties", nargs="+", help="Filter by difficulty")
        p.add_argument("--repos-dir", type=Path, required=True, help="Directory for repo checkouts")
        p.add_argument("--results-dir", type=Path, default=Path("gate_results"), help="Output directory")
        p.add_argument("--seed", type=int, default=42)
        p.add_argument("--model", default="claude-haiku-4-5-20251001")
        p.add_argument("--timeout", type=int, default=1800)
        p.add_argument("--no-checkout", action="store_true", help="Skip repo checkout")
        p.add_argument("--dry-run", action="store_true", help="Print commands without invoking claude")

    gate_p = sub.add_parser("gate", help="Validation gate (2-task dry run)")
    _add_common(gate_p)
    gate_p.add_argument("--skip-eval", action="store_true", help="Skip criterion 4 (eval harness verdicts)")

    run_p = sub.add_parser("run", help="Full benchmark run")
    _add_common(run_p)
    run_p.add_argument("--resume", action="store_true", help="Resume from completed tasks")

    prereqs_p = sub.add_parser("prereqs", help="Run Phase 0 prerequisite checks")
    prereqs_p.add_argument("--full", action="store_true", default=False, help="Include live API checks")

    return parser


def _load_and_prepare_tasks(args: argparse.Namespace) -> list[dict]:
    """Load, filter, and optionally checkout tasks based on CLI args."""
    from benchmark.swebench.tasks import load_tasks_from_hf, load_tasks_from_jsonl, prepare_tasks, select_tasks

    tasks = load_tasks_from_jsonl(args.tasks_jsonl) if args.tasks_jsonl else load_tasks_from_hf(args.tasks_hf)

    tasks = select_tasks(tasks, instance_ids=args.instance_ids, difficulties=args.difficulties)

    if not args.no_checkout:
        tasks = prepare_tasks(tasks, args.repos_dir)

    return tasks


def _run_gate_cmd(args: argparse.Namespace) -> None:
    """Execute the gate subcommand: run 2-task dry run and check criteria."""
    from benchmark.swebench.gate import GateConfig, format_gate_report, run_gate

    tasks = _load_and_prepare_tasks(args)
    config = GateConfig(
        seed=args.seed,
        model=args.model,
        timeout=args.timeout,
        results_dir=args.results_dir,
        patches_dir=args.results_dir / "patches",
        dry_run=args.dry_run,
        skip_eval=args.skip_eval,
    )
    result = run_gate(tasks, config)
    print(format_gate_report(result))  # noqa: T201
    sys.exit(0 if result.passed else 1)


def _run_all_cmd(args: argparse.Namespace) -> None:
    """Execute the run subcommand: full benchmark run with optional resume."""
    from benchmark.swebench.runner import PLANKTON_ROOT, load_completed_ids, run_all

    tasks = _load_and_prepare_tasks(args)
    patches_dir = args.results_dir / "patches"
    completed_ids = load_completed_ids(args.results_dir) if args.resume else None
    result = run_all(
        tasks,
        seed=args.seed,
        model=args.model,
        timeout=args.timeout,
        results_dir=args.results_dir,
        patches_dir=patches_dir,
        plankton_root=PLANKTON_ROOT,
        completed_ids=completed_ids,
        dry_run=args.dry_run,
    )
    if result["aborted"]:
        print(f"ABORTED: {result['abort_reason']}")  # noqa: T201
    print(f"Completed: {result['tasks_completed']}, Skipped: {result['tasks_skipped']}")  # noqa: T201
    sys.exit(1 if result["aborted"] else 0)


def _run_prereqs_cmd(args: argparse.Namespace) -> None:
    """Execute the prereqs subcommand: run Phase 0 checks."""
    from benchmark.swebench.prereqs import format_report, run_all_checks

    results = run_all_checks(full_mode=args.full)
    print(format_report(results))  # noqa: T201
    sys.exit(0 if all(r.passed for r in results) else 1)


def main() -> None:
    """Parse args and dispatch to the appropriate subcommand handler."""
    args = _build_parser().parse_args()
    if args.subcommand == "gate":
        _run_gate_cmd(args)
    elif args.subcommand == "run":
        _run_all_cmd(args)
    elif args.subcommand == "prereqs":
        _run_prereqs_cmd(args)


if __name__ == "__main__":
    main()
