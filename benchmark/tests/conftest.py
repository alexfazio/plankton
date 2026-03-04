"""Shared test fixtures."""

from pathlib import Path

import pytest


@pytest.fixture
def tmp_data_dir(tmp_path: Path) -> Path:
    """Create a temporary data directory for test isolation."""
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    return data_dir
