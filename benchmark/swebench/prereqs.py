"""Phase 0 prerequisite checks for the SWE-bench benchmark."""

from __future__ import annotations

import dataclasses
import json
import os
import re
import shutil
import subprocess  # noqa: S404  # nosec B404
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Callable

PLANKTON_ROOT = Path(__file__).resolve().parents[2]


@dataclasses.dataclass
class PrereqResult:
    """Result of a single prerequisite check."""

    name: str
    passed: bool
    detail: str
    step: int  # Phase 0 step number (1-11)


def _parse_version(v: str) -> tuple[int, ...]:
    """Parse a version string into a tuple of ints for comparison."""
    parts: list[int] = []
    for p in v.strip().split("."):
        m = re.match(r"^\d+", p)
        if m:
            parts.append(int(m.group()))
        else:
            break
    return tuple(parts)


# ---------- checks ----------


def check_claude_version(*, run_fn: Callable[..., Any] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 1: Verify claude CLI version >= 2.1.50."""
    if run_fn is None:
        run_fn = lambda: subprocess.run(["claude", "-v"], capture_output=True, text=True, check=False)  # noqa: E731 S603 S607  # nosec B603 B607
    try:
        proc = run_fn()
        version_str = proc.stdout.strip()
        if _parse_version(version_str) >= (2, 1, 50):
            return PrereqResult(name="check_claude_version", passed=True, detail=f"v{version_str}", step=1)
        return PrereqResult(name="check_claude_version", passed=False, detail=f"v{version_str} < 2.1.50", step=1)
    except FileNotFoundError:
        return PrereqResult(name="check_claude_version", passed=False, detail="claude CLI not found", step=1)


def check_bare_alias(
    *,
    settings_path: Path | None = None,
    which_fn: Callable[[str], str | None] | None = None,
    **_kwargs: Any,
) -> PrereqResult:
    """Step 2: Verify bare-settings.json and cc alias.

    Note: shutil.which cannot inspect shell aliases, so this only
    checks that a 'cc' binary exists on PATH — not that it expands
    to 'claude --bare ...'. The ADR's manual check uses
    `type cc | grep -q '-bare'` for alias verification.
    """
    settings_path = settings_path or Path.home() / ".claude" / "bare-settings.json"
    which_fn = which_fn or shutil.which
    issues: list[str] = []
    if not settings_path.exists():
        issues.append(f"{settings_path} missing")
    else:
        try:
            data = json.loads(settings_path.read_text())
        except json.JSONDecodeError as exc:
            issues.append(f"invalid JSON: {exc}")
            data = {}
        if data and not data.get("disableAllHooks"):
            issues.append("disableAllHooks not true")
    if not which_fn("cc"):
        issues.append("cc alias not found")
    if issues:
        return PrereqResult(name="check_bare_alias", passed=False, detail="; ".join(issues), step=2)
    return PrereqResult(name="check_bare_alias", passed=True, detail="bare-settings.json ok, cc found", step=2)


def check_hooks_present(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 3: Verify hooks dir has .sh files and .ruff.toml exists."""
    root = plankton_root or PLANKTON_ROOT
    hooks_dir = root / ".claude" / "hooks"
    issues: list[str] = []
    if not hooks_dir.is_dir():
        issues.append("hooks dir missing")
    elif not list(hooks_dir.glob("*.sh")):
        issues.append("no .sh files in hooks")
    issues.extend(f"{cfg} missing" for cfg in (".ruff.toml", "ty.toml") if not (root / cfg).exists())
    if issues:
        return PrereqResult(name="check_hooks_present", passed=False, detail="; ".join(issues), step=3)
    return PrereqResult(name="check_hooks_present", passed=True, detail="hooks and .ruff.toml present", step=3)


def check_baseline_no_hooks(*, settings_path: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 4: Verify bare-settings.json has disableAllHooks=true."""
    settings_path = settings_path or Path.home() / ".claude" / "bare-settings.json"
    if not settings_path.exists():
        return PrereqResult(name="check_baseline_no_hooks", passed=False, detail="settings file missing", step=4)
    data = json.loads(settings_path.read_text())
    if data.get("disableAllHooks") is True:
        return PrereqResult(name="check_baseline_no_hooks", passed=True, detail="disableAllHooks=true", step=4)
    return PrereqResult(name="check_baseline_no_hooks", passed=False, detail="disableAllHooks not true", step=4)


def check_claude_md_renamed(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 5: Verify CLAUDE.md does NOT exist at plankton_root."""
    root = plankton_root or PLANKTON_ROOT
    if (root / "CLAUDE.md").exists():
        return PrereqResult(name="check_claude_md_renamed", passed=False, detail="CLAUDE.md still present", step=5)
    return PrereqResult(name="check_claude_md_renamed", passed=True, detail="CLAUDE.md absent", step=5)


def check_subprocess_workarounds(
    *, which_fn: Callable[[str], str | None] | None = None, **_kwargs: Any
) -> PrereqResult:
    """Step 6: Verify `script` command available."""
    which_fn = which_fn or shutil.which
    if which_fn("script"):
        return PrereqResult(name="check_subprocess_workarounds", passed=True, detail="script found", step=6)
    return PrereqResult(name="check_subprocess_workarounds", passed=False, detail="script not found", step=6)


def check_eval_harness(*, which_fn: Callable[[str], str | None] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 7: Check if hal-eval OR sb is available."""
    which_fn = which_fn or shutil.which
    for cmd in ("hal-eval", "sb"):
        if which_fn(cmd):
            return PrereqResult(name="check_eval_harness", passed=True, detail=f"{cmd} found", step=7)
    return PrereqResult(name="check_eval_harness", passed=False, detail="neither hal-eval nor sb found", step=7)


def check_subprocess_permission_fix(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 8: Verify multi_linter.sh has permission flags."""
    root = plankton_root or PLANKTON_ROOT
    hook = root / ".claude" / "hooks" / "multi_linter.sh"
    if not hook.exists():
        return PrereqResult(
            name="check_subprocess_permission_fix", passed=False, detail="multi_linter.sh missing", step=8
        )
    content = hook.read_text()
    missing = [flag for flag in ("dangerously-skip-permissions", "disallowedTools") if flag not in content]
    if missing:
        return PrereqResult(
            name="check_subprocess_permission_fix", passed=False, detail=f"missing: {', '.join(missing)}", step=8
        )
    return PrereqResult(name="check_subprocess_permission_fix", passed=True, detail="permission flags present", step=8)


def check_tool_restriction(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 9: Verify agent.py contains tool blocklist."""
    root = plankton_root or PLANKTON_ROOT
    agent = root / "benchmark" / "swebench" / "agent.py"
    if not agent.exists():
        return PrereqResult(name="check_tool_restriction", passed=False, detail="agent.py missing", step=9)
    content = agent.read_text()
    if "WebFetch,WebSearch,Task" in content:
        return PrereqResult(name="check_tool_restriction", passed=True, detail="tool blocklist present", step=9)
    return PrereqResult(name="check_tool_restriction", passed=False, detail="tool blocklist missing", step=9)


def check_concurrency_probe(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 10: Check for concurrency probe results."""
    root = plankton_root or PLANKTON_ROOT
    probe = root / "benchmark" / "swebench" / "results" / "concurrency_probe.json"
    if probe.exists():
        return PrereqResult(name="check_concurrency_probe", passed=True, detail="probe results found", step=10)
    return PrereqResult(name="check_concurrency_probe", passed=True, detail="warning: no probe results", step=10)


def check_archive_clean(*, plankton_root: Path | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 11: Check no stale .py files in benchmark/ root."""
    root = plankton_root or PLANKTON_ROOT
    bench = root / "benchmark"
    if not bench.is_dir():
        return PrereqResult(name="check_archive_clean", passed=True, detail="benchmark/ dir absent", step=11)
    stale = [f.name for f in bench.glob("*.py")]
    if stale:
        return PrereqResult(
            name="check_archive_clean", passed=False, detail=f"stale files: {', '.join(stale)}", step=11
        )
    return PrereqResult(name="check_archive_clean", passed=True, detail="benchmark/ clean", step=11)


# ---------- full-mode live checks ----------

_HOOK_EVIDENCE = ("PreToolUse", "PostToolUse", "Notification", "Stop")


def _clean_env() -> dict[str, str]:
    """Return os.environ without CLAUDECODE to allow nested claude -p calls."""
    return {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}


def check_baseline_zero_hooks(*, run_fn: Callable[..., Any] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 4 full: Run trivial task via bare claude -p, check stdout for hook evidence."""
    if run_fn is None:
        claude_bin = shutil.which("claude")
        if not claude_bin:
            return PrereqResult(name="check_baseline_zero_hooks_live", passed=False, detail="claude not found", step=4)
        run_fn = lambda: subprocess.run(  # noqa: E731 S603  # nosec B603
            [
                claude_bin,
                "--setting-sources",
                "",
                "--settings",
                str(Path.home() / ".claude" / "bare-settings.json"),
                "--strict-mcp-config",
                "--disable-slash-commands",
                "-p",
                "--dangerously-skip-permissions",
                "say hello",
            ],
            capture_output=True,
            text=True,
            check=False,
            env=_clean_env(),
        )
    proc = run_fn()
    stdout = proc.stdout or ""
    for marker in _HOOK_EVIDENCE:
        if marker in stdout:
            return PrereqResult(
                name="check_baseline_zero_hooks_live", passed=False, detail=f"hook evidence: {marker}", step=4
            )
    return PrereqResult(name="check_baseline_zero_hooks_live", passed=True, detail="no hook evidence", step=4)


def check_tty_workaround(*, run_fn: Callable[..., Any] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 6a: Run script -q /dev/null claude -p 'say hi', verify non-empty stdout and exit 0."""
    if run_fn is None:
        script_bin = shutil.which("script")
        claude_bin = shutil.which("claude")
        if not script_bin or not claude_bin:
            missing = [name for name, path in [("script", script_bin), ("claude", claude_bin)] if not path]
            return PrereqResult(
                name="check_tty_workaround_live", passed=False, detail=f"not found: {', '.join(missing)}", step=6
            )
        run_fn = lambda: subprocess.run(  # noqa: E731 S603  # nosec B603
            [script_bin, "-q", "/dev/null", claude_bin, "-p", "--dangerously-skip-permissions", "say hi"],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
            env=_clean_env(),
        )
    try:
        proc = run_fn()
    except subprocess.TimeoutExpired:
        return PrereqResult(name="check_tty_workaround_live", passed=False, detail="timeout after 60s", step=6)
    if proc.returncode != 0:
        return PrereqResult(name="check_tty_workaround_live", passed=False, detail=f"exit {proc.returncode}", step=6)
    if not (proc.stdout or "").strip():
        return PrereqResult(name="check_tty_workaround_live", passed=False, detail="empty stdout", step=6)
    return PrereqResult(name="check_tty_workaround_live", passed=True, detail="tty workaround ok", step=6)


def check_large_stdin(*, run_fn: Callable[..., Any] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 6b: Pipe >7000 chars to claude -p, verify non-empty stdout."""
    if run_fn is None:
        claude_bin = shutil.which("claude")
        if not claude_bin:
            return PrereqResult(name="check_large_stdin_live", passed=False, detail="claude not found", step=6)
        large_input = "x" * 7001
        run_fn = lambda: subprocess.run(  # noqa: E731 S603  # nosec B603
            [claude_bin, "-p", "--dangerously-skip-permissions", "echo back"],
            input=large_input,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
            env=_clean_env(),
        )
    try:
        proc = run_fn()
    except subprocess.TimeoutExpired:
        return PrereqResult(name="check_large_stdin_live", passed=False, detail="timeout after 60s", step=6)
    if not (proc.stdout or "").strip():
        return PrereqResult(name="check_large_stdin_live", passed=False, detail="empty stdout", step=6)
    return PrereqResult(name="check_large_stdin_live", passed=True, detail="large stdin ok", step=6)


def check_tool_blocklist_enforcement(*, run_fn: Callable[..., Any] | None = None, **_kwargs: Any) -> PrereqResult:
    """Step 9: Run claude -p with --disallowedTools, verify blocked tool not in output."""
    if run_fn is None:
        claude_bin = shutil.which("claude")
        if not claude_bin:
            return PrereqResult(name="check_tool_blocklist_live", passed=False, detail="claude not found", step=9)
        run_fn = lambda: subprocess.run(  # noqa: E731 S603  # nosec B603
            [
                claude_bin,
                "-p",
                "--dangerously-skip-permissions",
                "use WebFetch",
                "--disallowedTools",
                "WebFetch,WebSearch,Task",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
            env=_clean_env(),
        )
    try:
        proc = run_fn()
    except subprocess.TimeoutExpired:
        return PrereqResult(name="check_tool_blocklist_live", passed=False, detail="timeout after 60s", step=9)
    stdout = proc.stdout or ""
    if "WebFetch" in stdout and "tool_use" in stdout:
        return PrereqResult(
            name="check_tool_blocklist_live", passed=False, detail="blocked tool appeared in output", step=9
        )
    return PrereqResult(name="check_tool_blocklist_live", passed=True, detail="blocklist enforced", step=9)


# ---------- registry + runner ----------

FULL_CHECKS: list[Callable[..., PrereqResult]] = [
    check_baseline_zero_hooks,
    check_tty_workaround,
    check_large_stdin,
    check_tool_blocklist_enforcement,
]

CHECKS: list[Callable[..., PrereqResult]] = [
    check_claude_version,
    check_bare_alias,
    check_hooks_present,
    check_baseline_no_hooks,
    check_claude_md_renamed,
    check_subprocess_workarounds,
    check_eval_harness,
    check_subprocess_permission_fix,
    check_tool_restriction,
    check_concurrency_probe,
    check_archive_clean,
]


def run_all_checks(
    *, plankton_root: Path | None = None, full_mode: bool = False, **overrides: Any
) -> list[PrereqResult]:
    """Run all checks, catching exceptions per-check.

    When *full_mode* is True the FULL_CHECKS list is appended.
    """
    root = plankton_root or PLANKTON_ROOT
    kwargs: dict[str, Any] = {"plankton_root": root, **overrides}
    checks = list(CHECKS)
    if full_mode:
        checks.extend(FULL_CHECKS)
    results: list[PrereqResult] = []
    for check_fn in checks:
        try:
            result = check_fn(**kwargs)
        except Exception as exc:
            name = getattr(check_fn, "__name__", repr(check_fn))
            result = PrereqResult(name=name, passed=False, detail=f"Exception: {exc}", step=0)
        results.append(result)
    return results


def format_report(results: list[PrereqResult]) -> str:
    """Format results as a markdown table."""
    lines = ["# Phase 0 Prerequisites", "", "| Step | Check | Status | Detail |", "| --- | --- | --- | --- |"]
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        lines.append(f"| {r.step} | {r.name} | {status} | {r.detail} |")
    passed = sum(1 for r in results if r.passed)
    lines.append(f"\n{passed}/{len(results)} checks passed.")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys

    results = run_all_checks()
    print(format_report(results))  # noqa: T201
    sys.exit(0 if all(r.passed for r in results) else 1)
