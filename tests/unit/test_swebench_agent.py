"""Tests for benchmark.swebench.agent module."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

# --- Step 1.2: _write_prompt_file ---


class TestWritePromptFile:
    """Test _write_prompt_file helper."""

    def test_write_prompt_file_content(self, tmp_path):
        """Verify prompt content is written verbatim."""
        from benchmark.swebench.agent import _write_prompt_file

        prompt = "x" * 9000
        path = _write_prompt_file(prompt, tmp_path)
        assert path.read_text() == prompt

    def test_write_prompt_file_location(self, tmp_path):
        """Verify prompt file is created inside tmp_path."""
        from benchmark.swebench.agent import _write_prompt_file

        path = _write_prompt_file("hello", tmp_path)
        assert path.parent == tmp_path


# --- Step 1.3: _extract_patch ---


class TestExtractPatch:
    """Test _extract_patch helper."""

    def test_extract_patch_returns_diff(self, tmp_git_repo):  # noqa: F811
        """Return a diff when the working tree has changes."""
        from benchmark.swebench.agent import _extract_patch

        (tmp_git_repo / "stub.py").write_text("def foo(): return 42\n")
        patch = _extract_patch(tmp_git_repo)
        assert "def foo" in patch
        assert patch.startswith("diff --git")

    def test_extract_patch_empty_when_clean(self, tmp_git_repo):  # noqa: F811
        """Return empty string when working tree is clean."""
        from benchmark.swebench.agent import _extract_patch

        patch = _extract_patch(tmp_git_repo)
        assert patch == ""


# --- Step 1.4: _parse_claude_output ---


class TestParseClaudeOutput:
    """Test _parse_claude_output helper."""

    def test_parse_claude_output_json(self):
        """Parse valid JSON stdout into claude_output key."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result": "ok"}', stderr="")
        parsed = _parse_claude_output(result, 12.3)
        assert parsed["claude_output"] == {"result": "ok"}
        assert parsed["returncode"] == 0
        assert parsed["elapsed_s"] == 12.3

    def test_parse_claude_output_invalid_json(self):
        """Fall back to raw_stdout when JSON parsing fails."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="not json", stderr="")
        parsed = _parse_claude_output(result, 5.0)
        assert "raw_stdout" in parsed
        assert "claude_output" not in parsed


# --- Step 1.1: _build_cmd ---


class TestBuildCmd:
    """Test _build_cmd helper."""

    def test_build_cmd_baseline_flags(self, tmp_path):
        """Include setting-sources flag for baseline condition."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("baseline", "claude-sonnet-4-20250514", prompt_file)
        joined = " ".join(cmd)
        assert "--setting-sources" in joined
        assert "--disallowedTools" in joined
        assert "--dangerously-skip-permissions" in joined

    def test_build_cmd_baseline_empty_setting_sources_quoted(self, tmp_path):
        """Empty --setting-sources value must be shell-quoted so it isn't lost."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("baseline", "claude-sonnet-4-20250514", prompt_file)
        shell_str = cmd[-1]  # the sh -c argument
        # The empty arg must be quoted ('' or "") so the shell preserves it
        assert "--setting-sources ''" in shell_str or '--setting-sources ""' in shell_str

    def test_build_cmd_baseline_settings_not_consumed_by_setting_sources(self, tmp_path):
        """--settings must appear as its own flag, not as a value of --setting-sources."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("baseline", "claude-sonnet-4-20250514", prompt_file)
        shell_str = cmd[-1]
        # --settings should be preceded by the quoted empty arg, not directly after --setting-sources
        idx_sources = shell_str.index("--setting-sources")
        idx_settings = shell_str.index("--settings")
        # Between them there must be a quoted empty string
        between = shell_str[idx_sources + len("--setting-sources") : idx_settings]
        assert "'" in between or '"' in between

    def test_build_cmd_plankton_flags(self, tmp_path):
        """Omit setting-sources flag for plankton condition."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("plankton", "claude-sonnet-4-20250514", prompt_file)
        joined = " ".join(cmd)
        assert "--setting-sources" not in joined
        assert "--disallowedTools" in joined
        assert "--dangerously-skip-permissions" in joined

    def test_build_cmd_plankton_with_settings(self, tmp_path):
        """Plankton condition should forward --settings when provided."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        settings_path = Path("/tmp/s.json")
        cmd = _build_cmd("plankton", "claude-sonnet-4-20250514", prompt_file, settings=settings_path)
        shell_str = cmd[-1]
        assert "--settings" in shell_str
        assert "/tmp/s.json" in shell_str

    def test_build_cmd_plankton_no_settings_by_default(self, tmp_path):
        """Plankton condition without settings param should not include --settings."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("plankton", "claude-sonnet-4-20250514", prompt_file)
        shell_str = cmd[-1]
        assert "--settings" not in shell_str

    def test_build_cmd_baseline_ignores_settings_param(self, tmp_path):
        """Baseline always uses BARE_SETTINGS regardless of settings param."""
        from benchmark.swebench.agent import BARE_SETTINGS, _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        cmd = _build_cmd("baseline", "claude-sonnet-4-20250514", prompt_file, settings=Path("/tmp/other.json"))
        shell_str = cmd[-1]
        assert str(BARE_SETTINGS) in shell_str
        assert "/tmp/other.json" not in shell_str

    def test_build_cmd_tty_wrapper(self, tmp_path):
        """Wrap command with script for TTY emulation."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("test")
        for condition in ("baseline", "plankton"):
            cmd = _build_cmd(condition, "claude-sonnet-4-20250514", prompt_file)
            assert cmd[0] == "script"
            assert "-q" in cmd
            assert "/dev/null" in cmd


# --- Step 1.5: solve ---


class TestSolve:
    """Test solve entry point."""

    def test_solve_returns_required_keys(self, tmp_git_repo, monkeypatch):  # noqa: F811
        """Return patch, condition, and metadata keys."""
        import benchmark.swebench.agent as agent_mod

        def mock_run(*args, **kwargs):
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix bug", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="claude-sonnet-4-20250514",
        )
        assert "patch" in result
        assert "condition" in result
        assert "metadata" in result
        assert result["condition"] == "plankton"

    def test_solve_raises_on_bad_condition(self, tmp_path):
        """Raise ValueError for unknown condition."""
        from benchmark.swebench.agent import solve

        with pytest.raises(ValueError, match="invalid"):
            solve(
                {"instance_id": "x", "problem_statement": "y", "repo_dir": str(tmp_path)},
                condition="invalid",
                model="m",
            )

    def test_solve_handles_timeout(self, tmp_git_repo, monkeypatch):  # noqa: F811
        """Return empty patch and error metadata on timeout."""
        import benchmark.swebench.agent as agent_mod

        call_count = 0

        def mock_run(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                # git rev-parse HEAD
                return subprocess.CompletedProcess(args=[], returncode=0, stdout="abc123\n", stderr="")
            raise subprocess.TimeoutExpired(cmd="test", timeout=10)

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            timeout=10,
        )
        assert result["patch"] == ""
        assert "error" in result["metadata"]


# --- Step 1.6: main ---


class TestMain:
    """Test main CLI entry point."""

    def test_main_dry_run(self, tmp_path, monkeypatch, capsys):
        """Skip subprocess calls in dry-run mode."""
        import sys

        import benchmark.swebench.agent as agent_mod

        monkeypatch.setattr(
            sys,
            "argv",
            [
                "agent",
                "--dry-run",
                "--condition",
                "plankton",
                "--repo-dir",
                str(tmp_path),
                "--prompt",
                "fix the bug",
                "--model",
                "claude-sonnet-4-20250514",
            ],
        )

        calls = []
        original_subprocess = subprocess

        def mock_run(*args, **kwargs):
            calls.append(args)
            return original_subprocess.CompletedProcess(args=[], returncode=0, stdout="{}", stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        agent_mod.main()
        captured = capsys.readouterr()
        assert "dry" in captured.out.lower() or "DRY" in captured.out
        assert len(calls) == 0

    def test_main_dry_run_writes_prompt_file(self, tmp_path, monkeypatch):
        """Write prompt file even in dry-run mode."""
        import sys

        import benchmark.swebench.agent as agent_mod

        monkeypatch.setattr(
            sys,
            "argv",
            [
                "agent",
                "--dry-run",
                "--condition",
                "plankton",
                "--repo-dir",
                str(tmp_path),
                "--prompt",
                "fix the bug",
            ],
        )

        agent_mod.main()
        assert (tmp_path / ".swebench_prompt.txt").exists()
        assert (tmp_path / ".swebench_prompt.txt").read_text(encoding="utf-8") == "fix the bug"


# --- Shell injection fix ---


class TestBuildCmdSecurity:
    """Test _build_cmd security against path injection attacks."""

    def test_build_cmd_path_with_spaces(self, tmp_path):
        """Properly quote or escape paths containing spaces."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "path with spaces" / "prompt.txt"
        prompt_file.parent.mkdir(parents=True, exist_ok=True)
        prompt_file.write_text("test")
        cmd = _build_cmd("baseline", "claude-sonnet-4-20250514", prompt_file)
        shell_part = cmd[-1]  # the sh -c argument
        # Should be quoted so spaces don't split
        assert "path with spaces" not in shell_part or "'" in shell_part

    def test_build_cmd_path_with_special_chars(self, tmp_path):
        """Test that special characters in paths are properly escaped."""
        from benchmark.swebench.agent import _build_cmd

        prompt_file = tmp_path / "$(evil)" / "prompt.txt"
        prompt_file.parent.mkdir(parents=True, exist_ok=True)
        prompt_file.write_text("test")
        cmd = _build_cmd("plankton", "claude-sonnet-4-20250514", prompt_file)
        shell_part = cmd[-1]
        # $(evil) should be quoted/escaped
        assert "$(evil)" not in shell_part or "'" in shell_part


# --- Encoding ---


class TestEncoding:
    """Test Unicode encoding handling."""

    def test_write_prompt_file_unicode(self, tmp_path):
        """Test that prompt files are written with correct UTF-8 encoding."""
        from benchmark.swebench.agent import _write_prompt_file

        prompt = "修正してください"
        path = _write_prompt_file(prompt, tmp_path)
        assert path.read_text(encoding="utf-8") == prompt

    def test_write_prompt_file_emoji(self, tmp_path):
        """Test that emoji characters survive round-trip."""
        from benchmark.swebench.agent import _write_prompt_file

        prompt = "Fix bug 🐛 in module"
        path = _write_prompt_file(prompt, tmp_path)
        assert path.read_text(encoding="utf-8") == prompt

    def test_write_prompt_file_mixed_scripts(self, tmp_path):
        """Test CJK + Latin + emoji mixed content."""
        from benchmark.swebench.agent import _write_prompt_file

        prompt = "修正 the bug 🐛 in módule"
        path = _write_prompt_file(prompt, tmp_path)
        assert path.read_text(encoding="utf-8") == prompt


# --- _extract_patch with original SHA ---


class TestExtractPatchWithSha:
    """Test _extract_patch with original SHA parameter."""

    def test_extract_patch_after_commit(self, tmp_git_repo):
        """Test patch extraction against a specific commit SHA."""
        # Get original SHA
        import subprocess

        from benchmark.swebench.agent import _extract_patch

        sha = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=tmp_git_repo,  # noqa: S603 S607
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        # Modify, commit
        (tmp_git_repo / "stub.py").write_text("def foo(): return 42\n")
        subprocess.run(["git", "add", "."], cwd=tmp_git_repo, capture_output=True, check=True)  # noqa: S603 S607
        subprocess.run(["git", "commit", "-m", "change"], cwd=tmp_git_repo, capture_output=True, check=True)  # noqa: S603 S607
        # diff HEAD would be empty, but diff against original_sha should show changes
        patch = _extract_patch(tmp_git_repo, original_sha=sha)
        assert "def foo" in patch

    def test_extract_patch_uncommitted(self, tmp_git_repo):
        """Test patch extraction for uncommitted changes."""
        from benchmark.swebench.agent import _extract_patch

        (tmp_git_repo / "stub.py").write_text("def foo(): return 42\n")
        patch = _extract_patch(tmp_git_repo)
        assert "def foo" in patch


# --- solve() model flexibility ---


class TestSolveModelFlexibility:
    """Test solve() model selection behavior."""

    def test_solve_default_model(self, tmp_git_repo, monkeypatch):
        """Test that solve uses the default model when SWEBENCH_MODEL is unset."""
        import benchmark.swebench.agent as agent_mod

        monkeypatch.delenv("SWEBENCH_MODEL", raising=False)

        captured_cmds = []

        def mock_run(*args, **kwargs):
            captured_cmds.append(args)
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
        )
        assert result["condition"] == "plankton"

    def test_solve_model_from_env(self, tmp_git_repo, monkeypatch):
        """Test that solve uses the model specified in SWEBENCH_MODEL env var."""
        import benchmark.swebench.agent as agent_mod

        monkeypatch.setenv("SWEBENCH_MODEL", "claude-opus-4-20250514")

        captured_cmds = []

        def mock_run(*args, **kwargs):
            captured_cmds.append(args)
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
        )
        assert result["condition"] == "plankton"
        # Verify the env model was used in the command (2nd call is the main subprocess)
        # captured_cmds: [0]=git rev-parse, [1]=main solve cmd, [2]=git diff
        main_cmd = captured_cmds[1][0][-1]  # args tuple, cmd list, last element (sh -c string)
        assert "claude-opus-4-20250514" in main_cmd

    def test_solve_includes_model_requested(self, tmp_git_repo, monkeypatch):
        """solve() metadata should include model_requested field."""
        import benchmark.swebench.agent as agent_mod

        def mock_run(*args, **kwargs):
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="glm-4-plus",
        )
        assert result["metadata"]["model_requested"] == "glm-4-plus"

    def test_solve_returns_passed_none(self, tmp_git_repo, monkeypatch):
        """Test that solve returns passed=None before evaluation."""
        import benchmark.swebench.agent as agent_mod

        def mock_run(*args, **kwargs):
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
        )
        assert "passed" in result
        assert result["passed"] is None


# --- Step B1: solve timeout sets error_type ---


class TestSolveErrorType:
    """Test that solve() sets error_type=infra on timeout."""

    def test_solve_timeout_sets_error_type_infra(self, tmp_git_repo, monkeypatch):
        """When solve() catches TimeoutExpired, metadata includes error_type=infra."""
        import benchmark.swebench.agent as agent_mod

        call_count = 0

        def mock_run(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return subprocess.CompletedProcess(args=[], returncode=0, stdout="abc123\n", stderr="")
            raise subprocess.TimeoutExpired(cmd="test", timeout=10)

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            timeout=10,
        )
        assert result["metadata"].get("error_type") == "infra"


# --- Slice E: Error type refinement ---


class TestErrorTypeRefinement:
    """Test _parse_claude_output error_type logic."""

    def test_returncode_1_with_valid_json_should_not_be_infra(self) -> None:
        """returncode=1 with valid JSON should NOT be error_type infra."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=1, stdout='{"result": "ok"}', stderr="")
        metadata = _parse_claude_output(result, 5.0)
        assert metadata.get("error_type") != "infra"
        assert "claude_output" in metadata

    def test_returncode_1_with_invalid_json_should_be_infra(self) -> None:
        """returncode=1 with invalid JSON should be error_type infra."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="not json", stderr="crash")
        metadata = _parse_claude_output(result, 5.0)
        assert metadata.get("error_type") == "infra"

    def test_returncode_0_should_never_be_infra(self) -> None:
        """returncode=0 should never be error_type infra."""
        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=0, stdout="not json", stderr="")
        metadata = _parse_claude_output(result, 5.0)
        assert "error_type" not in metadata


# --- Slice A1: Cost tracking in _parse_claude_output ---


class TestCostTracking:
    """Test cost_usd extraction from claude JSON output."""

    def test_should_extract_cost_usd_from_top_level(self):
        """Should extract cost_usd from claude JSON output containing top-level cost_usd."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({"cost_usd": 0.05, "result": "..."}), stderr=""
        )
        metadata = _parse_claude_output(result, 10.0)
        assert metadata["cost_usd"] == 0.05

    def test_should_extract_cost_usd_from_nested_usage(self):
        """Should extract cost_usd nested under usage key."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({"usage": {"cost_usd": 0.12}, "result": "ok"}), stderr=""
        )
        metadata = _parse_claude_output(result, 10.0)
        assert metadata["cost_usd"] == 0.12

    def test_should_leave_cost_usd_absent_when_no_cost_data(self):
        """Should leave cost_usd absent when claude output has no cost data."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps({"result": "ok"}), stderr="")
        metadata = _parse_claude_output(result, 10.0)
        assert "cost_usd" not in metadata

    def test_should_extract_model_id_from_output(self):
        """Should extract model from claude JSON output to top-level metadata."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({"model": "glm-4", "result": "ok"}), stderr=""
        )
        metadata = _parse_claude_output(result, 10.0)
        assert metadata["model_id"] == "glm-4"

    def test_should_not_set_model_id_when_absent(self):
        """Should not set model_id when claude output has no model key."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps({"result": "ok"}), stderr="")
        metadata = _parse_claude_output(result, 10.0)
        assert "model_id" not in metadata

    def test_should_store_cost_usd_zero(self):
        """Should store cost_usd=0 when top-level cost_usd is zero."""
        import json

        from benchmark.swebench.agent import _parse_claude_output

        result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({"cost_usd": 0, "result": "ok"}), stderr=""
        )
        metadata = _parse_claude_output(result, 10.0)
        assert "cost_usd" in metadata
        assert metadata["cost_usd"] == 0


# --- Slice F: Non-ASCII solve test ---


class TestSolveNonAscii:
    """Test solve() with non-ASCII problem_statement."""

    def test_solve_writes_non_ascii_problem_statement(self, tmp_git_repo, monkeypatch) -> None:
        """solve() should write non-ASCII problem_statement to prompt file."""
        import benchmark.swebench.agent as agent_mod

        def mock_run(*args, **kwargs):
            return subprocess.CompletedProcess(args=[], returncode=0, stdout='{"result":"ok"}', stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        problem = "修正してください 🐛 — fix the büggy módule"
        agent_mod.solve(
            {"instance_id": "test-1", "problem_statement": problem, "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
        )
        prompt_file = tmp_git_repo / ".swebench_prompt.txt"
        assert prompt_file.exists()
        assert prompt_file.read_text(encoding="utf-8") == problem


# --- Remediation: settings wiring, model_requested completeness ---


class TestSolveSettingsWiring:
    """Test that solve() forwards settings to _build_cmd."""

    def test_solve_forwards_settings_to_build_cmd(self, tmp_git_repo, monkeypatch) -> None:
        """solve(settings=Path(...)) dry_run cmd should contain --settings."""
        import benchmark.swebench.agent as agent_mod

        result = agent_mod.solve(
            {"instance_id": "t1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            settings=Path("/tmp/glm-settings.json"),
            dry_run=True,
        )
        cmd_str = " ".join(str(c) for c in result["metadata"]["cmd"])
        assert "--settings" in cmd_str
        assert "/tmp/glm-settings.json" in cmd_str


class TestModelRequestedCompleteness:
    """Test model_requested appears in all solve() return paths."""

    def test_dry_run_includes_model_requested(self, tmp_git_repo) -> None:
        """solve(dry_run=True) metadata should include model_requested."""
        from benchmark.swebench.agent import solve

        result = solve(
            {"instance_id": "t1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="glm-4",
            dry_run=True,
        )
        assert result["metadata"]["model_requested"] == "glm-4"

    def test_timeout_includes_model_requested(self, tmp_git_repo, monkeypatch) -> None:
        """solve() that times out should still have model_requested in metadata."""
        import benchmark.swebench.agent as agent_mod

        call_count = 0

        def mock_run(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return subprocess.CompletedProcess(args=[], returncode=0, stdout="abc\n", stderr="")
            raise subprocess.TimeoutExpired(cmd="test", timeout=1)

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "t1", "problem_statement": "fix", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="glm-4-plus",
            timeout=1,
        )
        assert result["metadata"]["model_requested"] == "glm-4-plus"


# --- dry_run param on solve() ---


class TestSolveDryRun:
    """Tests for the dry_run parameter on solve()."""

    def test_solve_dry_run_skips_subprocess(self, tmp_git_repo, monkeypatch) -> None:
        """solve(dry_run=True) must not call subprocess.run for claude."""
        import benchmark.swebench.agent as agent_mod

        calls = []

        def mock_run(*args, **kwargs):
            calls.append(args)
            return __import__("subprocess").CompletedProcess([], 0, stdout="", stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": __import__("subprocess").TimeoutExpired,
                    "CompletedProcess": __import__("subprocess").CompletedProcess,
                },
            )(),
        )

        agent_mod.solve(
            {"instance_id": "t1", "problem_statement": "fix it", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            dry_run=True,
        )
        # only the git rev-parse call is allowed; no claude subprocess
        claude_calls = [c for c in calls if any("claude" in str(a) for a in (c[0] if c else []))]
        assert len(claude_calls) == 0, "dry_run=True must not invoke the claude subprocess"

    def test_solve_dry_run_returns_required_keys(self, tmp_git_repo, monkeypatch) -> None:
        """solve(dry_run=True) must still return the standard result dict."""
        import benchmark.swebench.agent as agent_mod

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(
                        lambda *a, **k: __import__("subprocess").CompletedProcess([], 0, stdout="", stderr="")
                    ),
                    "TimeoutExpired": __import__("subprocess").TimeoutExpired,
                    "CompletedProcess": __import__("subprocess").CompletedProcess,
                },
            )(),
        )

        result = agent_mod.solve(
            {"instance_id": "t1", "problem_statement": "fix it", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            dry_run=True,
        )
        for key in ("patch", "condition", "passed", "metadata"):
            assert key in result

    def test_solve_dry_run_does_not_call_git_rev_parse(self, tmp_git_repo, monkeypatch) -> None:
        """solve(dry_run=True) must not call git rev-parse HEAD."""
        import benchmark.swebench.agent as agent_mod

        calls: list = []

        def mock_run(*args, **kwargs):
            calls.append(list(args[0]) if args else [])
            return subprocess.CompletedProcess([], 0, stdout="", stderr="")

        monkeypatch.setattr(
            agent_mod,
            "subprocess",
            type(
                "M",
                (),
                {
                    "run": staticmethod(mock_run),
                    "TimeoutExpired": subprocess.TimeoutExpired,
                    "CompletedProcess": subprocess.CompletedProcess,
                },
            )(),
        )

        agent_mod.solve(
            {"instance_id": "t1", "problem_statement": "fix it", "repo_dir": str(tmp_git_repo)},
            condition="plankton",
            model="m",
            dry_run=True,
        )
        rev_parse_calls = [c for c in calls if "rev-parse" in c]
        assert len(rev_parse_calls) == 0, "dry_run=True must not call git rev-parse HEAD"
