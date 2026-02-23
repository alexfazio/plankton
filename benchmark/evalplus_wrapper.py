"""Wrapper for evalplus.evaluate that patches macOS setrlimit crashes.

macOS does not support setrlimit for RLIMIT_AS or RLIMIT_DATA when
the requested limit exceeds the current hard limit. This wrapper
monkeypatches setrlimit to silently skip failures before evalplus
imports it.
"""

import resource
import sys
from contextlib import suppress

_original_setrlimit = resource.setrlimit


def _safe_setrlimit(which: int, limits: tuple[int, int]) -> None:
    """Try setrlimit, silently skip on ValueError (macOS)."""
    with suppress(ValueError):
        _original_setrlimit(which, limits)


resource.setrlimit = _safe_setrlimit  # type: ignore[assignment]

# Now run evalplus evaluate as if invoked directly
from evalplus.evaluate import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
