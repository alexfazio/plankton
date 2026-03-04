"""Integration tests for inject_hooks robustness."""

from __future__ import annotations

from pathlib import Path

import pytest


class TestHooksRobustness:
    """Tests for inject_hooks robustness under error conditions."""

    def test_inject_hooks_missing_source_raises_clear_error(self, tmp_path):
        """inject_hooks should raise FileNotFoundError when .claude/hooks/ doesn't exist."""
        from benchmark.swebench.runner import inject_hooks

        fake_plankton_root = tmp_path / "fake_plankton"
        fake_plankton_root.mkdir()
        task_dir = tmp_path / "task"
        task_dir.mkdir()

        with pytest.raises(FileNotFoundError, match="not found"):
            inject_hooks(task_dir, plankton_root=fake_plankton_root)

    def test_inject_hooks_file_instead_of_dir_raises_clear_error(self, tmp_path):
        """inject_hooks should distinguish 'not a directory' from 'not found'."""
        from benchmark.swebench.runner import inject_hooks

        fake_root = tmp_path / "fake_root"
        claude_dir = fake_root / ".claude"
        claude_dir.mkdir(parents=True)
        # Create hooks as a file, not a directory
        (claude_dir / "hooks").write_text("not a dir")
        task_dir = tmp_path / "task"
        task_dir.mkdir()

        with pytest.raises(FileNotFoundError, match="exists but is not a directory"):
            inject_hooks(task_dir, plankton_root=fake_root)

    def test_inject_hooks_partial_config_copies_what_exists(self, tmp_path):
        """inject_hooks should copy existing config files and skip missing ones."""
        from benchmark.swebench.runner import inject_hooks

        fake_root = tmp_path / "root"
        hooks_src = fake_root / ".claude" / "hooks"
        hooks_src.mkdir(parents=True)
        (hooks_src / "test_hook.sh").write_text("#!/bin/sh\necho ok\n")
        # Only create .ruff.toml, not ty.toml or subprocess-settings.json
        (fake_root / ".ruff.toml").write_text("[lint]\n")

        task_dir = tmp_path / "task"
        task_dir.mkdir()

        inject_hooks(task_dir, plankton_root=fake_root)

        # Hook was copied
        assert (task_dir / ".claude" / "hooks" / "test_hook.sh").exists()
        # .ruff.toml was copied
        assert (task_dir / ".ruff.toml").exists()
        # ty.toml was not created (source didn't exist)
        assert not (task_dir / "ty.toml").exists()
