"""Smoke test to verify test infrastructure works."""


def test_import_plankton():
    """Verify the plankton package is importable."""
    import src  # noqa: F811

    assert hasattr(src, "__doc__")
