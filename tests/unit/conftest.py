"""Shared fixtures for unit tests."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def tmp_git_repo(tmp_path: Path) -> Path:
    """Real initialized git repo with one committed file."""
    subprocess.run(["git", "init"], cwd=tmp_path, capture_output=True, check=True)  # noqa: S603 S607
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=tmp_path, capture_output=True, check=True)  # noqa: S603 S607
    subprocess.run(["git", "config", "user.name", "T"], cwd=tmp_path, capture_output=True, check=True)  # noqa: S603 S607
    (tmp_path / "stub.py").write_text("def foo(): pass\n")
    subprocess.run(["git", "add", "."], cwd=tmp_path, capture_output=True, check=True)  # noqa: S603 S607
    subprocess.run(["git", "commit", "-m", "init"], cwd=tmp_path, capture_output=True, check=True)  # noqa: S603 S607
    return tmp_path


@pytest.fixture
def mock_completed_process():
    """Factory for subprocess.CompletedProcess with sensible defaults."""

    def _make(*, returncode: int = 0, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr=stderr)

    return _make
