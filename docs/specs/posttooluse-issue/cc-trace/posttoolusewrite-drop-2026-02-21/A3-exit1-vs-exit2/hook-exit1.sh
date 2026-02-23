#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A3-exit1-vs-exit2/exit1-marker.txt"
echo "[hook] fatal hook failure" >&2
exit 1
