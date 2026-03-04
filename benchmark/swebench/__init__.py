"""Plankton SWE-bench Verified Mini benchmark infrastructure."""

from __future__ import annotations

from .agent import solve
from .analyze import compute_mcnemar, generate_report, load_paired_results, load_paired_results_from_combined
from .gate import CriterionResult, GateConfig, GateResult, format_gate_report, run_gate
from .hal_adapter import run
from .prereqs import PrereqResult, run_all_checks
from .runner import load_completed_ids, run_all, run_task
from .tasks import checkout_repo, load_tasks_from_hf, load_tasks_from_jsonl, prepare_tasks, select_tasks

__all__ = [
    "CriterionResult",
    "GateConfig",
    "GateResult",
    "PrereqResult",
    "checkout_repo",
    "compute_mcnemar",
    "format_gate_report",
    "generate_report",
    "load_completed_ids",
    "load_paired_results",
    "load_paired_results_from_combined",
    "load_tasks_from_hf",
    "load_tasks_from_jsonl",
    "prepare_tasks",
    "run",
    "run_all",
    "run_all_checks",
    "run_gate",
    "run_task",
    "select_tasks",
    "solve",
]
