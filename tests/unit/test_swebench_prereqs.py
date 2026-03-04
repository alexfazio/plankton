"""Tests for benchmark.swebench.prereqs — Phase 0 prerequisite checks."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


# --- Test 1: PrereqResult is a dataclass with expected fields ---
def test_prereq_result_dataclass():
    from benchmark.swebench.prereqs import PrereqResult

    r = PrereqResult(name="test", passed=True, detail="ok", step=1)
    assert r.name == "test"
    assert r.passed is True
    assert r.detail == "ok"
    assert r.step == 1


# --- Test 2: CHECKS list has 11 entries ---
def test_checks_list_has_11_entries():
    from benchmark.swebench.prereqs import CHECKS

    assert len(CHECKS) == 11


# --- Test 3: check_claude_version passes for >= 2.1.50 ---
def test_claude_version_pass():
    from benchmark.swebench.prereqs import check_claude_version

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="2.1.50\n", stderr="")
    r = check_claude_version(run_fn=fake_run)
    assert r.passed is True
    assert r.step == 1


# --- Test 4: check_claude_version fails for < 2.1.50 ---
def test_claude_version_fail_old():
    from benchmark.swebench.prereqs import check_claude_version

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="2.0.0\n", stderr="")
    r = check_claude_version(run_fn=fake_run)
    assert r.passed is False


# --- Test 5: check_claude_version fails when claude not found ---
def test_claude_version_not_found():
    from benchmark.swebench.prereqs import check_claude_version

    def bad_run(*a, **kw):
        raise FileNotFoundError("claude not found")

    r = check_claude_version(run_fn=bad_run)
    assert r.passed is False
    assert "not found" in r.detail.lower()


# --- Test 6: check_bare_alias passes with correct settings ---
def test_bare_alias_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_bare_alias

    settings = tmp_path / "bare-settings.json"
    settings.write_text(json.dumps({"disableAllHooks": True}))
    r = check_bare_alias(settings_path=settings, which_fn=lambda x: "/usr/bin/cc")
    assert r.passed is True
    assert r.step == 2


# --- Test 6b: check_bare_alias fails with friendly message on invalid JSON ---
def test_bare_alias_invalid_json(tmp_path: Path):
    from benchmark.swebench.prereqs import check_bare_alias

    settings = tmp_path / "bare-settings.json"
    settings.write_text("{not valid json")
    r = check_bare_alias(settings_path=settings, which_fn=lambda x: "/usr/bin/cc")
    assert r.passed is False
    assert "invalid JSON" in r.detail


# --- Test 7: check_bare_alias fails when settings missing ---
def test_bare_alias_fail_no_file(tmp_path: Path):
    from benchmark.swebench.prereqs import check_bare_alias

    r = check_bare_alias(settings_path=tmp_path / "nope.json", which_fn=lambda x: "/usr/bin/cc")
    assert r.passed is False


# --- Test 8: check_hooks_present passes ---
def test_hooks_present_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_hooks_present

    hooks_dir = tmp_path / ".claude" / "hooks"
    hooks_dir.mkdir(parents=True)
    (hooks_dir / "lint.sh").write_text("#!/bin/bash\n")
    (tmp_path / ".ruff.toml").write_text("")
    (tmp_path / "ty.toml").write_text("")
    r = check_hooks_present(plankton_root=tmp_path)
    assert r.passed is True
    assert r.step == 3


# --- Test 8b: check_hooks_present warns when ty.toml missing ---
def test_hooks_present_missing_ty_toml(tmp_path: Path):
    from benchmark.swebench.prereqs import check_hooks_present

    hooks_dir = tmp_path / ".claude" / "hooks"
    hooks_dir.mkdir(parents=True)
    (hooks_dir / "lint.sh").write_text("#!/bin/bash\n")
    (tmp_path / ".ruff.toml").write_text("")
    # ty.toml intentionally missing
    r = check_hooks_present(plankton_root=tmp_path)
    assert r.passed is False
    assert "ty.toml" in r.detail


# --- Test 9: check_hooks_present fails when dir missing ---
def test_hooks_present_fail(tmp_path: Path):
    from benchmark.swebench.prereqs import check_hooks_present

    r = check_hooks_present(plankton_root=tmp_path)
    assert r.passed is False


# --- Test 10: check_baseline_no_hooks passes ---
def test_baseline_no_hooks_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_baseline_no_hooks

    settings = tmp_path / "bare-settings.json"
    settings.write_text(json.dumps({"disableAllHooks": True}))
    r = check_baseline_no_hooks(settings_path=settings)
    assert r.passed is True
    assert r.step == 4


# --- Test 11: check_claude_md_renamed passes when absent ---
def test_claude_md_renamed_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_claude_md_renamed

    r = check_claude_md_renamed(plankton_root=tmp_path)
    assert r.passed is True
    assert r.step == 5


# --- Test 12: check_claude_md_renamed fails when present ---
def test_claude_md_renamed_fail(tmp_path: Path):
    from benchmark.swebench.prereqs import check_claude_md_renamed

    (tmp_path / "CLAUDE.md").write_text("# Claude")
    r = check_claude_md_renamed(plankton_root=tmp_path)
    assert r.passed is False


# --- Test 13: check_subprocess_workarounds passes ---
def test_subprocess_workarounds_pass():
    from benchmark.swebench.prereqs import check_subprocess_workarounds

    r = check_subprocess_workarounds(which_fn=lambda x: "/usr/bin/script")
    assert r.passed is True
    assert r.step == 6


# --- Test 14: check_eval_harness passes with hal-eval ---
def test_eval_harness_pass():
    from benchmark.swebench.prereqs import check_eval_harness

    r = check_eval_harness(which_fn=lambda x: "/usr/bin/hal-eval" if x == "hal-eval" else None)
    assert r.passed is True
    assert r.step == 7


# --- Test 15: check_eval_harness fails when neither found ---
def test_eval_harness_fail():
    from benchmark.swebench.prereqs import check_eval_harness

    r = check_eval_harness(which_fn=lambda x: None)
    assert r.passed is False


# --- Test 16: check_subprocess_permission_fix passes ---
def test_subprocess_permission_fix_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_subprocess_permission_fix

    hook = tmp_path / ".claude" / "hooks" / "multi_linter.sh"
    hook.parent.mkdir(parents=True)
    hook.write_text("#!/bin/bash\n# dangerously-skip-permissions\n# disallowedTools\n")
    r = check_subprocess_permission_fix(plankton_root=tmp_path)
    assert r.passed is True
    assert r.step == 8


# --- Test 17: check_subprocess_permission_fix fails when missing ---
def test_subprocess_permission_fix_fail(tmp_path: Path):
    from benchmark.swebench.prereqs import check_subprocess_permission_fix

    r = check_subprocess_permission_fix(plankton_root=tmp_path)
    assert r.passed is False


# --- Test 18: check_tool_restriction passes ---
def test_tool_restriction_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_tool_restriction

    agent = tmp_path / "benchmark" / "swebench" / "agent.py"
    agent.parent.mkdir(parents=True)
    agent.write_text('blocklist = "WebFetch,WebSearch,Task"\n')
    r = check_tool_restriction(plankton_root=tmp_path)
    assert r.passed is True
    assert r.step == 9


# --- Test 19: check_concurrency_probe passes with warning ---
def test_concurrency_probe_warning(tmp_path: Path):
    from benchmark.swebench.prereqs import check_concurrency_probe

    r = check_concurrency_probe(plankton_root=tmp_path)
    assert r.passed is True
    assert "warning" in r.detail.lower()
    assert r.step == 10


# --- Test 20: check_archive_clean passes ---
def test_archive_clean_pass(tmp_path: Path):
    from benchmark.swebench.prereqs import check_archive_clean

    bench = tmp_path / "benchmark"
    bench.mkdir()
    swe = bench / "swebench"
    swe.mkdir()
    (swe / "agent.py").write_text("")  # inside swebench/ is fine
    r = check_archive_clean(plankton_root=tmp_path)
    assert r.passed is True
    assert r.step == 11


# --- Test 21: run_all_checks returns 11 results even with exceptions ---
def test_run_all_checks_catches_exceptions(tmp_path: Path):
    from benchmark.swebench.prereqs import run_all_checks

    results = run_all_checks(
        plankton_root=tmp_path,
        run_fn=lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("boom")),
        which_fn=lambda x: None,
        settings_path=tmp_path / "nonexistent.json",
    )
    assert len(results) == 11
    for r in results:
        assert hasattr(r, "passed")


# --- Test 22: format_report includes PASS/FAIL ---
def test_format_report():
    from benchmark.swebench.prereqs import PrereqResult, format_report

    results = [
        PrereqResult(name="a", passed=True, detail="ok", step=1),
        PrereqResult(name="b", passed=False, detail="bad", step=2),
    ]
    report = format_report(results)
    assert "PASS" in report
    assert "FAIL" in report
    assert "1/2" in report


# --- Test 23: CLI exit logic returns 0 when all checks pass ---
def test_cli_exit_0_all_pass():
    from benchmark.swebench.prereqs import PrereqResult

    all_pass = [PrereqResult(name=f"c{i}", passed=True, detail="ok", step=i) for i in range(1, 12)]
    assert all(r.passed for r in all_pass)
    # This mirrors the __main__ block: sys.exit(0 if all(r.passed ...) else 1)
    exit_code = 0 if all(r.passed for r in all_pass) else 1
    assert exit_code == 0


# --- Test 24: CLI exit logic returns 1 when any check fails ---
def test_cli_exit_1_on_failure():
    from benchmark.swebench.prereqs import PrereqResult

    results = [
        PrereqResult(name="c1", passed=True, detail="ok", step=1),
        PrereqResult(name="c2", passed=False, detail="bad", step=2),
    ]
    exit_code = 0 if all(r.passed for r in results) else 1
    assert exit_code == 1


# --- Test 25: importable from benchmark.swebench ---
def test_importable_from_package():
    from benchmark.swebench import PrereqResult, run_all_checks  # noqa: F401


# --- Test 26: should return 11 results when full_mode=False ---
def test_full_mode_false_returns_11(tmp_path: Path):
    from benchmark.swebench.prereqs import run_all_checks

    results = run_all_checks(
        plankton_root=tmp_path,
        full_mode=False,
        run_fn=lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="2.1.50\n", stderr=""),
        which_fn=lambda x: None,
        settings_path=tmp_path / "nonexistent.json",
    )
    assert len(results) == 11


# --- Test 27: should return 15 results when full_mode=True ---
def test_full_mode_true_returns_15(tmp_path: Path):
    from benchmark.swebench.prereqs import run_all_checks

    results = run_all_checks(
        plankton_root=tmp_path,
        full_mode=True,
        run_fn=lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="2.1.50\n", stderr=""),
        which_fn=lambda x: None,
        settings_path=tmp_path / "nonexistent.json",
    )
    assert len(results) == 15


# --- Test 28: check_baseline_zero_hooks passes when no hook evidence ---
def test_baseline_zero_hooks_pass():
    from benchmark.swebench.prereqs import check_baseline_zero_hooks

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="Hello world\n", stderr="")
    r = check_baseline_zero_hooks(run_fn=fake_run)
    assert r.passed is True
    assert r.step == 4
    assert r.name == "check_baseline_zero_hooks_live"


# --- Test 29: check_baseline_zero_hooks fails when hook evidence found ---
def test_baseline_zero_hooks_fail_hook_evidence():
    from benchmark.swebench.prereqs import check_baseline_zero_hooks

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(
        args=[], returncode=0, stdout="PostToolUse hook fired\n", stderr=""
    )
    r = check_baseline_zero_hooks(run_fn=fake_run)
    assert r.passed is False


# --- Test 30: check_tty_workaround passes when command completes ---
def test_tty_workaround_pass():
    from benchmark.swebench.prereqs import check_tty_workaround

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="hi\n", stderr="")
    r = check_tty_workaround(run_fn=fake_run)
    assert r.passed is True
    assert r.step == 6
    assert r.name == "check_tty_workaround_live"


# --- Test 31: check_tty_workaround fails when command fails ---
def test_tty_workaround_fail():
    from benchmark.swebench.prereqs import check_tty_workaround

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="error")
    r = check_tty_workaround(run_fn=fake_run)
    assert r.passed is False


# --- Test 32: check_large_stdin passes when output non-empty ---
def test_large_stdin_pass():
    from benchmark.swebench.prereqs import check_large_stdin

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(args=[], returncode=0, stdout="response\n", stderr="")
    r = check_large_stdin(run_fn=fake_run)
    assert r.passed is True
    assert r.step == 6
    assert r.name == "check_large_stdin_live"


# --- Test 33: check_tool_blocklist_enforcement passes when blocked tool absent ---
def test_tool_blocklist_enforcement_pass():
    from benchmark.swebench.prereqs import check_tool_blocklist_enforcement

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(
        args=[], returncode=0, stdout="I cannot use that tool\n", stderr=""
    )
    r = check_tool_blocklist_enforcement(run_fn=fake_run)
    assert r.passed is True
    assert r.step == 9
    assert r.name == "check_tool_blocklist_live"


def test_parse_version_with_suffix():
    """Should parse '2.1.52 (Claude Code)' as (2, 1, 52)."""
    from benchmark.swebench.prereqs import _parse_version

    assert _parse_version("2.1.52 (Claude Code)") == (2, 1, 52)


def test_parse_version_plain():
    """Should parse '2.1.50' as (2, 1, 50) (no regression)."""
    from benchmark.swebench.prereqs import _parse_version

    assert _parse_version("2.1.50") == (2, 1, 50)


def test_claude_version_pass_with_suffix():
    """Should return True for version check with suffixed version string."""
    from benchmark.swebench.prereqs import check_claude_version

    fake_run = lambda *a, **kw: subprocess.CompletedProcess(
        args=[], returncode=0, stdout="2.1.52 (Claude Code)\n", stderr=""
    )
    r = check_claude_version(run_fn=fake_run)
    assert r.passed is True


def test_tty_workaround_default_excludes_claudecode(monkeypatch):
    """Should exclude CLAUDECODE from env in check_tty_workaround default run_fn."""
    monkeypatch.setenv("CLAUDECODE", "1")
    captured_env = {}

    def spy_run(*args, **kwargs):
        captured_env.update(kwargs.get("env", {}))
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="hi\n", stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", spy_run)
    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: f"/usr/bin/{x}")
    from benchmark.swebench.prereqs import check_tty_workaround

    check_tty_workaround()
    assert "CLAUDECODE" not in captured_env


def test_large_stdin_default_excludes_claudecode(monkeypatch):
    """Should exclude CLAUDECODE from env in check_large_stdin default run_fn."""
    monkeypatch.setenv("CLAUDECODE", "1")
    captured_env = {}

    def spy_run(*args, **kwargs):
        captured_env.update(kwargs.get("env", {}))
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="response\n", stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", spy_run)
    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: f"/usr/bin/{x}")
    from benchmark.swebench.prereqs import check_large_stdin

    check_large_stdin()
    assert "CLAUDECODE" not in captured_env


# --- Test 34: should fail gracefully when script not found in check_tty_workaround ---
def test_tty_workaround_script_not_found(monkeypatch):
    from benchmark.swebench.prereqs import check_tty_workaround

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: None)
    r = check_tty_workaround()
    assert r.passed is False
    assert "not found" in r.detail


# --- Test 34b: should report only missing binary in check_tty_workaround ---
def test_tty_workaround_only_claude_missing(monkeypatch):
    from benchmark.swebench.prereqs import check_tty_workaround

    monkeypatch.setattr(
        "benchmark.swebench.prereqs.shutil.which",
        lambda x: "/usr/bin/script" if x == "script" else None,
    )
    r = check_tty_workaround()
    assert r.passed is False
    assert "claude" in r.detail
    assert "script" not in r.detail


# --- Test 34c: should report only missing binary when script missing ---
def test_tty_workaround_only_script_missing(monkeypatch):
    from benchmark.swebench.prereqs import check_tty_workaround

    monkeypatch.setattr(
        "benchmark.swebench.prereqs.shutil.which",
        lambda x: "/usr/bin/claude" if x == "claude" else None,
    )
    r = check_tty_workaround()
    assert r.passed is False
    assert "script" in r.detail
    assert "claude" not in r.detail


# --- Test 35: should fail gracefully when claude not found in check_large_stdin ---
def test_large_stdin_claude_not_found(monkeypatch):
    from benchmark.swebench.prereqs import check_large_stdin

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: None)
    r = check_large_stdin()
    assert r.passed is False
    assert "not found" in r.detail


# --- Test 36: should use step=0 for exception results ---
def test_run_all_checks_exception_step_zero(tmp_path: Path):
    from benchmark.swebench.prereqs import run_all_checks

    def boom(**kwargs):
        raise RuntimeError("kaboom")

    results = run_all_checks(
        plankton_root=tmp_path,
        run_fn=boom,
        which_fn=lambda x: None,
        settings_path=tmp_path / "nonexistent.json",
    )
    exception_results = [r for r in results if "Exception" in r.detail]
    assert len(exception_results) > 0
    for r in exception_results:
        assert r.step == 0


# --- Test 37: should use bare settings flags in check_baseline_zero_hooks ---
def test_baseline_zero_hooks_uses_setting_sources(monkeypatch):
    from benchmark.swebench.prereqs import check_baseline_zero_hooks

    captured_args: list[list[str]] = []

    def spy_run(*args, **kwargs):
        captured_args.append(args[0] if args else kwargs.get("args", []))
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="hello\n", stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", spy_run)
    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: f"/usr/bin/{x}")
    check_baseline_zero_hooks()
    assert len(captured_args) == 1
    cmd = captured_args[0]
    assert "--setting-sources" in cmd
    assert any("bare-settings.json" in str(a) for a in cmd)


# --- Test 38: should fail gracefully when claude not found in check_baseline_zero_hooks ---
def test_baseline_zero_hooks_claude_not_found(monkeypatch):
    from benchmark.swebench.prereqs import check_baseline_zero_hooks

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: None)
    r = check_baseline_zero_hooks()
    assert r.passed is False
    assert "not found" in r.detail


# --- Test 39: check_tty_workaround subprocess.run must include timeout ---
def test_tty_workaround_default_run_fn_has_timeout(monkeypatch):
    """The default run_fn passed to subprocess.run must specify a timeout."""
    import subprocess

    from benchmark.swebench.prereqs import check_tty_workaround

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: "/usr/bin/" + x)
    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured.update(kwargs)
        return subprocess.CompletedProcess(cmd, 0, stdout="hi", stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", fake_run)
    check_tty_workaround()
    assert "timeout" in captured, "subprocess.run must be called with a timeout="


# --- Test 40: check_large_stdin subprocess.run must include timeout ---
def test_large_stdin_default_run_fn_has_timeout(monkeypatch):
    """The default run_fn passed to subprocess.run must specify a timeout."""
    import subprocess

    from benchmark.swebench.prereqs import check_large_stdin

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: "/usr/bin/claude")
    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured.update(kwargs)
        return subprocess.CompletedProcess(cmd, 0, stdout="hi", stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", fake_run)
    check_large_stdin()
    assert "timeout" in captured, "subprocess.run must be called with a timeout="


# --- Test 41: check_tool_blocklist_enforcement subprocess.run must include timeout ---
def test_tool_blocklist_default_run_fn_has_timeout(monkeypatch):
    """The default run_fn passed to subprocess.run must specify a timeout."""
    import subprocess

    from benchmark.swebench.prereqs import check_tool_blocklist_enforcement

    monkeypatch.setattr("benchmark.swebench.prereqs.shutil.which", lambda x: "/usr/bin/claude")
    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured.update(kwargs)
        return subprocess.CompletedProcess(cmd, 0, stdout='{"type":"result"}', stderr="")

    monkeypatch.setattr("benchmark.swebench.prereqs.subprocess.run", fake_run)
    check_tool_blocklist_enforcement()
    assert "timeout" in captured, "subprocess.run must be called with a timeout="


# --- Test 42: check_tty_workaround handles TimeoutExpired gracefully ---
def test_tty_workaround_timeout_returns_fail():
    """If the subprocess times out, check_tty_workaround should return passed=False."""
    import subprocess

    from benchmark.swebench.prereqs import check_tty_workaround

    def hanging_run():
        raise subprocess.TimeoutExpired(cmd="claude", timeout=30)

    r = check_tty_workaround(run_fn=hanging_run)
    assert r.passed is False
    assert "timeout" in r.detail.lower()


# --- Test 43: check_large_stdin handles TimeoutExpired gracefully ---
def test_large_stdin_timeout_returns_fail():
    """If the subprocess times out, check_large_stdin should return passed=False."""
    import subprocess

    from benchmark.swebench.prereqs import check_large_stdin

    def hanging_run():
        raise subprocess.TimeoutExpired(cmd="claude", timeout=30)

    r = check_large_stdin(run_fn=hanging_run)
    assert r.passed is False
    assert "timeout" in r.detail.lower()


# --- Test 44: check_tool_blocklist_enforcement handles TimeoutExpired gracefully ---
def test_tool_blocklist_timeout_returns_fail():
    """If the subprocess times out, check_tool_blocklist_enforcement returns passed=False."""
    import subprocess

    from benchmark.swebench.prereqs import check_tool_blocklist_enforcement

    def hanging_run():
        raise subprocess.TimeoutExpired(cmd="claude", timeout=30)

    r = check_tool_blocklist_enforcement(run_fn=hanging_run)
    assert r.passed is False
    assert "timeout" in r.detail.lower()
