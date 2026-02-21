#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B1-debug-four-channel/stderr-exit2-marker.txt"
echo "[hook] 3 violation(s) remain after delegation" >&2
exit 2
