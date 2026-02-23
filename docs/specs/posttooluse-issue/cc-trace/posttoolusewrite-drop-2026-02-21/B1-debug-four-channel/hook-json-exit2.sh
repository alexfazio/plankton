#!/bin/bash
echo "hook-ran-at-$(date +%s)" > "/Users/alex/Documents/GitHub/plankton/.claude/tests/hooks/posttoolusewrite-drop-2026-02-21/B1-debug-four-channel/json-exit2-marker.txt"
echo '{"hookResult":"error","message":"[hook] 3 violation(s) remain"}'
exit 2
