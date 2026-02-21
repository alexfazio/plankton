#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A1-edit-vs-write/edit-marker.txt"
echo "[hook] 3 violation(s) remain after delegation" >&2
exit 2
