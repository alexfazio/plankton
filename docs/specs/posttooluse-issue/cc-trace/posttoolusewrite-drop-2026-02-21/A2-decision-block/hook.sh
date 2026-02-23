#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/A2-decision-block/marker.txt"
echo '{"decision":"block","reason":"3 violations remain after auto-fix"}'
exit 0
