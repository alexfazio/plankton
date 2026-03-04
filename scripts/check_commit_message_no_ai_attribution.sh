#!/usr/bin/env bash
# Reject commit messages that include AI attribution boilerplate.

set -euo pipefail

msg_file="${1:-}"
[[ -z "${msg_file}" ]] && exit 0
[[ ! -f "${msg_file}" ]] && exit 0

if grep -Eiq '(^|\b)(co-authored-by|claude code|claude)(\b|:)' "${msg_file}"; then
  cat >&2 <<'EOF'
Commit message rejected: AI attribution strings are not allowed.

Blocked patterns:
- Co-Authored-By
- Claude Code
- Claude
EOF
  exit 1
fi

exit 0
