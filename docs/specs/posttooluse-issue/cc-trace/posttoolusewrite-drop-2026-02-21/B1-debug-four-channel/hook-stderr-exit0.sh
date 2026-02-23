#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B1-debug-four-channel/stderr-exit0-marker.txt"
echo "[hook:warning] subprocess timed out (exit 124)" >&2
exit 0
